import XCTest
@testable import G526CameraDrive

// MARK: - Sahte bileşenler

private final class FakeTasking: GeminiTasking {
    struct Call {
        var model: String?
        var retries: Int?
        var uris: [String]
        var prompt: String
    }

    var currentModel = "gemini-ana"
    var backups: [String] = []
    /// Sırayla verilecek sonuçlar; bitince "{}" döner
    var results: [Result<String, GeminiError>] = []
    var calls: [Call] = []
    var fallbackCalls = 0

    func fallbackModels() async -> [String] {
        fallbackCalls += 1
        return backups
    }

    func runTask(_ task: ExamTask, docs: [GeminiDoc], model: String?, serverRetries: Int?) async throws -> String {
        calls.append(Call(model: model, retries: serverRetries, uris: docs.map { $0.uri }, prompt: task.prompt))
        if results.isEmpty { return "{}" }
        return try results.removeFirst().get()
    }
}

@MainActor
private final class FakeMem: GeminiMemoryProviding {
    var isWanted = true
    var uploadFailure: GeminiError?
    var uploads = 0
    var revalidated = 0
    var lostOnRevalidate = 0

    func wanted(_ docs: [GeminiDoc]) -> Bool { return isWanted }

    func prepare(_ docs: [GeminiDoc], session: Bool, progress: @escaping (Int, Int) -> Void) async throws -> (docs: [GeminiDoc], cache: String) {
        return (docs, "")
    }

