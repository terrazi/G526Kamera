import XCTest
@testable import G526CameraDrive

// MARK: - Sahte bileşenler

private final class FakeClient: GeminiAsking {
    struct Call {
        var text: String
        var audio: Data?
        var docs: [String]
        var history: [GeminiTurn]
        var cached: String
        /// nil = seçili model; dolu = yedek model
        var model: String? = nil
        /// nil = varsayılan yeniden deneme sayısı
        var retries: Int? = nil
        /// Model zinciri: nil = seçili profilin anahtarı; dolu = başka profilin anahtarı
        var key: String? = nil
        /// Model zinciri: en çok bu kadar sn cevap beklenir (nil = sınırsız)
        var timeout: TimeInterval? = nil
    }

    var replies: [Result<GeminiAnswer, Error>] = []
    var calls: [Call] = []
    /// Sırayla verilecek "kısa sesi yazıya dök" sonuçları (bitince boş metin)
    var transcripts: [String] = []
    var transcribeCalls = 0

    /// Seçili model adı ve yedek model listesi (GeminiChat yedek model mantığı için)
    var current = "gemini-3.8-flash"
    var fallback: [String] = []
    var fallbackCalls = 0

    /// Model zinciri: kalıcı hata. Anahtar "anahtar|model" ("-" = seçili profilin anahtarı) ya da yalnız "model"
    var failModels: [String: Error] = [:]
    /// Model zinciri: bu modeller (yalnız cevap bekleme sınırı verilmişse) cevap vermez → zaman aşımı hatası
    var timeoutModels: Set<String> = []

    var currentModel: String { return current }

    func fallbackModels() async -> [String] {
        fallbackCalls += 1
        return fallback
    }

    func ask(questionText: String, audioWAV: Data?, docs: [GeminiDoc], history: [GeminiTurn], cached: String) async throws -> GeminiAnswer {
        return try await ask(questionText: questionText, audioWAV: audioWAV, docs: docs, history: history, cached: cached,
                             model: nil, serverRetries: nil)
    }

    func ask(questionText: String, audioWAV: Data?, docs: [GeminiDoc], history: [GeminiTurn], cached: String,
             model: String?, serverRetries: Int?) async throws -> GeminiAnswer {
        return try await ask(questionText: questionText, audioWAV: audioWAV, docs: docs, history: history, cached: cached,
                             model: model, serverRetries: serverRetries, key: nil, timeout: nil)
    }

    func ask(questionText: String, audioWAV: Data?, docs: [GeminiDoc], history: [GeminiTurn], cached: String,
             model: String?, serverRetries: Int?, key: String?, timeout: TimeInterval?) async throws -> GeminiAnswer {
        calls.append(Call(text: questionText, audio: audioWAV, docs: docs.map { $0.name }, history: history, cached: cached,
                          model: model, retries: serverRetries, key: key, timeout: timeout))
        let name = model ?? current
        let id = "\(key ?? "-")|\(name)"
        if let e = failModels[id] ?? failModels[name] { throw e }
        if timeout != nil, timeoutModels.contains(id) || timeoutModels.contains(name) {
            var e = GeminiError("Gemini cevap vermedi (zaman aşımı).", .network)
            e.timedOut = true
            throw e
        }
        if replies.isEmpty { return GeminiAnswer(question: questionText, answer: "Cevap \(calls.count).") }
        return try replies.removeFirst().get()
    }

    func transcribe(audioWAV: Data) async throws -> String {
        transcribeCalls += 1
        return transcripts.isEmpty ? "" : transcripts.removeFirst()
    }
}

private final class FakeDocs: GeminiDocProviding {
    var result: Result<(docs: [GeminiDoc], notes: [String]), Error> =
        .success((docs: [GeminiDoc(name: "a.pdf", data: Data("%PDF".utf8))], notes: []))
    var counts: [Int] = []

    func fetch(count: Int) async throws -> (docs: [GeminiDoc], notes: [String]) {
        counts.append(count)
        return try result.get()
    }
}

private final class FakeRecorder: QuestionRecording {
    var result: (pcm: Data, outcome: QuestionOutcome) = (Data(count: 32000), .done)
    /// Sırayla verilecek sonuçlar; bitince `result` verilir
    var results: [(pcm: Data, outcome: QuestionOutcome)] = []
    /// Her kayıtta istenen "konuşma başlasın diye bekleme" süresi
    var waits: [TimeInterval] = []
    /// true: kayıt, `cancel()` gelene kadar sürer
    var hold = false
    var entered = false
    var cancelled = 0
    private var pending: CheckedContinuation<(pcm: Data, outcome: QuestionOutcome), Never>?

    /// "Tamam ile bitir" isteği ve sessizlik süresi (yeni kayıt çağrısı)
    var endWords: [Bool] = []
    var silences: [TimeInterval] = []

    func record(waitForSpeech: TimeInterval, endWord: Bool, silenceEnd: TimeInterval,
                onStatus: @escaping (String) -> Void) async -> (pcm: Data, outcome: QuestionOutcome) {
        endWords.append(endWord)
        silences.append(silenceEnd)
        return await record(waitForSpeech: waitForSpeech, onStatus: onStatus)
    }

    func record(waitForSpeech: TimeInterval, onStatus: @escaping (String) -> Void) async -> (pcm: Data, outcome: QuestionOutcome) {
        entered = true
        waits.append(waitForSpeech)
        onStatus("Dinliyorum")
        if !hold {
            if !results.isEmpty { return results.removeFirst() }
            return result
        }
        return await withCheckedContinuation { continuation in
            self.pending = continuation
        }
    }

    func cancel() {
        cancelled += 1
        pending?.resume(returning: (Data(), .stopped))
        pending = nil
    }
}

private final class FlushLog {
    var calls = 0
    var remaining = 0
}

private final class Log {
    var spoken: [String] = []
    var active: [Bool] = []
    var speakResult = true
    /// true: okuma hemen bitmiş sayılır (oturum akışı okuma bitmesini bekler)
    var autoFinish = false
    /// autoFinish ile bitirilen okuma sonuna kadar okundu mu (false: kesildi)
    var completed = true
    /// onBatchProgress ile bildirilen toplu cevap sıraları
    var progress: [Int] = []
}

@MainActor
private final class FakeMemory: GeminiMemoryProviding {
    var isWanted = true
    var uploadFailure: GeminiError?
    var cacheName = "cachedContents/1"
    var prepared = 0
    var sessions: [Bool] = []
    var dropped = 0
    var released = 0
    var revalidated = 0
    var uploads = 0
    var lostOnRevalidate = 0

    func wanted(_ docs: [GeminiDoc]) -> Bool { return isWanted }

    func prepare(_ docs: [GeminiDoc], session: Bool, progress: @escaping (Int, Int) -> Void) async throws -> (docs: [GeminiDoc], cache: String) {
        prepared += 1
        sessions.append(session)
        if let failure = uploadFailure { throw failure }
        progress(docs.count, docs.count)
        let marked = docs.map { doc -> GeminiDoc in
            var d = doc
            d.uri = "https://files/\(doc.name)"
            d.remote = "files/\(doc.name)"
            return d
        }
        return (marked, session ? cacheName : "")
    }

    func upload(_ docs: [GeminiDoc], progress: @escaping (Int, Int) -> Void) async throws -> [GeminiDoc] {
        uploads += 1
        return docs.map { doc -> GeminiDoc in
            var d = doc
            d.uri = "https://files/yeni/\(doc.name)"
            d.remote = "files/yeni/\(doc.name)"
            return d
        }
    }

    func revalidate(_ docs: [GeminiDoc]) async -> (docs: [GeminiDoc], lost: Int) {
        revalidated += 1
        return (docs, lostOnRevalidate)
    }

    func dropCache() async { dropped += 1 }
    func release() async { released += 1 }
}

@MainActor
final class GeminiChatTests: XCTestCase {
    private var client = FakeClient()
    private var docs = FakeDocs()
    private var recorder = FakeRecorder()
    private var log = Log()
    private var options = GeminiOptions(privacyOK: true, hasKey: true, docCount: 3)
    private var chat: GeminiChat!
    private var memory = FakeMemory()
    private var lastURL = FileManager.default.temporaryDirectory

