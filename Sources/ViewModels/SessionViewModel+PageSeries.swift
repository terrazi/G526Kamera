import Foundation

/// Toplu çekim (kullanıcı kararı 2026-11-16): "evet" denince TEK soru değil bir OTURUM çekilir. Tek sınır süredir (varsayılan 75 sn); sayfa sayısı yoktur,
/// sayfalar eşit sürede gösterilmez: süre içinde ne kadar sayfa gösterilirse hepsi tek PDF olur.
///
/// Akış: (0) kamera önceden hazırdır (bkz. `SessionViewModel+SeriesReady`): telefon kameranın Wi-Fi'sinde, hücresel kapalı, kamera bağlı, kullanıcı "Başla"yı bekler;
/// "Başla" denince "Başladı." söylenir ve süre HEMEN başlar. Kamera hazır değilse eski düzen: (1) oturum bir kez duyurulur ("75 saniye… kulaklık kapanacak");
/// (2) Kestirme hücreseli, mikrofonu ve kulaklığı kapatır, telefon kameranın Wi-Fi'sine geçer; (3) kamera hiç konuşmadan aralıksız çeker, saniyede bir fotoğraf (ses de titreşim de YOK; sayfaları kullanıcı kendi hızında
/// gösterir); (4) kamera kapanır, internet ve kulaklık geri gelir (kulaklık gelene kadar ses yolu değişikliği duraklatma sayılmaz); (5) bütün oturumun
/// fotoğrafları TEK PDF'tir: telefondaki klasöre "bekliyor" olarak yazılır, tek istekle gönderilir ve PDF'teki BÜTÜN soruların cevabı numara sırasıyla,
/// her cevap arasında `Timing.answerGap` sn boşlukla okunur; (6) sonra yeni oturum sorulur. Cevaplar duyulana kadar PDF silinmez.
extension SessionViewModel {
    // MARK: Kamera sorusunun cümleleri

    /// "Kamera ile çekmek ister misiniz?" sorusu: toplu çekim açıksa oturum sorusu
    func cameraAskText(again: Bool) -> String {
        guard cameraSettings.pageSeries else {
            if settings.examType == .camera { return again ? Say.askCameraOnlyAgain : Say.askCameraOnly }   // görüntülü sınav: "evet / hayır" sorulmaz
            return again ? Say.askCameraAgain : Say.askCamera
        }
        let seconds = cameraSettings.seriesSeconds
        return again ? Say.askCameraSeriesAgain(seconds: seconds) : Say.askCameraSeries(seconds: seconds)
    }

    /// Cevapsız kalınca yeniden sorma ("Cevap vermediniz…") ya da anlaşılmayınca ("Anlayamadım…")
    func cameraAskReminder(unclear: Bool, attempt: Int) -> String {
        guard cameraSettings.pageSeries else {
            if settings.examType == .camera { return unclear ? Say.reask(Say.askCameraOnlyAgain, attempt: attempt) : Say.askCameraOnlyRepeat(attempt) }
            return unclear ? Say.reask(Say.askCameraAgain, attempt: attempt) : Say.askCameraRepeat(attempt)
        }
        let seconds = cameraSettings.seriesSeconds
        return unclear ? Say.reask(Say.askCameraSeriesAgain(seconds: seconds), attempt: attempt)
                       : Say.askCameraSeriesRepeat(attempt, seconds: seconds)
    }

    /// Onarımdan sonra evet / hayır yeniden sorulurken
    var cameraAskAfterRecovery: String {
        guard cameraSettings.pageSeries else { return settings.examType == .camera ? Say.askCameraOnlyAfterRecovery : Say.askCameraAfterRecovery }
        return Say.askCameraSeriesAfterRecovery(seconds: cameraSettings.seriesSeconds)
    }

    /// Kamera "evet" denince: toplu çekim açıksa oturum başlar, değilse eski düzen (soru mu paragraf mı, tek çekim)
    func startCameraSession() async {
        if cameraSettings.pageSeries {
            await runPageSeries()
        } else {
            await askCaptureKind()
        }
    }

    // MARK: Oturum

