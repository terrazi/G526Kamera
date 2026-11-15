import XCTest
@testable import G526CameraDrive

/// Kameranın şarjı bitti ya da kapalı: 5 denemeden sonra sesle devam edilir, kamera 5 dakikada bir sorular arasında yoklanır; döndüyse
/// "Kameraya N dakika M saniye boyunca ulaşılamıyordu, şu an itibarıyla düzeldi ve kamera kullanılabiliyor" denir ve kamera yeniden sisteme girer.
@MainActor
final class CameraWatchTests: XCTestCase {
    typealias T = SessionViewModel.Timing

    private func harness(replies: [Result<GeminiReply, Error>]? = nil) -> SessionHarness {
        let h = SessionHarness(cameraFlow: true)
        h.camera.results = [.failure(.notConnected), .failure(.notConnected), .failure(.notConnected), .failure(.notConnected), .failure(.noFrames)]
        h.answering.results = replies ?? [.success(FakeAnswering.reply(1))]
        h.trackEvents { name in
            if name == "Kameraya_Gec" { h.health.internet = false }
            if name == "Hücresele_Gec" { h.health.internet = true }
            if name == "Hücresel_Ac" { h.health.internet = true }
        }
        return h
    }

    private func reply(_ h: SessionHarness, _ text: String) {
        h.listener.say(text)
        h.scheduler.advance(by: T.numberConfirm + 0.1)
    }

    /// İlk soruda kamera "evet" denir ve 5 deneme de başarısız olur; sesle devam edilmeye başlanana kadar bekler
    private func giveUp(_ h: SessionHarness, minutes: Int = 5) async {
        _ = await h.startListening()
        reply(h, "evet")
        let voice = await waitUntil(45) { h.speaker.spoken.last == Say.cameraFailed(.noFrames, down: true, minutes: minutes) && h.vm.listenMode == .question && h.vm.phase == .listening }
        XCTAssertTrue(voice, "Sesle devam edilmedi: \(h.speaker.spoken)")
    }

    func testRecoveryMessageNamesTheMinutesAndSeconds() {
        XCTAssertEqual(Say.cameraBack(seconds: 432), "Kameraya 7 dakika 12 saniye boyunca ulaşılamıyordu. Şu an itibarıyla düzeldi ve kamera kullanılabiliyor.")
        XCTAssertTrue(Say.cameraBack(seconds: 60).contains("1 dakika boyunca"))
        XCTAssertFalse(Say.cameraBack(seconds: 60).contains("saniye boyunca"))
        XCTAssertTrue(Say.cameraBack(seconds: 45).contains("45 saniye boyunca"))
        XCTAssertTrue(Say.cameraBack(seconds: 0).contains("0 saniye"))
        XCTAssertTrue(Say.cameraFailed(.noFrames, down: true).contains("5 dakikada bir"))
        XCTAssertTrue(Say.cameraFailed(.noFrames, down: true, minutes: 12).contains("12 dakikada bir"))
        XCTAssertFalse(Say.cameraFailed(.noFrames).contains("dakikada bir"))
    }

    func testAfterGivingUpTheCameraQuestionIsNotAskedAgain() async {
        let h = harness()
        await giveUp(h)
        XCTAssertEqual(h.camera.captures, 5)
        XCTAssertEqual(h.speaker.spoken.filter { $0 == Say.askCamera }.count, 1, "Kamera yalnız ilk soruda soruldu")
        h.ask("Soru 1. A seçeneği Adana")
        let done = await waitUntil(45) { h.vm.answers.count == 1 && h.vm.phase == .listening }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        XCTAssertEqual(h.vm.listenMode, .question, "Sıradaki soru için kamera sorulmaz, sesle okunur")
        XCTAssertEqual(h.speaker.spoken.filter { $0 == Say.askCamera }.count, 1)
        XCTAssertEqual(h.camera.captures, 5, "Kamera yeniden denenmedi")
    }

    func testTheCameraIsCheckedEveryFiveMinutesAndNotBefore() async {
        let h = harness()
        await giveUp(h)
        h.scheduler.advance(by: T.cameraProbeEvery - 1)
        await settle()
        XCTAssertEqual(h.camera.probes, 0, "Beş dakika dolmadan yoklanmaz")
        XCTAssertEqual(T.cameraProbeEvery, 300)
    }

    /// Ayarlar'dan kontrol aralığı değiştirilebilir: 1...60 dakika, kalıcı, varsayılan 5
    func testTheCheckIntervalIsSetInTheSettingsAndKept() {
        let defaults = UserDefaults(suiteName: "g526.kamera.kontrol")!
        defaults.removePersistentDomain(forName: "g526.kamera.kontrol")
        let s = AppSettings(defaults: defaults)
        XCTAssertEqual(s.cameraCheckMinutes, 5, "Varsayılan 5 dakika")
        s.cameraCheckMinutes = 12
        XCTAssertEqual(AppSettings(defaults: defaults).cameraCheckMinutes, 12, "Kalıcı")
        s.cameraCheckMinutes = 0
        XCTAssertEqual(s.cameraCheckMinutes, 1, "En az 1 dakika")
        s.cameraCheckMinutes = 500
        XCTAssertEqual(s.cameraCheckMinutes, 60, "En çok 60 dakika")
    }

