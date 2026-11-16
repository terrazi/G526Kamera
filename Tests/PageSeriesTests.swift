import XCTest
import UIKit
@testable import G526CameraDrive

/// Sayfa bazlı toplu çekim (kullanıcı kararı 2026-11-16): bir oturumda birkaç sayfa, çekim boyunca ses ve titreşim yok,
/// sayfadaki bütün soruların cevabı sırayla okunur.
@MainActor
final class PageSeriesTests: XCTestCase {
    typealias T = SessionViewModel.Timing

    /// Bir oturumun sonucu: `photos` fotoğraflık TEK PDF (planlanan 75)
    private func series(photos: Int = 75, planned: Int = 75, failure: CameraFailure? = nil) -> Result<PageSeries, CameraFailure> {
        return .success(PageSeries(shot: FakeCamera.page(1, photos: photos), planned: planned, failure: failure))
    }

    /// Kameraya geçince internet gider, "Hücresele Geç" kestirmesi interneti getirir
    private func harness(seriesResults: [Result<PageSeries, CameraFailure>],
                         pageReplies: [Result<[GeminiReply], Error>],
                         archive: Bool = false) -> SessionHarness {
        let h = SessionHarness(cameraFlow: true, archive: archive, pageSeries: true)
        h.camera.seriesResults = seriesResults
        h.answering.pageResults = pageReplies
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

    private func questionOpen(_ h: SessionHarness) -> Bool {
        return h.vm.listenMode == .cameraChoice && h.vm.phase == .listening
    }

    private func index(of text: String, in spoken: [String]) -> Int? { return spoken.firstIndex(of: text) }

    // MARK: Akış

    func testYesStartsASessionAndAllTheAnswersOfTheSinglePdfAreReadInOrder() async {
        let h = harness(seriesResults: [series()],
                        pageReplies: [.success([FakeAnswering.reply(1), FakeAnswering.reply(2), FakeAnswering.reply(3)])])
        _ = await h.startListening()
        let ask = Say.askCameraSeries(pages: 5, seconds: 15)
        XCTAssertEqual(h.speaker.spoken, [Say.readyCamera, ask], "Toplu çekim açıkken soru oturum sorusudur")
        reply(h, "evet")
        let done = await waitUntil(45) { h.vm.answers.count == 3 && self.questionOpen(h) }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        XCTAssertEqual(h.events, ["kestirme:Kameraya_Gec", "oturum", "kestirme:Hücresele_Gec", "sayfa gönderimi"],
                       "Önce kameraya geçilir ve oturum çekilir, sonra internete dönülür, ondan sonra TEK PDF tek istekle gönderilir")
        XCTAssertEqual(h.camera.seriesCalls.first?.pages, 5)
        XCTAssertEqual(h.camera.seriesCalls.first?.seconds, 15)
        XCTAssertEqual(h.camera.captures, 0, "Tek soruluk çekim kullanılmaz")
        XCTAssertEqual(h.answering.pageCalls.count, 1, "75 sayfalık PDF tek seferde gider")
        XCTAssertEqual(h.answering.pageCalls.first?.shot.pageCount, 75)
        XCTAssertEqual(h.answering.pageCalls.first?.expectedNumber, 1)
        let spoken = h.speaker.spoken
        let first = index(of: "Soru 1, Denizli, Örgütsel Davranış", in: spoken)
        let second = index(of: "Soru 2, Denizli, Örgütsel Davranış", in: spoken)
        let third = index(of: "Soru 3, Denizli, Örgütsel Davranış", in: spoken)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertNotNil(third)
        if let first = first, let second = second, let third = third {
            XCTAssertEqual(second, first + 1, "Cevaplar arasında başka cümle girmez")
            XCTAssertEqual(third, second + 1)
        }
        XCTAssertEqual(h.speaker.spoken.last, ask, "Bitince yeni oturum sorulur")
        XCTAssertTrue(h.vm.pendingShots.isEmpty)
        XCTAssertEqual(h.vm.questions.map { $0.number }, [1, 2, 3])
    }

    func testTheSessionIsAnnouncedOnceAndNothingIsSaidWhileTheCameraRuns() async {
        let h = harness(seriesResults: [series()], pageReplies: [.success([FakeAnswering.reply(1)])])
        var spokenBefore = -1
        var handlersSet = true
        h.camera.onSeries = {
            spokenBefore = h.speaker.spoken.count
            handlersSet = h.camera.onSay != nil || h.camera.onSayWait != nil
        }
        _ = await h.startListening()
        reply(h, "evet")
        let done = await waitUntil(45) { h.vm.answers.count == 1 && self.questionOpen(h) }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        guard spokenBefore > 0 else { return XCTFail("Oturum başlamadı: \(h.speaker.spoken)") }
        let starting = Say.seriesStarting(pages: 5, seconds: 15)
        XCTAssertEqual(h.speaker.spoken.filter { $0 == starting }.count, 1, "Duyuru oturum başında bir kez")
        XCTAssertEqual(h.speaker.spoken[spokenBefore - 1], starting, "Kameraya geçilmeden hemen önce söylenen son cümle duyurudur")
        XCTAssertFalse(handlersSet, "Kameranın konuşma bağlantıları oturumda verilmez: çekim sessizdir")
        let seriesDone = Say.seriesDone(taken: 75, planned: 75)
        XCTAssertEqual(h.speaker.spoken[spokenBefore], seriesDone, "Çekim sırasında ve hemen ardından duyuruya kadar hiçbir şey söylenmez")
    }

    func testTheHeadsetDroppingDuringTheSessionDoesNotPauseTheFlow() async {
        let h = harness(seriesResults: [series()], pageReplies: [.success([FakeAnswering.reply(1)])])
        var paused = false
        func notePause() { if case .paused = h.vm.phase { paused = true } }
        h.trackEvents { name in
            if name == "Kameraya_Gec" {
                h.health.internet = false
                h.route.change(to: FakeRoute.noHeadphones)   // kestirme kulaklığı kapattı
                notePause()
            }
            if name == "Hücresele_Gec" {
                h.health.internet = true
                Task { @MainActor in
                    await Task.yield()
                    await Task.yield()
                    h.route.change(to: FakeRoute.good)       // kulaklık birkaç sn sonra döndü
                }
            }
        }
        h.camera.onSeries = { notePause() }
        _ = await h.startListening()
        reply(h, "evet")
        let done = await waitUntil(45) { h.vm.answers.count == 1 }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        XCTAssertFalse(paused, "Oturum boyunca kulaklığın düşmesi duraklatma sayılmaz")
        XCTAssertTrue(h.speaker.spoken.contains(Say.seriesDone(taken: 75, planned: 75)))
        XCTAssertFalse(h.isHardwarePause)
    }

    func testASessionCutShortStillSendsThePhotosItGot() async {
        let h = harness(seriesResults: [series(photos: 40, planned: 75, failure: .noFrames)], pageReplies: [.success([FakeAnswering.reply(1)])])
        _ = await h.startListening()
        reply(h, "evet")
        let done = await waitUntil(45) { h.vm.answers.count == 1 && self.questionOpen(h) }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        XCTAssertTrue(h.speaker.spoken.contains(Say.seriesDone(taken: 40, planned: 75)), "Yarıda kesilince kaç sayfa alındığı söylenir")
        XCTAssertEqual(h.answering.pageCalls.first?.shot.pageCount, 40)
        XCTAssertTrue(h.vm.pendingShots.isEmpty)
    }

    func testASessionThatCannotConnectFallsBackToReadingTheQuestionAloud() async {
        let h = harness(seriesResults: Array(repeating: .failure(.notConnected), count: T.cameraRepairs + 1), pageReplies: [])
        _ = await h.startListening()
        reply(h, "evet")
        let fallen = await waitUntil(45) { h.vm.listenMode == .question && h.vm.phase == .listening }
        XCTAssertTrue(fallen, "\(h.speaker.spoken)")
        XCTAssertEqual(h.camera.seriesCalls.count, T.cameraRepairs + 1)
        XCTAssertTrue(h.speaker.spoken.contains(Say.cameraFailed(.notConnected, down: true, minutes: h.settings.cameraCheckMinutes)))
        XCTAssertTrue(h.vm.pendingShots.isEmpty)
        XCTAssertTrue(h.answering.pageCalls.isEmpty)
    }

    func testAPdfWithNoQuestionSaysSoAndTakesNoNumber() async {
        let empty = GeminiReply(number: nil, option: "", text: "", spoken: "", model: "fake")
        let h = harness(seriesResults: [series(), series()], pageReplies: [.success([empty]), .success([FakeAnswering.reply(1)])])
        _ = await h.startListening()
        reply(h, "evet")
        let said = await waitUntil(45) { h.speaker.spoken.contains(Say.pageNoQuestion) && self.questionOpen(h) }
        XCTAssertTrue(said, "\(h.speaker.spoken)")
        XCTAssertTrue(h.vm.answers.isEmpty, "Soru bulunmayan PDF cevap üretmez")
        XCTAssertEqual(h.vm.nextNumber, 1, "Numara tüketilmez")
        XCTAssertTrue(h.vm.questions.isEmpty, "Satır bırakmaz")
        XCTAssertTrue(h.vm.pendingShots.isEmpty, "Soru bulunmayan PDF de gönderilmiş sayılır")
        reply(h, "evet")
        let done = await waitUntil(45) { h.vm.answers.count == 1 && self.questionOpen(h) }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        XCTAssertEqual(h.answering.pageCalls.map { $0.expectedNumber }, [1, 1])
    }

    func testTheSessionQuestionIsAskedAgainInTheSessionWording() async {
        let h = harness(seriesResults: [], pageReplies: [])
        _ = await h.startListening()
        h.listener.say("şey acaba nasıl")
        h.scheduler.advance(by: T.numberUnclear + 0.1)
        let again = await waitUntil(45) { h.speaker.spoken.last == Say.askCameraSeriesAgain(pages: 5, seconds: 15) && self.questionOpen(h) }
        XCTAssertTrue(again, "\(h.speaker.spoken)")
        XCTAssertEqual(h.camera.seriesCalls.count, 0)
    }

    func testThePdfIsPersistedAsAPageAndMovesToSentWhenAllAnswersAreHeard() async {
        let h = harness(seriesResults: [series()], pageReplies: [.success([FakeAnswering.reply(1), FakeAnswering.reply(2), FakeAnswering.reply(3)])],
                        archive: true)
        _ = await h.startListening()
        reply(h, "evet")
        let done = await waitUntil(45) { h.vm.answers.count == 3 && self.questionOpen(h) }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        let summary = h.fileStore!.summary()
        XCTAssertEqual(summary.pending, 0)
        XCTAssertEqual(summary.sent, 1, "PDF, bütün cevapları duyulunca Gönderilen klasörüne taşınır")
    }

    func testACaptureStoreRestoresAPageAsAPage() {
        let root = makeTempFolder("g526-sayfa")
        let store = FileCaptureStore(root: root)
        store.prepare()
        _ = store.keep(FakeCamera.page(7), kind: .page)
        _ = store.keep(FakeCamera.shot(video: false), kind: .question)
        let restored = store.restorePending()
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored.filter { $0.isPage }.count, 1, "Sayfa yeniden açılınca da sayfa olarak geri yüklenir")
        XCTAssertEqual(restored.filter { !$0.isPage }.count, 1)
    }

