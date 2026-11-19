import Foundation

/// Otomatik zamanlı başlatma (kullanıcı kararı 2026-11-19; saf mantık ve sabitler `AutoStart` içinde).
///
/// Akış: "Başlat" → açılış denetimi → `askCameraChoice` → `autoAnnounce`. İlk taramada kamera açılış saati gelmediyse saat söylenir ve "Başla" dinlenir;
/// kapı (`autoTick`, saniyede bir) saati bekler. Saat gelince `autoOpenCamera`: "Kamera açılıyor.", kameraya geçilir, "Kameranın başlaması için lütfen
/// N. soruyu okutunuz." denir ve yine "Başla" dinlenir. Kapı bu sırada kameraya bakar (`autoLook`): beklenen SORU görülürse beşten, en geç başlama anı
/// gelirse on beşten sayılır ve `runPageSeries` çalışır (kamera hazır olduğu için "Başladı." denip süre hemen başlar). "Başla" / "Başlat" her an geçerlidir
/// (`fireCameraChoice`); tetikler birbirini iptal eder. Bir kez tetiklendikten sonra taramalar sırayla sürer: cevaplar okununca kamera açılır, "Yeni iki
/// sayfalık tarama 15 saniye sonra başlayacak." denir, son 5 saniyede beşten sayılır ve tarama başlar (soru görülmesi beklenmez). Ayarlardaki soru sayısı
/// tamamlanınca bütün cevaplar baştan, 2 sn arayla okunur ve sınav kapanır (`autoFinishExam`). Soru sayısı girilmemişse ve Gemini taramada soru bulamazsa
/// art arda iki tarama boş çıkarsa sınav kendiliğinden kapanır (`noteEmptyScan`, `autoFinishExam`). Program hiçbir adımda sesli komut İSTEMEZ:
/// başlangıçta "önceki kayıttan devam mı" sorulmaz (yeni sınav açılır), çekim olmazsa sesle okumaya geçilmez (yeniden denenir).
///
/// Kapı yalnız "Başla" dinlenirken (aşama dinleme, kip kamera seçimi) iş yapar; onarım, duraklatma ya da başka bir iş araya girerse zamanlayıcı düşer ve
/// akış yeniden `beginListening(mode: .cameraChoice)` çağırınca kendiliğinden kurulur.
extension SessionViewModel {
    /// Otomatik zamanlı başlatma geçerli mi: toplu çekim ve ayar açık, kamera kullanılabilir
    var autoMode: Bool {
        return cameraSettings.autoStart && seriesMode && settings.examType != .voice
    }

    /// Mikrofon zorunlu değil: kulaklık mikrofonu kipinde ve otomatik başlatmada "Başla" beklenirken mikrofon çalışmasa da akış sürer
    var micOptional: Bool {
        return AudioRouting.headsetMicMode && autoMode && listenMode == .cameraChoice
    }

    /// Bu oturumda cevabı alınmış soru numaraları
    var answeredNumbers: Set<Int> {
        return Set(answers.map { $0.number })
    }

    /// Taramayı başlatacak (kulaklıktan istenen) soru: başlangıç sorusundan itibaren cevabı alınmamış en küçük numara. `orLater`: cevaplanmış soru varsa
    /// daha ilerideki cevapsız bir soru da taramayı başlatır
    var autoTarget: (number: Int, orLater: Bool) {
        let answered = answeredNumbers
        return (AutoStart.nextMissing(first: cameraSettings.autoFirstNumber, answered: answered), !answered.isEmpty)
    }

    // MARK: Duyuru ve bekleme

