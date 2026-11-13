import XCTest
@testable import G526CameraDrive

/// 6 profilli eski düzenden 4 profilli yeni düzene geçiş (Keychain düzen işareti ve eski anahtarların silinmesi)
final class GeminiLayoutMigrationTests: XCTestCase {
    private let d = UserDefaults.standard
    private var savedProfiles: Data?
    private var savedActive: Any?

    override func setUp() {
        super.setUp()
        savedProfiles = d.data(forKey: "geminiProfiles")
        savedActive = d.object(forKey: "geminiActive")
        // İmzasız benzetici derlemede gerçek Keychain çalışmaz: bellekteki sahte depo kullanılır
        Keychain.testStore = [:]
    }

    override func tearDown() {
        Keychain.testStore = nil
        d.set(savedProfiles, forKey: "geminiProfiles")
        d.set(savedActive, forKey: "geminiActive")
        super.tearDown()
    }

    private func legacySix() -> [GeminiProfile] {
        return (1...6).map { GeminiProfile(name: "N\($0)", model: "m\($0)", free: $0 != 6) }
    }

    func testOldLayoutKeysAreDeletedAndProfilesMovedToTheFourSlots() {
        for slot in 1...6 { Keychain.set("eski-anahtar-\(slot)", for: GeminiProfiles.keychainName(slot: slot)) }
        Keychain.remove(GeminiProfiles.layoutMarker)
        d.set(try? JSONEncoder().encode(legacySix()), forKey: "geminiProfiles")
        d.set(5, forKey: "geminiActive")

        let s = AppSettings()

        XCTAssertEqual(s.geminiKeys, ["", "", "", ""], "eski anahtarlar silinir (kullanıcı yeniden girecek)")
        for slot in 1...6 { XCTAssertNil(Keychain.get(GeminiProfiles.keychainName(slot: slot)), "\(slot). yuva") }
        XCTAssertEqual(s.geminiProfiles.map { $0.name }, ["N2", "N4", "N5", "N6"])
        XCTAssertEqual(s.geminiActive, 3, "eski 5. profil yeni 3. olur")
        XCTAssertEqual(Keychain.get(GeminiProfiles.layoutMarker), GeminiProfiles.layoutVersion)
        XCTAssertEqual(d.integer(forKey: "geminiActive"), 3, "yeni sayı kalıcı yazılır")
        let stored = (d.data(forKey: "geminiProfiles")).flatMap { try? JSONDecoder().decode([GeminiProfile].self, from: $0) }
        XCTAssertEqual(stored?.map { $0.name }, ["N2", "N4", "N5", "N6"], "yeni liste kalıcı yazılır")
    }

    func testSecondLaunchDoesNotTouchTheNewKeysOrShiftAnything() {
        for slot in 1...GeminiProfiles.legacySlotCount { Keychain.remove(GeminiProfiles.keychainName(slot: slot)) }
        Keychain.set(GeminiProfiles.layoutVersion, for: GeminiProfiles.layoutMarker)
        Keychain.set("AQ.yeni-1", for: GeminiProfiles.keychainName(slot: 1))
        Keychain.set("AQ.yeni-4", for: GeminiProfiles.keychainName(slot: 4))
        d.set(try? JSONEncoder().encode(GeminiProfiles.defaults()), forKey: "geminiProfiles")
        d.set(3, forKey: "geminiActive")

        let s = AppSettings()

        XCTAssertEqual(s.geminiKeys, ["AQ.yeni-1", "", "", "AQ.yeni-4"], "yeni düzende anahtarlar korunur")
        XCTAssertEqual(s.geminiActive, 3, "yeni düzende seçili profil değişmez")
        XCTAssertEqual(s.geminiProfiles, GeminiProfiles.defaults())
    }

    func testFreshInstallGetsTheFourDefaultsAndTheMarker() {
        Keychain.remove(GeminiProfiles.layoutMarker)
        d.removeObject(forKey: "geminiProfiles")
        d.removeObject(forKey: "geminiActive")

        let s = AppSettings()

        XCTAssertEqual(s.geminiProfiles, GeminiProfiles.defaults())
        XCTAssertEqual(s.geminiKeys.count, GeminiProfiles.slotCount)
        XCTAssertEqual(s.geminiActive, 1)
        XCTAssertEqual(Keychain.get(GeminiProfiles.layoutMarker), GeminiProfiles.layoutVersion)
    }

    func testUnreadableMarkerDoesNotDeleteKeysWhenProfilesAreAlreadyFour() {
        // Keychain geçici okunamadı (işaret yok) ama kayıtlı profil sayısı 4: yeni düzendir, anahtarlar silinmemeli
        Keychain.set("AQ.yeni-2", for: GeminiProfiles.keychainName(slot: 2))
        Keychain.remove(GeminiProfiles.layoutMarker)
        d.set(try? JSONEncoder().encode(GeminiProfiles.defaults()), forKey: "geminiProfiles")
        d.set(2, forKey: "geminiActive")

        let s = AppSettings()

        XCTAssertEqual(s.geminiKeys, ["", "AQ.yeni-2", "", ""])
        XCTAssertEqual(s.geminiActive, 2, "seçili profil kaymaz")
        XCTAssertEqual(Keychain.get(GeminiProfiles.layoutMarker), GeminiProfiles.layoutVersion, "işaret yeniden yazılır")
    }
}
