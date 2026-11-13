import Foundation

struct GeminiReply: Equatable {
    /// Gemini'nin okuduğu soru numarası (bulunamadıysa nil)
    let number: Int?
    let option: String
    let text: String
    /// Kulaklıktan okunacak cümle
    let spoken: String
    /// Cevabı veren model
    let model: String
}

@MainActor
protocol Answering: AnyObject {
    /// Dikte edilen soruyu Gemini'ye sorar. `expectedNumber`: soru numarası okunmamışsa kullanılacak sıradaki numara.
    /// `audio`: soruyu okuyanın ses kaydı (WAV); verilirse asıl kaynak odur, `question` dikte metni ipucu olur.
    func answer(question: String, expectedNumber: Int, audio: Data?) async throws -> GeminiReply
}

/// Modül 5: soruyu Gemini'ye gönderir, kısa cevabı çözer. Model kota/yoğunluk/gecikme verirse sıradaki modele geçer.
@MainActor
final class GeminiAnswerService: Answering {
    /// Sırayla denenecek modeller (aynı anahtarla)
    static let models = ["gemini-3.6-flash", "gemini-3.5-flash-lite", "gemini-3.1-flash-lite"]
    /// Son model dışındakilerde cevap için beklenecek süre (sn); dolunca sıradaki model denenir
    static let perModelLimit: TimeInterval = 40
    static let optionCodes = "A=Adana, B=Bursa, C=Ceyhan, D=Denizli, E=Erzurum"

    /// Sistem komutu: kullanıcının verdiği çerçeve + (1) şık sözcükleri (2) dikte hatalarına ve zayıf İngilizce telaffuzuna karşı empati
    static let systemPrompt = """
    Sen bir sınav okuyucu asistansın. Gelen test sorularını çöz ve SADECE şu formatta tek satır yanıt ver: \
    Soru [numara], [şık sözcüğü], [doğru cevabın metni]. Örnek: Soru 1, Denizli, Örgütsel Davranış.

    Şıklar: A=Adana, B=Bursa, C=Ceyhan, D=Denizli, E=Erzurum. Şık için HER ZAMAN bu sözcüğü yaz, harf yazma. \
    Soru okunurken şıklar A, B, C, D, E harfleriyle ya da bu sözcüklerle okunmuş olabilir.

    Soru, kullanıcının sesli okuduğu metnin Türkçe dikte (konuşma tanıma) çıktısıdır; yazı hatalarla dolu olabilir. \
    Bazen dikte metninin yanında kullanıcının SES KAYDI da gelir: o zaman asıl kaynak ses kaydıdır, önce onu dinle; dikte \
    metni yalnız ipucudur. Kaydın sonundaki "Cevapla" ya da "Gönder" sözcüğü tetikleyicidir, soruya katma. \
    Kullanıcı İngilizce sorularda çoğu zaman kelimeleri yanlış telaffuz eder ve Türkçe tanıyıcı İngilizce kelimeleri \
    Türkçe okunuşa benzeyen anlamsız sözcükler olarak yazar (ör. "kompleks ayşın" gibi). Bu yüzden metni harfi harfine \
    değil, kullanıcıya empati kurarak oku: kimin, hangi sınavda, ne söylemeye çalıştığını düşün. Bozuk görünen her \
    sözcük için olası İngilizce (ya da Türkçe) karşılıkları ses benzerliğiyle çıkar, soru kalıbını, şıkları, konunun \
    terimlerini ve gramer yapısını birlikte değerlendir. Çok boyutlu düşün: birden çok açıdan (anlam, ses, bağlam, \
    şıkların birbirine benzerliği) bakıp en tutarlı yorumu seç. Şıkların hangi harfe ya da sözcüğe denk geldiğini de aynı şekilde karıştırma.

    Soru numarası okunmadıysa ya da anlaşılmadıysa kullanıcı mesajındaki ipucunu kullan. Cevap metnini şıktan kısaca yaz. \
    Giriş, açıklama, markdown, tırnak ve ek cümle yazma. Emin değilsen en olası şıkkı yaz.
    """

    private let keyProvider: () -> String
    private let modelNames: [String]
    private let makeClient: (String) -> GeminiClient
    private let limit: TimeInterval

    init(key: @escaping () -> String,
         models: [String] = GeminiAnswerService.models,
         limit: TimeInterval = GeminiAnswerService.perModelLimit,
         makeClient: ((String) -> GeminiClient)? = nil) {
        self.keyProvider = key
        self.modelNames = models
        self.limit = limit
        self.makeClient = makeClient ?? { model in GeminiClient(key: key, model: { model }) }
    }

