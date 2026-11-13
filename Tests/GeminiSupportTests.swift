import XCTest
@testable import G526CameraDrive

final class GeminiSupportTests: XCTestCase {
    // MARK: Hata çevirisi

    private func describe(_ status: Int, _ message: String, reason: String = "") -> (GeminiErrorKind, String) {
        var err: [String: Any] = ["message": message]
        if !reason.isEmpty { err["details"] = [["reason": reason]] }
        return GeminiSupport.describeError(status: status, json: ["error": err], model: "m")
    }

    func testErrorMapping() {
        XCTAssertEqual(describe(400, "API key not valid. Please pass a valid API key.", reason: "API_KEY_INVALID").0, .key)
        XCTAssertEqual(describe(403, "denied").0, .key)
        XCTAssertEqual(describe(404, "not found").0, .model)
        XCTAssertEqual(describe(503, "x").0, .http)
        XCTAssertEqual(describe(413, "x").0, .tooBig)
        XCTAssertEqual(describe(400, "User location is not supported for the API use.").0, .key)
        let cap = describe(429, "Your project has exceeded its monthly spending cap.")
        XCTAssertEqual(cap.0, .cap)
        XCTAssertTrue(cap.1.contains("harcama sınırınız doldu"), cap.1)
        let quota = describe(429, "Quota exceeded. Please retry in 31.2s.")
        XCTAssertEqual(quota.0, .quota)
        XCTAssertTrue(quota.1.contains("32 saniye"), quota.1)
    }

    func testServerErrorShowsTheServersOwnMessage() {
        let body = Data("{\"error\":{\"message\":\"The model is overloaded.\"}}".utf8)
        let google = GeminiSupport.describeError(status: 503, json: GeminiSupport.errorObject(from: body), model: "m").1
        XCTAssertEqual(google, "Gemini şu an yanıt vermiyor (503). Sunucunun mesajı: The model is overloaded. Biraz sonra yeniden deneyin.")
        let html = Data("<html><body><h1>503 Service Unavailable</h1><p>Proxy blocked</p></body></html>".utf8)
        let proxy = GeminiSupport.describeError(status: 503, json: GeminiSupport.errorObject(from: html), model: "m").1
        XCTAssertTrue(proxy.contains("Proxy blocked"), proxy)
        XCTAssertFalse(proxy.contains("<"), proxy)
        XCTAssertEqual(GeminiSupport.describeError(status: 503, json: GeminiSupport.errorObject(from: Data()), model: "m").1,
                       "Gemini şu an yanıt vermiyor (503). Biraz sonra yeniden deneyin.")
    }

    // MARK: Kota mesajı, yoğunluk

    private func quotaDescribe(_ message: String, ids: [String] = []) -> String {
        let violations: [[String: Any]] = ids.map {
            ["quotaId": $0, "quotaMetric": "generativelanguage.googleapis.com/generate_content_free_tier_requests"]
        }
        let err: [String: Any] = ["message": message, "details": [["violations": violations]]]
        return GeminiSupport.describeError(status: 429, json: ["error": err], model: "m").1
    }

    func testQuotaMessageNamesTheDailyLimit() {
        let text = quotaDescribe("You exceeded your current quota. Quota exceeded for metric: generativelanguage.googleapis.com/generate_content_free_tier_requests, limit: 20, model: m\nPlease retry in 12s.",
                                 ids: ["GenerateRequestsPerDayPerProjectPerModel-FreeTier"])
        XCTAssertTrue(text.contains("günlük kotası doldu"), text)
        XCTAssertTrue(text.contains("sınır: 20"), text)
        XCTAssertTrue(text.contains("Quota exceeded for metric"), text)
    }

