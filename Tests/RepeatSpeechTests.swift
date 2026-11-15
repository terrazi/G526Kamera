import XCTest
@testable import G526CameraDrive

/// "Anlamadım", "duyamadım", "bir daha söyle", "yeniden söyle", "tekrar söyle"…: kullanıcı programın söylediğini duymadıysa ya da anlamadıysa
/// programın son sözü (soru, menü, cevap) aynen yeniden söylenir; her aşamada, durum bozulmadan. Program da anlamadığında aynısını ister.
@MainActor
final class RepeatSpeechTests: XCTestCase {
    private typealias T = SessionViewModel.Timing

    private let phrases = ["anlamadım", "anlayamadım", "duyamadım", "duymadım", "bir daha söyle", "yeniden söyle", "tekrar söyle", "yine söyle",
                           "bir kez daha söyle", "ne dedin", "ne dediniz", "efendim", "pardon", "neydi", "tekrar söyler misin", "bir daha söyler misiniz",
                           "yeniden anlatır mısınız", "tekrar edebilir misiniz", "anlamadım lütfen yeniden söyle", "duyamadım bir daha söyle",
                           "lütfen bir daha söyle", "anlamıyorum", "duyulmuyor", "anlaşılmadı", "bir daha oku", "yeniden oku"]

    // MARK: Çözümleme

    func testManyWaysOfAskingForARepeatAreUnderstood() {
        for text in phrases {
            XCTAssertEqual(VoiceCommand.parse(text), .repeatSpeech, text)
            XCTAssertEqual(VoiceCommand.parseLenient(text), .repeatSpeech, text)
        }
        // Tanıyıcı yakın sesle yazarsa da
        for text in ["anlamadim", "duyamadim", "Bir daha söyle.", "BİR DAHA SÖYLE", "yeniden söyle!", "duyamadın"] {
            XCTAssertEqual(VoiceCommand.parseLenient(text), .repeatSpeech, text)
        }
    }

    func testOldRepeatCommandsKeepTheirMeaning() {
        XCTAssertEqual(VoiceCommand.parse("tekrarla"), .repeatLast)
        XCTAssertEqual(VoiceCommand.parse("tekrar et"), .repeatLast)
        XCTAssertEqual(VoiceCommand.parse("tekrar eder misin"), .repeatLast)
        XCTAssertEqual(VoiceCommand.parse("lütfen tekrarla"), .repeatLast)
        XCTAssertEqual(VoiceCommand.parse("son cevabı tekrarla"), .repeatLast)
        XCTAssertEqual(VoiceCommand.parse("cevapları tekrarla"), .replayAnswers)
        XCTAssertEqual(VoiceCommand.parse("cevapları bir daha oku"), .replayAnswers)
        XCTAssertEqual(VoiceCommand.parse("soruyu baştan oku"), .cancelQuestion)
        XCTAssertEqual(VoiceCommand.parse("testi bitir"), .endTest)
    }

    /// Soru ve paragraf metninde geçebilecek parçalar, olumsuz söyleyişler ve tek başına belirsiz sözler programı konuşturmaz
    func testQuestionTextAndNegatedOrVagueWordsAreNotRepeatRequests() {
        for text in ["Soruyu anlamadım", "Bu cümleyi anlamadım", "Ben anlamadım soruyu", "Aşağıdakilerden hangisi duyamadım", "tekrar söyleme", "bir daha söylemem",
                     "tekrar anlatma", "bir daha söyleme", "söyle", "bir daha", "bir kez daha", "yeniden", "yine", "ne", "nasıl", "daha", "oku", "tekrar oku",
                     "tekrar eden bir sayı", "Bir kez daha söylenen cümle", "yeniden okuma", "bir daha okuma", "cevabı bir daha söyle"] {
            XCTAssertNotEqual(VoiceCommand.parse(text), .repeatSpeech, text)
        }
    }

