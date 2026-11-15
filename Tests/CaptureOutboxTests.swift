import XCTest
import UIKit
@testable import G526CameraDrive

/// Çekimlerin telefondaki KALICI klasörü: çekim gönderilmeden önce klasöre yazılır, internet gelene kadar (uygulama kapansa da) kaybolmaz,
/// gelince en eskisinden başlayarak sırayla gönderilir ve gönderildikten sonra da kullanıcı silene kadar silinmez.
@MainActor
final class CaptureStoreTests: XCTestCase {
    private var root: URL!
    private var store: FileCaptureStore!
    private let fm = FileManager.default

    override func setUp() {
        super.setUp()
        root = makeTempFolder("g526-cekim").appendingPathComponent("Cekimler", isDirectory: true)
        store = FileCaptureStore(root: root)
        store.prepare()
    }

    private func shot(at seconds: TimeInterval = 1_800_000_000, instruction: String = "") -> CapturedQuestion {
        var s = FakeCamera.shot()
        s.date = Date(timeIntervalSince1970: seconds)
        s.extraInstruction = instruction
        return s
    }

    private func folders(_ bucket: FileCaptureStore.Bucket) -> [String] {
        return ((try? fm.contentsOfDirectory(atPath: store.url(of: bucket).path)) ?? []).sorted()
    }

    func testPrepareCreatesTheFoldersSoTheyShowInTheFilesApp() {
        for bucket in FileCaptureStore.Bucket.allCases {
            var isDir: ObjCBool = false
            XCTAssertTrue(fm.fileExists(atPath: store.url(of: bucket).path, isDirectory: &isDir))
            XCTAssertTrue(isDir.boolValue)
        }
        XCTAssertEqual(FileCaptureStore.Bucket.pending.rawValue, "Bekleyen")
        XCTAssertEqual(FileCaptureStore.rootName, "Cekimler")
    }

