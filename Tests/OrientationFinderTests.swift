import XCTest
import CoreGraphics
import CoreVideo
@testable import G526CameraDrive

/// Yazının yönünü kendiliğinden bulma (kullanıcı isteği 2026-11-18): çekim bazen alttan, bazen yandan olabilir. Yazı yan ya da ters dururken de okunur;
/// yön cümleleri kameranın kendi duruşuna göre söylenir (metin çevrilip söylenmez), kareler yalnız kaydedilirken dik çevrilir.
/// Bu dosya saf kararı (`OrientationFinder.find`), kare başına yön kaydını, dönüş hesabını ve yön sözcüklerinin eşlenmesini sınar; cihazda doğrulanmadı.

// MARK: - Yön bulucu

final class OrientationFinderTests: XCTestCase {
    private func score(_ chars: Int) -> TextScore {
        var s = TextScore()
        s.chars = chars
        return s
    }

    /// `chars[yön]` kadar harf okuyan sahte okuyucu; hangi yönlerin okunduğunu da kaydeder
    private func search(_ chars: [ImageOrientation: Int], calls: inout [ImageOrientation], preferred: ImageOrientation = .normal)
        -> (orientation: ImageOrientation, value: Int?) {
        var log: [ImageOrientation] = []
        let result = OrientationFinder.find(preferred: preferred) { orientation -> (value: Int?, chars: Int) in
            log.append(orientation)
            let n = chars[orientation] ?? 0
            return (n, n)
        }
        calls = log
        return result
    }

    func testAnAlreadyReadableOrientationIsTheOnlyOneThatIsRead() {
        var calls: [ImageOrientation] = []
        let r = search([.normal: 120, .right90: 400], calls: &calls)
        XCTAssertEqual(r.orientation, .normal)
        XCTAssertEqual(calls, [.normal], "Yeterince okunuyorsa başka yön denenmez (hız ve pil)")
    }

    func testSidewaysTextIsFoundAndTheSearchStopsAtTheFirstClearReading() {
        var calls: [ImageOrientation] = []
        let r = search([.normal: 8, .right90: 150], calls: &calls)
        XCTAssertEqual(r.orientation, .right90)
        XCTAssertEqual(r.value, 150)
        XCTAssertEqual(calls, [.normal, .right90], "Açıkça okunan ilk yönde durulur")
        var upside: [ImageOrientation] = []
        XCTAssertEqual(search([.normal: 5, .rotate180: 140], calls: &upside).orientation, .rotate180)
        XCTAssertEqual(upside, ImageOrientation.allCases, "Ters yön en son denenir")
    }

    func testThePreferredOrientationIsTriedFirstWhateverItIs() {
        var calls: [ImageOrientation] = []
        let r = search([.left90: 200, .normal: 3], calls: &calls, preferred: .left90)
        XCTAssertEqual(r.orientation, .left90)
        XCTAssertEqual(calls, [.left90], "Önceki karede bulunan yön ilk denenir")
    }

    func testRecognitionGarbageInAWrongOrientationIsNeverChosen() {
        var calls: [ImageOrientation] = []
        let r = search([.normal: 10, .right90: 25, .left90: 30, .rotate180: 20], calls: &calls)
        XCTAssertEqual(r.orientation, .normal, "Yanlış yönde birkaç anlamsız harf okunabilir: eşik altı seçilmez")
        XCTAssertEqual(calls.count, 4)
    }

    func testAPartialViewReadInTheRightOrientationIsNotFlippedByAGarbledOtherReading() {
        var calls: [ImageOrientation] = []
        // Tercih edilen yön yarım okunuyor (40 harf); öteki 90 harf ama 3 katına (120) varmıyor
        let r = search([.normal: 40, .right90: 90], calls: &calls)
        XCTAssertEqual(r.orientation, .normal)
    }

