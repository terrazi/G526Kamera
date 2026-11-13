import XCTest
@testable import G526CameraDrive

/// Sesli konumlandırma: sayfa/sütun ölçümü, karar kuralları, durum makinesi, sesli komut sözcükleri ve rapor cümleleri.
final class GuidanceTests: XCTestCase {

    // MARK: - Yardımcılar

    private func col(_ x0: Double, _ x1: Double, y0: Double = 0.2, y1: Double = 0.8,
                     cells: Int = 300, sharp: Double = 1.0) -> ColumnBox {
        return ColumnBox(x0: x0, x1: x1, y0: y0, y1: y1, cells: cells, sharp: sharp)
    }

    private func metrics(x0: Double, x1: Double, y0: Double = 0.2, y1: Double = 0.8, cells: Int = 600,
                         sharp: Double = 1.0, columns: [ColumnBox] = []) -> PageMetrics {
        var m = PageMetrics()
        m.hasPage = true
        m.hasText = true
        m.x0 = x0
        m.x1 = x1
        m.y0 = y0
        m.y1 = y1
        m.cells = cells
        m.sharp = sharp
        m.columns = columns
        return m
    }

    private func decide(_ m: PageMetrics, _ choice: ColumnChoice? = nil) -> GuidanceDecision {
        return GuidanceAdvisor.decide(m, choice: choice, sharpFloor: 0.45)
    }

    private func twoColumns(left: ColumnBox, right: ColumnBox) -> PageMetrics {
        return metrics(x0: left.x0, x1: right.x1, columns: [left, right])
    }

    // MARK: - Tek bölümlü karar kuralları

    func testSingleBlockAdvice() {
        XCTAssertEqual(decide(metrics(x0: 0.2, x1: 0.8)).advice, .ok)
        XCTAssertEqual(decide(metrics(x0: 0.4, x1: 0.995)).advice, .moveRight)
        XCTAssertEqual(decide(metrics(x0: 0.005, x1: 0.6)).advice, .moveLeft)
        XCTAssertEqual(decide(metrics(x0: 0.005, x1: 0.995)).advice, .farther)
        XCTAssertEqual(decide(metrics(x0: 0.2, x1: 0.8, y0: GuidanceAnalyzer.skipTop + 0.005, y1: 0.8)).advice, .moveUp)
        XCTAssertEqual(decide(metrics(x0: 0.2, x1: 0.8, y0: 0.3, y1: 0.995)).advice, .moveDown)
        XCTAssertEqual(decide(metrics(x0: 0.4, x1: 0.6, y0: 0.4, y1: 0.6, cells: 150)).advice, .closer)
        XCTAssertEqual(decide(metrics(x0: 0.2, x1: 0.8, sharp: 0.2)).advice, .blurry)
    }

    func testNoTextAndBlurryPage() {
        XCTAssertEqual(decide(PageMetrics()).advice, .noText)
        var m = PageMetrics()
        m.hasPage = true
        XCTAssertEqual(decide(m).advice, .blurry)
    }

    // MARK: - Çok bölümlü (sütun / yan yana sayfa) kararları

    func testColumnsAllFitNoQuestion() {
        let m = twoColumns(left: col(0.13, 0.49), right: col(0.51, 0.88))
        XCTAssertEqual(decide(m).advice, .ok)
    }

    func testCutColumnAsksWhichOne() {
        let m = twoColumns(left: col(0.04, 0.57), right: col(0.60, 1.0))
        let d = decide(m)
        XCTAssertEqual(d.advice, .chooseColumn)
        XCTAssertEqual(d.options, [.left, .right, .all])
    }

    func testChoiceTargetsOnlyThatColumn() {
        let m = twoColumns(left: col(0.04, 0.57), right: col(0.60, 1.0))
        XCTAssertEqual(decide(m, .left).advice, .ok)          // sol sütun tam: yarım kalan sağ yok sayılır
        XCTAssertEqual(decide(m, .right).advice, .moveRight)  // sağ sütun taşıyor: kamerayı sağa
        XCTAssertNotEqual(decide(m, .all).advice, .ok)        // ikisi birden sığmıyor
    }

    func testChoiceRightWhenLeftIsCut() {
        let m = twoColumns(left: col(0.0, 0.40), right: col(0.43, 0.94))
        XCTAssertEqual(decide(m).advice, .chooseColumn)
        XCTAssertEqual(decide(m, .right).advice, .ok)
        XCTAssertEqual(decide(m, .left).advice, .moveLeft)
    }

    func testThreeColumnsOfferMiddle() {
        let cols = [col(0.06, 0.43), col(0.45, 0.82), col(0.84, 1.0)]
        let m = metrics(x0: 0.06, x1: 1.0, columns: cols)
        let d = decide(m)
        XCTAssertEqual(d.advice, .chooseColumn)
        XCTAssertTrue(d.options.contains(.middle))
        XCTAssertEqual(decide(m, .middle).advice, .ok)
        XCTAssertEqual(decide(m, .right).advice, .moveRight)
    }

