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
        /// Ağ bu kadar süre kesik kalırsa onarım başlar (kısa dalgalanmalar yok sayılır)
        static let offlineDebounce: TimeInterval = 3
        /// Kulaklık/mikrofon bu kadar süre dönmezse sıfırlama kestirmesi çalışır
        static let hardwareGrace: TimeInterval = 20
        /// Donanım geri geldikten sonra bu kadar süre sabit kalırsa devam edilir
        static let routeStable: TimeInterval = 1.5
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
    }

    // MARK: Ekranın gördüğü durum

    @Published var phase: SessionPhase = .idle {
        didSet { if phase != oldValue { tlog("[oturum] \(phase.title)") } }
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
    }

    // MARK: Uyarılar ve kontrol maddeleri

    func warn(_ id: String, _ text: String) {
        if let index = warnings.firstIndex(where: { $0.id == id }) {
            if warnings[index].text != text { tlog("[uyarı] \(id): \(text)") }
            warnings[index].text = text
        } else {
            tlog("[uyarı] \(id): \(text)")
            warnings.append(SessionWarning(id: id, text: text))
        }
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
            work = Task { [weak self] in await self?.runRecovery(.hardware, force: true) }
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
        beginEntry(text: question, withAudio: audio != nil)
        tlog("[soru \(nextNumber)] Gemini'ye gönderildi (\(audio != nil ? "ses kaydıyla" : "yalnız metin"), \(question.count) karakter)")
        work = Task { [weak self] in await self?.answer(question: question, english: english, audio: audio) }
    }

    // MARK: Cevaplama ve seslendirme (Modül 5)

    func answer(question: String, english: String = "", audio: Data?) async {
        do {
            let reply = try await deps.answering.answer(question: question, english: english, expectedNumber: nextNumber, audio: audio)
            guard !Task.isCancelled, phase == .answering else { return }
            let number = reply.number ?? nextNumber
            nextNumber = number + 1
            let record = AnswerRecord(number: number, option: reply.option, text: reply.text, spoken: reply.spoken)
            finishEntry(.answered(record.spoken), number: number, model: reply.model)
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
            try await deps.speaker.speak(record.spoken, saveAs: base)
            // Okuma durdurulduysa (duraklatma, kulaklık kopması) cevap duyulmamış sayılır; devam edince yeniden okunur
            guard !Task.isCancelled else { return }
            unheard = nil
            clearWarning("cevap")
            clearWarning("ses")
            refreshReplayAvailability()
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
            if phase == .answering || phase == .speaking { beginListening() }
        }
    }

    // MARK: Soru listesi (ana ekran)

    /// Tetikleyiciyle yüklenen soru listeye "gönderiliyor" işaretiyle girer
    func beginEntry(text: String, withAudio: Bool) {
        abandonEntry("Cevap alınamadı. Soruyu yeniden okuyun.")
        entrySeq += 1
        currentEntry = entrySeq
        questions.append(QuestionEntry(id: entrySeq, text: text, withAudio: withAudio, number: nextNumber))
    }

    /// Giden sorunun işaretini günceller (cevap geldi / gitmedi)
    func finishEntry(_ state: QuestionEntry.State, number: Int? = nil, model: String = "") {
        guard let id = currentEntry, let index = questions.firstIndex(where: { $0.id == id }) else { return }
        questions[index].state = state
        switch state {
        case .answered: tlog("[soru \(number ?? questions[index].number)] cevap geldi (\(model))")
        case .failed(let reason): tlog("[soru \(questions[index].number)] gitmedi: \(reason)")
        case .sending: break
        }
        if let number = number { questions[index].number = number }
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
