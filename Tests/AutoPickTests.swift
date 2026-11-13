import XCTest
@testable import G526CameraDrive

/// Kadrajda birden çok bölüm varken biri dört kenardan da tam sığıyorsa "sol mu, sağ mı" diye sormadan o bölümü seçip çekme.
final class AutoPickTests: XCTestCase {

    // MARK: - Yardımcılar

    private func col(_ x0: Double, _ x1: Double, y0: Double = 0.2, y1: Double = 0.8, cells: Int = 300) -> ColumnBox {
        return ColumnBox(x0: x0, x1: x1, y0: y0, y1: y1, cells: cells, sharp: 1.0)
    }

    private func page(_ columns: [ColumnBox]) -> PageMetrics {
        var m = PageMetrics()
        m.hasPage = true
        m.hasText = true
        m.x0 = columns.map { $0.x0 }.min() ?? 0
        m.x1 = columns.map { $0.x1 }.max() ?? 1
        m.y0 = columns.map { $0.y0 }.min() ?? 0
        m.y1 = columns.map { $0.y1 }.max() ?? 1
        m.cells = columns.reduce(0) { $0 + $1.cells }
        m.sharp = 1.0
        m.columns = columns
        return m
    }

    private var on: GuidanceConfig {
        var c = GuidanceConfig()
        c.autoPick = true
        return c
    }

    private func decide(_ m: PageMetrics, _ choice: ColumnChoice? = nil, config: GuidanceConfig? = nil,
                        skipping: ColumnChoice? = nil) -> GuidanceDecision {
        return GuidanceAdvisor.decide(m, choice: choice, config: config ?? on, sharpFloor: 0.45, skipping: skipping)
    }

    /// Soldaki tam sığıyor, sağdaki sağ kenardan taşıyor
    private var leftFits: PageMetrics { return page([col(0.04, 0.45), col(0.55, 1.0)]) }
    /// Sağdaki tam sığıyor, soldaki sol kenardan taşıyor
    private var rightFits: PageMetrics { return page([col(0.0, 0.45), col(0.55, 0.96)]) }

    // MARK: - Hangi bölüm tam sığıyor

    func testPicksTheOnlyColumnThatFitsOnAllFourSides() {
        let c = on
        XCTAssertEqual(GuidanceAdvisor.fittingChoice([col(0.04, 0.45), col(0.55, 1.0)], config: c), .left)
        XCTAssertEqual(GuidanceAdvisor.fittingChoice([col(0.0, 0.45), col(0.55, 0.96)], config: c), .right)
        XCTAssertNil(GuidanceAdvisor.fittingChoice([col(0.04, 0.45), col(0.55, 0.96)], config: c), "ikisi de sığıyor")
        XCTAssertNil(GuidanceAdvisor.fittingChoice([col(0.0, 0.45), col(0.55, 1.0)], config: c), "ikisi de kesik")
        XCTAssertNil(GuidanceAdvisor.fittingChoice([col(0.1, 0.9)], config: c), "tek bölümde seçim yok")
        XCTAssertNil(GuidanceAdvisor.fittingChoice([], config: c))
    }

    func testAColumnTouchingTheTopOrBottomDoesNotFit() {
        let c = on
        // Soldaki üstten dayalı (saat bandı payı sayılır), sağdaki tam sığıyor
        let top = GuidanceAnalyzer.skipTop + 0.01
        XCTAssertEqual(GuidanceAdvisor.fittingChoice([col(0.04, 0.45, y0: top), col(0.55, 0.96)], config: c), .right)
        // Soldaki alttan dayalı
        XCTAssertEqual(GuidanceAdvisor.fittingChoice([col(0.04, 0.45, y1: 0.995), col(0.55, 0.96)], config: c), .right)
        // İkisi de alttan dayalı: hiçbiri tam sığmıyor
        XCTAssertNil(GuidanceAdvisor.fittingChoice([col(0.04, 0.45, y1: 0.995), col(0.55, 0.96, y1: 0.995)], config: c))
    }

    func testTinyOrNarrowTextPiecesAreNotPicked() {
        let c = on
        XCTAssertNil(GuidanceAdvisor.fittingChoice([col(0.04, 0.45, cells: 40), col(0.55, 1.0)], config: c),
                     "az yazı hücresi: sayfa numarası gibi küçük parça seçilmez")
        XCTAssertNil(GuidanceAdvisor.fittingChoice([col(0.10, 0.18), col(0.55, 1.0)], config: c), "dar parça seçilmez")
    }

