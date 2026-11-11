import Foundation
import AVFoundation
import AudioToolbox
import Speech

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
    /// Konuşmanın başladığı an (en uzun süre buradan sayılır)
    private(set) var startAt = 0.0
    private(set) var reason: State?

    /// Konuşma başlamadan bu kadar sessizlik, biriken kısa seslerin sayımını sıfırlar
    static let onsetGap = 0.4

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
                if !started && speechTime >= minSpeechTime {
                    started = true
                    startAt = elapsed - speechTime
                }
            } else {
                silenceRun += dt
                // Uzun beklemede dağınık tıkırtılar (kapı, tuş sesi) toplanıp konuşma sayılmasın
                if !started && silenceRun >= EndpointDetector.onsetGap { speechTime = 0 }
            }
            if started && silenceRun >= silenceLimit {
                reason = .done
            } else if !started && elapsed >= noSpeechLimit {
                reason = .noSpeech
            } else if started && elapsed - startAt >= maxLength {
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
    /// done: konuşma bitti (sessizlik); word: kullanıcı "tamam" dedi
    case done, word, noSpeech, max, stopped
    case failed(String)
}

/// Soru kaydı arayüzü (sohbet mantığı sahte kayıtçıyla sınanabilsin diye).
protocol QuestionRecording: AnyObject {
    /// Mikrofonu açar, konuşma bitince (sessizlikte) ya da hata / iptalde döner. pcm: 16 kHz, 16 bit, tek kanal.
    /// `waitForSpeech`: konuşma başlamazsa en çok bu kadar saniye beklenir (.infinity = süresiz).
    func record(waitForSpeech: TimeInterval, onStatus: @escaping (String) -> Void) async -> (pcm: Data, outcome: QuestionOutcome)
    /// "Dinle … tamam": `endWord` true ise kayıt, kullanıcı "tamam" deyince biter (konuşma tanıma çalışabiliyorsa);
    /// konuşmadan sonra `silenceEnd` saniye sessizlik de bitirir. `endWord` false ise eski düzen (kısa sessizlikte biter).
    func record(waitForSpeech: TimeInterval, endWord: Bool, silenceEnd: TimeInterval,
                onStatus: @escaping (String) -> Void) async -> (pcm: Data, outcome: QuestionOutcome)
    func cancel()
}

extension QuestionRecording {
    func record(waitForSpeech: TimeInterval, endWord: Bool, silenceEnd: TimeInterval,
                onStatus: @escaping (String) -> Void) async -> (pcm: Data, outcome: QuestionOutcome) {
        return await record(waitForSpeech: waitForSpeech, onStatus: onStatus)
    }
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
    private var watchdog: Timer?
    private var cancelled = false
    private var waitLimit: TimeInterval = 7
    /// "Tamam" ile bitirme (yalnız ana iş parçacığında değişir)
    private var endWordMode = false
    private var endSilence: TimeInterval = 1.3
    private var wordRecognizer: SFSpeechRecognizer?
    private var wordTask: SFSpeechRecognitionTask?
    private var wordWork: DispatchWorkItem?
    private var wordRestarts = 0
    private let wordLock = NSLock()
    private var wordRequest: SFSpeechAudioBufferRecognitionRequest?
    /// Son kısmi yazıdan sonra "tamam" bu kadar süre değişmeden kalırsa kayıt biter (cümle arasındaki "tamam"ı kesmesin diye)
    static let endWordHold: TimeInterval = 0.7
    /// "Tamam" modunda tek kaydın en uzun süresi (sn)
    static let endWordMaxLength: Double = 120

    // Aşağıdakiler yalnızca `queue` üzerinde değişir
    private var detector = EndpointDetector()
    private var pcm = Data()
    private var signaled = false
    private var lastBuffer = Date()

    /// Konuşma başlamadan önce yalnız son bu kadar ses tutulur (süresiz beklemede bellek şişmesin): 1,2 sn
    private static let preRollBytes = 16000 * 2 * 12 / 10
    /// Bu kadar saniye mikrofondan hiç ses gelmezse kayıt hatayla biter
    private static let silentMicLimit: TimeInterval = 6

    func record(waitForSpeech: TimeInterval, onStatus: @escaping (String) -> Void) async -> (pcm: Data, outcome: QuestionOutcome) {
        return await record(waitForSpeech: waitForSpeech, endWord: false, silenceEnd: 1.3, onStatus: onStatus)
    }

