import XCTest
import AVFoundation
import CoreImage
import CoreVideo
import ImageIO
@testable import G526CameraDrive

/// Görüntü yönü (Normal / 90° sağa / 90° sola / 180°): ayar, fotoğraf, video ve sesli yönlendirme.
final class ImageOrientationTests: XCTestCase {
    // MARK: Ölçüm çevrilmiş görüntüde yapılır

    /// Landscape/portrait fark etmez: ekranda sütunları yan yana olan sentetik sayfa (blok yazı)
    private func synth(pages: [(Int, Int)], blocks: [(Int, Int, Int, Int)], w: Int, h: Int) -> [Float] {
        var luma = [Float](repeating: 30, count: w * h)
        for (px0, px1) in pages {
            for y in 45..<(h - 10) {
                for x in px0..<px1 { luma[y * w + x] = 235 }
            }
        }
        for (bx0, bx1, by0, by1) in blocks {
            var y = by0
            while y + 5 < by1 {
                var x = bx0
                while x + 30 <= bx1 {
                    for yy in y..<(y + 5) {
                        for xx in x..<(x + 30) { luma[yy * w + xx] = 40 }
                    }
                    x += 38
                }
                y += 14
            }
        }
        return luma
    }

    /// Ekran görüntüsünden (dw × dh) kameranın karesini (W × 540) kurar: `reorient`in tam tersi, üstte saat bandı (koyu)
    private func sensorFrame(from d: [Float], dw: Int, dh: Int, orientation o: ImageOrientation) -> (px: [Float], w: Int, h: Int) {
        let H = 540
        let top = Int(Double(H) * GuidanceAnalyzer.skipTop)
        let h = H - top
        let W = o.isQuarterTurn ? dh : dw
        XCTAssertEqual(o.isQuarterTurn ? dw : dh, h, "ekran boyu = bantsız kare yüksekliği")
        var s = [Float](repeating: 30, count: W * H)
        for yd in 0..<dh {
            for xd in 0..<dw {
                let x: Int, y: Int
                switch o {
                case .right90: x = yd; y = top + (h - 1 - xd)
                case .left90: x = W - 1 - yd; y = top + xd
                case .rotate180: x = W - 1 - xd; y = top + (h - 1 - yd)
                case .normal: x = xd; y = yd
                }
                s[y * W + x] = d[yd * dw + xd]
            }
        }
        return (s, W, H)
    }

    func testNormalOrientationLeavesTheGridAlone() {
        let L = [Float](repeating: 7, count: 200 * 100)
        let r = GuidanceAnalyzer.reorient(luma: L, width: 200, height: 100, orientation: .normal)
        XCTAssertEqual(r.px, L)
        XCTAssertEqual(r.w, 200)
        XCTAssertEqual(r.h, 100)
    }

    func testReorientRotatesLikeTheDisplayAndDropsTheClockBand() {
        let W = 200, H = 100
        let top = Int(Double(H) * GuidanceAnalyzer.skipTop)
        let h = H - top
        var L = [Float](repeating: 0, count: W * H)
        L[top * W + 0] = 255               // bandın hemen altında, sol üst
        L[top * W + (W - 1)] = 128         // bandın hemen altında, sağ üst
        L[2 * W + 50] = 99                 // saat bandının içinde
        func find(_ r: (px: [Float], w: Int, h: Int), _ v: Float) -> (x: Int, y: Int)? {
            guard let i = r.px.firstIndex(of: v) else { return nil }
            return (i % r.w, i / r.w)
        }
        let right = GuidanceAnalyzer.reorient(luma: L, width: W, height: H, orientation: .right90)
        XCTAssertEqual(right.w, h)
        XCTAssertEqual(right.h, W)
        XCTAssertEqual(find(right, 255)?.x, h - 1, "saat yönünde: sol üst → sağ üst")
        XCTAssertEqual(find(right, 255)?.y, 0)
        XCTAssertEqual(find(right, 128)?.x, h - 1, "sağ üst → sağ alt")
        XCTAssertEqual(find(right, 128)?.y, W - 1)
        XCTAssertNil(find(right, 99), "saat bandı atılır")

        let left = GuidanceAnalyzer.reorient(luma: L, width: W, height: H, orientation: .left90)
        XCTAssertEqual(left.w, h)
        XCTAssertEqual(left.h, W)
        XCTAssertEqual(find(left, 255)?.x, 0, "saat yönünün tersine: sol üst → sol alt")
        XCTAssertEqual(find(left, 255)?.y, W - 1)
        XCTAssertEqual(find(left, 128)?.y, 0, "sağ üst → sol üst")
        XCTAssertNil(find(left, 99))

        let half = GuidanceAnalyzer.reorient(luma: L, width: W, height: H, orientation: .rotate180)
        XCTAssertEqual(half.w, W)
        XCTAssertEqual(half.h, h)
        XCTAssertEqual(find(half, 255)?.x, W - 1, "180°: sol üst → sağ alt")
        XCTAssertEqual(find(half, 255)?.y, h - 1)
        XCTAssertNil(find(half, 99))
    }

