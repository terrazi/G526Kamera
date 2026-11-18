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

    /// Profilin kimliği: yuva numarası değil kendisi (kullanıcı sırayı değiştirince "dinlenen" profil kendisiyle birlikte taşınsın)
    var identity: String { return "\(name)|\(model)|\(key)" }
}

/// 4 yedekli Gemini profili (ilk sürümdeki düzen). Soru sırayla 1 → 2 → 3 → 4 profilin kendi anahtarı ve modeliyle sorulur;
/// kota dolarsa, sunucu hata verirse ya da cevap gecikirse sıradakine geçilir.
enum GeminiProfiles {
    static let slotCount = 4

    /// Keychain adı: 1. profil, tek anahtarlı sürümün adını korur (eski anahtar 1. profile gelir)
    static func keychainName(slot: Int) -> String {
        return slot == 1 ? "geminiKeyV3" : "geminiKeyV3_\(slot)"
    }

    /// Varsayılan sıra (kullanıcı kararı 2026-11-19: ücretli modeller kullanılır, en iyisi en başta; 4. model ücretsiz, orta halli bir modeldir):
    /// 1. Gemini 4 Argon, 2. Gemini 3.8 Flash, 3. Gemini 3.7 Flash (üçü de ücretli anahtar), 4. Gemini 3.5 Flash-Lite (ücretsiz anahtar).
    /// Model adları Google'ın model sayfasındaki uç adlarıdır (2026-11-19'da bakıldı). Bir model anahtarda açık değilse zincir sıradakine geçer.
    static let defaultNames = ["Ücretli Gemini 4 Argon", "Ücretli Gemini 3.8 Flash", "Ücretli Gemini 3.7 Flash", "Gemini 3.5 Flash-Lite"]
    static let defaultModels = ["gemini-4-argon", "gemini-3.8-flash", "gemini-3.7-flash", "gemini-3.5-flash-lite"]
    static let defaultFree = [false, false, false, true]

    /// Kayıtlı profilleri yeni düzene çevirir (bir kez; bkz. `AppSettings.applyPaidLineupOnce`): ücretli anahtar ilk üç yuvaya, bir ücretsiz anahtar
    /// dördüncü yuvaya yazılır, modeller ve adlar varsayılana döner. Ücretli anahtar yoksa hiçbir şeye dokunulmaz (nil).
    static func paidLineup(profiles: [GeminiProfile], keys: [String]) -> (profiles: [GeminiProfile], keys: [String])? {
        let pairs = Array(zip(profiles, keys))
        guard let paid = pairs.first(where: { !$0.0.free && !$0.1.trimmed.isEmpty })?.1.trimmed else { return nil }
        let free = pairs.first(where: { $0.0.free && !$0.1.trimmed.isEmpty })?.1.trimmed ?? ""
        let lineup = defaults()
        return (lineup, lineup.map { $0.free ? free : paid })
    }

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

    /// Sıra değiştirme (kullanıcı isteği 2026-11-18: ücretsiz modeller geç ya da yanlış cevap verebiliyor; yukarı / aşağı oklarıyla sıra değişsin):
    /// `index` konumundaki profil bir yukarı (-1) ya da bir aşağı (+1) taşınabilir mi
    static func canMove(_ index: Int, by offset: Int) -> Bool {
        let target = index + offset
        return abs(offset) == 1 && (0..<slotCount).contains(index) && (0..<slotCount).contains(target)
    }

    /// Profil adı boşsa "N. model"
    static func displayName(_ profile: GeminiProfile, slot: Int) -> String {
        let name = profile.name.trimmed
        return name.isEmpty ? "\(slot). model" : name
    }
}
