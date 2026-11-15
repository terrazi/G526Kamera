import XCTest
@testable import G526CameraDrive

/// "Kayıt sil" (istenen soruyu sil) ve "soru numarası düzelt": bölüm (gerekirse) ve numara söylenir, ikisi tekrarlanıp onay alınır; işlem yalnız
/// bu oturumda ve seçilen bölümün klasöründe yapılır; "hayır", cevapsızlık ve vazgeçme hiçbir kaydı değiştirmez.
final class NumberEditParsingTests: XCTestCase {
    func testDeleteChosenQuestionPhrases() {
        for text in ["kayıt sil", "kaydı sil", "Kaydı sil.", "soru kaydını sil", "lütfen kaydı sil", "belirli bir soruyu sil", "başka bir soruyu sil",
                     "numaralı soruyu sil", "belirli soruyu sil"] {
            XCTAssertEqual(VoiceCommand.parse(text), .deleteChosenQuestion, text)
        }
    }

    func testDeleteChosenIsNotConfusedWithOtherCommandsOrText() {
        XCTAssertEqual(VoiceCommand.parse("soruyu sil"), .cancelQuestion, "Belirleyici yoksa okunan soru iptal edilir")
        XCTAssertEqual(VoiceCommand.parse("son soruyu sil"), .deleteLastQuestion)
        XCTAssertEqual(VoiceCommand.parse("son kaydı sil"), .deleteLastQuestion)
        for text in ["kayıt", "sil", "kayıt listesini sil bence", "başka soruyu oku", "Ali kaydı sil dedi", "kaydı tekrarla"] {
            XCTAssertNotEqual(VoiceCommand.parse(text), .deleteChosenQuestion, text)
        }
    }

    func testRenumberPhrases() {
        for text in ["soru numarası düzelt", "soru numarasını düzelt", "Soru numarası düzeltme", "numara düzeltme", "numarayı değiştir",
                     "numarayı düzelt", "lütfen soru numarasını değiştir", "soru numarasını güncelle"] {
            XCTAssertEqual(VoiceCommand.parse(text), .renumberQuestion, text)
        }
    }

    func testRenumberIsNotConfusedWithQuestionText() {
        for text in ["numara", "düzelt", "soru numarası kaç", "Ali numarayı değiştirdi ve gitti", "numarayı söyle"] {
            XCTAssertNotEqual(VoiceCommand.parse(text), .renumberQuestion, text)
        }
    }

    func testTheMessagesNameTheSectionWhenThereIsOne() {
        XCTAssertEqual(Say.confirmDeleteLast(7), "Soru 7 kaydı silinecek: cevabı ve ses kaydı kalmayacak. Emin misiniz? Silmek için evet, vazgeçmek için hayır deyin.")
        XCTAssertTrue(Say.confirmDeleteLast(7, section: 2).hasPrefix("İkinci bölümdeki soru 7 kaydı silinecek"))
        XCTAssertEqual(Say.questionRenumbered(from: 7, to: 8, section: 0, cameraNext: false), "7 olan soru numarası 8 olarak değiştirildi. Lütfen sonraki soruyu okuyun.")
        XCTAssertTrue(Say.questionRenumbered(from: 7, to: 8, section: 1, cameraNext: true).hasPrefix("Birinci bölümde 7 olan soru numarası 8 olarak değiştirildi."))
        XCTAssertTrue(Say.confirmRenumber(from: 7, to: 8, section: 0, overwrite: false).hasPrefix("Soru 7, soru 8 olarak değiştirilecek."))
        XCTAssertTrue(Say.confirmRenumber(from: 7, to: 8, section: 0, overwrite: true).contains("kayıtlı olan soru 8 silinecek"))
    }
}

@MainActor
final class NumberEditFlowTests: XCTestCase {
    private typealias T = SessionViewModel.Timing

    private func harness(plan: [Int] = []) -> SessionHarness {
        let h = SessionHarness()
        for (index, count) in plan.enumerated() {
            h.settings.setSection(index, on: true)
            h.settings.setSectionQuestions(index, count)
        }
        return h
    }

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

