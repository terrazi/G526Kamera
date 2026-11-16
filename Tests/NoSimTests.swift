import XCTest
@testable import G526CameraDrive

/// Telefonda SIM kart yokken (kullanıcı denemesi 2026-11-16 14:11): "Hücresel Veri" kestirmesi yalnız Wi-Fi'yi kapatır, internet getirmez.
/// Program bunu anlar: hücresel ve sıfırlama Kestirmelerini çalıştırmaz (30 sn bekleme, onarım turları ve dakikalarca askıya alma olmaz),
/// nedeni açıkça söyler.
@MainActor
final class NoSimTests: XCTestCase {
    typealias T = SessionViewModel.Timing

    func testTheSimDecisionNeedsBothSignalsToBeEmpty() {
        XCTAssertFalse(CellularService.isAvailable(providers: 0, radios: 0))
        XCTAssertTrue(CellularService.isAvailable(providers: 1, radios: 0), "Takılı SIM varsa (radyo kapalı olsa da) var sayılır")
        XCTAssertTrue(CellularService.isAvailable(providers: 0, radios: 1), "Hizmet alan hat varsa var sayılır")
        XCTAssertTrue(CellularService.isAvailable(providers: 2, radios: 2))
    }

    func testTheDefaultHealthCheckAssumesACellularServiceSoOldBehaviourIsKept() {
        XCTAssertTrue(FakeHealth().hasCellularService())
    }

    /// Kamerasız açılış: internet yok + SIM yok → hiçbir Kestirme çalışmaz, açılış nedeni söyleyerek durur
    func testWithoutASimTheStartStopsWithTheReasonAndRunsNoShortcut() async {
        let h = SessionHarness()
        h.health.internet = false
        h.health.hasCellular = false
        h.vm.start()
        let stopped = await waitUntil { h.vm.phase == .idle && !h.vm.warnings.isEmpty }
        XCTAssertTrue(stopped)
        XCTAssertTrue(h.shortcuts.runs.isEmpty, "Hücresel/sıfırlama kestirmesi çalıştırılmadı: \(h.shortcuts.runs)")
        XCTAssertEqual(h.vm.warnings.first?.text, Say.noSimNoInternet)
        XCTAssertTrue(h.speaker.spoken.first?.hasPrefix("Kontrol başarısız") ?? false)
        XCTAssertTrue(h.speaker.spoken.first?.contains(Say.noSimNoInternet) ?? false)
        XCTAssertEqual(h.vm.checkup.first(where: { $0.id == "internet" })?.ok, false)
    }

    /// SIM varsa eski düzen aynen sürer (kestirme çalışır, internet gelir, açılış tamamlanır)
    func testWithASimTheOldRepairStillRuns() async {
        let h = SessionHarness()
        h.health.internet = false
        h.shortcuts.onRun = { name in if name == "Hücresel_Ac" { h.health.internet = true } }
        let listening = await h.startListening()
        XCTAssertTrue(listening)
        XCTAssertEqual(h.shortcuts.runs, ["Hücresel_Ac"])
    }

    private func offlineHarness() -> SessionHarness {
        let h = SessionHarness(cameraFlow: true, connectAtStart: true)
        h.camera.results = [.success(FakeCamera.shot()), .success(FakeCamera.shot())]
        h.answering.results = [.success(FakeAnswering.reply(1)), .success(FakeAnswering.reply(2))]
        h.trackEvents { name in
            if name == "Kameraya_Gec" { h.health.internet = false }
            if name == "Hücresele_Gec" { h.health.internet = true }
        }
        h.health.internet = false
        h.health.hasCellular = false
        h.settings.instantDetection = true
        return h
    }

    private func reply(_ h: SessionHarness, _ text: String) {
        h.listener.say(text)
        h.scheduler.advance(by: T.numberConfirm + 0.1)
    }

    private func cameraQuestionOpen(_ h: SessionHarness) -> Bool {
        return h.vm.listenMode == .cameraChoice && h.vm.phase == .listening
    }

    /// Kameralı açılış, SIM yok, internet yok: açılış durmaz (çevrimdışı çekim kipi). Kameraya yine hemen bağlanılır, hücresel kestirmesi
    /// çalışmaz, Gemini yoklanmaz, durum söylenir ve kamera sorusu sorulur.
    func testWithoutASimTheCameraStartContinuesOffline() async {
        let h = offlineHarness()
        let listening = await h.startListening()
        XCTAssertTrue(listening, "\(h.speaker.spoken)")
        XCTAssertEqual(h.events, ["kestirme:Kameraya_Gec", "bağlantı açıldı", "bağlantı kapandı"], "Kameraya bağlanıldı, kapandı; hücresel kestirmesi yok")
        XCTAssertTrue(h.speaker.spoken.contains(Say.offlineCaptureStart + " " + Say.readyCamera), "\(h.speaker.spoken)")
        XCTAssertEqual(h.health.geminiCalls, 0, "İnternet yokken Gemini yoklanmaz")
        XCTAssertEqual(h.vm.listenMode, .cameraChoice)
        XCTAssertEqual(h.vm.checkup.first(where: { $0.id == "internet" })?.ok, false)
    }

