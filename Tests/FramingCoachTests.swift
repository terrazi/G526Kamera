import XCTest
import CoreGraphics
@testable import G526CameraDrive

/// Kadraj koçu (kullanıcı kararı 2026-11-17, Ayarlar > "Toplu çekimde sesli konumlandırma"): toplu çekim ve deneme çekimi sürerken kadrajın durumu kısa
/// cümlelerle söylenir (hangi kenar kesik, hangi yöne kaydırılacak, çok yakın / bulanık, yazı küçük, üstte ve altta hangi satır). Koç çekimi
/// başlatmaz ya da bitirmez. Bu dosya saf mantığı (satır tarifi, değerlendirme, konuşma zamanlaması), ayarı ve oturuma bağlanışı sınar;
/// cihazda doğrulanmadı.

// MARK: - Satır tarifi

final class ViewLinesTests: XCTestCase {
    /// Üstten `top` oranında başlayan, 0,03 yüksekliğinde satır kutusu (Vision kutusu SOL ALT başlangıçlı)
    private func line(_ text: String, top: Double, x: Double = 0.1, width: Double = 0.8) -> (text: String, box: CGRect) {
        return (text: text, box: CGRect(x: x, y: 1 - top - 0.03, width: width, height: 0.03))
    }

    func testWordsDropPunctuationAndLoneSymbols() {
        XCTAssertEqual(ViewLines.words("— merhaba dünya, güzel! ★"), ["merhaba", "dünya", "güzel"])
        XCTAssertEqual(ViewLines.words("12. Aşağıdakilerden hangisi?"), ["12", "Aşağıdakilerden", "hangisi"])
        XCTAssertEqual(ViewLines.words("   "), [])
    }

    func testASingleColumnNamesTheFirstAndTheLastFullLine() {
        let v = ViewLines.make([
            line("Kavram haritası nedir ve neden kullanılır", top: 0.15),
            line("öğrenme sürecinde hangi işlevi görür", top: 0.45),
            line("doğru cevap hangisidir lütfen seçiniz", top: 0.80),
        ])
        XCTAssertEqual(v.starts, [LineEnd(side: nil, words: "Kavram haritası nedir ve")])
        XCTAssertEqual(v.ends, [LineEnd(side: nil, words: "cevap hangisidir lütfen seçiniz")])
        XCTAssertFalse(v.topCut)
        XCTAssertFalse(v.bottomCut)
        XCTAssertEqual(v.coverage, "Üstte Kavram haritası nedir ve ile başlıyor. Altta cevap hangisidir lütfen seçiniz ile bitiyor.")
    }

    func testALineTouchingTheBottomEdgeIsHalfSeenAndTheLastFullLineIsNamed() {
        let v = ViewLines.make([
            line("birinci satırın sözcükleri burada", top: 0.20),
            line("ikinci satırın sözcükleri burada", top: 0.60),
            (text: "yarım kalan alt satır sözcükleri", box: CGRect(x: 0.1, y: 0.002, width: 0.8, height: 0.03)),
        ])
        XCTAssertTrue(v.bottomCut)
        XCTAssertFalse(v.topCut)
        XCTAssertEqual(v.ends, [LineEnd(side: nil, words: "ikinci satırın sözcükleri burada")], "Yarım satırın sözcüğü güvenilmez: son TAM satır söylenir")
        XCTAssertEqual(v.coverage, "Üstte birinci satırın sözcükleri burada ile başlıyor. Alt satır yarım kalıyor; son tam satır ikinci satırın sözcükleri burada ile bitiyor.")
    }

    func testALineTouchingTheTopEdgeIsHalfSeen() {
        let v = ViewLines.make([
            (text: "yarım kalan üst satır sözcükleri", box: CGRect(x: 0.1, y: 0.975, width: 0.8, height: 0.03)),
            line("ikinci satırın sözcükleri burada", top: 0.30),
        ])
        XCTAssertTrue(v.topCut)
        XCTAssertEqual(v.coverage, "Üst satır yarım kalıyor; ilk tam satır ikinci satırın sözcükleri burada ile başlıyor. Altta ikinci satırın sözcükleri burada ile bitiyor.")
    }

    func testTextInTheCameraClockBandIsIgnored() {
        let v = ViewLines.make([
            line("12:45 kamera saat yazısı bandı", top: 0.02),
            line("gerçek sayfanın ilk satırı burada", top: 0.30),
        ], skipTop: GuidanceAnalyzer.skipTop)
        XCTAssertFalse(v.topCut, "Saat bandındaki yazı kesik sayılmaz")
        XCTAssertEqual(v.starts, [LineEnd(side: nil, words: "gerçek sayfanın ilk satırı")])
    }

    func testShortFragmentsAreNotLinesAndGiveNoCoverage() {
        let v = ViewLines.make([line("sayfa 3", top: 0.5), line("A) evet", top: 0.6)])
        XCTAssertTrue(v.starts.isEmpty)
        XCTAssertTrue(v.ends.isEmpty)
        XCTAssertNil(v.coverage)
        XCTAssertNil(ViewLines.make([]).coverage)
    }

    func testTheStartAndTheEndSentencesAreIndependentSoAHalfPageCanSayOnlyItsCutSide() {
        let v = ViewLines(starts: [LineEnd(side: nil, words: "alfa beta gama delta")], ends: [LineEnd(side: nil, words: "kırmızı mavi yeşil sarı")],
                          topCut: false, bottomCut: true)
        XCTAssertEqual(v.startsText, "Üstte alfa beta gama delta ile başlıyor.")
        XCTAssertEqual(v.endsText, "Alt satır yarım kalıyor; son tam satır kırmızı mavi yeşil sarı ile bitiyor.")
        XCTAssertNil(ViewLines().startsText)
        XCTAssertNil(ViewLines().endsText)
        XCTAssertEqual(ViewLines(topCut: true).startsText, "Üst satır yarım kalıyor.")
        XCTAssertEqual(ViewLines(bottomCut: true).endsText, "Alt satır yarım kalıyor.")
    }

