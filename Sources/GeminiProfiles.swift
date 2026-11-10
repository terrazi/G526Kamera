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
    /// Sesli söylenişi: "Pro, ücretli"
    var spokenName: String { return "\(name), \(free ? "ücretsiz" : "ücretli")" }
}

enum GeminiProfiles {
    static let slotCount = 3

    /// Keychain adı: 1. profil eski "geminiApiKey" adını korur
    static func keychainName(slot: Int) -> String {
        return slot == 1 ? "geminiApiKey" : "geminiApiKey\(slot)"
    }

    static func defaults() -> [GeminiProfile] {
        return [GeminiProfile(name: "Flash", model: GeminiConfig.defaultModel, free: false),
                GeminiProfile(name: "Pro", model: "", free: false),
                GeminiProfile(name: "Ücretsiz", model: "", free: true)]
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
            ?? GeminiProfileInfo(slot: 1, name: "Flash", model: GeminiConfig.defaultModel, key: "", free: false)
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

    /// Model seçiminde söylenen cümle: "Model seçimi yapınız. 1. model: Flash, ücretli. ..."
    static func choiceAnnouncement(_ list: [GeminiProfileInfo]) -> String {
        let items = usable(list).map { "\($0.slot). model: \($0.spokenName)." }
        return "Model seçimi yapınız. " + items.joined(separator: " ") + " Hangisini istiyorsunuz?"
    }

    /// Seçim sırasında söylenen "ikinci model", "2 model" ya da profil adı için sesli komut söylenişleri
    static func pickPhrases(slot: Int, name: String) -> String {
        let ordinals = ["birinci", "ikinci", "üçüncü"]
        var parts = ["\(ordinals[min(max(slot, 1), 3) - 1]) model", "\(slot) model", "\(slot) numaralı model"]
        if name.trimmed.count >= 3 { parts.append(name.trimmed) }
        return parts.joined(separator: ", ")
    }
}
