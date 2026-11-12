import XCTest
@testable import G526CameraDrive

/// Donma/aşırı yük önlemlerinin saf mantığı
final class FreezeGuardTests: XCTestCase {
    // MARK: Boş yer

    func testDiskLevels() {
        XCTAssertEqual(DiskGuard.level(freeMB: 5000), .ok)
        XCTAssertEqual(DiskGuard.level(freeMB: DiskGuard.lowMB), .ok, "eşik değerinin kendisi sorun değil")
        XCTAssertEqual(DiskGuard.level(freeMB: DiskGuard.lowMB - 1), .low)
        XCTAssertEqual(DiskGuard.level(freeMB: DiskGuard.criticalMB), .low)
        XCTAssertEqual(DiskGuard.level(freeMB: DiskGuard.criticalMB - 1), .critical)
        XCTAssertEqual(DiskGuard.level(freeMB: 0), .critical)
    }

    func testDiskUnknownIsNotAProblem() {
        XCTAssertEqual(DiskGuard.level(freeMB: -1), .ok)
        XCTAssertEqual(DiskGuard.notice(freeMB: -1), "")
    }

    func testDiskNoticeTextsMentionTheAmountAndTheAction() {
        XCTAssertEqual(DiskGuard.notice(freeMB: 3000), "")
        XCTAssertTrue(DiskGuard.notice(freeMB: 900).contains("900 MB"))
        let critical = DiskGuard.notice(freeMB: 100)
        XCTAssertTrue(critical.contains("100 MB") && critical.contains("video"), critical)
    }

    // MARK: Bellek

    func testMemoryCriticalThresholdIsAboveTrimThreshold() {
        XCTAssertGreaterThan(LoadGuard.memoryCriticalMB, LoadGuard.memoryTrimMB)
        XCTAssertFalse(LoadGuard.memoryCritical(LoadGuard.memoryCriticalMB - 1))
        XCTAssertTrue(LoadGuard.memoryCritical(LoadGuard.memoryCriticalMB))
        XCTAssertFalse(LoadGuard.memoryCritical(-1), "ölçülemedi sorun sayılmaz")
    }

    // MARK: Donma raporu

    func testHangTextIncludesLastActivity() {
        XCTAssertEqual(HealthMath.hangText(ms: 4200, activity: "klasöre kaydediliyor (3 sayfa)"),
                       "ekran 4,2 sn donuk kaldı (son işlem: klasöre kaydediliyor (3 sayfa))")
        XCTAssertEqual(HealthMath.hangText(ms: 3000, activity: ""), "ekran 3,0 sn donuk kaldı")
    }

    func testMonitorReportListsEvents() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("saglik-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let monitor = HealthMonitor(directory: dir)
        monitor.mark("deneme işlemi")
        monitor.event("ayrı olay")
        let report = monitor.report()          // q.sync: önceki event'in işlenmesini de bekler
        XCTAssertTrue(report.contains("ayrı olay"), report)
    }

    // MARK: Hafif mod

    func testSafeModeStartsOnlyAfterRepeatedUncleanExits() {
        XCTAssertFalse(HealthMath.needsSafeMode(uncleanStreak: 0))
        XCTAssertFalse(HealthMath.needsSafeMode(uncleanStreak: 1), "tek kapanış (ör. kullanıcı kapattı) hafif mod açmaz")
        XCTAssertTrue(HealthMath.needsSafeMode(uncleanStreak: 2))
        XCTAssertTrue(HealthMath.needsSafeMode(uncleanStreak: 5))
    }

    // MARK: Ses yeniden başlatma fırtınası

    func testRestartStreakCountsConsecutiveRestartsAndResetsAfterHealthyGap() {
        var s = RestartStreak()
        XCTAssertEqual(s.note(now: 0), 1)
        XCTAssertEqual(s.note(now: 1), 2)
        XCTAssertEqual(s.note(now: 31), 3, "30 sn aralık sorun sürüyor demek")
        XCTAssertEqual(s.note(now: 31 + RestartStreak.healthyGap + 1), 1, "uzun sessizlik sonrası yeniden başlar")
    }

    func testRestartDelayStaysHighWhileProblemPersists() {
        var s = RestartStreak()
        var delays: [TimeInterval] = []
        var now: TimeInterval = 0
        for _ in 0..<30 {
            let n = s.note(now: now)
            let d = SpeechTrigger.restartDelay(base: 0.4, recentRestarts: n)
            delays.append(d)
            now += d + 1                     // her yeniden başlatma bir öncekinden bekleme + 1 sn sonra
        }
        XCTAssertEqual(delays.last ?? 0, 30, accuracy: 0.001, "sorun sürerken bekleme üst sınıra çıkar ve orada kalır")
        XCTAssertLessThan(delays.first ?? 99, 1)
    }
}
