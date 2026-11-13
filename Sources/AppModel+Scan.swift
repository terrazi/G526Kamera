import Foundation
import UIKit
import CoreVideo

/// Bir çekimin sonucu
struct CaptureResult {
    /// Sayfa alındı ya da kullanıcıdan sayfa yeniden istendi (ilerleme sayılır)
    var progressed = false
}

extension AppModel {
    // MARK: - Başlatma / durdurma

    /// Taramayı başlatır (otomasyon bağlantısı ya da ekrandaki düğme); zaten sürüyorsa yok sayılır
    func beginScan(auto: Bool) {
        guard !phase.isRunning else {
            tlog("[akış] tarama zaten sürüyor; başlatma yok sayıldı")
            return
        }
        phase = .startingCamera
        runTask = Task { [weak self] in await self?.runScan(auto: auto) }
    }

    /// Sürmekte olan taramayı durdurur
    func stopScan() {
        guard phase.isRunning else { return }
        tlog("[akış] kullanıcı taramayı durdurdu")
        runTask?.cancel()
        voice.stop()
    }

    /// Bütün tarama: kamera → tarama → internet → Gemini → okuma
    func runScan(auto: Bool) async {
        prepareRun()
        announceStart()
        var reason = ScanRules.EndReason.cameraLost
        let cameraOK = await bringUpCamera()
        if cameraOK && !Task.isCancelled {
            reason = await scanLoop()
        } else if !Task.isCancelled && cameraState != .stopped {
            say("Kameraya bağlanılamadı.")
        }
        if Task.isCancelled { endCancelled(); return }
        await finishScan(reason: reason)
        if Task.isCancelled { endCancelled(); return }
        let online = await restoreInternet()
        if Task.isCancelled { endCancelled(); return }
        if pages.isEmpty {
            setStatus("Taranan sayfa yok")
            say("Hiç sayfa alınamadı. Gönderilecek bir şey yok.")
            await voice.waitUntilIdle()
        } else if online {
            await answerAndRead()
        } else {
            addNote("internet", "İnternete ulaşılamadı. Sayfalar belge klasöründe (\(runName)); cevaplar alınamadı.")
            say("İnternete ulaşılamadı. Sayfalar klasörde duruyor.")
            await voice.waitUntilIdle()
        }
        if Task.isCancelled { endCancelled(); return }
        endRun(success: true)
    }

    /// Bir taramanın başında durum sıfırlanır; ön koşullar denetlenir
    func prepareRun() {
        pages = []
        coverageStreak = 0
        runName = RunName.make()
        ScanFiles.removeAll()
        files = ScanFiles(runName: runName)
        latestSample = nil
        lastDocAt = nil
        videoCount = 0
        notes = []
        pageCount = 0
        answers = []
        lastSaid = ""
        UIApplication.shared.isIdleTimerDisabled = true
        phase = .startingCamera
        updatePowerSaving()
        configureVoice()
        if !folderReady {
            addNote("klasor", "Belge klasörü seçilmemiş: sayfalar ve videolar kaydedilemez. Ayarlar > Dosya bölümünden seçin.")
        }
        if settings.activeGeminiProfile.key.trimmed.isEmpty {
            addNote("gemini", "Gemini API anahtarı girilmemiş: cevaplar alınamaz. Ayarlar > Gemini bölümüne yazın.")
        }
        if !voice.headphonesReady {
            addNote("kulaklik", "Kulaklık bağlı değil: sesli uyarılar verilmiyor (telefon hoparlöründen hiç konuşulmaz). Kulaklığı bağlayın.")
        }
    }

    /// Açılışta söylenen: kaç soru / sayfa taranacak
    func announceStart() {
        let questions = settings.questionTotal
        let pageTotal = settings.pageTotal
        var parts: [String] = []
        if questions > 0 { parts.append("\(TurkishNumbers.cardinal(questions)) soru") }
        if pageTotal > 0 { parts.append("\(TurkishNumbers.cardinal(pageTotal)) sayfa") }
        if parts.isEmpty {
            addNote("toplam", "Soru ve sayfa sayısı girilmemiş (Ayarlar > Tarama). Tarama, kadraj boşalınca bitecek; eksik soru bildirilemez.")
            say("Soru sayısı girilmemiş.")
        } else {
            say(TurkishNumbers.capitalised(parts.joined(separator: ", ")) + " taranacak.")
        }
        if questions == 0 && pageTotal > 0 {
            addNote("toplam", "Soru sayısı girilmemiş (Ayarlar > Tarama): eksik cevaplar bildirilemez.")
        }
    }

