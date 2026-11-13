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
        ledger.extendOpen(number: 4, pages: [url("p3")])
        ledger.accept(number: 4, pages: [url("p4")], continuing: true)
        XCTAssertEqual(ledger.pages[4]?.map { $0.lastPathComponent }, ["p1.jpg", "p2.jpg", "p3.jpg", "p4.jpg"])
        XCTAssertNil(ledger.openNumber)
        XCTAssertFalse(ledger.isOpen(4))
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

    func testCutQuestionIsWarnedAboutBeforeItIsTakenAsAPart() {
        let open = ShotSelection(picks: [candidate(9, options: "ABCD", y0: 0.70)], problems: [])
        let outcome = QuestionOutcome(number: 9, full: empty, open: open)
        var ledger = ScanLedger(total: 20)
        // İlk iki çekimde yarım soru istenmez: "alttan kesilmiş" uyarısı verilir
        for _ in 0..<ScanLedger.warningsBeforePartial {
            XCTAssertEqual(ScanPlanner.plan(analysis([outcome]), ledger: ledger), [.reject(number: 9, problems: [.cutBottom])])
            ledger.noteReject(number: 9)
        }
        // Uyarılara rağmen sığmadıysa (sayfa sonunda bölünen soru) parça alınır
        guard case .startOpen(let n, let picks)? = ScanPlanner.plan(analysis([outcome]), ledger: ledger).first else {
            return XCTFail("parça alınmalıydı")
        }
        XCTAssertEqual(n, 9)
        XCTAssertEqual(picks.count, 1)
    }

    func testPartialIsTakenAtOnceWhenTheAttemptLimitIsTiny() {
        let open = ShotSelection(picks: [candidate(9, options: "ABCD", y0: 0.70)], problems: [])
        let outcome = QuestionOutcome(number: 9, full: empty, open: open)
        let one = ScanLedger(total: 20, maxAttempts: 1)
        XCTAssertTrue(one.partialAllowed(9), "tek denemede uyarı beklenemez: soru okunamadı olurdu")
        guard case .startOpen? = ScanPlanner.plan(analysis([outcome]), ledger: one).first else { return XCTFail("parça alınmalıydı") }
        XCTAssertFalse(ScanLedger(total: 20, maxAttempts: 5).partialAllowed(9))
        XCTAssertFalse(ScanLedger(total: 20, maxAttempts: 0).partialAllowed(9))
    }

    func testFullQuestionIsNeverWarnedAbout() {
        let actions = ScanPlanner.plan(analysis([QuestionOutcome(number: 9, full: selection(9), open: empty)]), ledger: ScanLedger(total: 20))
        guard case .accept(let n, _, let continuing)? = actions.first else { return XCTFail("tam soru kabul edilmeliydi") }
        XCTAssertEqual(n, 9)
        XCTAssertFalse(continuing)
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
        guard case .extendOpen(let n, let picks)? = actions.first else { return XCTFail("parça eklenmeliydi") }
        XCTAssertEqual(n, 9)
        XCTAssertEqual(picks.count, 1)
    }

    func testLeadingPartIsStashedWhenItsHeadIsNotCapturedYet() {
        let cont = ShotSelection(picks: [candidate(1)], problems: [])
        let actions = ScanPlanner.plan(analysis([QuestionOutcome(number: 3, full: selection(3), open: empty)], contFull: cont),
                                       ledger: ScanLedger(total: 20))
        XCTAssertEqual(actions.count, 2)
        guard case .stashTail(let n, let picks) = actions[0] else { return XCTFail("alt kısım saklanmalıydı") }
        XCTAssertEqual(n, 2, "3. sorudan önceki sorunun devamı")
        XCTAssertEqual(picks.count, 1)
    }

    func testLeadingPartOnThePageOfQuestionOneIsIgnored() {
        let cont = ShotSelection(picks: [candidate(1)], problems: [])
        let actions = ScanPlanner.plan(analysis([QuestionOutcome(number: 1, full: selection(1), open: empty)], contFull: cont),
                                       ledger: ScanLedger(total: 20))
        XCTAssertEqual(actions.count, 1, "1. sorudan önce soru yoktur: baştaki satırlar başlık sayılır")
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

/// Sorular sırayla çekilmese de (karışık sıra) kayıtlar soru numarasına göre tutulur
final class MixedOrderTests: XCTestCase {
    private func url(_ name: String) -> URL { return URL(fileURLWithPath: "/tmp/\(name).jpg") }

    private func candidate(_ n: Int, options: String = "ABCDE", y0: Double = 0.2) -> ShotCandidate {
        return ShotCandidate(frame: 0, block: OCRFixtures.block(n, y0: y0, options: options), sharp: 1.0, glare: 0)
    }

    private func frame(_ index: Int, lines: [OCRLine]) -> AnalyzedFrame {
        return AnalyzedFrame(index: index, lines: lines, sharp: 1.0, glare: 0)
    }

    private func analyze(_ lines: [OCRLine], frames: Int = 3) -> CaptureAnalysis {
        return CaptureAnalyzer.analyze((0..<frames).map { frame($0 * 3, lines: lines) }, total: 40, optionCount: 5, config: QualityConfig())
    }

    func testQuestionsInAnyOrderCompleteTheScan() {
        var ledger = ScanLedger(total: 6)
        for n in [5, 2, 6, 1, 4, 3] {
            XCTAssertFalse(ledger.isComplete)
            ledger.accept(number: n, pages: [url("q\(n)")], continuing: false)
        }
        XCTAssertTrue(ledger.isComplete)
        XCTAssertEqual(ledger.acceptedNumbers, [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(QuestionGroups.split(ledger.acceptedNumbers, size: 3), [[1, 2, 3], [4, 5, 6]])
    }

    func testMissingListIsSortedWhateverTheScanOrder() {
        var ledger = ScanLedger(total: 8)
        for n in [7, 2, 5] { ledger.accept(number: n, pages: [url("q\(n)")], continuing: false) }
        XCTAssertEqual(ledger.missing, [1, 3, 4, 6, 8])
    }

    func testTwoOpenQuestionsAreKeptApart() {
        var ledger = ScanLedger(total: 20)
        ledger.startOpen(number: 4, pages: [url("a4")])
        ledger.startOpen(number: 9, pages: [url("a9")])
        XCTAssertEqual(ledger.openNumbers, [4, 9])
        XCTAssertEqual(ledger.waitingNumbers, [4, 9])
        ledger.accept(number: 9, pages: [url("b9")], continuing: true)
        XCTAssertEqual(ledger.pages[9]?.map { $0.lastPathComponent }, ["a9.jpg", "b9.jpg"])
        XCTAssertTrue(ledger.isOpen(4), "4. sorunun üst kısmı kaybolmadı")
        XCTAssertEqual(ledger.openNumbers, [4])
        ledger.accept(number: 4, pages: [url("b4")], continuing: true)
        XCTAssertEqual(ledger.pages[4]?.map { $0.lastPathComponent }, ["a4.jpg", "b4.jpg"])
        XCTAssertEqual(ledger.waitingNumbers, [])
    }

    func testTailCapturedFirstIsJoinedWithItsHead() {
        var ledger = ScanLedger(total: 20)
        ledger.stashTail(number: 9, pages: [url("tail9")])
        XCTAssertTrue(ledger.hasTail(9))
        XCTAssertEqual(ledger.waitingNumbers, [9])
        XCTAssertFalse(ledger.isAccepted(9))
        let head = ShotSelection(picks: [candidate(9, options: "ABC", y0: 0.7)], problems: [])
        let empty = ShotSelection(picks: [], problems: [])
        let a = CaptureAnalysis(outcomes: [QuestionOutcome(number: 9, full: empty, open: head)], continuationFull: nil,
                                continuationOpen: nil, frameCount: 10, generalProblems: [.unreadable])
        let actions = ScanPlanner.plan(a, ledger: ledger)
        guard case .accept(let n, _, let continuing)? = actions.first else { return XCTFail("baş ile son birleşmeliydi") }
        XCTAssertEqual(n, 9)
        XCTAssertTrue(continuing)
        ledger.accept(number: 9, pages: [url("head9")], continuing: true)
        XCTAssertEqual(ledger.pages[9]?.map { $0.lastPathComponent }, ["head9.jpg", "tail9.jpg"], "önce üst, sonra alt kısım")
        XCTAssertFalse(ledger.hasTail(9))
    }

    func testTailOfAnotherQuestionIsNotAttachedToTheOpenOne() {
        var ledger = ScanLedger(total: 20)
        ledger.startOpen(number: 4, pages: [url("a4")])
        // Sayfa 10. sorudan başlıyor: baştaki parça 9. sorunun sonudur, açık olan 4. sorunun değil
        let lines = [OCRFixtures.line("D) devam", y: 0.05), OCRFixtures.line("E) son", y: 0.08)] + OCRFixtures.question(10, y0: 0.2)
        let a = analyze(lines)
        XCTAssertEqual(a.firstNumber, 10)
        let actions = ScanPlanner.plan(a, ledger: ledger)
        XCTAssertTrue(actions.contains(where: { if case .stashTail(let n, _) = $0 { return n == 9 } else { return false } }))
        XCTAssertFalse(actions.contains(where: { if case .accept(let n, _, _) = $0 { return n == 4 } else { return false } }),
                       "4. soru yanlış devamla tamamlanmamalı")
        XCTAssertTrue(actions.contains(where: { if case .accept(let n, _, _) = $0 { return n == 10 } else { return false } }))
    }

    func testTailBelongsToTheQuestionBeforeTheFirstNumberedOne() {
        var ledger = ScanLedger(total: 20)
        ledger.startOpen(number: 9, pages: [url("a9")])
        let lines = [OCRFixtures.line("D) devam", y: 0.05), OCRFixtures.line("E) son", y: 0.08)] + OCRFixtures.question(10, y0: 0.2)
        let actions = ScanPlanner.plan(analyze(lines), ledger: ledger)
        guard case .accept(let n, _, let continuing)? = actions.first else { return XCTFail("9. soru tamamlanmalıydı") }
        XCTAssertEqual(n, 9)
        XCTAssertTrue(continuing)
    }

    func testFirstNumberIsTheTopmostQuestionOfTheMajorityOfFrames() {
        let both = OCRFixtures.question(12, y0: 0.2) + OCRFixtures.question(13, y0: 0.5)
        let misread = OCRFixtures.question(13, y0: 0.5)
        let frames = [frame(0, lines: both), frame(3, lines: misread), frame(6, lines: both)]
        let a = CaptureAnalyzer.analyze(frames, total: 40, optionCount: 5, config: QualityConfig())
        XCTAssertEqual(a.firstNumber, 12, "tek karedeki eksik okuma sonucu bozmaz")
        XCTAssertNil(analyze(OCRFixtures.question(12, y0: 0.2), frames: 0).firstNumber, "kare yoksa ilk numara yok")
    }

    func testPagesShownInReverseOrderAreAllRecorded() {
        var ledger = ScanLedger(total: 12)
        // Önce 7-8-9. sorular, sonra 1-2-3. sorular, sonra 4-5-6: hepsi numarasına göre kaydedilir
        let pagesInOrder = [[7, 8, 9], [1, 2, 3], [4, 5, 6]]
        for page in pagesInOrder {
            var lines: [OCRLine] = []
            for (i, n) in page.enumerated() { lines += OCRFixtures.question(n, y0: 0.05 + 0.3 * Double(i)) }
            let actions = ScanPlanner.plan(analyze(lines), ledger: ledger)
            for action in actions {
                if case .accept(let n, _, let continuing) = action {
                    ledger.accept(number: n, pages: [url("q\(n)")], continuing: continuing)
                }
            }
        }
        XCTAssertEqual(ledger.acceptedNumbers, [1, 2, 3, 4, 5, 6, 7, 8, 9])
        XCTAssertEqual(ledger.missing, [10, 11, 12])
    }
}
