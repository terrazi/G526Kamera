import XCTest
@testable import G526CameraDrive

final class ScanVerdictTests: XCTestCase {
    private func verdict(pageTotal: Int = 5, pages: Int = 2, elapsed: TimeInterval = 100, maxSeconds: TimeInterval = 900,
                         emptyFor: TimeInterval = 0, sinceProgress: TimeInterval = 0) -> ScanRules.Verdict {
        return ScanRules.verdict(pageTotal: pageTotal, pages: pages, elapsed: elapsed, maxSeconds: maxSeconds,
                                 emptyFor: emptyFor, sinceProgress: sinceProgress)
    }

    func testFinishesWhenAllPagesAreTaken() {
        XCTAssertEqual(verdict(pages: 4), .keepGoing)
        XCTAssertEqual(verdict(pages: 5), .finish(.complete))
        XCTAssertEqual(verdict(pages: 6, elapsed: 5000), .finish(.complete), "süre dolmuş olsa bile tamam öncelikli")
    }

    func testTimeLimitFinishesButZeroMeansNoLimit() {
        XCTAssertEqual(verdict(elapsed: 900), .finish(.timeLimit))
        XCTAssertEqual(verdict(elapsed: 5000, maxSeconds: 0), .keepGoing)
    }

    func testEndsOnEmptyFrameOrNoProgressOnceAPageIsTaken() {
        XCTAssertEqual(verdict(emptyFor: 19.9), .keepGoing)
        XCTAssertEqual(verdict(emptyFor: 20), .finish(.noMorePages))
        XCTAssertEqual(verdict(sinceProgress: 89), .keepGoing)
        XCTAssertEqual(verdict(sinceProgress: 90), .finish(.noMorePages))
    }

    func testUnknownPageTotalEndsTheSameWay() {
        XCTAssertEqual(verdict(pageTotal: 0, pages: 7), .keepGoing, "sayfa sayısı bilinmiyorsa tamam diye bitmez")
        XCTAssertEqual(verdict(pageTotal: 0, pages: 7, emptyFor: 20), .finish(.noMorePages))
    }

    func testNothingTakenNeverEndsOnEmptyFrame() {
        XCTAssertEqual(verdict(pages: 0, emptyFor: 500, sinceProgress: 500), .keepGoing, "hiç sayfa yokken bitirilmez")
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
        XCTAssertEqual(ScanRules.emptyForEnd, 20)
        XCTAssertEqual(ScanRules.noProgressForEnd, 90)
        XCTAssertEqual(ScanRules.maxStills, 8)
    }
}

final class ScanTextTests: XCTestCase {
    func testPageTakenText() {
        XCTAssertEqual(ScanRules.pageTakenText(1), "Birinci sayfa alındı.")
        XCTAssertEqual(ScanRules.pageTakenText(12), "On ikinci sayfa alındı.")
    }

    func testSideList() {
        XCTAssertEqual(ScanRules.sideList([]), "")
        XCTAssertEqual(ScanRules.sideList([.bottom]), "alt")
        XCTAssertEqual(ScanRules.sideList([.top, .bottom]), "üst ve alt")
        XCTAssertEqual(ScanRules.sideList([.top, .bottom, .left]), "üst, alt ve sol")
    }

    func testCoverageTexts() {
        XCTAssertEqual(ScanRules.coverageRetryText([.bottom]), "Sayfanın alt kenarı görünmedi. Sayfayı yeniden gezdirin.")
        XCTAssertEqual(ScanRules.coverageRetryText([.top, .bottom]), "Sayfanın üst ve alt kenarları görünmedi. Sayfayı yeniden gezdirin.")
        XCTAssertEqual(ScanRules.pageTakenIncompleteText(2, missing: [.bottom]),
                       "İkinci sayfa alındı; sayfanın alt kenarı görünmemiş olabilir.")
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