    func endCancelled() {
        stopCapturing()
        stopCamera()
        voice.stop()
        phase = .failed
        setStatus("Durduruldu")
        finishRunCommon()
    }

    func endRun(success: Bool) {
        phase = success ? .done : .failed
        setStatus(success ? "Deneme sınavı tamamlandı" : "Durdu")
        finishRunCommon()
    }

    private func finishRunCommon() {
        UIApplication.shared.isIdleTimerDisabled = false
        ScreenDimmer.shared.update(dim: false)
        pipeline.guidanceOn = false
        files?.cleanup()
    }

    /// Çekim penceresini ve videoyu bırakır
    func stopCapturing() {
        collector.cancel()
        if recorder.isRecording { recorder.cancel() }
    }

    // MARK: - Kamera

    /// Kameranın Wi-Fi kestirmesini çalıştırır (adı yazılmışsa) ve görüntü gelene kadar bekler; gelmezse ayardaki sayıda yeniden dener
    func bringUpCamera() async -> Bool {
        phase = .startingCamera
        guard CameraUID(settings.uid) != nil else {
            addNote("kamera", "Kamera adı (UID) girilmemiş. Ayarlar > Kamera bölümüne yazın.")
            say("Kamera adı girilmemiş.")
            return false
        }
        let tries = max(settings.shortcutTries, 1)
        let wait = Double(settings.shortcutWaitSeconds)
        let shortcut = settings.cameraShortcutName.trimmed
        for attempt in 1...tries {
            if Task.isCancelled { return false }
            if !shortcut.isEmpty {
                setStatus("Kamera Wi-Fi kestirmesi çalışıyor (\(attempt)/\(tries))")
                _ = await runShortcutAndWait(shortcut)
                if Task.isCancelled { return false }
            }
            guard startCameraClient() else { return false }
            setStatus("Kameraya bağlanılıyor (\(attempt)/\(tries))")
            let deadline = now() + wait
            while now() < deadline && !Task.isCancelled {
                if decoding {
                    removeNote("kamera")
                    return true
                }
                await pause(0.5)
            }
            tlog("[akış] kamera \(attempt). denemede gelmedi")
        }
        addNote("kamera", "Kamera görüntüsü gelmedi (\(tries) deneme). Kameranın açık olduğunu ve telefonun kameranın Wi-Fi ağında olduğunu kontrol edin.")
        return false
    }

    // MARK: - Tarama döngüsü

    /// Kamera açıkken: evrak bekler, görünce 2 sn sonra sayfa çekimini başlatır, sonucu işler; bitiş kuralları dolunca nedenini verir
    func scanLoop() async -> ScanRules.EndReason {
        phase = .waitingForPage
        setStatus("Evrak bekleniyor")
        configureGuidance()
        let start = now()
        var docSince: TimeInterval?
        var emptySince: TimeInterval? = start
        var lastWindowEnd: TimeInterval?
        var lastProgress = start
        var lastReady: TimeInterval?
        var captures = 0
        var lostSince: TimeInterval?
        var repairs = 0
        while !Task.isCancelled {
            await pause(0.25)
            let t = now()
            // Kamera sağlığı: görüntü kesilirse yeniden bağlanılır (en çok 3 kez)
            if decoding {
                lostSince = nil
            } else if lostSince == nil {
                lostSince = t
            }
            if let lost = lostSince, t - lost >= ScanRules.cameraLostSeconds {
                if repairs >= 3 { return .cameraLost }
                repairs += 1
                say("Kamera görüntüsü kesildi. Yeniden bağlanılıyor.")
                let ok = await bringUpCamera()
                phase = captures == 0 ? .waitingForPage : .scanning
                lostSince = nil
                if !ok { return .cameraLost }
                docSince = nil
                continue
            }
            // Kadrajda belge var mı: son 1,2 sn içinde belge ölçümü geldi mi
            let doc = lastDocAt.map { t - $0 < 1.2 } ?? false
            if doc {
                docSince = docSince ?? t
                emptySince = nil
            } else {
                docSince = nil
                emptySince = emptySince ?? t
            }
            let emptyFor = emptySince.map { t - $0 } ?? 0
            let verdict = ScanRules.verdict(pageTotal: settings.pageTotal, pages: pages.count, elapsed: t - start,
                                            maxSeconds: Double(settings.scanMaxMinutes) * 60,
                                            emptyFor: emptyFor, sinceProgress: t - lastProgress)
            if case .finish(let reason) = verdict { return reason }
            if captures == 0 {
                if ScanRules.readyGaveUp(waited: t - start, maxMinutes: settings.readyMaxMinutes) {
                    addNote("evrak", "Hazır uyarısına rağmen \(settings.readyMaxMinutes) dakika boyunca kameraya evrak gösterilmedi.")
                    return .readyTimeout
                }
                if !doc && ScanRules.readyPromptDue(lastSpoken: lastReady, now: t, repeatSeconds: settings.readyRepeatSeconds) {
                    lastReady = t
                    say("Kamera hazır. Taranacak evrakı hazırlayıp kameraya tutun.")
                }
            }
            // Belge görünüyor: 2 sn sonra sayfa çekimi başlar (konum tarifi ve kadraj beklemesi yoktur)
            if doc, let since = docSince, t - since >= ScanRules.settleSeconds, let s = latestSample, t - s.arrived < 2,
               ScanRules.canRearm(firstCapture: captures == 0, diffToCapture: s.diffToCapture, stillFor: s.stillFor,
                                  sinceLastWindow: lastWindowEnd.map { t - $0 } ?? Double.infinity) {
                phase = .scanning
                let result = await captureAndProcess()
                captures += 1
                let end = now()
                lastWindowEnd = end
                docSince = nil
                if result.progressed { lastProgress = end }
                pipeline.markCaptured()
                phase = .scanning
                setStatus(statusAfterCapture())
            }
        }
        return .cameraLost
    }

