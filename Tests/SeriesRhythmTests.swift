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

    func testOnePhotoPerSlotIsKeptEvenWhenAllLookTheSameAndNothingIsSkipped() async {
        let t0 = 5000.0
        let c = collector(t0)
        feedPage(c, t0: t0, page: 1, firstID: 1)
        feedPage(c, t0: t0, page: 2, firstID: 11)
        let outcome = await c.finish()
        XCTAssertEqual(outcome.items.count, 10, "Her sayfada 5 dilim, iki sayfada 10 fotoğraf; aynı görünüm diye birleşmez")
        XCTAssertEqual(outcome.stats.busySkipped, 0)
        XCTAssertEqual(outcome.stats.merged, 0)
        // her dilimin en net sayılan karesi (ikincisi): 2, 4, 6, 8, 10, sonra 12, 14, …
        XCTAssertEqual(outcome.items.map { $0.jpeg.first }, [2, 4, 6, 8, 10, 12, 14, 16, 18, 20].map { UInt8($0) })
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
        XCTAssertEqual(Array(outcome.labels.prefix(6)), ["1. sayfa, tüm sayfa", "1. sayfa, üst", "1. sayfa, orta üst", "1. sayfa, orta alt", "1. sayfa, alt", "2. sayfa, tüm sayfa"])
        XCTAssertEqual(outcome.labels.last, "2. sayfa, alt")
    }

    func testASlotWithoutFramesIsSimplyMissingAndTheOthersKeepTheirLabels() async {
        let t0 = 8000.0
        let c = collector(t0)
        // yalnız "üst" (dilim 1) ve "alt" (dilim 4) dilimlerinde kare var
        c.offer(buffer: buffer(id: 1), time: t0 + 4 + 2.0, sharpness: 100, signature: signature)
        c.offer(buffer: buffer(id: 2), time: t0 + 16 + 2.0, sharpness: 100, signature: signature)
        let outcome = await c.finish()
        XCTAssertEqual(outcome.labels, ["1. sayfa, üst", "1. sayfa, alt"])
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
