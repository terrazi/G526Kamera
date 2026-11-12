import XCTest
import PDFKit
import UIKit
@testable import G526CameraDrive

final class PDFWrapTests: XCTestCase {
    private func makeJPEG(width: Int, height: Int, color: UIColor) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let image = renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 10, y: 10, width: width / 2, height: 12))
        }
        return image.jpegData(compressionQuality: 0.9)!
    }

    private func tempFile(_ name: String, _ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + name)
        try data.write(to: url)
        return url
    }

    func testJPEGInfo() throws {
        let data = makeJPEG(width: 320, height: 200, color: .white)
        let info = try PDFWrap.jpegInfo(data)
        XCTAssertEqual(info.width, 320)
        XCTAssertEqual(info.height, 200)
        XCTAssertTrue([1, 3].contains(info.components), "components=\(info.components)")
    }

    func testRejectsNonJPEG() {
        XCTAssertThrowsError(try PDFWrap.jpegInfo(Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0])))
        XCTAssertThrowsError(try PDFWrap.jpegInfo(Data()))
    }

    func testMultiPagePDFOpensInPDFKit() throws {
        let a = try tempFile("a.jpg", makeJPEG(width: 640, height: 360, color: .white))
        let b = try tempFile("b.jpg", makeJPEG(width: 300, height: 400, color: .yellow))
        let c = try tempFile("c.jpg", makeJPEG(width: 1920, height: 1080, color: .lightGray))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let handle = try FileHandle(forWritingTo: out)
        try PDFWrap.write(jpegs: [a, b, c], title: "Belge_(test)", to: handle)
        try handle.close()

        let data = try Data(contentsOf: out)
        XCTAssertEqual(String(data: data.prefix(8), encoding: .ascii), "%PDF-1.4")
        // JPEG baytları PDF içinde olduğu gibi durur (kayıpsız)
        let original = try Data(contentsOf: a)
        XCTAssertNotNil(data.range(of: original))

        let document = PDFDocument(url: out)
        XCTAssertNotNil(document)
        XCTAssertEqual(document?.pageCount, 3)
        let second = document?.page(at: 1)?.bounds(for: .mediaBox)
        XCTAssertEqual(Double(second?.width ?? 0), 300.0 * 72.0 / 150.0, accuracy: 0.1)
        XCTAssertEqual(Double(second?.height ?? 0), 400.0 * 72.0 / 150.0, accuracy: 0.1)
    }

    func testEmptyListFails() throws {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let handle = try FileHandle(forWritingTo: out)
        defer { try? handle.close() }
        XCTAssertThrowsError(try PDFWrap.write(jpegs: [], title: "x", to: handle))
    }

    /// Karar M: PDF parçaları mümkün olduğunca eşit sayıda sayfa içerir (sınır 20 sayfa / 15 MB)
    func testPartsSplitPagesEvenly() {
        func plan(_ pages: Int, bytes: Int = 0, maxPages: Int = 20) -> [Int] {
            var left = pages
            var out: [Int] = []
            while left > 0 {
                let n = UploadQueue.nextPartCount(pages: left, totalBytes: bytes * left / max(pages, 1), maxPages: maxPages)
                out.append(n)
                left -= n
            }
            return out
        }
        XCTAssertEqual(plan(70), [18, 18, 17, 17], "70 sayfa → 4 parça")
        XCTAssertEqual(plan(20), [20])
        XCTAssertEqual(plan(21), [11, 10])
        XCTAssertEqual(plan(1), [1])
        XCTAssertEqual(plan(41), [14, 14, 13], "41 sayfa → 3 parça")
        XCTAssertEqual(UploadQueue.nextPartCount(pages: 0, totalBytes: 0), 0)
        // Bayt sınırı sayfa sınırından önce dolarsa parça sayısı baytla belirlenir: 12 sayfa, 40 MB, sınır 15 MB → 3 parça
        XCTAssertEqual(UploadQueue.nextPartCount(pages: 12, totalBytes: 40 * 1024 * 1024), 4)
        XCTAssertEqual(plan(70, maxPages: 30), [24, 23, 23], "ayarda sayfa sınırı verilmişse o kullanılır")
    }
}