    override func setUp() {
        super.setUp()
        client = FakeClient()
        docs = FakeDocs()
        recorder = FakeRecorder()
        log = Log()
        memory = FakeMemory()
        lastURL = FileManager.default.temporaryDirectory.appendingPathComponent("son-cevap-\(UUID().uuidString).json")
        options = GeminiOptions(privacyOK: true, hasKey: true, docCount: 3)
        chat = makeChat(memory: nil)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: lastURL)
        super.tearDown()
    }

    private func makeChat(memory: GeminiMemoryProviding?) -> GeminiChat {
        let box = self
        let chat = GeminiChat(client: client, docs: docs, recorder: recorder, options: { box.options },
                              memory: memory, lastStore: LastAnswerStore(url: lastURL))
        let log = self.log
        chat.speak = { [weak chat] text in
            log.spoken.append(text)
            if log.speakResult && log.autoFinish {
                Task { @MainActor in chat?.speakingChanged(false, completed: log.completed) }
            }
            return log.speakResult
        }
        chat.stopSpeaking = {}
        chat.onActiveChange = { log.active.append($0) }
        chat.onBatchProgress = { log.progress.append($0) }
        return chat
    }

    private func waitUntil(_ seconds: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    func testVoiceQuestionHappyPath() async {
        XCTAssertTrue(chat.ask())
        let reached = await waitUntil { self.chat.phase == .speaking }
        XCTAssertTrue(reached)
        XCTAssertEqual(client.calls.count, 1)
        XCTAssertNotNil(client.calls[0].audio)
        XCTAssertEqual(String(decoding: client.calls[0].audio?.prefix(4) ?? Data(), as: UTF8.self), "RIFF")
        XCTAssertEqual(client.calls[0].docs, ["a.pdf"])
        XCTAssertEqual(docs.counts, [3])
        XCTAssertEqual(chat.answer, "Cevap 1.")
        XCTAssertEqual(log.spoken, ["Cevap 1."])
        XCTAssertEqual(chat.turns, 1)
        XCTAssertEqual(chat.docNames, ["a.pdf"])

        chat.speakingChanged(false)
        XCTAssertEqual(chat.phase, .idle)
        XCTAssertEqual(log.active, [true, false])
    }

    func testAnswerIsCleanedBeforeSpeaking() async {
        client.replies = [.success(GeminiAnswer(question: "oran", answer: "**Oran** %20 oldu."))]
        chat.ask()
        _ = await waitUntil { self.chat.phase == .speaking }
        XCTAssertEqual(log.spoken, ["Oran yüzde 20 oldu."])
        XCTAssertEqual(chat.answer, "**Oran** %20 oldu.")
    }

    func testPrivacyConfirmationIsRequired() async {
        options.privacyOK = false
        chat.ask()
        _ = await waitUntil { self.chat.phase == .speaking }
        XCTAssertTrue(client.calls.isEmpty)
        XCTAssertTrue(log.spoken.first?.contains("gizlilik") ?? false)
        XCTAssertTrue(chat.error.contains("gizlilik"))
        chat.speakingChanged(false)
        XCTAssertEqual(chat.phase, .idle)
    }

    func testMissingKeyIsReported() async {
        options.hasKey = false
        chat.ask()
        _ = await waitUntil { self.chat.phase == .speaking }
        XCTAssertTrue(client.calls.isEmpty)
        XCTAssertTrue(chat.error.contains("anahtarı"))
    }

    func testNoSpeechHeard() async {
        recorder.result = (Data(), .noSpeech)
        chat.ask()
        _ = await waitUntil { self.chat.phase == .speaking }
        XCTAssertTrue(client.calls.isEmpty)
        XCTAssertTrue(chat.error.contains("duyamadım"))
    }

    func testTooShortRecordingIsNotAQuestion() async {
        recorder.result = (Data(count: 1000), .done)
        chat.ask()
        _ = await waitUntil { self.chat.phase == .speaking }
        XCTAssertTrue(client.calls.isEmpty)
        XCTAssertTrue(chat.error.contains("duyamadım"))
    }

    func testMicrophoneFailureIsSpoken() async {
        recorder.result = (Data(), .failed("Mikrofon izni verilmedi."))
        chat.ask()
        _ = await waitUntil { self.chat.phase == .speaking }
        XCTAssertEqual(chat.error, "Mikrofon izni verilmedi.")
        XCTAssertEqual(log.spoken, ["Mikrofon izni verilmedi."])
    }

    func testMissingDocumentsAreReported() async {
        docs.result = .success((docs: [], notes: ["Drive klasöründe PDF bulunamadı."]))
        chat.ask()
        _ = await waitUntil { self.chat.phase == .speaking }
        XCTAssertTrue(client.calls.isEmpty)
        XCTAssertTrue(chat.error.contains("Okunacak belge bulunamadı"))
        XCTAssertTrue(chat.error.contains("PDF bulunamadı"))
    }

    func testDriveErrorIsReported() async {
        docs.result = .failure(DriveError.notSignedIn)
        chat.ask()
        _ = await waitUntil { self.chat.phase == .speaking }
        XCTAssertTrue(chat.error.contains("Drive"))
    }

    func testGeminiErrorIsSpoken() async {
        client.replies = [.failure(GeminiError("Kota ya da hız sınırı aşıldı.", .quota, status: 429))]
        chat.ask()
        _ = await waitUntil { self.chat.phase == .speaking }
        XCTAssertEqual(chat.error, "Kota ya da hız sınırı aşıldı.")
        XCTAssertEqual(log.spoken, ["Kota ya da hız sınırı aşıldı."])
        XCTAssertEqual(chat.turns, 0)
    }

    func testTypedQuestionSkipsRecording() async {
        XCTAssertTrue(chat.ask(text: "  Gemini, toplam nedir  "))
        _ = await waitUntil { self.chat.phase == .speaking }
        XCTAssertNil(client.calls[0].audio)
        XCTAssertEqual(client.calls[0].text, "Gemini, toplam nedir")
        XCTAssertEqual(chat.question, "toplam nedir")
        XCTAssertFalse(chat.ask(text: "   "))
    }

    func testHistoryKeepsLastTwelveTurns() async {
        for n in 1...14 {
            chat.ask(text: "soru \(n)")
            _ = await waitUntil { self.chat.phase == .speaking }
            chat.speakingChanged(false)
        }
        XCTAssertEqual(client.calls.map { $0.history.count }, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 12])
        XCTAssertEqual(chat.history.count, 12)
        XCTAssertEqual(chat.history.first?.question, "soru 3")
        XCTAssertEqual(client.calls[13].history.last?.question, "soru 13")
        XCTAssertEqual(chat.turns, 14)
    }

    func testNewConversationClearsHistory() async {
        chat.ask(text: "soru")
        _ = await waitUntil { self.chat.phase == .speaking }
        chat.speakingChanged(false)
        chat.newConversation()
        XCTAssertTrue(chat.history.isEmpty)
        XCTAssertEqual(chat.turns, 0)
        XCTAssertEqual(chat.answer, "")
    }

    func testBusyChatRefusesSecondQuestion() async {
        recorder.hold = true
        XCTAssertTrue(chat.ask())
        XCTAssertFalse(chat.ask())
        _ = await waitUntil { self.recorder.entered }
        XCTAssertFalse(chat.ask(text: "ikinci"))
        chat.cancel()
        XCTAssertEqual(chat.phase, .idle)
    }

    func testCancelWhileListening() async {
        recorder.hold = true
        chat.ask()
        let listening = await waitUntil { self.recorder.entered }
        XCTAssertTrue(listening)
        XCTAssertEqual(chat.phase, .listening)
        chat.cancel()
        XCTAssertEqual(chat.phase, .idle)
        XCTAssertEqual(recorder.cancelled, 1)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(client.calls.isEmpty)
        XCTAssertEqual(chat.phase, .idle)
        XCTAssertEqual(log.active, [true, false])
        XCTAssertTrue(log.spoken.isEmpty)
    }

    func testCancelBeforeTheTaskStartsNeverOpensTheMicrophone() async {
        recorder.hold = true
        chat.ask()
        chat.cancel()
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(recorder.entered)
        XCTAssertEqual(chat.phase, .idle)
        XCTAssertEqual(log.active, [true, false])
    }

    func testCancelIsIgnoredWhenIdle() {
        chat.cancel()
        XCTAssertEqual(chat.phase, .idle)
        XCTAssertTrue(log.active.isEmpty)
    }

    func testChatGoesIdleWhenSpeechCannotStart() async {
        log.speakResult = false
        chat.ask(text: "soru")
        _ = await waitUntil { self.chat.turns == 1 }
        _ = await waitUntil { self.chat.phase == .idle }
        XCTAssertEqual(chat.phase, .idle)
        XCTAssertEqual(chat.answer, "Cevap 1.")
    }

    func testSpeakingChangeOutsideSpeakingPhaseIsIgnored() async {
        recorder.hold = true
        chat.ask()
        _ = await waitUntil { self.recorder.entered }
        chat.speakingChanged(false)
        XCTAssertEqual(chat.phase, .listening)
        chat.cancel()
    }

    // MARK: Oturum

    private func answer(_ text: String, close: Bool = false, switchModel: Bool = false) -> Result<GeminiAnswer, Error> {
        var a = GeminiAnswer(question: "soru", answer: text)
        a.close = close
        a.switchModel = switchModel
        return .success(a)
    }

    private let noSpeech: (pcm: Data, outcome: QuestionOutcome) = (Data(), .noSpeech)

    func testSessionGreetsAnswersAndKeepsListening() async {
        log.autoFinish = true
        options.session = true
        recorder.results = [(Data(count: 32000), .done), noSpeech]
        XCTAssertTrue(chat.ask())
        let ended = await waitUntil { self.chat.status == "Oturum bitti" }
        XCTAssertTrue(ended)
        XCTAssertEqual(log.spoken, ["1 belge hazır. Sorunuzu bekliyorum.", "Cevap 1. Sonraki sorunuzu bekliyorum."])
        XCTAssertEqual(client.calls.count, 1)
        XCTAssertEqual(recorder.waits, [.infinity, .infinity], "varsayılan: oturum hiç kapanmaz")
        XCTAssertEqual(chat.phase, .idle)
        XCTAssertEqual(chat.turns, 1)
        XCTAssertEqual(log.active, [true, false])
    }

    func testSessionTimeoutIsUserDefined() async {
        log.autoFinish = true
        options.session = true
        options.sessionTimeout = 45
        recorder.results = [noSpeech]
        chat.ask()
        _ = await waitUntil { self.chat.status == "Oturum bitti" }
        XCTAssertEqual(recorder.waits, [45])
        XCTAssertTrue(client.calls.isEmpty)
        XCTAssertEqual(log.spoken, ["1 belge hazır. Sorunuzu bekliyorum."])
        XCTAssertEqual(chat.error, "")
    }

    func testDinleSaysListeningThenRecordsUntilTamam() async {
        log.autoFinish = true
        options.listenByWord = true
        options.listenSilence = 15
        options.announceListening = true
        recorder.result = (Data(count: 32000), .word)
        XCTAssertTrue(chat.ask())
        let done = await waitUntil { self.chat.phase == .idle && self.client.calls.count == 1 && self.log.spoken.count == 2 }
        XCTAssertTrue(done)
        XCTAssertEqual(log.spoken, ["Dinliyorum.", "Cevap 1."], "kayıttan önce program Dinliyorum der")
        XCTAssertEqual(recorder.endWords, [true])
        XCTAssertEqual(recorder.silences, [15])
        XCTAssertEqual(recorder.waits, [15], "tamam modunda bekleme en az sessizlik süresi kadar")
        XCTAssertNotNil(client.calls[0].audio, "ses dosyası doğrudan Gemini'ye gider")
    }

    func testDinleSilenceSecondsFollowSetting() async {
        log.autoFinish = true
        options.listenByWord = true
        options.listenSilence = 30
        recorder.result = (Data(count: 32000), .done)
        chat.ask()
        _ = await waitUntil { self.client.calls.count == 1 }
        XCTAssertEqual(recorder.silences, [30])
        XCTAssertEqual(recorder.waits, [30])
    }

    func testListenByWordOffKeepsSilenceRecording() async {
        options.listenByWord = false
        chat.ask()
        _ = await waitUntil { self.chat.phase == .speaking }
        XCTAssertEqual(recorder.endWords, [false])
        XCTAssertEqual(recorder.waits, [7])
        XCTAssertEqual(log.spoken, ["Cevap 1."], "ayar kapalıyken Dinliyorum denmez")
    }

    func testSessionTimeoutIsNotStretchedByTamamMode() async {
        log.autoFinish = true
        options.session = true
        options.sessionTimeout = 10
        options.listenByWord = true
        options.listenSilence = 15
        recorder.results = [noSpeech]
        chat.ask()
        _ = await waitUntil { self.chat.status == "Oturum bitti" }
        XCTAssertEqual(recorder.waits, [10], "kullanıcının oturum süresi korunur")
        XCTAssertEqual(recorder.silences, [15])
    }

    func testSessionTurnsAlsoEndOnTamam() async {
        log.autoFinish = true
        options.session = true
        options.listenByWord = true
        options.announceListening = true
        recorder.results = [(Data(count: 32000), .word), noSpeech]
        chat.ask()
        _ = await waitUntil { self.chat.status == "Oturum bitti" }
        XCTAssertEqual(recorder.endWords, [true, true])
        XCTAssertEqual(log.spoken.first, "1 belge hazır. Sorunuzu bekliyorum.", "oturumda hazırlık cümlesi Dinliyorum yerine geçer")
        XCTAssertFalse(log.spoken.contains("Dinliyorum."))
    }

    func testSingleVoiceQuestionStillWaitsOnlyBriefly() async {
        recorder.result = (Data(), .noSpeech)
        chat.ask()
        _ = await waitUntil { self.chat.phase == .speaking }
        XCTAssertEqual(recorder.waits, [7])
        XCTAssertTrue(chat.error.contains("duyamadım"))
    }

    func testSessionCloseFlagSaysGoodbyeAndStops() async {
        log.autoFinish = true
        options.session = true
        client.replies = [answer("Görüşürüz.", close: true)]
        chat.ask()
        _ = await waitUntil { self.chat.status == "Oturum kapandı" }
        XCTAssertEqual(log.spoken.last, "Görüşürüz.")
        XCTAssertFalse(log.spoken.contains { $0.contains("Sonraki sorunuzu") })
        XCTAssertEqual(recorder.waits.count, 1, "kapat dendikten sonra yeniden dinlenmemeli")
        XCTAssertEqual(chat.phase, .idle)
    }

    func testSessionCloseWithoutGoodbyeStillCloses() async {
        log.autoFinish = true
        options.session = true
        client.replies = [answer("", close: true)]
        chat.ask()
        _ = await waitUntil { self.chat.status == "Oturum kapandı" }
        XCTAssertEqual(log.spoken.last, "Oturum kapandı.")
        XCTAssertEqual(recorder.waits.count, 1)
    }

    func testSessionIgnoresSoundsThatAreNotQuestions() async {
        log.autoFinish = true
        options.session = true
        client.replies = [answer(""), answer("Gerçek cevap.")]
        recorder.results = [(Data(count: 32000), .done), (Data(count: 32000), .done), noSpeech]
        chat.ask()
        _ = await waitUntil { self.chat.status == "Oturum bitti" }
        XCTAssertEqual(client.calls.count, 2)
        XCTAssertEqual(log.spoken, ["1 belge hazır. Sorunuzu bekliyorum.", "Gerçek cevap. Sonraki sorunuzu bekliyorum."])
        XCTAssertEqual(chat.turns, 1, "boş cevap konuşma geçmişine girmemeli")
        XCTAssertEqual(chat.error, "")
    }

    func testSessionKeepsListeningAfterTooShortRecording() async {
        log.autoFinish = true
        options.session = true
        recorder.results = [(Data(count: 100), .done), noSpeech]
        chat.ask()
        _ = await waitUntil { self.chat.status == "Oturum bitti" }
        XCTAssertTrue(client.calls.isEmpty)
        XCTAssertEqual(recorder.waits.count, 2)
        XCTAssertEqual(chat.error, "")
    }

    func testEmptyAnswerOutsideSessionIsReported() async {
        client.replies = [answer("")]
        chat.ask(text: "bir şey")
        _ = await waitUntil { self.chat.phase == .speaking }
        XCTAssertTrue(chat.error.contains("anlayamadım"))
    }

    func testSwitchModelFlagStartsModelChoice() async {
        log.autoFinish = true
        options.session = true
        var choices = 0
        chat.onModelChoice = { choices += 1 }
        client.replies = [answer("", switchModel: true)]
        chat.ask()
        _ = await waitUntil { choices == 1 }
        XCTAssertEqual(choices, 1)
        XCTAssertEqual(chat.phase, .idle)
        XCTAssertEqual(recorder.waits.count, 1, "model seçimine geçince oturum dinlemeyi bırakır")
        XCTAssertEqual(log.spoken, ["1 belge hazır. Sorunuzu bekliyorum."])
        XCTAssertEqual(chat.turns, 0)
    }

    func testSkippedDocumentsAreAnnouncedInTheGreeting() async {
        log.autoFinish = true
        options.session = true
        docs.result = .success((docs: [GeminiDoc(name: "a.pdf", data: Data("%PDF".utf8))],
                                notes: ["2 belge boyut sınırı nedeniyle atlandı."]))
        recorder.results = [noSpeech]
        chat.ask()
        _ = await waitUntil { self.chat.status == "Oturum bitti" }
        XCTAssertEqual(log.spoken.first, "1 belge hazır. Dikkat: 2 belge boyut sınırı nedeniyle atlandı. Sorunuzu bekliyorum.")
    }

    func testNewDocumentsAreMentionedWhenTheSessionRestarts() async {
        log.autoFinish = true
        options.session = true
        recorder.results = [noSpeech, noSpeech]
        chat.ask()
        _ = await waitUntil { self.chat.status == "Oturum bitti" }
        docs.result = .success((docs: [GeminiDoc(name: "b.pdf", data: Data("%PDF".utf8)),
                                       GeminiDoc(name: "a.pdf", data: Data("%PDF".utf8))], notes: []))
        chat.ask()
        _ = await waitUntil { self.log.spoken.count == 2 }
        XCTAssertEqual(log.spoken[1], "2 belge hazır, 1 tanesi yeni. Sorunuzu bekliyorum.")
    }

    func testCancelWhileTheGreetingIsSpokenNeverOpensTheMicrophone() async {
        options.session = true
        chat.ask()
        _ = await waitUntil { self.log.spoken.count == 1 }
        XCTAssertEqual(chat.phase, .speaking)
        chat.cancel()
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(recorder.entered)
        XCTAssertEqual(chat.phase, .idle)
        XCTAssertEqual(log.active, [true, false])
    }

    // MARK: Harcama sınırı → ücretsiz profil

    private func paidProfile(_ slot: Int = 1) -> GeminiProfileInfo {
        return GeminiProfileInfo(slot: slot, name: "Pro", model: "m\(slot)", key: "k\(slot)", free: false)
    }

    private func freeProfile(_ slot: Int = 3) -> GeminiProfileInfo {
        return GeminiProfileInfo(slot: slot, name: "Ücretsiz", model: "m\(slot)", key: "k\(slot)", free: true)
    }

    private func capError() -> Result<GeminiAnswer, Error> {
        return .failure(GeminiError("Aylık harcama sınırınız doldu.", .cap, status: 429))
    }

    func testTransientErrorKeepsTheSessionOpen() async {
        log.autoFinish = true
        options.session = true
        client.replies = [.failure(GeminiError("Gemini şu an yanıt vermiyor (503).", .http, status: 503)), answer("Yüz lira.")]
        recorder.results = [(Data(count: 32000), .done), (Data(count: 32000), .done), noSpeech]
        chat.ask()
        let ended = await waitUntil { self.chat.status == "Oturum bitti" }
        XCTAssertTrue(ended)
        XCTAssertEqual(log.spoken, ["1 belge hazır. Sorunuzu bekliyorum.",
                                    "Gemini şu an yanıt vermiyor (503). Sorunuzu yeniden söyleyebilirsiniz.",
                                    "Yüz lira. Sonraki sorunuzu bekliyorum."])
        XCTAssertEqual(client.calls.count, 2)
        XCTAssertEqual(chat.turns, 1)
        XCTAssertEqual(chat.error, "", "başarılı cevaptan sonra hata temizlenir")
    }

    func testKeyErrorEndsTheSession() async {
        log.autoFinish = true
        options.session = true
        client.replies = [.failure(GeminiError("Anahtar geçersiz.", .key, status: 403))]
        recorder.results = [(Data(count: 32000), .done), (Data(count: 32000), .done)]
        chat.ask()
        let ended = await waitUntil { self.chat.phase == .idle && self.chat.error == "Anahtar geçersiz." }
        XCTAssertTrue(ended)
        XCTAssertEqual(client.calls.count, 1)
        XCTAssertEqual(recorder.waits.count, 1, "anahtar hatasından sonra yeniden dinlenmemeli")
    }

    func testRepeatedTransientErrorsEndTheSession() async {
        log.autoFinish = true
        options.session = true
        let down = GeminiError("İnternete ulaşılamadı.", .network)
        client.replies = [.failure(down), .failure(down), .failure(down)]
        recorder.results = [(Data(count: 32000), .done), (Data(count: 32000), .done), (Data(count: 32000), .done),
                            (Data(count: 32000), .done)]
        chat.ask()
        let ended = await waitUntil { self.chat.phase == .idle && self.client.calls.count == 3 }
        XCTAssertTrue(ended)
        XCTAssertEqual(chat.error, "İnternete ulaşılamadı.")
        XCTAssertEqual(client.calls.count, 3, "üçüncü geçici hatada oturum kapanır")
        XCTAssertEqual(log.spoken.filter { $0.hasSuffix("Sorunuzu yeniden söyleyebilirsiniz.") }.count, 2)
    }

    func testPendingPhotosAreFlushedBeforeEachDriveRead() async {
        log.autoFinish = true
        options.session = true
        let flush = FlushLog()
        chat.flushUploads = { flush.calls += 1; return flush.remaining }
        recorder.results = [(Data(count: 32000), .done), noSpeech]
        chat.ask()
        let ended = await waitUntil { self.chat.status == "Oturum bitti" }
        XCTAssertTrue(ended)
        XCTAssertEqual(flush.calls, 2, "oturum başında ve soruda")
        XCTAssertEqual(log.spoken, ["1 belge hazır. Sorunuzu bekliyorum.", "Cevap 1. Sonraki sorunuzu bekliyorum."],
                       "her şey yüklendiyse uyarı yok")
        XCTAssertFalse(chat.notes.contains { $0.contains("henüz Drive") })
    }

    func testPhotosStillUnsentAreWarnedAboutInTheGreetingAndTheAnswer() async {
        log.autoFinish = true
        options.session = true
        let flush = FlushLog()
        flush.remaining = 2
        chat.flushUploads = { flush.calls += 1; return flush.remaining }
        recorder.results = [(Data(count: 32000), .done), noSpeech]
        chat.ask()
        let ended = await waitUntil { self.chat.status == "Oturum bitti" }
        XCTAssertTrue(ended)
        let note = "2 fotoğraf henüz Drive'a yüklenmedi, Gemini onları göremez."
        XCTAssertEqual(log.spoken, ["1 belge hazır. Dikkat: \(note) Sorunuzu bekliyorum.",
                                    "Dikkat: \(note) Cevap 1. Sonraki sorunuzu bekliyorum."])
        XCTAssertTrue(chat.notes.contains(note))
    }

    func testUnsentNoteText() {
        XCTAssertEqual(GeminiText.unsentNote(3), "3 fotoğraf henüz Drive'a yüklenmedi, Gemini onları göremez.")
    }

    func testSpendingCapSwitchesToTheFreeProfileAndRetries() async {
        log.autoFinish = true
        options.profiles = [paidProfile(1), freeProfile(3)]
        options.active = 1
        options.autoFallback = true
        var switched: [(Int, Int)] = []
        chat.onProfileSwitch = { switched.append(($0.slot, $1.slot)) }
        client.replies = [capError(), .success(GeminiAnswer(question: "toplam", answer: "Yüz lira."))]
        chat.ask(text: "toplam nedir")
        _ = await waitUntil { self.log.spoken.count == 2 }
        XCTAssertEqual(switched.count, 1)
        XCTAssertEqual(switched.first?.0, 1)
        XCTAssertEqual(switched.first?.1, 3)
        XCTAssertEqual(client.calls.map { $0.text }, ["toplam nedir", "toplam nedir"], "aynı soru yeni modelle yinelenmeli")
        XCTAssertEqual(log.spoken, ["Aylık harcama sınırı doldu. Ücretsiz modeline geçtim.", "Yüz lira."])
        XCTAssertEqual(chat.error, "")
        XCTAssertEqual(chat.answer, "Yüz lira.")
    }

    func testSpendingCapWithoutAFreeProfileIsReported() async {
        options.profiles = [paidProfile(1), paidProfile(2)]
        options.active = 1
        options.autoFallback = true
        client.replies = [capError()]
        chat.ask(text: "soru")
        _ = await waitUntil { self.chat.phase == .speaking }
        XCTAssertEqual(client.calls.count, 1)
        XCTAssertEqual(chat.error, "Aylık harcama sınırınız doldu.")
    }

    func testSpendingCapDoesNotSwitchWhenAutoFallbackIsOff() async {
        options.profiles = [paidProfile(1), freeProfile(3)]
        options.active = 1
        options.autoFallback = false
        var switched = 0
        chat.onProfileSwitch = { _, _ in switched += 1 }
        client.replies = [capError()]
        chat.ask(text: "soru")
        _ = await waitUntil { self.chat.phase == .speaking }
        XCTAssertEqual(switched, 0)
        XCTAssertEqual(client.calls.count, 1)
        XCTAssertEqual(chat.error, "Aylık harcama sınırınız doldu.")
    }

    func testFreeProfileHittingTheCapDoesNotLoop() async {
        options.profiles = [paidProfile(1), freeProfile(3)]
        options.active = 3
        options.autoFallback = true
        client.replies = [capError()]
        chat.ask(text: "soru")
        _ = await waitUntil { self.chat.phase == .speaking }
        XCTAssertEqual(client.calls.count, 1)
        XCTAssertEqual(chat.error, "Aylık harcama sınırınız doldu.")
    }


    // MARK: Model zinciri (performans sırası): kota / hata / gecikme → aynı soru sıradaki profilin modeline

    private func chainProfiles() -> [GeminiProfileInfo] {
        let names = GeminiProfiles.defaultNames
        let models = GeminiProfiles.defaults().map { $0.model }
        return (1...6).map { GeminiProfileInfo(slot: $0, name: names[$0 - 1], model: models[$0 - 1], key: "k\($0)", free: $0 != 6) }
    }

    private func setUpChain(active: Int = 1, waitLimit: TimeInterval = 30) {
        log.autoFinish = true
        options.profiles = chainProfiles()
        options.active = active
        options.chainFallback = true
        options.waitLimit = waitLimit
        options.overloadFallback = false
    }

    private func askChain(_ text: String = "toplam nedir", until answer: String? = nil) async {
        XCTAssertTrue(chat.ask(text: text))
        _ = await waitUntil(5) { answer != nil ? self.chat.answer == answer : (!self.chat.answer.isEmpty || !self.chat.error.isEmpty) }
    }

    func testChainQuotaGoesToTheSecondModelAndSaysSo() async {
        setUpChain()
        client.failModels["-|gemini-3.8-flash"] = dailyQuota
        await askChain()
        XCTAssertEqual(client.calls.map { $0.model ?? "-" }, ["-", "gemini-3.6-flash"])
        XCTAssertEqual(client.calls.map { $0.key ?? "-" }, ["-", "k2"])
        XCTAssertEqual(client.calls.map { $0.text }, ["toplam nedir", "toplam nedir"], "aynı soru yinelenmeli")
        XCTAssertEqual(client.calls.map { $0.timeout }, [30, 30])
        XCTAssertEqual(log.spoken.first, "Gemini 3.8 Flash kotası doldu. Sorunuz Gemini 3.6 Flash modeline gönderiliyor.")
        XCTAssertEqual(chat.answer, "Cevap 2.")
        XCTAssertEqual(chat.error, "")
        XCTAssertTrue(chat.notes.contains { $0.contains("Gemini 3.6 Flash modelinden geldi") && $0.contains("kotası doldu") }, "\(chat.notes)")
    }

    func testChainSkipsAModelWhoseDailyQuotaIsFullOnTheNextQuestion() async {
        setUpChain()
        client.failModels["-|gemini-3.8-flash"] = dailyQuota
        await askChain()
        _ = await waitUntil { self.chat.phase == .idle }
        let spokenBefore = log.spoken.count
        await askChain("başka soru", until: "Cevap 3.")
        XCTAssertEqual(client.calls.map { $0.model ?? "-" }, ["-", "gemini-3.6-flash", "gemini-3.6-flash"], "kotası dolu model atlanır")
        XCTAssertFalse(log.spoken.dropFirst(spokenBefore).contains { $0.contains("Sorunuz") }, "tekrar bildirim yok")
    }

    func testChainMovesOnWhenTheModelTakesTooLong() async {
        setUpChain(waitLimit: 2)
        client.timeoutModels = ["-|gemini-3.8-flash"]
        await askChain()
        XCTAssertEqual(client.calls.first?.timeout, chat.waitMin, "çok kısa sınır en az waitMin sayılır")
        XCTAssertEqual(client.calls.map { $0.model ?? "-" }, ["-", "gemini-3.6-flash"])
        XCTAssertEqual(log.spoken.first, "Gemini 3.8 Flash uzun süre cevap vermedi. Sorunuz Gemini 3.6 Flash modeline gönderiliyor.")
        XCTAssertEqual(chat.error, "")
    }

    func testChainServerErrorAlsoMovesOn() async {
        setUpChain()
        client.failModels["-|gemini-3.8-flash"] = busy503
        await askChain()
        XCTAssertEqual(client.calls.map { $0.model ?? "-" }, ["-", "gemini-3.6-flash"])
        XCTAssertEqual(log.spoken.first, "Gemini 3.8 Flash şu an çok yoğun. Sorunuz Gemini 3.6 Flash modeline gönderiliyor.")
    }

    func testChainEndsWithThePaidProfileUsingItsOwnKeyAndNoWaitLimit() async {
        setUpChain()
        for id in ["-|gemini-3.8-flash", "k2|gemini-3.6-flash", "k3|gemini-2.5-pro", "k4|gemini-3.5-flash-lite", "k5|gemini-3.1-flash-lite"] {
            client.failModels[id] = dailyQuota
        }
        await askChain()
        XCTAssertEqual(client.calls.map { $0.model ?? "-" },
                       ["-", "gemini-3.6-flash", "gemini-2.5-pro", "gemini-3.5-flash-lite", "gemini-3.1-flash-lite", "gemini-3.1-flash-lite"])
        XCTAssertEqual(client.calls.map { $0.key ?? "-" }, ["-", "k2", "k3", "k4", "k5", "k6"])
        XCTAssertEqual(client.calls.map { $0.timeout }, [30, 30, 30, 30, 30, nil], "son modele bekleme sınırı konmaz")
        XCTAssertTrue(log.spoken.contains("Gemini 3.1 Flash-Lite kotası doldu. Sorunuz Ücretli Gemini 3.1 Flash-Lite modeline gönderiliyor."), "\(log.spoken)")
        XCTAssertEqual(chat.answer, "Cevap 6.")
        XCTAssertEqual(chat.error, "")
    }

    func testChainWhenEveryModelFailsSaysWhichOnesWereTried() async {
        setUpChain()
        for p in chainProfiles() { client.failModels["\(p.slot == 1 ? "-" : p.key)|\(p.model)"] = dailyQuota }
        await askChain()
        XCTAssertEqual(client.calls.count, 6)
        XCTAssertTrue(chat.error.hasPrefix("Tüm modeller denendi"), chat.error)
        XCTAssertTrue(chat.error.contains("günlük kotası doldu"), chat.error)
        XCTAssertTrue(chat.answer.isEmpty)
    }

    func testChainRotatesFromTheActiveProfile() {
        setUpChain(active: 4)
        XCTAssertEqual(chat.chainOthers(options).map { $0.slot }, [5, 6, 1, 2, 3])
    }

    func testChainIgnoresProfilesWithoutKeysAndIsOffWhenAloneOrDisabled() async {
        setUpChain()
        options.profiles = chainProfiles().map { var p = $0; if p.slot > 2 { p.key = "" }; return p }
        XCTAssertEqual(chat.chainOthers(options).map { $0.slot }, [2])
        options.profiles = chainProfiles().map { var p = $0; if p.slot > 1 { p.key = "" }; return p }
        XCTAssertTrue(chat.chainOthers(options).isEmpty)
        options.profiles = chainProfiles()
        options.chainFallback = false
        client.failModels["-|gemini-3.8-flash"] = dailyQuota
        await askChain()
        XCTAssertEqual(client.calls.count, 1, "zincir kapalıyken yalnız seçili model sorulur")
        XCTAssertEqual(chat.error, dailyQuota.message)
    }

    func testChainDoesNotChaseBlockedContentSpendingCapOrOfflineErrors() {
        for kind in [GeminiErrorKind.blocked, .empty, .tooBig, .cap] {
            XCTAssertFalse(GeminiChat.chainWorthy(GeminiError("x", kind)), "\(kind)")
        }
        XCTAssertFalse(GeminiChat.chainWorthy(GeminiError("x", .network)))
        var timedOut = GeminiError("x", .network); timedOut.timedOut = true
        XCTAssertTrue(GeminiChat.chainWorthy(timedOut))
        XCTAssertTrue(GeminiChat.chainWorthy(GeminiError("x", .quota, status: 429)))
        XCTAssertTrue(GeminiChat.chainWorthy(GeminiError("x", .http, status: 503)))
        XCTAssertTrue(GeminiChat.chainWorthy(GeminiError("x", .key, status: 400)))
        XCTAssertTrue(GeminiChat.chainWorthy(GeminiError("x", .model, status: 404)))
    }

    func testChainDocsOfAnotherKeyAreSentInlineWithoutFileAddresses() {
        let act = chainProfiles()[0], other = chainProfiles()[5]
        var d = GeminiDoc(name: "a.pdf", data: Data("%PDF-1.4 a".utf8))
        d.uri = "https://files/a"
        d.remote = "files/a"
        var sameKey = chainProfiles()[1]
        sameKey.key = act.key
        XCTAssertEqual(chat.chainDocs([d], to: sameKey, from: act).first?.uri, "https://files/a", "aynı anahtar: adres korunur")
        let moved = chat.chainDocs([d], to: other, from: act)
        XCTAssertEqual(moved.count, 1)
        XCTAssertEqual(moved.first?.uri, "", "başka anahtar: dosya adresi atılır")
        XCTAssertEqual(moved.first?.remote, "")
    }

    // MARK: Toplu cevap sırası, tekrar, hafıza

    private func batchReply(_ text: String, last: Int) -> Result<GeminiAnswer, Error> {
        var answer = GeminiAnswer(question: "ilk on soruyu cevapla", answer: text)
        answer.lastQuestion = last
        return .success(answer)
    }

    func testBatchCursorAdvancesOnlyWhenTheAnswerWasFullyRead() async {
        client.replies = [batchReply("Birinci sorunun cevabı DENİZLİ, altmış sekiz.", last: 10),
                          batchReply("Birinci sorunun cevabı DENİZLİ, altmış sekiz.", last: 10)]
        chat.ask(text: "ilk on soruyu cevapla")
        _ = await waitUntil { self.chat.phase == .speaking }
        XCTAssertEqual(log.progress, [], "okunurken sıra ilerlememeli")
        chat.speakingChanged(false, completed: false)
        XCTAssertEqual(log.progress, [], "kesilen okumada sıra ilerlememeli")

        chat.ask(text: "ilk on soruyu cevapla")
        _ = await waitUntil { self.chat.phase == .speaking && self.client.calls.count == 2 }
        chat.speakingChanged(false, completed: true)
        XCTAssertEqual(log.progress, [10], "sonuna kadar okununca sıra ilerler")
    }

    func testBatchCursorInSessionFollowsTheReadingResult() async {
        log.autoFinish = true
        log.completed = false
        options.session = true
        client.replies = [batchReply("Cevaplar.", last: 10)]
        recorder.results = [(Data(count: 32000), .done), noSpeech]
        chat.ask()
        _ = await waitUntil { self.chat.status == "Oturum bitti" }
        XCTAssertEqual(log.progress, [], "okuma kesildiyse oturumda da sıra ilerlemez")

        let fresh = makeChat(memory: nil)
        log.completed = true
        client.replies = [batchReply("Cevaplar.", last: 20)]
        recorder.results = [(Data(count: 32000), .done), noSpeech]
        fresh.ask()
        _ = await waitUntil { fresh.status == "Oturum bitti" }
        XCTAssertEqual(log.progress, [20])
    }

    func testRequestFailureNeverMovesTheCursor() async {
        client.replies = [.failure(GeminiError("İnternete ulaşılamadı.", .network))]
        chat.ask(text: "sıradaki on soruyu cevapla")
        _ = await waitUntil { self.chat.phase == .speaking || self.chat.phase == .idle }
        chat.speakingChanged(false)
        XCTAssertEqual(log.progress, [])
    }

    func testNonBatchAnswerLeavesTheCursorAlone() async {
        chat.ask(text: "toplam nedir")
        _ = await waitUntil { self.chat.phase == .speaking }
        chat.speakingChanged(false)
        XCTAssertEqual(log.progress, [])
    }

    func testRepeatLastAnswerSpeaksFromMemoryWithoutAskingGemini() async {
        client.replies = [batchReply("Birinci sorunun cevabı DENİZLİ, altmış sekiz.", last: 10)]
        chat.ask(text: "ilk on soruyu cevapla")
        _ = await waitUntil { self.chat.phase == .speaking }
        chat.speakingChanged(false, completed: false)         // kullanıcı cevabı kaçırdı
        XCTAssertEqual(log.progress, [])

        chat.ask(text: "son yanıtı tekrarla")
        _ = await waitUntil { self.log.spoken.count == 2 }
        XCTAssertEqual(client.calls.count, 1, "tekrar için Gemini'ye istek gitmemeli")
        XCTAssertEqual(log.spoken.last, "Birinci sorunun cevabı DENİZLİ, altmış sekiz.")
        XCTAssertEqual(chat.turns, 1, "tekrar geçmişe eklenmez")
        XCTAssertEqual(chat.history.count, 1)
        XCTAssertEqual(chat.tokens, 0)
        chat.speakingChanged(false, completed: true)
        XCTAssertEqual(log.progress, [10], "kaçırılan toplu cevap tekrarlanıp tam dinlenince sıra ilerler")
    }

    func testRepeatIsRememberedAcrossChats() async {
        chat.ask(text: "toplam nedir")
        _ = await waitUntil { self.chat.phase == .speaking }
        chat.speakingChanged(false)
        let reopened = makeChat(memory: nil)
        XCTAssertEqual(reopened.last?.answer, "Cevap 1.")
        reopened.ask(text: "bir daha söyle")
        _ = await waitUntil { self.log.spoken.count == 2 }
        XCTAssertEqual(log.spoken.last, "Cevap 1.")
        XCTAssertEqual(client.calls.count, 1)
    }

    func testRepeatWithoutAnyAnswerSaysSo() async {
        chat.ask(text: "son yanıtı tekrarla")
        _ = await waitUntil { self.log.spoken.count == 1 }
        XCTAssertEqual(log.spoken, [GeminiText.noLastLine])
        XCTAssertEqual(client.calls.count, 0)
    }

    func testNewQuestionPhrasedLikeARepeatIsStillAsked() async {
        chat.ask(text: "ilk on soruyu tekrar cevapla")
        _ = await waitUntil { self.chat.phase == .speaking }
        XCTAssertEqual(client.calls.count, 1)
    }

    func testShortSpokenRepeatIsRecognisedWithoutDocuments() async {
        chat.ask(text: "toplam nedir")
        _ = await waitUntil { self.chat.phase == .speaking }
        chat.speakingChanged(false)
        client.transcripts = ["Gemini, son cevabı tekrar et"]
        chat.ask()
        _ = await waitUntil { self.log.spoken.count == 2 }
        XCTAssertEqual(client.transcribeCalls, 1)
        XCTAssertEqual(client.calls.count, 1, "tekrar istenince ana istek gitmemeli")
        XCTAssertEqual(docs.counts.count, 1, "tekrar için belgeler yeniden hazırlanmamalı")
    }

    func testShortSpokenQuestionThatIsNotARepeatContinuesNormally() async {
        chat.ask(text: "toplam nedir")
        _ = await waitUntil { self.chat.phase == .speaking }
        chat.speakingChanged(false)
        client.transcripts = ["kira bedeli ne kadar"]
        chat.ask()
        _ = await waitUntil { self.client.calls.count == 2 }
        XCTAssertEqual(client.transcribeCalls, 1)
        XCTAssertNotNil(client.calls[1].audio, "normal soru sesle gitmeli")
    }

    func testLongSpokenRequestSkipsTheRepeatCheck() async {
        chat.ask(text: "toplam nedir")
        _ = await waitUntil { self.chat.phase == .speaking }
        chat.speakingChanged(false)
        recorder.result = (Data(count: 16000 * 2 * 8), .done)
        chat.ask()
        _ = await waitUntil { self.client.calls.count == 2 }
        XCTAssertEqual(client.transcribeCalls, 0, "5 saniyeden uzun ses doğrudan soru sayılır")
    }

    func testReadyLineMentionsPagesWhenTheyDifferFromDocuments() {
        XCTAssertEqual(GeminiText.readyLine(count: 2, new: nil, pages: 40), "2 belge, 40 sayfa hazır. Sorunuzu bekliyorum.")
        XCTAssertEqual(GeminiText.readyLine(count: 2, new: nil, pages: 2), "2 belge hazır. Sorunuzu bekliyorum.")
        XCTAssertEqual(GeminiText.readyLine(count: 2, new: 2, pages: 40), "2 belge, 40 sayfa hazır, hepsi yeni. Sorunuzu bekliyorum.")
    }

    func testMemoryUploadsOnceAndSessionUsesTheCacheThenReleasesIt() async {
        let memory = FakeMemory()
        chat = makeChat(memory: memory)
        log.autoFinish = true
        options.session = true
        docs.result = .success((docs: [GeminiDoc(name: "a.pdf", fileURL: URL(fileURLWithPath: "/tmp/yok.pdf"), size: 10, pages: 40, key: "k1")], notes: []))
        recorder.results = [(Data(count: 32000), .done), noSpeech]
        chat.ask()
        _ = await waitUntil { self.chat.status == "Oturum bitti" }
        XCTAssertEqual(log.spoken.first, "1 belge, 40 sayfa hazır. Sorunuzu bekliyorum.")
        XCTAssertEqual(client.calls.count, 1)
        XCTAssertEqual(client.calls[0].cached, "cachedContents/1")
        XCTAssertEqual(memory.sessions, [true, true], "hazırlıkta ve soruda hafıza oturum kipinde hazırlanır")
        let released = await waitUntil { memory.released == 1 }
        XCTAssertTrue(released, "oturum bitince önbellek silinmeli")
    }

    func testRestartingASessionDoesNotLetTheOldRunDeleteTheNewCache() async {
        let memory = FakeMemory()
        chat = makeChat(memory: memory)
        log.autoFinish = true
        options.session = true
        recorder.hold = true
        chat.ask()
        _ = await waitUntil { self.recorder.waits.count == 1 }
        chat.cancel()
        chat.ask()                                  // durdurup hemen yeniden sorulur: eski çalışma henüz sonlanmadı
        _ = await waitUntil { self.recorder.waits.count == 2 }
        chat.cancel()
        _ = await waitUntil { memory.released >= 1 }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(memory.released, 1, "yalnız son başlatılan çalışma önbelleği siler")
    }

    func testSingleQuestionUsesFilesButNoCache() async {
        let memory = FakeMemory()
        chat = makeChat(memory: memory)
        chat.ask(text: "toplam nedir")
        _ = await waitUntil { self.chat.phase == .speaking }
        XCTAssertEqual(memory.sessions, [false])
        XCTAssertEqual(client.calls[0].cached, "")
        XCTAssertEqual(memory.released, 0)
    }

    func testMemoryFailureFallsBackToInlineDocumentsWithANote() async {
        let memory = FakeMemory()
        memory.uploadFailure = GeminiError("Yükleme başarısız.", .http, status: 500)
        chat = makeChat(memory: memory)
        chat.ask(text: "toplam nedir")
        _ = await waitUntil { self.chat.phase == .speaking }
        XCTAssertEqual(client.calls.count, 1)
        XCTAssertEqual(client.calls[0].cached, "")
        XCTAssertTrue(chat.notes.contains("Belgeler Gemini hafızasına alınamadı, doğrudan gönderiliyor."), "\(chat.notes)")
    }

    func testKeyErrorDuringUploadIsReportedNotHidden() async {
        let memory = FakeMemory()
        memory.uploadFailure = GeminiError("API anahtarı geçersiz.", .key, status: 400)
        chat = makeChat(memory: memory)
        chat.ask(text: "toplam nedir")
        _ = await waitUntil { self.chat.phase == .speaking }
        XCTAssertEqual(client.calls.count, 0)
        XCTAssertEqual(chat.error, "API anahtarı geçersiz.")
    }

    func testExpiredCacheIsDroppedAndTheQuestionIsRetriedWithoutIt() async {
        let memory = FakeMemory()
        chat = makeChat(memory: memory)
        log.autoFinish = true
        options.session = true
        client.replies = [.failure(GeminiError("Önbellek bulunamadı.", .http, status: 404)), .success(GeminiAnswer(question: "q", answer: "Tamam."))]
        docs.result = .success((docs: [GeminiDoc(name: "a.pdf", fileURL: URL(fileURLWithPath: "/tmp/yok.pdf"), size: 10, pages: 40, key: "k1")], notes: []))
        recorder.results = [(Data(count: 32000), .done), noSpeech]
        chat.ask()
        _ = await waitUntil { self.chat.status == "Oturum bitti" }
        XCTAssertEqual(client.calls.map { $0.cached }, ["cachedContents/1", ""])
        XCTAssertEqual(memory.dropped, 1)
        XCTAssertTrue(log.spoken.contains("Tamam. Sonraki sorunuzu bekliyorum."), "\(log.spoken)")
    }

    func testServerErrorWithCacheFallsBackToAskingWithoutIt() async {
        let memory = FakeMemory()
        chat = makeChat(memory: memory)
        log.autoFinish = true
        options.session = true
        client.replies = [.failure(GeminiError("Gemini şu an yanıt vermiyor (503).", .http, status: 503)), .success(GeminiAnswer(question: "q", answer: "Tamam."))]
        docs.result = .success((docs: [GeminiDoc(name: "a.pdf", fileURL: URL(fileURLWithPath: "/tmp/yok.pdf"), size: 10, pages: 40, key: "k1")], notes: []))
        recorder.results = [(Data(count: 32000), .done), noSpeech]
        chat.ask()
        _ = await waitUntil { self.chat.status == "Oturum bitti" }
        XCTAssertEqual(client.calls.map { $0.cached }, ["cachedContents/1", ""])
        XCTAssertEqual(memory.dropped, 1)
        XCTAssertTrue(log.spoken.contains("Tamam. Sonraki sorunuzu bekliyorum."), "\(log.spoken)")
    }

    func testLostFilesAreReuploadedAndTheQuestionIsRetried() async {
        let memory = FakeMemory()
        memory.lostOnRevalidate = 1
        chat = makeChat(memory: memory)
        client.replies = [.failure(GeminiError("Dosya bulunamadı.", .http, status: 403)), .success(GeminiAnswer(question: "q", answer: "Tamam."))]
        docs.result = .success((docs: [GeminiDoc(name: "a.pdf", fileURL: URL(fileURLWithPath: "/tmp/yok.pdf"), size: 10, pages: 40, key: "k1")], notes: []))
        chat.ask(text: "toplam nedir")
        _ = await waitUntil { self.chat.phase == .speaking }
        XCTAssertEqual(client.calls.count, 2)
        XCTAssertEqual(memory.revalidated, 1)
        XCTAssertEqual(memory.uploads, 1)
        XCTAssertEqual(chat.answer, "Tamam.")
    }

    func testUnrelatedHTTPErrorIsNotRetriedAsAFileProblem() async {
        let memory = FakeMemory()
        chat = makeChat(memory: memory)
        client.replies = [.failure(GeminiError("Sunucu hatası.", .http, status: 500))]
        chat.ask(text: "toplam nedir")
        _ = await waitUntil { self.chat.phase == .speaking }
        XCTAssertEqual(client.calls.count, 1)
        XCTAssertEqual(memory.revalidated, 0)
        XCTAssertEqual(chat.error, "Sunucu hatası.")
    }

    // MARK: Yedek model (yoğunluk / kota)

    private let busy503 = GeminiError("Gemini şu an yanıt vermiyor (503). Sunucunun mesajı: This model is currently experiencing high demand. Biraz sonra yeniden deneyin.", .http, status: 503)
    private let dailyQuota = GeminiError("Bu modelin günlük kotası doldu (sınır: 20).", .quota, status: 429)
    private let minuteQuota = GeminiError("Dakikalık istek sınırı aşıldı. Yaklaşık 20 saniye bekleyip yeniden deneyin.", .quota, status: 429)

    private func askAndWait(_ text: String = "toplam nedir") async {
        XCTAssertTrue(chat.ask(text: text))
        _ = await waitUntil { self.chat.phase == .speaking }
    }

    func testBusyModelFallsBackToBackupWithoutRetryingTheSelectedModel() async {
        options.overloadFallback = true
        client.fallback = ["gemini-3.7-flash", "gemini-3.8-flash-lite"]
        client.replies = [.failure(busy503), .success(GeminiAnswer(question: "q", answer: "Yedek cevap."))]
        await askAndWait()
        XCTAssertEqual(client.calls.map { $0.model ?? "-" }, ["-", "gemini-3.7-flash"])
        XCTAssertEqual(client.calls.map { $0.retries ?? -1 }, [0, 0])
        XCTAssertEqual(chat.answer, "Yedek cevap.")
        XCTAssertEqual(chat.error, "")
        XCTAssertTrue(chat.notes.contains { $0.contains("gemini-3.7-flash") && $0.contains("gemini-3.8-flash") && $0.contains("şu an yoğun") },
                      "\(chat.notes)")
    }

    func testQuotaExceededFallsBackToBackupAndSaysSo() async {
        options.overloadFallback = true
        client.fallback = ["gemini-3.7-flash"]
        client.replies = [.failure(minuteQuota), .success(GeminiAnswer(question: "q", answer: "Yedek cevap."))]
        await askAndWait()
        XCTAssertEqual(client.calls.map { $0.model ?? "-" }, ["-", "gemini-3.7-flash"])
        XCTAssertEqual(chat.answer, "Yedek cevap.")
        XCTAssertTrue(chat.notes.contains { $0.contains("kotası dolu") }, "\(chat.notes)")
    }

    func testBackupModelStaysInUseForTheNextQuestions() async {
        options.overloadFallback = true
        client.fallback = ["gemini-3.7-flash"]
        client.replies = [.failure(busy503), .success(GeminiAnswer(question: "q", answer: "Bir.")),
                          .success(GeminiAnswer(question: "q", answer: "İki."))]
        await askAndWait()
        chat.speakingChanged(false)
        XCTAssertEqual(chat.phase, .idle)
        await askAndWait("kdv orani kac")
        XCTAssertEqual(client.calls.map { $0.model ?? "-" }, ["-", "gemini-3.7-flash", "gemini-3.7-flash"])
        XCTAssertEqual(client.fallbackCalls, 1)
        XCTAssertEqual(chat.answer, "İki.")
    }

    func testBackupStopsBeingUsedWhenTheSelectedModelChanges() async {
        options.overloadFallback = true
        client.fallback = ["gemini-3.7-flash"]
        client.replies = [.failure(busy503), .success(GeminiAnswer(question: "q", answer: "Bir."))]
        await askAndWait()
        chat.speakingChanged(false)
        XCTAssertEqual(chat.phase, .idle)
        client.current = "gemini-3.9-flash"
        await askAndWait("kdv orani kac")
        XCTAssertEqual(client.calls.map { $0.model ?? "-" }, ["-", "gemini-3.7-flash", "-"])
        XCTAssertEqual(client.calls.last?.retries, 0)
    }

    func testBusyModelWithoutAnyBackupIsRetriedOnceMore() async {
        options.overloadFallback = true
        client.fallback = []
        client.replies = [.failure(busy503), .success(GeminiAnswer(question: "q", answer: "İkinci denemede."))]
        await askAndWait()
        XCTAssertEqual(client.calls.map { $0.model ?? "-" }, ["-", "-"])
        XCTAssertEqual(client.calls.map { $0.retries ?? -1 }, [0, 1])
        XCTAssertEqual(chat.answer, "İkinci denemede.")
    }

    func testQuotaWithoutAnyBackupIsNotRetried() async {
        options.overloadFallback = true
        client.fallback = []
        client.replies = [.failure(dailyQuota)]
        await askAndWait()
        XCTAssertEqual(client.calls.count, 1)
        XCTAssertEqual(chat.error, dailyQuota.message)
    }

    func testWhenEveryModelFailsTheQuotaMessageWins() async {
        options.overloadFallback = true
        client.fallback = ["gemini-3.7-flash", "gemini-3.8-flash-lite"]
        client.replies = [.failure(busy503), .failure(dailyQuota), .failure(busy503)]
        await askAndWait()
        XCTAssertEqual(client.calls.count, 3)
        XCTAssertEqual(chat.error, dailyQuota.message)
    }

    func testSpendingCapAndKeyErrorsNeverTriggerTheBackupModel() async {
        options.overloadFallback = true
        client.fallback = ["gemini-3.7-flash"]
        client.replies = [.failure(GeminiError("Aylık harcama sınırınız doldu.", .cap, status: 429))]
        await askAndWait()
        XCTAssertEqual(client.calls.count, 1)
        XCTAssertEqual(client.fallbackCalls, 0)
        XCTAssertEqual(chat.error, "Aylık harcama sınırınız doldu.")
    }

    func testBackupIsOffWhenTheOptionIsOff() async {
        options.overloadFallback = false
        client.fallback = ["gemini-3.7-flash"]
        client.replies = [.failure(busy503)]
        await askAndWait()
        XCTAssertEqual(client.calls.count, 1)
        XCTAssertEqual(client.fallbackCalls, 0)
        XCTAssertEqual(chat.error, busy503.message)
    }

    func testBusyModelKeepsTheDocumentCacheAndAsksTheBackupWithoutIt() async {
        let memory = FakeMemory()
        chat = makeChat(memory: memory)
        log.autoFinish = true
        options.session = true
        options.overloadFallback = true
        client.fallback = ["gemini-3.7-flash"]
        client.replies = [.failure(busy503), .success(GeminiAnswer(question: "q", answer: "Tamam."))]
        docs.result = .success((docs: [GeminiDoc(name: "a.pdf", fileURL: URL(fileURLWithPath: "/tmp/yok.pdf"), size: 10, pages: 40, key: "k1")], notes: []))
        recorder.results = [(Data(count: 32000), .done), noSpeech]
        chat.ask()
        _ = await waitUntil { self.chat.status == "Oturum bitti" }
        XCTAssertEqual(client.calls.map { $0.cached }, ["cachedContents/1", ""])
        XCTAssertEqual(client.calls.map { $0.model ?? "-" }, ["-", "gemini-3.7-flash"])
        XCTAssertEqual(memory.dropped, 0)
    }
}

