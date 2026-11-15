import XCTest
@testable import G526CameraDrive

/// Kaizen turu: evet/hayır sorularında bulanık (tek harf farklı) eşleşmenin anlamı tersine çevirmesi. Türkçede olumsuzluk eki tek harf farkıdır
/// ("çekiyorum" / "çekmiyorum", "bitirme" / "bitirmek"): yanlış "evet" kamerayı açar (hücreseli keser) ya da testi bitirir. Kural: evet yalnız
/// AYNEN (ya da aynı sesle) eşleşmeyle; bulanık eşleşme yalnız hayır yönünde; olumsuz biçimler listede açıkça yazılı.
@MainActor
final class VoiceReplyHazardTests: XCTestCase {
    private func confusable(_ a: String, _ b: String) -> Bool {
        let ka = SpokenWords.key(a)
        let kb = SpokenWords.key(b)
        return ka == kb || (ka.count >= 5 && kb.count >= 5 && SpokenWords.withinOneEdit(ka, kb))
    }

    // MARK: Kamera sorusu

    func testCameraNaturalYesAnswers() {
        for text in ["evet", "Tamam.", "çekelim", "çek", "çekeyim", "çekerim", "çekiyorum", "evet çekiyoruz", "çekmek istiyorum", "çekmeyi isterim",
                     "kamerayla çekelim", "kamera ile çek", "kamerayı kullan", "kamerayı kullanalım", "fotoğraf çekelim", "kamerayla", "kamera"] {
            XCTAssertEqual(SpokenReply.cameraChoice(text), .yes, text)
        }
    }

    func testCameraNaturalNoAnswers() {
        for text in ["hayır", "çekmiyorum", "çekmem", "çekme", "çekmeyin", "çekmesin", "çekmek istemiyorum", "kamerayı kullanma", "kamerayı kullanmayalım",
                     "kamerayı kullanmıyorum", "kamera olmasın", "kamera gerekmez", "hayır çekmeyelim", "sesle okuyacağım", "ben okuyacağım", "okurum",
                     "kamerasız", "sesle okuyayım", "kamera değil"] {
            XCTAssertEqual(SpokenReply.cameraChoice(text), .no, text)
        }
    }

    func testCameraUnclearAnswersStayUnclear() {
        for text in ["çekmek", "bitir", "testi bitir", "devam", "cevapları tekrarla", "evet hayır", "çekmek istiyorum ama hayır", "belki", ""] {
            XCTAssertNil(SpokenReply.cameraChoice(text), text)
        }
    }

    /// Sözlüğe sonradan eklenecek her olumlu/olumsuz ikiz için de geçerli: olumsuz biçim ASLA evet olmaz, olumlu biçim hayır olmaz
    func testNoNegativeFormIsEverAcceptedAsYesInTheCameraQuestion() {
        for no in SpokenReply.cameraNo {
            for positive in SpokenReply.cameraYes.union(SpokenReply.cameraWeakYes) where confusable(no, positive) {
                XCTAssertEqual(SpokenReply.cameraChoice(no), .no, "'\(no)' ('\(positive)' ile karışır) evet sayıldı")
                XCTAssertEqual(SpokenReply.cameraChoice(positive), .yes, "'\(positive)' ('\(no)' ile karışır) evet sayılmadı")
            }
        }
    }

    // MARK: Testi bitirme onayı

    func testFinishConfirmationNaturalAnswers() {
        for text in ["evet", "bitirmek istiyorum", "bitirelim", "sonlandırmak istiyorum", "tamamlamak istiyorum", "tamam bitirelim", "evet bitirmeyi isterim"] {
            XCTAssertEqual(SpokenReply.yesNo(text), .yes, text)
        }
        for text in ["hayır", "bitirmiyorum", "bitirmem", "bitirmeyelim", "bitirmek istemiyorum", "bitirme devam edelim", "sonlandırmayın",
                     "devam etmek istiyorum", "vazgeçtim"] {
            XCTAssertEqual(SpokenReply.yesNo(text), .no, text)
        }
    }

