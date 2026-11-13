import XCTest
@testable import G526CameraDrive

final class AnswerServiceTests: XCTestCase {
    private func doc(_ page: Int, pdf: Int = 10, video: Int = 0) -> AnswerDoc {
        return AnswerDoc(page: page, pdf: pdf > 0 ? Data(repeating: 0x25, count: pdf) : nil,
                         video: video > 0 ? Data(repeating: 0x66, count: video) : nil)
    }

    // MARK: İstek

    func testRequestBodyCarriesVideoAndPdfPerPageInPageOrder() throws {
        let data = try AnswerService.requestBody(docs: [doc(2, pdf: 10), doc(1, pdf: 10, video: 20)], total: 50, optionCount: 5, thinking: nil)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let contents = try XCTUnwrap(json["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 6, "1. sayfa: etiket + video + pdf; 2. sayfa: etiket + pdf; sonda istem")
        XCTAssertEqual(parts[0]["text"] as? String, "Sayfa 1: video ve net kareler (PDF)")
        let video = try XCTUnwrap(parts[1]["inlineData"] as? [String: Any])
        XCTAssertEqual(video["mimeType"] as? String, "video/mp4")
        XCTAssertEqual(video["data"] as? String, Data(repeating: 0x66, count: 20).base64EncodedString())
        let pdf = try XCTUnwrap(parts[2]["inlineData"] as? [String: Any])
        XCTAssertEqual(pdf["mimeType"] as? String, "application/pdf")
        XCTAssertEqual(parts[3]["text"] as? String, "Sayfa 2: net kareler (PDF)")
        XCTAssertNotNil(parts[4]["inlineData"])
        let last = try XCTUnwrap(parts[5]["text"] as? String)
        XCTAssertTrue(last.contains("1–50"), "toplam soru sayısı istemde: \(last)")
        let config = try XCTUnwrap(json["generationConfig"] as? [String: Any])
        XCTAssertEqual(config["responseMimeType"] as? String, "application/json")
        XCTAssertEqual(config["mediaResolution"] as? String, "MEDIA_RESOLUTION_HIGH")
        XCTAssertNotNil(config["responseSchema"])
        XCTAssertNotNil(json["systemInstruction"])
    }

    func testRequestBodyVideoOnlyPage() throws {
        let data = try AnswerService.requestBody(docs: [doc(3, pdf: 0, video: 5)], thinking: nil)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let parts = try XCTUnwrap((json["contents"] as? [[String: Any]])?.first?["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0]["text"] as? String, "Sayfa 3: video")
    }

    func testPromptMentionsTotalAndOptions() {
        let p = AnswerService.prompt(total: 40, optionCount: 4)
        XCTAssertTrue(p.contains("A–D"))
        XCTAssertTrue(p.contains("1–40"))
        XCTAssertFalse(AnswerService.prompt(total: 0, optionCount: 5).contains("toplam"), "sayı bilinmiyorsa söylenmez")
        XCTAssertTrue(AnswerService.prompt(total: 0, optionCount: 5).contains("A–E"))
    }

    func testSystemPromptTellsGeminiToReadNumbersFromThePage() {
        XCTAssertTrue(AnswerService.system.contains("Soru numarasını sayfadaki yazıdan oku"))
        XCTAssertTrue(AnswerService.system.contains("GEZDİREREK"))
    }

    func testSchemaCarriesTheFourFields() throws {
        let items = try XCTUnwrap((AnswerService.schema["properties"] as? [String: Any])?["cevaplar"] as? [String: Any])
        let props = try XCTUnwrap((items["items"] as? [String: Any])?["properties"] as? [String: Any])
        XCTAssertEqual(Set(props.keys), ["no", "durum", "sik", "deger"])
    }

    // MARK: Gruplama

    func testChunkSplitsByCountAndBytes() {
        let docs = (1...5).map { doc($0, pdf: 40) }
        XCTAssertEqual(AnswerService.chunk(docs, budget: 1000, maxDocs: 20).count, 1)
        XCTAssertEqual(AnswerService.chunk(docs, budget: 1000, maxDocs: 2).map { $0.count }, [2, 2, 1])
        XCTAssertEqual(AnswerService.chunk(docs, budget: 100, maxDocs: 20).map { $0.count }, [2, 2, 1], "100 bayt sınırı = iki sayfa")
        XCTAssertEqual(AnswerService.chunk([], budget: 100, maxDocs: 2).count, 0)
    }

    func testChunkKeepsPageOrderAndOversizeDocAlone() {
        let docs = [doc(9, pdf: 300, video: 200), doc(2, pdf: 10), doc(5, pdf: 10)]
        let chunks = AnswerService.chunk(docs, budget: 100, maxDocs: 20)
        XCTAssertEqual(chunks.map { $0.map { $0.page } }, [[2, 5], [9]])
    }

    func testDocBytesCountVideoAndPdf() {
        XCTAssertEqual(doc(1, pdf: 10, video: 30).bytes, 40)
        XCTAssertEqual(doc(1, pdf: 0, video: 30).bytes, 30)
    }

    // MARK: Cevabı çözme

    private func response(_ parts: [[String: Any]], finish: String = "STOP") -> [String: Any] {
        return ["candidates": [["finishReason": finish, "content": ["parts": parts]]]]
    }

    func testResponseTextSkipsThoughtParts() throws {
        let text = try AnswerService.responseText(response([["text": "düşünüyorum", "thought": true], ["text": " {\"a\":1} "]]))
        XCTAssertEqual(text, "{\"a\":1}")
    }

    func testResponseTextErrors() {
        XCTAssertThrowsError(try AnswerService.responseText("metin")) { XCTAssertEqual(($0 as? GeminiError)?.kind, .error) }
        XCTAssertThrowsError(try AnswerService.responseText(["promptFeedback": ["blockReason": "SAFETY"]])) {
            XCTAssertEqual(($0 as? GeminiError)?.kind, .blocked)
        }
        XCTAssertThrowsError(try AnswerService.responseText(["candidates": []])) { XCTAssertEqual(($0 as? GeminiError)?.kind, .empty) }
        XCTAssertThrowsError(try AnswerService.responseText(response([["text": "  "]], finish: "MAX_TOKENS"))) {
            let e = $0 as? GeminiError
            XCTAssertEqual(e?.kind, .empty)
            XCTAssertTrue(e?.message.contains("MAX_TOKENS") ?? false)
        }
    }

    func testParseHandlesFencesAndOddTypes() {
        let json = """
        ```json
        {"cevaplar":[{"no":"2","durum":"tamam","sik":"b)","deger":"elli"},
                     {"no":1.0,"durum":"belirsiz","sik":"A","deger":"x"},
                     {"no":2,"durum":"tamam","sik":"C","deger":"kopya"},
                     {"no":3,"sik":"","deger":""},
                     {"no":4,"durum":"saçma","sik":"E","deger":"y"},
                     {"no":0,"sik":"A"},
                     {"sik":"A"}]}
        ```
        """
        let records = AnswerService.parse(json)
        XCTAssertEqual(records.map { $0.number }, [1, 2, 3, 4], "numaraya göre sıralı, kopya yok, geçersizler atılır")
        XCTAssertEqual(records[0].status, "belirsiz")
        XCTAssertEqual(records[1], AnswerRecord(number: 2, status: "tamam", letter: "B", value: "elli"))
        XCTAssertEqual(records[2].status, AnswerRecord.unread, "şık ve değer yoksa okunamadı")
        XCTAssertEqual(records[3].status, "tamam")
    }

    func testParseInvalidJSON() {
        XCTAssertEqual(AnswerService.parse("bu json değil"), [])
        XCTAssertEqual(AnswerService.parse("{\"baska\":[]}"), [])
        XCTAssertEqual(AnswerService.parse(""), [])
    }

    func testLetterOf() {
        XCTAssertEqual(AnswerService.letterOf("B"), "B")
        XCTAssertEqual(AnswerService.letterOf("b)"), "B")
        XCTAssertEqual(AnswerService.letterOf("e"), "E")
        XCTAssertEqual(AnswerService.letterOf(""), "")
        XCTAssertEqual(AnswerService.letterOf("F"), "")
        XCTAssertEqual(AnswerService.letterOf("xyz"), "")
    }

    // MARK: Sesli cümle

    func testSpokenLine() {
        let codes: [(letter: String, word: String)] = [("A", "ADANA"), ("B", "BURSA")]
        XCTAssertEqual(AnswerService.spokenLine(AnswerRecord(number: 1, status: "tamam", letter: "A", value: "kırk iki"), codes: codes),
                       "Birinci soru, ADANA, kırk iki.")
        XCTAssertEqual(AnswerService.spokenLine(AnswerRecord(number: 12, status: "tamam", letter: "B", value: ""), codes: codes),
                       "On ikinci soru, BURSA.")
        XCTAssertEqual(AnswerService.spokenLine(AnswerRecord(number: 3, status: "belirsiz", letter: "C", value: "z"), codes: codes),
                       "Üçüncü soru, C, z. Emin değilim.", "kodu olmayan şık harfiyle okunur")
        XCTAssertEqual(AnswerService.spokenLine(AnswerRecord(number: 4, status: "okunamadi", letter: "", value: ""), codes: codes),
                       "Dördüncü soru okunamadı.")
        XCTAssertEqual(AnswerService.spokenLine(AnswerRecord(number: 5, status: "tamam", letter: "", value: "x"), codes: codes),
                       "Beşinci soru okunamadı.")
    }

    // MARK: Zincir yardımcıları

    private func profile(_ slot: Int, key: String = "AIza-k", model: String = "m") -> GeminiProfileInfo {
        return GeminiProfileInfo(slot: slot, name: "Profil \(slot)", model: model.isEmpty ? "" : "\(model)\(slot)", key: key, free: slot != 4)
    }

    func testChainOrderStartsAtActiveAndWraps() {
        let all = (1...4).map { profile($0) }
        XCTAssertEqual(AnswerService.chainOrder(profiles: all, active: 3).map { $0.slot }, [3, 4, 1, 2])
        XCTAssertEqual(AnswerService.chainOrder(profiles: all, active: 1).map { $0.slot }, [1, 2, 3, 4])
    }

    func testChainOrderSkipsProfilesWithoutKey() {
        let list = [profile(1), profile(2, key: ""), profile(3), profile(4, key: "  ")]
        XCTAssertEqual(AnswerService.chainOrder(profiles: list, active: 3).map { $0.slot }, [3, 1])
    }

    func testChainOrderFallsBackToFirstUsableProfile() {
        let list = [profile(1, key: ""), profile(2), profile(3)]
        XCTAssertEqual(AnswerService.chainOrder(profiles: list, active: 1).map { $0.slot }, [2, 3], "seçili profilin anahtarı boş: ilk dolu profil")
    }

    func testChainOrderEmptyWithoutAnyKey() {
        XCTAssertEqual(AnswerService.chainOrder(profiles: (1...4).map { profile($0, key: "") }, active: 1).count, 0)
        XCTAssertEqual(AnswerService.chainOrder(profiles: [], active: 1).count, 0)
    }

    func testChainWorthy() {
        XCTAssertTrue(AnswerService.chainWorthy(GeminiError("k", .quota, status: 429)))
        XCTAssertTrue(AnswerService.chainWorthy(GeminiError("k", .key, status: 400)))
        XCTAssertTrue(AnswerService.chainWorthy(GeminiError("k", .model, status: 404)))
        XCTAssertTrue(AnswerService.chainWorthy(GeminiError("k", .empty)))
        XCTAssertTrue(AnswerService.chainWorthy(GeminiError("k", .http, status: 503)))
        XCTAssertTrue(AnswerService.chainWorthy(GeminiError("k", .http, status: 500)))
        XCTAssertFalse(AnswerService.chainWorthy(GeminiError("k", .cap, status: 429)))
        XCTAssertFalse(AnswerService.chainWorthy(GeminiError("k", .blocked)))
        XCTAssertFalse(AnswerService.chainWorthy(GeminiError("k", .tooBig, status: 413)))
        XCTAssertFalse(AnswerService.chainWorthy(GeminiError("k", .network)), "internet yoksa başka model de çalışmaz")
        var timeout = GeminiError("k", .network)
        timeout.timedOut = true
        XCTAssertTrue(AnswerService.chainWorthy(timeout), "cevap gecikmesi başka modele geçirir")
        XCTAssertFalse(AnswerService.chainWorthy(GeminiError("k", .http, status: 400)))
    }

    func testSwitchText() {
        let a = profile(1), b = profile(2)
        XCTAssertEqual(AnswerService.switchText(from: a, error: GeminiError("x", .quota, status: 429), to: b),
                       "Profil 1 kotası doldu. Sorular Profil 2 modeline gönderiliyor.")
        var timeout = GeminiError("x", .network)
        timeout.timedOut = true
        XCTAssertTrue(AnswerService.switchText(from: a, error: timeout, to: b).hasPrefix("Profil 1 uzun süre cevap vermedi."))
        XCTAssertTrue(AnswerService.switchText(from: a, error: GeminiError("x", .key, status: 400), to: b).hasPrefix("Profil 1 için API anahtarı geçersiz."))
        XCTAssertTrue(AnswerService.switchText(from: a, error: GeminiError("x", .model, status: 404), to: b).hasPrefix("Profil 1 modeli bulunamadı."))
        XCTAssertTrue(AnswerService.switchText(from: a, error: GeminiError("model overloaded", .http, status: 503), to: b)
            .hasPrefix("Profil 1 şu an çok yoğun."))
        XCTAssertTrue(AnswerService.switchText(from: a, error: GeminiError("x", .empty), to: b).hasPrefix("Profil 1 cevap veremedi."))
    }

    func testFailureLineNamesTheKeyOnKeyErrors() {
        let p = profile(2, key: "AIzaSyABCDEFGH")
        let line = AnswerService.failureLine(profile: p, error: GeminiError("geçersiz", .key, status: 400))
        XCTAssertTrue(line.hasPrefix("Profil 2: geçersiz (anahtar: "), line)
        XCTAssertEqual(AnswerService.failureLine(profile: p, error: GeminiError("kota", .quota, status: 429)), "Profil 2: kota")
    }

    func testCombinedKeepsLastKindAndJoinsTrail() {
        var last = GeminiError("son", .quota, status: 429)
        last.timedOut = true
        let merged = AnswerService.combined(last, trail: ["A: bir.", "B: iki."])
        XCTAssertEqual(merged.message, "A: bir. B: iki.")
        XCTAssertEqual(merged.kind, .quota)
        XCTAssertEqual(merged.status, 429)
        XCTAssertTrue(merged.timedOut)
        XCTAssertEqual(AnswerService.combined(last, trail: []).message, "son")
    }

    func testWaitLimit() {
        XCTAssertNil(AnswerService.waitLimit(setting: 0, docCount: 5))
        XCTAssertEqual(AnswerService.waitLimit(setting: 30, docCount: 4), 62)
        XCTAssertEqual(AnswerService.waitLimit(setting: 3, docCount: 0), 10, "en az 10 sn")
    }
}

/// Model zinciri: sahte sunucuyla uçtan uca
final class AnswerChainTests: XCTestCase {
    private final class Notes { var list: [String] = [] }

    override func setUp() {
        super.setUp()
        FakeGeminiProtocol.reset()
    }

    private func profiles(keys: [String] = ["AIza-1", "AIza-2", "AIza-3", "AIza-4"]) -> [GeminiProfileInfo] {
        return keys.enumerated().map { GeminiProfileInfo(slot: $0.offset + 1, name: "Profil \($0.offset + 1)",
                                                         model: "model-\($0.offset + 1)", key: $0.element, free: true) }
    }

    private func makeClient(_ p: GeminiProfileInfo) -> GeminiClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeGeminiProtocol.self]
        return GeminiClient(session: URLSession(configuration: config), baseURL: "https://example.test/v1beta",
                            key: { p.key }, model: { p.model }, sleep: { _ in })
    }

    private func queue(_ replies: FakeGeminiProtocol.Reply...) {
        FakeGeminiProtocol.lock.lock()
        FakeGeminiProtocol.replies = replies
        FakeGeminiProtocol.lock.unlock()
    }

    private func answerBody(_ number: Int = 1, letter: String = "B") -> Data {
        let inner = "{\"cevaplar\":[{\"no\":\(number),\"durum\":\"tamam\",\"sik\":\"\(letter)\",\"deger\":\"elli\"}]}"
        let object: [String: Any] = ["candidates": [["finishReason": "STOP", "content": ["parts": [["text": inner]]]]]]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private func errorBody(_ message: String, reason: String = "") -> Data {
        var err: [String: Any] = ["message": message]
        if !reason.isEmpty { err["details"] = [["reason": reason]] }
        return (try? JSONSerialization.data(withJSONObject: ["error": err])) ?? Data()
    }

    private let docs = [AnswerDoc(page: 1, pdf: Data("%PDF".utf8), video: nil)]

    private func ask(_ list: [GeminiProfileInfo], active: Int = 1, notes: Notes) async throws -> [AnswerRecord] {
        return try await AnswerService.ask(docs: docs, profiles: list, active: active, waitLimit: 30,
                                           makeClient: { self.makeClient($0) }, notify: { notes.list.append($0) })
    }

    func testFirstProfileAnswers() async throws {
        queue(.init(status: 200, body: answerBody(), error: nil))
        let notes = Notes()
        let records = try await ask(profiles(), notes: notes)
        XCTAssertEqual(records, [AnswerRecord(number: 1, status: "tamam", letter: "B", value: "elli")])
        XCTAssertEqual(FakeGeminiProtocol.urls.count, 1)
        XCTAssertTrue(FakeGeminiProtocol.urls[0].absoluteString.contains("model-1"))
        XCTAssertTrue(notes.list.isEmpty)
    }

    func testQuotaMovesToTheNextProfileAndSaysWhy() async throws {
        queue(.init(status: 429, body: errorBody("You exceeded your current quota"), error: nil),
              .init(status: 200, body: answerBody(), error: nil))
        let notes = Notes()
        let records = try await ask(profiles(), notes: notes)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(FakeGeminiProtocol.urls.count, 2)
        XCTAssertTrue(FakeGeminiProtocol.urls[1].absoluteString.contains("model-2"))
        XCTAssertEqual(notes.list, ["Profil 1 kotası doldu. Sorular Profil 2 modeline gönderiliyor."])
    }

    func testStartsAtTheActiveProfile() async throws {
        queue(.init(status: 200, body: answerBody(), error: nil))
        _ = try await ask(profiles(), active: 3, notes: Notes())
        XCTAssertTrue(FakeGeminiProtocol.urls[0].absoluteString.contains("model-3"))
    }

    func testInvalidKeyMovesOn() async throws {
        queue(.init(status: 400, body: errorBody("API key not valid.", reason: "API_KEY_INVALID"), error: nil),
              .init(status: 200, body: answerBody(), error: nil))
        let notes = Notes()
        _ = try await ask(profiles(), notes: notes)
        XCTAssertTrue(notes.list.first?.hasPrefix("Profil 1 için API anahtarı geçersiz.") ?? false)
    }

    func testSpendingCapStopsTheChain() async {
        queue(.init(status: 429, body: errorBody("You have reached your spending cap"), error: nil),
              .init(status: 200, body: answerBody(), error: nil))
        do {
            _ = try await ask(profiles(), notes: Notes())
            XCTFail("hata vermeliydi")
        } catch let e as GeminiError {
            XCTAssertEqual(e.kind, .cap)
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(FakeGeminiProtocol.urls.count, 1, "harcama sınırında diğer modele geçilmez")
    }

    func testEmptyAnswerListMovesOn() async throws {
        let inner = "{\"cevaplar\":[]}"
        let object: [String: Any] = ["candidates": [["finishReason": "STOP", "content": ["parts": [["text": inner]]]]]]
        let emptyList = try JSONSerialization.data(withJSONObject: object)
        queue(.init(status: 200, body: emptyList, error: nil), .init(status: 200, body: answerBody(), error: nil))
        let notes = Notes()
        let records = try await ask(profiles(), notes: notes)
        XCTAssertEqual(records.first?.letter, "B")
        XCTAssertEqual(notes.list.count, 1)
        XCTAssertTrue(notes.list[0].hasPrefix("Profil 1 cevap veremedi."))
    }

    func testEveryProfileFailingGivesOneCombinedMessage() async {
        queue(.init(status: 429, body: errorBody("quota 1"), error: nil), .init(status: 429, body: errorBody("quota 2"), error: nil))
        let notes = Notes()
        do {
            _ = try await ask(profiles(keys: ["AIza-1", "AIza-2", "", ""]), notes: notes)
            XCTFail("hata vermeliydi")
        } catch let e as GeminiError {
            XCTAssertTrue(e.message.contains("Profil 1:"), e.message)
            XCTAssertTrue(e.message.contains("Profil 2:"), e.message)
            XCTAssertEqual(e.kind, .quota)
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(notes.list.count, 1, "yalnız geçişler bildirilir, son hata bildirilmez")
    }

    func testNoKeyAtAll() async {
        do {
            _ = try await ask(profiles(keys: ["", "", "", ""]), notes: Notes())
            XCTFail("hata vermeliydi")
        } catch let e as GeminiError {
            XCTAssertEqual(e.kind, .key)
            XCTAssertTrue(e.message.contains("anahtarı girilmemiş"))
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(FakeGeminiProtocol.urls.count, 0)
    }
}
