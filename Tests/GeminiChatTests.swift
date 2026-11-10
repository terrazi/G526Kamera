import XCTest
@testable import G526CameraDrive

// MARK: - Sahte bileşenler

private final class FakeClient: GeminiAsking {
    struct Call {
        var text: String
        var audio: Data?
        var docs: [String]
        var history: [GeminiTurn]
    }

    var replies: [Result<GeminiAnswer, Error>] = []
    var calls: [Call] = []

    func ask(questionText: String, audioWAV: Data?, docs: [GeminiDoc], history: [GeminiTurn]) async throws -> GeminiAnswer {
        calls.append(Call(text: questionText, audio: audioWAV, docs: docs.map { $0.name }, history: history))
        if replies.isEmpty { return GeminiAnswer(question: questionText, answer: "Cevap \(calls.count).") }
        return try replies.removeFirst().get()
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
    /// true: kayıt, `cancel()` gelene kadar sürer
    var hold = false
    var entered = false
    var cancelled = 0
    private var pending: CheckedContinuation<(pcm: Data, outcome: QuestionOutcome), Never>?

    func record(onStatus: @escaping (String) -> Void) async -> (pcm: Data, outcome: QuestionOutcome) {
        entered = true
        onStatus("Dinliyorum")
        if !hold { return result }
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

private final class Log {
    var spoken: [String] = []
    var active: [Bool] = []
    var speakResult = true
}

@MainActor
final class GeminiChatTests: XCTestCase {
    private var client = FakeClient()
    private var docs = FakeDocs()
    private var recorder = FakeRecorder()
    private var log = Log()
    private var options = GeminiOptions(privacyOK: true, hasKey: true, docCount: 3)
    private var chat: GeminiChat!

    override func setUp() {
        super.setUp()
        client = FakeClient()
        docs = FakeDocs()
        recorder = FakeRecorder()
        log = Log()
        options = GeminiOptions(privacyOK: true, hasKey: true, docCount: 3)
        let box = self
        let chat = GeminiChat(client: client, docs: docs, recorder: recorder, options: { box.options })
        let log = self.log
        chat.speak = { text in
            log.spoken.append(text)
            return log.speakResult
        }
        chat.stopSpeaking = {}
        chat.onActiveChange = { log.active.append($0) }
        self.chat = chat
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

    func testHistoryKeepsLastSixTurns() async {
        for n in 1...8 {
            chat.ask(text: "soru \(n)")
            _ = await waitUntil { self.chat.phase == .speaking }
            chat.speakingChanged(false)
        }
        XCTAssertEqual(client.calls.map { $0.history.count }, [0, 1, 2, 3, 4, 5, 6, 6])
        XCTAssertEqual(chat.history.count, 6)
        XCTAssertEqual(chat.history.first?.question, "soru 3")
        XCTAssertEqual(client.calls[7].history.last?.question, "soru 7")
        XCTAssertEqual(chat.turns, 8)
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
}

// MARK: - Belge önbelleği

private final class FakeDrive: GeminiDriveSource {
    var listing: [DriveFileInfo] = []
    var downloads: [String] = []

    func listPDFs(count: Int) async throws -> [DriveFileInfo] {
        return Array(listing.prefix(count))
    }

    func download(fileID: String) async throws -> Data {
        downloads.append(fileID)
        let size = listing.first(where: { $0.id == fileID })?.size ?? 0
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
        XCTAssertEqual(drive.downloads, ["yeni", "eski"])

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

    func testBudgetSkipsDocumentsAndReportsIt() async throws {
        let drive = FakeDrive()
        drive.listing = [info("a", 60), info("b", 60), info("c", 30)]
        let store = GeminiDocStore(source: drive, cacheDirectory: directory, budget: 100)
        let result = try await store.fetch(count: 3)
        XCTAssertEqual(result.docs.map { $0.name }, ["a.pdf", "c.pdf"])
        XCTAssertEqual(result.notes.count, 1)
        XCTAssertTrue(result.notes[0].contains("1 belge"))
        XCTAssertFalse(drive.downloads.contains("b"))
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
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertEqual(files.count, 3)
    }
}
