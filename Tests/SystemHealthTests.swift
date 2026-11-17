import XCTest
@testable import G526CameraDrive

/// Öngörülemeyen sistem sorunları: bellek, ısı, düşük güç modu, boş yer ve takılma gözcüsü
@MainActor
final class SystemHealthTests: XCTestCase {
    private typealias T = SessionViewModel.Timing

    private func makeHarness() -> SessionHarness {
        let h = SessionHarness()
        h.settings.instantDetection = true
        return h
    }

    private func warning(_ h: SessionHarness, _ id: String) -> String? {
        return h.vm.warnings.first(where: { $0.id == id })?.text
    }

    private func snapshot(memory: Int? = 1500, thermal: ProcessInfo.ThermalState = .nominal, lowPower: Bool = false, disk: Int? = 5000) -> SystemSnapshot {
        return SystemSnapshot(availableMemoryMB: memory, footprintMB: 200, thermal: thermal, lowPowerMode: lowPower, freeDiskMB: disk)
    }

    // MARK: Bellek

    func testMemoryWarningDuringTheSessionLightensTheLoadAndTheSessionContinues() async {
        let h = makeHarness()
        _ = await h.startListening()
        h.system.current = snapshot(memory: 120)
        h.system.onMemoryWarning?()
        XCTAssertEqual(h.listener.trimStates, [true], "Yardımcı İngilizce tanıyıcı bırakılır")
        XCTAssertEqual(warning(h, "bellek"), Say.memoryLow)
        XCTAssertEqual(h.vm.phase, .listening, "Oturum sürer")
    }

    func testMemoryWarningWithoutASessionDoesNothing() async {
        let h = makeHarness()
        h.system.onMemoryWarning?()
        await settle()
        XCTAssertTrue(h.listener.trimStates.isEmpty)
        XCTAssertNil(warning(h, "bellek"))
    }

    func testMemoryRecoversAndTheHelperRecognizerComesBack() async {
        let h = makeHarness()
        _ = await h.startListening()
        h.system.current = snapshot(memory: 120)
        h.system.onMemoryWarning?()
        h.system.current = snapshot(memory: 1200)
        h.scheduler.advance(by: T.sentinelTick * Double(T.systemEveryTicks) + 1)
        XCTAssertEqual(h.listener.trimStates, [true, false], "Bellek rahatlayınca yardımcı tanıyıcı geri açılır")
        XCTAssertNil(warning(h, "bellek"))
    }

    func testLowMemoryDetectedByThePeriodicCheckWithoutAnyIOSWarning() async {
        let h = makeHarness()
        _ = await h.startListening()
        h.system.current = snapshot(memory: T.lowMemoryMB - 50)
        h.scheduler.advance(by: T.sentinelTick * Double(T.systemEveryTicks) + 1)
        XCTAssertEqual(h.listener.trimStates.first, true)
        XCTAssertNotNil(warning(h, "bellek"))
    }

    func testLowMemoryAtStartLightensTheLoadBeforeListening() async {
        let h = makeHarness()
        h.system.current = snapshot(memory: 100)
        let ok = await h.startListening()
        XCTAssertTrue(ok)
        XCTAssertEqual(h.listener.trimStates.first, true)
        XCTAssertNotNil(warning(h, "bellek"))
    }

    func testMemoryLoadIsRestoredWhenANewSessionStarts() async {
        let h = makeHarness()
        _ = await h.startListening()
        h.system.onMemoryWarning?()
        h.vm.endTest()
        h.system.current = snapshot(memory: 1500)
        _ = await h.startListening()
        XCTAssertEqual(h.listener.trimStates, [true, false], "Yeni oturum yüklü başlar; bellek hâlâ azsa açılışta yeniden kırpılır")
        XCTAssertNil(warning(h, "bellek"))
    }

    // MARK: Isı, güç modu, boş yer

    func testThermalSeriousAndCriticalWarnAndClearWhenItCoolsDown() async {
        let h = makeHarness()
        _ = await h.startListening()
        h.system.current = snapshot(thermal: .serious)
        h.system.onThermalChange?()
        XCTAssertEqual(warning(h, "isi"), Say.hot)
        h.system.current = snapshot(thermal: .critical)
        h.system.onThermalChange?()
        XCTAssertEqual(warning(h, "isi"), Say.veryHot)
        h.system.current = snapshot(thermal: .nominal)
        h.system.onThermalChange?()
        XCTAssertNil(warning(h, "isi"))
        XCTAssertEqual(h.listener.trimStates, [true, false], "Isı baskısında yük azaltılır, soğuyunca geri açılır")
    }

    func testFairThermalStateIsNotWorthAWarning() async {
        let h = makeHarness()
        _ = await h.startListening()
        h.system.current = snapshot(thermal: .fair)
        h.system.onThermalChange?()
        XCTAssertNil(warning(h, "isi"))
    }

    func testLowPowerModeWarnsAtStartAndWhenToggled() async {
        let h = makeHarness()
        h.system.current = snapshot(lowPower: true)
        _ = await h.startListening()
        XCTAssertEqual(warning(h, "guc"), Say.lowPowerMode)
        h.system.current = snapshot(lowPower: false)
        h.system.onPowerModeChange?()
        XCTAssertNil(warning(h, "guc"))
        h.system.current = snapshot(lowPower: true)
        h.system.onPowerModeChange?()
        XCTAssertEqual(warning(h, "guc"), Say.lowPowerMode)
    }

    func testLowDiskWarnsWithTheRemainingSpace() async {
        let h = makeHarness()
        h.system.current = snapshot(disk: 150)
        _ = await h.startListening()
        XCTAssertEqual(warning(h, "yer"), Say.lowDisk(150))
        h.system.current = snapshot(disk: 4000)
        h.scheduler.advance(by: T.sentinelTick * Double(T.systemEveryTicks) + 1)
        XCTAssertNil(warning(h, "yer"), "Yer açılınca uyarı silinir")
    }

