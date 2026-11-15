import XCTest
@testable import G526CameraDrive

/// Prosedür denetiminde bulunan eksik komutlar: soruyu iptal et, paragrafı iptal et, belirli bir sorunun cevabını tekrarla; kamera sorusunun
/// doğal cevapları ("kamerayla", "fotoğraf", "çekmeyin"…); komutların ortak paragraf kamera sorusunda da çalışması.
@MainActor
final class VoiceCancelTests: XCTestCase {
    typealias T = SessionViewModel.Timing

    // MARK: Ayrıştırma

    func testCancelQuestionPhrases() {
        for text in ["soruyu iptal et", "Soruyu iptal et.", "lütfen soruyu iptal et", "soruyu sil", "soruyu temizle", "soruyu iptal edelim",
                     "vazgeçtim soruyu sil", "soruyu baştan okuyacağım", "soruyu yeniden okuyayım", "soru iptal"] {
            XCTAssertEqual(VoiceCommand.parse(text), .cancelQuestion, text)
        }
    }

    func testCancelPassagePhrases() {
        for text in ["paragrafı iptal et", "Paragrafı sil", "ortak paragrafı iptal et", "ortak paragrafı sil", "paragrafı temizle",
                     "paragrafı baştan okuyacağım", "paragraf iptal", "lütfen ortak paragrafı iptal et"] {
            XCTAssertEqual(VoiceCommand.parse(text), .cancelPassage, text)
        }
    }

    /// Soru ve paragraf metnindeki sözler komut sayılmaz: yalnız metnin TAMAMI iptal cümlesiyse çalışır
    func testOrdinaryTextIsNeverACancelCommand() {
        for text in ["iptal et", "sil", "soruyu", "paragrafı ve soruyu sil", "bu soruyu iptal etmek için hangisi gerekir",
                     "sözleşmeyi iptal et", "soruyu baştan", "baştan okuyacağım", "paragraf", "ortak paragraf",
                     "aşağıdaki paragrafı sil ve soruya cevap ver"] {
            XCTAssertNil(VoiceCommand.parse(text), text)
        }
    }

    func testNumberedAnswerPhrases() {
        XCTAssertEqual(VoiceCommand.parse("beşinci sorunun cevabını tekrarla"), .repeatNumber(5))
        XCTAssertEqual(VoiceCommand.parse("5. sorunun cevabını oku"), .repeatNumber(5))
        XCTAssertEqual(VoiceCommand.parse("bir numaralı sorunun cevabını oku"), .repeatNumber(1))
        XCTAssertEqual(VoiceCommand.parse("on ikinci sorunun cevabını tekrarla"), .repeatNumber(12))
        XCTAssertEqual(VoiceCommand.parse("lütfen 7. sorunun cevabını söyle"), .repeatNumber(7))
        XCTAssertEqual(VoiceCommand.parse("soru 9 cevabı tekrar"), .repeatNumber(9))
    }

    /// Mevcut komutlar değişmez: numarasız "cevap" komutları eskisi gibidir
    func testExistingCommandsAreUnchanged() {
        XCTAssertEqual(VoiceCommand.parse("son cevabı tekrarla"), .repeatLast)
        XCTAssertEqual(VoiceCommand.parse("tekrarla"), .repeatLast)
        XCTAssertEqual(VoiceCommand.parse("cevapları tekrarla"), .replayAnswers)
        XCTAssertEqual(VoiceCommand.parse("tüm cevapları oku"), .replayAnswers)
        XCTAssertEqual(VoiceCommand.parse("testi bitir"), .endTest)
        XCTAssertEqual(VoiceCommand.parse("bitir"), .endTest)
        XCTAssertNil(VoiceCommand.parse("beşinci sorunun cevabı"), "Fiil yoksa komut değil")
        XCTAssertNil(VoiceCommand.parse("Soru 5 Ali eve gitti"))
    }

    func testCameraChoiceUnderstandsNaturalAnswers() {
        XCTAssertEqual(SpokenReply.cameraChoice("kamerayla"), .yes)
        XCTAssertEqual(SpokenReply.cameraChoice("kamera"), .yes)
        XCTAssertEqual(SpokenReply.cameraChoice("fotoğraf"), .yes)
        XCTAssertEqual(SpokenReply.cameraChoice("çekeyim"), .yes)
        XCTAssertEqual(SpokenReply.cameraChoice("çekmeyin"), .no)
        XCTAssertEqual(SpokenReply.cameraChoice("sesle okuyayım"), .no)
        XCTAssertEqual(SpokenReply.cameraChoice("kamera değil sesle"), .no, "Hayır sözü zayıf evet sözünü bastırır")
        XCTAssertEqual(SpokenReply.cameraChoice("kamera istemiyorum"), .no)
        XCTAssertNil(SpokenReply.cameraChoice("evet sesle"), "Çelişen söz anlaşılmamış sayılır")
        XCTAssertNil(SpokenReply.cameraChoice("soruyu iptal et"), "İptal komutu kamera sorusuna hayır değildir")
        XCTAssertNil(SpokenReply.cameraChoice("paragrafı sil"))
    }

