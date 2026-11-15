import XCTest
@testable import G526CameraDrive

/// Anlayamayınca susmamak: komut yalnız son sözden aranır, anlaşılmayan komut denemesi sesli bildirilir ve metinden atılır,
/// "Cevapla" duyulmayınca ve paragraf numaralarından sonra "Tamam" duyulmayınca program kendisi sorar, kipe göre ipucu listesi
@MainActor
final class UnderstandingTests: XCTestCase {
    private typealias T = SessionViewModel.Timing

    private func harness() -> SessionHarness {
        let h = SessionHarness()
        h.settings.askMissingNumber = false
        return h
    }

    private func say(_ h: SessionHarness, _ text: String, confirm: TimeInterval) {
        h.listener.say(text)
        h.scheduler.advance(by: confirm + 0.1)
    }

    private func spokenCount(_ h: SessionHarness, _ text: String) -> Int {
        return h.speaker.spoken.filter { $0 == text }.count
    }

    // MARK: Saf mantık

    func testSplitCommandWordsAreJoinedAgain() {
        XCTAssertNil(VoiceCommand.parse("tekrar la"))
        XCTAssertEqual(VoiceCommand.parseLenient("tekrar la"), .repeatLast)
        XCTAssertEqual(VoiceCommand.parseLenient("cevapları tekrar la"), .replayAnswers)
        XCTAssertEqual(VoiceCommand.parseLenient("testi bit ir"), .endTest)
        XCTAssertNil(VoiceCommand.parseLenient("kitap oku la"), "Komut olmayan söz komut sayılmaz")
        XCTAssertNil(VoiceCommand.parseLenient("Aşağıdakilerden hangisi doğrudur"))
    }

    func testCommandAttemptDetectionIsStrict() {
        XCTAssertTrue(CommandAttempt.looksLike("testi bit"))
        XCTAssertTrue(CommandAttempt.looksLike("cevapları tekra"))
        XCTAssertTrue(CommandAttempt.looksLike("sınavı bitirme"))
        XCTAssertFalse(CommandAttempt.looksLike("cevapları tekrar çok"), "Komut olmayan sözcük varsa soru olabilir")
        XCTAssertFalse(CommandAttempt.looksLike("Bir testin"), "Yalnız konu sözcüğü soru başlangıcıdır")
        XCTAssertFalse(CommandAttempt.looksLike("Cevap anahtarında"))
        XCTAssertFalse(CommandAttempt.looksLike("Aşağıdakilerden hangisi"))
        XCTAssertFalse(CommandAttempt.looksLike("Tamam"), "Tek başına tamam komut denemesi değildir")
        XCTAssertFalse(CommandAttempt.looksLike(""))
    }

    func testAccumulatorDropsTheTailWords() {
        var acc = TranscriptAccumulator()
        acc.update(partial: "bir iki üç dört")
        acc.dropWords(from: 2)
        XCTAssertEqual(acc.text, "bir iki")
        acc.dropWords(from: 0)
        XCTAssertTrue(acc.isEmpty)
    }

    func testHintListsFollowTheListeningMode() {
        XCTAssertEqual(ListenHints.hints(for: .question), .dictation)
        XCTAssertEqual(ListenHints.hints(for: .passage), .dictation)
        XCTAssertEqual(ListenHints.hints(for: .confirmEnd), .choice)
        XCTAssertEqual(ListenHints.hints(for: .reviewMenu), .choice)
        XCTAssertEqual(ListenHints.hints(for: .missingNumber), .number)
        XCTAssertEqual(ListenHints.hints(for: .passageTargets), .targets)
        XCTAssertTrue(ListenHints.choice.strings.contains("Evet"))
        XCTAssertTrue(ListenHints.number.strings.contains("yedi"))
        XCTAssertTrue(ListenHints.targets.strings.contains("Tamam"))
        XCTAssertGreaterThan(ListenHints.dictation.strings.count, ListenHints.choice.strings.count)
    }

    func testListenerGetsTheHintListOfEachMode() async {
        let h = harness()
        h.settings.askMissingNumber = true
        _ = await h.startListening()
        XCTAssertEqual(h.listener.startedHints.last, .dictation)
        h.ask("Bir soru metni A B C")
        let asking = await waitUntil { h.vm.listenMode == .missingNumber && h.vm.phase == .listening }
        XCTAssertTrue(asking)
        XCTAssertEqual(h.listener.startedHints.last, .number, "Numara beklenirken dar sayı listesi")
        say(h, "Testi bitir", confirm: T.numberConfirm)
        _ = await waitUntil { h.vm.phase == .listening }
        XCTAssertEqual(h.vm.listenMode, .missingNumber, "Numara beklerken komut çalışmaz (yalnız cevapları tekrarla)")
    }

