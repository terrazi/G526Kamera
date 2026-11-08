import Foundation
import Speech
import AVFoundation

/// Türkçe sesli komut eşleştirme (konuşma tanıma çıktısı ile tetikleme sözcüğü).
enum SpeechMatcher {
    static let turkish = Locale(identifier: "tr_TR")

    /// Küçük harfe çevirir, Türkçe harfleri sadeleştirir ve sözcüklere böler.
    static func words(_ text: String) -> [String] {
        var s = text.lowercased(with: turkish)
        s = s.folding(options: [.diacriticInsensitive], locale: turkish)
        s = s.replacingOccurrences(of: "ı", with: "i")
        var result: [String] = []
        var current = ""
        for scalar in s.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Virgülle ayrılmış tetikleme sözcükleri; "okey" için yaygın yazılışlar da eklenir.
    static func patterns(for trigger: String) -> [[String]] {
        var result: [[String]] = []
        for part in trigger.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let w = words(String(part))
            if w.isEmpty { continue }
            result.append(w)
            if w == ["okey"] {
                result.append(["okay"])
                result.append(["oke"])
                result.append(["ok"])
            }
        }
        return result
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a)
        let y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[y.count]
    }

    static func wordMatches(_ heard: String, _ target: String) -> Bool {
        if heard == target { return true }
        if min(heard.count, target.count) < 4 { return false }
        return distance(heard, target) <= 1
    }

    /// Metinde tetikleme sözcüğünün kaç kez geçtiği.
    static func occurrences(in transcript: String, trigger: String) -> Int {
        let heard = words(transcript)
        let pats = patterns(for: trigger)
        if heard.isEmpty || pats.isEmpty { return 0 }
        var count = 0
        var i = 0
        while i < heard.count {
            var matched = 0
            for p in pats where i + p.count <= heard.count {
                var ok = true
                for k in 0..<p.count where !wordMatches(heard[i + k], p[k]) {
                    ok = false
                    break
                }
                if ok { matched = max(matched, p.count) }
            }
            if matched > 0 {
                count += 1
                i += matched
            } else {
                i += 1
            }
        }
        return count
    }
}

