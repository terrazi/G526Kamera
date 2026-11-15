import XCTest
import CoreGraphics
@testable import G526CameraDrive

/// Kâğıt kenarları (Vision belge algılaması): kenar sınıflandırma, köşe çevirme, tarif cümleleri, çalışma sıklığı.
/// Vision'ın kendisi (gerçek görüntü) bu testlerde çağrılmaz; yalnız sonucun işlenmesi denenir.
final class PageEdgesTests: XCTestCase {

    // MARK: - Yardımcılar

    private func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, conf: Double = 0.9,
                      insets: PageEdges.Insets = PageEdges.Insets()) -> PageEdges {
        return PageEdges(points: [PageEdges.Point(x: x0, y: y0), PageEdges.Point(x: x1, y: y0),
                                  PageEdges.Point(x: x1, y: y1), PageEdges.Point(x: x0, y: y1)],
                         confidence: conf, insets: insets)
    }

    private func text(x0: Double = 0.2, x1: Double = 0.8, y0: Double = 0.25, y1: Double = 0.75) -> PageMetrics {
        var m = PageMetrics()
        m.hasPage = true
        m.hasText = true
        m.x0 = x0
        m.x1 = x1
        m.y0 = y0
        m.y1 = y1
        m.cells = 600
        m.sharp = 1.0
        return m
    }

    private func describe(_ m: PageMetrics) -> String? {
        return GuidanceScene.describe(GuidanceScene.parts(m, config: GuidanceConfig()), edges: GuidanceScene.usableEdges(m))
    }

    // MARK: - Kenar sınıflandırma

    func testSidesAreClassifiedWithAGapBetweenCutAndClear() {
        let inside = rect(0.1, 0.15, 0.9, 0.95)
        XCTAssertTrue(inside.allClear)
        XCTAssertTrue(inside.cutSides.isEmpty)

        let touching = rect(0.1, 0.15, 0.9, 0.99)
        XCTAssertEqual(touching.state(.bottom), .cut)
        XCTAssertEqual(touching.cutSides, [.bottom])
        XCTAssertFalse(touching.allClear)

        // Arası belirsiz: ne taşıyor ne de belirgin içinde (titreyen sonuç tarifi değiştirmesin)
        let between = rect(0.1, 0.15, 0.9, 0.97)
        XCTAssertEqual(between.state(.bottom), .unclear)
        XCTAssertTrue(between.cutSides.isEmpty)
        XCTAssertFalse(between.allClear)

        // Kadraj dışına taşan köşe (eksi boşluk) de taşma sayılır
        let over = rect(-0.02, 0.15, 0.9, 0.95)
        XCTAssertEqual(over.cutSides, [.left])
    }

    func testCutSidesComeInLeftRightTopBottomOrder() {
        let e = rect(0.0, 0.0, 1.0, 1.0)
        XCTAssertEqual(e.cutSides, [.left, .right, .top, .bottom])
        XCTAssertEqual(PageEdges.Side.allCases.map { $0.word }, ["sol", "sağ", "üst", "alt"])
    }

    func testClockBandCountsAsTheFrameEdge() {
        let band = GuidanceAnalyzer.skipTop
        let top = PageEdges.Insets.band(for: .normal)
        XCTAssertEqual(top.top, band, accuracy: 0.0001)
        XCTAssertEqual(top.left + top.right + top.bottom, 0, accuracy: 0.0001)
        // Kâğıdın üst kenarı bandın hemen altında: kadrajın üstünden taşıyor sayılır
        XCTAssertEqual(rect(0.1, 0.08, 0.9, 0.9, insets: top).state(.top), .cut)
        XCTAssertEqual(rect(0.1, 0.20, 0.9, 0.9, insets: top).state(.top), .clear)

        // Görüntü çevrilince band ekranda başka kenardadır
        XCTAssertEqual(PageEdges.Insets.band(for: .right90).right, band, accuracy: 0.0001)
        XCTAssertEqual(PageEdges.Insets.band(for: .left90).left, band, accuracy: 0.0001)
        XCTAssertEqual(PageEdges.Insets.band(for: .rotate180).bottom, band, accuracy: 0.0001)
        let right = PageEdges.Insets.band(for: .right90)
        XCTAssertEqual(rect(0.1, 0.1, 0.93, 0.9, insets: right).state(.right), .cut)
        XCTAssertEqual(rect(0.1, 0.1, 0.80, 0.9, insets: right).state(.right), .clear)
    }

    func testVisionCornersAreFlippedToATopLeftOrigin() {
        // Vision: sol-alt orijin; y büyükse yukarıda
        let e = PageEdges(visionTopLeft: CGPoint(x: 0.1, y: 0.9), topRight: CGPoint(x: 0.9, y: 0.9),
                          bottomRight: CGPoint(x: 0.9, y: 0.1), bottomLeft: CGPoint(x: 0.1, y: 0.1),
                          confidence: 0.8, insets: PageEdges.Insets())
        XCTAssertEqual(e.points.count, 4)
        XCTAssertEqual(e.points[0].x, 0.1, accuracy: 0.0001)
        XCTAssertEqual(e.points[0].y, 0.1, accuracy: 0.0001)   // sol-üst
        XCTAssertEqual(e.points[2].x, 0.9, accuracy: 0.0001)
        XCTAssertEqual(e.points[2].y, 0.9, accuracy: 0.0001)   // sağ-alt
        XCTAssertTrue(e.allClear)
        XCTAssertEqual(e.area, 0.64, accuracy: 0.001)
    }

    func testReliabilityNeedsConfidenceAndSize() {
        XCTAssertTrue(rect(0.1, 0.1, 0.9, 0.9).isReliable)
        XCTAssertFalse(rect(0.1, 0.1, 0.9, 0.9, conf: 0.5).isReliable)
        XCTAssertFalse(rect(0.40, 0.40, 0.55, 0.55).isReliable, "küçük dörtgen sayfa sayılmaz")
        XCTAssertFalse(PageEdges(points: [], confidence: 1).isReliable)
    }

    func testEnclosesChecksTheTextBox() {
        let e = rect(0.1, 0.15, 0.9, 0.95)
        XCTAssertTrue(e.encloses(x0: 0.2, x1: 0.8, y0: 0.25, y1: 0.75, tolerance: 0.08))
        XCTAssertTrue(e.encloses(x0: 0.03, x1: 0.97, y0: 0.10, y1: 0.99, tolerance: 0.08), "pay içinde")
        XCTAssertFalse(e.encloses(x0: 0.0, x1: 0.8, y0: 0.25, y1: 0.75, tolerance: 0.08))
        XCTAssertFalse(PageEdges(points: [], confidence: 1).encloses(x0: 0, x1: 1, y0: 0, y1: 1, tolerance: 1))
    }

    func testSummaryNamesTheCutSides() {
        XCTAssertEqual(rect(0.1, 0.15, 0.9, 0.95).summary, "dört kenarı görünüyor")
        XCTAssertEqual(rect(0.0, 0.15, 0.9, 1.0).summary, "kesik kenar: sol, alt")
        XCTAssertEqual(rect(0.1, 0.15, 0.9, 0.97).summary, "kenarı belirsiz")
        var m = text()
        XCTAssertFalse(m.summary.contains("sayfa"))
        m.edges = rect(0.1, 0.15, 0.9, 1.0)
        XCTAssertTrue(m.summary.hasSuffix("sayfa kesik kenar: alt"))
    }

    // MARK: - Tarif cümleleri

    func testSceneSaysTheWholePageFitsWhenAllFourEdgesAreVisible() {
        var m = text()
        m.edges = rect(0.1, 0.15, 0.9, 0.95)
        XCTAssertEqual(describe(m), "Tek sayfa görünüyor, kenarlarıyla birlikte tam sığıyor.")
    }

    func testSceneSaysWhichPageEdgesAreOutsideTheFrame() {
        var m = text()
        m.edges = rect(0.1, 0.15, 0.9, 1.0)
        XCTAssertEqual(describe(m), "Tek sayfa görünüyor, yazı tam sığıyor. Sayfanın alt kenarı kadrajın dışında kalıyor.")
        m.edges = rect(0.0, 0.15, 0.9, 1.0)
        XCTAssertEqual(describe(m), "Tek sayfa görünüyor, yazı tam sığıyor. Sayfanın sol ve alt kenarları kadrajın dışında kalıyor.")
        m.edges = rect(0.1, 0.0, 0.9, 0.95)
        XCTAssertEqual(describe(m), "Tek sayfa görünüyor, yazı tam sığıyor. Sayfanın üst kenarı kadrajın dışında kalıyor.")
        m.edges = rect(0.0, 0.15, 1.0, 1.0)
        XCTAssertEqual(describe(m), "Tek sayfa görünüyor, yazı tam sığıyor. Sayfa kadraja sığmıyor, yalnız bir kısmı görünüyor.")
    }

    func testSceneFallsBackToTheTextOnlyDescription() {
        let base = "Tek sayfa görünüyor, tam sığıyor."
        var m = text()
        XCTAssertEqual(describe(m), base, "Vision sonucu yok")

        m.edges = rect(0.1, 0.15, 0.9, 0.97)
        XCTAssertEqual(describe(m), base, "kenar belirsiz: söylenmez")

        m.edges = rect(0.1, 0.15, 0.9, 1.0, conf: 0.4)
        XCTAssertEqual(describe(m), base, "güven düşük")

        m.edges = rect(0.0, 0.0, 0.45, 1.0)
        XCTAssertTrue(m.edges?.isReliable == true)
        XCTAssertEqual(describe(m), base, "dörtgen yazıyı içine almıyor: sayfanın bir parçası olabilir")
    }

    func testAQuadHuggingTheTextIsNotThePageAndIsNotUsed() {
        let base = "Tek sayfa görünüyor, tam sığıyor."
        var m = text()   // yazı x 0,2–0,8, y 0,25–0,75
        m.edges = rect(0.195, 0.245, 0.805, 0.755)
        XCTAssertTrue(m.edges?.isReliable == true)
        XCTAssertEqual(describe(m), base, "dörtgen yazıya yapışık: kâğıt değil yazı bölgesi")

        m.edges = rect(0.18, 0.23, 0.82, 0.77)   // her yönde %1'den fazla pay: kâğıt sayılır
        XCTAssertEqual(describe(m), "Tek sayfa görünüyor, kenarlarıyla birlikte tam sığıyor.")

        // Yalnız bir yönde yapışık (altta pay yok): kullanılmaz
        m.edges = rect(0.1, 0.15, 0.9, 0.755)
        XCTAssertEqual(describe(m), base)
    }

    func testTextBoxIsMappedToTheFrameWhenTheClockBandWasCropped() {
        let band = GuidanceAnalyzer.skipTop
        // Normal yönde ölçüm düzlemi = kare: değişmez
        let normal = rect(0.1, 0.1, 0.9, 0.9, insets: PageEdges.Insets.band(for: .normal)).inFrame(x0: 0.2, x1: 0.8, y0: 0.25, y1: 0.75)
        XCTAssertEqual(normal.x0, 0.2, accuracy: 0.0001)
        XCTAssertEqual(normal.x1, 0.8, accuracy: 0.0001)
        XCTAssertEqual(normal.y0, 0.25, accuracy: 0.0001)
        XCTAssertEqual(normal.y1, 0.75, accuracy: 0.0001)
        // Band sağda: düzlem karenin soluna oturur
        let right = rect(0.1, 0.1, 0.9, 0.9, insets: PageEdges.Insets.band(for: .right90)).inFrame(x0: 0.2, x1: 0.8, y0: 0.25, y1: 0.75)
        XCTAssertEqual(right.x0, 0.2 * (1 - band), accuracy: 0.0001)
        XCTAssertEqual(right.x1, 0.8 * (1 - band), accuracy: 0.0001)
        XCTAssertEqual(right.y0, 0.25, accuracy: 0.0001)
        // Band solda: düzlem karenin sağına oturur
        let left = rect(0.1, 0.1, 0.9, 0.9, insets: PageEdges.Insets.band(for: .left90)).inFrame(x0: 0.2, x1: 0.8, y0: 0.25, y1: 0.75)
        XCTAssertEqual(left.x0, band + 0.2 * (1 - band), accuracy: 0.0001)
        XCTAssertEqual(left.x1, band + 0.8 * (1 - band), accuracy: 0.0001)
        // Band altta (180°): düzlem karenin üstüne oturur
        let upside = rect(0.1, 0.1, 0.9, 0.9, insets: PageEdges.Insets.band(for: .rotate180)).inFrame(x0: 0.2, x1: 0.8, y0: 0.25, y1: 0.75)
        XCTAssertEqual(upside.y0, 0.25 * (1 - band), accuracy: 0.0001)
        XCTAssertEqual(upside.y1, 0.75 * (1 - band), accuracy: 0.0001)
        XCTAssertEqual(upside.x0, 0.2, accuracy: 0.0001)

        // Çevrilmiş görüntüde (band sağda) dört kenar da içeride: tarif kenarlarla birlikte söylenir
        var m = text()
        m.edges = rect(0.1, 0.15, 0.8, 0.95, insets: PageEdges.Insets.band(for: .right90))
        XCTAssertEqual(describe(m), "Tek sayfa görünüyor, kenarlarıyla birlikte tam sığıyor.")
    }

    func testTextCutAndSeveralSectionsKeepTheTextDescription() {
        var cutText = text(x0: 0.005, x1: 0.6)
        cutText.edges = rect(0.0, 0.15, 0.9, 0.95)
        XCTAssertEqual(describe(cutText), "Tek sayfa görünüyor, sol tarafı kesik.")

        var two = text(x0: 0.13, x1: 0.88)
        two.columns = [ColumnBox(x0: 0.13, x1: 0.49, y0: 0.2, y1: 0.8, cells: 300, sharp: 1),
                       ColumnBox(x0: 0.51, x1: 0.88, y0: 0.2, y1: 0.8, cells: 300, sharp: 1)]
        two.edges = rect(0.05, 0.1, 0.95, 1.0)
        XCTAssertEqual(describe(two), "İki sayfa görünüyor, ikisi de tam sığıyor.")

        XCTAssertNil(describe(PageMetrics()))
    }

    // MARK: - Durum makinesi

    func testEngineSpeaksThePageEdgesOnceBeforeCapturing() {
        let e = GuidanceEngine()
        e.describeScene = true
        var m = text()
        m.edges = rect(0.1, 0.15, 0.9, 1.0)
        var spoken: [String] = []
        var captured = false
        for t in [0, 0.3, 0.6] {
            let o = e.step(m, time: t, stillFor: 1.0, diffToCapture: 100)
            if let s = o.speak { spoken.append(s) }
            if o.capture { captured = true }
        }
        XCTAssertEqual(spoken, ["Tek sayfa görünüyor, yazı tam sığıyor. Sayfanın alt kenarı kadrajın dışında kalıyor."])
        XCTAssertTrue(captured, "kâğıdın kenarı taşıyor diye çekim engellenmez")
    }

    func testEngineAdviceIsNotChangedByThePageEdges() {
        let plain = GuidanceEngine()
        let withEdges = GuidanceEngine()
        var m = text(x0: 0.4, x1: 0.995)
        let a = plain.step(m, time: 0, stillFor: 1.0, diffToCapture: 100)
        m.edges = rect(0.3, 0.15, 1.0, 0.95)
        let b = withEdges.step(m, time: 0, stillFor: 1.0, diffToCapture: 100)
        XCTAssertEqual(a.advice, b.advice)
        XCTAssertEqual(a.capture, b.capture)
        XCTAssertEqual(GuidanceAdvisor.decide(m, choice: nil, sharpFloor: 0.45),
                       GuidanceAdvisor.decide(text(x0: 0.4, x1: 0.995), choice: nil, sharpFloor: 0.45))
    }

    func testVideoConfirmationCarriesThePageEdgeDescription() {
        let e = GuidanceEngine()
        e.describeScene = true
        var bad = text(x0: 0.4, x1: 0.995)
        bad.edges = rect(0.3, 0.15, 1.0, 0.95)
        var spoken: [String] = []
        for t in [0.0, 0.3] {
            if let s = e.videoStep(bad, time: t, stillFor: 1.0).speak { spoken.append(s) }
        }
        var good = text()
        good.edges = rect(0.1, 0.15, 0.9, 1.0)
        for t in [0.6, 0.9, 1.2] {
            if let s = e.videoStep(good, time: t, stillFor: 1.0).speak { spoken.append(s) }
        }
        XCTAssertEqual(spoken.count, 2)
        XCTAssertEqual(spoken.last, "Tamam, böyle. Tek sayfa görünüyor, yazı tam sığıyor. Sayfanın alt kenarı kadrajın dışında kalıyor.")
    }

    // MARK: - Çalışma sıklığı

    func testTrackerRunsOnceAtFirstThenSlowsDownWhenTheResultDoesNotChange() {
        var t = PageEdgeTracker()
        XCTAssertTrue(t.due(at: 0))
        XCTAssertNil(t.current)

        let e = rect(0.1, 0.15, 0.9, 0.95)
        t.ingest(e, at: 0)
        XCTAssertEqual(t.current, e)
        XCTAssertFalse(t.due(at: 0.3))
        XCTAssertTrue(t.due(at: 0.6))

        t.ingest(rect(0.11, 0.16, 0.89, 0.94), at: 0.6)   // küçük oynama: kenar durumları aynı
        t.ingest(e, at: 1.2)
        XCTAssertFalse(t.due(at: 2.0), "sonuç değişmiyor: seyrek bakılır")
        XCTAssertFalse(t.due(at: 4.1))
        XCTAssertTrue(t.due(at: 4.3))
    }

    func testTrackerSpeedsUpAgainWhenTheResultChangesAndClearsOnReset() {
        var t = PageEdgeTracker()
        let e = rect(0.1, 0.15, 0.9, 0.95)
        t.ingest(e, at: 0)
        t.ingest(e, at: 0.6)
        t.ingest(e, at: 1.2)
        XCTAssertFalse(t.due(at: 2.0))

        t.ingest(rect(0.1, 0.15, 0.9, 1.0), at: 4.5)       // alt kenar taşmaya başladı
        XCTAssertFalse(t.due(at: 4.8))
        XCTAssertTrue(t.due(at: 5.2), "değişince yine sık bakılır")

        t.reset()
        XCTAssertNil(t.current)
        XCTAssertTrue(t.due(at: 5.3), "kamera oynadı: durunca hemen yeniden bakılır")
    }

    func testTrackerCountsRepeatedNothingAsCalmToo() {
        var t = PageEdgeTracker()
        t.ingest(nil, at: 0)
        t.ingest(nil, at: 0.6)
        t.ingest(nil, at: 1.2)
        XCTAssertNil(t.current)
        XCTAssertFalse(t.due(at: 2.0))
        XCTAssertTrue(t.due(at: 4.3))
    }
}