    private func files(_ h: SessionHarness, in folder: URL?) -> [String] {
        guard let folder = folder else { return [] }
        return AnswerLibrary(root: h.root).answerFiles(in: folder).map { $0.deletingPathExtension().lastPathComponent }
    }

    private func transcript(_ folder: URL?) -> String {
        guard let folder = folder else { return "" }
        return (try? String(contentsOf: folder.appendingPathComponent(AnswerLibrary.transcriptName), encoding: .utf8)) ?? ""
    }

    private func wait(_ h: SessionHarness, spoken: String, mode: ListenMode) async -> Bool {
        let ok = await waitUntil(45) { h.speaker.spoken.last == spoken && h.vm.listenMode == mode && h.vm.phase == .listening }
        XCTAssertTrue(ok, "Beklenen: \(spoken) / \(mode); duyulan: \(h.speaker.spoken.suffix(3)); kip \(h.vm.listenMode)")
        return ok
    }

    /// Üç cevaplı bölümsüz oturum
    private func threeAnswers() async -> SessionHarness {
        let h = harness()
        _ = await h.startListening()
        for number in 1...3 { await answerOne(h, number: number) }
        return h
    }

    // MARK: İstenen soruyu sil

    func testDeleteChosenAsksTheNumberThenConfirmsThenDeletesOnlyThatQuestion() async {
        let h = await threeAnswers()
        say(h, "kaydı sil")
        _ = await wait(h, spoken: Say.askDeleteNumber(section: 0), mode: .missingNumber)
        say(h, "iki")
        _ = await wait(h, spoken: Say.confirmDeleteLast(2, section: 0), mode: .confirmEnd)
        XCTAssertEqual(h.vm.answers.map { $0.number }, [1, 2, 3], "Onay gelmeden hiçbir şey silinmez")
        XCTAssertEqual(files(h, in: h.vm.sessionFolder), ["soru_1", "soru_2", "soru_3"])
        say(h, "evet")
        _ = await wait(h, spoken: Say.chosenQuestionDeleted(2, section: 0, reread: false, cameraNext: false), mode: .question)
        XCTAssertEqual(h.vm.answers.map { $0.number }, [1, 3])
        XCTAssertEqual(files(h, in: h.vm.sessionFolder), ["soru_1", "soru_3"], "Yalnız 2. sorunun ses dosyası silindi")
        let text = transcript(h.vm.sessionFolder)
        XCTAssertFalse(text.contains("Soru 2,"))
        XCTAssertTrue(text.contains("Soru 1,") && text.contains("Soru 3,"))
        XCTAssertFalse(h.vm.questions.contains { $0.number == 2 })
        XCTAssertEqual(h.vm.nextNumber, 4, "Eski bir soru silinince sıradaki numara değişmez")
        XCTAssertNil(h.vm.pendingDelete)
        XCTAssertNil(h.vm.numberEdit)
    }

    func testDeletingTheHighestQuestionLetsItBeReadAgain() async {
        let h = await threeAnswers()
        say(h, "kayıt sil")
        _ = await wait(h, spoken: Say.askDeleteNumber(section: 0), mode: .missingNumber)
        say(h, "üç")
        _ = await wait(h, spoken: Say.confirmDeleteLast(3, section: 0), mode: .confirmEnd)
        say(h, "evet")
        _ = await wait(h, spoken: Say.chosenQuestionDeleted(3, section: 0, reread: true, cameraNext: false), mode: .question)
        XCTAssertEqual(h.vm.nextNumber, 3)
    }

    func testNoKeepsEverything() async {
        let h = await threeAnswers()
        say(h, "kaydı sil")
        _ = await wait(h, spoken: Say.askDeleteNumber(section: 0), mode: .missingNumber)
        say(h, "iki")
        _ = await wait(h, spoken: Say.confirmDeleteLast(2, section: 0), mode: .confirmEnd)
        say(h, "hayır")
        _ = await wait(h, spoken: Say.deleteCancelled, mode: .question)
        XCTAssertEqual(h.vm.answers.map { $0.number }, [1, 2, 3])
        XCTAssertEqual(files(h, in: h.vm.sessionFolder), ["soru_1", "soru_2", "soru_3"])
        XCTAssertTrue(transcript(h.vm.sessionFolder).contains("Soru 2,"))
    }

