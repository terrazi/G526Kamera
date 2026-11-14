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

/// Cihaz içi (çevrimdışı) sürekli dinleme
@MainActor
protocol SpeechListening: AnyObject {
    var onEvent: (@MainActor (SpeechEvent) -> Void)? { get set }
    var isRunning: Bool { get }
    /// Mikrofondan en son ses tamponunun geldiği andan beri geçen saniye (hiç gelmediyse nil)
    var secondsSinceAudio: TimeInterval? { get }
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
    /// Üst üste bu kadar çabuk bitip hata veren görevden sonra dinleme durdurulur
    private static let maxQuickFailures = 5

    var onEvent: (@MainActor (SpeechEvent) -> Void)?
    private(set) var isRunning = false

    private let recognizer = SFSpeechRecognizer(locale: OnDeviceSpeechListener.locale)
    private let englishRecognizer = SFSpeechRecognizer(locale: OnDeviceSpeechListener.englishLocale)
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

    var secondsSinceAudio: TimeInterval? {
        guard let last = sink.lastAudio else { return nil }
        return Date().timeIntervalSince(last)
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
        try startEngine()
        isRunning = true
        beginTask()
        englishQuickFailures = 0
        beginEnglishTask()
    }

    func pause() {
        isRunning = false
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
        guard isRunning, let recognizer = recognizer else { return }
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
            Task { @MainActor in
                self?.handle(text: text, finished: finished, failed: error != nil, request: request)
            }
        }
    }

    /// Yardımcı İngilizce görev. Hata verirse ya da model yoksa sessizce vazgeçilir: Türkçe dinleme ve "Cevapla" etkilenmez.
    private func beginEnglishTask() {
        guard isRunning, wantsEnglish(), englishQuickFailures < OnDeviceSpeechListener.maxQuickFailures,
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

    private func handle(text: String?, finished: Bool, failed: Bool, request: SFSpeechAudioBufferRecognitionRequest) {
        // Eski (durdurulmuş ya da yenilenmiş) göreve ait gecikmiş sonuçları yok say
        guard isRunning, request === self.request else { return }
        if let text = text, !text.isEmpty {
            quickFailures = 0
            onEvent?(.partial(text))
        }
        guard finished else { return }
        if failed && Date().timeIntervalSince(taskStarted) < 1.5 { quickFailures += 1 }
        onEvent?(.taskEnded)
        if quickFailures >= OnDeviceSpeechListener.maxQuickFailures {
            pause()
            onEvent?(.failure("Konuşma tanıma üst üste hata verdi."))
            return
        }
        task = nil
        sink.attach(nil)
        // Sessizlik ya da süre sınırı yüzünden biten görev yerine hemen yenisi: dinleme kesilmez
        beginTask()
    }
}
