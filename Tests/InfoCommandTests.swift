import XCTest
@testable import G526CameraDrive

/// Bilgi ve düzeltme komutları: "yardım", "ne duydun", "son cümleyi sil", "durum", "cevapsız soruları söyle". Her komut yaptığını ya da
/// yapamadığını kısaca söyler; soru metni ve kip bozulmaz, hiçbiri Gemini'ye gitmez.
@MainActor
final class InfoCommandTests: XCTestCase {
    private typealias T = SessionViewModel.Timing

    private let phrases: [(VoiceCommand, [String])] = [
        (.help, ["yardım", "yardım et", "bana yardım et", "komutlar neler", "komutları söyle", "hangi komutlar var", "ne diyebilirim",
                 "neler söyleyebilirim", "komutları say", "lütfen yardım", "komutlar nedir", "hangi komutları söyleyebilirim"]),
        (.whatHeard, ["ne duydun", "ne duydunuz", "ne anladın", "şu ana kadar ne duydun", "duyduğunu oku", "duyduğunu söyle", "anladığını söyle",
                      "duyduğunuzu okuyun", "şimdiye kadar ne anladın"]),
        (.deleteLast, ["son cümleyi sil", "son cümleyi iptal et", "son sözü sil", "son kısmı sil", "az önce söylediğimi sil", "son cümleyi temizle",
                       "lütfen son cümleyi sil", "son sözü iptal et"]),
        (.status, ["durum", "durumu söyle", "durum nedir", "durum ne", "neredeyiz", "durum raporu", "durum bilgisi ver", "kaç soru cevaplandı",
                   "kaç cevap var", "şu ana kadar kaç soru cevaplandı", "kaçıncı soru", "kaç soru çözdük", "genel durumu söyle"]),
        (.missingAnswers, ["cevapsız soruları söyle", "cevapsız sorular hangileri", "eksik soruları söyle", "hangi sorular cevapsız",
                           "hangi soruları atladım", "atlanan soruları söyle", "cevabı olmayan sorular", "cevapsız soru var mı",
                           "eksik cevaplar hangileri", "atladığım soruları oku"])
    ]

    // MARK: Çözümleme

    func testManyWaysOfSayingEachInfoCommandAreUnderstood() {
        for (command, texts) in phrases {
            for text in texts {
                XCTAssertEqual(VoiceCommand.parse(text), command, text)
                XCTAssertEqual(VoiceCommand.parseLenient(text), command, text)
            }
        }
        for text in ["Yardım.", "YARDIM", "Durum!", "Ne duydun?", "Son cümleyi sil."] {
            XCTAssertTrue(VoiceCommand.parseLenient(text)?.isInfo == true, text)
        }
    }

    /// Soru ve paragraf metninde geçebilecek parçalar, olumsuz söyleyişler ve tek başına belirsiz sözler komut değildir
    func testQuestionTextAndNegatedOrVagueWordsAreNotInfoCommands() {
        for text in ["yardım etme", "durumu söyleme", "son cümleyi silme", "cevapsız soruları söyleme", "komutları söylemeyin", "Aşağıdaki durumlardan hangisi",
                     "Durum analizi yapınız", "Soru 5 durum", "yardım almak", "Cevapsız bırakılan soru", "kaç", "son", "cümle", "sil", "ne", "komut",
                     "son cümle", "iptal et", "son soruyu sil", "son cevabı sil", "Metindeki son cümleyi bulunuz", "Kaç tane soru cevaplandı",
                     "Hangi komutlar kullanılır", "Aşağıdaki cümleyi okuyunuz", "evet", "hayır", "tamam", "devam", "tekrar", "bitir", "atlanan"] {
            XCTAssertNotEqual(VoiceCommand.parse(text)?.isInfo, true, text)
        }
    }

