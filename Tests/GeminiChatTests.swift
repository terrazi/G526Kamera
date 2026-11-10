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
    /// Sırayla verilecek sonuçlar; bitince `result` verilir
    var results: [(pcm: Data, outcome: QuestionOutcome)] = []
    /// Her kayıtta istenen "konuşma başlasın diye bekleme" süresi
    var waits: [TimeInterval] = []
    /// true: kayıt, `cancel()` gelene kadar sürer
    var hold = false
    var entered = false
    var cancelled = 0
    private var pending: CheckedContinuation<(pcm: Data, outcome: QuestionOutcome), Never>?

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

private final class Log {
    var spoken: [String] = []
    var active: [Bool] = []
    var speakResult = true
    /// true: okuma hemen bitmiş sayılır (oturum akışı okuma bitmesini bekler)
    var autoFinish = false
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
        chat.speak = { [weak chat] text in
            log.spoken.append(text)
            if log.speakResult && log.autoFinish {
                Task { @MainActor in chat?.speakingChanged(false) }
            }
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