    func testANumberWithoutARecordIsRejectedAndNothingIsDeleted() async {
        let h = await threeAnswers()
        say(h, "kaydı sil")
        _ = await wait(h, spoken: Say.askDeleteNumber(section: 0), mode: .missingNumber)
        say(h, "yedi")
        let again = Say.reask(Say.editAgain(Say.askDeleteNumber(section: 0), lead: "Soru 7 kayıtlı değil"), attempt: 2)
        _ = await wait(h, spoken: again, mode: .missingNumber)
        XCTAssertEqual(h.vm.answers.map { $0.number }, [1, 2, 3])
        XCTAssertNil(h.vm.pendingDelete)
    }

    func testMissingNumberIsAskedThreeTimesThenTheActionIsDropped() async {
        let h = await threeAnswers()
        say(h, "kaydı sil")
        _ = await wait(h, spoken: Say.askDeleteNumber(section: 0), mode: .missingNumber)
        h.scheduler.advance(by: SilenceWatchdog.limit + 0.1)
        _ = await wait(h, spoken: Say.reask(Say.editAgain(Say.askDeleteNumber(section: 0), lead: "Cevap vermediniz"), attempt: 2), mode: .missingNumber)
        h.scheduler.advance(by: SilenceWatchdog.limit + 0.1)
        let third = Say.reask(Say.editAgain(Say.askDeleteNumber(section: 0), lead: "Cevap vermediniz"), attempt: 3)
        _ = await wait(h, spoken: third, mode: .missingNumber)
        XCTAssertTrue(third.contains("üçüncü defa soruyorum"))
        h.scheduler.advance(by: SilenceWatchdog.limit + 0.1)
        _ = await wait(h, spoken: Say.editGivenUp, mode: .question)
        XCTAssertEqual(h.vm.answers.map { $0.number }, [1, 2, 3], "Hiçbir kayıt değişmedi")
        XCTAssertNil(h.vm.numberEdit)
    }

    func testCancelWhileTheNumberIsAskedChangesNothing() async {
        let h = await threeAnswers()
        say(h, "kaydı sil")
        _ = await wait(h, spoken: Say.askDeleteNumber(section: 0), mode: .missingNumber)
        say(h, "vazgeç")
        _ = await wait(h, spoken: Say.editCancelled, mode: .question)
        XCTAssertEqual(h.vm.answers.map { $0.number }, [1, 2, 3])
        XCTAssertNil(h.vm.numberEdit)
    }

    func testWithoutAnyRecordItSaysSo() async {
        let h = harness()
        _ = await h.startListening()
        say(h, "kaydı sil")
        _ = await wait(h, spoken: Say.nothingToEdit, mode: .question)
        say(h, "numarayı düzelt")
        _ = await wait(h, spoken: Say.nothingToEdit, mode: .question)
    }

    // MARK: Soru numarası düzelt

    func testRenumberAsksBothNumbersRepeatsThemAndChangesTheRecordAfterConfirmation() async {
        let h = await threeAnswers()
        say(h, "soru numarası düzelt")
        _ = await wait(h, spoken: Say.askRenumberFrom(section: 0), mode: .missingNumber)
        say(h, "iki")
        _ = await wait(h, spoken: Say.askRenumberTo(from: 2), mode: .missingNumber)
        say(h, "dört")
        _ = await wait(h, spoken: Say.confirmRenumber(from: 2, to: 4, section: 0, overwrite: false), mode: .confirmEnd)
        XCTAssertEqual(h.vm.answers.map { $0.number }, [1, 2, 3], "Onay gelmeden hiçbir şey değişmez")
        XCTAssertEqual(files(h, in: h.vm.sessionFolder), ["soru_1", "soru_2", "soru_3"])
        say(h, "evet")
        _ = await wait(h, spoken: Say.questionRenumbered(from: 2, to: 4, section: 0, cameraNext: false), mode: .question)
        XCTAssertEqual(h.vm.answers.map { $0.number }, [1, 3, 4])
        XCTAssertEqual(files(h, in: h.vm.sessionFolder), ["soru_1", "soru_3", "soru_4"], "Ses dosyası da yeni numarayla")
        let text = transcript(h.vm.sessionFolder)
        XCTAssertFalse(text.contains("Soru 2,"))
        XCTAssertTrue(text.contains("Soru 4,"))
        XCTAssertTrue(h.vm.questions.contains { $0.number == 4 })
        XCTAssertFalse(h.vm.questions.contains { $0.number == 2 })
        XCTAssertEqual(h.vm.nextNumber, 4, "Eski bir soru düzeltilince sıradaki numara değişmez")
        XCTAssertNil(h.vm.pendingRenumber)
    }

