import XCTest
@testable import G526CameraDrive

/// Sınav bölümleri: ayarlarda etkin bölümler ve soru sayıları; "Bölümü tamamla" → cevaplar okunur → "Yeni bölüm mü, testi tamamlama mı?";
/// her bölümün cevapları ayrı klasörde (bolum_1, bolum_2…); bölümün soru sayısının üstündeki numara kabul edilmez.
final class SectionParsingTests: XCTestCase {
    func testSectionCommandWords() {
        for text in ["bölümü tamamla", "Bölümü bitir", "bu bölümü tamamlayalım", "bölümü bitirelim", "bölüm tamamlandı", "lütfen bölümü sonlandır"] {
            XCTAssertEqual(VoiceCommand.parse(text), .endSection, text)
        }
    }

    func testSectionCommandIsNotConfusedWithOtherCommandsOrQuestionText() {
        for text in ["bölümü tekrarla", "testi bölümü bitir", "bölümü iptal et", "bölümü bitirme", "bölüm", "bölge bitir",
                     "bölümü tamamla ve cevapları tekrarla"] {
            XCTAssertNotEqual(VoiceCommand.parse(text), .endSection, text)
        }
        XCTAssertEqual(VoiceCommand.parse("testi bitir"), .endTest)
        XCTAssertEqual(VoiceCommand.parse("sınavı bitirelim"), .endTest)
        XCTAssertTrue(VoiceCommand.endSection.isEnding)
        XCTAssertTrue(VoiceCommand.endTest.isEnding)
        XCTAssertFalse(VoiceCommand.replayAnswers.isEnding)
    }

    func testNextSectionAnswers() {
        for text in ["evet", "Evet, yeni bölüm", "yeni bölüm", "devam", "sonraki bölüme geçelim", "yeni bölüm istiyorum", "geçelim", "bitirme"] {
            XCTAssertEqual(SpokenReply.nextSection(text), .newSection, text)
        }
        for text in ["hayır", "testi tamamla", "testi bitir", "bitir", "tamamlayalım", "yeni bölüm istemiyorum", "testi bitirmek istiyorum"] {
            XCTAssertEqual(SpokenReply.nextSection(text), .finishTest, text)
        }
        for text in ["", "belki", "evet hayır", "bölümü tamamla", "hmm bilmem"] {
            XCTAssertNil(SpokenReply.nextSection(text), text)
        }
        XCTAssertEqual(SpokenReply.nextSection("testi tamamlamak istemiyorum"), .newSection, "Testi bitirmeyi reddetmek yeni bölümdür")
    }

    func testConfirmQuestionAcceptsTheSectionCommandAsYes() {
        XCTAssertEqual(SpokenReply.yesNo("bölümü tamamla"), .yes)
        XCTAssertEqual(SpokenReply.yesNo("evet"), .yes)
        XCTAssertEqual(SpokenReply.yesNo("hayır"), .no)
    }

    func testCompactListShortensLongRunsOfMissingNumbers() {
        XCTAssertEqual(Say.compactList([3]), "3")
        XCTAssertEqual(Say.compactList([2, 3]), "2 ve 3")
        XCTAssertEqual(Say.compactList([4, 5, 6]), "4, 5 ve 6")
        XCTAssertEqual(Say.compactList([4, 5, 6, 7]), "4 ile 7 arası")
        XCTAssertEqual(Say.compactList([1, 2, 3, 4, 5, 12, 31, 32, 33, 34, 35]), "1 ile 5 arası, 12 ve 31 ile 35 arası")
        XCTAssertEqual(Say.compactList([9, 3, 3]), "3 ve 9", "Sıralanır, yinelenenler atılır")
        XCTAssertEqual(Say.ordinal(1), "birinci")
        XCTAssertEqual(Say.ordinalCapital(2), "İkinci")
        XCTAssertEqual(Say.sectionStart(1, questions: 40), "Birinci bölüme başlıyorum. Bu bölümde 40 soru var.")
        XCTAssertEqual(Say.sectionStart(2, questions: 0), "İkinci bölüme başlıyorum.", "Soru sayısı girilmemişse söylenmez")
    }

