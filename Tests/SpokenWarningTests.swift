import XCTest
@testable import G526CameraDrive

/// Ekrana yazılan uyarılar kulaklıktan da söylenir (yalnız Bluetooth kulaklıktan, KURAL 1)
@MainActor
final class SpokenWarningTests: XCTestCase {
    func testNetworkLossAndFailedRepairAreSpoken() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.health.internet = false
        h.network.set(online: false)
        h.scheduler.advance(by: SessionViewModel.Timing.offlineDebounce + 0.1)
        let paused = await waitUntil { h.isConnectionPause }
        XCTAssertTrue(paused)
        let lost = await waitUntil { h.speaker.announcements.contains(Say.networkLost) }
        XCTAssertTrue(lost, "İnternet gidince kulaklıktan söylenir: \(h.speaker.announcements)")
        let gaveUp = await waitUntil { h.speaker.announcements.contains { $0.hasPrefix("Kestirmeler sorunu gideremedi") } }
        XCTAssertTrue(gaveUp, "Onarım başarısız olunca da söylenir: \(h.speaker.announcements)")
    }

    func testMissingMicrophoneIsSpokenWhileTheHeadphonesWork() async {
        let h = SessionHarness()
        h.route.current = FakeRoute.noMic
        h.vm.start()
        let paused = await waitUntil { h.isHardwarePause }
        XCTAssertTrue(paused)
        let said = await waitUntil { h.speaker.announcements.contains("Duraklatıldı: yaka mikrofonu yok") }
        XCTAssertTrue(said, "Kulaklık sağlamsa neden durduğu söylenir: \(h.speaker.announcements)")
    }

    func testNothingIsPlayedWithoutHeadphones() async {
        let h = SessionHarness()
        h.route.current = FakeRoute.noHeadphones
        h.vm.start()
        let paused = await waitUntil { h.isHardwarePause }
        XCTAssertTrue(paused)
        await settle()
        XCTAssertTrue(h.speaker.allCalls.isEmpty, "Kulaklık yokken ses hiçbir yerden çıkmaz (KURAL 1)")
        XCTAssertTrue(h.vm.voiceQueue.isEmpty, "Duyulamayan haber sonra tekrar edilmesin")
    }

    func testStartupWarningIsSpokenBeforeTheReadyAnnouncement() async {
        let h = SessionHarness()
        h.permissions.result = PermissionResult(microphone: true, speech: true, onDeviceSpeech: true, englishOnDevice: false)
        let ok = await h.startListening()
        XCTAssertTrue(ok)
        let texts = h.speaker.allCalls.map { $0.text }
        XCTAssertEqual(Array(texts.prefix(2)), [Say.noEnglishDictation, Say.ready])
    }

    func testBatteryWarningWaitsUntilTheAnswerWasHeard() async {
        let h = SessionHarness()
        h.answering.results = [.success(FakeAnswering.reply(1))]
        _ = await h.startListening()
        h.battery.set(19)
        XCTAssertTrue(h.speaker.announcements.isEmpty, "Dinlerken araya girmez")
        h.ask("Soru 1 hangisi doğrudur")
        let done = await waitUntil { h.vm.answers.count == 1 && h.vm.phase == .listening }
        XCTAssertTrue(done)
        let texts = h.speaker.allCalls.map { $0.text }
        XCTAssertEqual(texts, [Say.ready, "Soru 1, Denizli, Örgütsel Davranış", Say.lowBattery(19)], "Cevap duyulduktan sonra söylenir")
    }

    func testBackupModelNoteIsSpokenAfterTheAnswer() async {
        let h = SessionHarness()
        var reply = FakeAnswering.reply(1)
        reply.note = "1. profil kotası doldu; cevap ikinci modelden geldi."
        h.answering.results = [.success(reply)]
        _ = await h.startListening()
        h.ask("Soru 1 hangisi doğrudur")
        let done = await waitUntil { h.vm.answers.count == 1 && h.vm.phase == .listening }
        XCTAssertTrue(done)
        XCTAssertEqual(h.speaker.announcements, ["1. profil kotası doldu; cevap ikinci modelden geldi."])
        XCTAssertEqual(h.speaker.spoken.last, "Soru 1, Denizli, Örgütsel Davranış")
    }

    func testGenericAnswerFailureTellsTheUser() async {
        let h = SessionHarness()
        h.answering.results = [.failure(CocoaError(.fileReadUnknown))]
        _ = await h.startListening()
        h.ask("Soru 1 hangisi doğrudur")
        let done = await waitUntil { h.speaker.spoken.contains(Say.answerFailed) && h.vm.phase == .listening }
        XCTAssertTrue(done, "Beklenmedik hatada da kullanıcıya söylenir")
    }

    func testSameWarningIsNotRepeatedAndSettingTurnsItOff() async {
        let h = SessionHarness()
        h.vm.warn("giris", "Deneme uyarısı")
        let said = await waitUntil { h.speaker.announcements == ["Deneme uyarısı"] }
        XCTAssertTrue(said)
        h.vm.clearWarning("giris")
        h.vm.warn("giris", "Deneme uyarısı")
        await settle()
        XCTAssertEqual(h.speaker.announcements, ["Deneme uyarısı"], "Aynı cümle kısa sürede yeniden söylenmez")

        h.settings.spokenWarnings = false
        h.vm.warn("giris", "Başka uyarı")
        await settle()
        XCTAssertEqual(h.speaker.announcements, ["Deneme uyarısı"], "Ayar kapalıyken söylenmez")
        XCTAssertNotNil(h.vm.warnings.first(where: { $0.id == "giris" }), "Ekranda yine yazar")
    }

    func testNothingIsSpokenWhileACallOrSiriInterrupts() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.route.interrupt(began: true)
        await settle()
        XCTAssertTrue(h.speaker.announcements.isEmpty, "Arama sürerken konuşulmaz")
    }
}
