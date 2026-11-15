import XCTest
@testable import G526CameraDrive

/// V1'in kamera ayarlarının V4'e eksiksiz ve aynı anahtar / varsayılanlarla taşındığının mantıksal denetimi.
/// `v1Keys` ve `v1Defaults` V1 kaynağından (Settings.swift) mekanik olarak çıkarıldı, elle yazılmadı.
final class CameraSettingsTests: XCTestCase {
    /// V1 `Settings.swift` içinde UserDefaults / Keychain'e yazılan bütün anahtarlar
    static let v1Keys: [String] = [
        "audioLayout",
        "audioShortcutName",
        "batchIdle",
        "batchSize",
        "burstAfter",
        "burstBefore",
        "cameraIP",
        "cameraShortcutName",
        "connectionShortcutName",
        "cooldown",
        "deskew",
        "dimScreen",
        "documentOnly",
        "enhancement",
        "examCancelWindow",
        "examEnabled",
        "examGap",
        "examPageVideo",
        "examSelfCheck",
        "examVideoFirst",
        "examVideoMaxSeconds",
        "finishWord",
        "geminiActive",
        "geminiAutoFallback",
        "geminiBatchLast",
        "geminiCallWord",
        "geminiCapMonth",
        "geminiCapPrev",
        "geminiChainFallback",
        "geminiDocCount",
        "geminiEnabled",
        "geminiMemory",
        "geminiOptionCodes",
        "geminiOverloadFallback",
        "geminiPrivacyOK",
        "geminiProfiles",
        "geminiSession",
        "geminiSessionTimeout",
        "geminiThinking",
        "geminiWaitLimit",
        "guidanceAutoCapture",
        "guidanceAutoPick",
        "guidanceDescribe",
        "guidanceEnabled",
        "guidanceFrame",
        "guidanceGlare",
        "guidancePageEdges",
        "guidanceSharpness",
        "guidanceVoice",
        "imageOrientation",
        "jpegQuality",
        "listenEnd",
        "listenSilence",
        "motionEnabled",
        "motionSensitivity",
        "multiFrame",
        "pageVideoSeconds",
        "previewOff",
        "repairCheckSeconds",
        "repairChecks",
        "repairWaitSeconds",
        "sendMode",
        "speechRate",
        "speechVoiceID",
        "statusNotices",
        "streamQuality",
        "timestampMode",
        "triggerWord",
        "uid",
        "uploadFormat",
        "upscale",
        "videoGuidance",
        "videoHighRes",
        "videoMaxSeconds",
        "videoQuestion",
        "videoSendMode",
        "videoToGemini",
        "voiceEnabled",
        "cameraPassword"
    ]

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

    // MARK: Eksiksizlik

    /// V1'deki her ayar ya V4'te (bir bölümde) vardır ya da gerekçesiyle dışarıda bırakılmıştır; üçüncü bir durum yoktur
    func testEveryV1SettingIsEitherPortedOrExcludedWithReason() {
        let ported = Set(CameraSettings.allKeys)
        let excluded = Set(CameraSettings.excluded.map { $0.key })
        for key in Self.v1Keys {
            XCTAssertTrue(ported.contains(key) || excluded.contains(key), "V1 ayarı hesapta yok: \(key)")
            XCTAssertFalse(ported.contains(key) && excluded.contains(key), "hem alındı hem dışarıda: \(key)")
        }
        let v4Only = Set(CameraSettings.v4Only.map { $0.key })
        XCTAssertTrue(v4Only.isSubset(of: ported), "V4'e özgü ayar listede değil")
        XCTAssertTrue(v4Only.isDisjoint(with: Set(Self.v1Keys)), "V4'e özgü diye yazılan ayar V1'de var")
        for item in CameraSettings.v4Only { XCTAssertGreaterThan(item.reason.count, 10, "gerekçe yok: \(item.key)") }
        XCTAssertTrue(ported.subtracting(v4Only).isSubset(of: Set(Self.v1Keys)), "V1'de olmayan anahtar: \(ported.subtracting(v4Only).subtracting(Self.v1Keys))")
        XCTAssertTrue(excluded.isSubset(of: Set(Self.v1Keys)), "V1'de olmayan dışarıda anahtar: \(excluded.subtracting(Self.v1Keys))")
        XCTAssertEqual(ported.subtracting(v4Only).count + excluded.count, Set(Self.v1Keys).count)
        for item in CameraSettings.excluded { XCTAssertGreaterThan(item.reason.count, 10, "gerekçe yok: \(item.key)") }
        XCTAssertEqual(CameraSettings.excluded.count, Set(CameraSettings.excluded.map { $0.key }).count, "tekrarlı dışarıda anahtar")
    }

