import XCTest
import UIKit
import PDFKit
import CoreVideo
@testable import G526CameraDrive

private func makeBuffer() -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 8, 8, kCVPixelFormatType_32BGRA, nil, &buffer)
    return buffer!
}

final class FrameCollectorTests: XCTestCase {
    func testOnlyOffersAfterBeginAreKept() {
        let c = FrameCollector()
        c.offer(makeBuffer(), time: 0, sharpness: 1)
        XCTAssertFalse(c.isActive)
        c.begin()
        XCTAssertTrue(c.isActive)
        c.offer(makeBuffer(), time: 1, sharpness: 1)
        XCTAssertEqual(c.end().count, 1)
        XCTAssertFalse(c.isActive)
        c.offer(makeBuffer(), time: 2, sharpness: 1)
        XCTAssertEqual(c.end().count, 0, "end'den sonra gelen kare toplanmaz")
    }

    func testBestFramePerHalfSecondInTimeOrder() {
        let c = FrameCollector()
        c.begin()
        c.offer(makeBuffer(), time: 10.0, sharpness: 0.3)
        c.offer(makeBuffer(), time: 10.2, sharpness: 0.9)
        c.offer(makeBuffer(), time: 10.4, sharpness: 0.5)
        c.offer(makeBuffer(), time: 10.6, sharpness: 0.5)
        c.offer(makeBuffer(), time: 11.1, sharpness: 0.7)
        let frames = c.end()
        XCTAssertEqual(frames.map { $0.time }, [10.2, 10.6, 11.1])
        XCTAssertEqual(frames.map { $0.sharpness }, [0.9, 0.5, 0.7])
    }

    func testTieKeepsTheFirstFrame() {
        let c = FrameCollector()
        c.begin()
        c.offer(makeBuffer(), time: 0.0, sharpness: 0.8)
        c.offer(makeBuffer(), time: 0.1, sharpness: 0.8)
        XCTAssertEqual(c.end().first?.time, 0.0)
    }

    func testFiveSecondsAtThirtyFpsGivesTenFrames() {
        let c = FrameCollector()
        c.begin()
        let buffer = makeBuffer()
        for i in 0..<150 { c.offer(buffer, time: 100 + Double(i) / 30, sharpness: Double(i % 7)) }
        XCTAssertEqual(c.end().count, 10)
    }

    func testBeginClearsAndCancelDrops() {
        let c = FrameCollector()
        c.begin()
        c.offer(makeBuffer(), time: 0, sharpness: 1)
        c.begin()
        XCTAssertEqual(c.end().count, 0, "yeni begin öncekileri siler")
        c.begin()
        c.offer(makeBuffer(), time: 0, sharpness: 1)
        c.cancel()
        XCTAssertFalse(c.isActive)
        XCTAssertEqual(c.end().count, 0)
    }
}

final class ScanFilesTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("scanfiles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func jpeg(_ color: UIColor) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 60))
        return renderer.jpegData(withCompressionQuality: 0.9) { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 60))
        }
    }

    func testNames() {
        let files = ScanFiles(runName: "Sinav-20261113-0900", base: base)
        XCTAssertEqual(files.root.lastPathComponent, "g526-Sinav-20261113-0900")
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.root.path))
        XCTAssertEqual(files.jpegURL(question: 12, part: 1, serial: 3).lastPathComponent, "S12-1-3.jpg")
        XCTAssertEqual(files.videoURL(index: 4).lastPathComponent, "V04.mp4")
        XCTAssertEqual(files.videoURL(index: 12).lastPathComponent, "V12.mp4")
    }

    func testWriteJPEGAndBuildPDF() throws {
        let files = ScanFiles(runName: "Sinav-1", base: base)
        let a = try files.writeJPEG(jpeg(.red), question: 5, part: 1, serial: 1)
        let b = try files.writeJPEG(jpeg(.blue), question: 5, part: 1, serial: 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        let pdf = try files.buildPDF(name: "S5.pdf", jpegs: [a, b])
        XCTAssertEqual(pdf.lastPathComponent, "S5.pdf")
        let doc = try XCTUnwrap(PDFDocument(url: pdf))
        XCTAssertEqual(doc.pageCount, 2)
        // aynı adla yeniden kurulursa üzerine yazılır
        let again = try files.buildPDF(name: "S5.pdf", jpegs: [a])
        XCTAssertEqual(PDFDocument(url: again)?.pageCount, 1)
    }

    func testBuildPDFWithoutPagesFails() {
        let files = ScanFiles(runName: "Sinav-2", base: base)
        XCTAssertThrowsError(try files.buildPDF(name: "S1.pdf", jpegs: []))
    }

    func testCleanupAndRemoveAll() {
        let one = ScanFiles(runName: "Sinav-3", base: base)
        let two = ScanFiles(runName: "Sinav-4", base: base)
        let other = base.appendingPathComponent("baska-klasor", isDirectory: true)
        try? FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        one.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: one.root.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: two.root.path))
        ScanFiles.removeAll(base: base)
        XCTAssertFalse(FileManager.default.fileExists(atPath: two.root.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path), "yalnız g526-Sinav- önekli klasörler silinir")
    }
}
