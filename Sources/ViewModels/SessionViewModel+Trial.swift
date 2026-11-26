import Foundation

/// Kadraj kontrolü, deneme çekimi ve cevaplanamayan soruların notu (kullanıcı kararı 2026-11-17).
///
/// - "Kadraj kontrolü": hazır bekleyen kamerada (Başla'dan ÖNCE) 1,5 sn'lik canlı bir bakış; yazı okunuyor mu, bulanık mı sesle söylenir.
/// - "Deneme çekimi": hazır bekleyen kamerayla bir oturum süresi (varsayılan 75 sn) çekilir; video + PDF + rapor telefondaki `Cekimler/Deneme` klasörüne yazılır,
///   Gemini'ye GİTMEZ, internet gerekmez, soru numarası tüketilmez. Sonuç sesle söylenir; kamera yeniden hazırlanır ve gerçek çekim için "Başla" beklenir.
/// - Cevaplar okunduktan sonra: telefonun karelerde gördüğü ya da cevap numaraları arasında atlanmış soru varsa söylenir (yeniden çekim önerilir).
extension SessionViewModel {
    // MARK: Kadraj kontrolü

    /// Hazır bekleyen kameranın o anki görüntüsüne bakar; söylenecek cümle döner (kamera hazır değilse nedeni)
    func viewCheckText() async -> String {
        guard seriesCameraReady, deps.camera.holdingLive, !cameraBusy else {
            tlog("[kamera] kadraj kontrolü istendi ama kamera hazır bekleyen durumda değil")
            return CaptureSay.viewNotReady
        }
        guard let check = await deps.camera.checkView() else { return CaptureSay.viewNotReady }
        tlog("[kamera] kadraj kontrolü: \(check.frames) kare, netlik \(Int(check.sharpness.rounded())), \(check.text.map { $0.summary } ?? "yazı tanıma yok") → \(check.spoken)")
        return check.spoken
    }

    // MARK: Deneme çekimi (sesle)

    /// "Deneme çekimi" denince: yalnız hazır bekleyen kamerayla (talimat sorulurken) çalışır; değilse nedeni söylenir ve dinlemeye dönülür
    func performTrial(mode: ListenMode) {
        closeListening()
        attemptFails = 0
        clearWarning("duyulan")
        accumulator.clear()
        englishAccumulator.clear()
        liveText = ""
        liveEnglish = ""
        deps.recorder.reset()
        phase = .speaking
        work = Task { [weak self] in
            guard let self = self else { return }
            await self.runTrial(mode: mode)
        }
    }

    func runTrial(mode: ListenMode) async {
        guard mode == .cameraChoice, seriesCameraReady, deps.camera.holdingLive, !cameraBusy else {
            tlog("[komut] deneme çekimi istendi ama kamera hazır bekleyen durumda değil")
            guard await speakNotice(CaptureSay.trialNotReady) else { return }
            beginListening(mode: mode)
            return
        }
        cameraBusy = true
        defer { cameraBusy = false }
        let seconds = cameraSettings.seriesSeconds
        tlog("[kamera] deneme çekimi: \(seconds) sn, sesli komutla başlatıldı")
        guard await speakNotice(CaptureSay.trialIntro(seconds: seconds)) else {
            offerCamera = true
            return
        }
        phase = .answering
        statusNote = "Deneme çekimi sürüyor"
        let camera = deps.camera
        camera.onStatus = { [weak self] text in self?.statusNote = text }
        attachCoach(to: camera)
        let result = await withTaskCancellationHandler {
            await camera.captureTrial(seconds: seconds, connectLimit: Timing.cameraStartFirstConnect)
        } onCancel: {
            Task { @MainActor in camera.cancel() }
        }
        camera.onStatus = nil
        await detachCoach(from: camera)
        statusNote = ""
        guard !Task.isCancelled, phase == .answering else {
            // Kesinti (kulaklık, arama): deneme çekimi yarım kalır ama alınan kareler klasöre yazılır; kamera onarımdan sonra yeniden hazırlanır
            if case .success(let series) = result { deps.captureStore.keepTrial(series.shot, report: series.report) }
            offerCamera = true
            return
        }
        guard !Task.isCancelled, phase == .answering else {
            offerCamera = true
            return
        }
        var text = CaptureSay.trialFailed
        switch result {
        case .success(let series):
            let folder = deps.captureStore.keepTrial(series.shot, report: series.report)
            tlog("[kamera] deneme çekimi bitti: \(series.shot.pageCount) fotoğraflık PDF, klasör \(folder?.lastPathComponent ?? "yazılamadı"); rapor: \(series.report.replacingOccurrences(of: "\n", with: " | "))")
            if folder != nil { text = CaptureSay.trialDone(series.diagnosis?.spoken ?? "") }
        case .failure(let failure):
            tlog("[kamera] deneme çekimi olmadı: \(failure.message)")
            text = CaptureSay.trialFailed + " " + failure.message
        }
        guard await speakNotice(text) else {
            offerCamera = true
            return
        }
        // Kamera çekim bitince kapandı: gerçek çekim için yeniden hazırlanır ve talimat sorulur (internet bilerek kapalı kalır)
        deps.camera.closeHeld()
        await askCameraChoice(relink: true)
    }

