import Foundation

/// Kullanıcının okuduğu soru numarası. Sorular sırayla okunmak zorunda değildir ("Soru 7", sonra "Soru 3"): kayıt, sıraya göre değil
/// okunan numarayla yapılır. Numara, dikte metninin başından çıkarılır: "soru 7", "soru numarası 12", "7. soru", "yedinci soru",
/// "on ikinci soru", "soru yirmi beş". Metnin ortasındaki sayılara (şıklar, "3 kişi" gibi) bakılmaz.
enum SpokenNumber {
    /// "soru" sözcüğünün aranacağı baştaki sözcük sayısı (numara hep okumanın başında söylenir)
    private static let headWords = 5

    private static let units: [String: Int] = ["bir": 1, "iki": 2, "uc": 3, "dort": 4, "bes": 5, "alti": 6, "yedi": 7, "sekiz": 8, "dokuz": 9]
    private static let unitOrdinals: [String: Int] = [
        "birinci": 1, "ikinci": 2, "ucuncu": 3, "dorduncu": 4, "besinci": 5,
        "altinci": 6, "yedinci": 7, "sekizinci": 8, "dokuzuncu": 9
    ]
    private static let tens: [String: Int] = [
        "on": 10, "yirmi": 20, "otuz": 30, "kirk": 40, "elli": 50, "altmis": 60, "yetmis": 70, "seksen": 80, "doksan": 90
    ]
    private static let tenOrdinals: [String: Int] = [
        "onuncu": 10, "yirminci": 20, "otuzuncu": 30, "kirkinci": 40, "ellinci": 50,
        "altmisinci": 60, "yetmisinci": 70, "sekseninci": 80, "doksaninci": 90
    ]
    /// "soru numarası 5", "soru no 5"
    private static let fillers: Set<String> = ["numarasi", "numara", "no", "nu", "numarali"]
    /// "5'inci soru" → "5", "inci"
    private static let digitSuffixes: Set<String> = ["inci", "nci", "uncu", "ncu"]

    /// Metinde okunan soru numarası; yoksa ya da anlaşılamadıysa nil (1...999)
    static func extract(from text: String) -> Int? {
        let words = tokens(text)
        let limit = min(words.count, headWords)
        guard limit > 0 else { return nil }
        for index in 0..<limit where words[index] == "soru" {
            if let value = numberBefore(index, in: words) { return value }
            if let value = numberAfter(index, in: words) { return value }
        }
        return nil
    }

    /// Küçük harf, Türkçe harfler sadeleştirilmiş, noktalama atılmış sözcükler
    static func tokens(_ text: String) -> [String] {
        let lowered = text.lowercased(with: Locale(identifier: "tr_TR"))
        var folded = ""
        for ch in lowered {
            switch ch {
            case "ç": folded.append("c")
            case "ğ": folded.append("g")
            case "ı": folded.append("i")
            case "ö": folded.append("o")
            case "ş": folded.append("s")
            case "ü": folded.append("u")
            case "â": folded.append("a")
            case "î": folded.append("i")
            case "û": folded.append("u")
            default: folded.append(ch)
            }
        }
        return folded.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map { String($0) }
    }

    private struct Parsed {
        let value: Int
        let consumed: Int
        /// Rakamla ya da sıra sayısıyla ("beşinci") bitti: "bir soru" gibi belirsiz söyleyişlerden ayırır
        let final: Bool
    }

    /// "yedinci soru", "5. soru", "on ikinci soru": "soru"dan hemen önceki (başta başlayan) sayı. Yalnız rakam ve sıra sayısı kabul edilir;
    /// "bir soru" (= bir tane soru) numara sayılmaz.
    private static func numberBefore(_ index: Int, in words: [String]) -> Int? {
        guard index > 0 else { return nil }
        for start in 0...min(1, index - 1) {
            let slice = Array(words[start..<index])
            if let parsed = parse(slice), parsed.final, parsed.consumed == slice.count { return parsed.value }
        }
        return nil
    }

    /// "soru 7", "soru numarası 12", "soru yirmi beş", "soru bir"
    private static func numberAfter(_ index: Int, in words: [String]) -> Int? {
        var start = index + 1
        var skipped = 0
        while start < words.count, skipped < 2, fillers.contains(words[start]) {
            start += 1
            skipped += 1
        }
        guard start < words.count else { return nil }
        return parse(Array(words[start...]))?.value
    }

    /// Sözcük dizisinin başındaki sayıyı çözer (rakam ya da Türkçe sayı sözcükleri, 1...999)
    private static func parse(_ words: [String]) -> Parsed? {
        guard let first = words.first else { return nil }
        if let digits = Int(first), first.count <= 3 {
            guard digits >= 1 else { return nil }
            let suffix = words.count > 1 && digitSuffixes.contains(words[1])
            return Parsed(value: digits, consumed: suffix ? 2 : 1, final: true)
        }
        var value = 0
        var i = 0
        if words[0] == "yuzuncu" {
            return Parsed(value: 100, consumed: 1, final: true)
        } else if words[0] == "yuz" {
            value = 100
            i = 1
        } else if let unit = units[words[0]], words.count > 1, words[1] == "yuz" {
            value = unit * 100
            i = 2
        }
        if i < words.count {
            if let ten = tens[words[i]] {
                value += ten
                i += 1
            } else if let ten = tenOrdinals[words[i]] {
                return Parsed(value: value + ten, consumed: i + 1, final: true)
            }
        }
        if i < words.count {
            if let unit = units[words[i]] {
                value += unit
                i += 1
            } else if let unit = unitOrdinals[words[i]] {
                return Parsed(value: value + unit, consumed: i + 1, final: true)
            }
        }
        guard i > 0, value > 0 else { return nil }
        return Parsed(value: value, consumed: i, final: false)
    }
}
