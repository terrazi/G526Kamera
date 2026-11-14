import XCTest
@testable import G526CameraDrive

/// Döngü kesiciler: boşuna alarm, art arda onarım, konuşma tanıma hatası. Hepsi anında tespit (nabız) açıkken sınanır.
@MainActor
final class LoopGuardTests: XCTestCase {
    private typealias T = SessionViewModel.Timing

    private func makeHarness() -> SessionHarness {
        let h = SessionHarness()
        h.settings.instantDetection = true
        return h
    }

    /// İnternet nabzı art arda iki kez "yok" der (tam sınama ayrıca `h.health.internet` ile belirlenir)
    private func missTwoBeats(_ h: SessionHarness) async {
        h.health.quickResults = [false, false]
        h.scheduler.advance(by: Double(T.netBeatEvery) * T.sentinelTick + 0.01)
        await settle()
        h.scheduler.advance(by: Double(T.netRetryTicks) * T.sentinelTick + 0.01)
        await settle()
    }

    // MARK: Sınır duraklaması nabızla bozulmaz

    func testCapPauseIsNotUndoneBecauseTheRouteLooksFine() async {
        let h = makeHarness()
        _ = await h.startListening()
        h.vm.hardwareRecoveries = T.maxHardwareRecoveries
        await h.vm.runRecovery(.hardware, force: true)
        XCTAssertTrue(h.isHardwarePause, "Art arda onarım işe yaramadı: duraklatıldı")
        XCTAssertTrue(h.vm.holdForRetry)
        let spoken = h.speaker.spoken.count
        for _ in 0..<40 {
            h.scheduler.advance(by: 2)
            await settle()
        }
        XCTAssertTrue(h.isHardwarePause, "Ses yolu sağlam görünse de sınır beklemesi nabızla bozulmaz")
        XCTAssertEqual(h.speaker.spoken.count, spoken, "Döngüdeki gibi 'yeniden hazır' anonsu tekrarlanmaz")
        XCTAssertTrue(h.shortcuts.runs.isEmpty)
    }

    func testCapPauseEndsWhenTheWaitIsOverAndOneMoreTryIsMade() async {
        let h = makeHarness()
        _ = await h.startListening()
        h.vm.hardwareRecoveries = T.maxHardwareRecoveries
        await h.vm.runRecovery(.hardware, force: true)
        XCTAssertTrue(h.isHardwarePause)
        h.scheduler.advance(by: T.hardwareCapRetry + 1)
        let back = await waitUntil { h.vm.phase == .listening }
        XCTAssertTrue(back, "Bekleme dolunca bir kez daha denenir")
        XCTAssertFalse(h.vm.holdForRetry)
        XCTAssertEqual(h.vm.hardwareRecoveries, T.maxHardwareRecoveries - 1, "Yeniden başarısız olursa sınır hemen yine devreye girer")
    }

    func testRealRouteChangeEndsTheHoldSoTheReturnResumes() async {
        let h = makeHarness()
        _ = await h.startListening()
        h.vm.hardwareRecoveries = T.maxHardwareRecoveries
        await h.vm.runRecovery(.hardware, force: true)
        XCTAssertTrue(h.vm.holdForRetry)
        h.route.change(to: FakeRoute.noMic)
        XCTAssertFalse(h.vm.holdForRetry, "Ses yolu gerçekten değişti")
        h.route.change(to: FakeRoute.good)
        h.scheduler.advance(by: T.routeStable + 0.1)
        let back = await waitUntil { h.vm.phase == .listening }
        XCTAssertTrue(back, "Kullanıcı donanımı düzeltince devam edilir")
    }

    // MARK: İnternet nabzı boşuna alarm verirse