    // MARK: - Sesli yönlendirme (video kaydı sırasında)

    private func step(_ e: GuidanceEngine, _ m: PageMetrics, t: Double, still: Double = 1.0) -> GuidanceEngine.Output {
        return e.videoStep(m, time: t, stillFor: still)
    }

    func testSpeaksDirectionOnceThenRateLimits() {
        let e = GuidanceEngine()
        let m = metrics(x0: 0.4, x1: 0.995)
        var spoken: [String] = []
        for i in 0..<6 {
            if let s = step(e, m, t: Double(i) * 0.3).speak { spoken.append(s) }
        }
        XCTAssertEqual(spoken, ["Kamerayı epey sağa kaydırın."])
    }

    // MARK: - Video kaydı sırasında konum tarifi

    private func vstep(_ e: GuidanceEngine, _ m: PageMetrics, t: Double, still: Double = 2.0) -> GuidanceEngine.Output {
        return e.videoStep(m, time: t, stillFor: still)
    }

    func testVideoStepSpeaksDirectionOnce() {
        let e = GuidanceEngine()
        let m = metrics(x0: 0.4, x1: 0.995)
        var spoken: [String] = []
        for i in 0..<8 {
            let out = vstep(e, m, t: Double(i) * 0.3)
            if let t = out.speak { spoken.append(t) }
        }
        XCTAssertEqual(spoken, ["Kamerayı epey sağa kaydırın."])
    }

    func testVideoStepGoodFrameIsSilent() {
        let e = GuidanceEngine()
        for i in 0..<20 {
            let out = vstep(e, metrics(x0: 0.2, x1: 0.8), t: Double(i) * 0.3)
            XCTAssertNil(out.speak)
        }
        XCTAssertEqual(vstep(e, metrics(x0: 0.2, x1: 0.8), t: 10).status, "Video: kadraj uygun")
    }

    func testVideoStepTargetsAllSectionsInsteadOfAskingWhichOne() {
        let e = GuidanceEngine()
        let m = twoColumns(left: col(0.005, 0.49), right: col(0.51, 0.88))
        var advice: GuidanceAdvice?
        for i in 0..<4 { advice = vstep(e, m, t: Double(i) * 0.3).advice }
        XCTAssertNotNil(advice)
        XCTAssertNotEqual(advice, .chooseColumn)
        XCTAssertEqual(advice, .moveLeft)
    }

    func testVideoStepIsSilentWhileCameraMoves() {
        let e = GuidanceEngine()
        let m = metrics(x0: 0.4, x1: 0.995)
        for i in 0..<10 {
            let out = vstep(e, m, t: Double(i) * 0.3, still: 0.1)
            XCTAssertNil(out.speak)
            XCTAssertTrue(out.status.contains("hareket"))
        }
    }

    func testVideoStepIgnoresBlurAndGlare() {
        let e = GuidanceEngine()
        var m = metrics(x0: 0.2, x1: 0.8, sharp: 0.1)
        m.glare = 0.5
        for i in 0..<10 {
            let out = vstep(e, m, t: Double(i) * 0.3)
            XCTAssertNil(out.speak)
            XCTAssertEqual(out.advice, .ok)
        }
    }

    func testVideoStepNoTextIsSpokenOnlyAfterAWhile() {
        let e = GuidanceEngine()
        var spoken: [String] = []
        for i in 0..<3 {
            if let t = vstep(e, PageMetrics(), t: Double(i) * 0.3).speak { spoken.append(t) }
        }
        XCTAssertTrue(spoken.isEmpty, "sayfa çevrilirken kısa süreli yazı yokluğu söylenmez")
        if let t = vstep(e, PageMetrics(), t: 0.9).speak { spoken.append(t) }
        XCTAssertEqual(spoken, ["Yazı görünmüyor. Kamerayı belgeye çevirin."])
    }

    func testVideoStepRepeatsFourTimesThenMutesUntilAdviceChanges() {
        let e = GuidanceEngine()
        let cut = metrics(x0: 0.4, x1: 0.995)
        var count = 0
        for i in 0..<100 where vstep(e, cut, t: Double(i)).speak != nil { count += 1 }
        XCTAssertEqual(count, 4)
        // uygun kareye dönüp yeniden bozulunca yine söyler
        _ = vstep(e, metrics(x0: 0.2, x1: 0.8), t: 101)
        var again = false
        for i in 102..<110 where vstep(e, cut, t: Double(i)).speak != nil { again = true }
        XCTAssertTrue(again)
    }

    // MARK: - Sentetik görüntüde sayfa / sütun ölçümü

    private func synth(pages: [(Int, Int)], blocks: [(Int, Int, Int, Int)], w: Int = 960, h: Int = 540) -> [Float] {
        var luma = [Float](repeating: 30, count: w * h)
        for (px0, px1) in pages {
            for y in 45..<(h - 10) {
                for x in px0..<px1 { luma[y * w + x] = 235 }
            }
        }
        for (bx0, bx1, by0, by1) in blocks {
            var y = by0
            while y + 5 < by1 {
                var x = bx0
                while x + 30 <= bx1 {
                    for yy in y..<(y + 5) {
                        for xx in x..<(x + 30) { luma[yy * w + xx] = 40 }
                    }
                    x += 38
                }
                y += 14
            }
        }
        return luma
    }

