import Foundation

/// Gemini API ayarları ve sabitleri
enum GeminiConfig {
    static let baseURL = "https://generativelanguage.googleapis.com/v1beta"
    static let defaultModel = "gemini-3.6-flash"
}

enum GeminiErrorKind: String {
    case key, quota, cap, model, network, blocked, empty, tooBig, http, error
}

struct GeminiError: LocalizedError {
    let kind: GeminiErrorKind
    let message: String
    let status: Int
    /// Cevap beklerken zaman aşımı (bağlantı kuruldu, yanıt gelmedi): sıradaki modele geçmek için
    var timedOut = false

    init(_ message: String, _ kind: GeminiErrorKind = .error, status: Int = 0) {
        self.message = message
        self.kind = kind
        self.status = status
    }

    var errorDescription: String? { return message }
}

/// Gemini Files API'ye yüklenmiş dosya: isteklerde adresiyle (`uri`) anılır; 48 saat saklanır
struct GeminiUploadedFile: Equatable {
    var uri: String
    /// "files/abc123": durumu sorgulamak için
    var name: String
    /// "ACTIVE", "PROCESSING", "FAILED"; cevapta yoksa "ACTIVE" sayılır
    var state: String
}

/// Yardımcı işlevler: hata çevirisi, şık kodları, düşünme ayarı, model listesi
enum GeminiSupport {
    /// Kota hatası ücretsiz katmandan geldi: anahtarın projesinde faturalandırma açık değil
    static let freeTierHint = "Google bu anahtarı ücretsiz katmanda sayıyor: anahtarın projesinde faturalandırma açık değil, ücretli modeller bu anahtarla çalışmaz."