    func record(waitForSpeech: TimeInterval, endWord: Bool, silenceEnd: TimeInterval,
                onStatus: @escaping (String) -> Void) async -> (pcm: Data, outcome: QuestionOutcome) {
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                self.waitLimit = waitForSpeech
                self.endWordMode = endWord
                self.endSilence = silenceEnd
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
                if self.endWordMode {
                    // "Tamam" tanıma izni (sürekli dinleyen komut kapalıysa daha önce istenmemiş olabilir); verilmezse sessizlikle biter
                    SFSpeechRecognizer.requestAuthorization { [weak self] _ in
                        DispatchQueue.main.async { self?.beginAfterPermission(onStatus: onStatus) }
                    }
                } else {
                    self.beginAfterPermission(onStatus: onStatus)
                }
            }
        }
    }

    private func beginAfterPermission(onStatus: @escaping (String) -> Void) {
        guard completion != nil else { return }
        if cancelled {
            finish(.stopped)
            return
        }
        if playCue { AudioServicesPlaySystemSound(1113) }
        let delay = playCue ? 0.4 : 0.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.completion != nil else { return }
            if self.cancelled {
                self.finish(.stopped)
                return
            }
            self.startEngine(onStatus: onStatus)
        }
    }

    private func startEngine(onStatus: @escaping (String) -> Void) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: AudioRoute.categoryOptions)
            try session.setActive(true)
            AudioRoute.preferExternalMic(session)

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
            let limit = waitLimit
            // "Tamam" ile bitirme: konuşma tanıma kullanılabilirse; değilse eski düzen (kısa sessizlikte biter)
            let byWord = endWordMode && startWordRecognition()
            let silence = byWord ? endSilence : 1.3
            queue.sync {
                detector = byWord
                    ? EndpointDetector(silenceEnd: silence, noSpeech: limit, maxLen: QuestionRecorder.endWordMaxLength)
                    : EndpointDetector(noSpeech: limit)
                pcm = Data()
                signaled = false
                lastBuffer = Date()
            }
            if tapInstalled {
                input.removeTap(onBus: 0)
                tapInstalled = false
            }
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                guard let self = self else { return }
                self.wordLock.lock()
                let word = self.wordRequest
                self.wordLock.unlock()
                word?.append(buffer)
                let samples = self.convert(buffer)
                if samples.isEmpty { return }
                self.queue.async { self.consume(samples) }
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
            onStatus(wordRecognizer != nil ? "Dinliyorum — bitirince “tamam” deyin" : "Dinliyorum — sorunuzu söyleyin")

            // Mikrofon sessizce durduysa (başka uygulama aldı, arama geldi) süresiz beklemeye takılmasın
            watchdog?.invalidate()
            watchdog = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                guard let self = self, self.completion != nil else { return }
                let last = self.queue.sync { self.lastBuffer }
                if Date().timeIntervalSince(last) > QuestionRecorder.silentMicLimit {
                    self.finish(.failed("Mikrofondan ses gelmiyor. Başka bir uygulama mikrofonu kullanıyor olabilir."))
                }
            }
        } catch {
            finish(.failed("Mikrofon açılamadı: \(error.localizedDescription)"))
        }
    }

    private func finish(_ outcome: QuestionOutcome) {
        guard let done = completion else { return }
        completion = nil
        watchdog?.invalidate()
        watchdog = nil
        stopWordRecognition()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }
        let recorded: Data = queue.sync { self.pcm }
        done(recorded, outcome)
    }

    // MARK: - "Tamam" tanıma (ana iş parçacığı)

    /// Konuşma tanımayı açar; açılamazsa (izin yok, tanıyıcı kapalı) false: kayıt sessizlikle biter
    private func startWordRecognition() -> Bool {
        stopWordRecognition()
        wordRestarts = 0
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "tr-TR")), recognizer.isAvailable else {
            tlog("[dinle] konuşma tanıma kullanılamıyor, kayıt sessizlikle bitecek")
            return false
        }
        wordRecognizer = recognizer
        beginWordTask()
        return true
    }

    private func beginWordTask() {
        guard let recognizer = wordRecognizer, completion != nil else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        wordLock.lock()
        wordRequest = request
        wordLock.unlock()
        wordTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failed = error != nil
            DispatchQueue.main.async { self?.handleWord(text, isFinal: final, failed: failed, request: request) }
        }
    }

    private func handleWord(_ text: String?, isFinal: Bool, failed: Bool, request: SFSpeechAudioBufferRecognitionRequest) {
        guard completion != nil, wordRecognizer != nil else { return }
        wordLock.lock()
        let current = wordRequest === request
        wordLock.unlock()
        guard current else { return }       // eski görevin geç gelen sonucu
        wordWork?.cancel()
        wordWork = nil
        if let t = text, SpeechMatcher.endsWith(t, words: GeminiText.endWords) {
            if isFinal {
                finish(.word)
            } else {
                // "tamam" son sözcük; bir süre daha söz gelmezse kayıt biter
                let work = DispatchWorkItem { [weak self] in
                    guard let self = self, self.completion != nil else { return }
                    self.finish(.word)
                }
                wordWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + QuestionRecorder.endWordHold, execute: work)
            }
            return
        }
        if isFinal || failed {
            // Tanıma görevi bitti (iPhone görevleri yaklaşık bir dakikada kapatır): yenisi açılır, kayıt sürer
            guard wordRestarts < 40 else { return }
            wordRestarts += 1
            wordLock.lock()
            let old = wordRequest
            wordRequest = nil
            wordLock.unlock()
            old?.endAudio()
            wordTask?.cancel()
            wordTask = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.beginWordTask() }
        }
    }

    private func stopWordRecognition() {
        wordWork?.cancel()
        wordWork = nil
        wordLock.lock()
        let request = wordRequest
        wordRequest = nil
        wordLock.unlock()
        request?.endAudio()
        wordTask?.cancel()
        wordTask = nil
        wordRecognizer = nil
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
        lastBuffer = Date()
        samples.withUnsafeBufferPointer { pcm.append(Data(buffer: $0)) }
        let state = detector.feed(samples)
        let outcome: QuestionOutcome
        switch state {
        case .done: outcome = .done
        case .noSpeech: outcome = .noSpeech
        case .max: outcome = .max
        case .wait:
            // Konuşma başlayana kadar yalnız son 1,2 sn tutulur
            if pcm.count > QuestionRecorder.preRollBytes { pcm = Data(pcm.suffix(QuestionRecorder.preRollBytes)) }
            return
        case .speech: return
        }
        signaled = true
        DispatchQueue.main.async { [weak self] in self?.finish(outcome) }
    }
}
