import XCTest
@testable import G526CameraDrive

final class ScanVerdictTests: XCTestCase {
    private func verdict(total: Int = 40, accepted: Int = 5, complete: Bool = false, elapsed: TimeInterval = 100,
                         maxSeconds: TimeInterval = 900, emptyFor: TimeInterval = 0, sinceProgress: TimeInterval = 0,
                         asked: Bool = false, deadlinePassed: Bool = false) -> ScanRules.Verdict {
        return ScanRules.verdict(total: total, accepted: accepted, complete: complete, elapsed: elapsed, maxSeconds: maxSeconds,
                                 emptyFor: emptyFor, sinceProgress: sinceProgress, asked: asked, deadlinePassed: deadlinePassed)
    }

    func testCompleteAlwaysFinishes() {
        XCTAssertEqual(verdict(complete: true), .finish(.complete))
        XCTAssertEqual(verdict(complete: true, elapsed: 5000), .finish(.complete), "süre dolmuş olsa bile tamam öncelikli")
    }

    func testTimeLimitFinishesButZeroMeansNoLimit() {
        XCTAssertEqual(verdict(elapsed: 900), .finish(.timeLimit))
        XCTAssertEqual(verdict(elapsed: 5000, maxSeconds: 0), .keepGoing)
    }

    func testKnownTotalAsksForMissingAfterTenEmptySeconds() {
        XCTAssertEqual(verdict(emptyFor: 9.9), .keepGoing)
        XCTAssertEqual(verdict(emptyFor: 10), .askMissing)
        XCTAssertEqual(verdict(emptyFor: 30, asked: true), .keepGoing, "bir kez sorulduktan sonra tekrar askMissing dönmez")
    }

    func testNothingAcceptedNeverAsksForMissing() {
        XCTAssertEqual(verdict(accepted: 0, emptyFor: 60), .keepGoing)
    }

    func testGivesUpAfterTheMissingDeadline() {
        XCTAssertEqual(verdict(emptyFor: 5, asked: true, deadlinePassed: true), .finish(.missingGaveUp))
        XCTAssertEqual(verdict(asked: true, deadlinePassed: false), .keepGoing)
    }

    func testUnknownTotalEndsOnEmptyFrameOrNoProgress() {
        XCTAssertEqual(verdict(total: 0, emptyFor: 19), .keepGoing)
        XCTAssertEqual(verdict(total: 0, emptyFor: 20), .finish(.noMoreQuestions))
        XCTAssertEqual(verdict(total: 0, sinceProgress: 89), .keepGoing)
        XCTAssertEqual(verdict(total: 0, sinceProgress: 90), .finish(.noMoreQuestions))
        XCTAssertEqual(verdict(total: 0, accepted: 0, emptyFor: 500, sinceProgress: 500), .keepGoing, "hiç soru yokken bitirilmez")
    }
}

final class ScanTimingTests: XCTestCase {
    func testRearmFirstCaptureIsImmediate() {
        XCTAssertTrue(ScanRules.canRearm(firstCapture: true, diffToCapture: 0, stillFor: 0, sinceLastWindow: 0))
    }

    func testRearmAfterPageTurnNeedsStillness() {
        XCTAssertFalse(ScanRules.canRearm(firstCapture: false, diffToCapture: 9, stillFor: 0.1, sinceLastWindow: 3))
        XCTAssertTrue(ScanRules.canRearm(firstCapture: false, diffToCapture: 9, stillFor: 0.5, sinceLastWindow: 3))
        XCTAssertFalse(ScanRules.canRearm(firstCapture: false, diffToCapture: 2, stillFor: 5, sinceLastWindow: 3), "aynı sahne")
    }

    func testRearmSameSceneAfterTwelveSeconds() {
        XCTAssertFalse(ScanRules.canRearm(firstCapture: false, diffToCapture: 0, stillFor: 20, sinceLastWindow: 11.9))
        XCTAssertTrue(ScanRules.canRearm(firstCapture: false, diffToCapture: 0, stillFor: 20, sinceLastWindow: 12))
    }

