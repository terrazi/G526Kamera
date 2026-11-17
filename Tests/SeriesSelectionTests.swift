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

    /// Soru görünen kare: yazısı okunabilir ya da bir şık harfi / soru numarası görülmüş. Öteki kareler zayıftır.
    func testAFragmentWithAnOptionLetterCountsAsUsefulButAPlainWeakFrameDoesNot() {
        XCTAssertTrue(item(1, time: 1, quality: 4, words: [], options: "E").isUseful, "Yalnız E şıkkının göründüğü kare soruyu tamamlayabilir")
        XCTAssertTrue(item(2, time: 1, quality: 40, words: pageA).isUseful)
        XCTAssertFalse(item(3, time: 1, quality: 5, words: []).isUseful)
        XCTAssertFalse(item(4, time: 1, quality: 0).isUseful, "Yazı tanıma çalışmadıysa kare zayıftır")
        XCTAssertGreaterThan(item(1, time: 1, quality: 40, words: pageA, sharpness: 10).rank, item(4, time: 1, quality: 0, sharpness: 400).rank,
                             "Yararlı kare, ne kadar net olursa olsun zayıf kareden önce gelir")
    }

    /// Yazı tanıma azı okuduysa Gemini'nin göreceği kare yine de olsun: eksik sayfa en net zayıf karelerle tamamlanır, okunanların yerini almaz
    func testWeakFramesOnlyFillTheMissingPagesAndTheSharpestComeFirst() {
        var pool = SeriesPool()
        pool.add(item(1, time: 1, quality: 300, words: pageA, options: "ABCDE"))
        for k in 0..<4 {
            pool.add(item(UInt8(10 + k), time: Double(2 + k), quality: 5, words: [], sharpness: [100, 400, 200, 300][k],
                          signature: [UInt8](repeating: UInt8(30 + 60 * k), count: 576)))
        }
        XCTAssertEqual(pool.selected(minPages: 3).map { $0.jpeg.first }, [1, 11, 13], "Okunan kare + en net iki zayıf kare, zaman sırasıyla")
        XCTAssertEqual(pool.selected(minPages: 1).map { $0.jpeg.first }, [1], "Okunan kare yeterliyse zayıf kare eklenmez")
        XCTAssertEqual(pool.selected(minPages: 0).map { $0.jpeg.first }, [1])
        XCTAssertEqual(pool.selected(minPages: 99).count, 5, "Yer varsa hepsi")
    }

    func testWhenNothingIsReadableTheSharpestFramesAreStillChosen() {
        var pool = SeriesPool()
        for k in 0..<6 {
            pool.add(item(UInt8(k + 1), time: Double(k), quality: 0, sharpness: [50, 400, 100, 300, 20, 200][k],
                          signature: [UInt8](repeating: UInt8(20 + 40 * k), count: 576)))
        }
        XCTAssertEqual(pool.selected(minPages: 3).map { $0.jpeg.first }, [2, 4, 6], "Hiç yazı okunmadıysa yalnız netliğe göre en iyi üçü")
    }

    func testWeakFramesNeverPushReadableOnesOutOfAFullPool() {
        var pool = SeriesPool()
        pool.capacity = 2
        pool.add(item(1, time: 1, quality: 30, words: pageA))                                                               // okunan ama düşük puanlı
        pool.add(item(2, time: 2, quality: 0, sharpness: 400, signature: [UInt8](repeating: 20, count: 576)))              // çok net ama okunmayan
        pool.add(item(3, time: 3, quality: 0, sharpness: 390, signature: [UInt8](repeating: 200, count: 576)))
        XCTAssertEqual(pool.items.map { $0.jpeg.first }, [1, 2], "Havuz dolunca önce zayıf kareler atılır; okunan kare kalır")
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

    func testTheCollectorKeepsOneReadableFramePerViewAndTheBlurryWindowsDoNotJoinWhenThereAreEnoughReadableOnes() async {
        let t0 = 1000.0
        let collector = SeriesCollector(start: t0, maxPending: 1000, minPages: 0, reader: { self.reader($0) },
                                        renderer: { buffer in (data: Data([UInt8(self.id(of: buffer))]), width: 1920, height: 1080) })
        feed(collector, from: t0)
        let outcome = await collector.finish()
        XCTAssertEqual(outcome.stats.offered, 18)
        XCTAssertEqual(outcome.stats.windows, 6)
        XCTAssertEqual(outcome.stats.weak, 2, "Bulanık iki pencerenin yazısı okunamadı: elenmez, zayıf aday olarak havuza girer")
        XCTAssertEqual(outcome.stats.kept, 6, "Her pencere aday olur; kesin eleme çekim bitince yapılır")
        XCTAssertEqual(outcome.stats.merged, 4, "A'nın iki penceresi, A'dan sonraki iki bulanık pencere (yeni bir şey göstermiyor) ve B'nin iki penceresi birleşti")
        XCTAssertEqual(outcome.items.count, 2)
        XCTAssertEqual(outcome.readable, 2)
        // Her pencerenin en net karesi (üçüncüsü) aday olur: pencere 0 → kare 3, 1 → 6, 4 → 15, 5 → 18; eşit puanda aynı görünümün ilk adayı kalır
        XCTAssertEqual(outcome.items.map { $0.jpeg.first }, [3, 15].map { UInt8($0) })
    }

    /// Yazı tanıma hiç çalışmasa da (ör. model yok) çekim boş gitmez: en net kareler alınır
    func testWithoutTextRecognitionTheSharpestFramesAreStillUsed() async {
        let t0 = 2000.0
        let collector = SeriesCollector(start: t0, maxPending: 1000, reader: { _ in nil },
                                        renderer: { buffer in (data: Data([UInt8(self.id(of: buffer))]), width: 10, height: 10) })
        collector.offer(buffer: buffer(id: 1), time: t0 + 0.1, sharpness: 150, signature: [UInt8](repeating: 10, count: 576))
        collector.offer(buffer: buffer(id: 2), time: t0 + 0.6, sharpness: 60, signature: [UInt8](repeating: 200, count: 576))
        let outcome = await collector.finish()
        XCTAssertEqual(outcome.stats.readFailed, 2)
        XCTAssertEqual(outcome.stats.weak, 2)
        XCTAssertEqual(outcome.items.map { $0.jpeg.first }, [1, 2], "Bulanık da olsa elenmez: Gemini kararı verir")
        XCTAssertEqual(outcome.readable, 0)
    }

    /// Kullanıcının bildirdiği hata: hiçbir karede yazı okunamayınca çekim tümüyle çöpe gidiyordu. Artık en net kareler seçilir
    func testASessionWithNothingReadableStillYieldsItsSharpestFramesInsteadOfNothing() async {
        let t0 = 3000.0
        let sharpness: [Double] = [50, 400, 100, 300, 20, 200]
        let collector = SeriesCollector(start: t0, maxPending: 1000, minPages: 3, reader: { _ in TextScore() },
                                        renderer: { buffer in (data: Data([UInt8(self.id(of: buffer))]), width: 10, height: 10) })
        for window in 0..<6 {
            collector.offer(buffer: buffer(id: window + 1), time: t0 + Double(window) * 0.5 + 0.1, sharpness: sharpness[window],
                            signature: [UInt8](repeating: UInt8(20 + 40 * window), count: 576))
        }
        let outcome = await collector.finish()
        XCTAssertEqual(outcome.stats.offered, 6)
        XCTAssertEqual(outcome.stats.weak, 6)
        XCTAssertEqual(outcome.stats.kept, 6)
        XCTAssertEqual(outcome.readable, 0, "Hiçbiri okunmadı: kullanıcıya söylenir")
        XCTAssertEqual(outcome.items.map { $0.jpeg.first }, [2, 4, 6], "En net üç pencere, zaman sırasıyla")
    }

    func testAFragmentThatShowsOnlyAnOptionLetterIsKeptEvenWhenTheRestOfTheFrameIsNotReadable() async {
        let t0 = 3500.0
        let collector = SeriesCollector(start: t0, maxPending: 1000, minPages: 0, reader: { buffer in
            var t = TextScore()
            t.confidence = 0.9
            if self.id(of: buffer) == 1 { t.chars = 300; t.words = Set(self.pageA) } else { t.chars = 4; t.options = ["E"] }
            return t
        }, renderer: { buffer in (data: Data([UInt8(self.id(of: buffer))]), width: 10, height: 10) })
        collector.offer(buffer: buffer(id: 1), time: t0 + 0.1, sharpness: 200, signature: [UInt8](repeating: 20, count: 576))
        collector.offer(buffer: buffer(id: 2), time: t0 + 0.6, sharpness: 200, signature: [UInt8](repeating: 200, count: 576))
        let outcome = await collector.finish()
        XCTAssertEqual(outcome.items.map { $0.jpeg.first }, [1, 2], "Soruyu tamamlayan E şıkkı görünen kare, az yazılı diye atılmaz")
        XCTAssertEqual(outcome.readable, 2)
    }

    /// Çekimin teşhisi (kullanıcı kararı 2026-11-17): yazı tanımadan geçen pencerelerin sayısı, okunanlar, netliğin ortancası ve görülen soru numaraları
    /// toplayıcıdan çıkar; hiçbir karede yazı okunmuyorsa ve görüntü bulanıksa "bulanık / çok yakın" denir
    func testTheDiagnosisOfASessionWithNoReadableTextAndABlurryViewSaysBlurry() async {
        let t0 = 5000.0
        let sharpness: [Double] = [20, 30, 25, 10, 40, 35]
        let collector = SeriesCollector(start: t0, maxPending: 1000, minPages: 3, reader: { _ in TextScore() },
                                        renderer: { buffer in (data: Data([UInt8(self.id(of: buffer))]), width: 10, height: 10) })
        for window in 0..<6 {
            collector.offer(buffer: buffer(id: window + 1), time: t0 + Double(window) * 0.5 + 0.1, sharpness: sharpness[window],
                            signature: [UInt8](repeating: UInt8(20 + 40 * window), count: 576))
        }
        let outcome = await collector.finish()
        XCTAssertEqual(outcome.diagnosis.windows, 6)
        XCTAssertEqual(outcome.diagnosis.readableWindows, 0)
        XCTAssertEqual(outcome.diagnosis.medianSharpness, 27.5, accuracy: 0.001)
        XCTAssertEqual(outcome.diagnosis.hint, .blurry)
        XCTAssertEqual(outcome.diagnosis.spoken, CaptureSay.blurry)
        XCTAssertEqual(outcome.stats.readable, 0)
    }

    func testTheDiagnosisCollectsTheSeenQuestionNumbersAndFindsTheSkippedOne() async {
        let t0 = 5500.0
        let numbers: [Int: Int] = [1: 11, 2: 12, 3: 14]
        let collector = SeriesCollector(start: t0, maxPending: 1000, minPages: 0, reader: { buffer in
            var t = TextScore()
            t.chars = SeriesSelection.minChars + 300
            t.confidence = 0.9
            t.questionNumbers = [numbers[self.id(of: buffer)] ?? 0]
            return t
        }, renderer: { buffer in (data: Data([UInt8(self.id(of: buffer))]), width: 10, height: 10) })
        for window in 0..<3 {
            collector.offer(buffer: buffer(id: window + 1), time: t0 + Double(window) * 0.5 + 0.1, sharpness: 300,
                            signature: [UInt8](repeating: UInt8(20 + 80 * window), count: 576))
        }
        let outcome = await collector.finish()
        XCTAssertEqual(outcome.diagnosis.questionNumbers, [11, 12, 14])
        XCTAssertEqual(outcome.diagnosis.missingNumbers, [13])
        XCTAssertEqual(outcome.diagnosis.hint, .good)
        XCTAssertEqual(outcome.diagnosis.spoken, CaptureSay.missingSeen([13]))
        XCTAssertEqual(outcome.stats.readable, 3)
        XCTAssertEqual(outcome.stats.weak, 0)
    }

    func testWithoutTextRecognitionNothingIsDiagnosed() async {
        let t0 = 5800.0
        let collector = SeriesCollector(start: t0, maxPending: 1000, minPages: 2, reader: { _ in nil },
                                        renderer: { buffer in (data: Data([UInt8(self.id(of: buffer))]), width: 10, height: 10) })
        collector.offer(buffer: buffer(id: 1), time: t0 + 0.1, sharpness: 5, signature: [UInt8](repeating: 20, count: 576))
        collector.offer(buffer: buffer(id: 2), time: t0 + 0.6, sharpness: 6, signature: [UInt8](repeating: 200, count: 576))
        let outcome = await collector.finish()
        XCTAssertEqual(outcome.diagnosis.windows, 0, "Yazı tanıma çalışmadı: karar verilemez")
        XCTAssertEqual(outcome.diagnosis.hint, .good)
        XCTAssertEqual(outcome.diagnosis.spoken, "")
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
        let weak = Say.seriesDone(taken: 16, planned: 16, readable: false)
        XCTAssertTrue(weak.contains("Yazı net okunamadı") && weak.contains("yine de Gemini'ye gönderiliyor"), weak)
        XCTAssertEqual(Say.seriesDone(taken: 16, planned: 16, readable: true), Say.seriesDone(taken: 16, planned: 16))
        XCTAssertTrue(Say.seriesDone(taken: 5, planned: 75, readable: false).contains("yarıda kesildi"), "Kesilme her zaman söylenir")
    }
}
