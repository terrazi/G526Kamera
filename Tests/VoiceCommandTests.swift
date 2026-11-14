import XCTest
@testable import G526CameraDrive

/// Sesli komutlar ("testi bitir", "tekrarla"), sözlü evet/hayır ve "devam mı, yeni mi?" akışı, önceki kaydı hatırlama
@MainActor
final class VoiceCommandParseTests: XCTestCase {
    func testEndCommandsAreRecognizedOnlyWhenTheWholeTextIsTheCommand() {
        for text in ["Testi bitir", "testi bitir.", "Sınavı bitir", "sınavı sonlandır", "Lütfen testi bitir", "sınav bitti", "test sona erdi",
                     "Deneme sınavı bitti", "sınavı tamamla", "TESTİ BİTİR"] {
            XCTAssertEqual(VoiceCommand.parse(text), .endTest, text)
        }
        for text in ["Testi bitirmek için hangisi doğrudur", "soru yedi testi bitir", "sınavı bitirmeden önce", "bitir", "testi", ""] {
            XCTAssertNil(VoiceCommand.parse(text), text)
        }
    }

    func testRepeatCommand() {
        for text in ["Tekrarla", "son cevabı tekrarla", "cevabı tekrar oku", "Lütfen tekrarla"] {
            XCTAssertEqual(VoiceCommand.parse(text), .repeatLast, text)
        }
        XCTAssertNil(VoiceCommand.parse("soruyu tekrarla ve cevapla lütfen"))
    }

    func testYesNoAndStartReplies() {
        XCTAssertEqual(SpokenReply.yesNo("Evet"), .yes)
        XCTAssertEqual(SpokenReply.yesNo("evet bitir."), .yes)
        XCTAssertEqual(SpokenReply.yesNo("Hayır"), .no)
        XCTAssertEqual(SpokenReply.yesNo("hayır devam"), .no)
        XCTAssertNil(SpokenReply.yesNo("belki evet belki hayır olabilir ama emin değilim"))
        XCTAssertEqual(SpokenReply.start("Devam"), .continuePrevious)
        XCTAssertEqual(SpokenReply.start("önceki kayıttan devam"), .continuePrevious)
        XCTAssertEqual(SpokenReply.start("Yeni"), .startNew)
        XCTAssertEqual(SpokenReply.start("yeni sınav"), .startNew)
        XCTAssertNil(SpokenReply.start("soru bir"))
    }
}

@MainActor
final class VoiceCommandFlowTests: XCTestCase {
    private typealias T = SessionViewModel.Timing

    private func answerOne(_ h: SessionHarness, number: Int = 1) async {
        h.answering.results.append(.success(FakeAnswering.reply(number)))
        h.ask("Soru \(number). A seçeneği Adana")
        _ = await waitUntil { h.vm.answers.count == number && h.vm.phase == .listening }
    }

    // MARK: Testi bitir

    func testEndCommandAsksForConfirmationAndYesEndsTheTest() async {
        let h = SessionHarness()
        _ = await h.startListening()
        await answerOne(h)
        h.listener.say("Testi bitir")
        h.scheduler.advance(by: T.numberConfirm + 0.1)
        let asked = await waitUntil { h.vm.listenMode == .confirmEnd && h.vm.phase == .listening }
        XCTAssertTrue(asked)
        XCTAssertEqual(h.speaker.spoken.last, Say.confirmEnd)
        XCTAssertEqual(h.answering.calls.count, 1, "Komut Gemini'ye soru olarak gitmez")
        h.listener.say("Evet")
        h.scheduler.advance(by: T.numberConfirm + 0.1)
        let ended = await waitUntil { h.vm.phase == .finished }
        XCTAssertTrue(ended)
        XCTAssertEqual(h.speaker.spoken.last, Say.endingTest(1))
    }

