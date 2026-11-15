import XCTest
@testable import G526CameraDrive

/// Düşük şarj uyarısı ve kamera pil kademeleri
final class BatteryTests: XCTestCase {
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
}

/// Kameranın görüntü karesi başlığındaki pil bilgisi
final class CameraBatteryTests: XCTestCase {
    /// Gerçek kameradan alınmış 83 baytlık kare başlığı örneği (ofset 25'te float 3.0 → kademe 2, yaklaşık yarı)
    private static let sampleHeader: [UInt8] = [
        0x01, 0xaf, 0xaf, 0xaf, 0x7b, 0xf4, 0x0a, 0x0b, 0xb7, 0x0d, 0x40, 0x68, 0xc9, 0x6f, 0x25, 0xe8, 0x17, 0x6a, 0x9d, 0x49,
        0xb3, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x40, 0x88, 0x5d, 0x5a, 0x0e, 0x03, 0x45, 0x75, 0xf8, 0x0c, 0xf9, 0x01,
        0xbf, 0xce, 0x1c, 0x00, 0x00, 0x00, 0xab, 0x6f, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x77, 0x51, 0x6a, 0x2f, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x78, 0x00, 0x0a, 0xb4, 0x00, 0x00, 0x00, 0x32, 0xc4, 0x18, 0xf8, 0xac, 0x5c, 0x58, 0x79, 0xa8,
        0x1c, 0x00, 0x00]

    private func header(code: Float) -> [UInt8] {
        var h = [UInt8](repeating: 0, count: VideoFrameParser.headerSize)
        let bits = code.bitPattern
        for k in 0..<4 { h[CameraBattery.headerOffset + k] = UInt8((bits >> UInt32(8 * k)) & 0xFF) }
        return h
    }

    func testSampleHeaderSize() {
        XCTAssertEqual(Self.sampleHeader.count, VideoFrameParser.headerSize)
    }

    func testRealHeaderDecodesToHalf() {
        XCTAssertEqual(CameraBattery.decode(header: Self.sampleHeader), .level(2))
    }

    func testCodesMapToLevels() {
        XCTAssertEqual(CameraBattery.decode(header: header(code: 1)), .level(0))
        XCTAssertEqual(CameraBattery.decode(header: header(code: 2)), .level(1))
        XCTAssertEqual(CameraBattery.decode(header: header(code: 5)), .level(4))
        XCTAssertEqual(CameraBattery.decode(header: header(code: 99)), .charging)
        XCTAssertEqual(CameraBattery.decode(header: header(code: 3.9)), .level(2))      // kesir atılır
    }

    func testUnknownCodesAreIgnored() {
        XCTAssertNil(CameraBattery.decode(header: header(code: 0)))
        XCTAssertNil(CameraBattery.decode(header: header(code: 6)))
        XCTAssertNil(CameraBattery.decode(header: header(code: -1)))
        XCTAssertNil(CameraBattery.decode(header: header(code: .nan)))
        XCTAssertNil(CameraBattery.decode(header: header(code: .infinity)))
        XCTAssertNil(CameraBattery.decode(header: header(code: 1e9)))
        XCTAssertNil(CameraBattery.decode(header: [1, 2, 3]))
    }

    func testPhrasesAreEstimatesNotExactPercent() {
        XCTAssertEqual(CameraBattery.phrase(.level(1)), "kamera şarjı tahminen yüzde 20 ile 40 arasında")
        XCTAssertEqual(CameraBattery.phrase(.level(3)), "kamera şarjı tahminen yüzde 60 ile 80 arasında")
        XCTAssertTrue(CameraBattery.lowWarning(level: 0).contains("yüzde 20'nin altında"))
        XCTAssertTrue(CameraBattery.lowWarning(level: 1).contains("yüzde 20 ile 40"))
    }

