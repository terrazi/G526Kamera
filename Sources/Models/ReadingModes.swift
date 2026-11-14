import Foundation

/// Dinleme kipi: mikrofon şu an ne için açık, hangi sözcük işi bitirir.
enum ListenMode: Equatable {
    /// Soru okunuyor; "Cevapla" / "Gönder" ile gönderilir
    case question
    /// "Ortak paragraf" denmiş; paragraf okunuyor, "Tamamlandı" ile biter
    case passage
    /// Paragraf alındı; hangi sorulara ait olduğu numaralarla söyleniyor ("beş altı yedi, Cevapla")
    case passageTargets
    /// Soru okundu ama numarası söylenmedi; numara bekleniyor ("soru yedi")
    case missingNumber
}

/// Kayıtlı ortak paragraf: ait olduğu sorulardan biri her sorulduğunda Gemini'ye soruyla birlikte gider
struct PassageContext: Equatable {
    var text: String
    var english: String
    var audio: Data?
    /// Paragrafın ait olduğu tüm numaralar (söylendiği gibi)
    var all: [Int]
    /// Henüz cevaplanmamış olanlar; hepsi cevaplanınca paragraf bırakılır
    var remaining: [Int]
    /// Paragraf o kadar uzun okundu ki kaydın başı bellek sınırı yüzünden atıldı (metin tam, ses eksik)
    var audioTruncated = false
}

/// "Tamamlandı" denmiş ama hangi sorulara ait olduğu henüz söylenmemiş paragraf
struct PassageDraft: Equatable {
    var text: String
    var english: String
    var audio: Data?
    var audioTruncated = false
}

/// Numarası okunmadığı için numara beklenirken tutulan soru
struct HeldQuestion: Equatable {
    var text: String
    var english: String
    var audio: Data?
}

/// "Ortak paragraf" komutu: okumanın en başında söylenir, paragrafın kendisi sonra okunur
enum PassageCommand {
    /// Paragrafı bitiren sözcük
    static let finishWords = ["Tamamlandı", "Tamamlandi"]

    /// Metin "ortak paragraf" ile mi başlıyor (dikte "paragrafı" gibi ek de yazabilir)
    static func startsWith(_ text: String) -> Bool {
        let head = tokens(text).prefix(2).map { TriggerDetector.fold($0) }
        return head.count == 2 && head[0] == "ortak" && head[1].hasPrefix("paragraf")
    }

    /// Baştaki komut sözcüklerini atar (komut yoksa metni olduğu gibi döndürür)
    static func stripStart(_ text: String) -> String {
        guard startsWith(text) else { return text.trimmed }
        return tokens(text).dropFirst(2).joined(separator: " ").trimmed
    }

    private static func tokens(_ text: String) -> [String] {
        return text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }
}

/// Sıra sayıları: "üçüncü soruda" (anons için; rakam okunuşuna bırakılmaz)
enum TurkishOrdinal {
    private static let tens = ["", "on", "yirmi", "otuz", "kırk", "elli", "altmış", "yetmiş", "seksen", "doksan"]
    private static let tenOrdinals = ["", "onuncu", "yirminci", "otuzuncu", "kırkıncı", "ellinci", "altmışıncı", "yetmişinci", "sekseninci", "doksanıncı"]
    private static let unitOrdinals = ["", "birinci", "ikinci", "üçüncü", "dördüncü", "beşinci", "altıncı", "yedinci", "sekizinci", "dokuzuncu"]

    /// 1...199 için sıra sayısı sözcüğü; dışındakiler için nil
    static func word(_ n: Int) -> String? {
        switch n {
        case 1...9: return unitOrdinals[n]
        case 10...99: return n % 10 == 0 ? tenOrdinals[n / 10] : tens[n / 10] + " " + unitOrdinals[n % 10]
        case 100: return "yüzüncü"
        case 101...199: return "yüz " + (word(n - 100) ?? "")
        default: return nil
        }
    }

