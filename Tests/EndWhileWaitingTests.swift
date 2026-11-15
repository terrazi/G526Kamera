import XCTest
@testable import G526CameraDrive

/// "Testi bitir" soru numarası ya da ortak paragraf numaraları beklenirken de söylenebilir. Bekleyen iş (numarası beklenen soru, alınan paragraf)
/// bitirmeyle gönderilmeden kalacağı için onayda bu söylenir; vazgeçilirse (hayır, anlaşılmayan söz, cevapsızlık) aynı bekleme kipine dönülür.
@MainActor
final class EndWhileWaitingTests: XCTestCase {
    private typealias T = SessionViewModel.Timing

    private func harness() -> SessionHarness {
        let h = SessionHarness()
        h.settings.askMissingNumber = true
        return h
    }

    private func say(_ h: SessionHarness, _ text: String, confirm: TimeInterval = T.numberConfirm) {
        h.listener.say(text)
        h.scheduler.advance(by: confirm + 0.1)
    }

    private func answerOne(_ h: SessionHarness, number: Int) async {
        h.answering.results.append(.success(FakeAnswering.reply(number)))
        h.ask("Soru \(number). A seçeneği Adana")
        _ = await waitUntil(45) { h.vm.answers.count == number && h.vm.phase == .listening }
    }

    /// Numarası söylenmeyen bir soru okunur; program numarayı sorana kadar beklenir
    private func holdAQuestion(_ h: SessionHarness) async {
        h.ask("Ali eve gitti ve okula yürüdü")
        let asking = await waitUntil(45) { h.vm.listenMode == .missingNumber && h.vm.phase == .listening }
        XCTAssertTrue(asking, "Numara sorulmadı: \(h.speaker.spoken)")
        XCTAssertNotNil(h.vm.heldQuestion)
    }

    private func askEndConfirmation(_ h: SessionHarness, sentence: String) async {
        say(h, "testi bitir")
        let asked = await waitUntil(45) { h.vm.listenMode == .confirmEnd && h.vm.phase == .listening && h.speaker.spoken.last == sentence }
        XCTAssertTrue(asked, "Bitirme onayı sorulmadı: \(h.speaker.spoken)")
    }

    func testEndWhileTheNumberIsAskedMentionsTheHeldQuestionAndKeepsItWhenDeclined() async {
        let h = harness()
        _ = await h.startListening()
        await holdAQuestion(h)
        let calls = h.answering.calls.count
        await askEndConfirmation(h, sentence: Say.confirmEndHeldQuestion)
        XCTAssertNotNil(h.vm.heldQuestion, "Onay beklenirken soru tutulur")
        say(h, "hayır")
        let back = await waitUntil(45) { h.vm.listenMode == .missingNumber && h.vm.phase == .listening && h.speaker.spoken.last == Say.reviewBackToNumber }
        XCTAssertTrue(back, "Vazgeçilince numara yeniden sorulur: \(h.speaker.spoken)")
        XCTAssertNotNil(h.vm.heldQuestion, "Numarası beklenen soru kaybolmaz")
        XCTAssertEqual(h.answering.calls.count, calls, "Komut Gemini'ye gitmez")
        h.answering.results = [.success(FakeAnswering.reply(7))]
        say(h, "yedi")
        let sent = await waitUntil(45) { h.answering.calls.count == calls + 1 }
        XCTAssertTrue(sent, "\(h.speaker.spoken)")
        guard sent else { return }
        XCTAssertEqual(h.answering.calls[calls].question, "Soru 7. Ali eve gitti ve okula yürüdü")
    }

    func testConfirmingTheEndWhileTheNumberIsAskedEndsTheTestWithoutSendingTheHeldQuestion() async {
        let h = harness()
        h.settings.readAnswersAtEnd = false
        _ = await h.startListening()
        await holdAQuestion(h)
        await askEndConfirmation(h, sentence: Say.confirmEndHeldQuestion)
        say(h, "evet")
        let ended = await waitUntil(45) { h.vm.phase == .finished }
        XCTAssertTrue(ended, "\(h.speaker.spoken)")
        XCTAssertEqual(h.speaker.spoken.last, "Test tamamlandı.")
        XCTAssertTrue(h.answering.calls.isEmpty, "Numarası beklenen soru gönderilmez")
    }

