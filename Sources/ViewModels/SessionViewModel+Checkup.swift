import Foundation

/// Modül 1: açılış donanım kontrolü (izinler, kulaklık, mikrofon, internet, Gemini) ve "Ben hazırım" anonsu
extension SessionViewModel {
    func runStartup() async {
        deps.library.prepare()
        checkSystemAtStart()
        do {
            // Beklenmedik kapanmadan sonra aynı klasöre ve numaraya devam edilir (cevaplar ikiye bölünmesin, soru_N ezilmesin)
            choiceOffer = nil
            if let name = resume?.folder, let existing = deps.library.existingSessionFolder(named: name) {
                sessionFolder = existing
            } else if resume == nil, let remembered = rememberedSession() {
                // Önceki kayıt var (içinde cevap olan klasör): klasör ve numara geçici olarak onunki sayılır, kontrol bitince sesli sorulur:
                // "önceki kayıttan devam mı, yeni sınav mı?". Seçilene kadar klasöre hiçbir şey yazılmaz.
                sessionFolder = remembered.folder
                nextNumber = remembered.next
                choiceOffer = ChoiceOffer(answers: remembered.count, next: remembered.next, recent: remembered.recent)
            } else {
                sessionFolder = try deps.library.newSessionFolder(for: deps.now())
            }
            if let folder = sessionFolder { deps.journal.saveFolder(folder.lastPathComponent) }
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

        // 3) İnternet (yoksa Kestirmelerle onarılır)
        var internetOK = await deps.health.internetReachable()
        guard !Task.isCancelled else { return }
        if !internetOK {
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
        setCheck("internet", "İnternet", ok: internetOK, detail: "var")

        // 4) Gemini: ulaşılıyor mu, anahtar kabul ediliyor mu
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

        // 5) Hepsi tamam: anons ve dinleme. Anons yarıda kesilirse (kulaklık koptu) açılış kontrolü yol dönünce baştan yapılır
        clearWarning("start")
        pendingStart = true
        if let resumed = resume {
            // Beklenmedik kapanmadan sonra yeniden açıldık: ne olduğu söylenir, yarım kalan soru tamamlanır. Anons yarıda kesilirse
            // (kulaklık koptu) `resume` durur ve kontrol yol dönünce baştan yapılır.
            var notice = Say.resumed(cause: resumed.cause, downSeconds: resumed.downSeconds, pending: resumed.pending)
            if let context = passage, !context.remaining.isEmpty { notice += " " + Say.resumedPassage(context.remaining) }
            guard await speakNotice(notice) else { return }
            pendingStart = false
            resume = nil
            if let pending = resumed.pending {
                await resumePending(pending)
            } else {
                beginListening()
            }
            return
        }
        if let offer = choiceOffer {
            guard await speakNotice(Say.readyAskContinue(answers: offer.answers, next: offer.next)) else { return }
            pendingStart = false
            beginListening(mode: .startChoice)
            return
        }
        guard await speakNotice(Say.ready) else { return }
        pendingStart = false
        beginListening()
    }

    /// Hatırlanan önceki oturum: klasör hâlâ varsa ve içinde cevap dosyası varsa (klasör, sıradaki numara, cevap sayısı, yeni mi);
    /// aksi hâlde nil. Numara, defterdeki ile klasördeki en büyük soru numarasının bir fazlasından büyük olanıdır.
    func rememberedSession() -> (folder: URL, next: Int, count: Int, recent: Bool)? {
        guard let carry = carry, let url = deps.library.existingSessionFolder(named: carry.folder) else { return nil }
        // Hem ses dosyalarına (soru_N) hem düz yazıdaki (cevaplar.txt) satırlara bakılır: biri eksik olsa da kayıt hatırlanır
        var numbers = Set<Int>()
        for file in deps.library.answerFiles(in: url) {
            if let number = AnswerLibrary.questionNumber(fromFileName: file.lastPathComponent) { numbers.insert(number) }
        }
        for record in deps.library.transcriptRecords(in: url) { numbers.insert(record.number) }
        guard !numbers.isEmpty else { return nil }
        let recent = deps.now().timeIntervalSince(carry.at) <= Timing.rememberWindow
        return (url, max(carry.nextNumber, (numbers.max() ?? 0) + 1), numbers.count, recent)
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
