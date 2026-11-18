import XCTest
import CoreVideo
@testable import G526CameraDrive

/// Serbest tarama (kullanıcı kararı 2026-11-18 akşam, ilk cihaz denemesinden sonra): bölüm / köşe / sıra tarifi ve "tüm sayfa" çekimi yoktur. Oturum 60 sn,
/// hedef 2 sayfa; program komut vermez, her 10 saniyede geçen süreyi söyler; saniyede 2 kare alınır (en çok 120). Her 30 saniyenin sonunda sayfa denetimi:
/// iyiyse sonraki sayfaya geçilmesi, kötüyse (blok bozulması / bulanıklık) sayfanın yeniden taranması istenir. Kötü görüntü saklanmaz. Cihazda doğrulanmadı.
final class SeriesRhythmTests: XCTestCase {
    private let rhythm = SeriesRhythm.standard

    func testTheSessionIsSixtySecondsAndTakesTwoFramesASecond() {
        XCTAssertEqual(rhythm.pageSeconds, 10, "Dilim 10 sn: her dilim başında süre söylenir")
        XCTAssertEqual(rhythm.pages(in: 60), 6)
        XCTAssertEqual(rhythm.roundedSeconds(60), 60)
        XCTAssertEqual(rhythm.roundedSeconds(65), 60, "Süre 10 sn'lik dilimlere tamamlanır")
        XCTAssertEqual(rhythm.roundedSeconds(3), 10)
        XCTAssertEqual(CameraSettings.defaultSeriesSeconds, 60)
        XCTAssertEqual(SeriesRhythm.framesPerSlot * rhythm.pages(in: 60), 120, "60 saniyede en çok 120 kare")
        XCTAssertEqual(CameraSettings.seriesSecondsRange, 30...180)
        XCTAssertEqual(CameraSettings.seriesSecondsStep, 10)
    }

    func testEveryMomentOfTheSessionIsScanningWithoutSettleOrPageTurnGaps() {
        XCTAssertEqual(rhythm.position(at: 0)?.part, .scan)
        XCTAssertEqual(rhythm.position(at: 9.9)?.page, 1)
        XCTAssertEqual(rhythm.position(at: 10)?.page, 2)
        XCTAssertEqual(rhythm.position(at: 10)?.part, .scan)
        XCTAssertEqual(rhythm.position(at: 59.9)?.page, 6)
        XCTAssertNil(rhythm.position(at: -1))
        XCTAssertEqual(rhythm.shotSlot(at: 0)?.sub, 0, "Dilim başında kare atlanmaz")
        XCTAssertEqual(rhythm.shotSlot(at: 0.49)?.sub, 0)
        XCTAssertEqual(rhythm.shotSlot(at: 0.5)?.sub, 1, "Her yarım saniye ayrı bir karedir")
        XCTAssertEqual(rhythm.shotSlot(at: 9.9)?.sub, 19)
        XCTAssertEqual(rhythm.shotSlot(at: 10.2)?.sub, 0)
        XCTAssertNotEqual(rhythm.shotSlot(at: 0.2)?.index, rhythm.shotSlot(at: 10.2)?.index)
    }

    func testOnlyTheElapsedSecondsAreSpokenEveryTenSeconds() {
        XCTAssertNil(rhythm.cue(at: 0, totalPages: 6), "Başta yalnız \"Başladı\" denir")
        XCTAssertEqual(rhythm.cue(at: 10, totalPages: 6), "10 saniye.")
        XCTAssertEqual(rhythm.cue(at: 50, totalPages: 6), "50 saniye.")
        XCTAssertNil(rhythm.cue(at: 5, totalPages: 6))
        var cues: [String] = []
        for second in 0..<60 { if let c = rhythm.cue(at: Double(second), totalPages: 6) { cues.append(c) } }
        XCTAssertEqual(cues, ["10 saniye.", "20 saniye.", "30 saniye.", "40 saniye.", "50 saniye."], "Yön, bölüm ya da sayfa çevirme komutu yoktur")
    }

    func testTheLabelNamesTheTimeRangeAndTheFrame() {
        XCTAssertEqual(SeriesRhythm.label(page: 1, part: .scan), "0–10. saniye")
        XCTAssertEqual(SeriesRhythm.label(page: 2, part: .scan, sub: 1), "10–20. saniye, 2. kare")
        let third = SeriesRhythm.slotIndex(page: 3, part: .scan)
        XCTAssertEqual(SeriesRhythm.slot(index: third)?.page, 3)
        XCTAssertEqual(SeriesRhythm.slot(index: third)?.part, .scan)
    }

