import XCTest
@testable import G526CameraDrive

final class DocumentFolderTests: XCTestCase {
    private var dir: URL!
    private var suite: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("belge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suiteName = "belge-test-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        suite.removePersistentDomain(forName: suiteName)
    }

    private func folder() -> DocumentFolder {
        return DocumentFolder(defaults: suite, key: "k")
    }

    private func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f.date(from: s)!
    }

    func testStampIsYearMonthDayHourMinuteSecond() {
        XCTAssertEqual(FileStamp.stamp(date("2026-11-12 09:12:45")), "20261112091245")
        XCTAssertEqual(FileStamp.stamp(date("2026-01-05 00:03:09")), "20260105000309")
    }

    func testStampSortsChronologicallyByName() {
        let a = FileStamp.stamp(date("2026-11-12 09:12:45"))
        let b = FileStamp.stamp(date("2026-12-05 08:00:00"))
        XCTAssertLessThan(a, b)
    }

    func testUniqueNameAddsSuffixOnCollision() {
        var taken: Set<String> = []
        func next() -> String {
            let n = FileStamp.uniqueName(stamp: "20261112091245", ext: "pdf") { taken.contains($0) }
            taken.insert(n)
            return n
        }
        XCTAssertEqual(next(), "20261112091245.pdf")
        XCTAssertEqual(next(), "20261112091245-2.pdf")
        XCTAssertEqual(next(), "20261112091245-3.pdf")
        XCTAssertEqual(FileStamp.uniqueName(stamp: "20261112091245", ext: ".mp4") { _ in false }, "20261112091245.mp4")
    }

    func testNothingChosenReportsIt() {
        let f = folder()
        XCTAssertFalse(f.hasChoice)
        XCTAssertEqual(f.statusText(), "Klasör seçilmedi")
        XCTAssertNotNil(f.probe())
        XCTAssertThrowsError(try f.store(data: Data("a".utf8), ext: "txt"))
    }

    func testChosenFolderReceivesStampedFilesAndNeverOverwrites() throws {
        let f = folder()
        try f.choose(dir)
        XCTAssertTrue(f.hasChoice)
        XCTAssertNil(f.probe())
        let when = date("2026-11-12 09:12:45")
        let one = try f.store(data: Data("bir".utf8), ext: "txt", date: when)
        let two = try f.store(data: Data("iki".utf8), ext: "txt", date: when)
        XCTAssertEqual(one.lastPathComponent, "20261112091245.txt")
        XCTAssertEqual(two.lastPathComponent, "20261112091245-2.txt")
        XCTAssertEqual(try String(contentsOf: one, encoding: .utf8), "bir")
        XCTAssertEqual(try String(contentsOf: two, encoding: .utf8), "iki")
        XCTAssertTrue(f.statusText().hasSuffix("yazılabiliyor"), f.statusText())
    }

    func testStoreFileCopiesAndKeepsTheSource() throws {
        let f = folder()
        try f.choose(dir)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("kaynak-\(UUID().uuidString).mp4")
        try Data("video".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let stored = try f.store(file: source, ext: "mp4", date: date("2026-11-12 09:13:00"))
        XCTAssertEqual(stored.lastPathComponent, "20261112091300.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "kaynak silinmemeli")
        XCTAssertEqual(try Data(contentsOf: stored), Data("video".utf8))
    }

    func testMissingFolderIsReportedWithAHint() throws {
        let f = folder()
        try f.choose(dir)
        try FileManager.default.removeItem(at: dir)
        let reason = f.probe()
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("yeniden seçin") ?? false, reason ?? "")
    }

    func testForgetClearsTheChoice() throws {
        let f = folder()
        try f.choose(dir)
        f.forget()
        XCTAssertFalse(f.hasChoice)
    }
}

import PDFKit
import UIKit

final class FolderClientTests: XCTestCase {
    private var dir: URL!
    private var suite: UserDefaults!
    private var suiteName: String!
    private var folder: DocumentFolder!
    private var client: FolderClient!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("klasor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suiteName = "klasor-test-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        folder = DocumentFolder(defaults: suite, key: "k")
        client = FolderClient(folder: folder)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        suite.removePersistentDomain(forName: suiteName)
    }

