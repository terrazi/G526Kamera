import XCTest
@testable import G526CameraDrive

/// Ayarlar > Eski kayıtları sil: son 1 saat / 6 saat / 24 saat / tüm kayıtlar. Silinenler: o süre içinde başlayan sınav kayıtları (kayıt klasöründeki
/// cevap sesleri ve cevaplar.txt) ile telefondaki çekimler. Kayıt klasöründeki başka dosya ve klasörlere dokunulmaz.
final class CleanupWindowTests: XCTestCase {
    private let fm = FileManager.default
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeExam(_ root: URL, at date: Date, suffix: String = "") -> String {
        let name = AnswerLibrary.folderName(for: date) + suffix
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try? fm.createDirectory(at: dir.appendingPathComponent("bolum_2", isDirectory: true), withIntermediateDirectories: true)
        try? Data("Soru 1, Denizli, Örgütsel Davranış\n".utf8).write(to: dir.appendingPathComponent("cevaplar.txt"))
        try? Data([0]).write(to: dir.appendingPathComponent("soru_1.m4a"))
        try? Data([0]).write(to: dir.appendingPathComponent("bolum_2/soru_1.m4a"))
        return name
    }

    private func names(_ root: URL) -> [String] {
        return ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
    }

    func testTheFourChoicesAndTheirCutoffs() {
        XCTAssertEqual(CleanupWindow.allCases.map { $0.title }, ["Son 1 saat", "Son 6 saat", "Son 24 saat", "Tüm kayıtlar"])
        XCTAssertEqual(CleanupWindow.lastHour.cutoff(now: now), now.addingTimeInterval(-3_600))
        XCTAssertEqual(CleanupWindow.lastSixHours.cutoff(now: now), now.addingTimeInterval(-21_600))
        XCTAssertEqual(CleanupWindow.lastDay.cutoff(now: now), now.addingTimeInterval(-86_400))
        XCTAssertNil(CleanupWindow.all.cutoff(now: now), "Tüm kayıtlar: süre sınırı yok")
    }

    func testExamFoldersAreChosenByTheirStartTime() {
        let root = makeTempFolder("g526-temizlik")
        let recent = makeExam(root, at: now.addingTimeInterval(-30 * 60))
        let threeHours = makeExam(root, at: now.addingTimeInterval(-3 * 3_600))
        let thirtyHours = makeExam(root, at: now.addingTimeInterval(-30 * 3_600))
        let library = AnswerLibrary(root: root)
        func chosen(_ window: CleanupWindow) -> [String] {
            return library.examFolders(since: window.cutoff(now: now)).map { $0.lastPathComponent }.sorted()
        }
        XCTAssertEqual(chosen(.lastHour), [recent])
        XCTAssertEqual(chosen(.lastSixHours), [threeHours, recent].sorted())
        XCTAssertEqual(chosen(.lastDay), [threeHours, recent].sorted(), "30 saat önceki kayıt son 24 saatte değildir")
        XCTAssertEqual(chosen(.all), [thirtyHours, threeHours, recent].sorted())
    }

