import XCTest
@testable import G526CameraDrive

/// Beklenmedik kapanma: günlükten anlama (ExitAnalyzer), kalıcı defter (RunJournal), açılışta oturumu sürdürme, yarım kalan işi tamamlama,
/// 3 saniyelik "Programı kapat" ve açılış döngüsü koruması.
@MainActor
final class RelaunchTests: XCTestCase {
    private typealias T = SessionViewModel.Timing
    private typealias A = ExitAnalyzer

    private func unexpected(_ cause: String = "deneme", pending: PendingWork? = nil, next: Int = 1, folder: String? = nil, down: Int? = 10) -> RunStart {
        return RunStart(exit: .unexpected(cause: cause), pending: pending, nextNumber: next, folder: folder, downSeconds: down, loop: false)
    }

    private func hasWarning(_ h: SessionHarness, _ id: String) -> Bool {
        return h.vm.warnings.contains { $0.id == id }
    }

    // MARK: Günlükten kapanmayı anlama

    func testDeliberateFlagOrLogMarkIsNeverUnexpected() {
        XCTAssertEqual(A.analyze(sessionOpen: true, deliberate: true, previous: []), .deliberate)
        XCTAssertEqual(A.analyze(sessionOpen: true, deliberate: false, previous: ["10:00:00.000 \(A.deliberateMark) (düğmeye 3 sn basıldı)"]), .deliberate,
                       "Bayrak yazılamasa bile günlükteki işaret kullanıcının kapattığını gösterir")
    }

    func testNoOpenSessionIsClean() {
        XCTAssertEqual(A.analyze(sessionOpen: false, deliberate: false, previous: ["10:00:00.000 [oturum] Dinliyorum"]), .clean)
    }

    func testOpenSessionWithoutEndMarkIsUnexpected() {
        let log = ["10:00:00.000 \(A.startedMark)", "10:00:05.000 [oturum] Dinliyorum"]
        XCTAssertEqual(A.analyze(sessionOpen: true, deliberate: false, previous: log), .unexpected(cause: A.causeUnknown))
    }

    func testLogShowingTheSessionEndedOverridesALostFlag() {
        let log = ["10:00:00.000 \(A.startedMark)", "10:30:00.000 \(A.endedMark): Test bitti"]
        XCTAssertEqual(A.analyze(sessionOpen: true, deliberate: false, previous: log), .clean)
    }

    func testRestartedSessionAfterAnEndIsUnexpectedAgain() {
        let log = ["10:00:00.000 \(A.startedMark)", "10:30:00.000 \(A.endedMark): Test bitti", "10:31:00.000 \(A.startedMark)"]
        XCTAssertEqual(A.analyze(sessionOpen: true, deliberate: false, previous: log), .unexpected(cause: A.causeUnknown))
    }

    func testCauseFromMemoryWarning() {
        XCTAssertEqual(A.cause(from: ["10:00:00.000 [sistem] iOS bellek uyarısı verdi: ..."]), A.causeMemory)
        XCTAssertEqual(A.cause(from: ["10:00:00.000 [sistem] bellek az (kalan bellek 120 MB); yük azaltılıyor"]), A.causeMemory)
    }

    func testCauseFromLowAvailableMemoryInTheLastSnapshot() {
        let low = ["10:00:00.000 [sistem] bellek kullanımı 1500 MB, kalan 120 MB; ısı normal"]
        XCTAssertEqual(A.cause(from: low), A.causeMemory)
        let fine = ["10:00:00.000 [sistem] bellek kullanımı 200 MB, kalan 1900 MB; ısı normal"]
        XCTAssertEqual(A.cause(from: fine), A.causeUnknown)
        XCTAssertEqual(A.lastAvailableMemoryMB(in: ["x [sistem] kalan 90 MB;", "y [sistem] kalan 1900 MB;"]), 1900, "Son değer alınır")
    }