// MARK: - Belge önbelleği

private final class FakeDrive: GeminiDriveSource, @unchecked Sendable {
    var listing: [DriveFileInfo] = []
    private let lock = NSLock()
    private var log: [String] = []
    /// Veri sayfa işaretleri içersin diye PDF gibi görünen baytlar (her sayfa "/Type /Page")
    var pagesPerFile: [String: Int] = [:]

    var downloads: [String] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    func listPDFs(count: Int) async throws -> [DriveFileInfo] {
        return Array(listing.prefix(count))
    }

    func download(fileID: String) async throws -> Data {
        lock.lock()
        log.append(fileID)
        lock.unlock()
        let size = listing.first(where: { $0.id == fileID })?.size ?? 0
        if let pages = pagesPerFile[fileID] {
            var text = "%PDF-1.4\n"
            for _ in 0..<pages { text += "<< /Type /Page >>\n" }
            var data = Data(text.utf8)
            if data.count < size { data.append(Data(repeating: 32, count: size - data.count)) }
            return data
        }
        return Data(repeating: 7, count: size)
    }
}

final class GeminiDocStoreTests: XCTestCase {
    private var directory = FileManager.default.temporaryDirectory

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-test-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func info(_ id: String, _ size: Int) -> DriveFileInfo {
        return DriveFileInfo(id: id, name: "\(id).pdf", size: size, created: "")
    }

