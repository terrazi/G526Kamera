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

    /// Mikrofon zorunlu değil: otomatik başlatmada "Başla" beklenirken mikrofon çalışmasa da akış sürer
    var micOptional: Bool {
        return autoMode && listenMode == .cameraChoice
    }

    /// Taramalar sırayla mı yürüyor: bu oturumda en az bir tarama başladıysa ya da yarıda kalmış bir sınava devam ediliyorsa (kayıtlı cevap var).
    /// O zaman ilk tetik aranmaz (saat, soru görme); tarama 15 sn'lik boşluk ve geri sayımla başlar.
    var autoSequential: Bool {
        return auto.rounds > 0 || !answers.isEmpty
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

    /// Otomatik kapanışın esas aldığı soru sayısı (kullanıcı kararı 2026-11-26): bölümlü sınavda o anki bölümün Ayarlar > Sınav bölümleri'ndeki soru
    /// sayısı (her bölüm 1'den numaralanır; sayı girilmemişse 0: bölüm kendiliğinden tamamlanmaz), bölümsüz sınavda Video kaydı > "Sınavın soru sayısı"
    var autoQuestionTotal: Int {
        return sectionIndex > 0 ? sectionQuestionCount : cameraSettings.autoQuestionCount
    }

    /// Kulaklıktan istenen soru (kullanıcı kararı 2026-11-26): cevap yokken başlangıç sorusu, sonrasında sıradaki YENİ soru (cevabı alınmış en büyük
    /// numaranın bir fazlası). Eksik kalan soru istenmez, yalnız hatırlatılır; kullanıcı istediği soruyu istediği sırayla gösterebilir
    var autoAsked: Int {
        return AutoStart.nextNew(first: cameraSettings.autoFirstNumber, answered: answeredNumbers)
    }

    /// Art arda yeni cevap getirmeyen tarama sayısı (bkz. `AutoStart.State.roundsAtNew`)
    var autoStaleScans: Int {
        return max(0, auto.rounds - auto.roundsAtNew)
    }

    /// Son aşama mı: sona gelindi ama eksik soru var (bkz. `AutoStart.closing`)
    var autoClosing: Bool {
        return AutoStart.closing(count: autoQuestionTotal, first: cameraSettings.autoFirstNumber, answered: answeredNumbers, staleScans: autoStaleScans)
    }

    /// Eksik sorular: cevabı alınmış en büyük numaraya kadar aradaki boşluklar; son aşamada (`closing`) soru sayısına kadar cevapsız kalanların hepsi
    func autoMissingList(closing: Bool) -> [Int] {
        let total = autoQuestionTotal
        let answered = answeredNumbers
        let upTo = closing ? total : AutoStart.missingLimit(count: total, answered: answered)
        return AutoStart.missing(first: cameraSettings.autoFirstNumber, upTo: upTo, answered: answered)
    }

    var autoMissing: [Int] {
        return autoMissingList(closing: autoClosing)
    }

    // MARK: Duyuru ve bekleme

    /// Ayarlardaki soru sayısına ulaşıldı (kullanıcı kararı 2026-11-19): yeni tarama istenmez. Bütün cevaplar baştan, sırayla, aralarında 2 sn boşlukla
    /// okunur (her cevap: soru numarası, şehir kodlu şık, doğru cevabın metni) ve sınav kapanır; "Devam, Tekrar ya da Bitir" sorulmaz.
    /// `reachedEnd`: sona gelindi (bütün sorular cevaplandı ya da eksikler için verilen süre doldu); false: boş taramalar yüzünden kapanıyor.
    /// Bölümlü sınavda (kullanıcı kararı 2026-11-26) sona gelinen bölüm son bölüm değilse sınav KAPANMAZ: bölümün cevapları okunur ve sormadan sonraki
    /// bölüme geçilir (`completeSectionByVoice`); son bölümde sınav kapanır.
    func autoFinishExam(reachedEnd: Bool) async {
        let advance = reachedEnd && sectionIndex > 0 && sectionIndex < sectionPlan.count
        let missing = reachedEnd ? autoMissingList(closing: true) : []
        let what = advance ? "bölüm tamamlanıyor" : "sınav kapanıyor"
        let missingNote = missing.isEmpty ? "" : "; eksik: " + Say.compactList(missing)
        tlog("[otomatik] \(what) (soru sayısı \(autoQuestionTotal), cevaplanan \(answeredNumbers.count)\(missingNote)): cevaplar baştan okunacak")
        // Sona gelindiyse sınav TAMAMLANDI: bir sonraki "Başlat" yeni sınav açar. Boş taramalar yüzünden kapandıysa yarıda kalmıştır:
        // bir sonraki "Başlat" kaldığı yerden sürer. Sırada bölüm varsa sınav sürüyor: tamamlandı diye işaretlenmez
        if reachedEnd, !advance, let name = locationName {
            settings.finishedExamFolder = name
        }
        disarmAutoGate()
        auto.closingUntil = nil
        endScope = advance ? .section : .test
        auto.finishing = true
        auto.advancing = advance
        await beginReview(origin: .endRequest, returnTo: .question)
    }

    /// Yeni cevap geldiyse boş ve verimsiz tarama sayımları sıfırlanır (cevap sayısı değişmediyse dokunulmaz: aynı sorular yeniden cevaplanmış olabilir)
    func autoNoteProgress() {
        guard answers.count != auto.answersSeen else { return }
        auto.answersSeen = answers.count
        auto.emptyScans = 0
        auto.roundsAtNew = auto.rounds
    }

    /// Yeni bölüm kendiliğinden başlarken kapı sınavın başındaki gibi kurulur: yeni bölümün başlangıç sorusu kamerada görülünce (ya da "Başla" denince)
    /// tarama başlar. Saat tetikleri (açılış, en geç başlama) yalnız sınavın başı içindir; yeni bölümde beklenmez
    func autoResetForSection() {
        auto.rounds = 0
        auto.roundsAtNew = 0
        auto.emptyScans = 0
        auto.answersSeen = 0
        auto.planned = true
        auto.openAt = nil
        auto.latestAt = nil
        auto.promptedAt = nil
        auto.unreadSince = nil
        auto.missed = 0
        auto.closingUntil = nil
        auto.closingExpired = false
        auto.reminded = []
        auto.missingBefore = []
    }

    /// Sayfanın cevapları okunduktan sonra (kullanıcı kararı 2026-11-26): önceden eksik olup bu taramada cevabı gelen sorular bildirilir. Yoksa boş
    func autoCompletedNote() -> String {
        let before = auto.missingBefore
        auto.missingBefore = []
        guard !before.isEmpty else { return "" }
        let answered = answeredNumbers
        let done = before.filter { answered.contains($0) }
        guard !done.isEmpty else { return "" }
        autoNoteProgress()   // bu taramanın yeni cevapları sayıma girsin: son aşama kararı güncel duruma göre verilir
        let left = autoMissing
        auto.reminded = left   // kalanlar az önce söylendi: sıradaki tarama duyurusunda yeniden hatırlatılmaz
        let leftText = left.isEmpty ? "yok" : Say.compactList(left)
        tlog("[otomatik] eksik sorulardan tamamlananlar: \(Say.compactList(done)); kalan eksik: \(leftText)")
        return Say.autoCompleted(done, remaining: left)
    }

    /// Son aşama (kullanıcı kararı 2026-11-26): sona gelindi ama eksik soru var. Eksikler söylenir ve okutulmaları için `AutoStart.missingWindow` kadar
    /// süre verilir; sesli komut beklenmez. Kamera açılır ve kapı yalnız CEVAPSIZ bir soru görülünce taramayı başlatır (bu aşamada tarama kendiliğinden
    /// başlamaz). Tarama olursa cevaplar okunduktan sonra buraya yeniden gelinir ve süre baştan başlar; süre dolarsa bölüm / sınav tamamlanır.
    func autoStartClosing() async {
        let missing = autoMissingList(closing: true)
        auto.unreadSince = nil
        auto.missed = 0
        auto.closingUntil = nil
        auto.reminded = missing
        guard await speakNotice(Say.autoClosing(missing: missing, seconds: Int(AutoStart.missingWindow), section: sectionIndex > 0)) else {
            offerCamera = true
            return
        }
        tlog("[otomatik] son aşama: eksik sorular \(Say.compactList(missing)); okutulmaları için \(Int(AutoStart.missingWindow)) sn verildi")
        if !deps.camera.holding {
            guard await prepareSeriesCamera() else { return }
            guard !Task.isCancelled, phase == .answering else {
                offerCamera = true
                return
            }
        }
        let now = deps.now()
        auto.promptedAt = now
        auto.closingUntil = now.addingTimeInterval(AutoStart.missingWindow)
        beginListening(mode: .cameraChoice)
        if phase == .listening { statusNote = "Eksik sorular bekleniyor" }
    }

    /// `askCameraChoice` sonunda, "Başla" talimatı yerine çağrılır
    func autoAnnounce() async {
        let total = autoQuestionTotal
        if AutoStart.examComplete(count: total, nextMissing: autoTarget.number) {
            await autoFinishExam(reachedEnd: true)
            return
        }
        // Yeni cevap geldiyse boş tarama sayımı sıfırlanır; art arda boş taramalar sınırı aştıysa sınav kendiliğinden kapanır (sesli komut istenmez)
        autoNoteProgress()
        let limit = AutoStart.emptyScanLimit(count: total)
        if auto.emptyScans >= limit {
            tlog("[otomatik] art arda \(auto.emptyScans) taramada soru bulunamadı: sınav kapatılıyor")
            guard await speakNotice(Say.autoEmptyStop(scans: auto.emptyScans)) else {
                offerCamera = true
                return
            }
            await autoFinishExam(reachedEnd: false)
            return
        }
        // Son aşama (kullanıcı kararı 2026-11-26): sona gelindi ama eksik soru var. Eksikler söylenir ve okutulmaları için süre verilir; süre dolduysa
        // bölüm / sınav eksikleriyle tamamlanır
        if autoClosing {
            if auto.closingExpired {
                await autoFinishExam(reachedEnd: true)
            } else {
                await autoStartClosing()
            }
            return
        }
        // Kamera zaten açık bekliyorsa (kesintiden dönüş) soru yeniden istenir
        if deps.camera.holding {
            await autoAskForQuestion()
            return
        }
        if !autoSequential {
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
        let next = autoAsked
        auto.unreadSince = nil
        auto.missed = 0
        guard await speakNotice(autoGapSentence(next: next)) else {
            offerCamera = true
            return
        }
        let started = deps.now()
        auto.promptedAt = started
        auto.latestAt = started.addingTimeInterval(TimeInterval(AutoStart.gapSeconds - AutoStart.questionCountdown))
        tlog("[otomatik] cevaplar okundu: yeni tarama \(AutoStart.gapSeconds) sn sonra başlayacak (sıradaki yeni soru \(next)); kamera açılıyor")
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
    /// Sonraki tarama duyurusu (kullanıcı kararı 2026-11-26): sıradaki YENİ soru söylenir, eksik soru istenmez. Eksik listesi en son hatırlatılandan
    /// farklıysa bir kez hatırlatılır (her taramada yinelenmez)
    func autoGapSentence(next: Int) -> String {
        let missing = autoMissing
        let remind = missing != auto.reminded
        auto.reminded = missing
        if remind, !missing.isEmpty { tlog("[otomatik] eksik sorular hatırlatılıyor: \(Say.compactList(missing))") }
        return Say.autoGap(seconds: AutoStart.gapSeconds, next: next, missing: remind ? missing : [])
    }

    func autoAskForQuestion() async {
        // Son aşamadaysak (kamera kopup yeniden açıldı) yeni soru istenmez: eksikler ve süre yeniden duyurulur
        if autoClosing, !auto.closingExpired {
            await autoStartClosing()
            return
        }
        let target = autoTarget
        auto.promptedAt = nil
        auto.unreadSince = nil
        auto.missed = 0
        let later = autoSequential
        let next = autoAsked
        guard await speakNotice(later ? autoGapSentence(next: next) : Say.autoShow(number: target.number)) else {
            offerCamera = true
            return
        }
        let now = deps.now()
        auto.promptedAt = now
        if later {
            auto.latestAt = now.addingTimeInterval(TimeInterval(AutoStart.gapSeconds - AutoStart.questionCountdown))
            tlog("[otomatik] yeni tarama \(AutoStart.gapSeconds) sn sonra başlayacak (sıradaki yeni soru \(next))")
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
            if let openAt = auto.openAt, !autoSequential, now < openAt {
                armAutoGate()
                return
            }
            fireAuto(.open)
            return
        }
        if auto.promptedAt == nil { auto.promptedAt = now }
        if let until = auto.closingUntil {
            // Son aşama: tarama kendiliğinden başlamaz; yalnız cevapsız bir soru görülünce başlar. Süre dolunca bölüm / sınav tamamlanır
            if now >= until {
                fireAuto(.windowOver)
                return
            }
            if !auto.looking {
                auto.looking = true
                Task { @MainActor [weak self] in await self?.autoLook() }
            }
            armAutoGate()
            return
        }
        if autoSequential {
            // Sonraki taramalar: boşluk dolmadan başlanmaz. Dolunca beklenen soru kamerada görülünce başlanır (ilk taramadaki gibi: "N. soru görüldü",
            // beşten geri sayım); soru yapısı görünüp numara okunamıyorsa ya da hiç soru görülmüyorsa en geç `sequentialMaxWait` sn sonra yine başlanır
            let due = auto.latestAt ?? (auto.promptedAt ?? now).addingTimeInterval(TimeInterval(AutoStart.gapSeconds - AutoStart.questionCountdown))
            if now < due {
                armAutoGate()
                return
            }
            if now >= due.addingTimeInterval(AutoStart.sequentialMaxWait) {
                tlog("[otomatik] beklenen soru \(Int(AutoStart.sequentialMaxWait)) sn içinde görülmedi; tarama yine de başlatılıyor")
                fireAuto(.gap)
                return
            }
            if !auto.looking {
                auto.looking = true
                Task { @MainActor [weak self] in await self?.autoLook() }
            }
            armAutoGate()
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
        if let number = AutoStart.accepted(seen.numbers, ask: target.number, answered: answeredNumbers, limit: autoQuestionTotal) {
            tlog("[otomatik] kamerada soru görüldü: \(seen.summary)")
            fireAuto(.question(number))
            return
        }
        // Son aşamada "numara okunamadı, yine de başla" yoktur: kamera herhangi bir soru sayfasına bakarken tarama boş yere yinelenmesin, süre dolsun
        guard auto.closingUntil == nil else { return }
        let now = deps.now()
        if seen.looksLikeQuestion {
            auto.missed = 0
            if let since = auto.unreadSince {
                if now.timeIntervalSince(since) >= AutoStart.unreadSeconds {
                    tlog("[otomatik] soru yapısı \(Int(AutoStart.unreadSeconds)) sn'dir görünüyor ama \(autoAsked). soru okunamadı: \(seen.summary)")
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
        case .windowOver:
            // Eksikler için verilen süre doldu: tarama başlamaz, bölüm / sınav eksikleriyle tamamlanır. Bayrak önce kurulur: duyuru kesilirse onarımdan
            // sonra `autoAnnounce` aynı yerden sürdürür
            auto.closingUntil = nil
            auto.closingExpired = true
            guard await speakNotice(Say.autoWindowOver(section: sectionIndex > 0)) else {
                offerCamera = true
                return
            }
            guard !Task.isCancelled, phase == .speaking else {
                offerCamera = true
                return
            }
            await autoFinishExam(reachedEnd: true)
            return
        case .unreadable:
            guard await speakNotice(Say.autoUnread(number: autoAsked)) else {
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
        auto.closingUntil = nil
        auto.closingExpired = false
    }

    /// Gemini taramada soru bulamadı: sayılır. Sınır aşılınca (`AutoStart.emptyScanLimit`) bir sonraki adımda sınav kendiliğinden kapanır (`autoAnnounce`)
    func noteEmptyScan() {
        guard cameraSettings.autoStart, cameraSettings.pageSeries else { return }
        auto.emptyScans += 1
        tlog("[otomatik] taramada soru bulunamadı (art arda \(auto.emptyScans); sınır \(AutoStart.emptyScanLimit(count: autoQuestionTotal)))")
    }

    /// Mikrofon açılamadı ya da ses vermiyor ama zorunlu değil: bir kez yazılır, akış otomatik tetiklerle sürer
    func noteMicUnavailable(_ reason: String) {
        guard !auto.micGivenUp else { return }
        auto.micGivenUp = true
        tlog("[otomatik] mikrofon kullanılamıyor (\(reason)); sesli komut yok, otomatik tetiklerle sürülüyor")
        warn("mikrofon", "Kulaklık mikrofonu çalışmıyor; sesli komut verilemez. Tarama saatle ve soru görülünce kendiliğinden başlar.")
    }
}
