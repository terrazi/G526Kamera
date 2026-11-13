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
    }

    // MARK: Ekranın gördüğü durum

    @Published var phase: SessionPhase = .idle
    /// Dikte edilen (ve kırpılmış) soru metni
    @Published var liveText = ""
    @Published var answers: [AnswerRecord] = []
    @Published var warnings: [SessionWarning] = []
    @Published var checkup: [CheckItem] = []
    @Published var statusNote = ""
    @Published var canReplay = false
    @Published var routeVerdict: RouteVerdict?

    // MARK: Bağımlılıklar

    let settings: AppSettings
    let deps: SessionDependencies
    let watchdog: SilenceWatchdog
    let recovery: RecoveryCoordinator
    let replay: ReplayController

    // MARK: İç durum (uzantı dosyaları da kullanır)

    var accumulator = TranscriptAccumulator()
    var sessionFolder: URL?
    var nextNumber = 1
    var pendingStart = false
    var work: Task<Void, Never>?
    var confirmTask: ScheduledTask?
    var offlineCheck: ScheduledTask?
    var hardwareGrace: ScheduledTask?
    var stableTask: ScheduledTask?
    var retryTask: ScheduledTask?

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
        deps.network.onChange = { [weak self] online in self?.networkChanged(online) }
        deps.listener.onEvent = { [weak self] event in self?.handleSpeech(event) }
        watchdog.onExpire = { [weak self] in self?.silenceExpired() }
        replay.onState = { [weak self] state in self?.replayChanged(state) }
        refreshReplayAvailability()
    }

    // MARK: Başlat / bitir

    /// Oturumu başlatır: donanım kontrolü, sonra dinleme. El ile düğme, g526kamera://basla, saat ya da bildirim çağırır.
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

    /// g526kamera://basla ve Kestirmeler dönüşleri
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
        liveText = ""
        answers = []
        warnings = []
        checkup = []
        statusNote = ""
        nextNumber = 1
        pendingStart = false
        sessionFolder = nil
    }

    func cancelWork() {
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
    }

    // MARK: Uyarılar ve kontrol maddeleri

    func warn(_ id: String, _ text: String) {
        if let index = warnings.firstIndex(where: { $0.id == id }) {
            warnings[index].text = text
        } else {
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

    func refreshReplayAvailability() {
        let folder = sessionFolder ?? deps.library.latestFolder()
        canReplay = folder.map { !deps.library.answerFiles(in: $0).isEmpty } ?? false
    }

    // MARK: Dinleme (Modül 3)

    /// Mikrofonu açar ve yeni soruyu bekler. Eldeki yarım metin ve ses silinir.
    func beginListening() {
        cancelTimers()
        accumulator.clear()
        liveText = ""
        deps.recorder.reset()
        do {
            try deps.listener.start()
        } catch let error as ListenerError {
            if error.isHardware {
                warn("mikrofon", error.localizedDescription)
                work = Task { [weak self] in await self?.runRecovery(.hardware, force: true) }
            } else {
                stopForGood(error.localizedDescription)
            }
            return
        } catch {
            stopForGood(error.localizedDescription)
            return
        }
        clearWarning("mikrofon")
        phase = .listening
        statusNote = ""
        watchdog.kick()
        if !deps.network.isOnline { scheduleOfflineCheck() }
    }

    func handleSpeech(_ event: SpeechEvent) {
        guard phase == .listening else { return }
        switch event {
        case .partial(let text):
            guard accumulator.update(partial: text) else { return }
            liveText = accumulator.text
            watchdog.kick()
            reevaluateTrigger()
        case .taskEnded:
            accumulator.commitCurrent()
        case .failure(let message):
            warn("mikrofon", message)
            work = Task { [weak self] in await self?.runRecovery(.hardware, force: true) }
        }
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
            liveText = ""
            return
        }
        // Mikrofon duraklar, tetikleyici sözcük metinden kırpılmıştır; ses kaydı da bu andan sonra durur
        let audio: Data? = settings.sendAudio ? deps.recorder.wavData() : nil
        deps.listener.pause()
        watchdog.disarm()
        liveText = match.question
        phase = .answering
        statusNote = ""
        let question = match.question
        work = Task { [weak self] in await self?.answer(question: question, audio: audio) }
    }

    // MARK: Cevaplama ve seslendirme (Modül 5)

    func answer(question: String, audio: Data?) async {
        do {
            let reply = try await deps.answering.answer(question: question, expectedNumber: nextNumber, audio: audio)
            guard !Task.isCancelled, phase == .answering else { return }
            let number = reply.number ?? nextNumber
            nextNumber = number + 1
            let record = AnswerRecord(number: number, option: reply.option, text: reply.text, spoken: reply.spoken)
            store(record)
            phase = .speaking
            var base: URL?
            if let folder = sessionFolder {
                deps.library.removeExisting(question: number, in: folder)
                base = deps.library.fileBase(question: number, in: folder)
            }
            try await deps.speaker.speak(record.spoken, saveAs: base)
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
            warn("cevap", error.localizedDescription)
            if phase == .answering || phase == .speaking { beginListening() }
        }
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
