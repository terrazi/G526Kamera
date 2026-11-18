import Foundation
import Network

/// Hücresel yol anahtarı. Telefon kameranın (internetsiz) Wi-Fi ağındayken iOS isteği o ağa gönderir ve istek ulaşmaz (günlükte hata -1004).
/// Bu durumda Gemini ve internet yoklaması doğrudan hücresel arayüzden gönderilir; telefonun Wi-Fi'yi bırakması gerekmez.
enum CellularRoute {
    private static let lock = NSLock()
    private static var flag = false

    /// Toplu çekim kipi açık mı (AppEnvironment ayara bağlar). Kapalıyken hiçbir istek hücresel yola yönlendirilmez.
    static var enabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return flag
        }
        set {
            lock.lock()
            flag = newValue
            lock.unlock()
        }
    }

    /// Kameranın Wi-Fi ağı: 192.168.100.0/24
    static func isCameraNetwork(ip: UInt32) -> Bool {
        return (ip & 0xFFFF_FF00) == 0xC0A8_6400
    }

    /// İstek şimdi hücresel yoldan denensin mi: kip açık VE telefonun Wi-Fi adresi kameranın ağında.
    /// Başka bir Wi-Fi'de (internetli) ya da Wi-Fi kapalıyken normal yol kullanılır; mobil veri boşuna harcanmaz.
    static func shouldUse() -> Bool {
        guard enabled, let wifi = LocalNetwork.wifi() else { return false }
        return isCameraNetwork(ip: wifi.ip)
    }
}

/// Hücresel arayüze bağlanılamadı (arayüz kapalı, uçak modu, bağlanma süresi doldu): istek hiç gönderilmedi, normal yola düşülebilir
struct CellularUnavailable: Error, CustomStringConvertible {
    let reason: String
    var description: String { return reason }
}

// MARK: - HTTP/1.1 baytları (ağdan bağımsız, sınanabilir)

enum HTTPWire {
    struct Response: Equatable {
        var status: Int
        var headers: [String: String]
        var body: Data
    }