    func testNoNegativeFormIsEverAcceptedAsYesInTheFinishQuestion() {
        for no in SpokenReply.no {
            for positive in SpokenReply.yes.union(SpokenReply.confirmWeakYes) where confusable(no, positive) {
                XCTAssertEqual(SpokenReply.yesNo(no), .no, "'\(no)' ('\(positive)' ile karışır) evet sayıldı")
                XCTAssertEqual(SpokenReply.yesNo(positive), .yes, "'\(positive)' ('\(no)' ile karışır) evet sayılmadı")
            }
        }
    }

    // MARK: Cevap okuma sonrası menü

    func testReviewMenuNegatedFinishIsNotAFinishRequest() {
        XCTAssertEqual(SpokenReply.review("bitirme devam"), .continueTest)
        XCTAssertEqual(SpokenReply.review("bitirmeyelim devam edelim"), .continueTest)
        XCTAssertEqual(SpokenReply.review("sonlandırma tekrar oku"), .repeatAnswers)
        XCTAssertEqual(SpokenReply.review("bitirmek istiyorum"), .finishTest)
        XCTAssertEqual(SpokenReply.review("testi tamamlamak istiyorum"), .finishTest)
        XCTAssertEqual(SpokenReply.review("devam"), .continueTest)
        XCTAssertEqual(SpokenReply.review("tekrar"), .repeatAnswers)
        XCTAssertNil(SpokenReply.review("bitirme"), "Tek başına olumsuzluk üç seçenekten biri değildir: yeniden sorulur")
    }

    func testReviewMenuNegationsCannotBeMistakenForFinishing() {
        for negation in SpokenReply.finishNegations {
            XCTAssertEqual(SpokenReply.review("\(negation) devam"), .continueTest, negation)
        }
    }

    /// Seçeneği olumsuzlayan söz hiçbir seçeneği seçmez: "bitirmek istemiyorum" testi bitirmemeli, "devam etmeyelim" devam ettirmemeli
    func testReviewMenuNegatedChoicesAreNeverSelected() {
        for text in ["bitirmek istemiyorum", "testi bitirmek istemiyorum", "devam etmeyelim", "devam etmek istemiyorum", "devam etmiyorum", "tekrar etme",
                     "tekrar etmeyelim", "tekrar dinlemek istemiyorum", "tekrar okuma", "tekrar istemiyorum", "cevapları tekrar dinlemeyelim"] {
            XCTAssertNil(SpokenReply.review(text), text)
        }
        // Olumlu söyleyişler aynen çalışır
        XCTAssertEqual(SpokenReply.review("devam edelim"), .continueTest)
        XCTAssertEqual(SpokenReply.review("kaldığım yerden devam"), .continueTest)
        XCTAssertEqual(SpokenReply.review("tekrar dinle"), .repeatAnswers)
        XCTAssertEqual(SpokenReply.review("cevapları tekrarla"), .repeatAnswers)
        XCTAssertEqual(SpokenReply.review("bitirelim"), .finishTest)
        XCTAssertEqual(SpokenReply.review("testi tamamla"), .finishTest)
    }

    func testStartChoiceNegatedChoicesAreNeverSelected() {
        for text in ["devam etmeyelim", "devam etmek istemiyorum", "önceki kayıttan devam etmeyelim", "devam etmiyorum", "yeni başlamayalım",
                     "yeni sınav istemiyorum", "yeni değil", "önceki değil"] {
            XCTAssertNil(SpokenReply.start(text), text)
        }
        XCTAssertEqual(SpokenReply.start("devam edelim"), .continuePrevious)
        XCTAssertEqual(SpokenReply.start("önceki kayıttan devam"), .continuePrevious)
        XCTAssertEqual(SpokenReply.start("baştan başlayalım"), .startNew)
        XCTAssertEqual(SpokenReply.start("sıfırdan"), .startNew)
        XCTAssertEqual(SpokenReply.start("hayır yeni"), .startNew, "'Hayır' tek başına seçeneği olumsuzlamaz: sorunun iki seçeneği vardır")
    }

