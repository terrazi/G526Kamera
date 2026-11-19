import XCTest
import AVFoundation
import CoreGraphics
import CoreVideo
@testable import G526CameraDrive

/// Karedeki soru parçaları (kullanıcı isteği 2026-11-19: "her soru için tamlık denetimi"): yazı tanıma satırlarından numara, kök ve şıklar çıkarılır.
final class QuestionPiecesTests: XCTestCase {
    /// `y`: satırın kadrajın üstünden uzaklığı (0–1); kutu Vision ölçüsünde (başlangıç sol alt) kurulur
    private func row(_ text: String, x: Double = 0.1, y: Double, width: Double = 0.5) -> (text: String, box: CGRect) {
        return (text: text, box: CGRect(x: x, y: 1 - y - 0.03, width: width, height: 0.03))
    }

    private func letters(_ piece: QuestionPiece) -> String {
        return String(piece.options.keys.sorted())
    }

    func testAQuestionWithItsNumberStemAndFiveOptionsIsOnePiece() {
        let pieces = QuestionSpotter.pieces([
            row("47. It is clearly stated in the passage that James", y: 0.10),
            row("Bowman Lindsay ----.", y: 0.14),
            row("A) has invented a light bulb which is considered", y: 0.20),
            row("as the first prototype of the modern light bulbs", y: 0.24),
            row("B) invented his light bulb by improving the works", y: 0.30),
            row("C) made some improvements on one of the earlier", y: 0.36),
            row("D) started working as a scholar at the Watt", y: 0.42),
            row("E) demonstrated his invention at Watt institute by", y: 0.48)
        ])
        guard let piece = pieces.first, pieces.count == 1 else { return XCTFail("\(pieces)") }
        XCTAssertEqual(piece.number, 47)
        XCTAssertEqual(letters(piece), "ABCDE")
        XCTAssertTrue(piece.isStrict)
        XCTAssertFalse(piece.stemCut)
        XCTAssertEqual(piece.options["A"]?.words.contains("prototype"), true, "Devam satırının sözcükleri şıkka yazılır")
        XCTAssertEqual(piece.summary, "47:ABCDE")
    }

    func testOptionsAboveTheNextNumberAreTheTailOfThePreviousQuestion() {
        let pieces = QuestionSpotter.pieces([
            row("D) started working as a scholar at the Watt", y: 0.05),
            row("E) demonstrated his invention at Watt institute", y: 0.10),
            row("48. What was the attitude of the public towards", y: 0.20),
            row("A) ineffective", y: 0.26),
            row("B) sceptical", y: 0.30)
        ])
        guard pieces.count == 2 else { return XCTFail("\(pieces)") }
        XCTAssertNil(pieces[0].number)
        XCTAssertEqual(pieces[0].before, 48, "Numarasız şıklar, hemen ardından başlayan sorudan bir öncekinin kuyruğudur")
        XCTAssertEqual(letters(pieces[0]), "DE")
        XCTAssertEqual(pieces[0].summary, "<48:DE")
        XCTAssertEqual(pieces[1].number, 48)
        XCTAssertEqual(letters(pieces[1]), "AB")
    }

    func testANumberAtTheStartOfAnOptionLineDoesNotSplitTheQuestion() {
        let pieces = QuestionSpotter.pieces([
            row("12. Which of the following is true about the empire?", y: 0.10),
            row("A) It was founded in the", y: 0.16),
            row("7. century by nomads", y: 0.20),
            row("B) It collapsed in the next century", y: 0.26),
            row("C) It never existed", y: 0.32),
            row("13. What can be inferred from the passage?", y: 0.40),
            row("A) Nothing at all", y: 0.46),
            row("B) Everything is clear", y: 0.50)
        ])
        guard pieces.count == 2 else { return XCTFail("\(pieces)") }
        XCTAssertEqual(pieces[0].number, 12)
        XCTAssertEqual(letters(pieces[0]), "ABC", "Şık metninin satır başına düşen sayı yeni soru sayılmaz")
        XCTAssertEqual(pieces[0].options["A"]?.words.contains("nomads"), true)
        XCTAssertEqual(pieces[1].number, 13, "Sıradaki numara yeni soruyu başlatır")
        XCTAssertEqual(letters(pieces[1]), "AB")
    }

    func testAMisreadNextNumberStillStartsAQuestionWhenFreshOptionsFollow() {
        let pieces = QuestionSpotter.pieces([
            row("12. Which of the following is true about the empire?", y: 0.10),
            row("A) It was founded by nomads", y: 0.16),
            row("B) It collapsed quickly", y: 0.22),
            row("18. What can be inferred from the passage?", y: 0.30),
            row("A) Nothing at all", y: 0.36),
            row("B) Everything is clear", y: 0.42)
        ])
        XCTAssertEqual(pieces.map { $0.number }, [12, 18], "Numara yanlış okunsa da ardından A şıkkı geliyorsa yeni sorudur")
    }

