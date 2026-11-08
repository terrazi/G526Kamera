import Foundation

/// OCR ile okunan metni PDF'in SONUNA "metin sayfaları" olarak eklemek için yardımcılar (Windows sürümüyle aynı düzen).
/// Yazı tipi gömülmez: standart Helvetica kullanılır. WinAnsi'de olmayan 6 Türkçe harf (Ğ ğ İ ı Ş ş) kullanılmayan
/// kodlara eşlenir (/Differences + /ToUnicode); böylece harfler doğru görünür, kopyalanır ve aranır.
enum PDFText {
    static let pageWidth = 595.0
    static let pageHeight = 842.0
    static let margin = 54.0
    static let bodySize = 10.5
    static let leading = 14.5
    static let headSize = 13.0
    static let maxChars = 20000

    private static let turkish: [UInt32: UInt8] = [
        0x011E: 0x81, 0x011F: 0x8D, 0x0130: 0x8F, 0x0131: 0x90, 0x015E: 0x9D, 0x015F: 0xA0]
    private static let turkishCodes: Set<UInt8> = [0x81, 0x8D, 0x8F, 0x90, 0x9D, 0xA0]

    /// Helvetica uyumlu karakter genişlikleri (1000 birim), kod 32...255
    static let widths: [Int] = [
        278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278,
        556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556,
        1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778,
        667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556,
        333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556,
        556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584, 750,
        556, 778, 222, 556, 333, 1000, 556, 556, 333, 1000, 667, 333, 1000, 556, 611, 278,
        278, 222, 222, 333, 333, 350, 556, 1000, 333, 1000, 500, 333, 944, 667, 500, 667,
        500, 333, 556, 556, 556, 556, 260, 556, 333, 737, 370, 556, 584, 556, 737, 552,
        400, 549, 333, 333, 333, 576, 537, 333, 333, 333, 365, 556, 834, 834, 834, 611,
        667, 667, 667, 667, 667, 667, 1000, 722, 667, 667, 667, 667, 278, 278, 278, 278,
        722, 722, 778, 778, 778, 778, 778, 584, 778, 722, 722, 722, 722, 667, 667, 611,
        556, 556, 556, 556, 556, 556, 889, 500, 556, 556, 556, 556, 278, 278, 278, 278,
        556, 556, 556, 556, 556, 556, 556, 549, 611, 556, 556, 556, 556, 500, 556, 500
    ]

    /// Metni PDF'in kullandığı tek baytlık kodlamaya çevirir (Türkçe harfler özel kodlarda).
    static func encode(_ text: String) -> [UInt8] {
        var out: [UInt8] = []
        for scalar in text.precomposedStringWithCanonicalMapping.unicodeScalars {
            if let code = turkish[scalar.value] { out.append(code); continue }
            var s = scalar
            if s.value == 0xA0 || s.value == 0x09 { s = " " }
            if s.value < 32 { continue }
            if s.value < 0x80 { out.append(UInt8(s.value)); continue }
            if let data = String(Character(s)).data(using: .windowsCP1252), data.count == 1 {
                let b = data[0]
                out.append(turkishCodes.contains(b) || b == 0xAD ? 63 : b)
            } else {
                out.append(63)
            }
        }
        return out
    }

    static func width(_ bytes: [UInt8], size: Double) -> Double {
        var sum = 0
        for b in bytes where b >= 32 { sum += widths[Int(b) - 32] }
        return Double(sum) * size / 1000.0
    }

    /// Tek satırı sayfa genişliğine göre böler (kelime sınırında; çok uzun kelime karakterden).
    static func wrap(_ line: String, maxWidth: Double, size: Double) -> [[UInt8]] {
        let enc = encode(line)
        if width(enc, size: size) <= maxWidth { return [enc] }
        var lines: [[UInt8]] = []
        var cur: [UInt8] = []
        for piece in enc.split(separator: 32, omittingEmptySubsequences: false) {
            var word = Array(piece)
            let trial = cur.isEmpty ? word : cur + [32] + word
            if width(trial, size: size) <= maxWidth { cur = trial; continue }
            if !cur.isEmpty { lines.append(cur); cur = [] }
            while width(word, size: size) > maxWidth && word.count > 1 {
                var k = word.count
                while k > 1 && width(Array(word[0..<k]), size: size) > maxWidth { k -= 1 }
                lines.append(Array(word[0..<k]))
                word = Array(word[k...])
            }
            cur = word
        }
        if !cur.isEmpty { lines.append(cur) }
        return lines
    }

