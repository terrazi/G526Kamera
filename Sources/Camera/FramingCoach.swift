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

    /// "Üstte A ile başlıyor, altta B ile bitiyor." Satır bilgisi yoksa nil.
    var coverage: String? {
        var parts: [String] = []
        if topCut {
            parts.append("Üst satır yarım kalıyor.")
        } else if !starts.isEmpty {
            parts.append("Üstte " + starts.map { $0.phrase }.joined(separator: ", ") + " ile başlıyor.")
        }
        if bottomCut {
            if ends.isEmpty {
                parts.append("Alt satır yarım kalıyor.")
            } else {
                parts.append("Alt satır yarım kalıyor; son tam satır " + ends.map { $0.phrase }.joined(separator: ", ") + " ile bitiyor.")
            }
        } else if !ends.isEmpty {
            parts.append("Altta " + ends.map { $0.phrase }.joined(separator: ", ") + " ile bitiyor.")
        }
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
        case noText, blurry, glare, cutLeft, cutRight, shiftLeft, shiftRight, tooWide, tooSmall, emptyTop, good
    }
    var kind: Kind
    var text: String

    /// Kullanıcıdan bir şey isteyen (düzeltme) değerlendirme mi; `good` değil
    var isCorrection: Bool { return kind != .good }
}

/// Toplu çekimde sesli konumlandırma DESTEĞİ (kullanıcı kararı 2026-11-17, Ayarlar > "Toplu çekimde sesli konumlandırma"): çekimi başlatmaz ya da
/// bitirmez, yalnız kadrajın durumunu kısa cümlelerle söyler: hangi kenar kesik, sağa / sola kayma, yakın ve bulanıksa uzaklaşma, yazı küçükse
/// yaklaşma, üstte boşluk varsa aşağı kaydırma; düzeltme gerekmiyorsa üstte ve altta hangi satırla başlayıp bittiği.
/// Ölçüler tek soru çekimindeki yönlendirmeyle aynıdır (`GuidanceAdvisor`); farkı: dikey kesik bir sorun sayılmaz (sayfa kadrajdan büyüktür,
/// toplu çekimde yukarıdan aşağı kaydırılır), bunun yerine satır tarifi verilir.
enum FramingCoach {
    /// Yazının üst kenarı kadrajın bu oranından aşağıdaysa üst taraf boştur (kamera sayfanın üstünde kalmış)
    static let emptyTopLimit = 0.42
    /// Yazının alt kenarı kadrajın bu oranından yukarıdaysa alt taraf boştur (yalnız bilgi verilir: sayfa sonu olabilir)
    static let emptyBottomLimit = 0.55

    static func note(_ m: PageMetrics, lines: ViewLines?, config c: GuidanceConfig = GuidanceConfig(), sharpFloor: Double = 0.45) -> FramingNote {
        let d = GuidanceAdvisor.decide(m, config: c, sharpFloor: sharpFloor)
        switch d.advice {
        case .noText:
            return FramingNote(kind: .noText, text: "Yazı görünmüyor. Kamerayı sayfaya çevirin.")
        case .blurry:
            let text = d.fill >= 0.7 ? "Görüntü net değil, çok yakınsınız. Biraz uzaklaşın." : "Görüntü net değil. Kamerayı sabit tutun."
            return FramingNote(kind: .blurry, text: text)
        case .glare:
            return FramingNote(kind: .glare, text: "Sayfada parlama var. Kamerayı biraz eğin.")
        case .moveLeft, .moveRight, .moveUp, .moveDown:
            let word = GuidanceAdvisor.amountWord(shift: d.shift, config: c)
            let dir = d.advice.directionWord
            if d.scale > 1 {
                // Yazı kesik değil, küçük: yakınlaşınca taşacağı için önce ortalanır
                let kind: FramingNote.Kind = d.advice == .moveRight ? .shiftRight : .shiftLeft
                return FramingNote(kind: kind, text: "Yazı küçük. Önce kamerayı \(word) \(dir) kaydırıp sonra yaklaşın.")
            }
            let side = d.advice == .moveRight ? "Sağ" : "Sol"
            let kind: FramingNote.Kind = d.advice == .moveRight ? .cutRight : .cutLeft
            return FramingNote(kind: kind, text: "\(side) taraf kesik. Kamerayı \(word) \(dir) kaydırın.")
        case .farther:
            return FramingNote(kind: .tooWide, text: "Sayfa kadraja sığmıyor. Biraz uzaklaşın.")
        case .closer:
            return FramingNote(kind: .tooSmall, text: "Yazı küçük kalıyor. Biraz yaklaşın.")
        case .ok:
            break
        }
        // Düzeltme gerekmiyor
        if m.y0 - c.topBand > emptyTopLimit {
            return FramingNote(kind: .emptyTop, text: "Yazı kadrajın alt yarısında, üst taraf boş. Kamerayı biraz aşağı kaydırın.")
        }
        var parts: [String] = []
        if m.y1 < emptyBottomLimit { parts.append("Yazı kadrajın üst yarısında, alt taraf boş.") }
        if let coverage = lines?.coverage { parts.append(coverage) }
        if parts.isEmpty { parts.append("Kadraj uygun.") }
        return FramingNote(kind: .good, text: parts.joined(separator: " "))
    }

