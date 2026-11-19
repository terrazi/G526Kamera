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

// MARK: - Soru bütünlüğü (taramada hangi soru tam görülmedi)

/// Bir şıkkın bir karedeki görünüşü
struct OptionView: Equatable {
    /// Şıkkın satırlarındaki sözcükler (küçük harf, en az üç harf): başka bir karedeki aynı şıkla eşleştirmek için
    var words: Set<String> = []
    /// Şıkkın satırlarından biri kadrajın sol ya da sağ kenarına dayanıyor (yarım görünüyor)
    var cut = false
}

/// Bir karede görülen soru parçası (bkz. `QuestionSpotter.pieces`): numara satırıyla başlayan bir soru ya da numarası kadrajın dışında kalmış bir
/// sorunun devamı (yakından çekimde uzun soru tek kareye sığmaz; parçalar `QuestionCoverage` içinde birleştirilir)
struct QuestionPiece: Equatable {
    /// Soru numarası; nil: numara satırı karede yok
    var number: Int?
    /// Numaradan sonra, ilk şıkka kadar okunan harf sayısı
    var body = 0
    /// Kök satırlarından biri (numara satırı ve ilk şıkka kadar olanlar) kadrajın sol / sağ kenarına dayanıyor
    var stemCut = false
    /// Karede görülen şıklar
    var options: [Character: OptionView] = [:]
    /// Numarasız parçada: aynı sütunda hemen ardından başlayan sorunun numarası (parça, ondan bir önceki sorunun kuyruğudur)
    var before: Int?

    /// Sıkı kural (bkz. `QuestionSpotter`): satır başında numara, ardında soru metni ve altında en az iki şık
    var isStrict: Bool {
        return number != nil && options.count >= QuestionSpotter.minOptions && body >= QuestionSpotter.minBodyLetters
    }

    /// Günlük için: "47:ABCDE"; kenarda kesik görünen şık küçük harfle ("47:ABCde"); numarasız parça "?:CDE", ardından gelen soru biliniyorsa "<48:DE"
    var summary: String {
        let head = number.map { String($0) } ?? (before.map { "<\($0)" } ?? "?")
        let letters = options.keys.sorted().map { (options[$0]?.cut ?? false) ? String($0).lowercased() : String($0) }.joined()
        return head + ":" + letters + (stemCut ? "!" : "")
    }
}

extension QuestionSpotter {
    /// Satır kutusu kadrajın sol / sağ kenarına bu orandan yakınsa satır kesik sayılır (kadraj koçuyla aynı ölçü)
    static let edge = 0.012
    /// Sol kenarları arasında en az bu kadar boşluk olan satır kümeleri ayrı sütundur (aynı sütunun satırları girinti ve eğiklikle birkaç yüzde oynar)
    static let columnGap = 0.12
    /// Bir şıkkın en çok bu kadar devam satırı sayılır (son şıkkın ardından gelen paragraf o şıkka katılmasın)
    static let maxOptionRows = 4

    private struct PieceRow {
        var text: String
        var top: Double
        var minX: Double
        var maxX: Double
    }

    /// Satırdaki sözcükler: küçük harf, en az üç harf (`TextScore.words` ile aynı kural)
    static func rowWords(_ text: String) -> Set<String> {
        var result = Set<String>()
        for word in text.lowercased().split(whereSeparator: { !$0.isLetter }) where word.count >= 3 {
            result.insert(String(word))
        }
        return result
    }

    /// Sütunlar: satırlar sol kenarlarına göre kümelenir (kısa şık satırı, ortası karşı yarıya düşse de kendi sütununda kalır)
    private static func pieceColumns(_ rows: [PieceRow]) -> [[PieceRow]] {
        var columns: [[PieceRow]] = []
        var current: [PieceRow] = []
        for row in rows.sorted(by: { $0.minX < $1.minX }) {
            if let last = current.last, row.minX - last.minX >= columnGap {
                columns.append(current)
                current = []
            }
            current.append(row)
        }
        if !current.isEmpty { columns.append(current) }
        return columns
    }

