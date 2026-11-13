import XCTest
@testable import G526CameraDrive

final class QualityGateTests: XCTestCase {
    private let config = QualityConfig()

    private func block(_ n: Int = 12, y0: Double = 0.20, options: String = "ABCDE", conf: Double = 0.9) -> QuestionBlock {
        return OCRFixtures.block(n, y0: y0, options: options, conf: conf)
    }

    private func candidate(_ b: QuestionBlock, frame: Int = 0, sharp: Double = 1.0, glare: Double = 0) -> ShotCandidate {
        return ShotCandidate(frame: frame, block: b, sharp: sharp, glare: glare)
    }

    func testGoodCandidateHasNoProblem() {
        XCTAssertEqual(QualityGate.problems(candidate(block()), config: config), [])
        let selection = QualityGate.select([candidate(block())], config: config)
        XCTAssertEqual(selection.picks.count, 1)
        XCTAssertTrue(selection.problems.isEmpty)
    }

    func testBlurryAndGlareAreReported() {
        XCTAssertEqual(QualityGate.problems(candidate(block(), sharp: 0.2), config: config), [.blurry])
        XCTAssertEqual(QualityGate.problems(candidate(block(), glare: 0.05), config: config), [.glare])
        let both = QualityGate.problems(candidate(block(), sharp: 0.2, glare: 0.05), config: config)
        XCTAssertEqual(both, [.blurry, .glare], "önem sırasıyla")
    }

    func testSharpnessSettingChangesTheFloor() {
        XCTAssertEqual(QualityConfig.floor(forSharpness: 0), 0.30)
        XCTAssertEqual(QualityConfig.floor(forSharpness: 1), 0.45)
        XCTAssertEqual(QualityConfig.floor(forSharpness: 2), 0.60)
        XCTAssertEqual(QualityConfig.floor(forSharpness: 9), 0.60)
        let strict = QualityConfig(sharpFloor: 0.60)
        XCTAssertEqual(QualityGate.problems(candidate(block(), sharp: 0.5), config: strict), [.blurry])
        XCTAssertEqual(QualityGate.problems(candidate(block(), sharp: 0.5), config: config), [])
    }

    func testCutBottomIsTheTopPriority() {
        let cut = block(y0: 0.80)
        let problems = QualityGate.problems(candidate(cut, sharp: 0.2), config: config)
        XCTAssertEqual(problems.first, .cutBottom)
        XCTAssertTrue(problems.contains(.blurry))
    }

    func testIncompleteOptionsAreAProblemUnlessTheQuestionOpensBelow() {
        let incomplete = QuestionLayout.analyze(lines: OCRFixtures.question(5, y0: 0.20, options: "ABC") + OCRFixtures.question(6, y0: 0.50),
                                                total: 40, optionCount: 5).blocks[0]
        XCTAssertEqual(QualityGate.problems(candidate(incomplete), config: config), [.incomplete])
        let open = block(y0: 0.70, options: "ABCD")
        XCTAssertTrue(open.opensBelow)
        XCTAssertFalse(QualityGate.problems(candidate(open), config: config).isEmpty)
        XCTAssertEqual(QualityGate.problems(candidate(open), config: config, allowOpen: true), [])
    }

    func testLowConfidenceAndTinyTextAreUnreadable() {
        XCTAssertEqual(QualityGate.problems(candidate(block(conf: 0.3)), config: config), [.unreadable])
        var tiny = block()
        tiny.pitch = 0.005
        XCTAssertEqual(QualityGate.problems(candidate(tiny), config: config), [.tooSmall])
    }

    func testSecondPickNeedsEnoughFrameGap() {
        let good = block()
        let close = QualityGate.select([candidate(good, frame: 0), candidate(good, frame: 1)], config: config)
        XCTAssertEqual(close.picks.count, 1, "yan yana kareler iki kez eklenmez")
        let apart = QualityGate.select([candidate(good, frame: 0), candidate(good, frame: 4)], config: config)
        XCTAssertEqual(apart.picks.count, 2)
    }

    func testBestFrameComesFirstAndBadOnesAreNeverPicked() {
        let good = block()
        let picks = QualityGate.select([candidate(good, frame: 0, sharp: 0.3), candidate(good, frame: 3, sharp: 1.1),
                                        candidate(good, frame: 6, sharp: 0.9)], config: config).picks
        XCTAssertEqual(picks.first?.frame, 3)
        XCTAssertFalse(picks.contains(where: { $0.frame == 0 }), "bulanık kare seçilmez")
        let none = QualityGate.select([candidate(good, sharp: 0.1)], config: config)
        XCTAssertTrue(none.picks.isEmpty)
        XCTAssertEqual(none.problems, [.blurry])
        XCTAssertTrue(QualityGate.select([], config: config).picks.isEmpty)
    }

    func testSpokenSentences() {
        XCTAssertEqual(QualityGate.spoken([.cutBottom], number: 12), "On ikinci soru alttan kesilmiş. Kamerayı biraz aşağı kaydırın.")
        XCTAssertEqual(QualityGate.spoken([.blurry, .cutTop], number: 3), "Üçüncü soru üstten kesilmiş. Kamerayı biraz yukarı kaydırın.")
        XCTAssertEqual(QualityGate.spoken([.blurry], number: 0), "Yazı bulanık. Kamerayı sabit tutun.")
        XCTAssertEqual(QualityGate.spoken([], number: 4), "")
    }
}