    func testTwoColumnsAreReadSeparatelyEvenWhenAnOptionLineIsShort() {
        // Sağ sütun x = 0,40'tan başlar; "A) yes" satırının ortası kadrajın sol yarısına düşer ama sol kenarı sağ sütundadır
        let pieces = QuestionSpotter.pieces([
            row("51. It is clearly stated in the passage that before", x: 0.02, y: 0.10, width: 0.33),
            row("A) Joseph Lister had already started working", x: 0.03, y: 0.20, width: 0.32),
            row("B) the findings of Lister were met with ridicule", x: 0.03, y: 0.30, width: 0.32),
            row("52. Which of the following can be inferred", x: 0.40, y: 0.12, width: 0.5),
            row("A) yes", x: 0.41, y: 0.22, width: 0.06),
            row("B) no", x: 0.41, y: 0.32, width: 0.05)
        ])
        var byNumber: [Int: QuestionPiece] = [:]
        for piece in pieces {
            if let number = piece.number { byNumber[number] = piece }
        }
        XCTAssertEqual(byNumber[51].map { letters($0) }, "AB")
        XCTAssertEqual(byNumber[52].map { letters($0) }, "AB", "Kısa şık satırları kendi sütununun sorusuna yazılır")
    }

    func testALineTouchingTheSideOfTheFrameMarksItsOptionAsCut() {
        let pieces = QuestionSpotter.pieces([
            row("44. Which of the following could be the title", x: 0.45, y: 0.10, width: 0.5),
            row("A) A Brief History of Lighting", x: 0.46, y: 0.20, width: 0.4),
            row("B) Well-known Inventors of History and the", x: 0.46, y: 0.30, width: 0.54)
        ])
        guard let piece = pieces.first, pieces.count == 1 else { return XCTFail("\(pieces)") }
        XCTAssertEqual(piece.options["A"]?.cut, false)
        XCTAssertEqual(piece.options["B"]?.cut, true, "Sağ kenara dayanan satır yarım görünüyor")
        XCTAssertFalse(piece.stemCut)
        XCTAssertEqual(piece.summary, "44:Ab")
    }

    func testALineThatStartsWithItsNumberOrLetterIsNotCutAtTheLeftEdge() {
        let pieces = QuestionSpotter.pieces([
            row("44. Which of the following could be the title", x: 0.0, y: 0.10, width: 0.5),
            row("A) A Brief History of Lighting", x: 0.005, y: 0.20, width: 0.4),
            row("B) Well-known Inventors of History and", x: 0.005, y: 0.30, width: 0.4),
            row("their greatest inventions", x: 0.0, y: 0.34, width: 0.3)
        ])
        guard let piece = pieces.first, pieces.count == 1 else { return XCTFail("\(pieces)") }
        XCTAssertFalse(piece.stemCut, "Numara görünüyorsa satırın başı görünüyordur: sol kenara dayanması kesik sayılmaz")
        XCTAssertEqual(piece.options["A"]?.cut, false, "Şık harfi görünüyorsa satırın başı görünüyordur")
        XCTAssertEqual(piece.options["B"]?.cut, true, "Devam satırının başı kadrajın dışında kalmış olabilir")
    }

    func testOptionsLaidOutInTwoColumnsJoinTheirQuestion() {
        // Gerçek günlük 2026-11-19: şıklar iki sütunda (A, C solda; B, D sağda; E ortada) dizilince her soru üç ayrı parça görünüyordu
        let pieces = QuestionSpotter.pieces([
            row("1. In order to irrigate their crops, farmers ---- water", x: 0.10, y: 0.10, width: 0.6),
            row("A) abundant", x: 0.12, y: 0.16, width: 0.15),
            row("B) collective", x: 0.42, y: 0.16, width: 0.15),
            row("C) thorough", x: 0.12, y: 0.20, width: 0.15),
            row("D) wasteful", x: 0.42, y: 0.20, width: 0.15),
            row("E) practical", x: 0.27, y: 0.24, width: 0.15),
            row("3. The committee decided to ---- the proposal", x: 0.10, y: 0.34, width: 0.6),
            row("A) reject", x: 0.12, y: 0.40, width: 0.15),
            row("B) approve", x: 0.42, y: 0.40, width: 0.15),
            row("C) delay", x: 0.12, y: 0.44, width: 0.15),
            row("D) revise", x: 0.42, y: 0.44, width: 0.15)
        ])
        XCTAssertEqual(pieces.map { $0.summary }, ["1:ABCDE", "3:ABCD"], "Yan sütundaki şıklar hizasındaki soruya bağlanır")
    }

