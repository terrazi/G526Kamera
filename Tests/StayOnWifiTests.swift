import XCTest
@testable import G526CameraDrive

/// "Kameranın Wi-Fi'sinde kal" kipi (kullanıcı kararı 2026-11-16): telefon kameranın Wi-Fi ağında kalır, internet hücreselden gelir.
/// Çekimde "Kameraya geç" kestirmesi çalışmaz, çekim bitince Wi-Fi bırakılmaz; internet yoksa hücresel kestirmesi çalışır.
@MainActor
final class StayOnWifiTests: XCTestCase {
    typealias T = SessionViewModel.Timing

    /// `dropInternetOnCapture`: çekim sırasında internet kopar (hücresel düşmesi)
    private func harness(shots: [Result<CapturedQuestion, CameraFailure>]? = nil,
                         dropInternetOnCapture: Bool = false) -> SessionHarness {
        let h = SessionHarness(cameraFlow: true, stayOnWifi: true)
        h.camera.results = shots ?? [.success(FakeCamera.shot())]
        h.answering.results = [.success(FakeAnswering.reply(1))]
        h.trackEvents { name in
            if name == "Hücresele_Gec" { h.health.internet = true }
            if name == "Hücresel_Ac" { h.health.internet = true }
        }
        if dropInternetOnCapture {
            let record = h.camera.onCapture
            h.camera.onCapture = { record?(); h.health.internet = false }
        }
        return h
    }

    private func reply(_ h: SessionHarness, _ text: String) {
        h.listener.say(text)
        h.scheduler.advance(by: T.numberConfirm + 0.1)
    }

    private func cameraQuestionOpen(_ h: SessionHarness) -> Bool {
        return h.vm.listenMode == .cameraChoice && h.vm.phase == .listening
    }

    func testTheModeIsOnByDefaultAndKeptAndAppliedOnceOnOlderInstalls() {
        let defaults = UserDefaults(suiteName: "g526.testler.\(UUID().uuidString)")!
        let first = CameraSettings(defaults: defaults)
        XCTAssertTrue(first.stayOnWifi, "Varsayılan: bağlantılar hep açık (kullanıcı kararı 2026-11-19)")
        first.stayOnWifi = false
        XCTAssertFalse(CameraSettings(defaults: defaults).stayOnWifi, "Ayar kalıcıdır")
        // Önceki sürümden kapalı kalmış ayar yeni düzene bir kez çevrilir; sonra kullanıcının seçimine dokunulmaz
        let old = CameraSettings(defaults: defaults)
        old.applyAlwaysOnOnce()
        XCTAssertTrue(old.stayOnWifi, "Bir kez açılır")
        old.stayOnWifi = false
        old.applyAlwaysOnOnce()
        XCTAssertFalse(CameraSettings(defaults: defaults).stayOnWifi, "İkinci kez dokunulmaz")
    }

    /// İnternet varsa (hücresel Wi-Fi ile birlikte çalışıyorsa) hiçbir kestirme çalışmaz: ne kameraya geçiş ne internete dönüş
    func testNoShortcutRunsWhenTheInternetIsThere() async {
        let h = harness()
        _ = await h.startListening()
        reply(h, "evet")
        let again = await waitUntil(45) { h.vm.answers.count == 1 && self.cameraQuestionOpen(h) }
        XCTAssertTrue(again, "\(h.speaker.spoken)")
        XCTAssertEqual(h.events, ["çekim", "gönderim"], "Kestirme yok: telefon zaten kameranın ağında, internet hücreselden")
        XCTAssertEqual(h.camera.connectLimits, [T.stayConnectSeconds], "İlk denemede bağlanma kısa sınırla beklenir")
        XCTAssertTrue(h.vm.pendingShots.isEmpty)
    }

    /// Hücresel düşerse yalnız "Hücresele geç" kestirmesi çalışır (kullanıcının Wi-Fi'ye dokunmayan kestirmesi); "Kameraya geç" hiç çalışmaz
    func testOnlyTheCellularShortcutRunsWhenTheInternetIsMissingAfterTheCapture() async {
        let h = harness(dropInternetOnCapture: true)
        _ = await h.startListening()
        reply(h, "evet")
        let again = await waitUntil(45) { h.vm.answers.count == 1 && self.cameraQuestionOpen(h) }
        XCTAssertTrue(again, "\(h.speaker.spoken)")
        XCTAssertEqual(h.events, ["çekim", "kestirme:Hücresel_Ac", "gönderim"], "Hücresel onarım kestirmesi çalışır (Wi-Fi'ye dokunmaz)")
        XCTAssertFalse(h.shortcuts.runs.contains("Kameraya_Gec"))
        XCTAssertFalse(h.shortcuts.runs.contains("Hücresele_Gec"), "Geçiş kestirmelerine bu düzende gerek yoktur")
    }

