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
    static let maxHistory = 12
    /// Bir oturumda Gemini'ye verilecek en çok sayfa
    static let maxPages = 500
    /// Gemini bir PDF sayfasını ortalama bu kadar jetonla sayar
    static let tokensPerPage = 560
    /// Bundan az sayfa "hafıza" kullanmadan doğrudan (inline) gider
    static let memoryMinPages = 8
    /// Açık önbellek için en az jeton (Gemini 3.x Flash)
    static let cacheMinTokens = 4096
    /// Önbellek her soruda bu kadar saniye uzatılır
    static let cacheTTL = 1800
    /// Files API dosyaları 48 saat saklar; 40 saatten eskisi yeniden yüklenir
    static let fileKeepSeconds: Double = 40 * 3600
    /// Şık harfleri yerine sesli okunan kod sözcükleri
    static let defaultOptionCodes = "A=ADANA, B=BURSA, C=CEYHAN, D=DENİZLİ, E=ERZURUM"
    /// Eski varsayılan (E=EDİRNE): kayıtlı değer buysa yeni varsayılanla değiştirilir
    static let previousDefaultOptionCodes = "A=ADANA, B=BURSA, C=CEYHAN, D=DENİZLİ, E=EDİRNE"
    static let docsIntro = "Aşağıdaki belgeler, soruları yanıtlarken dayanacağın belgelerdir. Bunlar kullanıcının taradığı sayfalardır ve uygulama bunları sana doğrudan ekledi: Drive'a, bağlantıya ya da dosyaya erişmen gerekmez. Kullanıcı 'Drive'daki belge' derse bunları kastediyordur. Belgeleri okuyamadığını ya da uygulamanın sana göndermesi gerektiğini söyleme; belgeleri oku ve cevapla."
    /// Sınav videoları (sınav kâğıdının kısa çekimleri) PDF'lerle birlikte verilir
    static let examVideoIntro = "Ekte sınav kâğıdının kısa video(ları) da var. PDF'lerle birlikte değerlendir; PDF'te okunamayan, eksik ya da bozuk kalan soru, şekil ve şıklar için videoya da bak. Soruları yine PDF'lerdeki numaralarına göre cevapla."
    static let docsAck = "Belgeleri okudum, sorularınızı bekliyorum."
    static let transcribeSystem = "Sesi Türkçe olarak aynen yazıya dök. Başındaki çağrı sözcüğünü ('Gemini' gibi) yazma. Yorum ekleme."
    static let transcribeMarker = "Bu sesi yazıya dök."
    static let batchNote = "[Uygulama notu] Toplu cevapta en son verilen soru numarası: "
    /// Toplu cevap verildi ama kullanıcıya ulaşmadı (kalıcı sıra 0): model geçmişe bakıp bir sonraki grubu vermesin
    static let batchNoteNone = "[Uygulama notu] Toplu cevapta kullanıcıya ulaşan grup yok (en son verilen soru numarası: 0); "
        + "'sıradaki' denirse 1. sorudan başla, konuşma geçmişindeki ulaşmamış grubu sayma."

    /// Şık kodlarına göre tamamlanan yönerge (varsayılan kodlarla)
    static var systemPrompt: String { return GeminiSupport.systemPrompt(codesText: defaultOptionCodes) }

    static let systemTemplate: String = [
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
        "6. Belgeleri titizlikle oku: her PDF'in her sayfasını görüntü olarak incele; küçük yazıları, tabloları, soru "
            + "numaralarını, şık harflerini (A, B, C…), el yazısını, damga ve notları atlama. Eğik ya da ters taranmış "
            + "sayfaları düzelterek oku.",
        "7. Bütün belgeleri bir bütün olarak değerlendir: bir sorunun metni, şıkları ya da ilgili bilgi farklı belgelerde ya "
            + "da sayfalarda olabilir, hepsini birleştirerek cevapla. Aynı sayfa birden çok kez taranmış (mükerrer) olabilir: "
            + "en temiz ve en okunaklı olanı esas al, diğerlerini yok say, aynı bilgiyi iki kez sayma. PDF'lerin sonunda "
            + "'okunan metin (OCR)' başlıklı sayfalar olabilir: bunlar otomatik okumanın çıktısıdır ve hatalı olabilir; "
            + "sayfa görüntüsüyle çelişirse görüntüyü esas al.",
        "@@KURAL8@@",
        "9. Kullanıcı konuşmayı bitirmek istiyorsa ('oturumu kapat', 'yeter', 'bu kadar', 'görüşürüz' gibi) 'kapat' alanını "
            + "true yap ve 'cevap' alanına kısa bir vedalaşma yaz; aksi hâlde 'kapat' false olsun.",
        "10. Ses bir soru ya da istek içermiyorsa (gürültü, öksürük, başkalarının sohbeti, kendi kendine konuşma, anlaşılmayan "
            + "ses) 'soru' ve 'cevap' alanlarını boş bırak; tahmin yürütüp cevap uydurma.",
        "11. Kullanıcı yapay zekâ modelini değiştirmek istiyorsa ('model değiştir', 'modeli değiştir') 'model_degistir' "
            + "alanını true yap ve 'cevap' alanını boş bırak; aksi hâlde false olsun.",
        "@@KURAL12@@",
        "@@KURAL13@@",
        "Çıktı her zaman JSON olmalı: 'soru' alanına kullanıcının sorusunu (ses geldiyse duyduğun şekliyle yazarak) koy, "
            + "'cevap' alanına cevabını, 'kapat' ve 'model_degistir' alanlarına true ya da false, 'son_soru' alanına tamsayı koy."
    ].joined(separator: "\n")

    /// Sayfa fotoğrafını metne döktüren OCR yönergesi
    static let ocrPrompt = "Bu bir belge sayfasının fotoğrafıdır. Sayfadaki bütün yazıyı eksiksiz ve olduğu gibi metne dök. Kurallar: "
        + "Okuma sırasını koru (sütun varsa soldan sağa, yukarıdan aşağıya). Soru numaralarını, şık harflerini (A, B, C…), "
        + "madde işaretlerini, sayıları, tarihleri ve noktalama işaretlerini aynen koru. Tabloları satır satır yaz, "
        + "hücreleri ' | ' ile ayır. Yazım hatalarını düzeltme, çeviri yapma, özetleme ya da yorum ekleme. Okuyamadığın "
        + "yeri tahmin etme, orada [okunamadı] yaz. Sayfada hiç yazı yoksa yalnızca [yazı yok] yaz. Türkçe harfleri "
        + "(ç, ğ, ı, İ, ö, ş, ü) doğru yaz. Yalnızca metni ver; başlık, açıklama ya da Markdown ekleme."

    /// Sesli sorunun yanında gönderilen yönerge
    static let audioInstruction = "Yukarıdaki sesli soruyu yanıtla. Sesin başında bir çağrı sözcüğü ('Gemini', 'hey dostum' gibi) varsa soruya dahil değildir, "
        + "onu yok say. Sesin sonunda 'tamam' varsa o, kaydı bitirme sözcüğüdür; soruya dahil değildir. "
        + "JSON'daki 'soru' alanına soruyu duyduğun gibi yaz."

    static let responseSchema: [String: Any] = [
        "type": "OBJECT",
        "properties": ["soru": ["type": "STRING"], "cevap": ["type": "STRING"], "kapat": ["type": "BOOLEAN"],
                       "model_degistir": ["type": "BOOLEAN"], "son_soru": ["type": "INTEGER"]],
        "required": ["soru", "cevap", "kapat", "model_degistir", "son_soru"]
    ]
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