    func testTwoColumnsAreNamedBySide() {
        let v = ViewLines.make([
            line("sol sütunun birinci satırı burada", top: 0.20, x: 0.05, width: 0.4),
            line("sol sütunun son satırı burada", top: 0.70, x: 0.05, width: 0.4),
            line("sağ sütunun birinci satırı burada", top: 0.22, x: 0.55, width: 0.4),
            line("sağ sütunun son satırı burada", top: 0.72, x: 0.55, width: 0.4),
        ])
        XCTAssertEqual(v.starts.map { $0.side }, ["solda", "sağda"])
        XCTAssertEqual(v.ends.map { $0.side }, ["solda", "sağda"])
        XCTAssertEqual(v.coverage, "Üstte solda sol sütunun birinci satırı, sağda sağ sütunun birinci satırı ile başlıyor. Altta solda sütunun son satırı burada, sağda sütunun son satırı burada ile bitiyor.")
    }

    func testASingleLineOnTheOtherSideDoesNotMakeTwoColumns() {
        let v = ViewLines.make([
            line("soldaki tek satırın sözcükleri burada", top: 0.30, x: 0.05, width: 0.4),
            line("sağdaki ilk satırın sözcükleri burada", top: 0.30, x: 0.55, width: 0.4),
            line("sağdaki ikinci satırın sözcükleri burada", top: 0.60, x: 0.55, width: 0.4),
        ])
        XCTAssertEqual(v.starts.count, 1)
        XCTAssertNil(v.starts.first?.side)
    }
}

// MARK: - Değerlendirme

final class FramingCoachNoteTests: XCTestCase {
    private func metrics(x0: Double, x1: Double, y0: Double = 0.2, y1: Double = 0.8, sharp: Double = 1.0, cells: Int = 600, glare: Double = 0) -> PageMetrics {
        var m = PageMetrics()
        m.hasPage = true
        m.hasText = true
        m.x0 = x0; m.x1 = x1; m.y0 = y0; m.y1 = y1
        m.cells = cells
        m.sharp = sharp
        m.glare = glare
        return m
    }

    private func note(_ m: PageMetrics, lines: ViewLines? = nil) -> FramingNote {
        return FramingCoach.note(m, lines: lines, sharpFloor: 0.45)
    }

    func testNoTextAsksToPointTheCameraAtThePage() {
        let n = note(PageMetrics())
        XCTAssertEqual(n.kind, .noText)
        XCTAssertEqual(n.text, "Yazı görünmüyor. Kamerayı sayfaya çevirin.")
        XCTAssertTrue(n.isCorrection)
    }

    func testACutRightEdgeSaysWhichSideIsCutAndWhereToMoveTheCamera() {
        let n = note(metrics(x0: 0.15, x1: 0.995))
        XCTAssertEqual(n.kind, .cutRight)
        XCTAssertEqual(n.text, "Sağ taraf kesik. Kamerayı biraz sağa kaydırın.")
    }

    func testACutLeftEdgeSaysWhichSideIsCutAndWhereToMoveTheCamera() {
        let n = note(metrics(x0: 0.005, x1: 0.85))
        XCTAssertEqual(n.kind, .cutLeft)
        XCTAssertEqual(n.text, "Sol taraf kesik. Kamerayı biraz sola kaydırın.")
    }

    func testBothSidesCutMeansTheCameraIsTooCloseToTheWholePage() {
        let n = note(metrics(x0: 0.005, x1: 0.995))
        XCTAssertEqual(n.kind, .tooWide)
        XCTAssertEqual(n.text, "Sayfa kadraja sığmıyor. Biraz uzaklaşın.")
    }

    func testABlurryViewThatFillsTheFrameTellsTheUserToStepBack() {
        let n = note(metrics(x0: 0.1, x1: 0.9, y0: 0.1, y1: 0.9, sharp: 0.2))
        XCTAssertEqual(n.kind, .blurry)
        XCTAssertEqual(n.text, "Görüntü net değil, çok yakınsınız. Biraz uzaklaşın.")
    }

    func testABlurryViewThatDoesNotFillTheFrameOnlyAsksToHoldSteady() {
        let n = note(metrics(x0: 0.2, x1: 0.8, sharp: 0.2))
        XCTAssertEqual(n.kind, .blurry)
        XCTAssertEqual(n.text, "Görüntü net değil. Kamerayı sabit tutun.")
    }

    func testGlareAsksToTiltTheCamera() {
        let n = note(metrics(x0: 0.2, x1: 0.8, glare: 0.2))
        XCTAssertEqual(n.kind, .glare)
        XCTAssertEqual(n.text, "Sayfada parlama var. Kamerayı biraz eğin.")
    }

    func testSmallTextCentredInTheFrameAsksToMoveCloser() {
        let n = note(metrics(x0: 0.4, x1: 0.6, y0: 0.4, y1: 0.6))
        XCTAssertEqual(n.kind, .tooSmall)
        XCTAssertEqual(n.text, "Yazı küçük kalıyor. Biraz yaklaşın.")
    }

    func testSmallTextOffCentreAsksToCentreBeforeMovingCloser() {
        let n = note(metrics(x0: 0.6, x1: 0.8, y0: 0.4, y1: 0.6))
        XCTAssertEqual(n.kind, .shiftRight)
        XCTAssertEqual(n.text, "Yazı küçük. Önce kamerayı azıcık sağa kaydırıp sonra yaklaşın.")
    }

