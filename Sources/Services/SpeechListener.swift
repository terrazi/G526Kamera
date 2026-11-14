import Foundation
import AVFoundation
import Speech

enum SpeechEvent: Equatable {
    /// Çalışan görevin son kısmi metni
    case partial(String)
    /// Konuşma tanıma görevi bitti ve (dinleme sürüyorsa) yenisi başlatıldı: eldeki metin bölüm olarak saklanmalı
    case taskEnded
    /// Dinleme durdu (donanım ya da tanıyıcı hatası)
    case failure(String)
    /// Konuşma tanıyıcı kendi basamaklarını (görevi yenile, tanıyıcıyı yeniden yarat, ses motorunu yeniden kur) tüketti ya da yeniden
    /// denemekle geçmeyen bir eksik buldu; dinleme durdu. `permanent`: Dikte kapalı ya da model yok. `message`: nedeni (kalıcıysa söylenecek cümle).
    case recognizerDown(message: String, permanent: Bool)
    /// Ses motorunun yapılandırması değişti (giriş cihazı çıktı/geldi, ses servisi sıfırlandı): motor durmuş olabilir, tamponlar gelmeyebilir.
    /// Bildirim gelir gelmez, nabzı beklemeden dinleme yeniden kurulmalıdır.
    case engineStopped
    /// Yardımcı İngilizce tanıyıcının son kısmi metni. "Cevapla" aramasında KULLANILMAZ; yalnız Gemini'ye ikinci metin olarak gider.
    case englishPartial(String)
    /// İngilizce görev bitti ve yenisi başladı: eldeki İngilizce metin bölüm olarak saklanmalı
    case englishTaskEnded
}

enum ListenerError: LocalizedError, Equatable {
    case unavailable
    case noOnDeviceModel
    case noInput
    case engine(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Türkçe konuşma tanıma şu an kullanılamıyor."
        case .noOnDeviceModel: return Say.noOnDevice
        case .noInput: return "Mikrofondan ses gelmiyor. Yaka mikrofonunun alıcısını kontrol edin."
        case .engine(let message): return "Mikrofon başlatılamadı: \(message)"
        }
    }

    /// Donanımla ilgili hata mı (kestirmeyle onarılabilir) yoksa kalıcı bir eksik mi (izin, dikte modeli)
    var isHardware: Bool {
        switch self {
        case .noInput, .engine: return true
        case .unavailable, .noOnDeviceModel: return false
        }
    }
}

/// Apple'ın konuşma tanıma hata kodlarının (SFSpeechRecognitionTask.Error tablosu) bu uygulama için anlamı
enum RecognitionFault: Equatable {
    /// Yeniden denemekle geçmez: Siri/Dikte kapalı ya da çevrimdışı model yüklü değil. Mesaj kullanıcıya söylenir.
    case permanent(String)
    /// Görev düştü (bağlantı kesildi, önceki görev sürüyordu, tanıyıcı başlatılamadı…): yeniden kurmak denenir
    case transient

    static func classify(domain: String, code: Int) -> RecognitionFault {
        guard domain == "kLSRErrorDomain" else { return .transient }
        switch code {
        case 201: return .permanent(Say.dictationOff)      // Siri or Dictation is disabled
        case 102: return .permanent(Say.noOnDevice)        // Assets are not installed
        default: return .transient                         // 300 başlatılamadı, 301 iptal
        }
    }
}

/// Cihaz içi (çevrimdışı) sürekli dinleme
@MainActor
protocol SpeechListening: AnyObject {
    var onEvent: (@MainActor (SpeechEvent) -> Void)? { get set }
    var isRunning: Bool { get }
    /// Mikrofondan en son ses tamponunun geldiği andan beri geçen saniye (hiç gelmediyse nil)
    var secondsSinceAudio: TimeInterval? { get }
    /// Üst üste kaç Türkçe tanıma görevi çabuk bitti (0: tanıma sağlam). Bir görev birkaç saniye hata vermeden yaşarsa ya da metin gelirse sıfırlanır.
    var recognitionStreak: Int { get }
    func start() throws
    /// Mikrofonu ve tanıyıcıyı kapatır; bekleyen sonuçlar yok sayılır
    func pause()
}

