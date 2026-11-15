import XCTest
@testable import G526CameraDrive

/// Cevapları okuma: "cevapları tekrarla" her aşamada söylenebilir; okuma bitince kaç sorunun cevabının okunduğu söylenir ve
/// "Devam, Tekrar ya da Bitir" sorulur. Ayrıca tanıyıcının alternatif okumalarıyla anlama.
@MainActor
final class ReviewFlowTests: XCTestCase {
    private typealias T = SessionViewModel.Timing

    private func harness(missingNumber: Bool = false) -> SessionHarness {
        let h = SessionHarness()
        h.settings.askMissingNumber = missingNumber
        return h
    }

    private func answerOne(_ h: SessionHarness, number: Int) async {
        h.answering.results.append(.success(FakeAnswering.reply(number)))
        h.ask("Soru \(number). A seçeneği Adana")
        _ = await waitUntil { h.vm.answers.count == number && h.vm.phase == .listening }
    }

    private func say(_ h: SessionHarness, _ text: String, confirm: TimeInterval = T.numberConfirm) {
        h.listener.say(text)
        h.scheduler.advance(by: confirm + 0.1)
    }

    /// "Cevapları tekrarla" der; okuma başlayana kadar bekler
    private func startReading(_ h: SessionHarness, phrase: String = "Cevapları tekrarla") async {
        say(h, phrase)
        let reading = await waitUntil { h.vm.reviewing }
        XCTAssertTrue(reading, "Okuma başlamadı")
    }

    /// Çalan her dosyayı bitirir (aralar geçirilir); menü sorulana kadar bekler
    private func finishReading(_ h: SessionHarness, files: Int) async {
        for index in 0..<files {
            h.player.finish()
            if index < files - 1 { h.scheduler.advance(by: 3.1) }
        }
        let asked = await waitUntil { h.vm.listenMode == .reviewMenu && h.vm.phase == .listening }
        XCTAssertTrue(asked, "Okuma sonrası menü sorulmadı")
    }

    // MARK: Her aşamada "cevapları tekrarla"

    func testReplayCommandReadsAllAnswersReportsHowManyAndAsksWhatNext() async {
        let h = harness()
        _ = await h.startListening()
        await answerOne(h, number: 1)
        await answerOne(h, number: 2)
        await startReading(h)
        XCTAssertEqual(h.speaker.spoken.last, Say.reviewStart(2, ending: false))
        XCTAssertTrue(h.journal.sessionOpen, "Test sürüyor: oturum açık kalır, tekrar bir oturum sayılmaz")
        XCTAssertEqual(h.player.played.map { $0.lastPathComponent }, ["soru_1.m4a"])
        await finishReading(h, files: 2)
        XCTAssertEqual(h.player.played.map { $0.lastPathComponent }, ["soru_1.m4a", "soru_2.m4a"])
        XCTAssertEqual(h.speaker.spoken.last, Say.reviewReport(count: 2, failed: 0) + " " + Say.reviewMenu)
        XCTAssertTrue(h.vm.warnings.allSatisfy { $0.id != "tekrar" })
        XCTAssertEqual(h.answering.calls.count, 2, "Komut Gemini'ye gitmez")
    }

    func testMenuDevamGoesBackToTheTestAndAsksForTheNextQuestion() async {
        let h = harness()
        _ = await h.startListening()
        await answerOne(h, number: 1)
        await startReading(h)
        await finishReading(h, files: 1)
        say(h, "Devam")
        let back = await waitUntil { h.vm.listenMode == .question && h.vm.phase == .listening && h.speaker.spoken.last == Say.reviewBackToQuestion }
        XCTAssertTrue(back)
        await answerOne(h, number: 2)
        XCTAssertEqual(h.vm.answers.map { $0.number }, [1, 2], "Test kaldığı yerden sürer")
    }

    func testMenuTekrarReadsTheAnswersAgain() async {
        let h = harness()
        _ = await h.startListening()
        await answerOne(h, number: 1)
        await startReading(h)
        await finishReading(h, files: 1)
        say(h, "Tekrar")
        let again = await waitUntil { h.vm.reviewing && h.player.played.count == 2 }
        XCTAssertTrue(again)
        await finishReading(h, files: 1)
        XCTAssertEqual(h.speaker.spoken.last, Say.reviewReport(count: 1, failed: 0) + " " + Say.reviewMenu)
    }

