import XCTest
import Network
@testable import G526CameraDrive

// MARK: - HTTP çözümleyici ve istek başı (ağsız)

final class HTTPWireTests: XCTestCase {
    private func bytes(_ text: String) -> Data { return Data(text.utf8) }

    private func parse(_ pieces: [String]) -> HTTPWire.ResponseParser.Step {
        let parser = HTTPWire.ResponseParser()
        var step = HTTPWire.ResponseParser.Step.more
        for piece in pieces {
            step = parser.feed(bytes(piece))
            if step != .more { break }
        }
        return step
    }

    private func response(_ step: HTTPWire.ResponseParser.Step, file: StaticString = #filePath, line: UInt = #line) -> HTTPWire.Response? {
        guard case .done(let r) = step else {
            XCTFail("cevap tamamlanmadı: \(step)", file: file, line: line)
            return nil
        }
        return r
    }

    func testAFixedLengthAnswerIsReadEvenWhenItArrivesByteByByte() {
        let text = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\n{\"ok\":true}"
        let parser = HTTPWire.ResponseParser()
        var step = HTTPWire.ResponseParser.Step.more
        for ch in text { step = parser.feed(bytes(String(ch))) }
        guard let r = response(step) else { return }
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self), "{\"ok\":true}")
        XCTAssertEqual(r.headers["content-type"], "application/json", "başlık adları küçük harfle anılır")
    }

    func testChunkedAnswersAreDecodedWithExtensionsAndTrailers() {
        let r = response(parse(["HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
                                "5\r\nhel", "lo\r\n6;ext=1\r\n wor", "ld\r\n",
                                "0\r\nX-Trailer: 1\r\n\r\n"]))
        XCTAssertEqual(r.map { String(decoding: $0.body, as: UTF8.self) }, "hello world")
    }

    func testBigChunkedBodiesComeOutWhole() {
        let part = String(repeating: "a", count: 70_000)
        let r = response(parse(["HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
                                String(70_000, radix: 16) + "\r\n" + part + "\r\n",
                                String(70_000, radix: 16) + "\r\n" + part + "\r\n0\r\n\r\n"]))
        XCTAssertEqual(r?.body.count, 140_000)
    }

    func testAnInterimContinueAnswerIsSkipped() {
        let r = response(parse(["HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 429 Too Many Requests\r\nContent-Length: 2\r\n\r\n{}"]))
        XCTAssertEqual(r?.status, 429, "asıl cevap ara cevabın arkasından gelir")
        XCTAssertEqual(r?.body.count, 2)
    }

    func testAnAnswerWithoutALengthEndsWhenTheServerCloses() {
        let parser = HTTPWire.ResponseParser()
        XCTAssertEqual(parser.feed(bytes("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nabc")), .more)
        XCTAssertEqual(parser.feed(bytes("def")), .more)
        guard let r = response(parser.end()) else { return }
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self), "abcdef")
    }

    func testNoContentAnswersFinishAtOnceWithoutABody() {
        let r = response(parse(["HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n"]))
        XCTAssertEqual(r?.status, 204)
        XCTAssertEqual(r?.body.count, 0)
    }

    func testCutOffAnswersAreReportedAndNeverMistakenForComplete() {
        let parser = HTTPWire.ResponseParser()
        _ = parser.feed(bytes("HTTP/1.1 200 OK\r\nContent-Length: 50\r\n\r\nshort"))
        guard case .failed = parser.end() else { return XCTFail("yarım cevap tamam sayıldı") }

        let chunked = HTTPWire.ResponseParser()
        _ = chunked.feed(bytes("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel"))
        guard case .failed = chunked.end() else { return XCTFail("yarım bölüm tamam sayıldı") }

        guard case .failed(let message) = HTTPWire.ResponseParser().end() else { return XCTFail("boş cevap tamam sayıldı") }
        XCTAssertTrue(message.contains("cevap vermeden"))
    }

    func testGarbageAndCompressedAnswersFail() {
        guard case .failed = parse(["garbage\r\n\r\n"]) else { return XCTFail("anlaşılmaz cevap kabul edildi") }
        guard case .failed(let message) = parse(["HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 3\r\n\r\nabc"]) else {
            return XCTFail("sıkıştırılmış cevap kabul edildi")
        }
        XCTAssertTrue(message.contains("gzip"))
        guard case .failed = parse(["HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n"]) else { return XCTFail("bozuk bölüm kabul edildi") }
    }

    func testTheRequestHeadHasHostLengthAndCloseAndKeepsThePathAndQuery() {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-x:generateContent?pageSize=1&alt=json")!
        let head = HTTPWire.requestHead(method: "POST", url: url, headers: ["x-goog-api-key": "K", "Content-Type": "application/json"], contentLength: 12)
        let text = head.map { String(decoding: $0, as: UTF8.self) } ?? ""
        XCTAssertTrue(text.hasPrefix("POST /v1beta/models/gemini-x:generateContent?pageSize=1&alt=json HTTP/1.1\r\nHost: generativelanguage.googleapis.com\r\n"), text)
        XCTAssertTrue(text.contains("\r\nx-goog-api-key: K\r\n"))
        XCTAssertTrue(text.contains("\r\nContent-Type: application/json\r\n"))
        XCTAssertTrue(text.contains("\r\nAccept-Encoding: identity\r\n"), "sıkıştırılmış cevap istenmez")
        XCTAssertTrue(text.contains("\r\nContent-Length: 12\r\n"))
        XCTAssertTrue(text.hasSuffix("Connection: close\r\n\r\n"))
    }

    func testANonDefaultPortIsInTheHostHeaderAndAGetHasNoLength() {
        let head = HTTPWire.requestHead(method: "GET", url: URL(string: "http://127.0.0.1:8080")!, headers: [:], contentLength: nil)
        let text = head.map { String(decoding: $0, as: UTF8.self) } ?? ""
        XCTAssertTrue(text.hasPrefix("GET / HTTP/1.1\r\nHost: 127.0.0.1:8080\r\n"), text)
        XCTAssertFalse(text.contains("Content-Length"))
    }

    func testHeaderValuesWithLineBreaksAreRefused() {
        let url = URL(string: "https://example.test/")!
        XCTAssertNil(HTTPWire.requestHead(method: "GET", url: url, headers: ["x-goog-api-key": "K\r\nX-Evil: 1"], contentLength: nil))
        XCTAssertNil(HTTPWire.requestHead(method: "GET", url: url, headers: ["Bad\nName": "v"], contentLength: nil))
    }

    func testOnlyTheCameraWiFiSubnetCountsAsTheCameraNetwork() {
        func ip(_ text: String) -> UInt32 { return LocalNetwork.parse(text) ?? 0 }
        XCTAssertTrue(CellularRoute.isCameraNetwork(ip: ip("192.168.100.20")))
        XCTAssertTrue(CellularRoute.isCameraNetwork(ip: ip("192.168.100.254")))
        XCTAssertFalse(CellularRoute.isCameraNetwork(ip: ip("192.168.101.20")))
        XCTAssertFalse(CellularRoute.isCameraNetwork(ip: ip("192.168.1.20")))
        XCTAssertFalse(CellularRoute.isCameraNetwork(ip: ip("10.0.0.5")))
    }
}