    func runPageSeries() async {
        guard !cameraBusy else {
            tlog("[kamera] önceki çekim sürüyor; yeni oturum başlatılmadı")
            return
        }
        cameraBusy = true
        defer { cameraBusy = false }
        let seconds = cameraSettings.seriesSeconds
        let cameraName = cameraSettings.cameraShortcutName.trimmed
        let internetName = settings.internetShortcut.trimmed
        tlog("[kamera] toplu çekim: \(seconds) sn, kestirme “\(cameraName)”, internet kestirmesi “\(internetName)”")
        guard cameraConfigured else {
            await fallBackToVoice(Say.cameraShortcutsMissing)
            return
        }
        // Kamera hazır bekliyorsa (bağlı, görüntü akıyor) süre HEMEN başlar: "Başladı." denir, cümle bitince çekim sürer. Hazır değilse (bağlantı kopmuş)
        // eski düzen: duyuru kestirmeden ÖNCE söylenir (kestirme kulaklığı kapatabilir) ve oturum boyunca hiçbir şey söylenmez
        let ready = deps.camera.holding
        guard await speakNotice(ready ? Say.seriesGo : Say.seriesStarting(seconds: seconds)) else {
            tlog("[kamera] oturum duyurusu kesildi; kestirme çalıştırılmadı, onarımdan sonra yeniden sorulacak")
            offerCamera = true
            return
        }
        let attemptStart = deps.now()
        phase = .answering
        networkMayBeOnCamera = true
        statusNote = ready ? "Toplu çekim sürüyor" : "Toplu çekim: kameraya geçiliyor (hücresel, mikrofon ve kulaklık kapanıyor)"
        // Kestirme çalışırsa kulaklık düşebilir: ses yolu değişikliği donanım duraklatması sayılmaz
        let headsetWasThere = routeVerdict?.isSafe ?? true
        connectionResetActive = true
        defer { connectionResetActive = false }
        deps.camera.subject = .question
        let operation: (CameraCapturing, TimeInterval?) async -> Result<PageSeries, CameraFailure> = { camera, limit in
            await camera.captureSeries(seconds: seconds, connectLimit: limit)
        }
        let interrupted: (PageSeries) -> Void = { [weak self] series in self?.saveInterruptedSeries(series) }
        var result: Result<PageSeries, CameraFailure>
        if ready {
            // Hazır bekleyen bağlantı canlıysa hemen çekilir (kestirme çalışmaz, yeniden bağlanılmaz). Görüntü bir an kesilmişse (kayıp, anahtar kare bekleniyor)
            // `captureSeries` aynı Wi-Fi'de bağlantıyı yeniden kurar (≈ 2–3 sn); süre görüntü gelince başlar
            let camera = deps.camera
            camera.onStatus = { [weak self] text in self?.statusNote = text }
            result = await withTaskCancellationHandler {
                await operation(camera, Timing.cameraStartFirstConnect)
            } onCancel: {
                Task { @MainActor in camera.cancel() }
            }
            camera.onStatus = nil
            if case .failure(let failure) = result, failure == .notConnected || failure == .noFrames, !Task.isCancelled, phase == .answering {
                // Bekleyen bağlantı kopmuştu ve aynı Wi-Fi'de yeni bağlantı da kurulamadı: süre HİÇ başlamadı. Onarım döngüsünde süre sessizce başlatılmaz
                // (kullanıcı ne zaman başladığını bilemez, boşuna sayfa gösterir); kamera baştan hazırlanır ve "Başla" yeniden beklenir
                tlog("[kamera] hazır bekleyen bağlantıyla çekilemedi (\(failure.message)); süre başlamadı, kamera yeniden hazırlanıp \"Başla\" yeniden beklenecek")
                deps.camera.closeHeld()
                statusNote = ""
                guard await speakNotice(Say.seriesLinkLost) else { offerCamera = true; return }
                await askCameraChoice(relink: true)
                return
            } else if Task.isCancelled, case .success(let series) = result {
                interrupted(series)   // tam kesinti anında bitti: klasöre yazılır
                result = .failure(.cancelled)
            }
        } else {
            result = await repairLoop(cameraName: cameraName, speaks: false, operation: operation, interrupted: interrupted)
        }
        // Alınan sayfalar telefondaki klasöre yazılır: internete dönüş sürerken kesinti olsa da kaybolmaz
        if case .success(let series) = result {
            let kept = deps.captureStore.keep(shapedShot(series.shot, isPassage: false), kind: .page)
            keepPending(kept)
            result = .success(PageSeries(shot: kept, planned: series.planned, failure: series.failure, readable: series.readable,
                                         diagnosis: series.diagnosis, report: series.report))
        }
        var cameraGaveUp = false
        if case .failure(let failure) = result, failure == .notConnected || failure == .noFrames, !Task.isCancelled, phase == .answering {
            cameraGaveUp = true
            markCameraDown(since: attemptStart)
        }
        guard !Task.isCancelled, phase == .answering else {
            if pendingShots.isEmpty { offerCamera = true }
            return
        }
        statusNote = internetNote
        let online = await returnToInternet(shortcut: internetName)
        if online { networkMayBeOnCamera = false }
        // Kulaklık (Bluetooth) kestirmeyle geri gelir: gelene kadar beklenir; sorun olursa donanım duraklatması devreye girer
        var waited = 0.0
        while headsetWasThere, !Task.isCancelled, !(routeVerdict?.isSafe ?? true), waited < Timing.seriesHeadsetWait {
            await Task.yield()
            await deps.sleep(0.5)
            waited += 0.5
        }
        tlog("[kamera] oturum sonu: internet \(online ? "geldi" : "gelmedi"), kulaklık \((routeVerdict?.isSafe ?? true) ? "yerinde" : "dönmedi") (\(Int(waited)) sn beklendi)")
        connectionResetActive = false
        guard !Task.isCancelled, phase == .answering else {
            if pendingShots.isEmpty { offerCamera = true }
            return
        }
        switch result {
        case .failure(let failure):
            tlog("[kamera] toplu çekim olmadı: \(failure.message)")
            clearWarning("kamera")
            if online {
                await fallBackToVoice(Say.cameraFailed(failure, down: cameraGaveUp, minutes: settings.cameraCheckMinutes))
            } else if offlineCapture {
                await continueOffline(Say.cameraFailedOfflineContinue(failure))
            } else {
                await repairInternetAfterCamera(Say.cameraFailedOffline(failure))
            }
        case .success(let series):
            rememberShot(series.shot)
            let taken = series.shot.pageCount
            tlog("[kamera] toplu çekim bitti: \(taken)/\(series.planned) fotoğraflık PDF\(series.failure.map { "; kesilme nedeni: \($0.message)" } ?? ""); internet \(online ? "geldi" : "gelmedi")")
            if online {
                clearWarning("kamera")
                // Çekimin teşhisi (bulanık, çok yakın, yazı yok, görünmeyen numaralar) aynı cümlede söylenir: kullanıcı bir sonraki çekimi buna göre düzeltir
                let advice = series.diagnosis?.spoken ?? ""
                let done = Say.seriesDone(taken: taken, planned: series.planned, readable: series.readable) + (advice.isEmpty ? "" : " " + advice)
                guard await speakNotice(done) else { return }   // kesildi: PDF bekliyor, onarımdan sonra gönderilir
                // PDF bekleyenlerdedir: dinleme açılırken gönderilir (bkz. `beginListening`, `sendPendingShots`); cevaplar okunur, bitince yeni oturum sorulur
                armCameraOffer()
                beginListening()
            } else if offlineCapture {
                tlog("[kamera] çevrimdışı çekim kipi: \(taken) fotoğraflık PDF telefonda bekliyor")
                await continueOffline(Say.seriesSavedOffline)
            } else {
                warn("kamera", "Çekilen PDF telefonda bekliyor: internet gelmedi.")
                await repairInternetAfterCamera(Say.seriesSavedOffline)
            }
        }
    }

