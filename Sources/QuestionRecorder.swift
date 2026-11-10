import Foundation
import AVFoundation
import AudioToolbox

/// 16 kHz, 16 bit, tek kanal ses akışında konuşmanın başını ve sonunu (sessizlik) bulur.
/// Windows sürümündeki talk.py `EndpointDetector` ile aynı mantık: 20 ms'lik pencerelerin enerjisi,
/// son 150 pencerenin %20'lik dilimine göre uyarlanan eşik.
struct EndpointDetector {
    enum State: Equatable { case wait, speech, done, noSpeech, max }

    let rate: Int
    private let window: Int
    private let silenceLimit: Double
    private let noSpeechLimit: Double
    private let maxLength: Double
    private let minSpeechTime: Double

    private var rest: [Int16] = []
    private var levels: [Double] = []
    private(set) var elapsed = 0.0
    private(set) var speechTime = 0.0
    private(set) var silenceRun = 0.0
    private(set) var started = false
    private(set) var reason: State?

    init(rate: Int = 16000, silenceEnd: Double = 1.3, noSpeech: Double = 7.0, maxLen: Double = 30.0, minSpeech: Double = 0.25) {
        self.rate = rate
        self.window = rate / 50
        self.silenceLimit = silenceEnd
        self.noSpeechLimit = noSpeech
        self.maxLength = maxLen
        self.minSpeechTime = minSpeech
    }

    private func threshold() -> Double {
        let recent = levels.suffix(150).sorted()
        var floor = 0.0
        if !recent.isEmpty {
            let position = 0.2 * Double(recent.count - 1)
            let lo = Int(position.rounded(.down))
            let hi = min(lo + 1, recent.count - 1)
            floor = recent[lo] + (recent[hi] - recent[lo]) * (position - Double(lo))
        }
        return max(350.0, floor * 2.5 + 120.0)
    }

    /// Yeni örnekleri işler. Durum: wait (bekle), speech (konuşma sürüyor), done (bitti), noSpeech, max.
    mutating func feed(_ samples: [Int16]) -> State {
        if let r = reason { return r }
        rest.append(contentsOf: samples)
        var offset = 0
        while rest.count - offset >= window {
            var sum = 0.0
            for i in offset..<(offset + window) {
                let v = Double(rest[i])
                sum += v * v
            }
            offset += window
            let rms = (sum / Double(window)).squareRoot()
            let loud = rms > threshold()
            levels.append(rms)
            if levels.count > 400 { levels.removeFirst(100) }
            let dt = Double(window) / Double(rate)
            elapsed += dt
            if loud {
                speechTime += dt
                silenceRun = 0
                if speechTime >= minSpeechTime { started = true }
            } else {
                silenceRun += dt
            }
            if started && silenceRun >= silenceLimit {
                reason = .done
            } else if !started && elapsed >= noSpeechLimit {
                reason = .noSpeech
            } else if elapsed >= maxLength {
                reason = .max
            }
            if let r = reason {
                rest.removeAll()
                return r
            }
        }
        rest.removeFirst(offset)
        return started ? .speech : .wait
    }
}

enum QuestionOutcome: Equatable {
    case done, noSpeech, max, stopped
    case failed(String)
}

/// Soru kaydı arayüzü (sohbet mantığı sahte kayıtçıyla sınanabilsin diye).
protocol QuestionRecording: AnyObject {
    /// Mikrofonu açar, konuşma bitince (sessizlikte) ya da hata / iptalde döner. pcm: 16 kHz, 16 bit, tek kanal.
    func record(onStatus: @escaping (String) -> Void) async -> (pcm: Data, outcome: QuestionOutcome)
    func cancel()
}