    func testTheBestOrientationIsChosenWhenNoneIsClearButOneIsEnoughAndFarAheadOfTheRest() {
        var calls: [ImageOrientation] = []
        let r = search([.normal: 5, .right90: 70, .left90: 65, .rotate180: 20], calls: &calls)
        XCTAssertEqual(r.orientation, .right90)
        XCTAssertEqual(calls.count, 4, "Hiçbiri açık değilse dördü de okunur, en çok okunan seçilir")
    }

    func testWhenNothingIsReadAnywhereTheFirstReadingStaysAndNoOrientationIsInvented() {
        var calls: [ImageOrientation] = []
        let r = search([:], calls: &calls)
        XCTAssertEqual(r.orientation, .normal)
        XCTAssertEqual(r.value, 0)
    }

    // MARK: Kare başına yön kaydı

    private func buffer() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA, nil, &pb)
        return pb!
    }

    func testTheOrientationFoundForAFrameIsRememberedForItAndTriedFirstOnTheNextFrame() {
        let finder = OrientationFinder()
        finder.reset(base: .normal)
        let first = buffer(), second = buffer()
        var calls: [ImageOrientation] = []
        let reader: (CVPixelBuffer, ImageOrientation) -> TextScore? = { _, orientation in
            calls.append(orientation)
            return orientation == .left90 ? self.score(200) : self.score(4)
        }
        XCTAssertEqual(finder.readScore(first, base: .normal, enabled: true, reader: reader)?.chars, 200)
        XCTAssertEqual(finder.orientation(for: first, fallback: .normal), .left90)
        XCTAssertEqual(calls, [.normal, .right90, .left90])
        calls = []
        _ = finder.readScore(second, base: .normal, enabled: true, reader: reader)
        XCTAssertEqual(calls, [.left90], "Sonraki kare önce bulunan yönü dener")
        XCTAssertEqual(finder.orientation(for: second, fallback: .normal), .left90)
    }

    func testAFrameThatWasNeverReadKeepsTheFallbackOrientation() {
        let finder = OrientationFinder()
        XCTAssertEqual(finder.orientation(for: buffer(), fallback: .rotate180), .rotate180)
    }

    func testWithTheSettingOffTheFrameIsReadOnceInTheUsersOrientationAndNothingIsRecorded() {
        let finder = OrientationFinder()
        let frame = buffer()
        var calls: [ImageOrientation] = []
        let s = finder.readScore(frame, base: .right90, enabled: false) { _, orientation in
            calls.append(orientation)
            return self.score(3)
        }
        XCTAssertEqual(s?.chars, 3)
        XCTAssertEqual(calls, [.right90])
        XCTAssertEqual(finder.orientation(for: frame, fallback: .right90), .right90)
    }

    func testResetForgetsTheFramesAndStartsFromTheUsersOrientation() {
        let finder = OrientationFinder()
        finder.reset(base: .normal)
        let frame = buffer()
        _ = finder.readScore(frame, base: .normal, enabled: true) { _, orientation in
            self.score(orientation == .rotate180 ? 150 : 2)
        }
        XCTAssertEqual(finder.orientation(for: frame, fallback: .normal), .rotate180)
        finder.reset(base: .right90)
        XCTAssertEqual(finder.orientation(for: frame, fallback: .normal), .normal, "Yeni çekimde eski kare kayıtları kalmaz")
        var calls: [ImageOrientation] = []
        _ = finder.readScore(buffer(), base: .right90, enabled: true) { _, orientation in
            calls.append(orientation)
            return self.score(200)
        }
        XCTAssertEqual(calls, [.right90])
    }

    // MARK: Dönüş hesabı ve yön sözcükleri

    func testTheTurnFromTheUprightImageToTheCameraImageIsCountedInQuarterTurns() {
        XCTAssertEqual(ImageOrientation.turn(base: .normal, detected: .normal), 0)
        XCTAssertEqual(ImageOrientation.turn(base: .normal, detected: .right90), 3)
        XCTAssertEqual(ImageOrientation.turn(base: .normal, detected: .left90), 1)
        XCTAssertEqual(ImageOrientation.turn(base: .normal, detected: .rotate180), 2)
        XCTAssertEqual(ImageOrientation.turn(base: .right90, detected: .right90), 0)
        XCTAssertEqual(ImageOrientation.turn(base: .right90, detected: .normal), 1)
        XCTAssertEqual(ImageOrientation.turn(base: .left90, detected: .normal), 3)
    }

    func testDirectionsAreTurnedIntoTheCamerasOwnFrame() {
        XCTAssertEqual(ViewDirection.down.turned(0), .down)
        // Yazı kamerada yan duruyor (dik görüntü kamera görüntüsünün saat yönünde 90° çevrilmişi): dik görüntüde "aşağı" kamerada "sağa"
        XCTAssertEqual(ViewDirection.down.turned(3), .right)
        XCTAssertEqual(ViewDirection.up.turned(3), .left)
        XCTAssertEqual(ViewDirection.right.turned(3), .down)
        XCTAssertEqual(ViewDirection.up.turned(2), .down)
        XCTAssertEqual(ViewDirection.left.turned(1), .up)
        XCTAssertEqual(ViewDirection.up.turned(-1), .left)
        XCTAssertEqual(ViewDirection.up.turned(4), .up)
        XCTAssertEqual([ViewDirection.up, .right, .down, .left].map { $0.move }, ["yukarı", "sağa", "aşağı", "sola"])
        XCTAssertEqual([ViewDirection.up, .right, .down, .left].map { $0.side }, ["üst", "sağ", "alt", "sol"])
    }

    func testTheSettingIsOnByDefaultAndRemembered() {
        let defaults = UserDefaults(suiteName: "g526.testler.\(UUID().uuidString)")!
        let first = CameraSettings(defaults: defaults)
        XCTAssertTrue(first.autoOrientation, "Varsayılan: yazının yönü kendiliğinden bulunur")
        first.autoOrientation = false
        XCTAssertFalse(CameraSettings(defaults: defaults).autoOrientation, "Ayar kalıcıdır")
    }
}

