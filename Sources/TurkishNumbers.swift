import Foundation

/// Sayıların Türkçe okunuşu (sesli okuma için): 37 → "otuz yedi", sıra sayısı 37 → "otuz yedinci".
enum TurkishNumbers {
    private static let units = ["", "bir", "iki", "üç", "dört", "beş", "altı", "yedi", "sekiz", "dokuz"]
    private static let tensWords = ["", "on", "yirmi", "otuz", "kırk", "elli", "altmış", "yetmiş", "seksen", "doksan"]
    private static let ordLast: [String: String] = [
        "bir": "birinci", "iki": "ikinci", "üç": "üçüncü", "dört": "dördüncü", "beş": "beşinci", "altı": "altıncı",
        "yedi": "yedinci", "sekiz": "sekizinci", "dokuz": "dokuzuncu", "on": "onuncu", "yirmi": "yirminci",
        "otuz": "otuzuncu", "kırk": "kırkıncı", "elli": "ellinci", "altmış": "altmışıncı", "yetmiş": "yetmişinci",
        "seksen": "sekseninci", "doksan": "doksanıncı", "yüz": "yüzüncü", "bin": "bininci", "sıfır": "sıfırıncı"]

    /// 0...9999 için yazı ile sayı; dışındakiler rakamla döner.
    static func cardinal(_ n: Int) -> String {
        if n < 0 || n > 9999 { return String(n) }
        if n == 0 { return "sıfır" }
        var parts: [String] = []
        let th = n / 1000
        var rest = n % 1000
        if th > 0 { parts.append(th == 1 ? "bin" : units[th] + " bin") }
        let h = rest / 100
        rest = rest % 100
        if h > 0 { parts.append(h == 1 ? "yüz" : units[h] + " yüz") }
        let t = rest / 10
        let u = rest % 10
        if t > 0 { parts.append(tensWords[t]) }
        if u > 0 { parts.append(units[u]) }
        return parts.joined(separator: " ")
    }

    /// Sıra sayısı: 1 → "birinci", 37 → "otuz yedinci"
    static func ordinal(_ n: Int) -> String {
        if n < 0 || n > 9999 { return "\(n)." }
        var words = cardinal(n).components(separatedBy: " ")
        if let last = words.last { words[words.count - 1] = ordLast[last] ?? last }
        return words.joined(separator: " ")
    }

    /// Soru numaralarının sesli listesi: [15] → "15", [15, 22] → "15 ve 22", [3, 15, 22] → "3, 15 ve 22"
    static func spokenList(_ numbers: [Int]) -> String {
        let items = numbers.map { String($0) }
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " ve " + items[items.count - 1]
        }
    }

    /// İlk harfi büyütür (Türkçe: i → İ, ı → I)
    static func capitalised(_ text: String) -> String {
        guard let first = text.first else { return text }
        let head: String
        switch first {
        case "i": head = "İ"
        case "ı": head = "I"
        default: head = String(first).uppercased()
        }
        return head + text.dropFirst()
    }
}
