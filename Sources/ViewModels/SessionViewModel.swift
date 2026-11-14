import Foundation
import Combine

/// Oturumun beyni (MVVM'deki ViewModel). Durum makinesi: kontrol → dinle → Gemini → seslendir → dinle … ;
/// donanım koparsa duraklat (fail-safe), bağlantı koparsa Kestirmelerle onar. Dış dünya SessionDependencies üzerinden gelir.
///
/// Dosyalar: bu dosya yaşam döngüsü, dinleme ve cevaplama; +Checkup açılış kontrolü; +Recovery fail-safe, sessizlik, ağ ve onarım;
/// +Replay test sonu tekrar.
@MainActor
final class SessionViewModel: ObservableObject {
    enum Timing {
        /// Tetikleyici sözcük bu kadar değişmeden kalırsa gerçekten söylenmiş sayılır ("gönder" → "gönderi" yanlış alarmını önler)
        static let triggerConfirm: TimeInterval = 0.5
        /// Ağ bu kadar süre kesik kalırsa onarım başlar. Onarım önce bağlantıyı sınar, sağlamsa Kestirme çalıştırmaz; bu yüzden kısa tutulur.
        static let offlineDebounce: TimeInterval = 1
        /// Kulaklık/mikrofon bu kadar süre dönmezse sıfırlama kestirmesi çalışır
        static let hardwareGrace: TimeInterval = 20
        /// Donanım geri geldikten sonra bu kadar süre sabit kalırsa devam edilir
        static let routeStable: TimeInterval = 1
        /// Yarım okuma kesilince (kesinti sonrası) devam ettirmek için eldeki metnin en az sözcük sayısı
        static let partialMinWords = 4
        /// Numara istenince söylenen numara bu kadar sn sabit kalırsa soru gönderilir; numara hiç söylenmezse en çok bu kadar kez hatırlatılır
        static let numberConfirm: TimeInterval = 1.5
        static let numberReminderLimit = 2
        /// Cevap beklerken "cevap bekleniyor" anonsu bu aralıkla (sn) söylenir; bu süre dolarsa (sn) bekleme bırakılır
        static let answerCueEvery: TimeInterval = 30
        static let answerCap: TimeInterval = 180
        /// Sessizlikte dinlemeyi yenileyip sağlığa bakmadan önce beklenen süre
        static let silenceProbe: TimeInterval = 4
        /// Bağlantı onarılamazsa yeniden deneme aralığı
        static let connectionRetry: TimeInterval = 60
        /// Üst üste bu kadar donanım onarımı arada tek kelime tanınmadan yapıldıysa sıfırlama döngüsü kesilir
        static let maxHardwareRecoveries = 3
        /// Döngü kesilince bir sonraki deneme için bekleme
        static let hardwareCapRetry: TimeInterval = 60
        /// Cevap okunamayınca ikinci okuma denemesinden önceki kısa bekleme (sn)
        static let speakRetryDelay: TimeInterval = 1
        /// Kesinti sürerken (arama vb.) ses oturumunun yeniden açılıp açılamadığına bakma aralığı; bitiş bildirimi gelmezse yedek
        static let interruptionPoll: TimeInterval = 15
        /// Aynı uyarı cümlesi bu süre içinde kulaklıktan yeniden söylenmez (yol dalgalanınca konuşma yağmuru olmasın)
        static let announceRepeat: TimeInterval = 300
        /// Bu kadar saniyedir bekleyen uyarı eskimiştir, söylenmez
        static let announceMaxAge: TimeInterval = 180
        /// Aynı anda bekleyebilecek sesli uyarı sayısı
        static let maxQueuedAnnouncements = 6
        /// Art arda kaç denemede yol düzelmezse "çıkışı kulaklığa al" kestirmesinin bırakılıp eski onarım sırasına dönüleceği
        /// (yol her düzelişte sayaç sıfırlanır; çözmeyen kestirme sonsuz döngü olmasın)
        static let maxOutputTries = 6
        /// Kulaklık yoldan çıkınca "çıkışı kulaklığa al" kestirmesinin ilk kez çalıştırılacağı süre (yol bildirimleri otursun diye kısa bir bekleme;
        /// 20 sn'lik donanım beklemesini beklemez)
        static let outputQuickDelay: TimeInterval = 1
        /// Anında tespit (nabız): aralık, mikrofonun "takıldı" sayılacağı sessiz tampon süresi ve dinleme başlayınca beklenen nabız sayısı
        static let sentinelTick: TimeInterval = 0.5
        static let micStallLimit: TimeInterval = 1.2
        static let micWarmupTicks = 4
        /// Mikrofon art arda bu kadar yeniden kurulduysa Kestirmeler çalışır; bu kadar nabız sağlıklıysa sayaç sıfırlanır
        static let maxMicHeals = 3
        static let micHealthyTicks = 10
        /// İnternet yoklaması her bu kadar nabızda bir (dinlerken); bağlantı yokken (duraklatılmış) daha sık
        static let netBeatEvery = 10
        static let netPausedBeatEvery = 4
        /// Yoklama başarısızsa bir sonrakine kalan nabız sayısı ve art arda kaç başarısız yoklamada onarım başlayacağı
        static let netRetryTicks = 2
        static let netFailLimit = 2
        /// Ses servisi sıfırlanınca ses oturumunun yeniden kurulmasına kadar bekleme
        static let mediaHealDelay: TimeInterval = 0.3
        /// Bu süreden kısa kesintiden sonra kısa "Hazır" anonsu
        static let briefOutage: TimeInterval = 8
        /// Konuşma tanıma onarımı: dinlemenin gerçekten çalıştığı kanıtlanırken yoklama aralığı, en az ve en çok yoklama sayısı
        /// (ilk yoklamalarda görev hemen düşüyorsa kanıtlanmış sayılmaz), bir onarımdaki tur sayısı ve açılamıyorsa yeniden deneme aralığı
        static let proofPoll: TimeInterval = 0.5
        static let proofMinPolls = 5
        static let proofMaxPolls = 14
        static let recognizerRounds = 3
        static let recognizerRetry: TimeInterval = 15
        /// Sistem sağlığı: iOS'un kapatma eşiğine bu kadar bellek (MB) kalınca yük azaltılır, bu kadar toparlanınca geri açılır
        static let lowMemoryMB = 250
        static let memoryOKMB = 400
        /// Boş yer bu kadar MB'ın altına inince uyarılır (ses kayıtları yazılamayabilir)
        static let lowDiskMB = 200
        /// Kaynak durumu her bu kadar nabızda bir (60 sn) günlüğe yazılıp denetlenir
        static let systemEveryTicks = 120
        /// Nabız bu kadar saniyeden geç gelirse günlüğe yazılır (ana iş parçacığı takıldı ya da uygulama askıya alındı)
        static let tickLateLog: TimeInterval = 3
        /// Uygulamanın yaşadığı her bu kadar nabızda bir deftere işlenir (5 sn)
        static let heartbeatEveryTicks = 10
        /// Beklenmedik kapanma: bu süre (sn) içinde bu kadar kez olursa otomatik başlatma durdurulur (açılış döngüsü)
        static let loopWindow: TimeInterval = 120
        static let loopLimit = 3
        /// "Programı kapat" düğmesi: basılı tutma süresi (sn) ve günlüğün/panonun yazılması için kapanıştan önceki kısa bekleme
        static let closeHold: TimeInterval = 3
        static let closeDelay: TimeInterval = 0.4

