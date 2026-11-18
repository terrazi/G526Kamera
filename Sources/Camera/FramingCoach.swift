import Foundation
import CoreGraphics
import CoreVideo
import Vision

// MARK: - Kadrajdaki satırlar

/// Satırın baştan ya da sondan birkaç sözcüğü; iki sütun görünüyorsa hangi yanda olduğu ("solda" / "sağda")
struct LineEnd: Equatable {
    var side: String?
    var words: String

    /// "solda mercimek çorbası" ya da yalnız "mercimek çorbası"
    var phrase: String {
        if let side = side { return side + " " + words }
        return words
    }
}

/// Kadrajın en üstündeki ve en altındaki TAM satırlar ve kenara dayanıp yarım kalan satır var mı (kullanıcı kararı 2026-11-17: "en alttaki satır …
/// ile bitiyor" diye kameranın nereye kadar gördüğü söylensin). Saf mantık: Vision kutularından kurulur, birim testle denenir.
struct ViewLines: Equatable {
    /// Üstteki tam satır(lar): tek sütunda bir, iki sütunda sol ve sağ için birer tane
    var starts: [LineEnd] = []
    /// Alttaki tam satır(lar)
    var ends: [LineEnd] = []
    /// Bir satır kadrajın üst / alt kenarına dayanıyor (yarım görünüyor)
    var topCut = false
    var bottomCut = false
    /// Güveni yeterli satırlardaki harf + rakam sayısı: yazı program tarafından okunabiliyor mu (kullanıcı kararı 2026-11-18: okunuyorsa daha mükemmel
    /// görüntü aranmaz, ilk yeterli görüntü alınır)
    var chars = 0
    /// Kadrajın en üstündeki soru ya da paragrafın KESİK olduğuna dair kanıt YOK: ilk satır kenara dayanmıyor ve numarasız bir şık satırıyla (önceki sorunun
    /// kuyruğu) başlamıyor
    var topComplete = false
    /// Kadrajın en altındaki soru ya da paragrafın KESİK olduğuna dair kanıt YOK: son satır kenara dayanmıyor; son soru numarasından sonra E şıkkı
    /// görünüyor ya da yazı alt kenara yakın bitmiyor
    var bottomComplete = false

    /// Kadrajda başından sonuna (E şıkkı dahil) görünen soruların numaraları: ardışık ve artan değilse (yazı tanıma bir rakamı yanlış okumuş olabilir) boş
    var questions: [Int] = []
    /// Sıradaki soru: kadrajda yarım kalan (numarası görünen) soru, yoksa son tam sorunun ardından gelen numara; güvenilmezse nil
    var nextQuestion: Int?

    /// Yazı okunabiliyor (bkz. `SeriesSelection.minChars`)
    var isReadable: Bool { return chars >= SeriesSelection.minChars }

    /// Satır kutusu kenara bu orandan yakınsa kenara dayalı (kesik) sayılır
    static let edgeEpsilon = 0.012
    /// Bir satırdan en çok kaç sözcük söylenir
    static let maxWords = 4
    /// "Satır" sayılması için en az sözcük (sayfa numarası, tek sözcüklük kırıntı satır sayılmaz)
    static let minWords = 3

    /// Yazıyı sözcüklere ayırır: uçlardaki noktalama atılır, harf ya da rakam taşımayan parçalar düşer
    static func words(_ text: String) -> [String] {
        let junk = CharacterSet.punctuationCharacters.union(.symbols)
        return text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map { String($0).trimmingCharacters(in: junk) }
            .filter { $0.rangeOfCharacter(from: .alphanumerics) != nil }
    }

    private struct Item {
        var words: [String]
        var top: Double
        var bottom: Double
        var midX: Double
    }

    /// `lines`: Vision satırları, kutu başlangıcı SOL ALT, oranlar 0–1. `skipTop`: üstten bu orandaki bant (kameranın saat yazısı) yok sayılır.
    static func make(_ lines: [(text: String, box: CGRect)], skipTop: Double = 0) -> ViewLines {
        var result = ViewLines()
        for line in lines where (2 - Double(line.box.maxY) - Double(line.box.minY)) / 2 >= skipTop {   // saat bandındaki yazı sayılmaz
            result.chars += line.text.filter { ch in ch.isLetter || ch.isNumber }.count
        }
        let blocks = completeness(lines, skipTop: skipTop)
        result.topComplete = blocks.top
        result.bottomComplete = blocks.bottom
        result.questions = blocks.questions
        result.nextQuestion = blocks.next
        var items: [Item] = []
        for line in lines {
            let top = 1 - Double(line.box.maxY)
            let bottom = 1 - Double(line.box.minY)
            guard (top + bottom) / 2 >= skipTop else { continue }   // saat bandındaki yazı
            let words = ViewLines.words(line.text)
            guard !words.isEmpty else { continue }
            let cutTop = top < skipTop + edgeEpsilon
            let cutBottom = bottom > 1 - edgeEpsilon
            if cutTop { result.topCut = true }
            if cutBottom { result.bottomCut = true }
            // Kenara dayanan yarım satırın sözcükleri güvenilmez: başlangıç / bitiş olarak kullanılmaz
            if cutTop || cutBottom || words.count < minWords { continue }
            items.append(Item(words: words, top: top, bottom: bottom, midX: Double(line.box.midX)))
        }
        guard !items.isEmpty else { return result }

        func head(_ item: Item) -> String { return item.words.prefix(maxWords).joined(separator: " ") }
        func tail(_ item: Item) -> String { return item.words.suffix(maxWords).joined(separator: " ") }

        let left = items.filter { $0.midX < 0.5 }
        let right = items.filter { $0.midX >= 0.5 }
        if left.count >= 2 && right.count >= 2 {
            if let a = left.min(by: { $0.top < $1.top }), let b = right.min(by: { $0.top < $1.top }) {
                result.starts = [LineEnd(side: "solda", words: head(a)), LineEnd(side: "sağda", words: head(b))]
            }
            if let a = left.max(by: { $0.bottom < $1.bottom }), let b = right.max(by: { $0.bottom < $1.bottom }) {
                result.ends = [LineEnd(side: "solda", words: tail(a)), LineEnd(side: "sağda", words: tail(b))]
            }
        } else {
            if let a = items.min(by: { $0.top < $1.top }) { result.starts = [LineEnd(side: nil, words: head(a))] }
            if let b = items.max(by: { $0.bottom < $1.bottom }) { result.ends = [LineEnd(side: nil, words: tail(b))] }
        }
        return result
    }

    // MARK: Soru / paragraf bütünlüğü