    /// Telefon kameranın ağından düşmüşse ilk doğrudan deneme başarısız olur; onarım kestirmesi çalışır ve çekim tam süreyle yeniden denenir
    func testAFailedDirectConnectRunsTheRepairShortcutAndRetriesWithTheFullWait() async {
        let h = harness(shots: [.failure(.notConnected), .success(FakeCamera.shot())])
        _ = await h.startListening()
        reply(h, "evet")
        let done = await waitUntil(45) { h.vm.answers.count == 1 }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        XCTAssertEqual(h.events, ["çekim", "kestirme:Kamera_Onar", "çekim", "gönderim"])
        XCTAssertEqual(h.camera.connectLimits.count, 2)
        XCTAssertEqual(h.camera.connectLimits.first ?? nil, T.stayConnectSeconds)
        XCTAssertNil(h.camera.connectLimits.last ?? nil, "Onarımdan sonra bağlanma tam süreyle beklenir")
    }

    /// Kapalıyken eski düzen: her çekimde kameraya geçilir, sonra Wi-Fi bırakılır; bağlanma tam süreyle beklenir
    func testWhenTurnedOffTheOldOrderStaysAndTheFullWaitIsUsed() async {
        let h = SessionHarness(cameraFlow: true, stayOnWifi: false)
        h.camera.results = [.success(FakeCamera.shot())]
        h.answering.results = [.success(FakeAnswering.reply(1))]
        h.trackEvents { name in
            if name == "Kameraya_Gec" { h.health.internet = false }
            if name == "Hücresele_Gec" { h.health.internet = true }
        }
        _ = await h.startListening()
        reply(h, "evet")
        let again = await waitUntil(45) { h.vm.answers.count == 1 && self.cameraQuestionOpen(h) }
        XCTAssertTrue(again, "\(h.speaker.spoken)")
        XCTAssertEqual(h.events, ["kestirme:Kameraya_Gec", "çekim", "kestirme:Hücresele_Gec", "gönderim"])
        XCTAssertEqual(h.camera.connectLimits.count, 1)
        XCTAssertNil(h.camera.connectLimits.first ?? nil)
    }

    // MARK: Kamera yoklaması

    private func giveUp(_ h: SessionHarness) async {
        h.camera.results = [.failure(.notConnected), .failure(.notConnected), .failure(.notConnected), .failure(.notConnected), .failure(.noFrames)]
        _ = await h.startListening()
        reply(h, "evet")
        let voice = await waitUntil(45) {
            h.speaker.spoken.last == Say.cameraFailed(.noFrames, down: true, minutes: 5) && h.vm.listenMode == .question && h.vm.phase == .listening
        }
        XCTAssertTrue(voice, "Sesle devam edilmedi: \(h.speaker.spoken)")
    }

    /// Kamera kapalıyken yoklama doğrudan bakar: kamera görünürse ne kameraya geçiş ne internete dönüş kestirmesi çalışır
    func testTheCameraCheckLooksDirectlyAndRunsNoShortcutWhenTheCameraAnswers() async {
        let h = harness()
        await giveUp(h)
        let before = h.shortcuts.runs.count
        h.camera.probeResults = [true]
        h.clock.offset = 432
        h.scheduler.advance(by: T.cameraProbeEvery + 0.1)
        let told = await waitUntil(45) { h.speaker.spoken.contains(Say.cameraBack(seconds: 432)) }
        XCTAssertTrue(told, "\(h.speaker.spoken)")
        XCTAssertEqual(h.camera.probes, 1)
        XCTAssertEqual(h.shortcuts.runs.count, before, "Yoklamada kestirme çalışmadı: \(h.shortcuts.runs)")
        XCTAssertNil(h.vm.cameraDownSince)
    }

    /// Doğrudan bakışta kamera görünmezse kameraya geçiş kestirmesi bir kez çalışır ve yeniden bakılır
    func testTheCameraCheckRunsTheCameraShortcutOnceWhenTheDirectLookFails() async {
        let h = harness()
        await giveUp(h)
        let before = h.shortcuts.runs.count
        h.camera.probeResults = [false, true]
        h.clock.offset = 432
        h.scheduler.advance(by: T.cameraProbeEvery + 0.1)
        let told = await waitUntil(45) { h.speaker.spoken.contains(Say.cameraBack(seconds: 432)) }
        XCTAssertTrue(told, "\(h.speaker.spoken)")
        XCTAssertEqual(h.camera.probes, 2)
        XCTAssertEqual(Array(h.shortcuts.runs.dropFirst(before)), ["Kamera_Onar"], "Hücreseli kapatan kameraya geçiş kestirmesi çalışmaz: Wi-Fi onarılır")
    }

