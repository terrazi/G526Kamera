import XCTest
@testable import G526CameraDrive

/// Çekim teşhisi, kadraj kontrolü ve deneme çekimi (kullanıcı kararı 2026-11-17). Kamera sayfaya çok yakınsa, görüntü bulanıksa ya da kadraj bazı soruları
/// kaçırıyorsa çekim bitince kullanıcıya söylenir; "deneme çekimi" gerçek çekim gibi çeker ama video + PDF + rapor telefondaki Deneme klasörüne yazılır,
/// Gemini'ye hiçbir şey gitmez; "kadraj kontrolü" Başla'dan önce canlı görüntüye kısa bir bakıştır.
final class CaptureDiagnosisTests: XCTestCase {
    private func diagnosis(windows: Int, readable: Int, sharpness: Double = 200, numbers: [Int] = []) -> CaptureDiagnosis {
        return CaptureDiagnosis(windows: windows, readableWindows: readable, medianSharpness: sharpness, questionNumbers: numbers)
    }

    // MARK: Teşhis

    func testTheHintFollowsTheMeasures() {
        XCTAssertEqual(diagnosis(windows: 0, readable: 0).hint, .good, "Yazı tanıma hiç çalışmadıysa karar verilemez: sorun söylenmez")
        XCTAssertEqual(diagnosis(windows: 40, readable: 0, sharpness: 20).hint, .blurry, "Hiç yazı okunamadı ve görüntü bulanık: çok yakın ya da odak dışı")
        XCTAssertEqual(diagnosis(windows: 40, readable: 0, sharpness: 300).hint, .noText, "Hiç yazı okunamadı ama görüntü net: sayfa kadrajda değil ya da yazı küçük")
        XCTAssertEqual(diagnosis(windows: 40, readable: 4).hint, .mostlyUnreadable, "Pencerelerin onda biri okundu")
        XCTAssertEqual(diagnosis(windows: 40, readable: 10).hint, .good, "Dörtte biri okundu: yeterli")
        XCTAssertEqual(diagnosis(windows: 40, readable: 38).hint, .good)
    }

    func testOnlyAJumpOfOneOrTwoBetweenSeenNumbersCountsAsASkippedQuestion() {
        XCTAssertEqual(CaptureDiagnosis.gaps(in: [11, 12, 14, 15]), [13])
        XCTAssertEqual(CaptureDiagnosis.gaps(in: [1, 2, 3, 5]), [4])
        XCTAssertEqual(CaptureDiagnosis.gaps(in: [5, 8]), [6, 7])
        XCTAssertEqual(CaptureDiagnosis.gaps(in: [1, 10]), [], "Büyük boşluk sayfa sınırı ya da alt madde numarası olabilir: söylenmez")
        XCTAssertEqual(CaptureDiagnosis.gaps(in: [7, 7, 7]), [])
        XCTAssertEqual(CaptureDiagnosis.gaps(in: []), [])
        XCTAssertEqual(CaptureDiagnosis.gaps(in: [14, 11, 12]), [13], "Sıra önemli değildir")
    }

    func testTheNumbersAreReadOutNaturally() {
        XCTAssertEqual(CaptureDiagnosis.numberList([4]), "4")
        XCTAssertEqual(CaptureDiagnosis.numberList([4, 7]), "4 ve 7")
        XCTAssertEqual(CaptureDiagnosis.numberList([4, 7, 9]), "4, 7 ve 9")
        XCTAssertEqual(CaptureDiagnosis.numberList([]), "")
    }

