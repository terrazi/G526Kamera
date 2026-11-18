import XCTest
import CoreVideo
@testable import G526CameraDrive

/// Ritimli toplu çekim (kullanıcı kararı 2026-11-18): her sayfa için tüm sayfa → üst → orta üst → orta alt → alt (dilim başına 4 sn) → sayfa çevirme (5 sn);
/// sayfa başına 25 sn, 125 sn = 5 sayfa. Her dilimin en net karesi alınır, dilimin ilk 1,5 sn'si sayılmaz, kareler etiketle Gemini'ye gider.
/// Cihazda doğrulanmadı.
final class SeriesRhythmTests: XCTestCase {
    private let rhythm = SeriesRhythm.standard

    func testAPageTakesTwentyFiveSecondsAndTheDefaultSessionIsFivePages() {
        XCTAssertEqual(rhythm.pageSeconds, 25)
        XCTAssertEqual(rhythm.pages(in: 125), 5)
        XCTAssertEqual(rhythm.roundedSeconds(125), 125)
        XCTAssertEqual(rhythm.roundedSeconds(130), 125, "Yarım sayfa bırakılmaz")
        XCTAssertEqual(rhythm.roundedSeconds(10), 25, "En az bir sayfa")
        XCTAssertEqual(CameraSettings.defaultSeriesSeconds, 125)
    }

    func testThePartsOfAPageFollowTheAgreedOrder() {
        let order = SeriesRhythm.Part.allCases.map { $0.title }
        XCTAssertEqual(order, ["tüm sayfa", "üst", "orta üst", "orta alt", "alt", "sayfa çevirme"])
        XCTAssertEqual(rhythm.position(at: 0)?.part, .whole)
        XCTAssertEqual(rhythm.position(at: 3.9)?.part, .whole)
        XCTAssertEqual(rhythm.position(at: 4)?.part, .top)
        XCTAssertEqual(rhythm.position(at: 8)?.part, .upperMiddle)
        XCTAssertEqual(rhythm.position(at: 12)?.part, .lowerMiddle)
        XCTAssertEqual(rhythm.position(at: 16)?.part, .bottom)
        XCTAssertEqual(rhythm.position(at: 20)?.part, .turn)
        XCTAssertEqual(rhythm.position(at: 24.9)?.part, .turn)
        let next = rhythm.position(at: 25)
        XCTAssertEqual(next?.page, 2)
        XCTAssertEqual(next?.part, .whole)
        XCTAssertEqual(rhythm.position(at: 124.9)?.page, 5)
        XCTAssertNil(rhythm.position(at: -1))
    }

    func testFramesCountOnlyAfterTheSettleTimeAndNeverDuringThePageTurn() {
        XCTAssertNil(rhythm.shotSlot(at: 1.0), "Dilimin ilk 1,5 sn'si: kullanıcı yeni yere gidiyor")
        XCTAssertEqual(rhythm.shotSlot(at: 1.5)?.part, .whole)
        XCTAssertNil(rhythm.shotSlot(at: 5.0))
        XCTAssertEqual(rhythm.shotSlot(at: 5.6)?.part, .top)
        XCTAssertNil(rhythm.shotSlot(at: 21), "Sayfa çevirirken kare alınmaz")
        XCTAssertNil(rhythm.shotSlot(at: 24.9))
        let second = rhythm.shotSlot(at: 25 + 17.5)
        XCTAssertEqual(second?.page, 2)
        XCTAssertEqual(second?.part, .bottom)
        XCTAssertNotEqual(rhythm.shotSlot(at: 1.6)?.index, rhythm.shotSlot(at: 26.6)?.index, "Her sayfanın her diliminin kendi numarası var")
    }

    func testTheSpokenCuesFollowTheRhythmAndTheLastPageTurnIsSilent() {
        XCTAssertEqual(rhythm.cue(at: 0, totalPages: 5), "Birinci sayfa, tüm sayfa.")
        XCTAssertEqual(rhythm.cue(at: 4, totalPages: 5), "Üst.")
        XCTAssertEqual(rhythm.cue(at: 8, totalPages: 5), "Orta üst.")
        XCTAssertEqual(rhythm.cue(at: 12, totalPages: 5), "Orta alt.")
        XCTAssertEqual(rhythm.cue(at: 16, totalPages: 5), "Alt.")
        XCTAssertEqual(rhythm.cue(at: 20, totalPages: 5), "Sayfayı çevirin.")
        XCTAssertEqual(rhythm.cue(at: 25, totalPages: 5), "İkinci sayfa, tüm sayfa.")
        XCTAssertNil(rhythm.cue(at: 2, totalPages: 5), "Dilimin ortasında komut verilmez")
        XCTAssertNil(rhythm.cue(at: 20 + 4 * 25, totalPages: 5), "Son sayfadan sonra çevirilecek sayfa yok: sessiz pay")
        var cues = 0
        for second in 0..<125 where rhythm.cue(at: Double(second), totalPages: 5) != nil { cues += 1 }
        XCTAssertEqual(cues, 5 * 6 - 1, "Beş sayfada 6 dilim komutu; son çevirme sessiz")
    }