/// Gemini'ye verilecek bir PDF. Baytlar bellekte (kısa belgeler) ya da diskte durur; 500 sayfalık set belleğe doldurulmaz.
struct GeminiDoc {
    let name: String
    private let inlineData: Data?
    let fileURL: URL?
    let size: Int
    /// Sayfa sayısı (0 = bilinmiyor; boyuttan tahmin edilir)
    var pages: Int
    /// Eşleme anahtarı (klasördeki dosya adı + boyut); boşsa içerik özetinden türetilir
    var key: String
    /// Files API adresi ve adı ("files/abc"); belge yüklendiyse dolu
    var uri = ""
    var remote = ""
    /// Dosya diskte yoksa baytları getirir (ör. belge klasöründen yeniden okur)
    var loader: (() async throws -> Data)?

    init(name: String, data: Data) {
        self.name = name
        self.inlineData = data
        self.fileURL = nil
        self.size = data.count
        self.pages = 0
        self.key = ""
        self.loader = nil
    }

    init(name: String, fileURL: URL, size: Int, pages: Int, key: String, loader: (() async throws -> Data)? = nil) {
        self.name = name
        self.inlineData = nil
        self.fileURL = fileURL
        self.size = size
        self.pages = pages
        self.key = key
        self.loader = loader
    }

    /// Baytlar (diskteyse okunur; yoksa boş)
    var data: Data {
        if let d = inlineData { return d }
        if let url = fileURL, let d = try? Data(contentsOf: url, options: .mappedIfSafe) { return d }
        return Data()
    }

    /// Baytlar yoksa yükleyiciyle getirir
    func load() async throws -> Data {
        if let d = inlineData { return d }
        if let url = fileURL, let d = try? Data(contentsOf: url, options: .mappedIfSafe), size == 0 || d.count == size { return d }
        if let loader = loader { return try await loader() }
        return data
    }

    var pageEstimate: Int { return pages > 0 ? pages : max(1, (size + 249_999) / 250_000) }
    var isRemote: Bool { return !uri.isEmpty }
}

struct GeminiTurn: Equatable {
    let question: String
    let answer: String
    /// Bu turdaki toplu cevabın son soru numarası (0 = toplu cevap değil)
    let batch: Int

    init(question: String, answer: String, batch: Int = 0) {
        self.question = question
        self.answer = answer
        self.batch = batch
    }
}

struct GeminiAnswer: Equatable {
    var question: String
    var answer: String
    var promptTokens = 0
    var outputTokens = 0
    var totalTokens = 0
    var finish = ""
    /// Kullanıcı oturumu kapatmak istedi
    var close = false
    /// Kullanıcı "model değiştir" dedi
    var switchModel = false
    /// Toplu cevapta (10'arlı gruplar) verilen son soru numarası; 0 = toplu cevap değil
    var lastQuestion = 0
    /// Önbellekten okunan girdi jetonu
    var cachedTokens = 0
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

