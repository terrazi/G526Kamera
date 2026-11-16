import XCTest
@testable import G526CameraDrive

/// Sürüm 4: "Başlat"a basılınca kameraya hemen bağlanma (kullanıcı kararı 2026-11-16). Ses yolu doğrulanınca telefon kameranın Wi-Fi'sine geçer
/// (hücresel kapanır), kameraya bağlanılır ve görüntü ana ekranda akar; bağlantı ilk hücresel bağlantıdan önce kapanır ve internete geçilir.
/// Sonra her soruda eski düzen sürer. Bağlanılamazsa onarım denenir, olmazsa kamera sistemden çıkar ve sorular sesle okunur.
@MainActor
final class CameraStartTests: XCTestCase {
    typealias T = SessionViewModel.Timing

    private func harness(connectAtStart: Bool = true, holds: [Result<Void, CameraFailure>] = [],
                         shots: [Result<CapturedQuestion, CameraFailure>]? = nil) -> SessionHarness {
        let h = SessionHarness(cameraFlow: true, connectAtStart: connectAtStart)
        h.camera.results = shots ?? [.success(FakeCamera.shot())]
        h.camera.holdResults = holds
        h.answering.results = [.success(FakeAnswering.reply(1))]
        h.trackEvents { name in
            if name == "Kameraya_Gec" { h.health.internet = false }   // kameranın Wi-Fi'sinde hücresel kapalı
            if name == "Hücresele_Gec" { h.health.internet = true }
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

    /// Başlatınca: kameraya geçiş kestirmesi, bağlantı, görüntü gelince "bağlandı", bağlantı kapanır, sonra hücresel kestirmesi; ardından hazırım
    func testStartConnectsTheCameraThenClosesItBeforeTheInternetStep() async {
        let h = harness()
        let listening = await h.startListening()
        XCTAssertTrue(listening, "\(h.speaker.spoken)")
        XCTAssertEqual(h.events, ["kestirme:Kameraya_Gec", "bağlantı açıldı", "bağlantı kapandı", "kestirme:Hücresele_Gec"])
        XCTAssertEqual(h.speaker.spoken, [Say.cameraConnecting, Say.cameraStartOK, Say.readyCamera, Say.askCamera])
        XCTAssertFalse(h.camera.isHeld, "İnternete geçmeden kamera bağlantısı kapanmıştır")
        XCTAssertEqual(h.camera.captures, 0, "Başlangıçta hiçbir şey çekilmez")
        XCTAssertEqual(h.vm.checkup.first(where: { $0.id == "kameraBaglanti" })?.ok, true)
        XCTAssertNil(h.vm.cameraDownSince)
        XCTAssertFalse(h.vm.networkMayBeOnCamera, "Hücresel döndü: telefon kamerada kalmadı")
        XCTAssertEqual(h.vm.listenMode, .cameraChoice)
    }

    /// Başlangıçtan sonra her soruda eski düzen sürer: kameraya geç, çek, hücreseli aç, gönder
    func testAfterTheStartEveryQuestionKeepsTheOldOrder() async {
        let h = harness()
        _ = await h.startListening()
        reply(h, "evet")
        let again = await waitUntil(45) { h.vm.answers.count == 1 && self.cameraQuestionOpen(h) }
        XCTAssertTrue(again, "\(h.speaker.spoken)")
        XCTAssertEqual(h.events, ["kestirme:Kameraya_Gec", "bağlantı açıldı", "bağlantı kapandı", "kestirme:Hücresele_Gec",
                                  "kestirme:Kameraya_Gec", "çekim", "kestirme:Hücresele_Gec", "gönderim"])
    }

    /// Ayar kapalıysa başlatınca kameraya dokunulmaz (eski davranış)
    func testTurnedOffTheStartDoesNotTouchTheCamera() async {
        let h = harness(connectAtStart: false)
        let listening = await h.startListening()
        XCTAssertTrue(listening)
        XCTAssertEqual(h.events, [])
        XCTAssertEqual(h.camera.holdOpens, 0)
        XCTAssertEqual(h.speaker.spoken, [Say.readyCamera, Say.askCamera])
    }

    /// Kamera sorusu kapalıysa (V3 gibi çalışılıyorsa) kameraya bağlanılmaz
    func testWithoutTheCameraQuestionNothingConnects() async {
        let h = SessionHarness(cameraFlow: false, connectAtStart: true)
        let listening = await h.startListening()
        XCTAssertTrue(listening)
        XCTAssertEqual(h.camera.holdOpens, 0)
        XCTAssertTrue(h.shortcuts.runs.isEmpty)
    }

    /// İlk bağlanma olmazsa onarım kestirmesi çalışır ve yeniden bağlanılır
    func testAFailedConnectRunsTheRepairShortcutAndTriesAgain() async {
        let h = harness(holds: [.failure(.notConnected), .success(())])
        let listening = await h.startListening()
        XCTAssertTrue(listening, "\(h.speaker.spoken)")
        XCTAssertEqual(h.events, ["kestirme:Kameraya_Gec", "bağlantı açıldı", "kestirme:Kamera_Onar", "bağlantı açıldı", "bağlantı kapandı",
                                  "kestirme:Hücresele_Gec"])
        XCTAssertNil(h.vm.cameraDownSince)
        XCTAssertEqual(h.speaker.spoken.suffix(2), [Say.readyCamera, Say.askCamera])
    }

    /// Kamera hiç cevap vermezse (kapalı, şarjı bitti): üç deneme sonra internete dönülür, kamera sistemden çıkar, sorular sesle okunur
    func testWhenTheCameraNeverAnswersTheStartContinuesByVoice() async {
        let h = harness(holds: [.failure(.notConnected), .failure(.notConnected), .failure(.noFrames)])
        let listening = await h.startListening()
        XCTAssertTrue(listening, "\(h.speaker.spoken)")
        XCTAssertEqual(h.events, ["kestirme:Kameraya_Gec", "bağlantı açıldı", "kestirme:Kamera_Onar", "bağlantı açıldı",
                                  "kestirme:Kamera_Onar", "bağlantı açıldı", "kestirme:Hücresele_Gec"])
        XCTAssertEqual(h.camera.holdOpens, T.cameraStartRepairs + 1)
        XCTAssertNotNil(h.vm.cameraDownSince, "Kamera sistemden çıktı; yoklanacak")
        let minutes = AppSettings.clampCameraCheckMinutes(h.settings.cameraCheckMinutes)
        XCTAssertEqual(h.speaker.spoken.last, Say.readyCameraDown(minutes: minutes), "Kamera ayarları eksik denmez; kamerasının kapalı olduğu söylenir")
        XCTAssertFalse(h.speaker.spoken.contains(Say.askCamera), "Kamera kapalıyken kamera sorusu sorulmaz")
        XCTAssertEqual(h.vm.checkup.first(where: { $0.id == "kameraBaglanti" })?.ok, false)
        XCTAssertEqual(h.vm.listenMode, .question)
    }
}
