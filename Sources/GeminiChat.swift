import Foundation

/// Sohbetin ayarlardan okuduğu değerler (ayar sınıfına bağlanmadan sınanabilsin diye)
struct GeminiOptions {
    var privacyOK: Bool
    var hasKey: Bool
    var docCount: Int
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

    private let client: GeminiAsking
    private let docs: GeminiDocProviding
    private let recorder: QuestionRecording
    private let options: () -> GeminiOptions
    private var generation = 0
    private var task: Task<Void, Never>?

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
        tokens = 0
    }

    /// Okuma başladı / bitti haberi (GuidanceSpeaker'dan)
    func speakingChanged(_ speaking: Bool) {
        if !speaking && phase == .speaking { setPhase(.idle) }
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

        var audio: Data?
        var typed = ""
        if let t = text {
            typed = t
        } else {
            let result = await recorder.record { [weak self] line in
                Task { @MainActor in self?.recorderStatus(gen, line) }
            }
            guard gen == generation else { return }
            switch result.outcome {
            case .stopped:
                return setPhase(.idle)
            case .failed(let message):
                return fail(gen, message)
            case .done, .noSpeech, .max:
                break
            }
            if result.outcome == .noSpeech || result.pcm.count < GeminiChat.minQuestionBytes {
                return fail(gen, "Soruyu duyamadım. Mikrofonu ve sesi kontrol edip yeniden deneyin.")
            }
            audio = GeminiSupport.wav(fromPCM16: result.pcm)
        }

        do {
            setPhase(.thinking, "Belgeler hazırlanıyor…")
            let fetched = try await docs.fetch(count: opts.docCount)
            guard gen == generation else { return }
            notes = fetched.notes
            docNames = fetched.docs.map { $0.name }
            if fetched.docs.isEmpty {
                return fail(gen, "Okunacak belge bulunamadı. " + fetched.notes.joined(separator: " "))
            }
            status = "Gemini düşünüyor…"
            let reply = try await client.ask(questionText: typed, audioWAV: audio, docs: fetched.docs, history: history)
            guard gen == generation else { return }

            let heard = reply.question.isEmpty ? typed : reply.question
            let q = GeminiText.stripTrigger(heard, words: GeminiText.triggerList)
            question = q
            answer = reply.answer
            tokens = reply.totalTokens
            history.append(GeminiTurn(question: q.isEmpty ? "(sesli soru)" : q, answer: reply.answer))
            if history.count > GeminiConfig.maxHistory { history.removeFirst(history.count - GeminiConfig.maxHistory) }
            turns += 1
            error = ""
            tlog("[gemini] cevap geldi: \(reply.totalTokens) jeton, \(fetched.docs.count) belge")
            setPhase(.speaking, "Cevap okunuyor")
            if speak?(GeminiText.cleanForSpeech(reply.answer)) != true {
                setPhase(.idle)
            }
        } catch is CancellationError {
            return
        } catch let e as GeminiError {
            fail(gen, e.message)
        } catch {
            fail(gen, error.localizedDescription)
        }
    }
}
