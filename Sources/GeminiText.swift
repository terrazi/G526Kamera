import Foundation

/// Gemini cevabını sesli okunacak düz metne çevirir ve sorunun başındaki "Gemini" çağrı sözcüğünü atar
/// (Windows sürümündeki talk.py'nin clean_for_speech / strip_trigger karşılığı).
enum GeminiText {
    /// Ayarlarda hiçbir şey yazılı değilse kullanılan çağrı sözcüğü
    static let defaultCallWord = "gemini"
    /// Ayarda yeni kurulumdaki çağrı sözcükleri: "dinle" kaydı başlatır ("tamam" bitirir), "gemini" eskisi gibi çalışır
    static let defaultCallSetting = "dinle, gemini"
    /// Kayıt sırasında kaydı bitiren sözcükler (`SpeechMatcher.words` biçiminde)
    static let endWords = ["tamam", "tamamdir"]
    /// Çağrı sözcüğü "gemini" ise konuşma tanımanın onu yazabileceği başka biçimler de kabul edilir
    private static let geminiVariants = ["cimini", "geminay", "ceminay", "cemini", "jemini"]
    /// Oturumda her cevabın sonuna uygulama ekler (Gemini'ye bunu söyletmiyoruz)
    static let nextQuestionLine = "Sonraki sorunuzu bekliyorum."
    /// Oturumda geçici bir hata söylendikten sonra
    static let retryLine = "Sorunuzu yeniden söyleyebilirsiniz."

    /// Klasöre henüz kaydedilmemiş fotoğraflar için uyarı (Gemini onları göremez)
    static func unsentNote(_ count: Int) -> String {
        return "\(count) fotoğraf henüz klasöre kaydedilmedi, Gemini onları göremez."
    }

    /// Oturum başında söylenen hazırlık cümlesi. `new`: önceki hazırlıktan beri gelen yeni belge sayısı (ilkinde nil).
    /// `warnings`: atlanan belge gibi sorulara etki eden uyarılar (sesle de söylenir).
    static func readyLine(count: Int, new: Int?, warnings: [String] = [], pages: Int? = nil) -> String {
        var line = "\(count) belge hazır"
        if let p = pages, p > 0, p != count { line = "\(count) belge, \(p) sayfa hazır" }
        if let n = new, n > 0 {
            line += n >= count ? ", hepsi yeni" : ", \(n) tanesi yeni"
        }
        line += "."
        let warn = warnings.map { $0.trimmed }.filter { !$0.isEmpty }.joined(separator: " ")
        if !warn.isEmpty { line += " Dikkat: " + warn }
        return line + " Sorunuzu bekliyorum."
    }

    static let noLastLine = "Tekrarlanacak bir yanıt yok."

    /// Bundan kısa sözcükler çağrı sözcüğü sayılmaz (sohbette kendiliğinden tetikler)
    static let minCallWordLength = 3

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
                // "dostumun faturası" gibi sözcüğün ortasında kesmesin: çağrı sözcüğünden sonra harf gelmemeli
                let end = folded.index(folded.startIndex, offsetBy: w.count)
                if end < folded.endIndex && (folded[end].isLetter || folded[end].isNumber) { continue }
                let rest = t.dropFirst(w.count)
                return String(rest.drop(while: { " ,.:;-".contains($0) }))
            }
        }
        return t
    }

    /// Ayardaki çağrı sözcüklerini ("dostum, gemini" gibi, virgülle) temiz listeye çevirir: çok kısa ve yinelenen
    /// girdiler atılır, boşsa "dinle" ve "gemini" kullanılır, "gemini" varsa tanıma varyantları eklenir.
    static func callWordList(_ setting: String) -> [String] {
        var list: [String] = []
        for part in setting.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let w = String(part).trimmed
            let key = fold(w)
            if key.count >= minCallWordLength && !list.contains(where: { fold($0) == key }) { list.append(w) }
        }
        if list.isEmpty { list = ["dinle", defaultCallWord] }
        if list.contains(where: { fold($0) == defaultCallWord }) {
            for v in geminiVariants where !list.contains(where: { fold($0) == v }) { list.append(v) }
        }
        return list
    }

    /// Sesli komut kaydı için virgülle ayrılmış söylenişler
    static func callPhrases(_ setting: String) -> String {
        return callWordList(setting).joined(separator: ", ")
    }

    /// Sorunun başından atılacak sözcükler
    static func triggerList(for setting: String) -> [String] {
        return callWordList(setting)
    }

    /// Çağrı sözcüğü başka bir komutla (ör. fotoğraf çekme sözcüğü) aynıysa o sözcüklerin listesi
    static func clashes(_ setting: String, with others: [String]) -> [String] {
        let mine = Set(callWordList(setting).map { fold($0) })
        var out: [String] = []
        for other in others {
            for part in other.split(whereSeparator: { $0 == "," || $0 == ";" }) {
                let w = String(part).trimmed
                if mine.contains(fold(w)) && !out.contains(w) { out.append(w) }
            }
        }
        return out
    }
}