    func testMenuBitirCompletesTheTest() async {
        let h = harness()
        _ = await h.startListening()
        await answerOne(h, number: 1)
        await answerOne(h, number: 2)
        await startReading(h)
        await finishReading(h, files: 2)
        say(h, "Testi bitir")
        let ended = await waitUntil { h.vm.phase == .finished }
        XCTAssertTrue(ended)
        XCTAssertEqual(h.speaker.spoken.last, Say.testCompleted(2))
        XCTAssertEqual(h.vm.statusNote, "Test bitti. 2 cevap kaydedildi.")
    }

    func testUnclearMenuAnswerIsAskedAgainAndShowsWhatWasHeard() async {
        let h = harness()
        _ = await h.startListening()
        await answerOne(h, number: 1)
        await startReading(h)
        await finishReading(h, files: 1)
        say(h, "hmm bilmem", confirm: T.triggerConfirm)
        h.scheduler.advance(by: T.numberUnclear)
        let again = await waitUntil { h.speaker.spoken.last == Say.reviewMenuAgain && h.vm.listenMode == .reviewMenu && h.vm.phase == .listening }
        XCTAssertTrue(again)
        XCTAssertTrue(h.vm.warnings.contains { $0.id == "duyulan" && $0.text.contains("hmm bilmem") })
    }

    func testNoAnswerAfterAReplayRequestKeepsTheTestGoing() async {
        let h = harness()
        _ = await h.startListening()
        await answerOne(h, number: 1)
        await startReading(h)
        await finishReading(h, files: 1)
        h.scheduler.advance(by: SilenceWatchdog.limit + 0.1)
        let again = await waitUntil { h.speaker.spoken.last == Say.reviewMenuAgain && h.vm.listenMode == .reviewMenu && h.vm.phase == .listening }
        XCTAssertTrue(again, "Önce bir kez hatırlatılır")
        h.scheduler.advance(by: SilenceWatchdog.limit + 0.1)
        let back = await waitUntil { h.vm.listenMode == .question && h.vm.phase == .listening && h.speaker.spoken.last == Say.reviewNoAnswer + " " + Say.reviewBackToQuestion }
        XCTAssertTrue(back, "Yalnız tekrar istendiyse sessizlikte test devam eder")
    }

    func testReplayCommandWithNoAnswersSaysSoAndKeepsTheTestGoing() async {
        let h = harness()
        _ = await h.startListening()
        say(h, "Cevapları tekrarla")
        let said = await waitUntil { h.vm.listenMode == .question && h.vm.phase == .listening && h.speaker.spoken.last == Say.nothingToReplay + " " + Say.reviewBackToQuestion }
        XCTAssertTrue(said)
        XCTAssertTrue(h.player.played.isEmpty)
    }

    // MARK: Testi bitirme isteğiyle

    private func confirmEnd(_ h: SessionHarness) async {
        say(h, "Testi bitir")
        _ = await waitUntil { h.vm.listenMode == .confirmEnd && h.vm.phase == .listening }
        say(h, "Evet")
    }

    func testNoAnswerAfterAnEndRequestCompletesTheTest() async {
        let h = harness()
        _ = await h.startListening()
        await answerOne(h, number: 1)
        await confirmEnd(h)
        let reading = await waitUntil { h.vm.reviewing }
        XCTAssertTrue(reading)
        XCTAssertEqual(h.vm.phase, .speaking, "Test henüz bitmedi")
        await finishReading(h, files: 1)
        h.scheduler.advance(by: SilenceWatchdog.limit + 0.1)
        _ = await waitUntil { h.speaker.spoken.last == Say.reviewMenuAgain && h.vm.listenMode == .reviewMenu && h.vm.phase == .listening }
        h.scheduler.advance(by: SilenceWatchdog.limit + 0.1)
        let ended = await waitUntil { h.vm.phase == .finished }
        XCTAssertTrue(ended, "Bitirme istenmişti: sessizlikte test tamamlanır")
        XCTAssertEqual(h.speaker.spoken.last, Say.reviewNoAnswer + " " + Say.testCompleted(1))
    }

