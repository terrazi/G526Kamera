import XCTest
@testable import G526CameraDrive

/// Deneme sınavı: Türkçe sayılar ve serbest söylenen komutların anlam olarak eşleştirilmesi (Windows sürümündeki test_exam_text.py'nin karşılığı)
final class ExamTextTests: XCTestCase {
    private let scan: Set<String> = ["scan_done", "undo", "end", "more"]
    private let ans: Set<String> = ["pause", "continue", "end"]
    private let send: Set<String> = ["cancel", "more"]
    private let idle: Set<String> = ["start", "scan_done", "end", "undo"]
    private let rev: Set<String> = ["end", "more", "pause"]

    private func expect(_ cases: [(String, String?)], _ valid: Set<String>, _ ctx: String, file: StaticString = #filePath, line: UInt = #line) {
        for (t, exp) in cases {
            XCTAssertEqual(ExamText.match(t, valid), exp, "\(ctx): \(t)", file: file, line: line)
        }
    }

    func testScanContext() {
        let table: [String?: [String]] = [
            "scan_done": ["tarama bitti", "taramayı bitirdim", "tarama işi tamam", "hepsini taradım gönder", "artık gönder", "bitti",
                          "tamamlandı", "tüm sayfaları taradım", "sorular bitti", "drive'a gönder", "hepsini taradım", "işim bitti",
                          "yükle", "sayfalar tamam"],
            nil: ["tamam", "tarama bitmedi", "daha bitmedi", "bugün hava güzel", "evet", "bir daha"],
            "undo": ["son sayfayı sil", "yanlış taradım", "bulanık çıktı sil", "geri al", "bu sayfayı kaldır", "son taramayı iptal et"],
            "end": ["sınav tamamlandı", "sınavı bitir", "deneme sınavı bitti", "sınavı kapat", "sınav yeter"],
            "more": ["taramaya devam", "yeniden tara", "eksik sayfaları tara", "bir sayfa daha tarayalım", "okunamayanları tara",
                     "taramaya geri dön"],
        ]
        for (exp, list) in table {
            expect(list.map { ($0, exp) }, scan, "SCAN")
        }
    }

    func testAnswerContext() {
        expect([("devam", "continue"), ("duraklat", "pause"), ("dur", "pause"), ("bir dakika", "pause"), ("tamam devam et", "continue"),
                ("bitir", "end"), ("sınav tamamlandı", "end"), ("bu kadar", "end"), ("sus", "pause"), ("yeter", "pause"),
                ("evet", "continue"), ("durum nedir", nil), ("sonraki", "continue"), ("kaldığın yerden devam", "continue"),
                ("hadi", "continue")], ans, "ANS")
    }

    func testSendWindow() {
        expect([("iptal", "cancel"), ("vazgeç", "cancel"), ("hayır", "cancel"), ("daha bitmedi", "cancel"), ("dur", "cancel"),
                ("taramaya devam", "more"), ("tamam", nil), ("gönderme", "cancel"), ("yanlış", "cancel")], send, "SEND")
    }

    func testIdleAndReview() {
        expect([("deneme sınavı modu", "start"), ("sınav moduna geç", "start"), ("sınava başlayalım", "start"),
                ("deneme yapalım", "start"), ("deneme modu", "start"), ("test çözelim", "start"), ("sınavı başlat", "start"),
                ("sınav tamamlandı", "end"), ("merhaba", nil), ("okey", nil), ("deneme", nil), ("bugün sınav var", nil)], idle, "IDLE")
        expect([("bitti", "end"), ("sınav tamamlandı", "end"), ("eksik sayfaları tara", "more"), ("bu kadar", "end"),
                ("çıkış", "end"), ("otuz yedi", nil), ("37 neden", nil)], rev, "REV")
    }

    func testNegationAndEmpty() {
        XCTAssertNil(ExamText.match("", scan))
        XCTAssertNil(ExamText.match("   ", scan))
        XCTAssertNil(ExamText.match("tarama bitmedi", scan))
        XCTAssertTrue(ExamText.negated(ExamText.tokens("henüz bitmedi")))
    }

    func testFoldAndTokens() {
        XCTAssertEqual(ExamText.fold("ÇIĞIR İŞÜ"), "cigir isu")
        XCTAssertEqual(ExamText.tokens("Drive'a gönder!"), ["drive", "a", "gonder"])
        XCTAssertEqual(ExamText.tokens("37. soru"), ["37", "soru"])
    }

    func testCardinal() {
        let got = [0, 7, 10, 21, 100, 137, 1000, 1999].map { ExamText.cardinal($0) }
        XCTAssertEqual(got, ["sıfır", "yedi", "on", "yirmi bir", "yüz", "yüz otuz yedi", "bin", "bin dokuz yüz doksan dokuz"])
        XCTAssertEqual(ExamText.cardinal(20000), "20000")
    }

    func testOrdinal() {
        let got = [1, 2, 3, 10, 11, 12, 20, 21, 30, 40, 100, 101].map { ExamText.ordinal($0) }
        XCTAssertEqual(got, ["birinci", "ikinci", "üçüncü", "onuncu", "on birinci", "on ikinci", "yirminci", "yirmi birinci",
                             "otuzuncu", "kırkıncı", "yüzüncü", "yüz birinci"])
    }

    func testParseNumbers() {
        let table: [(String, [Int])] = [
            ("37", [37]), ("otuz yedinci soru", [37]), ("on ikinci", [12]), ("soru 5 ve 9", [5, 9]), ("beş, dokuz ve on bir", [5, 9, 11]),
            ("ilk soru", [1]), ("yüz yirmi üçüncü soru", [123]), ("bir daha söyle", []), ("birinci soru neden", [1]),
            ("37 neden", [37]), ("üç dört", [3, 4]), ("yirmi beş", [25]),
        ]
        for (text, exp) in table {
            XCTAssertEqual(ExamText.parseNumbers(text), exp, text)
        }
    }

    func testParseNumbersRoundTrip() {
        for n in [1, 5, 9, 10, 11, 19, 20, 21, 37, 50, 99, 100, 101, 120, 123, 250, 999] {
            XCTAssertEqual(ExamText.parseNumbers(ExamText.ordinal(n) + " soru"), [n], "ordinal \(n)")
            XCTAssertEqual(ExamText.parseNumbers("soru " + ExamText.cardinal(n)), [n], "cardinal \(n)")
        }
    }

    func testWantsAllAndRange() {
        XCTAssertTrue(ExamText.wantsAll("tüm cevapları oku"))
        XCTAssertTrue(ExamText.wantsAll("hepsini baştan tekrarla"))
        XCTAssertFalse(ExamText.wantsAll("37. soruyu oku"))
        XCTAssertFalse(ExamText.wantsAll("hepsini baştan", needSubject: true))
        XCTAssertEqual(ExamText.numberRange("5'ten 8'e kadar"), [5, 6, 7, 8])
        XCTAssertEqual(ExamText.numberRange("5 ile 7 arası"), [5, 6, 7])
        XCTAssertEqual(ExamText.numberRange("5 ve 9"), [])
    }
}
