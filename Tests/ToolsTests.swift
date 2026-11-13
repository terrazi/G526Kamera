import XCTest
@testable import G526CameraDrive

// MARK: - Düşük şarj uyarısı (ilk sürümden)

final class LowBatteryWatcherTests: XCTestCase {
    func testWarnsOncePerThreshold() {
        var w = LowBatteryWatcher()
        XCTAssertNil(w.update(percent: 60, charging: false))
        XCTAssertNil(w.update(percent: 21, charging: false))
        XCTAssertEqual(w.update(percent: 20, charging: false), 20)
        XCTAssertNil(w.update(percent: 19, charging: false))
        XCTAssertNil(w.update(percent: 12, charging: false))
        XCTAssertEqual(w.update(percent: 10, charging: false), 10)
        XCTAssertNil(w.update(percent: 9, charging: false))
        XCTAssertEqual(w.update(percent: 5, charging: false), 5)
        XCTAssertNil(w.update(percent: 4, charging: false))
    }

    func testResetsWhenChargedAndSkipsWhileCharging() {
        var w = LowBatteryWatcher()
        XCTAssertEqual(w.update(percent: 18, charging: false), 18)
        XCTAssertNil(w.update(percent: 15, charging: true))
        XCTAssertNil(w.update(percent: 40, charging: false))
        XCTAssertEqual(w.update(percent: 19, charging: false), 19, "Dolunca eşikler yeniden sayılır")
        XCTAssertNil(w.update(percent: nil, charging: false))
    }

    func testBigDropWarnsWithLowestThreshold() {
        var w = LowBatteryWatcher()
        XCTAssertEqual(w.update(percent: 4, charging: false), 4)
        XCTAssertNil(w.update(percent: 3, charging: false))
        XCTAssertNil(w.update(percent: 15, charging: false))
    }
}

// MARK: - Cihaz özeti, ses yolu adları, Say metinleri

@MainActor
final class DeviceInfoAndRouteTextTests: XCTestCase {
    func testSummaryHasEveryLine() {
        let text = DeviceInfo.summary(build: "abc123", model: "iPhone", system: "iOS 18.1", battery: 64, charging: true,
                                      thermal: "normal", freeBytes: 5_000_000_000)
        XCTAssertTrue(text.contains("Sürüm: abc123"))
        XCTAssertTrue(text.contains("iPhone, iOS 18.1"))
        XCTAssertTrue(text.contains("yüzde 64 (şarjda)"))
        XCTAssertTrue(text.contains("Isı: normal"))
        XCTAssertTrue(text.contains("GB"))
    }

    func testSummaryHandlesUnknownValues() {
        let text = DeviceInfo.summary(build: "x", model: "m", system: "s", battery: nil, charging: false, thermal: "normal", freeBytes: nil)
        XCTAssertTrue(text.contains("Şarj: okunamıyor"))
        XCTAssertTrue(text.contains("Boş yer: okunamıyor"))
        XCTAssertFalse(text.contains("(şarjda)"))
    }

    func testThermalWords() {
        XCTAssertEqual(DeviceInfo.thermalText(.nominal), "normal")
        XCTAssertEqual(DeviceInfo.thermalText(.critical), "çok sıcak")
    }

    func testRouteDescriptionNamesBothSides() {
        XCTAssertEqual(AudioRouting.describe(FakeRoute.good), "Çıkış: Bluetooth kulaklık. Giriş: Lightning/USB mikrofon.")
        XCTAssertEqual(AudioRouting.describe(FakeRoute.noHeadphones), "Çıkış: telefon hoparlörü. Giriş: Lightning/USB mikrofon.")
        XCTAssertEqual(AudioRouting.describe(FakeRoute.noMic), "Çıkış: Bluetooth kulaklık. Giriş: telefonun kendi mikrofonu.")
        XCTAssertEqual(AudioRouting.describe(RouteSnapshot(outputs: [], inputs: [])), "Çıkış: yok. Giriş: yok.")
    }

    func testSayTexts() {
        XCTAssertEqual(Say.lowBattery(10), "Telefonun şarjı yüzde 10. Telefonu şarja takın.")
        XCTAssertFalse(Say.notConfigured.contains("üç"), "Kestirme sayısı artık dört; metin sayı vermez")
        XCTAssertEqual(SessionPhase.paused(.manual).title, "Duraklatıldı: devam etmek için “Devam et”e basın")
        XCTAssertTrue(SessionPhase.paused(.manual).isRunning, "Elle duraklatılmış test sürüyor sayılır (Başlat açılmaz)")
    }
}

