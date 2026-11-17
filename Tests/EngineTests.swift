import XCTest
@testable import G526CameraDrive

// MARK: - Modül 4: onarım sırası

@MainActor
final class RecoveryCoordinatorTests: XCTestCase {
    private let names: (RecoveryStep) -> String = { step in
        switch step {
        case .wifi: return "WiFi_Ac"
        case .cellular: return "Hücresel_Ac"
        case .bluetooth: return "Bluetooth_Yenile"
        case .reset: return "Sistemi_Sifirla"
        }
    }

    private func make(_ shortcuts: FakeShortcuts, maxCycles: Int = 1,
                      name: ((RecoveryStep) -> String)? = nil) -> RecoveryCoordinator {
        let config = RecoveryCoordinator.Config(settle: 0, verifyWindow: 0, verifyInterval: 1, cycleGap: 0, maxCycles: maxCycles)
        return RecoveryCoordinator(shortcuts: shortcuts, name: name ?? names, config: config, sleep: { _ in })
    }

    func testAlreadyHealthyRunsNoShortcut() async {
        let shortcuts = FakeShortcuts()
        let result = await make(shortcuts).recover(reason: .network, verify: { _ in true }, update: { _ in })
        XCTAssertEqual(result, .recovered(by: nil))
        XCTAssertTrue(shortcuts.runs.isEmpty)
    }

    func testNetworkOrderIsCellularThenReset() async {
        let shortcuts = FakeShortcuts()
        let result = await make(shortcuts).recover(reason: .network, verify: { _ in false }, update: { _ in })
        XCTAssertEqual(result, .gaveUp)
        XCTAssertEqual(shortcuts.runs, ["Hücresel_Ac", "Sistemi_Sifirla"], "Wi-Fi adımı yok: V4'te Wi-Fi kameraya ayrılmıştır, yedek internet değildir")
    }

    func testStopsAtTheStepThatFixesIt() async {
        let shortcuts = FakeShortcuts()
        var fixed = false
        shortcuts.onRun = { name in if name == "Hücresel_Ac" { fixed = true } }
        let result = await make(shortcuts).recover(reason: .network, verify: { _ in fixed }, update: { _ in })
        XCTAssertEqual(result, .recovered(by: .cellular))
        XCTAssertEqual(shortcuts.runs, ["Hücresel_Ac"], "Düzelince sıradaki kestirme çalıştırılmaz")
    }

    func testHardwareRunsBluetoothRefreshThenReset() async {
        let shortcuts = FakeShortcuts()
        _ = await make(shortcuts).recover(reason: .hardware, verify: { _ in false }, update: { _ in })
        XCTAssertEqual(shortcuts.runs, ["Bluetooth_Yenile", "Sistemi_Sifirla"], "İnternet kestirmeleri donanımda çalışmaz")
    }

    func testBluetoothRefreshFixingTheRouteSkipsTheReset() async {
        let shortcuts = FakeShortcuts()
        var fixed = false
        shortcuts.onRun = { _ in fixed = true }
        let result = await make(shortcuts).recover(reason: .hardware, verify: { _ in fixed }, update: { _ in })
        XCTAssertEqual(result, .recovered(by: .bluetooth))
        XCTAssertEqual(shortcuts.runs, ["Bluetooth_Yenile"], "Hafif adım işe yaradıysa uçak modu kestirmesi çalışmaz")
    }

    func testEmptyBluetoothNameGoesStraightToReset() async {
        let shortcuts = FakeShortcuts()
        _ = await make(shortcuts, name: { $0 == .bluetooth ? "" : "X_\($0.rawValue)" })
            .recover(reason: .hardware, verify: { _ in false }, update: { _ in })
        XCTAssertEqual(shortcuts.runs, ["X_reset"])
    }

