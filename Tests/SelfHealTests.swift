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
        t.repairChecks = 1; t.checkInterval = 0; t.repairCooldown = 600   // eski davranış: ikinci başarısız yoklamada, 10 dk arayla
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
        t.repairChecks = 1; t.checkInterval = 0; t.repairCooldown = 600   // eski davranış: ikinci başarısız yoklamada, 10 dk arayla
        _ = t.record(online: false, now: 0, canRepair: false)
        XCTAssertEqual(t.record(online: false, now: 45, canRepair: false), .warn)
        XCTAssertEqual(t.record(online: false, now: 90, canRepair: true), .repair)
    }

    func testDefaultsAreThreeChecksAMinuteApartAndAMinuteBetweenTries() {
        let t = OfflineTracker()
        XCTAssertEqual(t.repairChecks, 3)
        XCTAssertEqual(t.checkInterval, 60)
        XCTAssertEqual(t.repairCooldown, 60)
        XCTAssertEqual(t.maxRepairsPerOutage, 3)
    }

    func testRepairWaitsForThreeChecksOneMinuteApartThenRetriesEveryMinute() {
        var t = OfflineTracker()
        // yoklama 45 sn'de bir gelir; sayılan yoklamalar en az 60 sn arayla: 0, 90, 180
        XCTAssertEqual(t.record(online: false, now: 0, canRepair: true), .none)
        XCTAssertEqual(t.record(online: false, now: 45, canRepair: true), .warn, "kullanıcıya haber hemen verilir")
        XCTAssertEqual(t.record(online: false, now: 90, canRepair: true), .none, "2. sayılan yoklama")
        XCTAssertEqual(t.record(online: false, now: 135, canRepair: true), .none, "son sayılandan 60 sn geçmedi: sayılmaz")
        XCTAssertEqual(t.counted, 2)
        XCTAssertEqual(t.record(online: false, now: 180, canRepair: true), .repair, "3. sayılan yoklamada kestirme çalışır")
        XCTAssertEqual(t.record(online: false, now: 225, canRepair: true), .none, "denemeler arası 1 dk dolmadı")
        XCTAssertEqual(t.record(online: false, now: 270, canRepair: true), .repair, "1 dk sonra ikinci deneme")
        XCTAssertEqual(t.record(online: false, now: 315, canRepair: true), .none)
        XCTAssertEqual(t.record(online: false, now: 360, canRepair: true), .repair)
        XCTAssertEqual(t.record(online: false, now: 600, canRepair: true), .none, "bir kesintide en çok 3 deneme")
        XCTAssertEqual(t.repairs, 3)
    }

    func testDuringExamFifteenSecondProbesStillCountOnlyOncePerMinute() {
        var t = OfflineTracker()
        var actions: [(TimeInterval, OfflineTracker.Action)] = []
        for k in 0...8 { let now = TimeInterval(k * 15); actions.append((now, t.record(online: false, now: now, canRepair: true))) }
        XCTAssertEqual(actions.first(where: { $0.1 == .repair })?.0, 120, "0., 60., 120. sn sayılır; 3. yoklamada çalışır")
        XCTAssertEqual(actions.first(where: { $0.1 == .warn })?.0, 15)
    }

    func testUserCanChangeChecksIntervalAndWait() {
        var t = OfflineTracker()
        t.repairChecks = 2; t.checkInterval = 30; t.repairCooldown = 60
        XCTAssertEqual(t.record(online: false, now: 0, canRepair: true), .none)
        XCTAssertEqual(t.record(online: false, now: 30, canRepair: true), .repair, "2 yoklama, 30 sn arayla")
        XCTAssertEqual(t.record(online: false, now: 60, canRepair: true), .none)
        XCTAssertEqual(t.record(online: false, now: 90, canRepair: true), .repair, "bekleme 60 sn")
    }

    func testTimerJitterDoesNotLoseACountedCheck() {
        var t = OfflineTracker()
        // yoklama 30 sn'de bir, zamanlayıcı birkaç yüz ms erken gelebilir: 59,8 sn "60 sn arayla" sayılır
        _ = t.record(online: false, now: 0, canRepair: true)
        _ = t.record(online: false, now: 29.9, canRepair: true)
        _ = t.record(online: false, now: 59.8, canRepair: true)
        XCTAssertEqual(t.counted, 2)
        _ = t.record(online: false, now: 89.7, canRepair: true)
        XCTAssertEqual(t.record(online: false, now: 119.6, canRepair: true), .repair, "0, 59,8, 119,6 → 3 sayılan yoklama")
        // bekleme de aynı payla: 60 sn'lik bekleme 59,5 sn sonra bitmiş sayılır
        XCTAssertEqual(t.record(online: false, now: 179.1, canRepair: true), .repair)
    }

    func testCameraLinkTextsAreForVoice() {
        XCTAssertEqual(ExamLink.camera.word, "Kamera")
        XCTAssertNotNil(ExamLink.camera.lostLine)
        XCTAssertNotNil(ExamLink.camera.repairLine)
        XCTAssertNotNil(ExamLink.camera.waitLine)
        XCTAssertTrue(ExamLink.camera.statusText.contains("Kamera"))
        XCTAssertTrue(ExamLink.camera.repairLine?.contains("Kamera kestirmesi") == true)
    }

    func testCameraShortcutNameIsPersisted() {
        let d = UserDefaults.standard
        let saved = d.object(forKey: "cameraShortcutName")
        defer { d.set(saved, forKey: "cameraShortcutName") }
        d.removeObject(forKey: "cameraShortcutName")
        let s = AppSettings()
        XCTAssertEqual(s.cameraShortcutName, "", "varsayılan boş: kamera kestirmesi kapalı")
        s.cameraShortcutName = "Wi-Fi Yenile"
        XCTAssertEqual(d.string(forKey: "cameraShortcutName"), "Wi-Fi Yenile")
    }

    func testRecoveryResetsTheCountedChecks() {
        var t = OfflineTracker()
        _ = t.record(online: false, now: 0, canRepair: true)
        _ = t.record(online: false, now: 60, canRepair: true)
        XCTAssertEqual(t.counted, 2)
        _ = t.record(online: true, now: 70, canRepair: true)
        XCTAssertEqual(t.counted, 0)
        XCTAssertEqual(t.record(online: false, now: 100, canRepair: true), .none)
        XCTAssertEqual(t.record(online: false, now: 160, canRepair: true), .warn)
        XCTAssertEqual(t.counted, 2, "yeni kesintide baştan sayılır")
    }

    func testSuspendKeepsCountedChecksSoTheShortcutDoesNotWaitAllOverAgain() {
        var t = OfflineTracker()
        for now in stride(from: 0.0, through: 120.0, by: 60.0) { _ = t.record(online: false, now: now, canRepair: true) }
        XCTAssertEqual(t.counted, 3)
        t.suspend()
        XCTAssertEqual(t.counted, 3)
        XCTAssertEqual(t.repairs, 1)
    }

    func testRepairSettingsDefaultsAndLimits() {
        let d = UserDefaults.standard
        let keys = ["repairChecks", "repairCheckSeconds", "repairWaitSeconds"]
        let saved = keys.map { d.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { d.set(v, forKey: k) } }
        for k in keys { d.removeObject(forKey: k) }
        var s = AppSettings()
        XCTAssertEqual([s.repairChecks, s.repairCheckSeconds, s.repairWaitSeconds], [3, 60, 60])
        d.set(99, forKey: "repairChecks"); d.set(1, forKey: "repairCheckSeconds"); d.set(99999, forKey: "repairWaitSeconds")
        s = AppSettings()
        XCTAssertEqual([s.repairChecks, s.repairCheckSeconds, s.repairWaitSeconds], [10, 30, 3600], "üst/alt sınırlar uygulanır")
        s.repairChecks = 4
        XCTAssertEqual(d.integer(forKey: "repairChecks"), 4, "değişiklik kalıcıdır")
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

    func testPickerURLRunsTheHelperShortcutWithTheKindAsText() throws {
        let c = try XCTUnwrap(ShortcutLink.pickerURL(kind: .connection)).absoluteString
        XCTAssertTrue(c.hasPrefix("shortcuts://run-shortcut?name=G526%20Kestirme%20Se%C3%A7&"), c)
        XCTAssertTrue(c.hasSuffix("input=text&text=baglanti"), c)
        let a = try XCTUnwrap(ShortcutLink.pickerURL(kind: .audio)).absoluteString
        XCTAssertTrue(a.hasSuffix("input=text&text=ses"), a)
        let k = try XCTUnwrap(ShortcutLink.pickerURL(kind: .camera)).absoluteString
        XCTAssertTrue(k.hasSuffix("input=text&text=kamera"), k)
    }

    func testSelectionFromHelperShortcutLink() throws {
        let url = try XCTUnwrap(URL(string: "g526kamera://sec?tur=baglanti&ad=H%C3%BCcresel%20Yenile"))
        let pick = try XCTUnwrap(ShortcutLink.selection(from: url))
        XCTAssertEqual(pick.kind, .connection)
        XCTAssertEqual(pick.name, "Hücresel Yenile")
        let audio = try XCTUnwrap(ShortcutLink.selection(from: try XCTUnwrap(URL(string: "g526kamera://sec?tur=Ses&ad=%20Ses%20Onar%20"))))
        XCTAssertEqual(audio.kind, .audio, "tür büyük/küçük harf ve boşluktan etkilenmez")
        XCTAssertEqual(audio.name, "Ses Onar", "ad kırpılır")
        let camera = try XCTUnwrap(ShortcutLink.selection(from: try XCTUnwrap(URL(string: "g526kamera://sec?tur=kamera&ad=Wi-Fi%20Yenile"))))
        XCTAssertEqual(camera.kind, .camera)
        XCTAssertEqual(camera.name, "Wi-Fi Yenile")
    }

    func testSelectionIgnoresOtherLinksAndEmptyNames() throws {
        XCTAssertNil(ShortcutLink.selection(from: try XCTUnwrap(URL(string: "g526kamera://kestirme"))), "kestirme dönüş bağlantısı seçim değildir")
        XCTAssertNil(ShortcutLink.selection(from: try XCTUnwrap(URL(string: "g526kamera://sec?tur=baglanti&ad="))))
        XCTAssertNil(ShortcutLink.selection(from: try XCTUnwrap(URL(string: "g526kamera://sec?tur=baska&ad=X"))))
        XCTAssertNil(ShortcutLink.selection(from: try XCTUnwrap(URL(string: "https://sec?tur=baglanti&ad=X"))))
    }

    // MARK: Kestirme adları ve sınırlayıcı

    func testSuspendKeepsRepairCountAndCooldownSoShortcutCannotLoopForever() {
        var t = OfflineTracker()
        t.repairChecks = 1; t.checkInterval = 0; t.repairCooldown = 600   // eski davranış: ikinci başarısız yoklamada, 10 dk arayla
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

    func testRepairThrottleWouldAllowDoesNotCountATry() {
        var t = RepairThrottle(cooldown: 180, maxTries: 2)
        XCTAssertTrue(t.wouldAllow(now: 0))
        XCTAssertTrue(t.wouldAllow(now: 0), "bakmak deneme saymaz")
        XCTAssertTrue(t.allow(now: 0))
        XCTAssertFalse(t.wouldAllow(now: 100), "bekleme süresi dolmadı")
        XCTAssertTrue(t.wouldAllow(now: 200))
        XCTAssertTrue(t.allow(now: 200))
        XCTAssertFalse(t.wouldAllow(now: 1000), "en çok 2 deneme")
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