    func upload(_ docs: [GeminiDoc], progress: @escaping (Int, Int) -> Void) async throws -> [GeminiDoc] {
        uploads += 1
        if let failure = uploadFailure { throw failure }
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

    func dropCache() async {}
    func release() async {}
}

private func remoteDoc(_ name: String, key: String) -> GeminiDoc {
    var d = GeminiDoc(name: name, data: Data("%PDF-1.4".utf8))
    d.key = key
    d.uri = "https://files/eski/\(name)"
    d.remote = "files/eski/\(name)"
    return d
}

private func localDoc(_ name: String, key: String) -> GeminiDoc {
    var d = GeminiDoc(name: name, data: Data("%PDF-1.4".utf8))
    d.key = key
    return d
}

private let task = ExamTask(prompt: "Şu soruları cevapla", schema: ExamPrompts.answerSchema)

// MARK: - İstek kurma ve cevap ayrıştırma

final class ExamGeminiRequestTests: XCTestCase {
    func testInlineDocsGoInOneUserTurnThenAckThenPrompt() throws {
        let obj = GeminiSupport.taskRequestObject(task, docs: [localDoc("a.pdf", key: "k1"), localDoc("b.pdf", key: "k2")])
        let contents = try XCTUnwrap(obj["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.count, 3)
        XCTAssertEqual(contents[0]["role"] as? String, "user")
        XCTAssertEqual(contents[1]["role"] as? String, "model")
        XCTAssertEqual(contents[2]["role"] as? String, "user")
        let parts = try XCTUnwrap(contents[0]["parts"] as? [[String: Any]])
        XCTAssertEqual(parts[0]["text"] as? String, "Belge 1: a.pdf")
        XCTAssertNotNil(parts[1]["inlineData"])
        XCTAssertEqual(parts[2]["text"] as? String, "Belge 2: b.pdf")
        XCTAssertEqual(parts.last?["text"] as? String, GeminiConfig.docsIntro)
        let last = try XCTUnwrap(contents[2]["parts"] as? [[String: Any]])
        XCTAssertEqual(last.first?["text"] as? String, "Şu soruları cevapla")
    }

    func testVideosGoInTheFinalTurnBeforeThePrompt() throws {
        var t = ExamTask(prompt: "Şu soruları cevapla", schema: [:], video: true)
        t.videos = [Data([1, 2, 3])]
        let obj = GeminiSupport.taskRequestObject(t, docs: [localDoc("a.pdf", key: "k1")])
        let contents = try XCTUnwrap(obj["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.count, 3)
        let last = try XCTUnwrap(contents[2]["parts"] as? [[String: Any]])
        XCTAssertEqual(last.first?["text"] as? String, GeminiConfig.examVideoIntro)
        XCTAssertEqual(last[1]["text"] as? String, "Video 1:")
        let video = try XCTUnwrap(last[2]["inlineData"] as? [String: Any])
        XCTAssertEqual(video["mimeType"] as? String, "video/mp4")
        XCTAssertEqual(last.last?["text"] as? String, "Şu soruları cevapla")
        let first = try XCTUnwrap(contents[0]["parts"] as? [[String: Any]])
        XCTAssertNil(first.compactMap { $0["inlineData"] as? [String: Any] }.first { ($0["mimeType"] as? String) == "video/mp4" })
    }

    func testPickVideosKeepsOnlyWhatFitsTheRequest() {
        let docs = [localDoc("a.pdf", key: "k1")]
        let size = docs[0].size
        let small = Data(count: 100)
        let big = Data(count: 5_000)
        XCTAssertEqual(ExamAsker.pickVideos([small, big], docs: docs, budget: size + 1_000).count, 1)
        XCTAssertEqual(ExamAsker.pickVideos([small, big], docs: docs, budget: size + 100_000).count, 2)
        XCTAssertEqual(ExamAsker.pickVideos([small], docs: [remoteDoc("r.pdf", key: "r")], budget: 150).count, 1,
                       "dosya adresiyle giden belge istek boyutunu doldurmaz")
        XCTAssertTrue(ExamAsker.pickVideos([big], docs: docs, budget: size).isEmpty)
    }

    func testRemoteDocsUseFileUris() throws {
        let obj = GeminiSupport.taskRequestObject(task, docs: [remoteDoc("a.pdf", key: "k1")])
        let contents = try XCTUnwrap(obj["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents[0]["parts"] as? [[String: Any]])
        let file = try XCTUnwrap(parts[1]["fileData"] as? [String: Any])
        XCTAssertEqual(file["fileUri"] as? String, "https://files/eski/a.pdf")
        XCTAssertNil(parts[1]["inlineData"])
    }

    func testRequestAsksForJSONWithSchemaAndSystem() throws {
        let data = try GeminiSupport.buildTaskRequest(task, docs: [])
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let config = try XCTUnwrap(obj["generationConfig"] as? [String: Any])
        XCTAssertEqual(config["responseMimeType"] as? String, "application/json")
        XCTAssertNotNil(config["responseSchema"])
        XCTAssertEqual(config["maxOutputTokens"] as? Int, 16384)
        let system = try XCTUnwrap((obj["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]])
        XCTAssertEqual(system.first?["text"] as? String, ExamPrompts.system)
        // belge yokken yalnız soru gider
        let contents = try XCTUnwrap(obj["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.count, 1)
    }

    func testAnswerPromptListsEveryQuestionKey() {
        let text = ExamPrompts.answerPrompt([(bolum: "", no: 3), (bolum: "Test 2", no: 7)])
        XCTAssertTrue(text.contains("no: 3"))
        XCTAssertTrue(text.contains("bolum: 'Test 2', no: 7"))
        XCTAssertTrue(text.hasPrefix("Şu soruları cevapla"))
    }

    func testRecheckPromptAsksForAFreshIndependentSolution() {
        let text = ExamPrompts.recheckPrompt([(bolum: "", no: 3), (bolum: "Test 2", no: 7)])
        XCTAssertTrue(text.hasPrefix("Şu soruları SIFIRDAN"))
        XCTAssertTrue(text.contains("no: 3"))
        XCTAssertTrue(text.contains("bolum: 'Test 2', no: 7"))
        XCTAssertNotEqual(text, ExamPrompts.answerPrompt([(bolum: "", no: 3), (bolum: "Test 2", no: 7)]))
    }

    func testParseTaskReturnsTextAndSkipsThoughts() throws {
        let object: [String: Any] = ["candidates": [["finishReason": "STOP", "content": ["parts": [
            ["text": "düşünce", "thought": true], ["text": "{\"cevaplar\":"], ["text": "[]}"]]]]]]
        XCTAssertEqual(try GeminiSupport.parseTask(object), "{\"cevaplar\":[]}")
    }

    func testParseTaskReportsBlockedAndEmpty() {
        XCTAssertThrowsError(try GeminiSupport.parseTask(["promptFeedback": ["blockReason": "SAFETY"]])) { error in
            XCTAssertEqual((error as? GeminiError)?.kind, .blocked)
        }
        XCTAssertThrowsError(try GeminiSupport.parseTask(["candidates": []])) { error in
            XCTAssertEqual((error as? GeminiError)?.kind, .empty)
        }
        let blank: [String: Any] = ["candidates": [["finishReason": "MAX_TOKENS", "content": ["parts": [["text": "  "]]]]]]
        XCTAssertThrowsError(try GeminiSupport.parseTask(blank)) { error in
            XCTAssertEqual((error as? GeminiError)?.kind, .empty)
            XCTAssertTrue((error as? GeminiError)?.message.contains("MAX_TOKENS") == true)
        }
        XCTAssertThrowsError(try GeminiSupport.parseTask("anlaşılmaz"))
    }

    func testSchemasHaveRequiredFields() {
        let verify = ExamPrompts.verifySchema
        XCTAssertEqual(verify["required"] as? [String], ["belgeler", "sorular", "okunamayan_sayfa", "not"])
        let answer = ExamPrompts.answerSchema
        XCTAssertEqual(answer["required"] as? [String], ["cevaplar"])
        XCTAssertTrue(ExamPrompts.system.contains("okunamadi"))
    }
}

// MARK: - Yedek model ve yeniden yükleme

@MainActor
final class ExamAskerTests: XCTestCase {
    func testSuccessfulAskUsesSelectedModel() async throws {
        let client = FakeTasking()
        client.results = [.success("{\"cevaplar\":[]}")]
        let asker = ExamAsker(client: client, memory: nil, overloadFallback: { true })
        let text = try await asker.ask(task, docs: [localDoc("a.pdf", key: "k1")])
        XCTAssertEqual(text, "{\"cevaplar\":[]}")
        XCTAssertEqual(client.calls.count, 1)
        XCTAssertNil(client.calls[0].model)
    }

    func testBusyModelFallsBackToBackupModel() async throws {
        let client = FakeTasking()
        client.backups = ["gemini-yedek"]
        client.results = [.failure(GeminiError("Gemini yoğun.", .http, status: 503)), .success("{\"ok\":1}")]
        let asker = ExamAsker(client: client, memory: nil, overloadFallback: { true })
        let text = try await asker.ask(task, docs: [])
        XCTAssertEqual(text, "{\"ok\":1}")
        XCTAssertEqual(client.calls.count, 2)
        XCTAssertEqual(client.calls[1].model, "gemini-yedek")
        XCTAssertEqual(client.calls[1].retries, 0)
    }

    func testFallbackIsSkippedWhenSettingIsOff() async {
        let client = FakeTasking()
        client.backups = ["gemini-yedek"]
        client.results = [.failure(GeminiError("Gemini yoğun.", .http, status: 503))]
        let asker = ExamAsker(client: client, memory: nil, overloadFallback: { false })
        do {
            _ = try await asker.ask(task, docs: [])
            XCTFail("hata beklenirdi")
        } catch let e as GeminiError {
            XCTAssertEqual(e.status, 503)
        } catch {
            XCTFail("beklenmeyen hata: \(error)")
        }
        XCTAssertEqual(client.calls.count, 1)
        XCTAssertEqual(client.fallbackCalls, 0)
    }

    func testQuotaErrorWinsWhenEveryBackupFails() async {
        let client = FakeTasking()
        client.backups = ["m2", "m3"]
        client.results = [.failure(GeminiError("Gemini yoğun.", .http, status: 503)),
                          .failure(GeminiError("Hata", .http, status: 500)),
                          .failure(GeminiError("Kota doldu.", .quota, status: 429))]
        let asker = ExamAsker(client: client, memory: nil, overloadFallback: { true })
        do {
            _ = try await asker.ask(task, docs: [])
            XCTFail("hata beklenirdi")
        } catch let e as GeminiError {
            XCTAssertEqual(e.kind, .quota)
        } catch {
            XCTFail("beklenmeyen hata: \(error)")
        }
        XCTAssertEqual(client.calls.map { $0.model ?? "ana" }, ["ana", "m2", "m3"])
    }

    func testKeyErrorIsNotRetriedOnBackupModels() async {
        let client = FakeTasking()
        client.backups = ["m2"]
        client.results = [.failure(GeminiError("Anahtar geçersiz.", .key, status: 401))]
        let asker = ExamAsker(client: client, memory: nil, overloadFallback: { true })
        do {
            _ = try await asker.ask(task, docs: [])
            XCTFail("hata beklenirdi")
        } catch let e as GeminiError {
            XCTAssertEqual(e.kind, .key)
        } catch {
            XCTFail("beklenmeyen hata: \(error)")
        }
        XCTAssertEqual(client.calls.count, 1)
    }

    func testLostFileIsReuploadedAndRetriedOnce() async throws {
        let client = FakeTasking()
        client.results = [.failure(GeminiError("Dosya bulunamadı.", .http, status: 404)), .success("{\"ok\":2}")]
        let mem = FakeMem()
        mem.lostOnRevalidate = 1
        let asker = ExamAsker(client: client, memory: mem, overloadFallback: { true })
        let text = try await asker.ask(task, docs: [remoteDoc("a.pdf", key: "k1")])
        XCTAssertEqual(text, "{\"ok\":2}")
        XCTAssertEqual(mem.revalidated, 1)
        XCTAssertEqual(mem.uploads, 1)
        XCTAssertEqual(client.calls.count, 2)
        XCTAssertEqual(client.calls[1].uris, ["https://files/yeni/a.pdf"])
        // sonraki isteklerde eski, kaybolmuş adres kullanılmaz
        _ = try await asker.ask(task, docs: [remoteDoc("a.pdf", key: "k1")])
        XCTAssertEqual(client.calls[2].uris, ["https://files/yeni/a.pdf"])
    }

    func testFileErrorWithoutLostFilesIsReported() async {
        let client = FakeTasking()
        client.results = [.failure(GeminiError("Geçersiz istek.", .http, status: 400))]
        let mem = FakeMem()
        mem.lostOnRevalidate = 0
        let asker = ExamAsker(client: client, memory: mem, overloadFallback: { true })
        do {
            _ = try await asker.ask(task, docs: [remoteDoc("a.pdf", key: "k1")])
            XCTFail("hata beklenirdi")
        } catch let e as GeminiError {
            XCTAssertEqual(e.status, 400)
        } catch {
            XCTFail("beklenmeyen hata: \(error)")
        }
        XCTAssertEqual(mem.uploads, 0)
        XCTAssertEqual(client.calls.count, 1)
    }

    // MARK: Hazırlık

    func testPrepareKeepsSmallSetsInline() async throws {
        let mem = FakeMem()
        mem.isWanted = false
        let asker = ExamAsker(client: FakeTasking(), memory: mem, overloadFallback: { true })
        let out = try await asker.prepare([localDoc("a.pdf", key: "k1")])
        XCTAssertEqual(out.map { $0.uri }, [""])
        XCTAssertEqual(mem.uploads, 0)
    }

    func testPrepareUploadsLargeSets() async throws {
        let mem = FakeMem()
        let asker = ExamAsker(client: FakeTasking(), memory: mem, overloadFallback: { true })
        let out = try await asker.prepare([localDoc("a.pdf", key: "k1"), localDoc("b.pdf", key: "k2")])
        XCTAssertEqual(out.map { $0.uri }, ["https://files/yeni/a.pdf", "https://files/yeni/b.pdf"])
        XCTAssertEqual(mem.uploads, 1)
    }

    func testPrepareFallsBackToInlineWhenUploadFailsForOtherReasons() async throws {
        let mem = FakeMem()
        mem.uploadFailure = GeminiError("Yükleme olmadı.", .http, status: 500)
        let asker = ExamAsker(client: FakeTasking(), memory: mem, overloadFallback: { true })
        let out = try await asker.prepare([remoteDoc("a.pdf", key: "k1")])
        XCTAssertEqual(out.map { $0.uri }, [""])
        XCTAssertEqual(out.map { $0.remote }, [""])
    }

    func testPrepareReportsKeyAndNetworkProblems() async {
        for kind in [GeminiErrorKind.key, .quota, .network] {
            let mem = FakeMem()
            mem.uploadFailure = GeminiError("Sorun", kind)
            let asker = ExamAsker(client: FakeTasking(), memory: mem, overloadFallback: { true })
            do {
                _ = try await asker.prepare([localDoc("a.pdf", key: "k1")])
                XCTFail("hata beklenirdi: \(kind)")
            } catch let e as GeminiError {
                XCTAssertEqual(e.kind, kind)
            } catch {
                XCTFail("beklenmeyen hata: \(error)")
            }
        }
    }
}
