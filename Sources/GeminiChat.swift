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
    /// Drive'dan okumadan önce bekleyen (toplu modda biriken) fotoğrafları gönderip bekler; hâlâ yüklenmeyen sayıyı döndürür
    var flushUploads: (() async -> Int)?
    /// Toplu cevap kullanıcıya SONUNA KADAR okunup ulaşınca çağrılır (parametre: verilen en büyük soru numarası); kalıcı sıra buradan ilerler
    var onBatchProgress: ((Int) -> Void)?

    private let client: GeminiAsking
    private let docs: GeminiDocProviding
    private let recorder: QuestionRecording
    private let options: () -> GeminiOptions
    private let memory: GeminiMemoryProviding?
    private let lastStore: LastAnswerStore
    /// Son verilen cevap (diskte de durur): "son yanıtı tekrarla" Gemini'ye gitmeden buradan okunur
    private(set) var last: LastAnswer?
    /// Okuma sonuna kadar bitince çağrılacak iş (toplu cevap sırası); kesilen okumada çağrılmaz
    private var pendingReceived: (() -> Void)?
    /// Bundan uzun sesli istek "tekrarla" olamaz, doğrudan soru sayılır (5 sn, 16 kHz 16 bit + WAV başlığı)
    static let repeatMaxBytes = 16000 * 2 * 5 + 44
    private var generation = 0
    private var task: Task<Void, Never>?
    /// Okuma bitişini bekleyen akış (oturumda cevap bitmeden mikrofon açılmaz)
    private var waitingForSpeech = false
    private var speechEndedEarly = false
    private var speechDone: CheckedContinuation<Void, Never>?
    /// Bu sohbette şimdiye kadar hazırlanan belge adları ("1 tanesi yeni" diyebilmek için)
    private var seenDocs: Set<String> = []
    /// Oturumda art arda yaşanan geçici hata sayısı (üstünde oturum biter)
    private var softErrors = 0
    /// Bu hatalar oturumu bitirmez: hata söylenir, dinlemeye devam edilir (anahtar, model, kota ve harcama sınırı bitirir)
    static let softErrorKinds: Set<GeminiErrorKind> = [.network, .http, .empty, .blocked, .error]
    static let maxSoftErrors = 2

    init(client: GeminiAsking, docs: GeminiDocProviding, recorder: QuestionRecording, options: @escaping () -> GeminiOptions,
         memory: GeminiMemoryProviding? = nil, lastStore: LastAnswerStore = LastAnswerStore()) {
        self.client = client
        self.docs = docs
        self.recorder = recorder
        self.options = options
        self.memory = memory
        self.lastStore = lastStore
        self.last = lastStore.load()
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
        pendingReceived = nil
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
        pendingReceived = nil
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
    /// completed: konuşma kesilmeden sonuna kadar okundu mu (false: kesildi/iptal/bitiş haberi gelmedi)
    func speakingChanged(_ speaking: Bool, completed: Bool = true) {
        guard !speaking else { return }
        let received = pendingReceived
        pendingReceived = nil
        if completed { received?() }
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

    /// Drive'dan okumadan önce bekleyen fotoğrafları gönderir; hâlâ yüklenmeyen fotoğraf sayısını döndürür
    private func syncUploads() async -> Int {
        guard let flush = flushUploads else { return 0 }
        return await flush()
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
    private func speakAndWait(_ text: String, _ label: String, received: (() -> Void)? = nil) async -> Bool {
        waitingForSpeech = true
        speechEndedEarly = false
        setPhase(.speaking, label)
        pendingReceived = received
        guard speak?(text) == true else {
            waitingForSpeech = false
            pendingReceived = nil
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
        softErrors = 0
        await runLoop(gen: gen, text: text, session: session, opts: opts)
        if session, let memory = memory {
            // Oturum bitti: önbellek silinir (saklama ücreti işlemesin). İptal edilen görevden bağımsız çalışsın diye ayrı görev.
            Task { @MainActor in await memory.release() }
        }
    }

    private func runLoop(gen: Int, text: String?, session: Bool, opts: GeminiOptions) async {
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
            let unsent = await syncUploads()
            let fetched = try await docs.fetch(count: opts.docCount)
            guard gen == generation else { return false }
            var allNotes = fetched.notes
            if unsent > 0 { allNotes.append(GeminiText.unsentNote(unsent)) }
            notes = allNotes
            docNames = fetched.docs.map { $0.name }
            if fetched.docs.isEmpty {
                fail(gen, "Okunacak belge bulunamadı. " + allNotes.joined(separator: " "))
                return false
            }
            let prepared = try await memorize(docs: fetched.docs, notes: &allNotes, session: true)
            guard gen == generation else { return false }
            notes = allNotes
            docNames = prepared.docs.map { $0.name }
            let fresh = seenDocs.isEmpty ? nil : prepared.docs.filter { !seenDocs.contains($0.name) }.count
            seenDocs.formUnion(docNames)
            let pages = prepared.docs.reduce(0) { $0 + $1.pageEstimate }
            let line = GeminiText.readyLine(count: prepared.docs.count, new: fresh, warnings: allNotes, pages: pages)
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

    /// Büyük belge setlerini Gemini'nin hafızasına koyar (Files API + oturumda önbellek). Hafıza kullanılamazsa belgeler doğrudan
    /// (inline) gider; 14 MB'a sığacak kadarına kırpılır ve not düşülür.
    private func memorize(docs input: [GeminiDoc], notes: inout [String], session: Bool) async throws -> (docs: [GeminiDoc], cache: String) {
        var docs = input
        var cache = ""
        if !docs.isEmpty, let mem = memory, mem.wanted(docs) {
            do {
                status = "Belgeler Gemini hafızasına alınıyor…"
                let result = try await mem.prepare(docs, session: session) { [weak self] done, total in
                    self?.status = "Belgeler Gemini’ye yükleniyor: \(done) / \(total)"
                }
                docs = result.docs
                cache = result.cache
                tlog("[gemini] hafıza: \(docs.count) belge\(cache.isEmpty ? "" : ", önbellekli")")
            } catch let e as GeminiError {
                if e.kind == .key || e.kind == .quota || e.kind == .cap || e.kind == .network { throw e }
                tlog("[gemini] hafızaya alınamadı, belgeler doğrudan gönderilecek: \(e.message)")
                docs = docs.map { var d = $0; d.uri = ""; d.remote = ""; return d }
                cache = ""
                notes.append("Belgeler Gemini hafızasına alınamadı, doğrudan gönderiliyor.")
            }
        }
        if !docs.isEmpty && !GeminiSupport.allRemote(docs) {
            let picked = GeminiSupport.selectDocs(docs.map { (name: $0.name, size: $0.size) })
            if !picked.skipped.isEmpty {
                let current = docs
                docs = picked.chosen.map { current[$0] }
                notes.append("\(picked.skipped.count) belge boyut sınırı nedeniyle atlandı.")
            }
        }
        return (docs, cache)
    }

    /// Soruyu sorar. Önbellek ya da yüklü dosya artık geçerli değilse (süresi dolmuş) önce önbelleksiz, sonra eksik dosyaları
    /// yeniden yükleyerek dener; sorun belgelerden değilse ilk hatayı olduğu gibi verir.
    private func askRobust(text: String, audio: Data?, docs: [GeminiDoc], cache: String) async throws -> GeminiAnswer {
        func go(_ list: [GeminiDoc], _ cached: String) async throws -> GeminiAnswer {
            if cached.isEmpty {
                return try await client.ask(questionText: text, audioWAV: audio, docs: list, history: history)
            }
            return try await client.ask(questionText: text, audioWAV: audio, docs: list, history: history, cached: cached)
        }
        func retryable(_ e: GeminiError) -> Bool { return e.status == 400 || e.status == 403 || e.status == 404 }
        var first = GeminiError("", .error)
        do {
            return try await go(docs, cache)
        } catch let e as GeminiError {
            guard GeminiSupport.allRemote(docs), retryable(e) else { throw e }
            first = e
        }
        tlog("[gemini] önbellek/dosya geçersiz olabilir (\(first.message)), denetleniyor")
        if !cache.isEmpty {
            await memory?.dropCache()
            do {
                return try await go(docs, "")
            } catch let e as GeminiError {
                guard retryable(e) else { throw e }
                first = e
            }
        }
        guard let memory = memory else { throw first }
        let checked = await memory.revalidate(docs)
        guard checked.lost > 0 else { throw first }
        let uploaded = try await memory.upload(checked.docs, progress: { _, _ in })
        return try await go(uploaded, "")
    }

    /// Soruyu sorar; aylık harcama sınırı dolmuşsa ve ücretsiz bir yedek profil varsa ona geçip (belgeleri o anahtarla yükleyip) aynı soruyu yineler.
    private func askWithFallback(gen: Int, opts: GeminiOptions, text: String, audio: Data?, docs: [GeminiDoc], cache: String,
                                 session: Bool) async throws -> GeminiAnswer {
        do {
            return try await askRobust(text: text, audio: audio, docs: docs, cache: cache)
        } catch let e as GeminiError where e.kind == .cap {
            let current = GeminiProfiles.active(opts.profiles, active: opts.active)
            guard let target = GeminiProfiles.fallbackTarget(opts.profiles, from: current, auto: opts.autoFallback) else { throw e }
            guard gen == generation, !Task.isCancelled else { throw CancellationError() }
            tlog("[gemini] harcama sınırı doldu: \(current.name) → \(target.name)")
            onProfileSwitch?(current, target)
            _ = await speakAndWait("Aylık harcama sınırı doldu. \(target.name) modeline geçtim.", "Model değişti")
            guard gen == generation, !Task.isCancelled else { throw CancellationError() }
            setPhase(.thinking, "Gemini düşünüyor…")
            // Dosyalar API anahtarının projesine aittir: yeni anahtarla yeniden yüklenir
            var dropped: [String] = []
            let reset = docs.map { var d = $0; d.uri = ""; d.remote = ""; return d }
            let again = try await memorize(docs: reset, notes: &dropped, session: session)
            return try await askRobust(text: text, audio: audio, docs: again.docs, cache: again.cache)
        }
    }

    // MARK: - Son yanıtı tekrarla

    private func remember(_ answer: String, batch: Int, question: String) {
        let item = LastAnswer(answer: answer, batch: max(0, batch), question: question)
        last = item
        lastStore.save(item)
    }

    /// Kullanıcı "son yanıtı tekrarla" dedi mi? Yazı biliniyorsa (yazılı soru) yerelde bakılır; yalnız ses varsa ve kısaysa
    /// belgesiz küçük bir yazıya dökme isteği yapılır. Hata olursa normal soru gibi sürer.
    private func repeatAsked(typed: String, audio: Data?, opts: GeminiOptions) async -> Bool {
        let words = GeminiText.triggerList(for: opts.callWords)
        if !typed.isEmpty {
            return GeminiSupport.isRepeatRequest(GeminiText.stripTrigger(typed, words: words))
        }
        guard let wav = audio, last != nil, wav.count <= GeminiChat.repeatMaxBytes else { return false }
        do {
            let heard = try await client.transcribe(audioWAV: wav)
            return GeminiSupport.isRepeatRequest(GeminiText.stripTrigger(heard, words: words))
        } catch {
            tlog("[gemini] kısa ses yazıya dökülemedi, normal soru sayılıyor: \(error.localizedDescription)")
            return false
        }
    }

    /// Son cevabı kendi hafızasından yeniden okur: Gemini'ye istek gitmez, ücret yazılmaz, geçmişe eklenmez.
    private func repeatLast(gen: Int, session: Bool) async -> Bool {
        error = ""
        guard let item = last else {
            return await deliver(gen: gen, session: session, text: GeminiText.noLastLine, received: nil)
        }
        question = "(son yanıt tekrarlandı)"
        answer = item.answer
        tokens = 0
        tlog("[gemini] son yanıt hafızadan tekrarlanıyor (istek yok)")
        let n = item.batch
        let received: (() -> Void)? = n > 0 ? { [weak self] in self?.onBatchProgress?(n) } : nil
        return await deliver(gen: gen, session: session, text: GeminiText.cleanForSpeech(item.answer), received: received)
    }

    /// Cevabı okutur. Oturumdaysa ve yeni soru dinlenecekse true döner.
    private func deliver(gen: Int, session: Bool, text: String, received: (() -> Void)?) async -> Bool {
        if session {
            let ok = await speakAndWait(text + " " + GeminiText.nextQuestionLine, "Cevap okunuyor", received: received)
            guard gen == generation else { return false }
            if !ok { setPhase(.idle) }
            return ok
        }
        setPhase(.speaking, "Cevap okunuyor")
        pendingReceived = received
        if speak?(text) != true {
            pendingReceived = nil
            setPhase(.idle)
        }
        return false
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
            if await repeatAsked(typed: typed, audio: audio, opts: opts) {
                guard gen == generation else { return false }
                return await repeatLast(gen: gen, session: session)
            }
            guard gen == generation else { return false }
            setPhase(.thinking, "Belgeler hazırlanıyor…")
            let unsent = await syncUploads()
            let fetched = try await docs.fetch(count: opts.docCount)
            guard gen == generation else { return false }
            var allNotes = fetched.notes
            var warning = ""
            if unsent > 0 {
                let note = GeminiText.unsentNote(unsent)
                allNotes.append(note)
                warning = "Dikkat: " + note + " "
            }
            notes = allNotes
            docNames = fetched.docs.map { $0.name }
            if fetched.docs.isEmpty {
                fail(gen, "Okunacak belge bulunamadı. " + allNotes.joined(separator: " "))
                return false
            }
            let prepared = try await memorize(docs: fetched.docs, notes: &allNotes, session: session)
            guard gen == generation else { return false }
            notes = allNotes
            docNames = prepared.docs.map { $0.name }
            seenDocs.formUnion(docNames)
            status = "Gemini düşünüyor…"
            let reply = try await askWithFallback(gen: gen, opts: opts, text: typed, audio: audio, docs: prepared.docs,
                                                  cache: prepared.cache, session: session)
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
            softErrors = 0
            tlog("[gemini] cevap geldi: \(reply.totalTokens) jeton, \(prepared.docs.count) belge, \(reply.cachedTokens) önbellekten")

            // Toplu cevap sırası, cevap kullanıcıya SONUNA KADAR okunup ulaşınca ilerler; kesilen/okunamayan/gelmeyen cevapta ilerlemez
            remember(reply.answer, batch: reply.lastQuestion, question: q)
            let n = reply.lastQuestion
            let received: (() -> Void)? = n > 0 ? { [weak self] in self?.onBatchProgress?(n) } : nil
            return await deliver(gen: gen, session: session, text: warning + spoken, received: received)
        } catch is CancellationError {
            return false
        } catch let e as GeminiError {
            if session, GeminiChat.softErrorKinds.contains(e.kind), softErrors < GeminiChat.maxSoftErrors,
               gen == generation, !Task.isCancelled {
                // Geçici hata (internet kopması gibi): oturum kapanmaz, hata söylenir ve soru yeniden beklenir
                softErrors += 1
                error = e.message
                tlog("[gemini] oturum sürüyor, geçici hata (\(softErrors)): \(e.message)")
                let ok = await speakAndWait(e.message + " " + GeminiText.retryLine, "Hata söyleniyor")
                guard gen == generation else { return false }
                if !ok { setPhase(.idle) }
                return ok
            }
            fail(gen, e.message)
            return false
        } catch {
            fail(gen, error.localizedDescription)
            return false
        }
    }
}
