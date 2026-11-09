import XCTest
import CoreVideo
@testable import G526CameraDrive

/// Belge kontrolü: yalnız kâğıt + yazı görünüyorsa çekilir; el/yüz/boş masa/çizgili desen çekilmez.
final class DocumentGateTests: XCTestCase {

    // MARK: - Sahneler

    /// GuidanceTests'teki sentetik sahne: koyu zemin, açık sayfalar, 30x5 piksellik "harf" parçaları
    private func synth(pages: [(Int, Int)], blocks: [(Int, Int, Int, Int)], w: Int = 960, h: Int = 540) -> [Float] {
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

    private func textPage() -> [Float] {
        return synth(pages: [(150, 810)], blocks: [(200, 760, 80, 480)])
    }

    /// Kesintisiz yatay çizgiler (çizgili kumaş / defter çizgisi gibi): yazıya benzer ama harf yok
    private func stripes() -> [Float] {
        var luma = synth(pages: [(150, 810)], blocks: [])
        var y = 80
        while y + 5 < 480 {
            for yy in y..<(y + 5) {
                for x in 200..<760 { luma[yy * 960 + x] = 40 }
            }
            y += 14
        }
        return luma
    }

    /// Dikey ve yatay çizgilerden oluşan ızgara (tablo)
    private func grid() -> [Float] {
        var luma = synth(pages: [(150, 810)], blocks: [])
        var y = 80
        while y < 480 {
            for yy in y..<(y + 3) { for x in 200..<760 { luma[yy * 960 + x] = 40 } }
            y += 40
        }
        var x = 200
        while x <= 760 {
            for xx in x..<(x + 3) { for yy in 80..<480 { luma[yy * 960 + xx] = 40 } }
            x += 40
        }
        return luma
    }

    // MARK: - Karar kuralı

    func testVerdictOnHandBuiltMetrics() {
        XCTAssertEqual(DocumentGate.verdict(PageMetrics()), .noPage)
        var page = PageMetrics()
        page.hasPage = true
        XCTAssertEqual(DocumentGate.verdict(page), .noText)

        var m = PageMetrics()
        m.hasPage = true
        m.hasText = true
        m.cells = 600
        XCTAssertEqual(DocumentGate.verdict(m), .document, "elle kurulan ölçüde harf parçası ölçülmemiş (-1): engellenmemeli")

        m.cells = 10
        XCTAssertEqual(DocumentGate.verdict(m), .noText, "çok az yazı belge sayılmaz")
        m.cells = 600
        m.glyphs = 0
        m.glyphShare = 0
        XCTAssertEqual(DocumentGate.verdict(m), .notTextLike)
        m.glyphs = 300
        m.glyphShare = 0.9
        XCTAssertEqual(DocumentGate.verdict(m), .document)
        m.glyphShare = 0.1
        XCTAssertEqual(DocumentGate.verdict(m), .notTextLike, "mürekkep çoğunlukla uzun şeritse yazı değildir")
    }

    // MARK: - Ölçülen sahneler

    func testTextPageIsDocument() {
        let m = GuidanceAnalyzer.analyze(luma: textPage(), width: 960, height: 540)
        XCTAssertTrue(m.hasText)
        XCTAssertGreaterThan(m.glyphs, 100, m.summary)
        XCTAssertGreaterThan(m.glyphShare, 0.9)
        XCTAssertEqual(DocumentGate.verdict(m), .document, DocumentGate.describe(m, DocumentGate.verdict(m)))
    }

    func testStripesAndGridAreNotDocuments() {
        for (name, scene) in [("çizgili", stripes()), ("ızgara", grid())] {
            let m = GuidanceAnalyzer.analyze(luma: scene, width: 960, height: 540)
            XCTAssertNotEqual(DocumentGate.verdict(m), .document, "\(name): \(DocumentGate.describe(m, DocumentGate.verdict(m)))")
            XCTAssertNotEqual(GuidanceAdvisor.decide(m, choice: nil, sharpFloor: 0.45).advice, .ok, name)
        }
    }

    func testBlankPageAndDarkSceneAreNotDocuments() {
        let blank = GuidanceAnalyzer.analyze(luma: synth(pages: [(150, 810)], blocks: []), width: 960, height: 540)
        XCTAssertNotEqual(DocumentGate.verdict(blank), .document, "boş kâğıt belge sayılmaz")
        let dark = GuidanceAnalyzer.analyze(luma: [Float](repeating: 30, count: 960 * 540), width: 960, height: 540)
        XCTAssertEqual(DocumentGate.verdict(dark), .noPage)
    }

    func testRealCameraFramesAreDocuments() {
        for (name, data) in [("sol kesik A", RealFrames.leftCutA), ("sol kesik B", RealFrames.leftCutB), ("iki kart", RealFrames.bothFull)] {
            guard let f = RealFrames.luma(data) else { return XCTFail("kare çözülemedi: \(name)") }
            let m = GuidanceAnalyzer.analyze(luma: f.px, width: f.w, height: f.h)
            XCTAssertGreaterThan(m.glyphs, 100, "\(name): \(m.summary)")
            XCTAssertGreaterThan(m.glyphShare, 0.5, name)
            XCTAssertEqual(DocumentGate.verdict(m), .document, "\(name): \(DocumentGate.describe(m, DocumentGate.verdict(m)))")
        }
    }

    func testGuidanceDoesNotAdviseOnNonDocuments() {
        let m = GuidanceAnalyzer.analyze(luma: stripes(), width: 960, height: 540)
        let e = GuidanceEngine()
        for i in 0..<12 {
            let o = e.step(m, time: Double(i) * 0.3, stillFor: 1.0, diffToCapture: 100)
            XCTAssertFalse(o.capture, "çizgili desen çekilmemeli")
        }
    }

    // MARK: - Çekim motoru

    /// 960x540 gri düzlemi 2 kat büyüterek 1920x1080 BGRA kareye çevirir (çözülmüş kamera karesi gibi)
    private func buffer(fromLuma px: [Float], w: Int, h: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true,
                                      kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        CVPixelBufferCreate(kCFAllocatorDefault, w * 2, h * 2, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        let buffer = try XCTUnwrap(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<(h * 2) {
            for x in 0..<(w * 2) {
                let v = UInt8(max(0, min(255, px[(y / 2) * w + (x / 2)])))
                let p = base + y * stride + x * 4
                p[0] = v
                p[1] = v
                p[2] = v
                p[3] = 255
            }
        }
        return buffer
    }

    private func capture(_ frame: CVPixelBuffer, documentOnly: Bool) -> Result<CapturedPhoto, CaptureError>? {
        let store = FrameStore(capacity: 20)
        let engine = CaptureEngine(store: store)
        store.add(buffer: frame, time: ProcessInfo.processInfo.systemUptime, sharpness: 100,
                  signature: [UInt8](repeating: 0, count: FrameAnalysis.signatureColumns * FrameAnalysis.signatureRows))
        let options = CaptureOptions(
            before: 2.0, after: 0.05, multiFrame: false,
            enhance: EnhanceOptions(level: 0, deskew: false, upscale: 1.0, timestamp: .keep, quality: 0.8),
            documentOnly: documentOnly)
        let done = expectation(description: "çekim")
        var outcome: Result<CapturedPhoto, CaptureError>?
        let accepted = engine.capture(reason: "test", options: options) { result in
            outcome = result
            done.fulfill()
        }
        XCTAssertTrue(accepted)
        wait(for: [done], timeout: 30)
        return outcome
    }

    func testEngineTakesDocumentsAndRefusesOtherScenes() throws {
        let doc = try buffer(fromLuma: try XCTUnwrap(RealFrames.luma(RealFrames.bothFull)).px, w: 960, h: 540)
        let striped = try buffer(fromLuma: stripes(), w: 960, h: 540)
        let dark = try buffer(fromLuma: [Float](repeating: 30, count: 960 * 540), w: 960, h: 540)

        let taken = try XCTUnwrap(capture(doc, documentOnly: true))
        switch taken {
        case .success(let photo): XCTAssertGreaterThan(photo.width, 0)
        case .failure(let error): XCTFail("belge çekilmeliydi: \(error)")
        }
        for (name, frame) in [("çizgili desen", striped), ("karanlık sahne", dark)] {
            let refused = try XCTUnwrap(capture(frame, documentOnly: true), name)
            switch refused {
            case .success: XCTFail("\(name) çekilmemeliydi")
            case .failure(let error):
                guard case .notDocument = error else { XCTFail("\(name): beklenmeyen hata \(error)"); continue }
                XCTAssertTrue(error.message.contains("Belge görünmüyor"))
            }
        }
        // kontrol kapalıyken her sahne çekilir
        let free = try XCTUnwrap(capture(dark, documentOnly: false))
        switch free {
        case .success: break
        case .failure(let error): XCTFail("kontrol kapalıyken çekilmeliydi: \(error)")
        }
    }

    func testDocumentOnlyIsOnByDefault() {
        UserDefaults.standard.removeObject(forKey: "documentOnly")
        XCTAssertTrue(AppSettings().documentOnly)
        XCTAssertFalse(CaptureOptions(before: 0, after: 0, multiFrame: false,
                                      enhance: EnhanceOptions(level: 0, deskew: false, upscale: 1.0, timestamp: .keep, quality: 0.8)).documentOnly,
                       "motor düzeyinde varsayılan kapalı: uygulama ayarla açar")
    }
}
