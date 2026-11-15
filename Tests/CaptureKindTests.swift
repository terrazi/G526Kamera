import XCTest
@testable import G526CameraDrive

/// Sürüm 4: kamera "evet" denince "Soru mu, ortak paragraf mı çekeceksiniz? Birinci seçenek soru, ikinci seçenek paragraf" diye sorulur;
/// "bir / birinci / 1 / soru" soru, "iki / ikinci / 2 / paragraf" ortak paragraf demektir ve çekim buna göre yürür.
/// (Harness bu soruyu varsayılan olarak kapatır; burada açılır.)
@MainActor
final class CaptureKindTests: XCTestCase {
    typealias T = SessionViewModel.Timing

    private func harness(shots: [Result<CapturedQuestion, CameraFailure>] = [.success(FakeCamera.shot())],
                         replies: [Result<GeminiReply, Error>] = [.success(FakeAnswering.reply(1))]) -> SessionHarness {
        let h = SessionHarness(cameraFlow: true)
        h.settings.askCaptureKind = true
        h.camera.results = shots
        h.answering.results = replies
        h.trackEvents { name in
            if name == "Kameraya_Gec" { h.health.internet = false }
            if name == "Hücresele_Gec" { h.health.internet = true }
            if name == "Hücresel_Ac" { h.health.internet = true }
        }
        return h
    }

    private func reply(_ h: SessionHarness, _ text: String) {
        h.listener.say(text)
        h.scheduler.advance(by: T.numberConfirm + 0.1)
    }

    private func cameraQuestionOpen(_ h: SessionHarness) -> Bool {
        return h.vm.listenMode == .cameraChoice && h.vm.phase == .listening
    }

    private func kindQuestionOpen(_ h: SessionHarness) -> Bool {
        return h.vm.listenMode == .captureKindChoice && h.vm.phase == .listening
    }

    /// Kamera sorusuna "evet" der; soru mu paragraf mı sorusu açılana kadar bekler
    private func sayYesAndWaitForTheKindQuestion(_ h: SessionHarness) async -> Bool {
        reply(h, "evet")
        return await waitUntil(45) { self.kindQuestionOpen(h) }
    }

    // MARK: Cevabın anlaşılması

    func testQuestionWordsAreUnderstoodAsAQuestion() {
        for text in ["bir", "1", "birinci", "birinci seçenek", "soru", "soru çekeceğim", "ilk", "birincisi"] {
            XCTAssertEqual(SpokenReply.captureKind(text), .question, text)
        }
    }

    func testPassageWordsAreUnderstoodAsAPassage() {
        for text in ["iki", "2", "ikinci", "ikinci seçenek", "paragraf", "ortak paragraf", "soru paragrafı", "paragraf çekeceğim", "ikincisi"] {
            XCTAssertEqual(SpokenReply.captureKind(text), .passage, text)
        }
    }

    func testAnswersThatChooseNothingOrBothAreNotTaken() {
        for text in ["", "evet", "merhaba", "bir iki", "bir mi iki mi", "soru mu paragraf mı", "paragrafı iptal et"] {
            XCTAssertNil(SpokenReply.captureKind(text), text)
        }
    }

    // MARK: Akış

    /// "Evet" denince hiçbir şey çekilmez ve hiçbir bağlantı değişmez: önce ne çekileceği sorulur
    func testYesToTheCameraFirstAsksWhetherItIsAQuestionOrAPassage() async {
        let h = harness()
        _ = await h.startListening()
        let asked = await sayYesAndWaitForTheKindQuestion(h)
        XCTAssertTrue(asked, "\(h.speaker.spoken)")
        XCTAssertEqual(h.speaker.spoken.last, Say.askCaptureKind)
        XCTAssertTrue(Say.askCaptureKind.contains("Birinci seçenek soru"))
        XCTAssertTrue(Say.askCaptureKind.contains("ikinci seçenek paragraf"))
        XCTAssertEqual(h.camera.captures, 0)
        XCTAssertTrue(h.shortcuts.runs.isEmpty, "Soru cevaplanmadan kameraya geçilmez")
    }

    func testChoosingTheQuestionCapturesAQuestionAndSendsItToGemini() async {
        for word in ["bir", "soru", "birinci", "1"] {
            let h = harness()
            _ = await h.startListening()
            _ = await sayYesAndWaitForTheKindQuestion(h)
            reply(h, word)
            let sent = await waitUntil(45) { h.vm.answers.count == 1 && self.cameraQuestionOpen(h) }
            XCTAssertTrue(sent, "\(word): \(h.speaker.spoken)")
            XCTAssertEqual(h.camera.subjects, [.question], word)
            XCTAssertEqual(h.answering.captureCalls.count, 1, "\(word): çekilen soru Gemini'ye gider")
        }
    }