    func testCauseFromThermalStateOnlyWhileItIsStillHot() {
        XCTAssertEqual(A.cause(from: ["10:00:00.000 [sistem] ısı değişti: çok sıcak"]), A.causeHot)
        XCTAssertEqual(A.cause(from: ["10:00:00.000 [sistem] ısı değişti: ısındı (yavaşlayabilir)"]), A.causeHot)
        XCTAssertEqual(A.cause(from: ["10:00:00.000 [sistem] ısı değişti: çok sıcak", "10:05:00.000 [sistem] ısı değişti: normal"]), A.causeUnknown,
                       "Isı normale dönmüşse neden o değildir")
        XCTAssertEqual(A.cause(from: ["10:00:00.000 [sistem] ısı değişti: biraz ısındı"]), A.causeUnknown, "Hafif ısınma neden sayılmaz")
    }

    func testCauseFromBackgroundAndStuck() {
        XCTAssertEqual(A.cause(from: ["10:00:00.000 [uygulama] arka plana ya da pasife geçti"]), A.causeBackground)
        XCTAssertEqual(A.cause(from: ["10:00:00.000 [uygulama] arka plana ya da pasife geçti", "10:00:30.000 [uygulama] öne geldi"]), A.causeUnknown)
        XCTAssertEqual(A.cause(from: ["10:00:00.000 [gözcü] aşama answering 660 sn boyunca değişmedi"]), A.causeStuck)
    }

    func testPreviousRunIsTheBlockAfterTheLastStartMarker() {
        let lines = ["eski satır", "\(AppLog.startMarker) 2026-01-01 ===", "a", "\(AppLog.startMarker) 2026-01-02 ===", "b", "c"]
        XCTAssertEqual(AppLog.lastRun(in: lines), ["\(AppLog.startMarker) 2026-01-02 ===", "b", "c"])
        XCTAssertEqual(AppLog.lastRun(in: ["x", "y"]), ["x", "y"], "İşaret yoksa hepsi")
    }

    func testLogIsPersistedAndThePreviousRunIsReadBack() {
        let url = makeTempFolder("g526-gunluk").appendingPathComponent("gunluk.txt")
        let first = AppLog(file: url)
        first.log("[oturum] BAŞLADI")
        first.log("[sistem] iOS bellek uyarısı verdi")
        first.flush()
        let second = AppLog(file: url)
        XCTAssertTrue(second.previousRun.contains { $0.contains("[sistem] iOS bellek uyarısı") }, "Önceki çalışmanın satırları dosyadan okunur")
        XCTAssertTrue(second.previousRun.first?.hasPrefix(AppLog.startMarker) == true)
        second.flush()
        XCTAssertEqual(A.analyze(sessionOpen: true, deliberate: false, previous: second.previousRun), .unexpected(cause: A.causeMemory))
    }

    // MARK: Kalıcı defter

    /// Sahte pano: değer ve değişim sayacı (UIPasteboard.changeCount gibi her yazışta artar)
    final class FakePasteboard {
        private(set) var value = ""
        private(set) var changeCount = 0
        func write(_ text: String) { value = text; changeCount += 1 }
        /// Kullanıcı kendi başına bir şey kopyaladı
        func userCopies(_ text: String) { write(text) }
    }

    private func makeJournal(_ defaults: UserDefaults, log: [String] = [], now: Date = Date(timeIntervalSince1970: 1_000), board: FakePasteboard = FakePasteboard()) -> RunJournal {
        let flag = ClipboardFlag(defaults: defaults, write: { board.write($0) }, changeCount: { board.changeCount })
        return RunJournal(defaults: defaults, previousLog: log, now: { now }, clipboard: flag)
    }

    private func freshDefaults() -> UserDefaults {
        return UserDefaults(suiteName: "g526.defter.\(UUID().uuidString)")!
    }

    func testFirstLaunchIsNeverUnexpected() {
        let journal = makeJournal(freshDefaults())
        XCTAssertEqual(journal.beginRun().exit, .firstRun)
    }