    func testReorientUndoesTheCameraRotationExactly() {
        // yan yatmış kamera: ekrandaki görüntüden kamera karesi kurulur, çevirme ekranı aynen geri verir
        let portrait = synth(pages: [(5, 495)], blocks: [(20, 215, 80, 900), (285, 480, 80, 900)], w: 500, h: 960)
        for o in [ImageOrientation.right90, .left90] {
            let s = sensorFrame(from: portrait, dw: 500, dh: 960, orientation: o)
            let r = GuidanceAnalyzer.reorient(luma: s.px, width: s.w, height: s.h, orientation: o)
            XCTAssertEqual(r.w, 500, o.title)
            XCTAssertEqual(r.h, 960, o.title)
            XCTAssertTrue(r.px == portrait, "\(o.title): çevrilmiş düzlem ekran görüntüsüne eşit")
        }
        let landscape = synth(pages: [(100, 860)], blocks: [(130, 440, 80, 480), (520, 830, 80, 480)], w: 960, h: 500)
        let s = sensorFrame(from: landscape, dw: 960, dh: 500, orientation: .rotate180)
        let r = GuidanceAnalyzer.reorient(luma: s.px, width: s.w, height: s.h, orientation: .rotate180)
        XCTAssertTrue(r.px == landscape, "180°")
    }

    func testColumnsOfASidewaysPageAreSideBySideOnTheScreen() {
        // ekranda (dik görünüm) iki sütun yan yana; kamera yan yattığı için kare üzerinde üst üste görünürler
        let portrait = synth(pages: [(5, 495)], blocks: [(20, 215, 80, 900), (285, 480, 80, 900)], w: 500, h: 960)
        for o in [ImageOrientation.right90, .left90] {
            let s = sensorFrame(from: portrait, dw: 500, dh: 960, orientation: o)
            let r = GuidanceAnalyzer.reorient(luma: s.px, width: s.w, height: s.h, orientation: o)
            let m = GuidanceAnalyzer.analyze(luma: r.px, width: r.w, height: r.h, skipTop: 0)
            XCTAssertTrue(m.hasText, o.title)
            XCTAssertEqual(m.columns.count, 2, "\(o.title): iki sütun")
            if m.columns.count == 2 {
                XCTAssertLessThan(m.columns[0].x1, m.columns[1].x0, "\(o.title): sütunlar yan yana, soldan sağa")
                XCTAssertLessThan(m.columns[0].x1, 0.5)
                XCTAssertGreaterThan(m.columns[1].x0, 0.5)
            }
            // Soru "sol mu, sağ mı" olur ("üst/alt" değil)
            let e = GuidanceEngine()
            XCTAssertTrue(e.questionText(options: GuidanceAdvisor.options(forColumnCount: 2), first: false).contains("Sol mu, sağ mı"))
        }
    }

    func testClockBandIsOnlyAdvisedOnUprightFrames() {
        XCTAssertEqual(GuidanceConfig().topBand, GuidanceAnalyzer.skipTop, "normal yönde saat bandı payı")
        var turned = GuidanceConfig()
        turned.topBand = 0
        // yazı çevrilmiş karenin üst kenarına yakın: bant payı yok, kenar payı 0,02
        var m = PageMetrics()
        m.hasPage = true
        m.hasText = true
        m.x0 = 0.2
        m.x1 = 0.8
        m.y0 = 0.01
        m.y1 = 0.8
        m.cells = 600
        m.sharp = 1
        XCTAssertEqual(GuidanceAdvisor.decide(m, choice: nil, config: turned, sharpFloor: 0.45).advice, .moveUp)
        m.y0 = 0.03
        XCTAssertEqual(GuidanceAdvisor.decide(m, choice: nil, config: turned, sharpFloor: 0.45).advice, .ok,
                       "çevrilmişte bant payı yok: 0,03 yeterli")
        XCTAssertEqual(GuidanceAdvisor.decide(m, choice: nil, sharpFloor: 0.45).advice, .moveUp,
                       "normal yönde 0,075 saat bandı payı gerekir")
    }

    // MARK: Video

    func testVideoTransformKeepsFrameInPositiveArea() {
        let w: CGFloat = 1920, h: CGFloat = 1080
        let frame = CGRect(x: 0, y: 0, width: w, height: h)
        let normal = frame.applying(ImageOrientation.normal.videoTransform(width: w, height: h))
        XCTAssertEqual(normal, frame)
        let flipped = frame.applying(ImageOrientation.rotate180.videoTransform(width: w, height: h))
        XCTAssertEqual(flipped, frame)
        for o in [ImageOrientation.right90, .left90] {
            let r = frame.applying(o.videoTransform(width: w, height: h))
            XCTAssertEqual(r, CGRect(x: 0, y: 0, width: h, height: w), "\(o.title): en/boy yer değiştirir, başlangıç (0,0)")
        }
        // sağa 90°: sensörün sol-üst köşesi ekranda sağ-üst olur
        let tl = CGPoint(x: 0, y: 0).applying(ImageOrientation.right90.videoTransform(width: w, height: h))
        XCTAssertEqual(tl, CGPoint(x: h, y: 0))
        // sola 90°: sensörün sol-üst köşesi ekranda sol-alt olur
        let tl2 = CGPoint(x: 0, y: 0).applying(ImageOrientation.left90.videoTransform(width: w, height: h))
        XCTAssertEqual(tl2, CGPoint(x: 0, y: w))
    }