    func testAPageIsBadWhenFewFramesAreValid() {
        XCTAssertEqual(SeriesRhythm.reviewSeconds, 30)
        XCTAssertTrue(SeriesRhythm.pageIsBad(valid: 0, damaged: 0, blurry: 0), "Hiç kare gelmedi")
        XCTAssertTrue(SeriesRhythm.pageIsBad(valid: 9, damaged: 0, blurry: 0), "On kareden az")
        XCTAssertTrue(SeriesRhythm.pageIsBad(valid: 12, damaged: 20, blurry: 20), "Karelerin üçte birinden azı geçerli")
        XCTAssertFalse(SeriesRhythm.pageIsBad(valid: 30, damaged: 5, blurry: 5))
        XCTAssertFalse(SeriesRhythm.pageIsBad(valid: 20, damaged: 20, blurry: 19))
    }

    func testTheReviewTellsTheReasonOrSendsTheUserToTheNextPage() {
        XCTAssertEqual(SeriesRhythm.reviewText(page: 1, damaged: 8, blurry: 3), "Birinci sayfa okunamadı: blok bozulmaları ve bulanıklık var. Bu sayfayı yeniden, yavaşça tarayın.")
        XCTAssertTrue(SeriesRhythm.reviewText(page: 2, damaged: 1, blurry: 9).contains("bulanıklık ve blok bozulmaları var"))
        XCTAssertTrue(SeriesRhythm.reviewText(page: 1, damaged: 0, blurry: 4).contains("bulanıklık var"))
        XCTAssertTrue(SeriesRhythm.reviewText(page: 1, damaged: 4, blurry: 0).contains("blok bozulmaları var"))
        XCTAssertTrue(SeriesRhythm.reviewText(page: 1, damaged: 0, blurry: 0).contains("yeterli görüntü gelmedi"))
        XCTAssertEqual(SeriesRhythm.nextPageText(page: 1, good: true), "Birinci sayfa tamam. Sonraki sayfaya geçin.")
        XCTAssertTrue(SeriesRhythm.nextPageText(page: 1, good: false).contains("Sonraki sayfaya geçin"))
    }
}

final class SlotBestTests: XCTestCase {
    func testTheBestFrameOfEachSlotIsReturnedWhenTheNextSlotStarts() {
        var best = SlotBest<String>()
        XCTAssertNil(best.offer(slot: 1, score: 5, payload: "a"))
        XCTAssertNil(best.offer(slot: 1, score: 9, payload: "b"))
        XCTAssertNil(best.offer(slot: 1, score: 7, payload: "c"))
        XCTAssertEqual(best.offer(slot: 2, score: 1, payload: "d"), "b", "Dilim 1'in en netliği")
        XCTAssertNil(best.offer(slot: 1, score: 99, payload: "late"), "Eski dilime geç gelen kare yok sayılır")
        XCTAssertEqual(best.flush(), "d")
        XCTAssertNil(best.flush())
    }
}