    func testKeepWritesPhotoVideoAndInfoAndMovesTheVideo() throws {
        let original = shot(instruction: "Şıkları sırayla oku")
        let originalVideo = original.video!
        let stored = store.keep(original, kind: .question)
        XCTAssertTrue(stored.archived)
        XCTAssertNotEqual(stored.video, originalVideo, "Video kalıcı klasöre taşınır")
        XCTAssertFalse(fm.fileExists(atPath: originalVideo.path), "Geçici yerde kalmaz")
        XCTAssertTrue(fm.fileExists(atPath: stored.video!.path))
        let name = try XCTUnwrap(folders(.pending).first)
        let dir = store.url(of: .pending).appendingPathComponent(name)
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("foto.jpg").path))
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("video.mp4").path))
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("bilgi.json").path))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("foto.jpg")), original.photo)
        XCTAssertTrue(name.hasPrefix("20270115-"), "Klasör adı çekim tarihiyle başlar: \(name)")
        XCTAssertEqual(store.summary().pending, 1)
    }

    func testPendingShotsSurviveARestartAndComeBackOldestFirst() {
        let late = store.keep(shot(at: 1_800_000_300, instruction: "geç"), kind: .question)
        let early = store.keep(shot(at: 1_800_000_100, instruction: "erken"), kind: .question)
        let middle = store.keep(shot(at: 1_800_000_200, instruction: "orta"), kind: .question)
        // Uygulama kapanıp açıldı: aynı klasörden yeni bir bileşen
        let reopened = FileCaptureStore(root: root)
        let restored = reopened.restorePending()
        XCTAssertEqual(restored.map { $0.id }, [early.id, middle.id, late.id], "En eskisi önce")
        XCTAssertEqual(restored.map { $0.extraInstruction }, ["erken", "orta", "geç"])
        XCTAssertTrue(restored.allSatisfy { $0.archived })
        XCTAssertEqual(restored[0].photo, early.photo)
        XCTAssertEqual(restored[0].videoBytes, 1, "Video dosyasının gerçek boyutu okunur")
        XCTAssertTrue(fm.fileExists(atPath: restored[0].video!.path))
        XCTAssertEqual(restored[0].date, early.date)
        XCTAssertEqual(restored[0].highResolution, early.highResolution)
    }

    func testSentShotMovesToTheSentFolderWithItsAnswerAndIsNotDeleted() throws {
        let stored = store.keep(shot(), kind: .question)
        store.markSent(stored, answer: "Soru 3, Bursa, Yönetim")
        XCTAssertTrue(folders(.pending).isEmpty)
        let name = try XCTUnwrap(folders(.sent).first)
        let dir = store.url(of: .sent).appendingPathComponent(name)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("cevap.txt"), encoding: .utf8), "Soru 3, Bursa, Yönetim")
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("foto.jpg").path), "Gönderilen çekim silinmez")
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("video.mp4").path))
        XCTAssertTrue(FileCaptureStore(root: root).restorePending().isEmpty, "Gönderilen çekim yeniden gönderilmez")
        let summary = store.summary()
        XCTAssertEqual(summary.sent, 1)
        XCTAssertEqual(summary.pending, 0)
    }

    func testUnsendableShotMovesToItsOwnFolderWithTheReasonAndIsNotDeleted() throws {
        let stored = store.keep(shot(), kind: .question)
        store.markUnsendable(stored, reason: "Gemini bu içeriği reddetti")
        let name = try XCTUnwrap(folders(.unsendable).first)
        let dir = store.url(of: .unsendable).appendingPathComponent(name)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("neden.txt"), encoding: .utf8), "Gemini bu içeriği reddetti")
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("foto.jpg").path))
        XCTAssertEqual(store.summary().unsendable, 1)
        XCTAssertTrue(store.restorePending().isEmpty)
    }

    func testShotWithAnUnreadablePhotoIsNotLostOnRestore() throws {
        _ = store.keep(shot(), kind: .question)
        let name = try XCTUnwrap(folders(.pending).first)
        try fm.removeItem(at: store.url(of: .pending).appendingPathComponent(name).appendingPathComponent("foto.jpg"))
        XCTAssertTrue(FileCaptureStore(root: root).restorePending().isEmpty)
        XCTAssertEqual(folders(.unsendable).count, 1, "Silinmez: kullanıcı görsün diye Gönderilemeyen'e alınır")
    }

    func testPassageShotsGoToTheirOwnFolderAndAreNeverPending() {
        let stored = store.keep(shot(), kind: .passage)
        XCTAssertEqual(folders(.passage).count, 1)
        XCTAssertTrue(folders(.pending).isEmpty)
        XCTAssertTrue(FileCaptureStore(root: root).restorePending().isEmpty)
        XCTAssertEqual(store.summary().passages, 1)
        XCTAssertTrue(stored.archived)
    }

    func testDeleteSentRemovesSentAndPassageButKeepsPendingAndUnsendable() {
        let pending = store.keep(shot(at: 1_800_000_001), kind: .question)
        let sent = store.keep(shot(at: 1_800_000_002), kind: .question)
        let bad = store.keep(shot(at: 1_800_000_003), kind: .question)
        _ = store.keep(shot(at: 1_800_000_004), kind: .passage)
        store.markSent(sent, answer: "a")
        store.markUnsendable(bad, reason: "r")
        XCTAssertEqual(store.deleteSent(), 2)
        XCTAssertEqual(store.summary().pending, 1)
        XCTAssertEqual(store.summary().unsendable, 1)
        XCTAssertEqual(store.summary().sent, 0)
        XCTAssertEqual(store.summary().passages, 0)
        XCTAssertEqual(store.restorePending().map { $0.id }, [pending.id], "Bekleyen çekime dokunulmaz")
    }

    func testDeleteAllRemovesEverythingIncludingPending() {
        _ = store.keep(shot(at: 1_800_000_001), kind: .question)
        let sent = store.keep(shot(at: 1_800_000_002), kind: .question)
        store.markSent(sent, answer: "a")
        _ = store.keep(shot(at: 1_800_000_003), kind: .passage)
        XCTAssertEqual(store.deleteAll(), 3)
        XCTAssertEqual(store.summary(), CaptureFolderSummary())
        XCTAssertTrue(store.restorePending().isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: store.url(of: .pending).path), "Klasörlerin kendisi kalır")
    }

    func testArchivedShotsVideoIsNotDeletedByDiscardButATemporaryOneIs() {
        let stored = store.keep(shot(), kind: .question)
        stored.discard()
        XCTAssertTrue(fm.fileExists(atPath: stored.video!.path), "Kalıcı klasördeki video kendiliğinden silinmez")
        let temporary = shot()
        temporary.discard()
        XCTAssertFalse(fm.fileExists(atPath: temporary.video!.path), "Geçici video silinir")
    }

    func testAShotThatCannotBeWrittenStaysInMemoryAndKeepsItsVideo() throws {
        // Kök, düz bir dosyanın altında: klasör açılamaz
        let blocker = makeTempFolder("g526-engel").appendingPathComponent("dosya")
        try Data([1]).write(to: blocker)
        let broken = FileCaptureStore(root: blocker.appendingPathComponent("Cekimler"))
        let original = shot()
        let result = broken.keep(original, kind: .question)
        XCTAssertFalse(result.archived)
        XCTAssertEqual(result.video, original.video, "Yazılamayan çekimin videosu yerinde kalır")
        XCTAssertTrue(fm.fileExists(atPath: original.video!.path))
    }

    func testSummaryReportsCountsAndSize() {
        var big = shot()
        big.photo = Data(count: 2_500_000)
        _ = store.keep(big, kind: .question)
        let summary = store.summary()
        XCTAssertEqual(summary.total, 1)
        XCTAssertGreaterThan(summary.bytes, 2_500_000)
        XCTAssertEqual(summary.sizeText, "2 MB")
        XCTAssertTrue(summary.text.contains("Bekleyen 1"))
        XCTAssertEqual(CaptureFolderSummary(bytes: 500_000).sizeText, "500 KB")
    }

    func testTwoShotsInTheSameSecondDoNotCollide() {
        let a = store.keep(shot(at: 1_800_000_000), kind: .question)
        let b = store.keep(shot(at: 1_800_000_000), kind: .question)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(folders(.pending).count, 2)
        XCTAssertEqual(store.restorePending().count, 2)
    }

    func testNoCaptureStoreKeepsNothingAndReturnsTheShotAsIs() {
        let none = NoCaptureStore()
        let original = shot()
        let result = none.keep(original, kind: .question)
        XCTAssertFalse(result.archived)
        XCTAssertEqual(result.video, original.video)
        XCTAssertTrue(none.restorePending().isEmpty)
        XCTAssertEqual(none.summary(), CaptureFolderSummary())
        XCTAssertEqual(none.deleteAll(), 0)
    }
}