    /// Ayarlardaki soru sayısına ulaşıldı (kullanıcı kararı 2026-11-19): yeni tarama istenmez. Bütün cevaplar baştan, sırayla, aralarında 2 sn boşlukla
    /// okunur (her cevap: soru numarası, şehir kodlu şık, doğru cevabın metni) ve sınav kapanır; "Devam, Tekrar ya da Bitir" sorulmaz.
    func autoFinishExam() async {
        tlog("[otomatik] soru sayısına ulaşıldı (\(cameraSettings.autoQuestionCount) soru, cevaplanan \(answeredNumbers.count)): cevaplar baştan okunacak ve sınav kapanacak")
        disarmAutoGate()
        endScope = .test
        auto.finishing = true
        await beginReview(origin: .endRequest, returnTo: .question)
    }

    /// `askCameraChoice` sonunda, "Başla" talimatı yerine çağrılır
    func autoAnnounce() async {
        if AutoStart.examComplete(count: cameraSettings.autoQuestionCount, nextMissing: autoTarget.number) {
            await autoFinishExam()
            return
        }
        // Yeni cevap geldiyse boş tarama sayımı sıfırlanır; art arda boş taramalar sınırı aştıysa sınav kendiliğinden kapanır (sesli komut istenmez)
        if answers.count != auto.answersSeen {
            auto.answersSeen = answers.count
            auto.emptyScans = 0
        }
        let limit = AutoStart.emptyScanLimit(count: cameraSettings.autoQuestionCount)
        if auto.emptyScans >= limit {
            tlog("[otomatik] art arda \(auto.emptyScans) taramada soru bulunamadı: sınav kapatılıyor")
            guard await speakNotice(Say.autoEmptyStop(scans: auto.emptyScans)) else {
                offerCamera = true
                return
            }
            await autoFinishExam()
            return
        }
        // Kamera zaten açık bekliyorsa (kesintiden dönüş) soru yeniden istenir
        if deps.camera.holding {
            await autoAskForQuestion()
            return
        }
        if auto.rounds == 0 {
            if !auto.planned {
                let now = deps.now()
                auto.planned = true
                auto.openAt = cameraSettings.autoOpenEnabled ? AutoStart.moment(minutes: cameraSettings.autoOpenMinutes, now: now) : nil
                auto.latestAt = cameraSettings.autoLatestEnabled ? AutoStart.moment(minutes: cameraSettings.autoLatestMinutes, now: now) : nil
                tlog("[otomatik] ilk tarama planı: kamera açılışı \(auto.openAt.map { AutoStart.clockText($0) } ?? "hemen"), en geç başlama \(auto.latestAt.map { AutoStart.clockText($0) } ?? "yok"), başlangıç sorusu \(cameraSettings.autoFirstNumber)")
            }
            if let openAt = auto.openAt, deps.now() < openAt {
                guard await speakNotice(Say.autoWaiting(clock: AutoStart.clockText(openAt))) else {
                    offerCamera = true
                    return
                }
                beginListening(mode: .cameraChoice)
                if phase == .listening { statusNote = "Kamera \(AutoStart.clockText(openAt)) saatinde açılacak" }
                return
            }
            await autoOpenCamera()
            return
        }
        await autoStartGap()
    }

    /// Sonraki taramalar (kullanıcı kararı 2026-11-19: Gemini'den gelen cevaplar okunduktan sonra 15 saniyelik süre başlar): boşluk HEMEN duyurulur, kamera
    /// bu süre içinde açılır. Kamera boşluğun son 5 saniyesinden önce hazır olursa kalan süre beklenir ("Başla" dinlenir, kapı geri sayımı başlatır);
    /// kameraya geçiş daha uzun sürdüyse hazır olur olmaz beşten sayılıp başlanır.
    func autoStartGap() async {
        let target = autoTarget
        auto.unreadSince = nil
        auto.missed = 0
        guard await speakNotice(Say.autoGap(seconds: AutoStart.gapSeconds, next: target.number)) else {
            offerCamera = true
            return
        }
        let started = deps.now()
        auto.promptedAt = started
        auto.latestAt = started.addingTimeInterval(TimeInterval(AutoStart.gapSeconds - AutoStart.questionCountdown))
        tlog("[otomatik] cevaplar okundu: yeni tarama \(AutoStart.gapSeconds) sn sonra başlayacak (sıradaki soru \(target.number)); kamera açılıyor")
        guard await prepareSeriesCamera() else { return }
        guard !Task.isCancelled, phase == .answering else {
            offerCamera = true
            return
        }
        let waited = deps.now().timeIntervalSince(started)
        if let due = auto.latestAt, deps.now() < due {
            beginListening(mode: .cameraChoice)
            if phase == .listening { statusNote = "Yeni tarama birazdan başlayacak" }
            return
        }
        tlog("[otomatik] kameraya geçiş \(Int(waited)) sn sürdü; boşluk doldu, geri sayım hemen başlıyor")
        await autoBegin(.gap)
    }

