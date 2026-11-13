import XCTest
@testable import G526CameraDrive

final class QuestionTextTests: XCTestCase {
    private func text(_ n: Int = 12, options: String = "ABCDE", extra: [OCRLine] = [], conf: Double = 0.95) -> QuestionText {
        return QuestionText.from(block: OCRFixtures.block(n, y0: 0.2, options: options, extra: extra, conf: conf))
    }

    func testCleanQuestionIsReliable() {
        let q = text()
        XCTAssertTrue(q.text.hasPrefix("12. Soru metni burada"))
        XCTAssertTrue(q.text.contains("E) seçenek 4"))
        XCTAssertEqual(q.letters, Set("ABCDE"))
        XCTAssertTrue(q.isReliable(optionCount: 5))
        XCTAssertTrue(q.isReliable(optionCount: 4))
    }

    func testMissingOptionOrLowConfidenceIsNotReliable() {
        XCTAssertFalse(text(options: "ABCD").isReliable(optionCount: 5), "E şıkkı okunmadı")
        XCTAssertTrue(text(options: "ABCD").isReliable(optionCount: 4), "4 şıklı sınavda yeter")
        XCTAssertFalse(text(conf: 0.6).isReliable(optionCount: 5), "ortalama güven düşük")
    }

    func testOneBadLineMakesTheQuestionUnreliable() {
        var lines = OCRFixtures.question(12, y0: 0.2)
        lines[2].confidence = 0.3
        let block = QuestionLayout.analyze(lines: lines, total: 40, optionCount: 5).blocks[0]
        XCTAssertFalse(QuestionText.from(block: block).isReliable(optionCount: 5))
    }

    func testBigGapBetweenLinesSuggestsAFigure() {
        // numara satırından sonra büyük boşluk (şekil yeri), sonra şıklar
        var lines = [OCRFixtures.line("12. Aşağıdaki şekle göre soruyu cevaplayın", y: 0.2), OCRFixtures.line("devam eden ikinci satır", y: 0.23)]
        for (i, c) in "ABCDE".enumerated() { lines.append(OCRFixtures.line("\(c)) seçenek \(i)", y: 0.5 + 0.03 * Double(i))) }
        let block = QuestionLayout.analyze(lines: lines, total: 40, optionCount: 5).blocks[0]
        let q = QuestionText.from(block: block)
        XCTAssertTrue(q.hasGap)
        XCTAssertFalse(q.isReliable(optionCount: 5))
    }

    func testMathTracesMakeTheQuestionUnreliable() {
        XCTAssertTrue(QuestionText.looksMathy("√16 + 3"))
        XCTAssertTrue(QuestionText.looksMathy("x^2 - 4 = 0"))
        XCTAssertTrue(QuestionText.looksMathy("3/4 oranında"))
        XCTAssertTrue(QuestionText.looksMathy("log 100 değeri"))
        XCTAssertTrue(QuestionText.looksMathy("10²"))
        XCTAssertFalse(QuestionText.looksMathy("Aşağıdakilerden hangisi Türkiye'nin başkentidir?"))
        XCTAssertFalse(QuestionText.looksMathy("Ali 12 elma, Veli 15 elma aldı. Toplam kaç elma vardır?"))
        let q = text(extra: [OCRFixtures.line("√9 kaçtır", y: 0.1)])
        XCTAssertFalse(q.isReliable(optionCount: 5))
    }

    func testTooShortTextIsNotReliable() {
        var q = text()
        q.text = "12. Soru"
        XCTAssertFalse(q.isReliable(optionCount: 5))
    }

    func testPartsAreMergedInOrder() {
        let head = QuestionText(text: "9. Soru köküdür\nA) bir\nB) iki", letters: ["A", "B"], meanConfidence: 0.95, minConfidence: 0.9, hasGap: false, mathy: false)
        let tail = QuestionText(text: "C) üç\nD) dört\nE) beş", letters: ["C", "D", "E"], meanConfidence: 0.9, minConfidence: 0.8, hasGap: false, mathy: false)
        let merged = QuestionText.merged([head, tail])
        XCTAssertEqual(merged.text, head.text + "\n" + tail.text)
        XCTAssertEqual(merged.letters, Set("ABCDE"))
        XCTAssertEqual(merged.minConfidence, 0.8)
        XCTAssertEqual(merged.meanConfidence, 0.925, accuracy: 0.0001)
        XCTAssertTrue(merged.isReliable(optionCount: 5))
        XCTAssertFalse(head.isReliable(optionCount: 5), "tek başına üst parçada son şıklar yok")
    }