    /// `index`'teki numara satırı yeni bir soru mu başlatıyor? Şık görülmemişken her numara satırı başlatır. Şıklar görülmeye başlamışsa yalnız sıradaki
    /// numara (N + 1) ya da ardından, başka bir numara satırına gelmeden, A şıkkını taşıyan bir şık satırı gelen numara başlatır.
    private static func startsQuestion(_ number: Int, after piece: QuestionPiece, rows: [PieceRow], at index: Int) -> Bool {
        if piece.options.isEmpty { return true }
        if let current = piece.number, number == current + 1 { return true }
        var next = index + 1
        while next < rows.count {
            if numbered(rows[next].text) != nil { return false }
            let marks = optionLetters(rows[next].text)
            if !marks.isEmpty { return marks.contains("A") }
            next += 1
        }
        return false
    }

    private static func close(_ piece: QuestionPiece, next: Int?, into result: inout [QuestionPiece]) {
        var closed = piece
        if closed.number == nil {
            // Numarasız ve şıksız satırlar (paragraf, başlık) parça değildir
            if closed.options.isEmpty { return }
            closed.before = next
        }
        result.append(closed)
    }

    /// Karedeki soru parçaları. Kutular Vision ölçüsündedir (0–1, başlangıç sol alt). Her sütun yukarıdan aşağı okunur: numara satırı yeni bir soru
    /// başlatır; şık satırları ve devamları o soruya yazılır; sütunun başında numarasız gelen şıklar "numarasız parça"dır.
    ///
    /// Şıkları görülmeye başlamış bir parçanın içinde satır başında rastlanan numara ancak sıradaki numaraysa (N + 1) ya da ardından yeni bir şık dizisi
    /// (A şıkkı) geliyorsa yeni soru sayılır: şık metninin satır başına düşen "7. yüzyılda" gibi bir sayı soruyu ikiye bölmesin.
    static func pieces(_ lines: [(text: String, box: CGRect)]) -> [QuestionPiece] {
        var rows: [PieceRow] = []
        for line in lines where letters(line.text) > 0 {
            rows.append(PieceRow(text: line.text, top: 1 - Double(line.box.maxY), minX: Double(line.box.minX), maxX: Double(line.box.maxX)))
        }
        var result: [QuestionPiece] = []
        for column in pieceColumns(rows) {
            var piece = QuestionPiece()
            var letter: Character?
            var extraRows = 0
            let ordered = column.sorted(by: { $0.top < $1.top })
            for (index, row) in ordered.enumerated() {
                let cut = row.minX < edge || row.maxX > 1 - edge
                if let start = numbered(row.text), startsQuestion(start.number, after: piece, rows: ordered, at: index) {
                    close(piece, next: start.number, into: &result)
                    piece = QuestionPiece()
                    piece.number = start.number
                    piece.body = start.rest
                    piece.stemCut = cut
                    letter = nil
                    extraRows = 0
                    // Çok kısa soru: şıklar numara satırının içinde olabilir ("3. 2 + 2 kaçtır?  A) 3  B) 4")
                    for inline in optionLetters(row.text) {
                        piece.options[inline] = OptionView(words: [], cut: cut)
                    }
                    continue
                }
                let marks = optionLetters(row.text)
                if marks.isEmpty {
                    if let current = letter {
                        if extraRows >= maxOptionRows { continue }
                        extraRows += 1
                        var view = piece.options[current] ?? OptionView()
                        view.words.formUnion(rowWords(row.text))
                        if cut { view.cut = true }
                        piece.options[current] = view
                    } else if piece.number != nil && piece.options.isEmpty {
                        piece.body += letters(row.text)
                        if cut { piece.stemCut = true }
                    }
                    continue
                }
                // Şık satırı: tek şıksa sözcükleri o şıkka yazılır; birkaç şık yan yanaysa ("A) 5   B) 6") sözcükler şıklara ayrılamaz
                for mark in marks {
                    var view = piece.options[mark] ?? OptionView()
                    if marks.count == 1 { view.words.formUnion(rowWords(row.text)) }
                    if cut { view.cut = true }
                    piece.options[mark] = view
                }
                letter = marks.count == 1 ? marks.first : nil
                extraRows = 0
            }
            close(piece, next: nil, into: &result)
        }
        return result
    }
}

