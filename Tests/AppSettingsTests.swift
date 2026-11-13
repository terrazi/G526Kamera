import XCTest
@testable import G526CameraDrive

/// Yeni sürümün ayar varsayılanları ve sınırları (kullanıcının kararlarıyla uyumlu olmalı)
final class AppSettingsTests: XCTestCase {
    private let keys = ["questionTotal", "optionCount", "groupSize", "geminiInput", "readyRepeatSeconds", "readyMaxMinutes", "maxAttempts",
                        "scanMaxMinutes", "missingWaitSeconds", "guidanceSharpness", "shortcutTries", "shortcutWaitSeconds",
                        "geminiWaitLimit", "answerPauseSeconds", "repeatPauseSeconds", "timestampMode", "previewOff", "dimScreen",
                        "jpegQuality", "sharpenImages", "cameraShortcutName", "connectionShortcutName", "geminiOptionCodes"]

    private func clear() {
        for k in keys { UserDefaults.standard.removeObject(forKey: k) }
    }

    override func setUp() {
        super.setUp()
        Keychain.testStore = [:]
        clear()
    }

    override func tearDown() {
        clear()
        Keychain.testStore = nil
        super.tearDown()
    }

    func testClamp() {
        XCTAssertEqual(AppSettings.clamp(nil, range: 10...300, fallback: 90), 90)
        XCTAssertEqual(AppSettings.clamp(60, range: 10...300, fallback: 90), 60)
        XCTAssertEqual(AppSettings.clamp(0, range: 10...300, fallback: 90), 10)
        XCTAssertEqual(AppSettings.clamp(999, range: 10...120, fallback: 30), 120)
    }

    func testFreshInstallDefaults() {
        let s = AppSettings()
        XCTAssertEqual(s.questionTotal, 0, "soru sayısı her sınavdan önce girilir")
        XCTAssertEqual(s.optionCount, 5)
        XCTAssertEqual(s.groupSize, 1)
        XCTAssertEqual(s.geminiInput, 0, "varsayılan: akıllı (temiz sorular metin, şüpheliler PDF)")
        XCTAssertEqual(s.readyRepeatSeconds, 30)
        XCTAssertEqual(s.readyMaxMinutes, 10)
        XCTAssertEqual(s.maxAttempts, 5)
        XCTAssertEqual(s.scanMaxMinutes, 15)
        XCTAssertEqual(s.missingWaitSeconds, 60)
        XCTAssertEqual(s.guidanceSharpness, 1)
        XCTAssertEqual(s.shortcutTries, 30)
        XCTAssertEqual(s.shortcutWaitSeconds, 60, "bekleme 1 dakika (2 dakika değil)")
        XCTAssertEqual(s.geminiWaitLimit, 30)
        XCTAssertEqual(s.answerPauseSeconds, 3)
        XCTAssertEqual(s.repeatPauseSeconds, 5)
        XCTAssertEqual(s.timestampMode, .blur)
        XCTAssertEqual(s.jpegQuality, 0.92, accuracy: 0.0001)
        XCTAssertTrue(s.sharpenImages)
        XCTAssertFalse(s.previewOff)
        XCTAssertFalse(s.dimScreen)
        XCTAssertEqual(s.cameraShortcutName, "")
        XCTAssertEqual(s.connectionShortcutName, "")
        XCTAssertEqual(s.geminiProfiles.count, GeminiProfiles.slotCount)
        XCTAssertEqual(s.geminiKeys.count, GeminiProfiles.slotCount)
        XCTAssertEqual(s.geminiOptionCodes, GeminiConfig.defaultOptionCodes)
    }

    func testStoredValuesAreClamped() {
        let d = UserDefaults.standard
        d.set(9999, forKey: "questionTotal")
        d.set(9, forKey: "groupSize")
        d.set(7, forKey: "optionCount")
        d.set(-4, forKey: "maxAttempts")
        d.set(1, forKey: "readyRepeatSeconds")
        d.set(0, forKey: "shortcutTries")
        d.set(5000, forKey: "shortcutWaitSeconds")
        d.set(5, forKey: "guidanceSharpness")
        let s = AppSettings()
        XCTAssertEqual(s.questionTotal, 300)
        XCTAssertEqual(s.groupSize, 3)
        XCTAssertEqual(s.optionCount, 5)
        XCTAssertEqual(s.maxAttempts, 0)
        XCTAssertEqual(s.readyRepeatSeconds, 10)
        XCTAssertEqual(s.shortcutTries, 1)
        XCTAssertEqual(s.shortcutWaitSeconds, 3600)
        XCTAssertEqual(s.guidanceSharpness, 2)
    }

    func testFourOptionsIsKept() {
        UserDefaults.standard.set(4, forKey: "optionCount")
        XCTAssertEqual(AppSettings().optionCount, 4)
    }

    func testOrientationFollowsFrame() {
        XCTAssertEqual(AppSettings.orientation(.normal, forFrame: 1), .right90)
        XCTAssertEqual(AppSettings.orientation(.left90, forFrame: 1), .left90)
        XCTAssertEqual(AppSettings.orientation(.right90, forFrame: 0), .normal)
        XCTAssertEqual(AppSettings.orientation(.rotate180, forFrame: 0), .rotate180)
        XCTAssertEqual(AppSettings.orientations(forFrame: 0), [.normal, .rotate180])
        XCTAssertEqual(AppSettings.orientations(forFrame: 1), [.right90, .left90])
    }
}
