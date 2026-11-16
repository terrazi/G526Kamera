import Foundation

/// Modül 1: açılış donanım kontrolü (izinler, kulaklık, mikrofon, internet, Gemini) ve "Ben hazırım" anonsu
extension SessionViewModel {
    func runStartup() async {
        deps.library.prepare()
        checkSystemAtStart()
        sectionPlan = settings.sectionPlan   // sınav boyunca bu oturumun başındaki ayar geçerlidir
        // Sürüm 4: "Başlat"a basılınca kameraya HEMEN bağlanılır (kulaklık ve mikrofon beklenmeden; görüntü ana ekranda akar). İnternete geçmeden önce kapanır (2b).
        guard await connectCameraAtStart() else { return }
        do {
            // Beklenmedik kapanmadan sonra aynı klasöre ve numaraya devam edilir (cevaplar ikiye bölünmesin, soru_N ezilmesin)
            choiceOffer = nil
            if let name = resume?.folder, let existing = deps.library.existingLocation(named: name) {
                try place(exam: existing.exam, section: existing.section)
            } else if resume == nil, let remembered = rememberedSession() {
                // Önceki kayıt var (içinde cevap olan klasör): klasör ve numara geçici olarak onunki sayılır, kontrol bitince sesli sorulur:
                // "önceki kayıttan devam mı, yeni sınav mı?". Seçilene kadar klasöre hiçbir şey yazılmaz.
                try place(exam: remembered.exam, section: remembered.section)
                nextNumber = remembered.next
                choiceOffer = ChoiceOffer(answers: remembered.count, next: remembered.next, recent: remembered.recent)
            } else {
                // Her sınav oturumu kendi klasörünü alır (adı o anın tarihi ve saati); bölüm ayarlıysa 1. bölümle başlanır
                let exam = try deps.library.newSessionFolder(for: deps.now())
                try place(exam: exam, section: sectionPlan.isEmpty ? 0 : 1)
            }
            saveLocation()
            if let resume = resume {
                var onDisk = 0
                if let folder = sessionFolder {
                    for file in deps.library.answerFiles(in: folder) {
                        onDisk = max(onDisk, AnswerLibrary.questionNumber(fromFileName: file.lastPathComponent) ?? 0)
                    }
                }
                nextNumber = max(nextNumber, resume.nextNumber, onDisk + 1)
            }
        } catch {
            await failStart("Cevap klasörü açılamadı: \(error.localizedDescription)")
            return
        }
        // Kayıt klasörü seçilmemiş / erişilemiyorsa oturum yine başlar (cevaplar uygulamanın kendi klasörüne gider) ama kırmızı kutuda uyarılır
        let folderWarning = deps.library.warning
        setCheck("klasor", "Kayıt klasörü", ok: folderWarning == nil, detail: folderWarning == nil ? "seçili, yazılabiliyor" : "seçilmemiş ya da erişilemiyor")
        if let text = folderWarning { warn("klasor", text) } else { clearWarning("klasor") }

        // 1) İzinler ve çevrimdışı dikte
        let permission = await deps.permissions.request()
        guard !Task.isCancelled else { return }
        let granted = permission.microphone && permission.speech
        setCheck("izin", "Mikrofon ve konuşma tanıma izni", ok: granted, detail: granted ? "var" : "verilmemiş")
        guard granted else { await failStart(Say.permissionDenied); return }
        setCheck("dikte", "Çevrimdışı Türkçe dikte", ok: permission.onDeviceSpeech, detail: permission.onDeviceSpeech ? "yüklü" : "yüklü değil")
        guard permission.onDeviceSpeech else { await failStart(Say.noOnDevice); return }
        // İngilizce yardımcı dikte: yoksa oturum yine başlar (İngilizce sorular yalnız ses kaydından çözülür), kırmızı kutuda uyarılır
        if settings.englishDictation {
            setCheck("ingilizce", "Çevrimdışı İngilizce dikte (yardımcı)", ok: permission.englishOnDevice,
                     detail: permission.englishOnDevice ? "yüklü" : "yüklü değil")
            if permission.englishOnDevice { clearWarning("ingilizce") } else { warn("ingilizce", Say.noEnglishDictation) }
        } else {
            clearWarning("ingilizce")
        }

        // 2) Ses yolu: Bluetooth kulaklık (çıkış) ve harici yaka mikrofonu (giriş)
        do {
            try deps.route.configure()
        } catch {
            await failStart("Ses oturumu açılamadı: \(error.localizedDescription)")
            return
        }
        deps.route.preferExternalInput()
        var verdict = await settledRoute().verdict
        // Ses iPhone'da kaldıysa ("Bluetooth music" seçili değil) ve kestirme tanımlıysa önce çıkış kulaklığa alınır
        if !verdict.headphonesOK, let fixed = await switchOutputToHeadphones() { verdict = fixed }
        guard !Task.isCancelled else { return }
        routeVerdict = verdict
        refreshInputs()
        setCheck("kulaklik", "Bluetooth kulaklık", ok: verdict.headphonesOK, detail: verdict.headphonesOK ? "bağlı" : verdict.hint)
        setCheck("mikrofon", "Yaka mikrofonu", ok: verdict.micOK, detail: verdict.micOK ? "bağlı" : "Lightning girişindeki mikrofon alıcısı görünmüyor")
        guard verdict.isSafe else {
            // Sessizce bekle: ses yolu düzelince kontrol baştan yapılır
            pendingStart = true
            enterHardwarePause(verdict)
            return
        }
        clearWarning("donanim")
        applyVolume(deps.system.snapshot().outputVolume)   // ses oturumu açıldı: cevapları duyabilecek miyiz

        // 2b) Sürüm 4: kameranın uyarıları ve "Kamera bağlandı" söylenir; kamera bağlantısı ilk hücresel bağlantıdan önce kapanır ve internete geçilir.
        // Kesilirse (kulaklık, arama) açılış kontrolü yol dönünce baştan yapılır.
        guard await finishCameraStart() else { return }

        // 3) İnternet (yoksa Kestirmelerle onarılır)
        var internetOK = await deps.health.internetReachable()
        guard !Task.isCancelled else { return }
        var offlineStart = false
        if !internetOK {
            // SIM kart yoksa hücresel Kestirme internet getirmez: boş yere onarım döngüsüne girilmez.
            // Kamera akışı açıksa sınav çevrimdışı sürer (çekimler telefonda birikir, internet gelince gönderilir); değilse nedeni söyle ve dur
            if !deps.health.hasCellularService() {
                if cameraOfferAvailable {
                    tlog("[açılış] internet yok ve telefonda SIM kart yok: çevrimdışı çekim kipinde sürülüyor (çekimler telefonda birikecek)")
                    setCheck("internet", "İnternet", ok: false, detail: "yok; SIM kart yok, çekimler telefonda birikecek")
                    offlineStart = true
                    offlineHeld = true
                } else {
                    tlog("[açılış] internet yok ve telefonda SIM kart yok: onarım Kestirmeleri çalıştırılmadı")
                    setCheck("internet", "İnternet", ok: false, detail: "yok; telefonda SIM kart yok")
                    await failStart(Say.noSimNoInternet)
                    return
                }
            }
        }
        if !internetOK, !offlineStart {
            setCheck("internet", "İnternet", ok: false, detail: "yok; Kestirmelerle düzeltiliyor")
            let result = await performRecovery(.network)
            guard !Task.isCancelled, case .recovering = phase else { return }
            if case .recovered = result {
                internetOK = true
                phase = .checking
            } else {
                await failStart(result == .notConfigured ? Say.notConfigured : "İnternet kurulamadı.")
                return
            }
        }
        if !offlineStart {
            setCheck("internet", "İnternet", ok: internetOK, detail: "var")

            // 4) Gemini: ulaşılıyor mu, anahtar kabul ediliyor mu (çevrimdışı çekim kipinde internet gelince sınanır)
            let gemini = await checkGemini()
            guard !Task.isCancelled else { return }
            switch gemini {
            case .ok:
                setCheck("gemini", "Gemini", ok: true, detail: "anahtar kabul edildi")
            case .keyRejected(let message):
                setCheck("gemini", "Gemini", ok: false, detail: message)
                await failStart(message)
                return
            case .unreachable(let message):
                setCheck("gemini", "Gemini", ok: false, detail: message)
                await failStart("Gemini'ye ulaşılamadı: \(message)")
                return
            }
        }

        // Kamera: soru açıksa ayarların tamam olduğu görünür (eksikse sorular sesle okunur ve bu başta söylenir)
        if settings.askCamera {
            setCheck("kamera", "Kamera ayarları", ok: cameraConfigured,
                     detail: cameraConfigured ? "kamera adı ve kestirmeler yazılı" : "eksik; sorular sesle okunacak")
        }

        // 5) Hepsi tamam: anons ve dinleme. Anons yarıda kesilirse (kulaklık koptu) açılış kontrolü yol dönünce baştan yapılır
        clearWarning("start")
        pendingStart = true
        if let resumed = resume {
            // Beklenmedik kapanmadan sonra yeniden açıldık: ne olduğu söylenir, yarım kalan soru tamamlanır. Anons yarıda kesilirse
            // (kulaklık koptu) `resume` durur ve kontrol yol dönünce baştan yapılır.
            var notice = Say.resumed(cause: resumed.cause, downSeconds: resumed.downSeconds, pending: resumed.pending, camera: cameraOfferAvailable)
            if sectionIndex > 0 { notice += " " + Say.sectionHere(sectionIndex, questions: sectionQuestionCount) }
            if let context = passage, !context.remaining.isEmpty { notice += " " + Say.resumedPassage(context.remaining, photo: context.viaCamera) }
            guard await speakNotice(notice) else { return }
            pendingStart = false
            resume = nil
            if let pending = resumed.pending {
                await resumePending(pending)
            } else {
                armCameraOffer()   // Sürüm 4: yarım soru yoksa sıradaki soru için kamera sorulur
                beginListening()
            }
            return
        }
        if let offer = choiceOffer {
            let askContinue = sectionIndex > 0 ? Say.readyAskContinueSection(section: sectionIndex, answers: offer.answers, next: offer.next)
                                                : Say.readyAskContinue(answers: offer.answers, next: offer.next)
            guard await speakNotice(askContinue) else { return }
            pendingStart = false
            beginListening(mode: .startChoice)
            return
        }
        // Kameraya oturum başında ulaşılamadıysa bu söylenir (kamera ayarları eksik değil, kamera kapalı); sorular sesle okunur
        let cameraDownAtStart = settings.askCamera && cameraConfigured && cameraDownSince != nil
        var ready = cameraDownAtStart ? Say.readyCameraDown(minutes: AppSettings.clampCameraCheckMinutes(settings.cameraCheckMinutes))
            : (cameraOfferAvailable ? Say.readyCamera : (settings.askCamera ? Say.readyCameraMissing : Say.ready))
        if offlineStart { ready = Say.offlineCaptureStart + " " + ready }
        // Bölümlü sınavda başlarken hangi bölümde olunduğu söylenir ("Birinci bölüme başlıyorum. Bu bölümde 40 soru var.")
        guard await speakNotice(sectionIndex > 0 ? ready + " " + Say.sectionStart(sectionIndex, questions: sectionQuestionCount) : ready) else { return }
        pendingStart = false
        armCameraOffer()   // Sürüm 4: ilk soru için de kamera sorulur
        beginListening()
    }

