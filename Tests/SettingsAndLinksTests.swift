import XCTest
@testable import G526CameraDrive

final class AppSettingsTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        return UserDefaults(suiteName: "g526.testler.ayar.\(UUID().uuidString)")!
    }

    func testDefaults() {
        let s = AppSettings(defaults: makeDefaults())
        XCTAssertFalse(s.startEnabled)
        XCTAssertEqual(s.startMinutes, 9 * 60)
        XCTAssertEqual(s.replayGap, 3, "Varsayılan boşluk 3 saniye")
        XCTAssertTrue(s.sendAudio)
        XCTAssertTrue(s.geminiVoice)
        XCTAssertEqual(s.wifiShortcut, "")
        XCTAssertEqual(s.cellularShortcut, "")
        XCTAssertEqual(s.bluetoothShortcut, "")
        XCTAssertEqual(s.resetShortcut, "")
    }

    func testValuesPersist() {
        let defaults = makeDefaults()
        let s = AppSettings(defaults: defaults)
        s.startEnabled = true
        s.startMinutes = 6 * 60 + 45
        s.wifiShortcut = "WiFi_Ac"
        s.cellularShortcut = "Hücresel_Ac"
        s.bluetoothShortcut = "Bluetooth_Yenile"
        s.resetShortcut = "Sistemi_Sifirla"
        s.replayGap = 5
        s.sendAudio = false
        s.geminiVoice = false

        let again = AppSettings(defaults: defaults)
        XCTAssertTrue(again.startEnabled)
        XCTAssertEqual(again.startMinutes, 405)
        XCTAssertEqual(again.wifiShortcut, "WiFi_Ac")
        XCTAssertEqual(again.cellularShortcut, "Hücresel_Ac")
        XCTAssertEqual(again.bluetoothShortcut, "Bluetooth_Yenile")
        XCTAssertEqual(again.resetShortcut, "Sistemi_Sifirla")
        XCTAssertEqual(again.replayGap, 5)
        XCTAssertFalse(again.sendAudio)
        XCTAssertFalse(again.geminiVoice)
    }

    func testReplayGapIsClampedToSliderRange() {
        let s = AppSettings(defaults: makeDefaults())
        s.replayGap = 99
        XCTAssertEqual(s.replayGap, 10)
        s.replayGap = -4
        XCTAssertEqual(s.replayGap, 0)
        XCTAssertEqual(AppSettings.replayGapRange, 0...10)
    }

    func testStartMinutesAreClamped() {
        let s = AppSettings(defaults: makeDefaults())
        s.startMinutes = 5000
        XCTAssertEqual(s.startMinutes, 1439)
        s.startMinutes = -1
        XCTAssertEqual(s.startMinutes, 0)
    }

    func testTimeText() {
        XCTAssertEqual(AppSettings.timeText(minutes: 9 * 60), "09:00")
        XCTAssertEqual(AppSettings.timeText(minutes: 23 * 60 + 5), "23:05")
        XCTAssertEqual(AppSettings.timeText(minutes: 9999), "23:59")
    }

    func testStartTimeRoundTrip() {
        let s = AppSettings(defaults: makeDefaults())
        s.startMinutes = 7 * 60 + 30
        let date = s.startTime
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        XCTAssertEqual(parts.hour, 7)
        XCTAssertEqual(parts.minute, 30)
        s.startTime = Calendar.current.date(bySettingHour: 21, minute: 15, second: 0, of: Date())!
        XCTAssertEqual(s.startMinutes, 21 * 60 + 15)
    }

    func testShortcutNamesAreTrimmedAndMissingOnesReported() {
        let s = AppSettings(defaults: makeDefaults())
        s.wifiShortcut = "  WiFi_Ac \n"
        XCTAssertEqual(s.shortcutName(for: .wifi), "WiFi_Ac")
        XCTAssertEqual(s.missingShortcuts, [.cellular, .bluetooth, .reset])
        s.cellularShortcut = "Hücresel_Ac"
        s.resetShortcut = "   "
        XCTAssertEqual(s.missingShortcuts, [.bluetooth, .reset], "Yalnız boşluktan oluşan ad boş sayılır")
    }
}

final class StartScheduleTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ hour: Int, _ minute: Int, day: Int = 13) -> Date {
        return calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute, second: 0))!
    }

    func testTodayIfNotPassedYet() {
        let next = StartSchedule.nextFire(after: date(8, 0), minutes: 9 * 60, calendar: calendar)
        XCTAssertEqual(next, date(9, 0))
    }

    func testTomorrowIfAlreadyPassed() {
        let next = StartSchedule.nextFire(after: date(10, 0), minutes: 9 * 60, calendar: calendar)
        XCTAssertEqual(next, date(9, 0, day: 14))
    }

    func testExactlyNowGoesToTomorrow() {
        let next = StartSchedule.nextFire(after: date(9, 0), minutes: 9 * 60, calendar: calendar)
        XCTAssertEqual(next, date(9, 0, day: 14), "Zaten başlamışken aynı dakikada ikinci kez tetiklenmez")
    }

    func testMinutesPastMidnightAreMappedToClock() {
        let next = StartSchedule.nextFire(after: date(0, 0), minutes: 23 * 60 + 59, calendar: calendar)
        XCTAssertEqual(next, date(23, 59))
    }
}

