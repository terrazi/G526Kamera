import XCTest
@testable import G526CameraDrive

/// Okuma komutları ve kesinti: soru Gemini'ye gidince bilgi, eksik soru numarası, ortak paragraf, kesintiden sonra kaldığı yerden devam
@MainActor
final class ReadingFlowTests: XCTestCase {
    private typealias Timing = SessionViewModel.Timing

    private func harness(number: Bool = false, progress: Bool = false, resume: Bool = false) -> SessionHarness {
        let h = SessionHarness()
        h.settings.askMissingNumber = number
        h.settings.spokenProgress = progress
        h.settings.smartResume = resume
        return h
    }

    /// Kullanıcı bir şey söyler ve "tetikleyici sabit kalır"
    private func say(_ h: SessionHarness, _ text: String, confirm: TimeInterval = Timing.triggerConfirm) {
        h.listener.say(text)
        h.scheduler.advance(by: confirm + 0.1)
    }

    private func answered(_ number: Int) -> String {
        return FakeAnswering.reply(number).spoken
    }

    // MARK: "Soru başarıyla alınıp gönderildi"

    func testQuestionSentIsAnnouncedAfterCevapla() async {
        let h = harness(progress: true)
        h.answering.results = [.success(FakeAnswering.reply(3))]
        h.answering.hold = true
        _ = await h.startListening()
        h.ask("Soru 3 bir soru")
        let said = await waitUntil { h.vm.announced.contains(Say.questionSent) && h.answering.calls.count == 1 }
        XCTAssertTrue(said)
        XCTAssertEqual(h.vm.phase, .answering, "Anons cevap beklemeyi bozmaz")
        await settle()
        h.answering.hold = false
        h.answering.release()
        let done = await waitUntil { h.speaker.spoken.last == self.answered(3) && h.vm.phase == .listening }
        XCTAssertTrue(done, "Cevap, anons bittikten sonra okunur")
        XCTAssertFalse(h.speaker.spoken.contains(Say.questionSent), "Anons cevap akışına karışmaz")
    }

    func testNoAnnouncementWhenProgressIsOff() async {
        let h = harness(progress: false)
        h.answering.results = [.success(FakeAnswering.reply(3))]
        _ = await h.startListening()
        h.ask("Soru 3 bir soru")
        let done = await waitUntil { h.speaker.spoken.last == self.answered(3) && h.vm.phase == .listening }
        XCTAssertTrue(done)
        XCTAssertFalse(h.vm.announced.contains(Say.questionSent))
    }

    func testStillWaitingCueRepeatsAndWaitIsGivenUpAfterThreeMinutes() async {
        let h = harness(progress: true)
        h.answering.hold = true
        _ = await h.startListening()
        h.ask("Soru 3 bir soru")
        let sent = await waitUntil { h.answering.calls.count == 1 }
        XCTAssertTrue(sent)
        await settle()
        h.scheduler.advance(by: Timing.answerCueEvery + 0.1)
        let cue = await waitUntil { h.vm.announced.contains(Say.stillWaiting) }
        XCTAssertTrue(cue, "30 saniyede cevap gelmediyse 'cevap bekleniyor' denir")
        XCTAssertEqual(h.vm.phase, .answering)

        h.scheduler.advance(by: Timing.answerCap)
        let gaveUp = await waitUntil { h.speaker.spoken.last == Say.geminiSlow && h.vm.phase == .listening }
        XCTAssertTrue(gaveUp, "3 dakikada cevap gelmezse durum söylenir ve dinlemeye dönülür")
        XCTAssertEqual(h.vm.questions.last?.state, .failed("Gemini cevap vermedi; soruyu yeniden okuyun."))
        XCTAssertFalse(h.vm.warnings.isEmpty)
        XCTAssertNil(h.journal.pending, "Yarım kalan iş kalmaz")
        h.answering.hold = false
        h.answering.release()   // iptal edilen istek sonradan dönse de oturumu bozmaz
        await settle()
        XCTAssertEqual(h.vm.phase, .listening)
        XCTAssertTrue(h.shortcuts.runs.isEmpty, "Bekleme sınırı onarım başlatmaz")
    }