    /// Dosya yükleme cevabından (`{"file": {...}}`) ya da durum sorgusundan (`{...}`) dosya bilgisi; adres yoksa nil
    static func parseUploadedFile(_ data: Data) -> GeminiUploadedFile? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let file = (json["file"] as? [String: Any]) ?? json
        guard let uri = (file["uri"] as? String)?.trimmed, !uri.isEmpty else { return nil }
        let state = ((file["state"] as? String) ?? "ACTIVE").uppercased()
        return GeminiUploadedFile(uri: uri, name: (file["name"] as? String) ?? "", state: state)
    }

    /// Yükleme adresi: "https://…/v1beta" → "https://…/upload/v1beta/files"
    static func uploadURL(base: String) -> String {
        let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        if let range = trimmedBase.range(of: "/", options: .backwards), !trimmedBase[range.upperBound...].isEmpty,
           trimmedBase[range.upperBound...].hasPrefix("v") {
            return String(trimmedBase[..<range.lowerBound]) + "/upload/" + String(trimmedBase[range.upperBound...]) + "/files"
        }
        return trimmedBase + "/upload/v1beta/files"
    }

    // MARK: Hata çevirisi

    /// Hata yanıtının gövdesinden hata nesnesi. JSON değilse (aradaki proxy / güvenlik duvarı HTML sayfası döndürmüş olabilir)
    /// etiketleri atılmış kısa metin "message" olarak konur; böylece nedeni görülebilir.
    static func errorObject(from data: Data) -> [String: Any] {
        if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], !obj.isEmpty { return obj }
        var text = String(decoding: data, as: UTF8.self)
        if let regex = try? NSRegularExpression(pattern: "<[^>]*>") {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        }
        let flat = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if flat.isEmpty { return [:] }
        return ["error": ["message": String(flat.prefix(200))]]
    }

    /// 429 (kota / hız sınırı) için hangi sınırın aşıldığını ve ne yapılacağını söyleyen mesaj.
    /// Google'ın ayrıntıları: details[].violations[].quotaId / quotaMetric ve "Please retry in 12s".
    static func quotaMessage(message: String, details: [[String: Any]]?) -> String {
        var ids: [String] = []
        for d in details ?? [] {
            if let violations = d["violations"] as? [[String: Any]] {
                for v in violations {
                    let quotaId = (v["quotaId"] as? String) ?? ""
                    let quotaMetric = (v["quotaMetric"] as? String) ?? ""
                    ids.append(quotaId + " " + quotaMetric)
                }
            }
        }
        let blob = (ids.joined(separator: " ") + " " + message).lowercased()
            .replacingOccurrences(of: "_", with: "").replacingOccurrences(of: " ", with: "")
        var wait = 0
        if let regex = try? NSRegularExpression(pattern: "retry in ([0-9.]+)s", options: [.caseInsensitive]),
           let m = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
           m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: message), let seconds = Double(message[r]) {
            wait = Int(seconds + 1)
        }
        var limit = ""
        if let regex = try? NSRegularExpression(pattern: "limit: ?(\\d+)", options: [.caseInsensitive]),
           let m = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
           m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: message) {
            limit = " (sınır: \(message[r]))"
        }
        let waitSeconds = wait > 0 ? wait : 60
        var text: String
        if blob.contains("perday") {
            text = "Bu modelin günlük kotası doldu\(limit). Günlük kota her gün Pasifik saatiyle gece yarısı (Türkiye'de yaklaşık 10:00-11:00) sıfırlanır. Başka bir model seçebilir ya da faturalandırmalı anahtar kullanabilirsiniz."
        } else if blob.contains("token") && blob.contains("perminute") {
            text = "Dakikalık token sınırı aşıldı\(limit): gönderilen belgeler çok yer tutuyor. Yaklaşık \(waitSeconds) saniye bekleyin ya da belge sayısını azaltın."
        } else if blob.contains("perminute") {
            text = "Dakikalık istek sınırı aşıldı\(limit). Yaklaşık \(waitSeconds) saniye bekleyip yeniden deneyin."
        } else {
            let waitText = wait > 0 ? " Yaklaşık \(wait) saniye sonra yeniden deneyin." : ""
            text = "Kota ya da hız sınırı aşıldı\(limit)." + waitText + " Ücretsiz katmanda sınırlar düşüktür."
        }
        // Google kotayı ücretsiz katmandan sayıyorsa (ölçü adında "free_tier") anahtar faturalandırmaya bağlı değildir: "ücretli" yuvaya yazılmış olsa da
        // ücretli modeller cevap vermez (günlükte: gemini-4-argon sınır 0, Flash modelleri günde 20 istek). Kullanıcıya açıkça söylenir.
        if blob.contains("freetier") {
            text += " " + GeminiSupport.freeTierHint
        }
        if let regex = try? NSRegularExpression(pattern: "Quota exceeded for metric:[^\\n]*"),
           let m = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
           let r = Range(m.range, in: message) {
            text += " (Google: \(String(String(message[r]).trimmed.prefix(160))))"
        }
        return text
    }

    static func describeError(status: Int, json: [String: Any], model: String) -> (GeminiErrorKind, String) {
        var message = ""
        var reason = ""
        if let err = json["error"] as? [String: Any] {
            message = (err["message"] as? String) ?? ""
            if let details = err["details"] as? [[String: Any]] {
                for d in details {
                    if let r = d["reason"] as? String, !r.isEmpty { reason = r }
                }
            }
        }
        let low = (message + " " + reason).lowercased()
        if low.contains("api key not valid") || low.contains("api_key_invalid") || low.contains("api key expired") {
            return (.key, "API anahtarı geçersiz ya da süresi dolmuş. AI Studio'dan aldığınız anahtarı yeniden yapıştırın.")
        }
        if low.contains("location is not supported") {
            return (.key, "Gemini API bulunduğunuz bölgede kullanılamıyor: " + message)
        }
        if status == 401 || status == 403 {
            return (.key, "Gemini anahtarınıza izin vermiyor (\(status)): " + (message.isEmpty ? "yetki yok" : message))
        }
        if status == 404 {
            return (.model, "Model bulunamadı (\(model.isEmpty ? "?" : model)). Ayarlardan modeli değiştirin.")
        }
        if status == 413 {
            return (.tooBig, "İstek çok büyük. Daha az ya da daha küçük belge seçin.")
        }
        if status == 429 && low.contains("spending cap") {
            return (.cap, "Aylık harcama sınırınız doldu. AI Studio'da Spend sayfasından sınırı yükseltin ya da ayın birinde sıfırlanmasını bekleyin.")
        }
        if status == 429 {
            let details = (json["error"] as? [String: Any])?["details"] as? [[String: Any]]
            return (.quota, quotaMessage(message: message, details: details))
        }
        if status == 400 {
            return (.http, "Gemini isteği kabul etmedi (400): " + (message.isEmpty ? "bilinmeyen neden" : message))
        }
        if status >= 500 {
            let detail = message.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let shown = detail.isEmpty ? "" : " Sunucunun mesajı: \(String(detail.prefix(200)))."
            return (.http, "Gemini şu an yanıt vermiyor (\(status)).\(shown) Biraz sonra yeniden deneyin.")
        }
        return (.http, "Gemini hatası (\(status)): " + String(message.prefix(200)))
    }

    /// İsteğe konacak thinkingLevel ya da nil. "auto": Gemma modellerinde "high" (Gemma düşünmeyi yalnız bu ayarla açar; ALES/YDS gibi
    /// soru çözümünde doğruluk için gerekir), Gemini modellerinde modelin kendi varsayılanı. Gemini 2.x thinkingLevel tanımaz
    /// (thinkingBudget kullanır) → ona hiç gönderilmez.
    static func thinkingLevel(model: String, setting: String) -> String? {
        let name = model.lowercased()
        if setting != "high" && setting != "minimal" {
            return name.contains("gemma") ? "high" : nil
        }
        if name.hasPrefix("gemini-2") || name.hasPrefix("models/gemini-2") { return nil }
        return setting
    }

    /// generationConfig'e thinkingConfig ekler (level nil ise dokunmaz)
    static func applyThinking(_ body: [String: Any], level: String?) -> [String: Any] {
        guard let level = level else { return body }
        var out = body
        var config = (out["generationConfig"] as? [String: Any]) ?? [:]
        config["thinkingConfig"] = ["thinkingLevel": level]
        out["generationConfig"] = config
        return out
    }

    /// /models cevabından generateContent destekleyen modellerin kısa adları ("models/" öneki atılır), sıralı
    static func parseModelList(_ json: [String: Any]) -> [String] {
        let models = (json["models"] as? [[String: Any]]) ?? []
        var names: [String] = []
        for m in models {
            let methods = (m["supportedGenerationMethods"] as? [String]) ?? []
            guard methods.contains("generateContent"), let name = m["name"] as? String else { continue }
            let short = name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
            if !short.isEmpty && !names.contains(short) { names.append(short) }
        }
        return names.sorted()
    }
}

