import Foundation

/// Sohbetin ayarlardan okuduğu değerler (ayar sınıfına bağlanmadan sınanabilsin diye)
struct GeminiOptions {
    var privacyOK: Bool
    var hasKey: Bool
    var docCount: Int
    /// Sorunun başındaki çağrı sözcüğünü atmak için (ayardaki ham metin)
    var callWords: String = GeminiText.defaultCallWord
    /// Oturum: sesli soru başlarken belgeleri hazırlayıp "hazır" der, her cevaptan sonra yeni soruyu kendiliğinden dinler.
    /// Yazılı sorularda uygulanmaz.
    var session: Bool = false
    /// Oturumda bu kadar saniye konuşulmazsa oturum kapanır; 0 = hiç kapanmaz
    var sessionTimeout: Int = 0
    /// Model profilleri ve seçili yuva (aylık harcama sınırı dolunca ücretsiz profile geçmek için)
    var profiles: [GeminiProfileInfo] = []
    var active: Int = 1
    var autoFallback: Bool = false
}

/// Gemini ile belge sohbeti: sesli soru → Drive'daki son PDF'ler + Gemini → sesli cevap.
/// (Windows sürümündeki g526/chat.py'nin karşılığı.) Durum: boşta → dinliyor → düşünüyor → okuyor.
@MainActor
final class GeminiChat: ObservableObject {
    enum Phase: Equatable { case idle, listening, thinking, speaking }

    /// Bundan kısa kayıt soru sayılmaz (16 kHz, 16 bit: 0,4 sn)
    static let minQuestionBytes = 16000 * 2 * 4 / 10

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status = ""
    @Published private(set) var question = ""
    @Published private(set) var answer = ""
    @Published private(set) var error = ""
    @Published private(set) var docNames: [String] = []
    @Published private(set) var notes: [String] = []
    @Published private(set) var turns = 0
    @Published private(set) var tokens = 0
    private(set) var history: [GeminiTurn] = []

    /// Sohbet başlayınca true, bitince false (sürekli dinleyen sesli komut bu sürede durdurulur)
    var onActiveChange: ((Bool) -> Void)?
    /// Metni sesli okutur; okuma başladıysa true döner
    var speak: ((String) -> Bool)?
    var stopSpeaking: (() -> Void)?
    /// Harcama sınırı yüzünden profil değişti (eski, yeni): ayarlar güncellenir
    var onProfileSwitch: ((GeminiProfileInfo, GeminiProfileInfo) -> Void)?
    /// Kullanıcı "model değiştir" dedi: oturum biter, sesli model seçimi başlar
    var onModelChoice: (() -> Void)?

    private let client: GeminiAsking
    private let docs: GeminiDocProviding
    private let recorder: QuestionRecording
    private let options: () -> GeminiOptions
    private var generation = 0
    private var task: Task<Void, Never>?
    /// Okuma bitişini bekleyen akış (oturumda cevap bitmeden mikrofon açılmaz)
    private var waitingForSpeech = false
    private var speechEndedEarly = false
    private var speechDone: CheckedContinuation<Void, Never>?
    /// Bu sohbette şimdiye kadar hazırlanan belge adları ("1 tanesi yeni" diyebilmek için)
    private var seenDocs: Set<String> = []

    init(client: GeminiAsking, docs: GeminiDocProviding, recorder: QuestionRecording, options: @escaping () -> GeminiOptions) {
        self.client = client
        self.docs = docs
        self.recorder = recorder
        self.options = options
    }

    var isActive: Bool { return phase != .idle }

    // MARK: - Dışarıya

    /// Sesli soru başlatır (yazılı soru için `text`). Meşgulse false döner.
    @discardableResult
    func ask(text: String? = nil) -> Bool {
        guard phase == .idle else { return false }
        var typed: String?
        if let t = text {
            let trimmed = t.trimmed
            if trimmed.isEmpty { return false }
            typed = trimmed
        }
        generation += 1
        let gen = generation
        let question = typed
        error = ""
        setPhase(question == nil ? .listening : .thinking, "Hazırlanıyor…")
        task = Task { [weak self] in
            await self?.run(gen: gen, text: question)
        }
        return true
    }

    /// Dinlemeyi / düşünmeyi / okumayı keser; bekleyen cevap yok sayılır.
    func cancel() {
        guard isActive else { return }
        generation += 1
        task?.cancel()
        task = nil
        recorder.cancel()
        stopSpeaking?()
        releaseSpeechWait()
        setPhase(.idle)
    }

    func newConversation() {
        history = []
        turns = 0
        question = ""
        answer = ""
        error = ""
        notes = []
        docNames = []
        seenDocs = []
        tokens = 0
    }

