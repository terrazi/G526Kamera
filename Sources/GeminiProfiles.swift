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
    static let slotCount = 6

    /// Keychain adı: 1. profil eski "geminiApiKey" adını korur
    static func keychainName(slot: Int) -> String {
        return slot == 1 ? "geminiApiKey" : "geminiApiKey\(slot)"
    }

    /// Varsayılan sıra = model zincirinin sırası = PERFORMANS sırası (kota dolunca / hata olunca / cevap gecikince bir sonrakine geçilir):
    /// 1. Gemini 3.8 Flash, 2. Gemini 3.6 Flash, 3. Gemini 2.5 Pro, 4. Gemini 3.5 Flash-Lite, 5. Gemini 3.1 Flash-Lite (hepsi ücretsiz katmanda),
    /// 6. ücretli Gemini 3.1 Flash-Lite (kendi ücretli anahtarı; ucuz: ≈0,25 $ / 1,50 $ milyon belirteç; günlük sınırı yok, en sonda). Kullanıcı Ayarlardan ya da "model değiştir" ile değiştirir.
    static let defaultSecondModel = "gemini-3.6-flash"
    static let defaultThirdModel = "gemini-2.5-pro"
    static let defaultLiteModel = "gemini-3.5-flash-lite"
    static let defaultOldLiteModel = "gemini-3.1-flash-lite"
    static let defaultNames = ["Gemini 3.8 Flash", "Gemini 3.6 Flash", "Gemini 2.5 Pro", "Gemini 3.5 Flash-Lite",
                               "Gemini 3.1 Flash-Lite", "Ücretli Gemini 3.1 Flash-Lite"]

    static func defaults() -> [GeminiProfile] {
        return [GeminiProfile(name: defaultNames[0], model: GeminiConfig.defaultModel, free: true),
                GeminiProfile(name: defaultNames[1], model: defaultSecondModel, free: true),
                GeminiProfile(name: defaultNames[2], model: defaultThirdModel, free: true),
                GeminiProfile(name: defaultNames[3], model: defaultLiteModel, free: true),
                GeminiProfile(name: defaultNames[4], model: defaultOldLiteModel, free: true),
                GeminiProfile(name: defaultNames[5], model: defaultOldLiteModel, free: false)]
    }

    /// Kaydedilmiş profillerde eksik yuvalar varsayılanla tamamlanır, boş kalan modeller varsayılanla dolar (anahtar girilene kadar etkisizdir);
    /// yalnız adı da eski varsayılansa ("Pro", "Ücretsiz", "Model N") ad yenilenir. Kullanıcının yazdığı model ve ad korunur.
    static func migrated(_ saved: [GeminiProfile]) -> [GeminiProfile] {
        var list = saved
        let defs = defaults()
        while list.count < defs.count { list.append(defs[list.count]) }
        let oldNames: [[String]] = [["Flash"], ["Pro"], ["Ücretsiz"], [], [], []]
        for i in list.indices where i < defs.count && saved.indices.contains(i) && list[i].model.trimmed.isEmpty {
            list[i].model = defs[i].model
            list[i].free = defs[i].free
            let name = list[i].name.trimmed
            if name.isEmpty || oldNames[i].contains(name) || name == "Model \(i + 1)" { list[i].name = defs[i].name }
        }
        return list
    }

    /// Anahtarı ve modeli dolu olan profiller (yuva sırasıyla)
    /// Hata iletilerinde anahtarın kendisini göstermeden hangi anahtarın kullanıldığını tanıtır: "AIza…x7Qd, 39 karakter"
    static func keyHint(_ key: String) -> String {
        let k = key.trimmed
        if k.isEmpty { return "anahtar boş" }
        if k.count <= 8 { return "\(k.count) karakter" }
        return "\(k.prefix(4))…\(k.suffix(4)), \(k.count) karakter"
    }

    /// Yapıştırılan anahtarda bilinen hatalar (boşluk, tırnak, kırpılmış ya da başka bir şey yapıştırılmış); sorun yoksa nil.
    /// Google AI Studio anahtarları "AIza" ile başlar ve 39 karakterdir.
    static func keyShapeProblem(_ key: String) -> String? {
        let k = key.trimmed
        if k.isEmpty { return nil }
        if k.contains(where: { $0.isWhitespace }) { return "Anahtarın içinde boşluk ya da satır sonu var; tek parça yapıştırın." }
        if k.contains(where: { "\"'“”‘’`".contains($0) }) { return "Anahtarın içinde tırnak işareti var; tırnaksız yapıştırın." }
        if !k.hasPrefix("AIza") { return "AI Studio anahtarları “AIza” ile başlar; bu başka bir şey olabilir." }
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
        let quotes = CharacterSet(charactersIn: "\"'“”‘’`")
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: quotes)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// "Anahtarı dene" sonucu: anahtarın model listesini alabilmesi Google'ın anahtarı kabul ettiğini gösterir (belirteç harcamaz);
    /// ardından profildeki modelin bu anahtarda görünüp görünmediği söylenir.
    static func keyTestText(model: String, result: Result<[String], GeminiError>) -> (ok: Bool, text: String) {
        switch result {
        case .failure(let e):
            return (false, "✗ " + e.message)
        case .success(let names):
            let wanted = model.trimmed.hasPrefix("models/") ? String(model.trimmed.dropFirst("models/".count)) : model.trimmed
            if wanted.isEmpty { return (true, "✓ Anahtar kabul edildi. (Bu profilde model adı boş.)") }
            if names.contains(wanted) { return (true, "✓ Anahtar kabul edildi; “\(wanted)” bu anahtarla kullanılabilir.") }
            return (false, "✓ Anahtar kabul edildi ama “\(wanted)” modeli bu anahtarda görünmüyor. “Modelleri listele” ile doğru adı bulun.")
        }
    }

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