/// Gemini'ye istek atan istemci: generateContent (yeniden denemeli), model listesi, anahtar sınaması
final class GeminiClient {
    private let session: URLSession
    /// Uzun süre verilen istekler için oturum: ağ katmanının "veri gelmeden bekleme" sınırı bu isteklerde erken işlemez (bkz. `idleAllowance`).
    /// İlk gerektiğinde kurulur (her istemci için boşuna ikinci oturum açılmasın); testlerde verilen oturum kullanılır
    private let givenSession: URLSession?
    private lazy var patientSession: URLSession = givenSession ?? GeminiClient.makeSession(requestTimeout: GeminiClient.patientIdle)
    /// Ağ katmanının olağan "veri gelmeden bekleme" sınırı (sn)
    static let usualIdle: TimeInterval = 120
    /// Uzun süre verilen isteklerin oturumunda veri gelmeden bekleme sınırı (sn); asıl süreyi istemcinin kendi sınırı (`timeout`) belirler
    static let patientIdle: TimeInterval = 900

    /// `timeout` kadar süre verilen istekte ağ katmanının veri gelmeden bekleme sınırı. Günlük 26.11.2026: yüksek düşünme düzeyiyle model 120 saniye
    /// hiç veri göndermedi; ağ katmanı isteği "-1001" ile kesti, hata "internete ulaşılamadı" sayıldı, sıradaki modele geçilmedi ve 240 saniyelik
    /// süre hiç işlemedi. İstemcinin kendi süresi her zaman önce dolmalı: o zaman hata "süresinde cevap vermedi" olur ve sıradaki model denenir.
    static func idleAllowance(for timeout: TimeInterval?) -> TimeInterval? {
        guard let limit = timeout, limit > 0 else { return nil }
        return max(usualIdle, limit + 15)
    }
    /// Kaynak deposu istekleri (`GeminiSources.swift`) de bu adresi, `sleep`'i ve aşağıdaki `transport` yollarını kullanır
    let baseURL: String
    private let keyProvider: () -> String
    private let modelProvider: () -> String
    let sleep: (TimeInterval) async -> Void
    /// Telefon kameranın (internetsiz) Wi-Fi ağındayken istekler önce hücresel arayüzden denenir (bkz. `CellularRoute`)
    private let preferCellular: () -> Bool
    private let cellular: GeminiTransport.CellularSender