    /// Okuma başladı / bitti haberi (GuidanceSpeaker'dan)
    func speakingChanged(_ speaking: Bool) {
        guard !speaking else { return }
        if waitingForSpeech {
            if let c = speechDone {
                speechDone = nil
                waitingForSpeech = false
                c.resume()
            } else {
                speechEndedEarly = true
            }
            return
        }
        if phase == .speaking { setPhase(.idle) }
    }

    // MARK: - İç işler

    private func setPhase(_ new: Phase, _ text: String = "") {
        let wasActive = isActive
        phase = new
        status = text
        if wasActive != isActive { onActiveChange?(isActive) }
    }

    private func recorderStatus(_ gen: Int, _ text: String) {
        if gen == generation && phase == .listening { status = text }
    }

    /// Hata mesajını yazar ve sesli söyler
    private func fail(_ gen: Int, _ message: String) {
        guard gen == generation else { return }
        error = message
        tlog("[gemini] \(message)")
        if speak?(message) == true {
            setPhase(.speaking, "")
        } else {
            setPhase(.idle)
        }
    }

    private func releaseSpeechWait() {
        waitingForSpeech = false
        speechEndedEarly = false
        if let c = speechDone {
            speechDone = nil
            c.resume()
        }
    }

    /// Metni okutur ve okuma bitene kadar bekler. Okuma başlayamadıysa false döner.
    private func speakAndWait(_ text: String, _ label: String) async -> Bool {
        waitingForSpeech = true
        speechEndedEarly = false
        setPhase(.speaking, label)
        guard speak?(text) == true else {
            waitingForSpeech = false
            return false
        }
        if speechEndedEarly {
            waitingForSpeech = false
            speechEndedEarly = false
            return true
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            speechDone = continuation
        }
        return true
    }

    private func run(gen: Int, text: String?) async {
        // Başlamadan iptal edildiyse mikrofon hiç açılmasın
        guard gen == generation, !Task.isCancelled else { return }
        let opts = options()
        guard opts.privacyOK else {
            return fail(gen, "Önce Gemini bölümündeki gizlilik onayını işaretleyin.")
        }
        guard opts.hasKey else {
            return fail(gen, "Gemini API anahtarı girilmemiş. Ayarlardan yapıştırın.")
        }

        let session = opts.session && text == nil
        if session {
            guard await prepare(gen, opts) else { return }
        }
        while true {
            let again = await runTurn(gen: gen, text: text, session: session)
            guard again, gen == generation, !Task.isCancelled else { return }
        }
    }

    /// Oturum başı: belgeleri hazırlar ve "N belge hazır, sorunuzu bekliyorum" der. Devam edilecekse true.
    private func prepare(_ gen: Int, _ opts: GeminiOptions) async -> Bool {
        setPhase(.thinking, "Belgeler hazırlanıyor…")
        do {
            let fetched = try await docs.fetch(count: opts.docCount)
            guard gen == generation else { return false }
            notes = fetched.notes
            docNames = fetched.docs.map { $0.name }
            if fetched.docs.isEmpty {
                fail(gen, "Okunacak belge bulunamadı. " + fetched.notes.joined(separator: " "))
                return false
            }
            let fresh = seenDocs.isEmpty ? nil : fetched.docs.filter { !seenDocs.contains($0.name) }.count
            seenDocs.formUnion(docNames)
            let line = GeminiText.readyLine(count: fetched.docs.count, new: fresh, warnings: fetched.notes)
            _ = await speakAndWait(line, "Hazırım")
            return gen == generation && !Task.isCancelled
        } catch is CancellationError {
            return false
        } catch let e as GeminiError {
            fail(gen, e.message)
            return false
        } catch {
            fail(gen, error.localizedDescription)
            return false
        }
    }

    /// Soruyu sorar; aylık harcama sınırı dolmuşsa ve ücretsiz bir yedek profil varsa ona geçip aynı soruyu yineler.
    private func askWithFallback(gen: Int, opts: GeminiOptions, text: String, audio: Data?, docs: [GeminiDoc]) async throws -> GeminiAnswer {
        do {
            return try await client.ask(questionText: text, audioWAV: audio, docs: docs, history: history)
        } catch let e as GeminiError where e.kind == .cap {
            let current = GeminiProfiles.active(opts.profiles, active: opts.active)
            guard let target = GeminiProfiles.fallbackTarget(opts.profiles, from: current, auto: opts.autoFallback) else { throw e }
            guard gen == generation, !Task.isCancelled else { throw CancellationError() }
            tlog("[gemini] harcama sınırı doldu: \(current.name) → \(target.name)")
            onProfileSwitch?(current, target)
            _ = await speakAndWait("Aylık harcama sınırı doldu. \(target.name) modeline geçtim.", "Model değişti")
            guard gen == generation, !Task.isCancelled else { throw CancellationError() }
            setPhase(.thinking, "Gemini düşünüyor…")
            return try await client.ask(questionText: text, audioWAV: audio, docs: docs, history: history)
        }
    }

