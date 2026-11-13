import Foundation

/// Modül 3: dikte metnini birleştirir. Konuşma tanıma görevi sessizlikte ya da süre dolunca biter ve yenisi başlar; ayrıca
/// uzun duraklamadan sonra tanıyıcı metne baştan başlayabilir. Bu yapı bölümleri tek soru metninde toplar.
struct TranscriptAccumulator: Equatable {
    private(set) var committed: [String] = []
    private(set) var current = ""

    var text: String {
        return (committed + [current]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    var isEmpty: Bool { return text.isEmpty }

    /// Çalışan görevin son (kısmi) metni. Metin değiştiyse true.
    @discardableResult
    mutating func update(partial: String) -> Bool {
        let new = partial.trimmed
        guard !new.isEmpty, new != current else { return false }
        if TranscriptAccumulator.looksLikeRestart(old: current, new: new) { commitCurrent() }
        current = new
        return true
    }

    /// Çalışan görev bitti (ya da yeniden başlatılıyor): şimdiki metin kalıcı bölüm olur
    mutating func commitCurrent() {
        if !current.isEmpty { committed.append(current) }
        current = ""
    }

    mutating func clear() {
        committed = []
        current = ""
    }

    /// Yeni kısmi metin eskinin devamı değil de baştan başlayan bir metin mi (tanıyıcı duraklamadan sonra sıfırlanır):
    /// eski metin en az 4 sözcükse ve yeni metin belirgin biçimde kısaysa ya da ilk sözcüğü tutmuyorsa.
    static func looksLikeRestart(old: String, new: String) -> Bool {
        let oldWords = words(old)
        let newWords = words(new)
        guard oldWords.count >= 4, !newWords.isEmpty, newWords.count < oldWords.count else { return false }
        if newWords.count * 2 < oldWords.count { return true }
        return newWords[0] != oldWords[0]
    }

    private static func words(_ text: String) -> [String] {
        return text.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }
}

struct TriggerMatch: Equatable {
    /// Yakalanan tetikleyici sözcük ("Cevapla" ya da "Gönder")
    let word: String
    /// Tetikleyiciden önce okunan soru metni (tetikleyici kırpılmıştır; boş olabilir)
    let question: String
}

/// "Cevapla" / "Gönder" tetikleyicisini bulur. Yalnız metnin SON sözcüğü tetikleyiciyse tetiklenir: soru metninin ortasındaki
/// "gönder…" gibi sözcükler (ya da tam "gönder" geçen bir cümle) yanlış alarm vermez. Büyük/küçük harf, noktalama ve Türkçe
/// harf farkı (ö/o) yok sayılır.
enum TriggerDetector {
    static let defaultWords = ["Cevapla", "Gönder"]

    static func match(in text: String, words: [String] = defaultWords) -> TriggerMatch? {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var end = tokens.count
        while end > 0, fold(tokens[end - 1]).isEmpty { end -= 1 }
        guard end > 0 else { return nil }
        let last = fold(tokens[end - 1])
        guard let word = words.first(where: { fold($0) == last }) else { return nil }
        let question = tokens[0..<(end - 1)].joined(separator: " ").trimmed
        return TriggerMatch(word: word, question: question)
    }

    static func fold(_ token: String) -> String {
        let junk = CharacterSet.punctuationCharacters.union(.symbols).union(.whitespacesAndNewlines)
        return token.trimmingCharacters(in: junk)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "tr_TR"))
    }
}
