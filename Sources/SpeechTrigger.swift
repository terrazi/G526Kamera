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

    /// `loose`: 3 harfli kısa sözcükler (sol, sağ) için, aynı harfle başlayan ve 1 harf farklı 2–4 harfli
    /// duyumlar da kabul edilir ("so", "sor", "sa", "sak"). Yalnızca soru bekleniyorken açılır.
    static func wordMatches(_ heard: String, _ target: String, loose: Bool = false) -> Bool {
        if heard == target { return true }
        if loose, target.count == 3, heard.count >= 2, heard.count <= 4, heard.first == target.first {
            return distance(heard, target) <= 1
        }
        if min(heard.count, target.count) < 4 { return false }
        return distance(heard, target) <= 1
    }

    /// Seçim sözcükleri (sol, soldaki, sağa…): metinde kümedeki sözcüklerden kaç tane geçtiği.
    /// 5+ harfli sözcüklerde 1 harf fark, `loose` iken `looseTokens` için kısa/bozuk duyumlar kabul edilir.
    static func tokenOccurrences(in transcript: String, tokens: [String], looseTokens: [String], loose: Bool) -> Int {
        var count = 0
        for w in words(transcript) {
            var hit = false
            for t in tokens {
                if w == t || (t.count >= 5 && w.count >= 5 && distance(w, t) <= 1) {
                    hit = true
                    break
                }
            }
            if !hit && loose {
                for t in looseTokens where wordMatches(w, t, loose: true) {
                    hit = true
                    break
                }
            }
            if hit { count += 1 }
        }
        return count
    }

    /// Metinde tetikleme sözcüğünün kaç kez geçtiği.
    static func occurrences(in transcript: String, trigger: String, loose: Bool = false) -> Int {
        let heard = words(transcript)
        let pats = patterns(for: trigger)
        if heard.isEmpty || pats.isEmpty { return 0 }
        var count = 0
        var i = 0
        while i < heard.count {
            var matched = 0
            for p in pats where i + p.count <= heard.count {
                var ok = true
                for k in 0..<p.count where !wordMatches(heard[i + k], p[k], loose: loose && p.count == 1) {
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

/// Esnek komut anlama: aynı niyeti anlatan çok sayıda söyleniş ("hepsini gönder", "tümünü gönder",
/// "pdf yap", "çekimler tamam", "bitirdim"…) tek tek sayılmak yerine sözcük gruplarıyla yakalanır.
/// Tüm sözcükler `SpeechMatcher.words` biçimindedir (küçük harf, aksansız, ı→i).
struct SpeechIntent {
    /// Tek başına yeterli sözcükler ("gönder", "bitirdim", "tamamlandı")
    var strong: Set<String>
    /// Bağlam sözcükleri ("hepsi", "tümü", "sayfalar", "pdf"…)
    var scope: Set<String>
    /// Yalnızca yakınında bir bağlam sözcüğü varsa yeten sözcükler ("tamam", "yap", "çevir"…)
    var weak: Set<String>
    /// Bağlam sözcüğü en çok kaç sözcük uzakta olabilir
    var window = 5

    private func hit(_ word: String, _ set: Set<String>) -> Bool {
        if set.contains(word) { return true }
        if word.count >= 6 {
            for t in set where t.count >= 6 && SpeechMatcher.distance(word, t) <= 1 { return true }
        }
        return false
    }

    func count(in transcript: String) -> Int {
        let w = SpeechMatcher.words(transcript)
        var n = 0
        for i in w.indices {
            if hit(w[i], strong) {
                n += 1
                continue
            }
            if hit(w[i], weak) {
                let lo = max(0, i - window)
                let hi = min(w.count - 1, i + window)
                var found = false
                for j in lo...hi where j != i && hit(w[j], scope) {
                    found = true
                    break
                }
                if found { n += 1 }
            }
        }
        return n
    }
}

/// Sürekli dinleyen, iPhone'un yerleşik Türkçe konuşma tanımasını kullanan tetikleyici.
/// Her şey ana kuyrukta çalışır; ses tamponları yalnızca kilitle korunan isteğe eklenir.
final class SpeechTrigger {
    /// Tetikleme sözcüğü duyuldu (ana iş parçacığı)
    var onTrigger: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    var onHeard: ((String) -> Void)?

    /// Tetikleme sözcüğü dışındaki sesli komutlar ("hepsi tamamlandı", "sol", "sağ"…).
    /// Ya `phrases` (virgülle ayrılmış kalıplar) ya da `tokens` (tek sözcüklük küme) kullanılır.
    struct Command {
        let id: String
        var phrases = ""
        var tokens: [String] = []
        var looseTokens: [String] = []
        /// Esnek niyet eşleştirmesi (kalıplara ek olarak)
        var intent: SpeechIntent?
        var count = 0
    }

    /// Komut duyuldu: (kimlik, duyulan metin), ana iş parçacığı
    var onCommand: ((String, String) -> Void)?
    /// Bir seçim sorusu beklenirken true: "sol/sağ" gibi kısa sözcükler gevşek eşleştirilir ve
    /// komut olmayan konuşma `onUnrecognized` ile bildirilir.
    var choiceMode = false {
        didSet {
            if choiceMode && !oldValue { restartTask(after: 0.1) }
            if !choiceMode { unrecognizedWork?.cancel() }
        }
    }
    /// Konuşma duyuldu ama hiçbir komuta uymadı ("komut anlaşılmadı"); yalnızca `choiceMode` iken
    var onUnrecognized: ((String) -> Void)?
    private var unrecognizedWork: DispatchWorkItem?
    /// Uygulama konuşurken (sesli yönlendirme) true: duyulanlar yok sayılır, bitince dinleme yenilenir
    var suppressed = false {
        didSet {
            if suppressed { unrecognizedWork?.cancel() }
            if oldValue && !suppressed { restartTask(after: 0.4) }
        }
    }
    private(set) var commands: [Command] = []

    func setCommands(_ list: [Command]) {
        commands = list
    }

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
        unrecognizedWork?.cancel()
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
        for c in commands {
            for p in SpeechMatcher.patterns(for: c.phrases) {
                let phrase = p.joined(separator: " ")
                hints.append(phrase)
                hints.append(phrase.capitalized)
            }
        }
        // Seçim sözcüklerinin ASR'nin tanıyacağı biçimleri (aksanlı yazım) bağlam ipucu olur
        hints.append(contentsOf: ["sol", "sağ", "orta", "sol taraf", "sağ taraf", "sol sütun", "sağ sütun",
                                  "sol sayfa", "sağ sayfa", "soldaki", "sağdaki", "ortadaki", "ikisi", "ikisi birden"])
        req.contextualStrings = hints
        if #available(iOS 16.0, *) { req.addsPunctuation = false }

        lastCount = 0
        for i in commands.indices { commands[i].count = 0 }
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

    /// Konuşma durulunca (1,8 sn sessizlik) hâlâ hiçbir komut çıkmadıysa "anlaşılmadı" bildirilir.
    private func scheduleUnrecognized(_ text: String) {
        unrecognizedWork?.cancel()
        let heard = SpeechMatcher.words(text)
        guard heard.contains(where: { $0.count >= 2 }) else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.running, self.choiceMode, !self.suppressed else { return }
            self.onUnrecognized?(text)
            self.restartTask(after: 0.2)
        }
        unrecognizedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }

    private func handle(text: String?, alternatives: [String], isFinal: Bool,
                        hasResult: Bool, error: Error?, token t: Int) {
        guard running, t == token else { return }

        if hasResult, let text = text {
            failures = 0
            onHeard?(text)
            // Uygulama konuşurken kendi sesini duymasın: sonuçlar atılır, konuşma bitince görev yenilenir
            if suppressed { return }
            let candidates = [text] + alternatives
            var best = 0
            for candidate in candidates {
                best = max(best, SpeechMatcher.occurrences(in: candidate, trigger: trigger))
            }
            var firedMain = false
            if best > lastCount {
                lastCount = best
                firedMain = true
            }
            var firedIDs: [String] = []
            for i in commands.indices {
                var b = 0
                for candidate in candidates {
                    if let intent = commands[i].intent { b = max(b, intent.count(in: candidate)) }
                    if commands[i].tokens.isEmpty {
                        b = max(b, SpeechMatcher.occurrences(in: candidate, trigger: commands[i].phrases))
                    } else {
                        b = max(b, SpeechMatcher.tokenOccurrences(in: candidate, tokens: commands[i].tokens,
                                                                  looseTokens: commands[i].looseTokens,
                                                                  loose: choiceMode))
                    }
                }
                if b > commands[i].count {
                    commands[i].count = b
                    firedIDs.append(commands[i].id)
                }
            }
            // Aynı duyum hem "sol" hem "sağ"a benziyorsa ("sal") karar verilemez: seçim yok sayılır
            let choiceIDs = firedIDs.filter { $0.hasPrefix("choice.") }
            var ids = firedIDs.filter { !$0.hasPrefix("choice.") }
            if choiceIDs.count == 1 && !ids.contains("finish") && !ids.contains("rechoose") { ids += choiceIDs }
            if firedMain || !firedIDs.isEmpty {
                unrecognizedWork?.cancel()
                if ids.isEmpty && !firedMain && choiceIDs.count > 1 { onUnrecognized?(text) }
                tlog("[ses] duyuldu: “\(text)” → \(firedMain ? "tetik " : "")\(ids.joined(separator: ","))")
                if firedMain { onTrigger?(text) }
                for id in ids { onCommand?(id, text) }
                restartTask(after: 0.25)
                return
            }
            if choiceMode { scheduleUnrecognized(text) }
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