    func testASideColumnRepeatingTheSameLettersBelongsToAnotherQuestion() {
        let pieces = QuestionSpotter.pieces([
            row("51. It is clearly stated in the passage that before", x: 0.02, y: 0.10, width: 0.33),
            row("A) Joseph Lister had already started working", x: 0.03, y: 0.20, width: 0.32),
            row("B) the findings of Lister were met with ridicule", x: 0.03, y: 0.30, width: 0.32),
            row("A) Thanks to his creative ideas and support", x: 0.45, y: 0.22, width: 0.4),
            row("B) Even though Joseph Lister revolutionized", x: 0.45, y: 0.32, width: 0.4)
        ])
        XCTAssertEqual(pieces.map { $0.summary }.sorted(), ["51:AB", "?:AB"], "Aynı harfleri taşıyan yan sütun başka bir sorunun parçasıdır")
    }

    func testPassageTextWithoutOptionsIsNotAPiece() {
        let pieces = QuestionSpotter.pieces([
            row("Thomas Edison filed a patent for his electric light", y: 0.10),
            row("in what became the modern light bulb. Building on", y: 0.14),
            row("the successful yet impractical platinum filament", y: 0.18)
        ])
        XCTAssertTrue(pieces.isEmpty, "\(pieces)")
    }
}

/// Taramanın bütününden hangi sorunun TAM GÖRÜLMEDİĞİ (kullanıcı kararı 2026-11-19: koç yanlış bilgi vermemeli; şüphede susulur).
final class QuestionCoverageTests: XCTestCase {
    private func piece(_ number: Int?, _ letters: String, words: [Character: [String]] = [:], cut: String = "", before: Int? = nil,
                       stemCut: Bool = false) -> QuestionPiece {
        var result = QuestionPiece()
        result.number = number
        result.body = number == nil ? 0 : 40
        result.before = before
        result.stemCut = stemCut
        for letter in letters {
            result.options[letter] = OptionView(words: Set(words[letter] ?? []), cut: cut.contains(letter))
        }
        return result
    }

    /// 47 ve 48 beş şıkkıyla ikişer karede görülmüş: taramada beklenen son şık E'dir
    private var base: [[QuestionPiece]] {
        return [[piece(47, "ABCDE")], [piece(47, "ABCDE")], [piece(48, "ABCDE")], [piece(48, "ABCDE")]]
    }

    func testQuestionsSeenWithAllTheirOptionsAreComplete() {
        let coverage = QuestionCoverage.make(base)
        XCTAssertEqual(coverage.incomplete, [])
        XCTAssertEqual(coverage.checked[47], "ABCDE")
        XCTAssertEqual(coverage.expectedTop, "E")
        XCTAssertTrue(coverage.logText.contains("tam görülmeyen yok"), coverage.logText)
    }

    func testTrailingOptionsThatNoFrameShowsMakeTheQuestionIncomplete() {
        let coverage = QuestionCoverage.make(base + [[piece(49, "ABC")], [piece(49, "ABC")]])
        XCTAssertEqual(coverage.incomplete, [49])
        XCTAssertEqual(coverage.reasons[49], "DE hiçbir karede görülmedi")
        XCTAssertTrue(coverage.logText.contains("49 (DE hiçbir karede görülmedi)"), coverage.logText)
    }

    func testAQuestionSeenInOnlyOneFrameIsNotJudged() {
        let coverage = QuestionCoverage.make(base + [[piece(49, "ABC")]])
        XCTAssertEqual(coverage.incomplete, [])
        XCTAssertNil(coverage.checked[49], "Tek karede görülen numara yazı tanıma yanılgısı olabilir")
    }

    func testAContinuationWithoutTheNumberIsJoinedThroughASharedOption() {
        let first = piece(49, "ABC", words: ["C": ["made", "some", "improvements", "earlier"]])
        let tail = piece(nil, "CDE", words: ["C": ["made", "some", "improvements", "one", "earlier"]])
        let coverage = QuestionCoverage.make(base + [[first], [first], [tail]])
        XCTAssertEqual(coverage.incomplete, [], "Numara kadrajın dışında kalsa da C şıkkı aynı: D ve E bu sorunundur")
        XCTAssertEqual(coverage.checked[49], "ABCDE")
        XCTAssertEqual(coverage.orphans, 0)
    }

    func testOptionsRightAboveTheNextQuestionBelongToThePreviousOne() {
        let coverage = QuestionCoverage.make(base + [[piece(49, "ABC")], [piece(49, "ABC")], [piece(nil, "DE", before: 50), piece(50, "AB")]])
        XCTAssertEqual(coverage.incomplete, [])
        XCTAssertEqual(coverage.checked[49], "ABCDE")
    }

    func testAnUnattachedContinuationShowingTheMissingOptionKeepsTheCoachSilent() {
        let coverage = QuestionCoverage.make(base + [[piece(49, "ABC")], [piece(49, "ABC")], [piece(nil, "DE")]])
        XCTAssertEqual(coverage.incomplete, [], "D ve E bir karede görülmüş ama soruya bağlanamamış: şüphede susulur")
        XCTAssertEqual(coverage.orphans, 1)
    }