    func testOnlyExamFoldersAreEverTouchedAndEverythingInsideGoesWithThem() {
        let root = makeTempFolder("g526-temizlik")
        let recent = makeExam(root, at: now.addingTimeInterval(-10 * 60))
        let sameSecond = makeExam(root, at: now.addingTimeInterval(-10 * 60), suffix: "_2")
        let old = makeExam(root, at: now.addingTimeInterval(-90 * 3_600))
        try? fm.createDirectory(at: root.appendingPathComponent("2026-11-01", isDirectory: true), withIntermediateDirectories: true)   // eski sürümlerin gün adı
        try? fm.createDirectory(at: root.appendingPathComponent("Cekimler/Bekleyen", isDirectory: true), withIntermediateDirectories: true)
        try? fm.createDirectory(at: root.appendingPathComponent("Notlarım", isDirectory: true), withIntermediateDirectories: true)
        try? Data("x".utf8).write(to: root.appendingPathComponent("deneme.txt"))
        try? Data("x".utf8).write(to: root.appendingPathComponent("20261115223912"))   // aynı adlı DOSYA: klasör değil, dokunulmaz
        let library = AnswerLibrary(root: root)

        XCTAssertEqual(library.deleteExamFolders(since: now.addingTimeInterval(-3_600)), 2)
        XCTAssertEqual(names(root), ["20261115223912", "2026-11-01", "Cekimler", "Notlarım", "deneme.txt", old].sorted())
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent(recent).path))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent(sameSecond).path))

        XCTAssertEqual(library.deleteExamFolders(since: nil), 2, "Tüm kayıtlar: kalan iki sınav klasörü (biri eski gün adlı)")
        XCTAssertEqual(names(root), ["20261115223912", "Cekimler", "Notlarım", "deneme.txt"].sorted(),
                       "Sınav olmayan klasörlere, dosyalara ve Cekimler klasörüne dokunulmaz")
    }

    func testAMissingOrEmptyRecordFolderDeletesNothing() {
        let missing = AnswerLibrary(root: makeTempFolder("g526-temizlik").appendingPathComponent("yok", isDirectory: true))
        XCTAssertEqual(missing.deleteExamFolders(since: nil), 0)
        XCTAssertTrue(missing.examFolders(since: nil).isEmpty)
    }

    func testTheDateOfAFolderNameIsReadInLocalTime() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let name = AnswerLibrary.folderName(for: date)
        XCTAssertEqual(AnswerLibrary.startDate(ofFolderNamed: name), date)
        XCTAssertEqual(AnswerLibrary.startDate(ofFolderNamed: name + "_3"), date)
        XCTAssertNotNil(AnswerLibrary.startDate(ofFolderNamed: "2026-11-13"))
        XCTAssertNil(AnswerLibrary.startDate(ofFolderNamed: "Cekimler"))
        XCTAssertNil(AnswerLibrary.startDate(ofFolderNamed: "deneme.txt"))
    }

    /// Yeni ad "2026-11-15-223912", önceki sürümün adı "20261115223912", en eski gün adı "2026-11-13": üçü de başladıkları ana göre bulunur
    func testFoldersOfAllThreeNameStylesAreFoundByTheirStartTime() {
        let root = makeTempFolder("g526-temizlik-adlar")
        let calendar = Calendar.current
        func date(_ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date {
            return calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute, second: second))!
        }
        XCTAssertEqual(AnswerLibrary.startDate(ofFolderNamed: "2026-11-15-223912"), date(15, 22, 39, 12))
        XCTAssertEqual(AnswerLibrary.startDate(ofFolderNamed: "2026-11-15-223912_2"), date(15, 22, 39, 12))
        XCTAssertEqual(AnswerLibrary.startDate(ofFolderNamed: "20261115223912"), date(15, 22, 39, 12))
        XCTAssertEqual(AnswerLibrary.startDate(ofFolderNamed: "2026-11-13"), date(13, 0, 0, 0))
        XCTAssertNil(AnswerLibrary.startDate(ofFolderNamed: "2026-11-15-2239"))
        XCTAssertNil(AnswerLibrary.startDate(ofFolderNamed: "2026-11-15-223912_x"))

        for name in [AnswerLibrary.folderName(for: date(15, 22, 39, 12)), "20261115223913", "2026-11-13", "2026-11-14-090000"] {
            try? fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let library = AnswerLibrary(root: root)
        XCTAssertEqual(library.examFolders(since: date(15, 0, 0, 0)).map { $0.lastPathComponent }.sorted(), ["2026-11-15-223912", "20261115223913"])
        XCTAssertEqual(library.examFolders(since: nil).count, 4)
        XCTAssertEqual(library.deleteExamFolders(since: date(14, 0, 0, 0)), 3, "14 Kasım 09:00 ve 15 Kasım'daki iki klasör silinir")
        XCTAssertEqual(names(root), ["2026-11-13"])
    }

    func testTheCountsExplainWhatWillBeDeleted() {
        XCTAssertEqual(CleanupCounts(exams: 2, captures: 5).text, "2 sınav kaydı, 5 çekim")
        XCTAssertEqual(CleanupCounts().text, "kayıt yok")
        XCTAssertEqual(CleanupCounts(exams: 1, captures: 0).doneText, "1 sınav kaydı ve 0 çekim silindi.")
        XCTAssertEqual(CleanupCounts().doneText, "Bu aralıkta silinecek kayıt yoktu.")
    }
}