    func testOldCommandsKeepTheirMeaning() {
        XCTAssertEqual(VoiceCommand.parse("testi bitir"), .endTest)
        XCTAssertEqual(VoiceCommand.parse("cevapları tekrarla"), .replayAnswers)
        XCTAssertEqual(VoiceCommand.parse("son cevabı tekrarla"), .repeatLast)
        XCTAssertEqual(VoiceCommand.parse("tekrarla"), .repeatLast)
        XCTAssertEqual(VoiceCommand.parse("beşinci sorunun cevabını tekrarla"), .repeatNumber(5))
        XCTAssertEqual(VoiceCommand.parse("soruyu iptal et"), .cancelQuestion)
        XCTAssertEqual(VoiceCommand.parse("paragrafı iptal et"), .cancelPassage)
        XCTAssertEqual(VoiceCommand.parse("anlamadım"), .repeatSpeech)
        XCTAssertEqual(VoiceCommand.parse("bir daha söyle"), .repeatSpeech)
        XCTAssertNil(VoiceCommand.parse("testi bitirme"))
        XCTAssertFalse(VoiceCommand.repeatSpeech.isInfo)
        XCTAssertFalse(VoiceCommand.endTest.isInfo)
    }

    func testInfoCommandsAreHintedToTheRecognizer() {
        for word in ["Yardım", "Ne duydun", "Son cümleyi sil", "Durum", "Cevapsız soruları söyle"] {
            XCTAssertTrue(ListenHints.dictation.strings.contains(word), word)
        }
        XCTAssertTrue(ListenHints.choice.strings.contains("Yardım"))
        XCTAssertLessThanOrEqual(OnDeviceSpeechListener.contextualStrings.count, 100)
    }

    // MARK: Söylenen cümleler

    func testSpokenSentencesOnlyMentionWhatIsKnown() {
        XCTAssertEqual(Say.status(answers: 0, next: 1, headphones: nil, internet: .unknown, battery: nil, charging: false),
                       "Henüz cevaplanan soru yok. Sıradaki soru numarası 1.")
        XCTAssertEqual(Say.status(answers: 4, next: 5, headphones: true, internet: .up, battery: 80, charging: true),
                       "4 soru cevaplandı. Sıradaki soru numarası 5. Kulaklık bağlı. İnternet var. Pil yüzde 80, şarjda.")
        XCTAssertEqual(Say.status(answers: 2, next: 3, headphones: false, internet: .down, battery: 15, charging: false),
                       "2 soru cevaplandı. Sıradaki soru numarası 3. Kulaklıkta sorun var. İnternet yok. Pil yüzde 15.")
        XCTAssertTrue(Say.status(answers: 2, next: 3, headphones: nil, internet: .suspect, battery: nil, charging: false).hasSuffix("İnternet kararsız."))
        XCTAssertEqual(Say.missingAnswers([], highest: 0), "Henüz cevaplanan soru yok.")
        XCTAssertEqual(Say.missingAnswers([], highest: 6), "Cevapsız soru yok. 6 numaraya kadar hepsi cevaplandı.")
        XCTAssertEqual(Say.missingAnswers([2, 5, 9], highest: 10), "Cevabı olmayan sorular: 2, 5 ve 9.")
        let many = Array(1...20)
        XCTAssertEqual(Say.missingAnswers(many, highest: 21), "Cevabı olmayan sorular: 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 ve 12 ve devamı.")
        XCTAssertEqual(Say.heard("Soru 2 Ali eve gitti"), "Duyduğum: Soru 2 Ali eve gitti.")
        let long = (1...40).map { "s\($0)" }.joined(separator: " ")
        let heard = Say.heard(long)
        XCTAssertTrue(heard.hasPrefix("Metin uzun. Duyduğum son 30 sözcük: s11 "), heard)
        XCTAssertTrue(heard.hasSuffix(" s40."), heard)
        XCTAssertEqual(Say.lastSentenceDeleted(["Sonra", "okula", "yürüdü"], remaining: true),
                       "Son cümle silindi: Sonra okula yürüdü. Soruyu okumaya devam edebilirsiniz.")
        XCTAssertEqual(Say.lastSentenceDeleted((1...12).map { "k\($0)" }, remaining: false),
                       "Son cümle silindi: k1 k2 k3 k4 k5 k6 k7 k8 ve devamı. Soru metni boş kaldı, baştan okuyabilirsiniz.")
    }

    // MARK: Akış yardımcıları

    private func say(_ h: SessionHarness, _ text: String) {
        h.listener.say(text)
        h.scheduler.advance(by: T.numberConfirm + 0.1)
    }