    func testSessionLeftOpenBecomesUnexpectedWithPendingWorkAndNumbers() {
        let defaults = freshDefaults()
        let run1 = makeJournal(defaults, now: Date(timeIntervalSince1970: 1_000))
        _ = run1.beginRun()
        run1.setSessionOpen(true)
        run1.saveNextNumber(5)
        run1.saveFolder("2026-11-14")
        run1.savePending(PendingWork(question: "Beşinci soru", english: "", spokenNumber: 5, number: nil, spoken: nil))
        run1.heartbeat()   // son nabız t=1000
        // Uygulama kapandı; 42 sn sonra yeniden açıldı
        let run2 = makeJournal(defaults, log: ["10:00:00.000 \(A.startedMark)"], now: Date(timeIntervalSince1970: 1_042))
        let start = run2.beginRun()
        XCTAssertEqual(start.exit, .unexpected(cause: A.causeUnknown))
        XCTAssertEqual(start.pending?.question, "Beşinci soru")
        XCTAssertEqual(start.nextNumber, 5)
        XCTAssertEqual(start.folder, "2026-11-14")
        XCTAssertEqual(start.downSeconds, 42)
        XCTAssertFalse(start.loop)
    }

    func testEndedSessionIsClean() {
        let defaults = freshDefaults()
        let run1 = makeJournal(defaults)
        _ = run1.beginRun()
        run1.setSessionOpen(true)
        run1.setSessionOpen(false)
        XCTAssertEqual(makeJournal(defaults).beginRun().exit, .clean)
    }

    func testDeliberateCloseIsRecognizedAndLeavesTheClosedMarkerOnTheClipboard() {
        let defaults = freshDefaults()
        let board = FakePasteboard()
        let run1 = makeJournal(defaults, board: board)
        _ = run1.beginRun()
        run1.setSessionOpen(true)
        run1.markDeliberateClose()
        XCTAssertEqual(board.value, ClipboardFlag.closed, "Kestirmeler otomasyonu bu işareti görünce uygulamayı yeniden açmaz")
        let run2 = makeJournal(defaults, board: board)
        XCTAssertEqual(run2.beginRun().exit, .deliberate)
        XCTAssertEqual(board.value, "", "Açılışta işaret silinir: bundan sonra bu düğme dışındaki her kapanma (oturum yokken de) yeniden açılır")
        run2.setSessionOpen(true)
        XCTAssertEqual(board.value, "", "Oturum başlayınca da işaret yok: o sırada gerçek bir kapanma yeniden açılabilsin")
        XCTAssertEqual(makeJournal(defaults, board: board).beginRun().exit, .unexpected(cause: A.causeUnknown),
                       "Bayrak tek seferliktir; oturum açıkken sonra kapanırsa beklenmedik sayılır")
    }

    func testClipboardNeverHoldsAMarkerWhileTheAppIsOpenWhateverTheSessionDoes() {
        let defaults = freshDefaults()
        let board = FakePasteboard()
        let journal = makeJournal(defaults, board: board)
        _ = journal.beginRun()
        XCTAssertFalse(board.value.hasPrefix(ClipboardFlag.prefix), "İlk açılışta da işaret yok: kapanma yalnız 'Programı kapat' düğmesiyle serbest")
        journal.setSessionOpen(true)
        XCTAssertEqual(board.value, "", "Oturum sürerken işaret yok: uygulama kapanırsa otomasyon yeniden açar")
        journal.setSessionOpen(false)
        XCTAssertEqual(board.value, "", "Testi Bitir'den sonra da işaret yok: uygulama başka yolla kapanırsa otomasyon yeniden açar")
    }

    func testEndingTheTestNeverMakesAClosedAppStay() {
        let defaults = freshDefaults()
        let board = FakePasteboard()
        let journal = makeJournal(defaults, board: board)
        _ = journal.beginRun()
        journal.setSessionOpen(true)
        journal.setSessionOpen(false)   // Testi Bitir
        // Uygulama kaydırılıp kapatıldı: panoda işaret yok, otomasyon açar; açılış oturum başlatmaz (test bilerek bitirilmişti)
        XCTAssertFalse(board.value.hasPrefix(ClipboardFlag.prefix))
        let reopened = makeJournal(defaults, board: board).beginRun()
        XCTAssertEqual(reopened.exit, .clean, "Test bitmişti: yeniden açılış yeni oturum başlatmaz")
        XCTAssertFalse(board.value.hasPrefix(ClipboardFlag.prefix))
    }