    func testFalseInternetAlarmChangesNothingAndKeepsTheHalfSentence() async {
        let h = makeHarness()
        _ = await h.startListening()
        h.listener.say("Türkiye'nin başkenti")
        let spoken = h.speaker.spoken.count
        await missTwoBeats(h)    // nabız "yok" der ama tam sınama (internet + Gemini) sağlam
        let noted = await waitUntil { h.vm.netFalseAlarms == 1 }
        XCTAssertTrue(noted, "Yanlış alarm sayıldı")
        XCTAssertEqual(h.vm.phase, .listening, "Dinleme hiç kesilmedi")
        XCTAssertTrue(h.shortcuts.runs.isEmpty)
        XCTAssertEqual(h.speaker.spoken.count, spoken, "Hiçbir anons yapılmadı")
        XCTAssertEqual(h.vm.liveText, "Türkiye'nin başkenti", "Yarım okunan soru silinmedi")
        XCTAssertEqual(h.vm.netPulse, .up)
    }

    func testRepeatedFalseAlarmsMuteTheHeartbeatRepair() async {
        let h = makeHarness()
        _ = await h.startListening()
        await missTwoBeats(h)
        _ = await waitUntil { h.vm.netFalseAlarms == 1 }
        await missTwoBeats(h)
        let muted = await waitUntil { h.vm.netMutedUntil != nil }
        XCTAssertTrue(muted, "İki yanlış alarmdan sonra nabızla onarım susturulur")
        let checks = h.health.internetCalls
        await missTwoBeats(h)
        await missTwoBeats(h)
        XCTAssertEqual(h.health.internetCalls, checks, "Susturulmuşken tam sınama bile başlatılmaz")
        XCTAssertEqual(h.vm.phase, .listening)
    }

    func testRealInternetLossStillStartsTheRepair() async {
        let h = makeHarness()
        _ = await h.startListening()
        h.health.internet = false
        await missTwoBeats(h)
        let ran = await waitUntil { h.shortcuts.runs.first == "WiFi_Ac" }
        XCTAssertTrue(ran, "Gerçek kopmada onarım gecikmeden başlar")
        XCTAssertEqual(h.vm.netFalseAlarms, 0)
    }

    // MARK: Konuşma tanıma hatası

    func testRecognizerFailureWithAHealthyRouteDoesNotRunTheBluetoothShortcuts() async {
        let h = makeHarness()
        _ = await h.startListening()
        let starts = h.listener.startCalls
        h.listener.onEvent?(.failure("Konuşma tanıma üst üste hata verdi."))
        await settle()
        XCTAssertEqual(h.vm.phase, .listening)
        XCTAssertGreaterThan(h.listener.startCalls, starts, "Dinleme yeniden kuruldu")
        XCTAssertTrue(h.shortcuts.runs.isEmpty, "Ses yolu sağlam: Bluetooth/uçak modu Kestirmeleri çalışmaz (kulaklığı koparırdı)")
    }

    func testRecognizerFailuresThatKeepComingEscalateOnlyAtTheEnd() async {
        let h = makeHarness()
        _ = await h.startListening()
        for _ in 0..<T.maxMicHeals {
            h.listener.onEvent?(.failure("Konuşma tanıma üst üste hata verdi."))
            await settle()
        }
        XCTAssertTrue(h.shortcuts.runs.isEmpty, "İlk birkaç hatada yalnız dinleme yeniden kurulur")
        h.listener.onEvent?(.failure("Konuşma tanıma üst üste hata verdi."))
        let ran = await waitUntil { !h.shortcuts.runs.isEmpty }
        XCTAssertTrue(ran, "Sürerse son çare olarak Kestirmeler çalışır")
    }

    func testRecognizerFailureWithABrokenRouteStillUsesTheOldRepair() async {
        let h = makeHarness()
        _ = await h.startListening()
        h.route.current = FakeRoute.noMic
        h.listener.onEvent?(.failure("Konuşma tanıma üst üste hata verdi."))
        let ran = await waitUntil { !h.shortcuts.runs.isEmpty || h.isHardwarePause }
        XCTAssertTrue(ran)
    }

