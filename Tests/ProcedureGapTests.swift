import XCTest
@testable import G526CameraDrive

/// Sınav prosedürü incelemesinde bulunan boşluklar (bkz. docs/ISLEM_ZINCIRLERI.md): düşük ses seviyesi, aynı numaranın sessizce ezilmesi,
/// test sonunda cevapsız soruların söylenmemesi, numara beklenirken "N. sorunun cevabını tekrarla" denememesi.
@MainActor
final class ProcedureGapTests: XCTestCase {
    private typealias T = SessionViewModel.Timing

    private func warning(_ h: SessionHarness, _ id: String) -> String? {
        return h.vm.warnings.first(where: { $0.id == id })?.text
    }

    /// Bir soruyu okuyup cevaplatır; cevap gelip dinleme dönene kadar bekler
    private func answer(_ h: SessionHarness, number: Int, file: StaticString = #filePath, line: UInt = #line) async {
        let calls = h.answering.calls.count
        h.answering.results.append(.success(FakeAnswering.reply(number)))
        h.ask("Soru \(number). A seçeneği Adana")
        let done = await waitUntil(45) { h.answering.calls.count == calls + 1 && h.vm.phase == .listening }
        XCTAssertTrue(done, "\(number). soru cevaplanmadı: \(h.speaker.spoken)", file: file, line: line)
    }

    // MARK: Boşluk 1: telefonun ses seviyesi

    func testLowVolumeAtStartWarnsButDoesNotBlockTheSession() async {
        let h = SessionHarness()
        h.system.current.outputVolume = 0.05
        let listening = await h.startListening()
        XCTAssertTrue(listening, "Düşük ses oturumu engellemez")
        XCTAssertEqual(warning(h, "seviye"), Say.lowVolume(5))
        XCTAssertEqual(h.vm.checkup.first(where: { $0.id == "seviye" })?.ok, false, "Donanım kontrolünde de görünür")
    }

    func testLowVolumeWarningClearsWhenTheVolumeRises() async {
        let h = SessionHarness()
        h.settings.instantDetection = true
        h.system.current.outputVolume = 0.05
        _ = await h.startListening()
        XCTAssertNotNil(warning(h, "seviye"))
        h.system.current.outputVolume = 0.5
        h.scheduler.advance(by: T.sentinelTick * Double(T.systemEveryTicks) + 1)
        XCTAssertNil(warning(h, "seviye"), "Ses açılınca bir dakika içinde uyarı kalkar")
    }

    func testLowVolumeAppearsDuringTheSessionToo() async {
        let h = SessionHarness()
        h.settings.instantDetection = true
        h.system.current.outputVolume = 0.5
        _ = await h.startListening()
        XCTAssertNil(warning(h, "seviye"))
        h.system.current.outputVolume = 0.0
        h.scheduler.advance(by: T.sentinelTick * Double(T.systemEveryTicks) + 1)
        XCTAssertEqual(warning(h, "seviye"), Say.lowVolume(0), "Oturum sırasında kısılan ses de fark edilir")
    }

    func testUnknownVolumeGivesNoWarning() async {
        let h = SessionHarness()
        h.settings.instantDetection = true
        h.system.current.outputVolume = nil
        _ = await h.startListening()
        h.scheduler.advance(by: T.sentinelTick * Double(T.systemEveryTicks) + 1)
        XCTAssertNil(warning(h, "seviye"), "Okunamayan seviye için yanlış alarm verilmez")
        XCTAssertNil(h.vm.checkup.first(where: { $0.id == "seviye" }))
    }

    // MARK: Boşluk 2: aynı numaralı cevap ezilir

    func testAnsweringTheSameNumberAgainSaysTheOldAnswerWasReplaced() async {
        let h = SessionHarness()
        _ = await h.startListening()
        await answer(h, number: 3)
        XCTAssertFalse(h.speaker.spoken.contains(Say.answerReplaced(3)), "İlk cevapta uyarı yoktur")
        await answer(h, number: 3)
        let told = await waitUntil(45) { h.speaker.spoken.contains(Say.answerReplaced(3)) }
        XCTAssertTrue(told, "Aynı numara yeniden cevaplanınca eski cevabın ezildiği söylenir: \(h.speaker.spoken)")
        XCTAssertEqual(h.vm.answers.count, 1, "Numara başına tek cevap")
        XCTAssertEqual(h.speaker.spoken.filter { $0 == Say.answerReplaced(3) }.count, 1, "Bir kez söylenir")
    }