    func testNumbersAboveTheLimitAreRejectedEverywhere() {
        XCTAssertEqual(SpokenNumber.extract(from: "Soru 40", limit: 40), 40)
        XCTAssertNil(SpokenNumber.extract(from: "Soru 41", limit: 40))
        XCTAssertNil(SpokenNumber.extract(from: "Soru 570", limit: 800), "Sınır ne olursa olsun 100'ün üstü kabul edilmez")
        XCTAssertNil(SpokenNumber.extract(from: "Soru 0"), "Sıfır numaralı soru yoktur")
        XCTAssertEqual(SpokenNumber.questionNumber(from: "yirmi beş", limit: 25), 25)
        XCTAssertNil(SpokenNumber.questionNumber(from: "yirmi altı", limit: 25))
        XCTAssertEqual(SpokenNumber.list(from: "5 6 7", limit: 6), [5, 6])
        XCTAssertEqual(SpokenNumber.list(from: "beşten yediye kadar", limit: 6), [5, 6])
    }
}

@MainActor
final class SectionSettingsTests: XCTestCase {
    private func settings(_ suite: String) -> (AppSettings, UserDefaults) {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (AppSettings(defaults: defaults), defaults)
    }

    func testNoSectionIsActiveByDefault() {
        let (s, _) = settings("g526.bolum.varsayilan")
        XCTAssertEqual(s.sectionPlan, [])
        XCTAssertEqual(s.sectionsOn, [false, false, false, false])
        XCTAssertEqual(s.sectionQuestions, [0, 0, 0, 0])
    }

    func testActiveSectionsRunInOrderWithTheirQuestionCounts() {
        let (s, _) = settings("g526.bolum.plan")
        s.setSection(0, on: true)
        s.setSectionQuestions(0, 40)
        s.setSectionQuestions(1, 10)   // etkin değil: plana girmez
        s.setSection(2, on: true)
        s.setSectionQuestions(2, 25)
        s.setSection(3, on: true)      // sayı girilmemiş: 0
        XCTAssertEqual(s.sectionPlan, [40, 25, 0])
    }

    func testQuestionCountsAreClampedAndPersisted() {
        let (s, defaults) = settings("g526.bolum.kalici")
        s.setSection(1, on: true)
        s.setSectionQuestions(1, 250)
        XCTAssertEqual(s.sectionQuestions[1], 100, "Hiçbir sınavda 100'den fazla soru yoktur")
        s.setSectionQuestions(1, -3)
        XCTAssertEqual(s.sectionQuestions[1], 0)
        s.setSectionQuestions(1, 35)
        s.setSection(3, on: true)
        s.setSectionQuestions(3, 20)
        let again = AppSettings(defaults: defaults)
        XCTAssertEqual(again.sectionsOn, [false, true, false, true])
        XCTAssertEqual(again.sectionQuestions, [0, 35, 0, 20])
        XCTAssertEqual(again.sectionPlan, [35, 20])
        s.setSection(9, on: true)   // geçersiz sıra: sessizce yok sayılır
        XCTAssertEqual(s.sectionsOn.count, 4)
    }
}

@MainActor
final class SectionFlowTests: XCTestCase {
    private typealias T = SessionViewModel.Timing