    func testEachSlotIsSplitInTwoAndTheLabelNamesTheFrame() {
        XCTAssertEqual(SeriesRhythm.framesPerSlot, 2)
        XCTAssertEqual(SeriesRhythm.framesPerSlot * SeriesRhythm.shotsPerPage * rhythm.pages(in: 125), 50, "Sayfa başına 10, beş sayfada 50 görüntü")
        XCTAssertEqual(rhythm.shotSlot(at: 1.5)?.sub, 0)
        XCTAssertEqual(rhythm.shotSlot(at: 2.74)?.sub, 0)
        XCTAssertEqual(rhythm.shotSlot(at: 2.75)?.sub, 1)
        XCTAssertEqual(rhythm.shotSlot(at: 3.9)?.sub, 1)
        XCTAssertEqual(rhythm.shotSlot(at: 25 + 8 + 3.0)?.sub, 1)
        XCTAssertEqual(SeriesRhythm.label(page: 2, part: .upperMiddle, sub: 1), "2. sayfa, orta üst, 2. kare")
    }

    func testEveryFrameLabelNamesThePageAndThePart() {
        let first = SeriesRhythm.slotIndex(page: 1, part: .whole)
        let third = SeriesRhythm.slotIndex(page: 3, part: .lowerMiddle)
        XCTAssertEqual(SeriesRhythm.slot(index: first)?.page, 1)
        XCTAssertEqual(SeriesRhythm.slot(index: third)?.page, 3)
        XCTAssertEqual(SeriesRhythm.slot(index: third)?.part, .lowerMiddle)
        XCTAssertEqual(SeriesRhythm.label(page: 3, part: .lowerMiddle), "3. sayfa, orta alt")
    }