/// Sürekli dinleyen, iPhone'un yerleşik Türkçe konuşma tanımasını kullanan tetikleyici.
/// Her şey ana kuyrukta çalışır; ses tamponları yalnızca kilitle korunan isteğe eklenir.
final class SpeechTrigger {
    /// Tetikleme sözcüğü duyuldu (ana iş parçacığı)
    var onTrigger: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    var onHeard: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "tr-TR"))
    private let engine = AVAudioEngine()
    private let requestLock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var running = false
    private var trigger = "okey"
    private var lastCount = 0
    private var failures = 0
    private var token = 0
    private var startWork: DispatchWorkItem?
    private var refreshTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var tapInstalled = false

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: .main) { [weak self] note in
            guard let self = self, self.running else { return }
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            if AVAudioSession.InterruptionType(rawValue: raw) == .ended {
                self.restartAll(after: 0.6, reason: "kesinti bitti")
            } else {
                self.onStatus?("Ses kesildi (arama / başka uygulama)")
            }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                            object: engine, queue: .main) { [weak self] _ in
            guard let self = self, self.running else { return }
            self.restartAll(after: 0.4, reason: "ses yönlendirmesi değişti")
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.running else { return }
            self.restartAll(after: 0.5, reason: "ses servisi sıfırlandı")
        })
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: - Dış arayüz

    func start(trigger word: String) {
        stop()
        trigger = word
        running = true
        onStatus?("İzinler isteniyor…")
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self = self, self.running else { return }
                guard status == .authorized else {
                    self.onStatus?("Konuşma tanıma izni verilmedi (Ayarlar > G526 Kamera)")
                    return
                }
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    DispatchQueue.main.async {
                        guard self.running else { return }
                        guard granted else {
                            self.onStatus?("Mikrofon izni verilmedi (Ayarlar > G526 Kamera)")
                            return
                        }
                        self.startEngine()
                    }
                }
            }
        }
    }

    func stop() {
        running = false
        startWork?.cancel()
        startWork = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        token += 1
        endRequest()
        task?.cancel()
        task = nil
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Ses motoru

    private func startEngine() {
        guard running else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
            try session.setActive(true)

            if engine.isRunning { engine.stop() }
            let input = engine.inputNode
            if tapInstalled {
                input.removeTap(onBus: 0)
                tapInstalled = false
            }
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw NSError(domain: "g526.speech", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Mikrofon biçimi geçersiz"])
            }
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                guard let self = self else { return }
                self.requestLock.lock()
                let r = self.request
                self.requestLock.unlock()
                r?.append(buffer)
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
        } catch {
            tlog("[ses] mikrofon açılamadı: \(error.localizedDescription)")
            onStatus?("Mikrofon açılamadı, tekrar deneniyor…")
            restartAll(after: 3, reason: "mikrofon hatası")
            return
        }
        scheduleStart(after: 0)
    }

    private func restartAll(after delay: TimeInterval, reason: String) {
        guard running else { return }
        tlog("[ses] yeniden başlatılıyor: \(reason)")
        startWork?.cancel()
        token += 1
        endRequest()
        task?.cancel()
        task = nil
        if engine.isRunning { engine.stop() }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.running else { return }
            self.startEngine()
        }
        startWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Tanıma görevi

    private func endRequest() {
        requestLock.lock()
        let r = request
        request = nil
        requestLock.unlock()
        r?.endAudio()
    }

    private func scheduleStart(after delay: TimeInterval) {
        guard running else { return }
        startWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.running else { return }
            if self.engine.isRunning {
                self.startTask()
            } else {
                self.startEngine()
            }
        }
        startWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func restartTask(after delay: TimeInterval) {
        guard running else { return }
        token += 1
        refreshTimer?.invalidate()
        refreshTimer = nil
        endRequest()
        task?.cancel()
        task = nil
        scheduleStart(after: delay)
    }

    private func startTask() {
        guard running else { return }
        guard let recognizer = recognizer else {
            onStatus?("Türkçe konuşma tanıma bu cihazda yok")
            return
        }
        guard recognizer.isAvailable else {
            onStatus?("Konuşma tanıma şu an kullanılamıyor, tekrar deneniyor…")
            scheduleStart(after: 3)
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .confirmation
        let onDevice = recognizer.supportsOnDeviceRecognition
        if onDevice { req.requiresOnDeviceRecognition = true }
        var hints: [String] = []
        for p in SpeechMatcher.patterns(for: trigger) {
            let phrase = p.joined(separator: " ")
            hints.append(phrase)
            hints.append(phrase.capitalized)
        }
        req.contextualStrings = hints
        if #available(iOS 16.0, *) { req.addsPunctuation = false }

        lastCount = 0
        token += 1
        let myToken = token
        requestLock.lock()
        request = req
        requestLock.unlock()

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let alternatives = result?.transcriptions.prefix(3).map { $0.formattedString } ?? []
            let isFinal = result?.isFinal ?? false
            let hasResult = result != nil
            DispatchQueue.main.async {
                self?.handle(text: text, alternatives: alternatives, isFinal: isFinal,
                             hasResult: hasResult, error: error, token: myToken)
            }
        }

        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: false) { [weak self] _ in
            self?.restartTask(after: 0.1)
        }

        let shown = SpeechMatcher.patterns(for: trigger).first?.joined(separator: " ") ?? trigger
        onStatus?("Dinleniyor — “\(shown)” deyin" + (onDevice ? "" : " (internet gerekir)"))
    }

    private func handle(text: String?, alternatives: [String], isFinal: Bool,
                        hasResult: Bool, error: Error?, token t: Int) {
        guard running, t == token else { return }

        if hasResult, let text = text {
            failures = 0
            onHeard?(text)
            var best = 0
            for candidate in [text] + alternatives {
                best = max(best, SpeechMatcher.occurrences(in: candidate, trigger: trigger))
            }
            if best > lastCount {
                lastCount = best
                tlog("[ses] tetikleme duyuldu: “\(text)”")
                onTrigger?(text)
                restartTask(after: 0.25)
                return
            }
            if isFinal {
                restartTask(after: 0.1)
                return
            }
        }

        if let error = error {
            let code = (error as NSError).code
            // 1110: konuşma yok, 203: tekrar dene, 216/301: iptal edildi
            let benign = [1110, 203, 216, 301].contains(code)
            if !benign { failures += 1 }
            let delay = benign ? 0.2 : min(0.5 * Double(failures), 5.0)
            if !benign { tlog("[ses] tanıma hatası \(code): \(error.localizedDescription)") }
            restartTask(after: delay)
        }
    }
}