// MARK: - Gemini istemcisinin yol seçimi (sahte hücresel gönderici)

private final class SenderLog {
    var calls = 0
    var requests: [URLRequest] = []
    var bodies: [Data?] = []
}

final class GeminiCellularRouteTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FakeGeminiProtocol.reset()
    }

    private func okBody() -> Data {
        let object: [String: Any] = ["candidates": [["finishReason": "STOP", "content": ["parts": [["text": "tamam"]]]]]]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private func makeClient(prefer: Bool, cellular: @escaping GeminiTransport.CellularSender) -> GeminiClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeGeminiProtocol.self]
        return GeminiClient(session: URLSession(configuration: config), baseURL: "https://example.test/v1beta",
                            key: { "AIza-TEST" }, model: { "" }, preferCellular: { prefer }, cellular: cellular, sleep: { _ in })
    }

    private func queue(_ replies: FakeGeminiProtocol.Reply...) {
        FakeGeminiProtocol.lock.lock()
        FakeGeminiProtocol.replies = replies
        FakeGeminiProtocol.lock.unlock()
    }

    func testTheCellularRouteIsUsedFirstAndTheNormalRouteIsNeverTouched() async throws {
        let log = SenderLog()
        let body = okBody()
        let client = makeClient(prefer: true) { request, payload in
            log.calls += 1
            log.requests.append(request)
            log.bodies.append(payload)
            return (body, 200)
        }
        let object = try await client.generate(model: "gemini-x", key: "AIza-TEST", body: Data("{}".utf8))
        XCTAssertNotNil(object as? [String: Any])
        XCTAssertEqual(log.calls, 1)
        XCTAssertEqual(log.requests.first?.url?.absoluteString, "https://example.test/v1beta/models/gemini-x:generateContent")
        XCTAssertEqual(log.requests.first?.value(forHTTPHeaderField: "x-goog-api-key"), "AIza-TEST")
        XCTAssertEqual(log.requests.first?.httpMethod, "POST")
        XCTAssertEqual(log.bodies.first ?? nil, Data("{}".utf8))
        XCTAssertEqual(FakeGeminiProtocol.urls.count, 0, "hücreselden cevap geldi: normal yola istek gitmez")
    }

    func testWhenTheCellularRouteCannotConnectTheNormalRouteTakesOver() async throws {
        let log = SenderLog()
        queue(.init(status: 200, body: okBody(), error: nil))
        let client = makeClient(prefer: true) { _, _ in
            log.calls += 1
            throw CellularUnavailable(reason: "bağlanılamadı (posix 50)")
        }
        let object = try await client.generate(model: "gemini-x", key: "AIza-TEST", body: Data("{}".utf8))
        XCTAssertNotNil(object as? [String: Any])
        XCTAssertEqual(log.calls, 1)
        XCTAssertEqual(FakeGeminiProtocol.urls.count, 1, "hücreselden bağlanılamadı: istek hiç gitmedi, normal yoldan gider")
    }

    func testAFailureAfterTheRequestWentOutOnCellularIsNotSentAgainOverTheNormalRoute() async {
        let log = SenderLog()
        let client = makeClient(prefer: true) { _, _ in
            log.calls += 1
            throw URLError(.timedOut)
        }
        do {
            _ = try await client.generate(model: "gemini-x", key: "AIza-TEST", body: Data("{}".utf8))
            XCTFail("hata beklenirdi")
        } catch let error as GeminiError {
            XCTAssertEqual(error.kind, .network)
        } catch {
            XCTFail("beklenmeyen hata: \(error)")
        }
        XCTAssertEqual(log.calls, 2, "ağ hatasında aynı yoldan bir kez daha denenir")
        XCTAssertEqual(FakeGeminiProtocol.urls.count, 0, "istek gitmiş olabilir: normal yoldan ikinci kez gönderilmez")
    }

    func testServerBusyAnswersOnCellularAreRetriedOnCellular() async throws {
        let log = SenderLog()
        let body = okBody()
        let client = makeClient(prefer: true) { _, _ in
            log.calls += 1
            return log.calls == 1 ? (Data("{}".utf8), 503) : (body, 200)
        }
        let object = try await client.generate(model: "gemini-x", key: "AIza-TEST", body: Data("{}".utf8))
        XCTAssertNotNil(object as? [String: Any])
        XCTAssertEqual(log.calls, 2)
        XCTAssertEqual(FakeGeminiProtocol.urls.count, 0)
    }

    func testWithoutTheCellularRouteTheSenderIsNeverCalled() async throws {
        let log = SenderLog()
        queue(.init(status: 200, body: okBody(), error: nil))
        let client = makeClient(prefer: false) { _, _ in
            log.calls += 1
            return (Data(), 200)
        }
        _ = try await client.generate(model: "gemini-x", key: "AIza-TEST", body: Data("{}".utf8))
        XCTAssertEqual(log.calls, 0)
        XCTAssertEqual(FakeGeminiProtocol.urls.count, 1)
    }

    func testTheModelListAndTheKeyProbeTakeTheSameRoute() async throws {
        let log = SenderLog()
        let list = (try? JSONSerialization.data(withJSONObject: ["models": [["name": "models/gemini-x", "supportedGenerationMethods": ["generateContent"]]]])) ?? Data()
        let client = makeClient(prefer: true) { request, payload in
            log.calls += 1
            log.requests.append(request)
            log.bodies.append(payload)
            return request.httpMethod == "POST" ? (Data("{}".utf8), 200) : (list, 200)
        }
        let names = try await client.listModels()
        XCTAssertEqual(names, ["gemini-x"])
        XCTAssertNotEqual(log.requests.first?.httpMethod, "POST", "model listesi GET'tir")
        XCTAssertNil(log.bodies.first ?? nil, "model listesi isteğinin gövdesi yoktur")
        let probe = await client.probeKey(model: "gemini-x", key: "AIza-TEST", viaQuery: false)
        XCTAssertEqual(probe.status, 200)
        XCTAssertEqual(log.calls, 2)
        XCTAssertEqual(FakeGeminiProtocol.urls.count, 0)
    }

    func testTheBackgroundGraceWrapperPassesResultsAndErrorsThroughWhenSwitchedOff() async {
        let saved = BackgroundGrace.enabled
        BackgroundGrace.enabled = false
        defer { BackgroundGrace.enabled = saved }
        let value = try? await BackgroundGrace.run("deneme") { 41 + 1 }
        XCTAssertEqual(value, 42)
        do {
            _ = try await BackgroundGrace.run("deneme") { () async throws -> Int in throw URLError(.timedOut) }
            XCTFail("hata beklenirdi")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        } catch {
            XCTFail("beklenmeyen hata: \(error)")
        }
    }
}