    func statusAfterCapture() -> String {
        if settings.pageTotal > 0 { return "Alınan sayfa: \(pages.count)/\(settings.pageTotal)" }
        return "Alınan sayfa: \(pages.count)"
    }

    // MARK: - Çekim

    /// Sayfa çekimi: ayardaki süre boyunca kare toplar ve video kaydeder (kamera sayfada gezdirilir), sonra kareleri ölçüp işler
    func captureAndProcess() async -> CaptureResult {
        videoCount += 1
        let seconds = Double(settings.sweepSeconds)
        let videoURL = files?.videoURL(index: videoCount)
        collector.begin()
        if let url = videoURL {
            recorder.start(to: url, orientation: settings.imageOrientation, maxSeconds: seconds + 0.5)
        }
        setStatus("Çekiliyor: kamerayı sayfada yavaşça gezdirin")
        await pause(seconds)
        if Task.isCancelled {
            collector.cancel()
            recorder.cancel()
            return CaptureResult()
        }
        let frames = collector.end()
        let video = await finishVideo(videoURL)
        setStatus("Sayfa inceleniyor…")
        return await processCapture(frames, video: video)
    }

    /// Videoyu kapatır; yazılabildiyse geçici dosyanın adresini verir
    private func finishVideo(_ url: URL?) async -> URL? {
        guard url != nil else { return nil }
        let result: Result<VideoRecorder.Output, VideoRecorder.Failure> = await withCheckedContinuation { continuation in
            recorder.finish { continuation.resume(returning: $0) }
        }
        switch result {
        case .success(let output):
            return output.url
        case .failure:
            tlog("[video] bu çekimin videosu alınamadı")
            return nil
        }
    }