/// Kare kimliği 50 ve üstü: yazısı okunan kare (120 harf); 50'nin altı: yazısı okunmayan kare (5 harf)
final class ScanCollectorTests: XCTestCase {
    private func buffer(id: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 8 + id, 4, kCVPixelFormatType_32BGRA, nil, &pb)
        return pb!
    }

    private func collector(_ t0: Double, clock: RhythmClock? = nil) -> SeriesCollector {
        return SeriesCollector(start: t0, clock: clock ?? RhythmClock(pages: 6),
                               reader: { buffer in
                                   let id = CVPixelBufferGetWidth(buffer) - 8
                                   var t = TextScore()
                                   t.chars = id < 50 ? 5 : 120
                                   t.confidence = 0.9
                                   t.words = Set(["aynı", "sayfa", "kelimeleri", "burada"])   // hepsi AYNI yazı: klasik seçim bunları tek kare yapardı
                                   return t
                               },
                               renderer: { buffer in (data: Data([UInt8(CVPixelBufferGetWidth(buffer) - 8)]), width: 1920, height: 1080) })
    }

    private let signature = [UInt8](repeating: 100, count: 576)
    private let other = [UInt8](repeating: 220, count: 576)
    private var damaged: Double { return FrameAnalysis.damagedBlockiness + 0.5 }

    func testTheSharpestFrameOfEveryHalfSecondIsKeptEvenWhenAllLookTheSame() async {
        let t0 = 5000.0
        let c = collector(t0)
        c.offer(buffer: buffer(id: 51), time: t0 + 0.1, sharpness: 100, signature: signature)
        c.offer(buffer: buffer(id: 52), time: t0 + 0.3, sharpness: 200, signature: signature)   // aynı yarım saniye, daha net
        c.offer(buffer: buffer(id: 53), time: t0 + 0.6, sharpness: 100, signature: signature)
        c.offer(buffer: buffer(id: 54), time: t0 + 1.2, sharpness: 100, signature: signature)
        c.offer(buffer: buffer(id: 55), time: t0 + 10.2, sharpness: 100, signature: signature)
        let outcome = await c.finish()
        XCTAssertEqual(outcome.items.map { $0.jpeg.first }, [52, 53, 54, 55], "Her yarım saniyenin en neti; aynı görünüm diye birleşmez")
        XCTAssertEqual(outcome.stats.merged, 0)
        XCTAssertEqual(outcome.stats.busySkipped, 0)
        XCTAssertEqual(outcome.labels, ["0–10. saniye, 1. kare", "0–10. saniye, 2. kare", "0–10. saniye, 3. kare", "10–20. saniye, 1. kare"])
    }

    func testBadFramesAreNotKept() async {
        let t0 = 6000.0
        let c = collector(t0)
        c.offer(buffer: buffer(id: 51), time: t0 + 0.1, sharpness: 100, signature: signature)
        c.offer(buffer: buffer(id: 52), time: t0 + 0.6, sharpness: 900, signature: signature, blockiness: damaged)   // bozuk
        c.offer(buffer: buffer(id: 10), time: t0 + 1.1, sharpness: 100, signature: other)                             // oynarken, yazısı okunmuyor: bulanık
        c.offer(buffer: buffer(id: 53), time: t0 + 12.1, sharpness: 100, signature: signature)
        c.offer(buffer: buffer(id: 54), time: t0 + 25.1, sharpness: 900, signature: signature, blockiness: damaged)   // bu dilimde yalnız bozuk var: yine gitmez
        let outcome = await c.finish()
        XCTAssertEqual(outcome.items.map { $0.jpeg.first }, [51, 53], "Kötü görüntü saklanmaz: bozuk ve bulanık kareler gönderilmez")
        XCTAssertEqual(outcome.labels, ["0–10. saniye, 1. kare", "10–20. saniye, 5. kare"])
    }

    func testWhenNothingIsGoodTheBadFramesStillGoWithANoteSoTheShotIsNotEmpty() async {
        let t0 = 7000.0
        let c = collector(t0)
        c.offer(buffer: buffer(id: 51), time: t0 + 0.1, sharpness: 100, signature: signature, blockiness: damaged)
        c.offer(buffer: buffer(id: 10), time: t0 + 0.6, sharpness: 100, signature: other)
        let outcome = await c.finish()
        XCTAssertEqual(outcome.items.count, 2)
        XCTAssertEqual(outcome.labels, ["0–10. saniye, 1. kare (bozuk kare)", "0–10. saniye, 2. kare (bulanık kare)"])
    }

    func testAMovingCameraIsFineWhenTheTextIsStillReadable() async {
        let t0 = 8000.0
        let c = collector(t0)
        c.offer(buffer: buffer(id: 51), time: t0 + 0.1, sharpness: 100, signature: signature)
        c.offer(buffer: buffer(id: 52), time: t0 + 0.6, sharpness: 100, signature: other)
        c.offer(buffer: buffer(id: 53), time: t0 + 1.1, sharpness: 100, signature: signature)
        let outcome = await c.finish()
        XCTAssertEqual(outcome.items.count, 3, "Kamera kaydırılırken alınan, yazısı okunan kare bulanık sayılmaz (gerçek günlük 2026-11-18)")
    }

    func testThePageReviewCountsTheFramesOfItsOwnThirtySeconds() async {
        let t0 = 9000.0
        let c = collector(t0)
        c.offer(buffer: buffer(id: 51), time: t0 + 0.1, sharpness: 100, signature: signature)
        c.offer(buffer: buffer(id: 52), time: t0 + 0.6, sharpness: 100, signature: signature, blockiness: damaged)
        c.offer(buffer: buffer(id: 10), time: t0 + 1.1, sharpness: 100, signature: other)
        c.offer(buffer: buffer(id: 53), time: t0 + 31.0, sharpness: 100, signature: signature)
        await c.settle()
        let first = c.quality(from: 0, to: 30)
        XCTAssertEqual(first.valid, 1)
        XCTAssertEqual(first.damaged, 1)
        XCTAssertEqual(first.blurry, 1)
        XCTAssertEqual(c.quality(from: 30, to: 60).valid, 1)
        XCTAssertEqual(c.quality(from: 30, to: 60).damaged, 0)
    }

    func testARescannedPageReplacesItsBadFrames() async {
        let t0 = 10000.0
        let clock = RhythmClock(pages: 6)
        let c = collector(t0, clock: clock)
        c.offer(buffer: buffer(id: 51), time: t0 + 0.1, sharpness: 100, signature: signature, blockiness: damaged)
        await c.settle()
        XCTAssertTrue(SeriesRhythm.pageIsBad(valid: c.quality(from: 0, to: 30).valid, damaged: 1, blurry: 0))
        clock.redo(seconds: 30)
        XCTAssertEqual(clock.totalSeconds, 90, "Yeniden taranan sayfa oturumu 30 sn uzatır")
        XCTAssertEqual(clock.offset, 30)
        // saat 30 sn geri alındı: oturumun 30. saniyesi yine sayfanın başı
        c.offer(buffer: buffer(id: 52), time: t0 + 30.1, sharpness: 100, signature: signature)
        XCTAssertEqual(clock.step(at: 40, problem: { _ in nil }), .cue("10 saniye."), "Süre anonsu yeniden taramayla baştan sayar")
        let outcome = await c.finish()
        XCTAssertEqual(outcome.items.map { $0.jpeg.first }, [52], "İlk taramanın bozuk karesi gitmez, yeniden taramanın temiz karesi gider")
        XCTAssertEqual(outcome.labels, ["0–10. saniye, 1. kare"])
    }

    func testTheClockWaitsWhileNoFramesArrive() {
        let t0 = 11000.0
        let clock = RhythmClock(pages: 6)
        let c = collector(t0, clock: clock)
        XCTAssertEqual(c.secondsSinceFrame(now: t0 + 2), 2, accuracy: 0.001)
        c.offer(buffer: buffer(id: 51), time: t0 + 5, sharpness: 100, signature: signature)
        XCTAssertEqual(c.secondsSinceFrame(now: t0 + 9), 4, accuracy: 0.001)
        XCTAssertTrue(clock.hold())
        XCTAssertEqual(clock.totalSeconds, 61, "Bekletilen her saniye oturumu uzatır")
        for _ in 0..<40 { clock.hold() }
        XCTAssertEqual(clock.totalSeconds, 80, "En çok 20 sn bekletilir")
        XCTAssertFalse(clock.hold())
        XCTAssertEqual(clock.maxExtraSeconds, 80, "20 sn bekleme + her sayfanın bir kez yeniden taranması")
    }

    func testNoRepeatCommandsAreGivenDuringTheScan() {
        let clock = RhythmClock(pages: 6)
        XCTAssertEqual(clock.step(at: 10, problem: { _ in .damaged }), .cue("10 saniye."), "Çekim sırasında \"tekrar gösterin\" denmez; hüküm sayfa sonunda verilir")
        XCTAssertEqual(clock.step(at: 11, problem: { _ in .damaged }), .silent)
        XCTAssertEqual(clock.offset, 0)
        let strict = RhythmClock(pages: 6, maxPerSlot: 1, maxTotal: 1)
        guard case .retry(let text, _, let attempt) = strict.step(at: 10, problem: { _ in .damaged }) else { return XCTFail("Sınır verilince tekrar düzeneği çalışır") }
        XCTAssertEqual(attempt, 1)
        XCTAssertTrue(text.contains("bozuldu"))
        XCTAssertEqual(strict.offset, 10)
    }

    func testTheClassicCollectorStaysUnlabeled() async {
        let t0 = 12000.0
        let c = SeriesCollector(start: t0, maxPending: 1000, reader: { _ in nil },
                                renderer: { buffer in (data: Data([UInt8(CVPixelBufferGetWidth(buffer) - 8)]), width: 10, height: 10) })
        c.offer(buffer: buffer(id: 1), time: t0 + 0.1, sharpness: 150, signature: signature)
        let outcome = await c.finish()
        XCTAssertEqual(outcome.labels, [], "Serbest tarama kapalıyken etiket yoktur")
    }
}

