import XCTest
import CoreGraphics
@testable import G526CameraDrive

/// Konumlandırma değerlendirmesi (kullanıcı kararı 2026-11-18): (1) kadrajda en az bir soru tam görünüyorsa hemen alınır, kesik komşu sorular "ekrana
/// sığmıyor" sebebi olmaz; (2) alınan sorunun üzerinde yeniden durulur ve başka soru yoksa "zaten alındı, başka soruya geçin" denir, kadrajda birkaç soru
/// varken mükerrer alım sorun sayılmaz; (3) yazının yönü bulunurken harf sayısı değil anlamlı sözcük sayısı da bakılır (baş aşağı okuma 80'den çok harf
/// verebiliyordu); (4) kamera oynamadan alınan, yazı tanıma gürültüsüyle birbirinden farklı görünen tekrarlar PDF'te birleşir.
/// Cihazda doğrulanmadı.

// MARK: - Tam görünen soru

final class CompleteQuestionTests: XCTestCase {
    private func line(_ text: String, top: Double, x: Double = 0.1, width: Double = 0.8) -> (text: String, box: CGRect) {
        return (text: text, box: CGRect(x: x, y: 1 - top - 0.03, width: width, height: 0.03))
    }

    private func question(_ number: Int, first: Double, upTo last: String = "E", step: Double = 0.10) -> [(text: String, box: CGRect)] {
        var rows = [line("\(number). Aşağıdaki cümlelerin hangisinde yazım yanlışı vardır", top: first)]
        for (i, letter) in ["A", "B", "C", "D", "E"].enumerated() {
            rows.append(line("\(letter)) \(i + 1). seçenek metni burada", top: first + step * Double(i + 1)))
            if letter == last { break }
        }
        return rows
    }

    private func metrics() -> PageMetrics {
        var m = PageMetrics()
        m.hasPage = true
        m.hasText = true
        m.x0 = 0.2; m.x1 = 0.8; m.y0 = 0.2; m.y1 = 0.8
        m.cells = 600
        m.sharp = 1.0
        return m
    }

    func testANumberedQuestionThatIsFullyVisibleIsCountedWithItsNumberAndWords() {
        let v = ViewLines.make(question(12, first: 0.10))
        XCTAssertEqual(v.completeQuestions, 1)
        XCTAssertEqual(v.completeMarks.first?.number, 12)
        XCTAssertGreaterThanOrEqual(v.completeMarks.first?.keys.count ?? 0, QuestionMark.minKeys)
    }

    /// Gerçek günlük: yazı tanıma soru numarasını ve ")" işaretini düşürüyor ("A The only way", "E in which stage")
    func testAQuestionWhoseNumberAndParenthesesWereNotReadIsStillCountedFromItsOptions() {
        let rows = [line("Answer these questions according to the passage", top: 0.10),
                    line("A The only way to survive", top: 0.20),
                    line("B The mentioned feeling is fear", top: 0.30),
                    line("C Heart rate increases quickly", top: 0.40),
                    line("D Alert in case of danger", top: 0.50),
                    line("E in which stage the body reacts", top: 0.60)]
        let v = ViewLines.make(rows)
        XCTAssertEqual(v.completeQuestions, 1)
        XCTAssertNil(v.completeMarks.first?.number)
    }

    func testAQuestionCutBeforeItsLastOptionIsNotComplete() {
        XCTAssertEqual(ViewLines.make(question(13, first: 0.10, upTo: "C")).completeQuestions, 0)
        let articleLines = [line("A study found that the number of people grew", top: 0.10), line("and the rest of them stayed at home", top: 0.20)]
        XCTAssertEqual(ViewLines.make(articleLines).completeQuestions, 0, "\"A study\" bir şık değildir")
    }