    /// Etkin bölümler: her biri için soru sayısı (örn. [3, 2]: 1. bölüm 3 soru, 2. bölüm 2 soru)
    private func harness(plan: [Int] = [3, 2], missingNumber: Bool = false) -> SessionHarness {
        let h = SessionHarness()
        h.settings.askMissingNumber = missingNumber
        for (index, count) in plan.enumerated() {
            h.settings.setSection(index, on: true)
            h.settings.setSectionQuestions(index, count)
        }
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

    private func finishReading(_ h: SessionHarness, files: Int) async {
        for index in 0..<files {
            h.player.finish()
            if index < files - 1 { h.scheduler.advance(by: 3.1) }
        }
        let asked = await waitUntil { h.vm.listenMode == .reviewMenu && h.vm.phase == .listening }
        XCTAssertTrue(asked, "Okuma sonrası menü sorulmadı: \(h.speaker.spoken)")
    }

    /// "Bölümü tamamla" → "evet" → cevaplar okunur → "Bitir"; yeni bölüm sorusu açılana kadar bekler
    private func completeTheSection(_ h: SessionHarness, answers: Int) async {
        say(h, "Bölümü tamamla")
        let confirming = await waitUntil(45) { h.vm.listenMode == .confirmEnd && h.vm.phase == .listening }
        XCTAssertTrue(confirming, "Onay sorulmadı: \(h.speaker.spoken)")
        say(h, "evet")
        let reading = await waitUntil(45) { h.vm.reviewing }
        XCTAssertTrue(reading, "Cevaplar okunmadı: \(h.speaker.spoken)")
        await finishReading(h, files: answers)
        say(h, "Bitir")
    }

    private func files(_ h: SessionHarness, in folder: URL?) -> [String] {
        guard let folder = folder else { return [] }
        return AnswerLibrary(root: h.root).answerFiles(in: folder).map { $0.deletingPathExtension().lastPathComponent }
    }

    // MARK: Başlangıç

    func testWithoutSectionsNothingChanges() async {
        let h = SessionHarness()
        _ = await h.startListening()
        XCTAssertEqual(h.vm.sectionIndex, 0)
        XCTAssertEqual(h.vm.sessionFolder, h.vm.examFolder, "Bölümsüz sınavda cevaplar doğrudan sınav klasörüne yazılır")
        XCTAssertTrue(h.speaker.spoken.contains(Say.ready), "Hazır anonsuna bölüm cümlesi eklenmez: \(h.speaker.spoken)")
        XCTAssertFalse(h.speaker.spoken.contains { $0.contains("bölüm") })
        XCTAssertEqual(h.journal.folder, h.vm.examFolder?.lastPathComponent)
    }

    func testTheExamFolderIsNamedByTheMomentAndTheFirstSectionStarts() async {
        let h = harness(plan: [3, 2])
        _ = await h.startListening()
        let name = AnswerLibrary.folderName(for: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(h.vm.examFolder?.lastPathComponent, name, "Sınav klasörünün adı tarih ve saattir")
        XCTAssertEqual(h.vm.sessionFolder?.lastPathComponent, "bolum_1")
        XCTAssertEqual(h.vm.sessionFolder?.deletingLastPathComponent(), h.vm.examFolder)
        XCTAssertEqual(h.vm.sectionIndex, 1)
        XCTAssertEqual(h.vm.sectionQuestionCount, 3)
        XCTAssertTrue(h.speaker.spoken.contains(Say.ready + " " + Say.sectionStart(1, questions: 3)), "\(h.speaker.spoken)")
        XCTAssertEqual(h.journal.folder, name + "@1", "Günlük sınav klasörünü ve bölümü saklar")
    }

    func testAnswersAreWrittenToTheSectionFolder() async {
        let h = harness(plan: [3, 2])
        _ = await h.startListening()
        await answerOne(h, number: 1)
        await answerOne(h, number: 2)
        XCTAssertEqual(files(h, in: h.vm.sessionFolder), ["soru_1", "soru_2"])
        XCTAssertEqual(files(h, in: h.vm.examFolder).count, 2, "Sınav klasörü bölüm klasörlerinin cevaplarını da sayar")
        let transcript = h.vm.sessionFolder?.appendingPathComponent(AnswerLibrary.transcriptName).path ?? ""
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcript), "cevaplar.txt de bölüm klasöründe")
    }

    // MARK: Bölümü tamamlama