final class SlotCheckTests: XCTestCase {
    private func lines(chars: Int, complete: Int = 0) -> ViewLines {
        var l = ViewLines()
        l.chars = chars
        l.completeQuestions = complete
        return l
    }

    func testDamagedAndUnreadableMovingFramesAreNotValid() {
        XCTAssertEqual(SlotCheck.problem(damaged: true, still: true, part: .scan, lines: nil, chars: 500), .damaged)
        XCTAssertEqual(SlotCheck.problem(damaged: false, still: false, part: .scan, lines: nil, chars: 20), .blurry, "Kamera oynuyor ve yazı okunmuyor")
        XCTAssertEqual(SlotCheck.problem(damaged: false, still: false, part: .scan, lines: nil), .blurry)
        XCTAssertEqual(SlotCheck.problem(damaged: false, still: true, part: .scan, lines: lines(chars: 5), chars: 5), .blurry, "Durgun ama yazı okunmuyor")
    }

    func testReadableFramesAreValidWhateverTheMotionAndWithoutAWholeQuestion() {
        XCTAssertNil(SlotCheck.problem(damaged: false, still: false, part: .scan, lines: nil, chars: 300), "Yazısı okunan kare, kamera oynasa da bulanık değildir")
        XCTAssertNil(SlotCheck.problem(damaged: false, still: true, part: .scan, lines: nil), "Yazı okuma çalışmadıysa kare yalnız bu yüzden elenmez")
        XCTAssertNil(SlotCheck.problem(damaged: false, still: true, part: .scan, lines: lines(chars: 400), chars: 400), "Tek karede sorunun tamamı aranmaz: komşu karelerle tamamlanır")
    }
}

