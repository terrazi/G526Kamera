import XCTest
@testable import G526CameraDrive

/// Ortak paragraf, eksik soru numarası ve kesinti sonrası devam için saf yardımcılar
final class ReadingModesTests: XCTestCase {
    // MARK: "Ortak paragraf" komutu

    func testPassageCommandIsRecognizedAtTheStartOnly() {
        XCTAssertTrue(PassageCommand.startsWith("Ortak paragraf"))
        XCTAssertTrue(PassageCommand.startsWith("ortak paragrafı okuyorum Ali eve gitti"))
        XCTAssertTrue(PassageCommand.startsWith("Ortak Paragraf. Ali eve gitti"))
        XCTAssertFalse(PassageCommand.startsWith("Ortak"))
        XCTAssertFalse(PassageCommand.startsWith("Soru 5 ortak paragraf"))
        XCTAssertFalse(PassageCommand.startsWith("paragraf ortak"))
        XCTAssertFalse(PassageCommand.startsWith(""))
    }

    func testPassageCommandIsStrippedFromTheText() {
        XCTAssertEqual(PassageCommand.stripStart("Ortak paragraf Ali eve gitti. Sonra okula yürüdü"), "Ali eve gitti. Sonra okula yürüdü")
        XCTAssertEqual(PassageCommand.stripStart("Ortak paragraf"), "")
        XCTAssertEqual(PassageCommand.stripStart("Ali eve gitti"), "Ali eve gitti")
    }

    func testFinishWordEndsThePassageButCevaplaDoesNot() {
        let text = "Ortak paragraf Ali eve gitti. Tamamlandı"
        XCTAssertNotNil(TriggerDetector.match(in: text, words: PassageCommand.finishWords))
        XCTAssertNotNil(TriggerDetector.match(in: "Ali eve gitti. Tamamlandı.", words: PassageCommand.finishWords))
        XCTAssertNil(TriggerDetector.match(in: "Ortak paragraf Ali eve gitti. Cevapla", words: PassageCommand.finishWords))
        XCTAssertNil(TriggerDetector.match(in: "Tamamlandı ve Ali eve gitti", words: PassageCommand.finishWords), "Yalnız son sözcük sayılır")
    }

    // MARK: Sıra sayıları

    func testOrdinalsAreSpokenAsWords() {
        let cases: [(Int, String)] = [
            (1, "birinci"), (3, "üçüncü"), (4, "dördüncü"), (9, "dokuzuncu"), (10, "onuncu"), (12, "on ikinci"),
            (20, "yirminci"), (25, "yirmi beşinci"), (40, "kırkıncı"), (99, "doksan dokuzuncu"), (100, "yüzüncü"),
            (101, "yüz birinci"), (110, "yüz onuncu")
        ]
        for (number, word) in cases {
            XCTAssertEqual(TurkishOrdinal.word(number), word, "\(number)")
        }
        XCTAssertNil(TurkishOrdinal.word(0))
        XCTAssertNil(TurkishOrdinal.word(200))
        XCTAssertEqual(TurkishOrdinal.inQuestion(3), "üçüncü soruda")
        XCTAssertEqual(TurkishOrdinal.inQuestion(250), "250 numaralı soruda")
    }

    // MARK: Son cümle

    func testLastSentenceOfUnfinishedText() {
        XCTAssertEqual(LastSentence.of("Soru 3 Ali eve gitti. Sonra okula yürüdü ve arkadaşlarıyla buluştu"), "Sonra okula yürüdü ve arkadaşlarıyla buluştu")
        XCTAssertEqual(LastSentence.of("Ali eve gitti. Sonra okula yürüdü ve arkadaşlarıyla buluştu."), "Sonra okula yürüdü ve arkadaşlarıyla buluştu")
        XCTAssertEqual(LastSentence.of("Hangisi doğrudur? Aşağıdakilerden birini seçin"), "Aşağıdakilerden birini seçin")
    }

    func testLastSentenceKeepsDecimalNumbersTogether() {
        XCTAssertEqual(LastSentence.of("Ali eve gitti. Sonuç 3.5 çıktı"), "Sonuç 3.5 çıktı")
    }

    func testVeryShortLastSentenceBorrowsTheOneBeforeIt() {
        XCTAssertEqual(LastSentence.of("Ali eve gitti. Evet."), "Ali eve gitti. Evet")
    }

