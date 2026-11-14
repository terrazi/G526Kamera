import XCTest
@testable import G526CameraDrive

/// Anında tespit (nabız): mikrofon tamponu, ses servisi, internet nabzı, donanım dönüşü ve canlı durum
@MainActor
final class InstantDetectionTests: XCTestCase {
    private typealias T = SessionViewModel.Timing

    private func makeHarness() -> SessionHarness {
        let h = SessionHarness()
        h.settings.instantDetection = true
        return h
    }

    /// Dinleme açıldıktan sonraki bekleme süresini geçirir
    private func passWarmup(_ h: SessionHarness) {
        h.scheduler.advance(by: T.sentinelTick * Double(T.micWarmupTicks + 1) + 0.01)
    }

    func testSettingIsOnByDefaultAndPersisted() {
        let defaults = UserDefaults(suiteName: "g526.testler.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.instantDetection)
        settings.instantDetection = false
        XCTAssertFalse(AppSettings(defaults: defaults).instantDetection)
    }

    // MARK: Mikrofon

    func testStalledMicIsRebuiltWithinSecondsAndTheHalfSentenceIsKept() async {
        let h = makeHarness()
        let ok = await h.startListening()
        XCTAssertTrue(ok)
        passWarmup(h)
        h.listener.say("Türkiye'nin başkenti")
        let starts = h.listener.startCalls
        h.listener.secondsSinceAudio = 5
        h.scheduler.advance(by: T.sentinelTick * 2)
        XCTAssertEqual(h.listener.startCalls, starts + 1, "Dinleme hemen yeniden kuruldu")
        XCTAssertEqual(h.vm.phase, .listening)
        XCTAssertTrue(h.vm.accumulator.text.contains("başkenti"), "Yarım metin korunur")
    }

    func testStalledListenerThatIsNotRunningIsAlsoRebuilt() async {
        let h = makeHarness()
        _ = await h.startListening()
        passWarmup(h)
        h.listener.pause()
        let starts = h.listener.startCalls
        h.scheduler.advance(by: T.sentinelTick * 2)
        XCTAssertEqual(h.listener.startCalls, starts + 1)
    }

    func testHealthyMicIsNeverTouched() async {
        let h = makeHarness()
        _ = await h.startListening()
        let starts = h.listener.startCalls
        h.scheduler.advance(by: 25)   // 30 sn'lik sessizlik bekçisinin süresinden kısa
        await settle()
        XCTAssertEqual(h.listener.startCalls, starts)
        XCTAssertEqual(h.vm.phase, .listening)
    }

    func testRepeatedStallsEscalateToTheShortcuts() async {
        let h = makeHarness()
        _ = await h.startListening()
        h.listener.secondsSinceAudio = 9
        for _ in 0..<12 {
            h.scheduler.advance(by: 2)
            await settle()
        }
        let ran = await waitUntil { !h.shortcuts.runs.isEmpty }
        XCTAssertTrue(ran, "Dinleme art arda kurulamayınca Kestirmeler çalışır")
    }

    func testEngineStoppedEventRebuildsListeningAtOnce() async {
        let h = makeHarness()
        _ = await h.startListening()
        passWarmup(h)
        let starts = h.listener.startCalls
        h.listener.onEvent?(.engineStopped)
        XCTAssertEqual(h.listener.startCalls, starts + 1)
        XCTAssertEqual(h.vm.phase, .listening)
    }

    func testEngineStoppedEventIsIgnoredWhenDetectionIsOff() async {
        let h = SessionHarness()
        _ = await h.startListening()
        let starts = h.listener.startCalls
        h.listener.onEvent?(.engineStopped)
        XCTAssertEqual(h.listener.startCalls, starts)
    }

    func testDetectionOffMeansNoPulseAtAll() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.listener.secondsSinceAudio = 9
        let starts = h.listener.startCalls
        h.scheduler.advance(by: 25)
        await settle()
        XCTAssertEqual(h.listener.startCalls, starts)
        XCTAssertEqual(h.health.quickCalls, 0)
        XCTAssertEqual(h.vm.liveStatus, "")
    }

    // MARK: Ses servisi

    func testMediaServicesResetPausesAndComesBackByItselfWithAShortCue() async {
        let h = makeHarness()
        _ = await h.startListening()
        h.route.onMediaServicesReset?()
        XCTAssertTrue(h.isHardwarePause)
        let configures = h.route.configureCalls
        h.scheduler.advance(by: T.mediaHealDelay + 0.1)
        XCTAssertGreaterThan(h.route.configureCalls, configures, "Ses oturumu yeniden kuruldu")
        h.scheduler.advance(by: T.routeStable + 0.1)
        let back = await waitUntil { h.vm.phase == .listening && h.speaker.spoken.last == Say.recoveredShort }
        XCTAssertTrue(back, "Kısa kesintide kısa anons")
        XCTAssertTrue(h.shortcuts.runs.isEmpty, "Kestirme gerekmedi")
    }

    func testMediaServicesResetIsRetriedWhileTheServiceIsStillDown() async {
        let h = makeHarness()
        _ = await h.startListening()
        h.route.configureError = NSError(domain: "test", code: 1)
        h.route.onMediaServicesReset?()
        h.scheduler.advance(by: T.mediaHealDelay + 0.1)
        let afterFirst = h.route.configureCalls
        h.scheduler.advance(by: 1.1)
        XCTAssertGreaterThan(h.route.configureCalls, afterFirst, "Servis dönene kadar 1 sn arayla yeniden denenir")
        h.route.configureError = nil
        h.scheduler.advance(by: 1.1)
        h.scheduler.advance(by: T.routeStable + 0.1)
        let back = await waitUntil { h.vm.phase == .listening }
        XCTAssertTrue(back)
    }