    /// İstek başı (gövde hariç). Başlık adında ya da değerinde satır sonu varsa nil (başlık enjeksiyonu).
    /// Sıkıştırma istenmez ("identity"): cevap olduğu gibi okunur. Bağlantı cevaptan sonra kapanır.
    static func requestHead(method: String, url: URL, headers: [String: String], contentLength: Int?) -> Data? {
        guard let host = url.host, !host.isEmpty,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var target = parts.percentEncodedPath
        if target.isEmpty { target = "/" }
        if let query = parts.percentEncodedQuery, !query.isEmpty { target += "?" + query }
        let defaultPort = url.scheme?.lowercased() == "http" ? 80 : 443
        var hostHeader = host.contains(":") ? "[\(host)]" : host
        if let port = url.port, port != defaultPort { hostHeader += ":\(port)" }

        var lines = ["\(method) \(target) HTTP/1.1", "Host: \(hostHeader)"]
        let own: Set<String> = ["host", "content-length", "connection"]
        var hasEncoding = false
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            let lower = name.lowercased()
            if own.contains(lower) { continue }
            // "\r\n" Swift'te TEK bir Character'dır; satır sonu denetimi bu yüzden karakterle değil Unicode skaleriyle yapılır
            if name.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == ":" }) ||
                value.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" }) {
                return nil
            }
            if lower == "accept-encoding" { hasEncoding = true }
            lines.append("\(name): \(value)")
        }
        if !hasEncoding { lines.append("Accept-Encoding: identity") }
        if let length = contentLength { lines.append("Content-Length: \(length)") }
        lines.append("Connection: close")
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    /// Cevabı parça parça okur: Content-Length, "chunked" ve bağlantı kapanana kadar gelen gövdeleri çözer; "100 Continue" gibi ara cevapları atlar.
    final class ResponseParser {
        enum Step: Equatable {
            case more
            case done(Response)
            case failed(String)
        }

        private enum Phase {
            case head
            case fixed(Int)
            case chunkSize
            case chunkData(Int)
            case trailers
            case untilClose
            case finished
        }

        static let maxHead = 64 * 1024

        private var buffer = [UInt8]()
        private var pos = 0
        private var phase = Phase.head
        private var status = 0
        private var headers: [String: String] = [:]
        private var body = [UInt8]()
        private var outcome: Step?

        /// Ağdan gelen yeni baytlar
        func feed(_ data: Data) -> Step {
            if let done = outcome { return done }
            buffer.append(contentsOf: data)
            return advance()
        }

        /// Sunucu bağlantıyı kapattı
        func end() -> Step {
            if let done = outcome { return done }
            switch phase {
            case .untilClose:
                body.append(contentsOf: buffer[pos...])
                pos = buffer.count
                return finish()
            case .head:
                return fail(buffer.count - pos == 0 ? "sunucu cevap vermeden bağlantıyı kapattı" : "cevap başı yarım kaldı")
            default:
                return fail("cevap yarım kaldı")
            }
        }

        private func advance() -> Step {
            while true {
                switch phase {
                case .head:
                    guard let headEnd = find([13, 10, 13, 10], from: pos) else {
                        if buffer.count - pos > ResponseParser.maxHead { return fail("cevap başı çok büyük") }
                        return .more
                    }
                    let headBytes = Array(buffer[pos..<headEnd])
                    pos = headEnd + 4
                    guard let head = ResponseParser.parseHead(headBytes) else { return fail("cevap başı anlaşılamadı") }
                    if head.status >= 100 && head.status < 200 { continue }   // ara cevap: asıl cevap arkasından gelir
                    status = head.status
                    headers = head.headers
                    if let encoding = headers["content-encoding"]?.lowercased(), !encoding.isEmpty, encoding != "identity" {
                        return fail("cevap sıkıştırılmış (\(encoding))")
                    }
                    if status == 204 || status == 304 { return finish() }
                    if let transfer = headers["transfer-encoding"]?.lowercased(), transfer.contains("chunked") {
                        phase = .chunkSize
                    } else if let text = headers["content-length"], let length = Int(text.trimmingCharacters(in: .whitespaces)), length >= 0 {
                        if length == 0 { return finish() }
                        phase = .fixed(length)
                    } else {
                        phase = .untilClose
                    }
                case .fixed(let length):
                    guard buffer.count - pos >= length else { return .more }
                    body = Array(buffer[pos..<(pos + length)])
                    pos += length
                    return finish()
                case .chunkSize:
                    guard let lineEnd = find([13, 10], from: pos) else {
                        if buffer.count - pos > 1024 { return fail("bölüm başı anlaşılamadı") }
                        return .more
                    }
                    let line = String(decoding: buffer[pos..<lineEnd], as: UTF8.self)
                    let hex = (line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "")
                        .trimmingCharacters(in: .whitespaces)
                    guard let size = Int(hex, radix: 16), size >= 0 else { return fail("bölüm uzunluğu anlaşılamadı") }
                    pos = lineEnd + 2
                    phase = size == 0 ? .trailers : .chunkData(size)
                case .chunkData(let size):
                    guard buffer.count - pos >= size + 2 else { return .more }
                    guard buffer[pos + size] == 13, buffer[pos + size + 1] == 10 else { return fail("bölüm sonu anlaşılamadı") }
                    body.append(contentsOf: buffer[pos..<(pos + size)])
                    pos += size + 2
                    phase = .chunkSize
                    compact()
                case .trailers:
                    guard let lineEnd = find([13, 10], from: pos) else { return .more }
                    if lineEnd == pos {
                        pos += 2
                        return finish()
                    }
                    pos = lineEnd + 2
                case .untilClose:
                    body.append(contentsOf: buffer[pos...])
                    pos = buffer.count
                    compact()
                    return .more
                case .finished:
                    return outcome ?? .more
                }
            }
        }

        /// Okunmuş baytlar tampondan atılır (uzun cevaplarda bellek şişmesin)
        private func compact() {
            if pos > 0 && (pos == buffer.count || pos > 1_000_000) {
                buffer.removeFirst(pos)
                pos = 0
            }
        }

        private func find(_ pattern: [UInt8], from start: Int) -> Int? {
            let count = buffer.count
            let length = pattern.count
            if count - start < length { return nil }
            var i = start
            while i <= count - length {
                if buffer[i] == pattern[0] {
                    var j = 1
                    while j < length && buffer[i + j] == pattern[j] { j += 1 }
                    if j == length { return i }
                }
                i += 1
            }
            return nil
        }

        private func finish() -> Step {
            let result = Step.done(Response(status: status, headers: headers, body: Data(body)))
            phase = .finished
            outcome = result
            return result
        }

        private func fail(_ message: String) -> Step {
            let result = Step.failed(message)
            phase = .finished
            outcome = result
            return result
        }

        static func parseHead(_ bytes: [UInt8]) -> (status: Int, headers: [String: String])? {
            let lines = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\r\n")
            guard let first = lines.first else { return nil }
            let parts = first.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let status = Int(parts[1]) else { return nil }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if name.isEmpty { continue }
                if let old = headers[name] {
                    headers[name] = old + ", " + value
                } else {
                    headers[name] = value
                }
            }
            return (status, headers)
        }
    }
}