    func testCueStopsOnceAnswerArrives() async {
        let h = harness(progress: true)
        h.answering.results = [.success(FakeAnswering.reply(2))]
        _ = await h.startListening()
        h.ask("Soru 2 bir soru")
        let done = await waitUntil { h.speaker.spoken.last == self.answered(2) && h.vm.phase == .listening }
        XCTAssertTrue(done)
        h.scheduler.advance(by: 200)
        await settle()
        XCTAssertFalse(h.vm.announced.contains(Say.stillWaiting))
        XCTAssertNotEqual(h.speaker.spoken.last, Say.geminiSlow)
    }

    // MARK: Eksik soru numarası

    func testMissingNumberIsAskedAndWrittenAtTheStart() async {
        let h = harness(number: true)
        h.answering.results = [.success(FakeAnswering.reply(7))]
        _ = await h.startListening()
        h.ask("Bir soru metni A B C")
        let asking = await waitUntil { h.vm.phase == .listening && h.vm.listenMode == .missingNumber }
        XCTAssertTrue(asking)
        XCTAssertEqual(h.speaker.spoken.last, Say.askNumber)
        XCTAssertTrue(h.answering.calls.isEmpty, "Numara söylenene kadar soru gitmez")

        say(h, "soru yedi", confirm: Timing.numberConfirm)
        let sent = await waitUntil { h.answering.calls.count == 1 }
        XCTAssertTrue(sent)
        XCTAssertEqual(h.answering.calls[0].question, "Soru 7. Bir soru metni A B C")
        XCTAssertEqual(h.answering.calls[0].expectedNumber, 7)
        let done = await waitUntil { h.speaker.spoken.last == self.answered(7) && h.vm.phase == .listening }
        XCTAssertTrue(done)
        XCTAssertEqual(h.vm.listenMode, .question)
        XCTAssertEqual(h.vm.answers.map { $0.number }, [7])
    }

    func testSequenceWordGivesTheNextNumber() async {
        let h = harness(number: true)
        h.answering.results = [.success(FakeAnswering.reply(1))]
        _ = await h.startListening()
        h.ask("Bir soru metni")
        let asking = await waitUntil { h.vm.listenMode == .missingNumber && h.vm.phase == .listening }
        XCTAssertTrue(asking)
        say(h, "sıradaki", confirm: Timing.numberConfirm)
        let sent = await waitUntil { h.answering.calls.count == 1 }
        XCTAssertTrue(sent)
        XCTAssertEqual(h.answering.calls[0].question, "Soru 1. Bir soru metni")
        XCTAssertEqual(h.answering.calls[0].expectedNumber, 1)
    }

    func testSpokenNumberInTheQuestionIsNotAskedAgain() async {
        let h = harness(number: true)
        h.answering.results = [.success(FakeAnswering.reply(4))]
        _ = await h.startListening()
        h.ask("Soru 4 bir soru metni")
        let done = await waitUntil { h.speaker.spoken.last == self.answered(4) && h.vm.phase == .listening }
        XCTAssertTrue(done)
        XCTAssertFalse(h.speaker.spoken.contains(Say.askNumber))
        XCTAssertEqual(h.answering.calls[0].question, "Soru 4 bir soru metni", "Numara zaten okunmuşsa metne dokunulmaz")
    }