    func testAShorterIntervalFromTheSettingsChecksTheCameraSooner() async {
        let h = harness()
        h.settings.cameraCheckMinutes = 2
        await giveUp(h, minutes: 2)
        XCTAssertTrue(h.speaker.spoken.contains(Say.cameraFailed(.noFrames, down: true, minutes: 2)), "Söylenen süre ayardaki süredir: \(h.speaker.spoken)")
        XCTAssertEqual(h.vm.cameraProbeInterval, 120)
        h.scheduler.advance(by: 119)
        await settle()
        XCTAssertEqual(h.camera.probes, 0, "İki dakika dolmadan yoklanmaz")
        h.camera.probeResults = [true]
        h.clock.offset = 125
        h.scheduler.advance(by: 1.2)
        let told = await waitUntil(45) { h.speaker.spoken.contains(Say.cameraBack(seconds: 125)) }
        XCTAssertTrue(told, "\(h.speaker.spoken)")
        XCTAssertEqual(h.camera.probes, 1)
    }

    func testALongerIntervalFromTheSettingsWaitsLonger() async {
        let h = harness()
        h.settings.cameraCheckMinutes = 10
        await giveUp(h, minutes: 10)
        XCTAssertEqual(h.vm.cameraProbeInterval, 600)
        h.scheduler.advance(by: T.cameraProbeEvery + 1)   // 5 dakika geçti: 10 dakikalık ayarda henüz yoklanmaz
        await settle()
        XCTAssertEqual(h.camera.probes, 0)
    }

    func testTheCameraComingBackIsAnnouncedWithTheDownTimeAndTheCameraQuestionReturns() async {
        let h = harness()
        await giveUp(h)
        h.camera.probeResults = [true]
        h.clock.offset = 432   // 7 dakika 12 saniye
        h.scheduler.advance(by: T.cameraProbeEvery + 0.1)
        let told = await waitUntil(45) { h.speaker.spoken.contains(Say.cameraBack(seconds: 432)) }
        XCTAssertTrue(told, "Kamera döndüğü söylenmedi: \(h.speaker.spoken)")
        XCTAssertTrue(h.speaker.spoken.contains(Say.cameraChecking), "Yoklama başlarken kullanıcıya söylenir (sessiz bekletilmez)")
        XCTAssertNil(h.vm.cameraDownSince, "Kamera yeniden sisteme alındı")
        XCTAssertTrue(h.vm.cameraOfferAvailable)
        XCTAssertEqual(h.camera.probes, 1)
        XCTAssertEqual(Array(h.shortcuts.runs.suffix(2)), ["Kameraya_Gec", "Hücresele_Gec"], "Yoklamadan sonra internete dönülür")
        let asked = await waitUntil(45) { h.vm.listenMode == .cameraChoice && h.vm.phase == .listening }
        XCTAssertTrue(asked, "Sıradaki soru için kamera sorusu yeniden sorulur: \(h.speaker.spoken)")
        XCTAssertEqual(h.camera.captures, 5, "Yoklama fotoğraf çekmez")
    }

    func testAStillDeadCameraIsCheckedAgainFiveMinutesLater() async {
        let h = harness()
        await giveUp(h)
        h.camera.probeResults = [false, true]
        h.clock.offset = 305
        h.scheduler.advance(by: T.cameraProbeEvery + 0.1)
        let still = await waitUntil(45) { h.speaker.spoken.last == Say.cameraStillDown && h.vm.listenMode == .question && h.vm.phase == .listening }
        XCTAssertTrue(still, "\(h.speaker.spoken)")
        XCTAssertNotNil(h.vm.cameraDownSince)
        XCTAssertFalse(h.vm.cameraOfferAvailable)
        h.clock.offset = 610
        h.scheduler.advance(by: T.cameraProbeEvery + 0.1)
        let back = await waitUntil(45) { h.speaker.spoken.contains(Say.cameraBack(seconds: 610)) }
        XCTAssertTrue(back, "\(h.speaker.spoken)")
        XCTAssertEqual(h.camera.probes, 2)
        XCTAssertNil(h.vm.cameraDownSince)
    }

    func testAnUnrelatedCameraFailureDoesNotTakeTheCameraOutOfTheSystem() async {
        let h = SessionHarness(cameraFlow: true)
        h.camera.results = [.failure(.noPosition)]
        h.trackEvents { name in
            if name == "Kameraya_Gec" { h.health.internet = false }
            if name == "Hücresele_Gec" { h.health.internet = true }
        }
        _ = await h.startListening()
        reply(h, "evet")
        let voice = await waitUntil(45) { h.speaker.spoken.last == Say.cameraFailed(.noPosition) && h.vm.listenMode == .question && h.vm.phase == .listening }
        XCTAssertTrue(voice, "\(h.speaker.spoken)")
        XCTAssertNil(h.vm.cameraDownSince, "Sayfa konumlanmadı: kamera çalışıyor, ulaşılamıyor sayılmaz")
        XCTAssertTrue(h.vm.cameraOfferAvailable)
    }

    func testTheCheckWaitsWhileAQuestionIsBeingRead() async {
        let h = harness()
        await giveUp(h)
        h.listener.say("Ali eve gitti ve okula yürüdü")   // soru okunuyor, henüz "Cevapla" denmedi
        h.camera.probeResults = [true]
        h.scheduler.advance(by: T.cameraProbeEvery + 0.1)
        await settle()
        XCTAssertEqual(h.camera.probes, 0, "Soru okunurken interneti kesen yoklama yapılmaz")
        XCTAssertNotNil(h.vm.cameraDownSince)
    }

    func testANewExamStartsWithTheCameraAvailableAgain() async {
        let h = harness()
        await giveUp(h)
        XCTAssertNotNil(h.vm.cameraDownSince)
        h.vm.resetSession()
        XCTAssertNil(h.vm.cameraDownSince)
        XCTAssertNil(h.vm.cameraProbeTask)
    }
}