// MARK: - Dokunmatik ekran kilidi (ilk sürümden)

@MainActor
private final class FakeLockPresenter: LockPresenting {
    var canPresent = true
    private(set) var presented = 0
    private(set) var dismissed = 0
    private(set) var onUnlock: (() -> Void)?

    func present(onUnlock: @escaping () -> Void) -> Bool {
        guard canPresent else { return false }
        presented += 1
        self.onUnlock = onUnlock
        return true
    }

    func dismiss() { dismissed += 1 }
}

@MainActor
final class ScreenLockTests: XCTestCase {
    private func make(canPresent: Bool = true) -> (ScreenLock, FakeLockPresenter, () -> [Bool]) {
        let presenter = FakeLockPresenter()
        presenter.canPresent = canPresent
        let lock = ScreenLock(presenter: presenter)
        var events: [Bool] = []
        lock.onChange = { events.append($0) }
        return (lock, presenter, { events })
    }

    func testStartsUnlocked() {
        let (lock, presenter, events) = make()
        XCTAssertFalse(lock.isLocked)
        XCTAssertEqual(presenter.presented, 0)
        XCTAssertTrue(events().isEmpty)
    }

    func testLockShowsWindowAndReports() {
        let (lock, presenter, events) = make()
        XCTAssertTrue(lock.lock())
        XCTAssertTrue(lock.isLocked)
        XCTAssertEqual(presenter.presented, 1)
        XCTAssertEqual(events(), [true])
    }

    func testLockTwiceDoesNotStackWindows() {
        let (lock, presenter, events) = make()
        lock.lock()
        XCTAssertTrue(lock.lock())
        XCTAssertEqual(presenter.presented, 1)
        XCTAssertEqual(events(), [true])
    }

    func testUnlockRemovesWindowAndReports() {
        let (lock, presenter, events) = make()
        lock.lock()
        lock.unlock()
        XCTAssertFalse(lock.isLocked)
        XCTAssertEqual(presenter.dismissed, 1)
        XCTAssertEqual(events(), [true, false])
    }

    func testUnlockWhenNotLockedDoesNothing() {
        let (lock, presenter, events) = make()
        lock.unlock()
        XCTAssertEqual(presenter.dismissed, 0)
        XCTAssertTrue(events().isEmpty)
    }

    func testHoldCallbackFromWindowUnlocks() {
        let (lock, presenter, events) = make()
        lock.lock()
        presenter.onUnlock?()
        XCTAssertFalse(lock.isLocked)
        XCTAssertEqual(events(), [true, false])
    }

    func testWindowThatCannotOpenLeavesScreenUnlocked() {
        let (lock, presenter, events) = make(canPresent: false)
        XCTAssertFalse(lock.lock())
        XCTAssertFalse(lock.isLocked)
        XCTAssertEqual(presenter.presented, 0)
        XCTAssertTrue(events().isEmpty)
    }

    func testCanLockAgainAfterUnlock() {
        let (lock, presenter, events) = make()
        lock.lock()
        lock.unlock()
        XCTAssertTrue(lock.lock())
        XCTAssertEqual(presenter.presented, 2)
        XCTAssertEqual(events(), [true, false, true])
    }

    func testUnlockNeedsThreeSecondHold() {
        XCTAssertEqual(ScreenLock.holdSeconds, 3)
    }
}

// MARK: - Oturumda: şarj uyarısı, elle duraklat / devam et, Sesi dene

@MainActor
final class SessionToolsTests: XCTestCase {
    // Şarj

    func testLowBatteryWarnsInTheRedBoxThenClearsWhenCharging() async {
        let h = SessionHarness()
        _ = await h.startListening()
        XCTAssertNil(h.vm.warnings.first(where: { $0.id == "pil" }))
        h.battery.set(19)
        XCTAssertEqual(h.vm.warnings.first(where: { $0.id == "pil" })?.text, Say.lowBattery(19))
        h.battery.set(18)
        XCTAssertEqual(h.vm.warnings.filter { $0.id == "pil" }.count, 1, "Aynı eşik için tek uyarı")
        h.battery.set(18, charging: true)
        XCTAssertNil(h.vm.warnings.first(where: { $0.id == "pil" }), "Şarja takılınca uyarı kalkar")
    }