    func testTheSettingsDescribeTheRhythmInPagesOfTwentyFiveSeconds() {
        XCTAssertEqual(CameraSettings.seriesSecondsRange, 25...200)
        XCTAssertEqual(CameraSettings.seriesSecondsStep, 25)
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

final class RhythmCollectorTests: XCTestCase {
    private func buffer(id: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 8 + id, 4, kCVPixelFormatType_32BGRA, nil, &pb)
        return pb!
    }

    private func collector(_ t0: Double) -> SeriesCollector {
        return SeriesCollector(start: t0, rhythm: SeriesRhythm.standard,
                               reader: { _ in
                                   var t = TextScore()
                                   t.chars = 120
                                   t.confidence = 0.9
                                   t.words = Set(["aynı", "sayfa", "kelimeleri", "burada"])   // hepsi AYNI yazı: klasik seçim bunları tek kare yapardı
                                   return t
                               },
                               renderer: { buffer in (data: Data([UInt8(CVPixelBufferGetWidth(buffer) - 8)]), width: 1920, height: 1080) })
    }

    private let signature = [UInt8](repeating: 100, count: 576)

    /// Bir sayfa: her alınan dilimde yerleşme süresinden sonra iki kare (ikincisi daha net), ayrıca yerleşirken ve sayfa çevirirken gelen çok net kareler
    private func feedPage(_ c: SeriesCollector, t0: Double, page: Int, firstID: Int) {
        var id = firstID
        let base = Double(page - 1) * 25
        for part in 0..<5 {
            let slotStart = base + Double(part) * 4
            // yerleşirken (0,5 sn): çok net ama sayılmaz
            c.offer(buffer: buffer(id: 100 + id), time: t0 + slotStart + 0.5, sharpness: 900, signature: signature)
            c.offer(buffer: buffer(id: id), time: t0 + slotStart + 2.0, sharpness: 100, signature: signature)
            c.offer(buffer: buffer(id: id + 1), time: t0 + slotStart + 3.0, sharpness: 200, signature: signature)
            id += 2
        }
        // sayfa çevirme: çok net ama sayılmaz
        c.offer(buffer: buffer(id: 150 + page), time: t0 + base + 22, sharpness: 900, signature: signature)
    }

    func testTwoPhotosPerSlotAreKeptEvenWhenAllLookTheSameAndNothingIsSkipped() async {
        let t0 = 5000.0
        let c = collector(t0)
        feedPage(c, t0: t0, page: 1, firstID: 1)
        feedPage(c, t0: t0, page: 2, firstID: 11)
        let outcome = await c.finish()
        XCTAssertEqual(outcome.items.count, 20, "Her sayfada 5 dilim × 2 kare = 10 fotoğraf, iki sayfada 20; aynı görünüm diye birleşmez")
        XCTAssertEqual(outcome.stats.busySkipped, 0)
        XCTAssertEqual(outcome.stats.merged, 0)
        // her dilimin her yarısından bir kare: 1, 2 (tüm sayfa), 3, 4 (üst), …
        XCTAssertEqual(outcome.items.map { $0.jpeg.first }, (1...20).map { UInt8($0) })
    }

    func testFramesFromTheSettlingTimeAndThePageTurnNeverEnterThePdf() async {
        let t0 = 6000.0
        let c = collector(t0)
        feedPage(c, t0: t0, page: 1, firstID: 1)
        let outcome = await c.finish()
        XCTAssertFalse(outcome.items.contains { $0.jpeg.first.map { Int($0) >= 100 } ?? false }, "Çok net ama yerleşirken ya da çevirirken gelen kareler alınmaz")
    }

    func testEveryPhotoCarriesItsPageAndPartLabelInPdfOrder() async {
        let t0 = 7000.0
        let c = collector(t0)
        feedPage(c, t0: t0, page: 1, firstID: 1)
        feedPage(c, t0: t0, page: 2, firstID: 11)
        let outcome = await c.finish()
        XCTAssertEqual(outcome.labels.count, outcome.items.count)
        XCTAssertEqual(Array(outcome.labels.prefix(6)), ["1. sayfa, tüm sayfa, 1. kare", "1. sayfa, tüm sayfa, 2. kare", "1. sayfa, üst, 1. kare", "1. sayfa, üst, 2. kare",
                                                         "1. sayfa, orta üst, 1. kare", "1. sayfa, orta üst, 2. kare"])
        XCTAssertEqual(outcome.labels.last, "2. sayfa, alt, 2. kare")
    }

    func testASlotWithoutFramesIsSimplyMissingAndTheOthersKeepTheirLabels() async {
        let t0 = 8000.0
        let c = collector(t0)
        // yalnız "üst" (dilim 1) ve "alt" (dilim 4) dilimlerinde kare var (ilk kare yerleşirken gelir: kamera durgunluğu ölçülsün)
        c.offer(buffer: buffer(id: 90), time: t0 + 4 + 0.5, sharpness: 100, signature: signature)
        c.offer(buffer: buffer(id: 1), time: t0 + 4 + 2.0, sharpness: 100, signature: signature)
        c.offer(buffer: buffer(id: 2), time: t0 + 16 + 2.0, sharpness: 100, signature: signature)
        let outcome = await c.finish()
        XCTAssertEqual(outcome.labels, ["1. sayfa, üst, 1. kare", "1. sayfa, alt, 1. kare"])
    }

    func testADamagedFrameIsDroppedWhenTheSameSlotHasACleanOneButKeptWhenNothingElseExists() async {
        let t0 = 10000.0
        let damaged = FrameAnalysis.damagedBlockiness + 0.5
        let mixed = collector(t0)
        mixed.offer(buffer: buffer(id: 90), time: t0 + 0.5, sharpness: 100, signature: signature)   // yerleşirken: kamera durgunluğu ölçülsün
        mixed.offer(buffer: buffer(id: 1), time: t0 + 2.0, sharpness: 100, signature: signature, blockiness: 1.0)       // 1. yarı sağlam
        mixed.offer(buffer: buffer(id: 2), time: t0 + 3.0, sharpness: 100, signature: signature, blockiness: damaged)   // 2. yarı yalnız bozuk
        let a = await mixed.finish()
        XCTAssertEqual(a.items.map { $0.jpeg.first }, [1], "Dilimde sağlam kare varsa bozuk olan gitmez")
        let onlyBad = collector(t0)
        onlyBad.offer(buffer: buffer(id: 91), time: t0 + 0.5, sharpness: 100, signature: signature)
        onlyBad.offer(buffer: buffer(id: 3), time: t0 + 2.0, sharpness: 100, signature: signature, blockiness: damaged)
        onlyBad.offer(buffer: buffer(id: 4), time: t0 + 3.0, sharpness: 100, signature: signature, blockiness: damaged)
        let b = await onlyBad.finish()
        XCTAssertEqual(b.items.count, 2, "Hiç sağlam kare yoksa bozuklar tek seçenektir (yeniden çekim hakkı bitmişse)")
    }

    func testTheClassicCollectorStaysUnlabeled() async {
        let t0 = 9000.0
        let c = SeriesCollector(start: t0, maxPending: 1000, reader: { _ in nil },
                                renderer: { buffer in (data: Data([UInt8(CVPixelBufferGetWidth(buffer) - 8)]), width: 10, height: 10) })
        c.offer(buffer: buffer(id: 1), time: t0 + 0.1, sharpness: 150, signature: signature)
        let outcome = await c.finish()
        XCTAssertEqual(outcome.labels, [], "Ritimsiz çekimde etiket yoktur")
    }
}

@MainActor
final class RhythmPromptTests: XCTestCase {
    func testTheRhythmLabelsAreListedInThePromptInPdfOrder() {
        let labels = ["1. sayfa, tüm sayfa", "1. sayfa, üst", "1. sayfa, orta üst", "1. sayfa, orta alt", "1. sayfa, alt"]
        let text = GeminiAnswerService.pageText(expectedNumber: 1, hasVideo: false, extra: "", pages: 5, labels: labels)
        XCTAssertTrue(text.contains("1) 1. sayfa, tüm sayfa; 2) 1. sayfa, üst; 3) 1. sayfa, orta üst; 4) 1. sayfa, orta alt; 5) 1. sayfa, alt"), text)
        XCTAssertTrue(text.contains("Çekim ritimliydi"))
        XCTAssertTrue(text.contains("İKİ kare"), "Her yerden iki kare vardır; aynı satır iki kez soru sayılmaz")
        XCTAssertTrue(text.contains("ETİKETLER YALNIZ İPUCUDUR"), "Kullanıcı sırayı şaşırabilir: Gemini etikete değil içeriğe güvenir")
        XCTAssertTrue(text.contains("içerikten bul"))
        XCTAssertTrue(GeminiAnswerService.pageSystemPrompt.contains("sırasız göstermiş olabilir"), "Sistem komutu da sırasız çekimi söyler")
    }

