import XCTest
import AVFoundation
@testable import G526CameraDrive

/// Baştan sona mantık denetiminde bulunan hataların testleri
@MainActor
final class SessionAuditTests: XCTestCase {
    // MARK: Açılış duyurusu

    func testReadyAnnouncementCutByRouteLossRunsStartupAgainWithoutRecoveredMessage() async {
        let h = SessionHarness()
        h.speaker.script = [SpeakError.routeUnsafe]
        h.vm.start()
        let paused = await waitUntil { h.isHardwarePause }
        XCTAssertTrue(paused)
        XCTAssertEqual(h.listener.startCalls, 0)

        h.route.change(to: FakeRoute.good)
        h.scheduler.advance(by: SessionViewModel.Timing.routeStable + 0.1)
        let listening = await waitUntil { h.vm.phase == .listening }
        XCTAssertTrue(listening)
        XCTAssertEqual(h.speaker.spoken, [Say.ready, Say.ready], "Açılış kontrolü baştan yapılıp 'hazırım' yeniden söylenir")
    }

    func testAnnouncementThatCannotBeSpokenDoesNotFreezeTheSession() async {
        let h = SessionHarness()
        h.speaker.script = [SpeakError.failed("Ses okunamadı.")]
        let listening = await h.startListening()
        XCTAssertTrue(listening, "Okunamayan duyuru yüzünden oturum takılmamalı")
        XCTAssertTrue(h.vm.warnings.contains { $0.id == "ses" })
    }

    // MARK: Duyulmamış cevap

    func testAnswerNotHeardBecauseOfRouteLossIsSpokenAgainWhenHeadphonesReturn() async {
        let h = SessionHarness()
        h.answering.results = [.success(FakeAnswering.reply(1))]
        h.speaker.script = [nil, SpeakError.routeUnsafe, nil]   // anons tamam, cevap okunurken yol güvensiz, tekrar tamam
        _ = await h.startListening()
        h.ask("Bir soru")
        let paused = await waitUntil { h.isHardwarePause }
        XCTAssertTrue(paused)
        XCTAssertEqual(h.vm.answers.count, 1)

        h.route.change(to: FakeRoute.good)
        h.scheduler.advance(by: SessionViewModel.Timing.routeStable + 0.1)
        let listening = await waitUntil { h.vm.phase == .listening }
        XCTAssertTrue(listening)
        XCTAssertEqual(h.speaker.spoken.last, "Soru 1, Denizli, Örgütsel Davranış", "Cevap yeniden okunur, soru baştan okutulmaz")
        XCTAssertFalse(h.speaker.spoken.contains(Say.recovered))
        XCTAssertNil(h.vm.unheard)
    }

    func testWarningsFromAFailedAnswerClearAfterTheNextSuccess() async {
        let h = SessionHarness()
        h.answering.results = [.failure(GeminiError("Kota", .quota)), .success(FakeAnswering.reply(1))]
        _ = await h.startListening()
        h.ask("Birinci")
        var ok = await waitUntil { h.vm.phase == .listening && h.vm.warnings.contains { $0.id == "cevap" } }
        XCTAssertTrue(ok)
        h.ask("İkinci")
        ok = await waitUntil { h.vm.answers.count == 1 && h.vm.phase == .listening }
        XCTAssertTrue(ok)
        XCTAssertFalse(h.vm.warnings.contains { $0.id == "cevap" })
    }

    // MARK: Ses kesintisi (arama, alarm, Siri)

    func testInterruptionPausesWithoutResetShortcutAndResumesWhenItEnds() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.route.configureError = NSError(domain: "arama", code: 1)   // arama sürerken ses oturumu açılamaz
        h.route.interrupt(began: true)
        XCTAssertTrue(h.isHardwarePause)
        XCTAssertFalse(h.listener.isRunning)

        h.scheduler.advance(by: 1_000)
        await settle()
        XCTAssertTrue(h.shortcuts.runs.isEmpty, "Kesintide sıfırlama kestirmesi çalıştırılmaz (aramayı keserdi)")
        XCTAssertTrue(h.isHardwarePause)