@MainActor
final class ScanPromptTests: XCTestCase {
    func testTheLabelsAreListedInThePromptInPdfOrder() {
        let labels = ["0–10. saniye, 1. kare", "0–10. saniye, 2. kare", "10–20. saniye, 1. kare"]
        let text = GeminiAnswerService.pageText(expectedNumber: 1, hasVideo: false, extra: "", pages: 3, labels: labels)
        XCTAssertTrue(text.contains("1) 0–10. saniye, 1. kare; 2) 0–10. saniye, 2. kare; 3) 10–20. saniye, 1. kare"), text)
        XCTAssertTrue(text.contains("Çekim serbest taramaydı"))
        XCTAssertTrue(text.contains("saniyede İKİ kare"))
        XCTAssertTrue(text.contains("aynı soruyu ya da satırı birden çok kez sayma"))
        XCTAssertTrue(text.contains("ETİKETLER YALNIZ İPUCUDUR"), "Gemini etikete değil içeriğe güvenir")
        XCTAssertTrue(text.contains("içerikten bul"))
        XCTAssertTrue(GeminiAnswerService.pageSystemPrompt.contains("sırasız göstermiş olabilir"), "Sistem komutu da sırasız çekimi söyler")
    }

    func testWithoutLabelsOrWithAMismatchThePromptStaysAsBefore() {
        let plain = GeminiAnswerService.pageText(expectedNumber: 1, hasVideo: false, extra: "", pages: 5)
        XCTAssertFalse(plain.contains("serbest taramaydı"))
        let mismatch = GeminiAnswerService.pageText(expectedNumber: 1, hasVideo: false, extra: "", pages: 5, labels: ["0–10. saniye, 1. kare"])
        XCTAssertEqual(mismatch, plain, "PDF'teki sayfa sayısı etiket sayısına uymuyorsa etiket kullanılmaz (sıra bozulmuş olabilir)")
    }

    func testTheLabelsSurviveARestartOfThePhone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tarama-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileCaptureStore(root: root)
        store.prepare()
        var shot = CapturedQuestion(photo: Data([1, 2, 3]))
        shot.isPage = true
        shot.rhythmLabels = ["0–10. saniye, 1. kare", "0–10. saniye, 2. kare"]
        _ = store.keep(shot, kind: .page)
        let restored = FileCaptureStore(root: root).restorePending()
        XCTAssertEqual(restored.first?.rhythmLabels, ["0–10. saniye, 1. kare", "0–10. saniye, 2. kare"])
    }
}

/// Üç yenilik birlikte eklendi (kullanıcı isteği 2026-11-18 akşam): büyük PDF'in dosya olarak yüklenmesi, güçlü yazı okuma, hareket takibi. Her biri
/// Ayarlar'dan kapatılabilir. Buradaki testler saf mantığı dener; Gemini'nin dosya yükleme hizmeti, Vision'ın güçlü kipi ve kare hizalaması cihazda doğrulanmadı.
final class PageNumbersTests: XCTestCase {
    func testANumberCountsOnlyWhenReadInTwoFrames() {
        XCTAssertEqual(SeriesRhythm.confirmedNumbers([11: 3, 12: 1, 13: 2, 0: 5]), [11, 13], "Tek karede okunan numara ve 0 sayılmaz")
        XCTAssertEqual(SeriesRhythm.confirmedNumbers([:]), [])
    }