    func testAfterAnEndRequestTheUserCanStillContinueTheTest() async {
        let h = harness()
        _ = await h.startListening()
        await answerOne(h, number: 1)
        await confirmEnd(h)
        _ = await waitUntil { h.vm.reviewing }
        await finishReading(h, files: 1)
        say(h, "Teste devam edelim")
        let back = await waitUntil { h.vm.listenMode == .question && h.vm.phase == .listening && h.speaker.spoken.last == Say.reviewBackToQuestion }
        XCTAssertTrue(back)
        XCTAssertTrue(h.vm.phase.isRunning)
    }

    func testReplayCanAlsoBeAskedWhileTheEndConfirmationIsWaiting() async {
        let h = harness()
        _ = await h.startListening()
        await answerOne(h, number: 1)
        say(h, "Testi bitir")
        _ = await waitUntil { h.vm.listenMode == .confirmEnd && h.vm.phase == .listening }
        say(h, "Cevapları tekrar oku")
        let reading = await waitUntil { h.vm.reviewing }
        XCTAssertTrue(reading, "Onay beklerken de cevaplar okutulabilir")
        await finishReading(h, files: 1)
        say(h, "Devam")
        let back = await waitUntil { h.vm.listenMode == .question && h.vm.phase == .listening }
        XCTAssertTrue(back, "Test bitmedi; devam edilir")
        XCTAssertNotEqual(h.vm.phase, .finished)
    }

    // MARK: Numara ve paragraf numarası beklerken

    func testReplayWhileWaitingForAQuestionNumberReturnsToThatQuestion() async {
        let h = harness(missingNumber: true)
        _ = await h.startListening()
        await answerOne(h, number: 1)
        h.answering.results.append(.success(FakeAnswering.reply(7)))
        h.ask("Bir soru metni A B C")
        _ = await waitUntil { h.vm.listenMode == .missingNumber && h.vm.phase == .listening }
        await startReading(h)
        await finishReading(h, files: 1)
        say(h, "Devam")
        let back = await waitUntil { h.vm.listenMode == .missingNumber && h.vm.phase == .listening && h.speaker.spoken.last == Say.reviewBackToNumber }
        XCTAssertTrue(back, "Okunan soru kaybolmaz: numarası yeniden sorulur")
        XCTAssertNotNil(h.vm.heldQuestion)
        say(h, "soru yedi")
        let sent = await waitUntil { h.answering.calls.count == 2 }
        XCTAssertTrue(sent)
        guard sent else { return }
        XCTAssertEqual(h.answering.calls[1].question, "Soru 7. Bir soru metni A B C")
    }

    func testReplayWhileWaitingForParagraphTargetsReturnsToTheTargets() async {
        let h = harness()
        _ = await h.startListening()
        await answerOne(h, number: 1)
        say(h, "Ortak paragraf Ali eve gitti. Sonra okula yürüdü Tamamlandı")
        _ = await waitUntil { h.vm.listenMode == .passageTargets && h.vm.phase == .listening }
        await startReading(h)
        await finishReading(h, files: 1)
        say(h, "Devam")
        let back = await waitUntil { h.vm.listenMode == .passageTargets && h.vm.phase == .listening && h.speaker.spoken.last == Say.reviewBackToTargets }
        XCTAssertTrue(back)
        XCTAssertNotNil(h.vm.passageDraft, "Alınan paragraf kaybolmaz")
        say(h, "beş altı yedi Tamam")
        let saved = await waitUntil { h.vm.passage?.all == [5, 6, 7] && h.vm.listenMode == .question }
        XCTAssertTrue(saved)
    }

    // MARK: Kesinti ve gözcü