    /// Komutu söyler; program tam bir cümle söyleyip aynı kipte dinlemeye dönene kadar bekler ve söylediği cümleyi verir
    private func command(_ h: SessionHarness, _ text: String, mode: ListenMode = .question,
                         file: StaticString = #filePath, line: UInt = #line) async -> String? {
        let before = h.speaker.spoken.count
        say(h, text)
        let done = await waitUntil(45) { h.speaker.spoken.count == before + 1 && h.vm.phase == .listening && h.vm.listenMode == mode }
        XCTAssertTrue(done, "'\(text)' sonrası program bir cümle söyleyip dinlemeye dönmedi: \(h.speaker.spoken)", file: file, line: line)
        return h.speaker.spoken.last
    }

    private func answer(_ h: SessionHarness, number: Int) async {
        h.answering.results.append(.success(FakeAnswering.reply(number)))
        let before = h.vm.answers.count
        h.ask("Soru \(number). A seçeneği Adana")
        _ = await waitUntil(45) { h.vm.answers.count == before + 1 && h.vm.phase == .listening }
    }

    // MARK: Yardım

    func testHelpListsTheCommandsAtTheQuestionAndGoesNowhere() async {
        let h = SessionHarness()
        _ = await h.startListening()
        let said = await command(h, "yardım")
        XCTAssertEqual(said, Say.helpCommands)
        for word in ["Başla", "Testi bitir", "Cevapları tekrarla", "Son cümleyi sil", "Ne duydun", "Durum", "Cevapsız soruları söyle", "bir daha söyle"] {
            XCTAssertTrue(Say.helpCommands.contains(word), word)
        }
        XCTAssertTrue(h.answering.calls.isEmpty, "Yardım Gemini'ye gitmez")
        XCTAssertEqual(h.vm.answers.count, 0)
        // Sonra normal soru
        h.answering.results = [.success(FakeAnswering.reply(1))]
        h.ask("Soru 1 Yeni soru metni")
        let sent = await waitUntil(45) { h.answering.calls.count == 1 }
        XCTAssertTrue(sent)
        XCTAssertFalse(h.answering.calls[0].question.contains("yardım"), h.answering.calls[0].question)
    }

    func testHelpAtTheCameraQuestionAsksTheCameraQuestionAgain() async {
        let h = SessionHarness(cameraFlow: true)
        _ = await h.startListening()
        let open = await waitUntil(45) { h.vm.listenMode == .cameraChoice && h.vm.phase == .listening }
        XCTAssertTrue(open, "\(h.speaker.spoken)")
        let said = await command(h, "komutlar neler", mode: .cameraChoice)
        XCTAssertTrue(said?.hasPrefix(Say.helpCommands) == true, "\(String(describing: said))")
        XCTAssertTrue(said?.hasSuffix(Say.askCamera) == true, "Komutlar sayıldıktan sonra kamera sorusu yeniden sorulur: \(String(describing: said))")
        XCTAssertEqual(h.camera.captures, 0, "Yardım kamerayı açmaz")
        XCTAssertTrue(h.shortcuts.runs.isEmpty)
    }

    func testHelpAtAChoiceQuestionRepeatsThatQuestion() async {
        let h = SessionHarness()
        _ = await h.startListening()
        say(h, "testi bitir")
        let asked = await waitUntil(45) { h.vm.listenMode == .confirmEnd && h.vm.phase == .listening }
        XCTAssertTrue(asked, "\(h.speaker.spoken)")
        let said = await command(h, "yardım", mode: .confirmEnd)
        XCTAssertEqual(said, Say.confirmEnd, "Evet/hayır sorusunda sorunun kendisi ne söylenmesi gerektiğini anlatır")
        say(h, "hayır")
        let back = await waitUntil(45) { h.speaker.spoken.last == Say.endCancelled && h.vm.listenMode == .question && h.vm.phase == .listening }
        XCTAssertTrue(back, "\(h.speaker.spoken)")
    }

    // MARK: Durum

    func testStatusSaysHowManyAnswersAndWhichNumberIsNext() async {
        let h = SessionHarness()
        h.battery.set(80, charging: true)
        _ = await h.startListening()
        var said = await command(h, "durum")
        XCTAssertTrue(said?.hasPrefix("Henüz cevaplanan soru yok. Sıradaki soru numarası \(h.vm.nextNumber).") == true, "\(String(describing: said))")
        await answer(h, number: 1)
        await answer(h, number: 2)
        said = await command(h, "kaç soru cevaplandı")
        XCTAssertTrue(said?.hasPrefix("2 soru cevaplandı. Sıradaki soru numarası \(h.vm.nextNumber).") == true, "\(String(describing: said))")
        XCTAssertTrue(said?.contains("Pil yüzde 80, şarjda.") == true, "\(String(describing: said))")
        XCTAssertEqual(h.answering.calls.count, 2, "Durum sorusu Gemini'ye gitmez")
        XCTAssertEqual(h.vm.answers.count, 2)
    }