        /// Bir aşama bu süreden (sn) uzun hiç değişmezse takıldığı varsayılır (nil: o aşama sınırsız bekleyebilir, örn. dinleme ve duraklatmalar).
        /// Sınırlar, aşamanın kendi en uzun meşru süresinin üstündedir (örn. Gemini zincirinin en kötü sessiz bekleyişi ~10 dk).
        static func stuckLimit(for phase: SessionPhase) -> TimeInterval? {
            switch phase {
            case .checking: return 240
            case .answering: return 660
            case .speaking: return 180
            case .recovering: return 360
            default: return nil
            }
        }
    }

    // MARK: Ekranın gördüğü durum

    @Published var phase: SessionPhase = .idle {
        didSet {
            if phase != oldValue {
                tlog("[oturum] \(phase.title)")
                trackInterruption(from: oldValue)
                let open = SessionViewModel.countsAsSession(phase)
                if open != SessionViewModel.countsAsSession(oldValue) {
                    // Oturumun açık olduğu deftere ve günlüğe işlenir: uygulama bu arada kapanırsa sonraki açılış bunu görür
                    deps.journal.setSessionOpen(open)
                    tlog(open ? ExitAnalyzer.startedMark : "\(ExitAnalyzer.endedMark): \(phase.title)")
                    if !open {
                        // Oturum kapandı: bir sonraki başlatma eski bir kapanmanın "devamı" sayılmasın (kendiliğinden başlayan oturum
                        // kontrolde takılıp bittiyse "kaldığınız yerden sürüyorum" demesin, eski yarım iş yeniden sorulmasın)
                        resume = nil
                        deps.journal.savePending(nil)
                        deps.journal.savePassage(nil)
                    }
                }
                drainAnnouncementsIfQuiet()
            }
        }
    }
    /// Dikte edilen (ve kırpılmış) soru metni
    @Published var liveText = ""
    @Published var answers: [AnswerRecord] = []
    /// Yüklenen sorular ve her birinin Gemini'ye gidiş durumu (ana ekrandaki tek liste; yükleme sırasıyla)
    @Published var questions: [QuestionEntry] = []
    /// "Sesi dene" sonucu ve çalışıyor mu
    @Published var soundTest = ""
    @Published var testingSound = false
    @Published var warnings: [SessionWarning] = []
    @Published var checkup: [CheckItem] = []
    @Published var statusNote = ""
    @Published var canReplay = false
    /// Seçilebilir harici mikrofonlar (ana ekrandaki mikrofon listesi)
    @Published var inputs: [InputChoice] = []
    @Published var routeVerdict: RouteVerdict?
    /// Şu anki ses yolu, ana ekranda küçük yazıyla ("Çıkış: Bluetooth kulaklık. Giriş: Lightning/USB mikrofon.")
    @Published var routeText = ""
    /// "Canlı: Kulaklık ✓ · Mikrofon ✓ · İnternet ✓" (anında tespit açıksa)
    @Published var liveStatus = ""
    /// Okunmakta olan sorunun İngilizce tanıyıcıdan çıkan hâli (ana ekranda küçük yazıyla)
    @Published var liveEnglish = ""
    /// Mikrofonun şu an ne için açık olduğu (soru, ortak paragraf, paragrafın soru numaraları, eksik soru numarası)
    @Published var listenMode: ListenMode = .question
    /// Kayıtlı ortak paragraf (ait olduğu sorular cevaplanınca bırakılır)
    @Published var passage: PassageContext? {
        didSet {
            guard passage != oldValue else { return }
            // Uygulama beklenmedik kapanırsa paragraf (yalnız metin) defterde durur ve yeniden açılışta geri yüklenir
            deps.journal.savePassage(passage.map { SavedPassage(text: $0.text, english: $0.english, all: $0.all, remaining: $0.remaining) })
        }
    }

    // MARK: Bağımlılıklar

    let settings: AppSettings
    let deps: SessionDependencies
    let watchdog: SilenceWatchdog
    let recovery: RecoveryCoordinator
    let replay: ReplayController

    // MARK: İç durum (uzantı dosyaları da kullanır)