    func testHardwareLossWhileReadingStopsThePlaybackAndAsksTheMenuAfterRecovery() async {
        let h = harness()
        _ = await h.startListening()
        await answerOne(h, number: 1)
        await startReading(h)
        let stopsBefore = h.player.stopCalls
        h.route.change(to: FakeRoute.noHeadphones)
        let paused = await waitUntil { h.isHardwarePause }
        XCTAssertTrue(paused)
        XCTAssertFalse(h.vm.reviewing, "Okuma bırakıldı")
        XCTAssertGreaterThan(h.player.stopCalls, stopsBefore, "Çalan dosya susturuldu")
        h.route.change(to: FakeRoute.good)
        h.scheduler.advance(by: T.routeStable + 0.1)
        let back = await waitUntil { h.vm.listenMode == .reviewMenu && h.vm.phase == .listening }
        XCTAssertTrue(back, "Kesinti bitince menü yeniden sorulur")
        XCTAssertEqual(h.speaker.spoken.last, Say.reviewResume)
    }

    func testAFailedPlaybackIsReportedAndStillAsksWhatToDo() async {
        let h = harness()
        _ = await h.startListening()
        await answerOne(h, number: 1)
        await startReading(h)
        h.player.finish(false)
        let asked = await waitUntil { h.vm.listenMode == .reviewMenu && h.vm.phase == .listening }
        XCTAssertTrue(asked)
        XCTAssertEqual(h.speaker.spoken.last, Say.reviewReport(count: 1, failed: 1) + " " + Say.reviewMenu)
    }

    func testLongReadingIsNotMistakenForAStuckSession() async {
        let h = harness()
        _ = await h.startListening()
        await answerOne(h, number: 1)
        await answerOne(h, number: 2)
        await startReading(h)
        h.vm.watchedTicks = 100_000   // gözcü sınırını çoktan aşmış gibi
        h.player.finish()             // ilerleme var: ikinci cevaba geçilir
        XCTAssertEqual(h.vm.watchedTicks, 0, "Her cevapta gözcü sayacı sıfırlanır")
    }

    // MARK: Tanıyıcının alternatif okumaları

    func testAnAlternativeReadingCompletesAnUnclearYesNoAnswer() async {
        let h = harness()
        _ = await h.startListening()
        say(h, "Testi bitir")
        _ = await waitUntil { h.vm.listenMode == .confirmEnd && h.vm.phase == .listening }
        h.listener.onEvent?(.alternatives([["hayat", "hayır"]]))
        say(h, "hayat")
        let back = await waitUntil { h.vm.listenMode == .question && h.vm.phase == .listening && h.speaker.spoken.last == Say.endCancelled }
        XCTAssertTrue(back, "En iyi okuma anlaşılmadı, alternatifi 'hayır' anlaşıldı")
    }

    func testAlternativesNeverOverrideAClearBestReading() async {
        let h = harness()
        _ = await h.startListening()
        say(h, "Testi bitir")
        _ = await waitUntil { h.vm.listenMode == .confirmEnd && h.vm.phase == .listening }
        h.listener.onEvent?(.alternatives([["evet", "hayır"]]))
        say(h, "evet")
        let reading = await waitUntil { h.vm.phase != .listening }
        XCTAssertTrue(reading, "'evet' anlaşıldı; alternatif 'hayır' dikkate alınmaz")
        XCTAssertNotEqual(h.speaker.spoken.last, Say.endCancelled)
    }

    func testAnAlternativeCanAddAMissedNumberToTheParagraphTargets() async {
        let h = harness()
        _ = await h.startListening()
        say(h, "Ortak paragraf Ali eve gitti. Sonra okula yürüdü Tamamlandı")
        _ = await waitUntil { h.vm.listenMode == .passageTargets && h.vm.phase == .listening }
        h.listener.onEvent?(.alternatives([["beş"], ["alt", "altı"], ["ı"], ["yedi"], ["Tamam"]]))
        say(h, "beş alt ı yedi Tamam")
        let saved = await waitUntil { h.vm.passage != nil && h.vm.listenMode == .question }
        XCTAssertTrue(saved)
        XCTAssertEqual(h.vm.passage?.all, [5, 6, 7], "Kaçırılan 6 alternatif okumadan tamamlandı")
    }

    func testAlternativesNeverRemoveNumbersTheBestReadingHeard() async {
        let h = harness()
        _ = await h.startListening()
        say(h, "Ortak paragraf Ali eve gitti. Sonra okula yürüdü Tamamlandı")
        _ = await waitUntil { h.vm.listenMode == .passageTargets && h.vm.phase == .listening }
        h.listener.onEvent?(.alternatives([["beş", "iki"], ["altı"], ["yedi"], ["Tamam"]]))
        say(h, "beş altı yedi Tamam")
        let saved = await waitUntil { h.vm.passage != nil && h.vm.listenMode == .question }
        XCTAssertTrue(saved)
        XCTAssertEqual(h.vm.passage?.all, [5, 6, 7])
    }

