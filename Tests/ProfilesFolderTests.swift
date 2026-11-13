import XCTest
@testable import G526CameraDrive

// MARK: - Gemini profilleri ve anahtarları (ayar saklama)

final class GeminiProfileSettingsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Keychain.testStore = [:]
    }

    override func tearDown() {
        Keychain.testStore = nil
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        return UserDefaults(suiteName: "g526.testler.profil.\(UUID().uuidString)")!
    }

    func testFourProfilesStartWithDefaults() {
        let s = AppSettings(defaults: makeDefaults())
        XCTAssertEqual(s.geminiProfiles.count, GeminiProfiles.slotCount)
        XCTAssertEqual(s.geminiProfiles.map { $0.name }, GeminiProfiles.defaultNames)
        XCTAssertEqual(s.geminiProfiles.map { $0.model }, GeminiProfiles.defaultModels)
        XCTAssertEqual(s.geminiProfiles.map { $0.free }, [true, true, true, false], "Dördüncü profil ücretli anahtardır")
        XCTAssertEqual(s.geminiKeys, ["", "", "", ""])
        XCTAssertTrue(s.usableGeminiProfiles.isEmpty, "Anahtarsız profil kullanılmaz")
        XCTAssertEqual(s.primaryKey, "")
    }

    func testProfilesAndKeysPersistSeparately() {
        let defaults = makeDefaults()
        let s = AppSettings(defaults: defaults)
        s.geminiProfiles[1].model = "benim-modelim"
        s.geminiProfiles[1].name = "Yedek"
        s.geminiProfiles[3].free = true
        s.geminiKeys[0] = "  KEY-A  "
        s.geminiKeys[3] = "KEY-D"

        let again = AppSettings(defaults: defaults)
        XCTAssertEqual(again.geminiProfiles[1].model, "benim-modelim")
        XCTAssertEqual(again.geminiProfiles[1].name, "Yedek")
        XCTAssertTrue(again.geminiProfiles[3].free)
        XCTAssertEqual(again.geminiKeys, ["KEY-A", "", "", "KEY-D"], "Anahtarlar Keychain'den, kırpılmış gelir")
        XCTAssertNil(defaults.string(forKey: "v3.geminiKeyV3"), "Anahtar UserDefaults'a yazılmaz")
        XCTAssertFalse((defaults.data(forKey: "v3.geminiProfiles").map { String(decoding: $0, as: UTF8.self) } ?? "").contains("KEY-A"))
    }

    func testOldSingleKeyBecomesTheFirstProfileKey() {
        Keychain.testStore = [GeminiProfiles.keychainName(slot: 1): "ESKI-ANAHTAR"]
        let s = AppSettings(defaults: makeDefaults())
        XCTAssertEqual(s.geminiKeys[0], "ESKI-ANAHTAR")
        XCTAssertEqual(GeminiProfiles.keychainName(slot: 1), "geminiKeyV3", "Tek anahtarlı sürümün adı korunur")
        XCTAssertEqual(GeminiProfiles.keychainName(slot: 4), "geminiKeyV3_4")
    }

    func testOnlyProfilesWithKeyAndModelAreUsable() {
        let s = AppSettings(defaults: makeDefaults())
        s.geminiKeys[1] = "K2"
        s.geminiKeys[2] = "K3"
        s.geminiProfiles[2].model = "   "
        XCTAssertEqual(s.usableGeminiProfiles.map { $0.slot }, [2], "Modeli boş profil zincire girmez")
        XCTAssertEqual(s.primaryKey, "K2", "İlk kullanılabilir profilin anahtarı sağlık yoklamasında kullanılır")
        XCTAssertEqual(s.geminiProfileInfos().count, 4)
    }

    func testMigratedFillsMissingSlotsAndBlankModels() {
        let saved = [GeminiProfile(name: "", model: "", free: false), GeminiProfile(name: "Benim", model: "x-model", free: true)]
        let list = GeminiProfiles.migrated(saved)
        XCTAssertEqual(list.count, 4)
        XCTAssertEqual(list[0].name, GeminiProfiles.defaultNames[0])
        XCTAssertEqual(list[0].model, GeminiProfiles.defaultModels[0])
        XCTAssertFalse(list[0].free, "Kullanıcının ücretli/ücretsiz seçimi korunur")
        XCTAssertEqual(list[1].name, "Benim")
        XCTAssertEqual(list[1].model, "x-model")
        XCTAssertEqual(list[3].model, GeminiProfiles.defaultModels[3])
        XCTAssertEqual(GeminiProfiles.migrated(Array(repeating: saved[1], count: 9)).count, 4)
    }

    func testKeyKindLabelFollowsTheKey() {
        XCTAssertEqual(GeminiProfiles.keyKindLabel(free: true), "Ücretsiz anahtar")
        XCTAssertEqual(GeminiProfiles.keyKindLabel(free: false), "Ücretli anahtar")
        XCTAssertEqual(GeminiProfiles.displayName(GeminiProfile(name: "  ", model: "m", free: true), slot: 3), "3. model")
    }
}

