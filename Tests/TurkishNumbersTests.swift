import XCTest
@testable import G526CameraDrive

final class TurkishNumbersTests: XCTestCase {
    func testCardinals() {
        XCTAssertEqual(TurkishNumbers.cardinal(0), "sıfır")
        XCTAssertEqual(TurkishNumbers.cardinal(1), "bir")
        XCTAssertEqual(TurkishNumbers.cardinal(10), "on")
        XCTAssertEqual(TurkishNumbers.cardinal(12), "on iki")
        XCTAssertEqual(TurkishNumbers.cardinal(37), "otuz yedi")
        XCTAssertEqual(TurkishNumbers.cardinal(100), "yüz")
        XCTAssertEqual(TurkishNumbers.cardinal(101), "yüz bir")
        XCTAssertEqual(TurkishNumbers.cardinal(240), "iki yüz kırk")
        XCTAssertEqual(TurkishNumbers.cardinal(1000), "bin")
        XCTAssertEqual(TurkishNumbers.cardinal(2026), "iki bin yirmi altı")
        XCTAssertEqual(TurkishNumbers.cardinal(-3), "-3")
        XCTAssertEqual(TurkishNumbers.cardinal(12000), "12000")
    }

    func testOrdinals() {
        XCTAssertEqual(TurkishNumbers.ordinal(1), "birinci")
        XCTAssertEqual(TurkishNumbers.ordinal(2), "ikinci")
        XCTAssertEqual(TurkishNumbers.ordinal(3), "üçüncü")
        XCTAssertEqual(TurkishNumbers.ordinal(4), "dördüncü")
        XCTAssertEqual(TurkishNumbers.ordinal(10), "onuncu")
        XCTAssertEqual(TurkishNumbers.ordinal(12), "on ikinci")
        XCTAssertEqual(TurkishNumbers.ordinal(20), "yirminci")
        XCTAssertEqual(TurkishNumbers.ordinal(37), "otuz yedinci")
        XCTAssertEqual(TurkishNumbers.ordinal(40), "kırkıncı")
        XCTAssertEqual(TurkishNumbers.ordinal(100), "yüzüncü")
        XCTAssertEqual(TurkishNumbers.ordinal(0), "sıfırıncı")
    }

    func testSpokenList() {
        XCTAssertEqual(TurkishNumbers.spokenList([]), "")
        XCTAssertEqual(TurkishNumbers.spokenList([15]), "15")
        XCTAssertEqual(TurkishNumbers.spokenList([15, 22]), "15 ve 22")
        XCTAssertEqual(TurkishNumbers.spokenList([3, 15, 22]), "3, 15 ve 22")
    }

    func testCapitalisedUsesTurkishLetters() {
        XCTAssertEqual(TurkishNumbers.capitalised("ikinci"), "İkinci")
        XCTAssertEqual(TurkishNumbers.capitalised("ıspanak"), "Ispanak")
        XCTAssertEqual(TurkishNumbers.capitalised("üçüncü"), "Üçüncü")
        XCTAssertEqual(TurkishNumbers.capitalised("on ikinci"), "On ikinci")
        XCTAssertEqual(TurkishNumbers.capitalised(""), "")
    }
}
