import XCTest
@testable import G526CameraDrive

/// "Yeni sınav" seçilince önceki sınavdan telefonda kalan çekimler (gönderilememiş ya da cevapları tam dinlenmemiş PDF'ler) yeni sınavın
/// numaralarına karışmasın: günlükte (17.11.2026 08:10) eski PDF önce gönderilmiş, 44 cevabı yeni sınavın 1., 2., 3. sorusu diye okunmuştu.
@MainActor
final class LeftoverShotsTests: XCTestCase {
    typealias T = SessionViewModel.Timing

    private func harness() -> SessionHarness {
        let h = SessionHarness(cameraFlow: true, archive: true)
        h.camera.results = [.success(FakeCamera.shot())]
        h.answering.results = [.success(FakeAnswering.reply(1))]
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

    private func cameraQuestionOpen(_ h: SessionHarness) -> Bool {
        return h.vm.listenMode == .cameraChoice && h.vm.phase == .listening
    }

    private func count(_ h: SessionHarness, _ bucket: FileCaptureStore.Bucket) -> Int {
        guard let store = h.fileStore else { return -1 }
        return ((try? FileManager.default.contentsOfDirectory(atPath: store.url(of: bucket).path)) ?? []).count
    }

    /// Bir sınav yapılıp bitirilir, telefonda önceki sınavdan bir çekim kalır; yeni oturumda "önceki kayıt mı, yeni sınav mı" sorulur
    private func previousExamWithALeftoverShot(_ h: SessionHarness) async {
        _ = await h.startListening()
        reply(h, "evet")
        let done = await waitUntil(45) { h.vm.answers.count == 1 && self.cameraQuestionOpen(h) }
        XCTAssertTrue(done)
        h.vm.endTest()
        let kept = h.fileStore?.keep(FakeCamera.shot(video: false), kind: .question)
        XCTAssertEqual(kept?.archived, true)
        _ = await h.startListening()
        XCTAssertEqual(h.vm.listenMode, .startChoice)
        XCTAssertEqual(h.vm.pendingShots.count, 1, "Önceki sınavdan kalan çekim telefondaki klasörden geri yüklendi")
    }

    func testChoosingANewExamSetsAsideTheShotsLeftFromThePreviousExam() async {
        let h = harness()
        await previousExamWithALeftoverShot(h)
        let sentBefore = h.answering.captureCalls.count
        reply(h, "Yeni sınav")
        let on = await waitUntil(45) { self.cameraQuestionOpen(h) }
        XCTAssertTrue(on)
        XCTAssertTrue(h.vm.pendingShots.isEmpty, "Eski çekim gönderim sırasından çıktı")
        XCTAssertEqual(h.answering.captureCalls.count, sentBefore, "Eski çekim Gemini'ye gitmedi: cevapları yeni sınavın numaralarına karışmaz")
        XCTAssertEqual(count(h, .pending), 0)
        XCTAssertEqual(count(h, .unsendable), 1, "Silinmedi: telefonda Gonderilemeyen klasöründe duruyor")
        XCTAssertTrue(h.speaker.spoken.contains(Say.startingNewCamera + " " + Say.leftoverShotsSetAside(count: 1)), "Kullanıcıya söylenir")
        XCTAssertFalse(h.speaker.spoken.contains(Say.startingNewCamera), "Ayrılan çekim varsa duyuru ek cümleyle birlikte söylenir")
    }

    func testContinuingThePreviousRecordKeepsTheLeftoverShotInTheQueue() async {
        let h = harness()
        await previousExamWithALeftoverShot(h)
        reply(h, "Devam")
        let on = await waitUntil(45) { self.cameraQuestionOpen(h) }
        XCTAssertTrue(on)
        XCTAssertEqual(count(h, .unsendable), 0, "Önceki kayıttan devam edilince çekim ayrılmaz; sırayla gönderilmeye devam eder")
        XCTAssertFalse(h.speaker.spoken.contains { $0.contains("karışmasın diye ayrıldı") })
    }

    func testANewExamWithNothingLeftSaysNothingExtra() async {
        let h = harness()
        _ = await h.startListening()
        reply(h, "evet")
        let done = await waitUntil(45) { h.vm.answers.count == 1 && self.cameraQuestionOpen(h) }
        XCTAssertTrue(done)
        h.vm.endTest()
        _ = await h.startListening()
        XCTAssertEqual(h.vm.listenMode, .startChoice)
        reply(h, "Yeni sınav")
        let on = await waitUntil(45) { self.cameraQuestionOpen(h) }
        XCTAssertTrue(on)
        XCTAssertTrue(h.speaker.spoken.contains(Say.startingNewCamera))
        XCTAssertEqual(h.vm.setAsideLeftoverShots(), 0)
    }

    /// Bulanık eşleştirme görevin akışında da çalışır: "yeni" yerine "yeli" duyulsa yeni sınav seçilir; kamera sorusunda "evat" evet sayılır
    func testAMisheardNewIsStillTakenAsANewExamAndAMisheardYesAsYes() async {
        let h = harness()
        _ = await h.startListening()
        reply(h, "evat")
        let done = await waitUntil(45) { h.vm.answers.count == 1 && self.cameraQuestionOpen(h) }
        XCTAssertTrue(done, "Kamera sorusunda 'evat' evet sayıldı, soru çekilip cevaplandı")
        h.vm.endTest()
        _ = await h.startListening()
        XCTAssertEqual(h.vm.listenMode, .startChoice)
        reply(h, "yeli")
        let on = await waitUntil(45) { self.cameraQuestionOpen(h) && h.speaker.spoken.contains(Say.startingNewCamera) }
        XCTAssertTrue(on, "'yeli' yeni sınav sayıldı")
    }
}