    /// Hatırlanan önceki oturum: sınav klasörü hâlâ varsa ve içinde cevap varsa (sınav klasörü, bölüm sırası (0: bölümsüz), cevapların yazıldığı
    /// klasör, o klasörün sıradaki numarası, o klasördeki cevap sayısı, yeni mi); aksi hâlde nil. Numara, defterdeki ile klasördeki en büyük
    /// soru numarasının bir fazlasından büyük olanıdır. Bölümlü sınavda sayı ve numara şu anki bölümündür.
    func rememberedSession() -> (exam: URL, section: Int, folder: URL, next: Int, count: Int, recent: Bool)? {
        guard let carry = carry, let location = deps.library.existingLocation(named: carry.folder) else { return nil }
        let url = location.section > 0 ? deps.library.existingSectionFolder(in: location.exam, section: location.section) ?? location.exam : location.exam
        // Hem ses dosyalarına (soru_N) hem düz yazıdaki (cevaplar.txt) satırlara bakılır: biri eksik olsa da kayıt hatırlanır
        var numbers = Set<Int>()
        for file in deps.library.answerFiles(in: url) {
            if let number = AnswerLibrary.questionNumber(fromFileName: file.lastPathComponent) { numbers.insert(number) }
        }
        for record in deps.library.transcriptRecords(in: url) { numbers.insert(record.number) }
        // Yeni açılmış (henüz cevapsız) bölümde de önceki bölümlerin cevapları sınavı hatırlanır kılar
        guard !numbers.isEmpty || deps.library.examAnswerCount(exam: location.exam) > 0 else { return nil }
        let recent = deps.now().timeIntervalSince(carry.at) <= Timing.rememberWindow
        return (location.exam, location.section, url, max(carry.nextNumber, (numbers.max() ?? 0) + 1), numbers.count, recent)
    }

