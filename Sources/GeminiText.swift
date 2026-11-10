import Foundation

/// Gemini cevabını sesli okunacak düz metne çevirir ve sorunun başındaki "Gemini" çağrı sözcüğünü atar
/// (Windows sürümündeki talk.py'nin clean_for_speech / strip_trigger karşılığı).
enum GeminiText {
    /// Sesli komut olarak "Gemini" demenin tanınabilecek yazılışları (konuşma tanıma "Cemini", "Jemini" diye de duyabilir)
    static let callWords = "gemini, cimini, geminay, ceminay"

    private static let turkish = Locale(identifier: "tr_TR")

    private static func replace(_ text: String, _ pattern: String, _ template: String, multiline: Bool = false) -> String {
        var options: NSRegularExpression.Options = [.caseInsensitive]
        if multiline { options.insert(.anchorsMatchLines) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// Emoji ve çizim simgelerini boşluğa çevirir
    private static func stripSymbols(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .otherSymbol, .modifierSymbol, .surrogate, .privateUse, .format:
                out.append(" ")
            default:
                if scalar.value > 0xFFFF { out.append(" ") } else { out.append(scalar) }
            }
        }
        return String(out)
    }

    /// Markdown ve görsel işaretleri atar; yüzdeleri sesli okunacak biçime getirir.
    static func cleanForSpeech(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\r", with: "")
        s = replace(s, "\\[([^\\]]+)\\]\\([^)]+\\)", "$1")
        s = replace(s, "https?://\\S+|www\\.\\S+", " bağlantı ")
        s = replace(s, "^\\s{0,3}#{1,6}\\s*", "", multiline: true)
        s = replace(s, "^\\s*(?:[-*•▪◦–—]+|\\d{1,2}[.)])\\s+", "", multiline: true)
        for mark in ["**", "__", "`", "~~"] { s = s.replacingOccurrences(of: mark, with: "") }
        s = replace(s, "(?<![\\w*])\\*(?!\\s)|(?<!\\s)\\*(?![\\w*])", "")
        s = s.replacingOccurrences(of: "|", with: ", ")
        s = replace(s, "(\\d+(?:[.,]\\d+)?)\\s*%", "yüzde $1")
        s = replace(s, "%\\s*(\\d+(?:[.,]\\d+)?)", "yüzde $1")
        s = stripSymbols(s)
        s = replace(s, "[ \\t]+", " ")
        s = replace(s, "\\n{2,}", "\n")
        return s.trimmed
    }

    /// Türkçe harfleri sadeleştirip küçültür ("İ" → "i", "ş" → "s"…)
    static func fold(_ text: String) -> String {
        var out = ""
        for ch in text.lowercased(with: turkish) {
            switch ch {
            case "ı": out.append("i")
            case "ö": out.append("o")
            case "ü": out.append("u")
            case "ş": out.append("s")
            case "ç": out.append("c")
            case "ğ": out.append("g")
            default: out.append(ch)
            }
        }
        return out
    }

    /// Sorunun başındaki çağrı sözcüklerini ("gemini, ...") atar.
    static func stripTrigger(_ text: String, words: [String]) -> String {
        let t = text.trimmed
        let folded = fold(t)
        for word in words.sorted(by: { $0.count > $1.count }) {
            let w = fold(word).trimmed
            if !w.isEmpty && folded.hasPrefix(w) {
                let rest = t.dropFirst(w.count)
                return String(rest.drop(while: { " ,.:;-".contains($0) }))
            }
        }
        return t
    }

    /// callWords listesini sözcük dizisine çevirir
    static var triggerList: [String] {
        return callWords.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { String($0).trimmed }
            .filter { !$0.isEmpty } + ["cemini", "jemini", "gemini"]
    }
}