    /// Her ayar ekranda tam bir bölümde görünür (bir bölüm iki kez göstermez, hiçbiri açıkta kalmaz)
    func testEverySettingAppearsInExactlyOneSettingsGroup() {
        var seen: [String: CameraSettings.Group] = [:]
        for group in CameraSettings.Group.allCases {
            XCTAssertFalse(group.keys.isEmpty, "boş bölüm: \(group)")
            XCTAssertFalse(group.title.isEmpty)
            for key in group.keys {
                XCTAssertNil(seen[key], "\(key) iki bölümde: \(String(describing: seen[key])) ve \(group)")
                seen[key] = group
            }
        }
        XCTAssertEqual(Set(seen.keys), Set(CameraSettings.allKeys))
    }

    // MARK: Varsayılanlar (V1 ile aynı, belgelenmiş sapmalar hariç)

    /// V1 `init()` içindeki varsayılan değerler (kaynaktan çıkarıldı). Sapmalar `CameraSettings.deviations` içindedir.
    private func v1Defaults() -> [String: AnyHashable] {
        return [
            "uid": CameraSettings.defaultCameraUID, "cameraIP": "", "cameraPassword": "123456", "streamQuality": 1,
            "voiceEnabled": true, "triggerWord": "okey", "cooldown": 4.0,
            "jpegQuality": 0.92, "enhancement": 1, "deskew": false, "upscale": 1.0, "timestampMode": "blur",
            "multiFrame": true, "documentOnly": true, "burstBefore": 0.4, "burstAfter": 0.8,
            "motionEnabled": false, "motionSensitivity": 1, "previewOff": false,
            "guidanceEnabled": false, "guidanceVoice": true, "videoGuidance": true, "statusNotices": true,
            "guidanceAutoCapture": true, "imageOrientation": 0, "guidanceFrame": 0, "guidanceSharpness": 1,
            "guidanceGlare": true, "guidanceDescribe": true, "guidancePageEdges": true, "guidanceAutoPick": true,
            "examVideoMaxSeconds": 90, "pageVideoSeconds": 5, "videoToGemini": true, "videoQuestion": "",
            "videoHighRes": true, "cameraShortcutName": ""
        ]
    }

    private func current(_ s: CameraSettings) -> [String: AnyHashable] {
        return [
            "uid": s.uid, "cameraIP": s.cameraIP, "cameraPassword": s.cameraPassword, "streamQuality": s.streamQuality,
            "voiceEnabled": s.voiceEnabled, "triggerWord": s.triggerWord, "cooldown": s.cooldown,
            "jpegQuality": s.jpegQuality, "enhancement": s.enhancement, "deskew": s.deskew, "upscale": s.upscale,
            "timestampMode": s.timestampMode.rawValue, "multiFrame": s.multiFrame, "documentOnly": s.documentOnly,
            "burstBefore": s.burstBefore, "burstAfter": s.burstAfter, "motionEnabled": s.motionEnabled,
            "motionSensitivity": s.motionSensitivity, "previewOff": s.previewOff, "guidanceEnabled": s.guidanceEnabled,
            "guidanceVoice": s.guidanceVoice, "videoGuidance": s.videoGuidance, "statusNotices": s.statusNotices,
            "guidanceAutoCapture": s.guidanceAutoCapture, "imageOrientation": s.imageOrientation.rawValue,
            "guidanceFrame": s.guidanceFrame, "guidanceSharpness": s.guidanceSharpness, "guidanceGlare": s.guidanceGlare,
            "guidanceDescribe": s.guidanceDescribe, "guidancePageEdges": s.guidancePageEdges, "guidanceAutoPick": s.guidanceAutoPick,
            "examVideoMaxSeconds": s.examVideoMaxSeconds, "pageVideoSeconds": s.pageVideoSeconds, "videoToGemini": s.videoToGemini,
            "videoQuestion": s.videoQuestion, "videoHighRes": s.videoHighRes, "cameraShortcutName": s.cameraShortcutName
        ]
    }