    var accumulator = TranscriptAccumulator()
    /// Yardımcı İngilizce tanıyıcının metni (tetikleyici aramasında kullanılmaz; Gemini'ye ikinci metin olarak gider)
    var englishAccumulator = TranscriptAccumulator()
    var sessionFolder: URL?
    var nextNumber = 1
    /// Kulaklıktan söylenmeyi bekleyen uyarılar, şu an çalan söyleme görevi, her cümlenin son söylenme zamanı ve söylenenlerin kaydı
    var voiceQueue: [PendingAnnouncement] = []
    var voiceTask: Task<Void, Never>?
    var lastVoiced: [String: Date] = [:]
    var announced: [String] = []
    /// Yol düzelmeden "çıkışı kulaklığa al" kestirmesi art arda kaç kez çalıştı (yol düzelince sıfırlanır)
    var outputTries = 0
    /// Kulaklık yoldan çıkınca kestirmeyi hemen çalıştıracak zamanlayıcı ve çalışan deneme
    var outputQuick: ScheduledTask?
    var outputQuickRun: Task<Void, Never>?
    var pendingStart = false
    /// Alındığı ve kaydedildiği hâlde kulaklıktan duyulamamış cevap (okunurken ses yolu koptu); yol dönünce yeniden okunur
    var unheard: AnswerRecord?
    /// Şu an Gemini'ye giden sorunun satırı (yoksa nil) ve satır sayacı
    var currentEntry: Int?
    var entrySeq = 0
    /// Düşük şarj uyarısının hangi eşikleri söylediğini tutar
    var batteryWatcher = LowBatteryWatcher()
    /// Arada tek kelime tanınmadan art arda yapılan donanım onarımı sayısı
    var hardwareRecoveries = 0
    var work: Task<Void, Never>?
    var confirmTask: ScheduledTask?
    var offlineCheck: ScheduledTask?
    var hardwareGrace: ScheduledTask?
    var stableTask: ScheduledTask?
    var retryTask: ScheduledTask?
    /// Arama/alarm/Siri kesintisi sürüyor
    var interruptionActive = false
    var interruptionPoll: ScheduledTask?
    /// Anında tespit (nabız) durumu: döngü, mikrofon sağlığı ve onarım sayacı, internet nabzı
    var sentinel: ScheduledTask?
    var micCooldown = 0
    var micOKTicks = 0
    var micHealCount = 0
    var micAlive = true
    var netBeatTicks = 0
    var netFails = 0
    var netProbeBusy = false
    var netReconnecting = false
    var netPulse: NetPulse = .unknown
    /// Duraklama/onarım ilk başladığı an (kısa kesintide kısa anons için)
    var outageStart: Date?
    /// Sınır duraklaması (art arda onarım işe yaramadı): ses yolu sağlam görünse de süre dolana kadar devam edilmez. Yoksa nabız,
    /// "yol sağlam" diye hemen devam edip aynı onarım döngüsünü yeniden başlatır.
    var holdForRetry = false
    /// Hızlı nabız yoklaması bir kez boşuna alarm verdi (tam yoklama bağlantıyı sağlam buldu): nabız bu oturumda daha uzun sınırlı
    /// tam internet yoklamasıyla bakar. Onarım susturulmaz; gerçek kopma yine aynı hızda yakalanır.
    var netProbeSlow = false
    /// Son ağ onarımı çağrısı yanlış alarmdı (bağlantı sağlamdı, hiçbir şey durdurulmadı)
    var lastNetworkAlarmWasFalse = false
    /// Konuşma tanıma onarımı: arada tek kelime tanınmadan kaç kez düştü; bekleme zamanlayıcısı
    var recognizerRepairs = 0
    var recognizerRetryTask: ScheduledTask?
    /// Beklenmedik kapanmadan sonra oturum sürdürülüyor: anons edilip tüketilene kadar durur
    var resume: ResumeInfo?
    var launchHandled = false
    /// Sistem sağlığı: bellek yükü azaltılmış mı, dakikalık sayaç, takılma gözcüsü ve nabız gecikmesi
    var memoryLowActive = false
    var thermalTrimmed = false
    var systemTicks = 0
    var watchedPhase: SessionPhase?
    var watchedTicks = 0
    var stuckTrips = 0
    var lastTickAt: Date?
    var heartbeatTicks = 0
    /// Numarası okunmadığı için numara beklenen soru; "Tamamlandı" denmiş ama soru numaraları beklenen paragraf; numara hatırlatma sayısı
    var heldQuestion: HeldQuestion?
    var passageDraft: PassageDraft?
    var numberReminders = 0
    /// Kesinti (onarım, donanım beklemesi) hangi aşamadayken başladı: dinlerken mi, soru gitmişken (cevap beklenirken) mi
    var interruptedFrom: SessionPhase?
    /// Cevap beklenirken "cevap bekleniyor" anonsu ve 3 dakikalık bekleme sınırı için zamanlayıcı
    var answerWait: ScheduledTask?
    var answerWaitElapsed: TimeInterval = 0

    init(settings: AppSettings, deps: SessionDependencies) {
        self.settings = settings
        self.deps = deps
        watchdog = SilenceWatchdog(scheduler: deps.scheduler)
        recovery = RecoveryCoordinator(shortcuts: deps.shortcuts,
                                       name: { step in settings.shortcutName(for: step) },
                                       config: deps.recoveryConfig,
                                       sleep: deps.sleep)
        let route = deps.route
        replay = ReplayController(player: deps.replayPlayer, scheduler: deps.scheduler,
                                  canPlay: { AudioRouting.verdict(route.snapshot()).headphonesOK })
        deps.route.onChange = { [weak self] snapshot in self?.routeChanged(snapshot) }
        deps.route.onInterruption = { [weak self] began in self?.interrupted(began) }
        deps.network.onChange = { [weak self] online in self?.networkChanged(online) }
        deps.network.onPathChange = { [weak self] in self?.networkPathChanged() }
        deps.route.onMediaServicesReset = { [weak self] in self?.mediaServicesReset() }
        deps.battery.onChange = { [weak self] in self?.batteryChanged() }
        deps.system.onMemoryWarning = { [weak self] in self?.memoryWarningReceived() }
        deps.system.onThermalChange = { [weak self] in self?.thermalChanged() }
        deps.system.onPowerModeChange = { [weak self] in self?.powerModeChanged() }
        deps.listener.onEvent = { [weak self] event in self?.handleSpeech(event) }
        watchdog.onExpire = { [weak self] in self?.silenceExpired() }
        replay.onState = { [weak self] state in self?.replayChanged(state) }
        refreshReplayAvailability()
        refreshInputs()
    }

    /// Ana ekrandaki mikrofon listesi: yalnız harici (Lightning/USB/kablolu) mikrofonlar seçilebilir
    func refreshInputs() {
        inputs = deps.route.availableInputs().filter { $0.isExternal }
        let snapshot = deps.route.snapshot()
        var text = AudioRouting.describe(snapshot)
        // Mikrofon alıcısı takılı ama ses yoluna girmediyse nedeni yazılır ("giriş yok" tek başına yanıltıcıdır)
        if !snapshot.inputs.contains(where: { AudioRouting.externalMicPorts.contains($0) }), let receiver = inputs.first {
            text += phase.isAtRest
                ? " Mikrofon alıcısı (\(receiver.name)) takılı; “Sesi dene” ya da “Başlat” ile devreye girer."
                : " Mikrofon alıcısı (\(receiver.name)) takılı ama ses yoluna girmedi."
        }
        routeText = text
    }

    /// Kullanıcı listeden bir mikrofon seçti
    func chooseInput(_ uid: String) {
        if deps.route.selectInput(uid: uid) {
            clearWarning("giris")
        } else {
            warn("giris", "Mikrofon seçilemedi. Alıcının takılı ve mikrofonun açık olduğundan emin olun.")
        }
        refreshInputs()
        routeVerdict = AudioRouting.verdict(deps.route.snapshot())
    }

    // MARK: Başlat / bitir

    /// Oturumu başlatır: donanım kontrolü, sonra dinleme. El ile düğme, seslikontrol://basla, saat ya da bildirim çağırır.
    func start() {
        guard phase.isAtRest else { return }
        resetSession()
        // Beklenmedik kapanmadan sonra ortak paragraf yalnız metin olarak geri gelir (ses kaydı bellekteydi, kayboldu)
        if let saved = resume?.passage, !saved.remaining.isEmpty {
            passage = PassageContext(text: saved.text, english: saved.english, audio: nil, all: saved.all, remaining: saved.remaining)
            tlog("[paragraf] kapanmadan önceki ortak paragraf yazı olarak geri yüklendi (\(QuestionComposer.listText(saved.remaining)) numaralı sorular)")
        }
        phase = .checking
        deps.screen.keepAwake(true)
        deps.network.start()
        startSentinel()
        work = Task { [weak self] in await self?.runStartup() }
    }

    /// "Testi bitir": her şeyi durdurur; cevaplar klasörde kalır, "Cevapları Tekrarla" açılır
    func endTest() {
        guard phase.isRunning else { return }
        cancelWork()
        replay.stop()
        deps.speaker.stop()
        deps.listener.pause()
        deps.network.stop()
        deps.screen.keepAwake(false)
        phase = .finished
        passage = nil
        heldQuestion = nil
        passageDraft = nil
        listenMode = .question
        statusNote = "Test bitti. \(answers.count) cevap kaydedildi."
        refreshReplayAvailability()
    }

