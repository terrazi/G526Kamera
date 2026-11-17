import XCTest
import CoreVideo
@testable import G526CameraDrive

/// Bozuk (bloklaşmış, önceki sahneyle karışmış) kare: kullanıcının PDF'inde (2026-11-17) 60 sayfanın 10'u bozuktu ve bozuk kareler bloklardaki keskin
/// kenarlar yüzünden en "net" ölçülenlerdi, yani seçimde öne geçiyorlardı. Bozuk kare artık tanınır ve sağlam kareyle yarışamaz.
final class DamagedFrameTests: XCTestCase {
    // MARK: Yardımcılar

    /// Deterministik sahte gürültü (testler her çalışmada aynı sonucu versin)
    private struct Noise {
        var state: UInt32 = 12345
        mutating func next(_ range: Int) -> Int {
            state = state &* 1664525 &+ 1013904223
            return Int((state >> 16) % UInt32(range))
        }
    }

    /// Sağlam görüntü: eğik parlaklık + hafif gürültü (blok yapısı yok)
    private func cleanLuma(width: Int, height: Int) -> [UInt8] {
        var noise = Noise()
        var px = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                px[y * width + x] = UInt8(60 + (x + y) / 8 + noise.next(17))
            }
        }
        return px
    }

    /// Her 16×16 bloğu kendi düz değerine boyar (bozuk akışın çıktısı gibi), üstüne çok hafif gürültü; yalnız `fromRow` satırından aşağısı
    private func blocky(_ base: [UInt8], width: Int, height: Int, fromRow: Int = 0) -> [UInt8] {
        var noise = Noise(state: 777)
        var px = base
        var levels: [Int: Int] = [:]
        for y in fromRow..<height {
            for x in 0..<width {
                let key = (y / 16) * 1000 + (x / 16)
                if levels[key] == nil { levels[key] = 40 + noise.next(180) }
                px[y * width + x] = UInt8(levels[key]! + noise.next(2))
            }
        }
        return px
    }

    private func score(_ px: [UInt8], width: Int, height: Int, skipTop: Int = 0) -> Double {
        return px.withUnsafeBufferPointer { FrameAnalysis.blockiness(luma: $0.baseAddress!, width: width, height: height, stride: width, skipTop: skipTop) }
    }

    // MARK: Ölçüt

    func testACleanImageIsNotDamaged() {
        let value = score(cleanLuma(width: 640, height: 368), width: 640, height: 368)
        XCTAssertEqual(value, 1.0, accuracy: 0.1)
        XCTAssertLessThan(value, FrameAnalysis.damagedBlockiness)
    }

    func testAFlatImageWithoutAnyEdgeIsNotDamaged() {
        let flat = [UInt8](repeating: 128, count: 640 * 368)
        XCTAssertEqual(score(flat, width: 640, height: 368), 1.0, accuracy: 0.0001, "Kenar yok: oran 1, sağlam sayılır")
    }

    func testAFullyBlockyImageIsDamaged() {
        let clean = cleanLuma(width: 640, height: 368)
        let value = score(blocky(clean, width: 640, height: 368), width: 640, height: 368)
        XCTAssertGreaterThan(value, FrameAnalysis.damagedBlockiness)
        XCTAssertGreaterThan(value, 3, "Düz renkli 16'lık bloklar: sınırlarda çok güçlü kenar")
    }

    /// Gerçek bozulmada genellikle görüntünün yalnız bir kısmı bloklaşır (PDF'teki 8, 24, 55: alt yarı ve kenarlar)
    func testAPartlyBlockyImageIsStillDamaged() {
        let clean = cleanLuma(width: 640, height: 368)
        let partly = blocky(clean, width: 640, height: 368, fromRow: 240)
        XCTAssertGreaterThan(score(partly, width: 640, height: 368), FrameAnalysis.damagedBlockiness)
    }

    /// Kameranın saat yazısı üstte durur; üstteki `skipTop` satır ölçülmez
    func testTheTopRowsAreNotMeasured() {
        let clean = cleanLuma(width: 640, height: 368)
        let damagedTop = blocky(clean, width: 640, height: 368, fromRow: 0)
        // Altı sağlam, üst 128 satır bloklu olan görüntü: üst satırlar atlanınca sağlam çıkar
        var mixed = clean
        for y in 0..<128 { for x in 0..<640 { mixed[y * 640 + x] = damagedTop[y * 640 + x] } }
        XCTAssertGreaterThan(score(mixed, width: 640, height: 368, skipTop: 0), FrameAnalysis.damagedBlockiness)
        XCTAssertLessThan(score(mixed, width: 640, height: 368, skipTop: 128), FrameAnalysis.damagedBlockiness)
    }

    /// Tamponun satır başlığı (stride) genişlikten büyük olabilir: ölçüm satır uzunluğuna değil stride'a göre yürür
    func testThePixelBufferPathHonoursRowPadding() {
        func makeBuffer(damaged: Bool) -> CVPixelBuffer {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 330, 200, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &pb)
            let buffer = pb!
            let clean = cleanLuma(width: 330, height: 200)
            let source = damaged ? blocky(clean, width: 330, height: 200) : clean
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            for y in 0..<200 { for x in 0..<330 { base[y * stride + x] = source[y * 330 + x] } }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            return buffer
        }
        XCTAssertLessThan(FrameAnalysis.blockiness(makeBuffer(damaged: false)), FrameAnalysis.damagedBlockiness)
        XCTAssertGreaterThan(FrameAnalysis.blockiness(makeBuffer(damaged: true)), FrameAnalysis.damagedBlockiness)
    }

    func testAStoredDamagedFrameLosesToAnyHealthyOneWhateverItsSharpness() {
        let buffer = makeSmallBuffer()
        let healthy = StoredFrame(id: 1, time: 0, buffer: buffer, sharpness: 120, signature: [])
        let damaged = StoredFrame(id: 2, time: 0, buffer: buffer, sharpness: 5000, signature: [], damaged: true)
        XCTAssertGreaterThan(healthy.pickScore, damaged.pickScore)
        XCTAssertEqual([damaged, healthy].max(by: { $0.pickScore < $1.pickScore })?.id, 1)
        // Hepsi bozuksa yine en iyisi seçilir (çekim boş kalmaz)
        let worse = StoredFrame(id: 3, time: 0, buffer: buffer, sharpness: 80, signature: [], damaged: true)
        XCTAssertEqual([worse, damaged].max(by: { $0.pickScore < $1.pickScore })?.id, 2)
    }

    private func makeSmallBuffer() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 8, 4, kCVPixelFormatType_32BGRA, nil, &pb)
        return pb!
    }

    // MARK: Havuz

    private let pageA = ["irrigate", "crops", "african", "farmers", "invented", "elaborate", "systems", "transport", "water", "fields"]

    private func item(_ id: UInt8, time: Double, chars: Int = 300, words: [String], damaged: Bool = false, sharpness: Double = 100) -> SeriesItem {
        var t = TextScore()
        t.chars = chars
        t.confidence = 1
        t.words = Set(words)
        return SeriesItem(time: time, jpeg: Data([id]), width: 1920, height: 1080, sharpness: sharpness, text: t,
                          signature: [UInt8](repeating: 100, count: 576), damaged: damaged)
    }

    func testADamagedFrameIsNeverUsefulEvenWhenItsTextIsReadable() {
        XCTAssertTrue(item(1, time: 1, words: pageA).isUseful)
        XCTAssertFalse(item(1, time: 1, words: pageA, damaged: true).isUseful)
    }

    func testTheHealthyFrameOfTheSameViewReplacesTheDamagedOneInThePool() {
        var pool = SeriesPool()
        pool.add(item(1, time: 1, words: pageA, damaged: true, sharpness: 3000))
        pool.add(item(2, time: 2, words: pageA, sharpness: 100))
        XCTAssertEqual(pool.items.map { $0.jpeg.first }, [2], "Sağlam kare, bozuk karenin yerini alır")
    }

    func testADamagedFrameOfAViewWeAlreadyHaveHealthyIsDropped() {
        var pool = SeriesPool()
        pool.add(item(1, time: 1, words: pageA, sharpness: 100))
        pool.add(item(2, time: 2, words: pageA, damaged: true, sharpness: 3000))
        XCTAssertEqual(pool.items.map { $0.jpeg.first }, [1])
    }

    func testDamagedFramesOnlyFillUpTheMinimumAfterTheHealthyWeakOnes() {
        var pool = SeriesPool()
        let pageB = ["concern", "increases", "worldwide", "information", "covid", "yourself", "social", "media", "messaging", "apps"]
        let pageC = ["hurricane", "begins", "circle", "counterclockwise", "equator", "flooding", "damaging", "surge", "earthquake", "seismic"]
        pool.add(item(1, time: 1, words: pageA))                                              // sağlam, okunur
        pool.add(item(2, time: 2, chars: 5, words: pageB, damaged: true, sharpness: 4000))    // bozuk
        var weak = item(3, time: 3, chars: 5, words: pageC, sharpness: 30)                    // sağlam ama okunamayan
        weak.text?.words = Set(pageC)
        pool.add(weak)
        XCTAssertEqual(pool.selected(minPages: 1).map { $0.jpeg.first }, [1], "Yeterli sağlam kare var: bozuk gitmez")
        XCTAssertEqual(pool.selected(minPages: 2).map { $0.jpeg.first }, [1, 3], "Tamamlarken sağlam zayıf kare bozuktan önce gelir")
        XCTAssertEqual(pool.selected(minPages: 3).map { $0.jpeg.first }, [1, 2, 3], "Sağlam kare yetmezse bozuk da tamamlar: çekim boş kalmaz")
    }

    // MARK: Toplayıcı

    private func buffer(id: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 8 + id, 4, kCVPixelFormatType_32BGRA, nil, &pb)
        return pb!
    }
    private func id(of buffer: CVPixelBuffer) -> Int { return CVPixelBufferGetWidth(buffer) - 8 }
    private func signature(_ level: Int) -> [UInt8] { return [UInt8](repeating: UInt8(level), count: 576) }

    /// Bir pencerede hem sağlam hem bozuk kare varsa, bozuk kare ne kadar "net" ölçülürse ölçülsün sağlam olan kazanır
    func testAHealthyFrameWinsTheWindowOverASharperMeasuringDamagedOne() async {
        let t0 = 5000.0
        let collector = SeriesCollector(start: t0, maxPending: 1000, minPages: 0,
                                        reader: { _ in var t = TextScore(); t.chars = 300; t.confidence = 0.9; t.words = Set(self.pageA); return t },
                                        renderer: { buffer in (data: Data([UInt8(self.id(of: buffer))]), width: 10, height: 10) })
        collector.offer(buffer: buffer(id: 1), time: t0 + 0.1, sharpness: 200, signature: signature(100), blockiness: 1.05)
        collector.offer(buffer: buffer(id: 2), time: t0 + 0.2, sharpness: 3000, signature: signature(100), blockiness: 1.6)
        collector.offer(buffer: buffer(id: 3), time: t0 + 0.3, sharpness: 150, signature: signature(100), blockiness: 1.02)
        let outcome = await collector.finish()
        XCTAssertEqual(outcome.items.map { $0.jpeg.first }, [1], "Sağlam kareler arasında en net olanı")
        XCTAssertEqual(outcome.stats.damagedFrames, 1)
        XCTAssertEqual(outcome.stats.damagedWindows, 0)
        XCTAssertEqual(outcome.readable, 1)
    }

    /// Penceredeki bütün kareler bozuksa pencere "tamamen bozuk" sayılır: PDF'e yalnız sağlam kare yetmezse girer; soru numaraları, netlik ve
    /// "okunan pencere" sayısı bozuk kareden alınmaz (karışık yazı teşhisi ve eksik soru raporunu yanıltmasın)
    func testAWindowOfOnlyDamagedFramesIsLeftOutAndDoesNotFeedTheDiagnosis() async {
        let t0 = 6000.0
        let reader: SeriesCollector.Reader = { buffer in
            var t = TextScore()
            t.chars = 300
            t.confidence = 0.9
            switch self.id(of: buffer) {
            case 1: t.words = Set(self.pageA); t.questionNumbers = [13]
            case 2: t.words = ["bogus", "ghost", "mixed", "words", "from", "two", "pages", "blended", "together", "here"]; t.questionNumbers = [99]
            default: t.words = ["hurricane", "begins", "circle", "counterclockwise", "equator", "flooding", "damaging", "surge", "earthquake", "seismic"]; t.questionNumbers = [15]
            }
            return t
        }
        func run(minPages: Int) async -> SeriesCollector.Outcome {
            let collector = SeriesCollector(start: t0, maxPending: 1000, minPages: minPages, reader: reader,
                                            renderer: { buffer in (data: Data([UInt8(self.id(of: buffer))]), width: 10, height: 10) })
            collector.offer(buffer: buffer(id: 1), time: t0 + 0.1, sharpness: 200, signature: signature(20), blockiness: 1.03)
            collector.offer(buffer: buffer(id: 2), time: t0 + 0.6, sharpness: 2500, signature: signature(120), blockiness: 1.7)
            collector.offer(buffer: buffer(id: 3), time: t0 + 1.1, sharpness: 180, signature: signature(220), blockiness: 1.04)
            return await collector.finish()
        }
        let strict = await run(minPages: 0)
        XCTAssertEqual(strict.items.map { $0.jpeg.first }, [1, 3], "Bozuk pencere PDF'e girmez")
        XCTAssertEqual(strict.stats.damagedWindows, 1)
        XCTAssertEqual(strict.stats.readable, 2, "Bozuk pencere okunan sayılmaz")
        XCTAssertEqual(strict.questionNumbers, [13, 15], "Bozuk karedeki karışık numara (99) görülen numaralara katılmaz")
        XCTAssertEqual(strict.diagnosis.damagedWindows, 1)
        XCTAssertEqual(strict.readable, 2)

        let filled = await run(minPages: 3)
        XCTAssertEqual(filled.items.map { $0.jpeg.first }, [1, 2, 3], "Sağlam kare yetmezse bozuk da tamamlar: çekim boş kalmaz")
        XCTAssertEqual(filled.readable, 2, "Bozuk kare tamamlayıcı olarak gitse de okunan sayılmaz")
    }

    func testTheDamageReportLineIsInTheTrialReport() {
        var diagnosis = CaptureDiagnosis(windows: 10, readableWindows: 8, medianSharpness: 300, questionNumbers: [1, 2], damagedWindows: 3)
        XCTAssertTrue(diagnosis.report(seconds: 75, measured: 600, selected: 20, readable: 18).contains("Bozuk (bloklaşmış) pencere: 3"))
        diagnosis.damagedWindows = 0
        XCTAssertTrue(diagnosis.report(seconds: 75, measured: 600, selected: 20, readable: 18).contains("Bozuk (bloklaşmış) pencere: 0"))
    }
}