// MARK: - Bağlantı

/// Tek bir HTTP isteği/cevabı. Bütün durum tek bir sırada (`queue`) işlenir; devam (continuation) tam bir kez sürdürülür.
final class HTTPExchange {
    struct Plan {
        var host: String
        var port: UInt16
        var useTLS: Bool
        var interface: NWInterface.InterfaceType?
        var head: Data
        var body: Data?
        var connectTimeout: TimeInterval
        var idleTimeout: TimeInterval
        var totalTimeout: TimeInterval
    }

    /// Gövde bu boyutta parçalarla gönderilir: yavaş hücreselde ilerleme görülür (boşta süresi her parçada yenilenir), bellek şişmez
    static let chunkSize = 256 * 1024

    private let plan: Plan
    private let queue = DispatchQueue(label: "g526.http.exchange")
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<HTTPWire.Response, Error>?
    private let parser = HTTPWire.ResponseParser()
    private var timer: DispatchSourceTimer?
    private var started = Date()
    private var lastProgress = Date()
    private var ready = false
    private var finished = false
    private var cancelledEarly = false
    private var waitingReason = ""
    private var headSent = false
    private var bodyOffset = 0

    init(plan: Plan) {
        self.plan = plan
    }

    func start(_ continuation: CheckedContinuation<HTTPWire.Response, Error>) {
        queue.async {
            self.continuation = continuation
            if self.cancelledEarly {
                self.finish(.failure(URLError(.cancelled)))
            } else {
                self.open()
            }
        }
    }

    func cancel() {
        queue.async {
            if self.continuation == nil {
                self.cancelledEarly = true
            } else {
                self.finish(.failure(URLError(.cancelled)))
            }
        }
    }