    func testSilenceRemindsTwiceThenSendsWithTheNextNumber() async {
        let h = harness(number: true)
        h.answering.results = [.success(FakeAnswering.reply(1))]
        _ = await h.startListening()
        h.ask("Bir soru metni")
        var asking = await waitUntil { h.vm.listenMode == .missingNumber && h.vm.phase == .listening }
        XCTAssertTrue(asking)
        for round in 1...Timing.numberReminderLimit {
            h.scheduler.advance(by: SilenceWatchdog.limit + 0.1)
            asking = await waitUntil { h.speaker.spoken.last == Say.askNumberAgain && h.vm.phase == .listening && h.speaker.spoken.filter { $0 == Say.askNumberAgain }.count == round }
            XCTAssertTrue(asking, "\(round). hatırlatma")
        }
        XCTAssertTrue(h.answering.calls.isEmpty)
        h.scheduler.advance(by: SilenceWatchdog.limit + 0.1)
        let sent = await waitUntil { h.answering.calls.count == 1 }
        XCTAssertTrue(sent, "Numara hiç söylenmezse soru kaybolmaz: sıradaki numarayla gider")
        XCTAssertEqual(h.answering.calls[0].question, "Bir soru metni")
        let done = await waitUntil { h.vm.phase == .listening && h.speaker.spoken.last == self.answered(1) }
        XCTAssertTrue(done)
    }

    func testNumberIsNotAskedWhenTheSettingIsOff() async {
        let h = harness(number: false)
        h.answering.results = [.success(FakeAnswering.reply(1))]
        _ = await h.startListening()
        h.ask("Bir soru metni")
        let done = await waitUntil { h.speaker.spoken.last == self.answered(1) && h.vm.phase == .listening }
        XCTAssertTrue(done)
        XCTAssertFalse(h.speaker.spoken.contains(Say.askNumber))
    }

    // MARK: Ortak paragraf

    private func savePassage(_ h: SessionHarness, targets: String = "beş altı yedi", closer: String = "Tamam") async {
        say(h, "Ortak paragraf Ali eve gitti. Sonra okula yürüdü Tamamlandı")
        let asked = await waitUntil { h.vm.phase == .listening && h.vm.listenMode == .passageTargets }
        XCTAssertTrue(asked)
        XCTAssertEqual(h.speaker.spoken.last, Say.passageTaken, "Paragraf metni alındı denir")
        say(h, targets + " " + closer)
        let saved = await waitUntil { h.vm.phase == .listening && h.vm.listenMode == .question && h.vm.passage != nil }
        XCTAssertTrue(saved)
    }

    func testPassageTargetsAreClosedWithTamamAndNothingGoesToGemini() async {
        let h = harness()
        _ = await h.startListening()
        await savePassage(h, targets: "beş altı yedi", closer: "Tamam")
        XCTAssertEqual(h.vm.passage?.all, [5, 6, 7])
        XCTAssertTrue(h.answering.calls.isEmpty, "Paragraf kaydedilir, Gemini'ye bir şey gitmez")
    }

    func testPassageTargetsAcceptDigitsAndQuestionWords() async {
        for targets in ["5, 6, 7", "5. soru, 6. soru, 7. soru", "beşinci soru, altıncı soru, yedinci soru"] {
            let h = harness()
            _ = await h.startListening()
            await savePassage(h, targets: targets, closer: "Tamam")
            XCTAssertEqual(h.vm.passage?.all, [5, 6, 7], targets)
        }
    }

    func testPassageTargetsStillAcceptTheOldClosingWords() async {
        for closer in ["Cevapla", "Gönder", "Tamamlandı"] {
            let h = harness()
            _ = await h.startListening()
            await savePassage(h, targets: "beş altı yedi", closer: closer)
            XCTAssertEqual(h.vm.passage?.all, [5, 6, 7], closer)
        }
    }