    // MARK: Cevaplanamayan sorular

    /// Sayfanın cevapları okunduktan sonra söylenecek not: yalnız cevaplanan iki numaranın arasında atlanan sorular (bkz. `CaptureDiagnosis.missingAnswers`).
    /// `completeReadPage` sayfayı sıfırlamadan ÖNCE çağrılır. Söylenecek bir şey yoksa boş.
    func pageMissingNote() -> String {
        guard let page = pageBeingRead else { return "" }
        let incomplete = pageIncompleteNote(page)
        if autoMode {
            // Otomatik zamanlı başlatma (kullanıcı kararı 2026-11-26): atlanan sorular için "yeniden tarayın" denmez; eksikler sıradaki tarama duyurusunda
            // yalnız hatırlatılır (`autoGapSentence`). Burada, önceden eksik olup bu taramada cevabı gelen sorular bildirilir
            let skipped = CaptureDiagnosis.missingAnswers(answered: pageReplyNumbers)
            if !skipped.isEmpty {
                tlog("[sayfa] cevaplanmayan sorular: \(skipped.map { String($0) }.joined(separator: ",")) (cevaplananlar: \(pageReplyNumbers.map { String($0) }.joined(separator: ",")))")
            }
            let done = autoCompletedNote()
            return [done, incomplete].filter { !$0.isEmpty }.joined(separator: " ")
        }
        let missing = CaptureDiagnosis.missingAnswers(answered: pageReplyNumbers)
        guard !missing.isEmpty else { return incomplete }
        tlog("[sayfa] cevaplanmayan sorular: \(missing.map { String($0) }.joined(separator: ",")) (cevaplananlar: \(pageReplyNumbers.map { String($0) }.joined(separator: ",")); karelerde görülenler: \(page.seenNumbers.map { String($0) }.joined(separator: ",")))")
        let skipped = missing.count <= CaptureDiagnosis.maxListed ? CaptureSay.missingAnswers(missing) : CaptureSay.manyMissingAnswers
        return incomplete.isEmpty ? skipped : skipped + " " + incomplete
    }

    /// Cevabı okunan ama taramada tam görülmeyen sorular için not (bkz. `QuestionCoverage`, `CaptureDiagnosis.incompleteAnswers`); yoksa boş
    func pageIncompleteNote(_ page: CapturedQuestion) -> String {
        if page.incompleteNumbers.isEmpty { return "" }
        let spoken = CaptureDiagnosis.incompleteAnswers(incomplete: page.incompleteNumbers, answered: pageReplyNumbers)
        tlog("[sayfa] taramada tam görülmeyen sorular: \(page.incompleteNumbers.map { String($0) }.joined(separator: ",")); cevabı okunanlardan söylenecek: \(spoken.isEmpty ? "yok" : spoken.map { String($0) }.joined(separator: ","))")
        return spoken.isEmpty ? "" : CaptureSay.incompleteAnswers(spoken)
    }
}