/// Mikrofon tamponlarını ses iş parçacığından tanıma isteğine taşıyan, iş parçacığı güvenli kutu
private final class AudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var englishRequest: SFSpeechAudioBufferRecognitionRequest?
    private var last: Date?
    /// Aynı tamponlar soru sesi olarak da biriktirilir (Gemini'ye gönderilmek üzere)
    let recorder: PCMRecorder?

    init(recorder: PCMRecorder?) {
        self.recorder = recorder
    }

    func attach(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        self.request = request
        lock.unlock()
    }

    func attachEnglish(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        englishRequest = request
        lock.unlock()
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let current = request
        let english = englishRequest
        last = Date()
        lock.unlock()
        current?.append(buffer)
        english?.append(buffer)
        recorder?.append(buffer)
    }

    var lastAudio: Date? {
        lock.lock()
        defer { lock.unlock() }
        return last
    }

    func reset() {
        lock.lock()
        request = nil
        englishRequest = nil
        last = nil
        lock.unlock()
    }
}

@MainActor
final class OnDeviceSpeechListener: SpeechListening {
    static let locale = Locale(identifier: "tr-TR")
    /// Tanıyıcıya ipucu: tetikleyici sözcükler ve şık sözcükleri daha doğru yazılsın
    static let contextualStrings = ["Cevapla", "Gönder", "Adana", "Bursa", "Ceyhan", "Denizli", "Erzurum"]
    /// Yardımcı İngilizce tanıyıcı: Türkçe tanıyıcı İngilizce cümleleri Türkçe okunuşlu anlamsız sözcüklerle yazar; aynı ses bir de
    /// İngilizce tanıyıcıdan geçirilir ve Gemini'ye ikinci metin olarak gider ("Cevapla" yine yalnız Türkçe metinde aranır).
    static let englishLocale = Locale(identifier: "en-US")
    /// Yardımcı İngilizce görev üst üste bu kadar çabuk bitip hata verirse bırakılır (Türkçe dinlemeyi hiçbir zaman engellememeli)
    private static let maxQuickFailures = 2
    /// Bundan kısa yaşayan görev "çabuk bitti" sayılır; bundan uzun yaşayan görev tanımanın sağlam olduğunu gösterir
    static let quickLimit: TimeInterval = 1.5
    static let stableAfter: TimeInterval = 3
    /// Türkçe görev üst üste bu kadar çabuk biterse tanıyıcı kendi basamaklarını tüketmiş sayılır: dinleme durur ve `recognizerDown` gelir.
    /// Basamaklar: 1. hata: yardımcı İngilizce bırakılır, görev yenilenir. 2: tanıyıcı nesneleri yeniden yaratılır. 3-4: ses motoru yeniden kurulur.
    static let maxTurkishFailures = 5
    /// Yardımcı İngilizce tanıyıcı ilk çabuk hatada bırakılır (Apple iki çevrimdışı tanıyıcının aynı anda çalışmasını garanti etmez; Türkçe öncelikli)
    static let suspendEnglishAfter = 1
    /// Tanıyıcı nesneleri bu hatada yeniden yaratılır, ses motoru bu hatadan itibaren yeniden kurulur
    static let renewRecognizerAt = 2
    static let rebuildEngineFrom = 3

    /// Hata sayısına göre yeni tanıma görevinden önce beklenecek süre (sn): ilk iki hatada hemen, sonra 0,3 ve 1 sn
    static func restartDelay(afterFailures count: Int) -> TimeInterval {
        switch count {
        case ..<3: return 0
        case 3: return 0.3
        default: return 1
        }
    }

    var onEvent: (@MainActor (SpeechEvent) -> Void)?
    private(set) var isRunning = false

    private var recognizer = SFSpeechRecognizer(locale: OnDeviceSpeechListener.locale)
    private var englishRecognizer = SFSpeechRecognizer(locale: OnDeviceSpeechListener.englishLocale)
    /// İngilizce yardımcı tanıyıcı çalışsın mı (ayardan okunur; her yeni görevde sorulur)
    private let wantsEnglish: () -> Bool
    private var englishTask: SFSpeechRecognitionTask?
    private var englishRequest: SFSpeechAudioBufferRecognitionRequest?
    private var englishStarted = Date()
    private var englishQuickFailures = 0

