import XCTest
@testable import G526CameraDrive

final class ModelChoiceListTests: XCTestCase {
    func testChoosableKeepsTextModelsOnlyAndAtMostSeven() {
        let names = ["gemini-3.8-pro", "gemini-3.1-pro-preview", "gemini-3.8-flash", "gemini-3.7-flash", "gemini-3.5-flash",
                     "gemini-3.5-flash-lite", "gemini-3.1-flash-lite", "gemma-4-31b-it", "gemini-3.1-flash-tts-preview",
                     "embedding-001", "gemini-3.1-flash-image-preview", "imagen-4"]
        let list = ModelChoice.choosable(names)
        XCTAssertEqual(list, ["gemini-3.8-pro", "gemini-3.1-pro-preview", "gemini-3.8-flash", "gemini-3.7-flash",
                              "gemini-3.5-flash-lite", "gemini-3.1-flash-lite", "gemma-4-31b-it"])
        XCTAssertFalse(list.contains { $0.contains("tts") || $0.contains("image") || $0.contains("embed") })
        XCTAssertLessThanOrEqual(list.count, 7)
    }

    func testStableVersionBeatsPreviewAndNewestTwoPerFamily() {
        let list = ModelChoice.choosable(["models/gemini-3.8-flash-preview", "models/gemini-3.8-flash", "models/gemini-3.10-flash",
                                          "models/gemini-3.9-flash"])
        XCTAssertEqual(list, ["gemini-3.10-flash", "gemini-3.9-flash"], "3.10, 3.9'dan büyüktür; her aileden en yeni ikisi")
        XCTAssertEqual(ModelChoice.choosable(["gemini-3.8-flash-preview", "gemini-3.8-flash"]), ["gemini-3.8-flash"])
    }

    func testGemmaSizesAreRankedByVersionThenSize() {
        let list = ModelChoice.choosable(["gemma-4-26b-a4b-it", "gemma-4-31b-it", "gemma-3-27b-it"])
        XCTAssertEqual(list, ["gemma-4-31b-it", "gemma-4-26b-a4b-it"])
    }

    func testEmptyAndUnknownNames() {
        XCTAssertEqual(ModelChoice.choosable([]), [])
        XCTAssertEqual(ModelChoice.choosable(["text-bison", "aqa", "chat-x"]), [])
    }

    func testSpokenNames() {
        XCTAssertEqual(ModelChoice.spoken("gemini-3.8-flash"), "Gemini 3 nokta 8 Flash")
        XCTAssertEqual(ModelChoice.spoken("models/gemini-3.1-flash-lite"), "Gemini 3 nokta 1 Flash Lite")
        XCTAssertEqual(ModelChoice.spoken("gemma-4-31b-it"), "Gemma 4 31 B")
        XCTAssertEqual(ModelChoice.spoken("gemma-4-26b-a4b-it"), "Gemma 4 26 B")
        XCTAssertEqual(ModelChoice.spoken("gemini-3.1-pro-preview"), "Gemini 3 nokta 1 Pro önizleme")
    }

    func testAnnouncementMentionsTheCurrentModelAndHowToChoose() {
        let text = ModelChoice.announcement(slot: 1, choices: ["gemini-3.8-pro", "gemini-3.8-flash"], current: "gemini-3.8-flash")
        XCTAssertTrue(text.hasPrefix("Hangi modeli kullanmak istersiniz? Birinci model: Gemini 3 nokta 8 Pro."))
        XCTAssertTrue(text.contains("İkinci model: Gemini 3 nokta 8 Flash, şu anki."))
        XCTAssertTrue(text.contains("tekrarla") && text.contains("vazgeç"))
        XCTAssertTrue(ModelChoice.announcement(slot: 2, choices: ["a"], current: "").hasPrefix("Birinci alternatif model için"))
        XCTAssertTrue(ModelChoice.announcement(slot: 3, choices: ["a"], current: "").hasPrefix("İkinci alternatif model için"))
    }