    /// Kamerayı açar (kestirme, bağlanma, görüntü) ve beklenen soruyu ister. Kameraya ulaşılamazsa nedeni `prepareSeriesCamera` söyler ve akışı o sürdürür.
    func autoOpenCamera() async {
        guard await speakNotice(Say.seriesConnecting) else {
            offerCamera = true
            return
        }
        guard await prepareSeriesCamera() else { return }
        guard !Task.isCancelled, phase == .answering else {
            offerCamera = true
            return
        }
        await autoAskForQuestion()
    }

    /// İlk taramada "Kameranın başlaması için lütfen N. soruyu okutunuz." der; kapı kameraya bakmaya başlar. Sonraki taramalarda soru beklenmez: "Yeni iki
    /// sayfalık tarama 15 saniye sonra başlayacak." denir, kapı son 5 saniyede geri sayımı başlatır. İki durumda da "Başla" dinlenir.
    func autoAskForQuestion() async {
        let target = autoTarget
        auto.promptedAt = nil
        auto.unreadSince = nil
        auto.missed = 0
        let later = auto.rounds > 0
        guard await speakNotice(later ? Say.autoGap(seconds: AutoStart.gapSeconds, next: target.number) : Say.autoShow(number: target.number)) else {
            offerCamera = true
            return
        }
        let now = deps.now()
        auto.promptedAt = now
        if later {
            auto.latestAt = now.addingTimeInterval(TimeInterval(AutoStart.gapSeconds - AutoStart.questionCountdown))
            tlog("[otomatik] yeni tarama \(AutoStart.gapSeconds) sn sonra başlayacak (sıradaki soru \(target.number))")
        } else {
            tlog("[otomatik] \(target.number). soru bekleniyor; en geç başlama \(auto.latestAt.map { AutoStart.clockText($0) } ?? "yok")")
        }
        beginListening(mode: .cameraChoice)
        if phase == .listening { statusNote = later ? "Yeni tarama birazdan başlayacak" : "\(target.number). sorunun okutulması bekleniyor" }
    }

    // MARK: Kapı

    /// "Başla" dinlemesi açılınca kurulur (`beginListening`); zaten kuruluysa dokunulmaz
    func armAutoGate() {
        guard autoMode, autoTimer == nil else { return }
        autoTimer = deps.scheduler.after(AutoStart.tick) { [weak self] in self?.autoTick() }
    }

    func disarmAutoGate() {
        autoTimer?.cancel()
        autoTimer = nil
    }

    /// Kapının nabzı: saat geldi mi, en geç başlama anı geçti mi, kamerada beklenen soru görünüyor mu
    func autoTick() {
        autoTimer = nil
        guard autoMode, phase == .listening, listenMode == .cameraChoice else { return }
        let now = deps.now()
        guard deps.camera.holding else {
            // Kamera kapalı: ilk taramada açılış saati beklenir
            if let openAt = auto.openAt, auto.rounds == 0, now < openAt {
                armAutoGate()
                return
            }
            fireAuto(.open)
            return
        }
        if auto.promptedAt == nil { auto.promptedAt = now }
        if auto.rounds > 0 {
            // Sonraki taramalar: soru beklenmez; boşluğun son 5 saniyesi gelince geri sayım başlar
            let due = auto.latestAt ?? (auto.promptedAt ?? now).addingTimeInterval(TimeInterval(AutoStart.gapSeconds - AutoStart.questionCountdown))
            if now >= due {
                fireAuto(.gap)
            } else {
                armAutoGate()
            }
            return
        }
        let floor = (auto.promptedAt ?? now).addingTimeInterval(AutoStart.minGap)
        if let latest = auto.latestAt, now >= max(latest, floor) {
            fireAuto(.deadline)
            return
        }
        if !auto.looking {
            auto.looking = true
            Task { @MainActor [weak self] in await self?.autoLook() }
        }
        armAutoGate()
    }

