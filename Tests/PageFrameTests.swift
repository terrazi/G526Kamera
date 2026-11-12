import XCTest
@testable import G526CameraDrive

/// Yönlendirmenin hedef kadrajı: dikey tam sayfa (A4 oranı) ve bütün kare (eski davranış).
final class PageFrameTests: XCTestCase {
    private func metrics(x0: Double, x1: Double, y0: Double = 0.2, y1: Double = 0.8, cells: Int = 600,
                         columns: [ColumnBox] = []) -> PageMetrics {
        var m = PageMetrics()
        m.hasPage = true
        m.hasText = true
        m.x0 = x0
        m.x1 = x1
        m.y0 = y0
        m.y1 = y1
        m.cells = cells
        m.sharp = 1.0
        m.columns = columns
        return m
    }

    private func decide(_ m: PageMetrics, _ frame: PageFrame) -> GuidanceAdvice {
        var config = GuidanceConfig()
        config.frame = frame
        return GuidanceAdvisor.decide(m, choice: nil, config: config, sharpFloor: 0.45).advice
    }

    // MARK: Kadraj ölçüsü

    func testVerticalPageSharesTheMiddleOfALandscapeFrame() {
        let f = PageFrame.verticalPage(orientation: .normal)
        XCTAssertEqual(f.width, 0.7071 / 1.7778, accuracy: 0.001)
        XCTAssertEqual(f.x0, (1 - f.width) / 2, accuracy: 0.0001)
        XCTAssertEqual(f.x0 + f.x1, 1, accuracy: 0.0001, "kare ortasında")
        XCTAssertEqual(PageFrame.verticalPage(orientation: .rotate180), f, "180°'de de aynı")
    }

    func testQuarterTurnPageUsesTheLongSideOfTheSensor() {
        let f = PageFrame.verticalPage(orientation: .right90)
        XCTAssertEqual(f.width, 1.4142 / 1.7778, accuracy: 0.001)
        XCTAssertEqual(PageFrame.verticalPage(orientation: .left90), f)
        XCTAssertGreaterThan(f.width, PageFrame.verticalPage(orientation: .normal).width)
        XCTAssertLessThanOrEqual(f.width, 1)
    }

    func testFrameNeverExceedsTheSensorFrame() {
        // çok geniş kareli bir kamera olsa da kadraj kareden büyük olmaz
        let f = PageFrame.verticalPage(orientation: .right90, aspect: 1.2)
        XCTAssertEqual(f.x0, 0, accuracy: 0.0001)
        XCTAssertEqual(f.x1, 1, accuracy: 0.0001)
    }

    func testDefaultConfigKeepsTheWholeFrame() {
        XCTAssertEqual(GuidanceConfig().frame, .full)
        XCTAssertEqual(GuidanceEngine().config.frame, .full)
        let m = metrics(x0: 0.2, x1: 0.8)
        XCTAssertEqual(m.inFrame(.full), m, "bütün karede ölçüler değişmez")
    }