    func testEndingTheTestWhileClosingOnPurposeKeepsTheClosedMarker() {
        // Programı kapat: önce işaret yazılır, sonra çalışan oturum bitirilir; oturumun bitişi işareti silmemeli
        let defaults = freshDefaults()
        let board = FakePasteboard()
        let journal = makeJournal(defaults, board: board)
        _ = journal.beginRun()
        journal.setSessionOpen(true)
        journal.markDeliberateClose()
        journal.setSessionOpen(false)
        XCTAssertEqual(board.value, ClipboardFlag.closed, "Düğmeyle kapatırken oturumun bitmesi işareti silmez")
        journal.setAway(false)
        XCTAssertEqual(board.value, ClipboardFlag.closed, "Çıkarken başka bir çağrı da işareti silmez")
    }

    func testSessionEndingWhileAwayForShortcutsKeepsTheRepairMarkerUntilReturn() {
        let defaults = freshDefaults()
        let board = FakePasteboard()
        let journal = makeJournal(defaults, board: board)
        _ = journal.beginRun()
        journal.setSessionOpen(true)
        journal.setAway(true)
        journal.setSessionOpen(false)   // onarım sürerken oturum bitti
        XCTAssertEqual(board.value, ClipboardFlag.repair, "Kestirmeler'deyken otomasyon uygulamayı geri çekmemeli")
        journal.setAway(false)
        XCTAssertEqual(board.value, "", "Dönünce işaret silinir: bu düğme dışındaki her çıkış yeniden açılır")
    }

