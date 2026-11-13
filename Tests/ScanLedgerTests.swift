import XCTest
@testable import G526CameraDrive

final class ScanLedgerTests: XCTestCase {
    private func url(_ name: String) -> URL { return URL(fileURLWithPath: "/tmp/\(name).jpg") }

    func testMissingShrinksAsQuestionsAreAccepted() {
        var ledger = ScanLedger(total: 3)
        XCTAssertEqual(ledger.missing, [1, 2, 3])
        XCTAssertFalse(ledger.isComplete)
        ledger.accept(number: 2, pages: [url("a")], continuing: false)
        XCTAssertEqual(ledger.missing, [1, 3])
        XCTAssertEqual(ledger.acceptedNumbers, [2])
        ledger.accept(number: 1, pages: [url("b")], continuing: false)
        ledger.accept(number: 3, pages: [url("c")], continuing: false)
        XCTAssertTrue(ledger.isComplete)
        XCTAssertEqual(ledger.missing, [])
    }

    func testUnknownTotalNeverCompletes() {
        var ledger = ScanLedger(total: 0)
        ledger.accept(number: 1, pages: [url("a")], continuing: false)
        XCTAssertFalse(ledger.isComplete)
        XCTAssertEqual(ledger.missing, [])
    }

    func testAttemptLimitMarksTheQuestionUnreadable() {
        var ledger = ScanLedger(total: 2, maxAttempts: 3)
        XCTAssertFalse(ledger.noteReject(number: 2))
        XCTAssertFalse(ledger.noteReject(number: 2))
        XCTAssertTrue(ledger.noteReject(number: 2), "üçüncü denemede sınır doldu")
        XCTAssertEqual(ledger.unreadableNumbers, [2])
        XCTAssertEqual(ledger.missing, [1], "okunamadı işaretli soru eksik sayılmaz")
        XCTAssertFalse(ledger.noteReject(number: 2), "bir daha aynı soru için sınır bildirimi yapılmaz")
        ledger.accept(number: 1, pages: [url("a")], continuing: false)
        XCTAssertTrue(ledger.isComplete, "okunamayan soru atlanarak tarama tamamlanır")
    }

    func testZeroAttemptLimitMeansUnlimited() {
        var ledger = ScanLedger(total: 1, maxAttempts: 0)
        for _ in 0..<100 { XCTAssertFalse(ledger.noteReject(number: 1)) }
        XCTAssertEqual(ledger.attemptCount(1), 100)
        XCTAssertEqual(ledger.missing, [1])
    }

    func testAcceptingClearsUnreadable() {
        var ledger = ScanLedger(total: 1, maxAttempts: 1)
        XCTAssertTrue(ledger.noteReject(number: 1))
        ledger.accept(number: 1, pages: [url("a")], continuing: false)
        XCTAssertEqual(ledger.unreadableNumbers, [])
        XCTAssertTrue(ledger.isAccepted(1))
    }

    func testOpenQuestionIsMergedWithItsContinuation() {
        var ledger = ScanLedger(total: 5)
        ledger.startOpen(number: 4, pages: [url("p1"), url("p2")])
        XCTAssertEqual(ledger.openNumber, 4)
        XCTAssertFalse(ledger.isAccepted(4))
        ledger.extendOpen(pages: [url("p3")])
        ledger.accept(number: 4, pages: [url("p4")], continuing: true)
        XCTAssertEqual(ledger.pages[4]?.map { $0.lastPathComponent }, ["p1.jpg", "p2.jpg", "p3.jpg", "p4.jpg"])
        XCTAssertNil(ledger.openNumber)
        XCTAssertEqual(ledger.openPages, [])
    }

    func testGiveUpMarksTheRestUnreadableAndClosesOpen() {
        var ledger = ScanLedger(total: 4)
        ledger.accept(number: 1, pages: [url("a")], continuing: false)
        ledger.startOpen(number: 2, pages: [url("b")])
        ledger.giveUpOnMissing()
        XCTAssertEqual(ledger.unreadableNumbers, [2, 3, 4])
        XCTAssertNil(ledger.openNumber)
        XCTAssertTrue(ledger.isComplete)
    }