    func testEngineStoppedEventsDoNotCountTowardTheEscalation() async {
        let h = makeHarness()
        _ = await h.startListening()
        h.scheduler.advance(by: T.sentinelTick * Double(T.micWarmupTicks + 1) + 0.01)
        for _ in 0..<(T.maxMicHeals + 3) {
            h.listener.onEvent?(.engineStopped)
            h.scheduler.advance(by: T.sentinelTick * Double(T.micWarmupTicks + 1) + 0.01)
            await settle()
        }
        XCTAssertEqual(h.vm.micHealCount, 0)
        XCTAssertTrue(h.shortcuts.runs.isEmpty)
    }

    // MARK: "Yeniden hazır" anonsu döngüsü

    func testReadyAnnouncementIsMutedAfterRepeatedRecoveriesWithoutAWord() async {
        let h = makeHarness()
        _ = await h.startListening()
        h.vm.resumesWithoutSpeech = T.maxSilentResumes
        let spoken = h.speaker.spoken.count
        await h.vm.resumeAfterRecovery()
        XCTAssertEqual(h.speaker.spoken.count, spoken, "Aynı anons tekrar tekrar söylenmez")
        XCTAssertEqual(h.vm.phase, .listening, "Dinleme sessizce yeniden açılır")
    }

    func testAWordCounterResetsTheLoopBreaker() async {
        let h = makeHarness()
        _ = await h.startListening()
        h.vm.resumesWithoutSpeech = 2
        h.listener.say("Türkiye")
        XCTAssertEqual(h.vm.resumesWithoutSpeech, 0)
    }

    // MARK: Konuşma tanıma geri çekilmesi (saf yardımcılar)

    func testRecognizerRestartDelayGrowsThenStaysBounded() {
        let delays = (0...12).map { OnDeviceSpeechListener.restartDelay(afterFailures: $0) }
        XCTAssertEqual(Array(delays[0...2]), [0, 0, 0], "İlk hatalarda hemen yeniden denenir")
        XCTAssertEqual(Array(delays[3...5]), [1, 2, 3])
        XCTAssertEqual(delays[12], 5)
        XCTAssertLessThanOrEqual(delays.max() ?? 0, 5)
    }

    func testRecognizerGivesUpOnlyAfterALongStreakAndDropsTheEnglishHelperEarly() {
        XCTAssertGreaterThanOrEqual(OnDeviceSpeechListener.maxTurkishFailures, 10)
        XCTAssertLessThanOrEqual(OnDeviceSpeechListener.suspendEnglishAfter, 3)
    }

    // MARK: Hazır kestirme adları

    func testPresetShortcutNamesAreWrittenOnceAndCanBeChangedOrCleared() {
        let defaults = UserDefaults(suiteName: "g526.testler.\(UUID().uuidString)")!
        let s = AppSettings(defaults: defaults)
        XCTAssertEqual(s.wifiShortcut, "", "Ayarlar kendiliğinden dolmaz; ön ayar uygulama başında bir kez yazılır")
        s.applyShortcutPresetOnce()
        XCTAssertEqual(s.wifiShortcut, "Wifi")
        XCTAssertEqual(s.cellularShortcut, "Hücresel Veri")
        XCTAssertEqual(s.bluetoothShortcut, "Bluetooth")
        XCTAssertEqual(s.resetShortcut, "Sistemi Sıfırla")
        XCTAssertEqual(s.outputShortcut, "Kulaklık Düzeltme")
        XCTAssertTrue(s.missingShortcuts.isEmpty)
        // Kullanıcı değiştirir, bir tanesini siler: sonraki açılışta geri yazılmaz
        s.wifiShortcut = "Kendi Wifi"
        s.outputShortcut = ""
        let again = AppSettings(defaults: defaults)
        again.applyShortcutPresetOnce()
        XCTAssertEqual(again.wifiShortcut, "Kendi Wifi")
        XCTAssertEqual(again.outputShortcut, "")
        XCTAssertEqual(again.cellularShortcut, "Hücresel Veri")
    }
}
