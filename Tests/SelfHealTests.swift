import XCTest
@testable import G526CameraDrive

final class SelfHealTests: XCTestCase {
    // MARK: İnternet

    func testWarnsOnlyAfterConsecutiveFailuresAndOnlyOnce() {
        var t = OfflineTracker()
        XCTAssertEqual(t.record(online: false, now: 0, canRepair: false), .none, "tek başarısızlık uyarı değil")
        XCTAssertEqual(t.record(online: false, now: 45, canRepair: false), .warn)
        XCTAssertEqual(t.record(online: false, now: 90, canRepair: false), .none, "aynı kesintide ikinci uyarı yok")
        XCTAssertEqual(t.record(online: false, now: 135, canRepair: false), .none)
    }

    func testSingleBlipDoesNotWarn() {
        var t = OfflineTracker()
        XCTAssertEqual(t.record(online: false, now: 0, canRepair: true), .none)
        XCTAssertEqual(t.record(online: true, now: 45, canRepair: true), .none, "uyarılmadıysa 'geri geldi' denmez")
        XCTAssertEqual(t.record(online: false, now: 90, canRepair: true), .none, "sayaç sıfırlanmış olmalı")
    }

    func testRecoveryIsReportedOnceAfterWarning() {
        var t = OfflineTracker()
        _ = t.record(online: false, now: 0, canRepair: false)
        XCTAssertEqual(t.record(online: false, now: 45, canRepair: false), .warn)
        XCTAssertEqual(t.record(online: true, now: 90, canRepair: false), .recovered)
        XCTAssertEqual(t.record(online: true, now: 135, canRepair: false), .none)
    }

    func testRepairRespectsCooldownAndLimit() {
        var t = OfflineTracker()
        _ = t.record(online: false, now: 0, canRepair: true)
        XCTAssertEqual(t.record(online: false, now: 45, canRepair: true), .repair)
        XCTAssertEqual(t.record(online: false, now: 90, canRepair: true), .none, "10 dk dolmadan yeniden denenmez")
        XCTAssertEqual(t.record(online: false, now: 700, canRepair: true), .repair)
        XCTAssertEqual(t.record(online: false, now: 1400, canRepair: true), .repair)
        XCTAssertEqual(t.record(online: false, now: 2100, canRepair: true), .none, "en çok 3 deneme")
        XCTAssertEqual(t.repairs, 3)
        // internet gelince sayaçlar sıfırlanır, yeni kesintide yine denenir
        XCTAssertEqual(t.record(online: true, now: 2200, canRepair: true), .recovered)
        _ = t.record(online: false, now: 2300, canRepair: true)
        XCTAssertEqual(t.record(online: false, now: 2345, canRepair: true), .repair)
    }

    func testNoRepairWhenShortcutNotAllowed() {
        var t = OfflineTracker()
        _ = t.record(online: false, now: 0, canRepair: false)
        XCTAssertEqual(t.record(online: false, now: 45, canRepair: false), .warn)
        XCTAssertEqual(t.repairs, 0)
    }

    func testWarnThenRepairWhenShortcutGetsEnabled() {
        var t = OfflineTracker()
        _ = t.record(online: false, now: 0, canRepair: false)
        XCTAssertEqual(t.record(online: false, now: 45, canRepair: false), .warn)
        XCTAssertEqual(t.record(online: false, now: 90, canRepair: true), .repair)
    }

    // MARK: Ses sağlığı

    func testAudioHealthOkWhileBuffersAndSignalFlow() {
        XCTAssertEqual(AudioHealth.evaluate(now: 100, engineRunning: true, startedAt: 0, lastBuffer: 99.9, lastSignal: 99), .ok)
    }

    func testAudioHealthNoBuffers() {
        XCTAssertEqual(AudioHealth.evaluate(now: 100, engineRunning: true, startedAt: 0, lastBuffer: 80, lastSignal: 80), .noBuffers)
        XCTAssertEqual(AudioHealth.evaluate(now: 20, engineRunning: true, startedAt: 5, lastBuffer: nil, lastSignal: nil), .noBuffers)
        XCTAssertEqual(AudioHealth.evaluate(now: 10, engineRunning: true, startedAt: 5, lastBuffer: nil, lastSignal: nil), .ok,
                       "motor yeni başladıysa tampon beklenir")
    }

    func testAudioHealthSilentMic() {
        XCTAssertEqual(AudioHealth.evaluate(now: 200, engineRunning: true, startedAt: 0, lastBuffer: 199.9, lastSignal: nil), .silent)
        XCTAssertEqual(AudioHealth.evaluate(now: 200, engineRunning: true, startedAt: 0, lastBuffer: 199.9, lastSignal: 150), .ok)
        XCTAssertEqual(AudioHealth.evaluate(now: 200, engineRunning: true, startedAt: 0, lastBuffer: 199.9, lastSignal: 100), .silent)
    }

    func testAudioHealthIgnoresStoppedEngine() {
        XCTAssertEqual(AudioHealth.evaluate(now: 500, engineRunning: false, startedAt: 0, lastBuffer: nil, lastSignal: nil), .ok)
    }

    func testPeakOfSamples() {
        var samples: [Float] = [0, 0.001, -0.5, 0.2]
        let peak = samples.withUnsafeMutableBufferPointer { AudioHealth.peak(of: $0.baseAddress!, count: $0.count) }
        XCTAssertEqual(peak, 0.5, accuracy: 0.0001)
        var zeros = [Float](repeating: 0, count: 16)
        let none = zeros.withUnsafeMutableBufferPointer { AudioHealth.peak(of: $0.baseAddress!, count: $0.count) }
        XCTAssertLessThan(none, AudioHealth.signalFloor)
    }

