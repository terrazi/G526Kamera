import XCTest
@testable import G526CameraDrive

/// En yakın seçenek (bulanık eşleştirme): iki seçenekli zararsız sorularda tanıyıcı sözcüğü tam yazmasa da hangisine benzediğine bakılır.
/// Geri alınamayan yönler (testi bitirmek) hiçbir zaman bulanık seçilmez.
final class ClosestChoiceTests: XCTestCase {
    private func chars(_ s: String) -> [Character] { return Array(s) }

    func testEditDistanceCountsOneForASwapOfNeighbours() {
        XCTAssertEqual(SpokenWords.editDistance(chars("devam"), chars("devan")), 1)
        XCTAssertEqual(SpokenWords.editDistance(chars("devam"), chars("devma")), 1, "Bitişik iki harfin yer değiştirmesi tek farktır")
        XCTAssertEqual(SpokenWords.editDistance(chars("yeni"), chars("yeli")), 1)
        XCTAssertEqual(SpokenWords.editDistance(chars("evet"), chars("evvet")), 1)
        XCTAssertEqual(SpokenWords.editDistance(chars("devam"), chars("yeni")), 4)
        XCTAssertEqual(SpokenWords.editDistance([], chars("ab")), 2)
    }

    func testSimilarityIsMeasuredOnTheSoundKey() {
        XCTAssertEqual(SpokenWords.similarity("pitir", "bitir"), 1, accuracy: 0.0001, "p ≈ b, t ≈ d: aynı ses")
        XCTAssertEqual(SpokenWords.similarity("devam", "devan"), 0.8, accuracy: 0.0001)
        XCTAssertEqual(SpokenWords.similarity("yeni", "yeli"), 0.75, accuracy: 0.0001)
        XCTAssertLessThan(SpokenWords.similarity("devam", "yeni"), 0.3)
    }

    func testTheClosestOptionIsTheOneTheWordResembles() {
        let options: [Set<String>] = [SpokenReply.continueWords, SpokenReply.newWords]
        XCTAssertEqual(SpokenWords.closestOption(["yeli"], among: options), 1, "Dört harfli 'yeni' tek harf yanlış duyuldu")
        XCTAssertEqual(SpokenWords.closestOption(["devan"], among: options), 0)
        XCTAssertEqual(SpokenWords.closestOption(["sivirdam"], among: options), 1, "Uzun sözcükte iki harf farkı hoşgörülür")
    }

    func testAWordThatIsNotClearlyCloserToOneOptionIsNotChosen() {
        let options: [Set<String>] = [SpokenReply.continueWords, SpokenReply.newWords]
        XCTAssertNil(SpokenWords.closestOption(["devan", "yeni"], among: options), "İki seçeneğe de benzeyen söz: fark yetersiz")
        XCTAssertNil(SpokenWords.closestOption(["merhaba"], among: options))
        XCTAssertNil(SpokenWords.closestOption([], among: options))
        XCTAssertNil(SpokenWords.closestOption(["devan", "etmek", "istiyorum", "evet"], among: options), "Üç sözcükten uzun söz: tahmin yürütülmez")
        XCTAssertNil(SpokenWords.closestOption(["bir", "iki"], among: options), "Dört harften kısa sözcükler hesaba katılmaz")
        XCTAssertNil(SpokenWords.closestOption(["beni"], among: options), "İlk harf farklı: 'beni' ≠ 'yeni'")
        XCTAssertNil(SpokenWords.closestOption(["yani"], among: options), "Dolgu sözcük: 'yani' ≠ 'yeni'")
        XCTAssertNil(SpokenWords.closestOption(["yedi"], among: options), "Sayı sözcüğü: 'yedi' ≠ 'yeni'")
        XCTAssertNil(SpokenWords.closestOption(["pazarlama"], among: [SpokenReply.cameraYesClose, SpokenReply.cameraNo]), "Uzunluk farkı iki harf: 'pazarlama' ≠ 'başlama'")
        XCTAssertNil(SpokenWords.closestOption(["anlamiyorum"], among: [SpokenReply.cameraYesClose, SpokenReply.cameraNo]), "Ortak ek iki sözcüğü benzetmez")
    }