    func testDownloadsOnceThenUsesCache() async throws {
        let drive = FakeDrive()
        drive.listing = [info("yeni", 120), info("eski", 80)]
        let store = GeminiDocStore(source: drive, cacheDirectory: directory)

        let first = try await store.fetch(count: 2)
        XCTAssertEqual(first.docs.map { $0.name }, ["yeni.pdf", "eski.pdf"])
        XCTAssertEqual(first.docs.map { $0.data.count }, [120, 80])
        XCTAssertEqual(drive.downloads.sorted(), ["eski", "yeni"])

        let second = try await store.fetch(count: 2)
        XCTAssertEqual(second.docs.map { $0.data.count }, [120, 80])
        XCTAssertEqual(drive.downloads.count, 2, "ikinci çağrıda yeniden indirilmemeli")
    }

    func testChangedSizeInvalidatesCache() async throws {
        let drive = FakeDrive()
        drive.listing = [info("a", 100)]
        let store = GeminiDocStore(source: drive, cacheDirectory: directory)
        _ = try await store.fetch(count: 1)
        drive.listing = [info("a", 150)]
        let again = try await store.fetch(count: 1)
        XCTAssertEqual(again.docs[0].data.count, 150)
        XCTAssertEqual(drive.downloads, ["a", "a"])
    }

