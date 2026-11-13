import XCTest
@testable import G526CameraDrive

/// Okunan soru numarası: kullanıcı soruları karışık okuyabilir, kayıt okunan numarayla yapılır
final class SpokenNumberTests: XCTestCase {
    func testDigitsAndWordsAfterTheWordSoru() {
        let cases: [(String, Int)] = [
            ("Soru 7 aşağıdakilerden hangisi doğrudur", 7),
            ("soru numarası 12 bir şirket", 12),
            ("Soru no 3 A seçeneği", 3),
            ("Soru: 15 Which of the following", 15),
            ("Evet soru 9", 9),
            ("SORU ON", 10),
            ("Soru yirmi beş", 25),
            ("Soru yüz yirmi üç", 123),
            ("Soru bir. A seçeneği Adana", 1),
            ("Soru dokuz", 9),
            ("soru altmış iki hangisi", 62)
        ]
        for (text, expected) in cases {
            XCTAssertEqual(SpokenNumber.extract(from: text), expected, text)
        }
    }

    func testNumberBeforeTheWordSoru() {
        let cases: [(String, Int)] = [
            ("7. soru aşağıdakilerden", 7),
            ("5'inci soru", 5),
            ("Birinci soru metni", 1),
            ("İkinci soru", 2),
            ("Üçüncü soru", 3),
            ("dördüncü soru", 4),
            ("Beşinci soru", 5),
            ("Altıncı soru", 6),
            ("yedinci soru", 7),
            ("On ikinci soru", 12),
            ("yirmi beşinci soru", 25),
            ("kırkıncı soru", 40),
            ("Tamam yedinci soru", 7),
            ("İkinci soru üç şık var", 2)
        ]
        for (text, expected) in cases {
            XCTAssertEqual(SpokenNumber.extract(from: text), expected, text)
        }
    }

    func testTextWithoutANumberGivesNil() {
        let texts = [
            "", "soru", "Bir soru", "Hangisi doğrudur", "Bu soru duraklatılmışken okundu", "Soru yok",
            "Aşağıdakilerden 3 tanesi soru değildir", "soru 0", "soru 1234", "Gitmeyecek soru",
            "Aşağıdakilerden hangisi bir kuruluşun amacı değildir soru"
        ]
        for text in texts {
            XCTAssertNil(SpokenNumber.extract(from: text), text)
        }
    }

    func testNumbersDeepInsideTheQuestionAreIgnored() {
        XCTAssertNil(SpokenNumber.extract(from: "Aşağıdaki ifadelerden hangisi doğrudur ve bu soru 5 şıklıdır"))
    }
}

@MainActor
final class SpokenNumberSessionTests: XCTestCase {
    private func noNumberReply(_ option: String = "Denizli", _ text: String = "Örgütsel Davranış") -> GeminiReply {
        return GeminiReply(number: nil, option: option, text: text, spoken: "\(option), \(text)", model: "fake")
    }

    func testQuestionsReadOutOfOrderAreSavedWithTheNumberThatWasRead() async {
        let h = SessionHarness()
        // Gemini yanlışlıkla sıradaki numarayı söylese bile okunan numara geçerli
        h.answering.results = [.success(FakeAnswering.reply(1)), .success(FakeAnswering.reply(2, option: "Bursa", text: "Pazarlama"))]
        _ = await h.startListening()
        h.ask("Soru 7 aşağıdakilerden hangisi doğrudur")
        var done = await waitUntil { h.vm.answers.count == 1 && h.vm.phase == .listening }
        XCTAssertTrue(done)
        h.ask("Soru 3 bir şirketin amacı")
        done = await waitUntil { h.vm.answers.count == 2 && h.vm.phase == .listening }
        XCTAssertTrue(done)

        XCTAssertEqual(h.answering.calls.map { $0.expectedNumber }, [7, 3])
        XCTAssertEqual(h.vm.answers.map { $0.number }, [7, 3])
        XCTAssertEqual(Array(h.speaker.spoken.suffix(2)), ["Soru 7, Denizli, Örgütsel Davranış", "Soru 3, Bursa, Pazarlama"])
        XCTAssertEqual(h.speaker.calls.compactMap { $0.saveAs?.lastPathComponent }, ["soru_7", "soru_3"])
        XCTAssertEqual(h.vm.questions.map { $0.number }, [7, 3])
        XCTAssertTrue(h.vm.questions.allSatisfy { $0.numberSource == .spoken })
        let files = h.vm.deps.library.answerFiles(in: h.vm.sessionFolder!)
        XCTAssertEqual(files.map { $0.lastPathComponent }, ["soru_3.m4a", "soru_7.m4a"], "Tekrar, numara sırasıyla yapılır")
    }