    static func makeSession(requestTimeout: TimeInterval = GeminiClient.usualIdle) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.waitsForConnectivity = false
        c.timeoutIntervalForRequest = requestTimeout
        c.timeoutIntervalForResource = max(600, requestTimeout + 120)
        return URLSession(configuration: c)
    }

    init(session: URLSession? = nil,
         baseURL: String = GeminiConfig.baseURL,
         key: @escaping () -> String,
         model: @escaping () -> String,
         preferCellular: @escaping () -> Bool = { CellularRoute.shouldUse() },
         cellular: @escaping GeminiTransport.CellularSender = GeminiTransport.realCellular,
         sleep: @escaping (TimeInterval) async -> Void = { seconds in
             try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
         }) {
        self.session = session ?? GeminiClient.makeSession()
        self.givenSession = session
        self.baseURL = baseURL
        self.keyProvider = key
        self.modelProvider = model
        self.preferCellular = preferCellular
        self.cellular = cellular
        self.sleep = sleep
    }

    /// İsteği yolundan gönderir: telefon kamera ağındaysa önce hücresel, olmazsa (ya da hücreselden bağlanılamazsa) normal yoldan.
    /// Dönen durum 0 ise cevap HTTP değildir.
    func transport(_ request: URLRequest, body: Data?) async throws -> (data: Data, status: Int) {
        let viaCellular = preferCellular()
        // İsteğe olağandan uzun süre verildiyse (bkz. `idleAllowance`) sabırlı oturum kullanılır; hücresel yol süreyi isteğin kendisinden okur
        let chosen = request.timeoutInterval > GeminiClient.usualIdle ? patientSession : session
        return try await BackgroundGrace.run("gemini") {
            try await GeminiTransport.send(request, body: body, session: chosen, viaCellular: viaCellular, cellular: self.cellular)
        }
    }

    var model: String {
        let m = modelProvider().trimmed
        return m.isEmpty ? GeminiConfig.defaultModel : m
    }

    /// `transport` gibi, cevap başlıklarıyla (dosya yükleme için)
    func transportFull(_ request: URLRequest, body: Data?) async throws -> (data: Data, status: Int, headers: [String: String]) {
        let viaCellular = preferCellular()
        return try await BackgroundGrace.run("gemini") {
            try await GeminiTransport.sendFull(request, body: body, session: self.session, viaCellular: viaCellular)
        }
    }

    // MARK: Dosya yükleme (Files API)

    /// Büyük dosyayı (PDF) Gemini'ye bir kez yükler; sonraki isteklerde yalnız adresi gider (Google'ın belgelediği iki adımlı "resumable" yükleme:
    /// önce yükleme adresi istenir, sonra baytlar gönderilir). `limit` sn içinde bitmezse `timedOut` işaretli hata verir. Cihazda doğrulanmadı.
    func uploadFile(_ data: Data, mimeType: String, displayName: String, key: String, timeout limit: TimeInterval) async throws -> GeminiUploadedFile {
        let reply: Reply = try await withThrowingTaskGroup(of: Reply.self) { group in
            group.addTask {
                return Reply(value: try await self.uploadSteps(data, mimeType: mimeType, displayName: displayName, key: key))
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                return Reply(value: nil)
            }
            let first = try await group.next() ?? Reply(value: nil)
            group.cancelAll()
            return first
        }
        guard let file = reply.value as? GeminiUploadedFile else {
            var e = GeminiError("Dosya \(Int(limit)) sn içinde yüklenemedi.", .network)
            e.timedOut = true
            throw e
        }
        return file
    }

    private func uploadSteps(_ data: Data, mimeType: String, displayName: String, key: String) async throws -> GeminiUploadedFile {
        let apiKey = key.trimmed
        guard !apiKey.isEmpty else { throw GeminiError("Gemini API anahtarı girilmemiş. Ayarlardan yapıştırın.", .key) }
        guard let startURL = URL(string: GeminiSupport.uploadURL(base: baseURL)) else { throw GeminiError("Yükleme adresi geçersiz.", .error) }
        var start = URLRequest(url: startURL)
        start.httpMethod = "POST"
        start.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        start.setValue(String(data.count), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        start.setValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let meta = try JSONSerialization.data(withJSONObject: ["file": ["display_name": displayName]])
        let first: (data: Data, status: Int, headers: [String: String])
        do {
            first = try await transportFull(start, body: meta)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw GeminiError("Dosya yükleme başlatılamadı: \(error.localizedDescription)", .network)
        }
        guard (200..<300).contains(first.status) else {
            let (kind, message) = GeminiSupport.describeError(status: first.status, json: GeminiSupport.errorObject(from: first.data), model: model)
            throw GeminiError("Dosya yükleme başlatılamadı: \(message)", kind, status: first.status)
        }
        guard let target = first.headers["x-goog-upload-url"]?.trimmed, !target.isEmpty, let uploadURL = URL(string: target) else {
            throw GeminiError("Dosya yükleme adresi gelmedi.", .error, status: first.status)
        }
        var send = URLRequest(url: uploadURL)
        send.httpMethod = "POST"
        send.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        send.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        send.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        send.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        let second: (data: Data, status: Int, headers: [String: String])
        do {
            second = try await transportFull(send, body: data)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw GeminiError("Dosya yüklenemedi: \(error.localizedDescription)", .network)
        }
        guard (200..<300).contains(second.status) else {
            let (kind, message) = GeminiSupport.describeError(status: second.status, json: GeminiSupport.errorObject(from: second.data), model: model)
            throw GeminiError("Dosya yüklenemedi: \(message)", kind, status: second.status)
        }
        guard let file = GeminiSupport.parseUploadedFile(second.data) else {
            throw GeminiError("Dosya yüklendi ama adresi okunamadı.", .error, status: second.status)
        }
        return file
    }

    /// Yüklenen dosya kullanıma hazır mı ("ACTIVE")? Hazır değilse 2 sn arayla en çok `tries` kez sorulur. Durum sorulamıyorsa hazır sayılır
    /// (istek denenir; olmazsa çağıran dosyasız yola döner).
    func waitUntilActive(_ file: GeminiUploadedFile, key: String, tries: Int = 10) async -> Bool {
        if file.state == "ACTIVE" { return true }
        if file.state == "FAILED" { return false }
        guard !file.name.isEmpty, let url = URL(string: baseURL + "/" + file.name) else { return true }
        for _ in 0..<tries {
            await sleep(2)
            if Task.isCancelled { return false }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue(key.trimmed, forHTTPHeaderField: "x-goog-api-key")
            guard let result = try? await transport(request, body: nil), (200..<300).contains(result.status) else { continue }
            let state = GeminiSupport.parseUploadedFile(result.data)?.state ?? ""
            if state == "ACTIVE" { return true }
            if state == "FAILED" { return false }
        }
        return false
    }

    static let pathAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._")
        return set
    }()

    /// Sunucu hatalarında (500/502/503/504) yeniden denemeden önce beklenecek süreler (sn)
    static let serverBackoff: [TimeInterval] = [1.5, 4.0, 8.0]
    static let askServerRetries = 3

    private struct Reply: @unchecked Sendable { let value: Any? }

    /// Belirtilen model ve anahtarla tek seferlik generateContent. `timeout` verilirse cevap en çok o kadar beklenir
    /// (ağ hatasında yeniden denenmez); dolunca `timedOut` işaretli hata verilir.
    func generate(model name: String, key: String, body: Data, serverRetries: Int = GeminiClient.askServerRetries,
                  timeout: TimeInterval? = nil) async throws -> Any {
        let escaped = name.addingPercentEncoding(withAllowedCharacters: GeminiClient.pathAllowed) ?? name
        return try await post(path: "/models/\(escaped):generateContent", body: body, serverRetries: serverRetries, key: key,
                              timeout: timeout, model: name)
    }

    /// `timeout` verilirse cevap en çok o kadar beklenir (ağ hatasında yeniden denenmez); dolunca `timedOut` işaretli hata verilir.
    private func post(path: String, body: Data, serverRetries: Int = 1, key: String? = nil, timeout: TimeInterval? = nil,
                      model: String? = nil) async throws -> Any {
        guard let limit = timeout, limit > 0 else {
            return try await send(path: path, body: body, serverRetries: serverRetries, key: key, model: model, networkRetry: true)
        }
        let reply: Reply = try await withThrowingTaskGroup(of: Reply.self) { group in
            group.addTask {
                return Reply(value: try await self.send(path: path, body: body, serverRetries: serverRetries, key: key,
                                                        model: model, networkRetry: false, patience: limit))
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                return Reply(value: nil)
            }
            let first = try await group.next() ?? Reply(value: nil)
            group.cancelAll()
            return first
        }
        guard let value = reply.value else {
            var e = GeminiError("Gemini \(Int(limit)) sn içinde cevap vermedi.", .network)
            e.timedOut = true
            throw e
        }
        return value
    }

    /// `patience`: çağıranın bu isteğe verdiği süre (sn); ağ katmanının veri gelmeden bekleme sınırı ondan kısa kalmasın diye isteğe işlenir
    private func send(path: String, body: Data, serverRetries: Int, key override: String?, model overrideModel: String?,
                      networkRetry: Bool, patience: TimeInterval? = nil) async throws -> Any {
        let key = (override ?? keyProvider()).trimmed
        guard !key.isEmpty else {
            throw GeminiError("Gemini API anahtarı girilmemiş. Ayarlardan yapıştırın.", .key)
        }
        guard let url = URL(string: baseURL + path) else {
            throw GeminiError("Gemini adresi geçersiz.", .error)
        }
        var attempt = 0
        var serverAttempt = 0
        while true {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            if let idle = GeminiClient.idleAllowance(for: patience) { request.timeoutInterval = idle }
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let status: Int
            let data: Data
            do {
                let result = try await transport(request, body: body)
                guard result.status != 0 else {
                    throw GeminiError("Gemini'den anlaşılmaz yanıt geldi.", .error)
                }
                status = result.status
                data = result.data
            } catch let error as GeminiError {
                throw error
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                if networkRetry && attempt < 1 {
                    attempt += 1
                    await sleep(1.5)
                    continue
                }
                throw GeminiError("İnternete ulaşılamadı: \(error.localizedDescription)", .network)
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) ?? [String: Any]()
            if (200..<300).contains(status) { return json }
            if [500, 502, 503, 504].contains(status) && serverAttempt < serverRetries {
                let backoff = GeminiClient.serverBackoff
                await sleep(backoff[min(serverAttempt, backoff.count - 1)])
                serverAttempt += 1
                tlog("[gemini] HTTP \(status), yeniden deneniyor (\(serverAttempt)/\(serverRetries))")
                continue
            }
            let (kind, message) = GeminiSupport.describeError(status: status, json: GeminiSupport.errorObject(from: data),
                                                             model: overrideModel ?? model)
            tlog("[gemini] HTTP \(status) (\(path.split(separator: "?").first.map(String.init) ?? path)): \(message)")
            throw GeminiError(message, kind, status: status)
        }
    }

    /// Anahtarın görebildiği, metin üretebilen modellerin adları (ayarlardaki "Modelleri listele")
    func listModels() async throws -> [String] {
        let key = keyProvider().trimmed
        guard !key.isEmpty else {
            throw GeminiError("Gemini API anahtarı girilmemiş. Ayarlardan yapıştırın.", .key)
        }
        guard let url = URL(string: baseURL + "/models?pageSize=200") else {
            throw GeminiError("Gemini adresi geçersiz.", .error)
        }
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        let status: Int
        let data: Data
        do {
            let result = try await transport(request, body: nil)
            status = result.status
            data = result.data
        } catch {
            throw GeminiError("İnternete ulaşılamadı: \(error.localizedDescription)", .network)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let (kind, message) = GeminiSupport.describeError(status: status, json: json, model: "")
            throw GeminiError(message, kind, status: status)
        }
        return GeminiSupport.parseModelList(json)
    }
}

