import Foundation
import CoreGraphics
import CoreVideo
import Vision

/// Otomatik başlatma için canlı görüntüye bir bakışın sonucu (kullanıcı kararı 2026-11-19: kamera kâğıdı ya da "1." yazısını görünce değil,
/// 1. SORUYU görünce başlar).
struct QuestionSight: Equatable {
    /// İncelenen taze kare sayısı (0: görüntü gelmiyor)
    var frames = 0
    /// SORU olarak görünen numaralar: satır başında numara, ardında soru metni ve altında en az iki şık
    var numbers: Set<Int> = []
    /// Numarası okunsun okunmasın karede bir soru yapısı var: okunabilir yazı ve en az iki şık
    var looksLikeQuestion = false
    /// Okunan harf ve rakam sayısı
    var chars = 0

    /// Beklenen soru görünüyor mu; görünüyorsa numarası. `orLater`: sonraki taramalarda beklenen numara ya da daha ilerisi yeter
    /// (cevaplanmış eski sayfa yeniden taranmasın diye daha küçük numaralar sayılmaz).
    func shows(_ target: Int, orLater: Bool) -> Int? {
        if numbers.contains(target) { return target }
        guard orLater else { return nil }
        return numbers.filter { $0 > target }.min()
    }

    /// Günlük için kısa özet: "3 kare, 240 harf, soru 1,2, soru yapısı var"
    var summary: String {
        let list = numbers.sorted().map { String($0) }.joined(separator: ",")
        return "\(frames) kare, \(chars) harf" + (list.isEmpty ? "" : ", soru \(list)") + (looksLikeQuestion ? ", soru yapısı var" : "")
    }
}

/// Yazı tanıma satırlarından (metin + Vision kutusu) karede hangi SORULARIN göründüğünü bulur. Saf mantık: birim testle denenir.
///
/// Bir numara ancak şu üçü birlikteyse soru sayılır: (1) satır başında numara ("1." / "1)"), (2) ardında en az `minBodyLetters` harflik soru metni,
/// (3) aynı sütunda, sıradaki numaraya kadar en az `minOptions` farklı şık (A–E). Böylece sayfa numarası, "1. Bölüm" başlığı ve açıklamalardaki
/// numaralı maddeler soru sayılmaz. A'dan E'ye bütün şıklar ARANMAZ: yakından çekimde uzun soru kadraja sığmayabilir.
enum QuestionSpotter {
    static let minOptions = 2
    static let minBodyLetters = 10
    /// Numarası okunmayan soru yapısı için okunabilir yazı eşiği (harf + rakam)
    static let minChars = 40
    static let numberRange = 1...300

    /// Satır başında soru numarası: "1." / "1)" ve ardından boşlukla herhangi bir şey ya da bitişik rakam olmayan bir karakter ("1.5" ondalık sayıdır)
    private static let numberStart = try? NSRegularExpression(pattern: "^\\s*(\\d{1,3})\\s?[\\.\\)](?:\\s+\\S|[^\\d\\s])", options: [])
    /// Şık satırı. Yazı tanıma ")" işaretini düşürebilir ("E in which stage"): B–E harfi ve sözcük; A yalnız büyük harfli sözcükle
    /// ("A study" gibi satırlar şık sayılmasın)
    private static let optionStart = try? NSRegularExpression(
        pattern: "^\\s*\\(?(?:([B-E])(?:\\s?[\\)\\.\\]]|\\s+(?=\\p{L}))|(A)(?:\\s?[\\)\\.\\]]|\\s+(?=\\p{Lu})))", options: [])
    /// Satır içindeki şıklar ("A) 5   B) 6   C) 7"): harf ve kapanan ayraç
    private static let optionInside = try? NSRegularExpression(pattern: "(?<![\\p{L}0-9])([A-E])\\s?\\)", options: [])

    private struct Row {
        var text: String
        var top: Double
        var midX: Double
    }

    private static func letters(_ text: String) -> Int {
        return text.filter { $0.isLetter || $0.isNumber }.count
    }

