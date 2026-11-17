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

    /// Kuyruktaki bütün kareler analiz edilene kadar bekler (en çok 10 sn). Sabit uyku yavaş CI makinelerinde kareyi birikme sınırına takıp sayıyı bozuyordu.
    private func drain(_ pipeline: FramePipeline) {
        let deadline = Date().addingTimeInterval(10)
        while pipeline.analysisBacklog > 0 && Date() < deadline { usleep(5_000) }
    }

    private func analyzedCount(saving: Bool, fullRate: Bool = false) -> Int {
        let pipeline = FramePipeline()
        pipeline.saving = saving
        pipeline.fullRate = fullRate
        for i in 0..<10 {
            pipeline.handle(planarBuffer(), time: Double(i))
            drain(pipeline)     // analiz kuyruğu boşalsın (birikme sınırına takılmasın)
        }
        return pipeline.store.frames(from: -1, to: 100).count
    }

    func testSavingModeAnalyzesEveryOtherFrame() {
        XCTAssertEqual(analyzedCount(saving: false), 10)
        XCTAssertEqual(analyzedCount(saving: true), 5)
    }

    /// Toplu çekimde kameranın verdiği her kare ölçülür: pil tasarrufu açık olsa bile kareler seyreltilmez
    func testFullRateAnalyzesEveryFrameEvenInSavingMode() {
        XCTAssertEqual(analyzedCount(saving: true, fullRate: true), 10)
        XCTAssertEqual(analyzedCount(saving: false, fullRate: true), 10)
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
