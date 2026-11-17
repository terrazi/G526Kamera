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
        XCTAssertEqual(v.coverage, "Üst satır yarım kalıyor. Altta ikinci satırın sözcükleri burada ile bitiyor.")
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

    private func step(_ timer: inout FramingCoachTimer, _ m: PageMetrics, at time: TimeInterval, still: TimeInterval = 1, lines: ViewLines? = nil) -> String? {
        return timer.step(metrics: m, lines: lines, time: time, stillFor: still, sharpFloor: 0.45)
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