    func testTextSittingLowInTheFrameAsksToMoveTheCameraDown() {
        let n = note(metrics(x0: 0.2, x1: 0.8, y0: 0.6, y1: 0.9))
        XCTAssertEqual(n.kind, .emptyTop)
        XCTAssertEqual(n.text, "Yazı kadrajın alt yarısında, üst taraf boş. Kamerayı biraz aşağı kaydırın.")
        XCTAssertTrue(n.isCorrection)
    }

    func testTextRunningOffTheTopAndBottomIsNotAProblemInTheSeries() {
        let n = note(metrics(x0: 0.2, x1: 0.8, y0: GuidanceAnalyzer.skipTop + 0.005, y1: 0.995))
        XCTAssertEqual(n.kind, .good, "Sayfa kadrajdan büyüktür: dikey kesik sorun değil, satır tarifi verilir")
        XCTAssertEqual(n.text, "Kadraj uygun.")
        XCTAssertFalse(n.isCorrection)
    }

    func testAGoodViewDescribesTheTopAndTheBottomLine() {
        let lines = ViewLines(starts: [LineEnd(side: nil, words: "Kavram haritası nedir ve")],
                              ends: [LineEnd(side: nil, words: "cevap hangisidir lütfen seçiniz")])
        let n = note(metrics(x0: 0.2, x1: 0.8), lines: lines)
        XCTAssertEqual(n.kind, .good)
        XCTAssertEqual(n.text, "Üstte Kavram haritası nedir ve ile başlıyor. Altta cevap hangisidir lütfen seçiniz ile bitiyor.")
    }

    func testTextOnlyInTheUpperHalfIsReportedAsInformationNotAsACorrection() {
        let n = note(metrics(x0: 0.2, x1: 0.8, y0: 0.2, y1: 0.5))
        XCTAssertEqual(n.kind, .good)
        XCTAssertEqual(n.text, "Yazı kadrajın üst yarısında, alt taraf boş.")
    }

    func testTheFullDescriptionAddsTheSceneToTheCorrectionAndTheLines() {
        let lines = ViewLines(starts: [LineEnd(side: nil, words: "Kavram haritası nedir ve")], ends: [])
        let text = FramingCoach.describe(metrics(x0: 0.15, x1: 0.995), lines: lines, sharpFloor: 0.45)
        XCTAssertTrue(text.hasPrefix("Tek sayfa görünüyor"), text)
        XCTAssertTrue(text.contains("Sağ taraf kesik. Kamerayı biraz sağa kaydırın."), text)
        XCTAssertTrue(text.contains("Üstte Kavram haritası nedir ve ile başlıyor."), text)
    }

    func testTheFullDescriptionWithoutTextOnlyGivesTheReason() {
        XCTAssertEqual(FramingCoach.describe(PageMetrics(), lines: nil, sharpFloor: 0.45), "Yazı görünmüyor. Kamerayı sayfaya çevirin.")
    }

    // MARK: Sayfanın üç durumu (kâğıt kenarları)

    /// Kâğıt dörtgeni: verilen kenar konumlarıyla (kare oranı). 0 ya da 1: kâğıt o kenardan kadraj dışına taşıyor.
    private func edges(left: Double = 0.1, right: Double = 0.9, top: Double = 0.1, bottom: Double = 0.9) -> PageEdges {
        return PageEdges(points: [PageEdges.Point(x: left, y: top), PageEdges.Point(x: right, y: top),
                                  PageEdges.Point(x: right, y: bottom), PageEdges.Point(x: left, y: bottom)], confidence: 0.9)
    }

    private func withEdges(_ e: PageEdges?, y0: Double = 0.15, y1: Double = 0.85, x0: Double = 0.2, x1: Double = 0.8) -> PageMetrics {
        var m = metrics(x0: x0, x1: x1, y0: y0, y1: y1)
        m.edges = e
        return m
    }

    func testAFullPageWithFourFreeEdgesIsRecognisedAndNotGivenALineDescription() {
        let lines = ViewLines(starts: [LineEnd(side: nil, words: "alfa beta gama delta")], ends: [LineEnd(side: nil, words: "kırmızı mavi yeşil sarı")])
        let n = note(withEdges(edges()), lines: lines)
        XCTAssertEqual(n.kind, .goodFull)
        XCTAssertEqual(n.text, "Tam sayfa görünüyor, dört kenar boş.")
        XCTAssertFalse(n.isCorrection)
    }

    func testTheUpperHalfHasThreeFreeEdgesAndNamesWhereTheCutBottomLineEnds() {
        let lines = ViewLines(starts: [LineEnd(side: nil, words: "alfa beta gama delta")], ends: [LineEnd(side: nil, words: "cevap hangisidir lütfen seçiniz")],
                              topCut: false, bottomCut: true)
        let n = note(withEdges(edges(bottom: 1.0), y1: 0.95), lines: lines)
        XCTAssertEqual(n.kind, .goodUpper)
        XCTAssertEqual(n.text, "Sayfanın üst yarısı görünüyor, üst, sol ve sağ kenar boş. Alt satır yarım kalıyor; son tam satır cevap hangisidir lütfen seçiniz ile bitiyor.")
    }

    func testTheLowerHalfHasThreeFreeEdgesAndNamesWhereTheCutTopLineStarts() {
        let lines = ViewLines(starts: [LineEnd(side: nil, words: "alfa beta gama delta")], ends: [LineEnd(side: nil, words: "kırmızı mavi yeşil sarı")],
                              topCut: true, bottomCut: false)
        let n = note(withEdges(edges(top: 0.0), y0: 0.1, y1: 0.8), lines: lines)
        XCTAssertEqual(n.kind, .goodLower)
        XCTAssertEqual(n.text, "Sayfanın alt yarısı görünüyor, alt, sol ve sağ kenar boş. Üst satır yarım kalıyor; ilk tam satır alfa beta gama delta ile başlıyor.")
    }

