import XCTest
@testable import G526CameraDrive

final class HealthTests: XCTestCase {
    private func sample(_ t: Double, thermal: Int = 0, mem: Int = 300, stall: Int = 0, battery: Int = 80, low: Bool = false) -> HealthSample {
        return HealthSample(time: t, thermal: thermal, memoryMB: mem, stallMs: stall, battery: battery, lowPower: low)
    }

    func testThermalNamesAndLevels() {
        XCTAssertEqual(HealthMath.thermalLevel(.nominal), 0)
        XCTAssertEqual(HealthMath.thermalLevel(.fair), 1)
        XCTAssertEqual(HealthMath.thermalLevel(.serious), 2)
        XCTAssertEqual(HealthMath.thermalLevel(.critical), 3)
        XCTAssertEqual(HealthMath.thermalName(0), "normal")
        XCTAssertEqual(HealthMath.thermalName(2), "ciddi ısınmış")
    }

    func testSummaryReportsPeaksAndStalls() {
        var store = HealthStore()
        store.samples = [sample(1000), sample(1010, thermal: 2, mem: 640, stall: 2400), sample(1020, thermal: 1, mem: 500, stall: 200, battery: 64, low: true)]
        store.events = [HealthEvent(time: 1010, text: "bellek uyarısı")]
        let text = HealthMath.summary(store, previous: nil, previousUnclean: false)
        XCTAssertTrue(text.contains("3 örnek"), text)
        XCTAssertTrue(text.contains("şu an hafif ısınmış; en yüksek ciddi ısınmış"), text)
        XCTAssertTrue(text.contains("şu an 500 MB; en yüksek 640 MB"), text)
        XCTAssertTrue(text.contains("1 aralıkta; en uzunu 2.4 sn"), text)
        XCTAssertTrue(text.contains("Pil: %64 (düşük güç modu açık)"), text)
        XCTAssertTrue(text.contains("bellek uyarısı"), text)
        XCTAssertFalse(text.contains("beklenmedik"), text)
    }

    func testSummaryWithoutSamplesSaysSo() {
        let text = HealthMath.summary(HealthStore(), previous: nil, previousUnclean: false)
        XCTAssertTrue(text.contains("henüz örnek yok"), text)
    }

    func testSummaryShowsPreviousUncleanExit() {
        var old = HealthStore()
        old.samples = [sample(500, thermal: 2, mem: 980, stall: 3000)]
        let text = HealthMath.summary(HealthStore(), previous: old, previousUnclean: true)
        XCTAssertTrue(text.contains("Önceki kullanım beklenmedik kapanmış"), text)
        XCTAssertTrue(text.contains("ısı ciddi ısınmış, bellek 980 MB, takılma 3.0 sn"), text)
    }

    func testStallTrackerCountsOnlyTheLastMinute() {
        var t = StallTracker()
        t.record(at: 0)
        t.record(at: 30)
        t.record(at: 50)
        XCTAssertEqual(t.count(now: 55), 3)
        XCTAssertEqual(t.count(now: 70), 2, "ilk takılma 60 saniyeyi geçti")
        XCTAssertEqual(t.count(now: 200), 0)
    }

    func testLoadGuardDecisions() {
        XCTAssertFalse(LoadGuard.shedForStalls(count: 2))
        XCTAssertTrue(LoadGuard.shedForStalls(count: 3))
        XCTAssertFalse(LoadGuard.shouldTrimMemory(memoryMB: 900, sinceLastTrim: 100))
        XCTAssertTrue(LoadGuard.shouldTrimMemory(memoryMB: 1200, sinceLastTrim: 100))
        XCTAssertFalse(LoadGuard.shouldTrimMemory(memoryMB: 1200, sinceLastTrim: 5), "30 saniye dolmadan yeniden boşaltılmaz")
    }

    func testFootprintIsMeasurable() {
        XCTAssertGreaterThan(HealthMonitor.footprintMB(), 0)
    }

    func testStoreSurvivesEncodeDecode() throws {
        var store = HealthStore()
        store.samples = [sample(1), sample(2, thermal: 3)]
        store.events = [HealthEvent(time: 2, text: "x")]
        let data = try JSONEncoder().encode(store)
        XCTAssertEqual(try JSONDecoder().decode(HealthStore.self, from: data), store)
    }
}
