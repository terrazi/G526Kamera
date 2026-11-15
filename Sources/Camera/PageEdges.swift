import Foundation
import CoreGraphics
import CoreVideo
import ImageIO
import Vision

/// Sayfanın (kâğıdın) kadrajdaki dört köşesi: Apple Vision belge algılaması. Koordinatlar kare oranıdır (0–1), sol-üst orijinli,
/// ekranda görünen (çevrilmiş) görüntüye göredir. Yazı bloğu ölçümünden farkı: yazı değil kâğıdın kendi kenarını bulur,
/// böylece "yazı tam sığıyor ama kâğıdın alt kenarı kadrajın dışında" gibi durumlar da tarif edilebilir.
/// Yalnız bilgi verir: çekim kararını (yön, yaklaş, uzaklaş) değiştirmez.
struct PageEdges: Equatable {
    struct Point: Equatable {
        var x: Double
        var y: Double
    }

    /// Kameranın saat yazısı bandı: kareden bu kadar pay "kadraj kenarı" sayılır (band hangi kenardaysa o kenarın payıdır)
    struct Insets: Equatable {
        var left = 0.0
        var right = 0.0
        var top = 0.0
        var bottom = 0.0

        /// Band kare üstündedir; görüntü çevrilmişse ekranda sağda / solda / altta görünür
        static func band(for orientation: ImageOrientation, fraction: Double = GuidanceAnalyzer.skipTop) -> Insets {
            switch orientation {
            case .normal: return Insets(top: fraction)
            case .right90: return Insets(right: fraction)
            case .left90: return Insets(left: fraction)
            case .rotate180: return Insets(bottom: fraction)
            }
        }
    }

    enum Side: CaseIterable {
        case left, right, top, bottom

        var word: String {
            switch self {
            case .left: return "sol"
            case .right: return "sağ"
            case .top: return "üst"
            case .bottom: return "alt"
            }
        }
    }

    /// `cut`: kâğıt bu kenardan kadraj dışına taşıyor; `clear`: kenar kadrajın içinde, boşluk var; `unclear`: arası (titremesin diye söylenmez)
    enum State: Equatable {
        case cut, clear, unclear
    }

    /// Kâğıdın en dış noktası ile kadraj kenarı arası bundan azsa taşıyor, bundan çoksa tam içinde sayılır (arası belirsiz)
    static let cutGap = 0.012
    static let clearGap = 0.035
    /// Vision'ın güveni ve dörtgenin kadraja oranı bunun altındaysa sonuç kullanılmaz
    static let minConfidence = 0.7
    static let minArea = 0.15

    /// Köşeler sırayla: sol-üst, sağ-üst, sağ-alt, sol-alt
    var points: [Point]
    var confidence: Double
    var insets: Insets

    init(points: [Point], confidence: Double, insets: Insets = Insets()) {
        self.points = points
        self.confidence = confidence
        self.insets = insets
    }

    /// Vision köşeleri sol-alt orijinlidir; burada sol-üst orijine çevrilir.
    init(visionTopLeft tl: CGPoint, topRight tr: CGPoint, bottomRight br: CGPoint, bottomLeft bl: CGPoint,
         confidence: Double, insets: Insets) {
        func p(_ c: CGPoint) -> Point { return Point(x: Double(c.x), y: 1 - Double(c.y)) }
        self.init(points: [p(tl), p(tr), p(br), p(bl)], confidence: confidence, insets: insets)
    }

    /// Kâğıdın bu yöndeki en dış noktası ile kadraj kenarı arasındaki boşluk (kare oranı; eksi: taşıyor)
    func gap(_ side: Side) -> Double {
        let xs = points.map { $0.x }
        let ys = points.map { $0.y }
        switch side {
        case .left: return (xs.min() ?? 0) - insets.left
        case .right: return 1 - (xs.max() ?? 1) - insets.right
        case .top: return (ys.min() ?? 0) - insets.top
        case .bottom: return 1 - (ys.max() ?? 1) - insets.bottom
        }
    }

    func state(_ side: Side) -> State {
        let g = gap(side)
        if g < PageEdges.cutGap { return .cut }
        return g >= PageEdges.clearGap ? .clear : .unclear
    }

    /// Kadraj dışına taşan kenarlar (sol, sağ, üst, alt sırasıyla)
    var cutSides: [Side] {
        return Side.allCases.filter { state($0) == .cut }
    }

    /// Dört kenar da kadrajın içinde, belirgin boşlukla
    var allClear: Bool {
        return Side.allCases.allSatisfy { state($0) == .clear }
    }