    /// "üçüncü soruda" ("250 numaralı soruda": sıra sayısı sözcüğü olmayanlar için)
    static func inQuestion(_ n: Int) -> String {
        if let w = word(n) { return "\(w) soruda" }
        return "\(n) numaralı soruda"
    }
}

/// Okunan metnin son cümlesi: kesinti sonrası "en son şu cümleyi okudunuz" anonsu için
enum LastSentence {
    static let maxWords = 14
    private static let terminators: Set<Character> = [".", "?", "!", "…"]

    static func of(_ text: String) -> String {
        let trimmed = text.trimmed
        let body = String(trimmed.reversed().drop(while: { terminators.contains($0) || $0.isWhitespace }).reversed())
        guard !body.isEmpty else { return "" }
        let chars = Array(body)
        var start = 0
        var index = chars.count - 2
        while index >= 0 {
            // Cümle sonu: noktalama ve ardından boşluk ("3.5" gibi sayılar bölünmez)
            if terminators.contains(chars[index]), chars[index + 1].isWhitespace {
                start = index + 1
                break
            }
            index -= 1
        }
        var words = String(chars[start...]).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if words.count < 3, start > 0 {
            // Çok kısa bir son cümle ("Evet."): öncesinden de al
            words = body.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        }
        if words.count > maxWords { words = Array(words.suffix(maxWords)) }
        return words.joined(separator: " ")
    }
}

/// Gemini'ye gidecek soru metnini kurar: numara başa yazılır, ortak paragraf varsa soruyla birlikte gider
enum QuestionComposer {
    /// [5, 6, 7] → "5, 6 ve 7"
    static func listText(_ numbers: [Int]) -> String {
        let items = numbers.map { String($0) }
        guard let last = items.last else { return "" }
        if items.count == 1 { return last }
        return items.dropLast().joined(separator: ", ") + " ve " + last
    }

    /// Numara okunmamışsa (sonradan sorulup öğrenildiyse) soru metninin başına yazılır
    static func numbered(_ question: String, number: Int) -> String {
        return "Soru \(number). " + question
    }

    static func withPassage(question: String, passage: PassageContext, audioCombined: Bool) -> String {
        var text = "Ortak paragraf (\(listText(passage.all)) numaralı sorular için ortaktır; soruyu bu paragrafa göre çöz):\n\(passage.text)"
        if audioCombined { text += "\n\n(Ses kaydında önce ortak paragraf, ardından soru okunuyor.)" }
        if audioCombined && passage.audioTruncated {
            text += "\n(Paragraf çok uzun okunduğu için ses kaydında paragrafın ilk bölümü yok; paragrafın tamamı yukarıdaki dikte metnindedir, eksik bölüm için onu esas al.)"
        }
        return text + "\n\nŞimdi sorulan soru:\n\(question)"
    }

    static func english(passage: PassageContext, question: String) -> String {
        let p = passage.english.trimmed
        let q = question.trimmed
        if p.isEmpty { return q }
        return "Ortak paragraf: \(p)" + (q.isEmpty ? "" : "\nSoru: \(q)")
    }
}

/// Ortak paragrafın ses kaydı ile sorunun ses kaydını tek WAV'da birleştirir (Gemini tek ses kaydı alır)
enum AudioJoin {
    /// Birleşik kaydın en çok bayt sayısı (300 sn, 16 kHz, 16 bit): istek boyutu sınırı için
    static let maxBytes = 300 * 32_000 + 44

    /// `combined`: paragraf sesi gerçekten eklendi mi (ekleme olmadıysa yalnız soru sesi döner)
    static func join(passage: Data?, question: Data?) -> (data: Data?, combined: Bool) {
        guard let question = question else { return (nil, false) }
        guard let passage = passage, passage.count + question.count <= maxBytes,
              let joined = PCMRecorder.concatenated([passage, question]) else {
            return (question, false)
        }
        return (joined, true)
    }
}