    /// seslikontrol://basla (zamanlı başlatma), seslikontrol://yeniden (Kestirmeler "uygulama kapanınca aç" otomasyonu) ve Kestirmeler dönüşleri
    func handleURL(_ url: URL) {
        if ShortcutLink.isStartURL(url) {
            start()
            return
        }
        if ShortcutLink.isReopenURL(url) {
            // Yeniden açılış: uygulama kapanmışsa `launched` önceki oturumu zaten sürdürür; açıksa yalnız öne gelir
            tlog("[açılış] otomasyon uygulamayı yeniden açtı (seslikontrol://yeniden)")
            return
        }
        deps.shortcuts.handleCallback(url)
    }

    // MARK: Açılış ve kapanış

    /// Oturumun "açık" sayıldığı aşamalar: tekrar (replay) bir oturum değildir
    static func countsAsSession(_ phase: SessionPhase) -> Bool {
        return phase.isRunning && phase != .replaying
    }

    /// Uygulama açılınca bir kez çağrılır. Önceki çalışma oturum sürerken beklenmedik kapandıysa (iOS belleği, çökme, elle kapatma)
    /// oturum kendiliğinden yeniden başlar ve yarım kalan iş tamamlanır. Kullanıcı "Programı kapat" ile kapattıysa ya da oturum düzgün
    /// bittiyse hiçbir şey başlamaz. Kısa sürede art arda kapanma varsa (açılış döngüsü) otomatik başlatma yapılmaz.
    func launched() {
        guard !launchHandled else { return }
        launchHandled = true
        let run = deps.journal.beginRun()
        tlog("[açılış] önceki çalışma: \(run.exit.logText)")
        guard case .unexpected(let cause) = run.exit else { return }
        guard !run.loop else {
            deps.journal.setSessionOpen(false)
            deps.journal.savePending(nil)
            deps.journal.savePassage(nil)
            warn("kapanma", Say.restartLoop)
            tlog("[açılış] kısa sürede art arda beklenmedik kapanma: otomatik başlatma durduruldu")
            return
        }
        guard phase.isAtRest else { return }
        resume = ResumeInfo(cause: cause, downSeconds: run.downSeconds, pending: run.pending, nextNumber: run.nextNumber, folder: run.folder,
                            passage: run.passage)
        tlog("[açılış] oturum kendiliğinden yeniden başlatılıyor (kapalı kalma: \(run.downSeconds.map { "\($0) sn" } ?? "bilinmiyor"), yarım iş: \(run.pending == nil ? "yok" : "var"))")
        start()
    }

    /// "Programı kapat" düğmesine 3 saniye basıldı: oturum kapanır, defter ve pano "kullanıcı kapattı" olarak işaretlenir (yeniden açılmasın),
    /// günlük diske yazılır ve program gerçekten çıkar.
    func closeByUser() {
        tlog("[kapanış] kullanıcı kapattı (düğmeye \(Int(Timing.closeHold)) sn basıldı)")
        deps.journal.markDeliberateClose()
        deps.journal.savePending(nil)
        if phase == .replaying { stopReplay() }
        if phase.isRunning { endTest() }
        AppLog.shared.flush()
        Task { [weak self] in
            guard let self = self else { return }
            await self.deps.sleep(Timing.closeDelay)
            AppLog.shared.flush()
            self.deps.terminate()
        }
    }

    func resetSession() {
        cancelWork()
        accumulator.clear()
        englishAccumulator.clear()
        liveText = ""
        liveEnglish = ""
        answers = []
        questions = []
        currentEntry = nil
        entrySeq = 0
        batteryWatcher = LowBatteryWatcher()
        warnings = []
        checkup = []
        statusNote = ""
        nextNumber = 1
        pendingStart = false
        unheard = nil
        hardwareRecoveries = 0
        interruptionActive = false
        sessionFolder = nil
        voiceQueue = []
        lastVoiced = [:]
        outputTries = 0
        outputQuick?.cancel()
        outputQuick = nil
        outputQuickRun?.cancel()
        outputQuickRun = nil
        micCooldown = 0
        micOKTicks = 0
        micHealCount = 0
        micAlive = true
        netBeatTicks = 0
        netFails = 0
        netProbeBusy = false
        netReconnecting = false
        netPulse = .unknown
        outageStart = nil
        liveStatus = ""
        holdForRetry = false
        netProbeSlow = false
        lastNetworkAlarmWasFalse = false
        recognizerRepairs = 0
        recognizerRetryTask?.cancel()
        recognizerRetryTask = nil
        if memoryLowActive || thermalTrimmed { deps.listener.trimMemory(false) }
        memoryLowActive = false
        thermalTrimmed = false
        systemTicks = 0
        watchedPhase = nil
        watchedTicks = 0
        lastTickAt = nil
        heartbeatTicks = 0
        listenMode = .question
        passage = nil
        heldQuestion = nil
        passageDraft = nil
        numberReminders = 0
        interruptedFrom = nil
        answerWait?.cancel()
        answerWait = nil
        answerWaitElapsed = 0
    }

    func cancelWork() {
        abandonEntry("Kesildi: cevap gelmeden iş durdu. Soruyu yeniden okuyun.")
        work?.cancel()
        work = nil
        cancelTimers()
        retryTask?.cancel()
        retryTask = nil
        watchdog.disarm()
    }

    /// Kısa ömürlü bekleyen işleri iptal eder (çalışan `work` görevine dokunmaz)
    func cancelTimers() {
        confirmTask?.cancel()
        confirmTask = nil
        offlineCheck?.cancel()
        offlineCheck = nil
        hardwareGrace?.cancel()
        hardwareGrace = nil
        stableTask?.cancel()
        stableTask = nil
        interruptionPoll?.cancel()
        interruptionPoll = nil
        outputQuick?.cancel()
        outputQuick = nil
        answerWait?.cancel()
        answerWait = nil
    }

    // MARK: Uyarılar ve kontrol maddeleri

    /// Kulaklıktan zaten başka yerde söylenen ("start": Kontrol başarısız, "cevap": Gemini hatası) ya da kulaklıktan söylenemeyen
    /// ("ses": okuma hatası) uyarılar ayrıca söylenmez
    private static let silentWarnings: Set<String> = ["start", "cevap", "ses", "kapanma", "gozcu", "yedek"]

    /// Uyarıyı ekrana yazar; yeni ya da değişmişse kulaklıktan da söyler (`announce`)
    func warn(_ id: String, _ text: String) {
        var changed = true
        if let index = warnings.firstIndex(where: { $0.id == id }) {
            changed = warnings[index].text != text
            if changed { tlog("[uyarı] \(id): \(text)") }
            warnings[index].text = text
        } else {
            tlog("[uyarı] \(id): \(text)")
            warnings.append(SessionWarning(id: id, text: text))
        }
        if changed, !SessionViewModel.silentWarnings.contains(id) { announce(text) }
    }

