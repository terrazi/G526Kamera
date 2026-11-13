import XCTest
@testable import G526CameraDrive

final class TranscriptAccumulatorTests: XCTestCase {
    func testGrowingPartialReplacesCurrentText() {
        var t = TranscriptAccumulator()
        XCTAssertTrue(t.update(partial: "bir"))
        XCTAssertTrue(t.update(partial: "bir iki"))
        XCTAssertTrue(t.update(partial: "bir iki üç dört"))
        XCTAssertTrue(t.update(partial: "bir iki üç dört beş"))
        XCTAssertEqual(t.text, "bir iki üç dört beş")
    }

    func testSameOrEmptyPartialChangesNothing() {
        var t = TranscriptAccumulator()
        t.update(partial: "merhaba dünya")
        XCTAssertFalse(t.update(partial: "merhaba dünya"))
        XCTAssertFalse(t.update(partial: "   "))
        XCTAssertEqual(t.text, "merhaba dünya", "Boş kısmi metin mevcut metni silmez")
    }

    func testRestartedRecognizerKeepsEarlierText() {
        var t = TranscriptAccumulator()
        t.update(partial: "soru şöyle uzun bir cümle olarak başlıyor")
        t.update(partial: "devamı")   // tanıyıcı duraklamadan sonra baştan başladı
        XCTAssertEqual(t.text, "soru şöyle uzun bir cümle olarak başlıyor devamı")
    }

    func testRestartWithDifferentFirstWordIsDetected() {
        XCTAssertTrue(TranscriptAccumulator.looksLikeRestart(old: "bir iki üç dört beş", new: "altı yedi dört"))
        XCTAssertFalse(TranscriptAccumulator.looksLikeRestart(old: "bir iki üç dört beş", new: "bir iki üç dört beş altı"))
        XCTAssertFalse(TranscriptAccumulator.looksLikeRestart(old: "bir iki", new: "x"), "Kısa metinde yeniden başlama sayılmaz")
    }

    func testCommitCurrentKeepsTextAsSection() {
        var t = TranscriptAccumulator()
        t.update(partial: "ilk bölüm")
        t.commitCurrent()
        t.update(partial: "ikinci bölüm")
        XCTAssertEqual(t.text, "ilk bölüm ikinci bölüm")
    }

    func testClearEmptiesEverything() {
        var t = TranscriptAccumulator()
        t.update(partial: "bir şey")
        t.commitCurrent()
        t.update(partial: "başka şey")
        t.clear()
        XCTAssertTrue(t.isEmpty)
        XCTAssertEqual(t.text, "")
    }
}

final class TriggerDetectorTests: XCTestCase {
    func testTriggerAtEndTrimsTheWord() {
        let match = TriggerDetector.match(in: "Soru bir hangisi doğrudur Cevapla")
        XCTAssertEqual(match, TriggerMatch(word: "Cevapla", question: "Soru bir hangisi doğrudur"))
    }

    func testBothTriggerWordsWork() {
        XCTAssertEqual(TriggerDetector.match(in: "soru Gönder")?.word, "Gönder")
        XCTAssertEqual(TriggerDetector.match(in: "soru cevapla")?.word, "Cevapla")
    }

    func testCaseAndPunctuationAreIgnored() {
        XCTAssertNotNil(TriggerDetector.match(in: "soru CEVAPLA"))
        XCTAssertNotNil(TriggerDetector.match(in: "soru cevapla."))
        XCTAssertNotNil(TriggerDetector.match(in: "soru, \"gönder\"!"))
    }

    func testTurkishLettersAreFolded() {
        XCTAssertNotNil(TriggerDetector.match(in: "soru gonder"), "Tanıyıcı ö yerine o yazabilir")
        XCTAssertNotNil(TriggerDetector.match(in: "soru GÖNDER"))
    }

    func testOnlyTheLastWordTriggers() {
        XCTAssertNil(TriggerDetector.match(in: "gönder bana bir soru"))
        XCTAssertNil(TriggerDetector.match(in: "bu soru cevapla ile ilgili"))
    }

    func testSimilarWordsDoNotTrigger() {
        XCTAssertNil(TriggerDetector.match(in: "soru gönderi"))
        XCTAssertNil(TriggerDetector.match(in: "soru cevaplar"))
        XCTAssertNil(TriggerDetector.match(in: "soru cevaplama"))
    }

    func testBareTriggerGivesEmptyQuestion() {
        XCTAssertEqual(TriggerDetector.match(in: "Cevapla")?.question, "")
    }

    func testEmptyAndBlankTextNeverTrigger() {
        XCTAssertNil(TriggerDetector.match(in: ""))
        XCTAssertNil(TriggerDetector.match(in: "   "))
        XCTAssertNil(TriggerDetector.match(in: "..."))
    }

    func testTrailingPunctuationOnlyTokenIsSkipped() {
        XCTAssertEqual(TriggerDetector.match(in: "soru cevapla .")?.question, "soru")
    }

    func testCustomWords() {
        XCTAssertNotNil(TriggerDetector.match(in: "soru bitti", words: ["Bitti"]))
        XCTAssertNil(TriggerDetector.match(in: "soru cevapla", words: ["Bitti"]))
    }
}