    // MARK: Anlaşılmayan komut

    func testUnrecognisedCommandAttemptIsAnnouncedAndDroppedFromTheText() async {
        let h = harness()
        _ = await h.startListening()
        h.listener.say("testi bit")
        h.scheduler.advance(by: T.attemptConfirm + 0.1)
        let told = await waitUntil { h.speaker.spoken.last == Say.commandNotUnderstood && h.vm.phase == .listening }
        XCTAssertTrue(told, "Anlamayınca susmaz, anlayamadığını söyler")
        XCTAssertEqual(h.vm.accumulator.text, "", "Anlaşılmayan söz soru metnine karışmaz")
        XCTAssertEqual(h.vm.listenMode, .question)
        XCTAssertNotNil(h.vm.warnings.first { $0.id == "duyulan" }, "Ne duyulduğu ekranda yazar")
    }

    func testTheSecondFailureListsTheCommands() async {
        let h = harness()
        _ = await h.startListening()
        h.listener.say("testi bit")
        h.scheduler.advance(by: T.attemptConfirm + 0.1)
        _ = await waitUntil { h.speaker.spoken.last == Say.commandNotUnderstood && h.vm.phase == .listening }
        h.listener.say("testi bitr")
        h.scheduler.advance(by: T.attemptConfirm + 0.1)
        let help = await waitUntil { h.speaker.spoken.last == Say.commandHelp && h.vm.phase == .listening }
        XCTAssertTrue(help)
    }

    func testACommandAfterAnUnrecognisedAttemptIsStillUnderstood() async {
        let h = harness()
        _ = await h.startListening()
        h.listener.say("testi bit")
        h.scheduler.advance(by: T.utteranceGap + 0.1)   // söz bitti; "anlayamadım" süresi daha dolmadı
        h.listener.say("testi bit testi bitir")
        h.scheduler.advance(by: T.numberConfirm + 0.1)
        let asked = await waitUntil { h.vm.listenMode == .confirmEnd && h.vm.phase == .listening }
        XCTAssertTrue(asked, "Eski anlaşılmayan söz, sonraki doğru komutu bozmaz")
    }

    func testSplitCommandIsUnderstoodOnTheFirstTry() async {
        let h = harness()
        _ = await h.startListening()
        h.listener.say("testi bit ir")
        h.scheduler.advance(by: T.numberConfirm + 0.1)
        let asked = await waitUntil { h.vm.listenMode == .confirmEnd && h.vm.phase == .listening }
        XCTAssertTrue(asked)
    }

    func testStaleAttemptBeforeCevaplaDoesNotTurnTheCommandIntoAQuestion() async {
        let h = harness()
        _ = await h.startListening()
        h.listener.say("testi bit")
        h.scheduler.advance(by: T.utteranceGap + 0.1)
        h.listener.say("testi bit testi bitir Cevapla")
        h.scheduler.advance(by: T.triggerConfirm + 0.1)
        let asked = await waitUntil { h.vm.listenMode == .confirmEnd && h.vm.phase == .listening }
        XCTAssertTrue(asked)
        XCTAssertTrue(h.answering.calls.isEmpty, "Komut soru olarak Gemini'ye gitmez")
    }

    func testOrdinaryQuestionTextIsNeverTreatedAsACommandAttempt() async {
        let h = harness()
        _ = await h.startListening()
        h.listener.say("Bir testin güvenilirliği")
        h.scheduler.advance(by: T.attemptConfirm + 0.1)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(h.vm.accumulator.text, "Bir testin güvenilirliği")
        XCTAssertNotEqual(h.speaker.spoken.last, Say.commandNotUnderstood)
    }

    // MARK: "Cevapla" duyulmadı