    func testCompletingASectionReadsItsAnswersThenAsksAboutANewSectionAndStartsIt() async {
        let h = harness(plan: [3, 2])
        _ = await h.startListening()
        await answerOne(h, number: 1)
        await answerOne(h, number: 2)
        let section1 = h.vm.sessionFolder

        say(h, "Bölümü tamamla")
        let confirming = await waitUntil(45) { h.vm.listenMode == .confirmEnd && h.vm.phase == .listening }
        XCTAssertTrue(confirming, "\(h.speaker.spoken)")
        XCTAssertEqual(h.speaker.spoken.last, Say.confirmSectionEnd)
        say(h, "evet")
        let reading = await waitUntil(45) { h.vm.reviewing }
        XCTAssertTrue(reading, "\(h.speaker.spoken)")
        XCTAssertTrue(h.speaker.spoken.contains(Say.reviewStartSection(2)), "\(h.speaker.spoken)")
        await finishReading(h, files: 2)
        XCTAssertEqual(h.speaker.spoken.last, Say.reviewReport(count: 2, failed: 0) + " " + Say.reviewMenuSection)
        XCTAssertEqual(h.vm.phase, .listening)

        say(h, "Bitir")
        let asked = await waitUntil(45) { h.vm.listenMode == .nextSectionChoice && h.vm.phase == .listening }
        XCTAssertTrue(asked, "\(h.speaker.spoken)")
        XCTAssertEqual(h.speaker.spoken.last, Say.sectionCompleted(1, answers: 2, missing: [3]) + " " + Say.askNextSection(2),
                       "3 soruluk bölümde okunmayan 3. soru cevapsız sayılır")
        XCTAssertNotEqual(h.vm.phase, .finished, "Test bitmedi")

        say(h, "evet")
        let started = await waitUntil(45) { h.vm.sectionIndex == 2 && h.vm.listenMode == .question && h.vm.phase == .listening }
        XCTAssertTrue(started, "\(h.speaker.spoken)")
        XCTAssertEqual(h.speaker.spoken.last, Say.sectionStart(2, questions: 2) + " İlk soruyu okuyabilirsiniz.")
        XCTAssertEqual(h.vm.sessionFolder?.lastPathComponent, "bolum_2")
        XCTAssertEqual(h.vm.sessionFolder?.deletingLastPathComponent(), h.vm.examFolder, "Aynı sınav klasörü")
        XCTAssertEqual(h.vm.nextNumber, 1, "Numara her bölümde 1'den başlar")
        XCTAssertTrue(h.vm.answers.isEmpty)
        XCTAssertEqual(h.vm.sectionQuestionCount, 2)
        XCTAssertEqual(h.journal.folder, (h.vm.examFolder?.lastPathComponent ?? "") + "@2")
        XCTAssertEqual(h.journal.nextNumber, 1)

        // İkinci bölümün 1. sorusu birinci bölümün 1. sorusunu ezmez
        await answerOne(h, number: 1)
        XCTAssertEqual(files(h, in: section1), ["soru_1", "soru_2"], "1. bölümün cevapları yerinde")
        XCTAssertEqual(files(h, in: h.vm.sessionFolder), ["soru_1"])
        XCTAssertFalse(h.speaker.spoken.contains(Say.answerReplaced(1)), "Başka bölümün aynı numarası 'değiştirildi' sayılmaz")
        XCTAssertEqual(h.vm.statusNote, "")
    }

    func testAnsweringNoToTheNextSectionQuestionCompletesTheTestWithEachSectionsCount() async {
        let h = harness(plan: [3, 2])
        _ = await h.startListening()
        await answerOne(h, number: 1)
        await answerOne(h, number: 2)
        await completeTheSection(h, answers: 2)
        _ = await waitUntil(45) { h.vm.listenMode == .nextSectionChoice && h.vm.phase == .listening }
        say(h, "evet")
        _ = await waitUntil(45) { h.vm.sectionIndex == 2 && h.vm.listenMode == .question && h.vm.phase == .listening }
        await answerOne(h, number: 1)
        // 2. bölümü tamamla; 2. bölüm sonuncu: soru sorulmaz, test tamamlanır
        await completeTheSection(h, answers: 1)
        let ended = await waitUntil(45) { h.vm.phase == .finished }
        XCTAssertTrue(ended, "\(h.speaker.spoken)")
        XCTAssertEqual(h.speaker.spoken.last, Say.allSectionsDone + " " + Say.testCompletedSections([2, 1], current: 2, missing: [2]))
        XCTAssertEqual(h.vm.statusNote, "Test bitti. 1 cevap kaydedildi.")
    }

    func testSayingNoToANewSectionCompletesTheTestEarly() async {
        let h = harness(plan: [3, 2])
        _ = await h.startListening()
        await answerOne(h, number: 1)
        await completeTheSection(h, answers: 1)
        _ = await waitUntil(45) { h.vm.listenMode == .nextSectionChoice && h.vm.phase == .listening }
        say(h, "hayır")
        let ended = await waitUntil(45) { h.vm.phase == .finished }
        XCTAssertTrue(ended, "\(h.speaker.spoken)")
        XCTAssertEqual(h.speaker.spoken.last, Say.testCompletedSections([1], current: 1, missing: [2, 3]))
    }

