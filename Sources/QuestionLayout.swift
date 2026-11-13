import Foundation
import CoreGraphics

/// Bir OCR satırı: metin ve kutusu. Kutu 0–1 aralığında, ÜST-SOL başlangıçlıdır (y aşağı doğru artar), görüntü yönü uygulanmış
/// (kullanıcının gördüğü) görüntüye göredir.
struct OCRLine: Equatable {
    var text: String
    var box: CGRect
    var confidence: Double = 1
}

/// Sayfadaki bir sorunun (ya da sayfanın başındaki devam parçasının) yeri: numara satırı, şıklar ve kırpma sınırları.
struct QuestionBlock: Equatable {
    /// Soru numarası; 0 = sayfanın başındaki, numarası olmayan devam parçası
    var number: Int
    var column: Int
    var lines: [OCRLine]
    var options: [Character: OCRLine]
    /// Beklenen bütün şıklar (A…E ya da A…D) görüldü
    var complete: Bool
    /// Son şık yok, altında başka soru da yok ve yazı kadrajın alt kenarına yakın: soru bir sonraki sayfada sürüyor olabilir
    var opensBelow: Bool
    /// Kırpma sınırları (0–1; taşabilir: eksi ya da 1'den büyükse soru kadrajın dışına taşıyor demektir)
    var cropTop: Double
    var cropBottom: Double
    var cropLeft: Double
    var cropRight: Double
    /// Sorunun asıl içeriğinin (numara satırı … son şık satırı) kadraj içindeki sınırları (0–1); kırpma payları dahil değildir
    var contentTop: Double
    var contentBottom: Double
    var contentLeft: Double
    var contentRight: Double
    /// Satır aralığı (satır başından sonraki satır başına), kadraj yüksekliğinin oranı
    var pitch: Double
    /// Satırların ortalama OCR güveni (0–1)
    var confidence: Double

    var cutTop: Bool { return cropTop < -0.004 }
    var cutBottom: Bool { return cropBottom > 1.004 }
    var cutSide: Bool { return cropLeft < -0.004 || cropRight > 1.004 }
    /// Kırpma payları dahil her şey kadrajın içinde
    var insideFrame: Bool { return !cutTop && !cutBottom && !cutSide }
    /// Asıl içerik (numara … son şık) kadraja tam sığıyor; paylar kadraj dışına taşsa da soru eksiksiz alınır
    var contentCutTop: Bool { return contentTop < 0.004 }
    var contentCutBottom: Bool { return contentBottom > 0.996 }
    var contentCutSide: Bool { return contentLeft < 0.002 || contentRight > 0.998 }

    /// Kadraj içine sığdırılmış kırpma dikdörtgeni (0–1, üst-sol başlangıçlı)
    var cropRect: CGRect {
        let t = max(0, cropTop), b = min(1, cropBottom)
        let l = max(0, cropLeft), r = min(1, cropRight)
        return CGRect(x: l, y: t, width: max(0, r - l), height: max(0, b - t))
    }
}

struct PageLayout: Equatable {
    var blocks: [QuestionBlock]
    /// İlk soru numarasından önceki parça (önceki sayfadan devam eden sorunun kalanı olabilir); yoksa nil
    var leading: QuestionBlock?
    var columnCount: Int
    var lineCount: Int
}

/// Sayfadaki OCR satırlarından soru numaralarını, şıkları ve kırpma sınırlarını çıkarır. Saf mantıktır (görüntü işlemez).
///
/// Kırpma kuralı (kullanıcı kararı): üst sınır = numara satırından 2 satır yukarı (≈ 0,5 cm), alt sınır = son şık satırından 4 satır
/// aşağı (≈ 1 cm); "satır" ölçüsü sayfadaki gerçek satır aralığıdır (A4 ölçeği gerekmez). Altta başka bir soru başlıyorsa alt sınır
/// onun numara satırında biter (iki soru karışmasın).
enum QuestionLayout {
    static let topMarginLines = 2.0
    static let bottomMarginLines = 4.0
    /// Yazının bundan sonrası kadrajın alt kenarı sayılır: son şık yoksa soru sayfanın devamında sürüyor olabilir
    static let bottomEdge = 0.80
    /// Numara satırlarının sol kenarı sütun boyunca bu kadar (kadraj genişliği oranı) oynayabilir
    static let alignTolerance = 0.06
    static let maxQuestionNumber = 999

