import Foundation
import UIKit
import CoreVideo

/// Bir çekimin sonucu
struct CaptureResult {
    /// Yeni soru alındı, bir soruya başlandı ya da bir soru vazgeçildi (ilerleme sayılır)
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
        if ledger.acceptedNumbers.isEmpty {
            setStatus("Taranan soru yok")
            say("Hiç soru alınamadı. Gönderilecek bir şey yok.")
            await voice.waitUntilIdle()
        } else if online {
            await answerAndRead()
        } else {
            addNote("internet", "İnternete ulaşılamadı. Sorular belge klasöründe (\(runName)); cevaplar alınamadı.")
            say("İnternete ulaşılamadı. Sorular klasörde duruyor.")
            await voice.waitUntilIdle()
        }
        if Task.isCancelled { endCancelled(); return }
        endRun(success: true)
    }

    /// Bir taramanın başında durum sıfırlanır; ön koşullar denetlenir
    func prepareRun() {
        ledger = ScanLedger(total: settings.questionTotal, optionCount: settings.optionCount, maxAttempts: settings.maxAttempts)
        runName = RunName.make()
        ScanFiles.removeAll()
        files = ScanFiles(runName: runName)
        latestSample = nil
        lastDocAt = nil
        repeatGate.reset()
        jpegSerial = 0
        videoCount = 0
        notes = []
        acceptedNumbers = []
        waitingQuestions = []
        answers = []
        lastSaid = ""
        UIApplication.shared.isIdleTimerDisabled = true
        phase = .startingCamera
        updatePowerSaving()
        configureVoice()
        if !folderReady {
            addNote("klasor", "Belge klasörü seçilmemiş: sorular ve videolar kaydedilemez. Ayarlar > Dosya bölümünden seçin.")
        }
        if settings.activeGeminiProfile.key.trimmed.isEmpty {
            addNote("gemini", "Gemini API anahtarı girilmemiş: cevaplar alınamaz. Ayarlar > Gemini bölümüne yazın.")
        }
        if !voice.headphonesReady {
            addNote("kulaklik", "Kulaklık bağlı değil: sesli uyarılar verilmiyor (telefon hoparlöründen hiç konuşulmaz). Kulaklığı bağlayın.")
        }
    }

    /// Açılışta söylenen: kaç soru taranacak
    func announceStart() {
        let total = ledger.total
        if total > 0 {
            say("\(TurkishNumbers.capitalised(TurkishNumbers.cardinal(total))) soru taranacak.")
        } else {
            addNote("toplam", "Soru sayısı girilmemiş (Ayarlar > Tarama). Tarama boş kadraja ve süreye göre bitecek.")
            say("Soru sayısı girilmemiş.")
        }
    }

    func endCancelled() {
        stopCapturing()
        stopCamera()
        voice.stop()
        guidanceActive = false
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

    func qualityConfig() -> QualityConfig {
        return QualityConfig(sharpFloor: QualityConfig.floor(forSharpness: settings.guidanceSharpness))
    }

    /// Kamera açıkken: evrak bekler, görünce 2 sn sonra çeker, sonucu işler; bitiş kuralları dolunca nedenini verir
    func scanLoop() async -> ScanRules.EndReason {
        phase = .waitingForPage
        setStatus("Evrak bekleniyor")
        configureGuidance()
        guidanceActive = true
        defer { guidanceActive = false }
        let start = now()
        var docSince: TimeInterval?
        var emptySince: TimeInterval? = start
        var lastWindowEnd: TimeInterval?
        var lastProgress = start
        var lastReady: TimeInterval?
        var captures = 0
        var asked = false
        var deadline = 0.0
        var lastMissingPrompt = 0.0
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
                guidanceActive = false
                say("Kamera görüntüsü kesildi. Yeniden bağlanılıyor.")
                let ok = await bringUpCamera()
                phase = captures == 0 ? .waitingForPage : .scanning
                guidanceActive = true
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
            let verdict = ScanRules.verdict(total: ledger.total, accepted: ledger.acceptedNumbers.count, complete: ledger.isComplete,
                                            elapsed: t - start, maxSeconds: Double(settings.scanMaxMinutes) * 60,
                                            emptyFor: emptyFor, sinceProgress: t - lastProgress,
                                            asked: asked, deadlinePassed: asked && t >= deadline)
            switch verdict {
            case .finish(let reason):
                return reason
            case .askMissing:
                asked = true
                deadline = t + Double(settings.missingWaitSeconds)
                lastMissingPrompt = t
                say(ScanRules.missingText(ledger.missing))
                continue
            case .keepGoing:
                break
            }
            if asked && t - lastMissingPrompt >= ScanRules.missingRepeatSeconds {
                lastMissingPrompt = t
                say(ScanRules.missingText(ledger.missing))
            }
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
            // Belge sabit görünüyor: 2 sn sonra çekim
            if doc, let since = docSince, t - since >= ScanRules.settleSeconds, let s = latestSample, t - s.arrived < 2,
               ScanRules.canRearm(firstCapture: captures == 0, diffToCapture: s.diffToCapture, stillFor: s.stillFor,
                                  sinceLastWindow: lastWindowEnd.map { t - $0 } ?? Double.infinity) {
                phase = .scanning
                let result = await captureAndProcess()
                captures += 1
                let end = now()
                lastWindowEnd = end
                docSince = nil
                if result.progressed {
                    lastProgress = end
                    if asked { deadline = end + Double(settings.missingWaitSeconds) }
                }
                pipeline.markCaptured()
                phase = .scanning
                setStatus(statusAfterCapture())
            }
        }
        return .cameraLost
    }

    func statusAfterCapture() -> String {
        if ledger.total > 0 { return "Alınan: \(ledger.acceptedNumbers.count)/\(ledger.total)" }
        return "Alınan: \(ledger.acceptedNumbers.count)"
    }

    // MARK: - Çekim

    /// 5 sn kare toplar ve video kaydeder (yönlendirme sürer), sonra kareleri okuyup işler
    func captureAndProcess() async -> CaptureResult {
        videoCount += 1
        let videoURL = files?.videoURL(index: videoCount)
        collector.begin()
        if let url = videoURL {
            recorder.start(to: url, orientation: settings.imageOrientation, maxSeconds: ScanRules.windowSeconds + 0.5)
        }
        setStatus("Çekiliyor: kamerayı sabit tutun")
        await pause(ScanRules.windowSeconds)
        if Task.isCancelled {
            collector.cancel()
            recorder.cancel()
            return CaptureResult()
        }
        let frames = collector.end()
        await finishVideo(videoURL)
        guidanceActive = false
        setStatus("Sayfa okunuyor…")
        let result = await processCapture(frames)
        guidance.resetVideo()
        guidanceActive = true
        return result
    }

    private func finishVideo(_ url: URL?) async {
        guard url != nil else { return }
        let result: Result<VideoRecorder.Output, VideoRecorder.Failure> = await withCheckedContinuation { continuation in
            recorder.finish { continuation.resume(returning: $0) }
        }
        switch result {
        case .success(let output):
            do {
                try DocumentFolder.shared.store(file: output.url, subfolder: runName, name: String(format: "V%02d.mp4", videoCount))
            } catch {
                addNote("klasor", "Belge klasörüne yazılamadı: \(error.localizedDescription)")
            }
        case .failure:
            tlog("[video] bu çekimin videosu alınamadı")
        }
    }

    /// Karelerdeki soruları bulur, kalite kapısından geçirir, kabul edilenleri PDF yapar, sonucu sesle bildirir
    func processCapture(_ frames: [CollectedFrame]) async -> CaptureResult {
        var result = CaptureResult()
        guard !frames.isEmpty else {
            say("Görüntü alınamadı. Kamerayı kontrol edin.")
            return result
        }
        let orientation = settings.imageOrientation
        let config = qualityConfig()
        let total = ledger.total
        let options = ledger.optionCount
        let analysis: CaptureAnalysis = await Task.detached(priority: .userInitiated) {
            var analyzed: [AnalyzedFrame] = []
            for (i, f) in frames.enumerated() {
                let lines = VisionOCR.recognize(f.buffer, orientation: orientation)
                let metrics = GuidanceAnalyzer.analyze(f.buffer, orientation: orientation)
                analyzed.append(AnalyzedFrame(index: i, lines: lines, sharp: metrics?.sharp ?? 0, glare: metrics?.glare ?? 0))
            }
            return CaptureAnalyzer.analyze(analyzed, total: total, optionCount: options, config: config)
        }.value
        if Task.isCancelled { return result }
        let actions = ScanPlanner.plan(analysis, ledger: ledger)
        var accepted: [Int] = []
        var opened: Int?
        var stashed: [Int] = []
        var rejects: [(number: Int, problem: ShotProblem)] = []
        var limited: [Int] = []
        var duplicates = 0
        var general: [ShotProblem]?
        for action in actions {
            switch action {
            case .accept(let n, let picks, let continuing):
                if let urls = await renderPages(picks: picks, frames: frames, question: n) {
                    ledger.accept(number: n, pages: urls, continuing: continuing)
                    savePDF(for: n)
                    accepted.append(n)
                } else {
                    rejects.append((n, .unreadable))
                    if ledger.noteReject(number: n) { limited.append(n) }
                }
            case .startOpen(let n, let picks):
                if let urls = await renderPages(picks: picks, frames: frames, question: n) {
                    ledger.startOpen(number: n, pages: urls)
                    opened = n
                } else {
                    rejects.append((n, .unreadable))
                    if ledger.noteReject(number: n) { limited.append(n) }
                }
            case .extendOpen(let n, let picks):
                if let urls = await renderPages(picks: picks, frames: frames, question: n) {
                    ledger.extendOpen(number: n, pages: urls)
                    opened = n
                }
            case .stashTail(let n, let picks):
                if let urls = await renderPages(picks: picks, frames: frames, question: n) {
                    ledger.stashTail(number: n, pages: urls)
                    stashed.append(n)
                }
            case .reject(let n, let problems):
                if let top = problems.min(by: { $0.priority < $1.priority }) {
                    rejects.append((n, top))
                } else {
                    rejects.append((n, .unreadable))
                }
                if ledger.noteReject(number: n) { limited.append(n) }
            case .duplicate:
                ledger.noteDuplicate()
                duplicates += 1
            case .unidentified(let problems):
                general = problems
            }
        }
        refreshLedgerState()
        result.progressed = !accepted.isEmpty || opened != nil || !stashed.isEmpty || !limited.isEmpty
        speakCapture(accepted: accepted.sorted(), opened: opened, stashed: stashed.sorted(), limited: limited, rejects: rejects,
                     duplicates: duplicates, general: general)
        return result
    }

    /// Çekim sonucunu tek konuşmada bildirir: alınanlar, devam isteği, en önemli tek uyarı
    private func speakCapture(accepted: [Int], opened: Int?, stashed: [Int], limited: [Int], rejects: [(number: Int, problem: ShotProblem)],
                              duplicates: Int, general: [ShotProblem]?) {
        var parts: [String] = []
        if !accepted.isEmpty { parts.append(ScanRules.acceptedText(accepted)) }
        if let n = opened { parts.append(ScanRules.continueText(n)) }
        for n in stashed { parts.append(ScanRules.headText(n)) }
        for n in limited {
            parts.append("\(TurkishNumbers.capitalised(TurkishNumbers.ordinal(n))) soru okunamadı, bu soru atlanıyor.")
        }
        let t = now()
        let pending = rejects.filter { r in !limited.contains(r.number) }
        if let top = pending.min(by: { $0.problem.priority < $1.problem.priority }) {
            let text = QualityGate.spoken([top.problem], number: top.number)
            if repeatGate.allow(text, now: t) { parts.append(text) }
        } else if accepted.isEmpty && opened == nil && stashed.isEmpty && limited.isEmpty {
            if let general = general {
                let text = general == [.unreadable]
                    ? "Soru bulunamadı. Evrakı kadraja alıp sabit tutun."
                    : QualityGate.spoken(general, number: 0)
                if repeatGate.allow(text, now: t) { parts.append(text) }
            } else if duplicates > 0 {
                let text = "Bu sayfa zaten alındı. Sonraki sayfaya geçin."
                if repeatGate.allow(text, now: t, gap: 15) { parts.append(text) }
            }
        }
        if !parts.isEmpty { say(parts.joined(separator: " ")) }
    }

    /// Seçilen karelerden soru bölgesini kırpıp JPEG dosyalarına yazar (arka planda); hiçbiri yazılamazsa nil
    func renderPages(picks: [ShotCandidate], frames: [CollectedFrame], question: Int) async -> [URL]? {
        guard let files = files else { return nil }
        let orientation = settings.imageOrientation
        let quality = settings.jpegQuality
        let sharpen = settings.sharpenImages
        let stamp = settings.timestampMode
        var targets: [(frame: CollectedFrame, crop: CGRect, url: URL)] = []
        for p in picks where p.frame >= 0 && p.frame < frames.count {
            jpegSerial += 1
            targets.append((frames[p.frame], p.block.cropRect, files.jpegURL(question: question, part: 0, serial: jpegSerial)))
        }
        guard !targets.isEmpty else { return nil }
        let urls: [URL] = await Task.detached(priority: .userInitiated) {
            var out: [URL] = []
            for target in targets {
                guard let render = Enhancer.renderCrop(buffer: target.frame.buffer, crop: target.crop, orientation: orientation,
                                                       timestamp: stamp, quality: quality, sharpen: sharpen),
                      (try? render.data.write(to: target.url, options: .atomic)) != nil else { continue }
                out.append(target.url)
            }
            return out
        }.value
        return urls.isEmpty ? nil : urls
    }

    /// Bir sorunun PDF'ini (S12.pdf) yapar ve belge klasörüne yazar
    @discardableResult
    func savePDF(for number: Int) -> URL? {
        guard let files = files, let pages = ledger.pages[number] else { return nil }
        do {
            let pdf = try files.buildPDF(name: QuestionGroups.pdfName([number]), jpegs: pages)
            do {
                try DocumentFolder.shared.store(file: pdf, subfolder: runName, name: pdf.lastPathComponent)
                removeNote("klasor")
            } catch {
                addNote("klasor", "Belge klasörüne yazılamadı: \(error.localizedDescription)")
            }
            return pdf
        } catch {
            addNote("pdf", "\(number). soru PDF'e çevrilemedi: \(error.localizedDescription)")
            return nil
        }
    }

    /// Ekrandaki alınan / okunamayan soru bilgisini kayıt defterinden yeniler
    func refreshLedgerState() {
        acceptedNumbers = ledger.acceptedNumbers
        waitingQuestions = ledger.waitingNumbers
        let bad = ledger.unreadableNumbers
        if bad.isEmpty {
            removeNote("alinamayan")
        } else {
            addNote("alinamayan", "Alınamayan sorular: " + bad.map { String($0) }.joined(separator: ", "))
        }
    }

    // MARK: - Tarama sonu

    /// Tarama bitince: çekim ve kamera kapanır, eksikler "alınamadı" olur, sonuç sesle bildirilir
    func finishScan(reason: ScanRules.EndReason) async {
        stopCapturing()
        stopCamera()
        guidanceActive = false
        // Hiç soru alınmadıysa eksik listesi anlamsızdır (bütün sorular sayılırdı): yalnız bir şey alındıysa eksikler "alınamadı" olur
        let anyAccepted = !ledger.acceptedNumbers.isEmpty
        if reason != .complete && anyAccepted { ledger.giveUpOnMissing() }
        refreshLedgerState()
        let text: String
        switch reason {
        case .complete: text = "Tarama tamamlandı."
        case .timeLimit: text = "Tarama süresi doldu."
        case .noMoreQuestions: text = "Tarama bitti."
        case .missingGaveUp: text = "Eksik sorular alınamadı. Tarama bitti."
        case .readyTimeout: text = "Evrak gösterilmedi. Tarama durduruldu."
        case .cameraLost: text = "Kamera bağlantısı kurulamadı. Tarama durdu."
        }
        setStatus(statusAfterCapture())
        let bad = ledger.unreadableNumbers
        if bad.isEmpty || !anyAccepted {
            say(text)
        } else {
            say("\(text) Alınamayan sorular: \(TurkishNumbers.spokenList(bad)).")
        }
        await voice.waitUntilIdle()
    }
}