    func testDuplicatesAreCounted() {
        var ledger = ScanLedger(total: 1)
        ledger.noteDuplicate()
        ledger.noteDuplicate()
        XCTAssertEqual(ledger.duplicates, 2)
    }
}

final class ScanPlannerTests: XCTestCase {
    private func candidate(_ n: Int, frame: Int = 0, options: String = "ABCDE", y0: Double = 0.2) -> ShotCandidate {
        return ShotCandidate(frame: frame, block: OCRFixtures.block(n, y0: y0, options: options), sharp: 1.0, glare: 0)
    }

    private func selection(_ n: Int) -> ShotSelection {
        return ShotSelection(picks: [candidate(n)], problems: [])
    }

    private func analysis(_ outcomes: [QuestionOutcome], contFull: ShotSelection? = nil, contOpen: ShotSelection? = nil,
                          general: [ShotProblem] = [.unreadable]) -> CaptureAnalysis {
        return CaptureAnalysis(outcomes: outcomes, continuationFull: contFull, continuationOpen: contOpen, frameCount: 10,
                               generalProblems: general)
    }

    private let empty = ShotSelection(picks: [], problems: [])

    func testNewQuestionIsAcceptedAndKnownOneIsADuplicate() {
        var ledger = ScanLedger(total: 20)
        ledger.accept(number: 5, pages: [URL(fileURLWithPath: "/tmp/x.jpg")], continuing: false)
        let actions = ScanPlanner.plan(analysis([QuestionOutcome(number: 5, full: selection(5), open: empty),
                                                 QuestionOutcome(number: 6, full: selection(6), open: empty)]), ledger: ledger)
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(actions[0], .duplicate(number: 5))
        if case .accept(let n, let picks, let continuing) = actions[1] {
            XCTAssertEqual(n, 6)
            XCTAssertEqual(picks.count, 1)
            XCTAssertFalse(continuing)
        } else {
            XCTFail("6. soru kabul edilmeliydi")
        }
    }

    func testRejectedQuestionCarriesItsProblems() {
        let rejected = ShotSelection(picks: [], problems: [.blurry])
        let actions = ScanPlanner.plan(analysis([QuestionOutcome(number: 7, full: rejected, open: empty)]), ledger: ScanLedger(total: 20))
        XCTAssertEqual(actions, [.reject(number: 7, problems: [.blurry])])
    }

    func testOpenQuestionStartsAPartialCapture() {
        let open = ShotSelection(picks: [candidate(9, options: "ABCD", y0: 0.70)], problems: [])
        let actions = ScanPlanner.plan(analysis([QuestionOutcome(number: 9, full: empty, open: open)]), ledger: ScanLedger(total: 20))
        guard case .startOpen(let n, let picks)? = actions.first else { return XCTFail("parça alınmalıydı") }
        XCTAssertEqual(n, 9)
        XCTAssertEqual(picks.count, 1)
    }

    func testLeadingPartCompletesTheOpenQuestion() {
        var ledger = ScanLedger(total: 20)
        ledger.startOpen(number: 9, pages: [URL(fileURLWithPath: "/tmp/p1.jpg")])
        let cont = ShotSelection(picks: [candidate(1)], problems: [])
        let actions = ScanPlanner.plan(analysis([QuestionOutcome(number: 10, full: selection(10), open: empty)], contFull: cont),
                                       ledger: ledger)
        XCTAssertEqual(actions.count, 2)
        if case .accept(let n, _, let continuing) = actions[0] {
            XCTAssertEqual(n, 9)
            XCTAssertTrue(continuing)
        } else {
            XCTFail("devam parçası 9. soruyu tamamlamalıydı")
        }
    }

    func testLeadingPartWithoutLastOptionExtendsTheOpenQuestion() {
        var ledger = ScanLedger(total: 20)
        ledger.startOpen(number: 9, pages: [URL(fileURLWithPath: "/tmp/p1.jpg")])
        let part = ShotSelection(picks: [candidate(1)], problems: [])
        let actions = ScanPlanner.plan(analysis([], contFull: empty, contOpen: part), ledger: ledger)
        guard case .extendOpen(let picks)? = actions.first else { return XCTFail("parça eklenmeliydi") }
        XCTAssertEqual(picks.count, 1)
    }