    func testAMissingMiddleOptionIsReadingNoiseNotAGap() {
        let coverage = QuestionCoverage.make(base + [[piece(49, "ABD")], [piece(49, "ABD")]])
        XCTAssertEqual(coverage.incomplete, [], "Aradan eksik harf yazı tanımanın kaçırmasıdır")
    }

    func testAFourOptionExamIsNotMissingE() {
        let frames = [[piece(1, "ABCD")], [piece(1, "ABCD")], [piece(2, "ABCD")], [piece(2, "ABCD")], [piece(3, "ABCD")], [piece(3, "ABCD")]]
        let coverage = QuestionCoverage.make(frames)
        XCTAssertEqual(coverage.incomplete, [])
        XCTAssertEqual(coverage.expectedTop, "D")
    }

    func testWithTooFewQuestionsNothingIsClaimed() {
        let coverage = QuestionCoverage.make([[piece(49, "ABC")], [piece(49, "ABC")]])
        XCTAssertEqual(coverage.incomplete, [])
        XCTAssertNil(coverage.expectedTop, "Tek sorudan sınavın kaç şıklı olduğu bilinemez")
        XCTAssertEqual(QuestionCoverage.make([]).logText, "denetlenecek soru yok (hiçbir soru iki karede numarası, kökü ve şıklarıyla görülmedi)")
    }

    func testAnOptionCutAtTheEdgeInEveryFrameMakesTheQuestionIncomplete() {
        let cut = piece(44, "ABCDE", cut: "DE")
        let always = QuestionCoverage.make(base + [[cut], [cut], [cut]])
        XCTAssertEqual(always.incomplete, [44])
        XCTAssertEqual(always.reasons[44], "DE her karede kenarda kesik")
        let twice = QuestionCoverage.make(base + [[cut], [cut]])
        XCTAssertEqual(twice.incomplete, [], "İki kare yetmez: en az üç karede hep kesik görülmeli")
        let once = QuestionCoverage.make(base + [[cut], [cut], [cut], [piece(44, "ABCDE")]])
        XCTAssertEqual(once.incomplete, [], "Bir karede tam göründüyse soru tamdır")
        let elsewhere = QuestionCoverage.make(base + [[cut], [cut], [cut], [piece(nil, "DE")]])
        XCTAssertEqual(elsewhere.incomplete, [], "Bağlanamayan bir parçada D ve E tam görünüyor: şüphede susulur")
    }

    func testAStemCutAtTheEdgeInEveryFrameMakesTheQuestionIncomplete() {
        let cut = piece(44, "ABCDE", stemCut: true)
        XCTAssertEqual(QuestionCoverage.make(base + [[cut], [cut], [cut]]).reasons[44], "soru kökü her karede kenarda kesik")
        XCTAssertEqual(QuestionCoverage.make(base + [[cut], [cut], [piece(44, "ABCDE")]]).incomplete, [])
    }

    // MARK: Söylenen not

    func testOnlyAnsweredQuestionsAreMentionedAndTooManyMeansSilence() {
        XCTAssertEqual(CaptureDiagnosis.incompleteAnswers(incomplete: [48, 52], answered: [47, 48, 49]), [48], "Cevabı okunmayan soru söylenmez")
        XCTAssertEqual(CaptureDiagnosis.incompleteAnswers(incomplete: [], answered: [47, 48]), [])
        XCTAssertEqual(CaptureDiagnosis.incompleteAnswers(incomplete: [1, 2, 3], answered: [1, 2, 3, 4]), [1, 2, 3])
        XCTAssertEqual(CaptureDiagnosis.incompleteAnswers(incomplete: [1, 2, 3, 4], answered: [1, 2, 3, 4]), [],
                       "Dört soru birden eksik çıkıyorsa denetim güvenilmezdir: hiçbiri söylenmez")
        XCTAssertEqual(CaptureSay.incompleteAnswers([48]), "Taramada tam görünmeyen soru: 48. Cevabı kesin olmayabilir; isterseniz yeniden tarayın.")
        XCTAssertEqual(CaptureSay.incompleteAnswers([48, 52]),
                       "Taramada tam görünmeyen sorular: 48 ve 52. Cevapları kesin olmayabilir; isterseniz yeniden tarayın.")
    }

    // MARK: Toplayıcı

