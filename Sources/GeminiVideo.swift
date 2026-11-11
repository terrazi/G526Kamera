import Foundation

struct VideoAnalysis {
    let text: String
    /// Cevabı veren profilin adı
    let model: String
    let promptTokens: Int
}

/// Kısa videoyu Gemini'ye tek seferlik gönderir ("Bu videoda ne oluyor?"). Belge sohbetinden bağımsızdır.
/// Video doğrudan istekte (base64, inlineData) gider: 30 sn'lik video birkaç MB'tır, istek sınırının (20 MB) altında kalır;
/// ayrıca dosya yükleme adımı gerekmez ve başka profilin anahtarıyla yeniden denemek kolaydır.
/// Gemini videoyu saniyede 1 kare örnekler; dosyanın kare hızı token'ı değiştirmez.
enum GeminiVideo {
    static let defaultQuestion = "Bu videoda ne oluyor? Görünen belge, yazı ve önemli ayrıntıları kısaca anlat. Emin olmadığın şeyi uydurma."
    static let system = "Yalnızca verilen videoya dayan. Türkçe, kısa ve net cevap ver. Cevap sesli okunacak: madde işareti, başlık ve biçimlendirme kullanma."
    /// Ham video en çok bu kadar olabilir (base64 sonrası istek 20 MB'ın altında kalsın)
    static let maxBytes = 14 * 1024 * 1024

    static func requestObject(video: Data, question: String, highResolution: Bool) -> [String: Any] {
        let videoPart: [String: Any] = ["inlineData": ["mimeType": "video/mp4", "data": video.base64EncodedString()]]
        var config: [String: Any] = ["temperature": 0.3, "maxOutputTokens": 4096]
        if highResolution { config["mediaResolution"] = "MEDIA_RESOLUTION_HIGH" }
        return [
            "contents": [["role": "user", "parts": [videoPart, ["text": question]]]],
            "systemInstruction": ["parts": [["text": system]]],
            "generationConfig": config
        ]
    }

    /// Denenecek profiller: seçili profil, zincir açıksa ardından 1→…→6 döngüsüyle anahtarı ve modeli dolu olanlar
    static func candidates(profiles: [GeminiProfileInfo], active: Int, chain: Bool) -> [GeminiProfileInfo] {
        let usable = GeminiProfiles.usable(profiles)
        let act = GeminiProfiles.active(profiles, active: active)
        guard usable.contains(where: { $0.slot == act.slot }) else { return [] }
        var list = [act]
        if chain {
            let n = GeminiProfiles.slotCount
            for k in 1..<n {
                let slot = (act.slot - 1 + k) % n + 1
                if let p = usable.first(where: { $0.slot == slot }) { list.append(p) }
            }
        }
        return list
    }

    /// Videoyu sorar. Kota / yoğunluk / gecikme olursa (zincir açıksa) sıradaki profile geçer ve `notify` ile kısa bilgi verir.
    /// Son profile bekleme sınırı konmaz.
    @MainActor
    static func analyze(videoData: Data, question: String, highResolution: Bool,
                        profiles: [GeminiProfileInfo], active: Int, chain: Bool, waitLimit: TimeInterval,
                        notify: @escaping (String) -> Void) async throws -> VideoAnalysis {
        guard videoData.count <= maxBytes else {
            throw GeminiError("Video Gemini'ye gönderilemeyecek kadar büyük.", .tooBig)
        }
        let order = candidates(profiles: profiles, active: active, chain: chain)
        guard !order.isEmpty else {
            throw GeminiError("Gemini API anahtarı girilmemiş. Ayarlardan yapıştırın.", .key)
        }
        let object = requestObject(video: videoData, question: question, highResolution: highResolution)
        let body = try JSONSerialization.data(withJSONObject: object)
        var lastError = GeminiError("Gemini cevap vermedi.", .error)
        for (i, profile) in order.enumerated() {
            let isLast = i == order.count - 1
            let limit: TimeInterval? = (isLast || waitLimit <= 0) ? nil : max(waitLimit, 10)
            let client = GeminiClient(key: { profile.key }, model: { profile.model })
            do {
                let reply = try await client.postVideoTask(model: profile.model, key: profile.key, body: body, timeout: limit)
                let answer = try GeminiSupport.parseAnswer(reply)
                return VideoAnalysis(text: answer.answer, model: profile.name, promptTokens: answer.promptTokens)
            } catch let e as GeminiError {
                lastError = e
                guard !isLast, GeminiChat.chainWorthy(e) else { throw e }
                let text = GeminiChat.switchText(from: profile, error: e, to: order[i + 1])
                notify(text.replacingOccurrences(of: "Sorunuz", with: "Video"))
            }
        }
        throw lastError
    }
}