    func testEmptyNamesAreSkippedAndAllEmptyIsNotConfigured() async {
        let shortcuts = FakeShortcuts()
        _ = await make(shortcuts, name: { $0 == .cellular ? "  " : "X_\($0.rawValue)" })
            .recover(reason: .network, verify: { _ in false }, update: { _ in })
        XCTAssertEqual(shortcuts.runs, ["X_reset"])

        let none = FakeShortcuts()
        let result = await make(none, name: { _ in "" }).recover(reason: .network, verify: { _ in false }, update: { _ in })
        XCTAssertEqual(result, .notConfigured)
        XCTAssertTrue(none.runs.isEmpty)
    }

    func testForceSkipsTheInitialHealthCheck() async {
        let shortcuts = FakeShortcuts()
        let result = await make(shortcuts).recover(reason: .hardware, force: true, verify: { _ in true }, update: { _ in })
        XCTAssertEqual(result, .recovered(by: .reset))
        XCTAssertEqual(shortcuts.runs, ["Sistemi_Sifirla"], "Sağlıklı görünse bile en az bir kez çalışır")
    }

    func testRepeatsCyclesWithWaitingBetween() async {
        let shortcuts = FakeShortcuts()
        var updates: [RecoveryCoordinator.Update] = []
        let result = await make(shortcuts, maxCycles: 2)
            .recover(reason: .network, verify: { _ in false }, update: { updates.append($0) })
        XCTAssertEqual(result, .gaveUp)
        XCTAssertEqual(shortcuts.runs.count, 4, "Sürüm 4: internet için iki adım (hücresel, sıfırlama) × 2 tur; Wi-Fi artık internet adımı değil")
        XCTAssertTrue(updates.contains(.waiting(cycle: 1)))
        XCTAssertEqual(updates.first, .checking)
    }

    func testReportsProgressForEachStep() async {
        let shortcuts = FakeShortcuts()
        var updates: [RecoveryCoordinator.Update] = []
        _ = await make(shortcuts).recover(reason: .hardware, verify: { _ in false }, update: { updates.append($0) })
        XCTAssertEqual(updates, [.checking, .running(.bluetooth), .verifying(.bluetooth), .running(.reset), .verifying(.reset)])
    }

    func testVerificationWindowPollsRepeatedly() async {
        let shortcuts = FakeShortcuts()
        let config = RecoveryCoordinator.Config(settle: 0, verifyWindow: 5, verifyInterval: 1, cycleGap: 0, maxCycles: 1)
        let coordinator = RecoveryCoordinator(shortcuts: shortcuts, name: names, config: config, sleep: { _ in })
        var checks = 0
        let result = await coordinator.recover(reason: .hardware, verify: { _ in
            checks += 1
            return checks >= 4   // ilk sınama ve kestirmeden sonraki iki yoklama başarısız, sonra düzelir
        }, update: { _ in })
        XCTAssertEqual(result, .recovered(by: .bluetooth))
        XCTAssertEqual(shortcuts.runs.count, 1)
        XCTAssertEqual(checks, 4)
    }
}

// MARK: - Modül 4: 30 saniyelik sessizlik

@MainActor
final class SilenceWatchdogTests: XCTestCase {
    func testExpiresAfterThirtySeconds() {
        let scheduler = ManualScheduler()
        let dog = SilenceWatchdog(scheduler: scheduler)
        var expired = 0
        dog.onExpire = { expired += 1 }
        dog.kick()
        XCTAssertTrue(dog.isArmed)
        scheduler.advance(by: 29.9)
        XCTAssertEqual(expired, 0)
        scheduler.advance(by: 0.2)
        XCTAssertEqual(expired, 1)
        XCTAssertFalse(dog.isArmed)
    }

    func testKickRestartsTheClock() {
        let scheduler = ManualScheduler()
        let dog = SilenceWatchdog(scheduler: scheduler)
        var expired = 0
        dog.onExpire = { expired += 1 }
        dog.kick()
        scheduler.advance(by: 20)
        dog.kick()
        scheduler.advance(by: 29)
        XCTAssertEqual(expired, 0)
        scheduler.advance(by: 1.1)
        XCTAssertEqual(expired, 1)
    }

