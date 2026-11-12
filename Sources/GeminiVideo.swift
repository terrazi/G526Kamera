import Foundation

struct VideoAnalysis {
    let text: String
    /// Cevabı veren profilin adı
    let model: String
    let promptTokens: Int
}

/// Videoyu Gemini'ye tek seferlik gönderir ("Bu videoda ne oluyor?"). Belge sohbetinden bağımsızdır.
/// Küçük video (≤ 14 MB) doğrudan istekte (base64, inlineData) gider: ayrıca dosya yükleme adımı gerekmez.
/// Daha büyüğü (3 dk'lık kayıt ≈ 25–40 MB) önce Files API'ye yüklenir, işlenmesi beklenir, istekte dosya adresiyle verilir ve
/// iş bitince silinir (istek sınırı 20 MB'tır; belgelere göre bundan büyük istekte Files API şart).
/// Her profilin anahtarı ayrı proje olabileceğinden yüklenen dosya yalnız o profille kullanılır; profil değişirse yeniden yüklenir.
/// Gemini videoyu saniyede 1 kare örnekler; dosyanın kare hızı token'ı değiştirmez.
enum GeminiVideo {
    static let defaultQuestion = "Bu videoda ne oluyor? Görünen belge, yazı ve önemli ayrıntıları kısaca anlat. Emin olmadığın şeyi uydurma."
    static let system = "Yalnızca verilen videoya dayan. Türkçe, kısa ve net cevap ver. Cevap sesli okunacak: madde işareti, başlık ve biçimlendirme kullanma."
    /// Bu boyuta kadar video doğrudan istekte gider (base64 sonrası istek 20 MB'ın altında kalsın)
    static let inlineMaxBytes = 14 * 1024 * 1024
    /// Gönderilebilecek en büyük video (bellekte tutulur; 3 dk'lık kayıt bunun çok altındadır)
    static let maxBytes = 100 * 1024 * 1024

    /// Video doğrudan istekte mi gider, yoksa önce yüklenir mi
    static func usesFilesAPI(bytes: Int) -> Bool { return bytes > inlineMaxBytes }

    /// Yükleme süre sınırı (sn): en kötü 50 KB/sn bağlantı varsayılır, en az 300 sn
    static func uploadTimeout(bytes: Int) -> TimeInterval { return max(300, Double(bytes) / 50_000) }

    static func requestObject(video: Data, question: String, highResolution: Bool) -> [String: Any] {
        let videoPart: [String: Any] = ["inlineData": ["mimeType": "video/mp4", "data": video.base64EncodedString()]]
        return requestObject(videoPart: videoPart, question: question, highResolution: highResolution)
    }

    /// Yüklenmiş dosyaya (Files API adresi) bağlanan istek
    static func requestObject(fileURI: String, question: String, highResolution: Bool) -> [String: Any] {
        let videoPart: [String: Any] = ["fileData": ["mimeType": "video/mp4", "fileUri": fileURI]]
        return requestObject(videoPart: videoPart, question: question, highResolution: highResolution)
    }

    private static func requestObject(videoPart: [String: Any], question: String, highResolution: Bool) -> [String: Any] {
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
        // küçük video: gövde bir kez hazırlanır; büyük video: her profilde önce yüklenir
        var inlineBody: Data?
        if !usesFilesAPI(bytes: videoData.count) {
            let object = requestObject(video: videoData, question: question, highResolution: highResolution)
            inlineBody = try JSONSerialization.data(withJSONObject: object)
        }
        var lastError = GeminiError("Gemini cevap vermedi.", .error)
        for (i, profile) in order.enumerated() {
            let isLast = i == order.count - 1
            let limit: TimeInterval? = (isLast || waitLimit <= 0) ? nil : max(waitLimit, 10)
            let client = GeminiClient(key: { profile.key }, model: { profile.model })
            var uploaded: RemoteFile?
            do {
                let body: Data
                if let ready = inlineBody {
                    body = ready
                } else {
                    if i == 0 { notify("Video büyük, önce yükleniyor. Birkaç dakika sürebilir.") }
                    let file = try await client.uploadFile(name: "video", data: videoData, mimeType: "video/mp4",
                                                           timeout: uploadTimeout(bytes: videoData.count))
                    uploaded = file
                    let active = try await client.waitActive(file)
                    let object = requestObject(fileURI: active.uri, question: question, highResolution: highResolution)
                    body = try JSONSerialization.data(withJSONObject: object)
                }
                let reply = try await client.postVideoTask(model: profile.model, key: profile.key, body: body, timeout: limit)
                let answer = try GeminiSupport.parseAnswer(reply)
                if let file = uploaded { await client.deleteFile(name: file.name) }
                return VideoAnalysis(text: answer.answer, model: profile.name, promptTokens: answer.promptTokens)
            } catch let e as GeminiError {
                if let file = uploaded { await client.deleteFile(name: file.name) }
                lastError = e
                guard !isLast, GeminiChat.chainWorthy(e) else { throw e }
                let text = GeminiChat.switchText(from: profile, error: e, to: order[i + 1])
                notify(text.replacingOccurrences(of: "Sorunuz", with: "Video"))
            }
        }
        throw lastError
    }
}