    func testTheSpokenAdviceCombinesTheHintAndTheSkippedNumbers() {
        XCTAssertEqual(diagnosis(windows: 40, readable: 30, numbers: [1, 2, 3]).spoken, "", "Sorun yoksa söylenecek bir şey yok")
        XCTAssertEqual(diagnosis(windows: 0, readable: 0).spoken, "")
        XCTAssertEqual(diagnosis(windows: 40, readable: 0, sharpness: 10).spoken, CaptureSay.blurry)
        XCTAssertEqual(diagnosis(windows: 40, readable: 0, sharpness: 400).spoken, CaptureSay.noText)
        XCTAssertEqual(diagnosis(windows: 40, readable: 3).spoken, CaptureSay.mostlyUnreadable)
        XCTAssertEqual(diagnosis(windows: 40, readable: 30, numbers: [11, 12, 14]).spoken, CaptureSay.missingSeen([13]))
        XCTAssertEqual(diagnosis(windows: 40, readable: 3, numbers: [11, 12, 14]).spoken, CaptureSay.mostlyUnreadable + " " + CaptureSay.missingSeen([13]))
        XCTAssertEqual(diagnosis(windows: 40, readable: 30, numbers: [1, 3, 5, 7, 9, 11, 13, 15]).spoken, CaptureSay.manyMissingSeen, "Altıdan çok eksik numara tek tek sayılmaz")
        XCTAssertTrue(CaptureSay.blurry.contains("uzaklaş"), "Bulanıklık çok yakınlıktan gelebilir: uzaklaşmak söylenir")
        XCTAssertEqual(CaptureSay.missingSeen([13]), "Soru 13 görünmedi.")
        XCTAssertEqual(CaptureSay.missingSeen([4, 7]), "Soru 4 ve 7 görünmedi.")
    }

    func testTheAnswersOfAPageAreCheckedForSkippedQuestions() {
        XCTAssertEqual(CaptureDiagnosis.missingAnswers(answered: [11, 12, 14], seen: []), [13], "Cevap numaraları arasındaki boşluk")
        XCTAssertEqual(CaptureDiagnosis.missingAnswers(answered: [11, 12, 13], seen: [14, 15]), [14, 15], "Karelerde görülen ama cevaplanmayan son sorular")
        XCTAssertEqual(CaptureDiagnosis.missingAnswers(answered: [11, 12, 13], seen: [30]), [], "Uzaktaki görülen numara (alt madde, puan, yıl) sayılmaz")
        XCTAssertEqual(CaptureDiagnosis.missingAnswers(answered: [11, 12, 13], seen: [2]), [], "Cevapların gerisindeki görülen numara sayılmaz")
        XCTAssertEqual(CaptureDiagnosis.missingAnswers(answered: [], seen: [1, 2, 3]), [], "Numaralı cevap yoksa söylenecek bir şey yok")
        XCTAssertEqual(CaptureDiagnosis.missingAnswers(answered: [1, 400], seen: []), [], "Yanlış okunmuş numara: aralık çok açık")
        XCTAssertEqual(CaptureDiagnosis.missingAnswers(answered: [5], seen: []), [])
        XCTAssertEqual(CaptureDiagnosis.missingAnswers(answered: [1, 2, 3], seen: [1, 2, 3]), [])
        XCTAssertEqual(CaptureSay.missingAnswers([13]), "Soru 13 cevaplanamadı; okunamamış ya da kadraja tam girmemiş olabilir. İsterseniz o kısımları daha sabit gösterip yeniden çekin.")
    }

    func testTheMedianOfTheSharpnessValues() {
        XCTAssertEqual(CaptureDiagnosis.median([]), 0)
        XCTAssertEqual(CaptureDiagnosis.median([5]), 5)
        XCTAssertEqual(CaptureDiagnosis.median([9, 1, 5]), 5)
        XCTAssertEqual(CaptureDiagnosis.median([8, 2, 4, 6]), 5)
    }

    func testTheTrialReportListsTheRawMeasuresSoTheThresholdsCanBeTuned() {
        let report = diagnosis(windows: 40, readable: 10, sharpness: 123.4, numbers: [1, 2, 4]).report(seconds: 75, measured: 600, selected: 20, readable: 14)
        XCTAssertTrue(report.hasPrefix("Deneme çekimi raporu"))
        XCTAssertTrue(report.contains("Süre: 75 sn; ölçülen kare: 600 (yaklaşık saniyede 8)"), report)
        XCTAssertTrue(report.contains("Yazı tanımadan geçen pencere: 40; yazısı okunan: 10 (%25)"), report)
        XCTAssertTrue(report.contains("Netlik (ortanca): 123; bulanık eşiği: 60"), report)
        XCTAssertTrue(report.contains("PDF'e giren kare: 20 (yazısı okunan: 14)"), report)
        XCTAssertTrue(report.contains("Görülen soru numaraları: 1, 2, 4"), report)
        XCTAssertTrue(report.contains("Arada görünmeyen numaralar: 3"), report)
        XCTAssertTrue(report.contains("Sonuç: " + CaptureSay.missingSeen([3])), report)
        let clean = diagnosis(windows: 40, readable: 30, numbers: [1, 2, 3]).report(seconds: 75, measured: 600, selected: 20, readable: 20)
        XCTAssertTrue(clean.contains("Sonuç: Yazı yeterince okundu; bu kadrajla çekim yapılabilir."), clean)
        XCTAssertTrue(clean.contains("Arada görünmeyen numaralar: yok"), clean)
    }