    /// "Kadraj kontrolü" için tam tarif: kaç sayfa görünüyor ve hangisi kesik, varsa düzeltme, satır tarifi. Yazı yoksa yalnız nedeni.
    static func describe(_ m: PageMetrics, lines: ViewLines?, config c: GuidanceConfig = GuidanceConfig(), sharpFloor: Double = 0.45) -> String {
        let n = note(m, lines: lines, config: c, sharpFloor: sharpFloor)
        guard m.hasText, n.kind != .noText else { return n.text }
        var parts: [String] = []
        if let scene = GuidanceScene.describe(GuidanceScene.parts(m, config: c), edges: GuidanceScene.usableEdges(m)) { parts.append(scene) }
        if n.isCorrection {
            parts.append(n.text)
            if let coverage = lines?.coverage { parts.append(coverage) }
        } else {
            parts.append(n.text)
        }
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
struct FramingCoachTimer {
    struct Config {
        /// Kamera bu süredir durgunsa değerlendirilir
        var stillNeeded: TimeInterval = 0.45
        /// İki konuşma arası en az süre
        var speakGap: TimeInterval = 3.5
        /// Aynı değerlendirmenin yeniden söylenme aralığı
        var repeatGap: TimeInterval = 12
        /// Kaç ardışık ölçüm aynı çıkınca söylenir
        var stable = 2
        /// Aynı düzeltme art arda en çok kaç kez söylenir
        var maxSameCorrection = 3
    }

    var config = Config()
    private var candidate: FramingNote.Kind?
    private var consecutive = 0
    private var lastKind: FramingNote.Kind?
    private var lastTime: TimeInterval = -1000
    private var sameCount = 0
    private var lastWords: Set<String> = []
    private var correctionPending = false

    mutating func reset() {
        candidate = nil
        consecutive = 0
        lastKind = nil
        lastTime = -1000
        sameCount = 0
        lastWords = []
        correctionPending = false
    }

    /// Söylenecek cümle ya da nil
    mutating func step(metrics m: PageMetrics, lines: ViewLines?, time: TimeInterval, stillFor: TimeInterval,
                       guidance c: GuidanceConfig = GuidanceConfig(), sharpFloor: Double = 0.45) -> String? {
        guard stillFor >= config.stillNeeded else {
            candidate = nil
            consecutive = 0
            return nil
        }
        let note = FramingCoach.note(m, lines: lines, config: c, sharpFloor: sharpFloor)
        if note.kind == candidate {
            consecutive += 1
        } else {
            candidate = note.kind
            consecutive = 1
        }
        guard consecutive >= config.stable, time - lastTime >= config.speakGap else { return nil }
        let changed = note.kind != lastKind
        var words: Set<String> = []
        if note.kind == .good {
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
        if note.kind == .good && correctionPending { text = "Tamam. " + text }
        correctionPending = note.isCorrection
        lastKind = note.kind
        lastTime = time
        lastWords = words
        return text
    }
}