    /// Çekimin karelerini ölçer; sayfa kenarları videoda görüldüyse (ya da deneme sınırı dolduysa) sayfayı alır, değilse yeniden ister
    func processCapture(_ frames: [CollectedFrame], video: URL?) async -> CaptureResult {
        var result = CaptureResult()
        guard !frames.isEmpty else {
            say("Görüntü alınamadı. Kamerayı kontrol edin.")
            return result
        }
        let orientation = settings.imageOrientation
        let mode = CoverageMode(rawValue: settings.coverageMode) ?? .topBottom
        let measured: [SweepFrame] = await Task.detached(priority: .userInitiated) {
            var out: [SweepFrame] = []
            for (i, f) in frames.enumerated() {
                let m = GuidanceAnalyzer.analyze(f.buffer, orientation: orientation)
                let edges = mode == .off ? nil : PageEdgeDetector.detect(f.buffer, orientation: orientation)
                out.append(SweepFrame(index: i, time: f.time, sharp: m?.sharp ?? 0, glare: m?.glare ?? 0, edges: edges))
            }
            return out
        }.value
        if Task.isCancelled { return result }
        let coverage = PageSweep.coverage(measured)
        let missing = coverage.missing(mode)
        tlog("[sayfa] \(frames.count) kare, kenar ölçülen \(coverage.measured), görülen kenar \(coverage.seen.count), eksik \(missing.count)")
        if !missing.isEmpty && coverageStreak + 1 < settings.pageAttempts {
            coverageStreak += 1
            if let v = video { try? FileManager.default.removeItem(at: v) }
            say(ScanRules.coverageRetryText(missing))
            result.progressed = true
            return result
        }
        let number = pages.count + 1
        let picks = PageSweep.stills(measured, maxCount: ScanRules.maxStills)
        let jpegs = await renderStills(picks: picks, frames: frames, page: number)
        var pdf: URL?
        if let files = files, !jpegs.isEmpty {
            do {
                pdf = try files.buildPDF(name: String(format: "Sayfa%02d.pdf", number), jpegs: jpegs)
            } catch {
                addNote("pdf", "\(number). sayfanın kareleri PDF'e çevrilemedi: \(error.localizedDescription)")
            }
        }
        guard pdf != nil || video != nil else {
            say("Sayfa kaydedilemedi. Yeniden deneyin.")
            return result
        }
        storeInFolder(pdf: pdf, video: video, page: number)
        pages.append(ScannedPage(number: number, pdf: pdf, video: video, missing: missing))
        pageCount = pages.count
        coverageStreak = 0
        result.progressed = true
        say(missing.isEmpty ? ScanRules.pageTakenText(number) : ScanRules.pageTakenIncompleteText(number, missing: missing))
        return result
    }

    /// Alınan sayfanın PDF'i ve videosu belge klasörüne yazılır (Sayfa01.pdf, Sayfa01.mp4)
    private func storeInFolder(pdf: URL?, video: URL?, page: Int) {
        do {
            if let pdf = pdf { try DocumentFolder.shared.store(file: pdf, subfolder: runName, name: pdf.lastPathComponent) }
            if let video = video {
                try DocumentFolder.shared.store(file: video, subfolder: runName, name: String(format: "Sayfa%02d.mp4", page))
            }
            removeNote("klasor")
        } catch {
            addNote("klasor", "Belge klasörüne yazılamadı: \(error.localizedDescription)")
        }
    }

    /// Seçilen karelerin tamamını JPEG dosyalarına yazar (arka planda; kırpma yok, sayfa olduğu gibi)
    func renderStills(picks: [Int], frames: [CollectedFrame], page: Int) async -> [URL] {
        guard let files = files else { return [] }
        let orientation = settings.imageOrientation
        let quality = settings.jpegQuality
        let sharpen = settings.sharpenImages
        let stamp = settings.timestampMode
        var targets: [(frame: CollectedFrame, url: URL)] = []
        for i in picks where i >= 0 && i < frames.count {
            jpegSerial += 1
            targets.append((frames[i], files.jpegURL(page: page, serial: jpegSerial)))
        }
        guard !targets.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) {
            var out: [URL] = []
            for target in targets {
                guard let render = Enhancer.renderCrop(buffer: target.frame.buffer, crop: CGRect(x: 0, y: 0, width: 1, height: 1),
                                                       orientation: orientation, timestamp: stamp, quality: quality, sharpen: sharpen),
                      (try? render.data.write(to: target.url, options: .atomic)) != nil else { continue }
                out.append(target.url)
            }
            return out
        }.value
    }

    // MARK: - Tarama sonu

    /// Tarama bitince: çekim ve kamera kapanır, sonuç sesle bildirilir
    func finishScan(reason: ScanRules.EndReason) async {
        stopCapturing()
        stopCamera()
        pageCount = pages.count
        let text: String
        switch reason {
        case .complete: text = "Tarama tamamlandı."
        case .timeLimit: text = "Tarama süresi doldu."
        case .noMorePages: text = "Tarama bitti."
        case .readyTimeout: text = "Evrak gösterilmedi. Tarama durduruldu."
        case .cameraLost: text = "Kamera bağlantısı kurulamadı. Tarama durdu."
        }
        setStatus(statusAfterCapture())
        if pages.isEmpty {
            say(text)
        } else {
            say("\(text) \(TurkishNumbers.capitalised(TurkishNumbers.cardinal(pages.count))) sayfa alındı.")
        }
        await voice.waitUntilIdle()
    }
}