    // MARK: Kadraj kontrolü

    func testTheViewCheckVerdictsAreSpokenFromWhatTheCameraShows() {
        var readable = TextScore()
        readable.chars = SeriesSelection.minChars + 200
        readable.confidence = 0.9
        var withOptions = readable
        withOptions.options = ["A", "B", "C"]
        withOptions.questionNumbers = [4]
        XCTAssertEqual(ViewCheck(frames: 0, sharpness: 0, text: nil).spoken, CaptureSay.viewNoFrames, "Görüntü gelmiyor")
        XCTAssertEqual(ViewCheck(frames: 10, sharpness: 200, text: nil).spoken, CaptureSay.viewNoOCR, "Yazı tanıma çalışmadı: değerlendirilemez")
        XCTAssertEqual(ViewCheck(frames: 10, sharpness: 200, text: withOptions).spoken, CaptureSay.viewGood, "Soru numarası ve şıklar okunuyor")
        XCTAssertEqual(ViewCheck(frames: 10, sharpness: 200, text: readable).spoken, CaptureSay.viewTextOnly, "Yazı okunuyor ama soru yapısı görünmüyor")
        XCTAssertEqual(ViewCheck(frames: 10, sharpness: 20, text: TextScore()).spoken, CaptureSay.viewBlurry, "Yazı okunamıyor ve bulanık: çok yakın")
        XCTAssertEqual(ViewCheck(frames: 10, sharpness: 300, text: TextScore()).spoken, CaptureSay.viewNoText, "Yazı okunamıyor ama net: sayfa kadrajda değil")
    }
}

/// Sesli komutlar, depo ve oturum akışı
@MainActor
final class TrialFlowTests: XCTestCase {
    typealias T = SessionViewModel.Timing

    // MARK: Komutlar

    func testTheTrialAndViewCheckCommandsAreUnderstood() {
        for text in ["deneme çekimi", "Deneme çekimi.", "deneme çekimi yap", "deneme çekimini başlat", "lütfen deneme çekimi yapalım", "deneme çekimine başla"] {
            XCTAssertEqual(VoiceCommand.parse(text), .camera(.trial), text)
        }
        for text in ["kadraj kontrolü", "kadrajı kontrol et", "kadraj kontrolü yap", "kadraj nasıl", "kadraj iyi mi", "kadrajı denetle", "lütfen kadrajı kontrol et"] {
            XCTAssertEqual(VoiceCommand.parse(text), .camera(.viewCheck), text)
        }
    }

    func testTheNewCommandsDoNotStealOtherCommandsOrQuestionText() {
        XCTAssertEqual(VoiceCommand.parse("denemeyi bitir"), .endTest, "Sınav sözü: çekim sözcüğü yok")
        XCTAssertEqual(VoiceCommand.parse("testi bitir"), .endTest)
        XCTAssertEqual(VoiceCommand.parse("kadrajı dikey yap"), .camera(.frame(vertical: true)))
        XCTAssertEqual(VoiceCommand.parse("kadrajı yatay yap"), .camera(.frame(vertical: false)))
        XCTAssertEqual(VoiceCommand.parse("kamera durumu"), .report(.camera))
        for text in ["kadraj nedir", "kadraj", "deneme", "çekim", "deneme çekimi sırasında hangi yöntem kullanılır", "kadraj kontrolü nasıl yapılır",
                     "deneme sınavı çekimi", "çekimi iptal et"] {
            let parsed = VoiceCommand.parse(text)
            if parsed == .camera(.trial) || parsed == .camera(.viewCheck) { XCTFail("Komut sayılmamalıydı: \(text)") }
        }
        XCTAssertTrue(VoiceCommand.camera(.trial).isInfo)
        XCTAssertTrue(VoiceCommand.camera(.viewCheck).isLive)
    }

    // MARK: Video

