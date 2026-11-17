import XCTest
import CoreVideo
@testable import G526CameraDrive

/// Durgun an önceliği (kullanıcı kararı 2026-11-17): kamera en az `SeriesSelection.minStill` sn durgun kaldıktan sonra gelen kare, aynı penceredeki
/// hareketli kareden (daha "net" ölçülse bile) önce gelir; bozuk kare yine en sonda kalır.
final class StillMomentTests: XCTestCase {
    private let words = ["irrigate", "crops", "african", "farmers", "invented", "elaborate", "systems", "transport", "water", "fields"]

    private func buffer(id: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 8 + id, 4, kCVPixelFormatType_32BGRA, nil, &pb)
        return pb!
    }
    private func id(of buffer: CVPixelBuffer) -> Int { return CVPixelBufferGetWidth(buffer) - 8 }
    private func signature(_ level: Int) -> [UInt8] { return [UInt8](repeating: UInt8(level), count: 576) }

    private func collector(start: Double) -> SeriesCollector {
        return SeriesCollector(start: start, maxPending: 1000, minPages: 0,
                               reader: { _ in var t = TextScore(); t.chars = 300; t.confidence = 0.9; t.words = Set(self.words); return t },
                               renderer: { buffer in (data: Data([UInt8(self.id(of: buffer))]), width: 10, height: 10) })
    }

    func testAFrameIsStillOnlyAfterTheCameraHasStayedStillLongEnough() {
        let frame = { (stillFor: Double) in
            SeriesCollector.Frame(buffer: self.buffer(id: 1), time: 0, sharpness: 100, signature: [], blockiness: 1.0, stillFor: stillFor)
        }
        XCTAssertFalse(frame(0).still)
        XCTAssertFalse(frame(SeriesSelection.minStill - 0.05).still)
        XCTAssertTrue(frame(SeriesSelection.minStill + 0.05).still)
    }

    /// İlk kare hareketli ve çok net ölçülüyor; sonradan kamera durgunlaşınca gelen kare, daha az net olsa da pencereyi kazanır
    func testAFrameFromAStillMomentBeatsASharperMeasuringFrameTakenWhileTheCameraMoved() async {
        let t0 = 7000.0
        let c = collector(start: t0)
        let frames: [(Int, Double, Double)] = [(1, 0.05, 900), (2, 0.15, 100), (3, 0.25, 100), (4, 0.40, 120), (5, 0.45, 110)]
        for (id, offset, sharpness) in frames {
            c.offer(buffer: buffer(id: id), time: t0 + offset, sharpness: sharpness, signature: signature(100))
        }
        let outcome = await c.finish()
        XCTAssertEqual(outcome.items.map { $0.jpeg.first }, [4], "Durgun karelerin en netidir")
        XCTAssertEqual(outcome.stats.stillWindows, 1)
    }

    /// Kamera hiç durgunlaşmıyorsa (yavaş kaydırma) eskisi gibi en net kare kazanır
    func testWhenTheCameraNeverStaysStillTheSharpestFrameWins() async {
        let t0 = 7100.0
        let c = collector(start: t0)
        let frames: [(Int, Double, Double, Int)] = [(1, 0.05, 100, 10), (2, 0.15, 300, 200), (3, 0.25, 200, 10), (4, 0.35, 150, 200)]
        for (id, offset, sharpness, level) in frames {
            c.offer(buffer: buffer(id: id), time: t0 + offset, sharpness: sharpness, signature: signature(level))
        }
        let outcome = await c.finish()
        XCTAssertEqual(outcome.items.map { $0.jpeg.first }, [2])
        XCTAssertEqual(outcome.stats.stillWindows, 0)
    }

    /// Durgun ama bozuk kare, hareketli ama sağlam kareyi geçemez
    func testAStillButDamagedFrameStillLosesToAMovingHealthyOne() async {
        let t0 = 7200.0
        let c = collector(start: t0)
        c.offer(buffer: buffer(id: 1), time: t0 + 0.05, sharpness: 100, signature: signature(100), blockiness: 1.02)
        c.offer(buffer: buffer(id: 2), time: t0 + 0.40, sharpness: 3000, signature: signature(100), blockiness: 1.6)
        let outcome = await c.finish()
        XCTAssertEqual(outcome.items.map { $0.jpeg.first }, [1])
        XCTAssertEqual(outcome.stats.stillWindows, 0, "Kazanan hareketli kareydi")
    }

    /// Her pencerede durgun an aranır: pencere sınırında sayaç sıfırlanmaz (durgunluk pencereler arası sürer)
    func testStillnessCarriesOverFromOneWindowToTheNext() async {
        let t0 = 7300.0
        let c = collector(start: t0)
        // 0. pencere: tek kare (hareketli); 1. pencere: kamera hâlâ durgun, ilk karesinden itibaren durgun an sayılır
        c.offer(buffer: buffer(id: 1), time: t0 + 0.05, sharpness: 100, signature: signature(100))
        c.offer(buffer: buffer(id: 2), time: t0 + 0.55, sharpness: 100, signature: signature(100))
        c.offer(buffer: buffer(id: 3), time: t0 + 0.60, sharpness: 140, signature: signature(100))
        let outcome = await c.finish()
        XCTAssertEqual(outcome.stats.windows, 2)
        XCTAssertEqual(outcome.stats.stillWindows, 1, "İkinci pencerenin kazananı durgun an karesi")
    }
}