    /// Bağlantılar hep açık (kullanıcı kararı 2026-11-19): kamera hiç açılamasa da hücreseli kapatan "Kameraya geç" kestirmesi çalışmaz. Önce Wi-Fi
    /// onarım kestirmesi, olmazsa sistem sıfırlama (uçak modu), sonra yine Wi-Fi onarım kestirmesi denenir.
    func testEvenWhenTheCameraNeverOpensTheCellularIsNeverSwitchedOff() async {
        let h = harness()
        await giveUp(h)
        XCTAssertFalse(h.shortcuts.runs.contains("Kameraya_Gec"), "\(h.shortcuts.runs)")
        XCTAssertTrue(h.shortcuts.runs.contains("Kamera_Onar"), "Kopan kamera bağlantısı Wi-Fi onarım kestirmesiyle yeniden kurulur")
        XCTAssertTrue(h.shortcuts.runs.contains("Sistemi_Sifirla"), "Olmazsa uçak modu kestirmesi çalışır")
        XCTAssertEqual(h.shortcuts.runs.first, "Kamera_Onar", "İlk deneme kestirmesizdir; onarım kopunca başlar")
    }

    /// Telefonun Wi-Fi adresi baştan yoksa (kameranın ağından düşmüş) kamera boşuna aranmaz: doğrudan Wi-Fi onarım kestirmesi çalışır
    /// (gerçek günlük 2026-11-19 12:58: adres yokken 15 sn kamera arandı, kullanıcıya bir şey söylenmedi)
    func testWithoutAWiFiAddressTheFirstAttemptGoesStraightToTheRepairShortcut() async {
        let h = harness(shots: [.success(FakeCamera.shot())])
        _ = await h.startListening()
        h.camera.wifiMissingChecks = 1000
        h.trackEvents { name in
            if name == "Hücresele_Gec" || name == "Hücresel_Ac" { h.health.internet = true }
            if name == "Kamera_Onar" { h.camera.wifiMissingChecks = 0 }   // Wi-Fi kapat-aç: telefon kameranın ağına girdi
        }
        reply(h, "evet")
        let done = await waitUntil(45) { h.vm.answers.count == 1 }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        XCTAssertEqual(h.events.filter { $0 == "çekim" }.count, 1, "Wi-Fi adresi yokken kamera aranmadı; onarımdan sonra tek çekim. \(h.events)")
        XCTAssertEqual(h.shortcuts.runs.filter { $0 == "Kamera_Onar" }.count, 1, "\(h.shortcuts.runs)")
        XCTAssertEqual(h.shortcuts.runs.first, "Kamera_Onar", "İlk iş onarım kestirmesidir")
    }

    /// Wi-Fi onarım kestirmesinden sonra telefon kameranın ağına girmediyse kamera boşuna aranmaz: sıradaki denemeye hemen geçilir
    func testAfterARepairThatDoesNotBringTheWiFiBackTheCameraIsNotSearched() async {
        let h = harness(shots: [.failure(.notConnected), .success(FakeCamera.shot())])
        _ = await h.startListening()
        h.trackEvents { name in
            if name == "Hücresele_Gec" || name == "Hücresel_Ac" { h.health.internet = true }
            if name == "Kamera_Onar" { h.camera.wifiMissingChecks = h.shortcuts.runs.filter { $0 == "Kamera_Onar" }.count == 1 ? 1000 : 0 }
        }
        reply(h, "evet")
        let done = await waitUntil(45) { h.vm.answers.count == 1 }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        XCTAssertEqual(h.events.filter { $0 == "çekim" }.count, 2, "İlk onarımdan sonra Wi-Fi adresi yok: kamera aranmadı. \(h.events)")
        XCTAssertEqual(h.shortcuts.runs.filter { $0 == "Kamera_Onar" }.count, 2, "İkinci onarımdan sonra bağlanıldı: \(h.shortcuts.runs)")
        XCTAssertFalse(h.shortcuts.runs.contains("Kameraya_Gec"), "Hücreseli kapatan kestirme çalışmaz")
    }
}