/// Çekim klasörü (Cekimler) için süreli silme
@MainActor
final class CleanupCaptureTests: XCTestCase {
    private var root: URL!
    private var store: FileCaptureStore!
    private let fm = FileManager.default
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        root = makeTempFolder("g526-temizlik-cekim").appendingPathComponent("Cekimler", isDirectory: true)
        store = FileCaptureStore(root: root)
        store.prepare()
    }

    private func shot(minutesAgo: Double) -> CapturedQuestion {
        var s = FakeCamera.shot(video: false)
        s.date = now.addingTimeInterval(-minutesAgo * 60)
        return s
    }

    private func buckets() -> [String: Int] {
        var result: [String: Int] = [:]
        for bucket in FileCaptureStore.Bucket.allCases {
            result[bucket.rawValue] = ((try? fm.contentsOfDirectory(atPath: store.url(of: bucket).path)) ?? []).count
        }
        return result
    }

    /// Bekleyen (10 dk), gönderilen (3 saat), gönderilemeyen (20 saat), paragraf (30 saat) ve bir bekleyen daha (5 dk)
    private func fill() {
        _ = store.keep(shot(minutesAgo: 10), kind: .question)
        let sent = store.keep(shot(minutesAgo: 180), kind: .question)
        store.markSent(sent, answer: "Soru 1, Denizli, A")
        let bad = store.keep(shot(minutesAgo: 20 * 60), kind: .question)
        store.markUnsendable(bad, reason: "Gemini kabul etmedi")
        _ = store.keep(shot(minutesAgo: 30 * 60), kind: .passage)
        _ = store.keep(shot(minutesAgo: 5), kind: .page)
    }

    func testCountingAndDeletingFollowTheWindowInEveryFolder() {
        fill()
        XCTAssertEqual(store.count(since: now.addingTimeInterval(-3_600)), 2)
        XCTAssertEqual(store.count(since: now.addingTimeInterval(-6 * 3_600)), 3)
        XCTAssertEqual(store.count(since: now.addingTimeInterval(-24 * 3_600)), 4)
        XCTAssertEqual(store.count(since: nil), 5)

        XCTAssertEqual(store.delete(since: now.addingTimeInterval(-3_600)), 2, "Son 1 saatteki iki bekleyen çekim silinir")
        XCTAssertEqual(buckets(), ["Bekleyen": 0, "Gonderilen": 1, "Gonderilemeyen": 1, "Paragraf": 1])
        XCTAssertTrue(store.restorePending().isEmpty, "Silinen bekleyen çekimler yeniden yüklenmez")
        XCTAssertEqual(store.delete(since: now.addingTimeInterval(-6 * 3_600)), 1, "Gönderilen (3 saat önce) de silinir")
        XCTAssertEqual(buckets(), ["Bekleyen": 0, "Gonderilen": 0, "Gonderilemeyen": 1, "Paragraf": 1])
    }

    func testAllRecordsDeletesEverythingIncludingWhatWaitsToBeSent() {
        fill()
        XCTAssertEqual(store.delete(since: nil), 5)
        XCTAssertEqual(buckets(), ["Bekleyen": 0, "Gonderilen": 0, "Gonderilemeyen": 0, "Paragraf": 0])
        XCTAssertEqual(store.count(since: nil), 0)
        XCTAssertEqual(store.delete(since: nil), 0, "Boş klasörde ikinci silme bir şey yapmaz")
        for bucket in FileCaptureStore.Bucket.allCases {
            XCTAssertTrue(fm.fileExists(atPath: store.url(of: bucket).path), "Bölüm klasörleri kalır")
        }
    }

    /// Çekim klasörleri de sınav klasörleri gibi "yıl-ay-gün-saatdakikasaniye_kimlik" adını alır; önceki sürümün "20261115-223912_kimlik" adları okunur
    func testCaptureFoldersAreNamedByDateAndTimeAndOldNamesStillWork() {
        let kept = store.keep(shot(minutesAgo: 30), kind: .question)
        let dirs = (try? fm.contentsOfDirectory(at: store.url(of: .pending), includingPropertiesForKeys: nil)) ?? []
        XCTAssertEqual(dirs.count, 1)
        guard let dir = dirs.first else { return }
        let name = dir.lastPathComponent
        XCTAssertNotNil(name.range(of: "^\\d{4}-\\d{2}-\\d{2}-\\d{6}_[0-9A-Fa-f]{8}$", options: .regularExpression), name)
        XCTAssertEqual(name, "\(AnswerLibrary.folderName(for: kept.date))_\(kept.id.uuidString.prefix(8))")

        // Önceki sürümün adı ve bilgi dosyası yok: tarih adın kendisinden okunur
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let oldName = "\(formatter.string(from: kept.date))_\(kept.id.uuidString.prefix(8))"
        let oldDir = dir.deletingLastPathComponent().appendingPathComponent(oldName, isDirectory: true)
        XCTAssertNotNil(try? fm.moveItem(at: dir, to: oldDir))
        try? fm.removeItem(at: oldDir.appendingPathComponent("bilgi.json"))
        XCTAssertEqual(store.count(since: now.addingTimeInterval(-3_600)), 1, "Eski adlı klasörün tarihi okunur")
        XCTAssertEqual(store.count(since: now.addingTimeInterval(60)), 0)
    }

    func testTheCaptureTimeIsReadFromTheFolderNameWhenTheInfoFileIsGone() {
        let kept = store.keep(shot(minutesAgo: 30), kind: .question)
        XCTAssertTrue(kept.archived)
        let dir = ((try? fm.contentsOfDirectory(at: store.url(of: .pending), includingPropertiesForKeys: nil)) ?? []).first
        XCTAssertNotNil(dir)
        if let dir = dir { try? fm.removeItem(at: dir.appendingPathComponent("bilgi.json")) }
        XCTAssertEqual(store.count(since: now.addingTimeInterval(-3_600)), 1, "Klasör adındaki tarih kullanılır")
        XCTAssertEqual(store.count(since: now.addingTimeInterval(60)), 0)
    }
}