    func testWithoutLabelsOrWithAMismatchThePromptStaysAsBefore() {
        let plain = GeminiAnswerService.pageText(expectedNumber: 1, hasVideo: false, extra: "", pages: 5)
        XCTAssertFalse(plain.contains("ritimliydi"))
        let mismatch = GeminiAnswerService.pageText(expectedNumber: 1, hasVideo: false, extra: "", pages: 5, labels: ["1. sayfa, üst"])
        XCTAssertEqual(mismatch, plain, "PDF'teki sayfa sayısı etiket sayısına uymuyorsa etiket kullanılmaz (sıra bozulmuş olabilir)")
    }

    func testTheLabelsSurviveARestartOfThePhone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ritim-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileCaptureStore(root: root)
        store.prepare()
        var shot = CapturedQuestion(photo: Data([1, 2, 3]))
        shot.isPage = true
        shot.rhythmLabels = ["1. sayfa, tüm sayfa", "1. sayfa, üst"]
        _ = store.keep(shot, kind: .page)
        let restored = FileCaptureStore(root: root).restorePending()
        XCTAssertEqual(restored.first?.rhythmLabels, ["1. sayfa, tüm sayfa", "1. sayfa, üst"])
    }
}

/// Kamerada blok bozulmaları olur (kullanıcı kararı 2026-11-18): kullanıcı bunu bilmeli, sayfadan ayrılmamalı, o yerin temiz çekimi yeniden yapılabilmeli.
/// Bir alınan dilimde YALNIZ bozuk kare görülürse dilim tekrarlanır ve oturum uzar.
final class DamagedSlotRetryTests: XCTestCase {
    private let signature = [UInt8](repeating: 100, count: 576)

