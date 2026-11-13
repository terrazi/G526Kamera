import XCTest
@testable import G526CameraDrive

/// OCR satırlarından soru bulma ve kırpma sınırları (üst: numaradan 2 satır yukarı; alt: son şıktan 4 satır aşağı)
final class QuestionLayoutTests: XCTestCase {
    private func line(_ text: String, y: Double, x: Double = 0.1, w: Double = 0.8, h: Double = 0.02, conf: Double = 0.9) -> OCRLine {
        return OCRFixtures.line(text, y: y, x: x, w: w, h: h, conf: conf)
    }

    private func question(_ n: Int, y0: Double, x: Double = 0.1, w: Double = 0.8, options: String = "ABCDE") -> [OCRLine] {
        return OCRFixtures.question(n, y0: y0, x: x, w: w, options: options)
    }

    func testQuestionNumberParsing() {
        XCTAssertEqual(QuestionLayout.questionNumber(in: "12. Bir sayı"), 12)
        XCTAssertEqual(QuestionLayout.questionNumber(in: "12) Bir sayı"), 12)
        XCTAssertEqual(QuestionLayout.questionNumber(in: "(12) Bir sayı"), 12)
        XCTAssertEqual(QuestionLayout.questionNumber(in: "  7.Soru"), 7)
        XCTAssertNil(QuestionLayout.questionNumber(in: "12.5 kilogram"))
        XCTAssertNil(QuestionLayout.questionNumber(in: "3 kilogram"))
        XCTAssertNil(QuestionLayout.questionNumber(in: "0. Soru"))
        XCTAssertNil(QuestionLayout.questionNumber(in: "1234. Soru"))
        XCTAssertNil(QuestionLayout.questionNumber(in: "Soru 12."))
    }

    func testOptionLetters() {
        XCTAssertEqual(QuestionLayout.optionLetters(in: "A) 5  B) 6  C) 7"), ["A", "B", "C"])
        XCTAssertEqual(QuestionLayout.optionLetters(in: "B. kırmızı"), ["B"])
        XCTAssertEqual(QuestionLayout.optionLetters(in: "(D) elma"), ["D"])
        XCTAssertEqual(QuestionLayout.optionLetters(in: "bu bir cümledir"), [])
        XCTAssertEqual(QuestionLayout.optionLetters(in: "Ahmet gitti"), [])
    }

    func testTwoQuestionsOnOnePage() {
        let lines = question(12, y0: 0.20) + question(13, y0: 0.45)
        let layout = QuestionLayout.analyze(lines: lines, total: 40, optionCount: 5)
        XCTAssertEqual(layout.blocks.map { $0.number }, [12, 13])
        XCTAssertEqual(layout.columnCount, 1)
        let a = layout.blocks[0], b = layout.blocks[1]
        XCTAssertTrue(a.complete)
        XCTAssertTrue(b.complete)
        XCTAssertEqual(a.cropTop, 0.20 - 2 * 0.03, accuracy: 0.001, "numaradan 2 satır yukarı")
        // 12. sorunun altı normalde E + 4 satırdır (0,52) ama 13. sorunun numara satırında biter
        XCTAssertEqual(a.cropBottom, 0.45 - 0.2 * 0.03, accuracy: 0.001)
        XCTAssertEqual(b.cropBottom, (0.45 + 0.18 + 0.02) + 4 * 0.03, accuracy: 0.001, "son şıktan 4 satır aşağı")
        XCTAssertFalse(a.opensBelow)
        XCTAssertFalse(b.opensBelow)
        XCTAssertTrue(a.insideFrame && b.insideFrame)
        XCTAssertEqual(a.pitch, 0.03, accuracy: 0.002)
    }