/// Bir taramanın bütün karelerindeki soru parçalarından HANGİ SORUNUN TAM GÖRÜLMEDİĞİNİ çıkarır (saf mantık; birim testle denenir).
///
/// Kullanıcı kararı 2026-11-19: koç yanlış bilgi vermemeli. Bu yüzden hüküm yalnız güçlü kanıtla verilir, şüphede susulur:
/// - Yalnız en az `minFrames` karede sıkı kuralla (numara + kök + iki şık) görülen sorular denetlenir.
/// - Numarası kadrajın dışında kalan devam parçaları soruya iki yoldan bağlanır: aynı sütunda hemen ardından gelen sorunun numarasından (N + 1'in
///   üstündeki şıklar N'nindir) ya da ortak bir şıkkın sözcüklerinden (iki karede de "C" görünüyor ve metinleri aynı).
/// - "Şık hiç görülmedi" ancak görülen şıklar A'dan başlayan kesintisiz bir diziyse (A, B, C: alt taraf kadraja girmemiş) ve taramadaki soruların
///   çoğunda daha ileri bir şık varsa söylenir; aradan eksik harf (A, C, E) yazı tanımanın kaçırmasıdır, sayılmaz.
/// - Hiçbir soruya bağlanamayan bir parçada eksik şık varsa (bağlanamamış devam olabilir) yine susulur.
/// - "Kenarda kesik" ancak şık / kök en az `minCutFrames` karede görülüp HER birinde sol ya da sağ kenara dayanıyorsa söylenir.
struct QuestionCoverage: Equatable {
    static let minFrames = 2
    static let minCutFrames = 3
    /// Beklenen son şık (çoğu soruda E) en az bu kadar soruda görülmüş olmalı
    static let minTopVotes = 2
    /// Devam parçasını bağlamak için ortak şıkta en az bu kadar ortak sözcük ve küçük kümenin bu oranı aranır
    static let minSharedWords = 2
    static let sharedShare = 0.6
    static let letters: [Character] = ["A", "B", "C", "D", "E"]

    struct Entry: Equatable {
        /// Sıkı kuralla görüldüğü kare sayısı ve bunlardan kökü kenara dayanmayanlar
        var frames = 0
        var stemClean = 0
        /// Şık harfi → görüldüğü parça sayısı / kenara dayanmadan görüldüğü parça sayısı / sözcükleri
        var seen: [Character: Int] = [:]
        var clean: [Character: Int] = [:]
        var words: [Character: Set<String>] = [:]

        mutating func absorb(_ piece: QuestionPiece) {
            for (letter, view) in piece.options {
                seen[letter, default: 0] += 1
                if !view.cut { clean[letter, default: 0] += 1 }
                words[letter, default: []].formUnion(view.words)
            }
        }
    }

    /// Tam görülmeyen sorular (artan) ve günlük için nedenleri
    var incomplete: [Int] = []
    var reasons: [Int: String] = [:]
    /// Denetlenen sorular ve görülen şıkları ("ABCDE")
    var checked: [Int: String] = [:]
    /// Taramadaki soruların çoğunda görülen son şık; belirlenemediyse nil ("şık görülmedi" hükmü verilmez)
    var expectedTop: Character?
    /// Hiçbir soruya bağlanamayan devam parçası sayısı
    var orphans = 0

    static func similar(_ a: Set<String>, _ b: Set<String>) -> Bool {
        let small = min(a.count, b.count)
        if small < minSharedWords { return false }
        let common = a.intersection(b).count
        return common >= minSharedWords && Double(common) / Double(small) >= sharedShare
    }