    func testTheLastSectionCompletesTheTestWithoutAskingForAnotherOne() async {
        let h = harness(plan: [2])
        _ = await h.startListening()
        await answerOne(h, number: 1)
        await completeTheSection(h, answers: 1)
        let ended = await waitUntil(45) { h.vm.phase == .finished }
        XCTAssertTrue(ended, "\(h.speaker.spoken)")
        XCTAssertEqual(h.speaker.spoken.last, Say.testCompletedSections([1], current: 1, missing: [2]))
        XCTAssertFalse(h.speaker.spoken.contains { $0 == Say.askNextSection(2) })
    }

    func testUnansweredNewSectionQuestionIsAskedAgainThenTheNextSectionStarts() async {
        let h = harness(plan: [3, 2])
        _ = await h.startListening()
        await answerOne(h, number: 1)
        await completeTheSection(h, answers: 1)
        _ = await waitUntil(45) { h.vm.listenMode == .nextSectionChoice && h.vm.phase == .listening }
        h.scheduler.advance(by: SilenceWatchdog.limit + 0.1)
        let again = await waitUntil(45) { h.speaker.spoken.last == Say.askNextSectionAgain(2) && h.vm.listenMode == .nextSectionChoice && h.vm.phase == .listening }
        XCTAssertTrue(again, "\(h.speaker.spoken)")
        h.scheduler.advance(by: SilenceWatchdog.limit + 0.1)
        let third = await waitUntil(45) { h.speaker.spoken.last == Say.reask(Say.askNextSectionAgain(2), attempt: 3) && h.vm.listenMode == .nextSectionChoice && h.vm.phase == .listening }
        XCTAssertTrue(third, "Üçüncü defa sorulur: \(h.speaker.spoken)")
        h.scheduler.advance(by: SilenceWatchdog.limit + 0.1)
        let started = await waitUntil(45) { h.vm.sectionIndex == 2 && h.vm.listenMode == .question && h.vm.phase == .listening }
        XCTAssertTrue(started, "Cevap gelmezse test bitirilmez, yeni bölüme geçilir: \(h.speaker.spoken)")
        XCTAssertEqual(h.speaker.spoken.last, Say.nextSectionDefault + " " + Say.sectionStart(2, questions: 2) + " İlk soruyu okuyabilirsiniz.")
    }

    func testDecliningTheConfirmationKeepsTheSectionGoing() async {
        let h = harness(plan: [3])
        _ = await h.startListening()
        await answerOne(h, number: 1)
        say(h, "Bölümü tamamla")
        _ = await waitUntil(45) { h.vm.listenMode == .confirmEnd && h.vm.phase == .listening }
        say(h, "hayır")
        let back = await waitUntil(45) { h.vm.listenMode == .question && h.vm.phase == .listening && h.speaker.spoken.last == Say.sectionEndCancelled }
        XCTAssertTrue(back, "\(h.speaker.spoken)")
        XCTAssertEqual(h.vm.sectionIndex, 1)
        await answerOne(h, number: 2)
        XCTAssertEqual(h.vm.answers.map { $0.number }, [1, 2])
    }

    func testEndSectionOnAnExamWithoutSectionsSaysSo() async {
        let h = SessionHarness()
        _ = await h.startListening()
        say(h, "Bölümü tamamla")
        let said = await waitUntil(45) { h.speaker.spoken.last == Say.noSections && h.vm.listenMode == .question && h.vm.phase == .listening }
        XCTAssertTrue(said, "\(h.speaker.spoken)")
        XCTAssertNotEqual(h.vm.phase, .finished)
    }

    func testEndingTheWholeTestStillWorksInASectionedExam() async {
        let h = harness(plan: [3, 2])
        _ = await h.startListening()
        await answerOne(h, number: 1)
        say(h, "Testi bitir")
        _ = await waitUntil(45) { h.vm.listenMode == .confirmEnd && h.vm.phase == .listening }
        XCTAssertEqual(h.speaker.spoken.last, Say.confirmEnd)
        say(h, "evet")
        _ = await waitUntil(45) { h.vm.reviewing }
        await finishReading(h, files: 1)
        XCTAssertEqual(h.speaker.spoken.last, Say.reviewReport(count: 1, failed: 0) + " " + Say.reviewMenu, "Testi bitirme menüsü bölüm menüsü değildir")
        say(h, "Bitir")
        let ended = await waitUntil(45) { h.vm.phase == .finished }
        XCTAssertTrue(ended, "\(h.speaker.spoken)")
        XCTAssertEqual(h.speaker.spoken.last, Say.testCompletedSections([1], current: 1, missing: [2, 3]))
    }