    func testPassageIsSentWithItsQuestionsAndReleasedWhenAllAreAnswered() async {
        let h = harness()
        _ = await h.startListening()
        await savePassage(h)
        XCTAssertEqual(h.vm.passage?.all, [5, 6, 7])
        XCTAssertEqual(h.speaker.spoken.last, Say.passageReady([5, 6, 7]))
        XCTAssertTrue(h.answering.calls.isEmpty, "Paragraf tek başına gitmez")

        h.answering.results = [.success(FakeAnswering.reply(6))]
        h.ask("Soru 6 Ali nereye gitti")
        var back = await waitUntil { h.speaker.spoken.last == self.answered(6) && h.vm.phase == .listening }
        XCTAssertTrue(back)
        let first = h.answering.calls[0].question
        XCTAssertTrue(first.contains("5, 6 ve 7 numaralı sorular için ortaktır"))
        XCTAssertTrue(first.contains("Ali eve gitti. Sonra okula yürüdü"))
        XCTAssertTrue(first.hasSuffix("Soru 6 Ali nereye gitti"))
        XCTAssertEqual(h.vm.questions.last?.text, "Soru 6 Ali nereye gitti", "Listede yalnız okunan soru görünür")
        XCTAssertEqual(h.vm.passage?.remaining, [5, 7])

        h.answering.results = [.success(FakeAnswering.reply(8))]
        h.ask("Soru 8 başka bir soru")
        back = await waitUntil { h.speaker.spoken.last == self.answered(8) && h.vm.phase == .listening }
        XCTAssertTrue(back)
        XCTAssertEqual(h.answering.calls[1].question, "Soru 8 başka bir soru", "Paragrafa ait olmayan soruya paragraf eklenmez")
        XCTAssertEqual(h.vm.passage?.remaining, [5, 7])

        h.answering.results = [.success(FakeAnswering.reply(5)), .success(FakeAnswering.reply(7))]
        h.ask("Soru 5 ilk soru")
        back = await waitUntil { h.speaker.spoken.last == self.answered(5) && h.vm.phase == .listening }
        XCTAssertTrue(back)
        XCTAssertTrue(h.answering.calls[2].question.contains("Ali eve gitti."))
        h.ask("Soru 7 son soru")
        back = await waitUntil { h.speaker.spoken.last == self.answered(7) && h.vm.phase == .listening }
        XCTAssertTrue(back)
        XCTAssertNil(h.vm.passage, "Tüm soruları cevaplanınca paragraf bırakılır")
    }

    func testPassageAudioIsJoinedWithTheQuestionAudio() async {
        let h = harness()
        h.recorder.data = PCMRecorder.wav(samples: [1, 2, 3], sampleRate: 16_000)
        _ = await h.startListening()
        await savePassage(h, targets: "yedi")
        h.recorder.data = PCMRecorder.wav(samples: [9, 8], sampleRate: 16_000)
        h.answering.results = [.success(FakeAnswering.reply(7))]
        h.ask("Soru 7 bir soru")
        let sent = await waitUntil { h.answering.calls.count == 1 }
        XCTAssertTrue(sent)
        let joined = PCMRecorder.wav(samples: [1, 2, 3, 9, 8], sampleRate: 16_000)
        XCTAssertEqual(h.answering.calls[0].audio, joined, "Paragrafın sesi sorunun sesinin önüne eklenir")
        XCTAssertTrue(h.answering.calls[0].question.contains("Ses kaydında önce ortak paragraf"))
    }

    func testUnclearTargetsAreAskedAgain() async {
        let h = harness()
        _ = await h.startListening()
        say(h, "Ortak paragraf Ali eve gitti Tamamlandı")
        let asked = await waitUntil { h.vm.phase == .listening && h.vm.listenMode == .passageTargets }
        XCTAssertTrue(asked)
        say(h, "bilmiyorum Cevapla")
        let again = await waitUntil { h.speaker.spoken.last == Say.passageTargetsAgain && h.vm.phase == .listening }
        XCTAssertTrue(again)
        XCTAssertEqual(h.vm.listenMode, .passageTargets)
        XCTAssertNil(h.vm.passage)
        say(h, "iki üç Cevapla")
        let saved = await waitUntil { h.vm.passage?.all == [2, 3] && h.vm.phase == .listening }
        XCTAssertTrue(saved)
    }

    func testEmptyPassageIsRejected() async {
        let h = harness()
        _ = await h.startListening()
        say(h, "Ortak paragraf Tamamlandı")
        let said = await waitUntil { h.speaker.spoken.last == Say.passageEmpty && h.vm.phase == .listening }
        XCTAssertTrue(said)
        XCTAssertEqual(h.vm.listenMode, .question)
        XCTAssertNil(h.vm.passage)
    }