    func testDifferentNumbersNeverSayReplaced() async {
        let h = SessionHarness()
        _ = await h.startListening()
        await answer(h, number: 1)
        await answer(h, number: 2)
        await answer(h, number: 4)
        XCTAssertFalse(h.speaker.spoken.contains { $0.contains("önceki cevabı") }, "\(h.speaker.spoken)")
        XCTAssertEqual(h.vm.answers.map { $0.number }.sorted(), [1, 2, 4])
    }

    // MARK: Boşluk 3: test bitince cevapsız sorular

    func testTestCompletionTellsWhichQuestionsHaveNoAnswer() async {
        let h = SessionHarness()
        h.settings.readAnswersAtEnd = false
        _ = await h.startListening()
        await answer(h, number: 1)
        await answer(h, number: 4)
        h.listener.say("Testi bitir")
        h.scheduler.advance(by: T.numberConfirm + 0.1)
        let asked = await waitUntil(45) { h.vm.listenMode == .confirmEnd && h.vm.phase == .listening }
        XCTAssertTrue(asked)
        h.listener.say("Evet")
        h.scheduler.advance(by: T.numberConfirm + 0.1)
        let ended = await waitUntil(45) { h.vm.phase == .finished }
        XCTAssertTrue(ended, "\(h.speaker.spoken)")
        XCTAssertEqual(h.speaker.spoken.last, "Test tamamlandı. 2 cevap kaydedildi. Cevabı olmayan sorular: 2 ve 3.")
        XCTAssertEqual(h.speaker.spoken.last, Say.testCompleted(2, missing: [2, 3]))
    }

    func testTestCompletionWithoutGapsStaysAsBefore() async {
        let h = SessionHarness()
        h.settings.readAnswersAtEnd = false
        _ = await h.startListening()
        await answer(h, number: 1)
        await answer(h, number: 2)
        h.listener.say("Testi bitir")
        h.scheduler.advance(by: T.numberConfirm + 0.1)
        _ = await waitUntil(45) { h.vm.listenMode == .confirmEnd && h.vm.phase == .listening }
        h.listener.say("Evet")
        h.scheduler.advance(by: T.numberConfirm + 0.1)
        let ended = await waitUntil(45) { h.vm.phase == .finished }
        XCTAssertTrue(ended)
        XCTAssertEqual(h.speaker.spoken.last, "Test tamamlandı. 2 cevap kaydedildi.", "Boşluk yoksa cümle değişmez")
    }

    func testCompletionSentenceShortensALongList() {
        XCTAssertEqual(Say.testCompleted(0), "Test tamamlandı.")
        XCTAssertEqual(Say.testCompleted(3, missing: [2]), "Test tamamlandı. 3 cevap kaydedildi. Cevabı olmayan sorular: 2.")
        let many = Array(1...20)
        XCTAssertTrue(Say.testCompleted(1, missing: many).hasSuffix("ve 12 ve devamı."), Say.testCompleted(1, missing: many))
        XCTAssertEqual(Say.answerReplaced(7), "7 numaralı sorunun önceki cevabı yenisiyle değiştirildi.")
        XCTAssertEqual(Say.lowVolume(5), "Telefonun ses seviyesi yüzde 5, çok düşük. Cevapları duyamayabilirsiniz; telefonun ses artırma tuşuna basın.")
    }

    // MARK: Boşluk 4: numara beklenirken "N. sorunun cevabını tekrarla"

