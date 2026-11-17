import XCTest
import CoreVideo
@testable import G526CameraDrive

/// Toplu çekimde kare seçimi (kullanıcı kararı 2026-11-17): kameranın her karesi ölçülür, 0,5 sn'lik pencerelerin en netinden yazısı okunanlar PDF'e girer,
/// aynı görünümün tekrarı ve bulanık / boş kareler elenir.
final class SeriesSelectionTests: XCTestCase {
    // MARK: Yazı puanı

    private func lines(_ texts: [String], confidence: Float = 0.9) -> [(text: String, confidence: Float)] {
        return texts.map { (text: $0, confidence: confidence) }
    }

    func testAFullQuestionIsReadableAndItsOptionsAndNumberAreSeen() {
        let score = TextScore.make(lines: lines([
            "1. In order to irrigate their crops, African farmers",
            "A) abundant B) collective",
            "C) thorough D) wasteful",
            "E) practical"
        ]))
        XCTAssertTrue(score.isReadable)
        XCTAssertEqual(score.options, Set(["A", "B", "C", "D", "E"] as [Character]))
        XCTAssertEqual(score.questionNumbers, [1])
        XCTAssertTrue(score.words.contains("irrigate"))
        XCTAssertGreaterThan(score.value, 300, "Soru ve beş şık birlikte görününce yüksek puan")
    }

    func testBlurryOrEmptyFramesAreNotReadable() {
        XCTAssertFalse(TextScore.make(lines: []).isReadable)
        XCTAssertFalse(TextScore.make(lines: lines(["~~ .. --"], confidence: 0.9)).isReadable, "Harf yok")
        XCTAssertFalse(TextScore.make(lines: lines(["In order to irrigate their crops, African farmers invented elaborate"], confidence: 0.1)).isReadable,
                       "Güveni çok düşük satırlar sayılmaz")
        XCTAssertFalse(TextScore.make(lines: lines(["abc de"])).isReadable, "Birkaç harf okunur sayılmaz")
    }

    func testPageNumbersAndWordsInsideSentencesAreNotQuestionNumbersOrOptions() {
        let score = TextScore.make(lines: lines([
            "This test consists of 80 questions.",
            "information about Covid-19 and yourself is now",
            "the ABC) company"
        ]))
        XCTAssertTrue(score.questionNumbers.isEmpty, "\(score.questionNumbers)")
        XCTAssertFalse(score.options.contains("A"), "Sözcüğün ortasındaki harf şık değildir")
    }

    func testStemAloneScoresLowerThanTheSameQuestionWithItsOptions() {
        let stem = TextScore.make(lines: lines(["3. As concern increases worldwide about Covid-19 information yourself is now on social media"]))
        let full = TextScore.make(lines: lines(["3. As concern increases worldwide about Covid-19 information yourself is now on social media",
                                               "A) abundant B) collective C) thorough D) wasteful E) practical"]))
        XCTAssertGreaterThan(full.value, stem.value)
        XCTAssertEqual(stem.questionNumbers, [3])
    }

    func testSeveralQuestionNumbersOnOneLineAreAllSeen() {
        let score = TextScore.make(lines: lines(["1. In order to irrigate their crops 3. As concern increases worldwide"]))
        XCTAssertEqual(score.questionNumbers, [1, 3])
    }

    func testWordOverlapIsSymmetricAndBounded() {
        let a: Set<String> = ["alpha", "beta", "gamma", "delta"]
        let b: Set<String> = ["alpha", "beta", "gamma", "omega"]
        XCTAssertEqual(TextScore.overlap(a, b), 0.6, accuracy: 0.0001)
        XCTAssertEqual(TextScore.overlap(a, b), TextScore.overlap(b, a))
        XCTAssertEqual(TextScore.overlap(a, a), 1)
        XCTAssertEqual(TextScore.overlap(a, []), 0)
    }

    // MARK: Pencereler

    func testTheSharpestFrameOfEachWindowIsTheWinnerAndItIsGivenWhenTheNextWindowStarts() {
        var windows = WindowBest<Int>(start: 10, length: 0.5)
        XCTAssertNil(windows.offer(time: 10.05, sharpness: 50, payload: 1))
        XCTAssertNil(windows.offer(time: 10.20, sharpness: 300, payload: 2))
        XCTAssertNil(windows.offer(time: 10.40, sharpness: 120, payload: 3))
        XCTAssertEqual(windows.offer(time: 10.55, sharpness: 10, payload: 4), 2, "İlk pencerenin en netidir")
        XCTAssertEqual(windows.offer(time: 11.05, sharpness: 10, payload: 5), 4, "İkinci pencerenin tek karesi")
        XCTAssertEqual(windows.flush(), 5)
        XCTAssertNil(windows.flush(), "Pencere bir kez verilir")
    }