    func testOneCompleteQuestionBesideCutOnesIsAcceptedAtOnceInsteadOfAskingToMoveAway() {
        let rows = question(12, first: 0.05) + question(13, first: 0.60, upTo: "C")
        let v = ViewLines.make(rows)
        XCTAssertEqual(v.completeQuestions, 1)
        XCTAssertFalse(v.bottomComplete, "Alttaki soru kesik")
        for plan in [ShotPlan.any, .wholePage, .halves] {
            let n = FramingCoach.note(metrics(), lines: v, sharpFloor: 0.45, firstReadable: true, plan: plan)
            XCTAssertEqual(n.kind, .taken, "Plan \(plan): tam görünen soru varken uzaklaşma / kaydırma istenmez")
            XCTAssertTrue(n.kind.isGood)
        }
    }

    func testWithoutACompleteQuestionTheOldCorrectionsStillApplyAndTheDamagedFrameIsNeverAccepted() {
        let cutOnly = ViewLines.make(question(13, first: 0.60, upTo: "C"))
        XCTAssertNotEqual(FramingCoach.note(metrics(), lines: cutOnly, sharpFloor: 0.45, firstReadable: true).kind, .taken)
        var damaged = metrics()
        damaged.damaged = true
        let v = ViewLines.make(question(12, first: 0.10))
        XCTAssertEqual(FramingCoach.note(damaged, lines: v, sharpFloor: 0.45, firstReadable: true).kind, .damaged)
        XCTAssertNotEqual(FramingCoach.note(metrics(), lines: v, sharpFloor: 0.45, verbose: true, firstReadable: true).kind, .taken, "Kadraj kontrolü eski tarifi verir")
    }
}

// MARK: - Zaten alınan soru

final class AlreadyTakenTests: XCTestCase {
    private func line(_ text: String, top: Double) -> (text: String, box: CGRect) {
        return (text: text, box: CGRect(x: 0.1, y: 1 - top - 0.03, width: 0.8, height: 0.03))
    }

    /// Her sorunun kendi sözcükleri vardır (`topic` ekiyle): iki ayrı soru birbirine benzemesin
    private func question(_ number: Int, first: Double, upTo last: String = "E", step: Double = 0.10, topic: String = "yazım") -> [(text: String, box: CGRect)] {
        var rows = [line("\(number). \(topic)lar \(topic)ler \(topic)cılar \(topic)sizlik hangisidir", top: first)]
        for (i, letter) in ["A", "B", "C", "D", "E"].enumerated() {
            rows.append(line("\(letter)) \(topic)ağa \(topic)ece \(topic)ine \(topic)ona", top: first + step * Double(i + 1)))
            if letter == last { break }
        }
        return rows
    }

    private func metrics() -> PageMetrics {
        var m = PageMetrics()
        m.hasPage = true
        m.hasText = true
        m.x0 = 0.2; m.x1 = 0.8; m.y0 = 0.2; m.y1 = 0.8
        m.cells = 600
        m.sharp = 1.0
        return m
    }

    private func step(_ t: inout FramingCoachTimer, _ lines: ViewLines?, at time: TimeInterval, still: TimeInterval = 1) -> String? {
        return t.step(metrics: metrics(), lines: lines, time: time, stillFor: still, sharpFloor: 0.45, firstReadable: true, wholeFirst: true)
    }

    func testAFullyVisibleQuestionIsSpokenWithASingleMeasurementAndNamesTheQuestion() {
        var t = FramingCoachTimer()
        let v = ViewLines.make(question(12, first: 0.10))
        XCTAssertEqual(step(&t, v, at: 10), FramingCoach.okText, "Tek ölçüm yeter: ilk cümle bekletilmez")
        XCTAssertTrue(t.lastWasGood)
        XCTAssertEqual(t.lastCapture, "12. soru tamam, sıradaki 13. soru.")
        XCTAssertEqual(FramingCoach.withCapture(FramingCoach.okText, capture: t.lastCapture), "12. soru tamam, sıradaki 13. soru.")
    }

    func testStayingOnTheQuestionJustTakenIsNotCalledAlreadyTaken() {
        var t = FramingCoachTimer()
        let v = ViewLines.make(question(12, first: 0.10))
        XCTAssertNotNil(step(&t, v, at: 10))
        for time in [11.0, 12.0, 20.0, 30.0] { XCTAssertNil(step(&t, v, at: time), "Aynı durgunlukta yeniden söylenmez") }
    }