// MARK: - Kayıt klasörü (Dosyalar uygulamasından seçilen klasör)

final class FolderStoreTests: XCTestCase {
    private func makeStore() -> (FolderStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: "g526.testler.klasor.\(UUID().uuidString)")!
        return (FolderStore(defaults: defaults), defaults)
    }

    private func samePath(_ a: URL, _ b: URL) -> Bool {
        return a.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path
    }

    func testNothingChosenFallsBackWithAWarning() {
        let (store, _) = makeStore()
        store.refresh()
        XCTAssertEqual(store.state, .notChosen)
        XCTAssertFalse(store.hasChoice)
        let fallback = makeTempFolder("yedek")
        let resolution = store.resolution(fallback: fallback)
        XCTAssertEqual(resolution.url, fallback)
        XCTAssertTrue(resolution.warning?.contains("seçilmedi") ?? false)
        XCTAssertEqual(store.statusText(), "Klasör seçilmedi")
    }

    func testChosenFolderIsReadyAndWritable() throws {
        let (store, _) = makeStore()
        let dir = makeTempFolder("secilen")
        try store.choose(dir)
        guard case .ready(let url) = store.state else { return XCTFail("Klasör hazır olmalıydı: \(store.state)") }
        XCTAssertTrue(samePath(url, dir))
        XCTAssertTrue(store.hasChoice)
        let resolution = store.resolution(fallback: makeTempFolder("yedek"))
        XCTAssertNil(resolution.warning)
        XCTAssertTrue(samePath(resolution.url, dir))
        XCTAssertTrue(store.statusText().contains("yazılabiliyor"))
    }

    func testChoiceSurvivesANewStoreInstance() throws {
        let (store, defaults) = makeStore()
        let dir = makeTempFolder("kalici")
        try store.choose(dir)
        let again = FolderStore(defaults: defaults)
        again.refresh()
        guard case .ready(let url) = again.state else { return XCTFail("Seçim uygulama yeniden açılınca da geçerli olmalı") }
        XCTAssertTrue(samePath(url, dir))
    }

    func testDeletedFolderBecomesUnavailableAndFallsBack() throws {
        let (store, _) = makeStore()
        let dir = makeTempFolder("silinecek")
        try store.choose(dir)
        try FileManager.default.removeItem(at: dir)
        store.refresh()
        guard case .unavailable = store.state else { return XCTFail("Silinen klasör erişilemez sayılmalı: \(store.state)") }
        let fallback = makeTempFolder("yedek")
        let resolution = store.resolution(fallback: fallback)
        XCTAssertEqual(resolution.url, fallback)
        XCTAssertNotNil(resolution.warning, "Klasör kaybolursa kırmızı uyarı çıkar")
    }

    func testForgetReturnsToNotChosen() throws {
        let (store, _) = makeStore()
        try store.choose(makeTempFolder("unutulacak"))
        store.forget()
        XCTAssertEqual(store.state, .notChosen)
        XCTAssertFalse(store.hasChoice)
    }

    func testTestFileIsWrittenOnlyToAChosenFolder() throws {
        let (store, _) = makeStore()
        XCTAssertThrowsError(try store.writeTestFile(), "Klasör seçilmeden deneme dosyası yazılmaz")
        let dir = makeTempFolder("deneme")
        try store.choose(dir)
        let url = try store.writeTestFile()
        XCTAssertEqual(url.lastPathComponent, "deneme.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(samePath(url.deletingLastPathComponent(), dir))
    }

    func testAnswerLibraryFollowsTheResolverAndRefreshes() throws {
        let dir = makeTempFolder("kitaplik")
        var refreshed = 0
        let library = AnswerLibrary(resolver: { (url: dir, warning: "uyarı") }, refresh: { refreshed += 1 })
        XCTAssertEqual(library.root, dir)
        XCTAssertEqual(library.warning, "uyarı")
        library.prepare()
        XCTAssertEqual(refreshed, 1, "Oturum başında klasör yeniden denetlenir")
        let folder = try library.newSessionFolder(for: Date())
        XCTAssertTrue(folder.path.hasPrefix(dir.path), "Gün klasörü seçilen kökün içinde açılır")
    }

    func testPlainRootHasNoWarning() {
        let library = AnswerLibrary(root: makeTempFolder("duz"))
        XCTAssertNil(library.warning)
        library.prepare()
    }
}