    func testEmptyWindowsAreSkippedAndLateOrEarlyFramesAreIgnored() {
        var windows = WindowBest<Int>(start: 10, length: 0.5)
        XCTAssertNil(windows.offer(time: 9.9, sharpness: 999, payload: 0), "Başlangıçtan önceki kare")
        XCTAssertNil(windows.offer(time: 10.1, sharpness: 80, payload: 1))
        XCTAssertEqual(windows.offer(time: 12.2, sharpness: 70, payload: 2), 1, "Aradaki boş pencereler atlanır")
        XCTAssertNil(windows.offer(time: 10.2, sharpness: 999, payload: 3), "Eski pencereye geç gelen kare yok sayılır")
        XCTAssertEqual(windows.flush(), 2)
    }

    // MARK: Havuz

    private func item(_ id: UInt8, time: Double, quality chars: Int, words: [String]? = nil, options: String = "", sharpness: Double = 100,
                      signature: [UInt8] = [UInt8](repeating: 100, count: 576)) -> SeriesItem {
        var text: TextScore?
        if let words = words {
            var t = TextScore()
            t.chars = chars
            t.confidence = 1
            t.words = Set(words)
            t.options = Set(options)
            text = t
        }
        return SeriesItem(time: time, jpeg: Data([id]), width: 1920, height: 1080, sharpness: sharpness, text: text, signature: signature)
    }

    private let pageA = ["irrigate", "crops", "african", "farmers", "invented", "elaborate", "systems", "transport", "water", "fields"]
    private let pageB = ["concern", "increases", "worldwide", "information", "covid", "yourself", "social", "media", "messaging", "apps"]

    func testConsecutiveFramesOfTheSameViewKeepOnlyTheBestOne() {
        var pool = SeriesPool()
        pool.add(item(1, time: 1, quality: 100, words: pageA))
        pool.add(item(2, time: 2, quality: 300, words: pageA))   // aynı görünüm, daha iyi
        pool.add(item(3, time: 3, quality: 200, words: pageA))   // aynı görünüm, daha kötü
        XCTAssertEqual(pool.items.map { $0.jpeg.first }, [2])
        XCTAssertEqual(pool.merged, 2)
    }

    /// Kamera bir sorunun üzerinde yavaş kayarken ardışık kareler çok benzer olur; sonrakinde yeni bir şık (E) belirmişse o kare "tekrar" diye atılmaz
    func testAFrameThatShowsANewOptionIsNeverMergedAwayAsARepeat() {
        let stem = pageA
        var pool = SeriesPool()
        pool.add(item(1, time: 1, quality: 300, words: stem, options: "ABCD"))
        pool.add(item(2, time: 2, quality: 200, words: stem, options: "BCDE"))   // aynı yazı, ama E görünüyor; A görünmüyor
        XCTAssertEqual(pool.items.map { $0.jpeg.first }, [1, 2], "İkisinin de ötekinde olmayan içeriği var: ikisi de kalır")
        XCTAssertEqual(pool.merged, 0)
    }

    func testAFrameThatShowsEverythingTheKeptOneShowsAndMoreReplacesIt() {
        var pool = SeriesPool()
        pool.add(item(1, time: 1, quality: 300, words: pageA, options: "AB"))
        pool.add(item(2, time: 2, quality: 100, words: pageA, options: "ABC"))   // daha az net ama daha çok içerik
        XCTAssertEqual(pool.items.map { $0.jpeg.first }, [2])
    }

    func testASharperFrameThatShowsLessDoesNotReplaceTheOneThatShowsMore() {
        var pool = SeriesPool()
        pool.add(item(1, time: 1, quality: 100, words: pageA, options: "ABCDE"))
        pool.add(item(2, time: 2, quality: 400, words: pageA, options: "AB"))
        XCTAssertEqual(pool.items.map { $0.jpeg.first }, [1], "E şıkkı yalnız birincide görünüyor")
    }