    func testDisarmCancels() {
        let scheduler = ManualScheduler()
        let dog = SilenceWatchdog(scheduler: scheduler)
        var expired = 0
        dog.onExpire = { expired += 1 }
        dog.kick()
        dog.disarm()
        scheduler.advance(by: 100)
        XCTAssertEqual(expired, 0)
        XCTAssertFalse(dog.isArmed)
        XCTAssertEqual(SilenceWatchdog.limit, 30)
    }
}

// MARK: - Modül 6: tekrar

@MainActor
final class ReplayControllerTests: XCTestCase {
    private func urls(_ count: Int) -> [URL] {
        return (0..<count).map { URL(fileURLWithPath: "/tmp/soru_\($0 + 1).m4a") }
    }

    private func make(canPlay: @escaping () -> Bool = { true }) -> (ReplayController, FakePlayer, ManualScheduler) {
        let player = FakePlayer()
        let scheduler = ManualScheduler()
        return (ReplayController(player: player, scheduler: scheduler, canPlay: canPlay), player, scheduler)
    }

    func testPlaysInOrderWithExactGapBetweenFiles() {
        let (replay, player, scheduler) = make()
        replay.start(files: urls(3), gap: 3)
        XCTAssertEqual(player.played.count, 1)
        XCTAssertEqual(replay.state, .playing(index: 1, total: 3))

        player.finish()
        XCTAssertEqual(replay.state, .gap(next: 2, total: 3))
        XCTAssertEqual(scheduler.requested, [3])
        scheduler.advance(by: 2.99)
        XCTAssertEqual(player.played.count, 1)
        scheduler.advance(by: 0.02)
        XCTAssertEqual(player.played.count, 2)

        player.finish()
        scheduler.advance(by: 3)
        XCTAssertEqual(player.played.count, 3)
        player.finish()
        XCTAssertEqual(replay.state, .finished)
        XCTAssertEqual(scheduler.requested, [3, 3], "Son dosyadan sonra bekleme kurulmaz")
        XCTAssertEqual(player.played.map { $0.lastPathComponent }, ["soru_1.m4a", "soru_2.m4a", "soru_3.m4a"])
    }

    func testGapIsClampedToTheSliderRange() {
        let (replay, player, scheduler) = make()
        replay.start(files: urls(2), gap: 99)
        player.finish()
        XCTAssertEqual(scheduler.requested.last, 10)

        let (replay2, player2, scheduler2) = make()
        replay2.start(files: urls(2), gap: -5)
        player2.finish()
        XCTAssertEqual(scheduler2.requested.last, 0)
    }

    func testStopDuringGapCancelsTheNextFile() {
        let (replay, player, scheduler) = make()
        replay.start(files: urls(3), gap: 3)
        player.finish()
        replay.stop()
        scheduler.advance(by: 30)
        XCTAssertEqual(player.played.count, 1)
        XCTAssertEqual(replay.state, .stopped("Tekrar durduruldu."))
    }

    func testStopWhilePlayingSilencesThePlayer() {
        let (replay, player, _) = make()
        replay.start(files: urls(2), gap: 3)
        replay.stop(reason: "Kulaklık gitti")
        XCTAssertGreaterThanOrEqual(player.stopCalls, 1)
        XCTAssertEqual(replay.state, .stopped("Kulaklık gitti"))
    }

    func testNoPlaybackWithoutHeadphones() {
        let (replay, player, _) = make(canPlay: { false })
        replay.start(files: urls(2), gap: 3)
        XCTAssertTrue(player.played.isEmpty)
        XCTAssertEqual(replay.state, .stopped(Say.noHeadphonesForReplay))
    }