    func clearWarning(_ id: String) {
        warnings.removeAll { $0.id == id }
    }

    func setCheck(_ id: String, _ title: String, ok: Bool, detail: String = "") {
        let item = CheckItem(id: id, title: title, ok: ok, detail: detail)
        if let index = checkup.firstIndex(where: { $0.id == id }) {
            checkup[index] = item
        } else {
            checkup.append(item)
        }
    }

    /// Tekrarlanacak klasör: bu oturumun cevapları varsa o, yoksa (yeni oturum açılıp boş kaldıysa) cevap içeren en yeni gün klasörü
    func replayFolder() -> URL? {
        if let folder = sessionFolder, !deps.library.answerFiles(in: folder).isEmpty { return folder }
        return deps.library.latestFolder()
    }

    func refreshReplayAvailability() {
        canReplay = replayFolder() != nil
    }

    // MARK: Dinleme (Modül 3)

    /// Mikrofonu açar ve yeni soruyu bekler. Eldeki yarım metin ve ses silinir; yalnız `keepPartial` ise (kesinti sonrası, okunan soru ya da
    /// paragraf yarıda kalmışsa) korunur ve devam edilen okuma ona eklenir. `mode`: mikrofonun ne için açıldığı.
    func beginListening(mode: ListenMode = .question, keepPartial: Bool = false) {
        cancelTimers()
        abandonEntry("Cevap alınamadı. Soruyu yeniden okuyun.")
        deps.journal.savePending(nil)   // dinlemeye dönüldüyse yarım kalan iş yoktur
        unheard = nil
        if keepPartial, !accumulator.isEmpty {
            accumulator.commitCurrent()   // eski görevin yarım metni bölüm olur; yeni görevin metni onun arkasına eklenir
            englishAccumulator.commitCurrent()
            liveText = accumulator.text
            liveEnglish = englishAccumulator.text
        } else {
            accumulator.clear()
            englishAccumulator.clear()
            liveText = ""
            liveEnglish = ""
            deps.recorder.reset()
            if mode == .question {
                heldQuestion = nil
                passageDraft = nil
            }
        }
        listenMode = mode
        do {
            try deps.listener.start()
        } catch {
            listenerFailed(error)
            return
        }
        clearWarning("mikrofon")
        phase = .listening
        statusNote = ""
        micCooldown = Timing.micWarmupTicks
        micOKTicks = 0
        micAlive = true
        outageStart = nil
        watchdog.kick()
        if !deps.network.isOnline { scheduleOfflineCheck() }
        batteryChanged()
    }

    func handleSpeech(_ event: SpeechEvent) {
        guard phase == .listening else { return }
        switch event {
        case .partial(let text):
            guard accumulator.update(partial: text) else { return }
            hardwareRecoveries = 0   // mikrofon gerçekten çalışıyor
            recognizerRepairs = 0    // tanıma gerçekten çalışıyor
            liveText = accumulator.text
            watchdog.kick()
            if listenMode == .question, PassageCommand.startsWith(accumulator.text) {
                listenMode = .passage   // "ortak paragraf": paragraf okunuyor, "Tamamlandı" ile biter
                tlog("[paragraf] ortak paragraf kipi açıldı")
            }
            reevaluateTrigger()
        case .taskEnded:
            accumulator.commitCurrent()
        case .englishPartial(let text):
            guard englishAccumulator.update(partial: text) else { return }
            liveEnglish = englishAccumulator.text
        case .englishTaskEnded:
            englishAccumulator.commitCurrent()
        case .failure(let message):
            warn("mikrofon", message)
            // Ses yolu sağlamsa sorun donanımda değil konuşma tanıyıcıdadır: Bluetooth/uçak modu Kestirmeleri onu düzeltmez, kulaklığı koparır.
            // Dinleme yeniden kurulur; art arda olursa (healMic) Kestirmelere başvurulur.
            if settings.instantDetection, AudioRouting.verdict(deps.route.snapshot()).isSafe {
                healMic("konuşma tanıma hata verdi")
            } else {
                work = Task { [weak self] in await self?.runRecovery(.hardware, force: true) }
            }
        case .recognizerDown(let message, let permanent):
            tlog("[mikrofon] tanıyıcı düştü (\(permanent ? "kalıcı" : "geçici")): \(message)")
            if permanent {
                stopForGood(message)   // Dikte kapalı ya da model yok: yeniden denemek işe yaramaz, ne yapılacağı söylenir
            } else if AudioRouting.verdict(deps.route.snapshot()).isSafe {
                // Ses yolu sağlam: sorun tanıyıcıdadır. Bluetooth/uçak modu Kestirmeleri onu düzeltmez, kulaklığı koparır.
                work?.cancel()
                work = Task { [weak self] in await self?.repairRecognizer(message) }
            } else {
                work = Task { [weak self] in await self?.runRecovery(.hardware, force: true) }
            }
        case .engineStopped:
            // Dinleme yeni (yeniden) başladıysa bekleme süresinde yok sayılır; gerçekten durduysa nabız yine yakalar.
            // Motor bildirimi tek başına onarım sayacına sayılmaz (tamponlar gerçekten kesilirse nabız sayar).
            guard settings.instantDetection, micCooldown == 0 else { return }
            healMic("ses motoru durdu", counted: false)
        }
    }

    /// Dinleme açılamadı ya da durdu. Kalıcı eksikse (izin, dikte modeli) oturum kapanır; donanımsa Kestirmelerle onarılır.
    func listenerFailed(_ error: Error) {
        if let known = error as? ListenerError, !known.isHardware {
            stopForGood(known.localizedDescription)
            return
        }
        warn("mikrofon", error.localizedDescription)
        work = Task { [weak self] in await self?.runRecovery(.hardware, force: true) }
    }

    /// Kipe göre tetikleyici sabit kalırsa ateşler: soru ve paragraf numaralarında metnin sonu "Cevapla"/"Gönder", ortak paragrafta "Tamamlandı";
    /// eksik soru numarası beklenirken kısa bir numara cevabı ("soru yedi") ya da "sıradaki"
    private func reevaluateTrigger() {
        confirmTask?.cancel()
        confirmTask = nil
        let text = accumulator.text
        var delay = Timing.triggerConfirm
        switch listenMode {
        case .question, .passageTargets:
            guard TriggerDetector.match(in: text) != nil else { return }
        case .passage:
            guard TriggerDetector.match(in: text, words: PassageCommand.finishWords) != nil else { return }
        case .missingNumber:
            guard heldQuestion != nil, SpokenNumber.standalone(from: text) != nil || SpokenNumber.wantsSequence(text) else { return }
            delay = Timing.numberConfirm
        }
        confirmTask = deps.scheduler.after(delay) { [weak self] in self?.fireTrigger() }
    }

