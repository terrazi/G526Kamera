import Foundation

/// Sürüm 4: her soru için "kamera ile çekip göndermek ister misiniz?" akışı.
///
/// Evet denince sırayla: (1) Kestirme: hücresel kesilir, telefon kameranın Wi-Fi ağına bağlanır; (2) kamera açılır, program sayfayı sesle
/// konumlandırır, soruyu videoya ve fotoğrafa alır ve kamerayı kapatır; (3) Kestirme: Wi-Fi bırakılır, hücresel açılır, internet gelene
/// kadar beklenir; (4) fotoğraf + video Gemini'ye gider, cevap okunur ve kaydedilir (V3'ün cevap akışı aynen); (5) sıradaki soru için yine sorulur.
/// Hayır denince V3 gibi: kullanıcı soruyu okur, "Cevapla" der. Kamera akışı herhangi bir adımda başarısız olursa program nedenini söyler
/// ve soruyu sesle okumaya döner; kullanıcı hiçbir adımda sessizlikte bırakılmaz.
extension SessionViewModel {
    // MARK: Hazır mı

    /// Kamera sorusu sorulabilir mi: ayar açık, kamera adı geçerli ve iki kestirme adı yazılı
    var cameraOfferAvailable: Bool {
        guard settings.askCamera else { return false }
        return cameraConfigured
    }

    var cameraConfigured: Bool {
        return CameraUID(cameraSettings.uid) != nil
            && !cameraSettings.cameraShortcutName.trimmed.isEmpty
            && !settings.internetShortcut.trimmed.isEmpty
    }

    // MARK: Evet / hayır

    /// "Bu soruyu kamera ile çekip göndermek ister misiniz?"
    func askCameraChoice(again: Bool = false) async {
        // Telefonda bekleyen çekim varsa önce o gönderilir; gönderim kendi akışıyla (cevap, sıradaki soru) devam eder, burada yeniden sorulmaz
        if !again, resendablePending != nil, await sendPendingShots() { return }
        guard !Task.isCancelled else { return }
        guard await speakNotice(again ? Say.askCameraAgain : Say.askCamera) else { return }
        beginListening(mode: .cameraChoice)
    }

    func fireCameraChoice() {
        guard let reply = interpret(SpokenReply.yesNo) else { return }
        clearWarning("duyulan")
        closeListening()
        listenMode = .question   // seçim yapıldı: bundan sonraki bir onarım "evet / hayır"ı yeniden sormaz, bekleyen çekimi gönderir
        phase = .speaking
        cameraReminders = 0
        work = Task { [weak self] in
            guard let self = self else { return }
            if reply == .yes {
                await self.runCameraCapture()
            } else {
                await self.declineCamera()
            }
        }
    }

    func declineCamera() async {
        guard await speakNotice(Say.cameraDeclined) else { return }
        listenForVoiceQuestion()
    }

    /// Bu soru V3'teki gibi sesle okunur: kamera sorusu atlanır
    func listenForVoiceQuestion() {
        cameraOfferSuppressed = true
        beginListening(mode: .question)
    }

    /// Cevap gelmedi ya da anlaşılmadı: bir kez daha sorulur; yine olmazsa güvenli varsayılan (sesle okuma, ağ değiştirmeden)
    func cameraChoiceSilence() async {
        cameraReminders += 1
        if cameraReminders <= Timing.choiceReminderLimit {
            guard await speakNotice(Say.askCameraAgain) else { return }
            beginListening(mode: .cameraChoice)
        } else {
            cameraReminders = 0
            tlog("[kamera] evet / hayır cevabı gelmedi; sesle okumaya dönüldü")
            guard await speakNotice(Say.cameraDefaultVoice) else { return }
            listenForVoiceQuestion()
        }
    }

    // MARK: Çekim akışı