    // MARK: Defterde metin

    func testLedgerKeepsTheTextOfAnAcceptedQuestion() {
        var ledger = ScanLedger(total: 5)
        ledger.accept(number: 2, pages: [URL(fileURLWithPath: "/tmp/a.jpg")], continuing: false, text: text(2))
        XCTAssertNotNil(ledger.texts[2])
        ledger.accept(number: 3, pages: [URL(fileURLWithPath: "/tmp/b.jpg")], continuing: false)
        XCTAssertNil(ledger.texts[3], "metin verilmediyse yok: PDF gider")
    }

    func testLedgerJoinsHeadAndTailTexts() {
        let head = QuestionText(text: "9. A", letters: ["A", "B"], meanConfidence: 1, minConfidence: 1, hasGap: false, mathy: false)
        let tail = QuestionText(text: "C", letters: ["C", "D", "E"], meanConfidence: 1, minConfidence: 1, hasGap: false, mathy: false)
        var ledger = ScanLedger(total: 20)
        ledger.startOpen(number: 9, pages: [URL(fileURLWithPath: "/tmp/h.jpg")], text: head)
        ledger.accept(number: 9, pages: [URL(fileURLWithPath: "/tmp/t.jpg")], continuing: true, text: tail)
        XCTAssertEqual(ledger.texts[9]?.text, "9. A\nC")
        // sonu önce, başı sonra çekilen soru: yine üst + alt sırasıyla
        var reversed = ScanLedger(total: 20)
        reversed.stashTail(number: 9, pages: [URL(fileURLWithPath: "/tmp/t.jpg")], text: tail)
        reversed.accept(number: 9, pages: [URL(fileURLWithPath: "/tmp/h.jpg")], continuing: true, text: head)
        XCTAssertEqual(reversed.texts[9]?.text, "9. A\nC")
        // parçalardan birinin metni yoksa birleşik metin de yoktur
        var partial = ScanLedger(total: 20)
        partial.startOpen(number: 9, pages: [URL(fileURLWithPath: "/tmp/h.jpg")], text: nil)
        partial.accept(number: 9, pages: [URL(fileURLWithPath: "/tmp/t.jpg")], continuing: true, text: tail)
        XCTAssertNil(partial.texts[9])
    }

    // MARK: Gemini isteği

    func testTextDocBecomesATextPartWithoutAPDF() throws {
        let q = text(12)
        let textDoc = AnswerDoc(name: "S12", numbers: [12], data: Data(q.text.utf8), text: q.text)
        let pdfDoc = AnswerDoc(name: "S13.pdf", numbers: [13], data: Data(repeating: 0x25, count: 10))
        let data = try AnswerService.requestBody(docs: [textDoc, pdfDoc], thinking: nil)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let parts = try XCTUnwrap(((json["contents"] as? [[String: Any]])?.first)?["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 4, "metin: tek parça; PDF: etiket + veri; sonda istem")
        let first = try XCTUnwrap(parts[0]["text"] as? String)
        XCTAssertTrue(first.contains("telefonun okuduğu metin"))
        XCTAssertTrue(first.contains("12. Soru metni burada"))
        XCTAssertNil(parts[0]["inlineData"])
        XCTAssertNotNil(parts[2]["inlineData"])
        let last = try XCTUnwrap(parts[3]["text"] as? String)
        XCTAssertTrue(last.contains("12, 13"))
    }

    func testTextDocsDoNotCountTowardsThePDFLimit() {
        var docs: [AnswerDoc] = []
        for n in 1...6 { docs.append(AnswerDoc(name: "S\(n)", numbers: [n], data: Data("metin".utf8), text: "metin")) }
        for n in 7...8 { docs.append(AnswerDoc(name: "S\(n).pdf", numbers: [n], data: Data(repeating: 1, count: 10))) }
        XCTAssertEqual(AnswerService.chunk(docs, budget: 1000, maxDocs: 2).map { $0.count }, [8], "iki PDF sınırı aşılmadı: tek istek")
        let moreFiles = docs + [AnswerDoc(name: "S9.pdf", numbers: [9], data: Data(repeating: 1, count: 10))]
        XCTAssertEqual(AnswerService.chunk(moreFiles, budget: 1000, maxDocs: 2).map { $0.count }, [8, 1], "üçüncü PDF yeni isteğe")
    }

    func testSystemPromptMentionsPhoneReadText() {
        XCTAssertTrue(AnswerService.system.contains("telefonun okuduğu metin"))
    }
}