    func testSimilarSoundingNumbersAreAcceptedForParagraphTargetsAndMissingNumbers() async {
        let h = harness(missingNumber: true)
        h.answering.results = [.success(FakeAnswering.reply(5))]
        _ = await h.startListening()
        say(h, "Ortak paragraf Ali eve gitti. Sonra okula yürüdü Tamamlandı")
        _ = await waitUntil { h.vm.listenMode == .passageTargets && h.vm.phase == .listening }
        say(h, "peş altı yeti Tamam")
        // Dinleme yeniden açılmadan söylenen söz kaybolur: soru, dinleme açıldıktan sonra okunur
        let saved = await waitUntil { h.vm.phase == .listening && h.vm.listenMode == .question && h.vm.passage != nil }
        XCTAssertTrue(saved)
        XCTAssertEqual(h.vm.passage?.all, [5, 6, 7], "'peş' ve 'yeti' beş ve yedi olarak anlaşıldı")
        h.ask("Bir soru metni A B C")
        let asking = await waitUntil { h.vm.listenMode == .missingNumber && h.vm.phase == .listening }
        XCTAssertTrue(asking, "Numara istenmedi")
        say(h, "peş")
        let sent = await waitUntil { h.answering.calls.count == 1 }
        XCTAssertTrue(sent)
        guard sent else { return }
        XCTAssertEqual(h.answering.calls[0].expectedNumber, 5)
    }

    // MARK: Makul olmayan numara ("beş" → "570")

    private func holdAQuestion(_ h: SessionHarness) async {
        h.ask("Ali eve gitti ve okula yürüdü")
        let asking = await waitUntil(45) { h.vm.listenMode == .missingNumber && h.vm.phase == .listening }
        XCTAssertTrue(asking, "Numara sorulmadı: \(h.speaker.spoken)")
    }

    /// Cihaz günlüğü (22:09): "beş" denince tanıyıcı önce "500 Euro", sonra "570" yazdı; program 570'i kaydetti. Soru sayısının çok üstündeki
    /// sayı numara sayılmaz; tanıyıcının alternatif okuması ("beş") varsa o kullanılır.
    func testAnImplausibleBestReadingFallsBackToTheAlternativeReading() async {
        let h = harness(missingNumber: true)
        h.answering.results = [.success(FakeAnswering.reply(5))]
        _ = await h.startListening()
        await holdAQuestion(h)
        h.listener.onEvent?(.alternatives([["570", "beş"]]))
        say(h, "570")
        let sent = await waitUntil(45) { h.answering.calls.count == 1 }
        XCTAssertTrue(sent, "\(h.speaker.spoken)")
        guard sent else { return }
        XCTAssertEqual(h.answering.calls[0].expectedNumber, 5, "570 değil, alternatif okumadaki 5 kaydedilir")
    }

    /// Alternatif de yoksa yanlış numara kaydedilmez: numara yeniden sorulur, soru bekler
    func testAnImplausibleNumberWithoutAnAlternativeIsAskedAgainInsteadOfBeingSaved() async {
        let h = harness(missingNumber: true)
        _ = await h.startListening()
        await holdAQuestion(h)
        say(h, "570", confirm: T.numberUnclear)
        let again = await waitUntil(45) { h.speaker.spoken.last == Say.askNumberAgain && h.vm.listenMode == .missingNumber && h.vm.phase == .listening }
        XCTAssertTrue(again, "\(h.speaker.spoken)")
        XCTAssertTrue(h.answering.calls.isEmpty, "570 numarasıyla gönderilmez")
        XCTAssertNotNil(h.vm.heldQuestion, "Soru numarası söylenene kadar bekler")
        say(h, "beş")
        let sent = await waitUntil(45) { h.answering.calls.count == 1 }
        XCTAssertTrue(sent)
        guard sent else { return }
        XCTAssertEqual(h.answering.calls[0].expectedNumber, 5)
    }
}