    func testDefaultsMatchV1ExceptDocumentedDeviations() {
        let (s, _) = fresh()
        let now = current(s)
        let v1 = v1Defaults()
        // tablo bütün ayarları kapsıyor mu
        let v4Only = Set(CameraSettings.v4Only.map { $0.key })
        XCTAssertEqual(Set(v1.keys).union(v4Only), Set(CameraSettings.allKeys), "varsayılan tablosu ayar listesiyle örtüşmüyor")
        XCTAssertFalse(s.lastShotOff, "V4'e özgü \"son fotoğrafı gösterme\" varsayılanı: gösterilir")
        let deviating = Set(CameraSettings.deviations.map { $0.key })
        for (key, expected) in v1 {
            let actual = now[key]
            if deviating.contains(key) {
                XCTAssertNotEqual(actual, expected, "\(key) sapma olarak listelenmiş ama V1'le aynı")
            } else {
                XCTAssertEqual(actual, expected, "\(key) varsayılanı V1'den farklı")
            }
        }
        for d in CameraSettings.deviations {
            XCTAssertGreaterThan(d.reason.count, 20, "sapmanın gerekçesi yok: \(d.key)")
            XCTAssertNotEqual(d.v1, d.v4)
        }
        XCTAssertTrue(s.guidanceEnabled, "V4'te sesli konumlandırma varsayılan açık")
        XCTAssertFalse(s.guidanceDescribe, "kadraj tarifi / bölünüyor uyarıları varsayılan kapalı")
    }

    // MARK: Kalıcılık

    func testEverySettingIsPersistedUnderItsV1Key() {
        let (s, d) = fresh()
        s.uid = "ABC123"; s.cameraIP = "192.168.1.9"; s.cameraPassword = "gizli"; s.streamQuality = 2
        s.voiceEnabled = false; s.triggerWord = "tamam"; s.cooldown = 7
        s.jpegQuality = 0.8; s.enhancement = 2; s.deskew = true; s.upscale = 1.5; s.timestampMode = .crop
        s.multiFrame = false; s.documentOnly = false; s.burstBefore = 1.0; s.burstAfter = 1.5
        s.motionEnabled = true; s.motionSensitivity = 2; s.previewOff = true
        s.guidanceEnabled = false; s.guidanceVoice = false; s.videoGuidance = false; s.statusNotices = false
        s.guidanceAutoCapture = false; s.guidanceSharpness = 2; s.guidanceGlare = false; s.guidanceDescribe = true
        s.guidancePageEdges = false; s.guidanceAutoPick = false
        s.examVideoMaxSeconds = 120; s.pageVideoSeconds = 9; s.videoToGemini = false; s.videoQuestion = "yalnız seçenekleri söyle"
        s.videoHighRes = false; s.cameraShortcutName = "Kamera Wifi"
        s.guidanceFrame = 1; s.imageOrientation = .left90
        // V1'deki anahtar adlarıyla UserDefaults'a yazıldı
        XCTAssertEqual(d.string(forKey: "uid"), "ABC123")
        XCTAssertEqual(d.string(forKey: "cameraIP"), "192.168.1.9")
        XCTAssertEqual(Keychain.get("cameraPassword"), "gizli", "parola Keychain'de")
        XCTAssertNil(d.string(forKey: "cameraPassword"), "parola UserDefaults'ta durmaz")
        XCTAssertEqual(d.integer(forKey: "streamQuality"), 2)
        XCTAssertEqual(d.string(forKey: "timestampMode"), "crop")
        XCTAssertEqual(d.integer(forKey: "imageOrientation"), ImageOrientation.left90.rawValue)
        XCTAssertEqual(d.integer(forKey: "guidanceFrame"), 1)
        XCTAssertEqual(d.string(forKey: "videoQuestion"), "yalnız seçenekleri söyle")
        // yeni örnek hepsini geri okur
        let t = CameraSettings(defaults: d)
        XCTAssertEqual(current(t), current(s))
    }

