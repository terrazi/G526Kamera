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
        /// Numara beklenirken anlaşılmayan kısa bir söz bu süre değişmezse numara yeniden sorulur (30 sn beklenmez)
        static let numberUnclear: TimeInterval = 4
        /// Paragrafın soru numaraları bu kadar kez anlaşılamazsa paragraf yalnız sıradaki soruya bağlanır
        static let targetReminderLimit = 2
        /// Konuşmada bu kadar sessizlik olursa sonraki söz yeni bir sözdür (komut yalnız son sözden aranır; eski anlaşılmayan söz engel olmaz)
        static let utteranceGap: TimeInterval = 1
        /// Komut gibi duyulan ama anlaşılmayan söz bu süre değişmezse "anlayamadım" denir
        static let attemptConfirm: TimeInterval = 2.5
        /// Soru metni geldikten sonra bu süre hiçbir şey söylenmezse ve "Cevapla" duyulmadıysa hatırlatılır; bir soruda en çok bu kadar kez
        static let questionIdle: TimeInterval = 20
        static let idleReminderLimit = 2
        /// Paragraf numaraları söylendikten sonra bu süre "Tamam" duyulmazsa program kendisi sorar
        static let targetsIdle: TimeInterval = 4
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
        /// Önceki kayıt bu süreden (12 saat) eskiyse sesli soruya cevap gelmezse "yeni sınav" sayılır (eski cevapların üzerine yazılmasın)
        static let rememberWindow: TimeInterval = 12 * 3600
        /// "Devam mı, yeni mi?" sorusu cevapsız kalırsa en çok bu kadar hatırlatılır, sonra varsayılan uygulanır
        static let choiceReminderLimit = 1
        /// Sürüm 4: internete dönüşte beklenen en uzun süre (sn) ve Gemini gönderiminde ağ hatasından sonra deneme sayısı
        static let cameraInternetWait: TimeInterval = 30
        static let cameraInternetTries = 2
        static let cameraSendTries = 2
        /// Kameraya bağlanılamazsa kamera bağlantısı onarımının (Wi-Fi adımı) en çok kaç kez çalışıp çekimin yeniden deneneceği
        static let cameraRepairs = 2
        /// Kamera çekimi gönderilirken cevap beklemeye eklenen süre (sn) ve telefonda bekletilecek en çok çekim
        static let cameraExtraWait: TimeInterval = 180
        static let pendingShotLimit = 3
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
    /// Önceki oturumdan hatırlanan klasör ve sıradaki numara: uygulama açılırken defterden, "Testi bitir"de bellekten. Yeni başlatmada
    /// içinde cevap varsa "önceki kayıttan devam mı, yeni sınav mı?" diye sorulur.
    struct Carry: Equatable {
        var folder: String
        var nextNumber: Int
        var at: Date
    }
    var carry: Carry?
    /// Başlatırken bulunan ve henüz cevaplanmamış "devam mı, yeni mi?" sorusu
    struct ChoiceOffer: Equatable {
        var answers: Int
        var next: Int
        var recent: Bool
    }
    var choiceOffer: ChoiceOffer?
    var choiceReminders = 0
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
    var targetReminders = 0
    var targetDoneReminders = 0
    var endReminders = 0
    /// Söz bölümleri: son sözün metindeki ilk sözcük sırası, son sessizlikte metinde kaç sözcük vardı, sessizlik geçti mi ve sessizlik zamanlayıcısı
    var utteranceStart = 0
    var settledCount = 0
    var gapPassed = false
    var gapTask: ScheduledTask?
    /// Üst üste anlaşılmayan komut denemesi sayısı; soru başına "Cevapla" hatırlatma sayısı
    var attemptFails = 0
    var idleReminders = 0
    /// Cevaplar baştan okunuyor (oturum açık kalır; okuma bitince "Devam, Tekrar ya da Bitir" sorulur)
    var reviewing = false
    /// Okunan cevap dosyası sayısı (okuma sonunda "N sorunun cevabı okundu" raporu için)
    var reviewCount = 0
    /// Okuma bitince "Devam" denirse dönülecek dinleme kipi
    var reviewReturn: ListenMode = .question
    /// Okumayı kim istedi: testi bitirme isteği mi, yalnız cevapları tekrarlama isteği mi (sessizlikte varsayılan buna göre seçilir)
    var reviewOrigin: ReviewOrigin = .repeatRequest
    var reviewReminders = 0
    /// Tanıyıcının son kısmi metindeki sözcükler için alternatif okumaları (her sözcük için en iyi okuma önde)
    var heardOptions: [[String]] = []
    /// Kesinti (onarım, donanım beklemesi) hangi aşamadayken başladı: dinlerken mi, soru gitmişken (cevap beklenirken) mi
    var interruptedFrom: SessionPhase?
    /// Cevap beklenirken "cevap bekleniyor" anonsu ve 3 dakikalık bekleme sınırı için zamanlayıcı
    var answerWait: ScheduledTask?

    // MARK: Sürüm 4: kamera
    /// Kamera ayarları (V1'deki kamera bölümleri)
    let cameraSettings: CameraSettings
    /// Bir sonraki soru dinlemesinde önce "kamera ile çekmek ister misiniz?" sorulacak
    var offerCamera = false
    /// Kamera akışı (kestirme + çekim + internete dönüş + gönderim) sürüyor
    var cameraBusy = false
    var cameraReminders = 0
    var cameraGuidanceSpeaking = false
    /// Kullanıcı "hayır" dedi ya da kamera akışı olmadı: bu soru sesle okunur, aynı soru için kamera yeniden sorulmaz
    var cameraOfferSuppressed = false
    /// Çekilmiş ama internet olmadığı için gönderilememiş sorular (sırayla gönderilir)
    var pendingShots: [CapturedQuestion] = []
    /// Kendiliğinden yeniden gönderilmesi denenmiş bekleyen çekimler (bkz. `resendablePending`)
    var retriedShots = Set<UUID>()
    var answerWaitElapsed: TimeInterval = 0

    init(settings: AppSettings, deps: SessionDependencies, camera: CameraSettings = CameraSettings()) {
        self.settings = settings
        self.cameraSettings = camera
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
        if let folder = sessionFolder {
            carry = Carry(folder: folder.lastPathComponent, nextNumber: nextNumber, at: deps.now())
        }
        choiceOffer = nil
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
        // Önceki oturumun klasörü ve numarası hatırlanır: yeni başlatmada içinde cevap varsa "devam mı, yeni mi?" diye sorulur
        if let folder = run.folder {
            carry = Carry(folder: folder, nextNumber: run.nextNumber, at: deps.now().addingTimeInterval(-Double(run.downSeconds ?? 0)))
        }
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
        choiceOffer = nil
        choiceReminders = 0
        targetReminders = 0
        reviewing = false
        reviewReminders = 0
        heardOptions = []
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
        abortReview()
        abandonEntry("Kesildi: cevap gelmeden iş durdu. Soruyu yeniden okuyun.")
        work?.cancel()
        work = nil
        if cameraBusy {
            deps.camera.cancel()
            cameraBusy = false
        }
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
    private static let silentWarnings: Set<String> = ["start", "cevap", "ses", "kapanma", "gozcu", "yedek", "numara", "duyulan"]

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
        // Sürüm 4: yeni bir soru sınırında önce "kamera ile çekmek ister misiniz?" sorulur (evet / hayır dinlemesi buradan açılır)
        if mode == .question, !keepPartial, !cameraOfferSuppressed, offerCamera || resendablePending != nil {
            offerCamera = false
            if cameraOfferAvailable {
                work = Task { [weak self] in await self?.askCameraChoice() }
                return
            }
        }
        cancelTimers()
        abandonEntry("Cevap alınamadı. Soruyu yeniden okuyun.")
        deps.journal.savePending(nil)   // dinlemeye dönüldüyse yarım kalan iş yoktur
        unheard = nil
        heardOptions = []
        if keepPartial, !accumulator.isEmpty {
            accumulator.commitCurrent()   // eski görevin yarım metni bölüm olur; yeni görevin metni onun arkasına eklenir
            englishAccumulator.commitCurrent()
            liveText = accumulator.text
            liveEnglish = englishAccumulator.text
            beginNewUtterance()   // yeni görevin sözü, eldeki metnin arkasında yeni bir sözdür
        } else {
            resetUtterances()
            idleReminders = 0
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
        deps.listener.hints = ListenHints.hints(for: mode)
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
            noteUtterance()
            watchdog.kick()
            if listenMode == .question, PassageCommand.startsWith(accumulator.text) {
                listenMode = .passage   // "ortak paragraf": paragraf okunuyor, "Tamam" ile biter
                tlog("[paragraf] ortak paragraf kipi açıldı")
            }
            reevaluateTrigger()
        case .alternatives(let options):
            heardOptions = options
        case .taskEnded:
            accumulator.commitCurrent()
            heardOptions = []
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

    /// Kipe göre tetikleyici sabit kalırsa ateşler: soru ve paragraf numaralarında metnin sonu "Cevapla"/"Gönder", ortak paragrafta "Tamam";
    /// eksik soru numarası beklenirken kısa bir numara cevabı ("soru yedi") ya da "sıradaki"
    private func reevaluateTrigger() {
        confirmTask?.cancel()
        confirmTask = nil
        let text = accumulator.text
        var delay = Timing.triggerConfirm
        // "Cevapları tekrarla": soru, onay, numara ve paragraf numarası beklenirken her an söylenebilir; kısa süre sabit kalırsa çalışır
        if [ListenMode.question, .confirmEnd, .missingNumber, .passageTargets].contains(listenMode), spokenCommand() == .replayAnswers {
            confirmTask = deps.scheduler.after(Timing.numberConfirm) { [weak self] in self?.fireVoiceCommand() }
            return
        }
        switch listenMode {
        case .question:
            // Tek başına söylenen komut ("testi bitir"): kısa süre sabit kalırsa çalışır, "Cevapla" demek gerekmez
            if spokenCommand() != nil {
                confirmTask = deps.scheduler.after(Timing.numberConfirm) { [weak self] in self?.fireVoiceCommand() }
                return
            }
            guard TriggerDetector.match(in: text) != nil else {
                scheduleQuestionChecks()   // komut gibi ama anlaşılmadı mı, "Cevapla" mı duyulmadı: susmak yerine söylenir
                return
            }
        case .passageTargets:
            guard interpret({ TriggerDetector.match(in: $0, words: PassageCommand.targetWords) }) != nil else {
                // Numaralar söylendi ama "Tamam" duyulmadı (ya da hiçbir şey anlaşılmadı): program kendisi sorar
                confirmTask = deps.scheduler.after(Timing.targetsIdle) { [weak self] in self?.targetsIdle() }
                return
            }
        case .passage:
            // Yalnız "ortak paragraf" denmiş, paragraf henüz okunmaya başlanmamış: kısa süre sabit kalırsa kulaklıktan okuma istenir
            if PassageCommand.startsWith(text), PassageCommand.stripStart(text).isEmpty {
                confirmTask = deps.scheduler.after(Timing.numberConfirm) { [weak self] in self?.firePassagePrompt() }
                return
            }
            guard let match = TriggerDetector.match(in: text, words: PassageCommand.finishWords) else { return }
            // "tamam" paragrafın içinde de geçebilir (cümle sonunda): kısa duraklamada bitmez, daha uzun sabit kalmalı
            if TriggerDetector.fold(match.word) == "tamam" { delay = Timing.numberConfirm }
        case .missingNumber:
            guard heldQuestion != nil else { return }
            if numberReply() != nil {
                delay = Timing.numberConfirm
            } else {
                // Kısa ama numara olmayan bir söz duyuldu ("peş", "yedi mi"): 30 sn beklemeden yeniden sorulur. Uzun metin, kullanıcının
                // sonraki soruyu okumaya başladığı demektir; ona karışılmaz.
                guard text.split(whereSeparator: { $0.isWhitespace }).count <= 6 else { return }
                confirmTask = deps.scheduler.after(Timing.numberUnclear) { [weak self] in self?.numberUnclear() }
                return
            }
        case .confirmEnd:
            guard interpret(SpokenReply.yesNo) != nil else { scheduleChoiceUnclear(); return }
            delay = Timing.numberConfirm
        case .startChoice:
            guard interpret(SpokenReply.start) != nil else { scheduleChoiceUnclear(); return }
            delay = Timing.numberConfirm
        case .reviewMenu:
            guard interpret(SpokenReply.review) != nil else { scheduleChoiceUnclear(); return }
            delay = Timing.numberConfirm
        case .cameraChoice:
            guard interpret(SpokenReply.yesNo) != nil else { scheduleChoiceUnclear(); return }
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
        case .confirmEnd: fireConfirmEnd()
        case .startChoice: fireStartChoice()
        case .reviewMenu: fireReview()
        case .cameraChoice: fireCameraChoice()
        }
    }

    /// Mikrofonu kapatır (ses kaydı ve İngilizce metin `fire*` işlevlerinde önceden alınır; dinleme yeniden açılırken metin silinir)
    func closeListening() {
        deps.listener.pause()
        watchdog.disarm()
    }

    /// Tek başına söylenen sesli komutu uygular (soru olarak Gemini'ye gitmez). Soru dinlenirken her komut, onay ve numara beklenirken yalnız
    /// "cevapları tekrarla" çalışır.
    func fireVoiceCommand() {
        confirmTask = nil
        guard phase == .listening, let command = spokenCommand() else { return }
        switch listenMode {
        case .question:
            break
        case .confirmEnd, .missingNumber, .passageTargets:
            guard command == .replayAnswers else { return }
        default:
            return
        }
        run(command)
    }

    private func run(_ command: VoiceCommand) {
        let back = listenMode   // cevaplar okunduktan sonra "Devam" denirse buraya dönülür
        closeListening()
        attemptFails = 0
        clearWarning("duyulan")
        accumulator.clear()
        englishAccumulator.clear()
        liveText = ""
        liveEnglish = ""
        deps.recorder.reset()
        phase = .speaking
        switch command {
        case .endTest:
            // Yanlış tanımaya karşı önce onay istenir: "evet" bitirir, "hayır" (ya da cevapsızlık) devam ettirir
            tlog("[komut] sesli komut: testi bitir; onay isteniyor")
            endReminders = 0
            work = Task { [weak self] in
                guard let self = self, await self.speakNotice(Say.confirmEnd) else { return }
                self.beginListening(mode: .confirmEnd)
            }
        case .repeatLast:
            tlog("[komut] sesli komut: son cevabı tekrarla")
            work = Task { [weak self] in
                guard let self = self else { return }
                guard await self.speakNotice(self.answers.last?.spoken ?? Say.nothingToReplay) else { return }
                self.beginListening()
            }
        case .replayAnswers:
            tlog("[komut] sesli komut: cevapları tekrarla")
            work = Task { [weak self] in await self?.beginReview(origin: .repeatRequest, returnTo: back) }
        }
    }

    /// "Testi bitirmek istiyor musunuz?" sorusuna cevap: evet bitirir (önce cevaplar okunur), hayır devam ettirir
    private func fireConfirmEnd() {
        if interpret(VoiceCommand.parse) == .replayAnswers {
            fireVoiceCommand()
            return
        }
        guard let reply = interpret(SpokenReply.yesNo) else { return }
        clearWarning("duyulan")
        closeListening()
        accumulator.clear()
        englishAccumulator.clear()
        liveText = ""
        liveEnglish = ""
        deps.recorder.reset()
        phase = .speaking
        switch reply {
        case .yes:
            let count = answers.count
            let reading = settings.readAnswersAtEnd && count > 0
            tlog("[komut] testi bitirme onaylandı (\(count) cevap\(reading ? ", cevaplar okunacak" : ""))")
            // Prosedür: bitirmeden önce kaydedilen cevaplar sırayla okunur, ardından "Devam, Tekrar ya da Bitir" sorulur (Modül 6)
            work = Task { [weak self] in
                guard let self = self else { return }
                if reading {
                    await self.beginReview(origin: .endRequest, returnTo: .question)
                } else {
                    await self.completeTestByVoice()
                }
            }
        case .no:
            tlog("[komut] testi bitirmekten vazgeçildi")
            work = Task { [weak self] in
                guard let self = self, await self.speakNotice(Say.endCancelled) else { return }
                self.beginListening(mode: .question)
            }
        }
    }

    /// Evet/hayır ya da devam/yeni beklenirken anlaşılmayan kısa bir söz duyuldu: 30 sn beklemeden yeniden sorulur
    private func scheduleChoiceUnclear() {
        guard accumulator.text.split(whereSeparator: { $0.isWhitespace }).count <= 8 else { return }
        confirmTask = deps.scheduler.after(Timing.numberUnclear) { [weak self] in self?.choiceUnclear() }
    }

    func choiceUnclear() {
        confirmTask = nil
        guard phase == .listening, listenMode == .confirmEnd || listenMode == .startChoice || listenMode == .reviewMenu || listenMode == .cameraChoice else { return }
        let heard = accumulator.text
        if listenMode == .confirmEnd, interpret(SpokenReply.yesNo) != nil { return }
        if listenMode == .startChoice, interpret(SpokenReply.start) != nil { return }
        if listenMode == .reviewMenu, interpret(SpokenReply.review) != nil { return }
        if listenMode == .cameraChoice, interpret(SpokenReply.yesNo) != nil { return }
        tlog("[komut] cevap anlaşılamadı; duyulan: \"\(heard)\"")
        warn("duyulan", "Duyulan: “\(heard)”. Cevap anlaşılamadı.")
        work = Task { [weak self] in await self?.choiceSilence() }
    }

    /// Cevap gelmedi ("evet/hayır" ya da "devam/yeni" denmedi): testi bitirme sorusunda bitirilmez; başlangıç sorusunda bir kez hatırlatılır,
    /// yine olmazsa varsayılan uygulanır (önceki kayıt 12 saatten yeniyse devam, değilse yeni sınav)
    func choiceSilence() async {
        closeListening()
        phase = .speaking
        switch listenMode {
        case .confirmEnd:
            endReminders += 1
            if endReminders <= 1 {
                guard await speakNotice(Say.confirmEndAgain) else { return }
                beginListening(mode: .confirmEnd)
            } else {
                tlog("[komut] testi bitirme sorusu cevapsız kaldı; test devam ediyor")
                clearWarning("duyulan")
                guard await speakNotice(Say.endCancelled) else { return }
                beginListening(mode: .question)
            }
        case .startChoice:
            choiceReminders += 1
            if choiceReminders <= Timing.choiceReminderLimit {
                guard await speakNotice(Say.askChoiceAgain) else { return }
                beginListening(mode: .startChoice)
            } else {
                await applyStartChoice(continuePrevious: choiceOffer?.recent ?? true)
            }
        case .reviewMenu:
            await reviewSilence()
        case .cameraChoice:
            await cameraChoiceSilence()
        default:
            beginListening(mode: .question)
        }
    }

    /// "Önceki kayıttan devam mı, yeni sınav mı?" sorusuna cevap
    private func fireStartChoice() {
        guard let reply = interpret(SpokenReply.start) else { return }
        clearWarning("duyulan")
        closeListening()
        phase = .speaking
        work = Task { [weak self] in await self?.applyStartChoice(continuePrevious: reply == .continuePrevious) }
    }

    /// Devam: önceki klasör ve numara korunur, önceki cevaplar yüklenir. Yeni: yeni klasör, numara 1.
    func applyStartChoice(continuePrevious: Bool) async {
        let offer = choiceOffer
        clearWarning("duyulan")
        choiceOffer = nil
        choiceReminders = 0
        var goOn = continuePrevious
        if !goOn {
            do {
                sessionFolder = try deps.library.newSessionFolder(for: deps.now())
                nextNumber = 1
                answers = []
                deps.journal.saveNextNumber(1)
                if let folder = sessionFolder { deps.journal.saveFolder(folder.lastPathComponent) }
                carry = nil
                tlog("[açılış] yeni sınav seçildi: yeni klasör, numara 1")
            } catch {
                goOn = true
                warn("klasor", "Yeni klasör açılamadı: \(error.localizedDescription). Önceki kayıttan devam ediliyor.")
            }
        }
        if goOn {
            if let folder = sessionFolder { answers = deps.library.transcriptRecords(in: folder) }
            deps.journal.saveNextNumber(nextNumber)
            tlog("[açılış] önceki kayıttan devam: \(offer?.answers ?? answers.count) cevap, sıradaki soru \(nextNumber)")
        }
        let text = goOn ? Say.continuingPrevious(next: nextNumber) : Say.startingNew
        guard await speakNotice(text) else { return }
        beginListening(mode: .question)
    }

    private func fireQuestion() {
        guard let match = TriggerDetector.match(in: accumulator.text) else { return }
        // "Testi bitir, Cevapla": komut kısmı soru gibi gönderilmez
        if let command = commandIn(match.question) {
            run(command)
            return
        }
        guard !match.question.isEmpty else {
            // Yalnız "cevapla" denmiş: boş soru gönderilmez; sesteki "cevapla" sözcüğü bir sonraki soruya karışmasın. Kullanıcıya söylenir:
            // soru duyulmadıysa (okunmadı ya da tanıyıcı kaçırdı) sessizce beklemek "program anlamıyor" izlenimi verir.
            closeListening()
            accumulator.clear()
            englishAccumulator.clear()
            liveText = ""
            liveEnglish = ""
            deps.recorder.reset()
            phase = .speaking
            tlog("[soru] yalnız tetikleyici duyuldu; soru metni yok")
            work = Task { [weak self] in
                guard let self = self, await self.speakNotice(Say.noQuestionHeard) else { return }
                self.beginListening(mode: .question)
            }
            return
        }
        // Mikrofon duraklar, tetikleyici sözcük metinden kırpılmıştır; ses kaydı da bu andan sonra durur
        let audio: Data? = settings.sendAudio ? deps.recorder.wavData() : nil
        let english = settings.englishDictation ? englishAccumulator.text : ""
        let question = match.question
        closeListening()
        attemptFails = 0
        clearWarning("duyulan")
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
        let number: Int
        switch numberReply() {
        case .number(let heard)?: number = heard
        case .sequence?: number = nextNumber
        case nil: return
        }
        closeListening()
        heldQuestion = nil
        numberReminders = 0
        listenMode = .question
        liveText = held.text
        phase = .answering
        statusNote = ""
        clearWarning("numara")
        tlog("[soru] numara söylendi: \(number)")
        send(question: held.text, english: held.english, audio: held.audio, number: number, numberSpoken: false)
    }

    /// Numara beklenirken duyulan söz numara değildi: ne duyulduğu ekranda yazılır, numara yeniden sorulur
    func numberUnclear() {
        confirmTask = nil
        guard phase == .listening, listenMode == .missingNumber, heldQuestion != nil else { return }
        let heard = accumulator.text
        guard numberReply() == nil else { return }
        tlog("[soru] numara anlaşılamadı; duyulan: \"\(heard)\"")
        warn("numara", "Duyulan: “\(heard)”. Numara anlaşılamadı.")
        work = Task { [weak self] in await self?.numberSilence() }
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

    /// "Ortak paragraf" denip beklendi: "Lütfen ortak paragrafı okuyun, bitince Tamam deyin" der ve paragrafı dinler
    private func firePassagePrompt() {
        confirmTask = nil
        guard phase == .listening, listenMode == .passage,
              PassageCommand.startsWith(accumulator.text), PassageCommand.stripStart(accumulator.text).isEmpty else { return }
        closeListening()
        accumulator.clear()
        englishAccumulator.clear()
        liveText = ""
        liveEnglish = ""
        deps.recorder.reset()
        phase = .speaking
        tlog("[paragraf] ortak paragraf komutu duyuldu; paragrafı okuması isteniyor")
        work = Task { [weak self] in
            guard let self = self, await self.speakNotice(Say.passagePrompt) else { return }
            self.beginListening(mode: .passage)
        }
    }

    /// "Tamam" denince ortak paragraf alınır; hangi sorulara ait olduğu sorulur
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
        targetReminders = 0
        targetDoneReminders = 0
        listenMode = .passageTargets
        tlog("[paragraf] ortak paragraf alındı (\(text.count) karakter); hangi sorulara ait olduğu soruluyor")
        work = Task { [weak self] in
            guard let self = self, await self.speakNotice(Say.passageTaken) else { return }
            self.beginListening(mode: .passageTargets)
        }
    }

    /// Paragrafın ait olduğu soru numaraları ("beş altı yedi, Cevapla") alınır; paragraf o sorularla birlikte gider
    private func fireTargets() {
        guard let match = interpret({ TriggerDetector.match(in: $0, words: PassageCommand.targetWords) }) else { return }
        finishTargets(numbers: bestNumbers(primary: SpokenNumber.list(from: match.question)), heard: match.question)
    }

    /// Paragraf numaraları belli oldu (ya da anlaşılamadı): kaydedilir; anlaşılamadıysa sınırlı sayıda yeniden sorulur, sonra sıradaki soruya bağlanır
    func finishTargets(numbers given: [Int], heard: String) {
        var numbers = given
        closeListening()
        liveText = ""
        phase = .speaking
        guard let draft = passageDraft else {
            listenMode = .question
            work = Task { [weak self] in self?.beginListening(mode: .question) }
            return
        }
        var notice: String?
        if numbers.isEmpty {
            targetReminders += 1
            tlog("[paragraf] soru numaraları anlaşılamadı (deneme \(targetReminders)); duyulan: \"\(heard)\"")
            warn("numara", "Duyulan: “\(heard)”. Soru numaraları anlaşılamadı.")
            guard targetReminders > Timing.targetReminderLimit else {
                work = Task { [weak self] in
                    guard let self = self, await self.speakNotice(Say.passageTargetsAgain) else { return }
                    self.beginListening(mode: .passageTargets)
                }
                return
            }
            // Üst üste anlaşılamadı: sonsuz tekrar yerine paragraf sıradaki soruya bağlanır ve bu açıkça söylenir
            numbers = [nextNumber]
            notice = Say.passageFallback(nextNumber)
            tlog("[paragraf] numaralar anlaşılamadı; paragraf sıradaki soruya (\(nextNumber)) bağlandı")
        }
        targetReminders = 0
        targetDoneReminders = 0
        clearWarning("numara")
        passage = PassageContext(text: draft.text, english: draft.english, audio: draft.audio, all: numbers, remaining: numbers,
                                 audioTruncated: draft.audioTruncated)
        passageDraft = nil
        listenMode = .question
        tlog("[paragraf] ortak paragraf \(QuestionComposer.listText(numbers)) numaralı sorular için kaydedildi")
        let spokenNotice = notice ?? Say.passageReady(numbers)
        work = Task { [weak self] in
            guard let self = self, await self.speakNotice(spokenNotice) else { return }
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

    func answer(question: String, english: String = "", audio: Data?, spokenNumber: Int? = nil,
                fetch: (() async throws -> GeminiReply)? = nil) async {
        do {
            let reply: GeminiReply
            if let fetch = fetch {
                reply = try await fetch()   // Sürüm 4: kamera ile çekilen soru (görüntü + video) kendi isteğini yapar
            } else {
                reply = try await deps.answering.answer(question: question, english: english, expectedNumber: spokenNumber ?? nextNumber, audio: audio)
            }
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
