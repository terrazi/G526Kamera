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

    /// Kameralı açılış: kameraya yine hemen bağlanılır (görüntü akar), ama kamera kapanınca "Hücresel Veri" çalıştırılmaz
    func testWithoutASimTheCameraStartNeverRunsTheCellularShortcut() async {
        let h = SessionHarness(cameraFlow: true, connectAtStart: true)
        h.camera.results = [.success(FakeCamera.shot())]
        h.trackEvents { name in
            if name == "Kameraya_Gec" { h.health.internet = false }
            if name == "Hücresele_Gec" { h.health.internet = true }
        }
        h.health.hasCellular = false
        h.vm.start()
        let stopped = await waitUntil(10) { h.vm.phase == .idle && !h.vm.warnings.isEmpty }
        XCTAssertTrue(stopped, "\(h.speaker.spoken)")
        XCTAssertEqual(h.events, ["kestirme:Kameraya_Gec", "bağlantı açıldı", "bağlantı kapandı"], "Kameraya bağlanıldı, kapandı; hücresel kestirmesi yok")
        XCTAssertTrue(h.vm.warnings.contains { $0.text == Say.noSimNoInternet }, "\(h.vm.warnings.map { $0.text })")
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