    func testRenumberingTheLastQuestionMovesTheNextNumberAlong() async {
        let h = await threeAnswers()
        say(h, "numarayı değiştir")
        _ = await wait(h, spoken: Say.askRenumberFrom(section: 0), mode: .missingNumber)
        say(h, "üç")
        _ = await wait(h, spoken: Say.askRenumberTo(from: 3), mode: .missingNumber)
        say(h, "beş")
        _ = await wait(h, spoken: Say.confirmRenumber(from: 3, to: 5, section: 0, overwrite: false), mode: .confirmEnd)
        say(h, "evet")
        _ = await wait(h, spoken: Say.questionRenumbered(from: 3, to: 5, section: 0, cameraNext: false), mode: .question)
        XCTAssertEqual(h.vm.nextNumber, 6)
    }

    func testRenumberToAnExistingNumberWarnsAndReplacesIt() async {
        let h = await threeAnswers()
        say(h, "soru numarasını düzelt")
        _ = await wait(h, spoken: Say.askRenumberFrom(section: 0), mode: .missingNumber)
        say(h, "üç")
        _ = await wait(h, spoken: Say.askRenumberTo(from: 3), mode: .missingNumber)
        say(h, "bir")
        _ = await wait(h, spoken: Say.confirmRenumber(from: 3, to: 1, section: 0, overwrite: true), mode: .confirmEnd)
        say(h, "evet")
        _ = await wait(h, spoken: Say.questionRenumbered(from: 3, to: 1, section: 0, cameraNext: false), mode: .question)
        XCTAssertEqual(h.vm.answers.map { $0.number }, [1, 2])
        XCTAssertEqual(files(h, in: h.vm.sessionFolder), ["soru_1", "soru_2"])
        let lines = transcript(h.vm.sessionFolder).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.filter { $0.hasPrefix("Soru 1,") }.count, 1, "Aynı numaralı iki satır kalmaz: \(lines)")
        XCTAssertFalse(lines.contains { $0.hasPrefix("Soru 3,") })
    }

    func testRenumberNoChangesNothing() async {
        let h = await threeAnswers()
        say(h, "numarayı düzelt")
        _ = await wait(h, spoken: Say.askRenumberFrom(section: 0), mode: .missingNumber)
        say(h, "iki")
        _ = await wait(h, spoken: Say.askRenumberTo(from: 2), mode: .missingNumber)
        say(h, "dört")
        _ = await wait(h, spoken: Say.confirmRenumber(from: 2, to: 4, section: 0, overwrite: false), mode: .confirmEnd)
        say(h, "hayır")
        _ = await wait(h, spoken: Say.renumberCancelled(cameraNext: false), mode: .question)
        XCTAssertEqual(h.vm.answers.map { $0.number }, [1, 2, 3])
        XCTAssertEqual(files(h, in: h.vm.sessionFolder), ["soru_1", "soru_2", "soru_3"])
        XCTAssertTrue(transcript(h.vm.sessionFolder).contains("Soru 2,"))
    }

    func testRenumberConfirmationAsksThreeTimesThenChangesNothing() async {
        let h = await threeAnswers()
        say(h, "numarayı düzelt")
        _ = await wait(h, spoken: Say.askRenumberFrom(section: 0), mode: .missingNumber)
        say(h, "iki")
        _ = await wait(h, spoken: Say.askRenumberTo(from: 2), mode: .missingNumber)
        say(h, "dört")
        _ = await wait(h, spoken: Say.confirmRenumber(from: 2, to: 4, section: 0, overwrite: false), mode: .confirmEnd)
        h.scheduler.advance(by: SilenceWatchdog.limit + 0.1)
        let again = Say.confirmRenumberAgain(from: 2, to: 4, section: 0)
        _ = await wait(h, spoken: again, mode: .confirmEnd)
        h.scheduler.advance(by: SilenceWatchdog.limit + 0.1)
        _ = await wait(h, spoken: Say.reask(again, attempt: 3), mode: .confirmEnd)
        h.scheduler.advance(by: SilenceWatchdog.limit + 0.1)
        _ = await wait(h, spoken: Say.renumberCancelled(cameraNext: false), mode: .question)
        XCTAssertEqual(h.vm.answers.map { $0.number }, [1, 2, 3], "Cevapsızlık hiçbir şeyi değiştirmez")
        XCTAssertEqual(files(h, in: h.vm.sessionFolder), ["soru_1", "soru_2", "soru_3"])
    }

    func testTheSameNewNumberIsRejected() async {
        let h = await threeAnswers()
        say(h, "numarayı düzelt")
        _ = await wait(h, spoken: Say.askRenumberFrom(section: 0), mode: .missingNumber)
        say(h, "iki")
        _ = await wait(h, spoken: Say.askRenumberTo(from: 2), mode: .missingNumber)
        say(h, "iki")
        let again = Say.reask(Say.editAgain(Say.askRenumberTo(from: 2), lead: "Yeni numara eski numarayla aynı: 2"), attempt: 2)
        _ = await wait(h, spoken: again, mode: .missingNumber)
        XCTAssertEqual(h.vm.answers.map { $0.number }, [1, 2, 3])
    }

    // MARK: Bölümler: işlem yalnız seçilen bölümde

    /// 1. bölümde 1 ve 2. sorular, 2. bölümde 1. soru cevaplanmış; şu an 2. bölümde
    private func twoSections(plan: [Int] = [3, 3]) async -> (SessionHarness, URL, URL) {
        let h = harness(plan: plan)
        _ = await h.startListening()
        await answerOne(h, number: 1)
        await answerOne(h, number: 2)
        let first = h.vm.sessionFolder!
        await h.vm.beginNextSection(prefix: "")
        _ = await waitUntil(45) { h.vm.sectionIndex == 2 && h.vm.listenMode == .question && h.vm.phase == .listening }
        await answerOne(h, number: 1)
        return (h, first, h.vm.sessionFolder!)
    }

    func testSectionOnlyDeleteNeverTouchesTheSameNumberInAnotherSection() async {
        let (h, first, second) = await twoSections()
        say(h, "kaydı sil")
        _ = await wait(h, spoken: Say.askWhichSection(current: 2), mode: .missingNumber)
        say(h, "bu bölüm")
        _ = await wait(h, spoken: Say.askDeleteNumber(section: 2), mode: .missingNumber)
        say(h, "bir")
        _ = await wait(h, spoken: Say.confirmDeleteLast(1, section: 2), mode: .confirmEnd)
        XCTAssertTrue(Say.confirmDeleteLast(1, section: 2).hasPrefix("İkinci bölümdeki soru 1"))
        say(h, "evet")
        _ = await wait(h, spoken: Say.chosenQuestionDeleted(1, section: 2, reread: true, cameraNext: false), mode: .question)
        XCTAssertEqual(files(h, in: second), [], "2. bölümün 1. sorusu silindi")
        XCTAssertEqual(files(h, in: first), ["soru_1", "soru_2"], "1. bölümün cevapları yerinde")
        XCTAssertTrue(transcript(first).contains("Soru 1,") && transcript(first).contains("Soru 2,"))
        XCTAssertTrue(h.vm.answers.isEmpty)
    }

    func testDeletingFromAnEarlierSectionTouchesOnlyThatSection() async {
        let (h, first, second) = await twoSections()
        say(h, "kaydı sil")
        _ = await wait(h, spoken: Say.askWhichSection(current: 2), mode: .missingNumber)
        say(h, "birinci bölüm")
        _ = await wait(h, spoken: Say.askDeleteNumber(section: 1), mode: .missingNumber)
        say(h, "iki")
        _ = await wait(h, spoken: Say.confirmDeleteLast(2, section: 1), mode: .confirmEnd)
        XCTAssertTrue(Say.confirmDeleteLast(2, section: 1).hasPrefix("Birinci bölümdeki soru 2"))
        say(h, "evet")
        _ = await wait(h, spoken: Say.chosenQuestionDeleted(2, section: 1, reread: false, cameraNext: false), mode: .question)
        XCTAssertEqual(files(h, in: first), ["soru_1"])
        XCTAssertFalse(transcript(first).contains("Soru 2,"))
        XCTAssertTrue(transcript(first).contains("Soru 1,"))
        XCTAssertEqual(files(h, in: second), ["soru_1"], "2. bölüm etkilenmedi")
        XCTAssertEqual(h.vm.answers.map { $0.number }, [1], "Şu anki bölümün cevapları etkilenmedi")
    }

    func testRenumberInAnEarlierSectionChangesOnlyThatSection() async {
        let (h, first, second) = await twoSections()
        say(h, "numarayı düzelt")
        _ = await wait(h, spoken: Say.askWhichSection(current: 2), mode: .missingNumber)
        say(h, "birinci")
        _ = await wait(h, spoken: Say.askRenumberFrom(section: 1), mode: .missingNumber)
        say(h, "iki")
        _ = await wait(h, spoken: Say.askRenumberTo(from: 2), mode: .missingNumber)
        say(h, "üç")
        _ = await wait(h, spoken: Say.confirmRenumber(from: 2, to: 3, section: 1, overwrite: false), mode: .confirmEnd)
        say(h, "evet")
        _ = await wait(h, spoken: Say.questionRenumbered(from: 2, to: 3, section: 1, cameraNext: false), mode: .question)
        XCTAssertEqual(files(h, in: first), ["soru_1", "soru_3"])
        XCTAssertTrue(transcript(first).contains("Soru 3,") && !transcript(first).contains("Soru 2,"))
        XCTAssertEqual(files(h, in: second), ["soru_1"])
        XCTAssertEqual(h.vm.answers.map { $0.number }, [1])
        XCTAssertEqual(h.vm.nextNumber, 2, "Şu anki bölümün sıradaki numarası değişmedi")
    }

    func testTheSectionIsNotAskedWhenOnlyTheCurrentSectionHasRecords() async {
        let h = harness(plan: [3, 3])
        _ = await h.startListening()
        await answerOne(h, number: 1)
        await answerOne(h, number: 2)
        say(h, "kaydı sil")
        _ = await wait(h, spoken: Say.askDeleteNumber(section: 1), mode: .missingNumber)
        XCTAssertTrue(Say.askDeleteNumber(section: 1).contains("birinci bölümdeki"), "Bölüm cümlede söylenir")
        say(h, "iki")
        _ = await wait(h, spoken: Say.confirmDeleteLast(2, section: 1), mode: .confirmEnd)
        say(h, "hayır")
        _ = await wait(h, spoken: Say.deleteCancelled, mode: .question)
        XCTAssertEqual(h.vm.answers.map { $0.number }, [1, 2])
    }

    func testASectionWithoutRecordsIsRejected() async {
        let (h, _, _) = await twoSections(plan: [3, 3, 3])
        say(h, "kaydı sil")
        _ = await wait(h, spoken: Say.askWhichSection(current: 2), mode: .missingNumber)
        say(h, "üçüncü")
        let again = Say.reask(Say.editAgain(Say.askWhichSection(current: 2), lead: "Üçüncü bölümde kayıtlı soru yok"), attempt: 2)
        _ = await wait(h, spoken: again, mode: .missingNumber)
        XCTAssertEqual(h.vm.answers.map { $0.number }, [1])
    }
}