    func testHeadphonesLostBetweenFilesStopsTheRest() {
        var headphones = true
        let (replay, player, scheduler) = make(canPlay: { headphones })
        replay.start(files: urls(3), gap: 3)
        player.finish()
        headphones = false
        scheduler.advance(by: 3)
        XCTAssertEqual(player.played.count, 1)
        XCTAssertEqual(replay.state, .stopped(Say.noHeadphonesForReplay))
    }

    func testTwoFailedFilesInARowStop() {
        let (replay, player, scheduler) = make()
        replay.start(files: urls(4), gap: 3)
        player.finish(false)
        scheduler.advance(by: 3)
        player.finish(false)
        XCTAssertEqual(replay.state, .stopped("Dosya çalınamadı."), "Üst üste iki dosya çalınamazsa sorun dosyada değil, sistemdedir")
    }

    func testSingleBrokenFileIsSkippedAndTheRestKeepsPlaying() {
        let (replay, player, scheduler) = make()
        replay.start(files: urls(3), gap: 3)
        player.finish(false)
        XCTAssertEqual(replay.state, .gap(next: 2, total: 3), "Bozuk dosya tüm tekrarı durdurmaz")
        scheduler.advance(by: 3)
        player.finish()
        scheduler.advance(by: 3)
        player.finish()
        XCTAssertEqual(player.played.count, 3)
        XCTAssertEqual(replay.state, .finished)
        XCTAssertEqual(replay.failedCount, 1)
    }

    func testBrokenLastFileStillFinishes() {
        let (replay, player, _) = make()
        replay.start(files: urls(1), gap: 3)
        player.finish(false)
        XCTAssertEqual(replay.state, .finished)
        XCTAssertEqual(replay.failedCount, 1)
    }

    func testEmptyListFinishesImmediately() {
        let (replay, player, _) = make()
        replay.start(files: [], gap: 3)
        XCTAssertEqual(replay.state, .finished)
        XCTAssertTrue(player.played.isEmpty)
    }

    func testRestartIgnoresStaleCompletions() {
        let (replay, player, scheduler) = make()
        replay.start(files: urls(2), gap: 3)
        player.finish()
        replay.start(files: urls(2), gap: 3)   // gap bekleyen eski oturum iptal olur
        scheduler.advance(by: 3)
        XCTAssertEqual(player.played.count, 2, "Yeni başlangıç çaldı, eski boşluk bitişi çalmadı")
        XCTAssertEqual(replay.state, .playing(index: 1, total: 2))
    }
}

// MARK: - Modül 5 ve 6: cevap klasörü

final class AnswerLibraryTests: XCTestCase {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func touch(_ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data([1]).write(to: url)
    }