        h.route.configureError = nil
        let configuredBefore = h.route.configureCalls
        h.route.interrupt(began: false)
        h.scheduler.advance(by: SessionViewModel.Timing.routeStable + 0.1)
        let listening = await waitUntil { h.vm.phase == .listening && h.speaker.spoken.last == Say.recovered }
        XCTAssertTrue(listening)
        XCTAssertGreaterThan(h.route.configureCalls, configuredBefore, "Kesintiden sonra ses oturumu yeniden etkinleştirilir")
    }

    func testInterruptionDuringReplayStopsIt() async {
        let h = SessionHarness()
        h.answering.results = [.success(FakeAnswering.reply(1))]
        _ = await h.startListening()
        h.ask("Bir soru")
        _ = await waitUntil { h.vm.answers.count == 1 && h.vm.phase == .listening }
        h.vm.endTest()
        h.vm.startReplay()
        h.route.interrupt(began: true)
        XCTAssertEqual(h.vm.phase, .finished)
        XCTAssertTrue(h.vm.statusNote.contains("Ses kesintisi"))
    }

    func testMissingEndNotificationIsCoveredByPollingTheAudioSession() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.route.configureError = NSError(domain: "arama", code: 1)
        h.route.interrupt(began: true)
        h.scheduler.advance(by: SessionViewModel.Timing.interruptionPoll + 0.1)
        await settle()
        XCTAssertTrue(h.isHardwarePause, "Ses oturumu hâlâ açılamıyor: kesinti sürüyor")

        h.route.configureError = nil   // arama bitti ama iOS bitiş bildirimi göndermedi
        h.scheduler.advance(by: SessionViewModel.Timing.interruptionPoll + 0.1)
        await settle()
        h.scheduler.advance(by: SessionViewModel.Timing.routeStable + 0.1)
        let listening = await waitUntil { h.vm.phase == .listening && h.speaker.spoken.last == Say.recovered }
        XCTAssertTrue(listening)
        XCTAssertTrue(h.shortcuts.runs.isEmpty)
    }

    func testRouteChangeDuringAnInterruptionDoesNotResumeEarly() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.route.configureError = NSError(domain: "arama", code: 1)
        h.route.interrupt(began: true)
        h.route.change(to: FakeRoute.good)
        h.scheduler.advance(by: SessionViewModel.Timing.routeStable + 0.1)
        await settle()
        XCTAssertTrue(h.isHardwarePause, "Kesinti bitmeden yol güvenli görünse de devam edilmez")
    }

    func testReturningToTheAppRechecksAPausedSession() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.route.interrupt(began: true)
        h.vm.recheckHardware()   // uygulama öne geldi, kesinti bitişi bildirilmemişti
        h.scheduler.advance(by: SessionViewModel.Timing.routeStable + 0.1)
        let listening = await waitUntil { h.vm.phase == .listening }
        XCTAssertTrue(listening)
    }

    // MARK: Onarım döngüsü sınırı

    func testRepeatedHardwareRecoveriesStopInsteadOfLoopingForever() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.listener.startErrors = Array(repeating: ListenerError.engine("açılamadı"), count: 50)
        h.listener.onEvent?(.failure("Mikrofon durdu"))
        let capped = await waitUntil { h.isHardwarePause }
        XCTAssertTrue(capped)
        XCTAssertEqual(h.shortcuts.runs.count, SessionViewModel.Timing.maxHardwareRecoveries,
                       "Mikrofon onarılmasına rağmen çalışmıyorsa uçak modu kestirmesi sonsuza dek tekrarlanmaz")
        XCTAssertTrue(h.vm.warnings.contains { $0.id == "onarim" })
    }

    func testRecognizedWordResetsTheRecoveryCounter() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.listener.onEvent?(.failure("Mikrofon durdu"))
        let recovered = await waitUntil { h.speaker.spoken.last == Say.recovered && h.vm.phase == .listening }
        XCTAssertTrue(recovered)
        XCTAssertEqual(h.vm.hardwareRecoveries, 1)
        h.listener.say("bir iki üç")
        XCTAssertEqual(h.vm.hardwareRecoveries, 0)
    }

    func testFailedHardwareRecoveryRetriesLessOften() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.route.change(to: FakeRoute.noHeadphones)
        h.scheduler.advance(by: SessionViewModel.Timing.hardwareGrace + 0.1)   // sıfırlama çalışır ama işe yaramaz
        let paused = await waitUntil { h.shortcuts.runs.count == 1 }
        XCTAssertTrue(paused)
        await settle()
        XCTAssertTrue(h.isHardwarePause)
        h.scheduler.advance(by: SessionViewModel.Timing.hardwareGrace + 0.1)
        await settle()
        XCTAssertEqual(h.shortcuts.runs.count, 1, "İkinci sıfırlama 20 sn sonra değil, daha seyrek denenir")
        h.scheduler.advance(by: SessionViewModel.Timing.connectionRetry)
        let again = await waitUntil { h.shortcuts.runs.count == 2 }
        XCTAssertTrue(again)
    }

    // MARK: 30 saniye sessizlik + bağlantı

    func testSilenceWithStuckConnectionRunsNetworkRecovery() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.health.internet = false   // iOS "çevrimiçi" diyor ama gerçekte internet yok
        h.shortcuts.onRun = { name in if name == "WiFi_Ac" { h.health.internet = true } }
        h.scheduler.advance(by: SilenceWatchdog.limit + 0.1)
        let done = await waitUntil { h.speaker.spoken.last == Say.recovered && h.vm.phase == .listening }
        XCTAssertTrue(done)
        XCTAssertEqual(h.shortcuts.runs, ["WiFi_Ac"])
    }

    // MARK: Tekrar klasörü

    func testReplayFallsBackToEarlierDayWhenTheNewSessionFolderIsEmpty() async throws {
        let h = SessionHarness()
        let old = h.root.appendingPathComponent("2020-01-01", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data([1]).write(to: old.appendingPathComponent("soru_1.m4a"))
        h.vm.refreshReplayAvailability()
        XCTAssertTrue(h.vm.canReplay)

        h.permissions.result = PermissionResult(microphone: false, speech: true, onDeviceSpeech: true)
        h.vm.start()   // başarısız olur ama boş bir yeni gün klasörü açılmış olur
        let stopped = await waitUntil { h.vm.phase == .idle && !h.vm.warnings.isEmpty }
        XCTAssertTrue(stopped)
        XCTAssertTrue(h.vm.canReplay)

        h.vm.startReplay()
        XCTAssertEqual(h.vm.phase, .replaying)
        XCTAssertEqual(h.player.played.map { $0.lastPathComponent }, ["soru_1.m4a"])
    }
}