    func testStoppingAgainOnTheTakenQuestionWithNothingElseOnScreenSaysItIsAlreadyTaken() {
        var t = FramingCoachTimer()
        let v = ViewLines.make(question(12, first: 0.10))
        XCTAssertNotNil(step(&t, v, at: 10))
        XCTAssertNil(step(&t, v, at: 12, still: 0.05), "Kamera oynuyor")
        XCTAssertNil(step(&t, v, at: 14.0), "Düzeltme ardışık iki ölçümle söylenir")
        XCTAssertEqual(step(&t, v, at: 14.3), "12. soru zaten alındı. Başka soruya geçin.")
        XCTAssertFalse(t.lastWasGood, "Düzeltmedir: sonuna \"Alındı. Sonraki.\" eklenmez")
    }

    func testAnotherQuestionAfterTheTakenOneIsTakenNormally() {
        var t = FramingCoachTimer()
        XCTAssertNotNil(step(&t, ViewLines.make(question(12, first: 0.10)), at: 10))
        _ = step(&t, nil, at: 12, still: 0.05)
        let next = ViewLines.make(question(13, first: 0.10, topic: "noktalama"))
        let text = step(&t, next, at: 14)
        XCTAssertNotNil(text)
        XCTAssertFalse((text ?? "").contains("zaten"), "Başka soru: itiraz edilmez")
        XCTAssertEqual(t.lastCapture, "13. soru tamam, sıradaki 14. soru.")
    }

    func testSeveralQuestionsOnScreenNeverGetTheAlreadyTakenObjection() {
        var t = FramingCoachTimer()
        let two = ViewLines.make(question(12, first: 0.05, step: 0.05) + question(13, first: 0.40, step: 0.05, topic: "noktalama"))
        XCTAssertEqual(two.completeQuestions, 2)
        XCTAssertNotNil(step(&t, two, at: 10))
        _ = step(&t, two, at: 12, still: 0.05)
        for time in [14.0, 14.3, 14.6, 20.0] { XCTAssertFalse((step(&t, two, at: time) ?? "").contains("zaten")) }
        // Komşu soru kesik görünse de (kadrajda yalnız bir tam soru) mükerrer alım itiraz konusu değildir
        var u = FramingCoachTimer()
        let withCutNeighbour = ViewLines.make(question(12, first: 0.05) + question(13, first: 0.60, upTo: "C", topic: "noktalama"))
        XCTAssertEqual(withCutNeighbour.completeQuestions, 1)
        XCTAssertNotNil(step(&u, withCutNeighbour, at: 10))
        _ = step(&u, withCutNeighbour, at: 12, still: 0.05)
        for time in [14.0, 14.3, 14.6, 20.0] { XCTAssertFalse((step(&u, withCutNeighbour, at: time) ?? "").contains("zaten")) }
    }

    func testTheSameQuestionIsRecognisedDespiteReadingNoiseAndANewSessionForgetsIt() {
        let a = QuestionMark(number: nil, keys: Set((0..<20).map { "kelime\($0)" }))
        let noisy = QuestionMark(number: nil, keys: Set((0..<14).map { "kelime\($0)" }).union((0..<6).map { "bozuk\($0)" }))
        XCTAssertTrue(a.isSame(as: noisy), "Okuma gürültüsü kimliği bozmaz")
        let other = QuestionMark(number: nil, keys: Set((0..<20).map { "baska\($0)" }))
        XCTAssertFalse(a.isSame(as: other))
        XCTAssertTrue(QuestionMark(number: 7, keys: []).isSame(as: QuestionMark(number: 7, keys: ["kısa"])), "Sözcük azsa numaraya bakılır")
        XCTAssertFalse(QuestionMark(number: nil, keys: []).isSame(as: QuestionMark(number: nil, keys: [])))
        var t = FramingCoachTimer()
        let v = ViewLines.make(question(12, first: 0.10))
        _ = step(&t, v, at: 10)
        t.reset()
        _ = step(&t, v, at: 12, still: 0.05)
        _ = step(&t, v, at: 14.0)
        XCTAssertFalse((step(&t, v, at: 14.3) ?? "").contains("zaten"), "Yeni oturum önceki alınanları unutur")
    }
}