/// Çekim klasörünün oturumla birlikte çalışması: kayıp yok, sınır yok, sırayla gönderim, test bitince ve yeniden açılışta kalıcılık
@MainActor
final class CaptureOutboxFlowTests: XCTestCase {
    typealias T = SessionViewModel.Timing

    private func harness(shots: [Result<CapturedQuestion, CameraFailure>]? = nil,
                         replies: [Result<GeminiReply, Error>]? = nil,
                         cameraFlow: Bool = true) -> SessionHarness {
        let h = SessionHarness(cameraFlow: cameraFlow, archive: true)
        h.camera.results = shots ?? [.success(FakeCamera.shot())]
        h.answering.results = replies ?? [.success(FakeAnswering.reply(1))]
        h.trackEvents { name in
            if name == "Kameraya_Gec" { h.health.internet = false }
            if name == "Hücresele_Gec" { h.health.internet = true }
            if name == "Hücresel_Ac" { h.health.internet = true }
        }
        return h
    }

    private func reply(_ h: SessionHarness, _ text: String) {
        h.listener.say(text)
        h.scheduler.advance(by: T.numberConfirm + 0.1)
    }

    private func stored(_ h: SessionHarness, at seconds: TimeInterval, instruction: String = "") -> CapturedQuestion {
        var s = FakeCamera.shot()
        s.date = Date(timeIntervalSince1970: seconds)
        s.extraInstruction = instruction
        return h.fileStore!.keep(s, kind: .question)
    }

