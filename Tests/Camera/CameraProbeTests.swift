import XCTest
@testable import G526CameraDrive

/// Kamera sorgusu yalnız okuma komutları gönderir ve pil/güç alanlarını işaretler
final class CameraProbeTests: XCTestCase {
    func testOnlyReadCommandsAreSent() {
        for name in CameraProbe.all {
            XCTAssertTrue(name.hasPrefix("Get"), name)
            XCTAssertFalse(name.hasPrefix("Set") || name.hasPrefix("Open") || name.hasPrefix("Login") || name.hasPrefix("Appoint"), name)
        }
        XCTAssertEqual(Set(CameraProbe.all).count, CameraProbe.all.count, "tekrar eden komut var")
    }

    func testCommandJSONIsWellFormed() {
        let json = CameraCommand.object([("cmd", "GetBattery")])
        XCTAssertEqual(json, "{\"cmd\":\"GetBattery\"}")
    }

    func testBatteryFieldIsFlagged() {
        let reply: [String: Any] = ["cmd": "GetDevInfo", "id": "X", "battery": 80, "charging": 1, "wifisig": 3]
        let hints = CameraProbe.hints(in: reply)
        XCTAssertTrue(hints.contains("battery=80"))
        XCTAssertTrue(hints.contains("charging=1"))
        XCTAssertFalse(hints.contains { $0.hasPrefix("wifisig") })
        XCTAssertTrue(CameraProbe.format(name: "GetDevInfo", reply: reply).contains("OLASI PİL/GÜÇ"))
    }

    func testRealDeviceInfoReplyHasNoBatteryField() {
        // Gerçek kameradan alınan GetDevInfo cevabı (rapor dosyasından)
        let reply: [String: Any] = ["cmd": "GetDevInfo", "id": "GHBB-526029-XJPDT", "ver": "Mar 16 2026 14:28:19", "4G": 2,
                                    "4Gssid": "", "4Gpwd": "", "4Gsig": 0, "wifissid": "", "wifipwd": "123456789",
                                    "wifisig": 0, "ip": "192.168.100.1", "iccid": "", "ledstatus": 0, "lightstatus": 1, "lock": 2]
        XCTAssertTrue(CameraProbe.hints(in: reply).isEmpty)
        let line = CameraProbe.format(name: "GetDevInfo", reply: reply)
        XCTAssertFalse(line.contains("OLASI"))
    }

    func testNoReplyAndSummary() {
        XCTAssertEqual(CameraProbe.format(name: "GetBattery", reply: nil), "GetBattery: cevap yok")
        XCTAssertTrue(CameraProbe.summary(lines: ["a", "b"]).contains("bulunamadı"))
        XCTAssertTrue(CameraProbe.summary(lines: ["GetX: {} ◀ OLASI PİL/GÜÇ: battery=5"]).contains("bulundu"))
    }
}
