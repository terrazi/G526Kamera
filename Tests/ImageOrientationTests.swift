import XCTest
import AVFoundation
import CoreImage
import CoreVideo
import ImageIO
@testable import G526CameraDrive

/// Görüntü yönü (Normal / 90° sağa / 90° sola / 180°): ayar, fotoğraf, video ve sesli yönlendirme.
final class ImageOrientationTests: XCTestCase {
    private let moves: [GuidanceAdvice] = [.moveLeft, .moveUp, .moveRight, .moveDown]

    // MARK: Yön eşlemesi

    func testTurnsAreInverseOfEachOther() {
        for m in moves {
            XCTAssertEqual(ImageOrientation.left90.displayed(ImageOrientation.right90.displayed(m)), m)
            XCTAssertEqual(ImageOrientation.right90.displayed(ImageOrientation.left90.displayed(m)), m)
            XCTAssertEqual(ImageOrientation.rotate180.displayed(ImageOrientation.rotate180.displayed(m)), m)
            XCTAssertEqual(ImageOrientation.normal.displayed(m), m)
        }
    }

    func testRightTurnMovesSensorLeftToScreenTop() {
        // resim saat yönünde 90° çevrilince sensörün solu ekranda yukarı, üstü sağa, sağı aşağı, altı sola olur
        XCTAssertEqual(ImageOrientation.right90.displayed(.moveLeft), .moveUp)
        XCTAssertEqual(ImageOrientation.right90.displayed(.moveUp), .moveRight)
        XCTAssertEqual(ImageOrientation.right90.displayed(.moveRight), .moveDown)
        XCTAssertEqual(ImageOrientation.right90.displayed(.moveDown), .moveLeft)
        XCTAssertEqual(ImageOrientation.left90.displayed(.moveLeft), .moveDown)
        XCTAssertEqual(ImageOrientation.rotate180.displayed(.moveLeft), .moveRight)
        // yönsüz uyarılar değişmez
        XCTAssertEqual(ImageOrientation.right90.displayed(.closer), .closer)
        XCTAssertEqual(ImageOrientation.left90.displayed(.glare), .glare)
    }

    func testGuidancePhrasesFollowOrientation() {
        let e = GuidanceEngine()
        e.orientation = .right90
        XCTAssertEqual(e.phrase(for: .moveLeft), "Kamerayı biraz yukarı kaydırın.")
        XCTAssertEqual(e.phrase(for: .moveDown), "Kamerayı biraz sola kaydırın.")
        e.orientation = .rotate180
        XCTAssertTrue(e.flip)
        XCTAssertEqual(e.phrase(for: .moveRight), "Kamerayı biraz sola kaydırın.")
        e.flip = false
        XCTAssertEqual(e.orientation, .normal)
        XCTAssertEqual(e.phrase(for: .moveRight), "Kamerayı biraz sağa kaydırın.")
    }

    func testQuarterTurnAsksTopBottomInsteadOfLeftRight() {
        let e = GuidanceEngine()
        XCTAssertTrue(e.questionText(options: [.left, .right, .all], first: false).contains("Sol mu, sağ mı"))
        e.orientation = .left90
        XCTAssertTrue(e.questionText(options: [.left, .right, .all], first: false).contains("Üst mü, alt mı"))
        XCTAssertTrue(e.questionText(options: [.left, .middle, .right, .all], first: false).contains("Üst mü, orta mı, alt mı"))
        XCTAssertEqual(e.title(.left), "Üst")
        XCTAssertEqual(e.title(.right), "Alt")
        XCTAssertEqual(e.title(.all), "Hepsi")
        XCTAssertEqual(e.setChoice(.left), "Tamam, üst bölüm.")
    }

    func testColumnChoiceMapsToSensorSide() {
        // sağa çevrilmişte ekranda üstteki bölüm = sensörün solu
        XCTAssertEqual(ImageOrientation.right90.sensorChoice(.left), .left)
        XCTAssertEqual(ImageOrientation.right90.sensorChoice(.right), .right)
        // sola çevrilmişte ekranda üstteki bölüm = sensörün sağı
        XCTAssertEqual(ImageOrientation.left90.sensorChoice(.left), .right)
        XCTAssertEqual(ImageOrientation.left90.sensorChoice(.right), .left)
        XCTAssertEqual(ImageOrientation.rotate180.sensorChoice(.left), .right)
        XCTAssertEqual(ImageOrientation.normal.sensorChoice(.left), .left)
        XCTAssertEqual(ImageOrientation.right90.sensorChoice(.all), .all)
        XCTAssertEqual(ImageOrientation.left90.sensorChoice(.middle), .middle)
    }

    func testVoiceTokensSwitchToTopBottomOnlyWhenQuarterTurned() {
        XCTAssertTrue(ColumnChoice.left.tokens(for: .normal).contains("sol"))
        XCTAssertTrue(ColumnChoice.left.tokens(for: .rotate180).contains("sol"))
        XCTAssertTrue(ColumnChoice.left.tokens(for: .right90).contains("ust"))
        XCTAssertFalse(ColumnChoice.left.tokens(for: .right90).contains("sol"))
        XCTAssertTrue(ColumnChoice.right.tokens(for: .left90).contains("alt"))
        XCTAssertEqual(ColumnChoice.right.looseTokens(for: .left90), ["alt"])
        XCTAssertEqual(ColumnChoice.right.looseTokens(for: .normal), ["sag"])
        XCTAssertEqual(ColumnChoice.middle.tokens(for: .right90), ColumnChoice.middle.tokens)
        XCTAssertEqual(ColumnChoice.all.tokens(for: .left90), ColumnChoice.all.tokens)
    }

    // MARK: Ayar

    func testSettingMigratesFromOldFlipSwitch() {
        let name = "orient-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        d.set(true, forKey: "guidanceFlip")
        XCTAssertEqual(AppSettings.migratedOrientation(d), .rotate180)
        XCTAssertNil(d.object(forKey: "guidanceFlip"), "eski anahtar silinir")
        XCTAssertEqual(d.integer(forKey: "imageOrientation"), ImageOrientation.rotate180.rawValue)
        // ikinci okuma aynı sonucu verir
        XCTAssertEqual(AppSettings.migratedOrientation(d), .rotate180)
    }

    func testSettingDefaultsToNormalAndKeepsChoice() {
        let name = "orient-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        XCTAssertEqual(AppSettings.migratedOrientation(d), .normal)
        d.set(ImageOrientation.left90.rawValue, forKey: "imageOrientation")
        d.set(true, forKey: "guidanceFlip")   // yeni anahtar eskisinden önce gelir
        XCTAssertEqual(AppSettings.migratedOrientation(d), .left90)
        d.set(99, forKey: "imageOrientation") // bozuk değer: eski kutuya bakılır
        XCTAssertEqual(AppSettings.migratedOrientation(d), .normal)
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
