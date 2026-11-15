import XCTest
@testable import G526CameraDrive

/// "Soruyu atla" / "yeni soru": yarım kalan ya da yanlış anlaşılan soru bırakılır. "Son soruyu sil": en son kaydedilen sorunun kaydı
/// önce onay istenerek ("evet") silinir; "hayır", cevapsızlık ve anlaşılmayan söz hiçbir şeyi silmez.
final class SkipDeleteParsingTests: XCTestCase {
    func testSkipQuestionPhrases() {
        for text in ["soruyu atla", "Soruyu atla.", "bu soruyu atla", "lütfen soruyu atla", "soruyu atlayalım", "yeni soru", "Yeni soru.",
                     "soruyu geç", "bu soruyu geçelim", "soruyu bırak"] {
            XCTAssertEqual(VoiceCommand.parse(text), .skipQuestion, text)
        }
    }

    func testSkipIsNotConfusedWithOtherCommandsOrQuestionText() {
        XCTAssertEqual(VoiceCommand.parse("soruyu iptal et"), .cancelQuestion)
        XCTAssertEqual(VoiceCommand.parse("soruyu sil"), .cancelQuestion, "Son yoksa okunan soru iptal edilir")
        XCTAssertEqual(VoiceCommand.parse("paragrafı atla"), .cancelPassage)
        for text in ["atla", "geç", "yeni", "yeni paragraf", "yeni soruyu okuyacağım", "Ali yeni soru sordu", "soruyu atlamak için ne yapmalı",
                     "bir sonraki soruya geç"] {
            XCTAssertNotEqual(VoiceCommand.parse(text), .skipQuestion, text)
        }
        XCTAssertTrue(VoiceCommand.skipQuestion.isCancelQuestion)
        XCTAssertTrue(VoiceCommand.cancelQuestion.isCancelQuestion)
        XCTAssertFalse(VoiceCommand.deleteLastQuestion.isCancelQuestion)
    }

    func testDeleteLastQuestionPhrases() {
        for text in ["son soruyu sil", "Son soruyu sil.", "son cevabı sil", "son sorunun kaydını sil", "en son soruyu iptal et", "son kaydı sil",
                     "sonuncu soruyu silelim", "lütfen son soruyu sil", "son soruyu iptal et"] {
            XCTAssertEqual(VoiceCommand.parse(text), .deleteLastQuestion, text)
        }
    }

    func testDeleteLastIsNotConfusedWithOtherCommandsOrQuestionText() {
        XCTAssertEqual(VoiceCommand.parse("son cümleyi sil"), .deleteLast, "Cümle silme eskisi gibi")
        XCTAssertEqual(VoiceCommand.parse("son cevabı tekrarla"), .repeatLast)
        XCTAssertEqual(VoiceCommand.parse("soruyu sil"), .cancelQuestion)
        for text in ["sil", "son", "son soruyu", "sil son", "son soruyu silme", "son soruyu silmek için ne yapılır", "Ali son soruyu sildi",
                     "son soruyu sil ve cevapları tekrarla"] {
            XCTAssertNotEqual(VoiceCommand.parse(text), .deleteLastQuestion, text)
        }
        XCTAssertFalse(VoiceCommand.deleteLastQuestion.isInfo, "Silme komutu bilgi komutu değil: onay ister")
    }

    func testConfirmationSentencesNameTheQuestionAndAskThreeTimes() {
        XCTAssertTrue(Say.confirmDeleteLast(7).contains("Soru 7"))
        XCTAssertTrue(Say.confirmDeleteLast(7).contains("evet"))
        XCTAssertTrue(Say.confirmDeleteLastAgain(7).contains("ikinci defa soruyorum"))
        XCTAssertTrue(Say.reask(Say.confirmDeleteLastAgain(7), attempt: 3).contains("üçüncü defa soruyorum"))
        XCTAssertFalse(Say.lastQuestionDeleted(7, cameraNext: true).contains("okuyabilirsiniz"))
        XCTAssertTrue(Say.lastQuestionDeleted(7, cameraNext: false).contains("okuyabilirsiniz"))
    }
}

@MainActor
final class SkipDeleteFlowTests: XCTestCase {
    typealias T = SessionViewModel.Timing

    private func say(_ h: SessionHarness, _ text: String, after: TimeInterval = T.numberConfirm) {
        h.listener.say(text)
        h.scheduler.advance(by: after + 0.1)
    }

