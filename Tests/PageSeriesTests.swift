import XCTest
import UIKit
@testable import G526CameraDrive

/// Toplu çekim (kullanıcı kararı 2026-11-16): oturumun tek sınırı süredir (75 sn), sayfa sayısı yoktur; çekim boyunca ses ve titreşim yok,
/// görüntülerdeki bütün soruların cevabı sırayla, aralarında 2 sn boşlukla okunur.
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

    /// Cevaplar arasındaki 2 sn'lik beklemeler: her biri için o ana kadar söylenen cümle sayısı (bir cevabın hemen ardından, sıradaki cevaptan önce)
    private func answerGaps(_ h: SessionHarness) -> [Int] {
        return h.sleepLog.entries
            .filter { $0.seconds == T.answerGap && $0.spokenCount >= 1 && $0.spokenCount < h.speaker.spoken.count }
            .filter { h.speaker.spoken[$0.spokenCount - 1].hasPrefix("Soru") && h.speaker.spoken[$0.spokenCount].hasPrefix("Soru") }
            .map { $0.spokenCount }
    }

    // MARK: Akış

    func testYesStartsASessionAndAllTheAnswersOfTheSinglePdfAreReadInOrder() async {
        let h = harness(seriesResults: [series()],
                        pageReplies: [.success([FakeAnswering.reply(1), FakeAnswering.reply(2), FakeAnswering.reply(3)])])
        _ = await h.startListening()
        let ask = Say.askCameraSeries(seconds: 75)
        XCTAssertEqual(h.speaker.spoken, [Say.readyCamera, ask], "Toplu çekim açıkken soru oturum sorusudur")
        reply(h, "evet")
        let done = await waitUntil(45) { h.vm.answers.count == 3 && self.questionOpen(h) }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        XCTAssertEqual(h.events, ["kestirme:Kameraya_Gec", "oturum", "kestirme:Hücresele_Gec", "sayfa gönderimi"],
                       "Önce kameraya geçilir ve oturum çekilir, sonra internete dönülür, ondan sonra TEK PDF tek istekle gönderilir")
        XCTAssertEqual(h.camera.seriesCalls.first?.seconds, 75, "Oturumun tek sınırı süredir: sayfa sayısı verilmez")
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
        let starting = Say.seriesStarting(seconds: 75)
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
        let again = await waitUntil(45) { h.speaker.spoken.last == Say.askCameraSeriesAgain(seconds: 75) && self.questionOpen(h) }
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
        XCTAssertEqual(settings.seriesSeconds, 75, "Oturum süresi varsayılan 75 sn")
        defaults.set(1, forKey: "seriesTotalSeconds")
        XCTAssertEqual(CameraSettings(defaults: defaults).seriesSeconds, 15, "En az 15 sn")
        defaults.set(999, forKey: "seriesTotalSeconds")
        let clamped = CameraSettings(defaults: defaults)
        XCTAssertEqual(clamped.seriesSeconds, 150, "En çok 150 sn")
        let old = UserDefaults(suiteName: "g526.testler.\(UUID().uuidString)")!
        old.set(15, forKey: "seriesSeconds")   // eski sürümün "sayfa başına sn" anahtarı yeni süreyi etkilemez
        old.set(5, forKey: "seriesPages")
        XCTAssertEqual(CameraSettings(defaults: old).seriesSeconds, 75)
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
        let jpegs = (0..<4).map { _ in noisyJPEG() }
        let fitted = PageDocument.fit(jpegs, budget: jpegs.reduce(0) { $0 + $1.count } + 1000)
        XCTAssertEqual(fitted, jpegs, "Bütçeye sığan fotoğraflar yeniden sıkıştırılmaz")
    }

    func testPhotosOverTheBudgetAreRecompressedToFitWithoutLosingAny() {
        let jpegs = (0..<12).map { _ in noisyJPEG() }
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
        XCTAssertTrue(system.contains("eşit sürede gösterilmez"), "Sayfaların eşit sürede gösterilmediği, sayfa sayısının belli olmadığı söylenir")
        XCTAssertTrue(system.contains("ortak paragraf"), "Paragrafa bağlı soruların hepsi cevaplanır")
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

    // MARK: Süre tek sınır, cevaplar arası 2 sn

    func testTheSessionAnnouncementTalksOnlyAboutTheDuration() {
        let starting = Say.seriesStarting(seconds: 75)
        XCTAssertTrue(starting.contains("75 saniye"))
        XCTAssertFalse(starting.lowercased().contains("her sayfa"), "Sayfa sayısı ya da sayfa başına süre söylenmez")
        XCTAssertFalse(Say.askCameraSeries(seconds: 75).lowercased().contains("sayfa çekilecek"))
        XCTAssertFalse(Say.seriesDone(taken: 75, planned: 75).contains("sayfalık"), "PDF'in fotoğraf sayısı sayfa gibi söylenmez")
    }

    func testEveryAnswerOfThePdfIsFollowedByATwoSecondGapExceptTheLast() async {
        let h = harness(seriesResults: [series()],
                        pageReplies: [.success([FakeAnswering.reply(1), FakeAnswering.reply(2), FakeAnswering.reply(3)])])
        _ = await h.startListening()
        reply(h, "evet")
        let done = await waitUntil(45) { h.vm.answers.count == 3 && self.questionOpen(h) }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        XCTAssertEqual(T.answerGap, 2, "Cevaplar arası boşluk 2 sn")
        let gaps = answerGaps(h)
        XCTAssertEqual(gaps.count, 2, "Üç cevap arasında iki boşluk: sonuncudan sonra yoktur")
        for gap in gaps {
            XCTAssertTrue(h.speaker.spoken[gap - 1].hasPrefix("Soru"), "Boşluktan önce bir cevap okunmuştur")
            XCTAssertTrue(h.speaker.spoken[gap].hasPrefix("Soru"), "Boşluktan sonra sıradaki cevap okunur")
        }
        let answers = h.speaker.spoken.filter { $0.hasPrefix("Soru") }
        XCTAssertEqual(answers, ["Soru 1, Denizli, Örgütsel Davranış", "Soru 2, Denizli, Örgütsel Davranış", "Soru 3, Denizli, Örgütsel Davranış"],
                       "Her cevap soru numarası, şık sözcüğü ve doğru şıkkın metniyle, sırayla okunur")
    }

    func testASingleAnswerHasNoGap() async {
        let h = harness(seriesResults: [series()], pageReplies: [.success([FakeAnswering.reply(1)])])
        _ = await h.startListening()
        reply(h, "evet")
        let done = await waitUntil(45) { h.vm.answers.count == 1 && self.questionOpen(h) }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        XCTAssertTrue(answerGaps(h).isEmpty, "Tek cevaplık PDF'te cevap arası boşluk yoktur")
    }

    func testAPdfOfAnyNumberOfPagesIsOneRequest() async {
        // 75 sn'de 3 sayfa da gösterilebilir, 10 sayfa da: soru sayısı sabit değildir, hepsi tek istekte gider ve hepsi okunur
        let replies = (1...9).map { FakeAnswering.reply($0) }
        let h = harness(seriesResults: [series()], pageReplies: [.success(replies)])
        _ = await h.startListening()
        reply(h, "evet")
        let done = await waitUntil(45) { h.vm.answers.count == 9 && self.questionOpen(h) }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        XCTAssertEqual(h.answering.pageCalls.count, 1)
        XCTAssertEqual(answerGaps(h).count, 8, "9 cevap arasında 8 boşluk")
    }

    // MARK: Kamera: görüntü gelmeyen bağlantıda erken vazgeçme

    func testAConnectionThatGivesNoVideoIsDroppedTwentySecondsAfterTheHandshake() {
        typealias C = CameraCaptureController
        XCTAssertEqual(C.videoWaitSeconds, 20)
        // el sıkışma yok: tam süre beklenir
        XCTAssertFalse(C.shouldGiveUp(elapsed: 39, limit: 40, handshakeAge: nil, grace: true))
        XCTAssertTrue(C.shouldGiveUp(elapsed: 40, limit: 40, handshakeAge: nil, grace: true))
        // el sıkışıldı ama görüntü gelmiyor: 20 sn sonra bırakılır (40 sn beklenmez)
        XCTAssertFalse(C.shouldGiveUp(elapsed: 25, limit: 40, handshakeAge: 19.9, grace: true))
        XCTAssertTrue(C.shouldGiveUp(elapsed: 25, limit: 40, handshakeAge: 20, grace: true))
        // kesin sınır (oturum başı, 15 sn): el sıkışılsa da sınırdan sonra beklenmez
        XCTAssertTrue(C.shouldGiveUp(elapsed: 15, limit: 15, handshakeAge: 5, grace: false))
        XCTAssertFalse(C.shouldGiveUp(elapsed: 14, limit: 15, handshakeAge: 5, grace: false))
        // sınırın hemen sonunda el sıkışılırsa ek süre tanınır, ama en çok `connectGraceSeconds` kadar
        XCTAssertFalse(C.shouldGiveUp(elapsed: 41, limit: 40, handshakeAge: 3, grace: true))
        XCTAssertTrue(C.shouldGiveUp(elapsed: 55, limit: 40, handshakeAge: 15, grace: true))
    }

    func testTheLinkQualityIsGradedFromTheRepeatAndLossRatios() {
        // Günlükteki iyi oturumlar: tekrar %0,9–6,7, kayıp %0–0,2 → iyi / orta; görüntü gelmeyenler: tekrar %12–57 → zayıf
        XCTAssertEqual(LinkQuality.level(packets: 7940, lost: 0, repeated: 85), .good)
        XCTAssertEqual(LinkQuality.level(packets: 5984, lost: 0, repeated: 53), .good)
        XCTAssertEqual(LinkQuality.level(packets: 7509, lost: 16, repeated: 501), .fair)
        XCTAssertEqual(LinkQuality.level(packets: 842, lost: 34, repeated: 186), .weak)
        XCTAssertEqual(LinkQuality.level(packets: 463, lost: 51, repeated: 178), .weak)
        XCTAssertEqual(LinkQuality.level(packets: 0, lost: 0, repeated: 0), .weak, "Hiç paket gelmediyse bağlantı kullanılamaz")
        XCTAssertEqual(LinkQuality.text(packets: 842, lost: 34, repeated: 186), "kayıp %3.9, tekrar %22.1, bağlantı zayıf")
    }
}