    /// Oturum tam kesinti anında (kulaklık, arama, onarım) bitti: PDF klasöre yazılır ve onarımdan sonra gönderilir
    func saveInterruptedSeries(_ series: PageSeries) {
        let shot = deps.captureStore.keep(shapedShot(series.shot, isPassage: false), kind: .page)
        guard shot.archived else {
            shot.discard()
            return
        }
        keepPending(shot)
        tlog("[kamera] kesinti anında biten oturumun \(series.shot.pageCount) fotoğraflık PDF'i klasöre yazıldı; onarımdan sonra gönderilecek")
    }

    // MARK: Sayfanın cevapları

    /// PDF'in sıradaki cevabı okunur (ilki `answer` ile okundu): "sonraki soruyu okuyun" denmeden, kendi numarasıyla
    func readNextQueuedReply() async {
        guard !queuedReplies.isEmpty else { return }
        let next = queuedReplies.removeFirst()
        // Cevaplar art arda okunurken aşama hep "konuşma"dır (araya giren "cevap hazırlanıyor" gözcünün nabzına denk gelmez); sayaç sıfırlanmazsa
        // 75 cevaplık PDF'in okunması 180 sn'yi aşınca gözcü "takıldı" sanıp oturumu yeniden kurar ve cevaplar baştan okunurdu. Her cevap kendi süresini alır.
        watchedTicks = 0
        phase = .answering
        beginEntry(text: Say.cameraEntryText, withAudio: false, number: next.number)
        await answer(question: Say.cameraEntryText, audio: nil, spokenNumber: nil, fetch: { next })
    }

    /// Sayfanın bütün cevapları duyuldu: sayfa bekleyenlerden çıkar, klasörde "Gönderilen"e taşınır (cevaplar yanına yazılır)
    func completeReadPage() {
        guard let page = pageBeingRead else { return }
        pageBeingRead = nil
        queuedReplies = []
        completePending(page, answer: pageSpokenAll.joined(separator: "\n"))
        pageSpokenAll = []
        pageReplyNumbers = []
    }

    /// Gemini sayfada soru bulamadı: satır listeden çıkar (numara tüketilmez), kullanıcıya söylenir, sıradaki sayfaya / dinlemeye geçilir
    func finishEmptyPage() async {
        if let id = currentEntry, let index = questions.firstIndex(where: { $0.id == id }) { questions.remove(at: index) }
        currentEntry = nil
        deps.journal.savePending(nil)
        tlog("[sayfa] sayfada soru bulunamadı")
        completeReadPage()
        phase = .speaking
        guard await speakNotice(Say.pageNoQuestion) else { return }
        guard !Task.isCancelled, phase == .speaking else { return }
        guard await promptNextQuestion() else { return }
        beginListening()
    }
}