    func testFolderNameIsTheDateAndTimeDownToTheSecond() {
        let date = utc.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 22, minute: 39, second: 12))!
        XCTAssertEqual(AnswerLibrary.folderName(for: date, calendar: utc), "2026-11-15-223912", "Biçim: yıl-ay-gün-saatdakikasaniye")
        let early = utc.date(from: DateComponents(year: 2026, month: 1, day: 3, hour: 4, minute: 5, second: 6))!
        XCTAssertEqual(AnswerLibrary.folderName(for: early, calendar: utc), "2026-01-03-040506", "Tek haneliler sıfırla doldurulur")
    }

    func testParseFolderName() {
        XCTAssertEqual(AnswerLibrary.parseFolderName("2026-11-15-223912")?.day, "2026-11-15-223912")
        XCTAssertEqual(AnswerLibrary.parseFolderName("2026-11-15-223912")?.part, 1)
        XCTAssertEqual(AnswerLibrary.parseFolderName("2026-11-15-223912_2")?.part, 2)
        XCTAssertNil(AnswerLibrary.parseFolderName("2026-11-15-2239"), "Saniyesiz ad bu biçim değildir")
        XCTAssertNil(AnswerLibrary.parseFolderName("2026-11-15-223912@2"), "Bölüm eki klasör adı değildir")
        XCTAssertNil(AnswerLibrary.parseFolderName("2026-11-15-223912_x"))
        XCTAssertEqual(AnswerLibrary.parseFolderName("20261115223912")?.day, "20261115223912", "Önceki sürümün bitişik adı tanınır")
        XCTAssertEqual(AnswerLibrary.parseFolderName("20261115223912")?.part, 1)
        XCTAssertEqual(AnswerLibrary.parseFolderName("20261115223912_2")?.part, 2)
        XCTAssertNil(AnswerLibrary.parseFolderName("202611152239"), "Saniyesiz ad bu biçim değildir")
        XCTAssertNil(AnswerLibrary.parseFolderName("20261115223912@2"), "Bölüm eki klasör adı değildir")
        XCTAssertEqual(AnswerLibrary.parseFolderName("2026-11-13")?.day, "2026-11-13", "Eski gün adları tanınır")
        XCTAssertEqual(AnswerLibrary.parseFolderName("2026-11-13")?.part, 1)
        XCTAssertEqual(AnswerLibrary.parseFolderName("2026-11-13_3")?.part, 3)
        XCTAssertNil(AnswerLibrary.parseFolderName("notlar"))
        XCTAssertNil(AnswerLibrary.parseFolderName("2026-11-13_x"))
    }

    func testQuestionNumberFromFileName() {
        XCTAssertEqual(AnswerLibrary.questionNumber(fromFileName: "soru_12.m4a"), 12)
        XCTAssertEqual(AnswerLibrary.questionNumber(fromFileName: "soru_3.WAV"), 3)
        XCTAssertEqual(AnswerLibrary.questionNumber(fromFileName: "soru_7.caf"), 7)
        XCTAssertNil(AnswerLibrary.questionNumber(fromFileName: "cevaplar.txt"))
        XCTAssertNil(AnswerLibrary.questionNumber(fromFileName: "soru_4.txt"))
        XCTAssertNil(AnswerLibrary.questionNumber(fromFileName: "soru_x.m4a"))
        XCTAssertNil(AnswerLibrary.questionNumber(fromFileName: "anons.m4a"))
    }

    func testFilesAreListedByQuestionNumberNotByName() {
        let root = makeTempFolder()
        let library = AnswerLibrary(root: root)
        let folder = root.appendingPathComponent("gun", isDirectory: true)
        ["soru_10.m4a", "soru_2.m4a", "soru_1.wav", "cevaplar.txt", "gecici.tmp"].forEach { touch(folder.appendingPathComponent($0)) }
        XCTAssertEqual(library.answerFiles(in: folder).map { $0.lastPathComponent }, ["soru_1.wav", "soru_2.m4a", "soru_10.m4a"])
    }

    func testEachSessionGetsItsOwnFolderNamedByTheMoment() throws {
        let root = makeTempFolder()
        let library = AnswerLibrary(root: root)
        let first = utc.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 22, minute: 39, second: 12))!
        let later = utc.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 23, minute: 5, second: 40))!

        let a = try library.newSessionFolder(for: first, calendar: utc)
        XCTAssertEqual(a.lastPathComponent, "2026-11-15-223912")
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        touch(a.appendingPathComponent("soru_1.m4a"))

        let b = try library.newSessionFolder(for: later, calendar: utc)
        XCTAssertEqual(b.lastPathComponent, "2026-11-15-230540", "Aynı günün ikinci sınavı kendi klasörünü alır")
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.appendingPathComponent("soru_1.m4a").path), "Önceki sınavın cevapları yerinde")
    }

    func testNewSessionFolderDoesNotOverwriteAnEarlierSessionOfTheSameSecond() throws {
        let root = makeTempFolder()
        let library = AnswerLibrary(root: root)
        let date = utc.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 9, minute: 0, second: 0))!

        let first = try library.newSessionFolder(for: date, calendar: utc)
        XCTAssertEqual(first.lastPathComponent, "2026-11-13-090000")

        let reused = try library.newSessionFolder(for: date, calendar: utc)
        XCTAssertEqual(reused.lastPathComponent, "2026-11-13-090000", "İçi boş klasör yeniden kullanılır")

        touch(first.appendingPathComponent("soru_1.m4a"))
        let second = try library.newSessionFolder(for: date, calendar: utc)
        XCTAssertEqual(second.lastPathComponent, "2026-11-13-090000_2")
        touch(second.appendingPathComponent("soru_1.m4a"))
        XCTAssertEqual(try library.newSessionFolder(for: date, calendar: utc).lastPathComponent, "2026-11-13-090000_3")
    }

    func testEmptyLeftoverSessionFoldersAreRemovedButAnswersAreNeverTouched() throws {
        let root = makeTempFolder()
        let library = AnswerLibrary(root: root)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("20261101100000"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("20261102100000/bolum_1"), withIntermediateDirectories: true)   // yalnız boş bölüm klasörü
        touch(root.appendingPathComponent("20261103100000/soru_1.m4a"))
        touch(root.appendingPathComponent("20261104100000/bolum_2/soru_5.m4a"))
        touch(root.appendingPathComponent("20261105100000/not.txt"))   // cevap olmasa da başka dosya içeren klasör korunur
        try fm.createDirectory(at: root.appendingPathComponent("kendi-klasorum"), withIntermediateDirectories: true)   // oturum klasörü olmayan ada dokunulmaz
        let date = utc.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 8, minute: 0, second: 0))!
        _ = try library.newSessionFolder(for: date, calendar: utc)
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("20261101100000").path))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("20261102100000").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("20261103100000/soru_1.m4a").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("20261104100000/bolum_2/soru_5.m4a").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("20261105100000/not.txt").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("kendi-klasorum").path))
    }

    func testLatestFolderIsTheNewestOneWithAnswers() {
        let root = makeTempFolder()
        let library = AnswerLibrary(root: root)
        XCTAssertNil(library.latestFolder())
        touch(root.appendingPathComponent("20261112090000/soru_1.m4a"))
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("20261113090000"), withIntermediateDirectories: true)
        XCTAssertEqual(library.latestFolder()?.lastPathComponent, "20261112090000", "Cevapsız yeni klasör atlanır")
        touch(root.appendingPathComponent("20261112090000_2/soru_1.m4a"))
        XCTAssertEqual(library.latestFolder()?.lastPathComponent, "20261112090000_2")
        touch(root.appendingPathComponent("notlar/soru_1.m4a"))
        XCTAssertEqual(library.latestFolder()?.lastPathComponent, "20261112090000_2", "Oturum klasörü olmayanlar yok sayılır")
        touch(root.appendingPathComponent("2026-11-14/soru_1.m4a"))
        XCTAssertEqual(library.latestFolder()?.lastPathComponent, "2026-11-14", "Eski gün klasörü de zamanına göre sıralanır (14 Kasım gece yarısı > 12 Kasım)")
        touch(root.appendingPathComponent("20261114000001/soru_1.m4a"))
        XCTAssertEqual(library.latestFolder()?.lastPathComponent, "20261114000001")
    }

    /// Önceki sürümün bitişik adları ("20261101100000") ile yeni adlar ("2026-11-01-100000") yan yana durabilir: ikisi de oturum klasörüdür
    func testEmptyLeftoverFoldersOfBothNameStylesAreHandled() throws {
        let root = makeTempFolder()
        let library = AnswerLibrary(root: root)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("2026-11-01-100000"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("2026-11-02-100000_2/bolum_1"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("20261103100000"), withIntermediateDirectories: true)
        touch(root.appendingPathComponent("2026-11-04-100000/soru_1.m4a"))
        touch(root.appendingPathComponent("2026-11-05-100000/bolum_2/soru_5.m4a"))
        try fm.createDirectory(at: root.appendingPathComponent("2026-11-06-1000"), withIntermediateDirectories: true)   // oturum adı değil: dokunulmaz
        let date = utc.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 8, minute: 0, second: 0))!
        _ = try library.newSessionFolder(for: date, calendar: utc)
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("2026-11-01-100000").path))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("2026-11-02-100000_2").path))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("20261103100000").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("2026-11-04-100000/soru_1.m4a").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("2026-11-05-100000/bolum_2/soru_5.m4a").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("2026-11-06-1000").path))
    }

    /// Üç ad biçimi de zamana göre doğru sıralanır: yeni "2026-11-14-120000", önceki "20261114000001", en eski gün adı "2026-11-14"
    func testLatestFolderSortsAllThreeNameStylesByTime() {
        let root = makeTempFolder()
        let library = AnswerLibrary(root: root)
        touch(root.appendingPathComponent("2026-11-14/soru_1.m4a"))
        touch(root.appendingPathComponent("20261114000001/soru_1.m4a"))
        XCTAssertEqual(library.latestFolder()?.lastPathComponent, "20261114000001")
        touch(root.appendingPathComponent("2026-11-14-120000/soru_1.m4a"))
        XCTAssertEqual(library.latestFolder()?.lastPathComponent, "2026-11-14-120000", "Yeni adlı klasör önceki adlılardan sonra gelir")
        touch(root.appendingPathComponent("2026-11-14-120000_2/soru_1.m4a"))
        XCTAssertEqual(library.latestFolder()?.lastPathComponent, "2026-11-14-120000_2")
        touch(root.appendingPathComponent("2026-11-13-235959/soru_1.m4a"))
        XCTAssertEqual(library.latestFolder()?.lastPathComponent, "2026-11-14-120000_2", "Önceki güne ait yeni adlı klasör sonrakini geçemez")
        XCTAssertEqual(AnswerLibrary.sortKey("2026-11-14-120000"), "20261114120000")
        XCTAssertEqual(AnswerLibrary.sortKey("20261114120000"), "20261114120000")
        XCTAssertEqual(AnswerLibrary.sortKey("2026-11-14"), "20261114000000")
    }

    func testAnswerFilesOfASectionedExamAreListedSectionBySection() {
        let root = makeTempFolder()
        let library = AnswerLibrary(root: root)
        let exam = root.appendingPathComponent("20261115223912", isDirectory: true)
        touch(exam.appendingPathComponent("bolum_2/soru_1.m4a"))
        touch(exam.appendingPathComponent("bolum_1/soru_10.m4a"))
        touch(exam.appendingPathComponent("bolum_1/soru_2.m4a"))
        let names = library.answerFiles(in: exam).map { "\($0.deletingLastPathComponent().lastPathComponent)/\($0.lastPathComponent)" }
        XCTAssertEqual(names, ["bolum_1/soru_2.m4a", "bolum_1/soru_10.m4a", "bolum_2/soru_1.m4a"])
        XCTAssertEqual(library.answerFiles(in: exam.appendingPathComponent("bolum_1")).count, 2, "Bölüm klasörü yalnız kendi cevaplarını verir")
        XCTAssertEqual(library.latestFolder()?.lastPathComponent, "20261115223912", "Bölümlü sınav da son kayıt sayılır")
    }

    func testLocationNamesCarryTheSection() {
        XCTAssertEqual(AnswerLibrary.locationName(exam: "20261115223912", section: 0), "20261115223912")
        XCTAssertEqual(AnswerLibrary.locationName(exam: "20261115223912", section: 3), "20261115223912@3")
        XCTAssertEqual(AnswerLibrary.splitLocation("20261115223912@3").exam, "20261115223912")
        XCTAssertEqual(AnswerLibrary.splitLocation("20261115223912@3").section, 3)
        XCTAssertEqual(AnswerLibrary.splitLocation("20261115223912").section, 0)
        XCTAssertEqual(AnswerLibrary.splitLocation("2026-11-14").exam, "2026-11-14", "Eski gün adı bozulmaz")
        XCTAssertEqual(AnswerLibrary.sectionNumber(fromFolderName: "bolum_4"), 4)
        XCTAssertNil(AnswerLibrary.sectionNumber(fromFolderName: "bolum_x"))
        XCTAssertNil(AnswerLibrary.sectionNumber(fromFolderName: "soru_4"))
    }

    func testRemoveExistingOnlyTouchesThatQuestion() {
        let root = makeTempFolder()
        let library = AnswerLibrary(root: root)
        touch(root.appendingPathComponent("soru_2.m4a"))
        touch(root.appendingPathComponent("soru_2.wav"))
        touch(root.appendingPathComponent("soru_3.m4a"))
        library.removeExisting(question: 2, in: root)
        XCTAssertEqual(library.answerFiles(in: root).map { $0.lastPathComponent }, ["soru_3.m4a"])
    }

    func testTranscriptLinesAreAppended() {
        let root = makeTempFolder()
        let library = AnswerLibrary(root: root)
        library.appendTranscript("Soru 1, Adana, A", in: root)
        library.appendTranscript("Soru 2, Bursa, B", in: root)
        let text = try? String(contentsOf: root.appendingPathComponent(AnswerLibrary.transcriptName))
        XCTAssertEqual(text, "Soru 1, Adana, A\nSoru 2, Bursa, B\n")
    }

    func testFileBaseHasNoExtension() {
        let library = AnswerLibrary(root: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(library.fileBase(question: 5, in: URL(fileURLWithPath: "/tmp/g")).path, "/tmp/g/soru_5")
    }
}