    func testManyNewWordsAlsoCountAsNewContent() {
        var pool = SeriesPool()
        let base = (0..<40).map { "base\($0)" }
        let more = base + (0..<8).map { "extra\($0)" }
        pool.add(item(1, time: 1, quality: 300, words: base, options: "AB"))
        pool.add(item(2, time: 2, quality: 200, words: more, options: "AB"))   // aynı şıklar ama 8 yeni kelime (yeni satırlar): aynı görünüm, ama fazlasını gösteriyor
        XCTAssertEqual(pool.items.map { $0.jpeg.first }, [2], "Yeni kare ötekinin tamamını ve fazlasını içeriyor")
        var other = SeriesPool()
        other.add(item(1, time: 1, quality: 300, words: base, options: "AB"))
        other.add(item(2, time: 2, quality: 200, words: base + (0..<3).map { "noise\($0)" }, options: "AB"))   // birkaç kelimelik OKR gürültüsü yeni içerik sayılmaz
        XCTAssertEqual(other.items.map { $0.jpeg.first }, [1])
    }

    func testDifferentTextIsKeptEvenWhenTheFrameSignaturesLookTheSame() {
        var pool = SeriesPool()
        pool.add(item(1, time: 1, quality: 200, words: pageA))
        pool.add(item(2, time: 2, quality: 200, words: pageB))   // imza aynı, yazı farklı: iki ayrı görünüm
        XCTAssertEqual(pool.items.map { $0.jpeg.first }, [1, 2])
        XCTAssertEqual(pool.merged, 0)
    }

    func testWithoutTextTheSignatureDecidesWhetherTwoFramesAreTheSameView() {
        var pool = SeriesPool()
        let a = [UInt8](repeating: 100, count: 576)
        var b = a
        for i in 0..<288 { b[i] = 200 }
        pool.add(item(1, time: 1, quality: 0, sharpness: 200, signature: a))
        pool.add(item(2, time: 2, quality: 0, sharpness: 300, signature: a))
        pool.add(item(3, time: 3, quality: 0, sharpness: 300, signature: b))
        XCTAssertEqual(pool.items.map { $0.jpeg.first }, [2, 3])
    }

    func testThePoolDropsTheWeakestFramesWhenItIsFull() {
        var pool = SeriesPool()
        pool.capacity = 3
        let pages: [[String]] = (0..<5).map { k in (0..<10).map { "word\(k)x\($0)" } }
        for (k, chars) in [100, 500, 50, 400, 300].enumerated() {
            pool.add(item(UInt8(k + 1), time: Double(k), quality: chars, words: pages[k]))
        }
        XCTAssertEqual(pool.items.count, 3)
        XCTAssertEqual(Set(pool.items.compactMap { $0.jpeg.first }), [2, 4, 5], "En yüksek puanlı üçü kalır")
    }

    func testTheFinalSelectionDropsVeryWeakFramesAndKeepsTimeOrder() {
        var pool = SeriesPool()
        let pages: [[String]] = (0..<4).map { k in (0..<10).map { "term\(k)y\($0)" } }
        pool.add(item(1, time: 1, quality: 400, words: pages[0]))
        pool.add(item(2, time: 2, quality: 30, words: pages[1]))    // en iyinin %15'inin altında
        pool.add(item(3, time: 3, quality: 200, words: pages[2]))
        pool.add(item(4, time: 4, quality: 100, words: pages[3]))
        let kept = pool.selected()
        XCTAssertEqual(kept.map { $0.jpeg.first }, [1, 3, 4])
        XCTAssertEqual(kept.map { $0.time }, kept.map { $0.time }.sorted())
        XCTAssertTrue(SeriesPool().selected().isEmpty)
    }

    // MARK: Toplayıcı

