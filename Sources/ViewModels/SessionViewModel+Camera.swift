import Foundation

/// Sürüm 4: her soru için "kamera ile çekip göndermek ister misiniz?" akışı.
///
/// Evet denince sırayla: (1) Kestirme: hücresel kesilir, telefon kameranın Wi-Fi ağına bağlanır; (2) kamera açılır, program sayfayı sesle
/// konumlandırır, soruyu videoya ve fotoğrafa alır ve kamerayı kapatır; (3) Kestirme: Wi-Fi bırakılır, hücresel açılır, internet gelene
/// kadar beklenir; (4) fotoğraf + video Gemini'ye gider, cevap okunur ve kaydedilir (V3'ün cevap akışı aynen); (5) sıradaki soru için yine sorulur.
/// Hayır denince V3 gibi: kullanıcı soruyu okur, "Cevapla" der. Kamera akışı herhangi bir adımda başarısız olursa program nedenini söyler
/// ve soruyu sesle okumaya döner; kullanıcı hiçbir adımda sessizlikte bırakılmaz.
///
/// Ortak paragraf da aynı düzendedir (V3'teki sesle okuma gibi): kullanıcı "Ortak paragraf" der, program "kamera ile çekmek ister misiniz?"
/// diye sorar; evet denirse paragraf okunmaz, video + fotoğraf olarak çekilir (soruyla aynı kamera akışı), ardından "hangi sorular için?"
/// sorulur ve numaralar söylenir. Görüntüler o numaralı her soruyla birlikte Gemini'ye gider.
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
        // Önceki kamera akışı yarıda kesildiyse telefon kameranın Wi-Fi'sinde kalmış olabilir: önce internet geri getirilir
        await restoreInternetIfStrandedOnCamera()
        // Kesinti (kulaklık, arama, onarım) soruyu söylerken ya da bekleyen çekimi gönderirken gelirse soru kaybolmaz: onarımdan sonra yeniden sorulur
        guard !Task.isCancelled else { offerCamera = true; return }
        // Telefonda bekleyen çekim varsa önce o gönderilir; gönderim kendi akışıyla (cevap, sıradaki soru) devam eder, burada yeniden sorulmaz
        if !again, resendablePending != nil, await sendPendingShots() { return }
        guard !Task.isCancelled, await speakNotice(again ? Say.askCameraAgain : Say.askCamera) else {
            offerCamera = true
            return
        }
        beginListening(mode: .cameraChoice)
    }

    /// Yeni bir soru sınırı: kamera sorusu sorulacaksa bayrak kurulur (ilk soru, başlangıç seçimi, komuttan dönüş)
    func armCameraOffer() {
        offerCamera = cameraOfferAvailable
        cameraOfferSuppressed = false
    }

    /// Ortak paragraf kaydedildikten sonra sıradaki adım kamera sorusu olacak mı (bu soru için "hayır" denmediyse ve kamera hazırsa)
    var cameraNextAfterPassage: Bool {
        return cameraOfferAvailable && !cameraOfferSuppressed
    }

    /// Bir sonraki `beginListening(mode: .question)` kamera sorusunu soracak mı: sorulacaksa cümleler "soruyu okuyun" demez
    var cameraQuestionWillBeAsked: Bool {
        return cameraOfferAvailable && !cameraOfferSuppressed && (offerCamera || resendablePending != nil)
    }

    func fireCameraChoice() {
        guard let reply = interpret(SpokenReply.cameraChoice) else { return }
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

    // MARK: Ortak paragraf: sesle mi, kamerayla mı

    /// "Ortak paragrafı kamera ile çekmek ister misiniz?" sorusuna cevap: evet kamerayla çeker, hayır V3'teki gibi sesle okutur
    func firePassageCameraChoice() {
        guard let reply = interpret(SpokenReply.cameraChoice) else { return }
        clearWarning("duyulan")
        closeListening()
        // Seçim yapıldı: bundan sonraki bir onarım "evet / hayır"ı yeniden sormaz. Evet: çekim sürerken kip önemsizdir; hayır: paragraf kipi korunur
        listenMode = reply == .yes ? .question : .passage
        phase = .speaking
        cameraReminders = 0
        tlog("[paragraf] ortak paragraf için kamera sorusuna \(reply == .yes ? "evet" : "hayır") denildi")
        work = Task { [weak self] in
            guard let self = self else { return }
            if reply == .yes {
                await self.runCameraCapture(subject: .passage)
            } else {
                guard await self.speakNotice(Say.passageCameraDeclined) else { return }
                self.beginListening(mode: .passage)
            }
        }
    }

    /// Cevap gelmedi ya da anlaşılmadı: bir kez daha sorulur; yine olmazsa güvenli varsayılan (paragrafı sesle okutma, ağ değiştirmeden)
    func passageCameraChoiceSilence() async {
        cameraReminders += 1
        if cameraReminders <= Timing.choiceReminderLimit {
            guard await speakNotice(Say.askPassageCameraAgain) else { return }
            beginListening(mode: .passageCameraChoice)
        } else {
            cameraReminders = 0
            tlog("[paragraf] kamera sorusu cevapsız kaldı; paragraf sesle okutuluyor")
            listenMode = .passage
            guard await speakNotice(Say.passageCameraDefaultVoice) else { return }
            beginListening(mode: .passage)
        }
    }

    /// Paragraf çekimi olmadı: neden söylenir ve paragraf V3'teki gibi sesle okutulur
    func fallBackToVoicePassage(_ text: String) async {
        listenMode = .passage
        guard await speakNotice(text) else { return }
        beginListening(mode: .passage)
    }

    /// Paragrafın görüntüleri alındı ve internet geldi: hangi sorulara ait olduğu sorulur (V3'teki paragraf adımı aynen)
    func askPassageTargetsAfterCamera() async {
        statusNote = ""
        listenMode = .passageTargets
        guard await speakNotice(Say.passageTakenCamera) else { return }   // kesildi: taslak durur, onarımdan sonra yeniden sorulur
        beginListening(mode: .passageTargets)
    }

    /// Paragrafın video dosyası, artık ne taslakta ne kayıtlı paragrafta tutulmuyorsa silinir (paragraf değişti, bitti ya da vazgeçildi)
    func releasePassageShot(_ old: CapturedQuestion?) {
        guard let old = old else { return }
        if passage?.shot?.id == old.id || passageDraft?.shot?.id == old.id { return }
        old.discard()
    }

    // MARK: Çekim akışı

    /// Kamera çekimi. `subject == .passage`: çekilen ortak paragraftır; soru gibi Gemini'ye gönderilmez, "hangi sorulara ait" sorulana kadar
    /// taslak olarak tutulur. Her adımda kullanıcıya kısa bilgi verilir (kameraya geçiliyor, çekim başarılı, internet geldi…).
    func runCameraCapture(subject: CaptureSubject = .question) async {
        guard !cameraBusy else { return }
        cameraBusy = true
        defer { cameraBusy = false }
        let isPassage = subject == .passage
        let cameraName = cameraSettings.cameraShortcutName.trimmed
        let internetName = settings.internetShortcut.trimmed
        guard cameraConfigured else {
            if isPassage {
                await fallBackToVoicePassage(Say.passageShortcutsMissing)
            } else {
                await fallBackToVoice(Say.cameraShortcutsMissing)
            }
            return
        }
        guard await speakNotice(isPassage ? Say.passageCameraConnecting : Say.cameraConnecting) else {
            offerCamera = true   // kesildi (kulaklık, arama, onarım): onarımdan sonra kamera sorusu yeniden sorulur
            return
        }
        phase = .answering
        networkMayBeOnCamera = true   // kestirme çalışınca hücresel kapanır; internete dönüş doğrulanana kadar bayrak durur
        statusNote = "Kameraya geçiliyor (hücresel kesiliyor)"
        tlog("[kamera] hücresel kesilip kameranın Wi-Fi ağına geçiliyor: kestirme “\(cameraName)”\(isPassage ? " (ortak paragraf)" : "")")
        deps.camera.subject = subject
        var result = await captureWithRepair(cameraName: cameraName)
        // Çekim telefonda saklanır: internete dönüş sürerken kesinti olsa ya da gönderim başarısız olsa da kaybolmaz
        if case .success(var shot) = result {
            if !isPassage { shot.extraInstruction = cameraSettings.videoQuestion.trimmed }   // ek talimat soruya yöneliktir, paragrafa değil
            shot.highResolution = cameraSettings.videoHighRes
            if !cameraSettings.videoToGemini {
                shot.discard()
                shot.video = nil
                shot.videoBytes = 0
            }
            result = .success(shot)
            if isPassage {
                // Paragraf bir soru değildir: tek başına gönderilmez; hangi sorulara ait olduğu söylenene kadar taslak olarak tutulur
                // (kesinti olursa onarımdan sonra numaralar yeniden sorulur, bkz. `continuation`)
                passageDraft = PassageDraft(text: "", english: "", audio: nil, shot: shot)
                targetReminders = 0
                targetDoneReminders = 0
            } else {
                keepPending(shot)
            }
        }
        guard !Task.isCancelled, phase == .answering else {
            if !isPassage || passageDraft == nil { offerCamera = true }
            return
        }
        if case .success = result { sayGuidance(isPassage ? Say.passageCaptured : Say.cameraCaptured) }
        // Kamera kapandı: Wi-Fi bırakılır, hücresel açılır
        statusNote = "İnternete geçiliyor (Wi-Fi bırakılıyor)"
        let online = await returnToInternet(shortcut: internetName)
        if online { networkMayBeOnCamera = false }
        await waitForGuidanceSpeech()
        guard !Task.isCancelled, phase == .answering else {
            // Çekim telefonda bekliyorsa önce o gönderilir (bkz. beginListening); paragraf taslağı varsa numaraları sorulur (bkz. continuation)
            if (isPassage ? passageDraft == nil : pendingShots.isEmpty) { offerCamera = true }
            return
        }
        switch result {
        case .failure(let failure):
            tlog("[kamera] çekim olmadı: \(failure.message)")
            clearWarning("kamera")
            if online {
                if isPassage {
                    await fallBackToVoicePassage(Say.passageCameraFailed(failure))
                } else {
                    await fallBackToVoice(Say.cameraFailed(failure))
                }
            } else {
                await repairInternetAfterCamera(Say.cameraFailedOffline(failure))
            }
        case .success(let shot):
            tlog("[kamera] çekildi\(isPassage ? " (ortak paragraf)" : ""): fotoğraf \(shot.photo.count / 1024) KB, video \(shot.video == nil ? "yok" : "\(shot.videoBytes / 1024) KB, \(Int(shot.videoSeconds.rounded())) sn"); internet \(online ? "geldi" : "gelmedi")")
            if isPassage {
                if online {
                    clearWarning("kamera")
                    await askPassageTargetsAfterCamera()
                } else {
                    warn("kamera", "Çekilen paragraf telefonda bekliyor: internet gelmedi.")
                    await repairInternetAfterCamera(Say.passageSavedOffline)
                }
            } else if online {
                await sendShot(shot)
            } else {
                warn("kamera", "Çekilen soru telefonda bekliyor: internet gelmedi.")
                await repairInternetAfterCamera(Say.cameraSavedOffline)
            }
        }
    }

    /// Çekim bitti, internet geldi: fotoğraf + video Gemini'ye gider, cevap V3'ün akışıyla okunur ve kaydedilir
    func sendShot(_ original: CapturedQuestion) async {
        // Sesle kaydedilmiş ortak paragraf varsa çekilen soruyla birlikte gider (numara görüntüden okunur; paragraf listedeki numaralar için geçerlidir)
        var prepared = original
        if let context = passage {
            prepared.passageNote = QuestionComposer.cameraNote(passage: context)
            // Paragraf kamerayla çekilmişse görüntüleri de gider (soruinkinden önce; metindeki not sırayı söyler)
            if let media = context.shot, !context.remaining.isEmpty { prepared.passageMedia = PassageMedia(media) }
        }
        let shot = prepared
        sendingShotID = shot.id
        defer { sendingShotID = nil }
        phase = .answering
        statusNote = ""
        let expected = nextNumber
        beginEntry(text: Say.cameraEntryText, withAudio: false, number: expected)
        deps.journal.savePending(nil)
        if settings.spokenProgress { speakProgress(shot.passageMedia == nil ? Say.cameraSending : Say.cameraSendingWithPassage) }
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
                if Task.isCancelled, case .paused = phase {
                    // Cevap tam kesinti anında geldi: `answer` onu okumadan atar. Çekim telefonda kalır, onarımdan sonra yeniden gönderilir
                    retriedShots.remove(shot.id)
                } else {
                    dropPending(shot)
                }
                return reply
            } catch let error as GeminiError {
                last = error
                guard error.kind == .network, attempt < Timing.cameraSendTries, !Task.isCancelled else { break }
                tlog("[kamera] gönderim ağ hatası verdi; internet kestirmesi yeniden çalıştırılıp bir kez daha denenecek")
                _ = await returnToInternet(shortcut: settings.internetShortcut.trimmed)
            }
        }
        let failure = last ?? GeminiError("Gemini cevap vermedi.", .error)
        if Task.isCancelled {
            // Kulaklık ya da arama kesintisi (duraklatma) başarısızlık sayılmaz: çekim kalır ve onarımdan sonra yeniden denenebilir.
            // Başka iptallerde (bekleme sınırı, takılma gözcüsü) deneme hakkı yenilenmez: aynı çekim sonsuza dek yeniden gönderilmesin.
            if case .paused = phase { retriedShots.remove(shot.id) }
            throw failure
        }
        switch failure.kind {
        case .blocked, .tooBig:
            dropPending(shot)   // aynı çekim yeniden denense de aynı sonucu verir: telefonda tutulmaz
            offerCamera = cameraOfferAvailable   // hata söylendikten sonra bu soru için kamera yeniden sorulur
        default:
            if retriedShots.contains(shot.id) {
                // Bekleyen çekimin tek yeniden gönderimi de başarısız oldu: sınav akışı her soruda yeniden denemekle yavaşlamasın, atılır ve söylenir
                dropPending(shot)
                retriedShots.remove(shot.id)
                offerCamera = cameraOfferAvailable   // sınav akışı sesle okumaya kaymaz: söylendikten sonra kamera yeniden sorulur
                warn("kamera", Say.cameraPendingGivenUp)
            } else {
                warn("kamera", "Çekilen soru telefonda bekliyor (\(failure.kind == .network ? "Gemini'ye ulaşılamadı" : "gönderilemedi")).")
            }
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
        await sendShot(first)   // yine başarısız olursa `sendWithRetry` çekimi atar ve söyler
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

    /// Önceki kamera akışı yarıda kesildi (kulaklık, arama, onarım) ve internete dönüş doğrulanmadı: internet yoksa telefon kameranın Wi-Fi'sinde,
    /// hücresel kapalı kalmıştır. "İnternete geç" kestirmesi çalışır (internet varsa hiçbir şey yapılmaz). Sonraki kamera sorusundan ve
    /// bekleyen çekimin gönderiminden önce çağrılır; yoksa bağlantı 30 sn boşuna beklenir.
    func restoreInternetIfStrandedOnCamera() async {
        guard networkMayBeOnCamera, !Task.isCancelled else { return }
        if await deps.health.internetReachable() {
            networkMayBeOnCamera = false
            return
        }
        let name = settings.internetShortcut.trimmed
        guard !name.isEmpty else { return }
        tlog("[kamera] önceki kamera akışı yarıda kaldı ve internet yok; “\(name)” kestirmesi çalıştırılıyor")
        statusNote = "İnternete geçiliyor (Wi-Fi bırakılıyor)"
        if await returnToInternet(shortcut: name) { networkMayBeOnCamera = false }
        statusNote = ""
    }

    /// Test kamera akışı sürerken bitti: telefonun interneti kestirmeyle geri getirilir (yoksa kameranın Wi-Fi'sinde, hücresel kapalı kalırdı)
    func restoreInternetAfterCamera() {
        networkMayBeOnCamera = false
        let name = settings.internetShortcut.trimmed
        guard !name.isEmpty else { return }
        tlog("[kamera] test kamera akışı sürerken bitti; internet kestirmesi çalıştırılıyor: “\(name)”")
        work = Task { [weak self] in
            guard let self = self else { return }
            _ = await self.deps.shortcuts.run(name: name)
        }
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
