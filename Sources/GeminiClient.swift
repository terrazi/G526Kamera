import Foundation

/// Gemini API istemcisi (Windows sürümündeki g526/gemini.py'nin Swift karşılığı).
/// Belgeler PDF olarak "inline" gönderilir (istek toplamı 20 MB'ı geçmesin diye ~14 MB sınır). Cevap, sesli okunmaya
/// uygun olsun diye kısa/düz Türkçe istenir ve JSON olarak alınır: {"soru": anlaşılan soru, "cevap": cevap}.
enum GeminiConfig {
    static let baseURL = "https://generativelanguage.googleapis.com/v1beta"
    static let defaultModel = "gemini-3.8-flash"
    /// Ham PDF baytları; base64 ile ~18,7 MB olur, istek 20 MB'ın altında kalır
    static let inlineBudget = 14 * 1024 * 1024
    /// Sohbet geçmişinde tutulan son soru-cevap sayısı
    static let maxHistory = 6

    static let systemPrompt: String = [
        "Sen, kullanıcının taradığı belgeleri okuyup sorularını yanıtlayan bir belge asistanısın. "
            + "Cevabın hoparlörden yüksek sesle okunacak. Kurallar:",
        "1. Türkçe yaz. Kısa ve doğal konuş: genelde 2 ile 5 cümle; kullanıcı ayrıntı istemedikçe uzatma.",
        "2. Madde işareti, numaralı liste, tablo, başlık, kalın/italik işareti, emoji, bağlantı ve parantez yığını kullanma; "
            + "bunlar sesli okunurken anlamsız olur. Gerekirse 'birincisi, ikincisi' gibi sözcüklerle say.",
        "3. Tutarları ve tarihleri rakamla yaz ama birimlerini açık yaz (TL yerine Türk lirası, % yerine yüzde, "
            + "kg yerine kilogram); kısaltma kullanma. Uzun numaraları (IBAN, fatura, vergi numarası) tek tek rakamla ve "
            + "üçerli ya da dörderli gruplara ayırarak yaz.",
        "4. Yalnızca verilen belgelere dayan. Belgede yoksa 'Belgelerde bunu göremedim' de. Okunamayan ya da silik yerleri "
            + "tahmin etme, okunamadığını söyle. Hangi belgeden ve (varsa) hangi sayfadan aldığını kısaca belirt.",
        "5. Belgeler 'Belge 1', 'Belge 2' diye numaralıdır; Belge 1 en son taranandır. Kullanıcı 'son belge', 'en son' derse "
            + "Belge 1'i, 'bir önceki' derse Belge 2'yi kastediyor demektir. Belgeleri karıştırma.",
        "Çıktı her zaman JSON olmalı: 'soru' alanına kullanıcının sorusunu (ses geldiyse duyduğun şekliyle yazarak) koy, "
            + "'cevap' alanına cevabını."
    ].joined(separator: "\n")

    /// Sesli sorunun yanında gönderilen yönerge
    static let audioInstruction = "Yukarıdaki sesli soruyu yanıtla. Sesin başındaki 'Gemini' çağrı sözcüğü soruya dahil değildir, "
        + "onu yok say. JSON'daki 'soru' alanına soruyu duyduğun gibi yaz."

    static let responseSchema: [String: Any] = [
        "type": "OBJECT",
        "properties": ["soru": ["type": "STRING"], "cevap": ["type": "STRING"]],
        "required": ["soru", "cevap"]
    ]
}

enum GeminiErrorKind: String {
    case key, quota, model, network, blocked, empty, tooBig, http, error
}

struct GeminiError: LocalizedError {
    let kind: GeminiErrorKind
    let message: String
    let status: Int

    init(_ message: String, _ kind: GeminiErrorKind = .error, status: Int = 0) {
        self.message = message
        self.kind = kind
        self.status = status
    }

    var errorDescription: String? { return message }
}

struct GeminiDoc {
    let name: String
    let data: Data
}

struct GeminiTurn: Equatable {
    let question: String
    let answer: String
}

struct GeminiAnswer: Equatable {
    var question: String
    var answer: String
    var promptTokens = 0
    var outputTokens = 0
    var totalTokens = 0
    var finish = ""
}

/// Saf (ağsız) yardımcılar: istek kurma, cevap ayrıştırma, hata çevirisi, belge seçimi. Hepsi sınanabilir.
enum GeminiSupport {
    // MARK: Ses

