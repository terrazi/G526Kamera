import Foundation

/// Gemini'nin verdiği tek bir cevap: "Soru 1, Denizli, Örgütsel Davranış"
struct AnswerRecord: Identifiable, Equatable {
    let number: Int
    /// Şık sözcüğü (A=Adana, B=Bursa, C=Ceyhan, D=Denizli, E=Erzurum)
    let option: String
    /// Doğru cevabın metni
    let text: String
    /// Kulaklıktan okunan cümle
    let spoken: String

    var id: Int { return number }
}

/// Gemini cevabının satırını çözer: "[Soru No], [Şık], [Doğru Cevap]" (ayraç virgül, tire ya da iki nokta olabilir; "Soru: 3", "Soru No 3" ve
/// "5. soru, Denizli" de çözülür)
enum AnswerParser {
    struct Parsed: Equatable {
        var number: Int?
        var option: String
        var text: String
        /// Okunacak cümle: numara ve şık çözüldüyse düzenli "Soru N, Şık, Cevap", çözülemediyse temizlenmiş ham satır
        var spoken: String
    }

    private static let separators: Set<Character> = [",", "-", "–", "—", ":", ";"]

    static func parse(_ raw: String) -> Parsed {
        let line = firstLine(of: cleaned(raw))
        var number: Int?
        var rest = line
        if let head = line.range(of: "^\\s*(?:soru(?:\\s*(?:no|numara|numarası))?\\s*[:\\.\\-–—]?\\s*)?(\\d+)\\s*[\\.\\)]?(?:\\s*soru(?:su)?\\b)?", options: [.regularExpression, .caseInsensitive]) {
            number = Int(line[head].filter { $0.isNumber })
            rest = String(line[head.upperBound...])
        }
        rest = String(rest.drop(while: { $0.isWhitespace || separators.contains($0) }))

        var option = rest.trimmed
        var text = ""
        if let cut = rest.firstIndex(where: { separators.contains($0) }) {
            option = String(rest[rest.startIndex..<cut]).trimmed
            text = String(rest[rest.index(after: cut)...]).trimmingCharacters(in: CharacterSet(charactersIn: ",-–—:; ").union(.whitespacesAndNewlines))
        }

        var spoken = line
        if let number = number, !option.isEmpty {
            spoken = "Soru \(number), \(option)" + (text.isEmpty ? "" : ", \(text)")
        } else if number == nil, !option.isEmpty, !text.isEmpty {
            spoken = "\(option), \(text)"
        }
        return Parsed(number: number, option: option, text: text, spoken: spoken)
    }

    /// Birden çok satırlı cevap (bir sayfadaki sorular): her dolu satır ayrı çözülür; çözülemeyen (boş) satırlar atılır, aynı numara ikinci kez
    /// gelirse ilki kalır. Gemini'nin sırası korunur.
    static func parseLines(_ raw: String) -> [Parsed] {
        var result: [Parsed] = []
        var seen = Set<Int>()
        for part in cleaned(raw).components(separatedBy: .newlines) {
            let line = part.trimmed
            guard !line.isEmpty, !isNoQuestionLine(line) else { continue }
            let parsed = parse(line)
            guard !parsed.spoken.isEmpty else { continue }
            if let number = parsed.number, !seen.insert(number).inserted { continue }
            result.append(parsed)
        }
        return result
    }

    /// Sayfa kipinde "bu sayfada soru yok" işareti: satır yalnız "SORU YOK" (noktalama ve büyük/küçük harf önemsiz)
    static func isNoQuestionLine(_ line: String) -> Bool {
        let bare = line.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces)).lowercased()
        return bare == "soru yok"
    }

    /// Ham cevapta sayfanın soru içermediği bildirilmiş mi
    static func isNoQuestion(_ raw: String) -> Bool {
        return cleaned(raw).components(separatedBy: .newlines).contains { isNoQuestionLine($0.trimmed) }
    }

    /// Cevap cümlesi, kaydedilen numarayla: "Soru N, Şık, Cevap". Şık çözülemediyse ham satırın başına numara eklenir.
    static func spokenLine(number: Int, option: String, text: String, fallback: String) -> String {
        if option.isEmpty { return "Soru \(number), \(fallback)" }
        return "Soru \(number), \(option)" + (text.isEmpty ? "" : ", \(text)")
    }

    /// Biçim işaretlerini (yıldız, ters tırnak, köşeli parantez, başlık) atar
    private static func cleaned(_ raw: String) -> String {
        let junk = CharacterSet(charactersIn: "*`[]#_")
        return raw.components(separatedBy: junk).joined()
    }

    private static func firstLine(of text: String) -> String {
        for part in text.components(separatedBy: .newlines) {
            let line = part.trimmed
            if !line.isEmpty { return line }
        }
        return ""
    }
}