    func testNoToTheConfirmationKeepsTheTestGoing() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.listener.say("Sınavı bitir")
        h.scheduler.advance(by: T.numberConfirm + 0.1)
        _ = await waitUntil { h.vm.listenMode == .confirmEnd && h.vm.phase == .listening }
        h.listener.say("Hayır")
        h.scheduler.advance(by: T.numberConfirm + 0.1)
        let back = await waitUntil { h.vm.listenMode == .question && h.vm.phase == .listening && h.speaker.spoken.last == Say.endCancelled }
        XCTAssertTrue(back)
    }

    func testNoAnswerToTheConfirmationNeverEndsTheTest() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.listener.say("Testi bitir")
        h.scheduler.advance(by: T.numberConfirm + 0.1)
        _ = await waitUntil { h.vm.listenMode == .confirmEnd && h.vm.phase == .listening }
        h.scheduler.advance(by: SilenceWatchdog.limit + 0.1)
        let back = await waitUntil { h.vm.listenMode == .question && h.vm.phase == .listening && h.speaker.spoken.last == Say.endCancelled }
        XCTAssertTrue(back, "Cevap gelmezse test bitmez")
    }

    func testEndCommandFollowedByCevaplaIsNotSentAsAQuestion() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.ask("Testi bitir")
        let asked = await waitUntil { h.vm.listenMode == .confirmEnd && h.vm.phase == .listening }
        XCTAssertTrue(asked)
        XCTAssertTrue(h.answering.calls.isEmpty, "Gemini'ye hiçbir şey gitmez")
        XCTAssertTrue(h.vm.questions.isEmpty)
    }

    func testAQuestionThatMentionsEndingTheTestIsStillAQuestion() async {
        let h = SessionHarness()
        h.answering.results = [.success(FakeAnswering.reply(1))]
        _ = await h.startListening()
        h.ask("Testi bitirmek için hangisi doğrudur")
        let done = await waitUntil { h.vm.answers.count == 1 }
        XCTAssertTrue(done)
        XCTAssertEqual(h.answering.calls.count, 1)
    }

    // MARK: Son cevabı tekrarla

    func testRepeatCommandReadsTheLastAnswerAgainWithoutAskingGemini() async {
        let h = SessionHarness()
        _ = await h.startListening()
        await answerOne(h)
        let before = h.speaker.spoken.count
        h.listener.say("Tekrarla")
        h.scheduler.advance(by: T.numberConfirm + 0.1)
        let again = await waitUntil { h.speaker.spoken.count > before && h.vm.phase == .listening }
        XCTAssertTrue(again)
        XCTAssertTrue(h.speaker.spoken.contains("Soru 1, Denizli, Örgütsel Davranış"))
        XCTAssertEqual(h.speaker.spoken.filter { $0 == "Soru 1, Denizli, Örgütsel Davranış" }.count, 2)
        XCTAssertEqual(h.answering.calls.count, 1)
    }

    func testRepeatCommandWithNothingToRepeatSaysSo() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.listener.say("Tekrarla")
        h.scheduler.advance(by: T.numberConfirm + 0.1)
        let said = await waitUntil { h.speaker.spoken.last == Say.nothingToReplay && h.vm.phase == .listening }
        XCTAssertTrue(said)
    }

    // MARK: Önceki kaydı hatırlama

    private func finishedSessionWithOneAnswer(_ h: SessionHarness) async -> URL? {
        _ = await h.startListening()
        await answerOne(h)
        let folder = h.vm.sessionFolder
        h.vm.endTest()
        return folder
    }

    func testRestartAfterEndTestAsksAndContinuingKeepsFolderAndNumbering() async {
        let h = SessionHarness()
        let folder = await finishedSessionWithOneAnswer(h)
        XCTAssertEqual(h.vm.phase, .finished)
        _ = await h.startListening()
        XCTAssertEqual(h.vm.listenMode, .startChoice)
        XCTAssertEqual(h.speaker.spoken.last, Say.readyAskContinue(answers: 1, next: 2), "'İlk soruyu bekliyorum' denmez: önceki kayıt hatırlanır")
        h.listener.say("Devam")
        h.scheduler.advance(by: T.numberConfirm + 0.1)
        let on = await waitUntil { h.vm.listenMode == .question && h.vm.phase == .listening && h.speaker.spoken.last == Say.continuingPrevious(next: 2) }
        XCTAssertTrue(on)
        XCTAssertEqual(h.vm.sessionFolder, folder, "Aynı klasör")
        XCTAssertEqual(h.vm.nextNumber, 2)
        XCTAssertEqual(h.vm.answers.count, 1, "Önceki cevaplar yüklenir")
        await answerOne(h, number: 2)
        XCTAssertEqual(h.vm.answers.last?.number, 2)
        XCTAssertEqual(h.vm.sessionFolder, folder)
    }

    func testChoosingNewStartsAFreshFolderAndNumbering() async {
        let h = SessionHarness()
        let folder = await finishedSessionWithOneAnswer(h)
        _ = await h.startListening()
        h.listener.say("Yeni sınav")
        h.scheduler.advance(by: T.numberConfirm + 0.1)
        let on = await waitUntil { h.vm.listenMode == .question && h.vm.phase == .listening && h.speaker.spoken.last == Say.startingNew }
        XCTAssertTrue(on)
        XCTAssertNotEqual(h.vm.sessionFolder, folder, "Eski cevapların üzerine yazılmaz: yeni klasör")
        XCTAssertEqual(h.vm.nextNumber, 1)
        XCTAssertTrue(h.vm.answers.isEmpty)
    }

    func testUnansweredChoiceRemindsOnceThenContinuesWhenTheRecordIsRecent() async {
        let h = SessionHarness()
        let folder = await finishedSessionWithOneAnswer(h)
        _ = await h.startListening()
        h.scheduler.advance(by: SilenceWatchdog.limit + 0.1)
        let reminded = await waitUntil { h.speaker.spoken.last == Say.askChoiceAgain && h.vm.phase == .listening }
        XCTAssertTrue(reminded)
        h.scheduler.advance(by: SilenceWatchdog.limit + 0.1)
        let on = await waitUntil { h.speaker.spoken.last == Say.continuingPrevious(next: 2) && h.vm.phase == .listening }
        XCTAssertTrue(on)
        XCTAssertEqual(h.vm.sessionFolder, folder)
    }

    func testUnansweredChoiceStartsNewWhenTheRecordIsOld() async {
        let h = SessionHarness()
        let folder = await finishedSessionWithOneAnswer(h)
        h.vm.carry?.at = .distantPast
        _ = await h.startListening()
        h.scheduler.advance(by: SilenceWatchdog.limit + 0.1)
        _ = await waitUntil { h.speaker.spoken.last == Say.askChoiceAgain && h.vm.phase == .listening }
        h.scheduler.advance(by: SilenceWatchdog.limit + 0.1)
        let on = await waitUntil { h.speaker.spoken.last == Say.startingNew && h.vm.phase == .listening }
        XCTAssertTrue(on)
        XCTAssertNotEqual(h.vm.sessionFolder, folder)
        XCTAssertEqual(h.vm.nextNumber, 1)
    }

    func testFirstEverStartDoesNotAskAnything() async {
        let h = SessionHarness()
        _ = await h.startListening()
        XCTAssertEqual(h.vm.listenMode, .question)
        XCTAssertEqual(h.speaker.spoken.first, Say.ready)
    }

    func testEndedSessionWithoutAnswersDoesNotAsk() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.vm.endTest()
        _ = await h.startListening()
        XCTAssertEqual(h.vm.listenMode, .question)
        XCTAssertEqual(h.speaker.spoken.last, Say.ready, "Cevap yoksa hatırlanacak bir şey yok")
    }

    func testLaunchRemembersTheLastFolderAndNumberFromTheJournal() {
        let h = SessionHarness()
        h.journal.start = RunStart(exit: .clean, pending: nil, nextNumber: 5, folder: "2026-01-01", downSeconds: 60, loop: false)
        h.vm.launched()
        XCTAssertEqual(h.vm.carry?.folder, "2026-01-01")
        XCTAssertEqual(h.vm.carry?.nextNumber, 5)
        XCTAssertEqual(h.vm.phase, .idle, "Düzgün bitmiş önceki çalışma kendiliğinden oturum başlatmaz")
    }
}