    /// Ağ hatasının kısa adı (günlük için): "posix 50", "dns -65554", "tls -9806"
    static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code): return "posix \(code.rawValue)"
        case .dns(let code): return "dns \(code)"
        case .tls(let status): return "tls \(status)"
        @unknown default: return "\(error)"
        }
    }

    // MARK: Kurulum

    private func open() {
        guard let port = NWEndpoint.Port(rawValue: plan.port) else {
            finish(.failure(CellularUnavailable(reason: "kapı numarası geçersiz")))
            return
        }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = max(1, Int(plan.connectTimeout.rounded(.up)))
        tcp.enableKeepalive = true
        let parameters = NWParameters(tls: plan.useTLS ? NWProtocolTLS.Options() : nil, tcp: tcp)
        if let type = plan.interface { parameters.requiredInterfaceType = type }
        parameters.prohibitExpensivePaths = false      // hücresel "pahalı" yoldur; yasaklanmaz
        parameters.prohibitConstrainedPaths = false    // Düşük Veri Modu bu yüklemeyi engellemesin
        let connection = NWConnection(host: NWEndpoint.Host(plan.host), port: port, using: parameters)
        self.connection = connection
        started = Date()
        lastProgress = started
        connection.stateUpdateHandler = { [weak self] state in
            self?.queue.async { self?.onState(state) }
        }
        connection.start(queue: queue)
        startTimer()
    }

    private func startTimer() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 0.5, repeating: 0.5)
        source.setEventHandler { [weak self] in self?.tick() }
        timer = source
        source.resume()
    }

    private func onState(_ state: NWConnection.State) {
        guard !finished else { return }
        switch state {
        case .ready:
            ready = true
            lastProgress = Date()
            sendNext()
            receiveNext()
        case .waiting(let error):
            // Arayüz yok / henüz hazır değil (örn. uçak modundan yeni çıkıldı): sistem yol gelince kendiliğinden yeniden dener; süre `tick` ile sınırlanır
            waitingReason = HTTPExchange.describe(error)
        case .failed(let error):
            if ready {
                finish(.failure(URLError(.networkConnectionLost, userInfo: [NSLocalizedDescriptionKey: HTTPExchange.describe(error)])))
            } else {
                finish(.failure(CellularUnavailable(reason: "bağlanılamadı (\(HTTPExchange.describe(error)))")))
            }
        case .cancelled:
            finish(.failure(URLError(.cancelled)))
        default:
            break
        }
    }

    private func tick() {
        guard !finished else { return }
        let now = Date()
        if !ready {
            if now.timeIntervalSince(started) >= plan.connectTimeout {
                let why = waitingReason.isEmpty ? "\(Int(plan.connectTimeout)) sn içinde bağlanılamadı" : "bağlanılamadı (\(waitingReason))"
                finish(.failure(CellularUnavailable(reason: why)))
            }
            return
        }
        if now.timeIntervalSince(started) >= plan.totalTimeout || now.timeIntervalSince(lastProgress) >= plan.idleTimeout {
            finish(.failure(URLError(.timedOut)))
        }
    }

    // MARK: Gönderme ve okuma

    /// Önce istek başı, sonra gövde 256 KB'lık parçalarla; her parça işlenince bir sonrakine geçilir
    private func sendNext() {
        guard !finished, let connection = connection else { return }
        let piece: Data
        if !headSent {
            piece = plan.head
        } else if let body = plan.body, bodyOffset < body.count {
            let end = min(bodyOffset + HTTPExchange.chunkSize, body.count)
            piece = Data(body[bodyOffset..<end])
        } else {
            return
        }
        connection.send(content: piece, completion: .contentProcessed { [weak self] error in
            self?.queue.async {
                guard let self = self, !self.finished else { return }
                if let error = error {
                    self.finish(.failure(URLError(.networkConnectionLost, userInfo: [NSLocalizedDescriptionKey: HTTPExchange.describe(error)])))
                    return
                }
                self.lastProgress = Date()
                if self.headSent {
                    self.bodyOffset += piece.count
                } else {
                    self.headSent = true
                }
                self.sendNext()
            }
        })
    }

    private func receiveNext() {
        guard !finished, let connection = connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { [weak self] data, _, isComplete, error in
            self?.queue.async {
                guard let self = self, !self.finished else { return }
                if let data = data, !data.isEmpty {
                    self.lastProgress = Date()
                    switch self.parser.feed(data) {
                    case .done(let response):
                        self.finish(.success(response))
                        return
                    case .failed(let message):
                        self.finish(.failure(URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: message])))
                        return
                    case .more:
                        break
                    }
                }
                if let error = error {
                    self.finish(.failure(URLError(.networkConnectionLost, userInfo: [NSLocalizedDescriptionKey: HTTPExchange.describe(error)])))
                    return
                }
                if isComplete {
                    switch self.parser.end() {
                    case .done(let response):
                        self.finish(.success(response))
                    case .failed(let message):
                        self.finish(.failure(URLError(.networkConnectionLost, userInfo: [NSLocalizedDescriptionKey: message])))
                    case .more:
                        self.finish(.failure(URLError(.networkConnectionLost)))
                    }
                    return
                }
                self.receiveNext()
            }
        }
    }

    private func finish(_ result: Result<HTTPWire.Response, Error>) {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        timer = nil
        if let connection = connection {
            connection.stateUpdateHandler = nil
            connection.cancel()
            self.connection = nil
        }
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}

/// Hücresel arayüzden (Wi-Fi bağlı olsa da) HTTPS isteği. `URLSession` arayüz seçtirmez; Apple'ın önerdiği yol Network framework'ün
/// `requiredInterfaceType` ayarıdır (internetsiz bir cihazın Wi-Fi'sindeyken hücreseli kullanmak için).
enum CellularHTTP {
    struct Options {
        /// Zorunlu arayüz (gerçekte `.cellular`; yerel sınamada `.loopback`)
        var interface: NWInterface.InterfaceType? = .cellular
        /// Bağlanma (hücresel arayüz açılsın, TLS kurulsun) için en çok bekleme; dolarsa `CellularUnavailable`
        var connectTimeout: TimeInterval = 20
        /// Hiçbir ilerleme (gönderme ya da okuma) olmadan en çok bekleme
        var idleTimeout: TimeInterval = 120
        /// Bütün istek için üst sınır
        var totalTimeout: TimeInterval = 600
    }

