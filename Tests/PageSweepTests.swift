import XCTest
@testable import G526CameraDrive

/// Sayfa çekimi: videonun bütününde sayfanın kenarları görüldü mü ve Gemini'ye hangi net kareler gider
final class PageSweepTests: XCTestCase {

    // MARK: - Yardımcılar

    private func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, conf: Double = 0.9) -> PageEdges {
        return PageEdges(points: [PageEdges.Point(x: x0, y: y0), PageEdges.Point(x: x1, y: y0),
                                  PageEdges.Point(x: x1, y: y1), PageEdges.Point(x: x0, y: y1)], confidence: conf)
    }

    private func frame(_ i: Int, _ edges: PageEdges?, sharp: Double = 1.0, glare: Double = 0) -> SweepFrame {
        return SweepFrame(index: i, time: Double(i) * 0.5, sharp: sharp, glare: glare, edges: edges)
    }

    /// Sayfa kadraja tam sığıyor
    private var whole: PageEdges { return rect(0.1, 0.1, 0.9, 0.9) }
    /// Sayfanın üst yarısı: üst kenar kadrajda, alt kenar taşıyor
    private var topPart: PageEdges { return rect(0.1, 0.1, 0.9, 1.05) }
    /// Sayfanın alt yarısı: alt kenar kadrajda, üst kenar taşıyor
    private var bottomPart: PageEdges { return rect(0.1, -0.1, 0.9, 0.9) }
    /// Yakın çekim: sayfa kadrajı dört yandan aşıyor
    private var closeUp: PageEdges { return rect(-0.1, -0.1, 1.1, 1.1) }
    /// Sayfa yatayda kadrajdan geniş, dikeyde içeride
    private var wide: PageEdges { return rect(-0.1, 0.1, 1.1, 0.9) }

    // MARK: - Kapsama

    func testTopEdgeInOneFrameAndBottomEdgeInAnotherCoversThePage() {
        let frames = [frame(0, topPart), frame(1, closeUp), frame(2, closeUp), frame(3, bottomPart)]
        let c = PageSweep.coverage(frames)
        XCTAssertEqual(c.measured, 4)
        XCTAssertTrue(c.seen.contains(.top))
        XCTAssertTrue(c.seen.contains(.bottom))
        XCTAssertEqual(c.missing(.topBottom), [], "üst kenar bir karede, alt kenar başka karede: sayfa tamam")
        XCTAssertEqual(c.missing(.fourSides), [], "üst/alt karelerde sol ve sağ kenar da görünüyor")
    }

    func testBottomEdgeNeverSeenIsReported() {
        let frames = [frame(0, topPart), frame(1, topPart), frame(2, closeUp), frame(3, closeUp)]
        let c = PageSweep.coverage(frames)
        XCTAssertEqual(c.missing(.topBottom), [.bottom])
        XCTAssertEqual(c.missing(.fourSides), [.bottom])
    }

    func testTopEdgeNeverSeenIsReported() {
        let frames = [frame(0, bottomPart), frame(1, closeUp), frame(2, bottomPart)]
        XCTAssertEqual(PageSweep.coverage(frames).missing(.topBottom), [.top])
    }

    func testSideEdgesOnlyMatterInFourSideMode() {
        let frames = [frame(0, wide), frame(1, wide), frame(2, wide)]
        let c = PageSweep.coverage(frames)
        XCTAssertEqual(c.missing(.topBottom), [], "yatayda kadrajdan geniş sayfa: üst ve alt görüldü")
        XCTAssertEqual(c.missing(.fourSides), [.left, .right])
    }

    func testWholePageInOneFrameIsEnough() {
        let frames = [frame(0, whole), frame(1, whole), frame(2, whole)]
        let c = PageSweep.coverage(frames)
        XCTAssertEqual(c.missing(.fourSides), [])
    }

    func testOffModeNeverComplains() {
        let frames = [frame(0, closeUp), frame(1, closeUp), frame(2, closeUp)]
        XCTAssertEqual(PageSweep.coverage(frames).missing(.off), [])
        XCTAssertEqual(PageSweep.coverage(frames).missing(.topBottom), [.top, .bottom], "oysa yakın çekimde hiçbir kenar görülmedi")
    }

    func testTooFewMeasuredFramesSkipTheCheck() {
        let few = PageSweep.coverage([frame(0, closeUp), frame(1, closeUp), frame(2, nil), frame(3, nil)])
        XCTAssertEqual(few.measured, 2)
        XCTAssertEqual(few.missing(.topBottom), [], "kenar yeterince ölçülemediyse denetim atlanır (sayfa olduğu gibi alınır)")
        let none = PageSweep.coverage((0..<8).map { frame($0, nil) })
        XCTAssertEqual(none.measured, 0)
        XCTAssertEqual(none.missing(.fourSides), [])
        XCTAssertEqual(PageSweep.coverage([]).missing(.topBottom), [])
    }

    func testUnreliableEdgesAreNotCounted() {
        let weak = rect(0.1, 0.1, 0.9, 0.9, conf: 0.4)
        let tiny = rect(0.4, 0.4, 0.5, 0.5)
        let c = PageSweep.coverage([frame(0, weak), frame(1, tiny), frame(2, weak), frame(3, tiny)])
        XCTAssertEqual(c.measured, 0, "düşük güven ve küçük alan: sonuç kullanılmaz")
    }

    func testModeRequirements() {
        XCTAssertEqual(CoverageMode.off.required, [])
        XCTAssertEqual(CoverageMode.topBottom.required, [.top, .bottom])
        XCTAssertEqual(Set(CoverageMode.fourSides.required), Set(PageEdges.Side.allCases))
        XCTAssertEqual(CoverageMode(rawValue: 1), .topBottom)
    }

    // MARK: - Net kare seçimi

    func testAllFramesAreKeptWhenFewerThanTheLimit() {
        let frames = (0..<5).map { frame($0, nil) }
        XCTAssertEqual(PageSweep.stills(frames, maxCount: 8), [0, 1, 2, 3, 4])
        XCTAssertEqual(PageSweep.stills([], maxCount: 8), [])
    }

    func testSharpestFrameOfEachTimeSliceIsChosen() {
        // çift kareler bulanık (0,5), tek kareler net (1,0): 16 kare, 8 dilim → her dilimden tek kare
        let frames = (0..<16).map { frame($0, nil, sharp: $0 % 2 == 0 ? 0.5 : 1.0) }
        XCTAssertEqual(PageSweep.stills(frames, maxCount: 8), [1, 3, 5, 7, 9, 11, 13, 15])
    }

    func testStillsCoverTheWholeTimelineEvenWhenOneEndIsSharper() {
        // yalnız ilk yarı çok net: yine de her dilimden bir kare alınır (sayfanın sonu eksik kalmasın)
        let frames = (0..<12).map { frame($0, nil, sharp: $0 < 6 ? 1.2 : 0.6) }
        let picks = PageSweep.stills(frames, maxCount: 4)
        XCTAssertEqual(picks.count, 4)
        XCTAssertTrue(picks.contains(where: { $0 >= 9 }), "son dilimden de kare alınmalı: \(picks)")
        XCTAssertTrue(picks.contains(where: { $0 < 3 }))
    }

    func testGlareLosesToCleanFrameAtEqualSharpness() {
        let frames = [frame(0, nil, sharp: 1.0, glare: 0.08), frame(1, nil, sharp: 1.0, glare: 0.0)]
        XCTAssertEqual(PageSweep.stills(frames, maxCount: 1), [1])
    }

    func testPicksAreInTimeOrderAndLimitIsAtLeastOne() {
        let frames = (0..<6).map { frame($0, nil, sharp: Double(6 - $0) / 6) }
        XCTAssertEqual(PageSweep.stills(frames, maxCount: 0).count, 1)
        let picks = PageSweep.stills(frames, maxCount: 3)
        XCTAssertEqual(picks, picks.sorted())
        XCTAssertEqual(picks.count, 3)
    }

    func testStillScoreRanksSharpnessAndGlare() {
        XCTAssertGreaterThan(PageSweep.stillScore(frame(0, nil, sharp: 1.2)), PageSweep.stillScore(frame(0, nil, sharp: 0.6)))
        XCTAssertGreaterThan(PageSweep.stillScore(frame(0, nil, sharp: 1.0, glare: 0)), PageSweep.stillScore(frame(0, nil, sharp: 1.0, glare: 0.05)))
    }
}