    private func jpeg(_ color: UIColor) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 300), format: format).image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        }
        return image.jpegData(compressionQuality: 0.9)!
    }

    private func temp(_ name: String, _ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try data.write(to: url)
        return url
    }

    func testIsNotReadyUntilAFolderIsChosen() async throws {
        XCTAssertFalse(client.isReady)
        let file = try temp("a.txt", Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            _ = try await client.save(.text(file))
            XCTFail("klasör seçilmeden kaydedilmemeli")
        } catch let error as DocumentFolderError {
            XCTAssertTrue(error.message.contains("seçilmedi"))
        }
        try folder.choose(dir)
        XCTAssertTrue(client.isReady)
    }

    func testSavesTextVideoAndJpegWithStampedNames() async throws {
        try folder.choose(dir)
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        let stamp = FileStamp.stamp(when)
        let text = try temp("a.txt", Data("cevaplar".utf8))
        let video = try temp("v.mp4", Data("video".utf8))
        let photo = try temp("f.jpg", jpeg(.white))
        defer { for f in [text, video, photo] { try? FileManager.default.removeItem(at: f) } }

        let t = try await client.save(.text(text), date: when)
        let v = try await client.save(.video(video), date: when)
        let p = try await client.save(.jpeg(photo), date: when)
        XCTAssertEqual(t.id, "\(stamp).txt")
        XCTAssertEqual(v.id, "\(stamp).mp4")
        XCTAssertEqual(p.id, "\(stamp).jpg")
        XCTAssertEqual(t.size, 8)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(t.id), encoding: .utf8), "cevaplar")
        XCTAssertTrue(FileManager.default.fileExists(atPath: text.path), "kaynak dosya silinmemeli")
    }

    func testPdfIsWrittenAndSameSecondGetsASuffix() async throws {
        try folder.choose(dir)
        let when = Date(timeIntervalSince1970: 1_800_000_100)
        let a = try temp("1.jpg", jpeg(.white))
        let b = try temp("2.jpg", jpeg(.lightGray))
        defer { for f in [a, b] { try? FileManager.default.removeItem(at: f) } }

        let first = try await client.save(.pdf([a, b], title: "deneme"), date: when)
        let second = try await client.save(.pdf([a], title: "deneme"), date: when)
        let stamp = FileStamp.stamp(when)
        XCTAssertEqual(first.id, "\(stamp).pdf")
        XCTAssertEqual(second.id, "\(stamp)-2.pdf")
        let document = PDFDocument(url: dir.appendingPathComponent(first.id))
        XCTAssertEqual(document?.pageCount, 2)
        XCTAssertGreaterThan(first.size, 0)
    }

    func testListsNewestPdfsFirstAndReadsThemBack() async throws {
        try folder.choose(dir)
        let photo = try temp("f.jpg", jpeg(.white))
        defer { try? FileManager.default.removeItem(at: photo) }
        let old = try await client.save(.pdf([photo], title: "a"), date: Date(timeIntervalSince1970: 1_800_000_000))
        let new = try await client.save(.pdf([photo], title: "b"), date: Date(timeIntervalSince1970: 1_800_100_000))
        let note = try temp("n.txt", Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: note) }
        _ = try await client.save(.text(note), date: Date(timeIntervalSince1970: 1_800_200_000))

        let listing = try await client.listPDFs(count: 10)
        XCTAssertEqual(listing.map { $0.id }, [new.id, old.id], "yalnız PDF'ler, en yeni önce")
        XCTAssertEqual(listing[0].size, new.size)
        let data = try await client.download(fileID: new.id)
        XCTAssertEqual(data.count, new.size)
        XCTAssertNotNil(PDFDocument(data: data))
        let limited = try await client.listPDFs(count: 1)
        XCTAssertEqual(limited.count, 1)
    }

    func testDownloadOfAMissingFileFailsClearly() async throws {
        try folder.choose(dir)
        do {
            _ = try await client.download(fileID: "yok.pdf")
            XCTFail("olmayan dosya okunmamalı")
        } catch let error as DocumentFolderError {
            XCTAssertTrue(error.message.contains("yok.pdf"))
        }
    }

    func testListPageSizeFollowsTheDocumentCountSetting() {
        XCTAssertEqual(FolderClient.listPageSize(3), 3)
        XCTAssertEqual(FolderClient.listPageSize(0), 1)
        XCTAssertEqual(FolderClient.listPageSize(500), 50)
    }
}