    func testSilentQuestionTextGetsACueAndTheTextIsKept() async {
        let h = harness()
        h.answering.results = [.success(FakeAnswering.reply(1))]
        _ = await h.startListening()
        h.listener.say("Aşağıdakilerden hangisi Türkiye'nin başkentidir")
        h.scheduler.advance(by: T.questionIdle + 0.1)
        let told = await waitUntil { h.speaker.spoken.last == Say.noTriggerHeard && h.vm.phase == .listening }
        XCTAssertTrue(told)
        XCTAssertTrue(h.vm.accumulator.text.contains("başkentidir"), "Okunan soru kaybolmaz")
        h.listener.say("Cevapla")
        h.scheduler.advance(by: T.triggerConfirm + 0.1)
        let sent = await waitUntil { h.answering.calls.count == 1 }
        XCTAssertTrue(sent)
        guard sent else { return }
        XCTAssertTrue(h.answering.calls[0].question.contains("Türkiye'nin başkentidir"))
    }

    func testTheCueIsGivenAtMostTwiceForOneQuestion() async {
        let h = harness()
        _ = await h.startListening()
        h.listener.say("Aşağıdakilerden hangisi Türkiye'nin başkentidir")
        h.scheduler.advance(by: T.questionIdle + 0.1)
        _ = await waitUntil { self.spokenCount(h, Say.noTriggerHeard) == 1 && h.vm.phase == .listening }
        h.listener.say("ve")
        h.scheduler.advance(by: T.questionIdle + 0.1)
        _ = await waitUntil { self.spokenCount(h, Say.noTriggerHeard) == 2 && h.vm.phase == .listening }
        h.listener.say("ile")
        h.scheduler.advance(by: T.questionIdle + 0.1)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(spokenCount(h, Say.noTriggerHeard), 2)
    }

    // MARK: Ortak paragraf numaraları

    private func startPassageTargets(_ h: SessionHarness) async {
        _ = await h.startListening()
        say(h, "Ortak paragraf Ali eve gitti. Sonra okula yürüdü Tamamlandı", confirm: T.numberConfirm)
        _ = await waitUntil { h.vm.listenMode == .passageTargets && h.vm.phase == .listening }
    }

    func testPassageNumbersWithoutTamamAreConfirmedByTheProgram() async {
        let h = harness()
        await startPassageTargets(h)
        h.listener.say("beş altı yedi")
        h.scheduler.advance(by: T.targetsIdle + 0.1)
        let asked = await waitUntil { h.speaker.spoken.last == Say.passageTargetsConfirm([5, 6, 7]) && h.vm.phase == .listening }
        XCTAssertTrue(asked, "Numaralar duyuldu ama Tamam denmedi: program sorar")
        XCTAssertEqual(h.vm.listenMode, .passageTargets)
        h.listener.say("Tamam")
        h.scheduler.advance(by: T.numberConfirm + 0.1)
        let saved = await waitUntil { h.vm.passage != nil && h.vm.listenMode == .question && h.vm.phase == .listening }
        XCTAssertTrue(saved)
        XCTAssertEqual(h.vm.passage?.all, [5, 6, 7])
    }

    func testPassageNumbersAreAcceptedWhenTamamIsStillMissingAfterTheQuestion() async {
        let h = harness()
        await startPassageTargets(h)
        h.listener.say("beş altı yedi")
        h.scheduler.advance(by: T.targetsIdle + 0.1)
        _ = await waitUntil { h.speaker.spoken.last == Say.passageTargetsConfirm([5, 6, 7]) && h.vm.phase == .listening }
        h.vm.silenceExpired()   // yine bir şey söylenmedi
        let saved = await waitUntil { h.vm.passage != nil && h.vm.listenMode == .question && h.vm.phase == .listening }
        XCTAssertTrue(saved, "Numaralar belli: sonsuza kadar Tamam beklenmez")
        XCTAssertEqual(h.vm.passage?.all, [5, 6, 7])
    }

    func testSilenceWhileWaitingForPassageNumbersIsAskedAgain() async {
        let h = harness()
        await startPassageTargets(h)
        h.vm.silenceExpired()
        let asked = await waitUntil { h.speaker.spoken.last == Say.passageTargetsAgain && h.vm.phase == .listening }
        XCTAssertTrue(asked, "Sessizlikte program numaraları yeniden ister")
        XCTAssertEqual(h.vm.listenMode, .passageTargets)
    }

    func testUnclearWordsWhileWaitingForPassageNumbersAreAskedAgain() async {
        let h = harness()
        await startPassageTargets(h)
        h.listener.say("şey yani")
        h.scheduler.advance(by: T.targetsIdle + 0.1)
        let asked = await waitUntil { h.speaker.spoken.last == Say.passageTargetsAgain && h.vm.phase == .listening }
        XCTAssertTrue(asked)
    }
}