// MARK: - Gerçek soketle (127.0.0.1) uçtan uca

/// Yerel sahte HTTP sunucusu: istemcinin gerçek bir bağlantıdan konuştuğunu sınar (TLS ve hücresel arayüz hariç)
private final class LoopbackServer {
    private let queue = DispatchQueue(label: "test.loopback.server")
    private var listener: NWListener?
    private let lock = NSLock()
    private var last = Data()
    /// Biriken istek baytlarından cevabı üretir; nil: istek henüz tam değil ya da hiç cevap verilmez
    var respond: (Data) -> Data? = { _ in nil }
    private(set) var port: UInt16 = 0

    var lastRequest: Data {
        lock.lock()
        defer { lock.unlock() }
        return last
    }

    func start() throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        guard let value = listener.port?.rawValue, value != 0 else { throw URLError(.cannotConnectToHost) }
        port = value
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        var received = Data()
        func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
                guard let self = self else { return }
                if let data = data { received.append(data) }
                self.lock.lock()
                self.last = received
                self.lock.unlock()
                if let reply = self.respond(received) {
                    connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
                if isComplete || error != nil {
                    connection.cancel()
                    return
                }
                read()
            }
        }
        read()
    }

    /// Gövdesi tam gelmiş bir isteğin Content-Length'i (tam değilse nil)
    static func completeLength(of request: Data) -> Int? {
        guard let end = request.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: request[..<end.lowerBound], as: UTF8.self)
        var length = 0
        for line in head.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            length = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return request.count - end.upperBound >= length ? length : nil
    }

    static func answer(_ status: String, headers: String = "", body: String = "") -> Data {
        return Data("HTTP/1.1 \(status)\r\n\(headers)\r\n\(body)".utf8)
    }
}