    /// Açılış kontrolü başarısız: sebep kırmızı kutuya yazılır, kulaklık varsa söylenir, oturum başlamaz
    /// Anahtarı dolu profilleri sırayla yoklar; biri kabul edilirse Gemini hazırdır. Ondan önceki profillerin sorunu kırmızı kutuda yazılır
    /// (soru yine de ilk sağlam profile gider). Hiç anahtar yoksa tek anahtarsız yoklama "anahtar girilmemiş" sonucunu verir.
    func checkGemini() async -> GeminiHealth {
        let profiles = settings.usableGeminiProfiles
        guard !profiles.isEmpty else { return await deps.health.gemini(key: "") }
        var problems: [String] = []
        var first: GeminiHealth?
        for profile in profiles {
            if Task.isCancelled { break }
            let result = await deps.health.gemini(key: profile.key)
            switch result {
            case .ok:
                if problems.isEmpty { clearWarning("anahtar") } else { warn("anahtar", problems.joined(separator: " ")) }
                return .ok
            case .keyRejected(let message):
                problems.append("\(profile.name): anahtar kabul edilmedi (\(message)).")
            case .unreachable(let message):
                problems.append("\(profile.name): Gemini'ye ulaşılamadı (\(message)).")
            }
            if first == nil { first = result }
        }
        return first ?? .unreachable("yanıt yok")
    }

    func failStart(_ message: String) async {
        warn("start", message)
        if AudioRouting.verdict(deps.route.snapshot()).headphonesOK {
            _ = await speakNotice("Kontrol başarısız. " + message)
        }
        guard !Task.isCancelled else { return }
        cancelTimers()
        clearWarning("donanim")
        deps.listener.pause()
        deps.network.stop()
        deps.screen.keepAwake(false)
        phase = .idle
    }
}