    private func answerOne(_ h: SessionHarness, number: Int, expected: Int? = nil) async {
        h.answering.results = [.success(FakeAnswering.reply(number))]
        h.ask("Soru \(number). A seçeneği Adana")
        let count = expected ?? number
        let done = await waitUntil(45) { h.vm.answers.count == count && h.vm.phase == .listening }
        XCTAssertTrue(done, "\(number). soru cevaplanmadı: \(h.speaker.spoken)")
    }

    private func files(_ h: SessionHarness) -> [String] {
        guard let folder = h.vm.sessionFolder else { return [] }
        return AnswerLibrary(root: h.root).answerFiles(in: folder).map { $0.deletingPathExtension().lastPathComponent }
    }

    private func transcript(_ h: SessionHarness) -> String {
        guard let folder = h.vm.sessionFolder else { return "" }
        return (try? String(contentsOf: folder.appendingPathComponent(AnswerLibrary.transcriptName), encoding: .utf8)) ?? ""
    }

    /// "Son soruyu sil" der ve onay sorusu açılana kadar bekler
    private func askToDeleteLast(_ h: SessionHarness, number: Int) async {
        say(h, "Son soruyu sil")
        let asked = await waitUntil(45) { h.speaker.spoken.last == Say.confirmDeleteLast(number) && h.vm.listenMode == .confirmEnd && h.vm.phase == .listening }
        XCTAssertTrue(asked, "Onay sorulmadı: \(h.speaker.spoken)")
    }

    // MARK: Soruyu atla