    func testRepeatPhrasesAreNeverTakenForAnswersToTheChoiceQuestions() {
        for text in phrases {
            XCTAssertNil(SpokenReply.yesNo(text), "Evet/hayır: \(text)")
            XCTAssertNil(SpokenReply.start(text), "Devam/yeni: \(text)")
            XCTAssertNil(SpokenReply.cameraChoice(text), "Kamera: \(text)")
        }
    }

    func testRecognizerHintsIncludeTheRepeatPhrases() {
        for word in ["Anlamadım", "Duyamadım", "Bir daha söyle", "Yeniden söyle", "Tekrar söyle"] {
            XCTAssertTrue(OnDeviceSpeechListener.contextualStrings.contains(word), word)
            XCTAssertTrue(ListenHints.choice.strings.contains(word), word)
        }
        XCTAssertLessThanOrEqual(OnDeviceSpeechListener.contextualStrings.count, 100)
    }

    // MARK: Akış yardımcıları

    private func say(_ h: SessionHarness, _ text: String) {
        h.listener.say(text)
        h.scheduler.advance(by: T.numberConfirm + 0.1)
    }

    private func answerOne(_ h: SessionHarness, number: Int) async {
        h.answering.results.append(.success(FakeAnswering.reply(number)))
        h.ask("Soru \(number). A seçeneği Adana")
        _ = await waitUntil(45) { h.vm.answers.count == number && h.vm.phase == .listening }
    }

    /// Verilen sözü söyler; program tam bir anons daha söyleyip aynı kipte dinlemeye dönene kadar bekler
    private func askToRepeat(_ h: SessionHarness, _ text: String, mode: ListenMode, file: StaticString = #filePath, line: UInt = #line) async {
        let before = h.speaker.spoken.count
        say(h, text)
        let done = await waitUntil(45) { h.speaker.spoken.count == before + 1 && h.vm.phase == .listening && h.vm.listenMode == mode }
        XCTAssertTrue(done, "'\(text)' sonrası program tekrar söylemedi: \(h.speaker.spoken)", file: file, line: line)
    }

    // MARK: Soru dinlenirken: son cevap yeniden söylenir

    func testEveryPhraseReadsTheLastAnswerAgainAndKeepsListeningForTheQuestion() async {
        let h = SessionHarness()
        _ = await h.startListening()
        await answerOne(h, number: 1)
        let answer = h.vm.answers[0].spoken
        for text in phrases {
            await askToRepeat(h, text, mode: .question)
            XCTAssertEqual(h.speaker.spoken.last, answer, text)
        }
        XCTAssertEqual(h.answering.calls.count, 1, "Tekrar isteği Gemini'ye gitmez")
        XCTAssertEqual(h.vm.answers.count, 1)
        // Test normal sürer
        await answerOne(h, number: 2)
        XCTAssertEqual(h.vm.answers.map { $0.number }, [1, 2])
    }

    func testPartlyReadQuestionSurvivesARepeatRequestInTheMiddle() async {
        let h = SessionHarness()
        _ = await h.startListening()
        await answerOne(h, number: 1)
        h.listener.say("Soru 2 Ali eve gitti")
        h.scheduler.advance(by: T.utteranceGap + 0.1)
        let before = h.speaker.spoken.count
        say(h, "Soru 2 Ali eve gitti bir daha söyle")
        let done = await waitUntil(45) { h.speaker.spoken.count == before + 1 && h.vm.phase == .listening }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        XCTAssertEqual(h.speaker.spoken.last, h.vm.answers[0].spoken)
        XCTAssertEqual(h.vm.accumulator.text, "Soru 2 Ali eve gitti", "Okunan soru metni korunur, yalnız komut atılır")
        h.answering.results = [.success(FakeAnswering.reply(2))]
        h.listener.say("okula yürüdü Cevapla")   // dinleme yeniden açıldı: yeni görevin metni korunan metnin arkasına eklenir
        h.scheduler.advance(by: T.triggerConfirm + 0.1)
        let sent = await waitUntil(45) { h.answering.calls.count == 2 }
        XCTAssertTrue(sent, "\(h.speaker.spoken)")
        XCTAssertTrue(h.answering.calls[1].question.contains("Ali eve gitti okula yürüdü"), h.answering.calls[1].question)
        XCTAssertFalse(h.answering.calls[1].question.contains("söyle"), h.answering.calls[1].question)
    }

