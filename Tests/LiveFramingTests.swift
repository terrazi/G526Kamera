import XCTest
@testable import G526CameraDrive

/// Canlı okumayla çekim öncesi kadraj denetimi: sorular kadraja tam sığıyor mu
final class LiveFramingTests: XCTestCase {
    private func evaluate(_ lines: [OCRLine]) -> LiveFramingResult {
        return LiveFraming.evaluate(lines: lines, total: 40, optionCount: 5, config: QualityConfig())
    }

    func testFullQuestionsInsideTheFrameAreReady() {
        let r = evaluate(OCRFixtures.question(12, y0: 0.2) + OCRFixtures.question(13, y0: 0.5))
        XCTAssertTrue(r.ready)
        XCTAssertNil(r.problem)
        XCTAssertEqual(r.questions, 2)
    }

    func testQuestionCutAtTheBottomIsReportedAsCut() {
        // 13. sorunun son şıkları kadrajın altında kaldı
        let r = evaluate(OCRFixtures.question(12, y0: 0.2) + OCRFixtures.question(13, y0: 0.62, options: "ABC"))
        XCTAssertFalse(r.ready)
        XCTAssertEqual(r.problem, .cutBottom)
        XCTAssertEqual(r.number, 13)
    }

    func testMissingOptionInTheMiddleIsIncompleteNotCut() {
        let r = evaluate(OCRFixtures.question(12, y0: 0.2, options: "ABD"))
        XCTAssertFalse(r.ready)
        XCTAssertEqual(r.problem, .incomplete)
        XCTAssertEqual(r.number, 12)
    }

    func testQuestionTouchingTheTopEdgeIsCutAtTheTop() {
        let r = evaluate(OCRFixtures.question(12, y0: 0.001) + OCRFixtures.question(13, y0: 0.4))
        XCTAssertFalse(r.ready)
        XCTAssertEqual(r.problem, .cutTop)
        XCTAssertEqual(r.number, 12)
    }

    func testMostImportantProblemWins() {
        // 12. soru üstten, 13. soru alttan kesik: alttan kesik önce söylenir (öncelik 0)
        let r = evaluate(OCRFixtures.question(12, y0: 0.001) + OCRFixtures.question(13, y0: 0.7, options: "ABC"))
        XCTAssertEqual(r.problem, .cutBottom)
        XCTAssertEqual(r.number, 13)
    }

    func testNoQuestionMeansNoDecision() {
        let r = evaluate([OCRFixtures.line("SAYISAL BÖLÜM", y: 0.1), OCRFixtures.line("Sayfa 3", y: 0.9)])
        XCTAssertFalse(r.ready)
        XCTAssertNil(r.problem)
        XCTAssertEqual(r.questions, 0, "karar verilemez: konum tarifine bakılır")
        XCTAssertEqual(evaluate([]).questions, 0)
    }

    func testLeadingTailAtTheTopIsNotAProblem() {
        let lines = [OCRFixtures.line("D) devam", y: 0.05), OCRFixtures.line("E) son", y: 0.08)] + OCRFixtures.question(10, y0: 0.2)
        XCTAssertTrue(evaluate(lines).ready, "önceki sorunun devamı sayfanın başında olabilir")
    }
}

final class LiveVerdictRulesTests: XCTestCase {
    func testVerdictIsValidOnlyForARecentUnmovedScene() {
        // sahne 10 sn'den beri durgun; okuma 3 sn önceki kareden
        XCTAssertTrue(ScanRules.liveVerdictValid(takenAt: 97, now: 100, sampleArrived: 99.5, stillFor: 10))
        // okunan kareden sonra kamera oynadı (durgunluk 1 sn, okunan kare 3 sn önce)
        XCTAssertFalse(ScanRules.liveVerdictValid(takenAt: 97, now: 100, sampleArrived: 99.5, stillFor: 1))
        // çok eski okuma
        XCTAssertFalse(ScanRules.liveVerdictValid(takenAt: 80, now: 100, sampleArrived: 99.5, stillFor: 30))
        // gelecekteki zaman geçersiz
        XCTAssertFalse(ScanRules.liveVerdictValid(takenAt: 101, now: 100, sampleArrived: 99.5, stillFor: 30))
    }

    func testLiveVerdictOverridesTheMovementAdvice() {
        XCTAssertTrue(ScanRules.framingReady(docFor: 3, advice: .moveDown, adviceAge: 0.5, live: true), "OCR sığdığını söylüyor")
        XCTAssertFalse(ScanRules.framingReady(docFor: 3, advice: .ok, adviceAge: 0.5, live: false), "OCR bir soru kesik diyor")
        XCTAssertTrue(ScanRules.framingReady(docFor: 3, advice: .ok, adviceAge: 0.5, live: nil), "canlı karar yoksa konum tarifi")
        XCTAssertFalse(ScanRules.framingReady(docFor: 3, advice: .moveDown, adviceAge: 0.5, live: nil))
    }

    func testWaitingLimitStillAppliesWithALiveVerdict() {
        let limit = ScanRules.settleSeconds + ScanRules.framingWaitSeconds
        XCTAssertTrue(ScanRules.framingReady(docFor: limit, advice: nil, adviceAge: 99, live: false), "sığmasa da süre dolunca çekilir")
    }
}