    /// Kameraya bir bakış: beklenen soru görünüyorsa tetik; soru yapısı görünüp numarası okunamıyorsa süre tutulur
    func autoLook() async {
        let sight = await deps.camera.spotQuestions()
        auto.looking = false
        guard autoMode, phase == .listening, listenMode == .cameraChoice, deps.camera.holding else { return }
        guard let seen = sight, seen.frames > 0 else { return }
        let target = autoTarget
        if let number = AutoStart.accepted(seen.numbers, ask: target.number, answered: answeredNumbers) {
            tlog("[otomatik] kamerada soru görüldü: \(seen.summary)")
            fireAuto(.question(number))
            return
        }
        let now = deps.now()
        if seen.looksLikeQuestion {
            auto.missed = 0
            if let since = auto.unreadSince {
                if now.timeIntervalSince(since) >= AutoStart.unreadSeconds {
                    tlog("[otomatik] soru yapısı \(Int(AutoStart.unreadSeconds)) sn'dir görünüyor ama \(target.number). soru okunamadı: \(seen.summary)")
                    fireAuto(.unreadable)
                }
            } else {
                auto.unreadSince = now
                tlog("[otomatik] soru yapısı görünüyor, beklenen numara okunamadı: \(seen.summary)")
            }
        } else {
            auto.missed += 1
            if auto.missed >= AutoStart.unreadResetLooks { auto.unreadSince = nil }
        }
    }

    /// Tetik çalıştı: dinleme kapanır ve iş ana göreve geçer (sesli "Başla" ile aynı düzen; bkz. `fireCameraChoice`)
    func fireAuto(_ trigger: AutoStart.Trigger) {
        guard phase == .listening, listenMode == .cameraChoice else { return }
        tlog("[otomatik] tetik: \(trigger.logName)")
        disarmAutoGate()
        clearWarning("duyulan")
        closeListening()
        listenMode = .question   // seçim yapıldı: bundan sonraki bir onarım akışı baştan (kamera sorusundan) kurar
        phase = .speaking
        cameraReminders = 0
        work = Task { [weak self] in
            guard let self = self else { return }
            if trigger == .open {
                await self.autoOpenCamera()
            } else {
                await self.autoBegin(trigger)
            }
        }
    }

    // MARK: Geri sayım ve başlama

    /// Geri sayım (saniyede bir sözcük). Dönen false: kesildi (süre başlamaz)
    func autoCountdown(from start: Int) async -> Bool {
        var number = start
        while number >= 1 {
            let started = deps.now()
            guard await speakNotice(Say.countWord(number), remember: false) else { return false }
            let rest = 1.0 - deps.now().timeIntervalSince(started)
            if rest > 0 { await deps.sleep(rest) }
            guard !Task.isCancelled else { return false }
            number -= 1
        }
        return true
    }

    /// Geri sayım sürerken soru hâlâ kadrajda mı: en çok üç bakış. Hiçbirinde soru yapısı görünmezse (en az iki bakış) false; görüntü okunamadıysa
    /// (bakış sonuçsuz) soru kaybolmuş sayılmaz.
    func autoStillThere() async -> Bool {
        var seen = 0
        var lost = 0
        for _ in 0..<3 {
            guard !Task.isCancelled, deps.camera.holding else { return true }
            guard let sight = await deps.camera.spotQuestions(), sight.frames > 0 else { continue }
            if !sight.numbers.isEmpty || sight.looksLikeQuestion { seen += 1 } else { lost += 1 }
        }
        return seen > 0 || lost < 2
    }