    // MARK: Sesle okuma (kamerasız) akışı

    private func say(_ h: SessionHarness, _ text: String, after: TimeInterval = T.numberConfirm) {
        h.listener.say(text)
        h.scheduler.advance(by: after + 0.1)
    }

    func testCancelQuestionDropsTheDictatedTextAndStartsOver() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.listener.say("Soru 5 Ali eve gitti")
        h.scheduler.advance(by: T.utteranceGap + 0.1)
        say(h, "Soru 5 Ali eve gitti soruyu iptal et")
        let done = await waitUntil(45) { h.speaker.spoken.last == Say.questionCancelled && h.vm.listenMode == .question && h.vm.phase == .listening }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        XCTAssertEqual(h.vm.accumulator.text, "", "Okunan metin silindi")
        XCTAssertTrue(h.answering.calls.isEmpty, "Silinen soru Gemini'ye gitmez")
        h.answering.results = [.success(FakeAnswering.reply(7))]
        h.ask("Soru 7 Yeni soru metni")
        let sent = await waitUntil(45) { h.answering.calls.count == 1 }
        XCTAssertTrue(sent)
        XCTAssertFalse(h.answering.calls[0].question.contains("Ali eve gitti"), "Eski metin yeni soruya karışmaz: \(h.answering.calls[0].question)")
    }

    func testCancelPassageWhileReadingAbandonsIt() async {
        let h = SessionHarness()
        _ = await h.startListening()
        say(h, "ortak paragraf")
        let prompted = await waitUntil(45) { h.speaker.spoken.last == Say.passagePrompt && h.vm.listenMode == .passage && h.vm.phase == .listening }
        XCTAssertTrue(prompted)
        h.listener.say("Ali eve gitti. Sonra okula yürüdü")
        h.scheduler.advance(by: T.utteranceGap + 0.1)
        say(h, "Ali eve gitti. Sonra okula yürüdü paragrafı iptal et")
        let done = await waitUntil(45) { h.speaker.spoken.last == Say.passageCancelled(cameraNext: false) && h.vm.listenMode == .question && h.vm.phase == .listening }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        XCTAssertNil(h.vm.passage)
        XCTAssertNil(h.vm.passageDraft)
        XCTAssertEqual(h.vm.accumulator.text, "")
    }

    func testCancelPassageWhileTheNumbersAreAskedDropsTheDraft() async {
        let h = SessionHarness()
        _ = await h.startListening()
        say(h, "Ortak paragraf Ali eve gitti. Sonra okula yürüdü Tamamlandı", after: T.triggerConfirm)
        let asked = await waitUntil(45) { h.vm.listenMode == .passageTargets && h.vm.phase == .listening }
        XCTAssertTrue(asked)
        XCTAssertNotNil(h.vm.passageDraft)
        say(h, "paragrafı iptal et")
        let done = await waitUntil(45) { h.speaker.spoken.last == Say.passageCancelled(cameraNext: false) && h.vm.listenMode == .question && h.vm.phase == .listening }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        XCTAssertNil(h.vm.passageDraft)
        XCTAssertNil(h.vm.passage, "Numaralar söylenmeden iptal edilen paragraf kaydedilmez")
    }

    /// Kayıtlı ortak paragraf, hem "ortak paragrafı sil" hem "paragrafı iptal et" ile silinir (ilki paragraf başlatmaz)
    func testCancelPassageDeletesTheStoredPassage() async {
        for phrase in ["ortak paragrafı sil", "paragrafı iptal et"] {
            let h = SessionHarness()
            _ = await h.startListening()
            h.vm.passage = PassageContext(text: "Metin.", english: "", audio: nil, all: [5, 6], remaining: [5, 6])
            say(h, phrase)
            let done = await waitUntil(45) { h.speaker.spoken.last == Say.storedPassageCancelled(cameraNext: false) && h.vm.listenMode == .question && h.vm.phase == .listening }
            XCTAssertTrue(done, "\(phrase): \(h.speaker.spoken)")
            XCTAssertNil(h.vm.passage, phrase)
            XCTAssertNil(h.journal.passage, "\(phrase): defterden de silinir")
        }
    }

    func testCancelPassageWithoutOneSaysSo() async {
        let h = SessionHarness()
        _ = await h.startListening()
        say(h, "paragrafı sil")
        let done = await waitUntil(45) { h.speaker.spoken.last == Say.noPassageToCancel(cameraNext: false) && h.vm.phase == .listening }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
    }

    func testRepeatNumberReadsOnlyThatAnswer() async {
        let h = SessionHarness()
        h.answering.results = [.success(FakeAnswering.reply(5)), .success(FakeAnswering.reply(6))]
        _ = await h.startListening()
        h.ask("Soru 5 ilk soru")
        _ = await waitUntil(45) { h.vm.answers.count == 1 && h.vm.phase == .listening }
        h.ask("Soru 6 ikinci soru")
        _ = await waitUntil(45) { h.vm.answers.count == 2 && h.vm.phase == .listening }
        let five = h.vm.answers.first(where: { $0.number == 5 })?.spoken ?? "?"
        let six = h.vm.answers.first(where: { $0.number == 6 })?.spoken ?? "?"
        say(h, "beşinci sorunun cevabını tekrarla")
        let done = await waitUntil(45) { h.speaker.spoken.last == five && h.vm.phase == .listening }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        XCTAssertEqual(h.speaker.spoken.filter { $0 == five }.count, 2, "5. cevap bir kez okundu, bir kez tekrarlandı")
        XCTAssertEqual(h.speaker.spoken.filter { $0 == six }.count, 1, "6. cevap yeniden okunmaz")
        XCTAssertEqual(h.vm.answers.count, 2)
        XCTAssertEqual(h.answering.calls.count, 2, "Komut Gemini'ye gitmez")
    }

    func testRepeatNumberForAnUnansweredQuestionSaysSo() async {
        let h = SessionHarness()
        _ = await h.startListening()
        say(h, "yedinci sorunun cevabını oku")
        let done = await waitUntil(45) { h.speaker.spoken.last == Say.noAnswerFor(7) && h.vm.phase == .listening }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        XCTAssertTrue(h.answering.calls.isEmpty)
    }

    // MARK: Kameralı akış

    private func cameraHarness(shots: [Result<CapturedQuestion, CameraFailure>] = []) -> SessionHarness {
        let h = SessionHarness(cameraFlow: true)
        h.camera.results = shots
        h.trackEvents { name in
            if name == "Kameraya_Gec" { h.health.internet = false }
            if name == "Hücresele_Gec" || name == "Hücresel_Ac" { h.health.internet = true }
        }
        return h
    }

    private func cameraQuestionOpen(_ h: SessionHarness) -> Bool {
        return h.vm.listenMode == .cameraChoice && h.vm.phase == .listening
    }

    func testCancelQuestionAtTheCameraQuestionHasNothingToCancelAndAsksAgain() async {
        let h = cameraHarness()
        _ = await h.startListening()
        say(h, "soruyu iptal et")
        let again = await waitUntil(45) { h.speaker.suffixIs([Say.nothingToCancelQuestion, Say.askCamera]) && self.cameraQuestionOpen(h) }
        XCTAssertTrue(again, "'İptal' kamera sorusuna hayır sayılmaz: \(h.speaker.spoken)")
        XCTAssertEqual(h.camera.captures, 0)
        XCTAssertTrue(h.shortcuts.runs.isEmpty)
    }

    /// "Testi bitir", "cevapları tekrarla" gibi komutlar ortak paragraf kamera sorusunda da çalışır (kamera sorusundaki gibi)
    func testCommandsWorkAtThePassageCameraQuestion() async {
        let h = cameraHarness()
        _ = await h.startListening()
        say(h, "ortak paragraf")
        let asked = await waitUntil(45) { h.vm.listenMode == .passageCameraChoice && h.vm.phase == .listening }
        XCTAssertTrue(asked)
        say(h, "testi bitir")
        let confirm = await waitUntil(45) { h.speaker.spoken.last == Say.confirmEnd && h.vm.listenMode == .confirmEnd && h.vm.phase == .listening }
        XCTAssertTrue(confirm, "Komut anlaşılır, 'Anlayamadım' denmez: \(h.speaker.spoken)")
        XCTAssertEqual(h.camera.captures, 0)
        say(h, "hayır")
        let back = await waitUntil(45) { self.cameraQuestionOpen(h) && h.speaker.spoken.last == Say.askCamera }
        XCTAssertTrue(back, "Vazgeçilince bu soru için kamera yeniden sorulur: \(h.speaker.spoken)")
    }

    /// Ortak paragraf kamera sorusunda "paragrafı iptal et": istek bırakılır, KAYITLI paragraf silinmez, kamera sorusu yeniden gelir
    func testCancelAtThePassageCameraQuestionKeepsTheStoredPassage() async {
        let h = cameraHarness()
        _ = await h.startListening()
        h.vm.passage = PassageContext(text: "Metin.", english: "", audio: nil, all: [5, 6], remaining: [5, 6])
        say(h, "ortak paragraf")
        _ = await waitUntil(45) { h.vm.listenMode == .passageCameraChoice && h.vm.phase == .listening }
        say(h, "paragrafı iptal et")
        let back = await waitUntil(45) { self.cameraQuestionOpen(h) && h.speaker.suffixIs([Say.passageCancelled(cameraNext: true), Say.askCamera]) }
        XCTAssertTrue(back, "\(h.speaker.spoken)")
        XCTAssertNotNil(h.vm.passage, "Yeni paragraf isteği bırakıldı; önceki kayıtlı paragraf durur")
    }

    func testCancelWhileReadingTheCameraPassageAloudRestoresTheCameraQuestion() async {
        let h = cameraHarness()
        _ = await h.startListening()
        say(h, "ortak paragraf")
        _ = await waitUntil(45) { h.vm.listenMode == .passageCameraChoice && h.vm.phase == .listening }
        say(h, "hayır")
        _ = await waitUntil(45) { h.speaker.spoken.last == Say.passageCameraDeclined && h.vm.listenMode == .passage && h.vm.phase == .listening }
        h.listener.say("Ali eve gitti. Sonra okula yürüdü")
        h.scheduler.advance(by: T.utteranceGap + 0.1)
        say(h, "Ali eve gitti. Sonra okula yürüdü paragrafı iptal et")
        let back = await waitUntil(45) { self.cameraQuestionOpen(h) && h.speaker.suffixIs([Say.passageCancelled(cameraNext: true), Say.askCamera]) }
        XCTAssertTrue(back, "\(h.speaker.spoken)")
        XCTAssertNil(h.vm.passage)
        XCTAssertNil(h.vm.passageDraft)
    }

    /// Kamerayla çekilmiş paragraf, numaraları sorulurken iptal edilir: taslağın video dosyası silinir, kamera sorusu yeniden gelir
    func testCancelAfterTheCameraPassageShotDeletesTheVideo() async {
        var shot = FakeCamera.shot()
        shot.photo = Data([9, 9, 9])
        let h = cameraHarness(shots: [.success(shot)])
        _ = await h.startListening()
        say(h, "ortak paragraf")
        _ = await waitUntil(45) { h.vm.listenMode == .passageCameraChoice && h.vm.phase == .listening }
        say(h, "evet")
        let asked = await waitUntil(45) { h.vm.listenMode == .passageTargets && h.vm.phase == .listening }
        XCTAssertTrue(asked, "\(h.speaker.spoken)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: shot.video!.path))
        say(h, "paragrafı iptal et")
        let back = await waitUntil(45) { self.cameraQuestionOpen(h) && h.speaker.suffixIs([Say.passageCancelled(cameraNext: true), Say.askCamera]) }
        XCTAssertTrue(back, "\(h.speaker.spoken)")
        XCTAssertNil(h.vm.passageDraft)
        XCTAssertNil(h.vm.passage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shot.video!.path), "Vazgeçilen paragrafın video dosyası silinir")
    }

    /// "Kamerayla" diyen kullanıcı kamerayı başlatır (yalnız "evet" değil)
    func testSayingKameraylaAtTheCameraQuestionStartsTheCamera() async {
        let h = cameraHarness(shots: [.success(FakeCamera.shot())])
        h.answering.results = [.success(FakeAnswering.reply(1))]
        _ = await h.startListening()
        say(h, "kamerayla")
        let done = await waitUntil(45) { h.vm.answers.count == 1 }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        XCTAssertEqual(h.camera.captures, 1)
    }
}