    func testEndWhileTheTargetsAreAskedKeepsTheDraftWhenDeclined() async {
        let h = harness()
        _ = await h.startListening()
        await answerOne(h, number: 1)
        say(h, "Ortak paragraf Ali eve gitti. Sonra okula yürüdü Tamamlandı", confirm: T.triggerConfirm)
        let asked = await waitUntil(45) { h.vm.listenMode == .passageTargets && h.vm.phase == .listening }
        XCTAssertTrue(asked, "\(h.speaker.spoken)")
        await askEndConfirmation(h, sentence: Say.confirmEndHeldPassage)
        XCTAssertNotNil(h.vm.passageDraft)
        say(h, "hayır")
        let back = await waitUntil(45) { h.vm.listenMode == .passageTargets && h.vm.phase == .listening && h.speaker.spoken.last == Say.reviewBackToTargets }
        XCTAssertTrue(back, "\(h.speaker.spoken)")
        XCTAssertNotNil(h.vm.passageDraft, "Alınan paragraf kaybolmaz")
        say(h, "beş altı yedi Tamam")
        let saved = await waitUntil(45) { h.vm.listenMode == .question && h.vm.phase == .listening }
        XCTAssertTrue(saved, "Numaralar yine alınır: \(h.speaker.spoken)")
    }

    func testNoAnswerToTheEndQuestionReturnsToTheWaitingNumber() async {
        let h = harness()
        _ = await h.startListening()
        await holdAQuestion(h)
        await askEndConfirmation(h, sentence: Say.confirmEndHeldQuestion)
        h.scheduler.advance(by: SilenceWatchdog.limit + 0.1)
        let again = await waitUntil(45) { h.speaker.spoken.last == Say.confirmEndAgain && h.vm.listenMode == .confirmEnd && h.vm.phase == .listening }
        XCTAssertTrue(again, "\(h.speaker.spoken)")
        h.scheduler.advance(by: SilenceWatchdog.limit + 0.1)
        let third = await waitUntil(45) { h.speaker.spoken.last == Say.reask(Say.confirmEndAgain, attempt: 3) && h.vm.listenMode == .confirmEnd && h.vm.phase == .listening }
        XCTAssertTrue(third, "\(h.speaker.spoken)")
        h.scheduler.advance(by: SilenceWatchdog.limit + 0.1)
        let back = await waitUntil(45) { h.vm.listenMode == .missingNumber && h.vm.phase == .listening && h.speaker.spoken.last == Say.reviewBackToNumber }
        XCTAssertTrue(back, "Cevap gelmezse test bitmez, numara beklenmeye dönülür: \(h.speaker.spoken)")
        XCTAssertNotNil(h.vm.heldQuestion)
    }

    /// Cevaplar okunduktan sonra "Devam" denirse numarası beklenen soruya dönülür
    func testReadingBeforeEndingAndSayingContinueGoesBackToTheNumber() async {
        let h = harness()
        _ = await h.startListening()
        await answerOne(h, number: 1)
        await holdAQuestion(h)
        await askEndConfirmation(h, sentence: Say.confirmEndHeldQuestion)
        say(h, "evet")
        let reading = await waitUntil(45) { h.vm.reviewing }
        XCTAssertTrue(reading, "Cevaplar okunmaya başlamadı: \(h.speaker.spoken)")
        h.player.finish()
        let menu = await waitUntil(45) { h.vm.listenMode == .reviewMenu && h.vm.phase == .listening }
        XCTAssertTrue(menu, "\(h.speaker.spoken)")
        say(h, "Devam")
        let back = await waitUntil(45) { h.vm.listenMode == .missingNumber && h.vm.phase == .listening && h.speaker.spoken.last == Say.reviewBackToNumber }
        XCTAssertTrue(back, "Okunan soru kaybolmaz: \(h.speaker.spoken)")
        XCTAssertNotNil(h.vm.heldQuestion)
    }

    /// Soru sırasında "testi bitir" eskisi gibi çalışır (genel onay cümlesi, soru kipine dönüş)
    func testEndDuringAQuestionIsUnchanged() async {
        let h = harness()
        _ = await h.startListening()
        await askEndConfirmation(h, sentence: Say.confirmEnd)
        say(h, "hayır")
        let back = await waitUntil(45) { h.vm.listenMode == .question && h.vm.phase == .listening && h.speaker.spoken.last == Say.endCancelled }
        XCTAssertTrue(back, "\(h.speaker.spoken)")
    }
}