    private func buffer(id: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 8 + id, 4, kCVPixelFormatType_32BGRA, nil, &pb)
        return pb!
    }

    private func collector(_ t0: Double, clock: RhythmClock) -> SeriesCollector {
        return SeriesCollector(start: t0, clock: clock, reader: { _ in nil },
                               renderer: { buffer in (data: Data([UInt8(CVPixelBufferGetWidth(buffer) - 8)]), width: 1920, height: 1080) })
    }

    func testTheSlotThatJustEndedIsFoundOnlyAtItsEnd() {
        let rhythm = SeriesRhythm.standard
        XCTAssertEqual(rhythm.endingSlot(at: 4)?.part, .whole)
        XCTAssertEqual(rhythm.endingSlot(at: 8)?.part, .top)
        XCTAssertEqual(rhythm.endingSlot(at: 20)?.part, .bottom, "Alt dilim bitince (sayfa çevrilmeden) karar verilir")
        XCTAssertEqual(rhythm.endingSlot(at: 120)?.page, 5)
        XCTAssertNil(rhythm.endingSlot(at: 25), "Sayfa çevirme biterken yeniden çekim yoktur")
        XCTAssertNil(rhythm.endingSlot(at: 6), "Dilimin ortası")
        XCTAssertNil(rhythm.endingSlot(at: 0))
    }

    func testWithoutDamageTheClockOnlyGivesTheNormalCues() {
        let clock = RhythmClock(pages: 5)
        XCTAssertEqual(clock.step(at: 4, needsRetry: { _ in false }), .cue("Üst."))
        XCTAssertEqual(clock.step(at: 5, needsRetry: { _ in false }), .silent)
        XCTAssertEqual(clock.offset, 0)
        XCTAssertEqual(clock.totalSeconds, 125)
        XCTAssertEqual(clock.retries, 0)
    }

    func testADamagedSlotIsRepeatedTheUserIsToldToStayAndTheSessionGrows() {
        let clock = RhythmClock(pages: 5)
        guard case .retry(let text, let slot, let attempt) = clock.step(at: 4, needsRetry: { $0 == 0 }) else { return XCTFail("Bozuk dilim tekrarlanmalı") }
        XCTAssertEqual(slot, 0)
        XCTAssertEqual(attempt, 1)
        XCTAssertEqual(text, "Görüntü bozuldu. Sayfadan ayrılmayın, bu yeri tekrar gösterin.")
        XCTAssertEqual(clock.offset, 4)
        XCTAssertEqual(clock.totalSeconds, 129, "Tekrar oturumu bir dilim uzatır")
        XCTAssertEqual(clock.position(at: 4)?.part, .whole, "Saat geri alındı: aynı dilim yeniden başlıyor")
        XCTAssertEqual(clock.position(at: 4)?.into, 0)
        XCTAssertEqual(clock.step(at: 5, needsRetry: { _ in false }), .silent, "Tekrar sırasında başka komut yok")
        XCTAssertEqual(clock.step(at: 8, needsRetry: { _ in false }), .cue("Üst."), "Tekrar temiz geçince ritim kaldığı yerden sürer")
        XCTAssertEqual(clock.position(at: 8)?.part, .top)
    }

    func testTheSameSlotIsRepeatedAtMostTwiceAndTheSecondTextIsDifferent() {
        let clock = RhythmClock(pages: 5)
        _ = clock.step(at: 4, needsRetry: { _ in true })
        guard case .retry(let text, _, let attempt) = clock.step(at: 8, needsRetry: { _ in true }) else { return XCTFail("İkinci tekrar") }
        XCTAssertEqual(attempt, 2)
        XCTAssertEqual(text, "Hâlâ bozuk. Sayfadan ayrılmayın, bir kez daha gösterin.")
        XCTAssertEqual(clock.step(at: 12, needsRetry: { _ in true }), .cue("Üst."), "İki tekrardan sonra ritim sessizce sürer: o dilimin kalan en iyi karesi gider")
        XCTAssertEqual(clock.offset, 8)
    }

    func testTheWholeSessionRepeatsAtMostSixTimes() {
        let clock = RhythmClock(pages: 5)
        var second = 0
        while second < clock.totalSeconds {
            second += 1
            _ = clock.step(at: second, needsRetry: { _ in true })
        }
        XCTAssertEqual(clock.retries, 6)
        XCTAssertEqual(clock.totalSeconds, 125 + 24)
        XCTAssertEqual(clock.maxExtraSeconds, 44)
    }

    func testTheLastSlotOfTheLastPageCanBeRepeatedToo() {
        let clock = RhythmClock(pages: 5)
        guard case .retry(_, let slot, _) = clock.step(at: 120, needsRetry: { _ in true }) else { return XCTFail("Son dilim de tekrarlanır") }
        XCTAssertEqual(SeriesRhythm.slot(index: slot)?.page, 5)
        XCTAssertEqual(SeriesRhythm.slot(index: slot)?.part, .bottom)
        XCTAssertEqual(clock.totalSeconds, 129)
    }

    func testOnlyASlotWithDamagedFramesAndNoCleanFrameNeedsARepeat() {
        let t0 = 11000.0
        let clock = RhythmClock(pages: 5)
        let c = collector(t0, clock: clock)
        let damaged = FrameAnalysis.damagedBlockiness + 0.5
        c.offer(buffer: buffer(id: 1), time: t0 + 2.0, sharpness: 900, signature: signature, blockiness: damaged)
        c.offer(buffer: buffer(id: 2), time: t0 + 3.0, sharpness: 900, signature: signature, blockiness: damaged)
        XCTAssertTrue(c.slotNeedsRetry(0), "Dilimde yalnız bozuk kare var")
        XCTAssertFalse(c.slotNeedsRetry(1), "Hiç kare görülmeyen dilim (kamera durmuş olabilir) bozukluk sayılmaz")
        c.offer(buffer: buffer(id: 3), time: t0 + 3.5, sharpness: 100, signature: signature, blockiness: 1.0)
        XCTAssertFalse(c.slotNeedsRetry(0), "Bir sağlam kare yetiyor")
    }

    func testFramesWhileSettlingDoNotCountAsDamage() {
        let t0 = 12000.0
        let c = collector(t0, clock: RhythmClock(pages: 5))
        c.offer(buffer: buffer(id: 1), time: t0 + 0.5, sharpness: 900, signature: signature, blockiness: FrameAnalysis.damagedBlockiness + 0.5)
        XCTAssertFalse(c.slotNeedsRetry(0), "Yerleşirken gelen bozuk kare sayılmaz")
    }

    func testTheCleanShotOfTheRepeatReplacesTheDamagedOne() async {
        let t0 = 13000.0
        let clock = RhythmClock(pages: 5)
        let c = collector(t0, clock: clock)
        c.offer(buffer: buffer(id: 1), time: t0 + 2.0, sharpness: 900, signature: signature, blockiness: FrameAnalysis.damagedBlockiness + 0.5)
        guard case .retry = clock.step(at: 4, needsRetry: { c.slotNeedsRetry($0) }) else { return XCTFail("Dilim tekrarlanmalı") }
        // saat geri alındı: oturumun 6. saniyesi yine "tüm sayfa" diliminin 2. saniyesi
        c.offer(buffer: buffer(id: 2), time: t0 + 6.0, sharpness: 100, signature: signature, blockiness: 1.0)
        XCTAssertFalse(c.slotNeedsRetry(0))
        guard case .cue(let cue) = clock.step(at: 8, needsRetry: { c.slotNeedsRetry($0) }) else { return XCTFail("Temiz tekrardan sonra sıradaki komut") }
        XCTAssertEqual(cue, "Üst.")
        let outcome = await c.finish()
        XCTAssertEqual(outcome.items.count, 1)
        XCTAssertEqual(outcome.items.first?.jpeg.first, 2, "Tekrarın temiz karesi bozuk olanın yerine geçer")
        XCTAssertEqual(outcome.labels, ["1. sayfa, tüm sayfa, 1. kare"])
    }
}