    func fireTrigger() {
        confirmTask = nil
        guard phase == .listening else { return }
        switch listenMode {
        case .question: fireQuestion()
        case .passage: firePassage()
        case .passageTargets: fireTargets()
        case .missingNumber: fireNumber()
        }
    }

    /// Mikrofonu kapatır (ses kaydı ve İngilizce metin `fire*` işlevlerinde önceden alınır; dinleme yeniden açılırken metin silinir)
    private func closeListening() {
        deps.listener.pause()
        watchdog.disarm()
    }

    private func fireQuestion() {
        guard let match = TriggerDetector.match(in: accumulator.text) else { return }
        guard !match.question.isEmpty else {
            // Yalnız "cevapla" denmiş: boş soru gönderilmez; sesteki "cevapla" sözcüğü bir sonraki soruya karışmasın
            accumulator.clear()
            englishAccumulator.clear()
            liveText = ""
            liveEnglish = ""
            deps.recorder.reset()
            return
        }
        // Mikrofon duraklar, tetikleyici sözcük metinden kırpılmıştır; ses kaydı da bu andan sonra durur
        let audio: Data? = settings.sendAudio ? deps.recorder.wavData() : nil
        let english = settings.englishDictation ? englishAccumulator.text : ""
        let question = match.question
        closeListening()
        liveText = question
        // Kayıt, okunan numarayla yapılır: kullanıcı soruları sırayla okumak zorunda değildir
        let spoken = SpokenNumber.extract(from: question)
        if spoken == nil, settings.askMissingNumber {
            heldQuestion = HeldQuestion(text: question, english: english, audio: audio)
            numberReminders = 0
            tlog("[soru] numara okunmadı; numara isteniyor")
            phase = .speaking
            work = Task { [weak self] in await self?.askForNumber(again: false) }
            return
        }
        phase = .answering
        statusNote = ""
        send(question: question, english: english, audio: audio, number: spoken, numberSpoken: true)
    }

    /// "Lütfen okuduğunuz sorunun numarasını söyleyin" der ve numarayı dinler
    func askForNumber(again: Bool) async {
        guard heldQuestion != nil else { return }
        guard await speakNotice(again ? Say.askNumberAgain : Say.askNumber) else { return }
        beginListening(mode: .missingNumber)
    }

    /// Numara duyuldu ("soru yedi") ya da "sıradaki" denildi: bekleyen soru numarası başa yazılarak Gemini'ye gider
    private func fireNumber() {
        guard let held = heldQuestion else {
            listenMode = .question
            return
        }
        let text = accumulator.text
        let number: Int
        if let heard = SpokenNumber.standalone(from: text) {
            number = heard
        } else if SpokenNumber.wantsSequence(text) {
            number = nextNumber
        } else {
            return
        }
        closeListening()
        heldQuestion = nil
        numberReminders = 0
        listenMode = .question
        liveText = held.text
        phase = .answering
        statusNote = ""
        tlog("[soru] numara söylendi: \(number)")
        send(question: held.text, english: held.english, audio: held.audio, number: number, numberSpoken: false)
    }

    /// Numara hiç söylenmeden sessizlik sürerse: hatırlatılır; yine olmazsa eski davranış (sıradaki numara) uygulanır, soru kaybolmaz
    func numberSilence() async {
        guard let held = heldQuestion else { return }
        numberReminders += 1
        guard numberReminders <= Timing.numberReminderLimit else {
            closeListening()
            heldQuestion = nil
            numberReminders = 0
            listenMode = .question
            liveText = held.text
            phase = .answering
            statusNote = ""
            tlog("[soru] numara söylenmedi; sıradaki numara verilerek gönderiliyor")
            send(question: held.text, english: held.english, audio: held.audio, number: nil, numberSpoken: true)
            return
        }
        deps.listener.pause()
        watchdog.disarm()
        phase = .speaking
        await askForNumber(again: true)
    }

    /// "Tamamlandı" denince ortak paragraf alınır; hangi sorulara ait olduğu sorulur
    private func firePassage() {
        guard let match = TriggerDetector.match(in: accumulator.text, words: PassageCommand.finishWords) else { return }
        let text = PassageCommand.stripStart(match.question)
        let english = settings.englishDictation ? englishAccumulator.text : ""
        let audio: Data? = settings.sendAudio ? deps.recorder.wavData() : nil
        let audioTruncated = audio != nil && deps.recorder.truncated
        closeListening()
        liveText = ""
        phase = .speaking
        guard !text.isEmpty else {
            listenMode = .question
            tlog("[paragraf] paragraf metni boş kaldı")
            work = Task { [weak self] in
                guard let self = self, await self.speakNotice(Say.passageEmpty) else { return }
                self.beginListening(mode: .question)
            }
            return
        }
        passageDraft = PassageDraft(text: text, english: english, audio: audio, audioTruncated: audioTruncated)
        listenMode = .passageTargets
        tlog("[paragraf] ortak paragraf alındı (\(text.count) karakter); hangi sorulara ait olduğu soruluyor")
        work = Task { [weak self] in
            guard let self = self, await self.speakNotice(Say.passageTaken) else { return }
            self.beginListening(mode: .passageTargets)
        }
    }

    /// Paragrafın ait olduğu soru numaraları ("beş altı yedi, Cevapla") alınır; paragraf o sorularla birlikte gider
    private func fireTargets() {
        guard let match = TriggerDetector.match(in: accumulator.text) else { return }
        let numbers = SpokenNumber.list(from: match.question)
        closeListening()
        liveText = ""
        phase = .speaking
        guard let draft = passageDraft else {
            listenMode = .question
            work = Task { [weak self] in self?.beginListening(mode: .question) }
            return
        }
        guard !numbers.isEmpty else {
            tlog("[paragraf] soru numaraları anlaşılamadı; yeniden isteniyor")
            work = Task { [weak self] in
                guard let self = self, await self.speakNotice(Say.passageTargetsAgain) else { return }
                self.beginListening(mode: .passageTargets)
            }
            return
        }
        passage = PassageContext(text: draft.text, english: draft.english, audio: draft.audio, all: numbers, remaining: numbers,
                                 audioTruncated: draft.audioTruncated)
        passageDraft = nil
        listenMode = .question
        tlog("[paragraf] ortak paragraf \(QuestionComposer.listText(numbers)) numaralı sorular için kaydedildi")
        work = Task { [weak self] in
            guard let self = self, await self.speakNotice(Say.passageReady(numbers)) else { return }
            self.beginListening(mode: .question)
        }
    }