// MARK: - Yön bulma: anlamlı sözcük

final class OrientationSenseTests: XCTestCase {
    func testCommonWordsAreCountedInEnglishAndTurkishButGarbageGivesNone() {
        XCTAssertGreaterThanOrEqual(TextSense.count("the history of the world and its people in the past"), 5)
        XCTAssertGreaterThanOrEqual(TextSense.count("bu bir ve için"), 4)
        XCTAssertEqual(TextSense.count("questlons accordlng rJroon xz qq"), 0)
        XCTAssertEqual(TextSense.count(""), 0)
    }

    func testTheOppositeOrientationIsOnTheSameAxis() {
        XCTAssertEqual(ImageOrientation.normal.opposite, .rotate180)
        XCTAssertEqual(ImageOrientation.rotate180.opposite, .normal)
        XCTAssertEqual(ImageOrientation.right90.opposite, .left90)
        XCTAssertEqual(ImageOrientation.left90.opposite, .right90)
    }

    /// Gerçek günlük: ilk denenen yön baş aşağı okunup 80'den çok harf verdi, sayfalar 180° ters kaydedildi
    func testUpsideDownReadingWithManyLettersLosesToTheDirectionThatMakesSense() {
        // Değer = anlamlı sözcük sayısı; harf sayısı ayrı
        var reads: [ImageOrientation] = []
        let found = OrientationFinder.find(preferred: .normal, hint: { [.right90, .left90] }, sense: { (v: Int?) in v ?? 0 }) { orientation -> (value: Int?, chars: Int) in
            reads.append(orientation)
            switch orientation {
            case .normal: return (0, 10)
            case .right90: return (1, 200)     // baş aşağı: çok harf, anlamsız
            case .left90: return (9, 180)      // dik: anlamlı
            case .rotate180: return (0, 5)
            }
        }
        XCTAssertEqual(found.orientation, .left90)
        XCTAssertEqual(found.value, 9)
        XCTAssertEqual(reads, [.normal, .right90, .left90], "Anlamlı yön bulununca durur")
    }

    func testAPreferredDirectionThatReadsManyLettersButNoRealWordsIsCheckedAgainstTheOppositeOne() {
        var reads: [ImageOrientation] = []
        let found = OrientationFinder.find(preferred: .normal, sense: { (v: Int?) in v ?? 0 }) { orientation -> (value: Int?, chars: Int) in
            reads.append(orientation)
            return orientation == .rotate180 ? (8, 140) : (0, 150)
        }
        XCTAssertEqual(found.orientation, .rotate180)
        XCTAssertEqual(reads, [.normal, .rotate180], "Önce yalnız karşı yön okunur")
    }

    func testAMeaningfulPreferredDirectionIsReadAloneAndGarbageEverywhereKeepsThePreferredOne() {
        var reads = 0
        let alone = OrientationFinder.find(preferred: .normal, sense: { (v: Int?) in v ?? 0 }) { _ -> (value: Int?, chars: Int) in
            reads += 1
            return (10, 120)
        }
        XCTAssertEqual(alone.orientation, .normal)
        XCTAssertEqual(reads, 1, "Anlamlı okuma varken başka yön denenmez")
        let garbage = OrientationFinder.find(preferred: .normal, sense: { (v: Int?) in v ?? 0 }) { _ -> (value: Int?, chars: Int) in (1, 120) }
        XCTAssertEqual(garbage.orientation, .normal, "Hiçbir yön belirgin daha anlamlı değilse tercih edilen kalır")
    }

    func testWithoutASenseFunctionTheOldCharacterCountRulesApply() {
        let found = OrientationFinder.find(preferred: .normal) { orientation -> (value: String?, chars: Int) in
            orientation == .right90 ? ("x", 200) : ("y", 10)
        }
        XCTAssertEqual(found.orientation, .right90)
    }

