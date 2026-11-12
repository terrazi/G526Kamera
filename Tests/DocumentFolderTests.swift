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
