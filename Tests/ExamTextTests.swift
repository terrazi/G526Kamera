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

    /// "Sınavı kapat" = deneme sınavı modunu kapat; "sonlandır / bitir" yalnız yapılan sınavı bitirir
    func testCloseModeIsDistinctFromEndExam() {
        let idle: Set<String> = ["start", "scan_done", "end", "undo", "close"]
        let closing = ["sınavı kapat", "sınav modunu kapat", "deneme sınav modunu kapat", "deneme sınavı modunu kapat",
                       "deneme sınavını kapat", "sınav modunu kapatalım", "normal moda geç", "normal moda geçiş yap",
                       "normal modda çalış", "normal moda dön", "normal modu aç", "normal moda geçelim"]
        expect(closing.map { ($0, "close") }, idle, "KAPAT")
        let ending = ["sınavı sonlandır", "sınavı bitir", "sınav tamamlandı", "deneme sınavı bitti", "sınavı sonlandırın",
                      "sınavı tamamla", "sınavı kes", "sınavı tamamlandı", "sınav sona erdi", "sınavı sona erdi", "sınav tamam",
                      "deneme sınavı tamam", "sınavı bitirelim", "sınavı kesin"]
        expect(ending.map { ($0, "end") }, idle, "SONLANDIR")
    }

    func testCloseWordsWorkInEveryExamStage() {
        let stages: [Set<String>] = [
            ["scan_done", "more", "undo", "end", "close"],
            ["continue", "pause", "end", "close"],
            ["vstop", "vdel", "vskip", "end", "close"],
            ["yes", "no", "end", "close"],
            ["cancel", "end", "close"],
        ]
        for valid in stages {
            expect([("sınavı kapat", "close"), ("sınav modunu kapat", "close"), ("normal moda geç", "close"),
                    ("sınavı sonlandır", "end"), ("sınavı bitir", "end"), ("sınavı tamamla", "end"), ("sınavı kes", "end"),
                    ("sınav sona erdi", "end")], valid, "AŞAMA \(valid.sorted())")
        }
    }

    /// "Sınavı sonlandır" türevleri: yapılan sınavı bitirir, modu kapatmaz
    func testEndExamDerivatives() {
        let phrases = ["sınavı sonlandır", "sınavı bitir", "sınavı tamamla", "sınavı kes", "sınav tamamlandı", "sınav sona erdi",
                       "sınav tamam", "deneme sınavını bitir", "deneme sınavını sonlandır", "sınavı keselim", "sınavı sonuçlandır"]
        let stages: [Set<String>] = [
            ["start", "scan_done", "end", "undo", "close"],
            ["scan_done", "more", "undo", "end", "close"],
            ["continue", "pause", "end", "close"],
            ["vstop", "vdel", "vskip", "end", "close"],
            ["yes", "no", "end", "close"],
            ["cancel", "end", "close"],
            ["continue", "new", "end", "close"],
        ]
        for valid in stages {
            expect(phrases.map { ($0, "end") }, valid, "SONLANDIR \(valid.sorted())")
        }
    }

    func testEndDerivativesDoNotTriggerOnUnrelatedOrNegatedSpeech() {
        let idle: Set<String> = ["start", "scan_done", "end", "undo", "close"]
        expect([("kes", nil), ("kesin", nil), ("bu kesin doğru", nil), ("sınavı sonlandırma", nil), ("sınavı bitirme", nil),
                ("sınav bitmedi", nil), ("sınavı tamamlama", nil), ("sınav henüz tamam değil", nil)], idle, "KARIŞMA")
    }

    func testExamTamamEndsExamButPlainTamamStillAnswersYes() {
        let ask: Set<String> = ["yes", "no", "end", "close"]
        expect([("tamam", "yes"), ("evet", "yes"), ("devam", "yes"), ("tamam devam", "yes"), ("sınav tamam", "end"),
                ("sınavı tamamla", "end")], ask, "TAMAM")
    }

    func testCloseIsNotMatchedWithoutTheCloseCommand() {
        // Eski komut kümelerinde (close yok) "sınavı kapat" eskisi gibi sınavı bitirir
        expect([("sınavı kapat", "end"), ("sınavı sonlandır", "end")], ["scan_done", "end"], "ESKİ")
        expect([("normal moda geç", nil)], ["scan_done", "end"], "ESKİ")
    }

    func testCloseWordsAreNotMistakenForOtherCommands() {
        let idle: Set<String> = ["start", "scan_done", "end", "undo", "close"]
        // Olumsuz ve ilgisiz cümleler kapatma sayılmaz
        expect([("sınavı kapatma", nil), ("sınavı kapatmayın", nil), ("normal moda geçme", nil), ("normal moda geçmeyelim", nil),
                ("normal çalışsın", nil), ("moda geç", nil), ("normal", nil), ("kapat", nil), ("bugün hava normal", nil),
                ("sınavı başlat", "start"), ("deneme sınavı modu", "start")], idle, "YANLIŞ")
        // Video aşamasında yalnız "kapat" kaydı durdurur; "sınavı kapat" modu kapatır
        let rec: Set<String> = ["vstop", "vdel", "vskip", "end", "close"]
        expect([("kapat", "vstop"), ("durdur", "vstop"), ("sınavı kapat", "close")], rec, "VİDEO")
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

    // MARK: Video aşaması

    func testVideoStageCommands() {
        let rec: Set<String> = ["vstop", "vdel", "vskip", "end"]
        let table: [String?: [String]] = [
            "vstop": ["durdur", "durdurun", "kapat", "kaydı durdur", "video bitti", "yeter", "stop"],
            "vdel": ["sil", "videoyu sil", "iptal", "vazgeçtim", "yanlış oldu sil"],
            "vskip": ["atla", "videoyu atla", "fotoğraf taramasına geç", "video istemiyorum"],
            "end": ["sınavı kapat", "sınav tamamlandı", "sınavı bitir", "deneme sınavı bitti"],
            nil: ["bugün hava güzel", "merhaba"],
        ]
        for (exp, list) in table {
            expect(list.map { ($0, exp) }, rec, "VIDEO")
        }
    }

    func testVideoContinueQuestion() {
        let ask: Set<String> = ["yes", "no", "end"]
        let table: [String?: [String]] = [
            "yes": ["evet", "devam", "evet devam et", "tamam", "olur", "videoya devam", "tabii"],
            "no": ["hayır", "hayır istemiyorum", "yok", "fotoğrafa geç", "fotoğraf taramasına başla", "olmaz", "gerek yok"],
            "end": ["sınavı kapat", "sınav tamamlandı"],
        ]
        for (exp, list) in table {
            expect(list.map { ($0, exp) }, ask, "DEVAM")
        }
    }

    func testVideoWordsDoNothingOutsideVideoStage() {
        let scan: Set<String> = ["scan_done", "undo", "end", "more"]
        XCTAssertNotEqual(ExamText.match("durdur", scan), "vstop")
        XCTAssertNotEqual(ExamText.match("atla", scan), "vskip")
        XCTAssertNotEqual(ExamText.match("sil", scan), "vdel")
        XCTAssertNotEqual(ExamText.match("evet", scan), "yes")
        XCTAssertNotEqual(ExamText.match("hayır", scan), "no")
    }
}