    func testRepeatNumberWhileTheQuestionNumberIsAskedReadsItAndAsksTheNumberAgain() async {
        let h = SessionHarness()
        h.settings.askMissingNumber = true
        _ = await h.startListening()
        await answer(h, number: 5)
        let five = h.vm.answers.first(where: { $0.number == 5 })?.spoken ?? "?"
        h.ask("Ali eve gitti ve okula yürüdü")
        let asking = await waitUntil(45) { h.vm.listenMode == .missingNumber && h.vm.phase == .listening }
        XCTAssertTrue(asking, "\(h.speaker.spoken)")
        XCTAssertNotNil(h.vm.heldQuestion)
        let calls = h.answering.calls.count
        h.listener.say("beşinci sorunun cevabını tekrarla")
        h.scheduler.advance(by: T.numberConfirm + 0.1)
        let back = await waitUntil(45) {
            Array(h.speaker.spoken.suffix(2)) == [five, Say.reviewBackToNumber] && h.vm.listenMode == .missingNumber && h.vm.phase == .listening
        }
        XCTAssertTrue(back, "Cevap okunur, aynı soru yeniden sorulur: \(h.speaker.spoken)")
        XCTAssertNotNil(h.vm.heldQuestion, "Numarası beklenen soru korunur")
        XCTAssertEqual(h.answering.calls.count, calls, "Komut Gemini'ye gitmez")
        // Numara söylenince tutulan soru normal gider
        h.answering.results = [.success(FakeAnswering.reply(7))]
        h.listener.say("yedi")
        h.scheduler.advance(by: T.numberConfirm + 0.1)
        let sent = await waitUntil(45) { h.answering.calls.count == calls + 1 }
        XCTAssertTrue(sent, "\(h.speaker.spoken)")
        XCTAssertTrue(h.answering.calls[calls].question.contains("Ali eve gitti"), h.answering.calls[calls].question)
    }

    func testRepeatNumberWithoutAnAnswerSaysSoAndAsksTheNumberAgain() async {
        let h = SessionHarness()
        h.settings.askMissingNumber = true
        _ = await h.startListening()
        h.ask("Ali eve gitti ve okula yürüdü")
        _ = await waitUntil(45) { h.vm.listenMode == .missingNumber && h.vm.phase == .listening }
        h.listener.say("dokuzuncu sorunun cevabını tekrarla")
        h.scheduler.advance(by: T.numberConfirm + 0.1)
        let back = await waitUntil(45) {
            Array(h.speaker.spoken.suffix(2)) == [Say.noAnswerFor(9), Say.reviewBackToNumber] && h.vm.listenMode == .missingNumber && h.vm.phase == .listening
        }
        XCTAssertTrue(back, "\(h.speaker.spoken)")
        XCTAssertNotNil(h.vm.heldQuestion)
    }

    func testRepeatNumberWhileThePassageNumbersAreAskedKeepsTheDraft() async {
        let h = SessionHarness()
        _ = await h.startListening()
        await answer(h, number: 5)
        let five = h.vm.answers.first(where: { $0.number == 5 })?.spoken ?? "?"
        h.listener.say("Ortak paragraf Ali eve gitti. Sonra okula yürüdü Tamamlandı")
        h.scheduler.advance(by: T.triggerConfirm + 0.1)
        let asked = await waitUntil(45) { h.vm.listenMode == .passageTargets && h.vm.phase == .listening }
        XCTAssertTrue(asked, "\(h.speaker.spoken)")
        XCTAssertNotNil(h.vm.passageDraft)
        h.listener.say("beşinci sorunun cevabını tekrarla")
        h.scheduler.advance(by: T.numberConfirm + 0.1)
        let back = await waitUntil(45) {
            Array(h.speaker.spoken.suffix(2)) == [five, Say.reviewBackToTargets] && h.vm.listenMode == .passageTargets && h.vm.phase == .listening
        }
        XCTAssertTrue(back, "\(h.speaker.spoken)")
        XCTAssertNotNil(h.vm.passageDraft, "Paragraf taslağı korunur")
    }

    /// Numara beklenirken yalnız bir sayı söylemek hâlâ numara cevabıdır ("beş" komut sanılmaz)
    func testAPlainNumberWhileTheNumberIsAskedStillAnswersTheQuestion() async {
        let h = SessionHarness()
        h.settings.askMissingNumber = true
        _ = await h.startListening()
        h.ask("Ali eve gitti ve okula yürüdü")
        _ = await waitUntil(45) { h.vm.listenMode == .missingNumber && h.vm.phase == .listening }
        h.answering.results = [.success(FakeAnswering.reply(5))]
        h.listener.say("beş")
        h.scheduler.advance(by: T.numberConfirm + 0.1)
        let sent = await waitUntil(45) { h.answering.calls.count == 1 }
        XCTAssertTrue(sent, "\(h.speaker.spoken)")
    }
}