    func testTheCollectorJudgesCoverageFromTheFramesItKeeps() async {
        let t0 = 30000.0
        let signature = [UInt8](repeating: 100, count: 576)
        let full47 = piece(47, "ABCDE")
        let full48 = piece(48, "ABCDE")
        let short49 = piece(49, "ABC")
        let collector = SeriesCollector(start: t0, clock: RhythmClock(pages: 6),
                                        reader: { buffer in
                                            let id = CVPixelBufferGetWidth(buffer) - 8
                                            var text = TextScore()
                                            text.chars = 120
                                            text.confidence = 0.9
                                            text.pieces = id < 2 ? [full47] : (id < 4 ? [full48] : [short49])
                                            return text
                                        },
                                        renderer: { buffer in (data: Data([UInt8(CVPixelBufferGetWidth(buffer) - 8)]), width: 1920, height: 1080) })
        for id in 0..<6 {
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 8 + id, 4, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
            guard let buffer = pixelBuffer else { return XCTFail("kare oluşturulamadı") }
            collector.offer(buffer: buffer, time: t0 + 0.1 + 0.5 * Double(id), sharpness: 100, signature: signature)
        }
        let outcome = await collector.finish()
        XCTAssertEqual(outcome.items.count, 6)
        XCTAssertEqual(outcome.coverage.incomplete, [49], outcome.coverage.logText)
    }
}

/// Temiz an ve sınırlı tekrar azaltma (kullanıcı kararı 2026-11-19: "tüm tekrarları atmak yerine azaltabiliriz").
final class FrameThinningTests: XCTestCase {
    private func words(_ range: ClosedRange<Int>) -> Set<String> {
        return Set(range.map { "sozcuk\($0)" })
    }

    private func item(_ id: UInt8, time: Double, words: Set<String>, options: String = "", blockiness: Double = 1.0, chars: Int = 400) -> SeriesItem {
        var text = TextScore()
        text.chars = chars
        text.confidence = 0.9
        text.words = words
        text.options = Set(options)
        var result = SeriesItem(time: time, jpeg: Data([id]), width: 1920, height: 1080, sharpness: 500, text: text, signature: [])
        result.blockiness = blockiness
        return result
    }

    private func ids(_ items: [SeriesItem]) -> [UInt8] {
        return items.compactMap { $0.jpeg.first }
    }

    func testOfSeveralFramesShowingTheSameContentTheBestTwoStay() {
        let list = [
            item(1, time: 0.0, words: words(1...40), chars: 400),
            item(2, time: 0.5, words: words(1...40), chars: 300),
            item(3, time: 1.0, words: words(1...40), chars: 500),
            item(4, time: 1.5, words: words(1...40), chars: 450),
            item(5, time: 2.0, words: words(41...80))
        ]
        let thinned = SeriesPool.thinned(list)
        XCTAssertEqual(ids(thinned.kept), [3, 4, 5], "Aynı içerikten en iyi iki kare kalır (hepsi atılmaz), zaman sırası korunur")
        XCTAssertEqual(thinned.report, SeriesPool.ThinReport(dirty: 0, repeats: 2))
    }

    func testTwoFramesWithTheSameContentBothStay() {
        let list = [item(1, time: 0.0, words: words(1...40)), item(2, time: 0.5, words: words(1...40))]
        XCTAssertEqual(ids(SeriesPool.thinned(list).kept), [1, 2], "İki kare yedektir: azaltma üçüncüden başlar")
    }

    func testAFrameShowingADifferentOptionIsNeverARepeat() {
        let list = [
            item(1, time: 0.0, words: words(1...40), options: "ABC"),
            item(2, time: 0.5, words: words(1...40), options: "ABCD"),
            item(3, time: 1.0, words: words(1...40), options: "ABC"),
            item(4, time: 1.5, words: words(1...40), options: "ABCDE")
        ]
        XCTAssertEqual(ids(SeriesPool.thinned(list).kept), [1, 2, 3, 4], "Yeni bir şık harfi gösteren kare tekrar sayılmaz")
    }

    func testFramesThatMovedOnAreNotRepeats() {
        let list = [
            item(1, time: 0.0, words: words(1...40)),
            item(2, time: 0.5, words: words(11...50)),
            item(3, time: 1.0, words: words(21...60))
        ]
        XCTAssertEqual(ids(SeriesPool.thinned(list).kept), [1, 2, 3], "Kamera kaydıkça gelen kareler yeni içerik taşır")
    }

    func testFramesWithLittleTextAreLeftAlone() {
        let list = [
            item(1, time: 0.0, words: words(1...5)),
            item(2, time: 0.5, words: words(1...5)),
            item(3, time: 1.0, words: words(1...5), blockiness: 1.18),
            item(4, time: 1.5, words: words(1...5))
        ]
        XCTAssertEqual(ids(SeriesPool.thinned(list).kept), [1, 2, 3, 4], "Az yazı okunan karede hüküm verilmez")
    }