/// Oturum modeli: test sürerken silinmez; durunca hem kayıt klasörü hem çekimler silinir
@MainActor
final class CleanupSessionTests: XCTestCase {
    private let fm = FileManager.default

    private func exam(_ h: SessionHarness, minutesAgo: Double) -> URL {
        let date = Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(-minutesAgo * 60)
        let dir = h.root.appendingPathComponent(AnswerLibrary.folderName(for: date), isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data("Soru 1, Denizli, A\n".utf8).write(to: dir.appendingPathComponent("cevaplar.txt"))
        return dir
    }

    private func capture(_ h: SessionHarness, minutesAgo: Double, kind: CaptureKind = .question) -> CapturedQuestion {
        var s = FakeCamera.shot(video: false)
        s.date = Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(-minutesAgo * 60)
        return h.fileStore?.keep(s, kind: kind) ?? s
    }

    func testTheCountsAreShownBeforeAnythingIsDeleted() {
        let h = SessionHarness(archive: true)
        _ = exam(h, minutesAgo: 20)
        _ = exam(h, minutesAgo: 600)
        _ = capture(h, minutesAgo: 5)
        XCTAssertEqual(h.vm.cleanupCounts(.lastHour), CleanupCounts(exams: 1, captures: 1))
        XCTAssertEqual(h.vm.cleanupCounts(.lastDay), CleanupCounts(exams: 2, captures: 1))
        XCTAssertEqual(h.vm.cleanupCounts(.all), CleanupCounts(exams: 2, captures: 1))
    }

    func testDeletingRemovesTheRecordsAndTheCapturesAndDropsPendingShotsFromMemory() {
        let h = SessionHarness(archive: true)
        let recent = exam(h, minutesAgo: 20)
        let old = exam(h, minutesAgo: 600)
        let fresh = capture(h, minutesAgo: 5)
        let older = capture(h, minutesAgo: 600)
        h.vm.pendingShots = [older, fresh]
        h.vm.retriedShots = [fresh.id, older.id]

        let result = h.vm.deleteRecords(.lastHour)
        XCTAssertEqual(result, CleanupCounts(exams: 1, captures: 1))
        XCTAssertFalse(fm.fileExists(atPath: recent.path))
        XCTAssertTrue(fm.fileExists(atPath: old.path), "6 saat önceki kayıt son 1 saatin dışındadır")
        XCTAssertEqual(h.vm.pendingShots.map { $0.id }, [older.id], "Silinen çekim bekleyenler listesinden de düşer")
        XCTAssertEqual(h.vm.retriedShots, [older.id])

        XCTAssertEqual(h.vm.deleteRecords(.all), CleanupCounts(exams: 1, captures: 1))
        XCTAssertFalse(fm.fileExists(atPath: old.path))
        XCTAssertTrue(h.vm.pendingShots.isEmpty)
    }

    func testNothingIsDeletedWhileATestIsRunning() async {
        let h = SessionHarness(archive: true)
        let dir = exam(h, minutesAgo: 5)
        _ = capture(h, minutesAgo: 5)
        _ = await h.startListening()
        XCTAssertNil(h.vm.deleteRecords(.all), "Test sürerken silinmez")
        XCTAssertTrue(fm.fileExists(atPath: dir.path))
        XCTAssertEqual(h.fileStore?.count(since: nil), 1)
    }
}