    private static let numberRegex = try? NSRegularExpression(pattern: "^\\s*[\\(\\[]?\\s*(\\d{1,3})\\s*[\\.\\)\\]](?!\\d)")
    private static let optionRegex = try? NSRegularExpression(pattern: "(?:^|\\s)\\(?([A-E])\\s?[\\)\\.\\]]")

    /// "12. Soru metni" / "12) …" / "(12) …" → 12; "12.5" ve "3 kg" gibi satırlar numara sayılmaz
    static func questionNumber(in text: String) -> Int? {
        guard let regex = numberRegex else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let r = Range(match.range(at: 1), in: text) else { return nil }
        guard let value = Int(text[r]), value >= 1 else { return nil }
        return value
    }

    /// Satırdaki şık harfleri: "A) 12", "B. kırmızı", "A) 5  B) 6  C) 7" (aynı satırda birden çok şık olabilir)
    static func optionLetters(in text: String) -> [Character] {
        guard let regex = optionRegex else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var out: [Character] = []
        for m in regex.matches(in: text, options: [], range: range) {
            guard let r = Range(m.range(at: 1), in: text), let c = text[r].first else { continue }
            if !out.contains(c) { out.append(c) }
        }
        return out
    }

    /// `total` > 0 ise numaralar 1...total aralığına sınırlanır; `optionCount`: soru başına şık sayısı (4 ya da 5)
    static func analyze(lines rawLines: [OCRLine], total: Int, optionCount: Int) -> PageLayout {
        let count = min(max(optionCount, 2), 5)
        let expected: [Character] = Array("ABCDE".prefix(count))
        let limit = total > 0 ? total : maxQuestionNumber
        let lines = rawLines.filter { $0.box.height > 0 && !$0.text.trimmed.isEmpty }.sorted { $0.box.minY < $1.box.minY }

        // 1) numara adayları
        var marks: [Int] = []          // lines dizisindeki indisler
        for (i, line) in lines.enumerated() {
            if let n = questionNumber(in: line.text), n <= limit { marks.append(i) }
        }

        // 2) sütunlar: numara satırlarının sol kenarı iki ayrı yığında toplanıyorsa iki sütun
        var boundary: Double?
        if marks.count >= 2 {
            let xs = marks.map { Double(lines[$0].box.minX) }
            let lo = xs.min() ?? 0, hi = xs.max() ?? 0
            if hi - lo > 0.25 {
                let mid = (lo + hi) / 2
                let left = xs.filter { $0 < mid }, right = xs.filter { $0 >= mid }
                if !left.isEmpty && !right.isEmpty {
                    boundary = (left.reduce(0, +) / Double(left.count) + right.reduce(0, +) / Double(right.count)) / 2
                }
            }
        }
        func column(of line: OCRLine) -> Int {
            guard let b = boundary else { return 0 }
            if line.box.width > 0.7 { return -1 }          // iki sütunu kaplayan başlık satırı
            return Double(line.box.minX) < b ? 0 : 1
        }
        let columnCount = boundary == nil ? 1 : 2

        var blocks: [QuestionBlock] = []
        var leading: QuestionBlock?
        for col in 0..<columnCount {
            let colLines = lines.filter { column(of: $0) == col }
            let pitch = linePitch(colLines)
            // bu sütunun numaraları: hizalı ve artan
            var idx = marks.filter { column(of: lines[$0]) == col }
            idx = aligned(idx, lines: lines)
            idx = increasing(idx, lines: lines)
            for (k, mi) in idx.enumerated() {
                let numberLine = lines[mi]
                let nextY: Double? = k + 1 < idx.count ? Double(lines[idx[k + 1]].box.minY) : nil
                let startY = Double(numberLine.box.minY)
                let own = colLines.filter {
                    let y = Double($0.box.minY)
                    return y >= startY - 0.004 && (nextY == nil || y < nextY! - 0.004)
                }
                blocks.append(makeBlock(number: questionNumber(in: numberLine.text) ?? 0, column: col, lines: own,
                                        numberLine: numberLine, nextY: nextY, expected: expected, pitch: pitch))
            }
            // sayfanın başındaki numarasız parça (yalnız ilk sütunda)
            if col == 0 {
                let firstY: Double? = idx.first.map { Double(lines[$0].box.minY) }
                let head = colLines.filter { firstY == nil || Double($0.box.minY) < firstY! - 0.004 }
                if let first = head.first, head.count >= 2 || !optionLetters(in: head.map { $0.text }.joined(separator: " ")).isEmpty {
                    leading = makeBlock(number: 0, column: 0, lines: head, numberLine: first, nextY: firstY,
                                        expected: expected, pitch: pitch)
                }
            }
        }
        return PageLayout(blocks: blocks, leading: leading, columnCount: columnCount, lineCount: lines.count)
    }

