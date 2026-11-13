import XCTest
@testable import G526CameraDrive

/// Oturumun ana akışı: açılış kontrolü, soru → cevap → dinleme döngüsü, hata durumları
@MainActor
final class SessionFlowTests: XCTestCase {
    // MARK: Modül 1: açılış kontrolü

    func testStartAnnouncesReadyThenListens() async {
        let h = SessionHarness()
        let listening = await h.startListening()
        XCTAssertTrue(listening)
        XCTAssertEqual(h.speaker.spoken.first, Say.ready)
        XCTAssertNil(h.speaker.calls.first?.saveAs, "Anons kaydedilmez")
        XCTAssertEqual(h.listener.startCalls, 1)
        XCTAssertEqual(h.network.startCalls, 1)
        XCTAssertGreaterThanOrEqual(h.route.configureCalls, 1)
        XCTAssertEqual(h.screen.states.last, true, "Oturum boyunca ekran açık kalır")
        XCTAssertTrue(h.vm.checkup.allSatisfy { $0.ok })
        XCTAssertTrue(h.vm.warnings.isEmpty)
        XCTAssertNotNil(h.vm.sessionFolder)
    }

    func testReadySentenceMatchesSpecification() {
        XCTAssertEqual(Say.ready, "Ben hazırım, sistem kontrol edildi ve problem yok, şimdi ilk soruyu okumanı bekliyorum.")
        XCTAssertEqual(Say.recovered, "Bağlantı sorunu giderildi ve sistem yeniden hazır. Lütfen en son kaldığın soruyu tekrar oku.")
    }

    func testStartWithoutHeadphonesStaysSilentUntilTheyReturn() async {
        let h = SessionHarness()
        h.route.current = FakeRoute.noHeadphones
        h.vm.start()
        let paused = await waitUntil { h.isHardwarePause }
        XCTAssertTrue(paused)
        XCTAssertTrue(h.speaker.calls.isEmpty, "Kulaklık yokken hiçbir şey söylenmez")
        XCTAssertEqual(h.listener.startCalls, 0)

        h.route.change(to: FakeRoute.good)
        h.scheduler.advance(by: SessionViewModel.Timing.routeStable + 0.1)
        let listening = await waitUntil { h.vm.phase == .listening }
        XCTAssertTrue(listening)
        XCTAssertEqual(h.speaker.spoken.first, Say.ready, "Donanım gelince açılış kontrolü baştan yapılıp anons edilir")
    }

    func testStartWithoutMicrophoneAlsoWaits() async {
        let h = SessionHarness()
        h.route.current = FakeRoute.noMic
        h.vm.start()
        let paused = await waitUntil { h.isHardwarePause }
        XCTAssertTrue(paused)
        XCTAssertFalse(h.vm.checkup.first(where: { $0.id == "mikrofon" })?.ok ?? true)
    }

    func testMissingOnDeviceDictationStopsStart() async {
        let h = SessionHarness()
        h.permissions.result = PermissionResult(microphone: true, speech: true, onDeviceSpeech: false)
        h.vm.start()
        let stopped = await waitUntil { h.vm.phase == .idle && !h.vm.warnings.isEmpty }
        XCTAssertTrue(stopped)
        XCTAssertEqual(h.vm.warnings.first?.text, Say.noOnDevice)
        XCTAssertEqual(h.listener.startCalls, 0)
        XCTAssertEqual(h.screen.states.last, false)
    }

    func testDeniedPermissionStopsStart() async {
        let h = SessionHarness()
        h.permissions.result = PermissionResult(microphone: false, speech: true, onDeviceSpeech: true)
        h.vm.start()
        let stopped = await waitUntil { h.vm.phase == .idle && !h.vm.warnings.isEmpty }
        XCTAssertTrue(stopped)
        XCTAssertEqual(h.vm.warnings.first?.text, Say.permissionDenied)
    }

    func testRejectedKeyStopsStartAndSaysSo() async {
        let h = SessionHarness()
        h.health.geminiResult = .keyRejected("Anahtar geçersiz.")
        h.vm.start()
        let stopped = await waitUntil { h.vm.phase == .idle && !h.vm.warnings.isEmpty }
        XCTAssertTrue(stopped)
        XCTAssertEqual(h.vm.warnings.first?.text, "Anahtar geçersiz.")
        XCTAssertTrue(h.speaker.spoken.first?.hasPrefix("Kontrol başarısız") ?? false)
    }

