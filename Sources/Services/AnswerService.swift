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
    /// Cevap ilk sıradaki profilden gelmediyse nedenini anlatan kısa not ("1. profil kotası doldu; cevap … modelinden geldi"); aksi hâlde boş
    var note: String = ""
    /// Kulaklıktan söylenen tek kısa cümle: yalnız cevap diğer modeller yanıt vermeyince ÜCRETLİ modelden geldiyse "Ücretli modelden cevaplandı."
    /// (para harcandığı bilinsin). Hangi ücretsiz modelin cevapladığı ve sunucunun hata metinleri söylenmez; ayrıntı yalnız ekrandaki `note` içindedir.
    var spokenNote: String = ""
}

@MainActor
protocol Answering: AnyObject {
    /// Dikte edilen soruyu Gemini'ye sorar. `expectedNumber`: soru numarası okunmamışsa kullanılacak sıradaki numara.
    /// `audio`: soruyu okuyanın ses kaydı (WAV); verilirse asıl kaynak odur, `question` dikte metni ipucu olur.
    /// `english`: aynı sesin İngilizce tanıyıcıdan geçmiş hâli (boş olabilir); İngilizce cümlelerde Türkçe metinden daha doğrudur.
    /// `passage`: kamerayla çekilmiş ortak paragraf varsa görüntüleri (soru metni paragrafa göndermeyi söyler); yoksa nil
    func answer(question: String, english: String, expectedNumber: Int, audio: Data?, passage: PassageMedia?) async throws -> GeminiReply
    /// Sürüm 4: kamera ile çekilmiş soru (sayfa fotoğrafı + kısa video). Cevap biçimi ve profil zinciri sesle gelen soruyla aynıdır.
    func answer(capture: CapturedQuestion, expectedNumber: Int) async throws -> GeminiReply
}

extension Answering {
    func answer(question: String, english: String, expectedNumber: Int, audio: Data?) async throws -> GeminiReply {
        return try await answer(question: question, english: english, expectedNumber: expectedNumber, audio: audio, passage: nil)
    }

    func answer(question: String, expectedNumber: Int, audio: Data?) async throws -> GeminiReply {
        return try await answer(question: question, english: "", expectedNumber: expectedNumber, audio: audio)
    }
}

/// Modül 5: soruyu Gemini'ye gönderir, kısa cevabı çözer. 4 profil (her birinin kendi anahtarı ve modeli) sırayla denenir:
/// kota dolarsa, sunucu hata verirse, cevap gecikirse ya da anahtar/model sorunluysa sıradaki profile geçilir.
@MainActor
final class GeminiAnswerService: Answering {
    /// Son profil dışındakilerde cevap için beklenecek süre (sn); dolunca sıradaki profil denenir
    static let perModelLimit: TimeInterval = 40
    /// Kamera ile çekilen soruda (fotoğraf + video yüklenir, hücresel veriyle) son profil dışındakilerde beklenecek süre: yükleme de buna girer
    static let capturePerModelLimit: TimeInterval = 100
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

    Bazen ikinci bir dikte metni de gelir: aynı sesin İngilizce tanıyıcıdan geçmiş hâli. Soru İngilizceyse bu metin, Türkçe \
    dikte metninden çok daha doğrudur (ses kaydıyla birlikte değerlendir); Türkçe cümlelerde ise İngilizce metin anlamsızdır, onu yok say. \
    İki metin birbirini tamamlayabilir: Türkçe şıkları ve soru kalıbını Türkçe metinden, İngilizce cümleyi İngilizce metinden al.

    Kullanıcı soruları sırayla okumak zorunda değildir (önce Soru 7, sonra Soru 3 okunabilir): numarayı sıradan ya da ipucundan \
    çıkarma, okunan numarayı aynen yaz. Soru numarası hiç okunmadıysa ya da anlaşılmadıysa kullanıcı mesajındaki ipucunu kullan. \
    Bazen mesaj "Ortak paragraf (… numaralı sorular için ortaktır …)" diye başlar; ardından paragraf metni (ya da paragraf yazı olarak \
    değil, mesaja eklenen fotoğraf ve videoda görüntü olarak verildiği notu) ve "Şimdi sorulan soru:" bölümü gelir. Paragraf birden çok sorunun ortak metnidir: yalnız "Şimdi sorulan soru" bölümündeki soruyu, paragrafa dayanarak \
    yanıtla ve cevabı o sorunun numarasıyla ver; paragraftaki diğer numaraları cevaplama. Soru metni "Soru 7." diye başlıyorsa bu \
    numarayı kullanıcı söylemiştir (numara okumadan sonra sorulup öğrenildi): aynen kullan. \
    Cevap metnini şıktan kısaca yaz. \
    Giriş, açıklama, markdown, tırnak ve ek cümle yazma. Emin değilsen en olası şıkkı yaz.
    """

    /// Sürüm 4: kamera ile çekilen soru için sistem komutu. Cevap biçimi ve şık sözcükleri sesli sorudakiyle aynıdır; fark: soru görüntüden okunur
    /// ve kadrajın kenarlarından yarım görünen komşu sorular yok sayılır (sayfa ortada tek bir soruya konumlandırılmıştır, ama kenar taşabilir).
    static let captureSystemPrompt = """
    Sen bir sınav okuyucu asistansın. Mesajda basılı bir test sorusunun FOTOĞRAFI ve (varsa) aynı sayfanın kısa VİDEOSU var. \
    Soruyu görüntüden oku, çöz ve SADECE şu formatta tek satır yanıt ver: Soru [numara], [şık sözcüğü], [doğru cevabın metni]. \
    Örnek: Soru 1, Denizli, Örgütsel Davranış.