    private static let numberStart = try? NSRegularExpression(pattern: "^\\s*(\\d{1,3})\\s?[\\.\\)]\\s*\\S", options: [])
    private static let optionE = try? NSRegularExpression(pattern: "^\\s*\\(?E\\s?[\\)\\.]", options: [])
    private static let optionAny = try? NSRegularExpression(pattern: "^\\s*\\(?[A-E]\\s?[\\)\\.]\\s*\\S", options: [])
    /// Alt kenara bu kadar yakın biten (kadraj yüksekliğinin %12'si) yazının devamı kadrajın dışında olabilir
    private static let nearEdge = 0.12

    private static func matches(_ pattern: NSRegularExpression?, _ text: String) -> Bool {
        guard let pattern = pattern else { return false }
        return pattern.firstMatch(in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil
    }

    /// "34. Aşağıdakilerden …" satırından 34
    private static func questionNumber(_ text: String) -> Int? {
        guard let pattern = numberStart,
              let match = pattern.firstMatch(in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text)),
              match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[r])
    }

    /// `completeness` sonucu: üst / alt tam mı, kadrajda tam görünen sorular ve sıradaki soru
    struct Blocks {
        var top = false
        var bottom = false
        var questions: [Int] = []
        var next: Int?
    }

    private struct Row {
        var text: String
        var top: Double
        var bottom: Double
        var midX: Double
        var cutTop: Bool
        var cutBottom: Bool
    }

    /// Kadrajın en üstündeki ve en altındaki soru / paragrafın KESİK olduğuna dair kanıt var mı (kullanıcı kararı 2026-11-18: bir sorunun ya da paragrafın metni
    /// tam görünmeden kabul edilmez; gerekirse "Uzaklaşın" denip tüm sayfa istenir). Gerçek günlük: yazı tanıma soru numarasını çoğu karede okumuyor; bu yüzden
    /// "numarayla başlamıyor = kesik" denemez, yalnız KANIT aranır. Satırlar üstten alta, sütun sütun okunur (iki sütunda her biri ayrı).
    /// ÜST kesik: ilk satır kadrajın kenarına dayanıyor ya da numarasız bir şık satırıyla başlıyor (önceki sorunun kuyruğu).
    /// ALT kesik: son satır kenara dayanıyor; ya da son soru numarasından sonra E şıkkı yokken yazı alt kenara yakın bitiyor (soru dibe uzanıyor); ya da
    /// E'den sonra alt kenara yakın bitecek kadar (en az üç) satır var (başka bir paragraf başlamış). Numara hiç görünmüyorsa (paragraf, başlık) kanıt yoktur.
    /// Kâğıdın üst / alt kenarı görünüyorsa (tam sayfa) çağıran bu denetimi aşar. Yazı bulunmazsa ikisi de false.
    static func completeness(_ lines: [(text: String, box: CGRect)], skipTop: Double = 0) -> Blocks {
        var rows: [Row] = []
        for line in lines {
            let top = 1 - Double(line.box.maxY)
            let bottom = 1 - Double(line.box.minY)
            guard (top + bottom) / 2 >= skipTop, !words(line.text).isEmpty else { continue }
            rows.append(Row(text: line.text, top: top, bottom: bottom, midX: Double(line.box.midX),
                            cutTop: top < skipTop + edgeEpsilon, cutBottom: bottom > 1 - edgeEpsilon))
        }
        guard !rows.isEmpty else { return Blocks() }
        // İki sütun: satırların orta noktaları açıkça sol ve sağ yarıya dağılmışsa; tek sütunda uzun satırların ortası kadrajın ortasındadır
        let left = rows.filter { $0.midX < 0.45 }
        let right = rows.filter { $0.midX > 0.55 }
        let columns: [[Row]]
        if left.count >= 3 && right.count >= 3 {
            columns = [left, right]
        } else {
            columns = [rows]
        }
        var topOK = true
        var bottomOK = true
        var done: [Int] = []
        var notDone: [Int] = []
        for column in columns {
            let ordered = column.sorted { $0.top < $1.top }
            guard let first = ordered.first else { continue }
            // Sütundaki numaralı sorular: E şıkkına kadar görünen ve numara satırı kenara dayanmayan soru "tam"dır, öteki yarım kalmıştır
            let starts = ordered.indices.compactMap { i in questionNumber(ordered[i].text).map { (index: i, number: $0) } }
            for (k, start) in starts.enumerated() {
                let end = k + 1 < starts.count ? starts[k + 1].index : ordered.count
                let slice = ordered[start.index..<end]
                var complete = !ordered[start.index].cutTop && slice.contains { matches(optionE, $0.text) }
                if complete, k == starts.count - 1, let e = slice.firstIndex(where: { matches(optionE, $0.text) }) {
                    let after = ordered[(e + 1)...]
                    if after.count > 2 || ordered[e].cutBottom || after.contains(where: { $0.cutBottom }) { complete = false }
                }
                if complete { done.append(start.number) } else { notDone.append(start.number) }
            }
            // KESİK KANITI (gerçek günlük 2026-11-18: yazı tanıma soru numarasını çoğu karede okumadığı için "numarayla başlamıyor = kesik" saymak her
            // görüntüyü reddetti): ÜST kesik yalnız ilk satır kenara dayanıyorsa ya da numarasız bir ŞIK satırıyla başlıyorsa (önceki sorunun kuyruğu)
            if first.cutTop || (matches(optionAny, first.text) && !matches(numberStart, first.text)) { topOK = false }
            // ALT kesik: son satır kenara dayanıyorsa; ya da son soru numarasından sonra E şıkkı yokken yazı alt kenara yakın bitiyorsa (soru dibe uzanıyor);
            // ya da E'den sonra alt kenara yakın bitecek kadar çok satır varsa (başka bir paragraf başlamış). Numara hiç görünmüyorsa (paragraf, başlık)
            // kanıt yoktur: kesik sayılmaz
            guard let last = ordered.last else { continue }
            if last.cutBottom {
                bottomOK = false
            } else if last.bottom >= 1 - nearEdge, let n = ordered.lastIndex(where: { matches(numberStart, $0.text) }) {
                if let e = ordered[(n + 1)...].firstIndex(where: { matches(optionE, $0.text) }) {
                    if ordered[(e + 1)...].count > 2 { bottomOK = false }
                } else {
                    bottomOK = false
                }
            }
        }
        var result = Blocks(top: topOK, bottom: bottomOK)
        // Numaralar yalnız ardışık ve artansa güvenilir (yazı tanıma bir rakamı yanlış okuyabilir; iki sütunda sol sütun önce gelir): yoksa söylenmez
        done.sort()
        let consecutive = zip(done, done.dropFirst()).allSatisfy { $1 == $0 + 1 }
        if let last = done.last, consecutive {
            // Yarım kalan soru yalnız son tam sorudan SONRA geliyorsa sıradakidir (üst kenarda kesilen numara önceki sorudur)
            let next = notDone.filter { $0 > last }.min() ?? last + 1
            if next == last + 1 {
                result.questions = done
                result.next = next
            }
        }
        return result
    }

    /// Üst taraf: "Üstte A ile başlıyor." ya da üst satır kesikse "Üst satır yarım kalıyor; ilk tam satır A ile başlıyor."
    var startsText: String? {
        let phrase = starts.map { $0.phrase }.joined(separator: ", ")
        if topCut { return starts.isEmpty ? "Üst satır yarım kalıyor." : "Üst satır yarım kalıyor; ilk tam satır " + phrase + " ile başlıyor." }
        return starts.isEmpty ? nil : "Üstte " + phrase + " ile başlıyor."
    }

    /// Alt taraf: "Altta B ile bitiyor." ya da alt satır kesikse "Alt satır yarım kalıyor; son tam satır B ile bitiyor."
    var endsText: String? {
        let phrase = ends.map { $0.phrase }.joined(separator: ", ")
        if bottomCut { return ends.isEmpty ? "Alt satır yarım kalıyor." : "Alt satır yarım kalıyor; son tam satır " + phrase + " ile bitiyor." }
        return ends.isEmpty ? nil : "Altta " + phrase + " ile bitiyor."
    }

    /// "Üstte A ile başlıyor. Altta B ile bitiyor." Satır bilgisi yoksa nil.
    var coverage: String? {
        let parts = [startsText, endsText].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Canlı koçun kısa söylenişi (kullanıcı kararı 2026-11-17: cümle değil kelime): "Üstte: A." ya da üst satır kesikse "Üst satır kesik; ilk tam: A."
    var startsShort: String? {
        let phrase = starts.map { $0.phrase }.joined(separator: ", ")
        if topCut { return starts.isEmpty ? "Üst satır kesik." : "Üst satır kesik; ilk tam: " + phrase + "." }
        return starts.isEmpty ? nil : "Üstte: " + phrase + "."
    }

    /// "Altta: B." ya da alt satır kesikse "Alt satır kesik; son tam: B."
    var endsShort: String? {
        let phrase = ends.map { $0.phrase }.joined(separator: ", ")
        if bottomCut { return ends.isEmpty ? "Alt satır kesik." : "Alt satır kesik; son tam: " + phrase + "." }
        return ends.isEmpty ? nil : "Altta: " + phrase + "."
    }

    var shortCoverage: String? {
        let parts = [startsShort, endsShort].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// Kareyi okuyup satırları çıkarır (Vision, hızlı kip). Yalnız kamera durgunken ve seyrek çağrılır.
enum ViewLinesReader {
    static func read(_ pixelBuffer: CVPixelBuffer, orientation: ImageOrientation) -> ViewLines? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
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
        let skip = orientation == .normal ? GuidanceAnalyzer.skipTop : 0
        return ViewLines.make(lines, skipTop: skip)
    }
}

// MARK: - Kadraj koçu

/// Sayfa için çekim planı (kullanıcı kararı 2026-11-18: sistem kamerayı kendisi tutsaydı sayfayı nasıl çekerdi?): önce TÜM SAYFA tek seferde (kenarlar kadrajda
/// ve yazı okunuyor); birkaç konumlandırma denemesinde tam sayfa olmuyorsa ya da tam sayfa okunmayacak kadar küçük kalıyorsa ÜST YARI / ALT YARI.
/// `any`: plan yok (kadraj ne ise o kabul edilir; "Kadraj kontrolü" ve eski davranış).
enum ShotPlan: Equatable {
    case any, wholePage, halves
}

/// Koçun bir değerlendirmesi: ne durumda ve ne söylenecek
struct FramingNote: Equatable {
    enum Kind: String, Equatable {
        case noText, blurry, glare, cutLeft, cutRight, shiftLeft, shiftRight, tooWide, tooSmall, emptyTop, middle
        /// Kare bozuk (bloklaşmış): hiçbir zaman kabul edilmez; `incomplete`: soru ya da paragraf tam görünmüyor (kullanıcı kararı 2026-11-18)
        case damaged, incomplete
        /// Çekim planı (bkz. `ShotPlan`): `wholePage` tüm sayfa için uzaklaşılması, `halves` tam sayfanın olmadığı / okunmadığı için yarım yarım çekime geçilmesi
        case wholePage, halves
        /// Düzeltme gerekmiyor: `good` kâğıt kenarı bilinmiyorken; `goodFull` tam sayfa, `goodUpper` üst yarı, `goodLower` alt yarı
        case good, goodFull, goodUpper, goodLower

        var isGood: Bool { return self == .good || self == .goodFull || self == .goodUpper || self == .goodLower }

        /// Yazı okunabiliyorsa değişebilecek (iptal olabilecek) değerlendirme: yazı tanıma sonucu gelene kadar beklenir (bkz. `FramingCoachTimer`).
        /// Kenar kesikleri, "uzaklaşın", "yazı yok", bozuk kare ve eksik metin yazı tanımaya bakmadan söylenir.
        var awaitsText: Bool {
            switch self {
            case .blurry, .glare, .shiftLeft, .shiftRight, .tooSmall, .emptyTop, .middle, .good, .goodFull, .goodUpper, .goodLower: return true
            case .noText, .cutLeft, .cutRight, .tooWide, .damaged, .incomplete, .wholePage, .halves: return false
            }
        }
    }
    var kind: Kind
    var text: String

    /// Kullanıcıdan bir şey isteyen (düzeltme) değerlendirme mi
    var isCorrection: Bool { return !kind.isGood }
}

/// Sayfanın kadrajdaki konumu (kâğıt kenarları, Apple Vision): üç durum vardır (kullanıcı kararı 2026-11-17).
/// `full`: dört kenar da kadrajın içinde, boşluklu. `upperHalf`: üst, sol ve sağ kenar boş, alt kenardan sayfa devam ediyor (alttaki sorunun bir bölümü
/// girmiş olabilir). `lowerHalf`: alt, sol ve sağ kenar boş, üst kenardan sayfa devam ediyor. `middle`: üst ve alt kenar ikisi de kadraj dışında
/// (sayfanın ortasından bir dilim); bu bir düzeltme sebebidir.
enum PageLayout: Equatable {
    case full, upperHalf, lowerHalf, middle
}

struct PageLayoutReading: Equatable {
    var layout: PageLayout
    /// Kâğıdın kadraj dışına taşan sol / sağ kenarları (yazı tam görünse bile kâğıt yandan taşabilir)
    var cutSides: [PageEdges.Side]
    /// Dört kenar da belirgin boşlukla kadrajın içinde
    var allClear: Bool
}

/// Toplu çekimde sesli konumlandırma DESTEĞİ (kullanıcı kararı 2026-11-17, Ayarlar > "Toplu çekimde sesli konumlandırma"): çekimi başlatmaz ya da
/// bitirmez, yalnız kadrajın durumunu kısa cümlelerle söyler: hangi kenar kesik, sağa / sola kayma, yakın ve bulanıksa uzaklaşma, yazı küçükse
/// yaklaşma, üstte boşluk varsa aşağı kaydırma; düzeltme gerekmiyorsa sayfanın hangi durumda göründüğü (tam sayfa, üst yarı, alt yarı) ve yarım
/// görünümde kesik kenardan hangi satırın başlayıp bittiği.
/// Ölçüler tek soru çekimindeki yönlendirmeyle aynıdır (`GuidanceAdvisor`); farkı: dikey kesik bir sorun sayılmaz (sayfa kadrajdan büyüktür,
/// toplu çekimde yukarıdan aşağı kaydırılır), bunun yerine sayfanın konumu ve satır tarifi verilir.
enum FramingCoach {
    /// Yazının üst kenarı kadrajın bu oranından aşağıdaysa üst taraf boştur (kamera sayfanın üstünde kalmış)
    static let emptyTopLimit = 0.42
    /// Yazının alt kenarı kadrajın bu oranından yukarıdaysa alt taraf boştur (yalnız bilgi verilir: sayfa sonu olabilir)
    static let emptyBottomLimit = 0.55

    /// Kâğıt kenarlarından sayfanın durumu; kenarlar bilinmiyorsa (ölçülmedi, güvenilmez, yazıya yapışık) ya da üst / alt kenar belirsizse nil
    static func layout(_ m: PageMetrics) -> PageLayoutReading? {
        guard let e = GuidanceScene.usableEdges(m) else { return nil }
        let layout: PageLayout
        switch (e.state(.top), e.state(.bottom)) {
        case (.clear, .clear): layout = .full
        case (.clear, .cut): layout = .upperHalf
        case (.cut, .clear): layout = .lowerHalf
        case (.cut, .cut): layout = .middle
        default: return nil
        }
        let sides = [PageEdges.Side.left, PageEdges.Side.right].filter { e.state($0) == .cut }
        return PageLayoutReading(layout: layout, cutSides: sides, allClear: e.allClear)
    }

    /// Canlı koçta kelime ("Tam sayfa.", "Üst yarı.", "Alt yarı.", "Sağ kenar dışarıda."); ayrıntılıysa ("Kadraj kontrolü") tam cümle:
    /// "Tam sayfa görünüyor, dört kenar boş." / "Sayfanın üst yarısı görünüyor, üst, sol ve sağ kenar boş." (+ kesik kenar açıklaması)
    static func layoutText(_ r: PageLayoutReading, verbose: Bool) -> String {
        if !verbose {
            let outside = r.cutSides.isEmpty ? "" : r.cutSides.map { $0.word }.joined(separator: " ve ") + " kenar dışarıda."
            let name: String
            switch r.layout {
            case .full: name = r.cutSides.isEmpty ? "Tam sayfa." : "Üst ve alt boş;"
            case .upperHalf: name = r.cutSides.isEmpty ? "Üst yarı." : "Üst yarı;"
            case .lowerHalf: name = r.cutSides.isEmpty ? "Alt yarı." : "Alt yarı;"
            case .middle: name = "Sayfa ortası."
            }
            return outside.isEmpty ? name : name + " " + outside
        }
        // Kâğıt yandan taşıyorsa "dört kenar boş" denmez: "sağ kenarı kadrajın dışında kalıyor" / "sol ve sağ kenarları kadrajın dışında kalıyor"
        let sideClause = r.cutSides.isEmpty ? "" : r.cutSides.map { $0.word }.joined(separator: " ve ") + (r.cutSides.count == 1 ? " kenarı" : " kenarları") + " kadrajın dışında kalıyor"
        switch r.layout {
        case .full:
            if !r.cutSides.isEmpty { return "Sayfanın üstü ve altı görünüyor; " + sideClause + "." }
            return r.allClear ? "Tam sayfa görünüyor, dört kenar boş." : "Tam sayfa görünüyor."
        case .upperHalf:
            if !r.cutSides.isEmpty { return "Sayfanın üst yarısı görünüyor; " + sideClause + "." }
            return "Sayfanın üst yarısı görünüyor, üst, sol ve sağ kenar boş." + (verbose ? " Alt kenardan alttaki sorunun bir bölümü giriyor olabilir." : "")
        case .lowerHalf:
            if !r.cutSides.isEmpty { return "Sayfanın alt yarısı görünüyor; " + sideClause + "." }
            return "Sayfanın alt yarısı görünüyor, alt, sol ve sağ kenar boş." + (verbose ? " Üst kenardan üstteki sorunun bir bölümü giriyor olabilir." : "")
        case .middle:
            return "Sayfanın ortası görünüyor, üst ve alt kenar kadraj dışında."
        }
    }

    /// Düzgün kadraj ("düzeltme gerekmiyor") için kısa söyleniş; düzeltmeden sonra tek başına "Tamam." olur
    static let okText = "Uygun."

    /// Düzgün kadrajda (kullanıcı kararı 2026-11-18: "Uygun, çekildi" değil, yalnız "Alındı / Sonraki") sayfanın alındığı ve sıradakine geçilebileceği söylenir:
    /// görünüm durgun ve okunaklıyken kareler zaten kaydedilmektedir. "Uygun." ve düzeltmeden sonraki "Tamam." → "Alındı. Sonraki."; "Tamam. Üstte: …" →
    /// "Üstte: … Alındı. Sonraki."; sayfa durumu ("Tam sayfa.", "Alt yarı. …") ve "Alt boş." gibi cümlelerin sonuna " Alındı. Sonraki." eklenir.
    /// Düzeltme isteyen cümlelere eklenmez (çağıran yalnız düzgün kadrajda çağırır).
    static let capturedText = "Alındı. Sonraki."

    /// Tam sayfa tek karede olmuyor ya da okunmuyor: yarım yarım çekilir (her yarıda soru tam görünür). "Uzaklaşın" ile "Yaklaşın" arasında gidip gelinmez
    static let halvesText = "Tam sayfa olmuyor; yarım yarım çekin."

    static func withCapture(_ text: String, capture: String? = nil) -> String {
        let tail = capture ?? capturedText
        if text == okText || text == "Tamam." { return tail }
        if text.hasPrefix("Tamam. ") { return String(text.dropFirst("Tamam. ".count)) + " " + tail }
        return text + " " + tail
    }

    /// Alınan soruların ve sıradakinin söylenişi (kullanıcı kararı 2026-11-18): "34. ve 35. sorular tamam, sıradaki 36. soru." Kullanıcı bunu gözüyle
    /// gördüğü sayfadaki numaralarla karşılaştırıp neyin alındığını, hangisine geçeceğini ve ne kadar kaydıracağını anlar; atlanan soru kendiliğinden
    /// fark edilir. Numaralar güvenilir okunmadıysa nil (çağıran "Alındı. Sonraki." der; bkz. `ViewLines.questions`).
    static func questionsText(_ lines: ViewLines?) -> String? {
        guard let lines = lines, let first = lines.questions.first, let last = lines.questions.last, let next = lines.nextQuestion else { return nil }
        let said: String
        switch lines.questions.count {
        case 1: said = "\(first). soru"
        case 2: said = "\(first). ve \(last). sorular"
        default: said = "\(first). ile \(last). arası sorular"
        }
        return "\(said) tamam, sıradaki \(next). soru."
    }

    /// "azıcık" → "Azıcık" (Türkçe büyük harfle)
    static func capitalised(_ s: String) -> String {
        return String(s.prefix(1)).uppercased(with: Locale(identifier: "tr_TR")) + String(s.dropFirst())
    }

    /// `verbose` false (canlı koç): kelime ("Biraz sağa.", "Uzaklaşın.", "Bulanık, sabit tutun."); true ("Kadraj kontrolü"): tam cümle
    ///
    /// `firstReadable` (canlı koç; kullanıcı kararı 2026-11-18): görüntü kadraja sığıyor ve program okuyabiliyorsa daha mükemmel görüntü için düzeltme
    /// istenmez, ilk yeterli görüntü kabul edilir. Bozuk (bloklu) kare hiçbir zaman kabul edilmez; soru ya da paragraf tam görünmüyorsa (üstte numarasız
    /// başlıyor ya da altta E şıkkına varmadan bitiyor) kabul edilmez, tüm sayfa için "Uzaklaşın" denir (kâğıdın üst / alt kenarı görünüyorsa tam
    /// sayfa görünüyordur: sayılır). Okunduğu kanıtlanınca "yaklaşın, bulanık, parlama, üst boş, sayfa ortası" gibi iyileştirmeler söylenmez;
    /// yalnız yan kenar kesiği ve taşma (kadraja sığmama) düzeltilir.
    /// `plan` (yalnız `firstReadable` ile): `wholePage`: önce tüm sayfa; kâğıdın dört kenarı görünüp yazı okunuyorsa kabul, sayfa yarım / ortadan bir dilim
    /// görünüyorsa "Tüm sayfa için uzaklaşın", tam sayfa görünüp okunmuyorsa ya da küçük yazı yüzünden yaklaşmak gerekecekse `halves` (yarım yarım çekim).
    /// `halves`: tam görünen yarım ya da dilim kabul edilir; soru kesikse hangi yöne kaydırılacağı söylenir.
    static func note(_ m: PageMetrics, lines: ViewLines?, config c: GuidanceConfig = GuidanceConfig(), sharpFloor: Double = 0.45,
                     verbose: Bool = false, firstReadable: Bool = false, plan: ShotPlan = .any) -> FramingNote {
        if firstReadable && m.damaged {
            return FramingNote(kind: .damaged, text: verbose ? "Görüntü bozuk. Kamerayı sabit tutun." : "Bozuk, sabit tutun.")
        }
        var d = GuidanceAdvisor.decide(m, config: c, sharpFloor: sharpFloor)
        let proven = firstReadable && lines?.isReadable == true
        if firstReadable, plan == .wholePage, let lines = lines, !lines.isReadable {
            // Yazı tanıma bu görünümü okuyamadı: yaklaşmak gerekecekse ya da tam sayfa zaten kadrajdaysa (daha uzaklaşılamaz) tam sayfa olmaz
            let small = d.advice == .closer || (d.advice.isMove && d.scale > 1)
            if small || (d.advice == .ok && layout(m)?.layout == .full) {
                return FramingNote(kind: .halves, text: halvesText)
            }
        }
        if proven { d = relaxed(d) }
        switch d.advice {
        case .noText:
            return FramingNote(kind: .noText, text: verbose ? "Yazı görünmüyor. Kamerayı sayfaya çevirin." : "Yazı yok.")
        case .blurry:
            let close = d.fill >= 0.7
            if verbose {
                return FramingNote(kind: .blurry, text: close ? "Görüntü net değil, çok yakınsınız. Biraz uzaklaşın." : "Görüntü net değil. Kamerayı sabit tutun.")
            }
            return FramingNote(kind: .blurry, text: close ? "Bulanık, uzaklaşın." : "Bulanık, sabit tutun.")
        case .glare:
            return FramingNote(kind: .glare, text: verbose ? "Sayfada parlama var. Kamerayı biraz eğin." : "Parlama. Kamerayı eğin.")
        case .moveLeft, .moveRight, .moveUp, .moveDown:
            let word = GuidanceAdvisor.amountWord(shift: d.shift, config: c)
            let dir = d.advice.directionWord
            if d.scale > 1 {
                // Yazı kesik değil, küçük: yakınlaşınca taşacağı için önce ortalanır
                let kind: FramingNote.Kind = d.advice == .moveRight ? .shiftRight : .shiftLeft
                let text = verbose ? "Yazı küçük. Önce kamerayı \(word) \(dir) kaydırıp sonra yaklaşın." : "\(capitalised(word)) \(dir), sonra yaklaşın."
                return FramingNote(kind: kind, text: text)
            }
            let side = d.advice == .moveRight ? "Sağ" : "Sol"
            let kind: FramingNote.Kind = d.advice == .moveRight ? .cutRight : .cutLeft
            return FramingNote(kind: kind, text: verbose ? "\(side) taraf kesik. Kamerayı \(word) \(dir) kaydırın." : "\(capitalised(word)) \(dir).")
        case .farther:
            return FramingNote(kind: .tooWide, text: verbose ? "Sayfa kadraja sığmıyor. Biraz uzaklaşın." : "Uzaklaşın.")
        case .closer:
            return FramingNote(kind: .tooSmall, text: verbose ? "Yazı küçük kalıyor. Biraz yaklaşın." : "Yaklaşın.")
        case .ok:
            break
        }
        // Düzeltme gerekmiyor: sayfanın üç durumdan hangisinde göründüğü kâğıt kenarlarından bilinir
        let reading = layout(m)
        if proven, let lines = lines {
            // Okunuyor: soru / paragraf tam görünüyor mu? Kâğıdın üst (alt) kenarı görünüyorsa üst (alt) taraf tamdır
            let topSeen = reading?.layout == .full || reading?.layout == .upperHalf
            let bottomSeen = reading?.layout == .full || reading?.layout == .lowerHalf
            if plan == .wholePage, let r = reading {
                // Tam sayfa öncelikli: dört kenar kadrajdaysa kabul; değilse tüm sayfa için uzaklaşılır
                if r.layout == .full { return FramingNote(kind: .goodFull, text: layoutText(r, verbose: verbose)) }
                return FramingNote(kind: .wholePage, text: "Tüm sayfa için uzaklaşın.")
            }
            let topOK = lines.topComplete || topSeen
            let bottomOK = lines.bottomComplete || bottomSeen
            if !(topOK && bottomOK) {
                if plan == .halves && (topOK || bottomOK) {
                    // Yarımda yalnız bir uç kesik: soru kadrajın yukarısında / aşağısında devam ediyor, kamera o yöne kaydırılır
                    let direction = topOK ? "Metin kesik, biraz aşağı." : "Metin kesik, biraz yukarı."
                    return FramingNote(kind: .incomplete, text: [direction, lines.shortCoverage].compactMap { $0 }.joined(separator: " "))
                }
                return FramingNote(kind: .incomplete, text: verbose ? "Soru ya da paragraf tam görünmüyor. Tüm sayfa için uzaklaşın." : "Metin kesik, uzaklaşın.")
            }
            // Yeterli görüntü: sayfanın durumu ve kabul. Yarımlarda ilk ve son satırdan birkaç sözcük de okunur (kullanıcı kararı 2026-11-18: kullanıcı
            // okunanı gözüyle gördüğü sayfadaki satırlarla karşılaştırıp kaydırmayı buna göre doğru yapar); tam sayfada satır tarifi gerekmez
            // Soru numaraları okunduysa ("34. ve 35. sorular tamam, sıradaki 36. soru") satır sözcükleri okunmaz: numaralar hem daha kısa hem daha güvenilir
            let tails = (plan == .halves && questionsText(lines) == nil) ? lines.shortCoverage : nil
            if let r = reading, r.layout != .middle {
                let kind: FramingNote.Kind = r.layout == .upperHalf ? .goodUpper : (r.layout == .lowerHalf ? .goodLower : .goodFull)
                let spoken = [layoutText(r, verbose: verbose), r.layout == .full ? nil : tails].compactMap { $0 }
                return FramingNote(kind: kind, text: spoken.joined(separator: " "))
            }
            return FramingNote(kind: .good, text: tails ?? (verbose ? "Kadraj uygun." : okText))
        }
        if let reading = reading, reading.layout == .middle {
            let tail = verbose ? " Tam sayfa için uzaklaşın; yarım sayfa için kamerayı yukarı ya da aşağı kaydırın." : " Uzaklaşın ya da kaydırın."
            return FramingNote(kind: .middle, text: layoutText(reading, verbose: verbose) + tail)
        }
        if m.y0 - c.topBand > emptyTopLimit {
            return FramingNote(kind: .emptyTop, text: verbose ? "Yazı kadrajın alt yarısında, üst taraf boş. Kamerayı biraz aşağı kaydırın." : "Üst boş, biraz aşağı.")
        }
        if let reading = reading {
            // Yarım görünümde kesik kenardan hangi satırın başlayıp bittiği söylenir; tam sayfada satır tarifine gerek yoktur
            var parts = [layoutText(reading, verbose: verbose)]
            let kind: FramingNote.Kind
            switch reading.layout {
            case .upperHalf:
                kind = .goodUpper
                if let text = (verbose ? lines?.endsText : lines?.endsShort) { parts.append(text) }
            case .lowerHalf:
                kind = .goodLower
                if let text = (verbose ? lines?.startsText : lines?.startsShort) { parts.append(text) }
            default:
                kind = .goodFull
            }
            return FramingNote(kind: kind, text: parts.joined(separator: " "))
        }
        var parts: [String] = []
        if m.y1 < emptyBottomLimit { parts.append(verbose ? "Yazı kadrajın üst yarısında, alt taraf boş." : "Alt boş.") }
        if let coverage = (verbose ? lines?.coverage : lines?.shortCoverage) { parts.append(coverage) }
        if parts.isEmpty { parts.append(verbose ? "Kadraj uygun." : okText) }
        return FramingNote(kind: .good, text: parts.joined(separator: " "))
    }

    /// Yazı okunabildiği kanıtlanmış görünümde yazının küçüklüğü, bulanıklığı, parlaması ve "yazı yok" kararı iptal edilir (okunuyor: daha mükemmel
    /// görüntüye gerek yok). Gerçek kenar kesiği ve kadraja sığmama (uzaklaşın) olduğu gibi kalır; "önce kaydır sonra yaklaş" (küçük yazı) iptal olur.
    static func relaxed(_ d: GuidanceDecision) -> GuidanceDecision {
        switch d.advice {
        case .noText, .blurry, .glare, .closer:
            return GuidanceDecision(advice: .ok, fill: d.fill)
        case .moveLeft, .moveRight, .moveUp, .moveDown:
            return d.scale > 1 ? GuidanceDecision(advice: .ok, fill: d.fill) : d
        case .farther, .ok:
            return d
        }
    }

    /// "Kadraj kontrolü" için tam tarif: kaç sayfa görünüyor ve hangisi kesik, varsa düzeltme, sayfanın durumu, satır tarifi. Yazı yoksa yalnız nedeni.
    static func describe(_ m: PageMetrics, lines: ViewLines?, config c: GuidanceConfig = GuidanceConfig(), sharpFloor: Double = 0.45) -> String {
        let n = note(m, lines: lines, config: c, sharpFloor: sharpFloor, verbose: true)
        guard m.hasText, n.kind != .noText else { return n.text }
        var parts: [String] = []
        let scenes = GuidanceScene.parts(m, config: c)
        // Sayfanın durumu zaten söyleniyorsa ("Tam sayfa görünüyor…") tek sayfa cümlesi tekrarlanmaz
        let layoutSaid = [FramingNote.Kind.goodFull, .goodUpper, .goodLower, .middle].contains(n.kind)
        if !(layoutSaid && scenes.count == 1), let scene = GuidanceScene.describe(scenes, edges: GuidanceScene.usableEdges(m)) { parts.append(scene) }
        parts.append(n.text)
        if n.isCorrection, n.kind != .middle, let coverage = lines?.coverage { parts.append(coverage) }
        return parts.joined(separator: " ")
    }

    /// İki sözcük kümesinin örtüşmesi (kesişim / küçük kümenin boyu); biri boşsa 0
    static func overlap(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(min(a.count, b.count))
    }
}

/// Koçun konuşma zamanlaması (saf mantık): kamera durgunlaşınca ve aynı değerlendirme ardışık iki ölçümde çıkınca söyler; aynı cümleyi sık tekrarlamaz,
/// aynı düzeltmeyi en çok üç kez söyler (ısrar edilmez), "tamam"ı düzeltmeden sonra bir kez söyler, düzgün kadrajda yalnız görünüm değişince yeniden anlatır.
/// YENİ SAYFA (kullanıcı kararı 2026-11-17: gösterilen her sayfa için yardım yeniden başlar): kamera hareket edip yeniden durunca görünümün satır
/// sözcükleri öncekiyle büyük ölçüde örtüşmüyorsa (ya da okunamadıysa) sayaçlar, tekrar aralıkları ve "tamam" durumu sıfırlanır; ilk değerlendirme hemen söylenir.
/// Aynı sayfada küçük bir kaydırma (düzeltme denemesi) örtüşmeyi bozmaz: o zaman sayaçlar sürer.
struct FramingCoachTimer {
    struct Config {
        /// Kamera bu süredir durgunsa değerlendirilir
        var stillNeeded: TimeInterval = 0.35
        /// Durgunluk bundan kısaysa kamera oynuyor sayılır (sayfa değişmiş olabilir)
        var movingBelow: TimeInterval = 0.15
        /// İki konuşma arası en az süre
        var speakGap: TimeInterval = 1.5
        /// Aynı değerlendirmenin yeniden söylenme aralığı
        var repeatGap: TimeInterval = 6
        /// Kaç ardışık ölçüm aynı çıkınca söylenir
        var stable = 2
        /// Aynı düzeltme art arda en çok kaç kez söylenir
        var maxSameCorrection = 3
        /// Hareketten sonra satırlar okunana kadar en çok bu kadar beklenir (sayfa değişti mi diye bakılır); sonra yeni sayfa sayılır
        var lineWait: TimeInterval = 1.5
        /// Kâğıt kenarları bekleniyorsa (ayar açık) düzgün kadraj cümlesi için durgunluk en az bu kadar sürmeli: üç durum (tam / üst / alt) kenarlardan bilinir
        var edgeWait: TimeInterval = 0.9
        /// Bir sayfada (görünümde) en çok bu kadar cümle söylenir: ölçüm gürültüsü kulaklıkta sürekli konuşmaya dönüşmesin (yeni sayfada sıfırlanır)
        var maxPerView = 8
        /// Sözcük örtüşmesi bundan azsa görünüm yeni sayfadır
        var sameView = 0.4
        /// Sayfa karşılaştırmasında bundan kısa sözcükler ("ve", "bir", "için") sayılmaz
        var minWordLength = 4
        /// Tam sayfa için bu kadar uzaklaşma söylendikten sonra tam sayfa olmuyorsa yarım yarım çekime geçilir (`firstReadable` + `wholeFirst`). Gerçek günlük
        /// 2026-11-18: iki denemede 75 sn'nin 52 sn'si tam sayfa aramakla geçti, bu yüzden tek deneme
        var wholeTries = 1
        /// Son uzaklaşma cümlesinden bu kadar sn sonra (kullanıcıya uyması için süre) yarım yarım çekime geçilir
        var wholeWait: TimeInterval = 4
        /// Bu kadar sayfada tam sayfa olmayıp yarımlara geçildiyse sonraki sayfalar doğrudan yarımlarla başlar (tam sayfa yine kabul edilir)
        var halvesLearned = 1
    }

    var config = Config()
    private var candidate: FramingNote.Kind?
    private var consecutive = 0
    private var lastKind: FramingNote.Kind?
    private var lastTime: TimeInterval = -1000
    private var sameCount = 0
    private var lastWords: Set<String> = []
    private var correctionPending = false
    private var moved = false
    private var viewWords: Set<String> = []
    private var waitingSince: TimeInterval?
    private var spokenInView = 0
    /// Son söylenen cümle düzgün kadraj cümlesi miydi (çağıran bunun sonuna "çekildi" ekler; bkz. `FramingCoach.withCapture`)
    private(set) var lastWasGood = false
    /// Son söylenen cümle düzgün kadrajsa ve soru numaraları okunduysa "Alındı. Sonraki." yerine söylenecek cümle (bkz. `FramingCoach.questionsText`)
    private(set) var lastCapture: String?
    /// Yazı tanıma sonucu beklenirken (`firstReadable`) bekleme başlangıcı
    private var textWaitSince: TimeInterval?
    /// Bu görünümde tam sayfa için söylenen uzaklaşma sayısı; `Config.wholeTries`'a ulaşıp tam sayfa olmazsa yarım yarım çekime geçilir (bkz. `ShotPlan`)
    private var wholeTries = 0
    /// Bu sayfa için yarım yarım çekime geçildi
    private var halvesMode = false
    /// Yarım yarım çekimde üst yarı alındı: sıradaki görünüm aynı sayfanın alt yarısıdır (tam sayfa yeniden denenmez)
    private var expectSecondHalf = false
    /// Oturum boyunca öğrenme: üst üste kaç sayfada tam sayfa olmayıp yarımlara geçildi (`Config.halvesLearned`'a ulaşınca sonraki sayfalar doğrudan yarımlarla
    /// başlar: kitapçığın sayfaları aynı boydadır, her sayfada tam sayfa denemesiyle süre yitirilmez). Tam sayfa kabul edilince sıfırlanır
    private var halvesStreak = 0
    /// Bu sayfa için yarımlara geçiş seriye sayıldı
    private var countedHalves = false

    mutating func reset() {
        textWaitSince = nil
        wholeTries = 0
        halvesMode = false
        expectSecondHalf = false
        halvesStreak = 0
        countedHalves = false
        lastCapture = nil
        candidate = nil
        consecutive = 0
        lastKind = nil
        lastTime = -1000
        sameCount = 0
        lastWords = []
        correctionPending = false
        moved = false
        viewWords = []
        waitingSince = nil
        spokenInView = 0
        lastWasGood = false
    }

    /// Görünümün kimliği: ilk ve son tam satırın sözcükleri (küçük harf, kısa sözcükler atılır)
    static func viewSignature(_ lines: ViewLines?, minLength: Int = 4) -> Set<String> {
        guard let lines = lines else { return [] }
        let all = (lines.starts + lines.ends).flatMap { ViewLines.words($0.words) }
        return Set(all.map { $0.lowercased() }.filter { $0.count >= minLength })
    }

    /// Yeni sayfa: önceki sayfanın konuşma durumu unutulur (konuşma arası `speakGap` korunur: cümleler üst üste binmez)
    private mutating func startNewView() {
        textWaitSince = nil
        // Düzeltme sürerken görünüm değişti (kullanıcı aynı sayfada uzaklaşıp yaklaşıyor): plan ve deneme sayısı korunur, yoksa tam sayfa denemesi hiç bitmez.
        // Sayfa kabul edildiyse ya da hiçbir şey söylenmediyse yeni sayfadır: plan baştan, önce tam sayfa. Yarım yarım çekimde üst yarıdan sonraki görünüm
        // aynı sayfanın alt yarısıdır: yeniden tam sayfa denenmez
        if lastKind == nil || lastKind?.isGood == true {
            halvesMode = (halvesMode && expectSecondHalf) || halvesStreak >= config.halvesLearned
            expectSecondHalf = false
            wholeTries = 0
            countedHalves = false
        }
        candidate = nil
        consecutive = 0
        lastKind = nil
        sameCount = 0
        lastWords = []
        correctionPending = false
        spokenInView = 0
    }

    /// Söylenecek cümle ya da nil. `expectEdges`: kâğıt kenarı algılaması açık; düzgün kadraj cümlesi kenarlar gelene kadar bekler.
    /// `firstReadable` (canlı koç): okunabilen, tam görünen ve bozuk olmayan ilk görüntü kabul edilir (bkz. `FramingCoach.note`); yazı tanıma sonucu
    /// gelene kadar (en çok `lineWait`) iptal olabilecek değerlendirmeler ("yaklaşın", "bulanık", "uygun"…) söylenmez.
    /// `wholeFirst` (kullanıcı kararı 2026-11-18): her yeni sayfada önce TÜM SAYFA tek seferde istenir (`ShotPlan.wholePage`); `Config.wholeTries` denemede
    /// olmazsa ya da tam sayfa okunmuyorsa yarım yarım çekime geçilir (`ShotPlan.halves`), o sayfa için sürer
    mutating func step(metrics m: PageMetrics, lines: ViewLines?, time: TimeInterval, stillFor: TimeInterval,
                       guidance c: GuidanceConfig = GuidanceConfig(), sharpFloor: Double = 0.45, expectEdges: Bool = false,
                       firstReadable: Bool = false, wholeFirst: Bool = false) -> String? {
        if stillFor < config.movingBelow {
            moved = true
            waitingSince = nil
            candidate = nil
            consecutive = 0
            return nil
        }
        guard stillFor >= config.stillNeeded else {
            candidate = nil
            consecutive = 0
            return nil
        }
        if moved {
            if lines == nil {
                let since = waitingSince ?? time
                waitingSince = since
                if time - since < config.lineWait { return nil }   // satırlar okunana kadar: sayfa değişti mi bilinmiyor
            }
            let words = FramingCoachTimer.viewSignature(lines, minLength: config.minWordLength)
            let same = !words.isEmpty && !viewWords.isEmpty && FramingCoach.overlap(words, viewWords) >= config.sameView
            if !same { startNewView() }
            viewWords = words
            moved = false
            waitingSince = nil
        } else {
            // Durgun görünümün kimliği güncel tutulur: hareket başlayınca "önceki görünüm" budur
            let words = FramingCoachTimer.viewSignature(lines, minLength: config.minWordLength)
            if !words.isEmpty { viewWords = words }
        }
        let plan: ShotPlan = !firstReadable ? .any : (halvesMode ? .halves : (wholeFirst ? .wholePage : .any))
        var note = FramingCoach.note(m, lines: lines, config: c, sharpFloor: sharpFloor, firstReadable: firstReadable, plan: plan)
        let seeksWhole = plan == .wholePage && (note.kind == .wholePage || note.kind == .tooWide || note.kind == .incomplete)
        if seeksWhole, wholeTries >= config.wholeTries, time - lastTime >= config.wholeWait {
            // Tam sayfa için yeterince denendi ve olmadı: yarım yarım çekime geçilir
            note = FramingNote(kind: .halves, text: FramingCoach.halvesText)
        }
        if firstReadable {
            if lines != nil {
                textWaitSince = nil
            } else if note.kind.awaitsText {
                let since = textWaitSince ?? time
                textWaitSince = since
                if time - since < config.lineWait {
                    candidate = nil
                    consecutive = 0
                    return nil
                }
            }
        }
        if expectEdges, note.kind == .good, stillFor < config.edgeWait {
            candidate = nil
            consecutive = 0
            return nil
        }
        // Sayfa durumu bilinmişken kenarlar bir an belirsizleşirse ("Kadraj uygun.") geri düşülmez: ölçüm gürültüsüyle iki cümle arasında gidip gelinmesin
        if note.kind == .good, let last = lastKind, last.isGood, last != .good {
            candidate = nil
            consecutive = 0
            return nil
        }
        if note.kind == candidate {
            consecutive += 1
        } else {
            candidate = note.kind
            consecutive = 1
        }
        guard consecutive >= config.stable, time - lastTime >= config.speakGap, spokenInView < config.maxPerView else { return nil }
        let changed = note.kind != lastKind
        var words: Set<String> = []
        if note.kind.isGood {
            words = Set((lines?.ends ?? []).flatMap { ViewLines.words($0.words).map { $0.lowercased() } })
            if !changed {
                // Aynı düzgün kadraj: yalnız görünüm değiştiyse (alttaki satır başka) ve aralık dolduysa yeniden anlatılır
                guard time - lastTime >= config.repeatGap, !words.isEmpty, FramingCoach.overlap(words, lastWords) < 0.5 else { return nil }
            }
            sameCount = 0
        } else if changed {
            sameCount = 1
        } else {
            guard time - lastTime >= config.repeatGap, sameCount < config.maxSameCorrection else { return nil }
            sameCount += 1
        }
        var text = note.text
        if note.kind.isGood && correctionPending { text = note.text == FramingCoach.okText ? "Tamam." : "Tamam. " + text }
        correctionPending = note.isCorrection
        lastKind = note.kind
        lastTime = time
        lastWords = words
        spokenInView += 1
        lastWasGood = note.kind.isGood
        lastCapture = note.kind.isGood ? FramingCoach.questionsText(lines) : nil
        if note.kind == .halves {
            halvesMode = true
            if !countedHalves {
                halvesStreak += 1
                countedHalves = true
            }
        }
        if plan == .wholePage && note.kind == .goodFull { halvesStreak = 0 }
        if seeksWhole && note.kind != .halves { wholeTries += 1 }
        if plan == .halves && note.kind == .goodUpper { expectSecondHalf = true }
        return text
    }
}