    // MARK: İstek ve cevap (saf yardımcılar)

    static func userText(question: String, expectedNumber: Int, hasAudio: Bool = false) -> String {
        let hint = "İpucu: soru numarası okunmadıysa bu soruyu Soru \(expectedNumber) say."
        if hasAudio {
            return "\(hint)\n\nBu mesajda soruyu okuyanın ses kaydı var (asıl kaynak). Dikte metni yalnız ipucudur, hatalı olabilir:\n\(question)"
        }
        return "\(hint)\n\nOkunan soru (dikte çıktısı):\n\(question)"
    }

    static func requestBody(question: String, expectedNumber: Int, audio: Data? = nil) throws -> Data {
        var parts: [[String: Any]] = [["text": userText(question: question, expectedNumber: expectedNumber, hasAudio: audio != nil)]]
        if let audio = audio {
            parts.append(["inlineData": ["mimeType": "audio/wav", "data": audio.base64EncodedString()]])
        }
        let object: [String: Any] = [
            "systemInstruction": ["parts": [["text": systemPrompt]]],
            "contents": [["role": "user", "parts": parts]]
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// generateContent cevabından model metni (düşünce parçaları atlanır). Engellenmiş ya da boş cevapta GeminiError.
    static func replyText(from object: Any) throws -> String {
        guard let obj = object as? [String: Any] else {
            throw GeminiError("Gemini'den anlaşılmaz yanıt geldi.", .error)
        }
        if let feedback = obj["promptFeedback"] as? [String: Any], let reason = feedback["blockReason"] as? String, !reason.isEmpty {
            throw GeminiError("Gemini isteği güvenlik nedeniyle engelledi (\(reason)).", .blocked)
        }
        guard let candidates = obj["candidates"] as? [[String: Any]], let candidate = candidates.first else {
            throw GeminiError("Gemini boş yanıt döndürdü.", .empty)
        }
        let parts = ((candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        var text = ""
        for part in parts {
            if let thought = part["thought"] as? Bool, thought { continue }
            if let piece = part["text"] as? String { text += piece }
        }
        let trimmed = text.trimmed
        if trimmed.isEmpty {
            let finish = (candidate["finishReason"] as? String) ?? ""
            throw GeminiError("Gemini boş yanıt döndürdü (\(finish.isEmpty ? "neden yok" : finish)).", .empty)
        }
        return trimmed
    }

    /// Sıradaki modelin işe yarayacağı hatalar: kota, sunucu hatası/yoğunluk, cevap gecikmesi, boş cevap, anahtar ya da model adı sorunu.
    /// Harcama sınırı, içerik engeli, çok büyük istek ve internetin hiç olmaması başka modelle düzelmez.
    static func fallbackWorthy(_ error: GeminiError) -> Bool {
        switch error.kind {
        case .cap, .blocked, .tooBig: return false
        case .network: return error.timedOut
        case .empty: return true
        default: return [500, 502, 503, 504].contains(error.status) || error.kind == .quota || error.kind == .key || error.kind == .model
        }
    }

    // MARK: Answering

    func answer(question: String, expectedNumber: Int, audio: Data?) async throws -> GeminiReply {
        let key = keyProvider().trimmed
        guard !key.isEmpty, !modelNames.isEmpty else { throw GeminiError(Say.noKeyShort, .key) }
        let body = try GeminiAnswerService.requestBody(question: question, expectedNumber: expectedNumber, audio: audio)
        var lastError = GeminiError("Gemini cevap vermedi.", .error)
        var trail: [String] = []
        for (index, model) in modelNames.enumerated() {
            let isLast = index == modelNames.count - 1
            do {
                let client = makeClient(model)
                let object = try await client.generate(model: model, key: key, body: body,
                                                       serverRetries: GeminiClient.askServerRetries,
                                                       timeout: isLast ? nil : limit)
                let parsed = AnswerParser.parse(try GeminiAnswerService.replyText(from: object))
                if parsed.spoken.isEmpty { throw GeminiError("Gemini cevap satırı vermedi.", .empty) }
                return GeminiReply(number: parsed.number, option: parsed.option, text: parsed.text,
                                   spoken: parsed.spoken, model: model)
            } catch let error as GeminiError {
                trail.append("\(model): \(error.message)")
                lastError = error
                guard !isLast, GeminiAnswerService.fallbackWorthy(error) else { break }
            }
        }
        var merged = GeminiError(trail.joined(separator: " "), lastError.kind, status: lastError.status)
        merged.timedOut = lastError.timedOut
        throw merged
    }
}
