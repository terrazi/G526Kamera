import Foundation

/// Gemini model profili. Ücretli / ücretsiz olmak modelin değil API anahtarının özelliğidir (anahtarın bağlı olduğu
/// projenin faturalandırması), bu yüzden her profilin kendi anahtarı vardır; anahtar Keychain'de, burada tutulmaz.
struct GeminiProfile: Codable, Equatable {
    var name: String
    var model: String
    /// Anahtar ücretsiz katmandaysa işaretlenir (harcama sınırı dolunca yedek olarak bu profile geçilir)
    var free: Bool
}

/// Sohbetin / sesli seçimin gördüğü profil (anahtarla birlikte, 1'den başlayan yuva numarasıyla)
struct GeminiProfileInfo: Equatable {
    var slot: Int
    var name: String
    var model: String
    var key: String
    var free: Bool

    var usable: Bool { return !key.trimmed.isEmpty && !model.trimmed.isEmpty }
}

enum GeminiProfiles {
    /// Model profili sayısı: 4 (kullanıcı kararı 2026-11-13: Gemini 3.8 Flash çok yoğun, Gemini 2.5 Pro kaldırılmış; ikisi çıkarıldı)
    static let slotCount = 4
    /// Eski düzen: 6 yuva. Yeni düzene geçişte eski 1. (Gemini 3.8 Flash) ve 3. (Gemini 2.5 Pro) yuva atılır;
    /// eski 2., 4., 5., 6. yuva sırasıyla yeni 1.–4. yuva olur.
    static let legacySlotCount = 6
    static let legacyKeptSlots = [2, 4, 5, 6]
    /// Keychain'deki düzen işareti: yoksa kayıtlı anahtarlar eski düzendendir (silinir); uygulama silinip yeniden yüklense de Keychain'de kalır
    static let layoutMarker = "geminiLayout"
    static let layoutVersion = "4"

    /// Keychain adı: 1. profil eski "geminiApiKey" adını korur
    static func keychainName(slot: Int) -> String {
        return slot == 1 ? "geminiApiKey" : "geminiApiKey\(slot)"
    }

    /// Eski düzendeki yuva numarasının yeni düzendeki karşılığı (atılan yuva, sonraki korunan yuvaya gider: 1→1, 2→1, 3→2, 4→2, 5→3, 6→4)
    static func newSlot(fromLegacy old: Int) -> Int {
        for (i, kept) in legacyKeptSlots.enumerated() where old <= kept { return i + 1 }
        return slotCount
    }

    /// Eski 6 profilden yenilerini kurar (ad, model, ücretsiz bayrağı korunur); liste 6 değilse varsayılanlar
    static func profiles(fromLegacy saved: [GeminiProfile]) -> [GeminiProfile] {
        guard saved.count == legacySlotCount else { return defaults() }
        return migrated(legacyKeptSlots.map { saved[$0 - 1] })
    }

    /// Varsayılan sıra = model zincirinin sırası = PERFORMANS sırası (kota dolunca / hata olunca / cevap gecikince bir sonrakine geçilir):
    /// 1. Gemini 3.6 Flash, 2. Gemini 3.5 Flash-Lite, 3. Gemini 3.1 Flash-Lite (hepsi ücretsiz katmanda),
    /// 4. ücretli Gemini 3.1 Flash-Lite (kendi ücretli anahtarı; ucuz: ≈0,25 $ / 1,50 $ milyon belirteç; günlük sınırı yok, en sonda). Kullanıcı Ayarlardan ya da "model değiştir" ile değiştirir.
    static let defaultFlashModel = "gemini-3.6-flash"
    static let defaultLiteModel = "gemini-3.5-flash-lite"
    static let defaultOldLiteModel = "gemini-3.1-flash-lite"
    static let defaultNames = ["Gemini 3.6 Flash", "Gemini 3.5 Flash-Lite", "Gemini 3.1 Flash-Lite", "Ücretli Gemini 3.1 Flash-Lite"]

    static func defaults() -> [GeminiProfile] {
        return [GeminiProfile(name: defaultNames[0], model: defaultFlashModel, free: true),
                GeminiProfile(name: defaultNames[1], model: defaultLiteModel, free: true),
                GeminiProfile(name: defaultNames[2], model: defaultOldLiteModel, free: true),
                GeminiProfile(name: defaultNames[3], model: defaultOldLiteModel, free: false)]
    }

