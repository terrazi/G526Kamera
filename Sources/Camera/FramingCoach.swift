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

/// Koçun bir değerlendirmesi: ne durumda ve ne söylenecek
struct FramingNote: Equatable {
    enum Kind: String, Equatable {
        case noText, blurry, glare, cutLeft, cutRight, shiftLeft, shiftRight, tooWide, tooSmall, emptyTop, middle
        /// Düzeltme gerekmiyor: `good` kâğıt kenarı bilinmiyorken; `goodFull` tam sayfa, `goodUpper` üst yarı, `goodLower` alt yarı
        case good, goodFull, goodUpper, goodLower

        var isGood: Bool { return self == .good || self == .goodFull || self == .goodUpper || self == .goodLower }
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

    static func withCapture(_ text: String) -> String {
        if text == okText || text == "Tamam." { return capturedText }
        if text.hasPrefix("Tamam. ") { return String(text.dropFirst("Tamam. ".count)) + " " + capturedText }
        return text + " " + capturedText
    }

    /// "azıcık" → "Azıcık" (Türkçe büyük harfle)
    static func capitalised(_ s: String) -> String {
        return String(s.prefix(1)).uppercased(with: Locale(identifier: "tr_TR")) + String(s.dropFirst())
    }

    /// `verbose` false (canlı koç): kelime ("Biraz sağa.", "Uzaklaşın.", "Bulanık, sabit tutun."); true ("Kadraj kontrolü"): tam cümle
    static func note(_ m: PageMetrics, lines: ViewLines?, config c: GuidanceConfig = GuidanceConfig(), sharpFloor: Double = 0.45,
                     verbose: Bool = false) -> FramingNote {
        let d = GuidanceAdvisor.decide(m, config: c, sharpFloor: sharpFloor)
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
        var stillNeeded: TimeInterval = 0.45
        /// Durgunluk bundan kısaysa kamera oynuyor sayılır (sayfa değişmiş olabilir)
        var movingBelow: TimeInterval = 0.15
        /// İki konuşma arası en az süre
        var speakGap: TimeInterval = 3.5
        /// Aynı değerlendirmenin yeniden söylenme aralığı
        var repeatGap: TimeInterval = 12
        /// Kaç ardışık ölçüm aynı çıkınca söylenir
        var stable = 2
        /// Aynı düzeltme art arda en çok kaç kez söylenir
        var maxSameCorrection = 3
        /// Hareketten sonra satırlar okunana kadar en çok bu kadar beklenir (sayfa değişti mi diye bakılır); sonra yeni sayfa sayılır
        var lineWait: TimeInterval = 2.5
        /// Kâğıt kenarları bekleniyorsa (ayar açık) düzgün kadraj cümlesi için durgunluk en az bu kadar sürmeli: üç durum (tam / üst / alt) kenarlardan bilinir
        var edgeWait: TimeInterval = 1.2
        /// Bir sayfada (görünümde) en çok bu kadar cümle söylenir: ölçüm gürültüsü kulaklıkta sürekli konuşmaya dönüşmesin (yeni sayfada sıfırlanır)
        var maxPerView = 8
        /// Sözcük örtüşmesi bundan azsa görünüm yeni sayfadır
        var sameView = 0.4
        /// Sayfa karşılaştırmasında bundan kısa sözcükler ("ve", "bir", "için") sayılmaz
        var minWordLength = 4
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

    mutating func reset() {
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
        candidate = nil
        consecutive = 0
        lastKind = nil
        sameCount = 0
        lastWords = []
        correctionPending = false
        spokenInView = 0
    }

    /// Söylenecek cümle ya da nil. `expectEdges`: kâğıt kenarı algılaması açık; düzgün kadraj cümlesi kenarlar gelene kadar bekler
    mutating func step(metrics m: PageMetrics, lines: ViewLines?, time: TimeInterval, stillFor: TimeInterval,
                       guidance c: GuidanceConfig = GuidanceConfig(), sharpFloor: Double = 0.45, expectEdges: Bool = false) -> String? {
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
        let note = FramingCoach.note(m, lines: lines, config: c, sharpFloor: sharpFloor)
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
        return text
    }
}
