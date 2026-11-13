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

/// Gemini cevabının satırını çözer: "[Soru No], [Şık], [Doğru Cevap]" (ayraç virgül, tire ya da iki nokta olabilir)
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
        if let head = line.range(of: "^\\s*(?:soru\\s*)?(\\d+)\\s*[\\.\\)]?", options: [.regularExpression, .caseInsensitive]) {
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