    // MARK: Cevapsız sorular

    func testMissingAnswersNamesTheSkippedNumbers() async {
        let h = SessionHarness()
        _ = await h.startListening()
        var said = await command(h, "cevapsız soruları söyle")
        XCTAssertEqual(said, "Henüz cevaplanan soru yok.")
        await answer(h, number: 1)
        await answer(h, number: 3)
        await answer(h, number: 6)
        said = await command(h, "hangi sorular cevapsız")
        XCTAssertEqual(said, "Cevabı olmayan sorular: 2, 4 ve 5.")
        await answer(h, number: 2)
        await answer(h, number: 4)
        await answer(h, number: 5)
        said = await command(h, "eksik soruları söyle")
        XCTAssertEqual(said, "Cevapsız soru yok. 6 numaraya kadar hepsi cevaplandı.")
    }

    // MARK: Ne duydun

    func testWhatHeardReadsTheQuestionSoFarAndKeepsIt() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.listener.say("Soru 2 Ali eve gitti")
        h.scheduler.advance(by: T.utteranceGap + 0.1)
        let said = await command(h, "Soru 2 Ali eve gitti ne duydun")
        XCTAssertEqual(said, "Duyduğum: Soru 2 Ali eve gitti.")
        XCTAssertEqual(h.vm.accumulator.text, "Soru 2 Ali eve gitti", "Okunan metin korunur, yalnız komut atılır")
        // Okumaya kaldığı yerden devam edilir
        h.answering.results = [.success(FakeAnswering.reply(2))]
        h.listener.say("Sonra okula yürüdü Cevapla")
        h.scheduler.advance(by: T.triggerConfirm + 0.1)
        let sent = await waitUntil(45) { h.answering.calls.count == 1 }
        XCTAssertTrue(sent, "\(h.speaker.spoken)")
        XCTAssertTrue(h.answering.calls[0].question.contains("Ali eve gitti Sonra okula yürüdü"), h.answering.calls[0].question)
        XCTAssertFalse(h.answering.calls[0].question.contains("duydun"), h.answering.calls[0].question)
    }

    func testWhatHeardSaysSoWhenNothingWasHeardOrNoQuestionIsListenedTo() async {
        let h = SessionHarness()
        _ = await h.startListening()
        var said = await command(h, "ne duydun")
        XCTAssertEqual(said, Say.nothingHeard)
        say(h, "testi bitir")
        let asked = await waitUntil(45) { h.vm.listenMode == .confirmEnd && h.vm.phase == .listening }
        XCTAssertTrue(asked, "\(h.speaker.spoken)")
        said = await command(h, "ne duydun", mode: .confirmEnd)
        XCTAssertEqual(said, Say.noQuestionText)
    }

    // MARK: Son cümleyi sil

    func testDeleteLastSentenceRemovesOnlyTheLastSpokenPart() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.listener.say("Soru 2 Ali eve gitti")
        h.scheduler.advance(by: T.utteranceGap + 0.1)
        h.listener.say("Soru 2 Ali eve gitti Sonra okula yürüdü")
        h.scheduler.advance(by: T.utteranceGap + 0.1)
        let said = await command(h, "Soru 2 Ali eve gitti Sonra okula yürüdü son cümleyi sil")
        XCTAssertEqual(said, Say.lastSentenceDeleted(["Sonra", "okula", "yürüdü"], remaining: true))
        XCTAssertEqual(h.vm.accumulator.text, "Soru 2 Ali eve gitti", "Yalnız son söz silinir")
        XCTAssertTrue(h.answering.calls.isEmpty)
        // Doğru cümleyle devam edilir ve soru öyle gider
        h.answering.results = [.success(FakeAnswering.reply(2))]
        h.listener.say("Sonra eve döndü Cevapla")
        h.scheduler.advance(by: T.triggerConfirm + 0.1)
        let sent = await waitUntil(45) { h.answering.calls.count == 1 }
        XCTAssertTrue(sent, "\(h.speaker.spoken)")
        let question = h.answering.calls[0].question
        XCTAssertTrue(question.contains("Ali eve gitti Sonra eve döndü"), question)
        XCTAssertFalse(question.contains("okula"), "Silinen cümle soruya karışmaz: \(question)")
        XCTAssertFalse(question.contains("sil"), question)
    }

    func testDeleteLastSentenceCanEmptyTheQuestionOrFindNothingToDelete() async {
        let h = SessionHarness()
        _ = await h.startListening()
        var said = await command(h, "son cümleyi sil")
        XCTAssertEqual(said, Say.nothingToDelete, "Silinecek bir şey yoksa bunu söyler")
        h.listener.say("Soru 2 Ali eve gitti")
        h.scheduler.advance(by: T.utteranceGap + 0.1)
        said = await command(h, "Soru 2 Ali eve gitti son cümleyi sil")
        XCTAssertEqual(said, Say.lastSentenceDeleted(["Soru", "2", "Ali", "eve", "gitti"], remaining: false))
        XCTAssertEqual(h.vm.accumulator.text, "", "Tek söz silinince soru metni boş kalır")
    }

    // MARK: Cevapla ile birlikte

    func testInfoCommandBeforeCevaplaIsNotSentAsAQuestion() async {
        let h = SessionHarness()
        _ = await h.startListening()
        let before = h.speaker.spoken.count
        h.listener.say("durum Cevapla")
        h.scheduler.advance(by: T.triggerConfirm + 0.1)
        let done = await waitUntil(45) { h.speaker.spoken.count == before + 1 && h.vm.phase == .listening && h.vm.listenMode == .question }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        XCTAssertTrue(h.speaker.spoken.last?.hasPrefix("Henüz cevaplanan soru yok.") == true, "\(h.speaker.spoken)")
        XCTAssertTrue(h.answering.calls.isEmpty, "Komut soru gibi gitmez")
    }

    func testDeleteLastSentenceBeforeCevaplaKeepsTheEarlierQuestionOutOfTheSend() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.listener.say("Soru 2 Ali eve gitti")
        h.scheduler.advance(by: T.utteranceGap + 0.1)
        let before = h.speaker.spoken.count
        h.listener.say("Soru 2 Ali eve gitti son cümleyi sil Cevapla")
        h.scheduler.advance(by: T.triggerConfirm + 0.1)
        let done = await waitUntil(45) { h.speaker.spoken.count == before + 1 && h.vm.phase == .listening && h.vm.listenMode == .question }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        XCTAssertEqual(h.speaker.spoken.last, Say.lastSentenceDeleted(["Soru", "2", "Ali", "eve", "gitti"], remaining: false))
        XCTAssertTrue(h.answering.calls.isEmpty, "Silinen soru ve komut Gemini'ye gitmez")
    }

    // MARK: Her komut yaptığını ya da yapamadığını söyler

    func testEveryCommandSaysWhatItDidOrThatItCouldNot() async {
        let h = SessionHarness()
        _ = await h.startListening()
        let table: [(String, String)] = [
            ("son cevabı tekrarla", Say.nothingToReplay),
            ("beşinci sorunun cevabını tekrarla", Say.noAnswerFor(5)),
            ("soruyu iptal et", Say.nothingToCancelQuestion),
            ("paragrafı iptal et", Say.noPassageToCancel(cameraNext: false)),
            ("son cümleyi sil", Say.nothingToDelete),
            ("ne duydun", Say.nothingHeard),
            ("cevapsız soruları söyle", "Henüz cevaplanan soru yok."),
            ("yardım", Say.helpCommands)
        ]
        for (text, expected) in table {
            let said = await command(h, text)
            XCTAssertEqual(said, expected, text)
        }
        XCTAssertTrue(h.answering.calls.isEmpty)
        XCTAssertEqual(h.vm.answers.count, 0)
    }

    /// "Soruyu iptal et" okunmuş bir soru varken siler ve söyler; yokken silecek bir şey olmadığını söyler
    func testCancelQuestionSaysDeletedOnlyWhenSomethingWasRead() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.listener.say("Soru 5 Ali eve gitti")
        h.scheduler.advance(by: T.utteranceGap + 0.1)
        var said = await command(h, "Soru 5 Ali eve gitti soruyu iptal et")
        XCTAssertEqual(said, Say.questionCancelled)
        said = await command(h, "soruyu iptal et")
        XCTAssertEqual(said, Say.nothingToCancelQuestion)
    }
}
