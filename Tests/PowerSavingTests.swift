import XCTest
import CoreVideo
@testable import G526CameraDrive

/// Pil tasarrufu (önizleme kapalı): ekrana video gitmez, analiz seyrekleşir, ekran kısılıp geri verilir; varsayılan kapalıdır.
final class PowerSavingTests: XCTestCase {
    private func planarBuffer() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &pb)
        let buffer = pb!
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let p = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<180 { for x in 0..<320 { p[y * stride + x] = UInt8((x * 3 + y * 5) % 256) } }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    /// Analiz kuyruğundan geçen kare sayısı (onAnalyzed çağrıları)
    private final class Counter {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func analyzedCount(saving: Bool) -> Int {
        let pipeline = FramePipeline()
        let counter = Counter()
        pipeline.onAnalyzed = { _, _, _ in counter.increment() }
        pipeline.saving = saving
        for i in 0..<10 {
            pipeline.handle(planarBuffer(), time: Double(i))
            // Analiz kuyruğu boşalana kadar beklenir (yoğun makinede birikme sınırına takılıp kare atlanmasın)
            let expected = saving ? (i + 2) / 2 : i + 1
            let limit = Date().addingTimeInterval(5)
            while counter.count < expected && Date() < limit { usleep(10_000) }
        }
        usleep(200_000)
        return counter.count
    }

    func testDefaultsKeepPreviewOn() {
        let d = UserDefaults.standard
        d.removeObject(forKey: "previewOff")
        d.removeObject(forKey: "dimScreen")
        let s = AppSettings()
        XCTAssertFalse(s.previewOff, "önizleme varsayılan olarak açık olmalı")
        XCTAssertFalse(s.dimScreen, "ekran kısma varsayılan olarak kapalı olmalı")
    }

    func testPreviewAndDimTogglesAreIndependentAndPersist() {
        let s = AppSettings()
        s.previewOff = false
        s.dimScreen = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "dimScreen"))
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "previewOff"))
        s.previewOff = true
        s.dimScreen = false
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "previewOff"))
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "dimScreen"))
        UserDefaults.standard.removeObject(forKey: "previewOff")
        UserDefaults.standard.removeObject(forKey: "dimScreen")
    }

    func testSavingModeAnalyzesEveryOtherFrame() {
        XCTAssertEqual(analyzedCount(saving: false), 10)
        XCTAssertEqual(analyzedCount(saving: true), 5)
    }

    @MainActor
    func testScreenDimmerRestoresBrightness() {
        let dimmer = ScreenDimmer.shared
        dimmer.update(dim: false)
        XCTAssertFalse(dimmer.isDimmed)
        dimmer.update(dim: true)
        XCTAssertTrue(dimmer.isDimmed)
        dimmer.update(dim: true)            // ikinci kez kısmak asıl parlaklığı ezmemeli
        XCTAssertTrue(dimmer.isDimmed)
        dimmer.update(dim: false)
        XCTAssertFalse(dimmer.isDimmed)
    }

    @MainActor
    func testDimmedBrightnessIsRememberedOnDiskAndClearedAfterRestore() {
        let dimmer = ScreenDimmer.shared
        let defaults = UserDefaults.standard
        dimmer.update(dim: false)
        defaults.removeObject(forKey: ScreenDimmer.savedKey)
        dimmer.update(dim: true)
        XCTAssertNotNil(defaults.object(forKey: ScreenDimmer.savedKey), "çökmeye karşı diske yazılmalı")
        dimmer.update(dim: false)
        XCTAssertNil(defaults.object(forKey: ScreenDimmer.savedKey), "geri verilince silinmeli")
    }

    @MainActor
    func testRestoreIfLeftDimmedClearsStaleValue() {
        let dimmer = ScreenDimmer.shared
        dimmer.update(dim: false)
        UserDefaults.standard.set(0.6, forKey: ScreenDimmer.savedKey)
        dimmer.restoreIfLeftDimmed()
        XCTAssertNil(UserDefaults.standard.object(forKey: ScreenDimmer.savedKey))
    }
}

final class OptionCodeDefaultsTests: XCTestCase {
    func testDefaultOptionCodesAreTheApprovedOnes() {
        let codes = GeminiSupport.parseOptionCodes(GeminiConfig.defaultOptionCodes)
        XCTAssertEqual(codes.map { $0.letter }, ["A", "B", "C", "D", "E"])
        XCTAssertEqual(codes.map { $0.word }, ["ADANA", "BURSA", "CEYHAN", "DENİZLİ", "ERZURUM"])
    }

}
