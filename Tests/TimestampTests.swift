import XCTest
import CoreImage
import CoreVideo
import UIKit
import Vision
@testable import G526CameraDrive

/// Tarih/saat gizleme (bulanıklaştır / kes / olduğu gibi). Kamera karesine benzeyen, tarih yazısı sağ üstte olan bir test karesi üretilir.
final class TimestampTests: XCTestCase {
    private let width = 1920
    private let height = 1080

    private func makeBuffer() throws -> CVPixelBuffer {
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
        // UIKit çizimi için üst-sol başlangıç
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx)
        UIColor(red: 0.05, green: 0.05, blue: 0.14, alpha: 1).setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // belge gövdesi: açık zemin üzerinde metin satırları
        UIColor(white: 0.9, alpha: 1).setFill()
        ctx.fill(CGRect(x: 300, y: 200, width: 1300, height: 800))
        let body = UIFont.systemFont(ofSize: 30, weight: .regular)
        for i in 0..<14 {
            ("Belge metni örnek satır numarası \(i) — 0123456789" as NSString).draw(
                at: CGPoint(x: 340, y: 230 + i * 52),
                withAttributes: [.font: body, .foregroundColor: UIColor.black])
        }
        // kameranın işlediği tarih/saat: sağ üst, 39. satırdan başlar
        let osd = UIFont.monospacedSystemFont(ofSize: 28, weight: .bold)
        ("2026-11-08 17:35:12" as NSString).draw(
            at: CGPoint(x: 1561, y: 36),
            withAttributes: [.font: osd, .foregroundColor: UIColor.white])
        UIGraphicsPopContext()
        return buffer
    }

    private func luma(_ data: Data) throws -> (w: Int, h: Int, px: [UInt8]) {
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h)
        let ctx = try XCTUnwrap(CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (w, h, px)
    }

    private func highFreq(_ img: (w: Int, h: Int, px: [UInt8]), rows: Range<Int>, cols: Range<Int>) -> Double {
        var sum = 0, n = 0
        for y in rows { for x in cols.dropLast() {
            sum += abs(Int(img.px[y * img.w + x + 1]) - Int(img.px[y * img.w + x])); n += 1
        } }
        return Double(sum) / Double(max(n, 1))
    }

    private func render(_ buffer: CVPixelBuffer, _ mode: TimestampMode) throws -> (data: Data, width: Int, height: Int) {
        let opts = EnhanceOptions(level: 0, deskew: false, upscale: 1.0, timestamp: mode, quality: 1.0)
        return try XCTUnwrap(Enhancer.render(buffers: [buffer], options: opts))
    }

    private func digits(in data: Data, rows: Range<Int>) -> Int? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let crop = img.cropping(to: CGRect(x: 0, y: rows.lowerBound, width: img.width, height: rows.count)) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        guard (try? VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])) != nil else { return nil }
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined()
        return text.filter { $0.isNumber }.count
    }

    func testKeepLeavesFrameUntouched() throws {
        let out = try render(try makeBuffer(), .keep)
        XCTAssertEqual(out.width, width)
        XCTAssertEqual(out.height, height)
    }

    func testCropRemovesTopBand() throws {
        let out = try render(try makeBuffer(), .crop)
        let band = Int((Double(height) * Enhancer.timestampBand).rounded())
        XCTAssertEqual(out.width, width)
        XCTAssertEqual(out.height, height - band)
    }

    func testBlurKeepsSizeAndBodyButDestroysTextDetail() throws {
        let buffer = try makeBuffer()
        let keep = try luma(try render(buffer, .keep).data)
        let blurOut = try render(buffer, .blur)
        XCTAssertEqual(blurOut.width, width)
        XCTAssertEqual(blurOut.height, height)
        let blur = try luma(blurOut.data)

        // yazı bölgesi (sağ üst) artık ince ayrıntı taşımamalı
        let before = highFreq(keep, rows: 36..<68, cols: 1540..<1900)
        let after = highFreq(blur, rows: 36..<68, cols: 1540..<1900)
        XCTAssertGreaterThan(before, 4.0, "test karesinde yazı yok")
        XCTAssertLessThan(after, before * 0.5, "bulanıklaştırma yetersiz: \(after) / \(before)")

        // şeridin altı değişmemeli
        var diff = 0, n = 0
        for y in 100..<height { for x in stride(from: 0, to: width, by: 7) {
            diff += abs(Int(keep.px[y * width + x]) - Int(blur.px[y * width + x])); n += 1
        } }
        XCTAssertLessThan(Double(diff) / Double(n), 1.0, "şeridin altı değişti")
    }

    /// Bulanıklaştırma yalnızca tarih yazısının kutusunda olmalı; satırın geri kalanı ve gövde birebir kalmalı.
    func testBlurOnlyTouchesTheDateBox() throws {
        let buffer = try makeBuffer()
        let keep = try luma(try render(buffer, .keep).data)
        let blur = try luma(try render(buffer, .blur).data)
        // sol yarıdaki üst satırlar (aynı satırlar, tarihten uzak) değişmemeli
        var farDiff = 0, n = 0
        for y in 0..<100 { for x in stride(from: 0, to: 1400, by: 3) {
            farDiff += abs(Int(keep.px[y * width + x]) - Int(blur.px[y * width + x])); n += 1
        } }
        XCTAssertLessThan(Double(farDiff) / Double(n), 1.0, "kutunun dışı (satırın solu) değişti")
        // kutunun içi ise değişmeli
        var inDiff = 0, m = 0
        for y in 36..<68 { for x in stride(from: 1561, to: 1900, by: 2) {
            inDiff += abs(Int(keep.px[y * width + x]) - Int(blur.px[y * width + x])); m += 1
        } }
        XCTAssertGreaterThan(Double(inDiff) / Double(m), 5.0, "tarih kutusu değişmedi")
        // kutu tüm satır değil
        let box = Enhancer.boxRect(in: CGRect(x: 0, y: 0, width: width, height: height))
        XCTAssertLessThan(box.width / CGFloat(width), 0.25)
    }

    func testBlurMakesTimestampUnreadableByOCR() throws {
        let buffer = try makeBuffer()
        let keepData = try render(buffer, .keep).data
        guard let readable = digits(in: keepData, rows: 0..<100), readable >= 8 else {
            throw XCTSkip("Bu ortamda test yazısı OCR ile okunamadı; kontrol atlandı")
        }
        let blurred = try XCTUnwrap(digits(in: try render(buffer, .blur).data, rows: 0..<100))
        XCTAssertLessThan(blurred, 4, "bulanık şeritte hâlâ \(blurred) rakam okunuyor")
    }

    func testSmallFrameIsLeftAlone() throws {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 100, 66, kCVPixelFormatType_32BGRA, nil, &pb)
        let image = CIImage(cvPixelBuffer: try XCTUnwrap(pb))
        XCTAssertEqual(Enhancer.hideTimestamp(image, mode: .crop).extent.height, 66)
        XCTAssertEqual(Enhancer.hideTimestamp(image, mode: .blur).extent.height, 66)
    }

    func testSettingsMigrationFromOldCropToggle() {
        let d = UserDefaults.standard
        d.removeObject(forKey: "timestampMode")
        d.set(true, forKey: "cropTimestamp")
        XCTAssertEqual(AppSettings().timestampMode, .crop)
        d.set(false, forKey: "cropTimestamp")
        XCTAssertEqual(AppSettings().timestampMode, .blur)
        d.set("keep", forKey: "timestampMode")
        d.set(true, forKey: "cropTimestamp")
        XCTAssertEqual(AppSettings().timestampMode, .keep)
        d.removeObject(forKey: "timestampMode")
        d.removeObject(forKey: "cropTimestamp")
    }
}