    func testASliceFromTheMiddleOfThePageAsksForAFullPageOrAHalf() {
        let n = note(withEdges(edges(top: 0.0, bottom: 1.0), y0: 0.1, y1: 0.9))
        XCTAssertEqual(n.kind, .middle)
        XCTAssertTrue(n.isCorrection)
        XCTAssertEqual(n.text, "Sayfanın ortası görünüyor, üst ve alt kenar kadraj dışında. Tam sayfa için uzaklaşın; yarım sayfa için kamerayı yukarı ya da aşağı kaydırın.")
    }

    func testAPaperEdgeOutsideTheSideOfTheFrameIsReportedButIsNotACorrection() {
        let n = note(withEdges(edges(right: 1.0)))
        XCTAssertEqual(n.kind, .goodFull)
        XCTAssertEqual(n.text, "Sayfanın üstü ve altı görünüyor; sağ kenarı kadrajın dışında kalıyor.", "Yandan taşan kâğıt için 'tam sayfa' / 'dört kenar boş' denmez")
    }

    func testBothSidesOutsideAndTheHalfViewsNameTheSidesInTheirOwnWords() {
        XCTAssertEqual(note(withEdges(edges(left: 0.0, right: 1.0))).text, "Sayfanın üstü ve altı görünüyor; sol ve sağ kenarları kadrajın dışında kalıyor.")
        let upper = note(withEdges(edges(left: 0.0, bottom: 1.0), y1: 0.95))
        XCTAssertEqual(upper.kind, .goodUpper)
        XCTAssertEqual(upper.text, "Sayfanın üst yarısı görünüyor; sol kenarı kadrajın dışında kalıyor.")
        let lower = note(withEdges(edges(right: 1.0, top: 0.0), y0: 0.1, y1: 0.8))
        XCTAssertEqual(lower.kind, .goodLower)
        XCTAssertEqual(lower.text, "Sayfanın alt yarısı görünüyor; sağ kenarı kadrajın dışında kalıyor.")
    }

    func testAnUndecidedTopOrBottomEdgeMakesNoClaimAboutTheLayout() {
        let n = note(withEdges(edges(top: 0.02)))
        XCTAssertEqual(n.kind, .good, "Kenar 'kesik' ile 'boş' arasında: titremesin diye söylenmez")
        XCTAssertEqual(n.text, "Kadraj uygun.")
        XCTAssertNil(FramingCoach.layout(PageMetrics()))
    }

    func testATextProblemStillComesBeforeTheLayout() {
        var m = metrics(x0: 0.15, x1: 0.995)
        m.edges = edges(right: 1.0)
        XCTAssertEqual(note(m).kind, .cutRight)
    }

    func testTheFullDescriptionNamesTheLayoutWithItsExplanationWithoutRepeatingTheSinglePageSentence() {
        let text = FramingCoach.describe(withEdges(edges(bottom: 1.0), y1: 0.95), lines: nil, sharpFloor: 0.45)
        XCTAssertTrue(text.hasPrefix("Sayfanın üst yarısı görünüyor, üst, sol ve sağ kenar boş."), text)
        XCTAssertTrue(text.contains("Alt kenardan alttaki sorunun bir bölümü giriyor olabilir."), text)
        XCTAssertFalse(text.contains("Tek sayfa görünüyor"), text)
    }

    func testOverlapIsTheSharedShareOfTheSmallerSet() {
        XCTAssertEqual(FramingCoach.overlap(["a", "b", "c", "d"], ["c", "d", "e", "f", "g"]), 0.5, accuracy: 0.001)
        XCTAssertEqual(FramingCoach.overlap([], ["a"]), 0)
    }
}

// MARK: - Konuşma zamanlaması

final class FramingCoachTimerTests: XCTestCase {
    private func metrics(x0: Double, x1: Double, y0: Double = 0.2, y1: Double = 0.8) -> PageMetrics {
        var m = PageMetrics()
        m.hasPage = true
        m.hasText = true
        m.x0 = x0; m.x1 = x1; m.y0 = y0; m.y1 = y1
        m.cells = 600
        m.sharp = 1.0
        return m
    }

    private var cutRight: PageMetrics { return metrics(x0: 0.15, x1: 0.995) }
    private var tooSmall: PageMetrics { return metrics(x0: 0.4, x1: 0.6, y0: 0.4, y1: 0.6) }
    private var fine: PageMetrics { return metrics(x0: 0.2, x1: 0.8) }

    private func step(_ timer: inout FramingCoachTimer, _ m: PageMetrics, at time: TimeInterval, still: TimeInterval = 1, lines: ViewLines? = nil,
                      edges: Bool = false) -> String? {
        return timer.step(metrics: m, lines: lines, time: time, stillFor: still, sharpFloor: 0.45, expectEdges: edges)
    }

    func testNothingIsSaidWhileTheCameraIsMoving() {
        var t = FramingCoachTimer()
        for i in 0..<6 { XCTAssertNil(step(&t, cutRight, at: 10 + Double(i) * 0.3, still: 0.2)) }
    }

    func testACorrectionNeedsTwoConsecutiveMeasurementsBeforeItIsSpoken() {
        var t = FramingCoachTimer()
        XCTAssertNil(step(&t, cutRight, at: 10.0))
        XCTAssertEqual(step(&t, cutRight, at: 10.3), "Sağ taraf kesik. Kamerayı biraz sağa kaydırın.")
    }

