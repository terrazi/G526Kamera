import XCTest
@testable import G526CameraDrive

/// Kamera ayarlarının varsayılanları, kalıcılığı, sınırları ve eski anahtarlardan geçişi.
final class CameraSettingsTests: XCTestCase {
    private func fresh() -> (CameraSettings, UserDefaults) {
        let name = "kamera-ayar-testi-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return (CameraSettings(defaults: d), d)
    }

    override func setUp() {
        super.setUp()
        Keychain.testStore = [:]
    }

    override func tearDown() {
        Keychain.testStore = nil
        super.tearDown()
    }

    private func current(_ s: CameraSettings) -> [String: AnyHashable] {
        return [
            "uid": s.uid, "cameraIP": s.cameraIP, "cameraPassword": s.cameraPassword, "streamQuality": s.streamQuality,
            "jpegQuality": s.jpegQuality, "enhancement": s.enhancement, "deskew": s.deskew, "upscale": s.upscale,
            "timestampMode": s.timestampMode.rawValue, "multiFrame": s.multiFrame, "documentOnly": s.documentOnly,
            "burstBefore": s.burstBefore, "burstAfter": s.burstAfter, "previewOff": s.previewOff, "lastShotOff": s.lastShotOff,
            "guidanceEnabled": s.guidanceEnabled, "guidanceVoice": s.guidanceVoice, "statusNotices": s.statusNotices,
            "imageOrientation": s.imageOrientation.rawValue, "guidanceFrame": s.guidanceFrame,
            "guidanceSharpness": s.guidanceSharpness, "guidanceGlare": s.guidanceGlare, "guidanceDescribe": s.guidanceDescribe,
            "guidancePageEdges": s.guidancePageEdges, "pageVideoSeconds": s.pageVideoSeconds, "videoToGemini": s.videoToGemini,
            "videoQuestion": s.videoQuestion, "videoHighRes": s.videoHighRes, "cameraShortcutName": s.cameraShortcutName,
            "stayOnWifi": s.stayOnWifi, "connectAtStart": s.connectAtStart
        ]
    }

    // MARK: Varsayılanlar

    func testDefaults() {
        let (s, _) = fresh()
        XCTAssertEqual(s.uid, CameraSettings.defaultCameraUID)
        XCTAssertEqual(s.cameraIP, "")
        XCTAssertEqual(s.cameraPassword, "123456")
        XCTAssertEqual(s.streamQuality, 1)
        XCTAssertEqual(s.jpegQuality, 0.92, accuracy: 0.0001)
        XCTAssertEqual(s.timestampMode, .blur)
        XCTAssertTrue(s.multiFrame)
        XCTAssertTrue(s.documentOnly)
        XCTAssertFalse(s.previewOff)
        XCTAssertFalse(s.lastShotOff, "son fotoğraf varsayılan olarak gösterilir")
        XCTAssertTrue(s.guidanceEnabled, "sesli konumlandırma varsayılan açık")
        XCTAssertTrue(s.guidanceVoice)
        XCTAssertTrue(s.statusNotices)
        XCTAssertEqual(s.guidanceFrame, CameraSettings.defaultFrame)
        XCTAssertEqual(s.imageOrientation, .normal)
        XCTAssertEqual(s.guidanceSharpness, 1)
        XCTAssertTrue(s.guidanceGlare)
        XCTAssertFalse(s.guidanceDescribe, "kadraj tarifi varsayılan kapalı")
        XCTAssertTrue(s.guidancePageEdges)
        XCTAssertEqual(s.pageVideoSeconds, VideoRecorder.pageSegmentSeconds)
        XCTAssertTrue(s.videoToGemini)
        XCTAssertEqual(s.videoQuestion, "")
        XCTAssertTrue(s.videoHighRes)
        XCTAssertEqual(s.cameraShortcutName, "")
        XCTAssertFalse(s.stayOnWifi, "varsayılan: Wi-Fi ile hücresel sırayla değişir (kullanıcı kararı 2026-11-16)")
        XCTAssertTrue(s.connectAtStart, "başlatınca kameraya hemen bağlanılır (kullanıcı kararı 2026-11-16)")
    }

    // MARK: Kalıcılık