// MARK: - Yön cümleleri kameranın duruşuna göre

final class CameraStanceDirectionTests: XCTestCase {
    private func metrics(x0: Double = 0.15, x1: Double = 0.85, y0: Double = 0.2, y1: Double = 0.8) -> PageMetrics {
        var m = PageMetrics()
        m.hasPage = true
        m.hasText = true
        m.x0 = x0; m.x1 = x1; m.y0 = y0; m.y1 = y1
        m.cells = 600
        m.sharp = 1.0
        return m
    }

    private func edges(left: Double = 0.1, right: Double = 0.9, top: Double = 0.1, bottom: Double = 0.9) -> PageEdges {
        return PageEdges(points: [PageEdges.Point(x: left, y: top), PageEdges.Point(x: right, y: top),
                                  PageEdges.Point(x: right, y: bottom), PageEdges.Point(x: left, y: bottom)], confidence: 0.9)
    }

    private func page(_ e: PageEdges?, y0: Double = 0.15, y1: Double = 0.85) -> PageMetrics {
        var m = metrics(x0: 0.2, x1: 0.8, y0: y0, y1: y1)
        m.edges = e
        return m
    }

    private func note(_ m: PageMetrics, turn: Int) -> FramingNote {
        return FramingCoach.note(m, lines: nil, sharpFloor: 0.45, turn: turn)
    }

    func testWithoutATurnTheWordsAreUnchanged() {
        XCTAssertEqual(note(metrics(x1: 0.995), turn: 0).text, "Biraz sağa.")
    }

