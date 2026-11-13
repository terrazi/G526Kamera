import Foundation

/// Gemini API ayarları ve sabitleri
enum GeminiConfig {
    static let baseURL = "https://generativelanguage.googleapis.com/v1beta"
    static let defaultModel = "gemini-3.6-flash"
    /// Bir istekte inline gönderilecek en çok PDF baytı: base64 ile ~18,7 MB olur, istek sınırı (20 MB) aşılmaz
    static let inlineBudget = 14 * 1024 * 1024
    /// Şık harfleri yerine sesli okunan kod sözcükleri
    static let defaultOptionCodes = "A=ADANA, B=BURSA, C=CEYHAN, D=DENİZLİ, E=ERZURUM"
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

/// Yardımcı işlevler: hata çevirisi, şık kodları, düşünme ayarı, model listesi
enum GeminiSupport {
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
        if let regex = try? NSRegularExpression(pattern: "Quota exceeded for metric:[^\\n]*"),
           let m = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
           let r = Range(m.range, in: message) {
            text += " (Google: \(String(String(message[r]).trimmed.prefix(160))))"
        }
        return text
    }

    /// 503 ve sunucunun mesajı yoğunluk / geçici sorun diyorsa true: sorun istekte ya da önbellekte değil, modelin kendisinde.
    static func isOverload(_ e: GeminiError) -> Bool {
        guard e.status == 503 else { return false }
        return e.message.range(of: "high demand|overload|temporarily|try again later|unavailable|yoğun",
                               options: [.regularExpression, .caseInsensitive]) != nil
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

    /// "A=ADANA, B-BURSA; c:CEYHAN" → [("A","ADANA"), ("B","BURSA"), ("C","CEYHAN")]. Bozuk girdiler atlanır; aynı harf ilk tanımıyla kalır.
    static func parseOptionCodes(_ text: String) -> [(letter: String, word: String)] {
        var out: [(letter: String, word: String)] = []
        var seen = Set<String>()
        for part in text.components(separatedBy: CharacterSet(charactersIn: ",;\n")) {
            let trimmed = part.trimmed
            guard let first = trimmed.first, first.isLetter else { continue }
            var rest = Substring(trimmed.dropFirst())
            rest = rest.drop(while: { $0 == " " || $0 == "\t" })
            guard let separator = rest.first, "-=:–".contains(separator) else { continue }
            let word = String(rest.dropFirst()).trimmed
            let letter = String(first).uppercased()
            if word.isEmpty || seen.contains(letter) { continue }
            seen.insert(letter)
            out.append((letter: letter, word: word))
        }
        return out
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

    /// ```json ... ``` çitlerini atar
    static func stripFence(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "^\\s*```(?:json)?\\s*|\\s*```\\s*$",
                                                   options: [.caseInsensitive]) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }
}

/// Gemini'ye istek atan istemci: generateContent (yeniden denemeli), model listesi, anahtar sınaması
final class GeminiClient {
    private let session: URLSession
    private let baseURL: String
    private let keyProvider: () -> String
    private let modelProvider: () -> String
    private let sleep: (TimeInterval) async -> Void

    static func makeSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.waitsForConnectivity = false
        c.timeoutIntervalForRequest = 120
        c.timeoutIntervalForResource = 600
        return URLSession(configuration: c)
    }

    init(session: URLSession? = nil,
         baseURL: String = GeminiConfig.baseURL,
         key: @escaping () -> String,
         model: @escaping () -> String,
         sleep: @escaping (TimeInterval) async -> Void = { seconds in
             try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
         }) {
        self.session = session ?? GeminiClient.makeSession()
        self.baseURL = baseURL
        self.keyProvider = key
        self.modelProvider = model
        self.sleep = sleep
    }

    var model: String {
        let m = modelProvider().trimmed
        return m.isEmpty ? GeminiConfig.defaultModel : m
    }

    var hasKey: Bool { return !keyProvider().trimmed.isEmpty }

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
                                                        model: model, networkRetry: false))
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

    private func send(path: String, body: Data, serverRetries: Int, key override: String?, model overrideModel: String?,
                      networkRetry: Bool) async throws -> Any {
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
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let status: Int
            let data: Data
            do {
                let (d, response) = try await session.upload(for: request, from: body)
                guard let http = response as? HTTPURLResponse else {
                    throw GeminiError("Gemini'den anlaşılmaz yanıt geldi.", .error)
                }
                status = http.statusCode
                data = d
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
            let (d, response) = try await session.data(for: request)
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            data = d
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
            let (data, response) = try await session.upload(for: request, from: body)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
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