    func testMetricsAreMappedIntoTheFrame() {
        let f = PageFrame(x0: 0.3, x1: 0.7)
        let col = ColumnBox(x0: 0.3, x1: 0.5, y0: 0.2, y1: 0.8, cells: 100, sharp: 1)
        let m = metrics(x0: 0.3, x1: 0.7, columns: [col]).inFrame(f)
        XCTAssertEqual(m.x0, 0, accuracy: 0.0001)
        XCTAssertEqual(m.x1, 1, accuracy: 0.0001)
        XCTAssertEqual(m.columns[0].x1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(m.y0, 0.2, "dikey eksen değişmez")
        let outside = metrics(x0: 0.1, x1: 0.5).inFrame(f)
        XCTAssertEqual(outside.x0, -0.5, accuracy: 0.0001, "kadrajın dışı eksi olur")
    }

    // MARK: Kararlar

    func testCenteredVerticalPageIsOkInBothFrames() {
        let m = metrics(x0: 0.33, x1: 0.67, y0: 0.1, y1: 0.9)
        XCTAssertEqual(decide(m, .full), .ok)
        XCTAssertEqual(decide(m, .verticalPage(orientation: .normal)), .ok)
    }

    func testPageOffCenterIsMovedBackIntoTheVerticalFrame() {
        let m = metrics(x0: 0.10, x1: 0.45, y0: 0.1, y1: 0.9)
        XCTAssertEqual(decide(m, .full), .ok, "bütün karede sorun yok")
        XCTAssertEqual(decide(m, .verticalPage(orientation: .normal)), .moveLeft)
        let right = metrics(x0: 0.55, x1: 0.90, y0: 0.1, y1: 0.9)
        XCTAssertEqual(decide(right, .verticalPage(orientation: .normal)), .moveRight)
    }

    func testTextWiderThanThePageFrameAsksToMoveBack() {
        let wide = metrics(x0: 0.2, x1: 0.8, y0: 0.1, y1: 0.9)
        XCTAssertEqual(decide(wide, .full), .ok)
        XCTAssertEqual(decide(wide, .verticalPage(orientation: .normal)), .farther,
                       "iki kenardan da taşıyorsa yan yana sayfa / yatay sayfa: uzaklaşılır")
    }

    func testSmallPageInTheFrameAsksToComeCloser() {
        let m = metrics(x0: 0.45, x1: 0.55, y0: 0.4, y1: 0.6, cells: 150)
        XCTAssertEqual(decide(m, .verticalPage(orientation: .normal)), .closer)
    }

    func testTurnedFrameFitsALandscapeSensorBlock() {
        // 90° çevrilmiş görüntüde sayfa sensörde yatay durur: karenin %80'ine yakın kaplar
        let page = metrics(x0: 0.15, x1: 0.85, y0: 0.1, y1: 0.9)
        XCTAssertEqual(decide(page, .verticalPage(orientation: .right90)), .ok)
        let off = metrics(x0: 0.02, x1: 0.60, y0: 0.1, y1: 0.9)
        XCTAssertEqual(decide(off, .verticalPage(orientation: .right90)), .moveLeft)
    }

    func testColumnsOutsideTheFrameStillAskWhichToCapture() {
        let left = ColumnBox(x0: 0.20, x1: 0.48, y0: 0.1, y1: 0.9, cells: 300, sharp: 1)
        let right = ColumnBox(x0: 0.52, x1: 0.80, y0: 0.1, y1: 0.9, cells: 300, sharp: 1)
        let m = metrics(x0: 0.20, x1: 0.80, y0: 0.1, y1: 0.9, columns: [left, right])
        var config = GuidanceConfig()
        config.frame = .verticalPage(orientation: .normal)
        let d = GuidanceAdvisor.decide(m, choice: nil, config: config, sharpFloor: 0.45)
        XCTAssertEqual(d.advice, .chooseColumn)
    }

    // MARK: Önizleme kutusu (kırpma yok)

    func testPortraitPreviewBoxShowsTheWholeRotatedFrame() {
        let screen = CGSize(width: 375, height: 812)   // iPhone 12 mini
        let box = PageFrame.previewBox(screen: screen, portrait: true)
        XCTAssertGreaterThan(box.height, box.width, "Dikey seçili: dikey kutu")
        XCTAssertEqual(box.width / box.height, 9.0 / 16.0, accuracy: 0.001, "yatay 16:9 kare çevrilince tam oturur")
        XCTAssertLessThanOrEqual(box.width, screen.width - 32 + 0.5)
        XCTAssertLessThanOrEqual(box.height, screen.height * 0.6 + 0.5)
        // dar ekranda genişlik sınırı belirler
        let narrow = PageFrame.previewBox(screen: CGSize(width: 200, height: 2000), portrait: true)
        XCTAssertLessThanOrEqual(narrow.width, 168 + 0.5)
        XCTAssertEqual(narrow.width / narrow.height, 9.0 / 16.0, accuracy: 0.001)
    }

    func testLandscapePreviewBoxIsWideAndFollowsTheChoice() {
        let screen = CGSize(width: 375, height: 812)
        let wide = PageFrame.previewBox(screen: screen, portrait: false)
        XCTAssertGreaterThan(wide.width, wide.height, "Yatay seçili: yatay kutu")
        XCTAssertEqual(wide.width / wide.height, 16.0 / 9.0, accuracy: 0.001)
        XCTAssertEqual(wide.width, screen.width - 32, accuracy: 0.001)
        XCTAssertEqual(PageFrame.previewBox(screen: screen), wide, "varsayılan yatay")
    }

    func testPreviewLayerIsNeverCropped() {
        // kare görünüme sığdırılır: çevrilmiş katman görünümü aşmaz
        let tall = PageFrame.previewBox(screen: CGSize(width: 375, height: 812), portrait: true)
        let turned = DisplayView.layerSize(in: tall, orientation: .right90)
        XCTAssertEqual(turned, CGSize(width: tall.height, height: tall.width), "çevrilmemiş katman: en/boy yer değiştirir")
        // çevrilmiş katman 16:9'dur ve dikey kutuyu tam doldurur (9:16)
        XCTAssertEqual(turned.width / turned.height, 16.0 / 9.0, accuracy: 0.001)
        XCTAssertEqual(DisplayView.layerSize(in: tall, orientation: .left90), turned)
        let wide = PageFrame.previewBox(screen: CGSize(width: 375, height: 812), portrait: false)
        XCTAssertEqual(DisplayView.layerSize(in: wide, orientation: .normal), wide)
        XCTAssertEqual(DisplayView.layerSize(in: wide, orientation: .rotate180), wide)
    }

    // MARK: Kadraj yönü ↔ görüntü yönü

    func testVerticalFrameTurnsThePictureAQuarter() {
        XCTAssertEqual(AppSettings.orientation(.normal, forFrame: 1), .right90, "Dikey: yatay kare çevrilir")
        XCTAssertEqual(AppSettings.orientation(.rotate180, forFrame: 1), .right90)
        XCTAssertEqual(AppSettings.orientation(.left90, forFrame: 1), .left90, "seçilmiş yön korunur")
        XCTAssertEqual(AppSettings.orientation(.right90, forFrame: 1), .right90)
    }

    func testHorizontalFrameDoesNotTurnThePictureAQuarter() {
        XCTAssertEqual(AppSettings.orientation(.right90, forFrame: 0), .normal)
        XCTAssertEqual(AppSettings.orientation(.left90, forFrame: 0), .normal)
        XCTAssertEqual(AppSettings.orientation(.rotate180, forFrame: 0), .rotate180, "ters takılı kamera korunur")
        XCTAssertEqual(AppSettings.orientation(.normal, forFrame: 0), .normal)
    }

    func testOrientationChoicesMatchTheFrameDirection() {
        XCTAssertEqual(AppSettings.orientations(forFrame: 1), [.right90, .left90])
        XCTAssertEqual(AppSettings.orientations(forFrame: 0), [.normal, .rotate180])
        for frame in [0, 1] {
            for o in AppSettings.orientations(forFrame: frame) {
                XCTAssertEqual(AppSettings.orientation(o, forFrame: frame), o, "seçenek kendi kadrajında geçerli")
            }
        }
    }
}