    /// `recorder` verilirse mikrofon sesi ayrıca ona da akıtılır (dinleme yeniden başlatılsa da kayıt sürer)
    init(recorder: PCMRecorder? = nil, wantsEnglish: @escaping () -> Bool = { true }) {
        sink = AudioSink(recorder: recorder)
        self.wantsEnglish = wantsEnglish
    }
    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private var task: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private let sink: AudioSink
    private var taskStarted = Date()
    private var quickFailures = 0
    private var restartTask: Task<Void, Never>?
    /// Bu dinleme boyunca yardımcı İngilizce tanıyıcı bırakıldı (Türkçe görev üst üste hata verdi)
    private var englishSuspended = false

    var secondsSinceAudio: TimeInterval? {
        guard let last = sink.lastAudio else { return nil }
        return Date().timeIntervalSince(last)
    }

    var recognitionStreak: Int {
        if quickFailures > 0, task != nil, Date().timeIntervalSince(taskStarted) >= OnDeviceSpeechListener.stableAfter {
            quickFailures = 0   // görev birkaç saniyedir hata vermeden yaşıyor: tanıma sağlam
        }
        return quickFailures
    }

    /// Telefonda Türkçe çevrimdışı dikte var mı
    static var onDeviceAvailable: Bool {
        return SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition ?? false
    }

    /// Telefonda İngilizce çevrimdışı dikte var mı (yardımcı tanıyıcı için; yoksa yalnız ses kaydı ve Türkçe metin gider)
    static var englishAvailable: Bool {
        return SFSpeechRecognizer(locale: englishLocale)?.supportsOnDeviceRecognition ?? false
    }

    func start() throws {
        guard !isRunning else { return }
        guard let recognizer = recognizer, recognizer.isAvailable else { throw ListenerError.unavailable }
        guard recognizer.supportsOnDeviceRecognition else { throw ListenerError.noOnDeviceModel }
        quickFailures = 0
        englishSuspended = false
        try startEngine()
        isRunning = true
        beginTask()
        englishQuickFailures = 0
        beginEnglishTask()
    }

    func pause() {
        isRunning = false
        restartTask?.cancel()
        restartTask = nil
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        sink.attach(nil)
        englishRequest?.endAudio()
        englishTask?.cancel()
        englishTask = nil
        englishRequest = nil
        sink.attachEnglish(nil)
        stopEngine()
        sink.reset()
    }