    func testTheSentenceCarriesAnImprovementForReadScoresToo() {
        var score = TextScore.make(lines: [(text: "The history of the world and its people", confidence: 0.9)])
        XCTAssertGreaterThanOrEqual(score.sense, 4)
        score = TextScore.make(lines: [(text: "questlons accordlng rJroon", confidence: 0.9)])
        XCTAssertEqual(score.sense, 0)
        XCTAssertGreaterThan(score.chars, 0)
    }
}

// MARK: - Tekrarların birleşmesi

final class StillDuplicateTests: XCTestCase {
    private let base = (0..<40).map { "kelime\($0)" }

    private func item(_ id: UInt8, time: Double, noise: Int, options: String = "", quality: Int = 200,
                      signature: [UInt8] = [UInt8](repeating: 100, count: 576)) -> SeriesItem {
        var t = TextScore()
        t.chars = quality
        t.confidence = 1
        // Her karede ilk 30 kelime doğru okunur, 10 kelime başka bozulur (hızlı yazı tanıma gürültüsü): Jaccard 0,6
        t.words = Set(base.prefix(30)).union((0..<10).map { "bozuk\(noise)x\($0)" })
        t.options = Set(options)
        return SeriesItem(time: time, jpeg: Data([id]), width: 1920, height: 1080, sharpness: 100, text: t, signature: signature)
    }

    func testNoisyReadingsOfAStillViewAreMergedLikeTheRealSessionsNeeded() {
        var pool = SeriesPool()
        for k in 0..<6 { pool.add(item(UInt8(k + 1), time: Double(k), noise: k, quality: 200 + k)) }
        XCTAssertEqual(pool.items.count, 1, "Gerçek oturumda 60 sayfanın 39'u aynı görünümdü")
        XCTAssertEqual(pool.merged, 5)
        XCTAssertEqual(pool.items.first?.jpeg.first, 6, "En yüksek puanlı tekrar kalır")
    }

    func testAMovedCameraOrANewOptionKeepsBothFrames() {
        var moved = SeriesPool()
        moved.add(item(1, time: 1, noise: 1))
        moved.add(item(2, time: 2, noise: 2, signature: [UInt8](repeating: 140, count: 576)))   // imza farkı 40: görünüm değişti
        XCTAssertEqual(moved.items.count, 2)
        var option = SeriesPool()
        option.add(item(1, time: 1, noise: 1, options: "ABCD"))
        option.add(item(2, time: 2, noise: 2, options: "BCDE"))
        XCTAssertEqual(option.items.count, 2, "Yeni şık (E) belirdi: tekrar sayılmaz")
    }

    func testARepeatedViewAfterAnotherOneJoinsTheEarlierOneInsteadOfBeingAddedAgain() {
        var pool = SeriesPool()
        let other = [UInt8](repeating: 160, count: 576)
        func page(_ id: UInt8, _ k: Int, words: [String], signature: [UInt8]) -> SeriesItem {
            var t = TextScore()
            t.chars = 200
            t.confidence = 1
            t.words = Set(words)
            return SeriesItem(time: Double(id), jpeg: Data([id]), width: 1920, height: 1080, sharpness: 100, text: t, signature: signature)
        }
        let a = (0..<20).map { "alfa\($0)" }
        let b = (0..<20).map { "beta\($0)" }
        pool.add(page(1, 0, words: a, signature: [UInt8](repeating: 100, count: 576)))
        pool.add(page(2, 0, words: b, signature: other))
        pool.add(page(3, 0, words: a, signature: [UInt8](repeating: 100, count: 576)))   // A yeniden: son üç adaydan birincisiyle aynı
        XCTAssertEqual(pool.items.count, 2)
    }

    func testTheFinalSelectionDropsStillRepeatsThatWereNotNeighbours() {
        let items = (0..<4).map { item(UInt8($0 + 1), time: Double($0) * 10, noise: $0, quality: 100 + $0 * 10) }
        let kept = SeriesPool.distinct(items)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.jpeg.first, 4)
        XCTAssertEqual(TextScore.containment(["a", "b", "c", "d"], ["a", "b"]), 1)
        XCTAssertEqual(TextScore.containment([], ["a"]), 0)
    }
}