    func testAHalfBrokenFrameIsDroppedOnlyWhenItsCleanNeighboursShowTheSameContent() {
        let covered = [
            item(1, time: 0.0, words: words(1...40)),
            item(2, time: 0.5, words: words(10...45), blockiness: 1.18),
            item(3, time: 1.0, words: words(20...60))
        ]
        let thinned = SeriesPool.thinned(covered)
        XCTAssertEqual(ids(thinned.kept), [1, 3], "Yarı bozuk karenin içeriği komşu temiz karelerde var")
        XCTAssertEqual(thinned.report, SeriesPool.ThinReport(dirty: 1, repeats: 0))

        let newContent = [
            item(1, time: 0.0, words: words(1...40)),
            item(2, time: 0.5, words: words(100...140), blockiness: 1.18),
            item(3, time: 1.0, words: words(20...60))
        ]
        XCTAssertEqual(ids(SeriesPool.thinned(newContent).kept), [1, 2, 3], "Başka yerde olmayan içerik taşıyan kare, yarı bozuk da olsa gider")

        let newOption = [
            item(1, time: 0.0, words: words(1...40), options: "ABC"),
            item(2, time: 0.5, words: words(10...45), options: "ABCE", blockiness: 1.18),
            item(3, time: 1.0, words: words(20...60), options: "ABC")
        ]
        XCTAssertEqual(ids(SeriesPool.thinned(newOption).kept), [1, 2, 3], "Komşularda olmayan bir şık harfi gösteriyor")

        let alone = [
            item(1, time: 0.0, words: words(1...40)),
            item(2, time: 5.0, words: words(10...45), blockiness: 1.18),
            item(3, time: 10.0, words: words(20...60))
        ]
        XCTAssertEqual(ids(SeriesPool.thinned(alone).kept), [1, 2, 3], "Yakınında temiz kare yok")

        let dirtyNeighbours = [
            item(1, time: 0.0, words: words(1...40), blockiness: 1.17),
            item(2, time: 0.5, words: words(10...45), blockiness: 1.18),
            item(3, time: 1.0, words: words(20...60), blockiness: 1.19)
        ]
        XCTAssertEqual(ids(SeriesPool.thinned(dirtyNeighbours).kept), [1, 2, 3], "Komşular da yarı bozuksa hiçbiri atılmaz")
    }

    func testAVeryBlurryFrameIsDroppedOnlyWhenSharperFramesShowTheSameQuestion() {
        func shown(_ id: UInt8, time: Double, sharpness: Double, numbers: Set<Int>, options: String = "AC") -> SeriesItem {
            var result = item(id, time: time, words: words(1...5), options: options)
            result.sharpness = sharpness
            result.text?.questionNumbers = numbers
            return result
        }
        let list = [
            shown(1, time: 0, sharpness: 800, numbers: [4]),
            shown(2, time: 5, sharpness: 900, numbers: [4]),
            shown(3, time: 10, sharpness: 60, numbers: [4]),      // çok bulanık; 4. soru iki net karede de görülüyor
            shown(4, time: 15, sharpness: 50, numbers: [9]),      // çok bulanık ama 9. soruyu gösteren başka kare yok
            shown(5, time: 20, sharpness: 700, numbers: [5])
        ]
        let thinned = SeriesPool.thinned(list)
        XCTAssertEqual(ids(thinned.kept), [1, 2, 4, 5], "Yalnız daha net karelerde de görülen soruyu gösteren bulanık kare atılır")
        XCTAssertEqual(thinned.report, SeriesPool.ThinReport(dirty: 0, repeats: 0, blurry: 1))

        let between = [
            shown(1, time: 0.0, sharpness: 800, numbers: [], options: "ABCDE"),
            shown(2, time: 0.5, sharpness: 40, numbers: [], options: "AC"),
            shown(3, time: 1.0, sharpness: 900, numbers: [], options: "ABCDE"),
            shown(4, time: 9.0, sharpness: 40, numbers: [], options: "AC")      // yakınında net kare yok
        ]
        XCTAssertEqual(ids(SeriesPool.thinned(between).kept), [1, 3, 4], "Numara yoksa iki yanındaki net kareler aynı şıkları göstermeli")

        let allSharp = [
            shown(1, time: 0, sharpness: 2000, numbers: [4]),
            shown(2, time: 5, sharpness: 2100, numbers: [4]),
            shown(3, time: 10, sharpness: 400, numbers: [4])
        ]
        XCTAssertEqual(ids(SeriesPool.thinned(allSharp).kept), [1, 2, 3], "Netliği 300'ün üstündeki kare, ötekiler çok daha net olsa da bulanık sayılmaz")
    }

    func testThePoolThinsTheFreeScanSelectionUnlessTurnedOff() {
        var pool = SeriesPool()
        pool.keepAll = true
        for (index, chars) in [400, 300, 500, 450].enumerated() {
            pool.add(item(UInt8(index + 1), time: Double(index) * 0.5, words: words(1...40), chars: chars))
        }
        XCTAssertEqual(ids(pool.selected(minPages: 0)), [3, 4])
        XCTAssertEqual(pool.thinReport(), SeriesPool.ThinReport(dirty: 0, repeats: 2))
        pool.thinFrames = false
        XCTAssertEqual(ids(pool.selected(minPages: 0)), [1, 2, 3, 4], "Ayar kapalıyken geçerli karelerin hepsi gider")
        XCTAssertEqual(pool.thinReport(), SeriesPool.ThinReport())
    }