    /// İsteği gönderir. Bağlanılamazsa `CellularUnavailable` (istek hiç gitmedi); sonrasında `URLError` (-1001 süre doldu, -1005 bağlantı koptu…).
    static func perform(_ request: URLRequest, body: Data?, options: Options = Options()) async throws -> (data: Data, status: Int) {
        let response = try await performFull(request, body: body, options: options)
        return (response.body, response.status)
    }

    /// `perform` gibi, ama cevabın başlıklarını da verir (adlar küçük harf): dosya yüklemede yükleme adresi başlıkta gelir
    static func performFull(_ request: URLRequest, body: Data?, options: Options = Options()) async throws -> HTTPWire.Response {
        guard let url = request.url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { throw URLError(.badURL) }
        let useTLS = scheme == "https"
        let portNumber = url.port ?? (useTLS ? 443 : 80)
        guard (1...65535).contains(portNumber) else { throw URLError(.badURL) }
        let method = request.httpMethod ?? (body == nil ? "GET" : "POST")
        let length: Int? = body.map { $0.count } ?? (method == "POST" || method == "PUT" ? 0 : nil)
        guard let head = HTTPWire.requestHead(method: method, url: url, headers: request.allHTTPHeaderFields ?? [:], contentLength: length) else {
            throw URLError(.badURL)
        }
        let plan = HTTPExchange.Plan(host: host, port: UInt16(portNumber), useTLS: useTLS, interface: options.interface, head: head, body: body,
                                     connectTimeout: options.connectTimeout, idleTimeout: options.idleTimeout, totalTimeout: options.totalTimeout)
        let exchange = HTTPExchange(plan: plan)
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPWire.Response, Error>) in
                exchange.start(continuation)
            }
        } onCancel: {
            exchange.cancel()
        }
        return response
    }
}

/// Bir isteğin yolu: hücresel yol açıksa önce oradan; hücreselden bağlanılamazsa normal yoldan. Hücresel yoldan istek gittikten sonraki
/// hatalar (süre doldu, bağlantı koptu) normal yola düşmez: aynı istek iki kez gitmesin.
enum GeminiTransport {
    typealias CellularSender = (URLRequest, Data?) async throws -> (data: Data, status: Int)

    static let realCellular: CellularSender = { request, body in
        return try await CellularHTTP.perform(request, body: body)
    }

    /// Dönen durum 0 ise cevap HTTP değil
    static func send(_ request: URLRequest, body: Data?, session: URLSession, viaCellular: Bool,
                     cellular: CellularSender = GeminiTransport.realCellular) async throws -> (data: Data, status: Int) {
        let host = request.url?.host ?? "?"
        if viaCellular {
            do {
                let result = try await cellular(request, body)
                tlog("[ağ] \(host): hücresel yoldan gitti, HTTP \(result.status)")
                return result
            } catch let unavailable as CellularUnavailable {
                tlog("[ağ] \(host): hücresel yol açılamadı (\(unavailable.reason)); normal yoldan deneniyor")
            }
        }
        let pair: (Data, URLResponse)
        if let body = body {
            pair = try await session.upload(for: request, from: body)
        } else {
            pair = try await session.data(for: request)
        }
        return (pair.0, (pair.1 as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// `send` gibi, ama cevabın başlıklarını da verir (adlar küçük harf). Dosya yükleme (Gemini Files API) için: yükleme adresi başlıkta gelir
    static func sendFull(_ request: URLRequest, body: Data?, session: URLSession, viaCellular: Bool) async throws -> (data: Data, status: Int, headers: [String: String]) {
        let host = request.url?.host ?? "?"
        if viaCellular {
            do {
                let response = try await CellularHTTP.performFull(request, body: body)
                tlog("[ağ] \(host): hücresel yoldan gitti, HTTP \(response.status)")
                return (response.body, response.status, response.headers)
            } catch let unavailable as CellularUnavailable {
                tlog("[ağ] \(host): hücresel yol açılamadı (\(unavailable.reason)); normal yoldan deneniyor")
            }
        }
        let pair: (Data, URLResponse)
        if let body = body {
            pair = try await session.upload(for: request, from: body)
        } else {
            pair = try await session.data(for: request)
        }
        let http = pair.1 as? HTTPURLResponse
        var headers: [String: String] = [:]
        if let fields = http?.allHeaderFields {
            for (name, value) in fields {
                if let name = name as? String, let value = value as? String { headers[name.lowercased()] = value }
            }
        }
        return (pair.0, http?.statusCode ?? 0, headers)
    }
}