    func testAnalyzerFindsSingleTextBlock() {
        let luma = synth(pages: [(150, 810)], blocks: [(200, 760, 80, 480)])
        let m = GuidanceAnalyzer.analyze(luma: luma, width: 960, height: 540)
        XCTAssertTrue(m.hasPage)
        XCTAssertTrue(m.hasText)
        XCTAssertEqual(m.columns.count, 1)
        XCTAssertGreaterThan(m.x0, 0.17)
        XCTAssertLessThan(m.x0, 0.25)
        XCTAssertGreaterThan(m.x1, 0.70)
        XCTAssertLessThan(m.x1, 0.82)
        XCTAssertGreaterThan(m.y0, 0.10)
        XCTAssertLessThan(m.y0, 0.22)
        XCTAssertGreaterThan(m.y1, 0.82)
        XCTAssertLessThan(m.y1, 0.93)
        XCTAssertEqual(decide(m).advice == .moveLeft || decide(m).advice == .moveRight, false)
    }

    func testAnalyzerSplitsTwoColumns() {
        let luma = synth(pages: [(100, 860)], blocks: [(130, 440, 80, 480), (520, 830, 80, 480)])
        let m = GuidanceAnalyzer.analyze(luma: luma, width: 960, height: 540)
        XCTAssertTrue(m.hasText)
        XCTAssertEqual(m.columns.count, 2)
        if m.columns.count == 2 {
            XCTAssertLessThan(m.columns[0].x1, m.columns[1].x0)
        }
    }

    func testAnalyzerSeesTwoSeparatePagesAsTwoSections() {
        // dikişle ayrılmış yan yana iki sayfa: ikisi de sayfa sayılmalı
        let luma = synth(pages: [(60, 460), (500, 900)], blocks: [(90, 430, 80, 480), (530, 870, 80, 480)])
        let m = GuidanceAnalyzer.analyze(luma: luma, width: 960, height: 540)
        XCTAssertEqual(m.columns.count, 2)
    }

    func testBlurLowersSharpness() {
        let luma = synth(pages: [(150, 810)], blocks: [(200, 760, 80, 480)])
        let sharp = GuidanceAnalyzer.analyze(luma: luma, width: 960, height: 540)
        let blurred = GuidanceAnalyzer.boxBlur(GuidanceAnalyzer.boxBlur(luma, w: 960, h: 540, r: 2), w: 960, h: 540, r: 2)
        let soft = GuidanceAnalyzer.analyze(luma: blurred, width: 960, height: 540)
        XCTAssertGreaterThan(sharp.sharp, 0)
        XCTAssertLessThan(soft.sharp, sharp.sharp)
    }

    func testEmptyFrameHasNoText() {
        let luma = [Float](repeating: 90, count: 960 * 540)
        let m = GuidanceAnalyzer.analyze(luma: luma, width: 960, height: 540)
        XCTAssertFalse(m.hasText)
    }

    // MARK: - Sesli rapor

    // MARK: - Son fotoğrafı sil / yeniden çek

    // MARK: - Günlük sayaçlar

    // MARK: - Parlama

    func testGlareAdviceComesAfterPositionAndSharpness() {
        var m = metrics(x0: 0.2, x1: 0.8)
        m.glare = 0.08
        XCTAssertEqual(decide(m).advice, .glare)
        m.glare = 0.02
        XCTAssertEqual(decide(m).advice, .ok)
        var cut = metrics(x0: 0.01, x1: 0.8)
        cut.glare = 0.1
        XCTAssertEqual(decide(cut).advice, .moveLeft)
        var soft = metrics(x0: 0.2, x1: 0.8, sharp: 0.2)
        soft.glare = 0.1
        XCTAssertEqual(decide(soft).advice, .blurry)
        var off = GuidanceConfig()
        off.glareLimit = 2
        var g = metrics(x0: 0.2, x1: 0.8)
        g.glare = 0.5
        XCTAssertEqual(GuidanceAdvisor.decide(g, choice: nil, config: off, sharpFloor: 0.45).advice, .ok)
    }

    func testAnalyzerDetectsGlareBlobButNotSmallSpotsOrStrips() {
        let base = synth(pages: [(150, 810)], blocks: [(200, 760, 80, 480)])
        XCTAssertEqual(GuidanceAnalyzer.analyze(luma: base, width: 960, height: 540).glare, 0)

        var blob = base
        for y in 200..<320 { for x in 400..<520 { blob[y * 960 + x] = 255 } }
        let withBlob = GuidanceAnalyzer.analyze(luma: blob, width: 960, height: 540)
        XCTAssertTrue(withBlob.hasText)
        XCTAssertGreaterThan(withBlob.glare, 0.04)

        var spot = base
        for y in 200..<230 { for x in 400..<430 { spot[y * 960 + x] = 255 } }
        XCTAssertEqual(GuidanceAnalyzer.analyze(luma: spot, width: 960, height: 540).glare, 0)

        var strip = base
        for y in 300..<312 { for x in 250..<700 { strip[y * 960 + x] = 255 } }
        XCTAssertEqual(GuidanceAnalyzer.analyze(luma: strip, width: 960, height: 540).glare, 0)
    }