    /// Tetikten sonra: duyuru, geri sayım ve tarama. Soru geri sayımda kaybolursa süre başlamaz, soru yeniden beklenir.
    func autoBegin(_ trigger: AutoStart.Trigger) async {
        let target = autoTarget
        switch trigger {
        case .open:
            return
        case .question(let number):
            guard await speakNotice(Say.autoSeen(number: number), remember: false) else {
                offerCamera = true
                return
            }
            let watch = Task { @MainActor [weak self] () -> Bool in
                guard let self = self else { return true }
                return await self.autoStillThere()
            }
            guard await autoCountdown(from: AutoStart.questionCountdown) else {
                watch.cancel()
                offerCamera = true
                return
            }
            let still = await watch.value
            guard !Task.isCancelled, phase == .speaking else {
                offerCamera = true
                return
            }
            if !still {
                tlog("[otomatik] geri sayımda soru kadrajdan çıktı; süre başlamadı, soru yeniden bekleniyor")
                guard await speakNotice(Say.autoLost(number: number)) else {
                    offerCamera = true
                    return
                }
                auto.unreadSince = nil
                auto.missed = 0
                beginListening(mode: .cameraChoice)
                return
            }
        case .deadline:
            guard await speakNotice(Say.autoDeadline(number: target.number, seconds: AutoStart.deadlineCountdown)) else {
                offerCamera = true
                return
            }
            guard await autoCountdown(from: AutoStart.deadlineCountdown) else {
                offerCamera = true
                return
            }
        case .unreadable:
            guard await speakNotice(Say.autoUnread(number: target.number)) else {
                offerCamera = true
                return
            }
            guard await autoCountdown(from: AutoStart.questionCountdown) else {
                offerCamera = true
                return
            }
        case .gap:
            guard await autoCountdown(from: AutoStart.questionCountdown) else {
                offerCamera = true
                return
            }
        }
        guard !Task.isCancelled, phase == .speaking else {
            offerCamera = true
            return
        }
        await runPageSeries()
    }

    // MARK: Tur sayımı ve durma

    /// Tarama başladı (hangi tetikle olursa olsun): sonraki taramalar "sıradaki soru + süre" düzeniyle yürür
    func noteAutoRoundStarted() {
        auto.rounds += 1
        auto.promptedAt = nil
        auto.unreadSince = nil
        auto.missed = 0
        auto.latestAt = nil
        auto.openAt = nil
    }

    /// Gemini taramada soru bulamadı: sayılır. Sınır aşılınca (`AutoStart.emptyScanLimit`) bir sonraki adımda sınav kendiliğinden kapanır (`autoAnnounce`)
    func noteEmptyScan() {
        guard cameraSettings.autoStart, cameraSettings.pageSeries else { return }
        auto.emptyScans += 1
        tlog("[otomatik] taramada soru bulunamadı (art arda \(auto.emptyScans); sınır \(AutoStart.emptyScanLimit(count: cameraSettings.autoQuestionCount)))")
    }

    /// Mikrofon açılamadı ya da ses vermiyor ama zorunlu değil: bir kez yazılır, akış otomatik tetiklerle sürer
    func noteMicUnavailable(_ reason: String) {
        guard !auto.micGivenUp else { return }
        auto.micGivenUp = true
        tlog("[otomatik] mikrofon kullanılamıyor (\(reason)); sesli komut yok, otomatik tetiklerle sürülüyor")
        warn("mikrofon", "Kulaklık mikrofonu çalışmıyor; sesli komut verilemez. Tarama saatle ve soru görülünce kendiliğinden başlar.")
    }
}