    /// `frames`: geçerli (bozuk ya da bulanık olmayan) her karenin parçaları
    static func make(_ frames: [[QuestionPiece]]) -> QuestionCoverage {
        var result = QuestionCoverage()
        var entries: [Int: Entry] = [:]
        // 1) Sıkı kuralla görülen sorular (kare başına bir kez sayılır)
        for pieces in frames {
            var counted = Set<Int>()
            for piece in pieces where piece.isStrict {
                guard let number = piece.number, !counted.contains(number) else { continue }
                counted.insert(number)
                var entry = entries[number] ?? Entry()
                entry.frames += 1
                if !piece.stemCut { entry.stemClean += 1 }
                entries[number] = entry
            }
        }
        let established = Set(entries.filter { $0.value.frames >= minFrames }.map { $0.key })
        if established.isEmpty { return result }
        // 2) Numaralı parçalar ve ardından gelen sorusu bilinen devam parçaları doğrudan bağlanır
        var loose: [QuestionPiece] = []
        for pieces in frames {
            for piece in pieces {
                var owner: Int?
                if let number = piece.number {
                    owner = number
                } else if let next = piece.before {
                    owner = next - 1
                } else {
                    loose.append(piece)
                    continue
                }
                if let number = owner, established.contains(number), var entry = entries[number] {
                    entry.absorb(piece)
                    entries[number] = entry
                }
            }
        }
        // 3) Kalan devam parçaları ortak şıkkın sözcüklerinden bağlanır; bağlananlar yeni şık getirdikçe öbürleri de bağlanabilir
        var rounds = 0
        var changed = true
        while changed && rounds < 4 {
            changed = false
            rounds += 1
            var rest: [QuestionPiece] = []
            for piece in loose {
                var owners: [Int] = []
                for number in established {
                    guard let entry = entries[number] else { continue }
                    var matches = false
                    for (letter, view) in piece.options {
                        if let known = entry.words[letter], similar(view.words, known) {
                            matches = true
                            break
                        }
                    }
                    if matches { owners.append(number) }
                }
                if owners.count == 1, let number = owners.first, var entry = entries[number] {
                    entry.absorb(piece)
                    entries[number] = entry
                    changed = true
                } else {
                    rest.append(piece)
                }
            }
            loose = rest
        }
        result.orphans = loose.count
        // 4) Beklenen son şık: denetlenen soruların en çoğunda görülen son harf (eşitlikte küçük olan: daha az uyarı)
        var tops: [Character: Int] = [:]
        for number in established {
            if let top = entries[number]?.seen.keys.max() { tops[top, default: 0] += 1 }
        }
        let ranked = tops.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        if let first = ranked.first, first.value >= minTopVotes { result.expectedTop = first.key }
        // 5) Hüküm
        for number in established.sorted() {
            guard let entry = entries[number] else { continue }
            let seen = Set(entry.seen.keys)
            result.checked[number] = String(seen.sorted())
            var reason: String?
            if let top = result.expectedTop, let last = seen.max(), last < top {
                let run = Set(letters.filter { $0 <= last })
                let missing = letters.filter { $0 > last && $0 <= top }
                if seen == run, let firstMissing = missing.first, !loose.contains(where: { $0.options[firstMissing] != nil }) {
                    reason = "\(String(missing)) hiçbir karede görülmedi"
                }
            }
            if reason == nil {
                var cut: [Character] = []
                for letter in letters {
                    let seenCount = entry.seen[letter] ?? 0
                    let cleanCount = entry.clean[letter] ?? 0
                    if seenCount < minCutFrames || cleanCount > 0 { continue }
                    // Bağlanamayan bir parçada bu şık kenara dayanmadan görünüyorsa (bağlanamamış devam olabilir) hüküm verilmez
                    var cleanElsewhere = false
                    for piece in loose {
                        if let view = piece.options[letter], !view.cut { cleanElsewhere = true }
                    }
                    if !cleanElsewhere { cut.append(letter) }
                }
                if !cut.isEmpty {
                    reason = "\(String(cut)) her karede kenarda kesik"
                } else if entry.frames >= minCutFrames && entry.stemClean == 0 {
                    reason = "soru kökü her karede kenarda kesik"
                }
            }
            if let reason = reason {
                result.incomplete.append(number)
                result.reasons[number] = reason
            }
        }
        return result
    }

    /// Günlük satırı: "denetlenen 47:ABCDE 48:ABC; beklenen son şık E; bağlanamayan parça 2; tam görülmeyen 48 (DE hiçbir karede görülmedi)"
    var logText: String {
        if checked.isEmpty { return "denetlenecek soru yok (hiçbir soru iki karede numarası, kökü ve şıklarıyla görülmedi)" }
        let list = checked.keys.sorted().map { "\($0):\(checked[$0] ?? "")" }.joined(separator: " ")
        let top = expectedTop.map { String($0) } ?? "belirsiz"
        let bad = incomplete.map { "\($0) (\(reasons[$0] ?? ""))" }.joined(separator: ", ")
        return "denetlenen \(list); beklenen son şık \(top); bağlanamayan parça \(orphans); tam görülmeyen " + (bad.isEmpty ? "yok" : bad)
    }
}