    func testSlotNamesAndAlternativeIDs() {
        XCTAssertEqual(ModelChoice.slotName(1), "Ana model")
        XCTAssertEqual(ModelChoice.slotName(2), "Birinci alternatif model")
        XCTAssertEqual(ModelChoice.slotName(6), "Beşinci alternatif model")
        XCTAssertTrue(ModelChoice.isAlternativeID("model2"))
        XCTAssertTrue(ModelChoice.isAlternativeID("model6"))
        XCTAssertFalse(ModelChoice.isAlternativeID("model"))
        XCTAssertFalse(ModelChoice.isAlternativeID("modelRepeat"))
        XCTAssertFalse(ModelChoice.isAlternativeID("modelCancel"))
        XCTAssertTrue(ModelChoice.announcement(slot: 6, choices: ["gemini-3.8-flash"], current: "")
            .hasPrefix("Beşinci alternatif model için hangi modeli kullanmak istersiniz?"))
    }

    func testPickPhrases() {
        XCTAssertEqual(ModelChoice.pickPhrases(1), "birinci model, birinci modeli, 1 model, 1 numaralı model")
        XCTAssertEqual(ModelChoice.pickPhrases(3), "üçüncü model, üçüncü modeli, 3 model, 3 numaralı model")
        XCTAssertTrue(ModelChoice.pickPhrases(7).hasPrefix("yedinci model, yedinci modeli, 7 model"))
    }

    func testPhrasesAreRecognisedByTheSpeechMatcher() {
        XCTAssertGreaterThan(SpeechMatcher.occurrences(in: "model değiştir", trigger: ModelChoice.changePhrases), 0)
        XCTAssertGreaterThan(SpeechMatcher.occurrences(in: "birinci alternatif model seç", trigger: ModelChoice.secondPhrases), 0)
        XCTAssertGreaterThan(SpeechMatcher.occurrences(in: "ikinci alternatif model seç", trigger: ModelChoice.thirdPhrases), 0)
        XCTAssertGreaterThan(SpeechMatcher.occurrences(in: "üçüncü alternatif model seç", trigger: ModelChoice.alternativePhrases(slot: 4)), 0)
        XCTAssertGreaterThan(SpeechMatcher.occurrences(in: "dördüncü alternatif model seç", trigger: ModelChoice.alternativePhrases(slot: 5)), 0)
        XCTAssertGreaterThan(SpeechMatcher.occurrences(in: "beşinci alternatif model seç", trigger: ModelChoice.alternativePhrases(slot: 6)), 0)
        XCTAssertGreaterThan(SpeechMatcher.occurrences(in: "5 alternatif model seç", trigger: ModelChoice.alternativePhrases(slot: 6)), 0)
        XCTAssertGreaterThan(SpeechMatcher.occurrences(in: "ikinci model", trigger: ModelChoice.pickPhrases(2)), 0)
        XCTAssertEqual(SpeechMatcher.occurrences(in: "ikinci model", trigger: ModelChoice.pickPhrases(3)), 0)
        XCTAssertGreaterThan(SpeechMatcher.occurrences(in: "tekrarla", trigger: ModelChoice.repeatPhrases), 0)
        XCTAssertGreaterThan(SpeechMatcher.occurrences(in: "vazgeç", trigger: ModelChoice.cancelPhrases), 0)
    }
}

final class ProfileDefaultsTests: XCTestCase {
    func testDefaultModelsAndNamesFollowThePerformanceOrder() {
        let list = GeminiProfiles.defaults()
        XCTAssertEqual(GeminiProfiles.slotCount, 4)
        XCTAssertEqual(list.map { $0.model }, ["gemini-3.6-flash", "gemini-3.5-flash-lite", "gemini-3.1-flash-lite", "gemini-3.1-flash-lite"])
        XCTAssertEqual(list.map { $0.name }, ["Gemini 3.6 Flash", "Gemini 3.5 Flash-Lite", "Gemini 3.1 Flash-Lite", "Ücretli Gemini 3.1 Flash-Lite"])
        XCTAssertEqual(list.map { $0.free }, [true, true, true, false])
        XCTAssertEqual(GeminiConfig.defaultModel, "gemini-3.6-flash")
        XCTAssertEqual(GeminiProfiles.defaultNames, list.map { $0.name })
    }