    func testReadyPrompt() {
        XCTAssertTrue(ScanRules.readyPromptDue(lastSpoken: nil, now: 0, repeatSeconds: 30))
        XCTAssertFalse(ScanRules.readyPromptDue(lastSpoken: 100, now: 129, repeatSeconds: 30))
        XCTAssertTrue(ScanRules.readyPromptDue(lastSpoken: 100, now: 130, repeatSeconds: 30))
        XCTAssertFalse(ScanRules.readyPromptDue(lastSpoken: 100, now: 102, repeatSeconds: 0), "en sık 5 sn'de bir")
        XCTAssertTrue(ScanRules.readyPromptDue(lastSpoken: 100, now: 105, repeatSeconds: 0))
    }

    func testReadyGaveUp() {
        XCTAssertFalse(ScanRules.readyGaveUp(waited: 599, maxMinutes: 10))
        XCTAssertTrue(ScanRules.readyGaveUp(waited: 600, maxMinutes: 10))
        XCTAssertFalse(ScanRules.readyGaveUp(waited: 99999, maxMinutes: 0), "0 = sınırsız bekle")
    }

    func testDefaultsMatchTheAgreedDesign() {
        XCTAssertEqual(ScanRules.settleSeconds, 2)
        XCTAssertEqual(ScanRules.windowSeconds, 5)
        XCTAssertEqual(ScanRules.emptyForMissing, 10)
        XCTAssertEqual(ScanRules.sameWarningGap, 10)
    }
}

final class ScanTextTests: XCTestCase {
    func testMissingText() {
        XCTAssertEqual(ScanRules.missingText([]), "")
        XCTAssertEqual(ScanRules.missingText([15]), "15. soru eksik. İlgili sayfayı kameraya tutun.")
        XCTAssertEqual(ScanRules.missingText([15, 22]), "15 ve 22 eksik. İlgili sayfaları kameraya tutun.")
    }

    func testAcceptedAndContinueText() {
        XCTAssertEqual(ScanRules.acceptedText([]), "")
        XCTAssertEqual(ScanRules.acceptedText([12]), "12 alındı.")
        XCTAssertEqual(ScanRules.acceptedText([12, 13, 14]), "12, 13 ve 14 alındı.")
        XCTAssertEqual(ScanRules.continueText(12), "On ikinci sorunun devamını kameraya tutun.")
        XCTAssertEqual(ScanRules.continueText(2), "İkinci sorunun devamını kameraya tutun.")
    }
}

final class RepeatGateTests: XCTestCase {
    func testSameWarningIsHeldBackForTenSeconds() {
        var gate = RepeatGate()
        XCTAssertTrue(gate.allow("Yazı bulanık.", now: 0))
        XCTAssertFalse(gate.allow("Yazı bulanık.", now: 9.9))
        XCTAssertTrue(gate.allow("Yazı bulanık.", now: 10))
    }

    func testDifferentWarningsDoNotBlockEachOther() {
        var gate = RepeatGate()
        XCTAssertTrue(gate.allow("a", now: 0))
        XCTAssertTrue(gate.allow("b", now: 1))
        XCTAssertFalse(gate.allow("a", now: 2))
        gate.reset()
        XCTAssertTrue(gate.allow("a", now: 3))
    }
}

final class QuestionGroupsTests: XCTestCase {
    func testSplit() {
        XCTAssertEqual(QuestionGroups.split([1, 2, 3, 4, 5], size: 2), [[1, 2], [3, 4], [5]])
        XCTAssertEqual(QuestionGroups.split([5, 3, 1, 2, 4, 4], size: 3), [[1, 2, 3], [4, 5]])
        XCTAssertEqual(QuestionGroups.split([7, 8], size: 1), [[7], [8]])
        XCTAssertEqual(QuestionGroups.split([7, 8], size: 0), [[7], [8]], "0 → 1")
        XCTAssertEqual(QuestionGroups.split([], size: 2), [])
    }

    func testPdfName() {
        XCTAssertEqual(QuestionGroups.pdfName([12]), "S12.pdf")
        XCTAssertEqual(QuestionGroups.pdfName([12, 13, 14]), "S12-14.pdf")
        XCTAssertEqual(QuestionGroups.pdfName([14, 12]), "S12-14.pdf")
        XCTAssertEqual(QuestionGroups.pdfName([]), "S0.pdf")
    }
}