    func testQuotaMessageNamesTheMinuteLimits() {
        let tokens = quotaDescribe("Quota exceeded for metric: x_input_token_count, limit: 250000\nPlease retry in 20s.",
                                   ids: ["GenerateContentInputTokensPerMinutePerProjectPerModel-FreeTier"])
        XCTAssertTrue(tokens.contains("Dakikalık token sınırı"), tokens)
        XCTAssertTrue(tokens.contains("21 saniye"), tokens)
        let requests = quotaDescribe("Quota exceeded for metric: x_requests, limit: 5\nPlease retry in 12s.",
                                     ids: ["GenerateRequestsPerMinutePerProjectPerModel-FreeTier"])
        XCTAssertTrue(requests.contains("Dakikalık istek sınırı"), requests)
        XCTAssertTrue(requests.contains("13 saniye"), requests)
    }

    func testQuotaMessageWithoutDetailsStaysGeneric() {
        let text = quotaDescribe("Resource exhausted.")
        XCTAssertTrue(text.hasPrefix("Kota ya da hız sınırı aşıldı"), text)
        XCTAssertFalse(text.contains("Google:"), text)
    }

    func testOnlyBusyMessagesOn503CountAsOverload() {
        XCTAssertTrue(GeminiSupport.isOverload(GeminiError("Sunucunun mesajı: This model is currently experiencing high demand.", .http, status: 503)))
        XCTAssertTrue(GeminiSupport.isOverload(GeminiError("The model is overloaded.", .http, status: 503)))
        XCTAssertFalse(GeminiSupport.isOverload(GeminiError("Backend Error", .http, status: 503)))
        XCTAssertFalse(GeminiSupport.isOverload(GeminiError("high demand", .http, status: 500)))
    }

    // MARK: Küçük yardımcılar

    func testModelListKeepsOnlyGenerateContentModels() {
        let json: [String: Any] = ["models": [
            ["name": "models/gemini-3.8-pro", "supportedGenerationMethods": ["generateContent", "countTokens"]],
            ["name": "models/embedding-001", "supportedGenerationMethods": ["embedContent"]],
            ["name": "models/gemini-3.8-flash", "supportedGenerationMethods": ["generateContent"]],
            ["name": "models/gemini-3.8-flash", "supportedGenerationMethods": ["generateContent"]]
        ]]
        XCTAssertEqual(GeminiSupport.parseModelList(json), ["gemini-3.8-flash", "gemini-3.8-pro"])
        XCTAssertEqual(GeminiSupport.parseModelList([:]), [])
    }

    func testOptionCodesParse() {
        let codes = GeminiSupport.parseOptionCodes("A=ADANA, B-BURSA; c:CEYHAN, x, D=, A=ANKARA")
        XCTAssertEqual(codes.map { $0.letter }, ["A", "B", "C"])
        XCTAssertEqual(codes.map { $0.word }, ["ADANA", "BURSA", "CEYHAN"])
        XCTAssertEqual(GeminiSupport.parseOptionCodes(GeminiConfig.defaultOptionCodes).count, 5)
    }

    func testThinkingLevelOnlyForGemmaOrExplicitSetting() {
        XCTAssertEqual(GeminiSupport.thinkingLevel(model: "gemma-3-27b-it", setting: "auto"), "high")
        XCTAssertNil(GeminiSupport.thinkingLevel(model: "gemini-3.6-flash", setting: "auto"))
        XCTAssertEqual(GeminiSupport.thinkingLevel(model: "gemini-3.6-flash", setting: "high"), "high")
        XCTAssertNil(GeminiSupport.thinkingLevel(model: "gemini-2.5-flash", setting: "high"))
        let body = GeminiSupport.applyThinking(["generationConfig": ["temperature": 0.2]], level: "high")
        let config = body["generationConfig"] as? [String: Any]
        XCTAssertEqual((config?["thinkingConfig"] as? [String: String])?["thinkingLevel"], "high")
        XCTAssertEqual(config?["temperature"] as? Double, 0.2)
    }