    func testAFlickeringMeasurementNeverReachesTheTwoInARowBar() {
        var t = FramingCoachTimer()
        var spoken: [String] = []
        for i in 0..<8 {
            let m = i % 2 == 0 ? cutRight : tooSmall
            if let text = step(&t, m, at: 10 + Double(i) * 0.3) { spoken.append(text) }
        }
        XCTAssertTrue(spoken.isEmpty, "\(spoken)")
    }

    func testTheSameCorrectionIsNotRepeatedBeforeTheRepeatGapAndAtMostThreeTimes() {
        var t = FramingCoachTimer()
        var spokenAt: [TimeInterval] = []
        var time = 10.0
        while time < 80 {
            if step(&t, cutRight, at: time) != nil { spokenAt.append(time) }
            time += 0.3
        }
        XCTAssertEqual(spokenAt.count, 3, "Aynı düzeltme en çok üç kez söylenir: \(spokenAt)")
        for (a, b) in zip(spokenAt, spokenAt.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, FramingCoachTimer.Config().repeatGap - 0.01)
        }
    }

    func testANewCorrectionWaitsForTheSpeakGapSoSentencesDoNotPileUp() {
        var t = FramingCoachTimer()
        XCTAssertNil(step(&t, cutRight, at: 10.0))
        XCTAssertNotNil(step(&t, cutRight, at: 10.3))
        XCTAssertNil(step(&t, tooSmall, at: 10.6))
        XCTAssertNil(step(&t, tooSmall, at: 10.9), "Konuşma arası dolmadı")
        XCTAssertNil(step(&t, tooSmall, at: 12.0))
        XCTAssertEqual(step(&t, tooSmall, at: 14.0), "Yazı küçük kalıyor. Biraz yaklaşın.")
    }

    func testOkIsSaidOnceAfterACorrectionAndNeverRepeatedForTheSameView() {
        var t = FramingCoachTimer()
        _ = step(&t, cutRight, at: 10.0)
        XCTAssertNotNil(step(&t, cutRight, at: 10.3))
        XCTAssertNil(step(&t, fine, at: 14.0))
        XCTAssertEqual(step(&t, fine, at: 14.3), "Tamam. Kadraj uygun.")
        var again: [String] = []
        var time = 14.6
        while time < 80 {
            if let text = step(&t, fine, at: time) { again.append(text) }
            time += 0.3
        }
        XCTAssertTrue(again.isEmpty, "Düzgün kadraj aynı kaldıkça susar: \(again)")
    }

    func testAGoodViewIsDescribedAgainOnlyWhenTheLinesChanged() {
        var t = FramingCoachTimer()
        let a = ViewLines(starts: [LineEnd(side: nil, words: "alfa beta gama delta")], ends: [LineEnd(side: nil, words: "kırmızı mavi yeşil sarı")])
        let b = ViewLines(starts: [LineEnd(side: nil, words: "zeta eta teta iota")], ends: [LineEnd(side: nil, words: "kapa lamda mü nü")])
        _ = step(&t, fine, at: 10.0, lines: a)
        XCTAssertEqual(step(&t, fine, at: 10.3, lines: a), "Üstte alfa beta gama delta ile başlıyor. Altta kırmızı mavi yeşil sarı ile bitiyor.")
        XCTAssertNil(step(&t, fine, at: 14.0, lines: a), "Tekrar aralığı dolmadı")
        XCTAssertNil(step(&t, fine, at: 23.0, lines: a), "Görünüm aynı: yeniden anlatılmaz")
        XCTAssertEqual(step(&t, fine, at: 23.3, lines: b), "Üstte zeta eta teta iota ile başlıyor. Altta kapa lamda mü nü ile bitiyor.", "Görünüm değişti ve aralık doldu: yeniden anlatılır")
    }

    // MARK: Yeni sayfa: her gösterilen sayfada yardım yeniden başlar

    private let pageA = ViewLines(starts: [LineEnd(side: nil, words: "alfa beta gama delta")], ends: [LineEnd(side: nil, words: "kırmızı mavi yeşil sarı")])
    private let pageB = ViewLines(starts: [LineEnd(side: nil, words: "zeta teta iota kapa")], ends: [LineEnd(side: nil, words: "lamda omikron sigma tau")])

    /// Aynı düzeltme üç kez söylenir ve sınıra ulaşılır; dönen: son konuşma zamanı
    private func exhaust(_ t: inout FramingCoachTimer, _ m: PageMetrics, lines: ViewLines?) -> TimeInterval {
        var time = 10.0
        var last = 10.0
        var count = 0
        while time < 60 && count < 3 {
            if step(&t, m, at: time, lines: lines) != nil { count += 1; last = time }
            time += 0.3
        }
        XCTAssertEqual(count, 3)
        return last
    }

    func testAnotherPageRestartsTheHelpEvenWhenTheSameCorrectionHadReachedItsLimit() {
        var t = FramingCoachTimer()
        let last = exhaust(&t, cutRight, lines: pageA)
        // Sınır doldu: aynı sayfada susar
        XCTAssertNil(step(&t, cutRight, at: last + 13, lines: pageA))
        // Kamera oynadı (sayfa çevrildi), yeni sayfa aynı sorunla geldi
        let start = last + 20
        XCTAssertNil(step(&t, cutRight, at: start, still: 0, lines: nil))
        XCTAssertNil(step(&t, cutRight, at: start + 0.6, still: 0.6, lines: pageB), "İlk ölçüm")
        XCTAssertEqual(step(&t, cutRight, at: start + 0.9, still: 0.9, lines: pageB), "Sağ taraf kesik. Kamerayı biraz sağa kaydırın.", "Yeni sayfa için yeniden söylenir")
    }

    func testASmallShiftOnTheSamePageDoesNotRestartTheHelp() {
        var t = FramingCoachTimer()
        let last = exhaust(&t, cutRight, lines: pageA)
        let start = last + 20
        XCTAssertNil(step(&t, cutRight, at: start, still: 0, lines: nil))
        for i in 1...12 {
            XCTAssertNil(step(&t, cutRight, at: start + Double(i) * 0.3, still: 0.5 + Double(i) * 0.3, lines: pageA), "Aynı sayfa: sınır dolu, susar")
        }
    }

    func testAfterAMoveTheTimerWaitsForTheLinesBeforeDecidingWhetherThePageChanged() {
        var t = FramingCoachTimer()
        _ = step(&t, cutRight, at: 10.0, lines: pageA)
        XCTAssertNotNil(step(&t, cutRight, at: 10.3, lines: pageA))
        XCTAssertNil(step(&t, cutRight, at: 20.0, still: 0, lines: nil))
        for time in [20.5, 21.0, 21.5, 22.0, 22.5] {
            XCTAssertNil(step(&t, cutRight, at: time, still: 0.6, lines: nil), "Satırlar okunana kadar beklenir")
        }
        XCTAssertNil(step(&t, cutRight, at: 23.0, still: 1.1, lines: nil), "Süre doldu: yeni sayfa sayılır, ilk ölçüm")
        XCTAssertNotNil(step(&t, cutRight, at: 23.3, still: 1.4, lines: nil), "Satır okunamadı: yine de söylenir")
    }

    func testTheOkAfterACorrectionSurvivesASmallShiftOnTheSamePage() {
        var t = FramingCoachTimer()
        _ = step(&t, cutRight, at: 10.0, lines: pageA)
        XCTAssertNotNil(step(&t, cutRight, at: 10.3, lines: pageA))
        XCTAssertNil(step(&t, fine, at: 12.0, still: 0, lines: nil))
        XCTAssertNil(step(&t, fine, at: 13.0, still: 1.0, lines: pageA))
        XCTAssertNil(step(&t, fine, at: 13.3, still: 1.3, lines: pageA))
        XCTAssertEqual(step(&t, fine, at: 14.5, still: 1.6, lines: pageA),
                       "Tamam. Üstte alfa beta gama delta ile başlıyor. Altta kırmızı mavi yeşil sarı ile bitiyor.")
    }

    func testANewPageStartsWithoutAnOkFromThePreviousPagesCorrection() {
        var t = FramingCoachTimer()
        _ = step(&t, cutRight, at: 10.0, lines: pageA)
        XCTAssertNotNil(step(&t, cutRight, at: 10.3, lines: pageA))
        XCTAssertNil(step(&t, fine, at: 15.0, still: 0, lines: nil))
        XCTAssertNil(step(&t, fine, at: 16.0, still: 1.0, lines: pageB))
        let said = step(&t, fine, at: 16.3, still: 1.3, lines: pageB)
        XCTAssertEqual(said, "Üstte zeta teta iota kapa ile başlıyor. Altta lamda omikron sigma tau ile bitiyor.", "Yeni sayfa: önceki düzeltmeye 'tamam' denmez")
    }

    func testTheFullPageUpperAndLowerHalfAreAnnouncedWhenTheLayoutChanges() {
        func page(_ e: PageEdges, y0: Double = 0.15, y1: Double = 0.85) -> PageMetrics {
            var m = metrics(x0: 0.2, x1: 0.8, y0: y0, y1: y1)
            m.edges = e
            return m
        }
        func edges(top: Double = 0.1, bottom: Double = 0.9) -> PageEdges {
            return PageEdges(points: [PageEdges.Point(x: 0.1, y: top), PageEdges.Point(x: 0.9, y: top),
                                      PageEdges.Point(x: 0.9, y: bottom), PageEdges.Point(x: 0.1, y: bottom)], confidence: 0.9)
        }
        var t = FramingCoachTimer()
        _ = step(&t, page(edges()), at: 10.0)
        XCTAssertEqual(step(&t, page(edges()), at: 10.3), "Tam sayfa görünüyor, dört kenar boş.")
        _ = step(&t, page(edges(bottom: 1.0), y1: 0.95), at: 14.0)
        let upper = step(&t, page(edges(bottom: 1.0), y1: 0.95), at: 14.3)
        XCTAssertEqual(upper, "Sayfanın üst yarısı görünüyor, üst, sol ve sağ kenar boş.", "Tam sayfadan üst yarıya geçildi")
        _ = step(&t, page(edges(top: 0.0), y0: 0.1, y1: 0.8), at: 18.0)
        let lower = step(&t, page(edges(top: 0.0), y0: 0.1, y1: 0.8), at: 18.3)
        XCTAssertEqual(lower, "Sayfanın alt yarısı görünüyor, alt, sol ve sağ kenar boş.", "Üst yarıdan alt yarıya geçildi")
    }

    func testAKnownPageStateIsNotReplacedByTheVagueOkSentenceWhenTheEdgesBlinkOut() {
        var full = metrics(x0: 0.2, x1: 0.8, y0: 0.15, y1: 0.85)
        full.edges = PageEdges(points: [PageEdges.Point(x: 0.1, y: 0.1), PageEdges.Point(x: 0.9, y: 0.1),
                                        PageEdges.Point(x: 0.9, y: 0.9), PageEdges.Point(x: 0.1, y: 0.9)], confidence: 0.9)
        var t = FramingCoachTimer()
        _ = step(&t, full, at: 10.0)
        XCTAssertEqual(step(&t, full, at: 10.3), "Tam sayfa görünüyor, dört kenar boş.")
        // Kenarlar bir süre ölçülemedi: "Kadraj uygun." diye geri düşülüp tekrar anlatılmaz
        for i in 0..<8 { XCTAssertNil(step(&t, fine, at: 14.0 + Double(i) * 0.3)) }
    }

    func testOnePageGetsAtMostEightSentencesAndANewPageGetsItsBudgetBack() {
        var t = FramingCoachTimer()
        var spoken = 0
        for i in 0..<16 {
            let m = i % 2 == 0 ? cutRight : tooSmall   // ölçüm gürültüsü: iki düzeltme arasında gidip gelir
            let time = 10.0 + Double(i) * 4
            _ = step(&t, m, at: time, lines: pageA)
            if step(&t, m, at: time + 0.3, lines: pageA) != nil { spoken += 1 }
        }
        XCTAssertEqual(spoken, 8, "Aynı sayfada sekiz cümleden sonra susulur")
        // Sayfa çevrildi: yeni sayfa için yardım yeniden başlar
        let start = 100.0
        XCTAssertNil(step(&t, cutRight, at: start, still: 0, lines: nil))
        XCTAssertNil(step(&t, cutRight, at: start + 0.6, still: 0.6, lines: pageB))
        XCTAssertNotNil(step(&t, cutRight, at: start + 0.9, still: 0.9, lines: pageB))
    }

    func testTheOkGoodSentenceWaitsForThePaperEdgesWhenTheyAreExpected() {
        var t = FramingCoachTimer()
        XCTAssertNil(step(&t, fine, at: 10.0, still: 0.5, edges: true))
        XCTAssertNil(step(&t, fine, at: 10.3, still: 0.8, edges: true))
        XCTAssertNil(step(&t, fine, at: 10.6, still: 1.1, edges: true))
        XCTAssertNil(step(&t, fine, at: 10.9, still: 1.4, edges: true), "Kenarlar gelmedi: kısa bekleme sonrası sayılmaya başlar")
        XCTAssertEqual(step(&t, fine, at: 11.2, still: 1.7, edges: true), "Kadraj uygun.")
    }

    func testACorrectionDoesNotWaitForThePaperEdges() {
        var t = FramingCoachTimer()
        XCTAssertNil(step(&t, cutRight, at: 10.0, still: 0.5, edges: true))
        XCTAssertNotNil(step(&t, cutRight, at: 10.3, still: 0.8, edges: true))
    }

    func testResetForgetsEverythingSoANewSessionStartsClean() {
        var t = FramingCoachTimer()
        _ = step(&t, cutRight, at: 10.0)
        XCTAssertNotNil(step(&t, cutRight, at: 10.3))
        t.reset()
        XCTAssertNil(step(&t, cutRight, at: 10.6))
        XCTAssertNotNil(step(&t, cutRight, at: 10.9), "Sıfırlanınca konuşma aralığı beklenmez")
    }
}