    func testNoInternetAtStartIsFixedByWifiShortcutThenAnnouncesReady() async {
        let h = SessionHarness()
        h.health.internet = false
        h.shortcuts.onRun = { name in if name == "WiFi_Ac" { h.health.internet = true } }
        let listening = await h.startListening()
        XCTAssertTrue(listening)
        XCTAssertEqual(h.shortcuts.runs, ["WiFi_Ac"])
        XCTAssertEqual(h.speaker.spoken, [Say.ready], "Açılışta onarım sonrası da 'hazırım' anonsu söylenir")
    }

    func testHandleURLStartsSessionAndRoutesShortcutCallbacks() async {
        let h = SessionHarness()
        h.vm.handleURL(URL(string: "seslikontrol://basla")!)
        let listening = await waitUntil { h.vm.phase == .listening }
        XCTAssertTrue(listening)
        h.vm.handleURL(URL(string: "seslikontrol://kestirme/ok")!)
        XCTAssertEqual(h.shortcuts.callbacks.count, 1)
    }

    func testStartIgnoredWhileRunning() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.vm.start()
        await settle()
        XCTAssertEqual(h.listener.startCalls, 1)
        XCTAssertEqual(h.speaker.spoken, [Say.ready])
    }

    // MARK: Modül 3 ve 5: soru → cevap → dinleme

    func testQuestionIsSentTrimmedAnsweredSpokenAndSaved() async {
        let h = SessionHarness()
        h.answering.results = [.success(FakeAnswering.reply(1))]
        _ = await h.startListening()
        h.ask("Soru bir. A seçeneği Adana")
        let done = await waitUntil { h.vm.answers.count == 1 && h.vm.phase == .listening }
        XCTAssertTrue(done)

        XCTAssertEqual(h.answering.calls.count, 1)
        XCTAssertEqual(h.answering.calls[0].question, "Soru bir. A seçeneği Adana", "Tetikleyici kırpılır")
        XCTAssertEqual(h.answering.calls[0].expectedNumber, 1)
        XCTAssertEqual(h.answering.calls[0].audio, h.recorder.data, "Soru sesi de gönderilir")
        XCTAssertGreaterThanOrEqual(h.listener.pauseCalls, 1, "Gönderirken mikrofon duraklar")

        XCTAssertEqual(h.speaker.spoken.last, "Soru 1, Denizli, Örgütsel Davranış")
        XCTAssertEqual(h.speaker.calls.last?.saveAs?.lastPathComponent, "soru_1")
        XCTAssertEqual(h.listener.startCalls, 2, "Cevaptan sonra mikrofon yeniden açılır")
        XCTAssertTrue(h.vm.canReplay)

        let folder = h.vm.sessionFolder!
        let transcript = try? String(contentsOf: folder.appendingPathComponent("cevaplar.txt"))
        XCTAssertEqual(transcript, "Soru 1, Denizli, Örgütsel Davranış\n")
    }

    func testAudioIsOmittedWhenSettingIsOff() async {
        let h = SessionHarness()
        h.settings.sendAudio = false
        h.answering.results = [.success(FakeAnswering.reply(1))]
        _ = await h.startListening()
        h.ask("Soru bir")
        let done = await waitUntil { h.answering.calls.count == 1 }
        XCTAssertTrue(done)
        XCTAssertNil(h.answering.calls[0].audio)
    }

    func testEachQuestionIsSentSeparatelyWithNextNumber() async {
        let h = SessionHarness()
        h.answering.results = [.success(FakeAnswering.reply(1)), .success(FakeAnswering.reply(2, option: "Bursa", text: "Pazarlama"))]
        _ = await h.startListening()
        h.ask("Birinci soru")
        var done = await waitUntil { h.vm.answers.count == 1 && h.vm.phase == .listening }
        XCTAssertTrue(done)
        h.ask("İkinci soru")
        done = await waitUntil { h.vm.answers.count == 2 && h.vm.phase == .listening }
        XCTAssertTrue(done)

        XCTAssertEqual(h.answering.calls.map { $0.question }, ["Birinci soru", "İkinci soru"], "Sorular karışmadan ayrı ayrı gider")
        XCTAssertEqual(h.answering.calls.map { $0.expectedNumber }, [1, 2])
        XCTAssertEqual(h.vm.answers.map { $0.number }, [1, 2])
        XCTAssertEqual(h.speaker.calls.compactMap { $0.saveAs?.lastPathComponent }, ["soru_1", "soru_2"])
        let files = h.vm.deps.library.answerFiles(in: h.vm.sessionFolder!)
        XCTAssertEqual(files.map { $0.lastPathComponent }, ["soru_1.m4a", "soru_2.m4a"])
    }

    func testNumberReadByGeminiAdvancesTheCounter() async {
        let h = SessionHarness()
        h.answering.results = [.success(FakeAnswering.reply(5)), .success(FakeAnswering.reply(6))]
        _ = await h.startListening()
        h.ask("Beşinci soru")
        _ = await waitUntil { h.vm.answers.count == 1 && h.vm.phase == .listening }
        h.ask("Altıncı soru")
        _ = await waitUntil { h.answering.calls.count == 2 }
        XCTAssertEqual(h.answering.calls.map { $0.expectedNumber }, [1, 6])
    }

    func testBareTriggerWordSendsNothing() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.listener.say("Cevapla")
        h.scheduler.advance(by: 1)
        await settle()
        XCTAssertTrue(h.answering.calls.isEmpty)
        XCTAssertEqual(h.vm.phase, .listening)
    }

    func testTriggerInTheMiddleOfTheTextDoesNotFire() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.listener.say("bu soru gönder ile ilgili")
        h.scheduler.advance(by: 1)
        await settle()
        XCTAssertTrue(h.answering.calls.isEmpty)
        XCTAssertEqual(h.vm.phase, .listening)
    }

    func testTriggerNeedsToStayStable() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.listener.say("bir soru gönder")
        h.scheduler.advance(by: 0.2)
        h.listener.say("bir soru gönderi hakkında")   // tanıyıcı sözcüğü düzeltti: tetikleyici artık son sözcük değil
        h.scheduler.advance(by: 2)
        await settle()
        XCTAssertTrue(h.answering.calls.isEmpty)
    }

    func testDictationRestartKeepsEarlierText() async {
        let h = SessionHarness()
        h.answering.results = [.success(FakeAnswering.reply(1))]
        _ = await h.startListening()
        h.listener.say("birinci bölüm şu kadar uzun bir metin")
        h.listener.onEvent?(.taskEnded)   // tanıma görevi bitti, yenisi başladı: yeni görevin metni baştan başlar
        h.ask("ikinci bölüm devamı")
        _ = await waitUntil { h.answering.calls.count == 1 }
        XCTAssertEqual(h.answering.calls.first?.question, "birinci bölüm şu kadar uzun bir metin ikinci bölüm devamı")
    }

    func testGeminiFailureIsSpokenAndListeningResumes() async {
        let h = SessionHarness()
        h.answering.results = [.failure(GeminiError("Kota doldu", .quota))]
        _ = await h.startListening()
        h.ask("Bir soru")
        let done = await waitUntil { h.speaker.spoken.contains(Say.geminiFailure(GeminiError("", .quota))) && h.vm.phase == .listening }
        XCTAssertTrue(done)
        XCTAssertTrue(h.vm.warnings.contains { $0.id == "cevap" })
        XCTAssertTrue(h.vm.answers.isEmpty)
    }

    // MARK: Modül 2: fail-safe

    func testRouteLossMutesAndPausesEverything() async {
        let h = SessionHarness()
        h.answering.results = [.success(FakeAnswering.reply(1))]
        _ = await h.startListening()
        let stopsBefore = h.speaker.stopCalls
        h.route.change(to: FakeRoute.noHeadphones)
        XCTAssertTrue(h.isHardwarePause)
        XCTAssertGreaterThan(h.speaker.stopCalls, stopsBefore, "Ses anında kesilir")
        XCTAssertFalse(h.listener.isRunning, "Mikrofon kapanır")
        XCTAssertTrue(h.vm.warnings.contains { $0.id == "donanim" })

        // Duraklatıldığı sürece konuşulanlar işlenmez
        h.ask("Bu soru gitmemeli")
        await settle()
        XCTAssertTrue(h.answering.calls.isEmpty)
    }

    func testMicrophoneLossAlsoPauses() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.route.change(to: FakeRoute.noMic)
        XCTAssertTrue(h.isHardwarePause)
    }

    func testRouteReturnResumesWithAnnouncementAfterItStaysStable() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.route.change(to: FakeRoute.noHeadphones)
        h.route.change(to: FakeRoute.good)
        h.route.change(to: FakeRoute.noHeadphones)   // dalgalanma: sabit kalmadı
        h.scheduler.advance(by: 5)
        XCTAssertTrue(h.isHardwarePause, "Sabit kalmayan yol devam ettirmez")

        h.route.change(to: FakeRoute.good)
        h.scheduler.advance(by: SessionViewModel.Timing.routeStable + 0.1)
        let listening = await waitUntil { h.vm.phase == .listening }
        XCTAssertTrue(listening)
        XCTAssertEqual(h.speaker.spoken.last, Say.recovered)
        XCTAssertFalse(h.vm.warnings.contains { $0.id == "donanim" })
    }

    func testHardwareStaysLostRunsResetShortcutAndRecovers() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.route.change(to: FakeRoute.noHeadphones)
        h.shortcuts.onRun = { _ in h.route.current = FakeRoute.good }   // sıfırlama kestirmesi sorunu giderir
        h.scheduler.advance(by: SessionViewModel.Timing.hardwareGrace + 0.1)
        let listening = await waitUntil { h.vm.phase == .listening && h.speaker.spoken.last == Say.recovered }
        XCTAssertTrue(listening)
        XCTAssertEqual(h.shortcuts.runs, ["Bluetooth_Yenile"], "Kulaklık koptuysa önce hafif Bluetooth yenileme; işe yararsa sıfırlama çalışmaz")
    }

    func testSpeakerRefusingUnsafeRoutePausesInsteadOfPlaying() async {
        let h = SessionHarness()
        h.answering.results = [.success(FakeAnswering.reply(1))]
        h.speaker.script = [nil, SpeakError.routeUnsafe]   // anons tamam, cevap okunurken yol güvensiz
        _ = await h.startListening()
        h.ask("Bir soru")
        let paused = await waitUntil { h.isHardwarePause }
        XCTAssertTrue(paused)
        XCTAssertEqual(h.vm.answers.count, 1, "Cevap alındı ve kaydedildi, yalnız çalınmadı")
    }

    // MARK: Modül 4: kendi kendini onarma

    func testSilenceWithLiveMicrophoneOnlyRestartsListening() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.scheduler.advance(by: SilenceWatchdog.limit + 0.1)
        let restarted = await waitUntil { h.listener.startCalls == 2 && h.vm.watchdog.isArmed }
        XCTAssertTrue(restarted)
        XCTAssertTrue(h.shortcuts.runs.isEmpty, "Mikrofon canlıysa kestirme çalıştırılmaz")
        XCTAssertEqual(h.vm.phase, .listening)
    }

    func testSilenceWithDeadMicrophoneRunsResetShortcut() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.listener.secondsSinceAudio = nil   // mikrofondan hiç ses gelmiyor
        h.shortcuts.onRun = { _ in h.listener.secondsSinceAudio = 0.1 }
        h.scheduler.advance(by: SilenceWatchdog.limit + 0.1)
        let done = await waitUntil { h.speaker.spoken.last == Say.recovered && h.vm.phase == .listening }
        XCTAssertTrue(done)
        XCTAssertEqual(h.shortcuts.runs, ["Sistemi_Sifirla"])
    }

    func testEveryWordRestartsTheSilenceClock() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.scheduler.advance(by: 20)
        h.listener.say("bir iki üç")
        h.scheduler.advance(by: 20)   // toplam 40 sn ama son sözcükten beri 20
        await settle()
        XCTAssertEqual(h.listener.startCalls, 1)
        XCTAssertTrue(h.shortcuts.runs.isEmpty)
    }

    func testNetworkLossRunsShortcutsInOrderThenAnnouncesRecovery() async {
        let h = SessionHarness()
        _ = await h.startListening()
        let geminiCallsBefore = h.health.geminiCalls
        h.health.internet = false
        h.shortcuts.onRun = { name in
            if name == "Hücresel_Ac" {
                h.health.internet = true
                h.network.isOnline = true
            }
        }
        h.network.set(online: false)
        h.scheduler.advance(by: SessionViewModel.Timing.offlineDebounce + 0.1)
        let done = await waitUntil { h.speaker.spoken.last == Say.recovered && h.vm.phase == .listening }
        XCTAssertTrue(done)
        XCTAssertEqual(h.shortcuts.runs, ["WiFi_Ac", "Hücresel_Ac"], "Önce Wi-Fi, sonra hücresel; düzelince durur")
        XCTAssertGreaterThan(h.health.geminiCalls, geminiCallsBefore, "Düzeldiğini Gemini'ye de ping atarak doğrular")
    }

    func testShortNetworkBlipIsIgnored() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.network.set(online: false)
        h.scheduler.advance(by: 1)
        h.network.set(online: true)
        h.scheduler.advance(by: 10)
        await settle()
        XCTAssertTrue(h.shortcuts.runs.isEmpty)
        XCTAssertEqual(h.vm.phase, .listening)
    }

    func testDroppedGeminiRequestTriggersRecoveryAndAsksToRepeat() async {
        let h = SessionHarness()
        h.answering.results = [.failure(GeminiError("Bağlantı koptu", .network))]
        _ = await h.startListening()
        h.health.internet = false
        h.shortcuts.onRun = { name in if name == "WiFi_Ac" { h.health.internet = true } }
        h.ask("Bir soru")
        let done = await waitUntil { h.speaker.spoken.last == Say.recovered && h.vm.phase == .listening }
        XCTAssertTrue(done)
        XCTAssertEqual(h.shortcuts.runs, ["WiFi_Ac"])
        XCTAssertTrue(h.vm.answers.isEmpty)
        XCTAssertTrue(h.vm.liveText.isEmpty, "Soru baştan okunacak")
    }

    func testFailedRecoveryPausesRetriesAndResumesWhenOnlineAgain() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.health.internet = false
        h.network.set(online: false)
        h.scheduler.advance(by: SessionViewModel.Timing.offlineDebounce + 0.1)
        let paused = await waitUntil { h.isConnectionPause }
        XCTAssertTrue(paused)
        XCTAssertEqual(h.shortcuts.runs, ["WiFi_Ac", "Hücresel_Ac", "Sistemi_Sifirla"])
        XCTAssertTrue(h.vm.warnings.contains { $0.id == "onarim" })

        // Bir dakika sonra yeniden dener
        h.scheduler.advance(by: SessionViewModel.Timing.connectionRetry + 0.1)
        let retried = await waitUntil { h.shortcuts.runs.count == 6 }
        XCTAssertTrue(retried)
        await settle()
        XCTAssertTrue(h.isConnectionPause)

        // İnternet kendiliğinden gelirse devam eder
        h.health.internet = true
        h.network.set(online: true)
        let listening = await waitUntil { h.vm.phase == .listening && h.speaker.spoken.last == Say.recovered }
        XCTAssertTrue(listening)
        XCTAssertFalse(h.vm.warnings.contains { $0.id == "onarim" })
    }

    func testEmptyShortcutNamesAreReportedNotRun() async {
        let h = SessionHarness(shortcutNames: false)
        _ = await h.startListening()
        h.health.internet = false
        h.network.set(online: false)
        h.scheduler.advance(by: SessionViewModel.Timing.offlineDebounce + 0.1)
        let paused = await waitUntil { h.isConnectionPause }
        XCTAssertTrue(paused)
        XCTAssertTrue(h.shortcuts.runs.isEmpty)
        XCTAssertEqual(h.vm.warnings.first(where: { $0.id == "onarim" })?.text, Say.notConfigured)
    }

    func testListenerFailureTriggersHardwareRecovery() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.listener.onEvent?(.failure("Mikrofon durdu"))
        let done = await waitUntil { h.speaker.spoken.last == Say.recovered && h.vm.phase == .listening }
        XCTAssertTrue(done)
        XCTAssertEqual(h.shortcuts.runs, ["Sistemi_Sifirla"])
        XCTAssertEqual(h.listener.startCalls, 2, "Onarımdan sonra mikrofon yeniden açılır")
    }

    // MARK: Modül 6: test sonu

    func testEndTestStopsEverythingAndEnablesReplay() async {
        let h = SessionHarness()
        h.answering.results = [.success(FakeAnswering.reply(1))]
        _ = await h.startListening()
        h.ask("Bir soru")
        _ = await waitUntil { h.vm.answers.count == 1 && h.vm.phase == .listening }
        h.vm.endTest()
        XCTAssertEqual(h.vm.phase, .finished)
        XCTAssertFalse(h.listener.isRunning)
        XCTAssertGreaterThanOrEqual(h.network.stopCalls, 1, "Tekrar öncesi ağ izleme kapanır")
        XCTAssertEqual(h.screen.states.last, false)
        XCTAssertTrue(h.vm.canReplay)
    }

    func testReplayPlaysSavedFilesInOrderWithConfiguredGapAndStaysOffline() async {
        let h = SessionHarness()
        h.settings.replayGap = 3
        h.answering.results = [.success(FakeAnswering.reply(1)), .success(FakeAnswering.reply(2)), .success(FakeAnswering.reply(3))]
        _ = await h.startListening()
        for number in 1...3 {
            h.ask("Soru \(number)")
            _ = await waitUntil { h.vm.answers.count == number && h.vm.phase == .listening }
        }
        h.vm.endTest()
        let startsBefore = h.network.startCalls
        let micStartsBefore = h.listener.startCalls

        h.vm.startReplay()
        XCTAssertEqual(h.vm.phase, .replaying)
        XCTAssertEqual(h.player.played.map { $0.lastPathComponent }, ["soru_1.m4a"])
        h.player.finish()
        XCTAssertEqual(h.scheduler.requested.last, 3)
        h.scheduler.advance(by: 2.9)
        XCTAssertEqual(h.player.played.count, 1, "Boşluk dolmadan sıradaki çalmaz")
        h.scheduler.advance(by: 0.2)
        XCTAssertEqual(h.player.played.map { $0.lastPathComponent }, ["soru_1.m4a", "soru_2.m4a"])
        h.player.finish()
        h.scheduler.advance(by: 3)
        XCTAssertEqual(h.player.played.count, 3)
        h.player.finish()

        XCTAssertEqual(h.vm.phase, .finished)
        XCTAssertEqual(h.vm.statusNote, "Tekrar bitti.")
        XCTAssertEqual(h.network.startCalls, startsBefore, "Tekrar sırasında ağ izlenmez/kullanılmaz")
        XCTAssertEqual(h.listener.startCalls, micStartsBefore, "Tekrar sırasında mikrofon açılmaz")
        XCTAssertEqual(h.answering.calls.count, 3)
    }

    func testReplayRefusesWithoutHeadphones() async {
        let h = SessionHarness()
        h.answering.results = [.success(FakeAnswering.reply(1))]
        _ = await h.startListening()
        h.ask("Bir soru")
        _ = await waitUntil { h.vm.answers.count == 1 && h.vm.phase == .listening }
        h.vm.endTest()
        h.route.current = FakeRoute.noHeadphones
        h.vm.startReplay()
        XCTAssertEqual(h.vm.phase, .finished)
        XCTAssertTrue(h.player.played.isEmpty)
        XCTAssertTrue(h.vm.warnings.contains { $0.id == "tekrar" })
    }

    func testReplayWithNothingSavedSaysSo() async {
        let h = SessionHarness()
        h.vm.startReplay()
        XCTAssertTrue(h.player.played.isEmpty)
        XCTAssertEqual(h.vm.warnings.first(where: { $0.id == "tekrar" })?.text, Say.nothingToReplay)
        XCTAssertEqual(h.vm.phase, .idle)
    }

    func testLosingHeadphonesDuringReplayStopsIt() async {
        let h = SessionHarness()
        h.answering.results = [.success(FakeAnswering.reply(1)), .success(FakeAnswering.reply(2))]
        _ = await h.startListening()
        for number in 1...2 {
            h.ask("Soru \(number)")
            _ = await waitUntil { h.vm.answers.count == number && h.vm.phase == .listening }
        }
        h.vm.endTest()
        h.vm.startReplay()
        h.route.change(to: FakeRoute.noHeadphones)
        XCTAssertEqual(h.vm.phase, .finished)
        XCTAssertEqual(h.vm.statusNote, Say.noHeadphonesForReplay)
        h.scheduler.advance(by: 20)
        XCTAssertEqual(h.player.played.count, 1)
    }
}