    /// 16 bit tek kanal ham PCM'i WAV dosyasına sarar.
    static func wav(fromPCM16 pcm: Data, rate: Int = 16000, channels: Int = 1) -> Data {
        var out = Data()
        func u32(_ v: Int) { var x = UInt32(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        func u16(_ v: Int) { var x = UInt16(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        out.append(contentsOf: Array("RIFF".utf8))
        u32(36 + pcm.count)
        out.append(contentsOf: Array("WAVE".utf8))
        out.append(contentsOf: Array("fmt ".utf8))
        u32(16)
        u16(1)
        u16(channels)
        u32(rate)
        u32(rate * channels * 2)
        u16(channels * 2)
        u16(16)
        out.append(contentsOf: Array("data".utf8))
        u32(pcm.count)
        out.append(pcm)
        return out
    }

    // MARK: Belge seçimi

    /// docs: EN YENİ İLK. Sığan en yeni belgeleri seçer, sırayı korur. Dönüş: (seçilen indisler, atlanan adlar).
    static func selectDocs(_ docs: [(name: String, size: Int)], budget: Int = GeminiConfig.inlineBudget)
        -> (chosen: [Int], skipped: [String]) {
        var chosen: [Int] = []
        var skipped: [String] = []
        var used = 0
        for (i, doc) in docs.enumerated() {
            if doc.size > budget || used + doc.size > budget {
                skipped.append(doc.name)
                continue
            }
            chosen.append(i)
            used += doc.size
        }
        return (chosen, skipped)
    }

    // MARK: Hata çevirisi

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
        if status == 429 {
            var wait = ""
            if let regex = try? NSRegularExpression(pattern: "retry in ([0-9.]+)s", options: [.caseInsensitive]),
               let m = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
               m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: message), let seconds = Double(message[r]) {
                wait = " Yaklaşık \(Int(seconds + 1)) saniye sonra yeniden deneyin."
            }
            return (.quota, "Kota ya da hız sınırı aşıldı." + wait + " Ücretsiz katmanda sınırlar düşüktür.")
        }
        if status == 400 {
            return (.http, "Gemini isteği kabul etmedi (400): " + (message.isEmpty ? "bilinmeyen neden" : message))
        }
        if status >= 500 {
            return (.http, "Gemini şu an yanıt vermiyor (\(status)). Biraz sonra yeniden deneyin.")
        }
        return (.http, "Gemini hatası (\(status)): " + String(message.prefix(200)))
    }

    // MARK: İstek kurma

    /// Belgeler ilk kullanıcı turuna eklenir. Sesli soru WAV olarak, belgelerden sonra gelir.
    static func requestObject(questionText: String, audioWAV: Data?, docs: [GeminiDoc],
                              history: [GeminiTurn], system: String = GeminiConfig.systemPrompt) -> [String: Any] {
        var contents: [[String: Any]] = []
        for turn in history {
            contents.append(["role": "user", "parts": [["text": turn.question]]])
            contents.append(["role": "model", "parts": [["text": modelTurnText(turn)]]])
        }
        let current: [[String: Any]]
        if let wav = audioWAV {
            current = [["inlineData": ["mimeType": "audio/wav", "data": wav.base64EncodedString()]],
                       ["text": GeminiConfig.audioInstruction]]
        } else {
            current = [["text": questionText]]
        }
        contents.append(["role": "user", "parts": current])

        if !docs.isEmpty {
            var docParts: [[String: Any]] = []
            for (n, doc) in docs.enumerated() {
                docParts.append(["text": "Belge \(n + 1): \(doc.name)"])
                docParts.append(["inlineData": ["mimeType": "application/pdf", "data": doc.data.base64EncodedString()]])
            }
            var first = contents[0]
            let firstParts = (first["parts"] as? [[String: Any]]) ?? []
            first["parts"] = docParts + firstParts
            contents[0] = first
        }
        return [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": contents,
            "generationConfig": [
                "temperature": 0.3,
                "responseMimeType": "application/json",
                "responseSchema": GeminiConfig.responseSchema,
                "maxOutputTokens": 4096
            ] as [String: Any]
        ]
    }

    static func buildRequest(questionText: String, audioWAV: Data?, docs: [GeminiDoc],
                             history: [GeminiTurn]) throws -> Data {
        let object = requestObject(questionText: questionText, audioWAV: audioWAV, docs: docs, history: history)
        return try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
    }

    private static func modelTurnText(_ turn: GeminiTurn) -> String {
        let object: [String: Any] = ["soru": turn.question, "cevap": turn.answer]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return turn.answer
    }

    // MARK: Cevap ayrıştırma

    private static func intValue(_ any: Any?) -> Int {
        return (any as? NSNumber)?.intValue ?? 0
    }

    /// generateContent cevabından GeminiAnswer çıkarır. Engellenmiş / boş cevapta GeminiError.
    static func parseAnswer(_ object: Any) throws -> GeminiAnswer {
        guard let obj = object as? [String: Any] else {
            throw GeminiError("Gemini'den anlaşılmaz yanıt geldi.", .error)
        }
        if let feedback = obj["promptFeedback"] as? [String: Any], let reason = feedback["blockReason"] as? String, !reason.isEmpty {
            throw GeminiError("Gemini isteği güvenlik nedeniyle engelledi (\(reason)).", .blocked)
        }
        guard let candidates = obj["candidates"] as? [[String: Any]], let cand = candidates.first else {
            throw GeminiError("Gemini boş yanıt döndürdü.", .empty)
        }
        let finish = (cand["finishReason"] as? String) ?? ""
        let parts = ((cand["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        var text = ""
        for p in parts {
            if let thought = p["thought"] as? Bool, thought { continue }
            if let t = p["text"] as? String { text += t }
        }
        let usage = obj["usageMetadata"] as? [String: Any] ?? [:]
        var answer = GeminiAnswer(question: "", answer: text.trimmed)
        answer.promptTokens = intValue(usage["promptTokenCount"])
        answer.outputTokens = intValue(usage["candidatesTokenCount"])
        answer.totalTokens = intValue(usage["totalTokenCount"])
        answer.finish = finish
        if text.trimmed.isEmpty {
            if ["SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "RECITATION"].contains(finish) {
                throw GeminiError("Gemini cevabı güvenlik nedeniyle engelledi (\(finish)).", .blocked)
            }
            throw GeminiError("Gemini boş yanıt döndürdü (\(finish.isEmpty ? "neden yok" : finish)).", .empty)
        }
        let cleaned = stripFence(text)
        if let data = cleaned.data(using: .utf8),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let reply = (json["cevap"] as? String)?.trimmed, !reply.isEmpty {
            answer.answer = reply
            answer.question = ((json["soru"] as? String) ?? "").trimmed
        }
        return answer
    }

    /// ```json ... ``` çitlerini atar
    static func stripFence(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "^\\s*```(?:json)?\\s*|\\s*```\\s*$",
                                                   options: [.caseInsensitive]) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }
}

/// Soru sorma arayüzü (sohbet mantığı sahte istemciyle sınanabilsin diye).
protocol GeminiAsking: AnyObject {
    func ask(questionText: String, audioWAV: Data?, docs: [GeminiDoc], history: [GeminiTurn]) async throws -> GeminiAnswer
}

/// Gerçek istemci: URLSession ile generateContent çağırır.
final class GeminiClient: GeminiAsking {
    private let session: URLSession
    private let baseURL: String
    private let keyProvider: () -> String
    private let modelProvider: () -> String
    private let sleep: (TimeInterval) async -> Void

    static func makeSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.waitsForConnectivity = false
        c.timeoutIntervalForRequest = 120
        c.timeoutIntervalForResource = 240
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

    private static let pathAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._")
        return set
    }()

    func ask(questionText: String, audioWAV: Data?, docs: [GeminiDoc], history: [GeminiTurn]) async throws -> GeminiAnswer {
        if questionText.trimmed.isEmpty && audioWAV == nil {
            throw GeminiError("Soru boş.", .error)
        }
        let body = try GeminiSupport.buildRequest(questionText: questionText, audioWAV: audioWAV, docs: docs, history: history)
        let name = model.addingPercentEncoding(withAllowedCharacters: GeminiClient.pathAllowed) ?? model
        let object = try await post(path: "/models/\(name):generateContent", body: body)
        return try GeminiSupport.parseAnswer(object)
    }

    /// POST + bir kez yeniden deneme (ağ hatası ve 500/502/503/504 için, 1,5 sn sonra)
    private func post(path: String, body: Data) async throws -> Any {
        let key = keyProvider().trimmed
        guard !key.isEmpty else {
            throw GeminiError("Gemini API anahtarı girilmemiş. Ayarlardan yapıştırın.", .key)
        }
        guard let url = URL(string: baseURL + path) else {
            throw GeminiError("Gemini adresi geçersiz.", .error)
        }
        var attempt = 0
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
                if attempt < 1 {
                    attempt += 1
                    await sleep(1.5)
                    continue
                }
                throw GeminiError("İnternete ulaşılamadı: \(error.localizedDescription)", .network)
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) ?? [String: Any]()
            if (200..<300).contains(status) { return json }
            if [500, 502, 503, 504].contains(status) && attempt < 1 {
                attempt += 1
                await sleep(1.5)
                continue
            }
            let (kind, message) = GeminiSupport.describeError(status: status, json: (json as? [String: Any]) ?? [:], model: model)
            tlog("[gemini] HTTP \(status): \(message)")
            throw GeminiError(message, kind, status: status)
        }
    }
}