    // MARK: Ayarlar

    func testSeriesSettingsDefaultsAndRanges() {
        let defaults = UserDefaults(suiteName: "g526.testler.\(UUID().uuidString)")!
        let settings = CameraSettings(defaults: defaults)
        XCTAssertTrue(settings.pageSeries, "Toplu çekim varsayılan AÇIK")
        XCTAssertEqual(settings.seriesPages, 5)
        XCTAssertEqual(settings.seriesSeconds, 15)
        defaults.set(99, forKey: "seriesPages")
        defaults.set(1, forKey: "seriesSeconds")
        let clamped = CameraSettings(defaults: defaults)
        XCTAssertEqual(clamped.seriesPages, 10)
        XCTAssertEqual(clamped.seriesSeconds, 5)
        clamped.pageSeries = false
        XCTAssertFalse(CameraSettings(defaults: defaults).pageSeries, "Ayar kalıcıdır")
    }

    func testASessionNeedsAFewPhotosToBeKept() {
        XCTAssertEqual(CameraCaptureController.minPhotos(total: 75), 5)
        XCTAssertEqual(CameraCaptureController.minPhotos(total: 3), 3)
        XCTAssertEqual(CameraCaptureController.minPhotos(total: 1), 1)
    }

    // MARK: Tek PDF ve boyut bütçesi