    func testOnlyASingleHoleBetweenTwoSeenNumbersIsMissing() {
        XCTAssertEqual(SeriesRhythm.holes(in: [11, 13]), [12])
        XCTAssertEqual(SeriesRhythm.holes(in: [27, 29, 30]), [28])
        XCTAssertEqual(SeriesRhythm.holes(in: [10, 11, 12, 13, 14, 17]), [], "Ardışık iki eksik kesin değildir: komşu sayfanın numarası kadraja girmiş olabilir")
        XCTAssertEqual(SeriesRhythm.holes(in: [10, 11, 12]), [])
        XCTAssertEqual(SeriesRhythm.holes(in: []), [])
    }

    func testTheSpokenReviewNamesTheSeenQuestionsTheMissingOneAndTheSpeed() {
        XCTAssertEqual(SeriesRhythm.nextPageText(page: 1, good: true, seen: [10, 11, 12, 13, 14]),
                       "Birinci sayfa tamam. Görülen sorular: 10 ile 14 arası. Sonraki sayfaya geçin.")
        XCTAssertTrue(SeriesRhythm.nextPageText(page: 1, good: true, barelyMoved: true).contains("Kamera az kaydırıldı"))
        XCTAssertEqual(SeriesRhythm.missingText(page: 1, missing: [12]), "Birinci sayfada 12. soru görülmedi. Bu sayfayı yeniden tarayın.")
        XCTAssertTrue(SeriesRhythm.missingText(page: 2, missing: [12, 15]).contains("12 ve 15. sorular"))
        XCTAssertEqual(SeriesRhythm.reviewText(page: 1, damaged: 0, blurry: 5, fast: true),
                       "Birinci sayfa okunamadı: bulanıklık var; kamera hızlı kaydırıldı. Bu sayfayı yeniden, daha yavaş tarayın.")
        XCTAssertFalse(SeriesRhythm.reviewText(page: 1, damaged: 5, blurry: 0, fast: true).contains("hızlı"), "Bulanıklık yoksa hız söylenmez")
    }

    func testTheCollectorCountsTheQuestionNumbersOfValidFrames() async {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 4, kCVPixelFormatType_32BGRA, nil, &pb)
        let buffer = pb!
        let t0 = 20000.0
        let signature = [UInt8](repeating: 100, count: 576)
        let c = SeriesCollector(start: t0, clock: RhythmClock(pages: 6),
                                reader: { _ in
                                    var t = TextScore()
                                    t.chars = 200
                                    t.questionNumbers = [12]
                                    return t
                                },
                                renderer: { _ in (data: Data([1]), width: 1920, height: 1080) })
        c.offer(buffer: buffer, time: t0 + 0.1, sharpness: 100, signature: signature)
        c.offer(buffer: buffer, time: t0 + 0.6, sharpness: 100, signature: signature)
        c.offer(buffer: buffer, time: t0 + 1.1, sharpness: 100, signature: signature, blockiness: FrameAnalysis.damagedBlockiness + 0.5)
        await c.settle()
        let q = c.quality(from: 0, to: 30)
        XCTAssertEqual(q.valid, 2)
        XCTAssertEqual(q.damaged, 1)
        XCTAssertEqual(q.numbers[12], 2, "Bozuk karenin numarası sayılmaz")
        XCTAssertEqual(SeriesRhythm.confirmedNumbers(q.numbers), [12])
    }
}

