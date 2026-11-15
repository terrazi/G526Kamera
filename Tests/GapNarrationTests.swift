import XCTest
@testable import G526CameraDrive

/// Boşluk bilgisi: program sessiz bir işle meşgulken ya da uzun süre dinlerken ses çıkmazsa kısa bir cümleyle durumu söyler.
@MainActor
final class GapNarrationTests: XCTestCase {
    private typealias Timing = SessionViewModel.Timing

    private func harness(narration: Bool = true, seconds: Int = 10) -> SessionHarness {
        let h = SessionHarness()
        h.settings.gapNarration = narration
        h.settings.gapNarrationSeconds = seconds
        return h
    }

    private func count(_ h: SessionHarness, _ text: String) -> Int {
        return h.speaker.spoken.filter { $0 == text }.count
    }

    // MARK: Ayar

    func testSettingsDefaultsPersistAndClamp() {
        let name = "g526.testler.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let first = AppSettings(defaults: defaults)
        XCTAssertTrue(first.gapNarration, "varsayılan: açık")
        XCTAssertEqual(first.gapNarrationSeconds, 10)
        first.gapNarration = false
        first.gapNarrationSeconds = 20
        let again = AppSettings(defaults: defaults)
        XCTAssertFalse(again.gapNarration)
        XCTAssertEqual(again.gapNarrationSeconds, 20)
        again.gapNarrationSeconds = 1
        XCTAssertEqual(again.gapNarrationSeconds, 5, "alt sınır")
        again.gapNarrationSeconds = 500
        XCTAssertEqual(again.gapNarrationSeconds, 30, "üst sınır")
        XCTAssertEqual(Timing.answerCueEvery, 15, "cevap beklerken 15 saniyede bir bilgi")
    }

    // MARK: Meşgul cümleleri

    func testBusyPhraseNamesTheSilentWork() async {
        let h = harness()
        _ = await h.startListening()
        h.vm.phase = .checking
        XCTAssertEqual(h.vm.busyPhrase, Say.gapChecking)
        h.vm.phase = .recovering
        XCTAssertEqual(h.vm.busyPhrase, Say.gapRepairing)
        h.vm.phase = .answering
        h.vm.statusNote = "Kameraya geçiliyor (hücresel kesiliyor)"
        XCTAssertEqual(h.vm.busyPhrase, Say.gapCameraSwitch)
        h.vm.statusNote = "Kamera kontrol ediliyor (hücresel kesiliyor)"
        XCTAssertEqual(h.vm.busyPhrase, Say.gapCameraSwitch)
        h.vm.statusNote = "İnternete geçiliyor (Wi-Fi bırakılıyor)"
        XCTAssertEqual(h.vm.busyPhrase, Say.gapInternetSwitch)
        h.vm.statusNote = "Kamera bağlantısı onarılıyor (2. deneme)"
        XCTAssertEqual(h.vm.busyPhrase, Say.gapCameraRepair)
        h.vm.statusNote = "Konum uygun — sabit tutun"
        XCTAssertNil(h.vm.busyPhrase, "kamera yönlendirmesi kendi cümlesini söyler")
        h.vm.statusNote = ""
        XCTAssertNil(h.vm.busyPhrase, "cevap beklerken 'Cevap bekleniyor' ayrıca söylenir")
        h.vm.phase = .listening
        XCTAssertNil(h.vm.busyPhrase)
    }

    func testSilentCameraSwitchIsNarratedEveryInterval() async {
        let h = harness(seconds: 10)
        _ = await h.startListening()
        h.vm.phase = .answering
        h.vm.statusNote = "Kameraya geçiliyor (hücresel kesiliyor)"
        h.scheduler.advance(by: 9)
        await settle()
        XCTAssertEqual(count(h, Say.gapCameraSwitch), 0, "daha bir aralık dolmadı")
        h.scheduler.advance(by: 20)
        let first = await waitUntil { self.count(h, Say.gapCameraSwitch) >= 1 }
        XCTAssertTrue(first, "birkaç saniye sessizlikte durum söylenir")
        let spokenOnce = count(h, Say.gapCameraSwitch)
        h.scheduler.advance(by: 30)
        let more = await waitUntil { self.count(h, Say.gapCameraSwitch) > spokenOnce }
        XCTAssertTrue(more, "iş sürdükçe aralıkla tekrarlanır")
        XCTAssertEqual(h.vm.phase, .answering, "bilgi cümlesi aşamayı değiştirmez")
    }