    func testRepeatBeforeCevaplaIsAlsoAnsweredWithoutSendingAnything() async {
        let h = SessionHarness()
        _ = await h.startListening()
        await answerOne(h, number: 1)
        let before = h.speaker.spoken.count
        h.listener.say("anlamadım Cevapla")
        h.scheduler.advance(by: T.triggerConfirm + 0.1)
        let done = await waitUntil(45) { h.speaker.spoken.count == before + 1 && h.vm.phase == .listening }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        XCTAssertEqual(h.answering.calls.count, 1)
    }

    // MARK: Onay, menü, numara, paragraf, başlangıç, kamera sorusu

    func testRepeatAtTheFinishConfirmationAsksTheQuestionAgainWithoutChangingIt() async {
        let h = SessionHarness()
        _ = await h.startListening()
        say(h, "testi bitir")
        let asked = await waitUntil(45) { h.vm.listenMode == .confirmEnd && h.vm.phase == .listening }
        XCTAssertTrue(asked, "\(h.speaker.spoken)")
        for text in ["duyamadım", "bir daha söyle", "tekrarla", "tekrar et", "yeniden söyle"] {
            await askToRepeat(h, text, mode: .confirmEnd)
            XCTAssertEqual(h.speaker.spoken.last, Say.confirmEnd, text)
        }
        XCTAssertNotEqual(h.vm.phase, .finished, "Tekrar isteği testi bitirmez")
        say(h, "evet")
        let ended = await waitUntil(45) { h.vm.phase == .finished }
        XCTAssertTrue(ended, "\(h.speaker.spoken)")
    }

    func testRepeatAtTheReviewMenuReadsTheMenuNotTheAnswersAgain() async {
        let h = SessionHarness()
        _ = await h.startListening()
        await answerOne(h, number: 1)
        say(h, "Cevapları tekrarla")
        _ = await waitUntil(45) { h.vm.reviewing }
        h.player.finish()
        let asked = await waitUntil(45) { h.vm.listenMode == .reviewMenu && h.vm.phase == .listening }
        XCTAssertTrue(asked, "\(h.speaker.spoken)")
        let menu = Say.reviewReport(count: 1, failed: 0) + " " + Say.reviewMenu
        XCTAssertEqual(h.speaker.spoken.last, menu)
        for text in ["anlamadım", "tekrar söyle", "bir daha söyle"] {
            await askToRepeat(h, text, mode: .reviewMenu)
            XCTAssertEqual(h.speaker.spoken.last, menu, text)
        }
        XCTAssertEqual(h.player.played.count, 1, "'Tekrar söyle' cevapları yeniden oynatmaz (menüdeki 'Tekrar' seçeneği ayrıdır)")
        say(h, "Devam")
        let back = await waitUntil(45) { h.vm.listenMode == .question && h.vm.phase == .listening && h.speaker.spoken.last == Say.reviewBackToQuestion }
        XCTAssertTrue(back, "\(h.speaker.spoken)")
    }

    func testMenuTekrarOptionStillReplaysTheAnswers() async {
        let h = SessionHarness()
        _ = await h.startListening()
        await answerOne(h, number: 1)
        say(h, "Cevapları tekrarla")
        _ = await waitUntil(45) { h.vm.reviewing }
        h.player.finish()
        _ = await waitUntil(45) { h.vm.listenMode == .reviewMenu && h.vm.phase == .listening }
        say(h, "Tekrar")
        let again = await waitUntil(45) { h.vm.reviewing && h.player.played.count == 2 }
        XCTAssertTrue(again, "Menüde tek başına 'Tekrar' cevapları yeniden oynatır: \(h.speaker.spoken)")
    }