final class MotionTrackerTests: XCTestCase {
    private func buffer() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 8, kCVPixelFormatType_32BGRA, nil, &pb)
        return pb!
    }

    private func samples(_ count: Int, dx: (Int) -> Double, dt: Double = 0.1) -> [MotionTracker.Sample] {
        return (0..<count).map { MotionTracker.Sample(time: Double($0) * dt, dx: dx($0), dy: 0, dt: dt) }
    }

    func testAFastSweepIsReportedAsFast() {
        let s = MotionTracker.summarize(samples(30) { _ in 0.1 }, failures: 2)
        XCTAssertEqual(s.samples, 30)
        XCTAssertEqual(s.failures, 2)
        XCTAssertEqual(s.medianSpeed, 1.0, accuracy: 0.0001)
        XCTAssertEqual(s.fastShare, 1.0, accuracy: 0.0001)
        XCTAssertTrue(s.isFast)
        XCTAssertFalse(s.barelyMoved)
        XCTAssertTrue(s.logText.contains("30 ölçüm"))
    }

    func testACameraThatJittersInOnePlaceBarelyMoved() {
        let s = MotionTracker.summarize(samples(60) { $0 % 2 == 0 ? 0.01 : -0.01 }, failures: 0)
        XCTAssertEqual(s.movingShare, 1.0, accuracy: 0.0001)
        XCTAssertLessThan(s.extentX, 0.05)
        XCTAssertTrue(s.barelyMoved, "Kamera kıpırdıyor ama aynı yerde: sayfanın tamamı taranmamış olabilir")
        XCTAssertFalse(s.isFast)
    }

    func testNoJudgementWhenNothingMovesOrWhenThePageIsSwept() {
        let frozen = MotionTracker.summarize(samples(60) { _ in 0 }, failures: 0)
        XCTAssertFalse(frozen.barelyMoved, "Hiç hareket ölçülmediyse ölçüm çalışmıyor olabilir: hüküm verilmez")
        let sweep = MotionTracker.summarize(samples(60) { _ in 0.02 }, failures: 0)
        XCTAssertEqual(sweep.extentX, 1.2, accuracy: 0.0001)
        XCTAssertFalse(sweep.barelyMoved)
        XCTAssertFalse(sweep.isFast, "Saniyede 0,2 kare boyu: okunaklı hız")
        XCTAssertFalse(MotionTracker.summarize([], failures: 0).isFast)
    }

    func testTheTrackerMeasuresConsecutiveFramesAndIgnoresLongGaps() async {
        let tracker = MotionTracker(align: { _, _ in (dx: 0.05, dy: 0.0) })
        for i in 0..<5 {
            tracker.offer(buffer(), time: 100 + Double(i) * 0.1)
            await tracker.drain()
        }
        tracker.offer(buffer(), time: 105)   // 4,6 sn ara: ölçülmez
        await tracker.drain()
        let s = tracker.summary(from: 100, to: 110)
        XCTAssertEqual(s.samples, 4)
        XCTAssertEqual(s.failures, 0)
        XCTAssertEqual(s.extentX, 0.2, accuracy: 0.0001)
        XCTAssertEqual(s.medianSpeed, 0.5, accuracy: 0.001)
        XCTAssertEqual(tracker.summary(from: 200, to: 210).samples, 0)
    }

    func testFramesThatCannotBeAlignedAreCountedAsFailures() async {
        let tracker = MotionTracker(align: { _, _ in nil })
        for i in 0..<3 {
            tracker.offer(buffer(), time: 50 + Double(i) * 0.1)
            await tracker.drain()
        }
        let s = tracker.summary(from: 50, to: 51)
        XCTAssertEqual(s.samples, 0)
        XCTAssertEqual(s.failures, 2)
    }
}

final class ReadPaceTests: XCTestCase {
    func testAccurateReadingIsKeptWhileThePhoneKeepsUp() {
        let pace = ReadPace(enabled: true)
        XCTAssertTrue(pace.useAccurate)
        for _ in 0..<10 { XCTAssertFalse(pace.record(seconds: 0.2)) }
        XCTAssertTrue(pace.useAccurate)
        XCTAssertEqual(pace.report.count, 10)
        XCTAssertEqual(pace.report.average, 0.2, accuracy: 0.0001)
    }

    func testAccurateReadingIsDroppedOnceWhenItIsTooSlow() {
        let pace = ReadPace(enabled: true)
        XCTAssertFalse(pace.record(seconds: 1.0))
        XCTAssertFalse(pace.record(seconds: 1.0))
        XCTAssertFalse(pace.record(seconds: 1.0))
        XCTAssertTrue(pace.record(seconds: 1.0), "Dört okumanın ortalaması 0,4 sn'yi aştı: hızlı kipe dönülür")
        XCTAssertFalse(pace.useAccurate)
        XCTAssertFalse(pace.record(seconds: 1.0), "Bir kez haber verilir")
        XCTAssertTrue(pace.report.gaveUp)
    }

    func testTheSettingTurnsAccurateReadingOff() {
        XCTAssertFalse(ReadPace(enabled: false).useAccurate)
    }
}

