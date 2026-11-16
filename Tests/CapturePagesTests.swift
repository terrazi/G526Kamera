import XCTest
import UIKit
@testable import G526CameraDrive

/// Sabit süreli çekim (kullanıcı kararı 2026-11-16): her soru ya da paragraf için ayarlı süre (varsayılan 10 sn) çekilir; her saniyenin en net karesi
/// bir fotoğraf olur, fotoğraflar TEK PDF'e dizilir, aynı sürenin küçük H.264 videosu ayrıca gider; ikisi Gemini'ye gönderilir.
/// Çekim sırasında sesli geri sayım vardır ("N saniye boyunca çekim yapabilirsiniz. Başlıyorum." → N … 1).
@MainActor
final class CapturePagesTests: XCTestCase {
    typealias T = SessionViewModel.Timing

    override func setUp() {
        super.setUp()
        Keychain.testStore = [:]
    }

    override func tearDown() {
        Keychain.testStore = nil
        super.tearDown()
    }

    // MARK: Yardımcılar

    /// Gürültülü (gerçekçi boyutlu) bir JPEG
    private func jpeg(seed: Int, width: Int = 640, height: Int = 360) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        return renderer.jpegData(withCompressionQuality: 0.9) { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            for i in 0..<400 {
                UIColor(hue: CGFloat((i * 7 + seed * 13) % 100) / 100, saturation: 0.9, brightness: 0.9, alpha: 1).setFill()
                ctx.fill(CGRect(x: (i * 37 + seed * 11) % (width - 30), y: (i * 53 + seed * 5) % (height - 12), width: 30, height: 12))
            }
        }
    }

    private func body(_ shot: CapturedQuestion, fps: Double? = nil) throws -> [String: Any] {
        let data = try GeminiAnswerService.captureBody(shot, expectedNumber: 4, fps: fps)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func parts(_ object: [String: Any]) throws -> [[String: Any]] {
        let contents = try XCTUnwrap(object["contents"] as? [[String: Any]])
        return try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
    }

    private func mime(_ part: [String: Any]) -> String {
        if let inline = part["inlineData"] as? [String: Any] { return inline["mimeType"] as? String ?? "?" }
        return part["text"] != nil ? "metin" : "?"
    }

    private func decoded(_ part: [String: Any]) throws -> Data {
        let inline = try XCTUnwrap(part["inlineData"] as? [String: Any])
        return try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(inline["data"] as? String)))
    }

    private func pdfShot(pages: Int = 10) throws -> CapturedQuestion {
        let jpegs = (0..<pages).map { jpeg(seed: $0) }
        var shot = FakeCamera.shot()
        shot.photo = jpegs[0]
        shot.pdf = try XCTUnwrap(PageDocument.make(jpegs: jpegs))
        shot.pageCount = pages
        return shot
    }

    // MARK: PDF

    func testTenPhotosBecomeOneTenPagePdfWithoutBlowingUpTheSize() throws {
        let jpegs = (0..<10).map { jpeg(seed: $0) }
        let pdf = try XCTUnwrap(PageDocument.make(jpegs: jpegs))
        XCTAssertEqual(PageDocument.pageCount(of: pdf), 10)
        XCTAssertTrue(pdf.starts(with: Array("%PDF".utf8)))
        let total = jpegs.reduce(0) { $0 + $1.count }
        XCTAssertLessThan(pdf.count, Int(Double(total) * 1.6) + 30_000, "JPEG'ler olduğu gibi gömülür: PDF \(pdf.count), fotoğraflar \(total)")
    }

    func testUnreadablePicturesAreSkippedAndNothingReadableGivesNil() throws {
        let good = jpeg(seed: 1)
        let pdf = try XCTUnwrap(PageDocument.make(jpegs: [Data([1, 2, 3]), good, Data(), good]))
        XCTAssertEqual(PageDocument.pageCount(of: pdf), 2)
        XCTAssertNil(PageDocument.make(jpegs: []))
        XCTAssertNil(PageDocument.make(jpegs: [Data([9, 9, 9])]))
        XCTAssertEqual(PageDocument.pageCount(of: Data([1, 2, 3])), 0)
    }

    // MARK: Gemini isteği

    func testThePdfGoesToGeminiInPlaceOfTheSinglePhotoAndThenTheVideoAndTheText() throws {
        let shot = try pdfShot()
        let list = try parts(try body(shot, fps: VideoRecorder.fps))
        XCTAssertEqual(list.map(mime), ["application/pdf", "video/mp4", "metin"], "Tek fotoğraf gitmez; metin en sonda")
        XCTAssertEqual(try decoded(list[0]), shot.pdf)
        let text = try XCTUnwrap(list[2]["text"] as? String)
        XCTAssertTrue(text.contains("10 sayfalık PDF"), text)
        XCTAssertTrue(text.contains("video"))
    }

    func testWithoutAPdfTheSinglePhotoStillGoes() throws {
        var shot = FakeCamera.shot()
        shot.photo = jpeg(seed: 3)
        let list = try parts(try body(shot))
        XCTAssertEqual(list.map(mime), ["image/jpeg", "video/mp4", "metin"])
        let text = try XCTUnwrap(list[2]["text"] as? String)
        XCTAssertFalse(text.contains("PDF"))
    }

    func testThePdfAloneGoesWhenTheVideoIsTurnedOffOrMissing() throws {
        var shot = try pdfShot(pages: 3)
        shot.video = nil
        shot.videoBytes = 0
        let list = try parts(try body(shot))
        XCTAssertEqual(list.map(mime), ["application/pdf", "metin"])
        let text = try XCTUnwrap(list[1]["text"] as? String)
        XCTAssertTrue(text.contains("3 sayfalık PDF") && !text.contains("video"), text)
    }

    func testThePdfSizeCountsAgainstTheInlineLimitSoAHugeVideoIsLeftOut() throws {
        var shot = try pdfShot(pages: 2)
        shot.pdf = Data(count: 13_000_000)   // 13 MB'lık PDF + 2 MB video 14 MB sınırını aşar
        shot.videoBytes = 2_000_000
        XCTAssertEqual(shot.visualBytes, 13_000_000)
        XCTAssertFalse(shot.canSendVideo)
        shot.pdf = Data(count: 4_000_000)
        XCTAssertTrue(shot.canSendVideo, "10 fotoğraflık PDF ≈ 4 MB + video ≈ 1,5 MB sığar")
    }

    func testThePassagePdfGoesBeforeTheQuestionsImages() throws {
        var question = try pdfShot(pages: 4)
        let passage = try pdfShot(pages: 6)
        question.passageMedia = PassageMedia(passage)
        let list = try parts(try body(question))
        XCTAssertEqual(list.map(mime), ["application/pdf", "video/mp4", "application/pdf", "video/mp4", "metin"])
        XCTAssertEqual(try decoded(list[0]), passage.pdf, "Önce paragrafın PDF'i")
        XCTAssertEqual(try decoded(list[2]), question.pdf)
    }

    func testThePromptKnowsThePagesAreSuccessivePhotosOfTheSameQuestion() {
        let prompt = GeminiAnswerService.captureSystemPrompt
        XCTAssertTrue(prompt.contains("PDF"))
        XCTAssertTrue(prompt.contains("BİRLİKTE"), "Sayfalar ve video birlikte değerlendirilir")
        XCTAssertTrue(prompt.contains("YOK SAY"), "Kenardaki yarım sorular yine yok sayılır")
    }

    // MARK: Telefondaki kalıcı klasör

    func testThePdfIsKeptNextToThePhotoAndComesBackAfterARestart() throws {
        let root = makeTempFolder("g526-pdf").appendingPathComponent("Cekimler", isDirectory: true)
        let store = FileCaptureStore(root: root)
        store.prepare()
        let shot = try pdfShot(pages: 5)
        let kept = store.keep(shot, kind: .question)
        XCTAssertTrue(kept.archived)
        let dir = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: store.url(of: .pending), includingPropertiesForKeys: nil).first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sayfalar.pdf").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("foto.jpg").path))

        let reopened = FileCaptureStore(root: root).restorePending()
        XCTAssertEqual(reopened.count, 1)
        XCTAssertEqual(reopened.first?.pdf, shot.pdf)
        XCTAssertEqual(reopened.first?.pageCount, 5)
        XCTAssertEqual(reopened.first?.photo, shot.photo)
    }

    // MARK: Ayarlar ve söylenen cümleler

    func testTheCaptureLastsTenSecondsByDefaultAndTheCountdownIsOn() {
        let name = "g526-capture-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        let s = CameraSettings(defaults: d)
        XCTAssertEqual(s.pageVideoSeconds, 10)
        XCTAssertEqual(VideoRecorder.pageSegmentSeconds, 10)
        XCTAssertTrue(s.countdown)
        s.countdown = false
        s.pageVideoSeconds = 7
        let again = CameraSettings(defaults: d)
        XCTAssertFalse(again.countdown)
        XCTAssertEqual(again.pageVideoSeconds, 7)
    }

    func testTheCountdownSaysTheDurationThenStartsAndCountsDown() {
        XCTAssertEqual(CameraSay.countdownIntro(seconds: 10), "10 saniye boyunca çekim yapabilirsiniz. Başlıyorum.")
        XCTAssertEqual(CameraSay.countdownNumber(10), "10")
        XCTAssertEqual(CameraSay.countdownNumber(1), "1")
    }

    // MARK: Akış: çekim öncesi duyuru bitmeden çekim sürmez

    func testTheAnnouncementBeforeTheCaptureIsSpokenInFullAndAwaited() async {
        let h = SessionHarness(cameraFlow: true)
        h.camera.results = [.success(FakeCamera.shot())]
        h.camera.waitedGuidance = CameraSay.countdownIntro(seconds: 10)
        h.answering.results = [.success(FakeAnswering.reply(1))]
        h.trackEvents { name in
            if name == "Kameraya_Gec" { h.health.internet = false }
            if name == "Hücresele_Gec" { h.health.internet = true }
        }
        var doneAt: Int?
        h.camera.onWaitedSayDone = { doneAt = h.speaker.spoken.count }
        _ = await h.startListening()
        h.listener.say("evet")
        h.scheduler.advance(by: T.numberConfirm + 0.1)
        let answered = await waitUntil(45) { h.vm.answers.count == 1 }
        XCTAssertTrue(answered)
        XCTAssertTrue(h.speaker.spoken.contains(CameraSay.countdownIntro(seconds: 10)), "Duyuru kulaklıktan söylenir: \(h.speaker.spoken)")
        let said = h.speaker.spoken.firstIndex(of: CameraSay.countdownIntro(seconds: 10)) ?? -1
        XCTAssertNotNil(doneAt)
        XCTAssertGreaterThan(doneAt ?? 0, said, "Çekim, duyuru söylenip BİTTİKTEN sonra sürer")
    }
}
