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

    private func analyzedCount(saving: Bool) -> Int {
        let pipeline = FramePipeline()
        pipeline.saving = saving
        for i in 0..<10 {
            pipeline.handle(planarBuffer(), time: Double(i))
            usleep(80_000)      // analiz kuyruğu boşalsın (birikme sınırına takılmasın)
        }
        usleep(300_000)
        return pipeline.store.frames(from: -1, to: 100).count
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
}