    func testMonitorNeedsStableFrames() {
        let m = CameraBatteryMonitor()
        let h = header(code: 3)
        for i in 1..<CameraBatteryMonitor.stableFrames {
            XCTAssertNil(m.feed(header: h, now: Double(i)))
        }
        XCTAssertEqual(m.feed(header: h, now: 10), .level(2))
        XCTAssertNil(m.feed(header: h, now: 11))                       // aynı değer yeniden bildirilmez
        XCTAssertEqual(m.current(now: 12), .level(2))
    }

    func testMonitorIgnoresSingleGlitchFrame() {
        let m = CameraBatteryMonitor()
        let good = header(code: 4)
        for i in 0..<CameraBatteryMonitor.stableFrames { _ = m.feed(header: good, now: Double(i)) }
        XCTAssertNil(m.feed(header: header(code: 1), now: 20))         // tek bozuk kare
        XCTAssertNil(m.feed(header: good, now: 21))
        XCTAssertEqual(m.current(now: 22), .level(3))
    }

    func testMonitorFollowsRealChange() {
        let m = CameraBatteryMonitor()
        for i in 0..<CameraBatteryMonitor.stableFrames { _ = m.feed(header: header(code: 4), now: Double(i)) }
        var changed: CameraBatteryLevel?
        for i in 0..<CameraBatteryMonitor.stableFrames { changed = m.feed(header: header(code: 3), now: Double(100 + i)) ?? changed }
        XCTAssertEqual(changed, .level(2))
        var charging: CameraBatteryLevel?
        for i in 0..<CameraBatteryMonitor.stableFrames { charging = m.feed(header: header(code: 99), now: Double(200 + i)) ?? charging }
        XCTAssertEqual(charging, .charging)
    }

    func testMonitorValueGoesStaleAndResets() {
        let m = CameraBatteryMonitor()
        for i in 0..<CameraBatteryMonitor.stableFrames { _ = m.feed(header: header(code: 3), now: Double(i)) }
        XCTAssertEqual(m.current(now: 10), .level(2))
        XCTAssertNil(m.current(now: 7 + CameraBatteryMonitor.maxAge + 1))      // eski bilgi güncel sayılmaz
        m.reset()
        XCTAssertNil(m.current(now: 10))
    }

    func testMonitorIgnoresFramesWithoutBatteryValue() {
        let m = CameraBatteryMonitor()
        for i in 0..<20 { XCTAssertNil(m.feed(header: header(code: 0), now: Double(i))) }
        XCTAssertNil(m.current(now: 21))
    }

    func testLowWarningOncePerLevelAndResets() {
        var w = CameraLowBatteryWatcher()
        XCTAssertNil(w.update(.level(4)))
        XCTAssertNil(w.update(.level(2)))
        XCTAssertEqual(w.update(.level(1)), 1)
        XCTAssertNil(w.update(.level(1)))
        XCTAssertEqual(w.update(.level(0)), 0)
        XCTAssertNil(w.update(.level(0)))
        XCTAssertNil(w.update(.level(1)))                              // 1'i zaten söyledik
        XCTAssertNil(w.update(.charging))                              // şarjda: sıfırlanır
        XCTAssertEqual(w.update(.level(1)), 1)                         // yeniden düşünce tekrar uyarır
        XCTAssertNil(w.update(.level(3)))
        XCTAssertEqual(w.update(.level(0)), 0)
    }

    func testFirstValueAlreadyLowWarnsOnce() {
        var w = CameraLowBatteryWatcher()
        XCTAssertEqual(w.update(.level(0)), 0)
        XCTAssertNil(w.update(.level(0)))
    }

    func testFrameParserKeepsHeaderSoBatteryCanBeRead() {
        var stream = Self.sampleHeader
        let payload: [UInt8] = [1, 2, 3, 4, 5]
        let n = UInt32(payload.count)
        for k in 0..<4 { stream[VideoFrameParser.lengthOffset + k] = UInt8((n >> UInt32(8 * k)) & 0xFF) }
        stream += payload + [0xF4, 0xF3, 0xF2, 0xF1]
        let frames = VideoFrameParser().append(stream, gapBefore: false)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(CameraBattery.decode(header: frames[0].header), .level(2))
    }
}