    func testACapturedQuestionIsWrittenToTheFolderBeforeItIsSentAndStaysThereAfterwards() async {
        let h = harness()
        var duringSend: CaptureFolderSummary?
        h.answering.onCall = { _ in duringSend = h.fileStore?.summary() }
        _ = await h.startListening()
        reply(h, "evet")
        let done = await waitUntil(45) { h.vm.answers.count == 1 }
        XCTAssertTrue(done)
        XCTAssertEqual(duringSend?.pending, 1, "Gönderim sürerken çekim telefondaki klasörde (Bekleyen) durur")
        let summary = h.fileStore!.summary()
        XCTAssertEqual(summary.pending, 0)
        XCTAssertEqual(summary.sent, 1, "Gönderilen çekim silinmez: Gönderilen klasörüne taşınır")
        XCTAssertTrue(h.vm.pendingShots.isEmpty)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: h.fileStore!.url(of: .sent).path)) ?? []
        let dir = h.fileStore!.url(of: .sent).appendingPathComponent(names.first ?? "yok")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("video.mp4").path), "Video da silinmez")
        let answer = try? String(contentsOf: dir.appendingPathComponent("cevap.txt"), encoding: .utf8)
        XCTAssertEqual(answer, "Soru 1, Denizli, Örgütsel Davranış", "Cevap yanına yazılır")
    }

    func testBlockedShotMovesToTheUnsendableFolderInsteadOfBeingDeleted() async {
        let h = harness(replies: [.failure(GeminiError("engellendi", .blocked))])
        _ = await h.startListening()
        reply(h, "evet")
        let failed = await waitUntil(45) { h.vm.warnings.contains { $0.id == "cevap" } }
        XCTAssertTrue(failed)
        await settle()
        XCTAssertTrue(h.vm.pendingShots.isEmpty)
        XCTAssertEqual(h.fileStore?.summary().unsendable, 1)
        XCTAssertEqual(h.fileStore?.summary().pending, 0)
    }

    func testThereIsNoLimitOnTheNumberOfPendingShots() async {
        let h = harness()
        _ = await h.startListening()
        var all: [CapturedQuestion] = []
        for n in 0..<8 {
            let one = stored(h, at: 1_800_000_000 + TimeInterval(n))
            all.append(one)
            h.vm.keepPending(one)
        }
        XCTAssertEqual(h.vm.pendingShots.count, 8, "Sayı sınırı yok: hiçbir çekim yenisine yer açmak için silinmez")
        XCTAssertTrue(all.allSatisfy { FileManager.default.fileExists(atPath: $0.video!.path) })
        XCTAssertEqual(h.fileStore?.summary().pending, 8)
    }

    func testPendingShotsFromAnEarlierRunAreRestoredAtStartAndSentOldestFirst() async {
        let h = harness(shots: [], replies: [.success(FakeAnswering.reply(1)), .success(FakeAnswering.reply(2)), .success(FakeAnswering.reply(3))])
        // Önceki çalışmadan kalanlar (kaydedilme sırası karışık)
        let c = stored(h, at: 1_800_000_300, instruction: "üçüncü")
        let a = stored(h, at: 1_800_000_100, instruction: "birinci")
        let b = stored(h, at: 1_800_000_200, instruction: "ikinci")
        h.vm.start()
        let sent = await waitUntil(60) { h.vm.answers.count == 3 }
        XCTAssertTrue(sent, "Üç bekleyen çekimin üçü de gönderilir")
        XCTAssertEqual(h.answering.captureCalls.map { $0.shot.id }, [a.id, b.id, c.id], "En eskisinden başlayarak sırayla")
        let summary = h.fileStore!.summary()
        XCTAssertEqual(summary.pending, 0)
        XCTAssertEqual(summary.sent, 3, "Hiçbiri kaybolmaz, hiçbiri silinmez")
    }

    func testPendingShotsAreSentEvenWhenTheCameraQuestionIsOff() async {
        let h = harness(shots: [], replies: [.success(FakeAnswering.reply(1))], cameraFlow: false)
        _ = stored(h, at: 1_800_000_100)
        XCTAssertFalse(h.vm.cameraOfferAvailable, "Kamera sorusu kapalı")
        h.vm.start()
        let sent = await waitUntil(60) { h.vm.answers.count == 1 }
        XCTAssertTrue(sent, "Bekleyen çekim kamera sorusu olmasa da gönderilir")
        XCTAssertEqual(h.fileStore?.summary().sent, 1)
        XCTAssertEqual(h.fileStore?.summary().pending, 0)
        let listening = await waitUntil(45) { h.vm.phase == .listening && h.vm.listenMode == .question }
        XCTAssertTrue(listening, "Gönderimden sonra soru beklenir")
    }

    func testWithoutInternetPendingShotsStayAndTheTestGoesOnListening() async {
        let h = harness(shots: [], replies: [], cameraFlow: false)
        _ = stored(h, at: 1_800_000_100)
        // Açılış denetimi geçer; bekleyen çekim gönderilmek istenirken internet yoktur
        h.speaker.holdWhen = { text in
            if text == Say.cameraPendingSending { h.health.internet = false }
            return false
        }
        h.vm.start()
        let listening = await waitUntil(60) { h.vm.phase == .listening && h.vm.listenMode == .question }
        XCTAssertTrue(listening, "İnternet yokken bekleyen çekim yüzünden oturum takılmaz")
        XCTAssertEqual(h.vm.pendingShots.count, 1)
        XCTAssertEqual(h.fileStore?.summary().pending, 1, "Çekim klasörde durur")
        XCTAssertTrue(h.answering.captureCalls.isEmpty)
        XCTAssertTrue(h.vm.warnings.contains { $0.id == "kamera" }, "Kullanıcıya söylenir")
    }

    func testShotsLeftAfterTheTestEndedSurviveAndAreRestoredByTheNextRun() async {
        let h = harness(shots: [], replies: [])
        _ = await h.startListening()
        let a = stored(h, at: 1_800_000_100)
        h.vm.keepPending(a)
        h.vm.endTest()
        XCTAssertEqual(h.fileStore?.summary().pending, 1)
        XCTAssertEqual(h.vm.pendingShots.count, 1, "Test bitince çekim atılmaz")
        // Uygulama kapandı: bellek gitti, klasör kaldı
        h.vm.pendingShots.removeAll()
        h.answering.results = [.success(FakeAnswering.reply(1))]
        h.vm.start()
        let sent = await waitUntil(60) { h.vm.answers.count == 1 }
        XCTAssertTrue(sent, "Bir sonraki testte klasördeki çekim gönderilir")
        XCTAssertEqual(h.answering.captureCalls.first?.shot.id, a.id)
        XCTAssertEqual(h.fileStore?.summary().sent, 1)
    }

    func testRestoreDropsShotsTheUserDeletedFromTheFolder() async {
        let h = harness(shots: [], replies: [])
        let a = stored(h, at: 1_800_000_100)
        h.vm.keepPending(a)
        h.fileStore?.deleteAll()   // kullanıcı klasörü Ayarlar'dan temizledi
        h.vm.restorePendingShots()
        XCTAssertTrue(h.vm.pendingShots.isEmpty)
    }

    func testDeleteButtonsWorkOnlyWhenNoTestIsRunning() async {
        let h = harness(shots: [], replies: [])
        _ = await h.startListening()
        _ = stored(h, at: 1_800_000_100)
        let sent = stored(h, at: 1_800_000_200)
        h.fileStore?.markSent(sent, answer: "a")
        XCTAssertEqual(h.vm.deleteSentCaptures(), 0, "Test sürerken silinmez")
        XCTAssertEqual(h.vm.deleteAllCaptures(), 0)
        XCTAssertEqual(h.vm.captureFolderSummary().total, 2)
        h.vm.endTest()
        XCTAssertEqual(h.vm.deleteSentCaptures(), 1)
        XCTAssertEqual(h.vm.captureFolderSummary().pending, 1, "Bekleyen çekime dokunulmaz")
        XCTAssertEqual(h.vm.deleteAllCaptures(), 1)
        XCTAssertEqual(h.vm.captureFolderSummary().total, 0)
        XCTAssertTrue(h.vm.pendingShots.isEmpty)
    }

    func testCapturedPassageIsKeptInItsFolderAndNotSentOnItsOwn() async {
        let h = harness(shots: [.success(FakeCamera.shot())])
        _ = await h.startListening()
        reply(h, "ortak paragraf")
        let asked = await waitUntil(45) { h.vm.listenMode == .passageCameraChoice && h.vm.phase == .listening }
        XCTAssertTrue(asked, "Paragraf için kamera sorusu sorulur")
        reply(h, "evet")
        let taken = await waitUntil(45) { h.vm.listenMode == .passageTargets && h.vm.phase == .listening }
        XCTAssertTrue(taken, "Paragraf çekilir ve hangi sorular için olduğu sorulur")
        XCTAssertEqual(h.fileStore?.summary().passages, 1, "Paragraf çekimi Paragraf klasörüne yazılır")
        XCTAssertEqual(h.fileStore?.summary().pending, 0, "Paragraf çekimi bekleyen soru değildir")
        XCTAssertTrue(h.answering.captureCalls.isEmpty, "Paragraf tek başına gönderilmez")
        XCTAssertTrue(h.vm.pendingShots.isEmpty)
    }
}