// MARK: - Ayar

final class SeriesGuidanceSettingTests: XCTestCase {
    func testTheSettingIsOffByDefaultAndRemembered() {
        let defaults = UserDefaults(suiteName: "g526.testler.\(UUID().uuidString)")!
        let first = CameraSettings(defaults: defaults)
        XCTAssertFalse(first.seriesGuidance, "Varsayılan: toplu çekim eskisi gibi sessiz")
        first.seriesGuidance = true
        XCTAssertTrue(CameraSettings(defaults: defaults).seriesGuidance, "Ayar kalıcıdır")
    }

    func testTurningItOnAlsoTurnsOnTheSceneDescriptionPageEdgesAndSpokenWarnings() {
        let defaults = UserDefaults(suiteName: "g526.testler.\(UUID().uuidString)")!
        let s = CameraSettings(defaults: defaults)
        s.guidanceDescribe = false
        s.guidancePageEdges = false
        s.guidanceVoice = false
        s.seriesGuidance = true
        XCTAssertTrue(s.guidanceDescribe)
        XCTAssertTrue(s.guidancePageEdges)
        XCTAssertTrue(s.guidanceVoice)
    }

    func testTurningItOffLeavesTheOtherSettingsAsTheUserHasThem() {
        let defaults = UserDefaults(suiteName: "g526.testler.\(UUID().uuidString)")!
        let s = CameraSettings(defaults: defaults)
        s.seriesGuidance = true
        s.seriesGuidance = false
        XCTAssertTrue(s.guidanceDescribe)
        XCTAssertTrue(s.guidanceVoice)
        s.guidanceVoice = false
        s.seriesGuidance = false
        XCTAssertFalse(s.guidanceVoice, "Zaten kapalıyken yeniden kapatmak başkasını açmaz")
    }
}