final class CellularHTTPSocketTests: XCTestCase {
    private func options(connect: TimeInterval = 5, idle: TimeInterval = 10, total: TimeInterval = 30) -> CellularHTTP.Options {
        var o = CellularHTTP.Options()
        o.interface = .loopback   // simülatörde hücresel arayüz yoktur; ağ kodu aynıdır
        o.connectTimeout = connect
        o.idleTimeout = idle
        o.totalTimeout = total
        return o
    }

    private func url(_ server: LoopbackServer, _ path: String = "/v1beta/models/x:generateContent?alt=1") -> URL {
        return URL(string: "http://127.0.0.1:\(server.port)\(path)")!
    }

    func testAnUploadInPartsAndAFixedLengthAnswerOverARealSocket() async throws {
        let server = LoopbackServer()
        try server.start()
        defer { server.stop() }
        server.respond = { received in
            guard let length = LoopbackServer.completeLength(of: received) else { return nil }
            let json = "{\"got\":\(length)}"
            return LoopbackServer.answer("200 OK", headers: "Content-Type: application/json\r\nContent-Length: \(json.utf8.count)\r\nConnection: close\r\n", body: json)
        }
        var request = URLRequest(url: url(server))
        request.httpMethod = "POST"
        request.setValue("secret", forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload = Data(repeating: 0x41, count: 600_000)   // 256 KB'lık 3 parça
        let result = try await CellularHTTP.perform(request, body: payload, options: options())
        XCTAssertEqual(result.status, 200)
        XCTAssertEqual(String(decoding: result.data, as: UTF8.self), "{\"got\":600000}", "gövdenin tamamı sunucuya ulaştı")
        let sent = String(decoding: server.lastRequest.prefix(400), as: UTF8.self)
        XCTAssertTrue(sent.hasPrefix("POST /v1beta/models/x:generateContent?alt=1 HTTP/1.1\r\n"), sent)
        XCTAssertTrue(sent.contains("Host: 127.0.0.1:\(server.port)\r\n"), sent)
        XCTAssertTrue(sent.contains("x-goog-api-key: secret\r\n"), sent)
        XCTAssertTrue(sent.contains("Content-Length: 600000\r\n"), sent)
        XCTAssertTrue(sent.contains("Connection: close\r\n"), sent)
    }

    func testAChunkedAnswerOverARealSocket() async throws {
        let server = LoopbackServer()
        try server.start()
        defer { server.stop() }
        server.respond = { received in
            guard LoopbackServer.completeLength(of: received) != nil else { return nil }
            return LoopbackServer.answer("200 OK", headers: "Transfer-Encoding: chunked\r\n", body: "5\r\nhello\r\n6;x=1\r\n world\r\n0\r\n\r\n")
        }
        let result = try await CellularHTTP.perform(URLRequest(url: url(server, "/chunked")), body: nil, options: options())
        XCTAssertEqual(result.status, 200)
        XCTAssertEqual(String(decoding: result.data, as: UTF8.self), "hello world")
    }

    func testAnAnswerThatEndsWhenTheServerClosesOverARealSocket() async throws {
        let server = LoopbackServer()
        try server.start()
        defer { server.stop() }
        server.respond = { received in
            guard LoopbackServer.completeLength(of: received) != nil else { return nil }
            return LoopbackServer.answer("503 Service Unavailable", body: "busy")
        }
        let result = try await CellularHTTP.perform(URLRequest(url: url(server, "/close")), body: nil, options: options())
        XCTAssertEqual(result.status, 503)
        XCTAssertEqual(String(decoding: result.data, as: UTF8.self), "busy")
    }

    func testAnUnreachablePortReportsUnavailableBecauseNothingWasSent() async throws {
        let server = LoopbackServer()
        try server.start()
        let closed = url(server, "/")
        server.stop()
        do {
            _ = try await CellularHTTP.perform(URLRequest(url: closed), body: nil, options: options(connect: 3))
            XCTFail("bağlanılamamalıydı")
        } catch is CellularUnavailable {
            // beklenen: istek hiç gitmedi, çağıran normal yola düşebilir
        } catch {
            XCTFail("CellularUnavailable beklenirdi: \(error)")
        }
    }

    func testASilentServerEndsWithATimeoutInsteadOfHangingForever() async throws {
        let server = LoopbackServer()
        try server.start()
        defer { server.stop() }
        let started = Date()
        do {
            _ = try await CellularHTTP.perform(URLRequest(url: url(server, "/silent")), body: nil, options: options(idle: 1.5))
            XCTFail("süre dolmalıydı")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        } catch {
            XCTFail("URLError beklenirdi: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testCancellingTheTaskStopsTheRequestAtOnce() async throws {
        let server = LoopbackServer()
        try server.start()
        defer { server.stop() }
        let target = url(server, "/slow")
        let opts = options()
        let task = Task { try await CellularHTTP.perform(URLRequest(url: target), body: nil, options: opts) }
        try await Task.sleep(nanoseconds: 500_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("iptal edilmeliydi")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        } catch {
            XCTFail("URLError beklenirdi: \(error)")
        }
    }
}
