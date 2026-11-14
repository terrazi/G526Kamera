import XCTest
@testable import G526CameraDrive

/// İsteğe bağlı "çıkışı kulaklığa al" kestirmesi ("Oynatma Hedefini Ayarla"): ses iPhone'a düşünce Bluetooth'a dokunmadan çıkışı kulaklığa alır
@MainActor
final class OutputShortcutTests: XCTestCase {
    private let shortcutName = "Kulaklığa_Al"

    func testSettingIsEmptyByDefaultAndPersisted() {
        let defaults = UserDefaults(suiteName: "g526.testler.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.outputShortcut, "")
        settings.outputShortcut = shortcutName
        XCTAssertEqual(AppSettings(defaults: defaults).outputShortcut, shortcutName)
    }

    func testStartupPutsTheOutputOnTheHeadphonesWhenItIsOnThePhone() async {
        let h = SessionHarness()
        h.settings.outputShortcut = shortcutName
        h.route.current = FakeRoute.noHeadphones
        h.shortcuts.onRun = { ran in if ran == "Kulaklığa_Al" { h.route.current = FakeRoute.good } }
        let ok = await h.startListening()
        XCTAssertTrue(ok, "Çıkış kulaklığa alınınca test başlar")
        XCTAssertEqual(h.shortcuts.runs, [shortcutName], "Bluetooth kapatılıp açılmaz")
        XCTAssertEqual(h.speaker.spoken.first, Say.ready)
    }

    func testWithoutTheShortcutNothingIsRunAtStartup() async {
        let h = SessionHarness()
        h.route.current = FakeRoute.noHeadphones
        h.vm.start()
        let paused = await waitUntil { h.isHardwarePause }
        XCTAssertTrue(paused)
        XCTAssertTrue(h.shortcuts.runs.isEmpty)
    }

    func testHeadphonesAlreadyOnTheRouteNeverRunTheShortcut() async {
        let h = SessionHarness()
        h.settings.outputShortcut = shortcutName
        _ = await h.startListening()
        XCTAssertTrue(h.shortcuts.runs.isEmpty)
    }

    func testLostOutputDuringTheTestIsFixedBeforeBluetoothIsRefreshed() async {
        let h = SessionHarness()
        h.settings.outputShortcut = shortcutName
        _ = await h.startListening()
        h.shortcuts.onRun = { ran in if ran == "Kulaklığa_Al" { h.route.current = FakeRoute.good } }
        h.route.change(to: FakeRoute.noHeadphones)
        h.scheduler.advance(by: SessionViewModel.Timing.hardwareGrace + 0.1)
        await settle()
        h.scheduler.advance(by: SessionViewModel.Timing.routeStable + 0.1)
        let back = await waitUntil { h.vm.phase == .listening && h.speaker.spoken.last == Say.recovered }
        XCTAssertTrue(back)
        XCTAssertEqual(h.shortcuts.runs, [shortcutName], "Bluetooth yenileme ve sıfırlama çalışmaz")
    }

    func testWhenTheShortcutDoesNotHelpTheUsualRepairFollows() async {
        let h = SessionHarness()
        h.settings.outputShortcut = shortcutName
        _ = await h.startListening()
        h.route.change(to: FakeRoute.noHeadphones)
        h.scheduler.advance(by: SessionViewModel.Timing.hardwareGrace + 0.1)
        let ran = await waitUntil { h.shortcuts.runs.count == 4 }
        XCTAssertTrue(ran)
        XCTAssertEqual(h.shortcuts.runs, [shortcutName, shortcutName, "Bluetooth_Yenile", "Sistemi_Sifirla"],
                       "Önce hemen, sonra süre dolunca çıkış kestirmesi; çözmezse eski sıra")
    }

    func testShortcutStopsAfterTooManyFailedTries() async {
        let h = SessionHarness()
        h.settings.outputShortcut = shortcutName
        _ = await h.startListening()
        h.vm.outputTries = SessionViewModel.Timing.maxOutputTries
        h.route.change(to: FakeRoute.noHeadphones)
        h.scheduler.advance(by: SessionViewModel.Timing.hardwareGrace + 0.1)
        let ran = await waitUntil { h.shortcuts.runs.count == 2 }
        XCTAssertTrue(ran)
        XCTAssertEqual(h.shortcuts.runs, ["Bluetooth_Yenile", "Sistemi_Sifirla"], "Hak bitince eski onarım sırası")
    }

    // MARK: Kulaklık düşünce elle değil kendiliğinden: birkaç saniye içinde

    func testDroppedHeadphonesAreBroughtBackWithinSecondsWithoutWaitingForTheGrace() async {
        let h = SessionHarness()
        h.settings.outputShortcut = shortcutName
        _ = await h.startListening()
        h.shortcuts.onRun = { ran in if ran == "Kulaklığa_Al" { h.route.current = FakeRoute.good } }
        h.route.change(to: FakeRoute.noHeadphones)
        let paused = await waitUntil { h.isHardwarePause }
        XCTAssertTrue(paused)
        XCTAssertTrue(h.shortcuts.runs.isEmpty, "Yol bildirimleri otursun diye birkaç saniye beklenir")
        XCTAssertLessThan(SessionViewModel.Timing.outputQuickDelay, SessionViewModel.Timing.hardwareGrace)
        h.scheduler.advance(by: SessionViewModel.Timing.outputQuickDelay + 0.1)
        let ran = await waitUntil { h.shortcuts.runs.count == 1 }
        XCTAssertTrue(ran, "20 sn'lik beklemeden önce çalışır")
        await settle()
        h.scheduler.advance(by: SessionViewModel.Timing.routeStable + 0.1)
        let back = await waitUntil { h.vm.phase == .listening && h.speaker.spoken.last == Say.recovered }
        XCTAssertTrue(back)
        XCTAssertEqual(h.shortcuts.runs, [shortcutName], "Bluetooth yenileme ve sıfırlama çalışmaz")
        XCTAssertEqual(h.vm.outputTries, 0, "Yol dönünce hak yenilenir")
    }

    func testNoQuickAttemptWithoutTheShortcut() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.route.change(to: FakeRoute.noHeadphones)
        h.scheduler.advance(by: SessionViewModel.Timing.outputQuickDelay + 0.1)
        await settle()
        XCTAssertTrue(h.shortcuts.runs.isEmpty)
    }

    func testNoQuickAttemptWhenOnlyTheMicrophoneIsMissing() async {
        let h = SessionHarness()
        h.settings.outputShortcut = shortcutName
        _ = await h.startListening()
        h.route.change(to: FakeRoute.noMic)
        h.scheduler.advance(by: SessionViewModel.Timing.outputQuickDelay + 0.1)
        await settle()
        XCTAssertTrue(h.shortcuts.runs.isEmpty, "Kulaklık yolda: çıkış kestirmesi gereksiz")
    }

    func testHeadphonesBackBeforeTheQuickAttemptNeverRunTheShortcut() async {
        let h = SessionHarness()
        h.settings.outputShortcut = shortcutName
        _ = await h.startListening()
        h.route.change(to: FakeRoute.noHeadphones)
        h.route.change(to: FakeRoute.good)
        h.scheduler.advance(by: SessionViewModel.Timing.outputQuickDelay + 0.1)
        await settle()
        XCTAssertTrue(h.shortcuts.runs.isEmpty)
    }
}