    func testBatteryIsIgnoredWhenNoTestIsRunning() {
        let h = SessionHarness()
        h.battery.set(5)
        XCTAssertTrue(h.vm.warnings.isEmpty)
    }

    func testBatteryAlreadyLowAtStartWarnsOnce() async {
        let h = SessionHarness()
        h.battery.percent = 9
        _ = await h.startListening()
        XCTAssertEqual(h.vm.warnings.first(where: { $0.id == "pil" })?.text, Say.lowBattery(9))
    }

    // Duraklat / devam et

    func testPauseButtonOnlyWorksWhileATestRuns() async {
        let h = SessionHarness()
        XCTAssertFalse(h.vm.canPauseByUser)
        h.vm.pauseByUser()
        XCTAssertEqual(h.vm.phase, .idle, "Başlamamış testte duraklatılamaz")
        _ = await h.startListening()
        XCTAssertTrue(h.vm.canPauseByUser)
    }

    func testPauseStopsListeningAndIgnoresSpeech() async {
        let h = SessionHarness()
        _ = await h.startListening()
        let pausesBefore = h.listener.pauseCalls
        h.vm.pauseByUser()
        XCTAssertEqual(h.vm.phase, .paused(.manual))
        XCTAssertGreaterThan(h.listener.pauseCalls, pausesBefore, "Mikrofon kapanır")
        XCTAssertFalse(h.vm.canPauseByUser)
        h.ask("Bu soru duraklatılmışken okundu")
        await settle()
        XCTAssertTrue(h.answering.calls.isEmpty, "Duraklatılmışken hiçbir şey Gemini'ye gitmez")
        XCTAssertEqual(h.vm.liveText, "")
    }

    func testResumeListensAgain() async {
        let h = SessionHarness()
        _ = await h.startListening()
        let startsBefore = h.listener.startCalls
        h.vm.pauseByUser()
        h.vm.resumeByUser()
        let back = await waitUntil { h.vm.phase == .listening }
        XCTAssertTrue(back)
        XCTAssertGreaterThan(h.listener.startCalls, startsBefore, "Devam edince mikrofon yeniden açılır")
    }

    func testResumeWithUnsafeRouteWaitsForHardware() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.vm.pauseByUser()
        h.route.change(to: FakeRoute.noHeadphones)
        h.vm.resumeByUser()
        let waiting = await waitUntil { h.isHardwarePause }
        XCTAssertTrue(waiting, "Kulaklık yokken devam edilmez, donanım beklemesine girilir")
    }

    func testResumeRepeatsAnAnswerThatWasCutOffWhileSpeaking() async {
        let h = SessionHarness()
        h.answering.results = [.success(FakeAnswering.reply(1))]
        _ = await h.startListening()
        h.speaker.hold = true   // "Ben hazırım" anonsu geçti; şimdi cevabın okunması askıda kalır
        h.ask("Bir soru")
        let speaking = await waitUntil { h.vm.phase == .speaking }
        XCTAssertTrue(speaking)
        h.vm.pauseByUser()
        XCTAssertEqual(h.vm.phase, .paused(.manual))
        XCTAssertEqual(h.vm.answers.count, 1, "Cevap kaydedilmişti, kaybolmaz")
        h.speaker.hold = false
        let callsBefore = h.speaker.calls.count
        h.vm.resumeByUser()
        let back = await waitUntil { h.vm.phase == .listening }
        XCTAssertTrue(back)
        XCTAssertGreaterThan(h.speaker.calls.count, callsBefore)
        XCTAssertEqual(h.speaker.spoken.last, "Soru 1, Denizli, Örgütsel Davranış", "Kesilen cevap devam edince yeniden okunur")
    }

    // Sesi dene

    func testSoundTestPlaysThroughHeadphonesAndReportsTheRoute() async {
        let h = SessionHarness()
        h.vm.testSound()
        let done = await waitUntil { !h.vm.testingSound && h.vm.soundTest.contains("duydunuz mu") }
        XCTAssertTrue(done, h.vm.soundTest)
        XCTAssertEqual(h.speaker.spoken, [Say.soundTest])
        XCTAssertTrue(h.vm.soundTest.contains("Çıkış: Bluetooth kulaklık"))
        XCTAssertEqual(h.vm.phase, .idle, "Sesi dene testi başlatmaz")
    }

    func testSoundTestPlaysNothingWithoutHeadphones() async {
        let h = SessionHarness()
        h.route.change(to: FakeRoute.noHeadphones)
        h.vm.testSound()
        let done = await waitUntil { !h.vm.testingSound && !h.vm.soundTest.isEmpty }
        XCTAssertTrue(done)
        XCTAssertTrue(h.speaker.spoken.isEmpty, "Kulaklık yokken ses hiçbir yerden çıkmaz (KURAL 1)")
        XCTAssertTrue(h.vm.soundTest.contains("Kulaklıktan ses çalınamaz"), h.vm.soundTest)
    }

    func testSoundTestWarnsAboutAMissingMic() async {
        let h = SessionHarness()
        h.route.change(to: FakeRoute.noMic)
        h.vm.testSound()
        let done = await waitUntil { !h.vm.testingSound && h.vm.soundTest.contains("mikrofonu görünmüyor") }
        XCTAssertTrue(done, h.vm.soundTest)
        XCTAssertEqual(h.speaker.spoken, [Say.soundTest], "Kulaklık sağlamsa ses yine denenir")
    }

    func testSoundTestIsIgnoredWhileATestRuns() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.vm.testSound()
        XCTAssertFalse(h.vm.testingSound)
        XCTAssertEqual(h.vm.soundTest, "")
    }
}