    func testMediaServicesResetIsIgnoredWhenDetectionIsOff() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.route.onMediaServicesReset?()
        XCTAssertEqual(h.vm.phase, .listening)
    }

    // MARK: Donanım dönüşü

    func testHardwareReturnIsNoticedEvenWhenNoRouteNotificationArrives() async {
        let h = makeHarness()
        _ = await h.startListening()
        h.route.change(to: FakeRoute.noMic)
        let paused = await waitUntil { h.isHardwarePause }
        XCTAssertTrue(paused)
        h.route.current = FakeRoute.good   // iOS bildirim göndermedi
        h.scheduler.advance(by: T.sentinelTick + 0.01)
        h.scheduler.advance(by: T.routeStable + 0.1)
        let back = await waitUntil { h.vm.phase == .listening }
        XCTAssertTrue(back)
    }

    // MARK: İnternet

    func testHeartbeatStaysQuietWhileTheInternetIsFine() async {
        let h = makeHarness()
        _ = await h.startListening()
        for _ in 0..<12 {
            h.scheduler.advance(by: 5)
            await settle()
        }
        XCTAssertGreaterThanOrEqual(h.health.quickCalls, 10)
        XCTAssertEqual(h.vm.phase, .listening)
        XCTAssertTrue(h.shortcuts.runs.isEmpty)
        XCTAssertEqual(h.vm.netPulse, .up)
    }

    func testTwoMissedBeatsStartTheRepairWithoutWaitingForAnyNotification() async {
        let h = makeHarness()
        _ = await h.startListening()
        h.health.internet = false
        h.health.quickResults = [false, false]
        h.scheduler.advance(by: Double(T.netBeatEvery) * T.sentinelTick + 0.01)
        await settle()
        XCTAssertEqual(h.vm.netPulse, .suspect, "Tek nabız eksikliği şüphe sayılır, onarım başlamaz")
        XCTAssertEqual(h.vm.phase, .listening)
        h.scheduler.advance(by: Double(T.netRetryTicks) * T.sentinelTick + 0.01)
        let ran = await waitUntil { h.shortcuts.runs.first == "WiFi_Ac" }
        XCTAssertTrue(ran, "İkinci nabız da yoksa Kestirme (önce Wi-Fi) çalışır")
        XCTAssertEqual(h.health.quickCalls, 2)
    }

    func testASingleMissedBeatNeverStartsTheRepair() async {
        let h = makeHarness()
        _ = await h.startListening()
        h.health.quickResults = [false]
        h.scheduler.advance(by: Double(T.netBeatEvery) * T.sentinelTick + 0.01)
        await settle()
        h.scheduler.advance(by: Double(T.netRetryTicks) * T.sentinelTick + 0.01)
        await settle()
        XCTAssertEqual(h.vm.phase, .listening)
        XCTAssertTrue(h.shortcuts.runs.isEmpty)
        XCTAssertEqual(h.vm.netPulse, .up)
    }

    func testPathChangeProbesAtOnce() async {
        let h = makeHarness()
        _ = await h.startListening()
        h.network.onPathChange?()
        await settle()
        XCTAssertEqual(h.health.quickCalls, 1, "Wi-Fi ↔ hücresel geçişinde nabız beklenmez")
    }

    func testInternetReturnResumesAtOnceWithoutWaitingForTheRetry() async {
        let h = makeHarness()
        _ = await h.startListening()
        h.health.internet = false
        h.network.set(online: false)
        h.scheduler.advance(by: T.offlineDebounce + 0.1)
        let gaveUp = await waitUntil { h.vm.phase == .paused(.noConnection) }
        XCTAssertTrue(gaveUp)
        h.health.internet = true
        h.scheduler.advance(by: Double(T.netPausedBeatEvery) * T.sentinelTick + 0.01)
        let back = await waitUntil { h.vm.phase == .listening }
        XCTAssertTrue(back, "60 sn'lik yeniden deneme ve dönüş bildirimi beklenmedi")
    }

    // MARK: Canlı durum ve kısa kesinti

    func testLiveStatusShowsEachLink() async {
        let h = makeHarness()
        _ = await h.startListening()
        h.scheduler.advance(by: T.sentinelTick + 0.01)
        XCTAssertTrue(h.vm.liveStatus.contains("Kulaklık ✓"))
        XCTAssertTrue(h.vm.liveStatus.contains("Mikrofon ✓"))
        h.route.change(to: FakeRoute.noHeadphones)
        h.scheduler.advance(by: T.sentinelTick + 0.01)
        XCTAssertTrue(h.vm.liveStatus.contains("Kulaklık ✗"))
        XCTAssertTrue(h.vm.liveStatus.contains("Mikrofon ✗"))
    }

    func testBriefOutageIsShorterThanTheLimit() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(SessionViewModel.isBriefOutage(since: now.addingTimeInterval(-3), now: now))
        XCTAssertFalse(SessionViewModel.isBriefOutage(since: now.addingTimeInterval(-T.briefOutage - 1), now: now))
        XCTAssertFalse(SessionViewModel.isBriefOutage(since: nil, now: now))
    }

    func testOutageDetectionTimingsAreInstantEnough() {
        XCTAssertLessThanOrEqual(T.sentinelTick, 0.5)
        XCTAssertLessThanOrEqual(T.micStallLimit + T.sentinelTick, 2, "Mikrofon kopması en geç ~2 sn'de yakalanır")
        XCTAssertLessThanOrEqual(T.outputQuickDelay, 1)
        XCTAssertLessThanOrEqual(T.offlineDebounce, 1)
    }
}