extension VoiceCancelTests {
    /// Bozuk okunan iptal komutu susulmadan geri bildirim alır (komut denemesi sayılır); soru metni sayılmaz
    func testMisheardCancelCommandIsReportedNotSwallowedSilently() async {
        XCTAssertTrue(CommandAttempt.looksLike("soruyu iptalet"), "Birleşik yazılan komut")
        XCTAssertTrue(CommandAttempt.looksLike("paragrafı iptalet"))
        XCTAssertFalse(CommandAttempt.looksLike("iptal et"), "Konu sözcüğü yok: soru metni olabilir")
        XCTAssertFalse(CommandAttempt.looksLike("soruyu"))
        XCTAssertFalse(CommandAttempt.looksLike("Soru iptal edilmiştir"))
        let h = SessionHarness()
        _ = await h.startListening()
        h.listener.say("soruyu iptalet")
        h.scheduler.advance(by: T.attemptConfirm + 0.1)
        let told = await waitUntil(45) { h.speaker.spoken.last == Say.commandNotUnderstood && h.vm.phase == .listening }
        XCTAssertTrue(told, "\(h.speaker.spoken)")
        XCTAssertEqual(h.vm.accumulator.text, "", "Anlaşılmayan söz soru metnine karışmaz")
    }

    /// Numarası okunmadığı için numara beklenen soru "soruyu iptal et" ile bırakılır: boşuna sıradaki numarayla Gemini'ye gitmez
    func testCancelQuestionWhileTheNumberIsAskedDropsTheHeldQuestion() async {
        let h = SessionHarness()
        h.settings.askMissingNumber = true
        _ = await h.startListening()
        h.ask("Ali eve gitti ve okula yürüdü")
        let asked = await waitUntil(45) { h.vm.listenMode == .missingNumber && h.vm.phase == .listening }
        XCTAssertTrue(asked, "\(h.speaker.spoken)")
        XCTAssertNotNil(h.vm.heldQuestion)
        h.listener.say("soruyu iptal et")
        h.scheduler.advance(by: T.numberConfirm + 0.1)
        let done = await waitUntil(45) { h.speaker.spoken.last == Say.questionCancelled && h.vm.listenMode == .question && h.vm.phase == .listening }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        XCTAssertNil(h.vm.heldQuestion, "Bekleyen soru bırakıldı")
        XCTAssertTrue(h.answering.calls.isEmpty, "Silinen soru Gemini'ye gitmez")
        // Sonraki soru normal gider
        h.answering.results = [.success(FakeAnswering.reply(4))]
        h.ask("Soru 4 Yeni soru")
        let sent = await waitUntil(45) { h.answering.calls.count == 1 }
        XCTAssertTrue(sent)
        XCTAssertFalse(h.answering.calls[0].question.contains("Ali eve gitti"), h.answering.calls[0].question)
    }