// MARK: - Kadraj kontrolü cümlesi

final class ViewCheckFramingTests: XCTestCase {
    private var readable: TextScore {
        var text = TextScore()
        text.chars = SeriesSelection.minChars + 200
        text.confidence = 0.9
        text.options = ["A", "B", "C"]
        text.questionNumbers = [4]
        return text
    }

    func testAGoodViewSpeaksTheFramingBeforeTheVerdict() {
        var check = ViewCheck(frames: 12, sharpness: 300, text: readable)
        check.framing = "Üstte Kavram haritası nedir ve ile başlıyor."
        XCTAssertEqual(check.spoken, "Üstte Kavram haritası nedir ve ile başlıyor. " + CaptureSay.viewGood)
    }

    func testACorrectionReplacesTheVerdictSoTheUserIsNotToldToStart() {
        var check = ViewCheck(frames: 12, sharpness: 300, text: readable)
        check.framing = "Sağ taraf kesik. Kamerayı biraz sağa kaydırın."
        check.framingIsCorrection = true
        XCTAssertEqual(check.spoken, "Sağ taraf kesik. Kamerayı biraz sağa kaydırın.")
    }

    func testWithoutFramingTheVerdictIsTheSameAsBefore() {
        XCTAssertEqual(ViewCheck(frames: 12, sharpness: 300, text: readable).spoken, CaptureSay.viewGood)
    }

