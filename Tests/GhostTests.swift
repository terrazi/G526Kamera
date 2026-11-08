import XCTest
import CoreImage
import CoreVideo
import UIKit
import ImageIO
@testable import G526CameraDrive

/// Birkaç kareyi birleştirirken "gölge" (çift/hayalet yazı) oluşmamalı: kayık kareler atılır, aynı kareler birleşir.
final class GhostTests: XCTestCase {
    private let width = 1920
    private let height = 1080

    /// Belge benzeri kare; `dx/dy` kadar kaydırılmış çizilir. `seed` küçük bir gürültü ekler.
    private func makeBuffer(dx: Int = 0, dy: Int = 0, seed: UInt64 = 1) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true,
                                      kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        let buffer = try XCTUnwrap(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let ctx = try XCTUnwrap(CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx)
        UIColor(red: 0.05, green: 0.05, blue: 0.14, alpha: 1).setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        UIColor(white: 0.9, alpha: 1).setFill()
        ctx.fill(CGRect(x: 300 + dx, y: 200 + dy, width: 1300, height: 800))
        let body = UIFont.systemFont(ofSize: 30, weight: .regular)
        for i in 0..<14 {
            ("Belge metni örnek satır numarası \(i) — 0123456789" as NSString).draw(
                at: CGPoint(x: 340 + dx, y: 230 + i * 52 + dy),
                withAttributes: [.font: body, .foregroundColor: UIColor.black])
        }
        UIGraphicsPopContext()
        // çok hafif gürültü (aynı karelerde bile birebir aynı olmasın)
        var state = seed &+ 0x9E3779B97F4A7C15
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for _ in 0..<40_000 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let x = Int((state >> 33) % UInt64(width)), y = Int((state >> 13) % UInt64(height))
            let p = base + y * stride + x * 4
            let delta = Int((state >> 5) % 5) - 2
            for c in 0..<3 { p[c] = UInt8(max(0, min(255, Int(p[c]) + delta))) }
        }
        return buffer
    }

    private func render(_ buffers: [CVPixelBuffer]) throws -> (data: Data, width: Int, height: Int, used: Int) {
        let opts = EnhanceOptions(level: 0, deskew: false, upscale: 1.0, timestamp: .keep, quality: 1.0)
        return try XCTUnwrap(Enhancer.render(buffers: buffers, options: opts))
    }

    private func luma(_ data: Data) throws -> [UInt8] {
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        var px = [UInt8](repeating: 0, count: img.width * img.height)
        let ctx = try XCTUnwrap(CGContext(data: &px, width: img.width, height: img.height, bitsPerComponent: 8,
                                          bytesPerRow: img.width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return px
    }

    /// Keskin kenarlarda iki görüntü arasındaki ortalama fark (referansa göre): hayalet varsa büyür.
    private func ghostMetric(ref: [UInt8], out: [UInt8]) -> Double {
        var sum = 0, n = 0
        for y in 200..<1000 { for x in stride(from: 300, to: 1600, by: 1) {
            let i = y * width + x
            let g = max(abs(Int(ref[i + 1]) - Int(ref[i])), abs(Int(ref[i + width]) - Int(ref[i])))
            if g > 60 { sum += abs(Int(ref[i]) - Int(out[i])); n += 1 }
        } }
        return n == 0 ? 0 : Double(sum) / Double(n)
    }

    func testStaticFramesAreAllMerged() throws {
        let frames = try (0..<3).map { try makeBuffer(seed: UInt64($0 + 1)) }
        let out = try render(frames)
        XCTAssertEqual(out.used, 3, "kıpırdamamış kareler birleşmeliydi")
    }

    func testShiftedFramesAreDroppedSoNoGhost() throws {
        let ref = try makeBuffer(seed: 1)
        for (dx, dy) in [(1, 0), (3, 2), (12, 3), (40, 20)] {
            let frames = [ref, try makeBuffer(dx: dx, dy: dy, seed: 2), try makeBuffer(dx: -dx, dy: dy, seed: 3)]
            let out = try render(frames)
            XCTAssertEqual(out.used, 1, "kayma (\(dx),\(dy)): kayık kareler atılmalıydı")
            let single = try luma(try render([ref]).data)
            let merged = try luma(out.data)
            XCTAssertLessThan(ghostMetric(ref: single, out: merged), 2.0, "kayma (\(dx),\(dy)): hayalet var")
        }
    }

    func testNaiveAveragingWouldGhost() throws {
        // kontrol: kayık karelerin saf ortalaması belirgin hayalet yapardı (testin gücünü gösterir)
        let ref = try makeBuffer(seed: 1)
        let shifted = try makeBuffer(dx: 12, dy: 3, seed: 2)
        let a = CIImage(cvPixelBuffer: ref), b = CIImage(cvPixelBuffer: shifted)
        let filter = try XCTUnwrap(CIFilter(name: "CIDissolveTransition"))
        filter.setValue(a, forKey: kCIInputImageKey); filter.setValue(b, forKey: kCIInputTargetImageKey)
        filter.setValue(0.5, forKey: kCIInputTimeKey)
        let mixed = try XCTUnwrap(filter.outputImage)
        let context = CIContext()
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let data = try XCTUnwrap(context.jpegRepresentation(of: mixed.cropped(to: a.extent), colorSpace: space, options: [:]))
        let naive = try luma(data)
        let single = try luma(try render([ref]).data)
        XCTAssertGreaterThan(ghostMetric(ref: single, out: naive), 10.0)
    }

    func testSingleFrameIsReturnedUnchangedInSize() throws {
        let out = try render([try makeBuffer()])
        XCTAssertEqual(out.used, 1)
        XCTAssertEqual(out.width, width)
        XCTAssertEqual(out.height, height)
    }
}