    /// Soruyu (varsa ortak paragrafıyla ve başına numarası yazılarak) Gemini'ye yollar
    func send(question: String, english: String, audio: Data?, number: Int?, numberSpoken: Bool, ack: Bool = true) {
        var text = question
        if let number = number, !numberSpoken { text = QuestionComposer.numbered(question, number: number) }
        var englishOut = english
        var audioOut = audio
        let effective = number ?? nextNumber
        if let context = passage, context.remaining.contains(effective) {
            let joined = AudioJoin.join(passage: context.audio, question: audio)
            text = QuestionComposer.withPassage(question: text, passage: context, audioCombined: joined.combined)
            englishOut = QuestionComposer.english(passage: context, question: english)
            if joined.data != nil { audioOut = joined.data }
            tlog("[paragraf] soru \(effective) ortak paragrafla birlikte gönderiliyor")
        }
        dispatchQuestion(text, english: englishOut, audio: audioOut, spokenNumber: number, display: question, ack: ack)
    }

    /// Soruyu listeye işler, "yarım kalan iş" olarak deftere yazar (uygulama bu arada kapanırsa yeniden sorulur) ve Gemini'ye gönderir.
    /// `display`: listede görünen metin (ortak paragraf eklenmiş hâli değil). `ack`: "soru gönderildi" anonsu yapılır mı.
    func dispatchQuestion(_ question: String, english: String, audio: Data?, spokenNumber: Int?, display: String? = nil, ack: Bool = false) {
        let announced = spokenNumber ?? nextNumber
        beginEntry(text: display ?? question, withAudio: audio != nil, number: announced)
        deps.journal.savePending(PendingWork(question: question, english: english, spokenNumber: spokenNumber, number: nil, spoken: nil))
        tlog("[soru \(announced)] Gemini'ye gönderildi (\(audio != nil ? "ses kaydıyla" : "yalnız metin"), \(question.count) karakter; numara \(spokenNumber != nil ? "okundu" : "okunmadı, sıradaki"))")
        work = Task { [weak self] in await self?.answer(question: question, english: english, audio: audio, spokenNumber: spokenNumber) }
        if ack, settings.spokenProgress { speakProgress(Say.questionSent) }
        startAnswerWait()
    }

    /// Beklenmedik kapanmadan önce Gemini'ye gitmiş soru yeniden sorulur (ses kaydı kaybolduğu için yalnız metinle); cevabı alınmış ama
    /// duyulmamışsa yalnız cevap yeniden okunur
    func resumePending(_ pending: PendingWork) async {
        if let spoken = pending.spoken, let number = pending.number {
            tlog("[soru \(number)] kapanmadan önce alınan cevap yeniden okunuyor")
            guard await speakNotice(spoken) else { return }
            guard await promptNextQuestion() else { return }
            beginListening()
            return
        }
        phase = .answering
        statusNote = ""
        liveText = pending.question
        tlog("[soru] kapanmadan önce gönderilen soru yeniden soruluyor (yalnız metin)")
        dispatchQuestion(pending.question, english: pending.english, audio: nil, spokenNumber: pending.spokenNumber)
    }

    // MARK: Cevaplama ve seslendirme (Modül 5)

    func answer(question: String, english: String = "", audio: Data?, spokenNumber: Int? = nil) async {
        do {
            let reply = try await deps.answering.answer(question: question, english: english, expectedNumber: spokenNumber ?? nextNumber, audio: audio)
            guard !Task.isCancelled, phase == .answering else { return }
            // Numara önceliği: kullanıcının okuduğu (dikte metninden) > Gemini'nin metinden/sesten okuduğu > sıradaki
            let number = spokenNumber ?? reply.number ?? nextNumber
            let source: QuestionEntry.NumberSource = spokenNumber != nil ? .spoken : (reply.number != nil ? .heard : .sequence)
            nextNumber = number + 1
            // Cevap cümlesi (kulaklıktan okunan ve dosyaya yazılan) her zaman kaydedilen numarayı taşır
            let spoken = reply.number == number ? reply.spoken : AnswerParser.spokenLine(number: number, option: reply.option, text: reply.text, fallback: reply.spoken)
            let record = AnswerRecord(number: number, option: reply.option, text: reply.text, spoken: spoken)
            tlog("[soru \(number)] numara kaynağı: \(source.logName)")
            finishEntry(.answered(record.spoken), number: number, model: reply.model, source: source)
            // Cevap yedek profilden geldiyse sebebi kırmızı kutuda yazılır; ilk profilden gelince silinir
            // Ekranda ayrıntılı not (sunucunun hata metinleri dahil) kalır; kulaklıktan hangi modelin cevapladığı söylenmez, yalnız
            // ücretli modelden geldiyse "Ücretli modelden cevaplandı." denir (hata metinleri hiç okunmaz)
            if reply.note.isEmpty {
                clearWarning("yedek")
            } else {
                let changed = warnings.first(where: { $0.id == "yedek" })?.text != reply.note
                warn("yedek", reply.note)
                if changed, !reply.spokenNote.isEmpty { announce(reply.spokenNote) }
            }
            store(record)
            completePassage(for: number)
            deps.journal.saveNextNumber(nextNumber)
            deps.journal.savePending(PendingWork(question: question, english: english, spokenNumber: spokenNumber, number: number, spoken: record.spoken))
            phase = .speaking
            unheard = record
            var base: URL?
            if let folder = sessionFolder {
                deps.library.removeExisting(question: number, in: folder)
                base = deps.library.fileBase(question: number, in: folder)
            }
            if let task = voiceTask { await task.value }   // çalan bir uyarı varsa bitsin, üst üste konuşulmasın
            guard !Task.isCancelled, phase == .speaking else { return }
            try await deps.speaker.speak(record.spoken, saveAs: base)
            // Okuma durdurulduysa (duraklatma, kulaklık kopması) cevap duyulmamış sayılır; devam edince yeniden okunur
            guard !Task.isCancelled else { return }
            unheard = nil
            clearWarning("cevap")
            clearWarning("ses")
            verifyRecording(number: number, requested: base != nil)
            refreshReplayAvailability()
            await settleAnnouncements()   // cevap duyulduktan sonra bekleyen uyarılar (şarj, ücretli model…) söylenir
            guard !Task.isCancelled, phase == .speaking else { return }
            guard await promptNextQuestion() else { return }   // "Lütfen sonraki soruyu okuyun"; yarıda kesilirse akışı duraklama/onarım sürdürür
            beginListening()
        } catch is CancellationError {
            return
        } catch let error as SpeakError {
            await handleSpeakError(error)
        } catch let error as GeminiError {
            guard !Task.isCancelled else { return }   // iptal edilen istek (bekleme sınırı, duraklatma) onarım başlatmaz
            await handleGeminiError(error)
        } catch {
            guard !Task.isCancelled else { return }
            finishEntry(.failed(error.localizedDescription))
            warn("cevap", error.localizedDescription)
            if phase == .answering || phase == .speaking, await speakNotice(Say.answerFailed) { beginListening() }
        }
    }

    // MARK: Soru listesi (ana ekran)