    func testSkipDropsTheHalfReadQuestionAndTheNextOneGoesNormally() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.listener.say("Soru 5 Ali eve gitti")
        h.scheduler.advance(by: T.utteranceGap + 0.1)
        say(h, "Soru 5 Ali eve gitti soruyu atla")
        let done = await waitUntil(45) { h.speaker.spoken.last == Say.questionSkipped && h.vm.listenMode == .question && h.vm.phase == .listening }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        XCTAssertEqual(h.vm.accumulator.text, "", "Yarım kalan metin atıldı")
        XCTAssertTrue(h.answering.calls.isEmpty, "Atlanan soru Gemini'ye gitmez")
        h.answering.results = [.success(FakeAnswering.reply(6))]
        h.ask("Soru 6 Yeni soru metni")
        let sent = await waitUntil(45) { h.answering.calls.count == 1 }
        XCTAssertTrue(sent)
        XCTAssertFalse(h.answering.calls[0].question.contains("Ali eve gitti"), h.answering.calls[0].question)
    }

    func testNewQuestionIsTheSameAsSkip() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.listener.say("Soru 5 Ali eve gitti")
        h.scheduler.advance(by: T.utteranceGap + 0.1)
        say(h, "Soru 5 Ali eve gitti yeni soru")
        let done = await waitUntil(45) { h.speaker.spoken.last == Say.questionSkipped && h.vm.listenMode == .question && h.vm.phase == .listening }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
    }

    func testSkipWithNothingReadSaysSo() async {
        let h = SessionHarness()
        _ = await h.startListening()
        say(h, "soruyu atla")
        let done = await waitUntil(45) { h.speaker.spoken.last == Say.nothingToSkipQuestion && h.vm.listenMode == .question && h.vm.phase == .listening }
        XCTAssertTrue(done, "Sessiz kalmaz, atlanacak soru olmadığını söyler: \(h.speaker.spoken)")
    }

    func testSkipWhileTheNumberIsAskedDropsTheHeldQuestion() async {
        let h = SessionHarness()
        h.settings.askMissingNumber = true
        _ = await h.startListening()
        h.ask("Ali eve gitti ve okula yürüdü")
        let asked = await waitUntil(45) { h.vm.listenMode == .missingNumber && h.vm.phase == .listening }
        XCTAssertTrue(asked, "\(h.speaker.spoken)")
        XCTAssertNotNil(h.vm.heldQuestion)
        say(h, "soruyu atla")
        let done = await waitUntil(45) { h.speaker.spoken.last == Say.questionSkipped && h.vm.listenMode == .question && h.vm.phase == .listening }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        XCTAssertNil(h.vm.heldQuestion, "Numarası beklenen soru bırakıldı")
        XCTAssertTrue(h.answering.calls.isEmpty)
    }

    // MARK: Son soruyu sil

    func testDeleteLastAsksForConfirmationAndDeletesNothingYet() async {
        let h = SessionHarness()
        _ = await h.startListening()
        await answerOne(h, number: 1)
        await answerOne(h, number: 2)
        await askToDeleteLast(h, number: 2)
        XCTAssertEqual(h.vm.answers.map { $0.number }, [1, 2], "Onay gelmeden hiçbir şey silinmez")
        XCTAssertEqual(files(h), ["soru_1", "soru_2"])
    }

    func testYesDeletesTheLastQuestionCompletelyAndItCanBeReadAgain() async {
        let h = SessionHarness()
        _ = await h.startListening()
        await answerOne(h, number: 1)
        await answerOne(h, number: 2)
        XCTAssertTrue(transcript(h).contains("Soru 2,"))
        await askToDeleteLast(h, number: 2)
        say(h, "evet")
        let done = await waitUntil(45) { h.speaker.spoken.last == Say.lastQuestionDeleted(2, cameraNext: false) && h.vm.listenMode == .question && h.vm.phase == .listening }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        XCTAssertEqual(h.vm.answers.map { $0.number }, [1], "Cevap listeden gitti")
        XCTAssertEqual(files(h), ["soru_1"], "Ses dosyası silindi, öteki soru korundu")
        XCTAssertFalse(transcript(h).contains("Soru 2,"), "Düz yazıdaki satır silindi")
        XCTAssertTrue(transcript(h).contains("Soru 1,"), "Öteki cevabın satırı korundu")
        XCTAssertFalse(h.vm.questions.contains { $0.number == 2 }, "Ana ekrandaki satır silindi")
        XCTAssertEqual(h.vm.nextNumber, 2, "Silinen soru yeniden okunacağı için sıradaki numara ona döner")
        XCTAssertNil(h.vm.pendingDelete)
        await answerOne(h, number: 2)
        XCTAssertEqual(h.vm.answers.map { $0.number }, [1, 2], "Silinen soru yeniden okunup cevaplanabilir")
    }

    func testNoKeepsEverything() async {
        let h = SessionHarness()
        _ = await h.startListening()
        await answerOne(h, number: 1)
        await answerOne(h, number: 2)
        await askToDeleteLast(h, number: 2)
        say(h, "hayır")
        let back = await waitUntil(45) { h.speaker.spoken.last == Say.deleteCancelled && h.vm.listenMode == .question && h.vm.phase == .listening }
        XCTAssertTrue(back, "\(h.speaker.spoken)")
        XCTAssertEqual(h.vm.answers.map { $0.number }, [1, 2])
        XCTAssertEqual(files(h), ["soru_1", "soru_2"])
        XCTAssertTrue(transcript(h).contains("Soru 2,"))
        XCTAssertNil(h.vm.pendingDelete)
    }

    func testUnclearOrMissingConfirmationAsksThreeTimesThenNeverDeletes() async {
        let h = SessionHarness()
        _ = await h.startListening()
        await answerOne(h, number: 1)
        await askToDeleteLast(h, number: 1)
        h.listener.say("hmm bilmem")
        h.scheduler.advance(by: T.numberUnclear + 0.1)
        let second = await waitUntil(45) { h.speaker.spoken.last == Say.confirmDeleteLastAgain(1) && h.vm.listenMode == .confirmEnd && h.vm.phase == .listening }
        XCTAssertTrue(second, "İkinci defa sorulur: \(h.speaker.spoken)")
        h.scheduler.advance(by: SilenceWatchdog.limit + 0.1)
        let third = await waitUntil(45) { h.speaker.spoken.last == Say.reask(Say.confirmDeleteLastAgain(1), attempt: 3) && h.vm.listenMode == .confirmEnd && h.vm.phase == .listening }
        XCTAssertTrue(third, "Üçüncü defa sorulur: \(h.speaker.spoken)")
        h.scheduler.advance(by: SilenceWatchdog.limit + 0.1)
        let kept = await waitUntil(45) { h.speaker.spoken.last == Say.deleteCancelled && h.vm.listenMode == .question && h.vm.phase == .listening }
        XCTAssertTrue(kept, "Onay hiç gelmezse silinmez: \(h.speaker.spoken)")
        XCTAssertEqual(h.vm.answers.map { $0.number }, [1])
        XCTAssertEqual(files(h), ["soru_1"])
    }

    func testLastMeansTheMostRecentlySavedNotTheHighestNumber() async {
        let h = SessionHarness()
        _ = await h.startListening()
        await answerOne(h, number: 3, expected: 1)
        await answerOne(h, number: 1, expected: 2)
        await askToDeleteLast(h, number: 1)
        say(h, "evet")
        let done = await waitUntil(45) { h.speaker.spoken.last == Say.lastQuestionDeleted(1, cameraNext: false) && h.vm.phase == .listening }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        XCTAssertEqual(h.vm.answers.map { $0.number }, [3], "En son okunan 1. soru silindi, 3. soru kaldı")
    }

    func testNothingToDeleteSaysSo() async {
        let h = SessionHarness()
        _ = await h.startListening()
        say(h, "son soruyu sil")
        let done = await waitUntil(45) { h.speaker.spoken.last == Say.nothingToDeleteLast && h.vm.listenMode == .question && h.vm.phase == .listening }
        XCTAssertTrue(done, "Kayıt yoksa sessiz kalmaz, söyler: \(h.speaker.spoken)")
        XCTAssertNil(h.vm.pendingDelete)
    }

    func testDeletingWhileTheNumberIsAskedReturnsToTheNumberQuestion() async {
        let h = SessionHarness()
        h.settings.askMissingNumber = true
        _ = await h.startListening()
        h.answering.results = [.success(FakeAnswering.reply(1))]
        h.ask("Ali eve gitti ve okula yürüdü")
        _ = await waitUntil(45) { h.vm.listenMode == .missingNumber && h.vm.phase == .listening }
        say(h, "bir", after: T.numberConfirm)
        let first = await waitUntil(45) { h.vm.answers.count == 1 && h.vm.phase == .listening }
        XCTAssertTrue(first, "\(h.speaker.spoken)")
        h.ask("Mehmet okula gitti ve eve döndü")
        let asked = await waitUntil(45) { h.vm.listenMode == .missingNumber && h.vm.phase == .listening }
        XCTAssertTrue(asked, "\(h.speaker.spoken)")
        say(h, "son soruyu sil")
        let confirming = await waitUntil(45) { h.speaker.spoken.last == Say.confirmDeleteLast(1) && h.vm.listenMode == .confirmEnd && h.vm.phase == .listening }
        XCTAssertTrue(confirming, "\(h.speaker.spoken)")
        XCTAssertNotNil(h.vm.heldQuestion, "Bekleyen soru korunur")
        say(h, "evet")
        let back = await waitUntil(45) { h.vm.listenMode == .missingNumber && h.vm.phase == .listening && h.speaker.spoken.last?.hasSuffix(Say.reviewBackToNumber) == true }
        XCTAssertTrue(back, "\(h.speaker.spoken)")
        XCTAssertEqual(h.vm.answers.count, 0, "1. sorunun kaydı silindi")
        XCTAssertNotNil(h.vm.heldQuestion, "Numarası beklenen soru yerinde")
    }

    /// Silme onayı bittikten sonra "testi bitir" kendi onay sorusunu sorar (silme durumu bayat kalmaz)
    func testAfterTheDeleteQuestionTheEndQuestionIsTheNormalOne() async {
        let h = SessionHarness()
        _ = await h.startListening()
        await answerOne(h, number: 1)
        await askToDeleteLast(h, number: 1)
        say(h, "hayır")
        _ = await waitUntil(45) { h.speaker.spoken.last == Say.deleteCancelled && h.vm.listenMode == .question && h.vm.phase == .listening }
        say(h, "testi bitir")
        let asked = await waitUntil(45) { h.speaker.spoken.last == Say.confirmEnd && h.vm.listenMode == .confirmEnd && h.vm.phase == .listening }
        XCTAssertTrue(asked, "\(h.speaker.spoken)")
        say(h, "hayır")
        let back = await waitUntil(45) { h.speaker.spoken.last == Say.endCancelled && h.vm.listenMode == .question && h.vm.phase == .listening }
        XCTAssertTrue(back, "\(h.speaker.spoken)")
        XCTAssertEqual(h.vm.answers.count, 1, "Hayır denince hiçbir şey silinmedi")
    }
}