    // MARK: Kestirme bağlantısı

    func testShortcutURLEncodesNameAndReturns() throws {
        let url = try XCTUnwrap(ShortcutLink.url(name: "Hücresel Yenile"))
        let text = url.absoluteString
        XCTAssertTrue(text.hasPrefix("shortcuts://x-callback-url/run-shortcut?name="), text)
        XCTAssertTrue(text.contains("H%C3%BCcresel%20Yenile"), text)
        XCTAssertTrue(text.contains("x-success=g526kamera://kestirme"), text)
    }

    func testShortcutURLKeepsSpecialCharactersInsideTheName() throws {
        let url = try XCTUnwrap(ShortcutLink.url(name: "a&b=c"))
        XCTAssertTrue(url.absoluteString.contains("name=a%26b%3Dc&"), url.absoluteString)
    }

    func testShortcutURLNeedsAName() {
        XCTAssertNil(ShortcutLink.url(name: ""))
        XCTAssertNil(ShortcutLink.url(name: "   "))
    }

    // MARK: Kestirme adları ve sınırlayıcı

    func testSuspendKeepsRepairCountAndCooldownSoShortcutCannotLoopForever() {
        var t = OfflineTracker()
        var now: TimeInterval = 0
        func tick(_ n: Int) -> [OfflineTracker.Action] {
            var out: [OfflineTracker.Action] = []
            for _ in 0..<n { now += 45; out.append(t.record(online: false, now: now, canRepair: true)) }
            return out
        }
        XCTAssertTrue(tick(2).contains(.repair), "ilk kesintide kestirme çalışır")
        t.suspend()                       // kestirme çalışırken program arka plana geçti
        let after = tick(10)              // yaklaşık 7,5 dakika, bekleme süresi (10 dk) dolmadı
        XCTAssertFalse(after.contains(.repair), "bekleme süresi dolmadan yeniden çalışmamalı")
        XCTAssertTrue(after.contains(.warn), "uyarı yeniden söylenir")
    }

    func testRepairThrottleWaitsBetweenTriesAndStopsAfterMax() {
        var t = RepairThrottle(cooldown: 180, maxTries: 3)
        XCTAssertTrue(t.allow(now: 0))
        XCTAssertFalse(t.allow(now: 100), "bekleme süresi dolmadı")
        XCTAssertTrue(t.allow(now: 181))
        XCTAssertTrue(t.allow(now: 400))
        XCTAssertFalse(t.allow(now: 1000), "en çok 3 deneme")
    }

    func testRepairThrottleResetAllowsAgain() {
        var t = RepairThrottle(cooldown: 180, maxTries: 1)
        XCTAssertTrue(t.allow(now: 0))
        XCTAssertFalse(t.allow(now: 500))
        t.reset()
        XCTAssertTrue(t.allow(now: 501))
    }

    private func freshDefaults() -> UserDefaults {
        let name = "kestirme-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    func testConnectionShortcutNameStartsEmpty() {
        let d = freshDefaults()
        XCTAssertEqual(AppSettings.migratedConnectionShortcutName(d), "")
    }

    func testConnectionShortcutNameKeepsOldNameOnlyIfOldSwitchWasOn() {
        let on = freshDefaults()
        on.set(true, forKey: "cellularShortcutOn")
        on.set("Hücresel Yenile", forKey: "cellularShortcutName")
        XCTAssertEqual(AppSettings.migratedConnectionShortcutName(on), "Hücresel Yenile")
        XCTAssertEqual(on.string(forKey: "connectionShortcutName"), "Hücresel Yenile", "yeni anahtara yazılır")
        XCTAssertNil(on.object(forKey: "cellularShortcutOn"))
        XCTAssertEqual(AppSettings.migratedConnectionShortcutName(on), "Hücresel Yenile", "ikinci açılışta da kalır")

        let off = freshDefaults()
        off.set(false, forKey: "cellularShortcutOn")
        off.set("Hücresel Yenile", forKey: "cellularShortcutName")
        XCTAssertEqual(AppSettings.migratedConnectionShortcutName(off), "", "kapalıysa ad taşınmaz")
    }

    func testConnectionShortcutNameUserChoiceWins() {
        let d = freshDefaults()
        d.set("Benim Kestirmem", forKey: "connectionShortcutName")
        d.set(true, forKey: "cellularShortcutOn")
        XCTAssertEqual(AppSettings.migratedConnectionShortcutName(d), "Benim Kestirmem")
    }

    func testDefaultCameraUIDIsValid() {
        XCTAssertEqual(AppSettings.defaultCameraUID, "G526029XJPDT")
        XCTAssertNotNil(CameraUID(AppSettings.defaultCameraUID))
    }

    func testRouteWarningOnlyForMicReceiver() {
        XCTAssertFalse(AudioRoute.routeWarning([.usbAudio]).isEmpty)
        XCTAssertEqual(AudioRoute.routeWarning([.bluetoothA2DP]), "")
        XCTAssertEqual(AudioRoute.routeWarning([.builtInSpeaker]), "", "hoparlör bilerek seçilmiş olabilir")
    }

    func testThermalGuardOnlyReactsToSeriousAndCritical() {
        XCTAssertFalse(ThermalGuard.isHot(.nominal))
        XCTAssertFalse(ThermalGuard.isHot(.fair))
        XCTAssertTrue(ThermalGuard.isHot(.serious))
        XCTAssertTrue(ThermalGuard.isHot(.critical))
    }
}