    func testCevaplaInsidePassageDoesNotSendAnything() async {
        let h = harness()
        _ = await h.startListening()
        h.listener.say("Ortak paragraf Ali dedi ki cevapla")
        h.scheduler.advance(by: 2)
        await settle()
        XCTAssertEqual(h.vm.listenMode, .passage)
        XCTAssertTrue(h.answering.calls.isEmpty)
        XCTAssertEqual(h.vm.phase, .listening)
    }

    // MARK: Kesinti sonrası devam

    /// İnternet gider, kestirme düzeltir; onarım bitince oturum dinlemeye döner
    private func dropAndRepairInternet(_ h: SessionHarness) async {
        h.health.internet = false
        h.shortcuts.onRun = { name in if name == "WiFi_Ac" { h.health.internet = true; h.network.isOnline = true } }
        h.network.set(online: false)
        h.scheduler.advance(by: Timing.offlineDebounce + 0.1)
    }

    func testAfterInterruptionOnceTheQuestionWasSentTheUserIsToldToRepeatIfNeeded() async {
        let h = harness(resume: true)
        h.answering.results = [.failure(GeminiError("Bağlantı koptu", .network))]
        _ = await h.startListening()
        h.health.internet = false
        h.shortcuts.onRun = { name in if name == "WiFi_Ac" { h.health.internet = true } }
        h.ask("Bir soru")
        let done = await waitUntil { h.speaker.spoken.last == Say.recoveredAfterSend && h.vm.phase == .listening }
        XCTAssertTrue(done)
        XCTAssertFalse(h.speaker.spoken.contains(Say.recovered))
        XCTAssertTrue(h.vm.liveText.isEmpty)
    }

    func testInterruptionWhileListeningRepeatsTheLastSentenceAndMergesTheRest() async {
        let h = harness(resume: true)
        h.answering.results = [.success(FakeAnswering.reply(3))]
        _ = await h.startListening()
        h.listener.say("Soru 3 Ali eve gitti. Sonra okula yürüdü ve arkadaşlarıyla buluştu")
        await dropAndRepairInternet(h)
        let expected = Say.continuePartial(passage: false, number: 3, sentence: "Sonra okula yürüdü ve arkadaşlarıyla buluştu")
        let back = await waitUntil { h.speaker.spoken.last == expected && h.vm.phase == .listening }
        XCTAssertTrue(back, "Son cümle ve soru numarası söylenir")
        XCTAssertEqual(h.vm.liveText, "Soru 3 Ali eve gitti. Sonra okula yürüdü ve arkadaşlarıyla buluştu", "Yarım metin korunur")

        say(h, "ve eve döndü Cevapla")
        let sent = await waitUntil { h.answering.calls.count == 1 }
        XCTAssertTrue(sent)
        XCTAssertEqual(h.answering.calls[0].question, "Soru 3 Ali eve gitti. Sonra okula yürüdü ve arkadaşlarıyla buluştu ve eve döndü")
    }

    func testInterruptedShortFragmentIsNotCarriedOver() async {
        let h = harness(resume: true)
        _ = await h.startListening()
        h.listener.say("Soru 3")
        await dropAndRepairInternet(h)
        let back = await waitUntil { h.speaker.spoken.last == Say.recovered && h.vm.phase == .listening }
        XCTAssertTrue(back, "Birkaç sözcük için devam anonsu yapılmaz; soru baştan okunur")
        XCTAssertTrue(h.vm.liveText.isEmpty)
    }

    func testWithoutSmartResumeThePartialTextIsDropped() async {
        let h = harness(resume: false)
        _ = await h.startListening()
        h.listener.say("Soru 3 Ali eve gitti. Sonra okula yürüdü ve arkadaşlarıyla buluştu")
        await dropAndRepairInternet(h)
        let back = await waitUntil { h.speaker.spoken.last == Say.recovered && h.vm.phase == .listening }
        XCTAssertTrue(back)
        XCTAssertTrue(h.vm.liveText.isEmpty)
    }