    /// Tetikleyiciyle yüklenen soru listeye "gönderiliyor" işaretiyle girer
    func beginEntry(text: String, withAudio: Bool, number: Int? = nil) {
        abandonEntry("Cevap alınamadı. Soruyu yeniden okuyun.")
        entrySeq += 1
        currentEntry = entrySeq
        questions.append(QuestionEntry(id: entrySeq, text: text, withAudio: withAudio, number: number ?? nextNumber))
    }

    /// Giden sorunun işaretini günceller (cevap geldi / gitmedi)
    func finishEntry(_ state: QuestionEntry.State, number: Int? = nil, model: String = "", source: QuestionEntry.NumberSource? = nil) {
        guard let id = currentEntry, let index = questions.firstIndex(where: { $0.id == id }) else { return }
        questions[index].state = state
        switch state {
        case .answered: tlog("[soru \(number ?? questions[index].number)] cevap geldi (\(model))")
        case .failed(let reason):
            tlog("[soru \(questions[index].number)] gitmedi: \(reason)")
            deps.journal.savePending(nil)   // kullanıcıdan soruyu yeniden okuması istenir; yarım kalan iş kalmaz
        case .sending: break
        }
        if let number = number { questions[index].number = number }
        if let source = source { questions[index].numberSource = source }
        if !model.isEmpty { questions[index].model = model }
        currentEntry = nil
    }

    /// Cevabı gelmeden iş kesildiyse satır "gitmedi" olur
    func abandonEntry(_ reason: String) {
        if currentEntry != nil { finishEntry(.failed(reason)) }
    }

    private func store(_ record: AnswerRecord) {
        if let index = answers.firstIndex(where: { $0.number == record.number }) {
            answers[index] = record
        } else {
            answers.append(record)
            answers.sort { $0.number < $1.number }
        }
        if let folder = sessionFolder, !deps.library.upsertTranscript(record.spoken, number: record.number, in: folder) {
            warn("yazi", Say.transcriptFailed)
        }
    }

    private func handleSpeakError(_ error: SpeakError) async {
        switch error {
        case .stopped:
            break
        case .routeUnsafe:
            enterHardwarePause(AudioRouting.verdict(deps.route.snapshot()))
        case .failed(let message):
            warn("ses", message)
            guard phase == .speaking else { return }
            // Cevap duyulmadan geçilmesin (sınavda cevap kaybı olur): bir kez, kayıtsız (dosya yazmadan) yeniden okunur.
            // Yine olmazsa cevabın metni kırmızı kutuda kalır; sesli söylenemediği için ayrıca anons edilmez.
            if let record = unheard {
                await deps.sleep(Timing.speakRetryDelay)
                guard !Task.isCancelled, phase == .speaking else { return }
                do {
                    try await deps.speaker.speak(record.spoken, saveAs: nil)
                    unheard = nil
                    clearWarning("ses")
                    tlog("[ses] okuma ikinci denemede oldu: soru \(record.number)")
                    verifyRecording(number: record.number, requested: sessionFolder != nil)   // yeniden okuma dosya yazmaz: eksikse kırmızı kutuda görünür
                    refreshReplayAvailability()
                } catch SpeakError.routeUnsafe {
                    enterHardwarePause(AudioRouting.verdict(deps.route.snapshot()))
                    return
                } catch SpeakError.failed(_) {
                    warn("cevap", "Cevap okunamadı: \(record.spoken)")
                    tlog("[ses] okuma ikinci denemede de olmadı: soru \(record.number)")
                } catch {
                    return
                }
            }
            guard !Task.isCancelled, phase == .speaking else { return }
            guard await promptNextQuestion() else { return }
            beginListening()
        }
    }

    /// Cevabın ses dosyası klasöre gerçekten yazıldı mı: yazılamadıysa (yer doldu, klasör erişimi gitti) kırmızı kutuda ve kulaklıktan bildirilir
    func verifyRecording(number: Int, requested: Bool) {
        guard requested, let folder = sessionFolder else { return }
        let saved = deps.library.answerFiles(in: folder).contains { AnswerLibrary.questionNumber(fromFileName: $0.lastPathComponent) == number }
        if saved {
            clearWarning("kayit")
        } else {
            warn("kayit", Say.recordingFailed(number))
        }
    }

    /// Ağ hatasında (istek düştü) Kestirmelerle onarım; diğer hatalarda kısa sesli bilgi ve yeniden dinleme
    private func handleGeminiError(_ error: GeminiError) async {
        guard phase == .answering else { return }
        finishEntry(.failed(error.kind == .network ? "Gemini'ye ulaşılamadı; bağlantı gelince soruyu yeniden okuyun." : error.message))
        if error.kind == .network {
            warn("cevap", "Gemini'ye ulaşılamadı: \(error.message)")
            await runRecovery(.network)
            return
        }
        warn("cevap", error.message)
        if await speakNotice(Say.geminiFailure(error)) { beginListening() }
    }

    /// Duyulmamış cevabı yeniden okur. Okuma sentez sırasında kesilmişse soru_N dosyası silinmiştir: bu okumada yeniden yazılır, yoksa test
    /// sonundaki tekrar bu cevabı atlardı. Dosya duruyorsa (kesinti çalma sırasında olduysa) üzerine yazılmaz. Sonuna kadar okunduysa true.
    func rereadUnheard(_ record: AnswerRecord) async -> Bool {
        var base: URL?
        if let folder = sessionFolder {
            let exists = deps.library.answerFiles(in: folder).contains { AnswerLibrary.questionNumber(fromFileName: $0.lastPathComponent) == record.number }
            if !exists { base = deps.library.fileBase(question: record.number, in: folder) }
        }
        guard await speakNotice(record.spoken, saveAs: base) else { return false }
        verifyRecording(number: record.number, requested: base != nil)
        refreshReplayAvailability()
        return true
    }

    /// Kısa anons: yalnız kulaklıktan çalar; `saveAs` verilmedikçe kaydedilmez. Sonuna kadar çalındıysa true.
    @discardableResult
    func speakNotice(_ text: String, saveAs: URL? = nil) async -> Bool {
        phase = .speaking
        await settleAnnouncements()   // önce bekleyen uyarılar, sonra bu anons
        guard !Task.isCancelled, phase == .speaking else { return false }
        do {
            try await deps.speaker.speak(text, saveAs: saveAs)
        } catch SpeakError.routeUnsafe {
            enterHardwarePause(AudioRouting.verdict(deps.route.snapshot()))
            return false
        } catch SpeakError.failed(let message) {
            // Okunamayan duyuru işi durdurmaz (yoksa oturum sessizce takılırdı): sebep yazılır, sistem dinlemeye geçer
            warn("ses", message)
        } catch {
            return false
        }
        return !Task.isCancelled && phase == .speaking
    }

    /// Kurtarılamaz bir eksik (izin, dikte modeli): oturum kapanır, sebep ekranda kalır
    func stopForGood(_ message: String) {
        warn("durdu", message)
        cancelWork()
        deps.speaker.stop()
        deps.listener.pause()
        deps.network.stop()
        deps.screen.keepAwake(false)
        phase = .idle
    }
}
