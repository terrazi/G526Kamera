import XCTest
@testable import G526CameraDrive

final class AnswerParserTests: XCTestCase {
    func testSpecificationExample() {
        let p = AnswerParser.parse("Soru 1, Denizli, Örgütsel Davranış")
        XCTAssertEqual(p.number, 1)
        XCTAssertEqual(p.option, "Denizli")
        XCTAssertEqual(p.text, "Örgütsel Davranış")
        XCTAssertEqual(p.spoken, "Soru 1, Denizli, Örgütsel Davranış")
    }

    func testMarkdownAndDashSeparatorsAreNormalized() {
        let p = AnswerParser.parse("**Soru 12 - Ceyhan - Marketing mix**")
        XCTAssertEqual(p.number, 12)
        XCTAssertEqual(p.option, "Ceyhan")
        XCTAssertEqual(p.text, "Marketing mix")
        XCTAssertEqual(p.spoken, "Soru 12, Ceyhan, Marketing mix")
    }

    func testBracketedFormatFromThePrompt() {
        let p = AnswerParser.parse("[Soru 3] - [Bursa] - [Rekabet stratejisi]")
        XCTAssertEqual(p.number, 3)
        XCTAssertEqual(p.option, "Bursa")
        XCTAssertEqual(p.text, "Rekabet stratejisi")
    }

    func testOptionOnly() {
        let p = AnswerParser.parse("Soru 3: Adana")
        XCTAssertEqual(p.number, 3)
        XCTAssertEqual(p.option, "Adana")
        XCTAssertEqual(p.text, "")
        XCTAssertEqual(p.spoken, "Soru 3, Adana")
    }

    func testOnlyTheFirstLineIsUsed() {
        let p = AnswerParser.parse("\n\nSoru 2, Erzurum, Motivasyon\nÇünkü açıklama burada.")
        XCTAssertEqual(p.number, 2)
        XCTAssertEqual(p.spoken, "Soru 2, Erzurum, Motivasyon")
    }

    func testHyphenInsideTheAnswerTextIsKept() {
        let p = AnswerParser.parse("Soru 4, Denizli, Çok-boyutlu analiz")
        XCTAssertEqual(p.option, "Denizli")
        XCTAssertEqual(p.text, "Çok-boyutlu analiz")
    }

    func testMissingNumberKeepsOptionAndText() {
        let p = AnswerParser.parse("Erzurum, Kalite yönetimi")
        XCTAssertNil(p.number)
        XCTAssertEqual(p.option, "Erzurum")
        XCTAssertEqual(p.text, "Kalite yönetimi")
        XCTAssertEqual(p.spoken, "Erzurum, Kalite yönetimi")
    }

    func testNumberWithDotAndNoWord() {
        let p = AnswerParser.parse("7. Adana, Pazarlama")
        XCTAssertEqual(p.number, 7)
        XCTAssertEqual(p.option, "Adana")
        XCTAssertEqual(p.text, "Pazarlama")
    }

    func testUnparseableLineIsSpokenAsIs() {
        let p = AnswerParser.parse("Emin değilim")
        XCTAssertNil(p.number)
        XCTAssertEqual(p.spoken, "Emin değilim")
    }

    func testEmptyInput() {
        let p = AnswerParser.parse("  \n ")
        XCTAssertNil(p.number)
        XCTAssertEqual(p.spoken, "")
    }
}