/// Kullanıcı kararı 2026-11-18: bulanık kare, bozuk kare ve bir sorunun tamamını ya da çoğunu içine almayan kare doğru kabul edilmez
final class SlotCheckTests: XCTestCase {
    private func lines(chars: Int, complete: Int = 0, paragraph: Bool = false) -> ViewLines {
        var l = ViewLines()
        l.chars = chars
        l.completeQuestions = complete
        l.paragraph = paragraph
        return l
    }

    func testDamagedAndMovingFramesAreNeverValid() {
        XCTAssertEqual(SlotCheck.problem(damaged: true, still: true, part: .whole, lines: nil), .damaged)
        XCTAssertEqual(SlotCheck.problem(damaged: true, still: false, part: .top, lines: lines(chars: 500, complete: 2)), .damaged, "Bozukluk bulanıklıktan önce söylenir")
        XCTAssertEqual(SlotCheck.problem(damaged: false, still: false, part: .top, lines: lines(chars: 500, complete: 2)), .blurry, "Kamera oynarken alınan kare bulanıktır")
    }

    func testTheWholePageSlotOnlyChecksDamageAndBlur() {
        XCTAssertNil(SlotCheck.problem(damaged: false, still: true, part: .whole, lines: lines(chars: 0)), "Sayfa haritasında soru aranmaz")
    }

    func testAPartNeedsReadableTextAndAWholeQuestionOrAParagraph() {
        XCTAssertEqual(SlotCheck.problem(damaged: false, still: true, part: .top, lines: lines(chars: 5)), .blurry, "Yazı okunmuyor: bulanık ya da boş")
        XCTAssertEqual(SlotCheck.problem(damaged: false, still: true, part: .lowerMiddle, lines: lines(chars: 400)), .noQuestion, "Yazı var ama baştan sona görünen soru yok")
        XCTAssertNil(SlotCheck.problem(damaged: false, still: true, part: .upperMiddle, lines: lines(chars: 400, complete: 1)))
        XCTAssertNil(SlotCheck.problem(damaged: false, still: true, part: .bottom, lines: lines(chars: 400, paragraph: true)), "Soru yapısı olmayan paragraf da geçerlidir")
        XCTAssertNil(SlotCheck.problem(damaged: false, still: true, part: .top, lines: nil), "Yazı okuma çalışmadıysa kare yalnız bu yüzden elenmez")
        XCTAssertNil(SlotCheck.problem(damaged: false, still: false, part: .whole, lines: nil, chars: 300), "Yazısı okunan kare, kamera oynasa da bulanık değildir")
        XCTAssertEqual(SlotCheck.problem(damaged: false, still: false, part: .whole, lines: nil, chars: 20), .blurry)
    }

    func testPartsMustShareLinesWithThePreviousPartButDoubtNeverAsksForARepeat() {
        let a = Set((1...20).map { "sozcuk\($0)" })
        let half = Set((11...30).map { "sozcuk\($0)" })
        let other = Set((101...120).map { "baska\($0)" })
        XCTAssertTrue(SlotCheck.overlaps(previous: a, current: half), "Yarı yarıya örtüşen parçalar")
        XCTAssertFalse(SlotCheck.overlaps(previous: a, current: other), "Hiç ortak satır yok: arada yer atlanmış")
        XCTAssertTrue(SlotCheck.overlaps(previous: Set(["yalnız", "birkaç", "sözcük"]), current: other), "Az sözcük okunduysa hüküm verilmez")
    }

    func testReadingBasedReasonsRepeatASlotOnlyOnce() {
        XCTAssertEqual(SlotProblem.damaged.retryLimit(2), 2)
        XCTAssertEqual(SlotProblem.blurry.retryLimit(2), 2)
        XCTAssertEqual(SlotProblem.noQuestion.retryLimit(2), 1)
        XCTAssertEqual(SlotProblem.noOverlap.retryLimit(2), 1)
        let clock = RhythmClock(pages: 5)
        guard case .retry = clock.step(at: 4, problem: { _ in .noQuestion }) else { return XCTFail("İlk tekrar") }
        XCTAssertEqual(clock.step(at: 8, problem: { _ in .noQuestion }), .cue("Üst."), "Yazı okumaya dayanan neden ikinci kez tekrar ettirmez")
    }