    func testPageBudgetKeepsNewestAndReportsSkipped() async throws {
        let drive = FakeDrive()
        drive.listing = [info("a", 300), info("b", 300), info("c", 300)]
        drive.pagesPerFile = ["a": 200, "b": 200, "c": 150]
        let store = GeminiDocStore(source: drive, cacheDirectory: directory, maxPages: 500)
        let result = try await store.fetch(count: 3)
        XCTAssertEqual(result.docs.map { $0.name }, ["a.pdf", "b.pdf"])
        XCTAssertEqual(result.docs.map { $0.pages }, [200, 200])
        XCTAssertEqual(result.notes, ["1 belge 500 sayfa sınırı nedeniyle atlandı."])
    }

    func testExactly500PagesFitAndThe501stDoesNot() async throws {
        let drive = FakeDrive()
        drive.listing = [info("a", 300), info("b", 300), info("c", 300)]
        drive.pagesPerFile = ["a": 100, "b": 200, "c": 200]
        let store = GeminiDocStore(source: drive, cacheDirectory: directory, maxPages: 500)
        let fit = try await store.fetch(count: 3)
        XCTAssertEqual(fit.docs.map { $0.name }, ["a.pdf", "b.pdf", "c.pdf"])
        XCTAssertTrue(fit.notes.isEmpty)
        drive.listing = [info("n", 300)] + drive.listing
        drive.pagesPerFile["n"] = 1
        let over = try await store.fetch(count: 4)
        XCTAssertEqual(over.docs.map { $0.name }, ["n.pdf", "a.pdf", "b.pdf"])
        XCTAssertEqual(over.notes, ["1 belge 500 sayfa sınırı nedeniyle atlandı."])
    }

