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
        guard settings.askCamera, cameraDownSince == nil else { return false }   // kameraya ulaşılamıyorsa soru sesle okunur (bkz. SessionViewModel+CameraWatch)
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
        if !again { cameraReminders = 0 }   // her soru için sayaç baştan başlar (önceki sorudan kalan "cevapsız" sayısı taşınmaz)
        // Önceki kamera akışı yarıda kesildiyse telefon kameranın Wi-Fi'sinde kalmış olabilir: önce internet geri getirilir
        await restoreInternetIfStrandedOnCamera()
        // Kesinti (kulaklık, arama, onarım) soruyu söylerken ya da bekleyen çekimi gönderirken gelirse soru kaybolmaz: onarımdan sonra yeniden sorulur
        guard !Task.isCancelled else { offerCamera = true; return }
        // Telefonda bekleyen çekim varsa önce o gönderilir; gönderim kendi akışıyla (cevap, sıradaki soru) devam eder, burada yeniden sorulmaz
        if !again, resendablePending != nil, await sendPendingShots() { return }
        // Bekleyenlerin hepsi gönderilip cevapları alındı: bir kez söylenir, sonra canlı sorulara dönülür
        if !again, drainActive, resendablePending == nil {
            drainActive = false
            if pendingShots.isEmpty {
                guard !Task.isCancelled, await speakNotice(Say.cameraPendingDone) else { offerCamera = true; return }
            }
        }
        guard cameraOfferAvailable else {
            // Kamera sorusu kapatılmış ya da yapılandırılmamış (yalnız bekleyen çekim vardı): soru V3 gibi sesle okunur
            guard !Task.isCancelled else { offerCamera = true; return }   // kesildi: onarımdan sonra bekleyen çekim yeniden denenir
            pendingDrainSkipped = true
            beginListening(mode: .question)
            return
        }
        guard !Task.isCancelled, await speakNotice(cameraAskText(again: again)) else {
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
                await self.startCameraSession()
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

    /// Cevap gelmedi ya da anlaşılmadı: soru toplam `Timing.cameraAsks` kez sorulur. Sessizlikte "Cevap vermediniz, ikinci (üçüncü) defa
    /// soruyorum", anlaşılmayan sözde "Anlayamadım" denir. Sonuncuda da cevap gelmezse kameraya kendiliğinden geçilir ("evet" denmiş gibi).
    func cameraChoiceSilence(unclear: Bool = false) async {
        cameraReminders += 1
        if cameraReminders < Timing.cameraAsks {
            let text = cameraAskReminder(unclear: unclear, attempt: cameraReminders + 1)
            guard await speakNotice(text) else { return }
            beginListening(mode: .cameraChoice)
        } else {
            cameraReminders = 0
            tlog("[kamera] evet / hayır cevabı \(Timing.cameraAsks) kez gelmedi; kameraya kendiliğinden geçiliyor")
            clearWarning("duyulan")
            listenMode = .question   // seçim yapıldı: bundan sonraki bir onarım "evet / hayır"ı yeniden sormaz, kesilen çekim yeniden denenir
            guard await speakNotice(Say.cameraAutoStart) else {
                offerCamera = true
                return
            }
            await startCameraSession()
        }
    }

    // MARK: Soru mu, paragraf mı

    /// Kamera "evet" denince: çekilecek şeyin soru mu ortak paragraf mı olduğu sorulur; çekim ve gönderim buna göre yürür
    /// (paragraf soru gibi gönderilmez: hangi sorulara ait olduğu sorulur, görüntüler o sorularla gider)
    func askCaptureKind() async {
        cameraReminders = 0
        // Ayarlardan kapatılmışsa her çekim soru sayılır (V4'ün ilk davranışı)
        guard settings.askCaptureKind else {
            await runCameraCapture()
            return
        }
        guard await speakNotice(Say.askCaptureKind) else {
            offerCamera = true   // kesildi: onarımdan sonra kamera sorusu yeniden sorulur
            return
        }
        beginListening(mode: .captureKindChoice)
    }

    func fireCaptureKind() {
        guard let kind = interpret(SpokenReply.captureKind) else { return }
        clearWarning("duyulan")
        closeListening()
        listenMode = .question   // seçim yapıldı: çekim sürerken kip önemsizdir; bundan sonraki bir onarım soruyu yeniden sormaz
        phase = .speaking
        cameraReminders = 0
        tlog("[kamera] çekilecek şey: \(kind == .passage ? "ortak paragraf" : "soru")")
        work = Task { [weak self] in
            await self?.runCameraCapture(subject: kind == .passage ? .passage : .question)
        }
    }

    /// Cevap gelmedi ya da anlaşılmadı: toplam `Timing.cameraAsks` kez sorulur; üçüncüde de cevap gelmezse soru olarak çekilir
    func captureKindSilence(unclear: Bool = false) async {
        cameraReminders += 1
        if cameraReminders < Timing.cameraAsks {
            let text = unclear ? Say.reask(Say.askCaptureKindAgain, attempt: cameraReminders + 1) : Say.askCaptureKindRepeat(cameraReminders + 1)
            guard await speakNotice(text) else { return }
            beginListening(mode: .captureKindChoice)
        } else {
            cameraReminders = 0
            tlog("[kamera] soru mu paragraf mı cevabı \(Timing.cameraAsks) kez gelmedi; soru olarak çekiliyor")
            clearWarning("duyulan")
            listenMode = .question
            guard await speakNotice(Say.captureKindDefault) else {
                offerCamera = true
                return
            }
            await runCameraCapture()
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
            guard await speakNotice(Say.reask(Say.askPassageCameraAgain, attempt: cameraReminders + 1)) else { return }
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
        guard !cameraBusy else {
            tlog("[kamera] önceki çekim sürüyor; yeni çekim başlatılmadı")
            return
        }
        cameraBusy = true
        defer { cameraBusy = false }
        let isPassage = subject == .passage
        let cameraName = cameraSettings.cameraShortcutName.trimmed
        let internetName = settings.internetShortcut.trimmed
        tlog("[kamera] evet denildi\(isPassage ? " (ortak paragraf)" : ""): kestirme “\(cameraName)”, internet kestirmesi “\(internetName)”, kamera adı \(CameraUID(cameraSettings.uid) == nil ? "geçersiz" : "geçerli")")
        guard cameraConfigured else {
            if isPassage {
                await fallBackToVoicePassage(Say.passageShortcutsMissing)
            } else {
                await fallBackToVoice(Say.cameraShortcutsMissing)
            }
            return
        }
        guard await speakNotice(isPassage ? Say.passageCameraConnecting : Say.cameraConnecting) else {
            tlog("[kamera] “Kameraya geçiliyor” anonsu kesildi (kulaklık, arama ya da onarım); kestirme çalıştırılmadı, onarımdan sonra yeniden sorulacak")
            offerCamera = true   // kesildi (kulaklık, arama, onarım): onarımdan sonra kamera sorusu yeniden sorulur
            return
        }
        let attemptStart = deps.now()
        phase = .answering
        networkMayBeOnCamera = true   // kestirme çalışınca hücresel kapanır; internete dönüş doğrulanana kadar bayrak durur
        statusNote = cameraSettings.stayOnWifi ? "Kameraya bağlanılıyor" : "Kameraya geçiliyor (hücresel kesiliyor)"
        tlog(cameraSettings.stayOnWifi ? "[kamera] Wi-Fi'de kal: telefon kameranın ağında kalır, hücresel kesilmez"
             : "[kamera] hücresel kesilip kameranın Wi-Fi ağına geçiliyor: kestirme “\(cameraName)”\(isPassage ? " (ortak paragraf)" : "")")
        deps.camera.subject = subject
        var result = await captureWithRepair(cameraName: cameraName)
        // Çekim telefonda saklanır: internete dönüş sürerken kesinti olsa ya da gönderim başarısız olsa da kaybolmaz
        if case .success(let taken) = result {
            // Çekim telefondaki kalıcı klasöre yazılır (video da oraya taşınır): internet gelene kadar, uygulama kapansa da kaybolmaz ve
            // gönderildikten sonra da kullanıcı silene kadar orada durur
            let shot = deps.captureStore.keep(shapedShot(taken, isPassage: isPassage), kind: isPassage ? .passage : .question)
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
        // 5 denemede de kameraya ulaşılamadı (kapalı, şarjı bitti, menzil dışı): kamera sistemden çıkarılır, sesle devam edilir, 5 dakikada bir yoklanır
        var cameraGaveUp = false
        if case .failure(let failure) = result, failure == .notConnected || failure == .noFrames, !Task.isCancelled, phase == .answering {
            cameraGaveUp = true
            markCameraDown(since: attemptStart)
        }
        guard !Task.isCancelled, phase == .answering else {
            if !isPassage || passageDraft == nil { offerCamera = true }
            return
        }
        if case .success = result {
            // SIM yoksa "internete geçiliyor" denmez (geçilmeyecek): internet kontrol edildiği söylenir
            let offlineNoSim = !isPassage && !deps.health.hasCellularService()
            sayGuidance(isPassage ? Say.passageCaptured : (offlineNoSim ? Say.cameraCapturedOffline : Say.cameraCaptured))
        }
        // Kamera kapandı (görüntü kapatıldı: kamera boşta, Wi-Fi yayını sürer). Eski düzende Wi-Fi bırakılır, hücresel açılır;
        // "Wi-Fi'de kal" kipinde telefon kameranın ağında kalır ve yalnız internet yoksa hücresel kestirmesi çalışır
        if cameraSettings.stayOnWifi {
            tlog("[kamera] kamera uykuya alındı (görüntü kapatıldı); telefon kameranın Wi-Fi'sinde kalıyor")
        }
        statusNote = internetNote
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
                    await fallBackToVoicePassage(Say.passageCameraFailed(failure, down: cameraGaveUp, minutes: settings.cameraCheckMinutes))
                } else {
                    await fallBackToVoice(Say.cameraFailed(failure, down: cameraGaveUp, minutes: settings.cameraCheckMinutes))
                }
            } else if !isPassage, offlineCapture {
                await continueOffline(Say.cameraFailedOfflineContinue(failure))
            } else {
                await repairInternetAfterCamera(Say.cameraFailedOffline(failure))
            }
        case .success(let shot):
            rememberShot(shot)
            tlog("[kamera] çekildi\(isPassage ? " (ortak paragraf)" : ""): \(shot.pdf == nil ? "fotoğraf \(shot.photo.count / 1024) KB" : "\(shot.pageCount) fotoğraflık PDF \((shot.pdf?.count ?? 0) / 1024) KB"), video \(shot.video == nil ? "yok" : "\(shot.videoBytes / 1024) KB, \(Int(shot.videoSeconds.rounded())) sn"); internet \(online ? "geldi" : "gelmedi")")
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
            } else if offlineCapture {
                // SIM kart yok: internet bekletilmez, onarım Kestirmesi çalışmaz. Çekim telefonda birikir, sınav sıradaki soruyla sürer;
                // internet gelince bekleyenler sırayla gönderilir (bkz. `drainPendingWhenOnline`)
                tlog("[kamera] çevrimdışı çekim kipi: çekim telefonda bekliyor (\(pendingShots.count) bekleyen), sıradaki soruya geçiliyor")
                await continueOffline(Say.cameraSavedOfflineContinue(waiting: pendingShots.count))
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
        if let context = passage, !original.isPage {   // toplu çekimde sayfa kendi başınadır: sesle okunmuş paragraf notu eklenmez
            prepared.passageNote = QuestionComposer.cameraNote(passage: context)
            // Paragraf kamerayla çekilmişse görüntüleri de gider (soruinkinden önce; metindeki not sırayı söyler)
            if let media = context.shot, !context.remaining.isEmpty { prepared.passageMedia = PassageMedia(media) }
        }
        let shot = prepared
        queuedReplies = []   // yeni gönderim: önceki sayfadan kalan cevap yoktur
        pageBeingRead = nil
        pageSpokenAll = []
        sendingShotID = shot.id
        defer { sendingShotID = nil }
        phase = .answering
        statusNote = ""
        let expected = nextNumber
        beginEntry(text: Say.cameraEntryText, withAudio: false, number: expected)
        deps.journal.savePending(nil)
        if settings.spokenProgress {
            // Toplu gönderimde her çekim için hangisinin gönderildiği söylenir (kullanıcı boşlukta kalmaz)
            speakProgress(shot.isPage ? Say.pageSending(index: drainIndex, total: drainTotal)
                          : drainActive ? Say.cameraDrainSending(index: drainIndex, total: drainTotal)
                          : (shot.passageMedia == nil ? Say.cameraSending : Say.cameraSendingWithPassage))
        }
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
                let reply: GeminiReply
                if shot.isPage {
                    // Toplu çekim: sayfadaki bütün sorular tek istekte cevaplanır. İlki hemen okunur, kalanlar sırayla (bkz. `readNextQueuedReply`);
                    // sayfa bütün cevaplar duyulunca bekleyenlerden çıkar (`completeReadPage`): yarıda kalırsa kaybolmaz, yeniden gönderilir
                    let replies = try await deps.answering.answerPage(capture: shot, expectedNumber: expected)
                    guard let first = replies.first else { throw GeminiError("Gemini cevap satırı vermedi.", .empty) }
                    queuedReplies = Array(replies.dropFirst())
                    pageBeingRead = shot
                    pageSpokenAll = replies.map { $0.spoken }.filter { !$0.isEmpty }
                    tlog("[sayfa] Gemini sayfa için \(replies.count) cevap verdi")
                    reply = first
                } else {
                    reply = try await deps.answering.answer(capture: shot, expectedNumber: expected)
                }
                if Task.isCancelled, case .paused = phase {
                    // Cevap tam kesinti anında geldi: `answer` onu okumadan atar. Çekim telefonda kalır, onarımdan sonra yeniden gönderilir
                    retriedShots.remove(shot.id)
                } else if !shot.isPage {
                    completePending(shot, answer: reply.spoken)
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
            shelvePending(shot, reason: failure.message)   // aynı çekim yeniden denense de aynı sonucu verir: gönderilmez, ama silinmez ("Gönderilemeyen" klasörü)
            offerCamera = cameraOfferAvailable   // hata söylendikten sonra bu soru için kamera yeniden sorulur
        default:
            if noteSendFailure(shot.id) {
                // İnternet çalıştığı hâlde defalarca gönderilemedi: bu test için beklemeye alınır, silinmez
                offerCamera = cameraOfferAvailable
                warn("kamera", Say.cameraPendingParked)
            } else if retriedShots.contains(shot.id) {
                // Bekleyen çekimin tek yeniden gönderimi de başarısız oldu: sınav akışı her soruda yeniden denemekle yavaşlamasın diye bir sonraki
                // başarılı cevaba kadar beklenir. Çekim ATILMAZ: telefondaki klasörde durur ve internet / Gemini düzelince sırayla gönderilir.
                offerCamera = cameraOfferAvailable   // sınav akışı sesle okumaya kaymaz: söylendikten sonra kamera yeniden sorulur
                warn("kamera", Say.cameraPendingKept)
            } else {
                warn("kamera", "Çekilen soru telefonda bekliyor (\(failure.kind == .network ? "Gemini'ye ulaşılamadı" : "gönderilemedi")).")
            }
        }
        throw failure
    }

    /// Gönderilmemiş çekimlerden henüz yeniden denenmemiş ilki. Her çekim bir kez kendiliğinden yeniden denenir; yine başarısızsa
    /// bir sonraki başarılı gönderime kadar beklenir (yoksa hata sonsuz "yeniden dene" döngüsüne girerdi).
    var resendablePending: CapturedQuestion? {
        return pendingShots.first { !retriedShots.contains($0.id) && (sendFailures[$0.id] ?? 0) < Timing.pendingSendAttempts }
    }

    /// Bekleyen çekimin gönderimi başarısız oldu. Sınıra ulaşıldıysa çekim bu test için beklemeye alınır (klasörde durur, silinmez): true döner.
    func noteSendFailure(_ id: UUID) -> Bool {
        guard pendingShots.contains(where: { $0.id == id }) else { return false }
        let count = (sendFailures[id] ?? 0) + 1
        sendFailures[id] = count
        return count >= Timing.pendingSendAttempts
    }

    /// Önceki çekimden kalan soru (internet gelmediği için gönderilememişti) gönderilir. Gönderim başladıysa true (devamını `answer` yürütür);
    /// internet yoksa ya da konuşma kesildiyse false.
    func sendPendingShots() async -> Bool {
        guard let first = resendablePending else { return false }
        // SIM kart yoksa internet kendiliğinden gelmez: her soru sınırında konuşup 30 sn beklenmez; internet yoksa sessizce geçilir
        if !deps.health.hasCellularService(), !(await deps.health.internetReachable()) {
            offlineHeld = true
            tlog("[kamera] telefonda \(pendingShots.count) bekleyen çekim var, internet yok (SIM kart yok): gönderilmedi")
            return false
        }
        // Toplu gönderimin başında bir kez: "internet tekrar kuruldu, dosya gönderimi yapılıyor, lütfen bekleyiniz"; sıradaki çekimler sessiz gider
        if !drainActive {
            drainTotal = max(1, pendingShots.count)
            drainIndex = 0
            guard await speakNotice(Say.cameraPendingSending) else { return true }   // konuşma kesildi: onarım sonrası yeniden denenir
        }
        guard await waitForInternet(seconds: Timing.cameraInternetWait) else {
            warn("kamera", "Bekleyen çekilen soru gönderilemedi: internet yok.")
            drainActive = false
            return false
        }
        clearWarning("kamera")
        drainActive = true
        drainIndex += 1
        retriedShots.insert(first.id)
        await sendShot(first)   // yine başarısız olursa `sendWithRetry` çekimi atar ve söyler
        return true
    }

    /// Çevrimdışı çekim kipi: kamera akışı açık ve telefonda SIM kart yok. İnternet yokken sınav durmaz, çekimler telefonda birikir.
    var offlineCapture: Bool {
        return cameraOfferAvailable && !deps.health.hasCellularService()
    }

    /// Çekim (ya da çekim hatası) söylenir, sıradaki soru için kamera sorusu açılır; sınav internet beklemeden sürer
    func continueOffline(_ text: String) async {
        offlineHeld = true
        statusNote = ""
        guard await speakNotice(text) else { return }   // kesildi (kulaklık, arama): onarımdan sonra sıradaki adım yeniden kurulur
        armCameraOffer()
        beginListening()
    }

    /// Çevrimdışı çekim kipinde bekleyen çekimler varken internet geldi: dinleme açıksa (yarım söz yoksa) bekleyenler sırayla gönderilir
    func drainPendingWhenOnline() {
        guard offlineHeld, phase == .listening, resendablePending != nil, accumulator.isEmpty,
              listenMode == .cameraChoice || listenMode == .question else { return }
        offlineHeld = false
        tlog("[kamera] internet geldi; telefonda bekleyen \(pendingShots.count) çekim gönderilecek")
        beginListening(mode: .question)
    }

    /// Kameraya geçilir ve çekilir. Kameraya bağlanılamazsa (kestirme çalışmadı, kamera yanıt vermedi, görüntü gelmedi) "kamera bağlantısı
    /// onarımı" (Ayarlar'daki Wi-Fi adımı) çalışır ve çekim yeniden denenir; `Timing.cameraRepairs` onarımdan sonra vazgeçilir.
    func captureWithRepair(cameraName: String) async -> Result<CapturedQuestion, CameraFailure> {
        return await repairLoop(cameraName: cameraName, speaks: true,
                                operation: { camera, limit in await camera.capture(connectLimit: limit) },
                                interrupted: { [weak self] shot in self?.saveInterruptedShot(shot) })
    }

    /// Onarım döngüsünün gövdesi (tek çekim ve toplu çekim ortak kullanır). `operation`: kameraya bağlanıp çekimi yapan iş; `speaks`: kamera
    /// konuşma ve durum bağlantılarını alır (toplu çekimde konuşma yoktur); `interrupted`: çekim tam kesinti anında bittiyse klasöre yazılır.
    func repairLoop<T>(cameraName: String, speaks: Bool,
                       operation: (CameraCapturing, TimeInterval?) async -> Result<T, CameraFailure>,
                       interrupted: (T) -> Void) async -> Result<T, CameraFailure> {
        var result: Result<T, CameraFailure> = .failure(.notConnected)
        var repairMissing = false   // onarım kestirmesi telefonda yok ("kestirmesi bulunamadı"): aynı yok kestirme bir daha denenmez
        var onCameraNetwork = false   // kameraya geçiş kestirmesi çalıştı: telefon kameranın Wi-Fi'sindedir, onarım kestirmesi olmasa da kamera yeniden denenir
        let stay = cameraSettings.stayOnWifi   // "Wi-Fi'de kal": ilk denemede kestirme çalışmaz
        var resetDone = false   // bağlantı sıfırlama (uçak modu) bir çekimde en çok BİR kez çalışır
        for attempt in 0...Timing.cameraRepairs {
            var name = cameraName
            if attempt > 0 {
                let repair = settings.shortcutName(for: .wifi)
                name = repair.isEmpty || repairMissing ? cameraName : repair   // onarım kestirmesi yazılmamışsa ya da telefonda yoksa kameraya geçiş kestirmesi yeniden çalışır
                var afterReset = false
                if attempt == Timing.cameraResetAfter, !resetDone, !settings.shortcutName(for: .reset).isEmpty {
                    // İki deneme (ilk + bir onarım) sonuçsuz: telefonun telsizleri uçak moduyla baştan kurulur, sonra "Kameraya Geç" ile yeniden denenir
                    resetDone = true
                    afterReset = true
                    await resetConnectionsForCamera(announce: true)
                    guard !Task.isCancelled, phase == .answering else { return .failure(.cancelled) }
                    name = cameraName   // Wi-Fi açık, hücresel kapalı: kameraya geçiş kestirmesi
                }
                statusNote = "Kamera bağlantısı onarılıyor (\(attempt). deneme)"
                tlog("[kamera] bağlantı onarımı \(attempt). deneme: kestirme “\(name)”\(afterReset ? " (bağlantı sıfırlamadan sonra)" : "")")
                sayGuidance(afterReset ? Say.cameraResetDone : Say.cameraRepairing)
            }
            let outcome: ShortcutOutcome
            if stay && attempt == 0 {
                // Telefon kameranın Wi-Fi'sinde kalmıştır: kestirme çalışmaz, doğrudan bağlanılır; bağlanamazsa onarım kestirmesi devreye girer
                tlog("[kamera] Wi-Fi'de kal: kestirme çalıştırılmadı, doğrudan bağlanılıyor (en çok \(Int(Timing.stayConnectSeconds)) sn)")
                outcome = .success
            } else {
                tlog("[kamera] kestirme çalıştırılıyor: “\(name)”")
                outcome = await runShortcutRetryingTransient(name: name)
                tlog("[kamera] kestirme sonucu: \(outcome)")
            }
            if case .failed(let message) = outcome, SessionViewModel.isMissingShortcutError(message), attempt > 0, name != cameraName {
                repairMissing = true
                tlog("[kamera] “\(name)” kestirmesi bu telefonda yok: Kestirmeler'de bu adla kestirme oluşturulmalı (KURULUM.md); sonraki denemede kameraya geçiş kestirmesi çalışır")
            }
            guard !Task.isCancelled, phase == .answering else {
                tlog("[kamera] kestirmeden dönüşte iş iptal edilmiş ya da durum değişmiş (\(phase)); çekim yapılmadı")
                return .failure(.cancelled)
            }
            let camera = deps.camera
            // Zaman aşımında kestirme çalışmış ama dönüş haberi gelmemiş olabilir: kameranın kendisi karar verir
            if outcome == .success || outcome == .timedOut { onCameraNetwork = true }
            // Onarım denemesinde Wi-Fi onarım kestirmesi yoksa ya da çalışmadıysa bile (telefon zaten kameranın ağındaysa) kameraya yeniden bağlanılır
            var retryWithoutShortcut = false
            if attempt > 0, onCameraNetwork, case .failed = outcome { retryWithoutShortcut = true }
            if outcome == .success || outcome == .timedOut || retryWithoutShortcut {
                if speaks {
                    deps.camera.onSay = { [weak self] text in self?.sayGuidance(text) }
                    deps.camera.onSayWait = { [weak self] text in await self?.sayGuidanceAndWait(text) }
                }
                deps.camera.onStatus = { [weak self] text in self?.statusNote = text }
                // V3 işi iptal ederse (kulaklık, arama, onarım: `work?.cancel()`) kamera da kapanır; yoksa 70 sn boyunca açık kalırdı
                let limit: TimeInterval? = stay && attempt == 0 ? Timing.stayConnectSeconds : nil
                result = await withTaskCancellationHandler {
                    await operation(camera, limit)
                } onCancel: {
                    Task { @MainActor in camera.cancel() }
                }
                deps.camera.onSay = nil
                deps.camera.onSayWait = nil
                deps.camera.onStatus = nil
                await waitForGuidanceSpeech()
            } else {
                tlog("[kamera] kestirme çalışmadı (\(outcome)): kameraya geçilemedi")
                result = .failure(.notConnected)
            }
            guard !Task.isCancelled, phase == .answering else {
                // Çekim tam kesinti anında (kulaklık, arama, onarım) bitmiş olabilir: kaybolmasın diye klasöre yazılır
                if case .success(let shot) = result { interrupted(shot) }
                return .failure(.cancelled)
            }
            if case .failure(let failure) = result, failure == .notConnected || failure == .noFrames { continue }
            break
        }
        return result
    }

    /// Kamera iki denemede de açılmadı: "Sistem sıfırlama" kestirmesi (uçak modu aç/kapa) çalışır; Wi-Fi, Bluetooth ve hücresel telsizler baştan kurulur.
    /// Uçak modu Bluetooth kulaklığı da düşürür (günlükte ≈ 25 sn): bu sürede ses yolu değişikliği duraklatma sayılmaz (`connectionResetActive`) ve
    /// kulaklığın dönmesi `Timing.cameraResetHeadsetWait` sn'ye kadar beklenir. Duyuru kestirmeden ÖNCE söylenir (kestirme uygulamayı askıya alır).
    func resetConnectionsForCamera(announce: Bool) async {
        let name = settings.shortcutName(for: .reset)
        guard !name.isEmpty else { return }
        connectionResetActive = true
        defer { connectionResetActive = false }
        let headsetWasThere = routeVerdict?.isSafe ?? true   // kulaklık zaten yoktuysa dönmesi beklenmez (oturum başında henüz takılmamış olabilir)
        tlog("[kamera] \(Timing.cameraResetAfter) denemede kameraya bağlanılamadı: bağlantı sıfırlama kestirmesi “\(name)” (uçak modu aç/kapa) çalıştırılıyor")
        statusNote = "Telefonun bağlantıları sıfırlanıyor"
        if announce { await sayGuidanceAndWait(Say.cameraResetting) }
        let outcome = await runShortcutRetryingTransient(name: name)
        tlog("[kamera] sıfırlama kestirmesi sonucu: \(outcome)")
        var waited = 0.0
        while headsetWasThere, !Task.isCancelled, !(routeVerdict?.isSafe ?? true), waited < Timing.cameraResetHeadsetWait {
            await Task.yield()   // ses yolu bildirimi gelsin (uyku hiç beklemese de ilerlesin)
            await deps.sleep(0.5)
            waited += 0.5
        }
        tlog("[kamera] sıfırlamadan sonra kulaklık \((routeVerdict?.isSafe ?? true) ? "yerinde" : "dönmedi") (\(Int(waited)) sn beklendi)")
    }

    /// Kestirmeler uygulaması kestirmeyi bazen kendisi geri çevirir: "Çalma Hedefi aygıt bulunamadığı için iş ayarlanamadı". Sınav
    /// sırasında kulaklık sesi açıkken, ses yolu o anda değişirken görüldü; kestirmenin kendisi yanlış değildir. Bu geçici hatada
    /// birkaç saniye sonra aynı kestirme yeniden çalıştırılır. Başka sonuçlar (kestirme yok, iptal, zaman aşımı) beklemeden döner.
    func runShortcutRetryingTransient(name: String) async -> ShortcutOutcome {
        var outcome = await deps.shortcuts.run(name: name)
        var retries = 0
        while retries < Timing.shortcutTransientRetries, !Task.isCancelled,
              case .failed(let message) = outcome, SessionViewModel.isTransientShortcutError(message) {
            retries += 1
            tlog("[kestirme] “\(name)” Kestirmeler tarafından geri çevrildi (\(message)); \(retries). yeniden deneme")
            try? await Task.sleep(nanoseconds: UInt64(Timing.shortcutTransientPause * 1_000_000_000))
            guard !Task.isCancelled else { break }
            outcome = await deps.shortcuts.run(name: name)
        }
        return outcome
    }

    /// Kestirmeler "böyle bir kestirme yok" mu diyor ("“Kamera Bağlantısını Onar” kestirmesi bulunamadı."): yeniden denemek işe yaramaz
    static func isMissingShortcutError(_ message: String) -> Bool {
        let text = message.lowercased()
        return text.contains("kestirmesi bulunamad") || text.contains("could not be found") || text.contains("couldn’t be found")
    }

    /// Kestirmeler'in ses yolu değişirken verdiği geçici ret mesajı mı ("Çalma Hedefi aygıt bulunamadığı için iş ayarlanamadı")
    static func isTransientShortcutError(_ message: String) -> Bool {
        return message.lowercased().contains("çalma hedefi")
    }

    /// Kamera akışından sonra internet iki denemede de gelmedi: durum söylenir ve V3'ün internet onarımı (hücresel → sıfırlama) çalışır.
    /// Düzelince oturum dinlemeye döner; telefonda bekleyen çekim varsa önce o gönderilir (bkz. `beginListening`).
    func repairInternetAfterCamera(_ text: String) async {
        guard await speakNotice(text) else { return }
        await runRecovery(.network, force: true)
    }

    // MARK: Bekleyen çekimler

    /// Çekime Ayarlar'daki talimat ve kalite eklenir; video gönderilmeyecekse dosyası hemen silinir
    func shapedShot(_ taken: CapturedQuestion, isPassage: Bool) -> CapturedQuestion {
        var shot = taken
        if !isPassage { shot.extraInstruction = cameraSettings.videoQuestion.trimmed }   // ek talimat soruya yöneliktir, paragrafa değil
        shot.highResolution = cameraSettings.videoHighRes
        if !cameraSettings.videoToGemini {
            shot.discard()
            shot.video = nil
            shot.videoBytes = 0
        }
        return shot
    }

    /// Çekim, kesinti (kulaklık, arama, onarım) anında bitti: klasöre yazılır. Soru çekimi bekleyenlere eklenir ve onarımdan sonra gönderilir;
    /// paragraf çekimi Paragraf klasöründe durur (taslağı yoktur: kullanıcı paragrafı yeniden çeker). Klasöre yazılamazsa eskisi gibi silinir.
    func saveInterruptedShot(_ taken: CapturedQuestion) {
        let isPassage = deps.camera.subject == .passage
        let shot = deps.captureStore.keep(shapedShot(taken, isPassage: isPassage), kind: isPassage ? .passage : .question)
        guard shot.archived else {
            shot.discard()
            return
        }
        if !isPassage { keepPending(shot) }
        tlog("[kamera] kesinti anında biten çekim klasöre yazıldı\(isPassage ? " (ortak paragraf)" : "; onarımdan sonra gönderilecek")")
    }

    /// Çekim gönderilene kadar bekleyenler listesinde tutulur (dosyaları kalıcı klasörde durur). Sayı sınırı YOK: hiçbir çekim, yenisi için
    /// yer açılsın diye silinmez.
    func keepPending(_ shot: CapturedQuestion) {
        if !pendingShots.contains(shot) { pendingShots.append(shot) }
    }

    /// Önceki çalışmalardan kalan, gönderilmemiş çekimler telefondaki klasörden geri yüklenir (en eskisi önce). Disk gerçektir: klasörden
    /// silinmiş çekim listeden de düşer; kalıcı klasöre yazılamamış (geçici) çekimler kullanılmaz.
    func restorePendingShots() {
        let stored = deps.captureStore.restorePending()
        for shot in pendingShots where !stored.contains(shot) { shot.discard() }
        pendingShots = stored
        retriedShots.removeAll()
        if !stored.isEmpty { tlog("[kamera] telefondaki klasörden \(stored.count) bekleyen çekim geri yüklendi; sırayla gönderilecek") }
    }

    /// Test bitti: gönderilemeyen çekimler SİLİNMEZ. Telefondaki klasörde durur ve bir sonraki testte (internet varsa) sırayla gönderilir;
    /// ekranda kaç sorunun cevapsız kaldığı yazılır. Yalnız kalıcı klasöre yazılamamış (geçici) çekimler kaybolur: geçici video dosyaları
    /// bir sonraki açılışta silinir ve çekim yeniden yüklenemez; bu da söylenir.
    func noteUnsentShots() {
        retriedShots.removeAll()
        sendFailures.removeAll()
        let unsaved = pendingShots.filter { !$0.archived }
        for shot in unsaved { shot.discard() }
        pendingShots.removeAll { !$0.archived }
        if !pendingShots.isEmpty {
            statusNote += " Uyarı: çekilen \(pendingShots.count) soru Gemini'ye gönderilemedi, cevabı yok. Telefonda Cekimler klasöründe duruyor, silinmez; sonraki testte sırayla gönderilir."
            tlog("[kamera] test bitti; gönderilemeyen \(pendingShots.count) çekilmiş soru telefondaki klasörde kaldı")
        }
        if !unsaved.isEmpty {
            statusNote += " Uyarı: \(unsaved.count) çekilmiş soru telefona kaydedilemediği için gönderilemedi ve kayboldu."
            tlog("[kamera] test bitti; klasöre yazılamayan \(unsaved.count) çekim gönderilemedi")
        }
    }

    /// Çekim Gemini'ye gitti ve cevap geldi: bekleyenlerden çıkar, klasörde "Gönderilen"e taşınır (silinmez; cevap yanına yazılır)
    func completePending(_ shot: CapturedQuestion, answer: String) {
        pendingShots.removeAll { $0 == shot }
        sendFailures[shot.id] = nil
        deps.captureStore.markSent(shot, answer: answer)
        shot.discard()   // yalnız kalıcı klasöre yazılamamış (geçici) çekimin videosunu siler
    }

    /// Çekim gönderilemez (Gemini reddetti, fazla büyük): bekleyenlerden çıkar, klasörde "Gönderilemeyen"e taşınır. Silinmez.
    func shelvePending(_ shot: CapturedQuestion, reason: String) {
        pendingShots.removeAll { $0 == shot }
        retriedShots.remove(shot.id)
        sendFailures[shot.id] = nil
        deps.captureStore.markUnsendable(shot, reason: reason)
        shot.discard()
    }

    // MARK: Bağlantı geçişi

    /// Kestirme: Wi-Fi bırakılır, hücresel açılır; internet gelene kadar beklenir. İkinci kez denenir. İnternet geldi mi.
    func returnToInternet(shortcut: String) async -> Bool {
        // "Wi-Fi'de kal": telefon kameranın ağında kalır, internet hücreselden gelir. İnternet varsa hiçbir kestirme çalışmaz;
        // yoksa hücresel kestirmesi (yalnız hücreseli yenileyen, Wi-Fi'ye dokunmayan) çalışır
        if cameraSettings.stayOnWifi {
            if await waitForInternet(seconds: Timing.stayInternetCheck) {
                tlog("[kamera] Wi-Fi'de kal: internet var, kestirme çalıştırılmadı")
                return true
            }
            guard !Task.isCancelled else { return false }
            tlog("[kamera] Wi-Fi'de kal: internet yok; hücresel kestirmesi çalıştırılıyor: “\(shortcut)”")
        }
        // SIM kart yok: hücresel kestirme internet getirmez, yalnız Wi-Fi'yi kapatır (telefonda başka internet yolu kalmaz). Çalıştırılmaz;
        // internet yalnız telefonun başka bir Wi-Fi ağına geçmesiyle gelebilir, kısa süre beklenip sonuç bildirilir.
        if !deps.health.hasCellularService() {
            tlog("[kamera] telefonda SIM kart yok: “\(shortcut)” çalıştırılmadı (Wi-Fi'yi kapatır, internet getirmez)")
            return await waitForInternet(seconds: Timing.stayInternetCheck)
        }
        for attempt in 1...Timing.cameraInternetTries {
            let outcome = await runShortcutRetryingTransient(name: shortcut)
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
        // SIM kart yok: internet kestirmeyle gelmez; her soru sınırında boşuna beklenmez (bkz. `offlineCapture`)
        if offlineCapture { return }
        if await deps.health.internetReachable() {
            networkMayBeOnCamera = false
            return
        }
        let name = settings.internetShortcut.trimmed
        guard !name.isEmpty else { return }
        tlog("[kamera] önceki kamera akışı yarıda kaldı ve internet yok; “\(name)” kestirmesi çalıştırılıyor")
        statusNote = internetNote
        if await returnToInternet(shortcut: name) { networkMayBeOnCamera = false }
        statusNote = ""
    }

    /// Test kamera akışı sürerken bitti: telefonun interneti kestirmeyle geri getirilir (yoksa kameranın Wi-Fi'sinde, hücresel kapalı kalırdı)
    func restoreInternetAfterCamera() {
        networkMayBeOnCamera = false
        let name = settings.internetShortcut.trimmed
        guard !name.isEmpty else { return }
        guard deps.health.hasCellularService() else {
            tlog("[kamera] test kamera akışı sürerken bitti; telefonda SIM kart yok, internet kestirmesi “\(name)” çalıştırılmadı")
            return
        }
        tlog("[kamera] test kamera akışı sürerken bitti; internet kestirmesi çalıştırılıyor: “\(name)”")
        work = Task { [weak self] in
            guard let self = self else { return }
            // "Wi-Fi'de kal": telefon kameranın ağında kalır; internet varsa kestirme gerekmez
            if self.cameraSettings.stayOnWifi, await self.deps.health.internetReachable() { return }
            _ = await self.deps.shortcuts.run(name: name)
        }
    }

    func waitForInternet(seconds: TimeInterval) async -> Bool {
        var waited: TimeInterval = 0
        while !Task.isCancelled {
            if await deps.health.internetReachable() { return true }
            if waited >= seconds {
                // Neden internet yok: telefonun Wi-Fi adresi hâlâ varsa kestirme Wi-Fi'yi kapatmamıştır; yoklamanın hata kodu (-1009 = bağlantı yok, -1001 = zaman aşımı)
                let wifi = LocalNetwork.wifi().map { LocalNetwork.string($0.ip) } ?? "yok"
                let probe = InternetProbe.lastFailure
                tlog("[kamera] internet gelmedi (\(Int(waited)) sn beklendi): telefon Wi-Fi adresi \(wifi); yoklama: \(probe.isEmpty ? "ayrıntı yok" : probe)")
                return false
            }
            await deps.sleep(2)
            waited += 2
        }
        return false
    }

    // MARK: Yardımcılar

    /// İnternete dönüş sürerken ekranda ve boşluk bilgisinde görünen not ("İnternete geçiliyor" sesli bilgiyi de tetikler)
    var internetNote: String {
        return cameraSettings.stayOnWifi ? "İnternete geçiliyor (hücresel kontrol ediliyor)" : "İnternete geçiliyor (Wi-Fi bırakılıyor)"
    }

    /// Çekim sürerken kamera programının yönlendirme cümleleri: ayrı bir cümle sürüyorsa yenisi atlanır (art arda üst üste binmesin)
    func sayGuidance(_ text: String) {
        guard cameraBusy, !cameraGuidanceSpeaking else { return }
        cameraGuidanceSpeaking = true
        Task { [weak self] in
            guard let self = self else { return }
            _ = try? await self.deps.speaker.speak(text, saveAs: nil)
            self.quietTicks = 0
            self.cameraGuidanceSpeaking = false
        }
    }

    /// Sıralı cümle (çekim öncesi duyuru): önceki yönlendirme cümlesi bitince söylenir ve bu cümle bitince döner (`sayGuidance` gibi atlanmaz)
    func sayGuidanceAndWait(_ text: String) async {
        var waited = 0
        while cameraGuidanceSpeaking, waited < 25, !Task.isCancelled {
            await deps.sleep(0.2)
            waited += 1
        }
        guard cameraBusy, !Task.isCancelled else { return }
        cameraGuidanceSpeaking = true
        _ = try? await deps.speaker.speak(text, saveAs: nil)
        quietTicks = 0
        cameraGuidanceSpeaking = false
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