    func testLongSentenceIsCutToTheLastWords() {
        let words = (1...20).map { "kelime\($0)" }
        let result = LastSentence.of(words.joined(separator: " "))
        XCTAssertEqual(result.split(separator: " ").count, LastSentence.maxWords)
        XCTAssertTrue(result.hasSuffix("kelime20"))
        XCTAssertTrue(result.hasPrefix("kelime7 "))
    }

    func testLastSentenceOfNothingIsEmpty() {
        XCTAssertEqual(LastSentence.of(""), "")
        XCTAssertEqual(LastSentence.of("  ...  "), "")
    }

    // MARK: Eksik soru numarası

    func testStandaloneNumberAnswers() {
        let cases: [(String, Int)] = [
            ("yedi", 7), ("Soru yedi", 7), ("yedinci soru", 7), ("yirmi beş", 25), ("soru numarası on iki", 12),
            ("yedi cevapla", 7), ("5", 5), ("soru 5", 5), ("Üçüncü", 3), ("numara dokuz", 9), ("on ikinci soru", 12)
        ]
        for (text, expected) in cases {
            XCTAssertEqual(SpokenNumber.standalone(from: text), expected, text)
        }
    }

    func testStandaloneRejectsLongTextAndNonNumbers() {
        XCTAssertNil(SpokenNumber.standalone(from: ""))
        XCTAssertNil(SpokenNumber.standalone(from: "soru"))
        XCTAssertNil(SpokenNumber.standalone(from: "bilmiyorum"))
        XCTAssertNil(SpokenNumber.standalone(from: "aşağıdakilerden hangisi doğrudur yedi seçenek var"), "Sonraki soruyu okumaya başlandıysa numara sayılmaz")
        XCTAssertNil(SpokenNumber.standalone(from: "yedi sekiz"), "İki ayrı sayı tek numara değildir")
    }

    func testSequenceRequest() {
        XCTAssertTrue(SpokenNumber.wantsSequence("sıradaki"))
        XCTAssertTrue(SpokenNumber.wantsSequence("sıradaki numara"))
        XCTAssertTrue(SpokenNumber.wantsSequence("geç"))
        XCTAssertFalse(SpokenNumber.wantsSequence("yedi"))
        XCTAssertFalse(SpokenNumber.wantsSequence(""))
    }

    // MARK: Paragrafın ait olduğu sorular

    func testPassageTargetsLists() {
        let cases: [(String, [Int])] = [
            ("5 6 7", [5, 6, 7]),
            ("beş altı yedi", [5, 6, 7]),
            ("beş, altı ve yedi", [5, 6, 7]),
            ("5 ile 7 arası", [5, 6, 7]),
            ("beşten yediye kadar", [5, 6, 7]),
            ("5-7", [5, 6, 7]),
            ("on iki on üç", [12, 13]),
            ("yedi", [7]),
            ("yirmi bir yirmi iki", [21, 22]),
            ("7 ile 5 arası", [5, 7]),
            ("üç beş üç", [3, 5])
        ]
        for (text, expected) in cases {
            XCTAssertEqual(SpokenNumber.list(from: text), expected, text)
        }
    }

    func testPassageTargetsWithoutNumbersAreEmpty() {
        XCTAssertEqual(SpokenNumber.list(from: ""), [])
        XCTAssertEqual(SpokenNumber.list(from: "bilmiyorum"), [])
    }

    func testListTextIsReadNaturally() {
        XCTAssertEqual(QuestionComposer.listText([5]), "5")
        XCTAssertEqual(QuestionComposer.listText([5, 7]), "5 ve 7")
        XCTAssertEqual(QuestionComposer.listText([5, 6, 7]), "5, 6 ve 7")
        XCTAssertEqual(QuestionComposer.listText([]), "")
    }

    // MARK: Gemini'ye gidecek metin

    func testNumberIsWrittenAtTheStartOfTheQuestion() {
        XCTAssertEqual(QuestionComposer.numbered("Hangisi doğrudur A B C", number: 7), "Soru 7. Hangisi doğrudur A B C")
    }