    /// Kamera sorusu açıkken "N. sorunun cevabını tekrarla": yalnız o cevap okunur, ardından kamera sorusu yeniden gelir
    func testRepeatNumberAtTheCameraQuestionReadsOnlyThatAnswerAndAsksAgain() async {
        let h = SessionHarness(cameraFlow: true)
        h.trackEvents { name in
            if name == "Kameraya_Gec" { h.health.internet = false }
            if name == "Hücresele_Gec" || name == "Hücresel_Ac" { h.health.internet = true }
        }
        h.camera.results = [.success(FakeCamera.shot())]
        h.answering.results = [.success(FakeAnswering.reply(5))]
        _ = await h.startListening()
        h.listener.say("evet")
        h.scheduler.advance(by: T.numberConfirm + 0.1)
        _ = await waitUntil(45) { h.vm.answers.count == 1 && h.vm.listenMode == .cameraChoice && h.vm.phase == .listening }
        let five = h.vm.answers.first(where: { $0.number == 5 })?.spoken ?? "?"
        h.listener.say("beşinci sorunun cevabını tekrarla")
        h.scheduler.advance(by: T.numberConfirm + 0.1)
        let back = await waitUntil(45) { h.speaker.suffixIs([five, Say.askCamera]) && h.vm.listenMode == .cameraChoice && h.vm.phase == .listening }
        XCTAssertTrue(back, "\(h.speaker.spoken)")
        XCTAssertEqual(h.camera.captures, 1, "Komut yeni çekim başlatmaz")
        XCTAssertEqual(h.answering.captureCalls.count + h.answering.calls.count, 1, "Komut Gemini'ye gitmez")
    }
}

private extension FakeSpeaker {
    /// Söylenenlerin son parçaları verilen sırayla mı
    func suffixIs(_ tail: [String]) -> Bool {
        return Array(spoken.suffix(tail.count)) == tail
    }
}
