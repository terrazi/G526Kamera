import XCTest
@testable import G526CameraDrive

/// Söylenenin tek seferde anlaşılması: komutların, evet/hayır/devam cevaplarının, sayıların söyleyiş çeşitleri, tanıyıcının yakın sesli
/// yazımları ("peş", "yeti", "dörd") ve komutların birbirine karışmaması
final class SpokenGrammarTests: XCTestCase {
    // MARK: Ses anahtarı ve yakınlık

    func testSoundKeyTreatsVoicedAndVoicelessPairsAlike() {
        XCTAssertEqual(SpokenWords.key("bes"), SpokenWords.key("pes"))
        XCTAssertEqual(SpokenWords.key("dort"), SpokenWords.key("dord"))
        XCTAssertEqual(SpokenWords.key("yedi"), SpokenWords.key("yeti"))
        XCTAssertEqual(SpokenWords.key("sekiz"), SpokenWords.key("sekis"))
        XCTAssertNotEqual(SpokenWords.key("bes"), SpokenWords.key("alti"))
    }

    func testWithinOneEdit() {
        XCTAssertTrue(SpokenWords.withinOneEdit("tekrarla", "tekrarla"))
        XCTAssertTrue(SpokenWords.withinOneEdit("tekrarla", "tekrala"), "silme")
        XCTAssertTrue(SpokenWords.withinOneEdit("tekrarla", "tekrarlar"), "ekleme")
        XCTAssertTrue(SpokenWords.withinOneEdit("tekrarla", "tekrerla"), "değiştirme")
        XCTAssertTrue(SpokenWords.withinOneEdit("tekrarla", "tekarrla"), "yer değiştirme")
        XCTAssertFalse(SpokenWords.withinOneEdit("tekrarla", "tekrxxla"))
        XCTAssertFalse(SpokenWords.withinOneEdit("bitir", "devam"))
    }

    func testShortWordsNeedTheSameSoundBeyondThatNoGuessing() {
        XCTAssertTrue(SpokenWords.matches("pitir", ["bitir"]))
        XCTAssertFalse(SpokenWords.matches("evat", ["evet"]), "Kısa sözcükte tek harf farkı kabul edilmez")
        XCTAssertTrue(SpokenWords.matches("tekrala", ["tekrarla"]), "Uzun sözcükte tek harf farkı kabul edilir")
    }

    // MARK: Komutlar

    func testEndCommandVariations() {
        for text in ["Testi bitir", "testi bitirelim", "sınavı bitirelim", "sınavı sonlandır", "testi sonlandıralım", "test bitti", "sınav bitti",
                     "testi tamamla", "sınavı tamamlayalım", "bitir", "bitirelim", "lütfen testi bitirin", "testi bitirmek istiyorum",
                     "testi pitir", "TESTİ BİTİR.", "evet sınavı bitir", "Sınavı artık bitirelim"] {
            XCTAssertEqual(VoiceCommand.parse(text), .endTest, text)
        }
    }

    func testRepeatLastVersusReplayAllAreNeverMixedUp() {
        for text in ["tekrarla", "tekrar et", "son cevabı tekrarla", "cevabı tekrar et", "cevabı oku", "son cevabı oku", "sonuncuyu tekrar oku"] {
            XCTAssertEqual(VoiceCommand.parse(text), .repeatLast, text)
        }
        for text in ["cevapları tekrarla", "cevapları tekrar et", "tüm cevapları oku", "bütün cevapları baştan oku", "cevapları yeniden oku",
                     "cevapları dinleyelim", "hepsini tekrarla", "hepsini oku", "cevapları bir daha oku", "cevapları tekrarlar mısın",
                     "cevapları dekrarla"] {
            XCTAssertEqual(VoiceCommand.parse(text), .replayAnswers, text)
        }
    }

    func testOrdinaryQuestionSentencesAreNeverCommands() {
        for text in ["Testi bitirmek için hangisi doğrudur", "Aşağıdaki cevapları tekrar okuyunuz ve işaretleyiniz", "tekrar eden bir sayı",
                     "Soru beş. Hangisi doğrudur", "cevapları karşılaştırınız", "Testi tekrarlamak gerekir mi"] {
            XCTAssertNil(VoiceCommand.parse(text), text)
        }
    }

    // MARK: Evet / hayır / devam / yeni

    func testYesNoVariations() {
        for text in ["evet", "Evet bitirelim", "tamam", "olur", "aynen", "tabii", "evet testi bitir", "sınav bitti"] {
            XCTAssertEqual(SpokenReply.yesNo(text), .yes, text)
        }
        for text in ["hayır", "hayir", "vazgeç", "vazgeçtim", "iptal", "devam", "devam et", "yok", "olmaz", "hayır bitirme devam edelim"] {
            XCTAssertEqual(SpokenReply.yesNo(text), .no, text)
        }
        XCTAssertNil(SpokenReply.yesNo("evet hayır"))
        XCTAssertNil(SpokenReply.yesNo("belki"))
    }

