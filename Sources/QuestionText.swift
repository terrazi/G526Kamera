import Foundation

/// Bir sorunun telefonda (Apple Vision ile) okunan metni ve güvenilirlik ölçüleri. Güvenilirse Gemini'ye PDF yerine bu metin gönderilir
/// (birkaç KB: çok daha küçük ve hızlı). Saf mantıktır.
struct QuestionText: Equatable {
    var text: String
    /// Metinde bulunan şık harfleri
    var letters: Set<Character>
    var meanConfidence: Double
    var minConfidence: Double
    /// Satırlar arasında şekil / tablo olabilecek büyük boşluk var
    var hasGap: Bool
    /// Formül, kesir, üs, özel matematik sembolü izi var
    var mathy: Bool

    /// Metin güveni için alt sınırlar
    static let minMean = 0.85
    static let minLine = 0.5
    /// Satır aralığının bu katından büyük dikey boşluk şekil / tablo sayılır
    static let gapPitches = 3.0
    static let minLength = 15

    static func from(block: QuestionBlock) -> QuestionText {
        let lines = block.lines.sorted { $0.box.minY < $1.box.minY }
        let text = lines.map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
        var gap = false
        if lines.count >= 2 && block.pitch > 0 {
            for i in 1..<lines.count where Double(lines[i].box.minY - lines[i - 1].box.maxY) > gapPitches * block.pitch { gap = true }
        }
        return QuestionText(text: text, letters: Set(block.options.keys), meanConfidence: block.confidence,
                            minConfidence: lines.map { $0.confidence }.min() ?? 0, hasGap: gap, mathy: looksMathy(text))
    }

    /// Sorunun parçaları (üst, alt) tek metinde birleşir
    static func merged(_ parts: [QuestionText]) -> QuestionText {
        guard let first = parts.first else { return QuestionText(text: "", letters: [], meanConfidence: 0, minConfidence: 0, hasGap: false, mathy: false) }
        let text = parts.map { $0.text }.joined(separator: "\n")
        var letters = Set<Character>()
        for p in parts { letters.formUnion(p.letters) }
        return QuestionText(text: text, letters: letters,
                            meanConfidence: parts.map { $0.meanConfidence }.reduce(0, +) / Double(parts.count),
                            minConfidence: parts.map { $0.minConfidence }.min() ?? first.minConfidence,
                            hasGap: parts.contains(where: { $0.hasGap }), mathy: parts.contains(where: { $0.mathy }) || looksMathy(text))
    }

    /// Yalnız metin olarak gönderilebilir mi: bütün şıklar var, okuma güveni yüksek, şekil/tablo/formül izi yok
    func isReliable(optionCount: Int) -> Bool {
        let expected = Set("ABCDE".prefix(min(max(optionCount, 2), 5)))
        return expected.isSubset(of: letters) && meanConfidence >= QuestionText.minMean && minConfidence >= QuestionText.minLine
            && !hasGap && !mathy && text.count >= QuestionText.minLength
    }

    private static let mathSymbols = Set("√∑∫∏≤≥≠≈±×÷π∞∆°∠⊥∈∉∪∩⊂⊃→⇒⇔^_{}\\²³⁴⁵⁶⁷⁸⁹⁻½⅓¼¾")
    private static let fraction = try? NSRegularExpression(pattern: "\\d\\s*/\\s*\\d")
    private static let functions = try? NSRegularExpression(pattern: "\\b(log|sin|cos|tan|cot|lim)\\b", options: [.caseInsensitive])

    /// Formül, kesir, üs, işlev adı ya da özel matematik sembolü var mı (bunlar OCR'da kolay bozulur)
    static func looksMathy(_ text: String) -> Bool {
        if text.contains(where: { mathSymbols.contains($0) }) { return true }
        let range = NSRange(text.startIndex..., in: text)
        if let f = fraction, f.firstMatch(in: text, options: [], range: range) != nil { return true }
        if let f = functions, f.firstMatch(in: text, options: [], range: range) != nil { return true }
        return false
    }
}