    func testLeadingPartIsIgnoredWhenNothingIsOpen() {
        let cont = ShotSelection(picks: [candidate(1)], problems: [])
        let actions = ScanPlanner.plan(analysis([QuestionOutcome(number: 3, full: selection(3), open: empty)], contFull: cont),
                                       ledger: ScanLedger(total: 20))
        XCTAssertEqual(actions.count, 1)
    }

    func testNothingFoundIsUnidentified() {
        let actions = ScanPlanner.plan(analysis([], general: [.glare]), ledger: ScanLedger(total: 20))
        XCTAssertEqual(actions, [.unidentified(problems: [.glare])])
    }
}

final class CaptureAnalyzerTests: XCTestCase {
    private func frame(_ index: Int, lines: [OCRLine], sharp: Double = 1.0, glare: Double = 0) -> AnalyzedFrame {
        return AnalyzedFrame(index: index, lines: lines, sharp: sharp, glare: glare)
    }

    func testBestFramesAreChosenPerQuestion() {
        let page = OCRFixtures.question(12, y0: 0.2) + OCRFixtures.question(13, y0: 0.5)
        let frames = [frame(0, lines: page, sharp: 0.2), frame(1, lines: page, sharp: 1.1), frame(4, lines: page, sharp: 0.9)]
        let result = CaptureAnalyzer.analyze(frames, total: 40, optionCount: 5, config: QualityConfig())
        XCTAssertEqual(result.outcomes.map { $0.number }, [12, 13])
        for outcome in result.outcomes {
            XCTAssertEqual(outcome.full.picks.first?.frame, 1, "en net kare önce")
            XCTAssertFalse(outcome.full.picks.contains(where: { $0.frame == 0 }), "bulanık kare seçilmez")
        }
        XCTAssertEqual(result.frameCount, 3)
    }

    func testQuestionSeenOnlyOpenIsReportedAsOpen() {
        let page = OCRFixtures.question(12, y0: 0.70, options: "ABCD")
        let result = CaptureAnalyzer.analyze([frame(0, lines: page), frame(3, lines: page)], total: 40, optionCount: 5,
                                             config: QualityConfig())
        XCTAssertEqual(result.outcomes.count, 1)
        XCTAssertTrue(result.outcomes[0].full.picks.isEmpty)
        XCTAssertFalse(result.outcomes[0].open.picks.isEmpty)
    }

    func testLeadingPartNeedsOptions() {
        let titleOnly = [OCRFixtures.line("SAYISAL BÖLÜM", y: 0.05), OCRFixtures.line("Sayfa 3", y: 0.08)]
        let withTitle = CaptureAnalyzer.analyze([frame(0, lines: titleOnly + OCRFixtures.question(2, y0: 0.2))], total: 40,
                                                optionCount: 5, config: QualityConfig())
        XCTAssertNil(withTitle.continuationFull, "başlık satırları devam parçası sayılmaz")
        let head = [OCRFixtures.line("D) devam", y: 0.05), OCRFixtures.line("E) son", y: 0.08)]
        let withOptions = CaptureAnalyzer.analyze([frame(0, lines: head + OCRFixtures.question(2, y0: 0.2))], total: 40,
                                                  optionCount: 5, config: QualityConfig())
        XCTAssertNotNil(withOptions.continuationFull)
    }

    func testGeneralProblemsExplainWhyNothingWasFound() {
        let config = QualityConfig()
        XCTAssertEqual(CaptureAnalyzer.generalProblems([], config: config), [.unreadable])
        let text = (0..<6).map { OCRFixtures.line("satır \($0)", y: 0.1 + 0.05 * Double($0)) }
        XCTAssertEqual(CaptureAnalyzer.generalProblems([frame(0, lines: text, glare: 0.1)], config: config), [.glare])
        XCTAssertEqual(CaptureAnalyzer.generalProblems([frame(0, lines: text, sharp: 0.1)], config: config), [.blurry])
        XCTAssertEqual(CaptureAnalyzer.generalProblems([frame(0, lines: [], sharp: 1.0)], config: config), [.unreadable])
    }
}