    /// Çevrimdışı kipte çekilen sorular telefonda birikir, sınav sıradaki soruyla sürer; bekleyen gönderme için konuşulmaz, 30 sn beklenmez
    func testOfflineShotsAccumulateAndTheExamContinues() async {
        let h = offlineHarness()
        let listening = await h.startListening()
        XCTAssertTrue(listening)
        reply(h, "evet")
        let first = await waitUntil(45) { h.vm.pendingShots.count == 1 && self.cameraQuestionOpen(h) }
        XCTAssertTrue(first, "\(h.speaker.spoken)")
        reply(h, "evet")
        let second = await waitUntil(45) { h.vm.pendingShots.count == 2 && self.cameraQuestionOpen(h) }
        XCTAssertTrue(second, "\(h.speaker.spoken)")
        XCTAssertEqual(h.events.filter { $0 == "kestirme:Hücresele_Gec" }.count, 0, "Hücresel kestirmesi hiç çalışmadı")
        XCTAssertEqual(h.events.filter { $0 == "çekim" }.count, 2)
        XCTAssertTrue(h.answering.captureCalls.isEmpty, "İnternet yok: hiçbir şey gönderilmedi")
        XCTAssertEqual(h.speaker.spoken.filter { $0 == Say.cameraSavedOfflineContinue }.count, 2)
        XCTAssertFalse(h.speaker.spoken.contains(Say.cameraPendingSending), "Her soruda boşuna 'bekleyen gönderiliyor' denmez")
        XCTAssertFalse(h.speaker.spoken.contains(Say.cameraSavedOffline), "Onarım sözü verilmez")
    }

    /// Çevrimdışı kipte nabız "internet yok" dese de onarım başlamaz, test duraklamaz
    func testTheHeartbeatDoesNotPauseTheExamWhileOfflineWithoutASim() async {
        let h = offlineHarness()
        let listening = await h.startListening()
        XCTAssertTrue(listening)
        let runsBefore = h.shortcuts.runs.count
        for _ in 0..<(T.netFailLimit + 3) {
            h.vm.netBeat("deneme")
            _ = await waitUntil(1) { !h.vm.netProbeBusy }
        }
        XCTAssertEqual(h.vm.phase, .listening)
        XCTAssertEqual(h.shortcuts.runs.count, runsBefore, "Onarım kestirmesi çalışmadı")
        XCTAssertFalse(h.speaker.announcements.contains(Say.networkLost))
    }

    /// İnternet gelince (nabız ya da yol değişimi) bekleyen çekimler sırayla gönderilir ve cevapları okunur
    func testWhenTheInternetComesTheWaitingShotsAreSentInOrder() async {
        let h = offlineHarness()
        let listening = await h.startListening()
        XCTAssertTrue(listening)
        reply(h, "evet")
        let first = await waitUntil(45) { h.vm.pendingShots.count == 1 && self.cameraQuestionOpen(h) }
        XCTAssertTrue(first, "\(h.speaker.spoken)")
        reply(h, "evet")
        let second = await waitUntil(45) { h.vm.pendingShots.count == 2 && self.cameraQuestionOpen(h) }
        XCTAssertTrue(second, "\(h.speaker.spoken)")

        h.health.internet = true   // Wi-Fi ya da hücresel geldi
        h.vm.netBeat("internet geldi")
        let sent = await waitUntil(45) { h.vm.answers.count == 2 && h.vm.pendingShots.isEmpty && self.cameraQuestionOpen(h) }
        XCTAssertTrue(sent, "gönderilen \(h.answering.captureCalls.count), bekleyen \(h.vm.pendingShots.count), \(h.speaker.spoken)")
        XCTAssertEqual(h.answering.captureCalls.count, 2)
        XCTAssertEqual(h.vm.answers.map { $0.number }, [1, 2])
    }

    /// Oturum sürerken internet kopar ve SIM yok: onarım Kestirme çalıştırmaz, nedeni söyler; internet kendiliğinden gelirse onarım biter
    func testWithoutASimTheOutageRepairRunsNoShortcutAndSaysWhy() async {
        let h = SessionHarness()
        let listening = await h.startListening()
        XCTAssertTrue(listening)
        h.health.hasCellular = false
        h.health.internet = false
        let result = await h.vm.performRecovery(.network)
        XCTAssertEqual(result, .gaveUp)
        XCTAssertTrue(h.shortcuts.runs.isEmpty, "\(h.shortcuts.runs)")
        let said = await waitUntil { h.speaker.announcements.contains(Say.noSimNoInternet) }
        XCTAssertTrue(said, "\(h.speaker.announcements)")

        h.health.internet = true
        let again = await h.vm.performRecovery(.network)
        XCTAssertEqual(again, .recovered(by: nil), "Wi-Fi ile internet geldi: onarım tamam")
        XCTAssertTrue(h.shortcuts.runs.isEmpty)
    }

    /// "Kamerayı dene": SIM yoksa internet kestirmesi atlanır, sınama nedeni yazarak biter
    func testTheCameraTestSkipsTheInternetShortcutWithoutASim() async {
        let defaults = UserDefaults(suiteName: "g526.testler.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        let cameraSettings = CameraSettings(defaults: defaults)
        cameraSettings.cameraShortcutName = "Kameraya_Gec"
        settings.internetShortcut = "Hücresele_Gec"
        let camera = FakeCamera()
        camera.results = [.success(FakeCamera.shot())]
        let shortcuts = FakeShortcuts()
        let health = FakeHealth()
        health.hasCellular = false
        let tester = CameraTester(camera: camera, shortcuts: shortcuts, health: health, settings: settings, cameraSettings: cameraSettings,
                                  sessionActive: { false }, sleep: { _ in })
        await tester.run()
        XCTAssertEqual(shortcuts.runs, ["Kameraya_Gec"], "Hücresele geç kestirmesi çalışmadı")
        XCTAssertTrue(tester.lines.last?.contains("SIM kart yok") ?? false, "\(tester.lines)")
        XCTAssertFalse(tester.running)
    }
}