    func testQuestionBelowWithoutLastOptionOpensToNextPage() {
        let lines = question(12, y0: 0.70, options: "ABCD")
        let layout = QuestionLayout.analyze(lines: lines, total: 40, optionCount: 5)
        XCTAssertEqual(layout.blocks.count, 1)
        XCTAssertFalse(layout.blocks[0].complete)
        XCTAssertTrue(layout.blocks[0].opensBelow, "son şık yok ve yazı sayfanın altına dayanıyor")
    }

    func testMissingOptionInTheMiddleOfPageIsIncompleteNotOpen() {
        let lines = question(5, y0: 0.20, options: "ABC") + question(6, y0: 0.50)
        let layout = QuestionLayout.analyze(lines: lines, total: 40, optionCount: 5)
        XCTAssertFalse(layout.blocks[0].complete)
        XCTAssertFalse(layout.blocks[0].opensBelow, "altında başka soru var")
    }

    func testLeadingContinuationBlockHasNoNumber() throws {
        let head = [line("C) devam eden şık", y: 0.05), line("D) başka şık", y: 0.08), line("E) son şık", y: 0.11)]
        let layout = QuestionLayout.analyze(lines: head + question(14, y0: 0.25), total: 40, optionCount: 5)
        XCTAssertEqual(layout.blocks.map { $0.number }, [14])
        let leading = try XCTUnwrap(layout.leading)
        XCTAssertEqual(leading.number, 0)
        XCTAssertTrue(leading.complete, "devam parçası son şığı içeriyor")
        XCTAssertEqual(Set(leading.options.keys), Set<Character>(["C", "D", "E"]))
    }

    func testTwoColumnPage() {
        let left = question(1, y0: 0.20, x: 0.05, w: 0.40)
        let right = question(2, y0: 0.20, x: 0.55, w: 0.40)
        let layout = QuestionLayout.analyze(lines: left + right, total: 40, optionCount: 5)
        XCTAssertEqual(layout.columnCount, 2)
        XCTAssertEqual(layout.blocks.map { $0.number }.sorted(), [1, 2])
        for block in layout.blocks {
            XCTAssertTrue(block.complete, "soru \(block.number) kendi sütunundaki şıkları görmeli")
            XCTAssertEqual(block.lines.count, 7)
        }
        let one = layout.blocks.first(where: { $0.number == 1 })
        XCTAssertLessThan(one?.cropRight ?? 1, 0.5, "sol sütunun kırpması sağ sütuna taşmaz")
    }

    func testNumbersBeyondTotalAreIgnored() {
        let layout = QuestionLayout.analyze(lines: question(25, y0: 0.2), total: 20, optionCount: 5)
        XCTAssertTrue(layout.blocks.isEmpty)
        let open = QuestionLayout.analyze(lines: question(25, y0: 0.2), total: 0, optionCount: 5)
        XCTAssertEqual(open.blocks.map { $0.number }, [25], "toplam girilmediyse sınır yok")
    }

    func testFourOptionQuestionsAreCompleteWithD() {
        let layout = QuestionLayout.analyze(lines: question(3, y0: 0.2, options: "ABCD"), total: 10, optionCount: 4)
        XCTAssertTrue(layout.blocks[0].complete)
    }

    func testBlockCutByTheFrameEdge() {
        // E şıkkı kadrajın altına değiyor
        let layout = QuestionLayout.analyze(lines: question(9, y0: 0.80), total: 10, optionCount: 5)
        let b = layout.blocks[0]
        XCTAssertTrue(b.contentCutBottom)
        XCTAssertTrue(b.cutBottom, "alt pay kadraj dışına taşıyor")
        let r = b.cropRect
        XCTAssertLessThanOrEqual(r.maxY, 1.0)
        XCTAssertGreaterThan(r.height, 0)
    }

    func testLinePitchFallsBackToHeight() {
        XCTAssertEqual(QuestionLayout.linePitch([line("x", y: 0.5, h: 0.02)]), 0.03, accuracy: 0.0001)
        XCTAssertEqual(QuestionLayout.linePitch([]), 0.02, accuracy: 0.0001)
    }
}