    // MARK: Ses motoru

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw ListenerError.noInput }
        let sink = self.sink
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            sink.feed(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw ListenerError.engine(error.localizedDescription)
        }
        self.engine = engine
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                                queue: .main) { [weak self] _ in
            Task { @MainActor in self?.engineConfigurationChanged() }
        }
    }

    private func engineConfigurationChanged() {
        guard isRunning else { return }
        tlog("[mikrofon] ses motorunun yapılandırması değişti")
        onEvent?(.engineStopped)
    }

    private func stopEngine() {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        guard let engine = engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    // MARK: Tanıma görevi

    private func beginTask() {
        guard isRunning else { return }
        guard let recognizer = recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            tlog("[mikrofon] Türkçe tanıyıcı şu an kullanılamıyor")
            pause()
            onEvent?(.recognizerDown(message: ListenerError.unavailable.localizedDescription, permanent: false))
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        request.contextualStrings = OnDeviceSpeechListener.contextualStrings
        self.request = request
        sink.attach(request)
        taskStarted = Date()
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let finished = (result?.isFinal ?? false) || error != nil
            let info = error.map { RecognitionErrorInfo(domain: ($0 as NSError).domain, code: ($0 as NSError).code, text: $0.localizedDescription) }
            Task { @MainActor in
                self?.handle(text: text, finished: finished, error: info, request: request)
            }
        }
    }

    /// Yardımcı İngilizce görev. Hata verirse ya da model yoksa sessizce vazgeçilir: Türkçe dinleme ve "Cevapla" etkilenmez.
    private func beginEnglishTask() {
        guard isRunning, wantsEnglish(), !englishSuspended, quickFailures == 0, englishQuickFailures < OnDeviceSpeechListener.maxQuickFailures,
              let recognizer = englishRecognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        englishRequest = request
        sink.attachEnglish(request)
        englishStarted = Date()
        englishTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let finished = (result?.isFinal ?? false) || error != nil
            Task { @MainActor in
                self?.handleEnglish(text: text, finished: finished, failed: error != nil, request: request)
            }
        }
    }

    private func handleEnglish(text: String?, finished: Bool, failed: Bool, request: SFSpeechAudioBufferRecognitionRequest) {
        guard isRunning, request === self.englishRequest else { return }
        if let text = text, !text.isEmpty {
            englishQuickFailures = 0
            onEvent?(.englishPartial(text))
        }
        guard finished else { return }
        if failed && Date().timeIntervalSince(englishStarted) < 1.5 { englishQuickFailures += 1 }
        onEvent?(.englishTaskEnded)
        englishTask = nil
        sink.attachEnglish(nil)
        beginEnglishTask()
    }

    private struct RecognitionErrorInfo: Sendable {
        let domain: String
        let code: Int
        let text: String
        var summary: String { return "\(domain) \(code): \(text)" }
    }

    private func handle(text: String?, finished: Bool, error: RecognitionErrorInfo?, request: SFSpeechAudioBufferRecognitionRequest) {
        // Eski (durdurulmuş ya da yenilenmiş) göreve ait gecikmiş sonuçları yok say
        guard isRunning, request === self.request else { return }
        if let text = text, !text.isEmpty {
            quickFailures = 0
            onEvent?(.partial(text))
        }
        guard finished else { return }
        let age = Date().timeIntervalSince(taskStarted)
        let quick = age < OnDeviceSpeechListener.quickLimit
        if quick {
            quickFailures += 1
        } else if age >= OnDeviceSpeechListener.stableAfter {
            quickFailures = 0   // uzun yaşadı: tanıma sağlam, eski çabuk hatalar unutulur
        }
        if let error = error {
            tlog("[mikrofon] tanıma görevi hata verdi\(quick ? " (hemen, üst üste \(quickFailures))" : ""): \(error.summary)")
        } else if quick {
            tlog("[mikrofon] tanıma görevi hata vermeden hemen bitti (üst üste \(quickFailures))")
        }
        onEvent?(.taskEnded)
        if let error = error, case .permanent(let message) = RecognitionFault.classify(domain: error.domain, code: error.code) {
            pause()
            onEvent?(.recognizerDown(message: message, permanent: true))
            return
        }
        if quickFailures >= OnDeviceSpeechListener.maxTurkishFailures {
            pause()
            onEvent?(.recognizerDown(message: error?.summary ?? "görev hemen bitiyor", permanent: false))
            return
        }
        task = nil
        sink.attach(nil)
        // Basamak 1: iki çevrimdışı tanıyıcı çakışıyor olabilir; Türkçe öncelikli, yardımcı İngilizce bırakılır
        if quickFailures >= OnDeviceSpeechListener.suspendEnglishAfter { dropEnglish() }
        // Basamak 2: tanıyıcı nesnesi bozulmuş olabilir (ses servisi sıfırlandıysa); yenileri yaratılır
        if quickFailures == OnDeviceSpeechListener.renewRecognizerAt { renewRecognizers() }
        // Basamak 3-4: ses motoru ve dinleme kancası baştan kurulur (giriş biçimi değişmiş olabilir)
        if quickFailures >= OnDeviceSpeechListener.rebuildEngineFrom, !rebuildEngine() {
            pause()
            onEvent?(.engineStopped)
            return
        }
        // Sessizlik ya da süre sınırı yüzünden biten görev yerine hemen yenisi: dinleme kesilmez
        let delay = OnDeviceSpeechListener.restartDelay(afterFailures: quickFailures)
        guard delay > 0 else {
            beginTask()
            return
        }
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.beginTask()
        }
    }

    private func dropEnglish() {
        guard !englishSuspended else { return }
        englishSuspended = true
        englishRequest?.endAudio()
        englishTask?.cancel()
        englishTask = nil
        englishRequest = nil
        sink.attachEnglish(nil)
        tlog("[mikrofon] Türkçe tanıma düştü; yardımcı İngilizce tanıyıcı bu dinleme boyunca bırakıldı")
    }

    private func renewRecognizers() {
        recognizer = SFSpeechRecognizer(locale: OnDeviceSpeechListener.locale)
        englishRecognizer = SFSpeechRecognizer(locale: OnDeviceSpeechListener.englishLocale)
        tlog("[mikrofon] tanıyıcı nesneleri yeniden yaratıldı")
    }

    private func rebuildEngine() -> Bool {
        tlog("[mikrofon] ses motoru yeniden kuruluyor")
        stopEngine()
        do {
            try startEngine()
            return true
        } catch {
            tlog("[mikrofon] ses motoru kurulamadı: \(error.localizedDescription)")
            return false
        }
    }
}