    func testTheTrialVideoUsesMoreFramesAndABiggerBitrateButTheNormalOneIsUnchanged() {
        XCTAssertEqual(VideoRecorder.bitrate(width: 1920, height: 1080), 1_161_216, "Soru videosu: saniyede 2 kare, eski bit hızı")
        XCTAssertEqual(VideoRecorder.trialFps, 8)
        XCTAssertEqual(VideoRecorder.bitrate(width: 1920, height: 1080, fps: VideoRecorder.trialFps, maxBitrate: VideoRecorder.trialMaxBitrate), 2_500_000)
        XCTAssertEqual(VideoRecorder.bitrate(width: 640, height: 360, fps: VideoRecorder.trialFps, maxBitrate: VideoRecorder.trialMaxBitrate), 516_096)
    }

    // MARK: Depo

    private func trialShot(withVideo video: Bool = true) -> CapturedQuestion {
        var shot = FakeCamera.page(5, photos: 12)
        shot.date = Date(timeIntervalSince1970: 1_800_000_000)
        if video {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("deneme-\(UUID().uuidString).mp4")
            try? Data([0, 1, 2, 3]).write(to: url)
            shot.video = url
            shot.videoBytes = 4
            shot.videoSeconds = 75
        }
        return shot
    }

    func testATrialIsWrittenToItsOwnFolderAndNeverMixesWithTheQueueOfShotsForGemini() throws {
        let root = makeTempFolder("g526-deneme").appendingPathComponent("Cekimler", isDirectory: true)
        let store = FileCaptureStore(root: root)
        store.prepare()
        let shot = trialShot()
        let source = try XCTUnwrap(shot.video)
        let folder = try XCTUnwrap(store.keepTrial(shot, report: "Deneme çekimi raporu\n\nSüre: 75 sn"))
        let fm = FileManager.default
        XCTAssertEqual(folder.deletingLastPathComponent().lastPathComponent, "Deneme")
        XCTAssertEqual(Set(try fm.contentsOfDirectory(atPath: folder.path)), ["foto.jpg", "sayfalar.pdf", "rapor.txt", "video.mp4"])
        XCTAssertFalse(fm.fileExists(atPath: source.path), "Geçici video klasöre TAŞINIR")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("rapor.txt")), "Deneme çekimi raporu\n\nSüre: 75 sn")
        let summary = store.summary()
        XCTAssertEqual(summary.trials, 1)
        XCTAssertEqual(summary.pending, 0, "Deneme gönderilecekler arasına girmez")
        XCTAssertEqual(summary.sent, 0)
        XCTAssertTrue(summary.text.contains("deneme 1"), summary.text)
        XCTAssertEqual(summary.total, 1)
        XCTAssertTrue(store.restorePending().isEmpty, "Uygulama yeniden açılınca deneme Gemini'ye gönderilecekler arasında çıkmaz")
        XCTAssertEqual(FileCaptureStore.Bucket.allCases.map { $0.rawValue }, ["Bekleyen", "Gonderilen", "Gonderilemeyen", "Paragraf"], "Deneme bölüm değildir")
    }

    func testTheSummaryTextStaysTheSameWhenThereIsNoTrial() {
        XCTAssertEqual(CaptureFolderSummary(pending: 1, sent: 2, unsendable: 3, passages: 4, bytes: 500_000).text,
                       "Bekleyen 1, gönderilen 2, gönderilemeyen 3, paragraf 4 · 500 KB")
    }

    func testDeletingAndCountingByDateAlsoReachTheTrials() throws {
        let root = makeTempFolder("g526-deneme-sil").appendingPathComponent("Cekimler", isDirectory: true)
        let store = FileCaptureStore(root: root)
        store.prepare()
        var old = trialShot(withVideo: false)
        old.date = Date(timeIntervalSince1970: 1_700_000_000)
        var recent = trialShot(withVideo: false)
        recent.date = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNotNil(store.keepTrial(old, report: "a"))
        XCTAssertNotNil(store.keepTrial(recent, report: "b"))
        XCTAssertEqual(store.count(since: nil), 2)
        XCTAssertEqual(store.count(since: Date(timeIntervalSince1970: 1_750_000_000)), 1, "Süreli aralıkta yalnız yeni deneme")
        XCTAssertEqual(store.delete(since: Date(timeIntervalSince1970: 1_750_000_000)), 1)
        XCTAssertEqual(store.summary().trials, 1)
        XCTAssertEqual(store.deleteAll(), 1)
        XCTAssertEqual(store.summary().trials, 0)
        XCTAssertEqual(store.summary(), CaptureFolderSummary())
    }

    func testAStoreThatKeepsNothingDropsTheTrialVideoInsteadOfLeavingItBehind() throws {
        let shot = trialShot()
        let source = try XCTUnwrap(shot.video)
        XCTAssertNil(NoCaptureStore().keepTrial(shot, report: "x"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    // MARK: Oturum

    private func series(photos: Int = 16, readable: Bool = true, seen: [Int] = [], diagnosis: CaptureDiagnosis? = nil) -> Result<PageSeries, CameraFailure> {
        return .success(PageSeries(shot: FakeCamera.page(1, photos: photos, seen: seen), planned: photos, failure: nil, readable: readable, diagnosis: diagnosis))
    }

    private func harness(seriesResults: [Result<PageSeries, CameraFailure>] = [],
                         pageReplies: [Result<[GeminiReply], Error>] = [],
                         archive: Bool = true) -> SessionHarness {
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

    private func say(_ h: SessionHarness, _ text: String) {
        h.listener.say(text)
        h.scheduler.advance(by: T.numberConfirm + 0.1)
    }

    private func questionOpen(_ h: SessionHarness) -> Bool {
        return h.vm.listenMode == .cameraChoice && h.vm.phase == .listening
    }

    private var readableText: TextScore {
        var text = TextScore()
        text.chars = SeriesSelection.minChars + 200
        text.confidence = 0.9
        text.options = ["A", "B", "C"]
        text.questionNumbers = [4]
        return text
    }

    func testTheViewCheckSpeaksTheVerdictAndTheCameraKeepsWaitingForStart() async {
        let h = harness()
        h.camera.viewChecks = [ViewCheck(frames: 12, sharpness: 300, text: readableText)]
        _ = await h.startListening()
        say(h, "kadraj kontrolü")
        let done = await waitUntil(45) { h.speaker.spoken.last == CaptureSay.viewGood && self.questionOpen(h) }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        XCTAssertEqual(h.camera.viewCheckCalls, 1)
        XCTAssertTrue(h.camera.holding, "Kamera açık bekler: çekim başlamadı")
        XCTAssertEqual(h.camera.seriesCalls.count, 0)
        XCTAssertEqual(h.camera.trialCalls.count, 0)
        XCTAssertEqual(h.answering.pageCalls.count, 0)
    }

    func testTheViewCheckOfABlurryViewTellsTheUserToStepBack() async {
        let h = harness()
        h.camera.viewChecks = [ViewCheck(frames: 12, sharpness: 15, text: TextScore())]
        _ = await h.startListening()
        say(h, "kadrajı kontrol et")
        let done = await waitUntil(45) { h.speaker.spoken.last == CaptureSay.viewBlurry && self.questionOpen(h) }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
    }

    func testTheViewCheckWithoutAWaitingCameraSaysItNeedsOne() async {
        let h = SessionHarness()
        _ = await h.startListening()
        say(h, "kadraj kontrolü")
        let done = await waitUntil(45) { h.speaker.spoken.last == CaptureSay.viewNotReady && h.vm.phase == .listening && h.vm.listenMode == .question }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        XCTAssertEqual(h.camera.viewCheckCalls, 0, "Kamera hazır bekleyen durumda değil: bakılmaz")
    }

    func testTheTrialIsRecordedToTheFolderNeverSentToGeminiAndTheCameraIsPreparedAgain() async throws {
        let h = harness()
        let report = "Deneme çekimi raporu\n\nSüre: 75 sn"
        let measured = CaptureDiagnosis(windows: 40, readableWindows: 30, medianSharpness: 200, questionNumbers: [1, 2, 3])
        h.camera.trialResults = [.success(PageSeries(shot: trialShotWithVideo(), planned: 12, failure: nil, readable: true, diagnosis: measured, report: report))]
        _ = await h.startListening()
        say(h, "deneme çekimi")
        let ask = Say.askCameraSeries(seconds: 60)
        let done = await waitUntil(60) { h.camera.trialCalls.count == 1 && h.speaker.spoken.last == ask && self.questionOpen(h) }
        XCTAssertTrue(done, "\(h.speaker.spoken) \(h.events)")
        XCTAssertEqual(h.camera.trialCalls.first?.seconds, 60)
        XCTAssertEqual(h.camera.trialHeldAtStart, [true], "Deneme hazır bekleyen bağlantıyla başladı")
        XCTAssertEqual(h.camera.seriesCalls.count, 0, "Gerçek çekim değil")
        XCTAssertEqual(h.answering.pageCalls.count, 0, "Gemini'ye hiçbir şey gitmez")
        XCTAssertEqual(h.answering.captureCalls.count, 0)
        XCTAssertEqual(h.shortcuts.runs.filter { $0 == "Hücresele_Gec" }.count, 0, "İnternet gerekmez: internete dönülmez")
        let spoken = h.speaker.spoken
        XCTAssertTrue(spoken.contains(CaptureSay.trialIntro(seconds: 60)), "\(spoken)")
        XCTAssertTrue(spoken.contains(CaptureSay.trialDone("")), "Sorun yoksa \"bu kadrajla çekim yapılabilir\" denir: \(spoken)")
        XCTAssertTrue(h.vm.questions.isEmpty, "Soru numarası tüketilmez")
        XCTAssertEqual(h.vm.answers.count, 0)
        XCTAssertTrue(h.vm.pendingShots.isEmpty)
        let store = try XCTUnwrap(h.fileStore)
        let summary = store.summary()
        XCTAssertEqual(summary.trials, 1)
        XCTAssertEqual(summary.pending, 0)
        XCTAssertEqual(summary.sent, 0)
        let folder = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: store.trialRoot, includingPropertiesForKeys: nil).first)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("rapor.txt")), report)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("video.mp4").path))
        XCTAssertTrue(h.camera.holding, "Gerçek çekim için kamera yeniden hazır")
    }

    private func trialShotWithVideo() -> CapturedQuestion {
        var shot = FakeCamera.page(5, photos: 12)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("deneme-\(UUID().uuidString).mp4")
        try? Data([0, 1, 2, 3]).write(to: url)
        shot.video = url
        shot.videoBytes = 4
        shot.videoSeconds = 75
        return shot
    }

    func testTheTrialSpeaksWhatWentWrongWithTheViewAndStillRecords() async {
        let h = harness()
        let blurry = CaptureDiagnosis(windows: 40, readableWindows: 0, medianSharpness: 12, questionNumbers: [])
        h.camera.trialResults = [.success(PageSeries(shot: trialShotWithVideo(), planned: 12, failure: nil, readable: false, diagnosis: blurry, report: "rapor"))]
        _ = await h.startListening()
        say(h, "deneme çekimi")
        let done = await waitUntil(60) { h.camera.trialCalls.count == 1 && h.speaker.spoken.last == Say.askCameraSeries(seconds: 60) && self.questionOpen(h) }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        XCTAssertTrue(h.speaker.spoken.contains(CaptureSay.trialDone(CaptureSay.blurry)), "\(h.speaker.spoken)")
        XCTAssertEqual(h.fileStore?.summary().trials, 1)
    }

    func testATrialThatFailsSaysSoAndTheCameraIsPreparedAgain() async {
        let h = harness()
        h.camera.trialResults = [.failure(.noFrames)]
        _ = await h.startListening()
        say(h, "deneme çekimi")
        let done = await waitUntil(60) { h.camera.trialCalls.count == 1 && h.speaker.spoken.last == Say.askCameraSeries(seconds: 60) && self.questionOpen(h) }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        XCTAssertTrue(h.speaker.spoken.contains(CaptureSay.trialFailed + " " + CameraFailure.noFrames.message), "\(h.speaker.spoken)")
        XCTAssertEqual(h.fileStore?.summary().trials, 0)
        XCTAssertEqual(h.answering.pageCalls.count, 0)
    }

    func testTheTrialCommandIsRefusedWhenNoCameraIsWaiting() async {
        let h = SessionHarness()
        _ = await h.startListening()
        say(h, "deneme çekimi")
        let done = await waitUntil(45) { h.speaker.spoken.last == CaptureSay.trialNotReady && h.vm.phase == .listening && h.vm.listenMode == .question }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        XCTAssertEqual(h.camera.trialCalls.count, 0)
    }

    // MARK: Gerçek çekimin teşhisi ve cevaplanmayan sorular

    func testTheDiagnosisOfARealCaptureIsSpokenRightAfterTheDoneSentence() async {
        let blurry = CaptureDiagnosis(windows: 40, readableWindows: 0, medianSharpness: 12, questionNumbers: [])
        let h = harness(seriesResults: [series(photos: 16, readable: false, diagnosis: blurry)], pageReplies: [.success([FakeAnswering.reply(1)])])
        _ = await h.startListening()
        say(h, "başla")
        let done = await waitUntil(45) { h.vm.answers.count == 1 && self.questionOpen(h) }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        let expected = Say.seriesDone(taken: 16, planned: 16, readable: false) + " " + CaptureSay.blurry
        XCTAssertTrue(h.speaker.spoken.contains(expected), "\(h.speaker.spoken)")
        XCTAssertEqual(h.answering.pageCalls.count, 1, "Sorun söylense de çekim Gemini'ye gider")
    }

    func testACaptureWithoutAProblemSaysNothingExtra() async {
        let fine = CaptureDiagnosis(windows: 40, readableWindows: 36, medianSharpness: 250, questionNumbers: [1, 2, 3])
        let h = harness(seriesResults: [series(photos: 16, diagnosis: fine)], pageReplies: [.success([FakeAnswering.reply(1), FakeAnswering.reply(2), FakeAnswering.reply(3)])])
        _ = await h.startListening()
        say(h, "başla")
        let done = await waitUntil(45) { h.vm.answers.count == 3 && self.questionOpen(h) }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        XCTAssertTrue(h.speaker.spoken.contains(Say.seriesDone(taken: 16, planned: 16, readable: true)), "\(h.speaker.spoken)")
        XCTAssertFalse(h.speaker.spoken.contains { $0.contains("cevaplanamadı") || $0.contains("görünmedi") }, "\(h.speaker.spoken)")
    }

    func testAQuestionGeminiSkippedIsSpokenAfterTheAnswersAndBeforeTheNextInstruction() async {
        let h = harness(seriesResults: [series(photos: 16, seen: [1, 2, 3, 4])],
                        pageReplies: [.success([FakeAnswering.reply(1), FakeAnswering.reply(2), FakeAnswering.reply(4)])])
        _ = await h.startListening()
        say(h, "başla")
        let ask = Say.askCameraSeries(seconds: 60)
        let done = await waitUntil(45) { h.vm.answers.count == 3 && h.speaker.spoken.last == ask && self.questionOpen(h) }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        let spoken = h.speaker.spoken
        let last = spoken.firstIndex(of: "Soru 4, Denizli, Örgütsel Davranış")
        let note = spoken.firstIndex(of: CaptureSay.missingAnswers([3]))
        XCTAssertNotNil(last, "\(spoken)")
        XCTAssertNotNil(note, "Cevap numaraları arasında 3 atlandı: \(spoken)")
        if let last = last, let note = note {
            XCTAssertEqual(note, last + 1, "Not, son cevabın hemen ardından söylenir")
            XCTAssertEqual(spoken.last, ask, "Sonra sıradaki oturumun talimatı gelir")
        }
        XCTAssertEqual(h.vm.answers.count, 3, "Cevaplar etkilenmez")
    }

    func testTheSkippedQuestionNoteDoesNotCarryOverToTheNextPage() async {
        let h = harness(seriesResults: [series(photos: 16, seen: [1, 2, 3, 4]), series(photos: 16, seen: [5, 6])],
                        pageReplies: [.success([FakeAnswering.reply(1), FakeAnswering.reply(2), FakeAnswering.reply(4)]),
                                      .success([FakeAnswering.reply(5), FakeAnswering.reply(6)])])
        _ = await h.startListening()
        say(h, "başla")
        let first = await waitUntil(45) { h.vm.answers.count == 3 && self.questionOpen(h) }
        XCTAssertTrue(first, "\(h.speaker.spoken)")
        say(h, "başla")
        let second = await waitUntil(45) { h.vm.answers.count == 5 && self.questionOpen(h) }
        XCTAssertTrue(second, "\(h.speaker.spoken)")
        XCTAssertEqual(h.speaker.spoken.filter { $0 == CaptureSay.missingAnswers([3]) }.count, 1, "Not yalnız ilk sayfa için, bir kez söylenir")
    }
}