    func testChoosingThePassageCapturesAPassageAndAsksWhichQuestionsItBelongsTo() async {
        for word in ["iki", "paragraf", "ikinci", "2", "ortak paragraf"] {
            var shot = FakeCamera.shot()
            shot.photo = Data([9, 9, 9])
            let h = harness(shots: [.success(shot)])
            _ = await h.startListening()
            _ = await sayYesAndWaitForTheKindQuestion(h)
            reply(h, word)
            let asked = await waitUntil(45) { h.vm.listenMode == .passageTargets && h.vm.phase == .listening }
            XCTAssertTrue(asked, "\(word): \(h.speaker.spoken)")
            XCTAssertEqual(h.camera.subjects, [.passage], "\(word): kamera paragraf için açıldı")
            XCTAssertTrue(h.answering.captureCalls.isEmpty && h.answering.calls.isEmpty, "\(word): paragraf soru gibi Gemini'ye gitmez")
            XCTAssertEqual(h.speaker.spoken.last, Say.passageTakenCamera, word)
            XCTAssertNotNil(h.vm.passageDraft?.shot, word)
        }
    }

    // MARK: Cevap gelmezse / anlaşılmazsa

    /// Kamera sorusundaki gibi: "Cevap vermediniz, ikinci (üçüncü) defa soruyorum"; üçüncüde de cevap yoksa soru olarak çekilir
    func testUnansweredKindQuestionIsAskedThreeTimesThenCapturedAsAQuestion() async {
        let h = harness()
        _ = await h.startListening()
        _ = await sayYesAndWaitForTheKindQuestion(h)
        h.scheduler.advance(by: SilenceWatchdog.limit + 0.1)
        let second = await waitUntil(45) { h.speaker.spoken.last == Say.askCaptureKindRepeat(2) && self.kindQuestionOpen(h) }
        XCTAssertTrue(second, "\(h.speaker.spoken)")
        XCTAssertTrue(Say.askCaptureKindRepeat(2).contains("ikinci defa soruyorum"))
        h.scheduler.advance(by: SilenceWatchdog.limit + 0.1)
        let third = await waitUntil(45) { h.speaker.spoken.last == Say.askCaptureKindRepeat(3) && self.kindQuestionOpen(h) }
        XCTAssertTrue(third, "\(h.speaker.spoken)")
        XCTAssertTrue(Say.askCaptureKindRepeat(3).contains("üçüncü defa soruyorum"))
        XCTAssertEqual(h.camera.captures, 0, "Üçüncü soruştan önce kamera açılmaz")
        h.scheduler.advance(by: SilenceWatchdog.limit + 0.1)
        let sent = await waitUntil(45) { h.vm.answers.count == 1 }
        XCTAssertTrue(sent, "\(h.speaker.spoken)")
        XCTAssertTrue(h.speaker.spoken.contains(Say.captureKindDefault))
        XCTAssertEqual(h.camera.subjects, [.question])
    }

    func testUnclearAnswerToTheKindQuestionIsAskedAgainRightAway() async {
        let h = harness()
        _ = await h.startListening()
        _ = await sayYesAndWaitForTheKindQuestion(h)
        h.listener.say("bilmem ki")
        h.scheduler.advance(by: T.numberUnclear + 0.1)
        let again = await waitUntil(45) { h.speaker.spoken.last == Say.askCaptureKindAgain && self.kindQuestionOpen(h) }
        XCTAssertTrue(again, "\(h.speaker.spoken)")
        XCTAssertTrue(Say.askCaptureKindAgain.hasPrefix("Anlayamadım"))
        XCTAssertEqual(h.camera.captures, 0)
        reply(h, "iki")
        let asked = await waitUntil(45) { h.vm.listenMode == .passageTargets && h.vm.phase == .listening }
        XCTAssertTrue(asked, "Yeniden sorulunca verilen cevap işler: \(h.speaker.spoken)")
        XCTAssertEqual(h.camera.subjects, [.passage])
    }

    /// Kamera sorusuna üç kez cevap gelmeyince kameraya kendiliğinden geçilir; ama önce ne çekileceği yine sorulur
    func testTheAutomaticCameraStartAlsoAsksWhatWillBeShot() async {
        let h = harness()
        _ = await h.startListening()
        h.scheduler.advance(by: SilenceWatchdog.limit + 0.1)
        _ = await waitUntil(45) { h.speaker.spoken.last == Say.askCameraRepeat(2) && self.cameraQuestionOpen(h) }
        h.scheduler.advance(by: SilenceWatchdog.limit + 0.1)
        _ = await waitUntil(45) { h.speaker.spoken.last == Say.askCameraRepeat(3) && self.cameraQuestionOpen(h) }
        h.scheduler.advance(by: SilenceWatchdog.limit + 0.1)
        let asked = await waitUntil(45) { self.kindQuestionOpen(h) }
        XCTAssertTrue(asked, "\(h.speaker.spoken)")
        XCTAssertTrue(h.speaker.spoken.contains(Say.cameraAutoStart))
        XCTAssertEqual(h.camera.captures, 0)
    }

    // MARK: Ayar

    func testTurningTheKindQuestionOffCapturesAQuestionDirectly() async {
        let h = harness()
        h.settings.askCaptureKind = false
        _ = await h.startListening()
        reply(h, "evet")
        let sent = await waitUntil(45) { h.vm.answers.count == 1 && self.cameraQuestionOpen(h) }
        XCTAssertTrue(sent, "\(h.speaker.spoken)")
        XCTAssertFalse(h.speaker.spoken.contains(Say.askCaptureKind))
        XCTAssertEqual(h.camera.subjects, [.question])
    }
}