    func testStripFence() {
        XCTAssertEqual(GeminiSupport.stripFence("```json\n{\"a\":1}\n```"), "{\"a\":1}")
        XCTAssertEqual(GeminiSupport.stripFence("{\"a\":1}"), "{\"a\":1}")
    }
}

// MARK: - Ağ istemcisi (sahte URLProtocol)

final class FakeGeminiProtocol: URLProtocol {
    struct Reply {
        var status: Int = 200
        var body: Data = Data()
        var error: Error?
        var headers: [String: String] = [:]
    }

    static let lock = NSLock()
    static var replies: [Reply] = []
    static var urls: [URL] = []
    static var headers: [[String: String]] = []
    static var bodies: [Data] = []
    static var methods: [String] = []

    static func reset() {
        lock.lock()
        replies = []
        urls = []
        headers = []
        bodies = []
        methods = []
        lock.unlock()
    }

    static func read(_ stream: InputStream) -> Data {
        var data = Data()
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { return true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { return request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream { body = FakeGeminiProtocol.read(stream) }
        let url = request.url!
        FakeGeminiProtocol.lock.lock()
        FakeGeminiProtocol.urls.append(url)
        FakeGeminiProtocol.headers.append(request.allHTTPHeaderFields ?? [:])
        FakeGeminiProtocol.bodies.append(body)
        FakeGeminiProtocol.methods.append(request.httpMethod ?? "")
        let reply = FakeGeminiProtocol.replies.isEmpty ? Reply(status: 500, body: Data(), error: nil)
                                                       : FakeGeminiProtocol.replies.removeFirst()
        FakeGeminiProtocol.lock.unlock()
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        var fields = ["Content-Type": "application/json"]
        for (k, v) in reply.headers { fields[k] = v }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: fields)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class SleepLog {
    var values: [TimeInterval] = []
}

final class GeminiClientTests: XCTestCase {
    private var sleeps = SleepLog()

    override func setUp() {
        super.setUp()
        FakeGeminiProtocol.reset()
        sleeps = SleepLog()
    }

    private func makeClient(key: String = " AIza-TEST \n", model: String = "") -> GeminiClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeGeminiProtocol.self]
        let log = sleeps
        return GeminiClient(session: URLSession(configuration: config), baseURL: "https://example.test/v1beta",
                            key: { key }, model: { model }, sleep: { seconds in log.values.append(seconds) })
    }

    private func okBody(_ text: String = "tamam") -> Data {
        let object: [String: Any] = ["candidates": [["finishReason": "STOP", "content": ["parts": [["text": text]]]]]]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private func errorBody(_ message: String, reason: String = "") -> Data {
        var err: [String: Any] = ["message": message]
        if !reason.isEmpty { err["details"] = [["reason": reason]] }
        return (try? JSONSerialization.data(withJSONObject: ["error": err])) ?? Data()
    }

    private func queue(_ replies: FakeGeminiProtocol.Reply...) {
        FakeGeminiProtocol.lock.lock()
        FakeGeminiProtocol.replies = replies
        FakeGeminiProtocol.lock.unlock()
    }

    private func failure(_ body: () async throws -> Void) async -> GeminiError? {
        do {
            try await body()
            return nil
        } catch let e as GeminiError {
            return e
        } catch {
            return GeminiError("başka hata: \(error)")
        }
    }

    private let body = Data("{}".utf8)

    func testSuccessfulRequestUsesKeyHeaderAndModelUrl() async throws {
        queue(.init(status: 200, body: okBody(), error: nil))
        let client = makeClient()
        let object = try await client.generate(model: "gemini-x", key: " AIza-TEST \n", body: body)
        XCTAssertNotNil(object as? [String: Any])
        XCTAssertEqual(FakeGeminiProtocol.urls.count, 1)
        XCTAssertEqual(FakeGeminiProtocol.urls[0].absoluteString, "https://example.test/v1beta/models/gemini-x:generateContent")
        let header = FakeGeminiProtocol.headers[0].first(where: { $0.key.lowercased() == "x-goog-api-key" })?.value
        XCTAssertEqual(header, "AIza-TEST")
        XCTAssertEqual(FakeGeminiProtocol.methods[0], "POST")
    }

    func testMissingKeyIsRejectedWithoutRequest() async {
        let client = makeClient(key: "  ")
        let e = await failure { _ = try await client.generate(model: "m", key: "  ", body: self.body) }
        XCTAssertEqual(e?.kind, .key)
        XCTAssertEqual(FakeGeminiProtocol.urls.count, 0)
    }

    func testInvalidKeyResponse() async {
        queue(.init(status: 400, body: errorBody("API key not valid. Please pass a valid API key.", reason: "API_KEY_INVALID"), error: nil))
        let client = makeClient()
        let e = await failure { _ = try await client.generate(model: "m", key: "AIza", body: self.body) }
        XCTAssertEqual(e?.kind, .key)
        XCTAssertEqual(e?.status, 400)
    }

    func testServerErrorIsRetriedWithGrowingWait() async throws {
        queue(.init(status: 503, body: errorBody("overloaded"), error: nil),
              .init(status: 503, body: errorBody("overloaded"), error: nil),
              .init(status: 200, body: okBody(), error: nil))
        let client = makeClient()
        _ = try await client.generate(model: "m", key: "AIza", body: body)
        XCTAssertEqual(FakeGeminiProtocol.urls.count, 3)
        XCTAssertEqual(sleeps.values, [1.5, 4.0])
    }

    func testPersistentServerErrorFailsAfterThreeRetries() async {
        queue(.init(status: 500, body: Data(), error: nil), .init(status: 500, body: Data(), error: nil),
              .init(status: 500, body: Data(), error: nil), .init(status: 500, body: Data(), error: nil),
              .init(status: 500, body: Data(), error: nil))
        let client = makeClient()
        let e = await failure { _ = try await client.generate(model: "m", key: "AIza", body: self.body) }
        XCTAssertEqual(e?.status, 500)
        XCTAssertEqual(FakeGeminiProtocol.urls.count, 4)
    }

    func testQuotaAndUnknownModelAreNotRetried() async {
        queue(.init(status: 429, body: errorBody("Quota exceeded. Please retry in 5s."), error: nil))
        let client = makeClient()
        let quota = await failure { _ = try await client.generate(model: "m", key: "AIza", body: self.body) }
        XCTAssertEqual(quota?.kind, .quota)
        XCTAssertEqual(FakeGeminiProtocol.urls.count, 1)
        FakeGeminiProtocol.reset()
        queue(.init(status: 404, body: errorBody("models/x is not found"), error: nil))
        let missing = await failure { _ = try await client.generate(model: "x", key: "AIza", body: self.body) }
        XCTAssertEqual(missing?.kind, .model)
    }

    func testNetworkErrorIsRetriedOnceThenReported() async {
        let offline = URLError(.notConnectedToInternet)
        queue(.init(status: 0, body: Data(), error: offline), .init(status: 0, body: Data(), error: offline))
        let client = makeClient()
        let e = await failure { _ = try await client.generate(model: "m", key: "AIza", body: self.body) }
        XCTAssertEqual(e?.kind, .network)
        XCTAssertEqual(FakeGeminiProtocol.urls.count, 2)
    }

    func testModelListRequest() async throws {
        let json: [String: Any] = ["models": [["name": "models/gemini-3.6-flash", "supportedGenerationMethods": ["generateContent"]]]]
        queue(.init(status: 200, body: (try? JSONSerialization.data(withJSONObject: json)) ?? Data(), error: nil))
        let names = try await makeClient().listModels()
        XCTAssertEqual(names, ["gemini-3.6-flash"])
        XCTAssertTrue(FakeGeminiProtocol.urls[0].absoluteString.hasPrefix("https://example.test/v1beta/models"))
    }
}