    /// Genel kural: olumsuzluk sözü + herhangi bir seçenek sözü = anlaşılmadı (yeniden sorulur)
    func testAnyChoiceNegationMakesTheAnswerUnclear() {
        for negation in SpokenReply.choiceNegations {
            for option in ["devam", "tekrar", "bitirmek", "yeni", "önceki", "baştan"] {
                XCTAssertNil(SpokenReply.review("\(option) \(negation)"), "\(option) \(negation)")
                XCTAssertNil(SpokenReply.start("\(option) \(negation)"), "\(option) \(negation)")
            }
        }
        for negation in SpokenReply.choiceNegations {
            XCTAssertTrue(SpokenReply.finishNegations.isDisjoint(with: [negation]), "'\(negation)' iki listede: bitirme olumsuzlukları ayrı ele alınır")
        }
    }

    // MARK: Olumsuz söz komut değildir

    /// "Testi bitirme" yakın sesli eşleşmeyle ("bitirme" ≈ "bitirmek") testi bitirme komutu sayılırdı; "cevapları tekrarlamayın" cevapları okuturdu
    func testNegatedCommandsAreNeverCommands() {
        for text in ["testi bitirme", "sınavı bitirmem", "testi tamamlama", "testi sonlandırma", "cevapları tekrarlama", "cevapları tekrarlamayın", "cevapları okuma",
                     "cevapları tekrar okuma", "son cevabı tekrarlama", "son cevabı okuma", "beşinci sorunun cevabını tekrarlama", "beşinci sorunun cevabını okuma",
                     "testi bitirmek istemiyorum", "testi bitirmeyelim", "cevapları dinlemek istemiyorum", "soruyu iptal etme"] {
            XCTAssertNil(VoiceCommand.parse(text), text)
        }
        for negation in SpokenReply.finishNegations.union(SpokenReply.choiceNegations) {
            for prefix in ["testi", "sınavı", "cevapları", "son cevabı", "cevapları tekrar", "soruyu", "paragrafı"] {
                XCTAssertNil(VoiceCommand.parse("\(prefix) \(negation)"), "\(prefix) \(negation)")
            }
        }
        // Olumlu komutlar aynen çalışır
        XCTAssertEqual(VoiceCommand.parse("testi bitir"), .endTest)
        XCTAssertEqual(VoiceCommand.parse("sınavı bitirelim"), .endTest)
        XCTAssertEqual(VoiceCommand.parse("testi bitirmek istiyorum"), .endTest)
        XCTAssertEqual(VoiceCommand.parse("cevapları tekrarla"), .replayAnswers)
        XCTAssertEqual(VoiceCommand.parse("son cevabı tekrarla"), .repeatLast)
        XCTAssertEqual(VoiceCommand.parse("beşinci sorunun cevabını tekrarla"), .repeatNumber(5))
        XCTAssertEqual(VoiceCommand.parse("soruyu iptal et"), .cancelQuestion)
        XCTAssertEqual(VoiceCommand.parse("paragrafı iptal et"), .cancelPassage)
    }

    // MARK: Soru metni komut sayılmaz

    /// Soru ve paragraf metninde geçebilecek kısa parçalar (komut sözcüklerine benzeyen sözcüklerle): hiçbiri komut olmamalı, yoksa soru sessizce yutulur
    func testRealisticQuestionFragmentsAreNeverCommands() {
        for text in ["Soru 5", "Soru beş", "Cevap B", "Cevabı yazınız", "Soruyu okuyunuz", "Soruyu yanıtlayınız", "Paragrafı okuyunuz", "Paragrafa göre",
                     "Aşağıdaki paragrafı okuyunuz", "Metni baştan okuyunuz", "Soruyu yeniden okuyunuz", "Testi bitirmek için", "Sınavı iptal etmek",
                     "Bu soruyu iptal ediniz", "Paragrafı silmek", "Soruyu iptal etme", "Paragrafı silme", "iptal et", "sil", "soruyu", "paragraf",
                     "ortak paragraf", "Soru iptal edilmiştir", "Aşağıdaki soruyu temizleyiniz", "Tekrar eden bir sayı", "Paragrafı baştan", "Cevabı sil",
                     "Testi bitirmek için hangisi doğrudur"] {
            XCTAssertNil(VoiceCommand.parse(text), text)
        }
        // Gerçek komutlar yine çalışır
        XCTAssertEqual(VoiceCommand.parse("Soruyu baştan oku"), .cancelQuestion)
        XCTAssertEqual(VoiceCommand.parse("Soruyu iptal edelim lütfen"), .cancelQuestion)
        XCTAssertEqual(VoiceCommand.parse("paragrafı baştan okuyayım"), .cancelPassage)
    }