// MARK: - Oturum: klasör uyarısı, mikrofon listesi, soru listesi, Gemini anahtar yoklaması, Bluetooth

@MainActor
final class SessionMainScreenTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Keychain.testStore = [:]
    }

    override func tearDown() {
        Keychain.testStore = nil
        super.tearDown()
    }

    // Kayıt klasörü

    func testMissingFolderWarnsButTheSessionStillStarts() async {
        let root = makeTempFolder("uygulama-klasoru")
        let library = AnswerLibrary(resolver: { (url: root, warning: "Kayıt klasörü seçilmedi.") }, refresh: {})
        let h = SessionHarness(library: library)
        let started = await h.startListening()
        XCTAssertTrue(started, "Klasör seçilmemesi testi engellemez")
        XCTAssertEqual(h.vm.warnings.first(where: { $0.id == "klasor" })?.text, "Kayıt klasörü seçilmedi.")
        XCTAssertEqual(h.vm.checkup.first(where: { $0.id == "klasor" })?.ok, false)
    }

    func testChosenFolderLeavesNoWarning() async {
        let h = SessionHarness()
        let started = await h.startListening()
        XCTAssertTrue(started)
        XCTAssertNil(h.vm.warnings.first(where: { $0.id == "klasor" }))
        XCTAssertEqual(h.vm.checkup.first(where: { $0.id == "klasor" })?.ok, true)
    }

    // Mikrofon listesi

    func testMicListShowsOnlyExternalInputs() {
        let h = SessionHarness()
        h.route.inputs = [InputChoice(uid: "builtin", name: "iPhone Mikrofonu", port: .builtInMic, isCurrent: true),
                          InputChoice(uid: "lightning", name: "Boya Mikrofon", port: .usbAudio, isCurrent: false)]
        h.vm.refreshInputs()
        XCTAssertEqual(h.vm.inputs.map { $0.uid }, ["lightning"], "Telefonun kendi mikrofonu listede çıkmaz")
    }

    func testChoosingAMicSelectsItAndClearsTheWarning() {
        let h = SessionHarness()
        h.route.inputs = [InputChoice(uid: "a", name: "Mikrofon A", port: .usbAudio, isCurrent: true),
                          InputChoice(uid: "b", name: "Mikrofon B", port: .headsetMic, isCurrent: false)]
        h.vm.warn("giris", "eski")
        h.vm.chooseInput("b")
        XCTAssertEqual(h.route.selectedUIDs, ["b"])
        XCTAssertNil(h.vm.warnings.first(where: { $0.id == "giris" }))
        XCTAssertEqual(h.vm.inputs.first(where: { $0.isCurrent })?.uid, "b")
    }

    func testChoosingAMissingMicWarns() {
        let h = SessionHarness()
        h.vm.chooseInput("yok")
        XCTAssertNotNil(h.vm.warnings.first(where: { $0.id == "giris" }), "Seçilemeyen mikrofon kırmızı kutuda yazılır")
    }

    // Soru listesi (yüklenen soru + gidiş işareti)

    func testQuestionAppearsWithSentMarkAfterTheAnswerArrives() async {
        let h = SessionHarness()
        h.answering.results = [.success(FakeAnswering.reply(1))]
        _ = await h.startListening()
        h.ask("Birinci soru metni")
        let done = await waitUntil { (h.vm.questions.first.map { $0.state != .sending } ?? false) && h.vm.phase == .listening }
        XCTAssertTrue(done)
        XCTAssertEqual(h.vm.questions.count, 1)
        let entry = h.vm.questions[0]
        XCTAssertEqual(entry.text, "Birinci soru metni", "Tetikleyici sözcük listeye girmez")
        XCTAssertEqual(entry.number, 1)
        XCTAssertEqual(entry.model, "fake")
        XCTAssertTrue(entry.withAudio)
        XCTAssertEqual(entry.state, .answered("Soru 1, Denizli, Örgütsel Davranış"))
    }

    func testQuestionsStayInOrderWithOneEntryEach() async {
        let h = SessionHarness()
        h.answering.results = [.success(FakeAnswering.reply(1)), .success(FakeAnswering.reply(2, option: "Bursa", text: "Pazarlama"))]
        _ = await h.startListening()
        h.ask("Birinci soru")
        var done = await waitUntil { h.vm.answers.count == 1 && h.vm.phase == .listening }
        XCTAssertTrue(done)
        h.ask("İkinci soru")
        done = await waitUntil { h.vm.answers.count == 2 && h.vm.phase == .listening }
        XCTAssertTrue(done)
        XCTAssertEqual(h.vm.questions.map { $0.text }, ["Birinci soru", "İkinci soru"])
        XCTAssertEqual(h.vm.questions.map { $0.number }, [1, 2])
        XCTAssertEqual(h.vm.questions.map { $0.id }, [1, 2])
        XCTAssertTrue(h.vm.questions.allSatisfy { if case .answered = $0.state { return true } else { return false } })
    }

    func testAudioFlagFollowsTheSetting() async {
        let h = SessionHarness()
        h.settings.sendAudio = false
        h.answering.results = [.success(FakeAnswering.reply(1))]
        _ = await h.startListening()
        h.ask("Bir soru")
        let done = await waitUntil { h.vm.questions.first.map { $0.state != .sending } ?? false }
        XCTAssertTrue(done)
        XCTAssertEqual(h.vm.questions.first?.withAudio, false)
    }

    func testFailedQuestionIsMarkedNotSentWithTheReason() async {
        let h = SessionHarness()
        h.answering.results = [.failure(GeminiError("Model bulunamadı.", .model))]
        _ = await h.startListening()
        h.ask("Gitmeyecek soru")
        let done = await waitUntil { h.vm.phase == .listening && h.vm.questions.count == 1 }
        XCTAssertTrue(done)
        XCTAssertEqual(h.vm.questions[0].state, .failed("Model bulunamadı."))
        XCTAssertTrue(h.vm.answers.isEmpty)
    }

    func testNewSessionStartsWithAnEmptyList() async {
        let h = SessionHarness()
        h.answering.results = [.success(FakeAnswering.reply(1))]
        _ = await h.startListening()
        h.ask("Bir soru")
        _ = await waitUntil { h.vm.answers.count == 1 && h.vm.phase == .listening }
        h.vm.endTest()
        XCTAssertEqual(h.vm.questions.count, 1, "Test bitince liste ekranda kalır")
        h.vm.start()
        XCTAssertTrue(h.vm.questions.isEmpty, "Yeni test boş listeyle başlar")
    }

    // Gemini anahtar yoklaması (başlangıç kontrolü)

    func testStartupPingsTheNextProfileWhenTheFirstKeyIsRejected() async {
        let h = SessionHarness()
        h.settings.geminiKeys = ["K1", "K2", "", ""]
        h.health.geminiResults = ["K1": .keyRejected("geçersiz")]
        let started = await h.startListening()
        XCTAssertTrue(started, "İkinci profil sağlamsa test başlar")
        XCTAssertEqual(h.health.geminiKeysAsked, ["K1", "K2"])
        let text = h.vm.warnings.first(where: { $0.id == "anahtar" })?.text ?? ""
        XCTAssertTrue(text.contains(GeminiProfiles.defaultNames[0]), "Bozuk profil kırmızı kutuda adıyla yazılır: \(text)")
    }

    func testStartupDoesNotWarnWhenTheFirstKeyWorks() async {
        let h = SessionHarness()
        h.settings.geminiKeys = ["K1", "K2", "", ""]
        let started = await h.startListening()
        XCTAssertTrue(started)
        XCTAssertEqual(h.health.geminiKeysAsked, ["K1"], "İlk anahtar sağlamsa diğerleri yoklanmaz")
        XCTAssertNil(h.vm.warnings.first(where: { $0.id == "anahtar" }))
    }

    // Bluetooth yenileme sırası

    func testForcedHardwareRecoveryAfterAListenerFailureSkipsBluetoothRefresh() {
        XCTAssertEqual(RecoveryReason.hardware.steps(force: true), [.reset])
        XCTAssertEqual(RecoveryReason.hardware.steps(force: false), [.bluetooth, .reset])
    }
}