    func testEverySettingIsPersistedAndReadBack() {
        let (s, d) = fresh()
        s.uid = "ABC123"; s.cameraIP = "192.168.1.9"; s.cameraPassword = "gizli"; s.streamQuality = 2
        s.jpegQuality = 0.8; s.enhancement = 2; s.deskew = true; s.upscale = 1.5; s.timestampMode = .crop
        s.multiFrame = false; s.documentOnly = false; s.burstBefore = 1.0; s.burstAfter = 1.5
        s.previewOff = true; s.lastShotOff = true
        s.guidanceEnabled = false; s.guidanceVoice = false; s.statusNotices = false
        s.guidanceSharpness = 2; s.guidanceGlare = false; s.guidanceDescribe = true; s.guidancePageEdges = false
        s.pageVideoSeconds = 9; s.videoToGemini = false; s.videoQuestion = "yalnız seçenekleri söyle"
        s.videoHighRes = false; s.cameraShortcutName = "Kamera Wifi"; s.stayOnWifi = true; s.connectAtStart = false
        s.guidanceFrame = 1; s.imageOrientation = .left90
        XCTAssertEqual(d.string(forKey: "uid"), "ABC123")
        XCTAssertEqual(d.string(forKey: "cameraIP"), "192.168.1.9")
        XCTAssertEqual(Keychain.get("cameraPassword"), "gizli", "parola Keychain'de")
        XCTAssertNil(d.string(forKey: "cameraPassword"), "parola UserDefaults'ta durmaz")
        XCTAssertEqual(d.integer(forKey: "streamQuality"), 2)
        XCTAssertEqual(d.string(forKey: "timestampMode"), "crop")
        XCTAssertEqual(d.integer(forKey: "imageOrientation"), ImageOrientation.left90.rawValue)
        XCTAssertEqual(d.integer(forKey: "guidanceFrame"), 1)
        XCTAssertEqual(d.string(forKey: "videoQuestion"), "yalnız seçenekleri söyle")
        let t = CameraSettings(defaults: d)
        XCTAssertEqual(current(t), current(s), "yeni örnek hepsini geri okur")
    }

    func testStoredValuesFromAnEarlierInstallAreReadBack() {
        let name = "kamera-eski-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        d.set("G526NEW", forKey: "uid"); d.set(2, forKey: "streamQuality"); d.set("blur", forKey: "timestampMode")
        d.set(false, forKey: "guidanceEnabled"); d.set(true, forKey: "guidanceDescribe"); d.set(11, forKey: "pageVideoSeconds")
        Keychain.set("parola-9", for: "cameraPassword")
        let s = CameraSettings(defaults: d)
        XCTAssertEqual(s.uid, "G526NEW"); XCTAssertEqual(s.streamQuality, 2); XCTAssertEqual(s.pageVideoSeconds, 11)
        XCTAssertEqual(s.cameraPassword, "parola-9")
        XCTAssertFalse(s.guidanceEnabled); XCTAssertTrue(s.guidanceDescribe)
    }

    // MARK: Sınırlar ve geçişler

    func testClampSeconds() {
        XCTAssertEqual(CameraSettings.clampSeconds(nil, range: 10...300, fallback: 90), 90)
        XCTAssertEqual(CameraSettings.clampSeconds(60, range: 10...300, fallback: 90), 60)
        XCTAssertEqual(CameraSettings.clampSeconds(0, range: 10...300, fallback: 90), 10)
        XCTAssertEqual(CameraSettings.clampSeconds(999, range: 10...120, fallback: 30), 120)
    }

    func testPageVideoSecondsAreClampedWhenRead() {
        let name = "kamera-sinir-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        d.set(99, forKey: "pageVideoSeconds")
        XCTAssertEqual(CameraSettings(defaults: d).pageVideoSeconds, 15, "üst sınır")
        d.set(0, forKey: "pageVideoSeconds")
        XCTAssertEqual(CameraSettings(defaults: d).pageVideoSeconds, 2, "alt sınır")
    }

    func testFrameChangeForcesMatchingOrientation() {
        let (s, _) = fresh()
        s.imageOrientation = .rotate180
        s.guidanceFrame = 1
        XCTAssertTrue(s.imageOrientation.isQuarterTurn, "dikey kadrajda görüntü dik çevrilir")
        s.imageOrientation = .left90
        s.guidanceFrame = 0
        XCTAssertFalse(s.imageOrientation.isQuarterTurn, "yatay kadrajda dik çevrilmez")
    }

    func testOldSettingsAreMigrated() {
        let name = "kamera-gecis-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        d.set(true, forKey: "cropTimestamp")
        d.set(true, forKey: "guidanceFlip")
        let s = CameraSettings(defaults: d)
        XCTAssertEqual(s.timestampMode, .crop, "eski 'saat yazısını kes' kutusu")
        XCTAssertEqual(s.imageOrientation, .rotate180, "eski 'kamera ters takılı' kutusu")
        XCTAssertNil(d.object(forKey: "guidanceFlip"), "eski anahtar silinir")
    }

    func testOrientationHelpers() {
        XCTAssertEqual(CameraSettings.orientations(forFrame: 1), [.right90, .left90])
        XCTAssertEqual(CameraSettings.orientations(forFrame: 0), [.normal, .rotate180])
        XCTAssertEqual(CameraSettings.defaultFrame, 0)
        XCTAssertEqual(CameraSettings.defaultCameraUID, "G526029XJPDT")
    }
}
