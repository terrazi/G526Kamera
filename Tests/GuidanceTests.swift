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

    // MARK: - Durum makinesi

    private func step(_ e: GuidanceEngine, _ m: PageMetrics, t: Double, still: Double = 1.0,
                      diff: Double = 100) -> GuidanceEngine.Output {
        return e.step(m, time: t, stillFor: still, diffToCapture: diff)
    }

    func testCapturesAfterStableOkThenWaitsForSceneChange() {
        let e = GuidanceEngine()
        let m = metrics(x0: 0.2, x1: 0.8)
        var captured = false
        for i in 0..<4 where !captured {
            captured = step(e, m, t: Double(i) * 0.3).capture
        }
        XCTAssertTrue(captured)
        XCTAssertFalse(e.armed)
        for i in 0..<10 {
            XCTAssertFalse(step(e, m, t: 5 + Double(i) * 0.3, diff: 0.5).capture, "aynı sahne ikinci kez çekilmemeli")
        }
        var again = false
        for i in 0..<5 where !again {
            again = step(e, m, t: 20 + Double(i) * 0.3, diff: 10).capture
        }
        XCTAssertTrue(again, "sayfa çevrilince yeniden çekmeli")
    }

    func testDoesNotCaptureWhileMoving() {
        let e = GuidanceEngine()
        let m = metrics(x0: 0.2, x1: 0.8)
        for i in 0..<6 {
            let o = step(e, m, t: Double(i) * 0.3, still: 0.1)
            XCTAssertFalse(o.capture)
            XCTAssertTrue(o.status.contains("hareket"))
        }
    }

    func testManualModeDoesNotAutoCapture() {
        let e = GuidanceEngine()
        e.autoCapture = false
        let m = metrics(x0: 0.2, x1: 0.8)
        for i in 0..<6 {
            XCTAssertFalse(step(e, m, t: Double(i) * 0.3).capture)
        }
    }

    func testSpeaksDirectionOnceThenRateLimits() {
        let e = GuidanceEngine()
        let m = metrics(x0: 0.4, x1: 0.995)
        var spoken: [String] = []
        for i in 0..<6 {
            if let s = step(e, m, t: Double(i) * 0.3).speak { spoken.append(s) }
        }
        XCTAssertEqual(spoken, ["Kamerayı biraz sağa kaydırın."])
    }

    // MARK: - Video kaydı sırasında konum tarifi

    private func vstep(_ e: GuidanceEngine, _ m: PageMetrics, t: Double, still: Double = 2.0) -> GuidanceEngine.Output {
        return e.videoStep(m, time: t, stillFor: still)
    }

    func testVideoStepSpeaksDirectionButNeverCapturesOrAsks() {
        let e = GuidanceEngine()
        let m = metrics(x0: 0.4, x1: 0.995)
        var spoken: [String] = []
        for i in 0..<8 {
            let out = vstep(e, m, t: Double(i) * 0.3)
            XCTAssertFalse(out.capture)
            XCTAssertFalse(out.awaitingChoice)
            if let t = out.speak { spoken.append(t) }
        }
        XCTAssertEqual(spoken, ["Kamerayı biraz sağa kaydırın."])
    }

    func testVideoStepGoodFrameIsSilentAndNeverCaptures() {
        let e = GuidanceEngine()
        for i in 0..<20 {
            let out = vstep(e, metrics(x0: 0.2, x1: 0.8), t: Double(i) * 0.3)
            XCTAssertNil(out.speak)
            XCTAssertFalse(out.capture)
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

    func testVideoStepDoesNotTouchPhotoState() {
        let e = GuidanceEngine()
        _ = e.setChoice(.left)
        for i in 0..<5 { _ = vstep(e, metrics(x0: 0.4, x1: 0.995), t: Double(i)) }
        XCTAssertEqual(e.choice, .left)
        e.resetVideo()
        XCTAssertEqual(e.choice, .left)
    }

    func testQuestionIsAskedRepeatedlyThenGivesUp() {
        let e = GuidanceEngine()
        let m = twoColumns(left: col(0.04, 0.57), right: col(0.60, 1.0))
        var spoken: [String] = []
        for t in [0.0, 0.3, 0.6, 10.0, 20.0, 30.0, 45.0] {
            let o = step(e, m, t: t)
            XCTAssertTrue(o.awaitingChoice)
            if let s = o.speak { spoken.append(s) }
        }
        XCTAssertEqual(spoken.count, 4)
        XCTAssertTrue(spoken[0].contains("Sol mu, sağ mı"))
        XCTAssertTrue(spoken[3].contains("Sesli yanıt alamadım"))
        XCTAssertTrue(e.awaitingChoice)
    }

    func testChoiceThenCaptureThenAsksAgainRememberingLast() {
        let e = GuidanceEngine()
        let m = twoColumns(left: col(0.04, 0.57), right: col(0.60, 1.0))
        _ = step(e, m, t: 0)
        _ = step(e, m, t: 0.3)
        XCTAssertEqual(e.setChoice(.left), "Tamam, sol bölüm.")
        XCTAssertFalse(e.awaitingChoice)
        var captured = false
        for i in 0..<5 where !captured {
            captured = step(e, m, t: 1 + Double(i) * 0.3).capture
        }
        XCTAssertTrue(captured)
        XCTAssertEqual(e.lastCaptured, .left)
        XCTAssertNil(e.choice)

        // kullanıcı kamerayı kaydırdı: sahne değişti, yine yarım bölüm var → yeniden sorulur
        var question: String?
        for i in 0..<4 where question == nil {
            question = step(e, m, t: 20 + Double(i) * 0.3, diff: 12).speak
        }
        XCTAssertNotNil(question)
        XCTAssertTrue(question?.contains("Sol bölüm çekildi") ?? false)
    }

    func testRechooseClearsChoice() {
        let e = GuidanceEngine()
        e.setChoice(.right)
        XCTAssertEqual(e.choice, .right)
        _ = e.clearChoice()
        XCTAssertNil(e.choice)
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

    // MARK: - Sesli komut sözcükleri

    private func hits(_ text: String, _ choice: ColumnChoice, loose: Bool = false) -> Int {
        return SpeechMatcher.tokenOccurrences(in: text, tokens: choice.tokens, looseTokens: choice.looseTokens, loose: loose)
    }

    func testChoiceVariants() {
        for phrase in ["sol", "Sola", "soldaki", "sol taraf", "sol tarafta", "Sol taraftaki sütun", "sol sayfa",
                       "sol sütun", "sol tarafındaki bölüm", "solda olan"] {
            XCTAssertGreaterThan(hits(phrase, .left), 0, phrase)
            XCTAssertEqual(hits(phrase, .right), 0, phrase)
        }
        for phrase in ["sağ", "Sağa", "sağdaki", "sağ taraf", "sağ taraftaki", "sağ sütun", "sağ sayfa",
                       "sağ tarafındaki bölüm", "sağdan"] {
            XCTAssertGreaterThan(hits(phrase, .right), 0, phrase)
            XCTAssertEqual(hits(phrase, .left), 0, phrase)
        }
        for phrase in ["orta", "ortadaki", "orta sütun", "ortadaki sayfa"] {
            XCTAssertGreaterThan(hits(phrase, .middle), 0, phrase)
        }
        for phrase in ["ikisi", "ikisi birden", "ikisini de", "hepsini", "tamamı", "üçü de"] {
            XCTAssertGreaterThan(hits(phrase, .all), 0, phrase)
        }
    }

    func testLooseMatchingOnlyWhenWaiting() {
        XCTAssertEqual(hits("so", .left, loose: false), 0)
        XCTAssertEqual(hits("so", .left, loose: true), 1)
        XCTAssertEqual(hits("sor", .left, loose: true), 1)
        XCTAssertEqual(hits("sor", .right, loose: true), 0)
        XCTAssertEqual(hits("sa", .right, loose: true), 1)
        XCTAssertEqual(hits("sak", .right, loose: true), 1)
        // hem sol hem sağa benzeyen duyum belirsizdir (AppModel/SpeechTrigger bunu "anlaşılmadı" sayar)
        XCTAssertEqual(hits("sal", .left, loose: true), 1)
        XCTAssertEqual(hits("sal", .right, loose: true), 1)
    }

    func testOrdinalChoices() {
        func count(_ text: String, _ tokens: [String]) -> Int {
            return SpeechMatcher.tokenOccurrences(in: text, tokens: tokens, looseTokens: [], loose: true)
        }
        XCTAssertEqual(count("birinci sütun", GuidanceVocabulary.first), 1)
        XCTAssertEqual(count("ilk", GuidanceVocabulary.first), 1)
        XCTAssertEqual(count("ikinci sütun", GuidanceVocabulary.second), 1)
        XCTAssertEqual(count("üçüncü", GuidanceVocabulary.last), 1)
        XCTAssertEqual(count("son", GuidanceVocabulary.last), 1)
        XCTAssertEqual(count("sol", GuidanceVocabulary.last), 0)
    }

    func testFinishReportAndRechoosePhrases() {
        func n(_ text: String, _ phrases: String) -> Int {
            return SpeechMatcher.occurrences(in: text, trigger: phrases)
        }
        for t in ["hepsi tamamlandı", "Hepsi tamamlandı.", "hepsi bitti", "hepsini gönder", "işlem tamamlandı", "çekim bitti"] {
            XCTAssertEqual(n(t, GuidanceVocabulary.finish), 1, t)
        }
        XCTAssertEqual(n("okey", GuidanceVocabulary.finish), 0)
        for t in ["rapor ver", "Rapor", "durum raporu", "kaç sayfa çekildi"] {
            XCTAssertEqual(n(t, GuidanceVocabulary.report), 1, t)
        }
        for t in ["yeniden seç", "tekrar seç", "seçimi değiştir"] {
            XCTAssertEqual(n(t, GuidanceVocabulary.rechoose), 1, t)
        }
        XCTAssertEqual(n("hepsi tamamlandı", GuidanceVocabulary.rechoose), 0)
    }

    private func intent(_ i: SpeechIntent, _ text: String) -> Int {
        return i.count(in: text)
    }

    func testManyWaysToSayFinishAndSend() {
        for t in ["hepsi tamamlandı", "Hepsini gönder", "tümünü gönder", "tamamını gönder", "bütün sayfaları gönder",
                  "gönder", "gönderebilirsin", "gönderir misin", "pdf yap", "PDF oluştur", "pdf'e çevir",
                  "çekimler tamam", "işlem tamam", "hepsi tamam", "hepsi bitti", "bitirdim", "çekim bitti",
                  "yükle", "dosyaları yolla", "fotoğrafları gönderebilirsin", "hepsini drive'a gönder",
                  "tamamlandı", "sayfaları pdf yapıp gönder", "bütün çekimleri tek pdf olarak gönder"] {
            XCTAssertGreaterThan(intent(GuidanceVocabulary.finishIntent, t), 0, t)
        }
    }

    func testFinishDoesNotFireOnOtherCommands() {
        for t in ["tamam", "okey", "sol", "sağ sütun", "rapor ver", "kaç sayfa gönderildi", "kaç sayfa çekildi",
                  "yeniden seç", "ikisi birden", "merhaba"] {
            XCTAssertEqual(intent(GuidanceVocabulary.finishIntent, t), 0, t)
        }
    }

    /// Sayfa çevirirken, kitabı tutarken, kendi kendine konuşurken söylenenler PDF göndermemeli / fotoğraf silmemeli
    func testEverydaySpeechDoesNotSendOrDelete() {
        for t in ["tamam sayfayı çevirdim", "sayfayı çevir", "şimdi sayfayı çevireyim", "sayfayı geri çevir", "bu sayfa bitti",
                  "bu sayfa tamam", "sayfa tamam", "fotoğrafı kaydet", "film bitti", "ders bitti", "bitti mi",
                  "kitabı kaldır", "kitabı biraz kaldır", "şunu kaldırayım", "bana bu sayfayı özetle", "hazırım", "evet",
                  "bir sonraki sayfaya geçelim", "bu fotoğraf güzel çıkmış", "pdf açıldı"] {
            XCTAssertEqual(intent(GuidanceVocabulary.finishIntent, t), 0, "finish: " + t)
            XCTAssertEqual(intent(GuidanceVocabulary.deleteLastIntent, t) + phraseHits(t, GuidanceVocabulary.deleteLast), 0, "sil: " + t)
        }
        XCTAssertEqual(intent(GuidanceVocabulary.reportIntent, "bana bu sayfayı özetle"), 0)
        // ama kapsam sözcüğü varsa yine çalışır
        for t in ["hepsi bitti", "tüm sayfalar tamam", "hepsini kaydet", "pdf'e çevir", "sayfaları pdf yap", "çekim bitti"] {
            XCTAssertGreaterThan(intent(GuidanceVocabulary.finishIntent, t), 0, t)
        }
    }

    func testManyWaysToAskForReport() {
        for t in ["rapor ver", "rapor", "özet ver", "durum ne", "durum raporu", "kaç sayfa çekildi",
                  "kaç sayfa gönderildi", "kaç tane çekildi", "kaç fotoğraf oldu"] {
            XCTAssertGreaterThan(intent(GuidanceVocabulary.reportIntent, t), 0, t)
        }
        for t in ["hepsini gönder", "sol", "okey", "tümünü gönder"] {
            XCTAssertEqual(intent(GuidanceVocabulary.reportIntent, t), 0, t)
        }
    }

    func testManyWaysToChooseAgain() {
        for t in ["yeniden seç", "tekrar seç", "başka sütun", "başka sayfa", "seçimi değiştir", "değiştir",
                  "vazgeç", "iptal", "yeniden sor"] {
            XCTAssertGreaterThan(intent(GuidanceVocabulary.rechooseIntent, t), 0, t)
        }
        for t in ["sol", "sağ", "hepsini gönder", "rapor ver", "sayfa"] {
            XCTAssertEqual(intent(GuidanceVocabulary.rechooseIntent, t), 0, t)
        }
    }

    // MARK: - Sesli rapor

    func testReportText() {
        let t = SpokenReport.make(captured: 12, sentPhotos: 10, sentDocs: 1, waiting: 2, folderReady: true,
                                  hasError: false, pdf: true, batchMode: true)
        XCTAssertTrue(t.contains("12 sayfanın fotoğrafı çekildi"), t)
        XCTAssertTrue(t.contains("10 sayfa 1 PDF olarak klasöre kaydedildi"), t)
        XCTAssertTrue(t.contains("2 sayfa gönderilmeyi bekliyor"), t)
        XCTAssertTrue(t.contains("hepsi tamamlandı deyin"), t)
    }

    func testReportTextEmptyAndProblems() {
        let empty = SpokenReport.make(captured: 0, sentPhotos: 0, sentDocs: 0, waiting: 0, folderReady: true,
                                      hasError: false, pdf: true, batchMode: true)
        XCTAssertEqual(empty, "Bugün henüz fotoğraf çekilmedi.")
        let notReady = SpokenReport.make(captured: 3, sentPhotos: 0, sentDocs: 0, waiting: 3, folderReady: false,
                                          hasError: false, pdf: true, batchMode: true)
        XCTAssertTrue(notReady.contains("seçilmediği"), notReady)
        XCTAssertTrue(notReady.contains("Henüz hiçbir şey klasöre kaydedilmedi"), notReady)
        let failed = SpokenReport.make(captured: 3, sentPhotos: 0, sentDocs: 0, waiting: 3, folderReady: true,
                                       hasError: true, pdf: true, batchMode: false)
        XCTAssertTrue(failed.contains("başarısız"), failed)
        let done = SpokenReport.make(captured: 5, sentPhotos: 5, sentDocs: 1, waiting: 0, folderReady: true,
                                     hasError: false, pdf: true, batchMode: true)
        XCTAssertTrue(done.contains("Bekleyen sayfa yok"), done)
    }

    func testAfterCaptureText() {
        XCTAssertEqual(SpokenReport.afterCapture(part: nil, waiting: 4, folderReady: true, batchMode: true),
                       "Çekim tamamlandı. 4 sayfa gönderilmeyi bekliyor.")
        XCTAssertEqual(SpokenReport.afterCapture(part: "Sol", waiting: 1, folderReady: true, batchMode: true),
                       "Sol bölüm çekildi. 1 sayfa gönderilmeyi bekliyor.")
        XCTAssertEqual(SpokenReport.afterCapture(part: nil, waiting: 1, folderReady: true, batchMode: false),
                       "Çekim tamamlandı. Dosya gönderiliyor.")
        XCTAssertEqual(SpokenReport.afterCapture(part: "Sağ", waiting: 2, folderReady: false, batchMode: true),
                       "Sağ bölüm çekildi. Belge klasörü seçilmediği için dosya bekliyor.")
    }

    func testAfterCapturePageLimitWarnings() {
        XCTAssertEqual(SpokenReport.afterCapture(part: nil, waiting: 10, folderReady: true, batchMode: true, batchSize: 10),
                       "Çekim tamamlandı. 10 sayfa gönderilmeyi bekliyor. PDF dolduğu için gönderiliyor, sonraki sayfalar yeni PDF olacak.")
        XCTAssertEqual(SpokenReport.afterCapture(part: nil, waiting: 9, folderReady: true, batchMode: true, batchSize: 10),
                       "Çekim tamamlandı. 9 sayfa gönderilmeyi bekliyor.")
        XCTAssertEqual(SpokenReport.afterCapture(part: nil, waiting: 30, folderReady: true, batchMode: true, batchSize: 0),
                       "Çekim tamamlandı. 30 sayfa gönderilmeyi bekliyor. PDF'e en çok 30 sayfa girer, sonraki sayfalar yeni PDF olacak.")
        XCTAssertEqual(SpokenReport.afterCapture(part: nil, waiting: 29, folderReady: true, batchMode: true, batchSize: 0),
                       "Çekim tamamlandı. 29 sayfa gönderilmeyi bekliyor.")
        XCTAssertEqual(SpokenReport.afterCapture(part: nil, waiting: 10, folderReady: false, batchMode: true, batchSize: 10),
                       "Çekim tamamlandı. Belge klasörü seçilmediği için dosya bekliyor.")
        XCTAssertEqual(SpokenReport.afterCapture(part: nil, waiting: 40, folderReady: true, batchMode: false, batchSize: 10),
                       "Çekim tamamlandı. Dosya gönderiliyor.")
    }

    func testAfterDeleteText() {
        func text(_ o: CaptureLog.Outcome, waiting: Int = 3, retake: Bool = false, part: String? = nil,
                  guided: Bool = true) -> String {
            return SpokenReport.afterDelete(o, waiting: waiting, retake: retake, part: part, guided: guided, trigger: "okey")
        }
        XCTAssertEqual(text(.removed("a.jpg")), "Son fotoğraf silindi. 3 sayfa gönderilmeyi bekliyor.")
        XCTAssertEqual(text(.removed("a.jpg"), waiting: 0), "Son fotoğraf silindi. Bekleyen sayfa yok.")
        XCTAssertEqual(text(.removed("a.jpg"), retake: true), "Son fotoğraf silindi. Sayfayı yeniden kadraja alın.")
        XCTAssertEqual(text(.removed("a.jpg"), retake: true, part: "Sol"), "Son fotoğraf silindi. Sol bölümü yeniden kadraja alın.")
        XCTAssertEqual(text(.removed("a.jpg"), retake: true, guided: false), "Son fotoğraf silindi. Yeniden çekmek için okey deyin.")
        XCTAssertEqual(text(.alreadySent), "Son sayfa zaten klasöre kaydedildi, silemem.")
        XCTAssertEqual(text(.uploading), "Son sayfa şu an gönderiliyor, silemem.")
        XCTAssertEqual(text(.none), "Bu oturumda silinecek fotoğraf yok.")
    }

    // MARK: - Son fotoğrafı sil / yeniden çek

    private func phraseHits(_ text: String, _ phrases: String) -> Int {
        return SpeechMatcher.occurrences(in: text, trigger: phrases)
    }

    func testManyWaysToDeleteLast() {
        for t in ["son fotoğrafı sil", "sonuncuyu sil", "sil", "bunu sil", "son çekimi sil", "fotoğrafı sil", "sayfayı sil",
                  "son sayfayı kaldır", "yanlış çekimi sil", "son fotoğrafı iptal et", "bunu çöpe at", "silebilirsin"] {
            XCTAssertGreaterThan(intent(GuidanceVocabulary.deleteLastIntent, t) + phraseHits(t, GuidanceVocabulary.deleteLast), 0, t)
        }
        for t in ["geri al", "son fotoğrafı geri al", "yanlış çektim"] {
            XCTAssertGreaterThan(phraseHits(t, GuidanceVocabulary.deleteLast), 0, t)
        }
        // çekim emirleri ve diğer komutlar silme sayılmamalı
        for t in ["fotoğrafı al", "al", "çek", "okey", "sol", "sağ", "son", "geri", "hepsini gönder", "rapor ver",
                  "kaç sayfa çekildi", "yeniden seç", "vazgeç", "iptal", "yeniden çek", "tekrar çek"] {
            XCTAssertEqual(intent(GuidanceVocabulary.deleteLastIntent, t) + phraseHits(t, GuidanceVocabulary.deleteLast), 0, t)
        }
    }

    func testManyWaysToRetake() {
        for t in ["yeniden çek", "tekrar çek", "bir daha çek", "baştan çek", "fotoğrafı yeniden çek", "tekrar çekelim",
                  "çekimi tekrarla", "sonuncuyu tekrar çek", "yine çek"] {
            XCTAssertGreaterThan(intent(GuidanceVocabulary.retakeIntent, t) + phraseHits(t, GuidanceVocabulary.retake), 0, t)
        }
        for t in ["çek", "okey", "bir sayfa çek", "fotoğraf çek", "hepsini gönder", "sol", "yeniden seç", "tekrar seç",
                  "rapor ver", "son fotoğrafı sil"] {
            XCTAssertEqual(intent(GuidanceVocabulary.retakeIntent, t) + phraseHits(t, GuidanceVocabulary.retake), 0, t)
        }
    }

    func testDeleteAndRetakeDoNotTriggerOtherCommands() {
        for t in ["son fotoğrafı sil", "sonuncuyu sil", "geri al"] {
            XCTAssertEqual(intent(GuidanceVocabulary.finishIntent, t), 0, t)
            XCTAssertEqual(intent(GuidanceVocabulary.reportIntent, t), 0, t)
        }
    }

    func testCaptureLogRemovesLastPendingOnly() {
        var log = CaptureLog()
        XCTAssertEqual(log.takeLast(pending: [], inFlight: []), .none)
        log.add("a.jpg")
        log.add("b.jpg")
        XCTAssertEqual(log.takeLast(pending: ["a.jpg", "b.jpg"], inFlight: []), .removed("b.jpg"))
        XCTAssertEqual(log.takeLast(pending: ["a.jpg"], inFlight: ["a.jpg"]), .uploading)
        // a.jpg gitmiş: eskileri silinmez, geçmiş temizlenir
        XCTAssertEqual(log.takeLast(pending: [], inFlight: []), .alreadySent)
        XCTAssertEqual(log.takeLast(pending: ["eski.jpg"], inFlight: []), .none)
    }

    // MARK: - Günlük sayaçlar

    func testDailyStatsPersistAndRollOver() {
        let suite = "g526.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let day1 = cal.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 12))!
        let day2 = cal.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 9))!
        let store = DailyStatsStore(defaults: defaults, key: "k", calendar: cal)
        store.recordCapture(now: day1)
        store.recordCapture(now: day1)
        store.recordSent(photos: 2, docs: 1, now: day1)
        store.undoCapture(now: day1)
        XCTAssertEqual(store.today(now: day1), DailyStats(day: "2026-11-09", captured: 1, sentPhotos: 2, sentDocs: 1))
        // uygulama yeniden açılınca sayaçlar korunur
        let again = DailyStatsStore(defaults: defaults, key: "k", calendar: cal)
        XCTAssertEqual(again.today(now: day1).captured, 1)
        // ertesi gün sıfırlanır, eksiye düşmez
        XCTAssertEqual(again.today(now: day2), DailyStats(day: "2026-11-10"))
        again.undoCapture(now: day2)
        XCTAssertEqual(again.today(now: day2).captured, 0)
    }

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

    func testGlareWarnsTwiceThenCaptures() {
        let e = GuidanceEngine()
        var m = metrics(x0: 0.2, x1: 0.8)
        m.glare = 0.1
        var warnings = 0
        var captured = false
        var t = 0.0
        while t < 40 && !captured {
            let o = step(e, m, t: t)
            if let s = o.speak, s.contains("parlama") { warnings += 1 }
            captured = o.capture
            t += 0.3
        }
        XCTAssertTrue(captured, "parlama sonsuza dek çekimi engellememeli")
        XCTAssertEqual(warnings, 2)
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

    func testFinishedText() {
        XCTAssertEqual(SpokenReport.finished(photos: 8, docs: 1, pdf: true), "Tamamlandı. 8 sayfa 1 PDF olarak klasöre kaydedildi.")
        XCTAssertEqual(SpokenReport.finished(photos: 3, docs: 3, pdf: false), "Tamamlandı. 3 fotoğraf klasöre kaydedildi.")
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
        XCTAssertEqual(spoken.first, "Kamerayı biraz sağa kaydırın.")
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
}