    /// Dörtgenin kadraja oranı (kare oranı, 0–1)
    var area: Double {
        guard points.count == 4 else { return 0 }
        var sum = 0.0
        for i in 0..<4 {
            let a = points[i]
            let b = points[(i + 1) % 4]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    var isReliable: Bool {
        return points.count == 4 && confidence >= PageEdges.minConfidence && area >= PageEdges.minArea
    }

    /// Yazı kutusu (kare oranı) dörtgenin sınırlayıcı kutusunun içinde mi (`tolerance` kadar payla)? Dışındaysa Vision sayfanın
    /// bir parçasını (tablo, resim) bulmuş olabilir; böyle bir sonuç sayfa tarifinde kullanılmaz.
    func encloses(x0: Double, x1: Double, y0: Double, y1: Double, tolerance t: Double) -> Bool {
        guard !points.isEmpty else { return false }
        let xs = points.map { $0.x }
        let ys = points.map { $0.y }
        return x0 >= (xs.min() ?? 0) - t && x1 <= (xs.max() ?? 1) + t
            && y0 >= (ys.min() ?? 0) - t && y1 <= (ys.max() ?? 1) + t
    }

    /// Yazı kutusunu (ölçüm düzlemi oranı) kare oranına çevirir. Görüntü çevrilmişse kameranın saat bandı ölçüm düzleminden
    /// atılmıştır (`GuidanceAnalyzer.reorient`), kare oranında ise yerinde durur; bu yüzden bandın olduğu eksende ölçek / kayma gerekir.
    func inFrame(x0: Double, x1: Double, y0: Double, y1: Double) -> (x0: Double, x1: Double, y0: Double, y1: Double) {
        let width = 1 - insets.left - insets.right
        let height = 1 - insets.bottom
        return (x0: insets.left + x0 * width, x1: insets.left + x1 * width, y0: y0 * height, y1: y1 * height)
    }

    /// Dörtgenin sınırlayıcı kutusu yazı kutusunu her yönde en az `margin` kadar aşıyor mu? Sayfada yazının çevresinde boşluk
    /// (kenar boşluğu) olur; dörtgen yazıya yapışıksa Vision kâğıdı değil yazı bölgesini bulmuştur, sonuç tarifte kullanılmaz.
    func surrounds(x0: Double, x1: Double, y0: Double, y1: Double, margin m: Double) -> Bool {
        guard !points.isEmpty else { return false }
        let xs = points.map { $0.x }
        let ys = points.map { $0.y }
        return (xs.min() ?? 0) <= x0 - m && (xs.max() ?? 1) >= x1 + m
            && (ys.min() ?? 0) <= y0 - m && (ys.max() ?? 1) >= y1 + m
    }

    /// Günlük / durum satırı için kısa özet
    var summary: String {
        if allClear { return "dört kenarı görünüyor" }
        let cut = cutSides
        if cut.isEmpty { return "kenarı belirsiz" }
        return "kesik kenar: " + cut.map { $0.word }.joined(separator: ", ")
    }
}

/// Vision belge algılama isteği. Kare başına yüzlerce milisaniye sürebilir; bu yüzden yalnız kamera durunca ve seyrek çağrılır
/// (bkz. `PageEdgeTracker`). Hata verirse (ör. simülatörde model yok) nil döner; yönlendirme o zaman yalnız yazı ölçümüyle sürer.
enum PageEdgeDetector {
    static func detect(_ pixelBuffer: CVPixelBuffer, orientation: ImageOrientation) -> PageEdges? {
        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation.cgOrientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let o = request.results?.first else { return nil }
        return PageEdges(visionTopLeft: o.topLeft, topRight: o.topRight, bottomRight: o.bottomRight, bottomLeft: o.bottomLeft,
                         confidence: Double(o.confidence), insets: PageEdges.Insets.band(for: orientation))
    }
}

/// Vision'ın ne zaman çalışacağını ve son sonucu tutar (saf mantık; birim testle denenir). Kamera hareket edince sonuç silinir;
/// durunca hemen bir kez, sonra sonuç değişirken 0,6 sn'de bir, değişmiyorsa (iki kez üst üste aynı) 3 sn'de bir çalışır: ısınma düşük kalır.
struct PageEdgeTracker {
    static let fastGap: TimeInterval = 0.6
    static let slowGap: TimeInterval = 3

    private(set) var current: PageEdges?
    private var lastRun: TimeInterval = -1000
    private var calm = 0
    private var ran = false

    mutating func reset() {
        current = nil
        lastRun = -1000
        calm = 0
        ran = false
    }

    func due(at time: TimeInterval) -> Bool {
        return time - lastRun >= (calm >= 2 ? PageEdgeTracker.slowGap : PageEdgeTracker.fastGap)
    }

    mutating func ingest(_ edges: PageEdges?, at time: TimeInterval) {
        if ran && PageEdgeTracker.same(edges, current) { calm += 1 } else { calm = 0 }
        current = edges
        lastRun = time
        ran = true
    }

    /// Kenar durumları aynıysa iki sonuç aynı sayılır (köşelerdeki küçük oynama önemsenmez)
    private static func same(_ a: PageEdges?, _ b: PageEdges?) -> Bool {
        switch (a, b) {
        case (nil, nil):
            return true
        case let (x?, y?):
            return PageEdges.Side.allCases.allSatisfy { x.state($0) == y.state($0) }
        default:
            return false
        }
    }
}