    func testStartChoiceVariations() {
        for text in ["devam", "önceki kayıttan devam", "önceki kayıttan sorulara devam edelim", "eski kayıttan devam et", "kaldığımız yerden"] {
            XCTAssertEqual(SpokenReply.start(text), .continuePrevious, text)
        }
        for text in ["yeni", "yeni sınav", "yeni sınava başlayalım", "baştan başlayalım", "sıfırdan"] {
            XCTAssertEqual(SpokenReply.start(text), .startNew, text)
        }
        XCTAssertNil(SpokenReply.start("yeni ama önceki de devam"))
    }

    func testReviewMenuVariations() {
        for text in ["Bitir", "bitirelim", "testi bitir", "testi bitirelim lütfen", "tamamla", "testi tamamla", "sınavı tamamlayalım", "kapat",
                     "bitirmek istiyorum", "sonlandır", "pitir"] {
            XCTAssertEqual(SpokenReply.review(text), .finishTest, text)
        }
        for text in ["Tekrar", "tekrarla", "cevapları tekrarla", "cevapları yeniden oku", "baştan oku", "bir daha oku", "tekrar dinleyelim",
                     "yeniden dinle", "dekrar"] {
            XCTAssertEqual(SpokenReply.review(text), .repeatAnswers, text)
        }
        for text in ["Devam", "devam et", "teste devam", "teste devam edelim", "kaldığım yerden devam", "soruya devam edelim", "sonraki soru",
                     "sıradaki soru", "sürdürelim", "devam edelim lütfen"] {
            XCTAssertEqual(SpokenReply.review(text), .continueTest, text)
        }
        for text in ["tamam", "evet", "hayır", "", "belki", "tekrar devam", "bitir devam", "tamam bitir devam"] {
            XCTAssertNil(SpokenReply.review(text), "Anlaşılmayan ya da çelişen söz: \(text)")
        }
    }

    // MARK: Komutlar birbirine karışmaz

    private func confusable(_ a: String, _ b: String) -> Bool {
        let ka = SpokenWords.key(a)
        let kb = SpokenWords.key(b)
        return ka == kb || (ka.count >= 5 && kb.count >= 5 && SpokenWords.withinOneEdit(ka, kb))
    }

    private func assertNoConfusion(_ first: (String, Set<String>), _ second: (String, Set<String>), file: StaticString = #filePath, line: UInt = #line) {
        for a in first.1 {
            for b in second.1 where confusable(a, b) {
                XCTFail("\(first.0) '\(a)' ile \(second.0) '\(b)' karışabilir", file: file, line: line)
            }
        }
    }

    func testVocabulariesOfDifferentIntentsCannotBeConfusedWithEachOther() {
        let groups: [(String, Set<String>)] = [
            ("konu", VoiceCommand.subjects), ("bitirme", VoiceCommand.endVerbs), ("tekrar", VoiceCommand.repeatVerbs),
            ("çoğul", VoiceCommand.allMarkers), ("tekil", VoiceCommand.lastMarkers), ("dolgu", VoiceCommand.fillers)
        ]
        for i in 0..<groups.count {
            for j in (i + 1)..<groups.count { assertNoConfusion(groups[i], groups[j]) }
        }
        assertNoConfusion(("evet", SpokenReply.yes), ("hayır", SpokenReply.no))
        assertNoConfusion(("devam", SpokenReply.continueWords), ("yeni", SpokenReply.newWords))
        assertNoConfusion(("menü-bitir", SpokenReply.reviewFinish), ("menü-devam", SpokenReply.reviewContinue))
        assertNoConfusion(("menü-bitir", SpokenReply.reviewFinish), ("menü-tekrar", VoiceCommand.repeatVerbs))
        assertNoConfusion(("menü-devam", SpokenReply.reviewContinue), ("menü-tekrar", VoiceCommand.repeatVerbs))
    }

    // MARK: Sayılar

    func testNumberListsInEveryWayOfSayingThem() {
        let cases: [(String, [Int])] = [
            ("5 6 7", [5, 6, 7]), ("5, 6, 7", [5, 6, 7]), ("567", [5, 6, 7]), ("beş altı yedi", [5, 6, 7]), ("beş, altı ve yedi", [5, 6, 7]),
            ("5. soru, 6. soru, 7. soru", [5, 6, 7]), ("beşinci soru altıncı soru yedinci soru", [5, 6, 7]), ("5 ile 7 arası", [5, 6, 7]),
            ("beşten yediye kadar", [5, 6, 7]), ("5-7", [5, 6, 7]), ("on iki, on üç", [12, 13]), ("yirmi beş yirmi altı", [25, 26])
        ]
        for (text, expected) in cases { XCTAssertEqual(SpokenNumber.list(from: text), expected, text) }
    }