    /// Bir soru-cevap turu. Oturumdaysa ve yeni soru dinlenecekse true döner.
    private func runTurn(gen: Int, text: String?, session: Bool) async -> Bool {
        let opts = options()
        var audio: Data?
        var typed = ""
        if let t = text {
            typed = t
        } else {
            if phase != .listening { setPhase(.listening, "Dinliyorum") }
            // Oturumda bekleme süresini kullanıcı belirler (0 = hiç kapanmaz); oturum dışı tek soruda 7 sn
            let wait: TimeInterval = session ? (opts.sessionTimeout > 0 ? TimeInterval(opts.sessionTimeout) : .infinity) : 7
            let result = await recorder.record(waitForSpeech: wait) { [weak self] line in
                Task { @MainActor in self?.recorderStatus(gen, line) }
            }
            guard gen == generation else { return false }
            switch result.outcome {
            case .stopped:
                setPhase(.idle)
                return false
            case .failed(let message):
                fail(gen, message)
                return false
            case .noSpeech:
                if session {
                    // Belirlenen süre içinde soru gelmedi: oturum sessizce kapanır, çağrı sözcüğüyle yeniden başlatılır
                    setPhase(.idle, "Oturum bitti")
                    return false
                }
                fail(gen, "Soruyu duyamadım. Mikrofonu ve sesi kontrol edip yeniden deneyin.")
                return false
            case .done, .max:
                break
            }
            if result.pcm.count < GeminiChat.minQuestionBytes {
                // Öksürük, kısa tık sesi: oturumda dinlemeye devam, tek soruda hata
                if session { return true }
                fail(gen, "Soruyu duyamadım. Mikrofonu ve sesi kontrol edip yeniden deneyin.")
                return false
            }
            audio = GeminiSupport.wav(fromPCM16: result.pcm)
        }

        do {
            setPhase(.thinking, "Belgeler hazırlanıyor…")
            let fetched = try await docs.fetch(count: opts.docCount)
            guard gen == generation else { return false }
            notes = fetched.notes
            docNames = fetched.docs.map { $0.name }
            if fetched.docs.isEmpty {
                fail(gen, "Okunacak belge bulunamadı. " + fetched.notes.joined(separator: " "))
                return false
            }
            seenDocs.formUnion(docNames)
            status = "Gemini düşünüyor…"
            let reply = try await askWithFallback(gen: gen, opts: opts, text: typed, audio: audio, docs: fetched.docs)
            guard gen == generation else { return false }
            tokens = reply.totalTokens

            if reply.switchModel {
                // "Model değiştir": oturum biter, sesli model seçimi başlar
                setPhase(.idle, "Model seçimi")
                onModelChoice?()
                return false
            }

            let heard = reply.question.isEmpty ? typed : reply.question
            let q = GeminiText.stripTrigger(heard, words: GeminiText.triggerList(for: opts.callWords))
            let spoken = GeminiText.cleanForSpeech(reply.answer)
            if session && reply.close {
                // "Oturumu kapat": vedalaşma okunur, "sonraki sorunuzu bekliyorum" denmez
                _ = await speakAndWait(spoken.isEmpty ? "Oturum kapandı." : spoken, "Oturum kapanıyor")
                guard gen == generation else { return false }
                setPhase(.idle, "Oturum kapandı")
                return false
            }
            if spoken.isEmpty {
                // Soru olmayan ses (gürültü, başkalarının sohbeti): oturumda sessizce dinlemeye devam
                if session { return true }
                fail(gen, "Soruyu anlayamadım. Lütfen yeniden sorun.")
                return false
            }

            question = q
            answer = reply.answer
            history.append(GeminiTurn(question: q.isEmpty ? "(sesli soru)" : q, answer: reply.answer))
            if history.count > GeminiConfig.maxHistory { history.removeFirst(history.count - GeminiConfig.maxHistory) }
            turns += 1
            error = ""
            tlog("[gemini] cevap geldi: \(reply.totalTokens) jeton, \(fetched.docs.count) belge")

            if session {
                let ok = await speakAndWait(spoken + " " + GeminiText.nextQuestionLine, "Cevap okunuyor")
                guard gen == generation else { return false }
                if !ok { setPhase(.idle) }
                return ok
            }
            setPhase(.speaking, "Cevap okunuyor")
            if speak?(spoken) != true {
                setPhase(.idle)
            }
            return false
        } catch is CancellationError {
            return false
        } catch let e as GeminiError {
            fail(gen, e.message)
            return false
        } catch {
            fail(gen, error.localizedDescription)
            return false
        }
    }
}