    private func yuvBuffer(width: Int, height: Int) -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            attrs as CFDictionary, &created)
        let buffer = created!
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
            let count = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane)
            memset(base, plane == 0 ? 90 : 128, count)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    func testRecordedVideoCarriesPlaybackRotation() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("yon-\(UUID().uuidString).mp4")
        let recorder = VideoRecorder()
        recorder.start(to: url, orientation: .right90)
        var t = 0.0
        while t <= 1.5 {
            recorder.append(yuvBuffer(width: 320, height: 180), time: 2000 + t)
            t += 0.1
        }
        let done = expectation(description: "video bitti")
        var output: VideoRecorder.Output?
        recorder.finish { result in
            if case .success(let o) = result { output = o }
            done.fulfill()
        }
        wait(for: [done], timeout: 60)
        guard let out = output else { return XCTFail("video üretilmedi") }
        defer { try? FileManager.default.removeItem(at: out.url) }
        let asset = AVURLAsset(url: out.url)
        guard let track = asset.tracks(withMediaType: .video).first else { return XCTFail("video izi yok") }
        XCTAssertEqual(Int(track.naturalSize.width), 320, "kareler çevrilmez; yalnız oynatma dönüşümü yazılır")
        XCTAssertEqual(Int(track.naturalSize.height), 180)
        let expected = ImageOrientation.right90.videoTransform(width: 320, height: 180)
        let got = track.preferredTransform
        XCTAssertEqual(got.a, expected.a, accuracy: 0.001)
        XCTAssertEqual(got.b, expected.b, accuracy: 0.001)
        XCTAssertEqual(got.c, expected.c, accuracy: 0.001)
        XCTAssertEqual(got.d, expected.d, accuracy: 0.001)
    }

    // MARK: Fotoğraf

    /// 640×360 kare: sol üstte 80×80 kırmızı kutu, geri kalanı koyu mavi
    private func markerBuffer() throws -> CVPixelBuffer {
        let width = 640, height = 360
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
        ctx.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // CGContext'te başlangıç sol alttır; belleğin ilk satırı karenin üstüdür
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: height - 80, width: 80, height: 80))
        return buffer
    }

    private func isRed(_ data: Data, at point: CGPoint) throws -> (w: Int, h: Int, red: Bool) {
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try XCTUnwrap(CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let i = (Int(point.y) * w + Int(point.x)) * 4
        return (w, h, px[i] > 200 && px[i + 1] < 70 && px[i + 2] < 70)
    }

    private func render(_ o: ImageOrientation) throws -> Data {
        let opts = EnhanceOptions(level: 0, deskew: false, upscale: 1.0, timestamp: .keep, quality: 1.0, orientation: o)
        let out = try XCTUnwrap(Enhancer.render(buffers: [try markerBuffer()], options: opts))
        if o.isQuarterTurn {
            XCTAssertEqual(out.width, 360, "\(o.title): en/boy yer değiştirir")
            XCTAssertEqual(out.height, 640)
        } else {
            XCTAssertEqual(out.width, 640)
            XCTAssertEqual(out.height, 360)
        }
        return out.data
    }

    func testPhotoIsRotatedLikeThePreview() throws {
        // normal: kutu sol üstte
        var r = try isRed(try render(.normal), at: CGPoint(x: 40, y: 40))
        XCTAssertTrue(r.red, "normal: sol üst")
        // sağa 90° (saat yönü): sol üst köşe sağ üste gider
        let right = try render(.right90)
        r = try isRed(right, at: CGPoint(x: 360 - 40, y: 40))
        XCTAssertTrue(r.red, "90° sağa: sağ üst")
        XCTAssertFalse(try isRed(right, at: CGPoint(x: 40, y: 40)).red)
        // sola 90°: sol üst köşe sol alta gider
        let left = try render(.left90)
        r = try isRed(left, at: CGPoint(x: 40, y: 640 - 40))
        XCTAssertTrue(r.red, "90° sola: sol alt")
        XCTAssertFalse(try isRed(left, at: CGPoint(x: 40, y: 40)).red)
        // 180°: sağ alta gider
        let half = try render(.rotate180)
        r = try isRed(half, at: CGPoint(x: 640 - 40, y: 360 - 40))
        XCTAssertTrue(r.red, "180°: sağ alt")
        XCTAssertFalse(try isRed(half, at: CGPoint(x: 40, y: 40)).red)
    }
}