/// Kendi AVAudioEngine'ini açıp soruyu kaydeder. Sürekli dinleyen `SpeechTrigger` bu sırada durdurulmuş olmalıdır
/// (iki dinleyici aynı anda mikrofonu paylaşmasın).
final class QuestionRecorder: QuestionRecording {
    /// Kayıt başlamadan önce kısa bir "başla" sesi çalınır
    var playCue = true

    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "g526.question")
    private var converter: AVAudioConverter?
    private var target: AVAudioFormat?
    private var tapInstalled = false
    private var completion: ((Data, QuestionOutcome) -> Void)?
    private var timeoutWork: DispatchWorkItem?
    private var cancelled = false

    // Aşağıdakiler yalnızca `queue` üzerinde değişir
    private var detector = EndpointDetector()
    private var pcm = Data()
    private var signaled = false

    func record(onStatus: @escaping (String) -> Void) async -> (pcm: Data, outcome: QuestionOutcome) {
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                self.begin(onStatus: onStatus) { pcm, outcome in
                    continuation.resume(returning: (pcm, outcome))
                }
            }
        }
    }

    func cancel() {
        DispatchQueue.main.async {
            self.cancelled = true
            if self.completion != nil { self.finish(.stopped) }
        }
    }

    // MARK: - Ana iş parçacığı

    private func begin(onStatus: @escaping (String) -> Void, completion: @escaping (Data, QuestionOutcome) -> Void) {
        if self.completion != nil {
            completion(Data(), .failed("Kayıt zaten sürüyor."))
            return
        }
        self.completion = completion
        cancelled = false
        onStatus("Mikrofon hazırlanıyor…")
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self, self.completion != nil else { return }
                if self.cancelled {
                    self.finish(.stopped)
                    return
                }
                guard granted else {
                    self.finish(.failed("Mikrofon izni verilmedi. iPhone Ayarlar bölümünden G526 Kamera için mikrofonu açın."))
                    return
                }
                if self.playCue { AudioServicesPlaySystemSound(1113) }
                let delay = self.playCue ? 0.4 : 0.0
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self = self, self.completion != nil else { return }
                    if self.cancelled {
                        self.finish(.stopped)
                        return
                    }
                    self.startEngine(onStatus: onStatus)
                }
            }
        }
    }

    private func startEngine(onStatus: @escaping (String) -> Void) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
            try session.setActive(true)

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0,
                  let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
                  let converter = AVAudioConverter(from: format, to: target) else {
                throw NSError(domain: "g526.question", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Mikrofon biçimi geçersiz"])
            }
            self.target = target
            self.converter = converter
            queue.sync {
                detector = EndpointDetector()
                pcm = Data()
                signaled = false
            }
            if tapInstalled {
                input.removeTap(onBus: 0)
                tapInstalled = false
            }
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                guard let self = self else { return }
                let samples = self.convert(buffer)
                if samples.isEmpty { return }
                self.queue.async { self.consume(samples) }
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
            onStatus("Dinliyorum — sorunuzu söyleyin")

            let work = DispatchWorkItem { [weak self] in self?.finish(.max) }
            timeoutWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 35, execute: work)
        } catch {
            finish(.failed("Mikrofon açılamadı: \(error.localizedDescription)"))
        }
    }

    private func finish(_ outcome: QuestionOutcome) {
        guard let done = completion else { return }
        completion = nil
        timeoutWork?.cancel()
        timeoutWork = nil
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }
        let recorded: Data = queue.sync { self.pcm }
        done(recorded, outcome)
    }

    // MARK: - Ses işleme

    /// Mikrofonun kendi biçimindeki tamponu 16 kHz / 16 bit / tek kanala çevirir (ses iş parçacığı)
    private func convert(_ buffer: AVAudioPCMBuffer) -> [Int16] {
        guard let converter = converter, let target = target else { return [] }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }
        var supplied = false
        var error: NSError?
        _ = converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if error != nil { return [] }
        guard let channel = out.int16ChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
    }

    /// `queue` üzerinde: örnekleri biriktirir, konuşma bitince ana iş parçacığına haber verir
    private func consume(_ samples: [Int16]) {
        if signaled { return }
        samples.withUnsafeBufferPointer { pcm.append(Data(buffer: $0)) }
        let state = detector.feed(samples)
        let outcome: QuestionOutcome
        switch state {
        case .done: outcome = .done
        case .noSpeech: outcome = .noSpeech
        case .max: outcome = .max
        case .wait, .speech: return
        }
        signaled = true
        DispatchQueue.main.async { [weak self] in self?.finish(outcome) }
    }
}
