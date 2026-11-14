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
        /// Sessizlikte dinlemeyi yenileyip sağlığa bakmadan önce beklenen süre
        static let silenceProbe: TimeInterval = 4
        /// Bağlantı onarılamazsa yeniden deneme aralığı
        static let connectionRetry: TimeInterval = 60
        /// Üst üste bu kadar donanım onarımı arada tek kelime tanınmadan yapıldıysa sıfırlama döngüsü kesilir
        static let maxHardwareRecoveries = 3
        /// Döngü kesilince bir sonraki deneme için bekleme
        static let hardwareCapRetry: TimeInterval = 300
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
        /// Nabız art arda bu kadar kez boşuna alarm verirse (bağlantı sağlamdı) nabızla onarım bu kadar saniye susturulur
        static let netFalseAlarmLimit = 2
        static let netMuteSeconds: TimeInterval = 600
        /// Arada tek kelime tanınmadan bu kadar "yeniden hazır" anonsundan sonra anons susturulur (döngü kesici)
        static let maxSilentResumes = 3
    }

    // MARK: Ekranın gördüğü durum

    @Published var phase: SessionPhase = .idle {
        didSet {
            if phase != oldValue {
                tlog("[oturum] \(phase.title)")
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
    /// İnternet nabzı boşuna alarm verdi (bağlantı sağlamdı) sayısı; art arda olursa nabızla onarım bir süre susturulur
    var netFalseAlarms = 0
    var netMutedUntil: Date?
    /// Son ağ onarımı çağrısı yanlış alarmdı (bağlantı sağlamdı, hiçbir şey durdurulmadı)
    var lastNetworkAlarmWasFalse = false
    /// Arada tek kelime tanınmadan art arda kaç kez "yeniden hazır" anonsu söylendi (döngü kesici)
    var resumesWithoutSpeech = 0

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
        statusNote = "Test bitti. \(answers.count) cevap kaydedildi."
        refreshReplayAvailability()
    }

    /// seslikontrol://basla ve Kestirmeler dönüşleri
    func handleURL(_ url: URL) {
        if ShortcutLink.isStartURL(url) {
            start()
            return
        }
        deps.shortcuts.handleCallback(url)
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
        netFalseAlarms = 0
        netMutedUntil = nil
        lastNetworkAlarmWasFalse = false
        resumesWithoutSpeech = 0
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
    }

    // MARK: Uyarılar ve kontrol maddeleri

    /// Kulaklıktan zaten başka yerde söylenen ("start": Kontrol başarısız, "cevap": Gemini hatası) ya da kulaklıktan söylenemeyen
    /// ("ses": okuma hatası) uyarılar ayrıca söylenmez
    private static let silentWarnings: Set<String> = ["start", "cevap", "ses"]

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

    /// Mikrofonu açar ve yeni soruyu bekler. Eldeki yarım metin ve ses silinir.
    func beginListening() {
        cancelTimers()
        abandonEntry("Cevap alınamadı. Soruyu yeniden okuyun.")
        unheard = nil
        accumulator.clear()
        englishAccumulator.clear()
        liveText = ""
        liveEnglish = ""
        deps.recorder.reset()
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
            resumesWithoutSpeech = 0
            liveText = accumulator.text
            watchdog.kick()
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

    /// Metnin sonu "Cevapla"/"Gönder" ise kısa bir süre sabit kalmasını bekler; kalırsa tetikler
    private func reevaluateTrigger() {
        confirmTask?.cancel()
        confirmTask = nil
        guard TriggerDetector.match(in: accumulator.text) != nil else { return }
        confirmTask = deps.scheduler.after(Timing.triggerConfirm) { [weak self] in self?.fireTrigger() }
    }

    func fireTrigger() {
        confirmTask = nil
        guard phase == .listening, let match = TriggerDetector.match(in: accumulator.text) else { return }
        guard !match.question.isEmpty else {
            // Yalnız "cevapla" denmiş: boş soru gönderilmez
            accumulator.clear()
            englishAccumulator.clear()
            liveText = ""
            liveEnglish = ""
            return
        }
        // Mikrofon duraklar, tetikleyici sözcük metinden kırpılmıştır; ses kaydı da bu andan sonra durur
        let audio: Data? = settings.sendAudio ? deps.recorder.wavData() : nil
        let english = settings.englishDictation ? englishAccumulator.text : ""
        deps.listener.pause()
        watchdog.disarm()
        liveText = match.question
        phase = .answering
        statusNote = ""
        let question = match.question
        // Kayıt, okunan numarayla yapılır: kullanıcı soruları sırayla okumak zorunda değildir
        let spokenNumber = SpokenNumber.extract(from: question)
        let announced = spokenNumber ?? nextNumber
        beginEntry(text: question, withAudio: audio != nil, number: announced)
        tlog("[soru \(announced)] Gemini'ye gönderildi (\(audio != nil ? "ses kaydıyla" : "yalnız metin"), \(question.count) karakter; numara \(spokenNumber != nil ? "okundu" : "okunmadı, sıradaki"))")
        work = Task { [weak self] in await self?.answer(question: question, english: english, audio: audio, spokenNumber: spokenNumber) }
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
            if reply.note.isEmpty { clearWarning("yedek") } else { warn("yedek", reply.note) }
            store(record)
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
            refreshReplayAvailability()
            await settleAnnouncements()   // cevap duyulduktan sonra bekleyen uyarılar (şarj, yedek model…) söylenir
            guard !Task.isCancelled, phase == .speaking else { return }
            beginListening()
        } catch is CancellationError {
            return
        } catch let error as SpeakError {
            handleSpeakError(error)
        } catch let error as GeminiError {
            await handleGeminiError(error)
        } catch {
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
        case .failed(let reason): tlog("[soru \(questions[index].number)] gitmedi: \(reason)")
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
        if let folder = sessionFolder { deps.library.appendTranscript(record.spoken, in: folder) }
    }

    private func handleSpeakError(_ error: SpeakError) {
        switch error {
        case .stopped:
            break
        case .routeUnsafe:
            enterHardwarePause(AudioRouting.verdict(deps.route.snapshot()))
        case .failed(let message):
            warn("ses", message)
            if phase == .speaking { beginListening() }
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

    /// Kısa anons: kaydedilmez, yalnız kulaklıktan çalar. Sonuna kadar çalındıysa true.
    @discardableResult
    func speakNotice(_ text: String) async -> Bool {
        phase = .speaking
        await settleAnnouncements()   // önce bekleyen uyarılar, sonra bu anons
        guard !Task.isCancelled, phase == .speaking else { return false }
        do {
            try await deps.speaker.speak(text, saveAs: nil)
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
