import XCTest
@testable import G526CameraDrive

/// Önizleme kutusu (kırpma yok, yalnız çevirme) ve kadraj yönü ↔ görüntü yönü uyumu.
final class PreviewLayoutTests: XCTestCase {
    // MARK: Önizleme kutusu (kırpma yok)

    func testPortraitPreviewBoxShowsTheWholeRotatedFrame() {
        let screen = CGSize(width: 375, height: 812)   // iPhone 12 mini
        let box = PreviewLayout.box(screen: screen, portrait: true)
        XCTAssertGreaterThan(box.height, box.width, "Dikey seçili: dikey kutu")
        XCTAssertEqual(box.width / box.height, 9.0 / 16.0, accuracy: 0.001, "yatay 16:9 kare çevrilince tam oturur")
        XCTAssertLessThanOrEqual(box.width, screen.width - 32 + 0.5)
        XCTAssertLessThanOrEqual(box.height, screen.height * 0.6 + 0.5)
        // dar ekranda genişlik sınırı belirler
        let narrow = PreviewLayout.box(screen: CGSize(width: 200, height: 2000), portrait: true)
        XCTAssertLessThanOrEqual(narrow.width, 168 + 0.5)
        XCTAssertEqual(narrow.width / narrow.height, 9.0 / 16.0, accuracy: 0.001)
    }

    func testLandscapePreviewBoxIsWideAndFollowsTheChoice() {
        let screen = CGSize(width: 375, height: 812)
        let wide = PreviewLayout.box(screen: screen, portrait: false)
        XCTAssertGreaterThan(wide.width, wide.height, "Yatay seçili: yatay kutu")
        XCTAssertEqual(wide.width / wide.height, 16.0 / 9.0, accuracy: 0.001)
        XCTAssertEqual(wide.width, screen.width - 32, accuracy: 0.001)
        XCTAssertEqual(PreviewLayout.box(screen: screen), wide, "varsayılan yatay")
    }

    func testPreviewLayerIsNeverCropped() {
        // kare görünüme sığdırılır: çevrilmiş katman görünümü aşmaz
        let tall = PreviewLayout.box(screen: CGSize(width: 375, height: 812), portrait: true)
        let turned = DisplayView.layerSize(in: tall, orientation: .right90)
        XCTAssertEqual(turned, CGSize(width: tall.height, height: tall.width), "çevrilmemiş katman: en/boy yer değiştirir")
        // çevrilmiş katman 16:9'dur ve dikey kutuyu tam doldurur (9:16)
        XCTAssertEqual(turned.width / turned.height, 16.0 / 9.0, accuracy: 0.001)
        XCTAssertEqual(DisplayView.layerSize(in: tall, orientation: .left90), turned)
        let wide = PreviewLayout.box(screen: CGSize(width: 375, height: 812), portrait: false)
        XCTAssertEqual(DisplayView.layerSize(in: wide, orientation: .normal), wide)
        XCTAssertEqual(DisplayView.layerSize(in: wide, orientation: .rotate180), wide)
    }

    // MARK: Kadraj yönü ↔ görüntü yönü

    func testVerticalFrameTurnsThePictureAQuarter() {
        XCTAssertEqual(CameraSettings.orientation(.normal, forFrame: 1), .right90, "Dikey: yatay kare çevrilir")
        XCTAssertEqual(CameraSettings.orientation(.rotate180, forFrame: 1), .right90)
        XCTAssertEqual(CameraSettings.orientation(.left90, forFrame: 1), .left90, "seçilmiş yön korunur")
        XCTAssertEqual(CameraSettings.orientation(.right90, forFrame: 1), .right90)
    }

    func testHorizontalFrameDoesNotTurnThePictureAQuarter() {
        XCTAssertEqual(CameraSettings.orientation(.right90, forFrame: 0), .normal)
        XCTAssertEqual(CameraSettings.orientation(.left90, forFrame: 0), .normal)
        XCTAssertEqual(CameraSettings.orientation(.rotate180, forFrame: 0), .rotate180, "ters takılı kamera korunur")
        XCTAssertEqual(CameraSettings.orientation(.normal, forFrame: 0), .normal)
    }

    func testOrientationChoicesMatchTheFrameDirection() {
        XCTAssertEqual(CameraSettings.orientations(forFrame: 1), [.right90, .left90])
        XCTAssertEqual(CameraSettings.orientations(forFrame: 0), [.normal, .rotate180])
        for frame in [0, 1] {
            for o in CameraSettings.orientations(forFrame: frame) {
                XCTAssertEqual(CameraSettings.orientation(o, forFrame: frame), o, "seçenek kendi kadrajında geçerli")
            }
        }
    }
}