    func runCameraCapture() async {
        guard !cameraBusy else { return }
        cameraBusy = true
        defer { cameraBusy = false }
        let cameraName = cameraSettings.cameraShortcutName.trimmed
        let internetName = settings.internetShortcut.trimmed
        guard cameraConfigured else {
            await fallBackToVoice(Say.cameraShortcutsMissing)
            return
        }
        guard await speakNotice(Say.cameraConnecting) else {
            offerCamera = true   // kesildi (kulaklık, arama, onarım): onarımdan sonra kamera sorusu yeniden sorulur
            return
        }
        phase = .answering
        statusNote = "Kameraya geçiliyor (hücresel kesiliyor)"
        tlog("[kamera] hücresel kesilip kameranın Wi-Fi ağına geçiliyor: kestirme “\(cameraName)”")
        var result = await captureWithRepair(cameraName: cameraName)
        // Çekim telefonda saklanır: internete dönüş sürerken kesinti olsa ya da gönderim başarısız olsa da kaybolmaz
        if case .success(var shot) = result {
            shot.extraInstruction = cameraSettings.videoQuestion.trimmed
            shot.highResolution = cameraSettings.videoHighRes
            if !cameraSettings.videoToGemini {
                shot.discard()
                shot.video = nil
                shot.videoBytes = 0
            }
            result = .success(shot)
            keepPending(shot)
        }
        guard !Task.isCancelled, phase == .answering else {
            offerCamera = true
            return
        }
        if case .success = result { sayGuidance(Say.cameraCaptured) }
        // Kamera kapandı: Wi-Fi bırakılır, hücresel açılır
        statusNote = "İnternete geçiliyor (Wi-Fi bırakılıyor)"
        let online = await returnToInternet(shortcut: internetName)
        await waitForGuidanceSpeech()
        guard !Task.isCancelled, phase == .answering else {
            if pendingShots.isEmpty { offerCamera = true }   // çekim telefonda bekliyorsa önce o gönderilir (bkz. beginListening)
            return
        }
        switch result {
        case .failure(let failure):
            tlog("[kamera] çekim olmadı: \(failure.message)")
            clearWarning("kamera")
            if online {
                await fallBackToVoice(Say.cameraFailed(failure))
            } else {
                await repairInternetAfterCamera(Say.cameraFailedOffline(failure))
            }
        case .success(let shot):
            tlog("[kamera] çekildi: fotoğraf \(shot.photo.count / 1024) KB, video \(shot.video == nil ? "yok" : "\(shot.videoBytes / 1024) KB, \(Int(shot.videoSeconds.rounded())) sn"); internet \(online ? "geldi" : "gelmedi")")
            if online {
                await sendShot(shot)
            } else {
                warn("kamera", "Çekilen soru telefonda bekliyor: internet gelmedi.")
                await repairInternetAfterCamera(Say.cameraSavedOffline)
            }
        }
    }

    /// Çekim bitti, internet geldi: fotoğraf + video Gemini'ye gider, cevap V3'ün akışıyla okunur ve kaydedilir
    func sendShot(_ shot: CapturedQuestion) async {
        phase = .answering
        statusNote = ""
        let expected = nextNumber
        beginEntry(text: Say.cameraEntryText, withAudio: false, number: expected)
        deps.journal.savePending(nil)
        if settings.spokenProgress { speakProgress(Say.cameraSending) }
        startAnswerWait()
        answerWaitElapsed = -Timing.cameraExtraWait   // fotoğraf + video hücresel veriyle yüklenir: V3'ün 180 sn sınırına bu kadar eklenir
        let fetch: () async throws -> GeminiReply = { [weak self] in
            guard let self = self else { throw CancellationError() }
            return try await self.sendWithRetry(shot, expected: expected)
        }
        await answer(question: Say.cameraEntryText, audio: nil, spokenNumber: nil, fetch: fetch)
    }