final class ReadingPlanTests: XCTestCase {
    private let codes: [(letter: String, word: String)] = [("A", "ADANA"), ("B", "BURSA"), ("C", "ÇORUM")]

    func testLinesAreSortedAndUseCityCodes() {
        let records = [AnswerRecord(number: 3, status: "tamam", letter: "B", value: "elli"),
                       AnswerRecord(number: 1, status: "tamam", letter: "A", value: "kırk iki")]
        XCTAssertEqual(ReadingPlan.lines(records, codes: codes),
                       ["Birinci soru, ADANA, kırk iki.", "Üçüncü soru, BURSA, elli."])
    }

    func testUnanswered() {
        let records = [AnswerRecord(number: 1, status: "tamam", letter: "A", value: "x"),
                       AnswerRecord(number: 2, status: "okunamadi", letter: "", value: ""),
                       AnswerRecord(number: 3, status: "belirsiz", letter: "C", value: "y")]
        XCTAssertEqual(ReadingPlan.unanswered(requested: [1, 2, 3, 4], records: records), [2, 4])
        XCTAssertEqual(ReadingPlan.unansweredText([]), "")
        XCTAssertEqual(ReadingPlan.unansweredText([2]), "2. soru okunamadı ya da cevaplanamadı.")
        XCTAssertEqual(ReadingPlan.unansweredText([2, 4]), "Okunamayan ya da cevaplanamayan sorular: 2 ve 4.")
    }

    func testFileText() {
        let records = [AnswerRecord(number: 1, status: "tamam", letter: "A", value: "kırk iki"),
                       AnswerRecord(number: 2, status: "okunamadi", letter: "", value: ""),
                       AnswerRecord(number: 3, status: "belirsiz", letter: "C", value: "")]
        let text = ReadingPlan.fileText(records, unanswered: [2, 4], codes: codes)
        XCTAssertEqual(text, "1. soru: A (ADANA) — kırk iki\n2. soru: okunamadı\n3. soru: C (ÇORUM) [emin değil]\n4. soru: cevap yok\n")
    }
}

final class RunNameTests: XCTestCase {
    func testFormat() {
        let utc = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_794_564_000)   // 2026-11-13 10:00:00 UTC
        XCTAssertEqual(RunName.make(date, timeZone: utc), "Sinav-20261113-1000")
        let istanbul = TimeZone(identifier: "Europe/Istanbul")!
        XCTAssertEqual(RunName.make(date, timeZone: istanbul), "Sinav-20261113-1300")
    }
}

/// Çekimden önce kadraj denetimi: yazı kadraja tam sığmadan (yarım soru kalmasın) çekim başlamaz
final class FramingGateTests: XCTestCase {
    func testCaptureWaitsUntilTheTextFitsTheFrame() {
        XCTAssertTrue(ScanRules.framingReady(docFor: 3, advice: .ok, adviceAge: 0.5))
        for advice in [GuidanceAdvice.moveDown, .moveUp, .moveLeft, .moveRight, .closer, .farther, .noText] {
            XCTAssertFalse(ScanRules.framingReady(docFor: 3, advice: advice, adviceAge: 0.5), "\(advice) iken çekilmez")
        }
    }

    func testCaptureWaitsWhileTheCameraIsMovingOrTheAdviceIsStale() {
        XCTAssertFalse(ScanRules.framingReady(docFor: 3, advice: nil, adviceAge: 0.5), "kamera hareket ediyorsa öneri yoktur")
        XCTAssertFalse(ScanRules.framingReady(docFor: 3, advice: .ok, adviceAge: 2.5), "eski ölçüme güvenilmez")
    }

    func testCaptureHappensAnywayAfterTheWaitingLimit() {
        let limit = ScanRules.settleSeconds + ScanRules.framingWaitSeconds
        XCTAssertFalse(ScanRules.framingReady(docFor: limit - 0.5, advice: .moveDown, adviceAge: 0.5))
        XCTAssertTrue(ScanRules.framingReady(docFor: limit, advice: .moveDown, adviceAge: 0.5), "sığmasa da süre dolunca çekilir")
        XCTAssertTrue(ScanRules.framingReady(docFor: limit, advice: nil, adviceAge: 99))
    }
}