    func testRepeatWhileTheNumberIsAskedKeepsTheHeldQuestion() async {
        let h = SessionHarness()
        h.settings.askMissingNumber = true
        _ = await h.startListening()
        h.ask("Ali eve gitti ve okula yürüdü")
        let asked = await waitUntil(45) { h.vm.listenMode == .missingNumber && h.vm.phase == .listening }
        XCTAssertTrue(asked, "\(h.speaker.spoken)")
        for text in ["anlamadım", "tekrarla", "ne dedin"] {
            await askToRepeat(h, text, mode: .missingNumber)
            XCTAssertEqual(h.speaker.spoken.last, Say.askNumber, text)
            XCTAssertNotNil(h.vm.heldQuestion, "Bekleyen soru kaybolmaz")
        }
        h.answering.results = [.success(FakeAnswering.reply(7))]
        say(h, "yedi")
        let sent = await waitUntil(45) { h.answering.calls.count == 1 }
        XCTAssertTrue(sent, "\(h.speaker.spoken)")
        XCTAssertTrue(h.answering.calls[0].question.contains("Ali eve gitti"), h.answering.calls[0].question)
    }

    func testRepeatWhileTheParagraphIsReadAndWhileItsTargetsAreAskedKeepsTheDraft() async {
        let h = SessionHarness()
        _ = await h.startListening()
        say(h, "Ortak paragraf")
        let prompt = await waitUntil(45) { h.speaker.spoken.last == Say.passagePrompt && h.vm.listenMode == .passage && h.vm.phase == .listening }
        XCTAssertTrue(prompt, "\(h.speaker.spoken)")
        await askToRepeat(h, "duyamadım", mode: .passage)
        XCTAssertEqual(h.speaker.spoken.last, Say.passagePrompt)
        say(h, "Ali eve gitti. Sonra okula yürüdü Tamam")
        let targets = await waitUntil(45) { h.vm.listenMode == .passageTargets && h.vm.phase == .listening && h.speaker.spoken.last == Say.passageTaken }
        XCTAssertTrue(targets, "Paragraf okunurken söylenen 'duyamadım' paragrafa karışmadı: \(h.speaker.spoken)")
        XCTAssertEqual(h.vm.passageDraft?.text, "Ali eve gitti. Sonra okula yürüdü")
        await askToRepeat(h, "bir daha söyle", mode: .passageTargets)
        XCTAssertEqual(h.speaker.spoken.last, Say.passageTaken)
        XCTAssertEqual(h.vm.passageDraft?.text, "Ali eve gitti. Sonra okula yürüdü", "Taslak bozulmaz")
        say(h, "beş altı yedi Tamam")
        let saved = await waitUntil(45) { h.vm.listenMode == .question && h.vm.passage?.all == [5, 6, 7] }
        XCTAssertTrue(saved, "\(h.speaker.spoken)")
    }

    func testParagraphTextContainingTheWordsIsNotMistakenForARepeatRequest() async {
        let h = SessionHarness()
        _ = await h.startListening()
        say(h, "Ortak paragraf")
        _ = await waitUntil(45) { h.vm.listenMode == .passage && h.vm.phase == .listening }
        let before = h.speaker.spoken.count
        say(h, "Ali bir kez daha söyledi ki duyamadım Tamam")
        let targets = await waitUntil(45) { h.vm.listenMode == .passageTargets && h.vm.phase == .listening }
        XCTAssertTrue(targets, "\(h.speaker.spoken)")
        XCTAssertEqual(h.vm.passageDraft?.text, "Ali bir kez daha söyledi ki duyamadım")
        XCTAssertEqual(h.speaker.spoken.count, before + 1, "Yalnız 'paragraf alındı' denir")
    }

    func testRepeatAtTheStartChoiceAsksItAgain() async {
        let h = SessionHarness()
        _ = await h.startListening()
        await answerOne(h, number: 1)
        h.vm.endTest()
        _ = await h.startListening()
        XCTAssertEqual(h.vm.listenMode, .startChoice)
        for text in ["anlamadım", "bir daha söyle", "tekrarla"] {
            await askToRepeat(h, text, mode: .startChoice)
            XCTAssertTrue(h.speaker.spoken.last?.hasSuffix(Say.readyAskContinue(answers: 1, next: 2)) == true, "\(text): \(h.speaker.spoken)")
        }
        say(h, "Devam")
        let on = await waitUntil(45) { h.vm.listenMode == .question && h.vm.phase == .listening && h.speaker.spoken.last == Say.continuingPrevious(next: 2) }
        XCTAssertTrue(on, "\(h.speaker.spoken)")
    }