    func testTheSpokenSentenceNamesTheReasonAndTheProblemsAreOrdered() {
        XCTAssertTrue(RhythmClock.retryText(problem: .damaged, attempt: 1).contains("bozuldu"))
        XCTAssertTrue(RhythmClock.retryText(problem: .blurry, attempt: 1).contains("bulanık"))
        XCTAssertTrue(RhythmClock.retryText(problem: .noQuestion, attempt: 1).contains("Soru tam görünmüyor"))
        for problem in SlotProblem.allCases {
            XCTAssertTrue(RhythmClock.retryText(problem: problem, attempt: 1).contains("Sayfadan ayrılmayın"), "Kullanıcı sayfadan ayrılmamalı")
            XCTAssertNotEqual(RhythmClock.retryText(problem: problem, attempt: 1), RhythmClock.retryText(problem: problem, attempt: 2))
        }
        XCTAssertLessThan(SlotProblem.damaged, SlotProblem.blurry)
        XCTAssertLessThan(SlotProblem.blurry, SlotProblem.noQuestion)
    }
}

final class ValidFrameRetryTests: XCTestCase {
    private func buffer(id: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 8 + id, 4, kCVPixelFormatType_32BGRA, nil, &pb)
        return pb!
    }

    private let signature = [UInt8](repeating: 100, count: 576)

    /// Kimlik 50'nin altındaki kareler kesik soru gösterir (yazı var, tam soru yok), 50 ve üstü tam soru; kimlik 40'ın altı yazısız
    private func collector(_ t0: Double, clock: RhythmClock) -> SeriesCollector {
        return SeriesCollector(start: t0, clock: clock,
                               reader: { buffer in
                                   let id = CVPixelBufferGetWidth(buffer) - 8
                                   var t = TextScore()
                                   t.chars = (id < 40 || (70..<80).contains(id)) ? 5 : 120   // 40'ın altı ve 70–79: yazısı okunmayan kare
                                   t.confidence = 0.9
                                   return t
                               },
                               renderer: { buffer in (data: Data([UInt8(CVPixelBufferGetWidth(buffer) - 8)]), width: 1920, height: 1080) },
                               coverage: { buffer in
                                   let id = CVPixelBufferGetWidth(buffer) - 8
                                   var l = ViewLines()
                                   l.chars = id < 40 ? 5 : 400
                                   l.completeQuestions = id >= 50 ? 1 : 0
                                   return l
                               })
    }

    func testASlotWithoutAWholeQuestionIsRepeatedAndTheValidRepeatReplacesIt() async {
        let t0 = 14000.0
        let clock = RhythmClock(pages: 5)
        let c = collector(t0, clock: clock)
        // 2. dilim ("üst", 4–8 sn): iki yarıda da kesik soru
        c.offer(buffer: buffer(id: 1), time: t0 + 4.5, sharpness: 100, signature: signature)      // yerleşirken: durgunluk ölçülsün
        c.offer(buffer: buffer(id: 41), time: t0 + 6.0, sharpness: 100, signature: signature)
        c.offer(buffer: buffer(id: 42), time: t0 + 7.0, sharpness: 100, signature: signature)
        XCTAssertNil(c.slotProblem(1), "Kazananlar daha yazı tanımadan geçmedi")
        XCTAssertEqual(clock.endingSlotIndex(at: 8), 1)
        await c.settle()
        XCTAssertEqual(c.slotProblem(1), .noQuestion)
        guard case .retry(let text, let slot, let attempt) = clock.step(at: 8, problem: { c.slotProblem($0) }) else { return XCTFail("Kesik soru gösteren dilim tekrarlanmalı") }
        XCTAssertEqual(slot, 1)
        XCTAssertEqual(attempt, 1)
        XCTAssertTrue(text.contains("Soru tam görünmüyor"))
        XCTAssertTrue(text.contains("Sayfadan ayrılmayın"))
        // saat geri alındı: oturumun 10. ve 11. saniyeleri yine bu diliminin 2. ve 3. saniyeleri (tekrar, ilk denemenin açık yarısından önce başlar)
        c.offer(buffer: buffer(id: 60), time: t0 + 10.0, sharpness: 100, signature: signature)
        c.offer(buffer: buffer(id: 61), time: t0 + 11.0, sharpness: 100, signature: signature)
        XCTAssertEqual(clock.endingSlotIndex(at: 12), 1)
        await c.settle()
        XCTAssertNil(c.slotProblem(1), "Tekrarda tam soru görüldü")
        XCTAssertEqual(clock.step(at: 12, problem: { c.slotProblem($0) }), .cue("Orta üst."))
        let outcome = await c.finish()
        XCTAssertEqual(outcome.items.map { $0.jpeg.first }, [60, 61], "Kesik soru gösteren kareler, dilimde geçerli kare varken PDF'e girmez")
        XCTAssertEqual(outcome.labels, ["1. sayfa, üst, 1. kare", "1. sayfa, üst, 2. kare"])
    }

    func testUnreadableTextIsReportedAsBlurry() async {
        let t0 = 15000.0
        let clock = RhythmClock(pages: 5)
        let c = collector(t0, clock: clock)
        c.offer(buffer: buffer(id: 1), time: t0 + 4.5, sharpness: 100, signature: signature)
        c.offer(buffer: buffer(id: 11), time: t0 + 6.0, sharpness: 100, signature: signature)
        c.offer(buffer: buffer(id: 12), time: t0 + 7.0, sharpness: 100, signature: signature)
        await c.settle()
        XCTAssertEqual(c.slotProblem(1), .blurry)
        guard case .retry(let text, _, _) = clock.step(at: 8, problem: { c.slotProblem($0) }) else { return XCTFail("Yazısı okunmayan dilim tekrarlanmalı") }
        XCTAssertTrue(text.contains("bulanık"))
    }

    func testAMovingCameraMakesTheSlotBlurry() async {
        let t0 = 16000.0
        let clock = RhythmClock(pages: 5)
        let c = collector(t0, clock: clock)
        let other = [UInt8](repeating: 220, count: 576)
        c.offer(buffer: buffer(id: 70), time: t0 + 4.5, sharpness: 100, signature: signature)
        c.offer(buffer: buffer(id: 71), time: t0 + 6.0, sharpness: 100, signature: other)
        c.offer(buffer: buffer(id: 72), time: t0 + 6.5, sharpness: 100, signature: signature)
        c.offer(buffer: buffer(id: 73), time: t0 + 7.0, sharpness: 100, signature: other)
        c.offer(buffer: buffer(id: 74), time: t0 + 7.5, sharpness: 100, signature: signature)
        await c.settle()
        XCTAssertEqual(c.slotProblem(1), .blurry, "Kamera hiç durgun kalmadı ve yazı okunmuyor")
    }

    func testAMovingCameraIsFineWhenTheTextIsStillReadable() async {
        let t0 = 18000.0
        let clock = RhythmClock(pages: 5)
        let c = collector(t0, clock: clock)
        let other = [UInt8](repeating: 220, count: 576)
        c.offer(buffer: buffer(id: 60), time: t0 + 4.5, sharpness: 100, signature: signature)
        c.offer(buffer: buffer(id: 61), time: t0 + 6.0, sharpness: 100, signature: other)
        c.offer(buffer: buffer(id: 62), time: t0 + 7.0, sharpness: 100, signature: signature)
        await c.settle()
        XCTAssertNil(c.slotProblem(1), "Kamera oynasa da yazısı okunan kare bulanık sayılmaz (gerçek günlük 2026-11-18)")
        let outcome = await c.finish()
        XCTAssertEqual(outcome.labels, ["1. sayfa, üst, 1. kare", "1. sayfa, üst, 2. kare"])
    }

    func testTheClockWaitsWhileNoFramesArrive() {
        let t0 = 19000.0
        let clock = RhythmClock(pages: 5)
        let c = collector(t0, clock: clock)
        XCTAssertEqual(c.secondsSinceFrame(now: t0 + 2), 2, accuracy: 0.001)
        c.offer(buffer: buffer(id: 60), time: t0 + 5, sharpness: 100, signature: signature)
        XCTAssertEqual(c.secondsSinceFrame(now: t0 + 9), 4, accuracy: 0.001)
        XCTAssertTrue(clock.hold())
        XCTAssertEqual(clock.totalSeconds, 126, "Bekletilen her saniye oturumu uzatır")
        XCTAssertEqual(clock.position(at: 4.5)?.part, .whole, "Saat bir saniye geride: 4,5. saniye hâlâ ilk dilim")
        XCTAssertEqual(clock.retries, 0, "Bekleme tekrar sayılmaz")
        for _ in 0..<40 { clock.hold() }
        XCTAssertEqual(clock.totalSeconds, 145, "En çok 20 sn bekletilir")
        XCTAssertFalse(clock.hold())
    }

    func testAnInvalidFrameIsStillSentWhenTheSlotNeverGetsAValidOneAndItsLabelSaysSo() async {
        let t0 = 17000.0
        let clock = RhythmClock(pages: 5)
        let c = collector(t0, clock: clock)
        c.offer(buffer: buffer(id: 1), time: t0 + 4.5, sharpness: 100, signature: signature)
        c.offer(buffer: buffer(id: 41), time: t0 + 6.0, sharpness: 100, signature: signature)
        let outcome = await c.finish()
        XCTAssertEqual(outcome.items.count, 1, "Hiç geçerli kare çıkmadıysa (tekrar hakkı bitti) eldeki en iyi kare boş geçilmez")
        XCTAssertEqual(outcome.labels, ["1. sayfa, üst, 1. kare (soru tam görünmüyor)"])
    }
}
