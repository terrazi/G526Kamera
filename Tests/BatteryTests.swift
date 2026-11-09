import XCTest
@testable import G526CameraDrive

/// "Batarya kontrol" sesli komutu ve düşük şarj uyarısı
final class BatteryTests: XCTestCase {
    private func hits(_ text: String) -> Int {
        return GuidanceVocabulary.batteryIntent.count(in: text)
    }

    func testManyWaysToAskForBattery() {
        for t in ["batarya kontrol", "şarj durumu nedir", "şarj durumu", "pil durumu nedir", "pil ne kadar", "telefonun şarjı ne kadar",
                  "kameranın şarjı", "batarya ne kadar kaldı", "şarjım kaç", "bataryayı kontrol et", "pil kaç"] {
            XCTAssertGreaterThan(hits(t), 0, t)
        }
    }

    func testOtherSpeechDoesNotAskForBattery() {
        for t in ["tamam", "rapor ver", "durum nedir", "hepsini gönder", "sayfayı çevir", "kaç sayfa çekildi", "son fotoğrafı sil",
                  "yeniden çek", "okey", "pilav yapalım", "pirinç", "pilot geldi", "özet ver"] {
            XCTAssertEqual(hits(t), 0, t)
        }
    }

    func testSpokenBatterySentence() {
        XCTAssertEqual(SpokenReport.battery(phone: 72, charging: false, camera: 55),
                       "Telefon yüzde 72, kamera yüzde 55 dolu görünüyor.")
        XCTAssertEqual(SpokenReport.battery(phone: 72, charging: true, camera: nil),
                       "Telefon yüzde 72 ve şarjda, kameranın şarj bilgisi alınamıyor.")
        XCTAssertTrue(SpokenReport.battery(phone: nil, charging: false, camera: nil).contains("okunamıyor"))
        XCTAssertTrue(SpokenReport.battery(phone: 15, charging: false, camera: nil).hasSuffix("Telefon şarjı düşük."))
        XCTAssertFalse(SpokenReport.battery(phone: 15, charging: true, camera: nil).contains("düşük"))
        XCTAssertTrue(SpokenReport.battery(phone: 80, charging: false, camera: 12).hasSuffix("Kamera şarjı düşük."))
    }

    func testLowBatteryWarnsOncePerThreshold() {
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

    func testLowBatteryResetsWhenChargedAndSkipsWhileCharging() {
        var w = LowBatteryWatcher()
        XCTAssertEqual(w.update(percent: 18, charging: false), 18)
        XCTAssertNil(w.update(percent: 15, charging: true))                       // şarjda: uyarma
        XCTAssertNil(w.update(percent: 40, charging: false))                      // doldu, sıfırlandı
        XCTAssertEqual(w.update(percent: 19, charging: false), 19)                // yeniden düşünce tekrar uyarır
        XCTAssertNil(w.update(percent: nil, charging: false))
    }

    func testBigDropWarnsWithLowestThreshold() {
        var w = LowBatteryWatcher()
        XCTAssertEqual(w.update(percent: 4, charging: false), 4)
        XCTAssertNil(w.update(percent: 3, charging: false))
        XCTAssertNil(w.update(percent: 15, charging: false))                      // 5 eşiği zaten söylendi, 10/20 yeniden sayılmaz
    }

    func testCameraBatteryFieldIsReadOnlyWhenPresent() {
        XCTAssertNil(CameraProbe.batteryPercent(in: ["cmd": "GetDevInfo", "id": "X", "wifisig": 3, "lock": 2]))
        XCTAssertEqual(CameraProbe.batteryPercent(in: ["cmd": "GetDevInfo", "battery": 64]), 64)
        XCTAssertEqual(CameraProbe.batteryPercent(in: ["cmd": "GetDevInfo", "Bat": "77%"]), 77)
        XCTAssertNil(CameraProbe.batteryPercent(in: ["cmd": "GetDevInfo", "battery": 250]))      // yüzde olamaz
    }
}

/// OCR ayarları
final class OcrSettingsTests: XCTestCase {
    func testLanguageCorrectionOnlyWhenTurkishIsFirst() {
        XCTAssertTrue(OcrRecognizer.useLanguageCorrection(for: ["tr-TR", "en-US"]))
        XCTAssertTrue(OcrRecognizer.useLanguageCorrection(for: ["TR-tr"]))
        XCTAssertFalse(OcrRecognizer.useLanguageCorrection(for: ["en-US", "tr-TR"]))
        XCTAssertFalse(OcrRecognizer.useLanguageCorrection(for: ["en-US"]))
        XCTAssertFalse(OcrRecognizer.useLanguageCorrection(for: []))
    }

    func testMinimumTextHeightIsSmallButSane() {
        XCTAssertGreaterThan(OcrConfig.minimumTextHeight, 0.002)
        XCTAssertLessThan(OcrConfig.minimumTextHeight, 1.0 / 32.0)
    }
}