    func testBusy38FlashAndRetired25ProAreGoneFromTheDefaults() {
        let list = GeminiProfiles.defaults()
        XCTAssertFalse(list.contains { $0.model == "gemini-3.8-flash" || $0.model == "gemini-2.5-pro" })
        XCTAssertFalse(list.contains { $0.name.contains("3.8") || $0.name.contains("2.5") })
        XCTAssertNotEqual(GeminiConfig.defaultModel, "gemini-3.8-flash")
    }

    func testMigrationFillsEmptyModelsAndAppendsMissingSlots() {
        let saved = [GeminiProfile(name: "Model 1", model: "", free: false),
                     GeminiProfile(name: "Flash", model: "", free: false),
                     GeminiProfile(name: "Ücretsiz", model: "", free: false)]
        let list = GeminiProfiles.migrated(saved)
        XCTAssertEqual(list.count, 4, "eksik yuva varsayılanla tamamlanır")
        XCTAssertEqual(list.map { $0.model }, ["gemini-3.6-flash", "gemini-3.5-flash-lite", "gemini-3.1-flash-lite", "gemini-3.1-flash-lite"])
        XCTAssertEqual(list[0].name, "Gemini 3.6 Flash", "boş model + “Model N” adı varsayılanla yenilenir")
        XCTAssertEqual(list[1].name, "Flash", "kullanıcının yazdığı ad korunur")
        XCTAssertTrue(list[1].free, "boş modelli profil varsayılan bayrağını alır")
        XCTAssertFalse(list[3].free)
    }

    func testMigrationKeepsTheUsersOwnNamesAndModels() {
        let saved = [GeminiProfile(name: "A", model: "x", free: false),
                     GeminiProfile(name: "Benim Pro", model: "gemini-3.8-pro", free: false),
                     GeminiProfile(name: "Hızlı", model: "", free: true)]
        let list = GeminiProfiles.migrated(saved)
        XCTAssertEqual(list[0].model, "x")
        XCTAssertFalse(list[0].free, "kullanıcının ücretsiz bayrağı korunur")
        XCTAssertEqual(list[1].name, "Benim Pro")
        XCTAssertEqual(list[1].model, "gemini-3.8-pro")
        XCTAssertEqual(list[2].name, "Hızlı", "kullanıcının adı korunur, yalnız boş model dolar")
        XCTAssertEqual(list[2].model, "gemini-3.1-flash-lite")
    }

    private func legacySix() -> [GeminiProfile] {
        return (1...6).map { GeminiProfile(name: "N\($0)", model: "m\($0)", free: $0 != 6) }
    }

    func testLegacySixProfilesKeepOnlySlots2And4And5And6() {
        let list = GeminiProfiles.profiles(fromLegacy: legacySix())
        XCTAssertEqual(list.map { $0.name }, ["N2", "N4", "N5", "N6"], "eski 1. (3.8 Flash) ve 3. (2.5 Pro) yuva atılır")
        XCTAssertEqual(list.map { $0.model }, ["m2", "m4", "m5", "m6"])
        XCTAssertEqual(list.map { $0.free }, [true, true, true, false], "ücretli bayrağı son profilde kalır")
    }

    func testLegacyDefaultSixBecomeTheNewFourDefaults() {
        let old = [GeminiProfile(name: "Gemini 3.8 Flash", model: "gemini-3.8-flash", free: true),
                   GeminiProfile(name: "Gemini 3.6 Flash", model: "gemini-3.6-flash", free: true),
                   GeminiProfile(name: "Gemini 2.5 Pro", model: "gemini-2.5-pro", free: true),
                   GeminiProfile(name: "Gemini 3.5 Flash-Lite", model: "gemini-3.5-flash-lite", free: true),
                   GeminiProfile(name: "Gemini 3.1 Flash-Lite", model: "gemini-3.1-flash-lite", free: true),
                   GeminiProfile(name: "Ücretli Gemini 3.1 Flash-Lite", model: "gemini-3.1-flash-lite", free: false)]
        XCTAssertEqual(GeminiProfiles.profiles(fromLegacy: old), GeminiProfiles.defaults())
    }