    func testNumbersWrittenWithSimilarSoundsAreUnderstood() {
        let cases: [(String, [Int])] = [
            ("peş altı yeti", [5, 6, 7]), ("beş alti yedi", [5, 6, 7]), ("dörd üç iki", [2, 3, 4]), ("sekis dokus", [8, 9]),
            ("peşten yediye kadar", [5, 6, 7]), ("peşinci soru altıncı soru yedinci soru", [5, 6, 7])
        ]
        for (text, expected) in cases { XCTAssertEqual(SpokenNumber.list(from: text), expected, text) }
    }

    func testSingleNumberReplies() {
        let cases: [(String, Int?)] = [
            ("yedi", 7), ("soru yedi", 7), ("numara on", 10), ("yirmi beş", 25), ("peş", 5), ("yeti", 7), ("soru yeti", 7), ("dörd", 4),
            ("sekis", 8), ("dokus", 9), ("yedi mi", nil), ("hmm", nil), ("evet", nil)
        ]
        for (text, expected) in cases { XCTAssertEqual(SpokenNumber.standalone(from: text), expected, text) }
    }

    func testQuestionNumberAtTheStartToleratesSimilarSounds() {
        XCTAssertEqual(SpokenNumber.extract(from: "peşinci soru Ali eve gitti"), 5)
        XCTAssertEqual(SpokenNumber.extract(from: "soru yeti Ali eve gitti"), 7)
        XCTAssertEqual(SpokenNumber.extract(from: "Soru 12 Ali eve gitti"), 12)
        XCTAssertNil(SpokenNumber.extract(from: "Ali eve gitti peş soru"), "Numara okumanın başında söylenir")
    }

    func testOrdinaryWordsAreNotTurnedIntoNumbers() {
        for word in ["için", "ait", "olan", "sorular", "paragraf", "ortak", "yeni", "yedek", "altın", "üçgen", "birlikte", "pek", "sonra", "hepsi"] {
            XCTAssertEqual(SpokenNumber.numberWord(SpokenNumber.tokens(word).first ?? word), SpokenNumber.tokens(word).first ?? word, word)
        }
    }

    // MARK: Tetikleyici sözcükler

    func testTriggerWordsWithSimilarSoundingSpellings() {
        XCTAssertEqual(TriggerDetector.match(in: "Anayasa nedir cevabla")?.question, "Anayasa nedir")
        XCTAssertEqual(TriggerDetector.match(in: "Anayasa nedir ceva pla")?.question, "Anayasa nedir", "Bölünmüş")
        XCTAssertNotNil(TriggerDetector.match(in: "5 6 7 damam", words: PassageCommand.targetWords))
        XCTAssertNotNil(TriggerDetector.match(in: "5 6 7 tamamlandi", words: PassageCommand.targetWords))
        XCTAssertNil(TriggerDetector.match(in: "doğru cevaplar"))
        XCTAssertNil(TriggerDetector.match(in: "doğru cevap"))
    }

    func testOrtakParagrafIsRecognizedInDamagedForms() {
        XCTAssertEqual(PassageCommand.startLength("ortak paragraf Ali"), 2)
        XCTAssertEqual(PassageCommand.startLength("Ortak paragrafı Ali"), 2)
        XCTAssertEqual(PassageCommand.startLength("ortag baragraf Ali"), 2, "b/p ve g/k karışması")
        XCTAssertEqual(PassageCommand.startLength("ortak para graf Ali"), 3, "Bölünmüş")
        XCTAssertEqual(PassageCommand.startLength("ortakparagraf Ali"), 1, "Bitişik")
        XCTAssertEqual(PassageCommand.startLength("ortak"), 0)
        XCTAssertEqual(PassageCommand.startLength("soru 5 ortak paragraf"), 0)
        XCTAssertEqual(PassageCommand.stripStart("ortak para graf Ali eve gitti"), "Ali eve gitti")
    }

    // MARK: Tanıyıcıya ipucu

    func testRecognizerHintsCoverCommandsMenusAndNumbers() {
        let hints = OnDeviceSpeechListener.contextualStrings
        XCTAssertLessThanOrEqual(hints.count, 100, "Apple en çok yüz kadar ipucu önerir")
        for word in ["Cevapla", "Gönder", "Tamam", "Tamamlandı", "Ortak paragraf", "Testi bitir", "Cevapları tekrarla", "Evet", "Hayır", "Devam", "Tekrar",
                     "Bitir", "bir", "beş", "altı", "yedi", "yirmi", "yüz", "beşinci"] {
            XCTAssertTrue(hints.contains(word), word)
        }
    }
}