    func testTheMoveWordIsSaidInTheCamerasOwnFrameWhenTheTextIsReadSideways() {
        // Dik görüntüde sayfanın sağı kesik: "sağa" (dönüş 0). Kamera 180° ters tutuluyorsa "sola"; yan tutuluyorsa "aşağı" / "yukarı"
        XCTAssertEqual(note(metrics(x1: 0.995), turn: 2).text, "Biraz sola.")
        XCTAssertEqual(note(metrics(x1: 0.995), turn: 1).text, "Biraz aşağı.")
        XCTAssertEqual(note(metrics(x1: 0.995), turn: 3).text, "Biraz yukarı.")
        // Tür (kesik sağ kenar) yönden bağımsızdır
        XCTAssertEqual(note(metrics(x1: 0.995), turn: 3).kind, .cutRight)
    }

    func testTheCutSideOfAFullPageIsNamedInTheCamerasOwnFrame() {
        let m = page(edges(right: 1.0), y0: 0.15, y1: 0.85)
        let upright = note(m, turn: 0).text
        XCTAssertTrue(upright.contains("sağ"), "Dönüş yokken kesik kenar sağ: \(upright)")
        let turned = note(m, turn: 2).text
        XCTAssertTrue(turned.contains("sol"), "Kamera ters: dik görüntünün sağı kamerada sol: \(turned)")
        XCTAssertFalse(turned.contains("sağ"), turned)
    }

    func testAnOpenPartIsAskedToBeSlidTowardsTheEndOfTheTextInTheCamerasFrame() {
        let open = ViewLines(bottomCut: true, chars: 160, topComplete: true, bottomComplete: false,
                             anchor: ["parçadaki", "çizili", "sözcüğün"], anchorHead: "13 Parçadaki altı çizili")
        let m = page(edges(bottom: 1.0), y1: 0.95)
        let upright = FramingCoach.note(m, lines: open, sharpFloor: 0.45, firstReadable: true, plan: .halves)
        XCTAssertEqual(upright.text, "Üst parça. Aşağı kaydırın; 13 Parçadaki altı çizili satırı kalsın.")
        let sideways = FramingCoach.note(m, lines: open, sharpFloor: 0.45, firstReadable: true, plan: .halves, turn: 3)
        XCTAssertEqual(sideways.kind, .goodPart, "Yön ne olursa olsun parça türü değişmez")
        XCTAssertEqual(sideways.text, "Üst parça. Sağa kaydırın; 13 Parçadaki altı çizili satırı kalsın.")
    }

    func testTheOverlapWarningsOfTheHalvesPlanAlsoFollowTheCameraFrame() {
        let middle = ViewLines(bottomCut: true, chars: 160, topComplete: false, bottomComplete: false, anchorHead: "ikinci parçanın bu sözcükleri")
        let m = page(edges(top: 0.0, bottom: 1.0), y0: 0.1, y1: 0.9)
        XCTAssertEqual(FramingCoach.note(m, lines: middle, sharpFloor: 0.45, firstReadable: true, plan: .halves, continuing: false).text,
                       "Örtüşme yok, biraz yukarı.")
        XCTAssertEqual(FramingCoach.note(m, lines: middle, sharpFloor: 0.45, firstReadable: true, plan: .halves, continuing: false, turn: 3).text,
                       "Örtüşme yok, biraz sola.")
        XCTAssertEqual(FramingCoach.note(m, lines: middle, sharpFloor: 0.45, firstReadable: true, plan: .halves, continuing: false, turn: 2).text,
                       "Örtüşme yok, biraz aşağı.")
    }

    func testTheTimerPassesTheTurnOnToTheSpokenSentence() {
        var t = FramingCoachTimer()
        let cutRight = metrics(x1: 0.995)
        XCTAssertNil(t.step(metrics: cutRight, lines: nil, time: 10.0, stillFor: 1, sharpFloor: 0.45, expectEdges: false, turn: 2))
        XCTAssertEqual(t.step(metrics: cutRight, lines: nil, time: 10.3, stillFor: 1, sharpFloor: 0.45, expectEdges: false, turn: 2), "Biraz sola.")
    }
}