    func testLegacyListOfAnotherSizeFallsBackToDefaults() {
        XCTAssertEqual(GeminiProfiles.profiles(fromLegacy: Array(legacySix().prefix(3))), GeminiProfiles.defaults())
        XCTAssertEqual(GeminiProfiles.profiles(fromLegacy: []), GeminiProfiles.defaults())
    }

    func testLegacySlotNumbersMapToTheNextKeptSlot() {
        XCTAssertEqual((1...6).map { GeminiProfiles.newSlot(fromLegacy: $0) }, [1, 1, 2, 2, 3, 4])
        XCTAssertEqual(GeminiProfiles.newSlot(fromLegacy: 9), 4)
        XCTAssertEqual(GeminiProfiles.newSlot(fromLegacy: 0), 1)
    }
}

@MainActor
final class ModelChooserTests: XCTestCase {
    private var spoken: [String] = []
    private var applied: [(slot: Int, model: String, activate: Bool)] = []
    private var listed: [String] = ["gemini-3.8-pro", "gemini-3.8-flash", "gemini-3.5-flash-lite", "gemini-3.1-flash-tts-preview"]
    private var listError: Error?
    private var requestedKeys: [String] = []
    private var profiles = [GeminiProfileInfo(slot: 1, name: "A", model: "gemini-3.8-flash", key: "k1", free: false),
                            GeminiProfileInfo(slot: 2, name: "B", model: "", key: "k2", free: false),
                            GeminiProfileInfo(slot: 3, name: "C", model: "gemma-4-31b-it", key: "", free: true)]
    private var activeKey = "k1"

    private func makeChooser(timeout: TimeInterval = 60) -> ModelChooser {
        return ModelChooser(profiles: { [unowned self] in self.profiles },
                            activeKey: { [unowned self] in self.activeKey },
                            lister: { [unowned self] key in
                                self.requestedKeys.append(key)
                                if let e = self.listError { throw e }
                                return self.listed
                            },
                            apply: { [unowned self] slot, model, activate in self.applied.append((slot, model, activate)) },
                            say: { [unowned self] text in self.spoken.append(text) },
                            timeout: timeout)
    }