// MARK: - Ses oturumu kesintisi bildirimi

@MainActor
final class AudioInterruptionTests: XCTestCase {
    func testInterruptionNotificationsAreForwarded() async {
        let guardian = AudioSessionGuard()
        var events: [Bool] = []
        guardian.onInterruption = { events.append($0) }
        for type in [AVAudioSession.InterruptionType.began, .ended] {
            NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
                                            userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue])
        }
        let ok = await waitUntil { events.count == 2 }
        XCTAssertTrue(ok)
        XCTAssertEqual(events, [true, false])
    }
}

// MARK: - Gemini sesi bekleme süresi

@MainActor
final class GeminiVoiceCooldownTests: XCTestCase {
    private func queue(_ replies: [FakeGeminiProtocol.Reply]) {
        FakeGeminiProtocol.lock.lock()
        FakeGeminiProtocol.replies = replies
        FakeGeminiProtocol.lock.unlock()
    }

    private func requestCount() -> Int {
        FakeGeminiProtocol.lock.lock()
        defer { FakeGeminiProtocol.lock.unlock() }
        return FakeGeminiProtocol.urls.count
    }

    private func failing(_ status: Int) -> FakeGeminiProtocol.Reply {
        let body = (try? JSONSerialization.data(withJSONObject: ["error": ["message": "hata"]])) ?? Data()
        return FakeGeminiProtocol.Reply(status: status, body: body, error: nil)
    }

    private func audio() -> FakeGeminiProtocol.Reply {
        let object: [String: Any] = ["candidates": [["content": ["parts": [["inlineData": [
            "mimeType": "audio/L16;rate=24000",
            "data": Data([1, 0, 2, 0]).base64EncodedString()]]]]]]]
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return FakeGeminiProtocol.Reply(status: 200, body: body, error: nil)
    }

    func testFailedVoiceIsSkippedDuringCooldownSoAnswersAreNotDelayed() async throws {
        FakeGeminiProtocol.reset()
        var clock = Date(timeIntervalSince1970: 1_000)
        let voice = GeminiVoice(key: { "AIza-TEST" }, cooldown: 300, now: { clock }, makeClient: fakeGeminiClient)
        let base = makeTempFolder()

        queue([failing(404), failing(404)])
        do {
            _ = try await voice.synthesize("a", to: base.appendingPathComponent("soru_1"))
            XCTFail("Hata bekleniyordu")
        } catch {}
        XCTAssertEqual(requestCount(), 2)

        do {
            _ = try await voice.synthesize("b", to: base.appendingPathComponent("soru_2"))
            XCTFail("Bekleme süresinde hata bekleniyordu")
        } catch {}
        XCTAssertEqual(requestCount(), 2, "Bekleme süresinde Gemini'ye istek atılmaz (telefonun sesi hemen devreye girer)")

        clock = clock.addingTimeInterval(301)
        queue([audio()])
        let url = try await voice.synthesize("c", to: base.appendingPathComponent("soru_3"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(requestCount(), 3, "Süre dolunca Gemini sesi yeniden denenir")
    }

    func testNetworkFailureDoesNotStartTheCooldown() async {
        FakeGeminiProtocol.reset()
        let offline = FakeGeminiProtocol.Reply(status: 0, body: Data(), error: URLError(.notConnectedToInternet))
        let voice = GeminiVoice(key: { "AIza-TEST" }, cooldown: 300, makeClient: fakeGeminiClient)
        let base = makeTempFolder()
        queue(Array(repeating: offline, count: 20))
        _ = try? await voice.synthesize("a", to: base.appendingPathComponent("soru_1"))
        let afterFirst = requestCount()
        XCTAssertGreaterThan(afterFirst, 0)
        _ = try? await voice.synthesize("b", to: base.appendingPathComponent("soru_2"))
        XCTAssertGreaterThan(requestCount(), afterFirst, "İnternet sorununda sonraki cevap yine denenir, bekleme süresi başlamaz")
    }

    func testSuccessfulVoiceNeverEntersCooldown() async throws {
        FakeGeminiProtocol.reset()
        let voice = GeminiVoice(key: { "AIza-TEST" }, cooldown: 300, makeClient: fakeGeminiClient)
        let base = makeTempFolder()
        queue([audio(), audio()])
        _ = try await voice.synthesize("a", to: base.appendingPathComponent("soru_1"))
        _ = try await voice.synthesize("b", to: base.appendingPathComponent("soru_2"))
        XCTAssertEqual(requestCount(), 2)
    }
}