    /// "34. Aşağıdakilerden hangisi" → (34, numaradan sonraki harf sayısı)
    static func numbered(_ text: String) -> (number: Int, rest: Int)? {
        guard let pattern = numberStart else { return nil }
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = pattern.firstMatch(in: text, options: [], range: whole), match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text), let number = Int(text[range]), numberRange.contains(number) else { return nil }
        return (number, letters(String(text[range.upperBound...])))
    }

    /// Satırdaki şık harfleri: satır başındaki şık ve satır içindeki "X)" biçimleri
    static func optionLetters(_ text: String) -> Set<Character> {
        var found = Set<Character>()
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        if let pattern = optionStart, let match = pattern.firstMatch(in: text, options: [], range: whole) {
            for group in 1..<match.numberOfRanges {
                if let range = Range(match.range(at: group), in: text), let letter = text[range].first { found.insert(letter) }
            }
        }
        if let pattern = optionInside {
            for match in pattern.matches(in: text, options: [], range: whole) where match.numberOfRanges > 1 {
                if let range = Range(match.range(at: 1), in: text), let letter = text[range].first { found.insert(letter) }
            }
        }
        return found
    }

    /// Satırlardan bakış sonucu (`frames` çağıran tarafından doldurulur). Kutular Vision ölçüsündedir (0–1, başlangıç sol alt).
    static func sight(_ lines: [(text: String, box: CGRect)]) -> QuestionSight {
        var sight = QuestionSight()
        var rows: [Row] = []
        var allOptions = Set<Character>()
        for line in lines {
            let count = letters(line.text)
            guard count > 0 else { continue }
            sight.chars += count
            allOptions.formUnion(optionLetters(line.text))
            rows.append(Row(text: line.text, top: 1 - Double(line.box.maxY), midX: Double(line.box.midX)))
        }
        guard !rows.isEmpty else { return sight }
        // İki sütun: satırların ortaları açıkça sol ve sağ yarıya dağılmışsa her sütun ayrı okunur (sağ sütunun şıkları sol sütunun sorusuna sayılmasın)
        let left = rows.filter { $0.midX < 0.45 }
        let right = rows.filter { $0.midX > 0.55 }
        let columns: [[Row]] = (left.count >= 3 && right.count >= 3) ? [left, right] : [rows]
        for column in columns {
            let ordered = column.sorted { $0.top < $1.top }
            var starts: [(index: Int, number: Int, rest: Int)] = []
            for (index, row) in ordered.enumerated() {
                if let found = numbered(row.text) { starts.append((index: index, number: found.number, rest: found.rest)) }
            }
            for (k, start) in starts.enumerated() {
                let end = k + 1 < starts.count ? starts[k + 1].index : ordered.count
                // Numara satırının içindeki şıklar da sayılır (çok kısa soru tek satırda olabilir); satır başı numara olduğu için yalnız "X)" biçimine bakılır
                var options = optionLetters(ordered[start.index].text)
                var body = start.rest
                var sawOption = false
                var index = start.index + 1
                while index < end {
                    let found = optionLetters(ordered[index].text)
                    if found.isEmpty {
                        if !sawOption { body += letters(ordered[index].text) }
                    } else {
                        sawOption = true
                        options.formUnion(found)
                    }
                    index += 1
                }
                if options.count >= minOptions && body >= minBodyLetters { sight.numbers.insert(start.number) }
            }
        }
        sight.looksLikeQuestion = sight.chars >= minChars && allOptions.count >= minOptions
        return sight
    }
}

/// Canlı kareyi Apple'ın güçlü yazı okuma kipiyle okur ve satırları kutularıyla verir (soru numaraları hızlı kipte çoğu karede okunmuyor)
enum QuestionSpotReader {
    static func read(_ pixelBuffer: CVPixelBuffer, orientation: ImageOrientation) -> [(text: String, box: CGRect)]? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.012
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation.cgOrientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        var lines: [(text: String, box: CGRect)] = []
        for case let observation as VNRecognizedTextObservation in (request.results ?? []) {
            if let best = observation.topCandidates(1).first, best.confidence >= TextScore.minConfidence {
                lines.append((text: best.string, box: observation.boundingBox))
            }
        }
        return lines
    }
}