    // MARK: Akış: olumsuz söz kamerayı başlatmaz

    private func cameraHarness() -> SessionHarness {
        let h = SessionHarness(cameraFlow: true)
        h.trackEvents { name in
            if name == "Kameraya_Gec" { h.health.internet = false }
            if name == "Hücresele_Gec" || name == "Hücresel_Ac" { h.health.internet = true }
        }
        return h
    }

    private func say(_ h: SessionHarness, _ text: String) {
        h.listener.say(text)
        h.scheduler.advance(by: SessionViewModel.Timing.numberConfirm + 0.1)
    }

    func testSayingIAmNotShootingNeverStartsTheCamera() async {
        let h = cameraHarness()
        _ = await h.startListening()
        say(h, "çekmiyorum")
        let voice = await waitUntil(45) { h.vm.listenMode == .question && h.vm.phase == .listening && h.speaker.spoken.last != Say.askCamera }
        XCTAssertTrue(voice, "Hayır: sesle okumaya geçilir: \(h.speaker.spoken)")
        XCTAssertEqual(h.camera.captures, 0, "Olumsuz söz kamerayı başlatmaz")
        XCTAssertTrue(h.shortcuts.runs.isEmpty, "Hücresel kesilmez: \(h.shortcuts.runs)")
    }

    func testSayingIWantToShootStartsTheCamera() async {
        let h = cameraHarness()
        h.camera.results = [.success(FakeCamera.shot())]
        h.answering.results = [.success(FakeAnswering.reply(1))]
        _ = await h.startListening()
        say(h, "çekmek istiyorum")
        let done = await waitUntil(45) { h.vm.answers.count == 1 }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        XCTAssertEqual(h.camera.captures, 1)
    }

    func testSayingIWantToFinishAtTheConfirmationFinishesTheTest() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.listener.say("testi bitir")
        h.scheduler.advance(by: SessionViewModel.Timing.numberConfirm + 0.1)
        let asked = await waitUntil(45) { h.vm.listenMode == .confirmEnd && h.vm.phase == .listening }
        XCTAssertTrue(asked, "\(h.speaker.spoken)")
        say(h, "bitirmek istiyorum")
        let finished = await waitUntil(45) { h.vm.phase == .finished }
        XCTAssertTrue(finished, "'Bitirmek istiyorum' hayır sayılmamalı: \(h.speaker.spoken)")
    }

    func testSayingIDoNotWantToFinishAtTheReviewMenuDoesNotEndTheTest() async {
        let h = SessionHarness()
        h.settings.askMissingNumber = false
        _ = await h.startListening()
        h.answering.results.append(.success(FakeAnswering.reply(1)))
        h.ask("Soru 1. A seçeneği Adana")
        _ = await waitUntil { h.vm.answers.count == 1 && h.vm.phase == .listening }
        say(h, "Cevapları tekrarla")
        let reading = await waitUntil { h.vm.reviewing }
        XCTAssertTrue(reading)
        h.player.finish()
        let asked = await waitUntil { h.vm.listenMode == .reviewMenu && h.vm.phase == .listening }
        XCTAssertTrue(asked, "\(h.speaker.spoken)")
        h.listener.say("bitirmek istemiyorum")
        h.scheduler.advance(by: SessionViewModel.Timing.triggerConfirm + 0.1)
        h.scheduler.advance(by: SessionViewModel.Timing.numberUnclear)
        let again = await waitUntil { h.speaker.spoken.last == Say.reviewMenuAgain && h.vm.listenMode == .reviewMenu && h.vm.phase == .listening }
        XCTAssertTrue(again, "Test bitmemeli, menü yeniden sorulmalı: \(h.speaker.spoken)")
        XCTAssertNotEqual(h.vm.phase, .finished)
        say(h, "devam")
        let back = await waitUntil { h.vm.listenMode == .question && h.vm.phase == .listening }
        XCTAssertTrue(back, "\(h.speaker.spoken)")
    }
}