    // MARK: - Gerçek kamera kareleri ve ışık düşüşü (vinyet)

    func testVignettedEdgeTextStillCountsAsCut() {
        // Kenara doğru kararan görüntüde (vinyet) kenara dayanan yazı satırı kısa görünmemeli
        var luma = synth(pages: [(0, 960)], blocks: [(0, 700, 80, 480)])
        for y in 0..<540 {
            for x in 0..<960 {
                let gain = Float(0.45 + 0.55 * min(1.0, Double(x) / 200.0))
                luma[y * 960 + x] *= gain
            }
        }
        let m = GuidanceAnalyzer.analyze(luma: luma, width: 960, height: 540)
        XCTAssertTrue(m.hasText)
        XCTAssertLessThan(m.x0, 0.02, "kenara dayanan yazı kenarda sayılmalı: \(m.x0)")
        XCTAssertEqual(decide(m).advice, .moveLeft)
    }

    func testRealFramesLeftCardCutAsksWhichColumn() {
        for (name, data) in [("A", RealFrames.leftCutA), ("B", RealFrames.leftCutB)] {
            guard let f = RealFrames.luma(data) else { return XCTFail("kare çözülemedi: \(name)") }
            XCTAssertEqual(f.w, 960)
            XCTAssertEqual(f.h, 540)
            let m = GuidanceAnalyzer.analyze(luma: f.px, width: f.w, height: f.h)
            XCTAssertEqual(m.columns.count, 2, "\(name): \(m.summary)")
            XCTAssertLessThan(m.columns.first?.x0 ?? 1, 0.02, "\(name): soldaki kart kenarda kesik")
            XCTAssertEqual(decide(m).advice, .chooseColumn, name)
            XCTAssertEqual(decide(m, .left).advice, .moveLeft, name)
            XCTAssertEqual(decide(m, .right).advice, .ok, "\(name): sağdaki kart tam görünüyor")
            XCTAssertEqual(m.glare, 0, name)
        }
    }

    func testRealFrameBothCardsFullDoesNotAsk() {
        guard let f = RealFrames.luma(RealFrames.bothFull) else { return XCTFail("kare çözülemedi") }
        let m = GuidanceAnalyzer.analyze(luma: f.px, width: f.w, height: f.h)
        XCTAssertEqual(m.columns.count, 2, m.summary)
        XCTAssertEqual(decide(m).advice, .ok, m.summary)
    }

    func testRealFrameWithGlareSpotIsFlagged() {
        guard var f = RealFrames.luma(RealFrames.leftCutA) else { return XCTFail("kare çözülemedi") }
        // sağ kartın yazısının üstüne parlama lekesi (doymuş beyaz elips)
        for y in 0..<f.h {
            for x in 0..<f.w {
                let dx = Double(x - 720) / 90.0
                let dy = Double(y - 300) / 70.0
                if dx * dx + dy * dy <= 1 { f.px[y * f.w + x] = 255 }
            }
        }
        let m = GuidanceAnalyzer.analyze(luma: f.px, width: f.w, height: f.h)
        XCTAssertGreaterThan(m.glare, 0.04, m.summary)
    }

    // MARK: - Hassas yönlendirme: yakınlaşmadan önce ortalama, tekrarda "biraz daha", bulanıklıkta doluluk

    private func firstSpeech(_ e: GuidanceEngine, _ m: PageMetrics) -> String? {
        var spoken: String?
        for i in 0..<4 where spoken == nil {
            spoken = step(e, m, t: Double(i) * 0.3).speak
        }
        return spoken
    }

    func testAdvisorCentresBeforeZoomingIn() {
        // yazı küçük ama kenara yakın: yakınlaşınca taşar, önce o yöne kaydırılır
        XCTAssertEqual(decide(metrics(x0: 0.05, x1: 0.30, y0: 0.30, y1: 0.50, cells: 150)).advice, .moveLeft)
        XCTAssertEqual(decide(metrics(x0: 0.70, x1: 0.95, y0: 0.30, y1: 0.50, cells: 150)).advice, .moveRight)
        XCTAssertEqual(decide(metrics(x0: 0.40, x1: 0.60, y0: 0.12, y1: 0.25, cells: 150)).advice, .moveUp)
        XCTAssertEqual(decide(metrics(x0: 0.40, x1: 0.60, y0: 0.75, y1: 0.97, cells: 150)).advice, .moveDown)
        // ortadaysa doğrudan yaklaşılır
        XCTAssertEqual(decide(metrics(x0: 0.40, x1: 0.60, y0: 0.40, y1: 0.60, cells: 150)).advice, .closer)
    }