    func testPageCountsAreRememberedBetweenFetches() async throws {
        let drive = FakeDrive()
        drive.listing = [info("a", 300), info("b", 300)]
        drive.pagesPerFile = ["a": 10, "b": 20]
        let store = GeminiDocStore(source: drive, cacheDirectory: directory)
        _ = try await store.fetch(count: 2)
        let before = drive.downloads.count
        let again = GeminiDocStore(source: drive, cacheDirectory: directory)
        let result = try await again.fetch(count: 2)
        XCTAssertEqual(result.docs.map { $0.pages }, [10, 20])
        XCTAssertEqual(drive.downloads.count, before, "sayfa sayıları diskteki eşlemeden gelmeli, yeniden indirilmemeli")
    }

    func testDocumentBytesAreReloadedWhenTheCacheFileIsGone() async throws {
        let drive = FakeDrive()
        drive.listing = [info("a", 300)]
        drive.pagesPerFile = ["a": 3]
        let store = GeminiDocStore(source: drive, cacheDirectory: directory)
        let result = try await store.fetch(count: 1)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("a.pdf"))
        let data = try await result.docs[0].load()
        XCTAssertEqual(data.count, 300)
        XCTAssertEqual(drive.downloads, ["a", "a"])
    }

    func testEmptyFolderGivesNote() async throws {
        let store = GeminiDocStore(source: FakeDrive(), cacheDirectory: directory)
        let result = try await store.fetch(count: 3)
        XCTAssertTrue(result.docs.isEmpty)
        XCTAssertTrue(result.notes.joined().contains("PDF"))
    }

    func testCacheKeepsOnlyNewestFiles() async throws {
        let drive = FakeDrive()
        drive.listing = (1...6).map { info("f\($0)", 10 + $0) }
        let store = GeminiDocStore(source: drive, cacheDirectory: directory, keep: 3)
        _ = try await store.fetch(count: 6)
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".pdf") }
        XCTAssertEqual(files.count, 3)
    }
}