    /// Ağ hatasında internet kestirmesi yeniden çalıştırılıp bir kez daha denenir; yine olmazsa soru telefonda saklanır
    func sendWithRetry(_ shot: CapturedQuestion, expected: Int) async throws -> GeminiReply {
        var last: GeminiError?
        for attempt in 1...Timing.cameraSendTries {
            do {
                let reply = try await deps.answering.answer(capture: shot, expectedNumber: expected)
                dropPending(shot)
                return reply
            } catch let error as GeminiError {
                last = error
                guard error.kind == .network, attempt < Timing.cameraSendTries, !Task.isCancelled else { break }
                tlog("[kamera] gönderim ağ hatası verdi; internet kestirmesi yeniden çalıştırılıp bir kez daha denenecek")
                _ = await returnToInternet(shortcut: settings.internetShortcut.trimmed)
            }
        }
        let failure = last ?? GeminiError("Gemini cevap vermedi.", .error)
        switch failure.kind {
        case .blocked, .tooBig:
            dropPending(shot)   // aynı çekim yeniden denense de aynı sonucu verir: telefonda tutulmaz
        default:
            warn("kamera", "Çekilen soru telefonda bekliyor (\(failure.kind == .network ? "Gemini'ye ulaşılamadı" : "gönderilemedi")).")
        }
        throw failure
    }

    /// Gönderilmemiş çekimlerden henüz yeniden denenmemiş ilki. Her çekim bir kez kendiliğinden yeniden denenir; yine başarısızsa
    /// bir sonraki başarılı gönderime kadar beklenir (yoksa hata sonsuz "yeniden dene" döngüsüne girerdi).
    var resendablePending: CapturedQuestion? {
        return pendingShots.first { !retriedShots.contains($0.id) }
    }

    /// Önceki çekimden kalan soru (internet gelmediği için gönderilememişti) gönderilir. Gönderim başladıysa true (devamını `answer` yürütür);
    /// internet yoksa ya da konuşma kesildiyse false.
    func sendPendingShots() async -> Bool {
        guard let first = resendablePending else { return false }
        guard await speakNotice(Say.cameraPendingSending) else { return true }   // konuşma kesildi: onarım sonrası yeniden denenir
        guard await waitForInternet(seconds: Timing.cameraInternetWait) else {
            warn("kamera", "Bekleyen çekilen soru gönderilemedi: internet yok.")
            return false
        }
        clearWarning("kamera")
        retriedShots.insert(first.id)
        await sendShot(first)
        if pendingShots.contains(first) {
            // Bekleyen çekimin tek yeniden gönderimi de başarısız oldu: sınav akışı her soruda yeniden denemekle yavaşlamasın, atılır ve söylenir
            dropPending(first)
            retriedShots.remove(first.id)
            warn("kamera", Say.cameraPendingGivenUp)
        }
        return true
    }

    /// Kameraya geçilir ve çekilir. Kameraya bağlanılamazsa (kestirme çalışmadı, kamera yanıt vermedi, görüntü gelmedi) "kamera bağlantısı
    /// onarımı" (Ayarlar'daki Wi-Fi adımı) çalışır ve çekim yeniden denenir; `Timing.cameraRepairs` onarımdan sonra vazgeçilir.
    func captureWithRepair(cameraName: String) async -> Result<CapturedQuestion, CameraFailure> {
        var result: Result<CapturedQuestion, CameraFailure> = .failure(.notConnected)
        for attempt in 0...Timing.cameraRepairs {
            var name = cameraName
            if attempt > 0 {
                let repair = settings.shortcutName(for: .wifi)
                name = repair.isEmpty ? cameraName : repair   // onarım kestirmesi yazılmamışsa kameraya geçiş kestirmesi yeniden çalışır
                statusNote = "Kamera bağlantısı onarılıyor (\(attempt). deneme)"
                tlog("[kamera] bağlantı onarımı \(attempt). deneme: kestirme “\(name)”")
                sayGuidance(Say.cameraRepairing)
            }
            let outcome = await deps.shortcuts.run(name: name)
            guard !Task.isCancelled, phase == .answering else { return .failure(.cancelled) }
            let camera = deps.camera
            // Zaman aşımında kestirme çalışmış ama dönüş haberi gelmemiş olabilir: kameranın kendisi karar verir
            if outcome == .success || outcome == .timedOut {
                deps.camera.onSay = { [weak self] text in self?.sayGuidance(text) }
                deps.camera.onStatus = { [weak self] text in self?.statusNote = text }
                // V3 işi iptal ederse (kulaklık, arama, onarım: `work?.cancel()`) kamera da kapanır; yoksa 70 sn boyunca açık kalırdı
                result = await withTaskCancellationHandler {
                    await camera.capture()
                } onCancel: {
                    Task { @MainActor in camera.cancel() }
                }
                deps.camera.onSay = nil
                deps.camera.onStatus = nil
                await waitForGuidanceSpeech()
            } else {
                tlog("[kamera] kestirme çalışmadı (\(outcome)): kameraya geçilemedi")
                result = .failure(.notConnected)
            }
            guard !Task.isCancelled, phase == .answering else {
                if case .success(let shot) = result { shot.discard() }   // kesilirken çekilmiş olabilir: video dosyası sahipsiz kalmasın
                return .failure(.cancelled)
            }
            if case .failure(let failure) = result, failure == .notConnected || failure == .noFrames { continue }
            break
        }
        return result
    }

    /// Kamera akışından sonra internet iki denemede de gelmedi: durum söylenir ve V3'ün internet onarımı (hücresel → sıfırlama) çalışır.
    /// Düzelince oturum dinlemeye döner; telefonda bekleyen çekim varsa önce o gönderilir (bkz. `beginListening`).
    func repairInternetAfterCamera(_ text: String) async {
        guard await speakNotice(text) else { return }
        await runRecovery(.network, force: true)
    }

    // MARK: Bekleyen çekimler

    /// Çekim gönderilene kadar telefonda tutulur. En çok `Timing.pendingShotLimit`: fazlası en eskisinden silinir (disk dolmasın)
    func keepPending(_ shot: CapturedQuestion) {
        if !pendingShots.contains(shot) { pendingShots.append(shot) }
        while pendingShots.count > Timing.pendingShotLimit {
            let old = pendingShots.removeFirst()
            old.discard()
            tlog("[kamera] bekleyen çekim sayısı sınırı aşıldı; en eskisi silindi")
        }
    }

    /// Test bitti: gönderilemeyen çekimler artık gönderilmez (sonraki bir oturumda eski testin sorusu yeniden gönderilmesin); video dosyaları
    /// silinir ve ekranda kaç sorunun cevapsız kaldığı yazılır
    func dropUnsentShots() {
        guard !pendingShots.isEmpty else { return }
        let count = pendingShots.count
        pendingShots.forEach { $0.discard() }
        pendingShots.removeAll()
        retriedShots.removeAll()
        statusNote += " Uyarı: çekilen \(count) soru Gemini'ye gönderilemedi, cevabı yok."
        tlog("[kamera] test bitti; gönderilemeyen \(count) çekilmiş soru atıldı")
    }

    func dropPending(_ shot: CapturedQuestion) {
        pendingShots.removeAll { $0 == shot }
        shot.discard()
    }

    // MARK: Bağlantı geçişi

    /// Kestirme: Wi-Fi bırakılır, hücresel açılır; internet gelene kadar beklenir. İkinci kez denenir. İnternet geldi mi.
    func returnToInternet(shortcut: String) async -> Bool {
        for attempt in 1...Timing.cameraInternetTries {
            let outcome = await deps.shortcuts.run(name: shortcut)
            guard !Task.isCancelled else { return false }
            // Zaman aşımı: kestirme çalışmış ama dönüş haberi gelmemiş olabilir; internet yoklaması karar verir
            if outcome == .success || outcome == .timedOut {
                if await waitForInternet(seconds: Timing.cameraInternetWait) { return true }
            }
            tlog("[kamera] internete dönüş \(attempt). deneme: kestirme \(outcome), internet gelmedi")
        }
        return false
    }

    func waitForInternet(seconds: TimeInterval) async -> Bool {
        var waited: TimeInterval = 0
        while !Task.isCancelled {
            if await deps.health.internetReachable() { return true }
            if waited >= seconds { return false }
            await deps.sleep(2)
            waited += 2
        }
        return false
    }

    // MARK: Yardımcılar

    /// Çekim sürerken kamera programının yönlendirme cümleleri: ayrı bir cümle sürüyorsa yenisi atlanır (art arda üst üste binmesin)
    func sayGuidance(_ text: String) {
        guard cameraBusy, !cameraGuidanceSpeaking else { return }
        cameraGuidanceSpeaking = true
        Task { [weak self] in
            guard let self = self else { return }
            _ = try? await self.deps.speaker.speak(text, saveAs: nil)
            self.cameraGuidanceSpeaking = false
        }
    }

    func waitForGuidanceSpeech() async {
        var waited = 0
        while cameraGuidanceSpeaking, waited < 50, !Task.isCancelled {
            await Task.yield()   // söylenmekte olan cümlenin görevine sıra verilir (uyku hiç beklemese de ilerlesin)
            await deps.sleep(0.2)
            waited += 1
        }
        cameraGuidanceSpeaking = false
    }

    /// Kamera akışı olmadı: neden söylenir ve soru V3'teki gibi sesle okunmaya başlanır
    func fallBackToVoice(_ text: String) async {
        guard await speakNotice(text) else { return }
        listenForVoiceQuestion()
    }
}