    func testACleanerFrameBeatsASlightlySharperButBlockyOne() {
        XCTAssertEqual(SeriesSelection.cleanScore(sharpness: 500, blockiness: 1.0), 500, accuracy: 0.001, "Temiz karede netlik olduğu gibi kalır")
        XCTAssertGreaterThan(SeriesSelection.cleanScore(sharpness: 900, blockiness: 1.03), SeriesSelection.cleanScore(sharpness: 1200, blockiness: 1.20))
        XCTAssertGreaterThan(SeriesSelection.cleanScore(sharpness: 3000, blockiness: 1.20), SeriesSelection.cleanScore(sharpness: 900, blockiness: 1.03),
                             "Çok daha net kare, bloklaşmış da olsa kazanır")
    }

    func testTheWinnerOfAHalfSecondIsTheCleanMoment() async {
        let t0 = 40000.0
        let signature = [UInt8](repeating: 100, count: 576)
        let collector = SeriesCollector(start: t0, clock: RhythmClock(pages: 6),
                                        reader: { _ in
                                            var text = TextScore()
                                            text.chars = 120
                                            text.confidence = 0.9
                                            return text
                                        },
                                        renderer: { buffer in (data: Data([UInt8(CVPixelBufferGetWidth(buffer) - 8)]), width: 1920, height: 1080) })
        var buffers: [CVPixelBuffer] = []
        for id in 1...2 {
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 8 + id, 4, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
            if let buffer = pixelBuffer { buffers.append(buffer) }
        }
        guard buffers.count == 2 else { return XCTFail("kare oluşturulamadı") }
        collector.offer(buffer: buffers[0], time: t0 + 0.1, sharpness: 900, signature: signature, blockiness: 1.03)
        collector.offer(buffer: buffers[1], time: t0 + 0.3, sharpness: 1200, signature: signature, blockiness: 1.20)   // aynı yarım saniye: daha net ama bloklaşmış
        let outcome = await collector.finish()
        XCTAssertEqual(ids(outcome.items), [1], "Aynı yarım saniyede temiz an karesi alınır")
    }

    func testFrameThinningIsOnByDefaultAndCanBeTurnedOff() {
        let defaults = UserDefaults(suiteName: "g526.testler.\(UUID().uuidString)")!
        let settings = CameraSettings(defaults: defaults)
        XCTAssertTrue(settings.thinFrames)
        settings.thinFrames = false
        XCTAssertFalse(CameraSettings(defaults: defaults).thinFrames)
    }
}

/// "Görülen sorular" sıkı kurala geçti; görüntü bozuk gelince "daha yavaş" denir (kullanıcı isteği 2026-11-19: "uygun olanları düzelt").
final class ScanCoachingTests: XCTestCase {
    func testWithStrongReadingOnlyStrictlySeenQuestionsCount() {
        var text = TextScore()
        text.questionNumbers = [7, 43, 47]          // gevşek kural: metnin içindeki "7." ve "43-46" da sayılmış
        XCTAssertEqual(text.shownNumbers, [7, 43, 47], "Hızlı okumada parça çıkarılmaz: eski kural")
        var strict = QuestionPiece()
        strict.number = 47
        strict.body = 40
        strict.options = ["A": OptionView(), "B": OptionView()]
        var bare = QuestionPiece()
        bare.number = 43
        bare.body = 40
        text.pieces = [strict, bare]
        text.piecesRead = true
        XCTAssertEqual(text.shownNumbers, [47], "Güçlü okumada yalnız numarası, kökü ve şıklarıyla görülen soru sayılır")
        text.pieces = []
        XCTAssertEqual(text.shownNumbers, [], "Karede soru yoksa metindeki sayılar soru sayılmaz")
    }

    func testTheSlowDownHintNeedsHalfOfTheFramesToBeBroken() {
        XCTAssertTrue(SeriesRhythm.isRough(valid: 16, damaged: 4, blurry: 0, dirty: 8), "20 karenin 12'si bozuk ya da yarı bozuk")
        XCTAssertTrue(SeriesRhythm.isRough(valid: 10, damaged: 10, blurry: 0, dirty: 0))
        XCTAssertFalse(SeriesRhythm.isRough(valid: 18, damaged: 2, blurry: 0, dirty: 3), "Dörtte biri bozuk: olağan")
        XCTAssertFalse(SeriesRhythm.isRough(valid: 2, damaged: 3, blurry: 0, dirty: 2), "Az kare ölçülmüşse hüküm verilmez")
        XCTAssertFalse(SeriesRhythm.isRough(valid: 0, damaged: 0, blurry: 0, dirty: 0))
        XCTAssertEqual(SeriesRhythm.slowDown, "Görüntü bozuk geliyor; kamerayı daha yavaş kaydırın.")
        XCTAssertEqual(SeriesRhythm.roughText(fast: true), SeriesRhythm.slowDown, "Kamera gerçekten hızlı kaydırıldıysa")
        XCTAssertEqual(SeriesRhythm.roughText(fast: false), "Görüntü bozuk geliyor; kamerayı her yerde bir iki saniye sabit tutun.",
                       "Kamera hızlı değilse sorun hız değildir: görüntü ancak kamera bir yerde durunca toparlanır")
        XCTAssertEqual(LinkLog.unique(["en0 (Wi-Fi)", "en0 (Wi-Fi)", "pdp_ip0 (hücresel)"]), ["en0 (Wi-Fi)", "pdp_ip0 (hücresel)"])
    }

