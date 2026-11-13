import Foundation

/// Gemini model profili. Ücretli / ücretsiz olmak modelin değil API anahtarının özelliğidir (anahtarın bağlı olduğu
/// projenin faturalandırması), bu yüzden her profilin kendi anahtarı vardır; anahtar Keychain'de saklanır, burada tutulmaz.
struct GeminiProfile: Codable, Equatable {
    var name: String
    var model: String
    /// Anahtar ücretsiz katmandaysa işaretlenir
    var free: Bool
}

/// Zincirin gördüğü profil: anahtarla birlikte, 1'den başlayan yuva numarasıyla
struct GeminiProfileInfo: Equatable {
    var slot: Int
    var name: String
    var model: String
    var key: String
    var free: Bool

    /// Anahtarı ve modeli dolu profil zincire girer; boş olanlar atlanır
    var usable: Bool { return !key.trimmed.isEmpty && !model.trimmed.isEmpty }
}

/// 4 yedekli Gemini profili (ilk sürümdeki düzen). Soru sırayla 1 → 2 → 3 → 4 profilin kendi anahtarı ve modeliyle sorulur;
/// kota dolarsa, sunucu hata verirse ya da cevap gecikirse sıradakine geçilir.
enum GeminiProfiles {
    static let slotCount = 4

    /// Keychain adı: 1. profil, tek anahtarlı sürümün adını korur (eski anahtar 1. profile gelir)
    static func keychainName(slot: Int) -> String {
        return slot == 1 ? "geminiKeyV3" : "geminiKeyV3_\(slot)"
    }

    /// Varsayılan sıra = performans sırası: 1. Gemini 3.6 Flash, 2. Gemini 3.5 Flash-Lite, 3. Gemini 3.1 Flash-Lite
    /// (üçü de ücretsiz katman anahtarı), 4. ücretli Gemini 3.1 Flash-Lite (kendi ücretli anahtarı, en sonda).
    static let defaultNames = ["Gemini 3.6 Flash", "Gemini 3.5 Flash-Lite", "Gemini 3.1 Flash-Lite", "Ücretli Gemini 3.1 Flash-Lite"]
    static let defaultModels = ["gemini-3.6-flash", "gemini-3.5-flash-lite", "gemini-3.1-flash-lite", "gemini-3.1-flash-lite"]
    static let defaultFree = [true, true, true, false]

    static func defaults() -> [GeminiProfile] {
        return (0..<slotCount).map { GeminiProfile(name: defaultNames[$0], model: defaultModels[$0], free: defaultFree[$0]) }
    }

    /// Kaydedilmiş profillerde eksik yuvalar varsayılanla tamamlanır; boş kalan model ve ad varsayılanla dolar.
    /// Kullanıcının yazdığı model ve ad korunur.
    static func migrated(_ saved: [GeminiProfile]) -> [GeminiProfile] {
        var list = Array(saved.prefix(slotCount))
        let defs = defaults()
        while list.count < slotCount { list.append(defs[list.count]) }
        for i in list.indices {
            if list[i].model.trimmed.isEmpty { list[i].model = defs[i].model }
            if list[i].name.trimmed.isEmpty { list[i].name = defs[i].name }
        }
        return list
    }

    /// Anahtarı ve modeli dolu profiller (yuva sırasıyla)
    static func usable(_ list: [GeminiProfileInfo]) -> [GeminiProfileInfo] {
        return list.filter { $0.usable }
    }

    /// Anahtar türü yazısı: anahtar neyse yazı da odur
    static func keyKindLabel(free: Bool) -> String {
        return free ? "Ücretsiz anahtar" : "Ücretli anahtar"
    }

    /// Profil adı boşsa "N. model"
    static func displayName(_ profile: GeminiProfile, slot: Int) -> String {
        let name = profile.name.trimmed
        return name.isEmpty ? "\(slot). model" : name
    }
}