    func testPassageIsSentTogetherWithTheQuestion() {
        let context = PassageContext(text: "Ali eve gitti.", english: "", audio: nil, all: [5, 6, 7], remaining: [5, 6, 7])
        let text = QuestionComposer.withPassage(question: "Soru 6 Ali nereye gitti", passage: context, audioCombined: false)
        XCTAssertTrue(text.contains("5, 6 ve 7 numaralı sorular için ortaktır"))
        XCTAssertTrue(text.contains("Ali eve gitti."))
        XCTAssertTrue(text.hasSuffix("Soru 6 Ali nereye gitti"))
        XCTAssertFalse(text.contains("Ses kaydında"))
        let withAudio = QuestionComposer.withPassage(question: "x", passage: context, audioCombined: true)
        XCTAssertTrue(withAudio.contains("Ses kaydında önce ortak paragraf"))
    }

    func testEnglishTextCombinesPassageAndQuestion() {
        let context = PassageContext(text: "t", english: "Ali went home", audio: nil, all: [1], remaining: [1])
        XCTAssertEqual(QuestionComposer.english(passage: context, question: "where did he go"), "Ortak paragraf: Ali went home\nSoru: where did he go")
        XCTAssertEqual(QuestionComposer.english(passage: context, question: ""), "Ortak paragraf: Ali went home")
        let plain = PassageContext(text: "t", english: "", audio: nil, all: [1], remaining: [1])
        XCTAssertEqual(QuestionComposer.english(passage: plain, question: "where"), "where")
    }

    // MARK: Ses birleştirme

    func testWavFilesAreJoinedEndToEnd() {
        let a = PCMRecorder.wav(samples: [1, 2, 3], sampleRate: 16_000)
        let b = PCMRecorder.wav(samples: [4, 5], sampleRate: 16_000)
        XCTAssertEqual(PCMRecorder.concatenated([a, b]), PCMRecorder.wav(samples: [1, 2, 3, 4, 5], sampleRate: 16_000))
        XCTAssertEqual(PCMRecorder.concatenated([a]), a)
        XCTAssertNil(PCMRecorder.concatenated([]))
        XCTAssertNil(PCMRecorder.concatenated([a, Data([1, 2, 3, 4])]), "Geçersiz parça birleştirmeyi bozmaz, hiç birleştirilmez")
    }

    func testAudioJoinKeepsTheQuestionWhenThePassageCannotBeAdded() {
        let a = PCMRecorder.wav(samples: [1, 2, 3], sampleRate: 16_000)
        let b = PCMRecorder.wav(samples: [4, 5], sampleRate: 16_000)
        let joined = AudioJoin.join(passage: a, question: b)
        XCTAssertTrue(joined.combined)
        XCTAssertEqual(joined.data, PCMRecorder.wav(samples: [1, 2, 3, 4, 5], sampleRate: 16_000))
        let noPassage = AudioJoin.join(passage: nil, question: b)
        XCTAssertFalse(noPassage.combined)
        XCTAssertEqual(noPassage.data, b)
        let broken = AudioJoin.join(passage: a, question: Data([1, 2, 3, 4]))
        XCTAssertFalse(broken.combined)
        XCTAssertEqual(broken.data, Data([1, 2, 3, 4]))
        let noQuestion = AudioJoin.join(passage: a, question: nil)
        XCTAssertFalse(noQuestion.combined)
        XCTAssertNil(noQuestion.data)
    }

    // MARK: Cümleler

    func testNewAnnouncementsSayWhatWasAskedFor() {
        XCTAssertEqual(Say.questionSent, "Soru başarıyla alınıp Gemini'ye gönderildi, cevap bekleniyor.")
        XCTAssertEqual(Say.recoveredAfterSend, "Bağlantı yeniden onarıldı. Sorunuz yarım kaldıysa son soruyu tekrar okuyunuz.")
        XCTAssertEqual(Say.askNumber, "Lütfen okuduğunuz sorunun numarasını söyleyin.")
        XCTAssertTrue(Say.passageTaken.hasPrefix("Paragraf metnini aldım."))
        XCTAssertEqual(Say.continuePartial(passage: false, number: 3, sentence: "Sonra okula gitti"),
                       "Bağlantı yeniden onarıldı. En son üçüncü soruda şu cümleyi okudunuz: Sonra okula gitti. Buradan devam edebilirsiniz.")
        XCTAssertTrue(Say.continuePartial(passage: true, number: nil, sentence: "Sonra okula gitti").contains("Ortak paragrafta en son şu cümleyi okudunuz: Sonra okula gitti."))
        XCTAssertEqual(Say.passageReady([5, 6, 7]), "Ortak paragraf 5, 6 ve 7 numaralı sorular için kaydedildi. Şimdi soruları okuyabilirsiniz.")
    }
}