    // MARK: Durum ve cevapsız sorular

    func testStatusAndMissingAnswersKnowTheSectionAndItsQuestionCount() async {
        let h = harness(plan: [5])
        _ = await h.startListening()
        await answerOne(h, number: 1)
        await answerOne(h, number: 3)
        XCTAssertEqual(h.vm.unansweredNumbers().missing, [2, 4, 5], "Soru sayısı biliniyorsa okunmayan son sorular da cevapsızdır")
        say(h, "cevapsız soruları söyle")
        let missing = await waitUntil(45) { h.speaker.spoken.last == Say.sectionMissing([2, 4, 5], questions: 5) }
        XCTAssertTrue(missing, "\(h.speaker.spoken)")
        say(h, "durum")
        let status = await waitUntil(45) { h.speaker.spoken.last?.hasPrefix(Say.sectionHere(1, questions: 5)) == true }
        XCTAssertTrue(status, "\(h.speaker.spoken)")
    }

    // MARK: Numara doğruluğu

    func testANumberAboveTheSectionCountIsNeverAccepted() async {
        let h = harness(plan: [3], missingNumber: true)
        h.answering.results = [.success(FakeAnswering.reply(2))]
        _ = await h.startListening()
        h.ask("Soru 45. Ali eve gitti ve okula yürüdü")
        let asking = await waitUntil(45) { h.vm.listenMode == .missingNumber && h.vm.phase == .listening }
        XCTAssertTrue(asking, "45, 3 soruluk bölümde yok: numara sorulur. \(h.speaker.spoken)")
        XCTAssertTrue(h.answering.calls.isEmpty)
        say(h, "dört", confirm: T.numberUnclear)
        let again = await waitUntil(45) { h.speaker.spoken.last == Say.askNumberAgainInSection(3) && h.vm.listenMode == .missingNumber && h.vm.phase == .listening }
        XCTAssertTrue(again, "\(h.speaker.spoken)")
        XCTAssertTrue(Say.askNumberAgainInSection(3).contains("1'den 3'e kadar"))
        XCTAssertTrue(h.answering.calls.isEmpty, "4 numarasıyla gönderilmez")
        say(h, "iki")
        let sent = await waitUntil(45) { h.answering.calls.count == 1 }
        XCTAssertTrue(sent)
        guard sent else { return }
        XCTAssertEqual(h.answering.calls[0].expectedNumber, 2)
    }

    func testASectionNumberInRangeIsReadFromTheQuestion() async {
        let h = harness(plan: [40])
        _ = await h.startListening()
        await answerOne(h, number: 40)
        XCTAssertEqual(h.vm.answers.map { $0.number }, [40])
    }

    // MARK: Kapanma sonrası devam

    func testRestartAfterAnEndedSectionedTestOffersTheSectionAndContinuesInIt() async {
        let h = harness(plan: [3, 2])
        _ = await h.startListening()
        await answerOne(h, number: 1)
        await answerOne(h, number: 2)
        await completeTheSection(h, answers: 2)
        _ = await waitUntil(45) { h.vm.listenMode == .nextSectionChoice && h.vm.phase == .listening }
        say(h, "evet")
        _ = await waitUntil(45) { h.vm.sectionIndex == 2 && h.vm.listenMode == .question && h.vm.phase == .listening }
        await answerOne(h, number: 1)
        let exam = h.vm.examFolder
        h.vm.endTest()
        XCTAssertEqual(h.vm.phase, .finished)

        _ = await h.startListening()
        XCTAssertEqual(h.vm.listenMode, .startChoice)
        XCTAssertEqual(h.speaker.spoken.last, Say.readyAskContinueSection(section: 2, answers: 1, next: 2), "Hangi bölümde kalındığı söylenir")
        say(h, "Devam")
        let on = await waitUntil(45) { h.vm.listenMode == .question && h.vm.phase == .listening && h.vm.sectionIndex == 2 }
        XCTAssertTrue(on, "\(h.speaker.spoken)")
        XCTAssertEqual(h.vm.examFolder, exam, "Aynı sınav klasörü")
        XCTAssertEqual(h.vm.sessionFolder?.lastPathComponent, "bolum_2")
        XCTAssertEqual(h.vm.nextNumber, 2)
        XCTAssertEqual(h.vm.answers.count, 1, "Yalnız bu bölümün cevapları yüklenir")
        XCTAssertTrue(h.speaker.spoken.last?.hasSuffix(Say.sectionHere(2, questions: 2)) == true, "\(h.speaker.spoken)")
    }