    private static func escape(_ bytes: [UInt8]) -> Data {
        var out = Data()
        for b in bytes {
            if b == 0x5C || b == 0x28 || b == 0x29 { out.append(0x5C) }
            out.append(b)
        }
        return out
    }

    /// [(sayfa numarası, metin)] -> her metin sayfası için içerik akışı. Boş metinler atlanır.
    static func pages(_ texts: [(number: Int, text: String)]) -> [Data] {
        let perPage = Int((pageHeight - 2 * margin - headSize - 14) / leading)
        let maxW = pageWidth - 2 * margin
        var result: [Data] = []
        for (number, raw) in texts {
            var text = raw.replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\u{0C}", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count > maxChars { text = String(text.prefix(maxChars)) }
            if text.isEmpty { continue }
            var lines: [[UInt8]] = []
            for rawLine in text.components(separatedBy: "\n") {
                if rawLine.trimmingCharacters(in: .whitespaces).isEmpty {
                    lines.append([])
                } else {
                    lines.append(contentsOf: wrap(rawLine, maxWidth: maxW, size: bodySize))
                }
            }
            while let last = lines.last, last.isEmpty { lines.removeLast() }
            var start = 0
            while start < lines.count {
                let chunk = Array(lines[start..<min(start + perPage, lines.count)])
                let head = encode("Sayfa \(number) - okunan metin (OCR)" + (start == 0 ? "" : " (devam)"))
                var content = Data()
                content.append(Data("BT /F2 \(Int(headSize)) Tf \(Int(margin)) \(Int(pageHeight - margin)) Td (".utf8))
                content.append(escape(head))
                content.append(Data(") Tj ET\nBT /F1 \(bodySize) Tf \(leading) TL \(Int(margin)) \(Int(pageHeight - margin - headSize - 20)) Td ".utf8))
                for (i, line) in chunk.enumerated() {
                    if i > 0 { content.append(Data(" T* ".utf8)) }
                    content.append(Data("(".utf8))
                    content.append(escape(line))
                    content.append(Data(") Tj".utf8))
                }
                content.append(Data(" ET".utf8))
                result.append(content)
                start += perPage
            }
        }
        return result
    }

    /// Kodlardan Unicode'a eşleme: kopyalama/arama/yapay zekâ okuması için.
    static func toUnicodeCMap() -> Data {
        var rows: [String] = []
        for code in 32...255 {
            var scalar: UInt32?
            if let tr = turkish.first(where: { $0.value == UInt8(code) }) {
                scalar = tr.key
            } else if let str = String(data: Data([UInt8(code)]), encoding: .windowsCP1252), let first = str.unicodeScalars.first,
                      !turkishCodes.contains(UInt8(code)) {
                scalar = first.value
            }
            if let s = scalar { rows.append(String(format: "<%02lX> <%04X>", code, s)) }
        }
        var out = ["/CIDInit /ProcSet findresource begin", "12 dict begin", "begincmap",
                   "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def",
                   "/CMapName /Adobe-Identity-UCS def", "/CMapType 2 def",
                   "1 begincodespacerange", "<00> <FF>", "endcodespacerange"]
        var i = 0
        while i < rows.count {
            let part = Array(rows[i..<min(i + 100, rows.count)])
            out.append("\(part.count) beginbfchar")
            out.append(contentsOf: part)
            out.append("endbfchar")
            i += 100
        }
        out.append(contentsOf: ["endcmap", "CMapName currentdict /CMap defineresource pop", "end", "end"])
        return Data(out.joined(separator: "\n").utf8)
    }
}