    // MARK: Önceki kayıt / yeni sınav

    func testTheStartQuestionTakesTheClosestOption() {
        XCTAssertEqual(SpokenReply.closestStart("yeli"), .startNew)
        XCTAssertEqual(SpokenReply.closestStart("yeri sınav"), .startNew)
        XCTAssertEqual(SpokenReply.closestStart("sıvırdam"), .startNew)
        XCTAssertEqual(SpokenReply.closestStart("devan"), .continuePrevious)
        XCTAssertEqual(SpokenReply.closestStart("devamı"), .continuePrevious)
        // Aynen duyulması gereken katı ayrıştırıcı değişmedi: dört harfli yanlış duyuş onda hâlâ anlaşılmaz
        XCTAssertNil(SpokenReply.start("yeli"))
        XCTAssertNil(SpokenReply.start("sıvırdam"))
    }

    func testTheStartQuestionNeverGuessesFromNegationsCommandsOrLongSentences() {
        for text in ["", "yani", "şey yani", "soru bir", "yeli etmiyorum", "yeli değil", "yeniden söyle", "bir daha söyle", "yeli ama önceki de devam etmek istiyorum",
                     "soruyu sil", "testi bitir", "anlamadım"] {
            XCTAssertNil(SpokenReply.closestStart(text), text)
        }
    }

    // MARK: Kamera sorusu

    func testTheCameraQuestionTakesAClearYesThatWasHeardImperfectly() {
        XCTAssertEqual(SpokenReply.closestCameraChoice("evat"), .yes)
        XCTAssertEqual(SpokenReply.closestCameraChoice("evvet"), .yes)
        XCTAssertEqual(SpokenReply.closestCameraChoice("tamaam"), .yes)
        XCTAssertEqual(SpokenReply.closestCameraChoice("hayar"), .no)
        XCTAssertNil(SpokenReply.cameraChoice("evat"), "Katı ayrıştırıcı bulanık evet vermez")
    }

    func testTheCameraQuestionIsNotAnsweredByGuessing() {
        for text in ["", "evet hayır", "evat istemiyorum", "kamerayla", "çekmek", "pazarlama", "başka", "başka şey", "iptal et", "testi bitir", "bir daha söyle"] {
            XCTAssertNil(SpokenReply.closestCameraChoice(text), text)
        }
    }

    // MARK: Yeni bölüm / testi tamamla

    func testTheNextSectionQuestionMayGuessNewSectionButNeverFinishTheTest() {
        XCTAssertEqual(SpokenReply.closestNextSection("evat"), .newSection)
        XCTAssertEqual(SpokenReply.closestNextSection("devan"), .newSection)
        XCTAssertEqual(SpokenReply.closestNextSection("yeli bölüm"), .newSection)
        XCTAssertNil(SpokenReply.nextSection("evat"))
        for text in ["bitirr", "bitr", "tamamlaa", "sonlandırr", "hayar", "kapatt", "evat bitirr", "yeli bitirr", "başka", ""] {
            XCTAssertNil(SpokenReply.closestNextSection(text), "Testi bitiren yön bulanık seçilmez: \(text)")
        }
    }

    // MARK: Devam / tekrar / bitir

    func testTheReviewMenuMayGuessContinueOrRepeatButNeverFinish() {
        XCTAssertEqual(SpokenReply.closestReview("devan"), .continueTest)
        XCTAssertEqual(SpokenReply.closestReview("tekrer"), .repeatAnswers)
        XCTAssertEqual(SpokenReply.closestReview("dinlee"), .repeatAnswers)
        for text in ["bitirr", "bitr", "sonlandırr", "tamamlaa", "kapatt", "devan bitirr", "soruyu sil", "soruyu atla", "sorular", ""] {
            XCTAssertNil(SpokenReply.closestReview(text), "Bitirme bulanık seçilmez, belirsiz söz anlaşılmaz: \(text)")
        }
    }
}