// MARK: - Anahtar denemesi (Ayarlar → "Anahtarı dene")

/// Tek bir deneme isteğinin sonucu: HTTP durumu (0 = ağa ulaşılamadı) ve Google'ın kendi iletisi
struct KeyProbe: Equatable {
    var status: Int
    var message: String
}

extension GeminiClient {
    /// Anahtarı gerçek kullanımdaki gibi sınar: profildeki modele çok kısa bir soru gönderir (birkaç belirteç harcar).
    /// `viaQuery` false ise anahtar `x-goog-api-key` başlığıyla (belgelerdeki yol), true ise adreste (`?key=`) gönderilir.
    /// Hata fırlatmaz; Google'ın ham durumunu ve iletisini döndürür ki ne dediği olduğu gibi görülebilsin.
    func probeKey(model: String, key: String, viaQuery: Bool) async -> KeyProbe {
        let name = model.trimmed.hasPrefix("models/") ? String(model.trimmed.dropFirst("models/".count)) : model.trimmed
        let escaped = name.addingPercentEncoding(withAllowedCharacters: GeminiClient.pathAllowed) ?? name
        let secret = key.trimmed
        var address = baseURL + "/models/\(escaped):generateContent"
        if viaQuery { address += "?key=" + (secret.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? secret) }
        guard let url = URL(string: address) else { return KeyProbe(status: 0, message: "adres geçersiz") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !viaQuery { request.setValue(secret, forHTTPHeaderField: "x-goog-api-key") }
        let object: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": "Yalnızca “tamam” yaz."]]]],
            "generationConfig": ["maxOutputTokens": 16]
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: object) else { return KeyProbe(status: 0, message: "istek kurulamadı") }
        do {
            let result = try await transport(request, body: body)
            let data = result.data
            let status = result.status
            let error = (GeminiSupport.errorObject(from: data)["error"] as? [String: Any]) ?? [:]
            let message = ((error["message"] as? String) ?? "").trimmed
            tlog("[gemini] anahtar sınaması (\(viaQuery ? "adres" : "başlık")): HTTP \(status) \(message.prefix(120))")
            return KeyProbe(status: status, message: message)
        } catch {
            // Ağ hatasının kodu da yazılır (örn. -1001 zaman aşımı, -1009 internet yok, -1200 TLS): neden ulaşılamadığı görülsün
            let code = (error as NSError).code
            tlog("[gemini] anahtar sınaması ağ hatası: \((error as NSError).domain) \(code) \(error.localizedDescription)")
            return KeyProbe(status: 0, message: "\(error.localizedDescription) (hata kodu \(code))")
        }
    }
}