    /// Yoğun / kotası dolu modelin yerine denenecek modeller: yalnız kararlı "flash" ve "flash-lite" adları (önizleme, ses, görsel yok),
    /// seçili model hariç; önce flash (yeni sürümden eskiye), sonra flash-lite.
    static func pickFallbackModels(_ names: [String], current: String, limit: Int = 2) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "^gemini-(\\d+(?:\\.\\d+)?)-flash(-lite)?$") else { return [] }
        var flash: [(version: [Int], name: String)] = []
        var lite: [(version: [Int], name: String)] = []
        for n in names where n != current {
            guard let m = regex.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)),
                  let vr = Range(m.range(at: 1), in: n) else { continue }
            let version = n[vr].split(separator: ".").compactMap { Int($0) }
            if m.range(at: 2).location != NSNotFound {
                lite.append((version: version, name: n))
            } else {
                flash.append((version: version, name: n))
            }
        }
        flash.sort { $1.version.lexicographicallyPrecedes($0.version) }
        lite.sort { $1.version.lexicographicallyPrecedes($0.version) }
        return Array((flash + lite).map { $0.name }.prefix(limit))
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

    // MARK: Sayfa sayısı

    private static func hasBytes(_ bytes: [UInt8], at index: Int, _ pattern: [UInt8]) -> Bool {
        guard index >= 0, index + pattern.count <= bytes.count else { return false }
        for (offset, b) in pattern.enumerated() where bytes[index + offset] != b { return false }
        return true
    }

    /// PDF'teki sayfa sayısı (/Type /Page nesneleri; /Pages sayılmaz). Nesne akışlı PDF'te sayılamazsa boyuta göre tahmin eder (~250 KB/sayfa).
    static func countPages(_ data: Data, size: Int = 0) -> Int {
        let bytes = [UInt8](data)
        let typeMark = Array("/Type".utf8)
        let pageMark = Array("/Page".utf8)
        let n = bytes.count
        var count = 0
        var i = 0
        while i < n {
            if bytes[i] == 0x2F && hasBytes(bytes, at: i, typeMark) {
                var j = i + typeMark.count
                while j < n && (bytes[j] == 0x20 || bytes[j] == 0x0A || bytes[j] == 0x0D || bytes[j] == 0x09) { j += 1 }
                if hasBytes(bytes, at: j, pageMark) {
                    let k = j + pageMark.count
                    let next: UInt8 = k < n ? bytes[k] : 0x20
                    let isLetter = (next >= 0x41 && next <= 0x5A) || (next >= 0x61 && next <= 0x7A)
                    if !isLetter { count += 1 }
                }
                i += typeMark.count
            } else {
                i += 1
            }
        }
        if count > 0 { return count }
        let basis = size > 0 ? size : n
        return max(1, (basis + 249_999) / 250_000)
    }

    // MARK: Şık kodları ve yönerge

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

    private static func example(_ codes: [(letter: String, word: String)]) -> (sentence: String, letter: String) {
        if codes.isEmpty { return ("Birinci sorunun cevabı D, altmış sekiz.", "D") }
        if let d = codes.first(where: { $0.letter == "D" }) {
            return ("Birinci sorunun cevabı \(d.word), altmış sekiz.", "D")
        }
        return ("Birinci sorunun cevabı \(codes[0].word), altmış sekiz.", codes[0].letter)
    }

    private static func rule8(_ codes: [(letter: String, word: String)]) -> String {
        let ex = example(codes)
        let sik: String
        if codes.isEmpty {
            sik = "Şık harfini söyle ve ardından şıkkın metnini ya da değerini belgede yazdığı gibi eksiksiz söyle; harfi ASLA tek başına söyleme "
                + "(şıkta hiç metin yoksa yalnız harf yeter). "
        } else {
            let table = codes.map { "\($0.letter) = \($0.word)" }.joined(separator: ", ")
            sik = "Şık harfini (A, B, C…) SÖYLEME; harfin yerine kullanıcının şık kodunu söyle: \(table) (kod sözcüğünü aynen, büyük harfle yaz). "
                + "Kod sözcüğünden sonra virgül koy ve doğru şıkkın metnini ya da değerini belgede yazdığı gibi eksiksiz söyle. "
                + "Şıkta hiç metin yoksa (yalnız harf ya da şekil) yalnız kod sözcüğünü söyle; kodu tanımlı olmayan bir harfi harfin kendisiyle söyle. "
        }
        var text = "8. Kullanıcı belgelerdeki numaralı bir soruyu istediğinde ('beşinci soruyu cevapla', '5. soru'), o soruyu belgelerde "
        text += "bul, çöz ve cevabı tam şu kalıpla ver: '\(ex.sentence)' (doğru şık \(ex.letter) ve değeri 68 ise; örnekteki sözcükleri ve sayıyı asla "
        text += "kendi cevabına kopyalama, cevabı yalnızca belgeden al). Sıra sayısını yazıyla yaz (birinci, ikinci, … beşinci, onuncu, "
        text += "on birinci). \(sik)Şık birden çok parçadan oluşuyorsa (ad, sayı, birim, tarih…) hepsini oku; sayıları okunuşuyla yazıyla yaz. "
        text += "Bu kalıpta 'şıkkıdır' gibi ek sözcük, gerekçe, belge adı ya da sayfa numarası ekleme; kullanıcı 'neden' diye sorarsa kısaca "
        text += "açıkla. Aynı numaralı soru birden çok belgede ya da kitapçıkta varsa tahmin etme, hangisini kastettiğini sor "
        text += "(örn. 'Birden fazla belgede 5. soru var, hangisi?'). Soruyu bulamazsan ya da şıklar okunamıyorsa tahmin etme, bunu söyle. "
        text += "Cevabın sonuna 'sonraki sorunuzu bekliyorum' gibi bir cümle ekleme; uygulama onu kendisi söyler."
        return text
    }

    private static func rule12(_ codes: [(letter: String, word: String)]) -> String {
        let ex = example(codes)
        var text = "12. Kullanıcı soruları toplu cevaplatmak isterse ('ilk on soruyu cevapla', 'sıradaki on soruyu cevapla', 'sonraki on soru', 'devam', 'on birden yirmiye "
        text += "kadar'), belgelerdeki numaralı soruları sıra numarasına göre onarlı gruplar hâlinde cevapla. İlk istekte 1'den 10'a kadar; "
        text += "'sıradaki', 'sonraki', 'devam', 'diğer on' denirse bu konuşmada en son verdiğin grubun hemen devamından 10 soru ver (önceki cevaplarına "
        text += "bak; kullanıcı aralık söylerse onu uygula). Uygulama sana 'Toplu cevapta en son verilen soru numarası: N' notunu verebilir: "
        text += "'sıradaki', 'sonraki' ya da 'devam' denirse konuşma geçmişine değil bu nota bakıp N+1'den başla (oturum kapanıp açılmış, internet kopmuş "
        text += "olabilir; N sıfırsa kullanıcıya hiçbir grup ulaşmamıştır, 1'den başla). Toplu cevap verdiğinde 'son_soru' alanına verdiğin gruptaki en büyük soru numarasını yaz; toplu cevap değilse 0 yaz. "
        text += "Her soru için 8. kuraldaki kalıpla ayrı bir cümle kur ('\(ex.sentence)' gibi). "
        text += "Soruları sırayla say, aralara başka söz ve gerekçe ekleme; 1. kuraldaki cümle sınırı bu durumda geçerli değildir. "
        text += "Okunamayan ya da belgelerde bulunamayan soru için 'Üçüncü soru okunamadı.' de ve sıraya devam et. Grubun sonunda hangi "
        text += "numaraya kadar geldiğini söyle ('Onuncu soruya kadar bitti.'); belgelerdeki son soruya gelince bunu belirt."
        return text
    }

    private static func rule13() -> String {
        var text = "13. Kullanıcı belirli soruların cevabını isterse ('üçüncü, sekizinci ve on beşinci soruların cevaplarını ver', '3, 8 ve 15. sorular'), "
        text += "yalnızca o soruları, istenen sırayla ve 8. kuraldaki kalıpla cevapla (her soru ayrı cümle; aralara başka söz ekleme). Önce konuşma "
        text += "geçmişine bak: istenen sorunun cevabını bu konuşmada zaten verdiysen aynı cevabı geçmişten AYNEN yeniden oku, belgeden yeniden çözme. "
        text += "Geçmişte olmayan soruları belgelerden bul ve çöz. Hepsini aynı yanıtta ver; hangisinin geçmişten, hangisinin yeni hazırlandığını söyleme. "
        text += "Bu durumda 'son_soru' alanına 0 yaz (toplu cevap sırasını değiştirme). Kullanıcı son yanıtını yeniden dinlemek isterse "
        text += "('son yanıtı tekrarla', 'bir daha söyle') son cevabını geçmişten aynen yinele ve 'son_soru' alanına 0 yaz."
        return text
    }

    /// Sistem yönergesi; codesText: şık kodları ("A=ADANA, B=BURSA…"; boş = harfin kendisi okunur)
    static func systemPrompt(codesText: String) -> String {
        let codes = parseOptionCodes(codesText)
        return GeminiConfig.systemTemplate
            .replacingOccurrences(of: "@@KURAL8@@", with: rule8(codes))
            .replacingOccurrences(of: "@@KURAL12@@", with: rule12(codes))
            .replacingOccurrences(of: "@@KURAL13@@", with: rule13())
    }

    // MARK: "Son yanıtı tekrarla" tanıma

    /// Küçük harf + Türkçe harfleri ASCII'ye indirger (karşılaştırma için)
    static func foldTR(_ text: String) -> String {
        let map: [Character: Character] = ["ç": "c", "ğ": "g", "ı": "i", "ö": "o", "ş": "s", "ü": "u", "â": "a", "î": "i", "û": "u"]
        let lowered = text.replacingOccurrences(of: "İ", with: "i").replacingOccurrences(of: "I", with: "ı").lowercased()
        var out = ""
        for ch in lowered {
            if let m = map[ch] {
                out.append(m)
            } else if ch.isASCII && (ch.isLetter || ch.isNumber) {
                out.append(ch)
            } else {
                out.append(" ")
            }
        }
        return out.split(separator: " ").joined(separator: " ")
    }

    private static let numberWords: Set<String> = ["iki", "uc", "dort", "bes", "alti", "yedi", "sekiz", "dokuz", "yirmi", "otuz", "kirk", "elli"]

    /// Rakam ya da yazıyla sayı/sıra sayısı ('3', 'üç', 'üçüncü', 'sekizinci'): belirli bir soruyu işaret eder. 'sonuncu' (son) sayılmaz.
    static func isNumberWord(_ w: String) -> Bool {
        if w.isEmpty { return false }
        if w.allSatisfy({ $0.isNumber }) || numberWords.contains(w) { return true }
        return (w.hasSuffix("inci") || w.hasSuffix("uncu")) && w != "sonuncu"
    }

    /// 'Son yanıtı tekrarla', 'bir daha söyle', 'yeniden oku' gibi isteği tanır. Yeni bir soruyu ('ilk on soruyu tekrar cevapla',
    /// 'sıradaki on soru') tekrar isteği saymaz.
    static func isRepeatRequest(_ text: String) -> Bool {
        let words = foldTR(text).split(separator: " ").map(String.init)
        if words.isEmpty || words.count > 9 { return false }
        let notRepeat = ["cevapla", "yanitla", "sirad", "sonrak", "ilk", "kadar", "arasi", "baslat"]
        if words.contains(where: { w in notRepeat.contains(where: { w.hasPrefix($0) }) || isNumberWord(w) }) { return false }
        let repeating = words.contains(where: { $0.hasPrefix("tekrar") || $0.hasPrefix("yinele") })
        let again = words.contains("daha") && words.contains("bir")
        let redo = words.contains("yeniden") || words.contains("bastan")
        if !(repeating || again || redo) { return false }
        if repeating || again { return true }
        let verbs = ["oku", "soyle", "dinle", "anlat", "ver", "yinele", "tekrar"]
        return words.contains(where: { w in verbs.contains(where: { w.hasPrefix($0) }) })
    }

    // MARK: İstek kurma

    static func allRemote(_ docs: [GeminiDoc]) -> Bool {
        return !docs.isEmpty && docs.allSatisfy { !$0.uri.isEmpty }
    }

    /// Dosya adresiyle (Files API) verilen belgeleri iki turluk bir giriş olarak dizer: kullanıcı (belgeler) + model (onay).
    /// Aynı dizi hem açık önbelleğe hem de önbelleksiz isteğe konur.
    static func docsTurns(_ docs: [GeminiDoc]) -> [[String: Any]] {
        var parts: [[String: Any]] = []
        for (n, doc) in docs.enumerated() {
            parts.append(["text": "Belge \(n + 1): \(doc.name)"])
            parts.append(["fileData": ["mimeType": "application/pdf", "fileUri": doc.uri]])
        }
        parts.append(["text": GeminiConfig.docsIntro])
        let ack = modelTurnText(GeminiTurn(question: "", answer: GeminiConfig.docsAck))
        return [["role": "user", "parts": parts], ["role": "model", "parts": [["text": ack]]]]
    }

    /// cachedContents oluşturma isteği: sistem yönergesi + dosya adresli belgeler
    static func cacheRequestObject(model: String, docs: [GeminiDoc], system: String, ttl: Int) -> [String: Any] {
        return ["model": "models/" + model, "contents": docsTurns(docs),
                "systemInstruction": ["parts": [["text": system]]], "ttl": "\(ttl)s"]
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

    /// Belgeler Files API'ye yüklenmişse dosya adresiyle, değilse inline gönderilir (ilk kullanıcı turuna eklenir).
    /// cached: açık önbelleğin adı ("cachedContents/…"): belgeler ve sistem yönergesi önbellekte olduğundan isteğe konmaz.
    /// batchLast > 0: uygulamanın tuttuğu "toplu cevapta en son verilen soru numarası" notu soruya eklenir.
    static func requestObject(questionText: String, audioWAV: Data?, docs: [GeminiDoc],
                              history: [GeminiTurn], system: String = GeminiConfig.systemPrompt,
                              cached: String = "", batchLast: Int = 0) -> [String: Any] {
        let remote = cached.isEmpty && allRemote(docs)
        var contents: [[String: Any]] = []
        if remote { contents.append(contentsOf: docsTurns(docs)) }
        for turn in history {
            contents.append(["role": "user", "parts": [["text": turn.question]]])
            contents.append(["role": "model", "parts": [["text": modelTurnText(turn)]]])
        }
        var current: [[String: Any]]
        if let wav = audioWAV {
            current = [["inlineData": ["mimeType": "audio/wav", "data": wav.base64EncodedString()]],
                       ["text": GeminiConfig.audioInstruction]]
        } else {
            current = [["text": questionText]]
        }
        if batchLast > 0 {
            current.append(["text": GeminiConfig.batchNote + "\(batchLast)."])
        } else if history.contains(where: { $0.batch > 0 }) {
            current.append(["text": GeminiConfig.batchNoteNone])
        }
        contents.append(["role": "user", "parts": current])

        if cached.isEmpty && !remote && !docs.isEmpty {
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
        var body: [String: Any] = [
            "contents": contents,
            "generationConfig": [
                "temperature": 0.3,
                "responseMimeType": "application/json",
                "responseSchema": GeminiConfig.responseSchema,
                "maxOutputTokens": 16384
            ] as [String: Any]
        ]
        if cached.isEmpty {
            body["systemInstruction"] = ["parts": [["text": system]]]
        } else {
            body["cachedContent"] = cached
        }
        return body
    }

    static func buildRequest(questionText: String, audioWAV: Data?, docs: [GeminiDoc],
                             history: [GeminiTurn], system: String = GeminiConfig.systemPrompt,
                             cached: String = "", batchLast: Int = 0, thinking: String? = nil) throws -> Data {
        let object = applyThinking(requestObject(questionText: questionText, audioWAV: audioWAV, docs: docs, history: history,
                                                 system: system, cached: cached, batchLast: batchLast), level: thinking)
        return try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
    }

    private static func modelTurnText(_ turn: GeminiTurn) -> String {
        let object: [String: Any] = ["soru": turn.question, "cevap": turn.answer, "kapat": false, "model_degistir": false,
                                     "son_soru": turn.batch]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return turn.answer
    }

    // MARK: Cevap ayrıştırma

    private static func intValue(_ any: Any?) -> Int {
        if let text = any as? String { return Int(text.trimmed) ?? 0 }
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
        answer.cachedTokens = intValue(usage["cachedContentTokenCount"])
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
           json["cevap"] != nil {
            // "cevap" boşsa soru olmayan ses (gürültü, başkalarının sohbeti) demektir; ham JSON okunmasın
            answer.answer = ((json["cevap"] as? String) ?? "").trimmed
            answer.question = ((json["soru"] as? String) ?? "").trimmed
            answer.close = (json["kapat"] as? Bool) == true
            answer.switchModel = (json["model_degistir"] as? Bool) == true
            answer.lastQuestion = min(max(intValue(json["son_soru"]), 0), 100_000)
        } else if cleaned.trimmed.hasPrefix("{") {
            // JSON gibi ama bozuk/yarım (genelde uzunluk sınırı): ham metin okunmasın, kurtarılabilen cevap okunsun
            guard let saved = salvageAnswer(cleaned) else {
                throw GeminiError("Gemini cevabı yarım kaldı. Soruyu yeniden sorun.", .empty)
            }
            answer.question = saved.question
            answer.answer = saved.answer + (finish == "MAX_TOKENS" ? truncatedNote : "")
            tlog("[gemini] bozuk/yarım JSON'dan cevap kurtarıldı (\(finish.isEmpty ? "?" : finish))")
        }
        return answer
    }

    static let truncatedNote = " Cevabın devamı uzunluk sınırı nedeniyle kesildi."

    /// Tırnaksız JSON dizgesi içeriğini çözer; sonda yarım kalmış kaçış (\ ya da \u12) varsa onu keser.
    private static func decodeJSONString(_ raw: String) -> String? {
        var text = raw
        for _ in 0..<2 {
            if let data = ("\"" + text + "\"").data(using: .utf8),
               let value = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? String {
                return value
            }
            guard let cut = text.lastIndex(of: "\\") else { return nil }
            text = String(text[text.startIndex..<cut])
        }
        return nil
    }

    private static func firstGroup(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// Yarım kalmış JSON'dan "cevap" ve "soru" metnini kurtarır; cevap yoksa nil.
    static func salvageAnswer(_ text: String) -> (question: String, answer: String)? {
        guard let rawAnswer = firstGroup("\"cevap\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)", in: text),
              let answer = decodeJSONString(rawAnswer)?.trimmed, !answer.isEmpty else { return nil }
        let question = firstGroup("\"soru\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"", in: text).flatMap { decodeJSONString($0) } ?? ""
        return (question.trimmed, answer)
    }

    /// Tek sayfa fotoğrafını metne çeviren istek (görsel önce, yönerge sonra)
    static func buildOCRRequest(jpeg: Data) throws -> Data {
        let object: [String: Any] = [
            "contents": [["role": "user", "parts": [
                ["inlineData": ["mimeType": "image/jpeg", "data": jpeg.base64EncodedString()]],
                ["text": GeminiConfig.ocrPrompt]
            ]]],
            "generationConfig": ["temperature": 0.0, "maxOutputTokens": 16384]
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
    }

    /// OCR cevabındaki kod çerçevesini ve "[yazı yok]" işaretini atar
    static func cleanOCRText(_ text: String) -> String {
        let cleaned = stripFence(text).trimmed
        let marker = cleaned.lowercased()
        if marker == "[yazı yok]" || marker == "[yazi yok]" { return "" }
        return cleaned
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

/// Soru sorma arayüzü (sohbet mantığı sahte istemciyle sınanabilsin diye).
protocol GeminiAsking: AnyObject {
    /// cached: açık önbellek adı (belgeler önbellekte); boş = önbelleksiz
    func ask(questionText: String, audioWAV: Data?, docs: [GeminiDoc], history: [GeminiTurn], cached: String) async throws -> GeminiAnswer
    /// Yedek model (nil = seçili model) ve sunucu hatasında yeniden deneme sayısı (nil = varsayılan) belirterek sorar
    func ask(questionText: String, audioWAV: Data?, docs: [GeminiDoc], history: [GeminiTurn], cached: String,
             model: String?, serverRetries: Int?) async throws -> GeminiAnswer
    /// Başka profilin anahtarıyla (nil = seçili profilin anahtarı) ve en çok `timeout` sn cevap bekleyerek sorar (model zinciri)
    func ask(questionText: String, audioWAV: Data?, docs: [GeminiDoc], history: [GeminiTurn], cached: String,
             model: String?, serverRetries: Int?, key: String?, timeout: TimeInterval?) async throws -> GeminiAnswer
    /// Seçili modelin adı
    var currentModel: String { get }
    /// Seçili model yoğunken ya da kotası doluyken denenecek yedek modeller (hesabın gerçek model listesinden); alınamazsa boş
    func fallbackModels() async -> [String]
    /// Kısa sesi belgesiz yazıya döker ("son yanıtı tekrarla" ön kontrolü)
    func transcribe(audioWAV: Data) async throws -> String
}

extension GeminiAsking {
    func transcribe(audioWAV: Data) async throws -> String { return "" }
    var currentModel: String { return "" }
    func fallbackModels() async -> [String] { return [] }
    func ask(questionText: String, audioWAV: Data?, docs: [GeminiDoc], history: [GeminiTurn], cached: String,
             model: String?, serverRetries: Int?) async throws -> GeminiAnswer {
        return try await ask(questionText: questionText, audioWAV: audioWAV, docs: docs, history: history, cached: cached)
    }
    func ask(questionText: String, audioWAV: Data?, docs: [GeminiDoc], history: [GeminiTurn]) async throws -> GeminiAnswer {
        return try await ask(questionText: questionText, audioWAV: audioWAV, docs: docs, history: history, cached: "")
    }
    func ask(questionText: String, audioWAV: Data?, docs: [GeminiDoc], history: [GeminiTurn], cached: String,
             model: String?, serverRetries: Int?, key: String?, timeout: TimeInterval?) async throws -> GeminiAnswer {
        return try await ask(questionText: questionText, audioWAV: audioWAV, docs: docs, history: history, cached: cached,
                             model: model, serverRetries: serverRetries)
    }
}

/// Files API'ye yüklenmiş bir dosya
struct RemoteFile: Equatable {
    var name: String
    var uri: String
    var state: String
}

/// Belgeleri Gemini'nin hafızasına koyan çağrılar (Files API + açık önbellek); hafıza mantığı sahte uzaktan sınansın diye ayrı arayüz.
protocol GeminiRemote: AnyObject {
    /// API anahtarının kısa parmak izi (dosyalar anahtarın projesine aittir)
    var keyFingerprint: String { get }
    /// Önbellek imzasına girer: model + anahtar + yönerge
    var cacheIdentity: String { get }
    func uploadFile(name: String, data: Data) async throws -> RemoteFile
    /// Dosya bilgisi; yoksa ya da erişilemiyorsa nil
    func getFile(name: String) async throws -> RemoteFile?
    func waitActive(_ file: RemoteFile) async throws -> RemoteFile
    func createCache(docs: [GeminiDoc]) async throws -> String
    func touchCache(_ name: String) async throws
    func deleteCache(_ name: String) async
}

/// Gerçek istemci: URLSession ile generateContent çağırır.
final class GeminiClient: GeminiAsking, GeminiRemote {
    private let session: URLSession
    private let baseURL: String
    private let keyProvider: () -> String
    private let modelProvider: () -> String
    private let codesProvider: () -> String
    private let batchProvider: () -> Int
    let thinkingProvider: () -> String
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
         codes: @escaping () -> String = { GeminiConfig.defaultOptionCodes },
         batchLast: @escaping () -> Int = { 0 },
         thinking: @escaping () -> String = { "auto" },
         sleep: @escaping (TimeInterval) async -> Void = { seconds in
             try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
         }) {
        self.session = session ?? GeminiClient.makeSession()
        self.baseURL = baseURL
        self.keyProvider = key
        self.modelProvider = model
        self.codesProvider = codes
        self.batchProvider = batchLast
        self.thinkingProvider = thinking
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

    private var systemPrompt: String { return GeminiSupport.systemPrompt(codesText: codesProvider()) }

    func ask(questionText: String, audioWAV: Data?, docs: [GeminiDoc], history: [GeminiTurn], cached: String) async throws -> GeminiAnswer {
        return try await ask(questionText: questionText, audioWAV: audioWAV, docs: docs, history: history, cached: cached,
                             model: nil, serverRetries: nil)
    }

    var currentModel: String { return model }

    func ask(questionText: String, audioWAV: Data?, docs: [GeminiDoc], history: [GeminiTurn], cached: String,
             model overrideModel: String?, serverRetries: Int?) async throws -> GeminiAnswer {
        return try await ask(questionText: questionText, audioWAV: audioWAV, docs: docs, history: history, cached: cached,
                             model: overrideModel, serverRetries: serverRetries, key: nil, timeout: nil)
    }

    func ask(questionText: String, audioWAV: Data?, docs: [GeminiDoc], history: [GeminiTurn], cached: String,
             model overrideModel: String?, serverRetries: Int?, key overrideKey: String?, timeout: TimeInterval?) async throws -> GeminiAnswer {
        if questionText.trimmed.isEmpty && audioWAV == nil {
            throw GeminiError("Soru boş.", .error)
        }
        var useModel = model
        if let m = overrideModel, !m.trimmed.isEmpty { useModel = m.trimmed }
        let body = try GeminiSupport.buildRequest(questionText: questionText, audioWAV: audioWAV, docs: docs, history: history,
                                                  system: systemPrompt, cached: cached, batchLast: batchProvider(),
                                                  thinking: GeminiSupport.thinkingLevel(model: useModel, setting: thinkingProvider()))
        let name = useModel.addingPercentEncoding(withAllowedCharacters: GeminiClient.pathAllowed) ?? useModel
        let object = try await post(path: "/models/\(name):generateContent", body: body,
                                    serverRetries: serverRetries ?? GeminiClient.askServerRetries,
                                    key: overrideKey, timeout: timeout, model: useModel)
        return try GeminiSupport.parseAnswer(object)
    }

    func fallbackModels() async -> [String] {
        do {
            let names = try await listModels()
            return GeminiSupport.pickFallbackModels(names, current: model)
        } catch {
            tlog("[gemini] yedek model listesi alınamadı: \(error.localizedDescription)")
            return []
        }
    }

    /// Kısa bir sesi (belgesiz) yazıya döker: 'son yanıtı tekrarla' gibi isteklerin tekrar mı yeni soru mu olduğunu anlamak için.
    /// Belge göndermediğinden birkaç yüz jetona mal olur.
    func transcribe(audioWAV: Data) async throws -> String {
        let schema: [String: Any] = ["type": "OBJECT", "properties": ["soru": ["type": "STRING"]], "required": ["soru"]]
        let config: [String: Any] = ["temperature": 0, "responseMimeType": "application/json", "maxOutputTokens": 256,
                                     "responseSchema": schema]
        let audioPart: [String: Any] = ["inlineData": ["mimeType": "audio/wav", "data": audioWAV.base64EncodedString()]]
        let textPart: [String: Any] = ["text": GeminiConfig.transcribeMarker]
        let turn: [String: Any] = ["role": "user", "parts": [audioPart, textPart]]
        let object: [String: Any] = [
            "systemInstruction": ["parts": [["text": GeminiConfig.transcribeSystem]]],
            "contents": [turn],
            "generationConfig": config
        ]
        let body = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        let name = model.addingPercentEncoding(withAllowedCharacters: GeminiClient.pathAllowed) ?? model
        let result = try await post(path: "/models/\(name):generateContent", body: body)
        guard let obj = result as? [String: Any],
              let cand = (obj["candidates"] as? [[String: Any]])?.first,
              let parts = (cand["content"] as? [String: Any])?["parts"] as? [[String: Any]] else { return "" }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        guard let data = GeminiSupport.stripFence(text).data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "" }
        return ((json["soru"] as? String) ?? "").trimmed
    }

    /// Sayfa fotoğrafındaki yazıyı okur (cihazdaki OCR'dan çok daha doğru). Yazı yoksa boş metin döner.
    func ocrImage(_ jpeg: Data) async throws -> String {
        let body = try GeminiSupport.buildOCRRequest(jpeg: jpeg)
        let name = model.addingPercentEncoding(withAllowedCharacters: GeminiClient.pathAllowed) ?? model
        let object = try await post(path: "/models/\(name):generateContent", body: body)
        return GeminiSupport.cleanOCRText(try GeminiSupport.parseAnswer(object).answer)
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

    /// Deneme sınavı görevleri (ExamGemini.swift): verilen (seçili ya da yedek) modele generateContent isteği gönderir
    func postTask(model name: String, body: Data, serverRetries: Int) async throws -> Any {
        let escaped = name.addingPercentEncoding(withAllowedCharacters: GeminiClient.pathAllowed) ?? name
        return try await post(path: "/models/\(escaped):generateContent", body: body, serverRetries: serverRetries)
    }

    /// Video analizi (GeminiVideo.swift): verilen anahtar ve modelle tek seferlik generateContent; `timeout` nil değilse en çok o kadar bekler
    func postVideoTask(model name: String, key: String, body: Data, timeout: TimeInterval?) async throws -> Any {
        let escaped = name.addingPercentEncoding(withAllowedCharacters: GeminiClient.pathAllowed) ?? name
        return try await post(path: "/models/\(escaped):generateContent", body: body, serverRetries: 1, key: key,
                              timeout: timeout, model: name)
    }

    /// Sunucu hatalarında (500/502/503/504) yeniden denemeden önce beklenecek süreler (sn). Gemini'nin geçici
    /// "yoğunluk" (503) hataları genelde birkaç saniyede geçer.
    static let serverBackoff: [TimeInterval] = [1.5, 4.0, 8.0]
    /// Soru sorarken sunucu hatasında en çok bu kadar yeniden deneme yapılır
    static let askServerRetries = 3

    /// POST + yeniden deneme: ağ hatasında bir kez (1,5 sn sonra); 500/502/503/504'te `serverRetries` kez, artan aralıkla
    private struct Reply: @unchecked Sendable { let value: Any? }

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
}

// MARK: - Files API ve açık önbellek (Gemini hafızası)

extension GeminiClient {
    var keyFingerprint: String { return GeminiMemory.fingerprint(keyProvider().trimmed) }

    var cacheIdentity: String {
        return [model, GeminiMemory.fingerprint(keyProvider().trimmed), GeminiMemory.fingerprint(systemPrompt)].joined(separator: "|")
    }

    private func requireKey() throws -> String {
        let key = keyProvider().trimmed
        guard !key.isEmpty else {
            throw GeminiError("Gemini API anahtarı girilmemiş. Ayarlardan yapıştırın.", .key)
        }
        return key
    }

    /// İstek gönderir; ağ hatasında ve 500/502/503/504'te bir kez yeniden dener (1,5 sn sonra).
    private func send(_ request: URLRequest, body: Data?) async throws -> (status: Int, data: Data, response: HTTPURLResponse) {
        var attempt = 0
        while true {
            do {
                let result: (Data, URLResponse)
                if let body = body {
                    result = try await session.upload(for: request, from: body)
                } else {
                    result = try await session.data(for: request)
                }
                guard let http = result.1 as? HTTPURLResponse else {
                    throw GeminiError("Gemini'den anlaşılmaz yanıt geldi.", .error)
                }
                if [500, 502, 503, 504].contains(http.statusCode) && attempt < 1 {
                    attempt += 1
                    await sleep(1.5)
                    continue
                }
                return (http.statusCode, result.0, http)
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
        }
    }

    private func checked(_ status: Int, _ data: Data) throws -> [String: Any] {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if (200..<300).contains(status) { return json }
        let (kind, message) = GeminiSupport.describeError(status: status, json: GeminiSupport.errorObject(from: data), model: model)
        tlog("[gemini] HTTP \(status): \(message)")
        throw GeminiError(message, kind, status: status)
    }

    /// JSON gövdeli / gövdesiz çağrı (cachedContents, files)
    private func call(_ method: String, path: String, body: [String: Any]?, timeout: TimeInterval = 60) async throws -> [String: Any] {
        let key = try requireKey()
        guard let url = URL(string: baseURL + path) else {
            throw GeminiError("Gemini adresi geçersiz.", .error)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        var payload: Data?
        if let body = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            payload = try JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])
        }
        let result = try await send(request, body: payload)
        return try checked(result.status, result.data)
    }

    private var uploadURLString: String {
        var base = baseURL
        if base.hasSuffix("/v1beta") { base = String(base.dropLast("/v1beta".count)) }
        return base + "/upload/v1beta/files"
    }

    /// Dosyayı Files API'ye yükler (kesintisiz-devam eden protokol, tek parça).
    func uploadFile(name: String, data: Data) async throws -> RemoteFile {
        let key = try requireKey()
        guard let startURL = URL(string: uploadURLString) else {
            throw GeminiError("Gemini adresi geçersiz.", .error)
        }
        var start = URLRequest(url: startURL)
        start.httpMethod = "POST"
        start.timeoutInterval = 60
        start.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        start.setValue(String(data.count), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        start.setValue("application/pdf", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        let meta = try JSONSerialization.data(withJSONObject: ["file": ["display_name": String(name.prefix(120))]])
        let first = try await send(start, body: meta)
        _ = try checked(first.status, first.data)
        guard let target = first.response.value(forHTTPHeaderField: "x-goog-upload-url"), let targetURL = URL(string: target) else {
            throw GeminiError("Gemini dosya yükleme adresi vermedi.", .error)
        }
        var finish = URLRequest(url: targetURL)
        finish.httpMethod = "POST"
        finish.timeoutInterval = 300
        finish.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        finish.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        finish.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        let done = try await send(finish, body: data)
        let json = try checked(done.status, done.data)
        guard let file = json["file"] as? [String: Any], let fileName = file["name"] as? String, let uri = file["uri"] as? String else {
            throw GeminiError("Gemini dosya yüklemeye anlaşılmaz yanıt verdi.", .error)
        }
        return RemoteFile(name: fileName, uri: uri, state: (file["state"] as? String) ?? "ACTIVE")
    }

    func getFile(name: String) async throws -> RemoteFile? {
        do {
            let json = try await call("GET", path: "/" + name, body: nil, timeout: 30)
            return RemoteFile(name: (json["name"] as? String) ?? name, uri: (json["uri"] as? String) ?? "",
                              state: (json["state"] as? String) ?? "ACTIVE")
        } catch let e as GeminiError where [400, 403, 404].contains(e.status) {
            return nil
        }
    }

    /// Yüklenen dosya kullanıma hazır (ACTIVE) olana dek bekler (en çok 180 sn).
    func waitActive(_ file: RemoteFile) async throws -> RemoteFile {
        var current = file
        var waited = 0.0
        while current.state != "ACTIVE" {
            if current.state == "FAILED" || waited > 180 {
                throw GeminiError("Gemini yüklenen belgeyi işleyemedi (\(current.state)).", .error)
            }
            await sleep(1.0)
            waited += 1.0
            guard let fresh = try await getFile(name: current.name) else {
                throw GeminiError("Gemini yüklenen belgeyi bulamadı.", .error)
            }
            current = fresh
        }
        return current
    }

    /// Sistem yönergesi + belgelerden önbellek kurar. Dönüş: önbellek adı.
    func createCache(docs: [GeminiDoc]) async throws -> String {
        let body = GeminiSupport.cacheRequestObject(model: model, docs: docs, system: systemPrompt, ttl: GeminiConfig.cacheTTL)
        let json = try await call("POST", path: "/cachedContents", body: body, timeout: 120)
        guard let name = json["name"] as? String, !name.isEmpty else {
            throw GeminiError("Gemini önbellek adı vermedi.", .error)
        }
        return name
    }

    /// Önbelleğin ömrünü uzatır
    func touchCache(_ name: String) async throws {
        _ = try await call("PATCH", path: "/" + name + "?updateMask=ttl", body: ["ttl": "\(GeminiConfig.cacheTTL)s"], timeout: 30)
    }

    func deleteCache(_ name: String) async {
        do {
            _ = try await call("DELETE", path: "/" + name, body: nil, timeout: 30)
        } catch {
            tlog("[gemini] önbellek silinemedi: \(error.localizedDescription)")
        }
    }
}