    func testDecisionReportsFillAndScale() {
        let d = decide(metrics(x0: 0.40, x1: 0.60, y0: 0.40, y1: 0.60, cells: 150))
        XCTAssertEqual(d.fill, 0.2, accuracy: 0.001)
        XCTAssertEqual(d.scale, 1.6, accuracy: 0.001, "büyütme en çok 1,6 sayılır")
        let ok = decide(metrics(x0: 0.15, x1: 0.85, y0: 0.15, y1: 0.85))
        XCTAssertEqual(ok.advice, .ok)
        XCTAssertEqual(ok.fill, 0.7, accuracy: 0.001)
        XCTAssertEqual(ok.scale, 1.0, accuracy: 0.001)
    }

    func testCloserWordingDependsOnHowMuchIsNeeded() {
        // çok küçük: "Yaklaşın"; sınıra yakın: "Biraz yaklaşın"
        XCTAssertEqual(firstSpeech(GuidanceEngine(), metrics(x0: 0.40, x1: 0.60, y0: 0.40, y1: 0.60, cells: 150)),
                       "Yaklaşın, yazı küçük kalıyor.")
        XCTAssertEqual(firstSpeech(GuidanceEngine(), metrics(x0: 0.24, x1: 0.76, y0: 0.30, y1: 0.70, cells: 150)),
                       "Biraz yaklaşın.")
    }

    func testRepeatedAdviceUsesShorterWording() {
        let e = GuidanceEngine()
        let m = metrics(x0: 0.4, x1: 0.995)
        var spoken: [String] = []
        var t = 0.0
        while t < 20 {
            if let s = step(e, m, t: t).speak { spoken.append(s) }
            t += 0.3
        }
        XCTAssertEqual(spoken.first, "Kamerayı epey sağa kaydırın.")
        XCTAssertGreaterThan(spoken.count, 1)
        XCTAssertEqual(spoken[1], "Biraz daha sağa kaydırın.", "tekrarda ilerleme beklenir")
    }

    func testBlurAdviceDependsOnFill() {
        // yazı kadrajı dolduruyor: büyük olasılıkla fazla yakın → önce uzaklaş
        XCTAssertEqual(firstSpeech(GuidanceEngine(), metrics(x0: 0.10, x1: 0.90, sharp: 0.2)),
                       "Görüntü net değil. Biraz uzaklaşın.")
        // küçük blok: önce kamerayı sabit tutup bekle
        XCTAssertEqual(firstSpeech(GuidanceEngine(), metrics(x0: 0.30, x1: 0.70, y0: 0.30, y1: 0.70, cells: 60, sharp: 0.2)),
                       "Görüntü net değil. Kamerayı sabit tutup bekleyin.")
    }

    func testNonTextLikePatternIsTreatedAsNoText() {
        var m = metrics(x0: 0.2, x1: 0.8)
        m.glyphs = 0
        m.glyphShare = 0
        XCTAssertEqual(decide(m).advice, .noText)
        m.glyphs = 300
        m.glyphShare = 0.9
        XCTAssertEqual(decide(m).advice, .ok)
        XCTAssertEqual(decide(metrics(x0: 0.2, x1: 0.8, cells: 20)).advice, .noText, "çok az yazı belge sayılmaz")
    }

    // MARK: - Yönlendirme: miktar, köşe, gidiş (doğru / ters / fazla) ve "Tamam" onayı

    private func feed(_ e: GuidanceEngine, _ m: PageMetrics, at times: [Double], still: Double = 1.0) -> [String] {
        var spoken: [String] = []
        for t in times {
            if let s = step(e, m, t: t, still: still).speak { spoken.append(s) }
        }
        return spoken
    }

    func testShiftAmountIsGradedIntoAzicikBirazEpey() {
        let slight = metrics(x0: 0.06, x1: 0.99)
        let some = metrics(x0: 0.20, x1: 0.99)
        let lot = metrics(x0: 0.40, x1: 0.995)
        XCTAssertEqual(decide(slight).shift, 0.025, accuracy: 0.002)
        XCTAssertEqual(decide(some).shift, 0.095, accuracy: 0.002)
        XCTAssertEqual(decide(lot).shift, 0.1975, accuracy: 0.002)
        XCTAssertEqual(firstSpeech(GuidanceEngine(), slight), "Kamerayı azıcık sağa kaydırın.")
        XCTAssertEqual(firstSpeech(GuidanceEngine(), some), "Kamerayı biraz sağa kaydırın.")
        XCTAssertEqual(firstSpeech(GuidanceEngine(), lot), "Kamerayı epey sağa kaydırın.")
        XCTAssertEqual(GuidanceAdvisor.amountWord(shift: 0), "azıcık")
        XCTAssertEqual(GuidanceAdvisor.amountWord(shift: 0.05), "biraz")
        XCTAssertEqual(GuidanceAdvisor.amountWord(shift: 0.14), "epey")
    }