    func testLaunchClearsAnOldClosedMarkerButNeverTouchesTheUsersOwnClipboard() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: "journal.hasRun")
        let board = FakePasteboard()
        // Eski sürümün ya da "Programı kapat"ın bıraktığı işaret
        ClipboardFlag(defaults: defaults, write: { board.write($0) }, changeCount: { board.changeCount }).set(ClipboardFlag.closed)
        _ = makeJournal(defaults, board: board).beginRun()
        XCTAssertEqual(board.value, "", "Açılışta eski işaret silinir")
        board.userCopies("Kopyalanan API anahtarı")
        _ = makeJournal(defaults, board: board).beginRun()
        XCTAssertEqual(board.value, "Kopyalanan API anahtarı", "Sonraki açılışlar kullanıcının panosunu ezmez")
    }

    func testFirstLaunchAfterAnUnexpectedCloseDoesNotLeaveAMarker() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: "journal.hasRun")
        defaults.set(true, forKey: "journal.sessionOpen")   // eski sürüm oturum sürerken kapanmıştı
        let board = FakePasteboard()
        let start = makeJournal(defaults, log: ["10:00:00.000 \(A.startedMark)"], board: board).beginRun()
        XCTAssertEqual(start.exit, .unexpected(cause: A.causeUnknown))
        XCTAssertEqual(board.value, "", "Oturum yeniden başlayacak: işaret yazılmaz")
    }

    func testCrashLeavesTheClipboardWithoutAMarkerSoTheAutomationReopens() {
        let defaults = freshDefaults()
        let board = FakePasteboard()
        let run1 = makeJournal(defaults, board: board)
        _ = run1.beginRun()
        run1.setSessionOpen(true)
        // çöktü: hiçbir şey yazılmadı
        XCTAssertEqual(board.value, "")
        let run2 = makeJournal(defaults, log: ["10:00:00.000 \(A.startedMark)"], board: board)
        XCTAssertEqual(run2.beginRun().exit, .unexpected(cause: A.causeUnknown))
        XCTAssertEqual(board.value, "", "Açılışta işaret yazılmaz; kendiliğinden başlayan oturum da zaten işareti temizler")
    }

    func testUserCopiedTextIsNeverWiped() {
        let defaults = freshDefaults()
        let board = FakePasteboard()
        let journal = makeJournal(defaults, board: board)
        _ = journal.beginRun()
        journal.setAway(true)
        XCTAssertEqual(board.value, ClipboardFlag.repair)
        board.userCopies("Kullanıcının kopyaladığı metin")
        journal.setAway(false)
        XCTAssertEqual(board.value, "Kullanıcının kopyaladığı metin", "Pano arada değiştiyse işaret bizim değildir, dokunulmaz")
        journal.setSessionOpen(true)
        XCTAssertEqual(board.value, "Kullanıcının kopyaladığı metin")
        journal.setAway(true)
        XCTAssertEqual(board.value, ClipboardFlag.repair)
        journal.setAway(false)
        XCTAssertEqual(board.value, "")
        board.userCopies("Başka bir metin")
        journal.setAway(false)
        XCTAssertEqual(board.value, "Başka bir metin")
    }

    func testRepairMarkerIsWrittenWhileTheAppLeavesForShortcutsAndRemovedOnReturn() {
        let defaults = freshDefaults()
        let board = FakePasteboard()
        let journal = makeJournal(defaults, board: board)
        _ = journal.beginRun()
        journal.setSessionOpen(true)
        journal.setAway(true)
        XCTAssertTrue(board.value.hasPrefix(ClipboardFlag.prefix), "Onarım kestirmesi için Kestirmeler'e geçerken otomasyon uygulamayı geri çekmemeli")
        XCTAssertEqual(board.value, ClipboardFlag.repair)
        journal.setAway(false)
        XCTAssertEqual(board.value, "", "Dönünce oturum sürüyor: işaret silinir")
    }

    func testReturningFromShortcutsAfterTheSessionEndedLeavesNoMarker() {
        let defaults = freshDefaults()
        let board = FakePasteboard()
        let journal = makeJournal(defaults, board: board)
        _ = journal.beginRun()
        journal.setSessionOpen(true)
        journal.setAway(true)
        journal.setSessionOpen(false)   // onarım sürerken oturum bitti
        journal.setAway(false)
        XCTAssertEqual(board.value, "", "Test bitmiş olsa da bu düğme dışındaki çıkış yeniden açılır")
    }

    func testRepeatedUnexpectedCloseWithinTheWindowIsALoop() {
        let defaults = freshDefaults()
        let first = makeJournal(defaults, now: Date(timeIntervalSince1970: 1_000))
        _ = first.beginRun()
        var loops: [Bool] = []
        for step in 1...T.loopLimit {
            let run = makeJournal(defaults, now: Date(timeIntervalSince1970: 1_000 + Double(step) * 20))
            run.setSessionOpen(true)   // oturum açılıp kapanıyor (çöküyor)
            let next = makeJournal(defaults, now: Date(timeIntervalSince1970: 1_000 + Double(step) * 20 + 5))
            loops.append(next.beginRun().loop)
        }
        XCTAssertEqual(loops, [false, false, true], "Üçüncü art arda kapanmada otomatik başlatma durdurulur")
    }

    func testSpacedOutUnexpectedClosesAreNotALoop() {
        let defaults = freshDefaults()
        _ = makeJournal(defaults).beginRun()
        for step in 1...5 {
            makeJournal(defaults).setSessionOpen(true)
            let later = makeJournal(defaults, now: Date(timeIntervalSince1970: 1_000 + Double(step) * (T.loopWindow + 60)))
            XCTAssertFalse(later.beginRun().loop, "Arası açık kapanmalar döngü sayılmaz (\(step))")
        }
    }

    // MARK: Açılışta oturumu sürdürme

    func testUnexpectedCloseRestartsTheSessionAndSaysWhatHappened() async {
        let h = SessionHarness()
        h.journal.start = unexpected(A.causeMemory, next: 4, down: 12)
        h.vm.launched()
        let listening = await waitUntil { h.vm.phase == .listening }
        XCTAssertTrue(listening, "Kullanıcı telefona dokunamaz: oturum kendiliğinden yeniden başlar")
        let said = h.speaker.calls.map { $0.text }
        XCTAssertTrue(said.contains { $0.contains("beklenmedik biçimde kapanıp yeniden açıldı") && $0.contains("12 saniye") && $0.contains("belleği") },
                      "Ne olduğu ve olası neden söylenir: \(said)")
        XCTAssertTrue(said.contains { $0.contains("soruyu baştan okuyun") }, "Yarım kalan iş yoksa son soruyu baştan okuması istenir")
        XCTAssertFalse(said.contains(Say.ready), "Olağan 'Ben hazırım' yerine bu anons söylenir")
        XCTAssertEqual(h.vm.nextNumber, 4, "Soru numarası kaldığı yerden sürer, soru_N ezilmez")
        XCTAssertNil(h.vm.resume, "Anons söylenince sürdürme bilgisi tüketilir")
    }

    func testLaunchHandlingRunsOnlyOnce() async {
        let h = SessionHarness()
        h.journal.start = unexpected()
        h.vm.launched()
        h.vm.launched()
        XCTAssertEqual(h.journal.beginCalls, 1)
        _ = await waitUntil { h.vm.phase == .listening }
    }

    func testCleanDeliberateAndFirstLaunchesStartNothing() async {
        for exit in [PreviousExit.clean, .deliberate, .firstRun] {
            let h = SessionHarness()
            h.journal.start = RunStart(exit: exit, pending: nil, nextNumber: 1, folder: nil, downSeconds: nil, loop: false)
            h.vm.launched()
            await settle()
            XCTAssertEqual(h.vm.phase, .idle, "\(exit): oturum kendiliğinden başlamaz")
            XCTAssertTrue(h.speaker.calls.isEmpty)
        }
    }

    func testStartupLoopStopsAutoStart() async {
        let h = SessionHarness()
        var run = unexpected()
        run.loop = true
        h.journal.start = run
        h.vm.launched()
        await settle()
        XCTAssertEqual(h.vm.phase, .idle, "Açılış döngüsüne girilmez")
        XCTAssertTrue(hasWarning(h, "kapanma"))
        XCTAssertFalse(h.journal.sessionOpen, "Bayrak silinir: bir sonraki açılış yine otomatik başlamasın")
    }

    // MARK: Yarım kalan işi tamamlama

    func testQuestionSentBeforeTheCloseIsAskedAgainAndAnswered() async {
        let h = SessionHarness()
        h.answering.results = [.success(FakeAnswering.reply(4, option: "Ankara", text: "Başkent"))]
        let pending = PendingWork(question: "Dördüncü soru Türkiye'nin başkenti neresidir", english: "", spokenNumber: 4, number: nil, spoken: nil)
        h.journal.start = unexpected(pending: pending, next: 4)
        h.vm.launched()
        let done = await waitUntil { h.vm.phase == .listening && h.answering.calls.count == 1 && h.vm.answers.count == 1 }
        XCTAssertTrue(done, "Yarım kalan soru yeniden sorulur, cevap okunur ve dinlemeye dönülür")
        XCTAssertEqual(h.answering.calls.first?.question, pending.question)
        XCTAssertNil(h.answering.calls.first?.audio, "Ses kaydı kapanmayla kaybolduğu için yalnız metin gider")
        XCTAssertEqual(h.answering.calls.first?.expectedNumber, 4)
        let said = h.speaker.calls.map { $0.text }
        XCTAssertTrue(said.contains { $0.contains("Gemini'ye gitmişti") })
        XCTAssertTrue(said.contains("Soru 4, Ankara, Başkent"))
        XCTAssertNil(h.journal.pending, "Cevap duyulunca yarım iş kalmaz")
    }

    func testAnswerReceivedBeforeTheCloseIsReadAgainWithoutAskingGemini() async {
        let h = SessionHarness()
        let pending = PendingWork(question: "Soru", english: "", spokenNumber: 2, number: 2, spoken: "Soru 2, Bursa, Yönetim")
        h.journal.start = unexpected(pending: pending, next: 3)
        h.vm.launched()
        let done = await waitUntil { h.vm.phase == .listening && h.speaker.calls.contains { $0.text == "Soru 2, Bursa, Yönetim" } }
        XCTAssertTrue(done)
        XCTAssertTrue(h.answering.calls.isEmpty, "Cevap zaten alınmıştı: Gemini'ye yeniden sorulmaz")
        XCTAssertTrue(h.speaker.calls.contains { $0.text.contains("cevabını yeniden okuyorum") })
        XCTAssertNil(h.journal.pending)
    }

    func testStartingAfterACloseContinuesInTheSameFolderAndNumbering() async {
        let h = SessionHarness()
        let name = AnswerLibrary.folderName(for: Date(timeIntervalSince1970: 1_800_000_000))
        let folder = h.root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: folder.appendingPathComponent("soru_6.m4a").path, contents: Data([1]))
        h.journal.start = unexpected(next: 2, folder: name)
        h.vm.launched()
        _ = await waitUntil { h.vm.phase == .listening }
        XCTAssertEqual(h.vm.sessionFolder?.lastPathComponent, name, "Cevaplar ikiye bölünmesin: aynı klasöre devam edilir")
        XCTAssertEqual(h.vm.nextNumber, 7, "Klasörde soru_6 varsa sıradaki numara 7'dir (defterdeki 2 değil)")
    }

    func testPendingWorkIsJournaledWhileGeminiThinksAndClearedWhenHeard() async {
        let h = SessionHarness()
        h.answering.results = [.success(FakeAnswering.reply(1))]
        _ = await h.startListening()
        h.answering.hold = true
        h.ask("Birinci soru")
        let waiting = await waitUntil { h.answering.calls.count == 1 }
        XCTAssertTrue(waiting)
        XCTAssertEqual(h.journal.pending?.question, "Birinci soru", "Gemini beklenirken soru yarım iş olarak deftere yazılır")
        XCTAssertNil(h.journal.pending?.spoken)
        h.answering.release()
        let done = await waitUntil { h.vm.phase == .listening && h.journal.pending == nil }
        XCTAssertTrue(done, "Cevap duyulup dinlemeye dönülünce yarım iş silinir")
        XCTAssertEqual(h.journal.nextNumber, 2, "Sıradaki numara deftere işlenir")
    }

    func testAnswerStoredButNotYetHeardIsJournaledWithItsSpokenLine() async {
        let h = SessionHarness()
        h.answering.results = [.success(FakeAnswering.reply(3, option: "Denizli", text: "Örgütsel Davranış"))]
        _ = await h.startListening()
        h.speaker.hold = true
        h.ask("Üçüncü soru")
        let speaking = await waitUntil { h.vm.phase == .speaking && h.journal.pending?.spoken != nil }
        XCTAssertTrue(speaking)
        XCTAssertEqual(h.journal.pending?.spoken, "Soru 3, Denizli, Örgütsel Davranış")
        XCTAssertEqual(h.journal.pending?.number, 3)
        h.speaker.hold = false
        h.speaker.release()
        _ = await waitUntil { h.vm.phase == .listening }
        XCTAssertNil(h.journal.pending)
    }

    func testFailedQuestionLeavesNoPendingWork() async {
        let h = SessionHarness()
        h.answering.results = [.failure(GeminiError("Anahtar geçersiz.", .error))]
        _ = await h.startListening()
        h.ask("Soru")
        let done = await waitUntil { h.vm.phase == .listening }
        XCTAssertTrue(done)
        XCTAssertNil(h.journal.pending, "Kullanıcıdan soruyu yeniden okuması istendi; yarım iş yok")
    }

    // MARK: Oturum bayrağı

    func testSessionOpenFlagFollowsTheSessionButNotTheReplay() async {
        let h = SessionHarness()
        XCTAssertFalse(h.journal.sessionOpen)
        _ = await h.startListening()
        XCTAssertTrue(h.journal.sessionOpen)
        h.vm.endTest()
        XCTAssertFalse(h.journal.sessionOpen, "Test bitince bayrak silinir: sonraki açılış beklenmedik sayılmaz")
        XCTAssertFalse(SessionViewModel.countsAsSession(.replaying), "Tekrar bir oturum değildir")
        XCTAssertTrue(SessionViewModel.countsAsSession(.listening))
        XCTAssertTrue(SessionViewModel.countsAsSession(.paused(.manual)))
        XCTAssertFalse(SessionViewModel.countsAsSession(.finished))
    }

    func testStartupFailureClearsTheFlag() async {
        let h = SessionHarness()
        h.permissions.result = PermissionResult(microphone: false, speech: false, onDeviceSpeech: false, englishOnDevice: false)
        h.vm.start()
        let idle = await waitUntil { h.vm.phase == .idle }
        XCTAssertTrue(idle)
        XCTAssertFalse(h.journal.sessionOpen, "Kalıcı eksikle durmuş oturum yeniden açılışta kendiliğinden başlamaz")
    }

    func testAutoResumedSessionThatNeverGetsGoingLeavesNoStaleResumeBehind() async {
        let h = SessionHarness()
        let pending = PendingWork(question: "Yarım kalan soru", english: "", spokenNumber: 4, number: nil, spoken: nil)
        h.journal.savePending(pending)
        h.journal.start = unexpected(pending: pending, next: 4)
        let good = h.permissions.result
        h.permissions.result = PermissionResult(microphone: false, speech: false, onDeviceSpeech: false, englishOnDevice: false)
        h.vm.launched()
        let closed = await waitUntil { h.journal.openHistory == [true, false] }
        XCTAssertTrue(closed, "Başlatma kalıcı bir eksikle durdu: oturum kapandı")
        XCTAssertNil(h.vm.resume, "Kapanan oturum eski kapanmanın devamı sayılmaz")
        XCTAssertNil(h.journal.pending, "Eski yarım iş de silinir: sonraki başlatmada yeniden sorulmaz")
        // Eksik giderilip elle başlatılınca olağan açılış anonsu söylenir, 'yeniden açıldı' denmez
        h.permissions.result = good
        h.vm.start()
        let listening = await waitUntil { h.vm.phase == .listening }
        XCTAssertTrue(listening)
        let said = h.speaker.calls.map { $0.text }
        XCTAssertFalse(said.contains { $0.contains("beklenmedik biçimde kapanıp") }, "Eski kapanma bir daha anlatılmaz: \(said)")
        XCTAssertTrue(h.answering.calls.isEmpty, "Eski yarım soru Gemini'ye yeniden gitmez")
    }

    // MARK: Programı kapat

    func testCloseButtonEndsTheSessionMarksItDeliberateAndExits() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.vm.closeByUser()
        XCTAssertTrue(h.journal.deliberate, "Kullanıcı kapattı işareti")
        XCTAssertFalse(h.journal.sessionOpen)
        XCTAssertNil(h.journal.pending)
        XCTAssertEqual(h.vm.phase, .finished)
        let exited = await waitUntil { h.exits.count == 1 }
        XCTAssertTrue(exited, "Program gerçekten çıkışı ister")
    }

    func testCloseButtonAlsoWorksWhenNothingIsRunning() async {
        let h = SessionHarness()
        h.vm.closeByUser()
        let exited = await waitUntil { h.exits.count == 1 }
        XCTAssertTrue(exited)
        XCTAssertTrue(h.journal.deliberate)
        XCTAssertEqual(h.vm.phase, .idle)
    }

    func testHoldSecondsIsThree() {
        XCTAssertEqual(T.closeHold, 3, "Kapatmak için 3 saniye basılı tutulur")
    }

    func testReopenURLDoesNotRestartARunningSession() async {
        let h = SessionHarness()
        _ = await h.startListening()
        let starts = h.listener.startCalls
        h.vm.handleURL(URL(string: "seslikontrol://yeniden")!)
        await settle()
        XCTAssertEqual(h.vm.phase, .listening)
        XCTAssertEqual(h.listener.startCalls, starts, "Açık oturuma dokunulmaz")
        XCTAssertTrue(ShortcutLink.isReopenURL(URL(string: "seslikontrol://yeniden")!))
        XCTAssertFalse(ShortcutLink.isStartURL(URL(string: "seslikontrol://yeniden")!))
    }
}