    func testCheckingAndRepairPhasesAreNarrated() async {
        let h = harness(seconds: 10)
        _ = await h.startListening()
        h.vm.phase = .checking
        h.scheduler.advance(by: 25)
        let checking = await waitUntil { self.count(h, Say.gapChecking) >= 1 }
        XCTAssertTrue(checking, "açılış kontrolü uzarsa sessiz kalınmaz: \(h.speaker.spoken)")
        h.vm.phase = .recovering
        h.scheduler.advance(by: 25)
        let repairing = await waitUntil { self.count(h, Say.gapRepairing) >= 1 }
        XCTAssertTrue(repairing, "onarım sürerken sessiz kalınmaz: \(h.speaker.spoken)")
    }

    // MARK: Boşta "Dinliyorum"

    func testIdleListeningSaysDinliyorumAndGoesBackToListening() async {
        let h = harness(seconds: 10)
        _ = await h.startListening()
        h.scheduler.advance(by: 25)
        await settle()
        XCTAssertEqual(count(h, Say.listeningNow), 0, "üç adım sessizlik dolmadan söylenmez")
        h.scheduler.advance(by: 30)
        let said = await waitUntil { self.count(h, Say.listeningNow) == 1 && h.vm.phase == .listening }
        XCTAssertTrue(said, "uzun sessizlikte 'Dinliyorum' denir ve dinlemeye dönülür: \(h.speaker.spoken)")
        XCTAssertEqual(h.vm.listenMode, .question)
    }

    func testIdleCueIsLimitedPerQuestion() async {
        let h = harness(seconds: 10)
        _ = await h.startListening()
        for _ in 0..<12 {
            h.scheduler.advance(by: 40)
            await settle()
        }
        let three = await waitUntil { self.count(h, Say.listeningNow) == 3 }
        XCTAssertTrue(three)
        h.scheduler.advance(by: 400)
        await settle()
        XCTAssertEqual(count(h, Say.listeningNow), 3, "bir soruda en çok üç kez")
    }

    func testNoIdleCueWhileTheUserIsReading() async {
        let h = harness(seconds: 10)
        _ = await h.startListening()
        h.listener.say("Soru beş aşağıdakilerden hangisi")   // okuma sürüyor: metin birikti
        h.scheduler.advance(by: 100)
        await settle()
        XCTAssertEqual(count(h, Say.listeningNow), 0, "kullanıcı soruyu okurken araya girilmez")
    }

    // MARK: Kapalıyken

    func testNothingIsSaidWhenTheSettingIsOff() async {
        let h = harness(narration: false)
        _ = await h.startListening()
        h.scheduler.advance(by: 300)
        await settle()
        XCTAssertEqual(count(h, Say.listeningNow), 0)
        h.vm.phase = .answering
        h.vm.statusNote = "Kameraya geçiliyor (hücresel kesiliyor)"
        h.scheduler.advance(by: 300)
        await settle()
        XCTAssertEqual(count(h, Say.gapCameraSwitch), 0)
    }

    func testTimerStopsWhenTheSessionEnds() async {
        let h = harness(seconds: 10)
        _ = await h.startListening()
        h.vm.endTest()
        h.scheduler.advance(by: 600)
        await settle()
        XCTAssertEqual(count(h, Say.listeningNow), 0)
        XCTAssertNil(h.vm.gapTask, "oturum bitince zamanlayıcı kendini yeniden kurmaz")
    }
}