    Şıklar: A=Adana, B=Bursa, C=Ceyhan, D=Denizli, E=Erzurum. Şık için HER ZAMAN bu sözcüğü yaz, harf yazma. \
    Sayfada şıklar A, B, C, D, E harfleriyle basılıdır; hangi harfin hangi sözcüğe denk geldiğini karıştırma.

    ODAK: üzerinde çalışılan soru, görüntünün ortasındaki ve şıklarıyla birlikte tam görünen sorudur. Görüntünün kenarlarında yarım \
    görünen başka sorular, şıklar, sütun ya da sayfa parçaları, sayfa numarası, üst ve alt bilgi başka sorulara aittir: bunları YOK SAY, \
    cevaplama, numaralarını kullanma, "soru bölünmüş" gibi bir şey söyleme. Soru tam kadrajda ise sorun yok demektir; hemen cevapla.

    Fotoğraf ve video aynı sayfayı gösterir. Fotoğrafta okunmayan, bulanık ya da parlama yüzünden görünmeyen bir yer varsa videodan \
    tamamla; ikisi çelişirse net olana güven. Soru numarasını soru metninin başından oku ve aynen yaz; numara okunamıyorsa kullanıcı \
    mesajındaki ipucunu kullan. Sayfada birkaç soruya ortak bir paragraf varsa onu oku ve ortada görünen soruyu o paragrafa dayanarak yanıtla. \
    Mesajda ayrıca kullanıcının daha önce çektiği ORTAK PARAGRAFIN fotoğrafı ve videosu da olabilir (mesajdaki not hangi görüntünün paragrafa, hangisinin \
    soruya ait olduğunu söyler): çekilen soru o paragrafın sorularından biriyse paragrafı oradan oku ve soruyu ona dayanarak yanıtla. \
    Cevap metnini şıktan kısaca yaz. Giriş, açıklama, markdown, tırnak ve ek cümle yazma. Emin değilsen en olası şıkkı yaz.
    """

    static func captureText(expectedNumber: Int, hasVideo: Bool, extra: String, passage: String = "") -> String {
        var text = "İpucu: soru numarası görüntüden okunamazsa bu soruyu Soru \(expectedNumber) say. Numara okunuyorsa sıraya değil okunan numaraya uy."
        text += hasVideo
            ? "\n\nBu mesajda soru sayfasının fotoğrafı ve aynı sayfanın kısa videosu var. Görüntünün ortasındaki soruyu cevapla; kenarlardan yarım görünen diğer soruları dikkate alma."
            : "\n\nBu mesajda soru sayfasının fotoğrafı var. Görüntünün ortasındaki soruyu cevapla; kenarlardan yarım görünen diğer soruları dikkate alma."
        let note = extra.trimmed
        if !note.isEmpty { text += "\n\nKullanıcının ek talimatı: \(note)" }
        let shared = passage.trimmed
        if !shared.isEmpty { text += "\n\n" + shared }
        return text
    }

    /// Kamerayla çekilmiş ortak paragrafın istek parçaları: fotoğraf, sığarsa video. Video okunamazsa (dosya yok) yalnız fotoğraf gider.
    static func passageParts(_ media: PassageMedia, withVideo: Bool, fps: Double?) -> [[String: Any]] {
        var parts: [[String: Any]] = [["inlineData": ["mimeType": "image/jpeg", "data": media.photo.base64EncodedString()]]]
        if withVideo, let url = media.video, let data = try? Data(contentsOf: url) {
            var part: [String: Any] = ["inlineData": ["mimeType": "video/mp4", "data": data.base64EncodedString()]]
            if let fps = fps { part["videoMetadata"] = ["fps": fps] }
            parts.append(part)
        }
        return parts
    }

    /// Çekilen soru için istek gövdesi. Video satır içi gider (≤ 14 MB; büyükse yalnız fotoğraf gider); `fps`: kaydın kare hızı (nil: ayarsız)
    static func captureBody(_ shot: CapturedQuestion, expectedNumber: Int, fps: Double? = VideoRecorder.fps) throws -> Data {
        var video: Data?
        if shot.canSendVideo, let url = shot.video { video = try? Data(contentsOf: url) }
        var parts: [[String: Any]] = [["text": captureText(expectedNumber: expectedNumber, hasVideo: video != nil, extra: shot.extraInstruction, passage: shot.passageNote)]]
        // Kamerayla çekilmiş ortak paragraf varsa görüntüleri soruninkinden ÖNCE gelir (mesajdaki not sırayı söyler)
        if let media = shot.passageMedia {
            parts.append(contentsOf: passageParts(media, withVideo: shot.canSendPassageVideo, fps: fps))
        }
        parts.append(["inlineData": ["mimeType": "image/jpeg", "data": shot.photo.base64EncodedString()]])
        if let video = video {
            var part: [String: Any] = ["inlineData": ["mimeType": "video/mp4", "data": video.base64EncodedString()]]
            if let fps = fps { part["videoMetadata"] = ["fps": fps] }
            parts.append(part)
        }
        var object: [String: Any] = [
            "systemInstruction": ["parts": [["text": captureSystemPrompt]]],
            "contents": [["role": "user", "parts": parts]]
        ]
        if shot.highResolution { object["generationConfig"] = ["mediaResolution": "MEDIA_RESOLUTION_HIGH"] }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private let profilesProvider: () -> [GeminiProfileInfo]
    private let makeClient: (GeminiProfileInfo) -> GeminiClient
    private let limit: TimeInterval
    private let captureLimit: TimeInterval
    private let now: () -> Date
    /// Bu profiller bu zamana kadar sona bırakılır (kotası doldu / cevap vermedi): her soruda boşuna beklenmesin
    private var restingUntil: [Int: Date] = [:]

    init(profiles: @escaping () -> [GeminiProfileInfo],
         limit: TimeInterval = GeminiAnswerService.perModelLimit,
         captureLimit: TimeInterval = GeminiAnswerService.capturePerModelLimit,
         now: @escaping () -> Date = { Date() },
         makeClient: ((GeminiProfileInfo) -> GeminiClient)? = nil) {
        self.profilesProvider = profiles
        self.limit = limit
        self.captureLimit = captureLimit
        self.now = now
        self.makeClient = makeClient ?? { profile in GeminiClient(key: { profile.key }, model: { profile.model }) }
    }

    // MARK: İstek ve cevap (saf yardımcılar)

    static func userText(question: String, english: String = "", expectedNumber: Int, hasAudio: Bool = false) -> String {
        let hint = "İpucu: soru numarası okunmadıysa bu soruyu Soru \(expectedNumber) say. Numara okunduysa sıraya değil okunan numaraya uy."
        var text: String
        if hasAudio {
            text = "\(hint)\n\nBu mesajda soruyu okuyanın ses kaydı var (asıl kaynak). Dikte metni yalnız ipucudur, hatalı olabilir:\n\(question)"
        } else {
            text = "\(hint)\n\nOkunan soru (dikte çıktısı):\n\(question)"
        }
        let second = english.trimmed
        if !second.isEmpty {
            text += "\n\nAynı sesin İngilizce tanıyıcıdan geçmiş hâli (İngilizce cümleleri Türkçe metinden daha doğru yazmış olabilir; Türkçe cümleleri bozuk yazar):\n\(second)"
        }
        return text
    }

    static func requestBody(question: String, english: String = "", expectedNumber: Int, audio: Data? = nil, passage: PassageMedia? = nil) throws -> Data {
        var parts: [[String: Any]] = [["text": userText(question: question, english: english, expectedNumber: expectedNumber, hasAudio: audio != nil)]]
        if let audio = audio {
            parts.append(["inlineData": ["mimeType": "audio/wav", "data": audio.base64EncodedString()]])
        }
        if let media = passage {
            // Ses kaydı + paragraf fotoğrafı + paragraf videosu 14 MB'ı (base64 ile ~18,7 MB) aşmasın: sığmazsa yalnız fotoğraf gider
            let used = (audio?.count ?? 0) + media.photo.count
            let fits = media.canHaveVideo && used + media.videoBytes <= CapturedQuestion.maxInlineVideoBytes
            parts.append(contentsOf: passageParts(media, withVideo: fits, fps: VideoRecorder.fps))
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

    /// Profilin modeline göre istek gövdesi: Gemma modelleri düşünmeyi yalnız "thinkingLevel" ile açar (soru çözümünde doğruluk için gerekir),
    /// Gemini modellerine dokunulmaz.
    static func body(_ body: Data, forModel model: String) -> Data {
        guard let level = GeminiSupport.thinkingLevel(model: model, setting: "auto"),
              let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: GeminiSupport.applyThinking(object, level: level)) else { return body }
        return data
    }

    // MARK: Answering

    /// Sıra: dinlenmiş profiller yuva sırasıyla, ardından sona bırakılanlar (hepsi sondaysa yine hepsi denenir)
    func order(_ usable: [GeminiProfileInfo]) -> [GeminiProfileInfo] {
        let t = now()
        let ready = usable.filter { (restingUntil[$0.slot] ?? .distantPast) <= t }
        let resting = usable.filter { (restingUntil[$0.slot] ?? .distantPast) > t }
        return ready + resting
    }

    private func rest(_ profile: GeminiProfileInfo, after error: GeminiError) {
        let seconds: TimeInterval
        switch error.kind {
        case .quota: seconds = error.message.contains("günlük") ? 3600 : 300
        case .key, .model, .cap: seconds = 900
        default: seconds = 120
        }
        restingUntil[profile.slot] = now().addingTimeInterval(seconds)
    }

    func answer(question: String, english: String, expectedNumber: Int, audio: Data?, passage: PassageMedia?) async throws -> GeminiReply {
        guard !GeminiProfiles.usable(profilesProvider()).isEmpty else { throw GeminiError(Say.noKeyShort, .key) }
        let body = try GeminiAnswerService.requestBody(question: question, english: english, expectedNumber: expectedNumber, audio: audio, passage: passage)
        // Paragraf görüntüsü de gidiyorsa istek, yüklemesi daha uzun süren çekilmiş soru gibi bekler
        return try await run(body: body, limit: passage == nil ? limit : captureLimit)
    }

    /// Kamera ile çekilen soru: kare hızı ayarı bu modelde reddedilirse (400) ayarsız bir kez daha denenir
    func answer(capture: CapturedQuestion, expectedNumber: Int) async throws -> GeminiReply {
        guard !GeminiProfiles.usable(profilesProvider()).isEmpty else { throw GeminiError(Say.noKeyShort, .key) }
        let body = try GeminiAnswerService.captureBody(capture, expectedNumber: expectedNumber)
        do {
            return try await run(body: body, limit: captureLimit)
        } catch let error as GeminiError where error.status == 400 && capture.canSendVideo {
            tlog("[kamera] kare hızı ayarıyla istek reddedildi (\(error.message)); ayarsız yeniden deneniyor")
            return try await run(body: try GeminiAnswerService.captureBody(capture, expectedNumber: expectedNumber, fps: nil), limit: captureLimit)
        }
    }

    /// Profil zinciri: istek sırayla her profile gönderilir (kota, sunucu hatası, gecikme, anahtar ya da model sorununda sıradakine geçilir)
    private func run(body: Data, limit: TimeInterval) async throws -> GeminiReply {
        let usable = GeminiProfiles.usable(profilesProvider())
        guard !usable.isEmpty else { throw GeminiError(Say.noKeyShort, .key) }
        let sequence = order(usable)
        var lastError = GeminiError("Gemini cevap vermedi.", .error)
        var trail: [String] = []
        var failedNames: [String] = []
        for (index, profile) in sequence.enumerated() {
            let isLast = index == sequence.count - 1
            do {
                let client = makeClient(profile)
                // Son profil dışındakilerde sunucu hatasında yeniden deneme ve uzun bekleme yok: hemen sıradakine geçilir
                let object = try await client.generate(model: profile.model, key: profile.key,
                                                       body: GeminiAnswerService.body(body, forModel: profile.model),
                                                       serverRetries: isLast ? GeminiClient.askServerRetries : 0,
                                                       timeout: isLast ? nil : limit)
                let parsed = AnswerParser.parse(try GeminiAnswerService.replyText(from: object))
                if parsed.spoken.isEmpty { throw GeminiError("Gemini cevap satırı vermedi.", .empty) }
                restingUntil[profile.slot] = nil
                let note = trail.isEmpty ? "" : "Cevap \(profile.name) modelinden geldi: " + trail.joined(separator: " ")
                let spokenNote = (!profile.free && !failedNames.isEmpty) ? Say.paidModelUsed : ""
                return GeminiReply(number: parsed.number, option: parsed.option, text: parsed.text,
                                   spoken: parsed.spoken, model: profile.model, note: note, spokenNote: spokenNote)
            } catch let error as GeminiError {
                trail.append("\(profile.name) (\(profile.model)): \(error.message)")
                failedNames.append(profile.name)
                lastError = error
                guard !isLast, GeminiAnswerService.fallbackWorthy(error) else { break }
                rest(profile, after: error)
            }
        }
        var merged = GeminiError(trail.joined(separator: " "), lastError.kind, status: lastError.status)
        merged.timedOut = lastError.timedOut
        throw merged
    }
}