    func testAnUnreadableViewKeepsItsOwnVerdictEvenWithAFraming() {
        var check = ViewCheck(frames: 12, sharpness: 20, text: TextScore())
        check.framing = "Kadraj uygun."
        XCTAssertEqual(check.spoken, CaptureSay.viewBlurry)
    }
}

// MARK: - Oturuma bağlanış

/// Ayar açıkken kamera çekim sürerken cümle söyleyebilir (kulaklıktan), kapalıyken toplu çekim eskisi gibi sessizdir
@MainActor
final class FramingCoachFlowTests: XCTestCase {
    typealias T = SessionViewModel.Timing

    private let coachSentence = "Sağ taraf kesik. Kamerayı biraz sağa kaydırın."

    private func harness() -> SessionHarness {
        let h = SessionHarness(cameraFlow: true, archive: false, pageSeries: true)
        h.camera.seriesResults = [.success(PageSeries(shot: FakeCamera.page(1, photos: 3), planned: 3, failure: nil, readable: true))]
        h.answering.pageResults = [.success([FakeAnswering.reply(1)])]
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

    func testWithTheSettingOnTheCoachSentenceIsSpokenWhileTheSeriesRuns() async {
        let h = harness()
        h.cameraSettings.seriesGuidance = true
        var attached = false
        h.camera.onSeries = {
            attached = h.camera.onSay != nil
            h.camera.onSay?(self.coachSentence)
        }
        _ = await h.startListening()
        say(h, "başla")
        let done = await waitUntil(45) { h.speaker.spoken.contains(self.coachSentence) && h.answering.pageCalls.count == 1 }
        XCTAssertTrue(attached, "Çekim sürerken kamera cümle söyleyebilir")
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        XCTAssertNil(h.camera.onSay, "Çekim bitince koç susturulur")
    }

    func testWithTheSettingOffTheSeriesStaysSilent() async {
        let h = harness()
        var attached = true
        h.camera.onSeries = {
            attached = h.camera.onSay != nil
            h.camera.onSay?(self.coachSentence)
        }
        _ = await h.startListening()
        say(h, "başla")
        let done = await waitUntil(45) { h.answering.pageCalls.count == 1 }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        XCTAssertFalse(attached, "Ayar kapalı: kamera çekim sürerken konuşamaz")
        XCTAssertFalse(h.speaker.spoken.contains(coachSentence))
    }

    func testACoachSentenceOutsideTheCaptureIsDropped() async {
        let h = harness()
        h.cameraSettings.seriesGuidance = true
        _ = await h.startListening()
        let before = h.speaker.spoken.count
        h.vm.sayCoach(coachSentence)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(h.speaker.spoken.count, before, "Çekim aşamasında değilken koç konuşmaz")
    }

    /// Önceki cümle sürerken gelen cümleler beklemeye alınır, yalnız en sonuncusu kalır (yeni sayfanın cümlesi kaybolmaz, konuşma üst üste binmez)
    func testSentencesArrivingWhileTheCoachIsSpeakingWaitAndOnlyTheLatestIsKept() async {
        let h = harness()
        h.cameraSettings.seriesGuidance = true
        var pending: String?
        h.camera.onSeries = {
            h.camera.onSay?("Birinci koç cümlesi.")
            h.camera.onSay?("İkinci koç cümlesi.")
            h.camera.onSay?("Üçüncü koç cümlesi.")
            pending = h.vm.coachPending?.text
        }
        _ = await h.startListening()
        say(h, "başla")
        let done = await waitUntil(45) { h.speaker.spoken.contains("Birinci koç cümlesi.") && h.answering.pageCalls.count == 1 }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        XCTAssertEqual(pending, "Üçüncü koç cümlesi.", "Konuşma sürerken en son cümle beklemeye alınır")
        XCTAssertFalse(h.speaker.spoken.contains("İkinci koç cümlesi."), "Araya giren eski cümle atılır")
        XCTAssertNil(h.vm.coachPending, "Süre dolunca bekleyen cümle söylenmez, temizlenir")
    }

    func testTheTrialCaptureAlsoGetsTheCoach() async {
        let h = harness()
        h.cameraSettings.seriesGuidance = true
        h.camera.trialResults = [.success(PageSeries(shot: FakeCamera.page(1, photos: 3), planned: 3, failure: nil, readable: true))]
        var attached = false
        h.camera.onTrial = {
            attached = h.camera.onSay != nil
            h.camera.onSay?(self.coachSentence)
        }
        _ = await h.startListening()
        say(h, "deneme çekimi")
        let done = await waitUntil(45) { h.speaker.spoken.contains(self.coachSentence) }
        XCTAssertTrue(attached)
        XCTAssertTrue(done, "\(h.speaker.spoken)")
    }

    func testTheViewCheckSpeaksTheFramingTheCameraDescribed() async {
        let h = harness()
        var text = TextScore()
        text.chars = SeriesSelection.minChars + 200
        text.confidence = 0.9
        text.options = ["A", "B", "C"]
        text.questionNumbers = [4]
        var check = ViewCheck(frames: 12, sharpness: 300, text: text)
        check.framing = "Üstte Kavram haritası nedir ve ile başlıyor."
        h.camera.viewChecks = [check]
        _ = await h.startListening()
        say(h, "kadraj kontrolü")
        let done = await waitUntil(45) { h.speaker.spoken.last == check.spoken }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
    }
}