    /// Kaydedilmiş profillerde eksik yuvalar varsayılanla tamamlanır, boş kalan modeller varsayılanla dolar (anahtar girilene kadar etkisizdir);
    /// boş ya da "Model N" adı varsayılan adla yenilenir. Kullanıcının yazdığı model ve ad korunur.
    static func migrated(_ saved: [GeminiProfile]) -> [GeminiProfile] {
        var list = Array(saved.prefix(slotCount))
        let defs = defaults()
        while list.count < defs.count { list.append(defs[list.count]) }
        for i in list.indices where saved.indices.contains(i) && list[i].model.trimmed.isEmpty {
            list[i].model = defs[i].model
            list[i].free = defs[i].free
            let name = list[i].name.trimmed
            if name.isEmpty || name == "Model \(i + 1)" { list[i].name = defs[i].name }
        }
        return list
    }

    /// Hata iletilerinde anahtarın kendisini göstermeden hangi anahtarın kullanıldığını tanıtır: "AIza…x7Qd, 39 karakter"
    static func keyHint(_ key: String) -> String {
        let k = key.trimmed
        if k.isEmpty { return "anahtar boş" }
        if k.count <= 8 { return "\(k.count) karakter" }
        return "\(k.prefix(4))…\(k.suffix(4)), \(k.count) karakter"
    }

    /// Yapıştırılan anahtarda bilinen hatalar (boşluk, tırnak, kırpılmış ya da başka bir şey yapıştırılmış); sorun yoksa nil.
    /// Eski AI Studio anahtarları "AIza" ile başlar ve 39 karakterdir; yenileri "AQ." ile başlar.
    static func keyShapeProblem(_ key: String) -> String? {
        let k = key.trimmed
        if k.isEmpty { return nil }
        if k.contains(where: { $0.isWhitespace }) { return "Anahtarın içinde boşluk ya da satır sonu var; tek parça yapıştırın." }
        if k.contains(where: { "\"'“”‘’`".contains($0) }) { return "Anahtarın içinde tırnak işareti var; tırnaksız yapıştırın." }
        // Google 2026'da AI Studio'da yeni "AQ." biçimli (kimlik doğrulama) anahtarlara geçti; uzunlukları sabit değildir
        if k.hasPrefix("AQ.") { return k.count < 20 ? "“AQ.” ile başlayan anahtar çok kısa; eksik yapışmış olabilir." : nil }
        if !k.hasPrefix("AIza") { return "AI Studio anahtarları “AIza” ya da “AQ.” ile başlar; bu başka bir şey olabilir." }
        if k.count != 39 { return "AI Studio anahtarı 39 karakterdir; bu \(k.count) karakter (eksik ya da fazla yapışmış olabilir)." }
        return nil
    }

    /// Profildeki "ücretsiz" anahtarının yazısı: anahtar türü neyse yazı da odur (anahtar kapalıyken "Ücretli")
    static func keyKindLabel(free: Bool) -> String {
        return free ? "Ücretsiz anahtar" : "Ücretli anahtar"
    }