// MARK: - Soru sesi (Gemini'ye giden kayıt)

final class PCMRecorderTests: XCTestCase {
    func testWavHeaderIsValid() {
        let wav = PCMRecorder.wav(samples: [0, 1, -1, 32767], sampleRate: 16_000)
        XCTAssertEqual(wav.count, 44 + 8)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: wav[12..<16], as: UTF8.self), "fmt ")
        func u16(_ at: Int) -> UInt16 {
            return UInt16(wav[at]) | (UInt16(wav[at + 1]) << 8)
        }
        func u32(_ at: Int) -> UInt32 {
            let low = UInt32(u16(at))
            let high = UInt32(u16(at + 2))
            return low | (high << 16)
        }
        XCTAssertEqual(u32(4), 36 + 8)
        XCTAssertEqual(u16(20), 1, "PCM")
        XCTAssertEqual(u16(22), 1, "tek kanal")
        XCTAssertEqual(u32(24), 16_000)
        XCTAssertEqual(u32(28), 32_000)
        XCTAssertEqual(u16(34), 16)
        XCTAssertEqual(String(decoding: wav[36..<40], as: UTF8.self), "data")
        XCTAssertEqual(u32(40), 8)
    }

    func testRecorderAccumulatesAndResets() {
        let recorder = PCMRecorder()
        XCTAssertNil(recorder.wavData())
        recorder.append(samples: Array(repeating: 5, count: 16_000))
        XCTAssertEqual(recorder.duration, 1, accuracy: 0.001)
        XCTAssertEqual(recorder.wavData()?.count, 44 + 32_000)
        recorder.reset()
        XCTAssertNil(recorder.wavData())
        XCTAssertEqual(recorder.duration, 0)
    }

    func testRecorderKeepsOnlyTheNewestThreeMinutes() {
        let recorder = PCMRecorder()
        let chunk = [Int16](repeating: 1, count: 16_000 * 100)
        recorder.append(samples: chunk)
        recorder.append(samples: chunk)
        recorder.append(samples: [Int16](repeating: 2, count: 16_000 * 100))
        XCTAssertLessThanOrEqual(recorder.duration, PCMRecorder.maxSeconds + 10.001)
        XCTAssertGreaterThanOrEqual(recorder.duration, PCMRecorder.maxSeconds)
        // En yeni ses korunur: WAV'ın son örneği 2
        let wav = recorder.wavData()!
        XCTAssertEqual(wav[wav.count - 2], 2)
    }
}
