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
        // Bekleme süresi (hardwareCapRetry) dolmadan: nabız ve yol yoklamaları defalarca çalışır, duraklama bozulmaz
        let ticks = Int(T.hardwareCapRetry / 2) - 3
        for _ in 0..<ticks {
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
        let noted = await waitUntil { h.vm.netProbeSlow }
        XCTAssertTrue(noted, "Yanlış alarm anlaşıldı: nabız tam yoklamaya geçti")
        XCTAssertEqual(h.vm.phase, .listening, "Dinleme hiç kesilmedi")
        XCTAssertTrue(h.shortcuts.runs.isEmpty)
        XCTAssertEqual(h.speaker.spoken.count, spoken, "Hiçbir anons yapılmadı")
        XCTAssertEqual(h.vm.liveText, "Türkiye'nin başkenti", "Yarım okunan soru silinmedi")
        XCTAssertEqual(h.vm.netPulse, .up)
    }

    func testAFalseAlarmNeverMutesTheHeartbeatItSwitchesToTheFullProbe() async {
        let h = makeHarness()
        _ = await h.startListening()
        await missTwoBeats(h)
        let slow = await waitUntil { h.vm.netProbeSlow }
        XCTAssertTrue(slow)
        // Susturma yok: sonraki nabızlar çalışmaya devam eder, yalnız hızlı yoklama yerine tam internet yoklaması kullanılır
        let quick = h.health.quickCalls
        let full = h.health.internetCalls
        h.scheduler.advance(by: Double(T.netBeatEvery) * T.sentinelTick + 0.01)
        await settle()
        h.scheduler.advance(by: Double(T.netBeatEvery) * T.sentinelTick + 0.01)
        await settle()
        XCTAssertEqual(h.health.quickCalls, quick, "Hızlı yoklama artık kullanılmaz")
        XCTAssertGreaterThanOrEqual(h.health.internetCalls, full + 2, "Nabız susmadı, tam yoklamayla bakıyor")
        XCTAssertEqual(h.vm.phase, .listening)
    }

    func testARealLossIsStillCaughtAfterTheSwitchToTheFullProbe() async {
        let h = makeHarness()
        _ = await h.startListening()
        await missTwoBeats(h)
        _ = await waitUntil { h.vm.netProbeSlow }
        h.health.internet = false
        h.scheduler.advance(by: Double(T.netBeatEvery) * T.sentinelTick + 0.01)
        await settle()
        h.scheduler.advance(by: Double(T.netRetryTicks) * T.sentinelTick + 0.01)
        await settle()
        let ran = await waitUntil { h.shortcuts.runs.first == "WiFi_Ac" }
        XCTAssertTrue(ran, "Gerçek kopma susturulmadan, nabızla yakalanır")
    }

    func testRealInternetLossStillStartsTheRepair() async {
        let h = makeHarness()
        _ = await h.startListening()
        h.health.internet = false
        await missTwoBeats(h)
        let ran = await waitUntil { h.shortcuts.runs.first == "WiFi_Ac" }
        XCTAssertTrue(ran, "Gerçek kopmada onarım gecikmeden başlar")
        XCTAssertFalse(h.vm.netProbeSlow, "Gerçek kopma yanlış alarm sayılmaz")
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

    // MARK: Konuşma tanıma düşerse: gerçek onarım

    func testRecognizerDownWithAHealthyRouteRepairsTheRecognizerAndSaysReadyOnlyAfterProof() async {
        let h = makeHarness()
        _ = await h.startListening()
        let starts = h.listener.startCalls
        h.listener.onEvent?(.recognizerDown(message: "kAFAssistantErrorDomain 1101: bağlantı", permanent: false))
        let back = await waitUntil { h.vm.phase == .listening && h.speaker.spoken.last == Say.recoveredShort }
        XCTAssertTrue(back, "Onarılınca tek bir 'hazır' söylenir ve dinlemeye dönülür")
        XCTAssertTrue(h.speaker.spoken.contains(Say.recognizerRestarting), "Önce ne olduğu söylenir; sessizlik kesinti sanılmasın")
        XCTAssertTrue(h.shortcuts.runs.isEmpty, "Ses yolu sağlam: Bluetooth/uçak modu Kestirmeleri çalışmaz")
        XCTAssertFalse(h.speaker.allCalls.map { $0.text }.contains(Say.hardwareRepairing), "Kulaklık ya da mikrofon suçlanmaz")
        XCTAssertGreaterThanOrEqual(h.listener.startCalls, starts + 2, "Biri kanıt için, biri asıl dinleme için")
        XCTAssertEqual(h.speaker.spoken.filter { $0 == Say.recoveredShort }.count, 1)
    }

    func testIfListeningCannotBeProvenTheReadyCueIsNotSpokenAndTheRealStateIsTold() async {
        let h = makeHarness()
        _ = await h.startListening()
        h.listener.recognitionStreak = 2   // tanıyıcı yeniden kurulsa da görevler hemen düşüyor
        h.listener.onEvent?(.recognizerDown(message: "x", permanent: false))
        let stuck = await waitUntil { h.isHardwarePause && h.vm.holdForRetry }
        XCTAssertTrue(stuck)
        XCTAssertFalse(h.speaker.spoken.contains(Say.recoveredShort), "Kanıtlanmadan 'hazır' denmez")
        XCTAssertEqual(h.vm.warnings.first { $0.id == "mikrofon" }?.text, Say.recognizerStuck, "Gerçek durum söylenir")
        XCTAssertTrue(h.shortcuts.runs.isEmpty)
        // Sessiz bekleme yok: 15 sn sonra yeniden denenir; bu sefer tanıma sağlam
        h.listener.recognitionStreak = 0
        h.scheduler.advance(by: T.recognizerRetry + 0.1)
        let back = await waitUntil { h.vm.phase == .listening && h.speaker.spoken.last == Say.recoveredShort }
        XCTAssertTrue(back)
        XCTAssertEqual(h.speaker.spoken.filter { $0 == Say.recognizerRestarting }.count, 1, "Yeniden denemede anons tekrarlanmaz")
    }

    func testHeartbeatDoesNotUndoTheWaitBetweenRecognizerRetries() async {
        let h = makeHarness()
        _ = await h.startListening()
        h.listener.recognitionStreak = 2
        h.listener.onEvent?(.recognizerDown(message: "x", permanent: false))
        _ = await waitUntil { h.isHardwarePause && h.vm.holdForRetry }
        let spoken = h.speaker.spoken.count
        for _ in 0..<10 {
            h.scheduler.advance(by: 1)
            await settle()
        }
        XCTAssertTrue(h.isHardwarePause, "Ses yolu sağlam görünse de nabız beklemeyi bozmaz")
        XCTAssertEqual(h.speaker.spoken.count, spoken)
    }

    func testPermanentRecognizerFaultStopsTheSessionWithTheRealReason() async {
        let h = makeHarness()
        _ = await h.startListening()
        h.listener.onEvent?(.recognizerDown(message: Say.dictationOff, permanent: true))
        XCTAssertEqual(h.vm.phase, .idle, "Yeniden denemek işe yaramaz")
        XCTAssertEqual(h.vm.warnings.first { $0.id == "durdu" }?.text, Say.dictationOff, "Ne yapılacağı söylenir")
        XCTAssertTrue(h.shortcuts.runs.isEmpty)
    }

    func testRecognizerDownWithABrokenRouteStillUsesTheHardwareRepair() async {
        let h = makeHarness()
        _ = await h.startListening()
        h.route.current = FakeRoute.noMic
        h.listener.onEvent?(.recognizerDown(message: "x", permanent: false))
        let ran = await waitUntil { !h.shortcuts.runs.isEmpty || h.isHardwarePause }
        XCTAssertTrue(ran)
    }

    func testRecognizedWordResetsTheRepairCounter() async {
        let h = makeHarness()
        _ = await h.startListening()
        h.vm.recognizerRepairs = 3
        h.listener.say("Türkiye")
        XCTAssertEqual(h.vm.recognizerRepairs, 0)
    }

    // MARK: Konuşma tanıma basamakları (saf yardımcılar)

    func testApplesFaultCodesAreClassified() {
        XCTAssertEqual(RecognitionFault.classify(domain: "kLSRErrorDomain", code: 201), .permanent(Say.dictationOff))
        XCTAssertEqual(RecognitionFault.classify(domain: "kLSRErrorDomain", code: 102), .permanent(Say.noOnDevice))
        XCTAssertEqual(RecognitionFault.classify(domain: "kLSRErrorDomain", code: 300), .transient)
        XCTAssertEqual(RecognitionFault.classify(domain: "kAFAssistantErrorDomain", code: 1101), .transient)
        XCTAssertEqual(RecognitionFault.classify(domain: "kAFAssistantErrorDomain", code: 1110), .transient)
        XCTAssertEqual(RecognitionFault.classify(domain: "kAFAssistantErrorDomain", code: 201), .transient, "Başka alan adındaki 201 kalıcı sayılmaz")
    }

    func testRecognizerRestartDelayIsShortAndBounded() {
        let delays = (0...12).map { OnDeviceSpeechListener.restartDelay(afterFailures: $0) }
        XCTAssertEqual(Array(delays[0...2]), [0, 0, 0], "İlk hatalarda hemen yeniden denenir")
        XCTAssertEqual(delays[3], 0.3)
        XCTAssertEqual(Array(delays[4...12]), Array(repeating: 1, count: 9))
    }

    func testRecognizerLadderRunsInOrderAndGivesUpQuickly() {
        typealias L = OnDeviceSpeechListener
        XCTAssertEqual(L.suspendEnglishAfter, 1, "Türkçe öncelikli: ilk çabuk hatada yardımcı İngilizce bırakılır")
        XCTAssertLessThan(L.suspendEnglishAfter, L.renewRecognizerAt)
        XCTAssertLessThan(L.renewRecognizerAt, L.rebuildEngineFrom)
        XCTAssertLessThan(L.rebuildEngineFrom, L.maxTurkishFailures)
        XCTAssertLessThanOrEqual(L.maxTurkishFailures, 6, "Basamaklar tükenince uzun süre sessiz denenmez; uygulama gerçek onarıma geçer")
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