    func testHalfBrokenFramesAreCountedInThePageQuality() async {
        let t0 = 50000.0
        let signature = [UInt8](repeating: 100, count: 576)
        let collector = SeriesCollector(start: t0, clock: RhythmClock(pages: 6),
                                        reader: { _ in
                                            var text = TextScore()
                                            text.chars = 120
                                            text.confidence = 0.9
                                            return text
                                        },
                                        renderer: { _ in (data: Data([1]), width: 1920, height: 1080) })
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 4, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        guard let buffer = pixelBuffer else { return XCTFail("kare oluşturulamadı") }
        collector.offer(buffer: buffer, time: t0 + 0.1, sharpness: 100, signature: signature)
        collector.offer(buffer: buffer, time: t0 + 0.6, sharpness: 100, signature: signature, blockiness: 1.18)
        collector.offer(buffer: buffer, time: t0 + 1.1, sharpness: 100, signature: signature, blockiness: 1.20)
        collector.offer(buffer: buffer, time: t0 + 1.6, sharpness: 100, signature: signature, blockiness: FrameAnalysis.damagedBlockiness + 0.5)
        await collector.settle()
        let quality = collector.quality(from: 0, to: 10)
        XCTAssertEqual(quality.valid, 3)
        XCTAssertEqual(quality.dirty, 2, "Bozuk eşiğinin altında kalan ama belirgin bloklaşmış kareler")
        XCTAssertEqual(quality.damaged, 1)
        _ = await collector.finish()
    }

    func testTheFrameDifferenceNoteGivesQuartilesAndTheStillShare() {
        XCTAssertEqual(SeriesCollector.diffNote([]), "")
        let note = SeriesCollector.diffNote([1, 1, 3, 5, 9])
        XCTAssertTrue(note.hasPrefix("ölçüm 5; çeyrekler 1.0 / 3.0 / 5.0; "), note)
        XCTAssertTrue(note.hasSuffix("(altında kalan %40)"), note)
    }
}

/// Kopmaların ayrıntılı günlüğü (kullanıcı isteği 2026-11-19): ne zaman koptu, ne kadar bağlıydı, kaçıncı kopma, ne kadar sonra döndü.
final class LinkTimelineTests: XCTestCase {
    func testDropsAndReturnsAreWrittenWithTheirDurations() {
        var line = LinkTimeline(name: "Wi-Fi")
        XCTAssertEqual(line.update(up: true, at: 100, detail: "adres 192.168.100.23"), "Wi-Fi: bağlı (adres 192.168.100.23)")
        XCTAssertNil(line.update(up: true, at: 150, detail: "adres 192.168.100.23"), "Durum değişmediyse satır yazılmaz")
        XCTAssertEqual(line.update(up: false, at: 512), "Wi-Fi KOPTU: 412 sn bağlıydı; bu çalıştırmada 1. kopma")
        XCTAssertNil(line.update(up: false, at: 520))
        XCTAssertEqual(line.update(up: true, at: 549, detail: "adres 192.168.100.23"), "Wi-Fi geri geldi: 37 sn yoktu (adres 192.168.100.23)")
        XCTAssertEqual(line.update(up: false, at: 600), "Wi-Fi KOPTU: 51 sn bağlıydı; bu çalıştırmada 2. kopma")
        XCTAssertEqual(line.drops, 2)
    }

    func testALinkThatIsMissingFromTheStartIsNotCountedAsADrop() {
        var line = LinkTimeline(name: "Kulaklık")
        XCTAssertEqual(line.update(up: false, at: 10), "Kulaklık: YOK")
        XCTAssertEqual(line.drops, 0)
        XCTAssertEqual(line.update(up: true, at: 25), "Kulaklık geri geldi: 15 sn yoktu")
    }

    func testTheReasonOfARouteChangeIsWrittenInPlainWords() {
        XCTAssertEqual(AudioRouting.changeDetail(nil), "")
        let gone = AudioRouting.changeDetail([AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        XCTAssertEqual(gone, "neden: aygıt ayrıldı (kulaklık koptu, kapandı ya da uzaklaştı)")
        XCTAssertEqual(AudioRouting.reasonName(.newDeviceAvailable), "yeni aygıt bağlandı")
        let resumable = AudioRouting.interruptionDetail([AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue])
        XCTAssertEqual(resumable, "ses sürdürülebilir")
    }
}