    func testSystemWarningsWaitForAQuietMomentThenAreSpokenThroughTheHeadset() async {
        let h = makeHarness()
        h.answering.results = [.success(FakeAnswering.reply(1))]
        _ = await h.startListening()
        h.system.current = snapshot(thermal: .critical)
        h.system.onThermalChange?()
        XCTAssertTrue(h.vm.voiceQueue.contains { $0.text == Say.veryHot }, "Dinlerken mikrofona karışmasın diye sıraya alınır")
        h.ask("Birinci soru")
        let spoken = await waitUntil { h.vm.announced.contains(Say.veryHot) && h.vm.phase == .listening }
        XCTAssertTrue(spoken, "Sınavdaki kişi ekrana bakamaz: uyarı sıradaki sessiz anda kulaklıktan da söylenir")
    }

    // MARK: Nabız ve defter

    func testHeartbeatIsWrittenToTheJournalWhileTheSessionRuns() async {
        let h = makeHarness()
        _ = await h.startListening()
        let before = h.journal.heartbeats
        h.scheduler.advance(by: T.sentinelTick * Double(T.heartbeatEveryTicks) * 3 + 0.1)
        XCTAssertGreaterThanOrEqual(h.journal.heartbeats - before, 3, "Kapalı kalma süresini hesaplamak için nabız deftere işlenir")
    }

    // MARK: Takılma gözcüsü

    func testSupervisorRestartsAnAnswerStepThatNeverFinishes() async {
        let h = makeHarness()
        h.answering.results = [.success(FakeAnswering.reply(1))]
        _ = await h.startListening()
        h.answering.hold = true   // Gemini hiç dönmüyor
        h.ask("Birinci soru")
        _ = await waitUntil { h.vm.phase == .answering }
        let limit = T.stuckLimit(for: .answering) ?? 0
        XCTAssertGreaterThan(limit, 0)
        h.scheduler.advance(by: limit - 30)
        XCTAssertEqual(h.vm.phase, .answering, "Sınırdan önce dokunulmaz (Gemini zinciri bu kadar bekleyebilir)")
        h.scheduler.advance(by: 40)
        let restarted = await waitUntil { h.vm.phase == .listening }
        XCTAssertTrue(restarted, "Takılan adım iptal edilir, oturum yeniden kurulup dinlemeye döner")
        XCTAssertNotNil(warning(h, "gozcu"))
        XCTAssertGreaterThanOrEqual(h.vm.stuckTrips, 1)
        h.answering.hold = false
        h.answering.release()
    }

    func testPhasesThatMayWaitForeverAreNeverSupervised() {
        XCTAssertNil(T.stuckLimit(for: .listening))
        XCTAssertNil(T.stuckLimit(for: .paused(.manual)))
        XCTAssertNil(T.stuckLimit(for: .paused(.noConnection)))
        XCTAssertNil(T.stuckLimit(for: .paused(.hardware("kulaklık yok"))))
        XCTAssertNil(T.stuckLimit(for: .replaying))
        XCTAssertNotNil(T.stuckLimit(for: .speaking))
        XCTAssertNotNil(T.stuckLimit(for: .checking))
    }

    func testReadingAnAnswerMayTakeFiveMinutesOtherSpeechThree() {
        XCTAssertEqual(T.answerSpeakingLimit, 300, "Cevap okunurken gözcü sınırı 300 sn")
        XCTAssertEqual(T.stuckLimit(for: .speaking), 180, "Diğer konuşmalarda sınır 180 sn")
        XCTAssertEqual(T.stuckLimit(for: .speaking, readingAnswer: true), 300)
        XCTAssertEqual(T.stuckLimit(for: .answering, readingAnswer: true), T.stuckLimit(for: .answering), "Yalnız konuşma aşaması uzar")
    }

    func testAnAnswerBeingReadIsNotRestartedBeforeFiveMinutes() async {
        let h = makeHarness()
        h.answering.results = [.success(FakeAnswering.reply(1))]
        _ = await h.startListening()
        h.speaker.hold = true   // cevap okunuyor, bitmiyor
        h.ask("Birinci soru")
        let reading = await waitUntil { h.vm.phase == .speaking && h.vm.unheard != nil }
        XCTAssertTrue(reading, "\(h.vm.phase)")
        h.scheduler.advance(by: 250)   // eski sınır (180 sn) çoktan aşıldı
        XCTAssertEqual(h.vm.phase, .speaking)
        XCTAssertEqual(h.vm.stuckTrips, 0, "Cevap okunurken 300 sn dolmadan yeniden kurulmaz")
        h.scheduler.advance(by: 60)
        let tripped = await waitUntil { h.vm.stuckTrips >= 1 }
        XCTAssertTrue(tripped, "300 sn'yi aşan okuma takılma sayılır")
        h.speaker.hold = false
        h.speaker.release()
    }

    func testListeningForHoursIsNotAStall() async {
        let h = makeHarness()
        _ = await h.startListening()
        h.scheduler.advance(by: 120)
        await settle()
        XCTAssertNil(warning(h, "gozcu"))
        XCTAssertEqual(h.vm.stuckTrips, 0)
    }

    func testPausedSessionWaitsForeverWithoutBeingRestarted() async {
        let h = makeHarness()
        _ = await h.startListening()
        h.vm.pauseByUser()
        h.scheduler.advance(by: 1000)
        await settle()
        XCTAssertEqual(h.vm.phase, .paused(.manual), "Kullanıcı duraklattıysa gözcü karışmaz")
        XCTAssertEqual(h.vm.stuckTrips, 0)
    }
}