    private func waitUntil(_ seconds: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    func testListIsReadThenPickingWritesTheMainModelAndActivatesIt() async {
        let c = makeChooser()
        c.begin(slot: 1)
        XCTAssertTrue(c.choosing)
        let ok = await waitUntil { self.spoken.count == 1 }
        XCTAssertTrue(ok)
        XCTAssertEqual(c.choices, ["gemini-3.8-pro", "gemini-3.8-flash", "gemini-3.5-flash-lite"])
        XCTAssertTrue(spoken[0].hasPrefix("Hangi modeli kullanmak istersiniz? Birinci model: Gemini 3 nokta 8 Pro."))
        XCTAssertTrue(spoken[0].contains("İkinci model: Gemini 3 nokta 8 Flash, şu anki."))
        XCTAssertEqual(requestedKeys, ["k1"])
        XCTAssertTrue(c.pick(3))
        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(applied[0].slot, 1)
        XCTAssertEqual(applied[0].model, "gemini-3.5-flash-lite")
        XCTAssertTrue(applied[0].activate)
        XCTAssertTrue(spoken.last?.hasPrefix("Ana model, Gemini 3 nokta 5 Flash Lite olarak seçildi.") ?? false)
        XCTAssertTrue(spoken.last?.contains("Şimdi bu model kullanılıyor.") ?? false)
        XCTAssertFalse(c.choosing)
        XCTAssertFalse(c.pick(1), "seçim bitince 'birinci model' yok sayılır")
    }

    func testRepeatReadsTheListAgainAndOutOfRangeKeepsChoosing() async {
        let c = makeChooser()
        c.begin()
        _ = await waitUntil { self.spoken.count == 1 }
        XCTAssertTrue(c.repeatList())
        XCTAssertEqual(spoken.count, 2)
        XCTAssertEqual(spoken[0], spoken[1])
        XCTAssertTrue(c.pick(6))
        XCTAssertTrue(c.choosing)
        XCTAssertEqual(spoken.last, "Listede altıncı model yok.")
        XCTAssertTrue(applied.isEmpty)
    }

    func testCancelLeavesTheModelUnchanged() async {
        let c = makeChooser()
        c.begin()
        _ = await waitUntil { self.spoken.count == 1 }
        XCTAssertTrue(c.cancel())
        XCTAssertEqual(spoken.last, "Model değişmedi.")
        XCTAssertTrue(applied.isEmpty)
        XCTAssertFalse(c.cancel())
        XCTAssertFalse(c.repeatList())
    }

    func testAlternativeSlotsUseTheirOwnKeyAndAskForThem() async {
        let c = makeChooser()
        c.begin(slot: 2)
        _ = await waitUntil { self.spoken.count == 1 }
        XCTAssertEqual(requestedKeys, ["k2"])
        XCTAssertTrue(spoken[0].hasPrefix("Birinci alternatif model için hangi modeli kullanmak istersiniz?"))
        XCTAssertTrue(c.pick(1))
        XCTAssertEqual(applied[0].slot, 2)
        XCTAssertEqual(applied[0].model, "gemini-3.8-pro")
        XCTAssertTrue(applied[0].activate)
        XCTAssertTrue(spoken.last?.hasPrefix("Birinci alternatif model, Gemini 3 nokta 8 Pro olarak seçildi.") ?? false)
    }

    func testProfileWithoutKeyBorrowsTheActiveKeyForTheListButIsNotActivated() async {
        let c = makeChooser()
        c.begin(slot: 3)
        _ = await waitUntil { self.spoken.count == 1 }
        XCTAssertEqual(requestedKeys, ["k1"], "3. profilin anahtarı yok: liste seçili profilin anahtarıyla alınır")
        XCTAssertTrue(spoken[0].hasPrefix("İkinci alternatif model için"))
        XCTAssertTrue(c.pick(2))
        XCTAssertEqual(applied[0].slot, 3)
        XCTAssertFalse(applied[0].activate)
        XCTAssertTrue(spoken.last?.contains("anahtarı girilmediği için") ?? false)
    }

    func testNoKeyAnywhereDoesNotStart() {
        profiles = profiles.map { var p = $0; p.key = ""; return p }
        activeKey = ""
        let c = makeChooser()
        c.begin()
        XCTAssertFalse(c.choosing)
        XCTAssertTrue(spoken.last?.contains("Gemini anahtarı") ?? false)
        XCTAssertTrue(requestedKeys.isEmpty)
    }

    func testListErrorIsSpokenAndChoosingEnds() async {
        listError = GeminiError("Anahtar geçersiz.", .key)
        let c = makeChooser()
        c.begin()
        let ok = await waitUntil { !self.spoken.isEmpty }
        XCTAssertTrue(ok)
        XCTAssertEqual(spoken[0], "Model listesi alınamadı. Anahtar geçersiz.")
        XCTAssertFalse(c.choosing)
    }

    func testEmptyListIsReported() async {
        listed = ["embedding-001", "gemini-3.1-flash-tts-preview"]
        let c = makeChooser()
        c.begin()
        _ = await waitUntil { !self.spoken.isEmpty }
        XCTAssertEqual(spoken[0], "Listelenecek uygun model bulunamadı.")
        XCTAssertFalse(c.choosing)
    }

    func testTimeoutEndsTheChoice() async {
        let c = makeChooser(timeout: 0.2)
        c.begin()
        _ = await waitUntil { self.spoken.count == 1 }
        let ok = await waitUntil { self.spoken.last == "Model değişmedi." }
        XCTAssertTrue(ok)
        XCTAssertFalse(c.choosing)
        XCTAssertTrue(applied.isEmpty)
    }

    func testEndSilentlyDropsALateListResult() async {
        let c = makeChooser()
        c.begin()
        c.end()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(spoken.isEmpty, "seçim bırakılmışsa geç gelen liste okunmaz")
        XCTAssertFalse(c.choosing)
    }
}