    private func buffer(id: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 8 + id, 4, kCVPixelFormatType_32BGRA, nil, &pb)
        return pb!
    }
    private func id(of buffer: CVPixelBuffer) -> Int { return CVPixelBufferGetWidth(buffer) - 8 }

    /// 3 sn'lik çekim: her pencerede üç kare (sonuncusu en net). 0–1 sn okunur (A sayfası), 1–2 sn bulanık, 2–3 sn okunur (B sayfası)
    private func feed(_ collector: SeriesCollector, from t0: Double) {
        var nextID = 0
        for window in 0..<6 {
            for k in 0..<3 {
                nextID += 1
                let time = t0 + Double(window) * 0.5 + 0.05 + Double(k) * 0.1
                collector.offer(buffer: buffer(id: nextID), time: time, sharpness: 100 + Double(k) * 50, signature: [UInt8](repeating: 100, count: 576))
            }
        }
    }

    private func reader(_ buffer: CVPixelBuffer) -> TextScore? {
        let n = id(of: buffer)
        let window = (n - 1) / 3
        var t = TextScore()
        t.confidence = 0.9
        switch window {
        case 0, 1: t.chars = 200; t.words = Set(pageA)
        case 2, 3: t.chars = 4
        default: t.chars = 220; t.words = Set(pageB)
        }
        return t
    }

    func testTheCollectorKeepsOneReadableFramePerViewAndDropsBlurryWindows() async {
        let t0 = 1000.0
        let collector = SeriesCollector(start: t0, maxPending: 1000, reader: { self.reader($0) },
                                        renderer: { buffer in (data: Data([UInt8(self.id(of: buffer))]), width: 1920, height: 1080) })
        feed(collector, from: t0)
        let outcome = await collector.finish()
        XCTAssertEqual(outcome.stats.offered, 18)
        XCTAssertEqual(outcome.stats.windows, 6)
        XCTAssertEqual(outcome.stats.unreadable, 2, "Bulanık iki pencere elendi")
        XCTAssertEqual(outcome.stats.kept, 4)
        XCTAssertEqual(outcome.stats.merged, 2, "A sayfasının iki penceresi ve B sayfasının iki penceresi birer görünümde birleşti")
        XCTAssertEqual(outcome.items.count, 2)
        // Her pencerenin en net karesi (üçüncüsü) aday olur: pencere 0 → kare 3, 1 → 6, 4 → 15, 5 → 18; eşit puanda aynı görünümün ilk adayı kalır
        XCTAssertEqual(outcome.items.map { $0.jpeg.first }, [3, 15].map { UInt8($0) })
    }

    func testWithoutTextRecognitionOnlySharpFramesAreUsed() async {
        let t0 = 2000.0
        let collector = SeriesCollector(start: t0, maxPending: 1000, reader: { _ in nil },
                                        renderer: { buffer in (data: Data([UInt8(self.id(of: buffer))]), width: 10, height: 10) })
        // 1. pencere: en net 150 (yeterli), 2. pencere: en net 60 (bulanık)
        collector.offer(buffer: buffer(id: 1), time: t0 + 0.1, sharpness: 150, signature: [UInt8](repeating: 10, count: 576))
        collector.offer(buffer: buffer(id: 2), time: t0 + 0.6, sharpness: 60, signature: [UInt8](repeating: 200, count: 576))
        let outcome = await collector.finish()
        XCTAssertEqual(outcome.stats.readFailed, 2)
        XCTAssertEqual(outcome.stats.unreadable, 1)
        XCTAssertEqual(outcome.items.map { $0.jpeg.first }, [1])
    }

    func testAnEmptyOrAllBlurrySessionYieldsNoFrames() async {
        let t0 = 3000.0
        let collector = SeriesCollector(start: t0, maxPending: 1000, reader: { _ in TextScore() },
                                        renderer: { _ in (data: Data([1]), width: 10, height: 10) })
        for k in 0..<10 {
            collector.offer(buffer: buffer(id: k), time: t0 + Double(k) * 0.2, sharpness: 400, signature: [UInt8](repeating: 100, count: 576))
        }
        let outcome = await collector.finish()
        XCTAssertTrue(outcome.items.isEmpty, "Keskin ama yazısız (ör. boş kâğıt, yer) kareler alınmaz")
        XCTAssertEqual(outcome.stats.offered, 10)
        XCTAssertEqual(outcome.stats.kept, 0)
    }

    func testFramesAfterFinishAreIgnored() async {
        let t0 = 4000.0
        let collector = SeriesCollector(start: t0, maxPending: 1000, reader: { _ in nil }, renderer: { _ in (data: Data([1]), width: 10, height: 10) })
        let outcome = await collector.finish()
        XCTAssertEqual(outcome.stats.offered, 0)
        collector.offer(buffer: buffer(id: 1), time: t0 + 0.1, sharpness: 500, signature: [UInt8](repeating: 1, count: 576))
        let again = await collector.finish()
        XCTAssertEqual(again.stats.offered, 0)
        XCTAssertTrue(again.items.isEmpty)
    }

    // MARK: Konuşma ve hata

    func testSpokenTextsAndMessages() {
        XCTAssertTrue(Say.seriesDone(taken: 18, planned: 18).contains("18 net görüntü"))
        XCTAssertTrue(Say.seriesDone(taken: 12, planned: 75).contains("yarıda kesildi"))
        XCTAssertFalse(Say.seriesDone(taken: 18, planned: 18).contains("sayfalık"))
        XCTAssertFalse(CameraFailure.unreadable.message.isEmpty)
        XCTAssertNotEqual(CameraFailure.unreadable, CameraFailure.noFrames)
        XCTAssertTrue(Say.seriesUnreadable.contains("Gemini'ye gönderilmedi"))
    }
}