    /// Panodan yapıştırılan metinden anahtarı ayıklar: metinde bir "AIza…" anahtarı varsa o alınır (başında "API key:" gibi
    /// sözcükler ya da tırnak olsa da); yoksa baştaki/sondaki boşluk ve tırnaklar atılır. Boşsa nil.
    static func cleanedKey(fromClipboard text: String?) -> String? {
        guard let text = text else { return nil }
        if let range = text.range(of: "AIza[0-9A-Za-z_\\-]{35}", options: .regularExpression) {
            return String(text[range])
        }
        if let range = text.range(of: "AQ\\.[0-9A-Za-z_.\\-]{20,}", options: .regularExpression) {
            return String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        let quotes = CharacterSet(charactersIn: "\"'“”‘’`")
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: quotes)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Yeni biçimli ("AQ.") anahtar Google'ın REST uç noktasında bazı hesaplarda reddedilebiliyor; anahtar hatasında bu bilgi eklenir
    static func keyFormatNote(key: String) -> String? {
        guard key.trimmed.hasPrefix("AQ.") else { return nil }
        return "Bu anahtar yeni “AQ.” biçiminde; Google bunu bazı hesaplarda reddediyor. Google Cloud Console’da Generative Language API’ye kısıtlı yeni bir anahtar (AIza…) oluşturmayı deneyin."
    }

    /// Google'ın yanıtı anahtarın kendisinin reddedildiği anlamına mı geliyor (yoksa anahtar geçmiş, başka bir şey takılmış mı)
    static func isKeyRejection(_ probe: KeyProbe) -> Bool {
        if probe.status == 401 || probe.status == 403 { return true }
        let low = probe.message.lowercased()
        return probe.status == 400 && (low.contains("api key") || low.contains("credential") || low.contains("api_key"))
    }

    private static func briefMessage(_ probe: KeyProbe) -> String {
        let text = probe.message.isEmpty ? "ileti yok" : String(probe.message.prefix(140))
        return "HTTP \(probe.status) – \(text)"
    }

    /// "Anahtarı dene" sonucu. `header` anahtarın başlıkla, `query` (yalnız başlık reddedilince denenir) adreste gönderilmesinin sonucudur.
    /// Google'ın 429 / 5xx / 404 gibi yanıtları anahtarın kabul edildiğini gösterir (kimliği doğrulanmadan bu yanıtlar gelmez).
    static func keyProbeText(model: String, key: String, header: KeyProbe, query: KeyProbe?) -> (ok: Bool, text: String) {
        func accepted(_ probe: KeyProbe, how: String) -> (ok: Bool, text: String)? {
            switch probe.status {
            case 200..<300: return (true, "✓ Anahtar ve model çalışıyor\(how).")
            case 429: return (true, "✓ Anahtar kabul edildi\(how), ama kota şu an dolu: \(briefMessage(probe))")
            case 500..<600: return (true, "✓ Anahtar kabul edildi\(how); model şu an yoğun (\(probe.status)), biraz sonra yine deneyin.")
            case 404: return (false, "✓ Anahtar kabul edildi\(how) ama “\(model.trimmed)” modeli bulunamadı. “Modelleri listele” ile doğru adı bulun.")
            default: return nil
            }
        }
        if let ok = accepted(header, how: "") { return ok }
        if header.status == 0 { return (false, "✗ İnternete ulaşılamadı: \(header.message)") }
        if let query = query, let ok = accepted(query, how: " (anahtar adreste gönderilince)") { return ok }
        if !isKeyRejection(header) {
            return (false, "✗ Google isteği kabul etmedi: \(briefMessage(header))")
        }
        var text = "✗ Google anahtarı reddetti. Başlıkla: \(briefMessage(header))"
        if let query = query { text += " · Adreste: " + (query.status == 0 ? query.message : briefMessage(query)) }
        text += "."
        if let note = keyFormatNote(key: key) { text += " " + note }
        return (false, text)
    }

    /// Anahtarı ve modeli dolu olan profiller (yuva sırasıyla)
    static func usable(_ list: [GeminiProfileInfo]) -> [GeminiProfileInfo] {
        return list.filter { $0.usable }
    }

    /// Seçili profil; boşsa ilk dolu profil, o da yoksa seçili yuva
    static func active(_ list: [GeminiProfileInfo], active: Int) -> GeminiProfileInfo {
        if let p = list.first(where: { $0.slot == active }), p.usable { return p }
        if let p = usable(list).first { return p }
        return list.first(where: { $0.slot == active }) ?? list.first
            ?? GeminiProfileInfo(slot: 1, name: defaultNames[0], model: GeminiConfig.defaultModel, key: "", free: false)
    }

    /// Aylık harcama sınırı dolunca geçilecek profil: şimdikisi ücretli olmalı, yedek ücretsiz ve kullanılabilir olmalı
    static func fallbackTarget(_ list: [GeminiProfileInfo], from current: GeminiProfileInfo, auto: Bool) -> GeminiProfileInfo? {
        guard auto, !current.free else { return nil }
        return usable(list).first(where: { $0.free && $0.slot != current.slot })
    }

    /// "202611" gibi ay anahtarı (yedeğe geçilen ayı hatırlamak için)
    static func monthKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d%02d", c.year ?? 0, c.month ?? 0)
    }
}