    func testShiftBeforeZoomingInIsMeasuredToo() {
        let d = decide(metrics(x0: 0.05, x1: 0.30, y0: 0.30, y1: 0.50, cells: 150))
        XCTAssertEqual(d.advice, .moveLeft)
        XCTAssertEqual(d.shift, 0.156, accuracy: 0.003, "yakınlaşınca taşacak miktar, büyütmeye bölünür")
        XCTAssertNil(d.also)
    }

    func testCornerTextNamesBothDirectionsInOneSentence() {
        let corner = metrics(x0: 0.004, x1: 0.80, y0: GuidanceAnalyzer.skipTop + 0.01, y1: 0.80)
        let d = decide(corner)
        XCTAssertEqual(d.advice, .moveLeft)
        XCTAssertEqual(d.also, .moveUp)
        XCTAssertEqual(d.shift, 0.098, accuracy: 0.003)
        XCTAssertEqual(d.alsoShift, 0.095, accuracy: 0.003)
        XCTAssertEqual(firstSpeech(GuidanceEngine(), corner), "Kamerayı biraz sola ve yukarı kaydırın.")
        // tek kenara dayalıysa ikinci yön yok
        XCTAssertNil(decide(metrics(x0: 0.005, x1: 0.6)).also)
    }

    func testSaysRightWhenTheCameraMovedTheRightWay() {
        let e = GuidanceEngine()
        let far = metrics(x0: 0.4, x1: 0.995)
        XCTAssertEqual(feed(e, far, at: [0, 0.3, 0.6]), ["Kamerayı epey sağa kaydırın."])
        _ = feed(e, far, at: [1.0, 1.3], still: 0.1)   // kamera hareket ediyor: ölçüm yok
        // yazı sola kaydı, kalan kaydırma azaldı
        XCTAssertEqual(feed(e, metrics(x0: 0.25, x1: 0.985), at: [3.0, 3.3, 3.6]), ["Doğru. Biraz daha sağa kaydırın."])
    }

    func testSaysWrongWayWhenTheRemainingShiftGrew() {
        let e = GuidanceEngine()
        let far = metrics(x0: 0.4, x1: 0.995)
        _ = feed(e, far, at: [0, 0.3, 0.6])
        _ = feed(e, far, at: [1.0, 1.3], still: 0.1)
        XCTAssertEqual(feed(e, metrics(x0: 0.55, x1: 0.999), at: [3.0, 3.3, 3.6]),
                       ["Ters yöne gittiniz. Kamerayı epey sağa kaydırın."])
    }

    func testSaysOvershotWhenTheAdviceFlipsToTheOtherSide() {
        let e = GuidanceEngine()
        let far = metrics(x0: 0.4, x1: 0.995)
        _ = feed(e, far, at: [0, 0.3, 0.6])
        _ = feed(e, far, at: [1.0, 1.3], still: 0.1)
        XCTAssertEqual(feed(e, metrics(x0: 0.005, x1: 0.6), at: [3.0, 3.3, 3.6]),
                       ["Fazla sağa kaydırdınız. Epey sola kaydırın."])
    }

    func testZoomTrendRightAndOvershoot() {
        let small = metrics(x0: 0.40, x1: 0.60, y0: 0.40, y1: 0.60, cells: 150)
        let bigger = metrics(x0: 0.25, x1: 0.75, y0: 0.25, y1: 0.75, cells: 150)
        let wide = metrics(x0: 0.005, x1: 0.995)

        let a = GuidanceEngine()
        XCTAssertEqual(feed(a, small, at: [0, 0.3, 0.6]), ["Yaklaşın, yazı küçük kalıyor."])
        _ = feed(a, small, at: [1.0, 1.3], still: 0.1)
        XCTAssertEqual(feed(a, bigger, at: [3.0, 3.3, 3.6]), ["Doğru. Biraz daha yaklaşın."])

        let b = GuidanceEngine()
        _ = feed(b, small, at: [0, 0.3, 0.6])
        _ = feed(b, small, at: [1.0, 1.3], still: 0.1)
        XCTAssertEqual(feed(b, wide, at: [3.0, 3.3, 3.6]), ["Fazla yaklaştınız. Biraz uzaklaşın."])
    }

    func testStuckAdviceEscalatesThenOffersTheTriggerWord() {
        let e = GuidanceEngine()
        let spoken = feed(e, metrics(x0: 0.4, x1: 0.995), at: (0..<200).map { Double($0) * 0.3 })
        XCTAssertEqual(spoken.count, 5, "\(spoken)")
        XCTAssertEqual(spoken[0], "Kamerayı epey sağa kaydırın.")
        XCTAssertEqual(spoken[1], "Biraz daha sağa kaydırın.")
        XCTAssertTrue(spoken[2].hasPrefix("Hâlâ aynı yönde."), spoken[2])
        XCTAssertTrue(spoken[3].hasPrefix("Hâlâ aynı yönde."), spoken[3])
        XCTAssertTrue(spoken[4].contains("okey diyerek yine de çekebilirsiniz"), spoken[4])
    }