    func testPersistedValuesAreReadBackThroughEveryKey() {
        // V1 / V3 kurulu telefonda eski değerler: aynı anahtarlarla yazılmış değerler V4'te kendiliğinden gelir
        let name = "kamera-eski-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        d.set("G526NEW", forKey: "uid"); d.set(2, forKey: "streamQuality"); d.set("blur", forKey: "timestampMode")
        d.set(true, forKey: "guidanceEnabled"); d.set(false, forKey: "guidanceDescribe"); d.set(11, forKey: "pageVideoSeconds")
        Keychain.set("parola-9", for: "cameraPassword")
        let s = CameraSettings(defaults: d)
        XCTAssertEqual(s.uid, "G526NEW"); XCTAssertEqual(s.streamQuality, 2); XCTAssertEqual(s.pageVideoSeconds, 11)
        XCTAssertEqual(s.cameraPassword, "parola-9")
        XCTAssertTrue(s.guidanceEnabled); XCTAssertFalse(s.guidanceDescribe)
    }

    // MARK: Sınırlar ve geçişler

    func testClampSeconds() {
        XCTAssertEqual(CameraSettings.clampSeconds(nil, range: 10...300, fallback: 90), 90)
        XCTAssertEqual(CameraSettings.clampSeconds(60, range: 10...300, fallback: 90), 60)
        XCTAssertEqual(CameraSettings.clampSeconds(0, range: 10...300, fallback: 90), 10)
        XCTAssertEqual(CameraSettings.clampSeconds(999, range: 10...120, fallback: 30), 120)
    }

    func testVideoSecondsAreClampedWhenRead() {
        let name = "kamera-sinir-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        d.set(5000, forKey: "examVideoMaxSeconds"); d.set(99, forKey: "pageVideoSeconds")
        var s = CameraSettings(defaults: d)
        XCTAssertEqual(s.examVideoMaxSeconds, 300, "üst sınır"); XCTAssertEqual(s.pageVideoSeconds, 15, "üst sınır")
        d.set(1, forKey: "examVideoMaxSeconds"); d.set(0, forKey: "pageVideoSeconds")
        s = CameraSettings(defaults: d)
        XCTAssertEqual(s.examVideoMaxSeconds, 10, "alt sınır"); XCTAssertEqual(s.pageVideoSeconds, 2, "alt sınır")
        let (fresh, _) = self.fresh()
        XCTAssertEqual(fresh.examVideoMaxSeconds, Int(VideoRecorder.examMaxSeconds))
        XCTAssertEqual(fresh.pageVideoSeconds, VideoRecorder.pageSegmentSeconds)
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

    func testOrientationHelpersMatchV1() {
        XCTAssertEqual(CameraSettings.orientations(forFrame: 1), [.right90, .left90])
        XCTAssertEqual(CameraSettings.orientations(forFrame: 0), [.normal, .rotate180])
        XCTAssertEqual(CameraSettings.defaultFrame, 0)
        XCTAssertEqual(CameraSettings.defaultCameraUID, "G526029XJPDT")
    }
}