    // MARK: - Yardımcılar

    /// Numara satırlarının sol kenarı sütunun ortancasından çok sapıyorsa (metin içindeki "1." gibi sıralamalar) elenir
    private static func aligned(_ idx: [Int], lines: [OCRLine]) -> [Int] {
        guard idx.count >= 3 else { return idx }
        let xs = idx.map { Double(lines[$0].box.minX) }.sorted()
        let median = xs[xs.count / 2]
        return idx.filter { abs(Double(lines[$0].box.minX) - median) <= alignTolerance }
    }

    /// Yukarıdan aşağıya numaralar artmalıdır: en uzun artan dizi tutulur (sayfadaki tek tük yanlış okumalar atılır)
    private static func increasing(_ idx: [Int], lines: [OCRLine]) -> [Int] {
        let nums = idx.map { questionNumber(in: lines[$0].text) ?? 0 }
        let n = idx.count
        if n <= 1 { return idx }
        var best = [Int](repeating: 1, count: n)
        var prev = [Int](repeating: -1, count: n)
        for i in 0..<n {
            for j in 0..<i where nums[j] < nums[i] && best[j] + 1 > best[i] {
                best[i] = best[j] + 1
                prev[i] = j
            }
        }
        var end = 0
        for i in 0..<n where best[i] > best[end] { end = i }
        var chain: [Int] = []
        var cur = end
        while cur >= 0 {
            chain.append(idx[cur])
            cur = prev[cur]
        }
        return chain.reversed()
    }

    /// Satır aralığı: ardışık satır başlarının farkının ortancası; ölçülemezse satır yüksekliğinden
    static func linePitch(_ lines: [OCRLine]) -> Double {
        let ys = lines.map { Double($0.box.minY) }.sorted()
        var deltas: [Double] = []
        if ys.count >= 2 {
            for i in 1..<ys.count {
                let d = ys[i] - ys[i - 1]
                if d > 0.004 && d < 0.08 { deltas.append(d) }
            }
        }
        if !deltas.isEmpty {
            deltas.sort()
            return deltas[deltas.count / 2]
        }
        let heights = lines.map { Double($0.box.height) }.sorted()
        if !heights.isEmpty { return heights[heights.count / 2] * 1.5 }
        return 0.02
    }

    private static func makeBlock(number: Int, column: Int, lines: [OCRLine], numberLine: OCRLine, nextY: Double?,
                                  expected: [Character], pitch: Double) -> QuestionBlock {
        var options: [Character: OCRLine] = [:]
        for line in lines {
            for letter in optionLetters(in: line.text) where options[letter] == nil { options[letter] = line }
        }
        let lastLetter = expected[expected.count - 1]
        // Numarasız devam parçası: önceki sayfadaki şıklar orada kaldığından yalnız SON şığı içermesi yeter
        let complete = number == 0 ? options[lastLetter] != nil : expected.allSatisfy { options[$0] != nil }
        let lastBottom = lines.map { Double($0.box.maxY) }.max() ?? Double(numberLine.box.maxY)

        let top = Double(lines.first?.box.minY ?? numberLine.box.minY) - topMarginLines * pitch
        var bottom: Double
        var opens = false
        if let end = options[lastLetter] {
            bottom = Double(end.box.maxY) + bottomMarginLines * pitch
        } else {
            bottom = lastBottom + bottomMarginLines * pitch
            opens = nextY == nil && lastBottom >= bottomEdge
        }
        if let next = nextY, bottom > next - 0.2 * pitch { bottom = next - 0.2 * pitch }

        let left = (lines.map { Double($0.box.minX) }.min() ?? 0) - 0.015
        let right = (lines.map { Double($0.box.maxX) }.max() ?? 1) + 0.015
        let conf = lines.isEmpty ? 0 : lines.map { $0.confidence }.reduce(0, +) / Double(lines.count)
        let contentTop = Double(lines.first?.box.minY ?? numberLine.box.minY)
        let contentBottom = options[lastLetter].map { Double($0.box.maxY) } ?? lastBottom
        return QuestionBlock(number: number, column: column, lines: lines, options: options, complete: complete,
                             opensBelow: opens, cropTop: top, cropBottom: bottom, cropLeft: left, cropRight: right,
                             contentTop: contentTop, contentBottom: contentBottom,
                             contentLeft: left + 0.015, contentRight: right - 0.015,
                             pitch: pitch, confidence: conf)
    }
}
