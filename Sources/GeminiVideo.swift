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
/// Gemini varsayılan olarak saniyede 1 kare okur; `videoMetadata.fps` ile kayıttaki kare hızı verilir (token harcaması kare sayısıyla orantılı).
enum GeminiVideo {
    /// Okuma işi: Gemini'ye bu konuda ek kural konmaz (kullanıcı kararı: "gemini'nin işine karışmayalım")
    static let readingInstruction = "Videodaki yazıları oku ve analiz et. Soruları çöz ve cevaplarını ver."

    /// Cevap düzeni (kullanıcının daha önce yazdığı cevaplama isteğinden uyarlandı, 8. ve 12. kural): her soru için soru numarası,
    /// şehir adlarıyla kodlanmış şık ve cevap metni; cevaplar soru numarası sırasıyla. Şık kodları ayarlardaki "Şık kodları"ndan gelir.
    static func answerFormat(optionCodes: String) -> String {
        let codes = GeminiSupport.parseOptionCodes(optionCodes)
        let ex = GeminiSupport.example(codes)
        let sik: String
        if codes.isEmpty {
            sik = "Şık harfini söyle ve ardından şıkkın metnini ya da değerini videoda yazdığı gibi söyle (şıkta metin yoksa yalnız harf yeter)."
        } else {
            let table = codes.map { "\($0.letter) = \($0.word)" }.joined(separator: ", ")
            sik = "Şık harfini (A, B, C…) söyleme; harfin yerine şık kodunu söyle: \(table) (kod sözcüğünü aynen, büyük harfle yaz). "
                + "Kod sözcüğünden sonra virgül koy ve doğru şıkkın metnini ya da değerini videoda yazdığı gibi söyle. "
                + "Şıkta metin yoksa yalnız kod sözcüğünü söyle."
        }
        return "Cevap düzeni: her soru için önce soru numarası, sonra şık, ardından cevap metni. Kalıp: '\(ex.sentence)' "
            + "(örnekteki sözcükleri ve sayıyı kendi cevabına kopyalama; cevabı yalnızca videodan al). "
            + "Sıra sayısını yazıyla yaz (birinci, ikinci, … on birinci), sayıları okunuşuyla yaz. \(sik) "
            + "Cevapları soru numarasına göre sıralı ver: 1, 2, 3… sırasıyla; sorular videoda karışık sırada görünse de numarasına göre diz. "
            + "Her soru ayrı cümle olsun; aralara başka söz ya da gerekçe ekleme."
    }

    /// Varsayılan talimat: okuma işi + cevap düzeni (ayarlardaki talimat boş değilse o kullanılır)
    static func defaultInstruction(optionCodes: String) -> String {
        return readingInstruction + " " + answerFormat(optionCodes: optionCodes)
    }

    /// Yalnızca çıktı biçimi: cevap sesle okunacağı için işaret ve başlık olmasın
    static let system = "Türkçe cevap ver. Cevap sesli okunacak: madde işareti, başlık ve biçimlendirme kullanma."
    /// Bu boyuta kadar video doğrudan istekte gider (base64 sonrası istek 20 MB'ın altında kalsın)
    static let inlineMaxBytes = 14 * 1024 * 1024
    /// Gönderilebilecek en büyük video (bellekte tutulur; 3 dk'lık kayıt bunun çok altındadır)
    static let maxBytes = 100 * 1024 * 1024

    /// Video doğrudan istekte mi gider, yoksa önce yüklenir mi
    static func usesFilesAPI(bytes: Int) -> Bool { return bytes > inlineMaxBytes }

    /// Yükleme süre sınırı (sn): en kötü 50 KB/sn bağlantı varsayılır, en az 300 sn
    static func uploadTimeout(bytes: Int) -> TimeInterval { return max(300, Double(bytes) / 50_000) }

    /// Gemini'nin videodan okuyacağı kare hızı: kaydın kare hızıyla aynı (varsayılan 1 kare/sn olurdu; kayıttaki karelerin
    /// yarısı boşa giderdi). Belgelerde `videoMetadata.fps` 0–24 arasındadır; ayar reddedilirse ayarsız yeniden denenir.
    /// Belirteç harcaması kare hızıyla orantılı artar (yaklaşık iki kat).
    static let sampleFPS: Double = VideoRecorder.fps

    static func requestObject(video: Data, question: String, highResolution: Bool, fps: Double? = nil) -> [String: Any] {
        let videoPart: [String: Any] = ["inlineData": ["mimeType": "video/mp4", "data": video.base64EncodedString()]]
        return requestObject(videoPart: videoPart, question: question, highResolution: highResolution, fps: fps)
    }

    /// Yüklenmiş dosyaya (Files API adresi) bağlanan istek
    static func requestObject(fileURI: String, question: String, highResolution: Bool, fps: Double? = nil) -> [String: Any] {
        let videoPart: [String: Any] = ["fileData": ["mimeType": "video/mp4", "fileUri": fileURI]]
        return requestObject(videoPart: videoPart, question: question, highResolution: highResolution, fps: fps)
    }

    private static func requestObject(videoPart: [String: Any], question: String, highResolution: Bool,
                                      fps: Double?) -> [String: Any] {
        var videoPart = videoPart
        if let fps = fps { videoPart["videoMetadata"] = ["fps": fps] }
        var config: [String: Any] = ["temperature": 0.3, "maxOutputTokens": 8192]
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
        var lastError = GeminiError("Gemini cevap vermedi.", .error)
        for (i, profile) in order.enumerated() {
            let isLast = i == order.count - 1
            let limit: TimeInterval? = (isLast || waitLimit <= 0) ? nil : max(waitLimit, 10)
            let client = GeminiClient(key: { profile.key }, model: { profile.model })
            var uploaded: RemoteFile?
            do {
                // küçük video istekte gider; büyük video bu profilde önce yüklenir (bir kez)
                let uri: String?
                if usesFilesAPI(bytes: videoData.count) {
                    if i == 0 { notify("Video büyük, önce yükleniyor. Birkaç dakika sürebilir.") }
                    let file = try await client.uploadFile(name: "video", data: videoData, mimeType: "video/mp4",
                                                           timeout: uploadTimeout(bytes: videoData.count))
                    uploaded = file
                    uri = try await client.waitActive(file).uri
                } else {
                    uri = nil
                }
                func ask(fps: Double?) async throws -> VideoAnalysis {
                    let object: [String: Any]
                    if let uri = uri {
                        object = requestObject(fileURI: uri, question: question, highResolution: highResolution, fps: fps)
                    } else {
                        object = requestObject(video: videoData, question: question, highResolution: highResolution, fps: fps)
                    }
                    let body = try JSONSerialization.data(withJSONObject: object)
                    let reply = try await client.postVideoTask(model: profile.model, key: profile.key, body: body, timeout: limit)
                    let answer = try GeminiSupport.parseAnswer(reply)
                    return VideoAnalysis(text: answer.answer, model: profile.name, promptTokens: answer.promptTokens)
                }
                let result: VideoAnalysis
                do {
                    result = try await ask(fps: sampleFPS)
                } catch let e as GeminiError where e.status == 400 {
                    // kare hızı ayarı bu model/biçimde kabul edilmemiş olabilir: ayarsız (1 kare/sn) bir kez daha denenir
                    tlog("[video] kare hızı ayarıyla istek reddedildi (\(e.message)); ayarsız yeniden deneniyor")
                    result = try await ask(fps: nil)
                }
                if let file = uploaded { await client.deleteFile(name: file.name) }
                return result
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
