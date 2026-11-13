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

    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let current = request
        last = Date()
        lock.unlock()
        current?.append(buffer)
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
        last = nil
        lock.unlock()
    }
}

@MainActor
final class OnDeviceSpeechListener: SpeechListening {
    static let locale = Locale(identifier: "tr-TR")
    /// Tanıyıcıya ipucu: tetikleyici sözcükler ve şık sözcükleri daha doğru yazılsın
    static let contextualStrings = ["Cevapla", "Gönder", "Adana", "Bursa", "Ceyhan", "Denizli", "Erzurum"]
    /// Üst üste bu kadar çabuk bitip hata veren görevden sonra dinleme durdurulur
    private static let maxQuickFailures = 5

    var onEvent: (@MainActor (SpeechEvent) -> Void)?
    private(set) var isRunning = false

    private let recognizer = SFSpeechRecognizer(locale: OnDeviceSpeechListener.locale)

    /// `recorder` verilirse mikrofon sesi ayrıca ona da akıtılır (dinleme yeniden başlatılsa da kayıt sürer)
    init(recorder: PCMRecorder? = nil) {
        sink = AudioSink(recorder: recorder)
    }
    private var engine: AVAudioEngine?
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

    func start() throws {
        guard !isRunning else { return }
        guard let recognizer = recognizer, recognizer.isAvailable else { throw ListenerError.unavailable }
        guard recognizer.supportsOnDeviceRecognition else { throw ListenerError.noOnDeviceModel }
        quickFailures = 0
        try startEngine()
        isRunning = true
        beginTask()
    }

    func pause() {
        isRunning = false
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        sink.attach(nil)
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
    }

    private func stopEngine() {
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