@MainActor
final class LargeUploadTests: XCTestCase {
    func testTheUploadedFileIsReadFromTheUploadReplyAndFromTheStatusReply() {
        let reply = Data(#"{"file":{"name":"files/abc","uri":"https://x/v1beta/files/abc","state":"ACTIVE","mimeType":"application/pdf"}}"#.utf8)
        XCTAssertEqual(GeminiSupport.parseUploadedFile(reply), GeminiUploadedFile(uri: "https://x/v1beta/files/abc", name: "files/abc", state: "ACTIVE"))
        let status = Data(#"{"name":"files/abc","uri":"https://x/v1beta/files/abc","state":"processing"}"#.utf8)
        XCTAssertEqual(GeminiSupport.parseUploadedFile(status)?.state, "PROCESSING")
        XCTAssertEqual(GeminiSupport.parseUploadedFile(Data(#"{"file":{"uri":"u"}}"#.utf8))?.state, "ACTIVE", "Durum yoksa hazır sayılır")
        XCTAssertNil(GeminiSupport.parseUploadedFile(Data(#"{"file":{"name":"files/abc"}}"#.utf8)), "Adres yoksa dosya kullanılamaz")
        XCTAssertNil(GeminiSupport.parseUploadedFile(Data("<html>".utf8)))
    }

    func testTheUploadAddressIsDerivedFromTheApiAddress() {
        XCTAssertEqual(GeminiSupport.uploadURL(base: GeminiConfig.baseURL), "https://generativelanguage.googleapis.com/upload/v1beta/files")
        XCTAssertEqual(GeminiSupport.uploadURL(base: "http://127.0.0.1:8080"), "http://127.0.0.1:8080/upload/v1beta/files")
    }

    func testAnUploadedPdfGoesByAddressAndASmallOneStaysInline() throws {
        let byAddress = GeminiAnswerService.visualPart(photo: Data([1]), pdf: Data([2]), pdfURI: "https://x/files/abc")
        XCTAssertEqual((byAddress["fileData"] as? [String: String])?["fileUri"], "https://x/files/abc")
        XCTAssertEqual((byAddress["fileData"] as? [String: String])?["mimeType"], "application/pdf")
        XCTAssertNil(byAddress["inlineData"])
        XCTAssertNotNil(GeminiAnswerService.visualPart(photo: Data([1]), pdf: Data([2]))["inlineData"])
        XCTAssertNotNil(GeminiAnswerService.visualPart(photo: Data([1]), pdf: nil, pdfURI: "https://x/files/abc")["inlineData"], "PDF yoksa fotoğraf gider")
        var shot = CapturedQuestion(photo: Data([1, 2, 3]))
        shot.isPage = true
        shot.pdf = Data([4, 5, 6])
        shot.pageCount = 3
        let body = try GeminiAnswerService.captureBody(shot, expectedNumber: 1, page: true, pdfURI: "https://x/files/abc")
        let text = String(data: body, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("fileUri"))
        XCTAssertFalse(text.contains("inlineData"), "Yüklenen PDF isteğin içinde yeniden gönderilmez")
    }

    func testBigBodiesGetMoreTimeAndSmallOnesKeepTheOldLimits() {
        XCTAssertEqual(GeminiAnswerService.uploadLimit(bytes: 40_000_000), 300, accuracy: 0.001)
        XCTAssertEqual(GeminiAnswerService.inlineAllowance(bytes: 20_000_000), 0, "Eski boyutlarda bekleme değişmez")
        XCTAssertEqual(GeminiAnswerService.inlineAllowance(bytes: 50_000_000), 250, accuracy: 0.001)
        XCTAssertGreaterThan(PageDocument.largeBudgetBytes, PageDocument.budgetBytes)
        XCTAssertLessThan(PageDocument.largeBudgetBytes, 50_000_000, "Gemini'nin PDF sınırı 50 MB")
    }

    func testTheThreeNewFeaturesAreOnByDefaultAndCanBeTurnedOff() {
        let defaults = UserDefaults(suiteName: "g526.testler.\(UUID().uuidString)")!
        let settings = CameraSettings(defaults: defaults)
        XCTAssertTrue(settings.largeUpload)
        XCTAssertTrue(settings.accurateReading)
        XCTAssertTrue(settings.motionTracking)
        settings.largeUpload = false
        settings.accurateReading = false
        settings.motionTracking = false
        let again = CameraSettings(defaults: defaults)
        XCTAssertFalse(again.largeUpload)
        XCTAssertFalse(again.accurateReading)
        XCTAssertFalse(again.motionTracking)
    }
}