// MARK: - Ayarlar: ekran kısma, telefon sesi, model seçimi, Gemma düşünme düzeyi

@MainActor
final class SettingsToolsTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        return UserDefaults(suiteName: "g526.testler.arac.\(UUID().uuidString)")!
    }

    func testDimAndVoiceDefaultsAndPersistence() {
        Keychain.testStore = [:]
        defer { Keychain.testStore = nil }
        let defaults = makeDefaults()
        let s = AppSettings(defaults: defaults)
        XCTAssertFalse(s.dimScreen, "Ekran kısma kendiliğinden açılmaz")
        XCTAssertEqual(s.phoneVoiceID, "", "Varsayılan ses Otomatik")
        s.dimScreen = true
        s.phoneVoiceID = "com.apple.voice.premium.tr-TR.Yelda"
        let again = AppSettings(defaults: defaults)
        XCTAssertTrue(again.dimScreen)
        XCTAssertEqual(again.phoneVoiceID, "com.apple.voice.premium.tr-TR.Yelda")
    }

    func testChoosingAModelSetsTheProfileModel() {
        Keychain.testStore = [:]
        defer { Keychain.testStore = nil }
        let settings = AppSettings(defaults: makeDefaults())
        let model = SettingsViewModel(settings: settings, shortcuts: FakeShortcuts())
        model.chooseModel("gemini-9-test", slot: 2)
        XCTAssertEqual(settings.geminiProfiles[1].model, "gemini-9-test")
        XCTAssertEqual(settings.geminiProfiles[0].model, GeminiProfiles.defaultModels[0], "Öbür profiller değişmez")
        XCTAssertEqual(model.keyResults[2]?.ok, true)
        model.chooseModel("x", slot: 9)
        XCTAssertEqual(settings.geminiProfiles.map { $0.model }, [GeminiProfiles.defaultModels[0], "gemini-9-test",
                                                                   GeminiProfiles.defaultModels[2], GeminiProfiles.defaultModels[3]],
                       "Geçersiz yuva yok sayılır")
    }

    func testListingModelsWithoutAKeyAsksForTheKey() async {
        Keychain.testStore = [:]
        defer { Keychain.testStore = nil }
        let model = SettingsViewModel(settings: AppSettings(defaults: makeDefaults()), shortcuts: FakeShortcuts())
        await model.listModels(slot: 1)
        XCTAssertEqual(model.keyResults[1]?.text, Say.noKeyShort)
        XCTAssertEqual(model.listingModelsSlot, 0)
    }

    func testGemmaGetsThinkingLevelButGeminiBodyIsUntouched() throws {
        let body = try GeminiAnswerService.requestBody(question: "soru", expectedNumber: 1)
        XCTAssertEqual(GeminiAnswerService.body(body, forModel: "gemini-3.6-flash"), body, "Gemini modellerine dokunulmaz")
        let gemma = GeminiAnswerService.body(body, forModel: "gemma-4-31b-it")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: gemma) as? [String: Any])
        let config = try XCTUnwrap(object["generationConfig"] as? [String: Any])
        XCTAssertEqual((config["thinkingConfig"] as? [String: String])?["thinkingLevel"], "high")
        XCTAssertNotNil(object["systemInstruction"], "Komut ve soru korunur")
        XCTAssertNotNil(object["contents"])
    }
}