final class ShortcutLinkTests: XCTestCase {
    func testRunURLEncodesTurkishNameAndCallbacks() throws {
        let url = try XCTUnwrap(ShortcutLink.runURL(name: "Hücresel_Ac"))
        let text = url.absoluteString
        XCTAssertTrue(text.hasPrefix("shortcuts://x-callback-url/run-shortcut?"))
        XCTAssertTrue(text.contains("name=H%C3%BCcresel_Ac"))
        XCTAssertTrue(text.contains("x-success=seslikontrol%3A%2F%2Fkestirme%2Fok"))
        XCTAssertTrue(text.contains("x-cancel=seslikontrol%3A%2F%2Fkestirme%2Fiptal"))
        XCTAssertTrue(text.contains("x-error=seslikontrol%3A%2F%2Fkestirme%2Fhata"))
    }

    func testRunURLEncodesSpaces() throws {
        let url = try XCTUnwrap(ShortcutLink.runURL(name: " Wi Fi Aç "))
        XCTAssertTrue(url.absoluteString.contains("name=Wi%20Fi%20A%C3%A7&"))
    }

    func testEmptyNameGivesNoURL() {
        XCTAssertNil(ShortcutLink.runURL(name: ""))
        XCTAssertNil(ShortcutLink.runURL(name: "   "))
    }

    func testCallbackParsing() {
        XCTAssertEqual(ShortcutLink.callback(from: URL(string: "seslikontrol://kestirme/ok")!), .success)
        XCTAssertEqual(ShortcutLink.callback(from: URL(string: "seslikontrol://kestirme/iptal")!), .cancelled)
        XCTAssertEqual(ShortcutLink.callback(from: URL(string: "seslikontrol://kestirme/hata?errorMessage=Boom")!), .failed("Boom"))
        XCTAssertEqual(ShortcutLink.callback(from: URL(string: "seslikontrol://kestirme/hata")!), .failed(""))
    }

    func testForeignURLsAreNotCallbacks() {
        XCTAssertNil(ShortcutLink.callback(from: URL(string: "seslikontrol://basla")!))
        XCTAssertNil(ShortcutLink.callback(from: URL(string: "baska://kestirme/ok")!))
        XCTAssertNil(ShortcutLink.callback(from: URL(string: "seslikontrol://kestirme/bilinmeyen")!))
    }

    func testOldSchemeStillWorksForExistingAutomations() {
        XCTAssertEqual(ShortcutLink.scheme, "seslikontrol")
        XCTAssertTrue(ShortcutLink.isStartURL(URL(string: "g526kamera://basla")!), "Eski adla kurulmuş otomasyon bozulmasın")
        XCTAssertEqual(ShortcutLink.callback(from: URL(string: "g526kamera://kestirme/ok")!), .success)
    }

    func testStartURL() {
        XCTAssertTrue(ShortcutLink.isStartURL(URL(string: "seslikontrol://basla")!))
        XCTAssertFalse(ShortcutLink.isStartURL(URL(string: "seslikontrol://kestirme/ok")!))
        XCTAssertFalse(ShortcutLink.isStartURL(URL(string: "baska://basla")!))
    }
}

final class SessionPhaseTests: XCTestCase {
    func testRunningAndRestStates() {
        let resting: [SessionPhase] = [.idle, .finished]
        let running: [SessionPhase] = [.checking, .listening, .answering, .speaking, .paused(.noConnection),
                                       .paused(.hardware("x")), .recovering(.network), .replaying]
        resting.forEach { XCTAssertTrue($0.isAtRest, "\($0)") }
        running.forEach { XCTAssertTrue($0.isRunning, "\($0)") }
    }

    func testEveryPhaseHasATitle() {
        let all: [SessionPhase] = [.idle, .checking, .listening, .answering, .speaking, .paused(.noConnection),
                                   .paused(.hardware("x")), .recovering(.hardware), .finished, .replaying]
        all.forEach { XCTAssertFalse($0.title.isEmpty, "\($0)") }
    }

    func testRecoveryStepsOrder() {
        XCTAssertEqual(RecoveryReason.network.steps, [.wifi, .cellular, .reset], "Önce Wi-Fi, sonra hücresel, sonra sıfırlama")
        XCTAssertEqual(RecoveryReason.hardware.steps, [.bluetooth, .reset], "Önce hafif Bluetooth yenileme, olmazsa sıfırlama")
        XCTAssertEqual(RecoveryReason.hardware.steps(force: true), [.reset], "Ses yolu sağlam görünürken yalnız sıfırlama")
        XCTAssertEqual(RecoveryReason.network.steps(force: true), RecoveryReason.network.steps)
    }
}

@MainActor
final class NetworkHealthTests: XCTestCase {
    func testOKAndQuotaCountAsReachable() {
        XCTAssertEqual(NetworkHealth.classify(status: 200, data: Data()), .ok)
        XCTAssertEqual(NetworkHealth.classify(status: 429, data: Data()), .ok)
    }

    func testRejectedKey() {
        for status in [400, 401, 403] {
            if case .keyRejected = NetworkHealth.classify(status: status, data: Data()) {} else {
                XCTFail("HTTP \(status) anahtar reddi sayılmalı")
            }
        }
    }

    func testServerErrorsAreUnreachable() {
        XCTAssertEqual(NetworkHealth.classify(status: 503, data: Data()), .unreachable("HTTP 503"))
        XCTAssertEqual(NetworkHealth.classify(status: 0, data: Data()), .unreachable("HTTP 0"))
    }
}