    func testRepeatAtTheCameraQuestionAsksItAgainAndDoesNotStartTheCamera() async {
        let h = SessionHarness(cameraFlow: true)
        _ = await h.startListening()
        XCTAssertEqual(h.vm.listenMode, .cameraChoice)
        for text in ["anlamadım", "duyamadım", "bir daha söyle", "yeniden söyle", "ne dedin"] {
            await askToRepeat(h, text, mode: .cameraChoice)
            XCTAssertTrue(h.speaker.spoken.last?.hasSuffix(Say.askCamera) == true, "\(text): \(h.speaker.spoken)")
        }
        XCTAssertEqual(h.camera.captures, 0, "Tekrar isteği kamerayı açmaz")
        XCTAssertTrue(h.shortcuts.runs.isEmpty, "Hücresel kesilmez: \(h.shortcuts.runs)")
        say(h, "hayır")
        let voice = await waitUntil(45) { h.speaker.spoken.last == Say.cameraDeclined && h.vm.listenMode == .question && h.vm.phase == .listening }
        XCTAssertTrue(voice, "\(h.speaker.spoken)")
    }

    func testRepeatAfterAnAnswerAndTheCameraQuestionSpeaksBothSoTheAnswerIsNotMissed() async {
        let h = SessionHarness(cameraFlow: true)
        h.trackEvents { name in
            if name == "Kameraya_Gec" { h.health.internet = false }
            if name == "Hücresele_Gec" || name == "Hücresel_Ac" { h.health.internet = true }
        }
        h.camera.results = [.success(FakeCamera.shot())]
        h.answering.results = [.success(FakeAnswering.reply(5))]
        _ = await h.startListening()
        say(h, "evet")
        _ = await waitUntil(45) { h.vm.answers.count == 1 && h.vm.listenMode == .cameraChoice && h.vm.phase == .listening }
        let answer = h.vm.answers[0].spoken
        await askToRepeat(h, "duyamadım", mode: .cameraChoice)
        XCTAssertEqual(h.speaker.spoken.last, answer + " " + Say.askCamera, "Cevap duyulmadıysa kamera sorusuyla birlikte yeniden söylenir")
        XCTAssertEqual(h.camera.captures, 1, "Yeni çekim başlamaz")
    }

    func testNothingToRepeatYetSaysSo() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.vm.recentSpeech = []
        await askToRepeat(h, "anlamadım", mode: .question)
        XCTAssertEqual(h.speaker.spoken.last, Say.nothingToRepeat)
    }

    // MARK: Program anlamayınca o da ister

    func testProgramAlsoAsksToRepeatWhenItDoesNotUnderstand() async {
        let h = SessionHarness()
        _ = await h.startListening()
        say(h, "testi bitir")
        _ = await waitUntil(45) { h.vm.listenMode == .confirmEnd && h.vm.phase == .listening }
        h.listener.say("hmm bilmem")
        h.scheduler.advance(by: T.triggerConfirm + 0.1)
        h.scheduler.advance(by: T.numberUnclear)
        let asked = await waitUntil(45) { h.speaker.spoken.last == Say.confirmEndAgain && h.vm.listenMode == .confirmEnd && h.vm.phase == .listening }
        XCTAssertTrue(asked, "\(h.speaker.spoken)")
        XCTAssertTrue(Say.confirmEndAgain.hasPrefix("Anlayamadım"))
        XCTAssertTrue(Say.reviewMenuAgain.hasPrefix("Anlayamadım"))
        XCTAssertTrue(Say.askCameraAgain.hasPrefix("Anlayamadım"))
        XCTAssertTrue(Say.commandNotUnderstood.lowercased().contains("anlayamad"))
    }
}