    func testTrendTrackerWindowSlowDriftAndReset() {
        var tr = GuidanceTrendTracker()
        let c = GuidanceConfig()
        // yavaş kayma: her adım küçük, toplamı eşiği aşınca "doğru"
        tr.observe(.moveRight, need: 0.20, time: 0, config: c)
        tr.observe(.moveRight, need: 0.19, time: 0.3, config: c)
        tr.observe(.moveRight, need: 0.18, time: 0.6, config: c)
        XCTAssertEqual(tr.peek(at: 0.6, config: c), .steady)
        tr.observe(.moveRight, need: 0.16, time: 0.9, config: c)
        XCTAssertEqual(tr.take(at: 0.9, config: c), .better)
        XCTAssertEqual(tr.peek(at: 0.9, config: c), .steady, "söylenince silinir")
        // çok eski karşılaştırma geçersiz: yeni başlangıç sayılır
        tr.observe(.moveRight, need: 0.10, time: 40, config: c)
        XCTAssertEqual(tr.peek(at: 40, config: c), .steady)
        tr.observe(.moveRight, need: 0.20, time: 41, config: c)
        XCTAssertEqual(tr.peek(at: 41, config: c), .worse)
        // süresi dolan gidiş söylenmez
        XCTAssertEqual(tr.peek(at: 70, config: c), .steady)
        // konum uygun olunca karşılaştırma silinir
        tr.observe(.ok, need: nil, time: 71, config: c)
        tr.observe(.moveRight, need: 0.05, time: 72, config: c)
        XCTAssertEqual(tr.peek(at: 72, config: c), .steady)
    }

    func testVideoTellsOkOnceAfterACorrection() {
        let e = GuidanceEngine()
        var spoken: [String] = []
        for i in 0..<8 {
            if let t = vstep(e, metrics(x0: 0.4, x1: 0.995), t: Double(i) * 0.3).speak { spoken.append(t) }
        }
        for i in 0..<6 {
            if let t = vstep(e, metrics(x0: 0.2, x1: 0.8), t: 5 + Double(i) * 0.3).speak { spoken.append(t) }
        }
        XCTAssertEqual(spoken, ["Kamerayı epey sağa kaydırın.", "Tamam, böyle."])
    }

    func testVideoFlickerOfOneGoodFrameDoesNotSayOk() {
        let e = GuidanceEngine()
        let cut = metrics(x0: 0.4, x1: 0.995)
        var spoken: [String] = []
        for i in 0..<4 { if let t = vstep(e, cut, t: Double(i) * 0.3).speak { spoken.append(t) } }
        if let t = vstep(e, metrics(x0: 0.2, x1: 0.8), t: 2).speak { spoken.append(t) }
        for i in 0..<3 { if let t = vstep(e, cut, t: 3 + Double(i) * 0.3).speak { spoken.append(t) } }
        XCTAssertFalse(spoken.contains("Tamam, böyle."), "tek ölçümlük uygun kare onay sayılmaz: \(spoken)")
        XCTAssertEqual(spoken.first, "Kamerayı epey sağa kaydırın.")
    }

    func testBlurWhenFrameIsFullSaysTooClose() {
        XCTAssertEqual(firstSpeech(GuidanceEngine(), metrics(x0: 0.04, x1: 0.96, sharp: 0.2)),
                       "Görüntü net değil, çok yakınsınız. Biraz uzaklaşın.")
    }

    // MARK: - Kadrajın tarifi (kaç sayfa, hangisi sığıyor)

    private func scene(_ m: PageMetrics) -> String? {
        return GuidanceScene.describe(GuidanceScene.parts(m, config: GuidanceConfig()))
    }

    func testSceneDescribesASinglePage() {
        XCTAssertEqual(scene(metrics(x0: 0.2, x1: 0.8)), "Tek sayfa görünüyor, tam sığıyor.")
        XCTAssertEqual(scene(metrics(x0: 0.005, x1: 0.6)), "Tek sayfa görünüyor, sol tarafı kesik.")
        XCTAssertEqual(scene(metrics(x0: 0.4, x1: 0.995)), "Tek sayfa görünüyor, sağ tarafı kesik.")
        XCTAssertEqual(scene(metrics(x0: 0.005, x1: 0.995)), "Tek sayfa görünüyor, iki yanı kesik.")
        XCTAssertEqual(scene(metrics(x0: 0.2, x1: 0.8, y0: 0.3, y1: 0.995)), "Tek sayfa görünüyor, alt kısmı kesik.")
        XCTAssertEqual(scene(metrics(x0: 0.004, x1: 0.80, y0: GuidanceAnalyzer.skipTop + 0.01, y1: 0.80)),
                       "Tek sayfa görünüyor, sol tarafı ve üst kısmı kesik.")
        XCTAssertNil(scene(PageMetrics()), "yazı yoksa tarif yok")
    }