    func testChoosingANewExamStartsAFreshFolderAtTheFirstSection() async {
        let h = harness(plan: [3, 2])
        _ = await h.startListening()
        await answerOne(h, number: 1)
        let first = h.vm.examFolder
        h.vm.endTest()
        _ = await h.startListening()
        say(h, "Yeni sınav")
        let on = await waitUntil(45) { h.vm.listenMode == .question && h.vm.phase == .listening && h.vm.sectionIndex == 1 }
        XCTAssertTrue(on, "\(h.speaker.spoken)")
        XCTAssertNotEqual(h.vm.examFolder, first, "Eski sınavın cevaplarının üzerine yazılmaz")
        XCTAssertEqual(h.vm.sessionFolder?.lastPathComponent, "bolum_1")
        XCTAssertEqual(h.vm.nextNumber, 1)
        XCTAssertTrue(h.speaker.spoken.last?.hasSuffix(Say.sectionStart(1, questions: 3)) == true, "\(h.speaker.spoken)")
        XCTAssertEqual(files(h, in: first.map { $0.appendingPathComponent("bolum_1") }), ["soru_1"])
    }

    func testUnexpectedCloseResumesInTheSameSection() async {
        let h = harness(plan: [3, 2])
        let name = AnswerLibrary.folderName(for: Date(timeIntervalSince1970: 1_800_000_000))
        let section = h.root.appendingPathComponent(name, isDirectory: true).appendingPathComponent("bolum_2", isDirectory: true)
        try? FileManager.default.createDirectory(at: section, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: section.appendingPathComponent("soru_1.m4a").path, contents: Data([1]))
        h.journal.start = RunStart(exit: .unexpected(cause: "deneme"), pending: nil, nextNumber: 1, folder: name + "@2", downSeconds: 10, loop: false)
        h.vm.launched()
        _ = await waitUntil { h.vm.phase == .listening }
        XCTAssertEqual(h.vm.sectionIndex, 2)
        XCTAssertEqual(h.vm.sessionFolder?.lastPathComponent, "bolum_2", "Cevaplar yeni klasöre değil, kalınan bölüme yazılır")
        XCTAssertEqual(h.vm.nextNumber, 2, "Bölümde soru_1 varsa sıradaki numara 2")
        XCTAssertTrue(h.speaker.spoken.contains { $0.hasSuffix(Say.sectionHere(2, questions: 2)) }, "\(h.speaker.spoken)")
    }

    func testTheReplayAfterTheTestReadsEverySection() async {
        let h = harness(plan: [3, 2])
        _ = await h.startListening()
        await answerOne(h, number: 1)
        await completeTheSection(h, answers: 1)
        _ = await waitUntil(45) { h.vm.listenMode == .nextSectionChoice && h.vm.phase == .listening }
        say(h, "evet")
        _ = await waitUntil(45) { h.vm.sectionIndex == 2 && h.vm.listenMode == .question && h.vm.phase == .listening }
        await answerOne(h, number: 1)
        h.vm.endTest()
        let replay = AnswerLibrary(root: h.root).answerFiles(in: h.vm.replayFolder() ?? h.root)
        XCTAssertEqual(replay.map { $0.deletingLastPathComponent().lastPathComponent + "/" + $0.deletingPathExtension().lastPathComponent },
                       ["bolum_1/soru_1", "bolum_2/soru_1"], "Tekrar modu bütün bölümleri sırayla okur")
    }
}