    /// Gürültülü (sıkışması zor) bir JPEG: gerçek bir sayfa fotoğrafının boyutuna yakın (1 piksel = 1 nokta: telefonun ekran ölçeğine bağlı değil)
    private func noisyJPEG(size: CGSize = CGSize(width: 960, height: 540), quality: CGFloat = 0.92) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.jpegData(withCompressionQuality: quality) { ctx in
            for _ in 0..<2500 {
                let r = CGFloat.random(in: 0...1)
                let g = CGFloat.random(in: 0...1)
                let b = CGFloat.random(in: 0...1)
                UIColor(red: r, green: g, blue: b, alpha: 1).setFill()
                ctx.fill(CGRect(x: CGFloat.random(in: 0..<size.width), y: CGFloat.random(in: 0..<size.height), width: 40, height: 20))
            }
        }
    }

    func testPhotosThatFitTheBudgetAreLeftUntouched() {
        let jpegs = (0..<4).map { noisyJPEG() }
        let fitted = PageDocument.fit(jpegs, budget: jpegs.reduce(0) { $0 + $1.count } + 1000)
        XCTAssertEqual(fitted, jpegs, "Bütçeye sığan fotoğraflar yeniden sıkıştırılmaz")
    }

    func testPhotosOverTheBudgetAreRecompressedToFitWithoutLosingAny() {
        let jpegs = (0..<12).map { noisyJPEG() }
        let raw = jpegs.reduce(0) { $0 + $1.count }
        let budget = raw / 2
        let fitted = PageDocument.fit(jpegs, budget: budget)
        XCTAssertEqual(fitted.count, jpegs.count, "Hiçbir fotoğraf atılmaz")
        XCTAssertLessThanOrEqual(fitted.reduce(0) { $0 + $1.count }, budget, "Toplam bütçeye sığar")
        XCTAssertTrue(fitted.allSatisfy { UIImage(data: $0) != nil }, "Yeniden sıkıştırılan fotoğraflar okunur")
        let pdf = PageDocument.make(jpegs: fitted)
        XCTAssertEqual(pdf.map { PageDocument.pageCount(of: $0) }, 12, "PDF her fotoğraf için bir sayfa taşır")
    }

    func testRecompressionCanAlsoShrinkTheImage() {
        let jpeg = noisyJPEG()
        let small = PageDocument.recompress(jpeg, quality: 0.6, scale: 0.5)
        XCTAssertNotNil(small)
        if let small = small, let image = UIImage(data: small) {
            XCTAssertEqual(Int(image.size.width * image.scale), 480, accuracy: 2)
        }
    }

    // MARK: Gemini isteği ve cevap satırları

    func testSeveralAnswerLinesAreParsedInOrderAndDuplicatesAreDropped() {
        let lines = AnswerParser.parseLines("Soru 4, Denizli, Örgütsel Davranış\n\nSoru 5, Adana, Yönetim\nSoru 4, Bursa, Başka")
        XCTAssertEqual(lines.map { $0.number }, [4, 5])
        XCTAssertEqual(lines.first?.option, "Denizli")
        XCTAssertEqual(lines.last?.spoken, "Soru 5, Adana, Yönetim")
    }

    func testTheNoQuestionMarkerGivesOneEmptyReplyAndNoMarkerAnswersGiveNone() {
        XCTAssertTrue(AnswerParser.parseLines("SORU YOK").isEmpty)
        XCTAssertTrue(AnswerParser.isNoQuestion("soru yok."))
        let parsed = GeminiAnswerService.parsePage("SORU YOK")
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.spoken, "")
        XCTAssertNil(parsed.first?.number)
        XCTAssertTrue(GeminiAnswerService.parsePage("").isEmpty, "Boş cevap hâlâ hata sayılır")
        XCTAssertEqual(GeminiAnswerService.parsePage("Soru 2, Ceyhan, Pazarlama").count, 1)
    }

    func testThePageRequestAsksForEveryQuestionOnThePageAndSendsThePdf() throws {
        var page = FakeCamera.page(1)
        page.extraInstruction = "Şıklar küçük yazılmış"
        let body = try GeminiAnswerService.captureBody(page, expectedNumber: 4, page: true)
        let object = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let system = (((object["systemInstruction"] as! [String: Any])["parts"] as! [[String: Any]])[0]["text"] as! String)
        XCTAssertTrue(system.contains("HER SORU İÇİN AYRI BİR SATIR"))
        XCTAssertTrue(system.contains("SORU YOK"))
        let contents = object["contents"] as! [[String: Any]]
        let parts = contents[0]["parts"] as! [[String: Any]]
        let inline = parts.compactMap { $0["inline_data"] as? [String: Any] ?? $0["inlineData"] as? [String: Any] }
        XCTAssertEqual(inline.count, 1, "Toplu çekimde yalnız PDF gider (video yok)")
        let mime = (inline.first?["mime_type"] as? String) ?? (inline.first?["mimeType"] as? String)
        XCTAssertEqual(mime, "application/pdf")
        let text = parts.last?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("Soru 4"))
        XCTAssertTrue(text.contains("bütün soruları"))
        XCTAssertTrue(text.contains("Şıklar küçük yazılmış"))
    }
}