    func testSceneDescribesTwoPages() {
        XCTAssertEqual(scene(twoColumns(left: col(0.13, 0.49), right: col(0.51, 0.88))),
                       "İki sayfa görünüyor, ikisi de tam sığıyor.")
        XCTAssertEqual(scene(twoColumns(left: col(0.04, 0.57), right: col(0.60, 1.0))),
                       "İki sayfa görünüyor. Soldaki tam sığıyor, sağdakinin bir bölümü görünüyor.")
        XCTAssertEqual(scene(twoColumns(left: col(0.0, 0.40), right: col(0.43, 0.94))),
                       "İki sayfa görünüyor. Sağdaki tam sığıyor, soldakinin bir bölümü görünüyor.")
        XCTAssertEqual(scene(twoColumns(left: col(0.0, 0.45), right: col(0.55, 1.0))),
                       "İki sayfa görünüyor, ikisinin de bir bölümü görünüyor.")
        XCTAssertEqual(scene(twoColumns(left: col(0.10, 0.45, y0: 0.3, y1: 0.995), right: col(0.55, 0.90, y0: 0.3, y1: 0.995))),
                       "İki sayfa görünüyor, ikisinin de alt kısmı kesik.")
        XCTAssertEqual(scene(twoColumns(left: col(0.10, 0.45, y0: 0.3, y1: 0.995), right: col(0.55, 1.0))),
                       "İki sayfa görünüyor. Soldakinin alt kısmı kesik, sağdakinin bir bölümü görünüyor.")
    }

    func testSceneDescribesThreeOrMoreSections() {
        let cut = metrics(x0: 0.06, x1: 1.0, columns: [col(0.06, 0.43), col(0.45, 0.82), col(0.84, 1.0)])
        XCTAssertEqual(scene(cut), "Üç bölüm görünüyor. Soldaki ve ortadaki tam sığıyor, sağdakinin bir bölümü görünüyor.")
        let fit = metrics(x0: 0.05, x1: 0.95, columns: [col(0.05, 0.30), col(0.36, 0.64), col(0.70, 0.95)])
        XCTAssertEqual(scene(fit), "Üç bölüm görünüyor, hepsi tam sığıyor.")
        let four = metrics(x0: 0.05, x1: 1.0, columns: [col(0.05, 0.22), col(0.28, 0.46), col(0.52, 0.72), col(0.78, 1.0)])
        XCTAssertEqual(scene(four), "Dört bölüm görünüyor, bazıları kesik.")
    }

    func testSceneIsSilentWhenTheSettingIsOff() {
        let e = GuidanceEngine()
        XCTAssertFalse(e.describeScene)
        XCTAssertEqual(firstSpeech(e, metrics(x0: 0.4, x1: 0.995)), "Kamerayı epey sağa kaydırın.")
    }

    func testSceneIsToldOnceWithTheFirstAdviceAndAgainWhenItChanges() {
        let e = GuidanceEngine()
        e.describeScene = true
        var spoken: [String] = []
        var t = 0.0
        while t < 14 {
            if let s = step(e, metrics(x0: 0.4, x1: 0.995), t: t).speak { spoken.append(s) }
            t += 0.3
        }
        XCTAssertEqual(spoken.first, "Tek sayfa görünüyor, sağ tarafı kesik. Kamerayı epey sağa kaydırın.")
        XCTAssertEqual(spoken[1], "Biraz daha sağa kaydırın.", "aynı tarif tekrar söylenmez")

        // kamera kaydı: tarif değişti, yeniden söylenir
        let f = GuidanceEngine()
        f.describeScene = true
        let far = metrics(x0: 0.4, x1: 0.995)
        _ = feed(f, far, at: [0, 0.3, 0.6])
        _ = feed(f, far, at: [1.0, 1.3], still: 0.1)
        XCTAssertEqual(feed(f, metrics(x0: 0.005, x1: 0.6), at: [3.0, 3.3, 3.6]),
                       ["Tek sayfa görünüyor, sol tarafı kesik. Fazla sağa kaydırdınız. Epey sola kaydırın."])
    }

    func testOkAfterACorrectionRepeatsTheFinalScene() {
        let e = GuidanceEngine()
        e.describeScene = true
        var spoken = feed(e, metrics(x0: 0.4, x1: 0.995), at: [0, 0.3])
        spoken += feed(e, metrics(x0: 0.2, x1: 0.8), at: [3.0, 3.3])
        XCTAssertEqual(spoken, ["Tek sayfa görünüyor, sağ tarafı kesik. Kamerayı epey sağa kaydırın.",
                                "Tamam. Tek sayfa görünüyor, tam sığıyor."])
    }

    func testVideoDescribesTheFrameWithTheAdviceAndTheConfirmation() {
        let e = GuidanceEngine()
        e.describeScene = true
        var spoken: [String] = []
        for i in 0..<8 {
            if let t = vstep(e, metrics(x0: 0.4, x1: 0.995), t: Double(i) * 0.3).speak { spoken.append(t) }
        }
        for i in 0..<4 {
            if let t = vstep(e, metrics(x0: 0.2, x1: 0.8), t: 5 + Double(i) * 0.3).speak { spoken.append(t) }
        }
        XCTAssertEqual(spoken, ["Tek sayfa görünüyor, sağ tarafı kesik. Kamerayı epey sağa kaydırın.",
                                "Tamam, böyle. Tek sayfa görünüyor, tam sığıyor."])
    }
}