    func testThreeColumnsPickLeftMiddleOrRightOnlyWhenExactlyOneFits() {
        let c = on
        XCTAssertEqual(GuidanceAdvisor.fittingChoice([col(0.03, 0.30), col(0.35, 0.65, y1: 0.995), col(0.70, 1.0)], config: c), .left)
        XCTAssertEqual(GuidanceAdvisor.fittingChoice([col(0.0, 0.30), col(0.35, 0.65), col(0.70, 1.0)], config: c), .middle)
        XCTAssertEqual(GuidanceAdvisor.fittingChoice([col(0.0, 0.30), col(0.35, 0.65, y1: 0.995), col(0.70, 0.97)], config: c), .right)
        XCTAssertNil(GuidanceAdvisor.fittingChoice([col(0.03, 0.30), col(0.35, 0.65), col(0.70, 1.0)], config: c), "iki bölüm sığıyor")
        // Dört bölümde ortadakilerin `.left/.right/.middle` karşılığı yok: sorulur
        let four = [col(0.0, 0.2), col(0.25, 0.45), col(0.5, 0.7, y1: 0.995), col(0.75, 1.0)]
        XCTAssertNil(GuidanceAdvisor.fittingChoice(four, config: c))
    }

    // MARK: - Karar

    func testDecideSkipsTheQuestionWhenOneColumnFitsAndTheSettingIsOn() {
        let d = decide(leftFits)
        XCTAssertEqual(d.advice, .ok)
        XCTAssertEqual(d.picked, .left)
        XCTAssertTrue(d.options.isEmpty)

        let r = decide(rightFits)
        XCTAssertEqual(r.advice, .ok)
        XCTAssertEqual(r.picked, .right)
    }

    func testDecideStillAsksWhenTheSettingIsOffOrNothingFits() {
        let off = decide(leftFits, config: GuidanceConfig())
        XCTAssertEqual(off.advice, .chooseColumn)
        XCTAssertNil(off.picked)
        XCTAssertEqual(off.options, [.left, .right, .all])

        let bothCut = decide(page([col(0.0, 0.45), col(0.55, 1.0)]))
        XCTAssertEqual(bothCut.advice, .chooseColumn)
        XCTAssertNil(bothCut.picked)
    }

    func testDecideDoesNotPickTheColumnThatWasJustCaptured() {
        let d = decide(leftFits, skipping: .left)
        XCTAssertEqual(d.advice, .chooseColumn, "aynı bölümü ikinci kez çekmemek için sorulur")
        XCTAssertNil(d.picked)
        XCTAssertEqual(decide(leftFits, skipping: .right).picked, .left, "öbür bölüm son çekilen ise seçilir")
    }

    func testAnExplicitChoiceIsNeverMarkedAsPicked() {
        XCTAssertNil(decide(leftFits, .left).picked)
        let r = decide(leftFits, .right)
        XCTAssertNil(r.picked)
        XCTAssertEqual(r.advice, .moveRight, "kullanıcının seçtiği kesik bölüm için yön söylenir")
        XCTAssertNil(decide(leftFits, .all).picked, "video ve 'hepsi' seçiminde bölüm seçilmez")
    }

    func testAPickedColumnThatIsTooSmallStillGetsCloserAdvice() {
        // Soldaki tam sığıyor ama çok küçük (ve yakınlaşınca da sığar): seçilir, sonra "yaklaşın" denir (çekilmez)
        let m = page([col(0.21, 0.40, y0: 0.4, y1: 0.55, cells: 200), col(0.55, 1.0)])
        let d = decide(m)
        XCTAssertEqual(d.picked, .left)
        XCTAssertNotEqual(d.advice, .ok)
    }

    // MARK: - Durum makinesi

    // MARK: - Elle çekim ("okey" komutu / düğme)

    private var singlePage: PageMetrics {
        var m = PageMetrics()
        m.hasPage = true
        m.hasText = true
        m.x0 = 0.2
        m.x1 = 0.8
        m.y0 = 0.25
        m.y1 = 0.75
        m.cells = 600
        m.sharp = 1.0
        return m
    }

    func testVideoNeverPicksAColumn() {
        let e = GuidanceEngine()
        e.config.autoPick = true
        let o = e.videoStep(leftFits, time: 0, stillFor: 1.0)
        XCTAssertNotEqual(o.advice, .chooseColumn)
        XCTAssertNil(decide(leftFits, .all).picked)
    }
}