    func testInterruptionInTheMiddleOfAPassageContinuesThePassage() async {
        let h = harness(resume: true)
        _ = await h.startListening()
        h.listener.say("Ortak paragraf Ali eve gitti. Sonra okula yürüdü")
        XCTAssertEqual(h.vm.listenMode, .passage)
        await dropAndRepairInternet(h)
        let expected = Say.continuePartial(passage: true, number: nil, sentence: "Sonra okula yürüdü")
        let back = await waitUntil { h.speaker.spoken.last == expected && h.vm.phase == .listening }
        XCTAssertTrue(back, "Paragrafın son cümlesi söylenir")
        XCTAssertEqual(h.vm.listenMode, .passage)

        say(h, "ve eve döndü Tamamlandı")
        let asked = await waitUntil { h.vm.listenMode == .passageTargets && h.vm.phase == .listening }
        XCTAssertTrue(asked)
        say(h, "yedi Cevapla")
        let saved = await waitUntil { h.vm.passage?.text == "Ali eve gitti. Sonra okula yürüdü ve eve döndü" && h.vm.phase == .listening }
        XCTAssertTrue(saved, "Kesintiden önceki ve sonraki paragraf metni birleşir")
    }

    func testInterruptionWhileAskingForTheNumberAsksAgain() async {
        let h = harness(number: true)
        h.answering.results = [.success(FakeAnswering.reply(4))]
        _ = await h.startListening()
        h.ask("Bir soru metni")
        let asking = await waitUntil { h.vm.listenMode == .missingNumber && h.vm.phase == .listening }
        XCTAssertTrue(asking)
        await dropAndRepairInternet(h)
        let back = await waitUntil { h.speaker.spoken.last == Say.recoveredAskNumber && h.vm.phase == .listening }
        XCTAssertTrue(back, "Bekleyen soru kaybolmaz; numara yeniden istenir")
        XCTAssertEqual(h.vm.listenMode, .missingNumber)
        say(h, "dört", confirm: Timing.numberConfirm)
        let sent = await waitUntil { h.answering.calls.count == 1 }
        XCTAssertTrue(sent)
        XCTAssertEqual(h.answering.calls[0].question, "Soru 4. Bir soru metni")
    }

    func testInterruptionWhileTheTargetsAreAskedKeepsThePassage() async {
        let h = harness()
        _ = await h.startListening()
        say(h, "Ortak paragraf Ali eve gitti Tamamlandı")
        let asked = await waitUntil { h.vm.listenMode == .passageTargets && h.vm.phase == .listening }
        XCTAssertTrue(asked)
        await dropAndRepairInternet(h)
        let back = await waitUntil { h.speaker.spoken.last == Say.recoveredAskTargets && h.vm.phase == .listening }
        XCTAssertTrue(back)
        say(h, "iki Cevapla")
        let saved = await waitUntil { h.vm.passage?.all == [2] && h.vm.phase == .listening }
        XCTAssertTrue(saved)
    }

    func testManualPauseDropsTheHeldQuestionAndPassageMode() async {
        let h = harness(number: true)
        _ = await h.startListening()
        h.ask("Bir soru metni")
        let asking = await waitUntil { h.vm.listenMode == .missingNumber && h.vm.phase == .listening }
        XCTAssertTrue(asking)
        h.vm.pauseByUser()
        h.vm.resumeByUser()
        let back = await waitUntil { h.vm.phase == .listening }
        XCTAssertTrue(back)
        XCTAssertEqual(h.vm.listenMode, .question)
        XCTAssertNil(h.vm.heldQuestion)
    }

    func testEndingTheTestForgetsThePassage() async {
        let h = harness()
        _ = await h.startListening()
        await savePassage(h)
        h.vm.endTest()
        let ended = await waitUntil { h.vm.phase == .finished || h.vm.phase == .idle }
        XCTAssertTrue(ended)
        XCTAssertNil(h.vm.passage)
        XCTAssertEqual(h.vm.listenMode, .question)
    }
}