    func testSpokenWordNumberIsUsedToo() async {
        let h = SessionHarness()
        h.answering.results = [.success(FakeAnswering.reply(1))]
        _ = await h.startListening()
        h.ask("On ikinci soru hangisi doğrudur")
        let done = await waitUntil { h.vm.answers.count == 1 && h.vm.phase == .listening }
        XCTAssertTrue(done)
        XCTAssertEqual(h.vm.answers.map { $0.number }, [12])
        XCTAssertEqual(h.speaker.calls.last?.saveAs?.lastPathComponent, "soru_12")
    }

    func testNextUnnumberedQuestionContinuesAfterTheLastReadNumber() async {
        let h = SessionHarness()
        h.answering.results = [.success(FakeAnswering.reply(1)), .success(noNumberReply())]
        _ = await h.startListening()
        h.ask("Soru 7 hangisi doğrudur")
        var done = await waitUntil { h.vm.answers.count == 1 && h.vm.phase == .listening }
        XCTAssertTrue(done)
        h.ask("Hangisi yanlıştır")
        done = await waitUntil { h.vm.answers.count == 2 && h.vm.phase == .listening }
        XCTAssertTrue(done)
        XCTAssertEqual(h.answering.calls.map { $0.expectedNumber }, [7, 8])
        XCTAssertEqual(h.vm.answers.map { $0.number }, [7, 8])
        XCTAssertEqual(h.speaker.spoken.last, "Soru 8, Denizli, Örgütsel Davranış", "Numara okunmasa da söylenen cümle numarayı taşır")
        XCTAssertEqual(h.vm.questions.last?.numberSource, .sequence)
    }

    func testNumberHeardByGeminiIsUsedWhenTheTextHasNone() async {
        let h = SessionHarness()
        h.answering.results = [.success(FakeAnswering.reply(9))]
        _ = await h.startListening()
        h.ask("Hangisi doğrudur")
        let done = await waitUntil { h.vm.answers.count == 1 && h.vm.phase == .listening }
        XCTAssertTrue(done)
        XCTAssertEqual(h.vm.answers.map { $0.number }, [9])
        XCTAssertEqual(h.vm.questions.last?.numberSource, .heard)
        XCTAssertEqual(h.vm.nextNumber, 10)
    }

    func testReadingTheSameNumberAgainReplacesTheAnswer() async {
        let h = SessionHarness()
        h.answering.results = [.success(FakeAnswering.reply(7)), .success(FakeAnswering.reply(7, option: "Bursa", text: "Pazarlama"))]
        _ = await h.startListening()
        h.ask("Soru 7 hangisi doğrudur")
        _ = await waitUntil { h.vm.answers.count == 1 && h.vm.phase == .listening }
        h.ask("Soru 7 yeniden okuyorum")
        let done = await waitUntil { h.answering.calls.count == 2 && h.vm.phase == .listening }
        XCTAssertTrue(done)
        XCTAssertEqual(h.vm.answers.count, 1)
        XCTAssertEqual(h.vm.answers.first?.option, "Bursa")
        let files = h.vm.deps.library.answerFiles(in: h.vm.sessionFolder!)
        XCTAssertEqual(files.map { $0.lastPathComponent }, ["soru_7.m4a"], "Çift dosya kalmaz")
    }

    func testRequestTellsGeminiTheNumberMayBeOutOfOrder() {
        XCTAssertTrue(GeminiAnswerService.systemPrompt.contains("sırayla okumak zorunda değildir"))
        let text = GeminiAnswerService.userText(question: "x", expectedNumber: 7)
        XCTAssertTrue(text.contains("Soru 7"))
        XCTAssertTrue(text.contains("okunan numaraya uy"))
    }
}
