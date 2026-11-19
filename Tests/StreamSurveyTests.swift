import XCTest
@testable import G526CameraDrive

/// Akış denemesi (kullanıcı kararı 2026-11-17): kameranın 1 / 2 / 3 numaralı akışlarının gerçek boyutu, kare hızı ve bitrate'i ölçülür; çekim akışı
/// Ayarlar'dan seçilebilir; ölçüm her oturumun sonunda günlüğe yazılır. Varsayılan davranış (otomatik) değişmez.
final class StreamMeterTests: XCTestCase {
    private func meter(stream: Int = 3, frames: Int = 10, interval: Double = 0.5, bytes: Int = 25_000, keyEvery: Int = 5) -> StreamMeter {
        let m = StreamMeter()
        m.begin(stream: stream)
        for i in 0..<frames {
            m.addFrame(bytes: bytes, keyFrame: i % keyEvery == 0, at: 100 + Double(i) * interval)
        }
        return m
    }

    func testFramesPerSecondDoesNotCountTheFirstFrame() {
        // 10 kare, 0,5 sn arayla: ilk kareden sonuncuya 4,5 sn, 9 aralık → saniyede 2 kare
        let s = meter().snapshot()
        XCTAssertEqual(s.frames, 10)
        XCTAssertEqual(s.seconds, 4.5, accuracy: 0.0001)
        XCTAssertEqual(StreamReport.framesPerSecond(s), 2.0, accuracy: 0.0001)
    }

    func testBitrateIsTotalBitsOverTheMeasuredSpan() {
        // 10 × 25 000 bayt = 250 000 bayt = 2 000 000 bit; 4,5 sn → ≈ 444 kbit/sn
        let s = meter().snapshot()
        XCTAssertEqual(StreamReport.kilobitsPerSecond(s), 2_000_000.0 / 1000 / 4.5, accuracy: 0.001)
    }

    func testKeyFramesAreCounted() {
        XCTAssertEqual(meter(frames: 10, keyEvery: 5).snapshot().keyFrames, 2)
        XCTAssertEqual(meter(frames: 10, keyEvery: 1).snapshot().keyFrames, 10)
    }

    func testTextNamesTheStreamTheDecodedSizeTheRateAndTheBitrate() {
        let m = meter(stream: 3, frames: 20, interval: 0.1, bytes: 10_000)
        m.addDecoded(width: 1280, height: 720)
        let text = StreamReport.text(m.snapshot())
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.hasPrefix("akış 3: 1280×720, "), text!)
        XCTAssertTrue(text!.contains("kare/sn"), text!)
        XCTAssertTrue(text!.contains("kbit/sn"), text!)
        XCTAssertTrue(text!.contains("20 kare"), text!)
        XCTAssertTrue(text!.contains("4 anahtar kare"), text!)
    }

    func testTextSaysSoWhenTheDecodedSizeIsUnknown() {
        let text = StreamReport.text(meter(stream: 1).snapshot())
        XCTAssertTrue(text?.contains("boyut okunamadı") == true, text ?? "nil")
    }

    func testTooFewFramesOrTooShortASpanGiveNoSummary() {
        XCTAssertNil(StreamReport.text(meter(frames: StreamReport.minFrames - 1, interval: 1).snapshot()), "Az kareyle sayılar güvenilmez")
        XCTAssertNil(StreamReport.text(meter(frames: 10, interval: 0.05).snapshot()), "0,45 sn'lik ölçüm yetmez")
        XCTAssertNil(StreamReport.text(StreamMeter().snapshot()), "Hiç kare yoksa özet yok")
    }

    func testResetClearsTheCountersButKeepsTheStreamNumber() {
        let m = meter(stream: 2)
        m.addDecoded(width: 640, height: 360)
        m.reset()
        let s = m.snapshot()
        XCTAssertEqual(s.stream, 2)
        XCTAssertEqual(s.frames, 0)
        XCTAssertEqual(s.bytes, 0)
        XCTAssertEqual(s.width, 0)
        XCTAssertEqual(s.seconds, 0)
    }

    func testBeginStartsAFreshMeasurementForTheNewStream() {
        let m = meter(stream: 1)
        m.begin(stream: 3)
        let s = m.snapshot()
        XCTAssertEqual(s.stream, 3)
        XCTAssertEqual(s.frames, 0)
    }

    func testMeterCountsSafelyFromTwoThreads() {
        let m = StreamMeter()
        m.begin(stream: 1)
        let group = DispatchGroup()
        for t in 0..<4 {
            group.enter()
            DispatchQueue.global().async {
                for i in 0..<250 { m.addFrame(bytes: 10, keyFrame: false, at: Double(t * 250 + i)) }
                m.addDecoded(width: 1920, height: 1080)
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(m.snapshot().frames, 1000)
        XCTAssertEqual(m.snapshot().bytes, 10_000)
    }
}

@MainActor
final class StreamChoiceTests: XCTestCase {
    func testAutomaticKeepsTodaysBehaviour() {
        XCTAssertEqual(CameraCaptureController.streamChoice(quality: 1, series: true).stream, 1)
        XCTAssertEqual(CameraCaptureController.streamChoice(quality: 2, series: true).stream, 1, "Toplu çekimde düşük kalite ayarı yok sayılır")
        XCTAssertEqual(CameraCaptureController.streamChoice(quality: 2, series: false).stream, 2)
        XCTAssertEqual(CameraCaptureController.streamChoice(quality: 2, series: false, override: 0).stream, 2)
        XCTAssertEqual(CameraCaptureController.streamChoice(quality: 1, series: false, override: 0).state, 1)
    }

    func testAChosenStreamWinsInEveryModeAndUsesLookCamsLevel() {
        for series in [true, false] {
            for quality in [1, 2] {
                let one = CameraCaptureController.streamChoice(quality: quality, series: series, override: 1)
                let two = CameraCaptureController.streamChoice(quality: quality, series: series, override: 2)
                let three = CameraCaptureController.streamChoice(quality: quality, series: series, override: 3)
                XCTAssertEqual(one.stream, 1); XCTAssertEqual(one.state, 1)
                XCTAssertEqual(two.stream, 2); XCTAssertEqual(two.state, 2)
                XCTAssertEqual(three.stream, 3); XCTAssertEqual(three.state, 2, "LookCam'de VGA = akış 3 / seviye 2")
            }
        }
    }

    func testAnUnknownOverrideFallsBackToAutomatic() {
        XCTAssertEqual(CameraCaptureController.streamChoice(quality: 1, series: true, override: 9).stream, 1)
        XCTAssertEqual(CameraCaptureController.streamChoice(quality: 2, series: false, override: -1).stream, 2)
    }

    func testTheSurveyOpensTheThreeStreamsInOrderWithLookCamsLevels() {
        let choices = CameraCaptureController.surveyChoices
        XCTAssertEqual(choices.map { $0.stream }, [1, 2, 3])
        XCTAssertEqual(choices.map { $0.state }, [1, 2, 2])
    }

    func testReplyLogLimitIsLongerForTheAnswersTheSurveyLooksAt() {
        XCTAssertEqual(CameraSession.replyLogLimit(for: "GetDevInfo"), 900)
        XCTAssertGreaterThan(CameraSession.replyLogLimit(for: "GetDevExInfo"), 200, "Pozlama cevabı kesilmemeli")
        XCTAssertGreaterThan(CameraSession.replyLogLimit(for: "GetDevVideoInfo"), 200)
        XCTAssertGreaterThan(CameraSession.replyLogLimit(for: "GetDevStream"), 200)
        XCTAssertEqual(CameraSession.replyLogLimit(for: "LoginDev"), 200)
    }
}

final class StreamOverrideSettingTests: XCTestCase {
    private func defaults() -> UserDefaults { return UserDefaults(suiteName: "g526.testler.\(UUID().uuidString)")! }

    func testTheStreamOverrideDefaultsToAutomatic() {
        XCTAssertEqual(CameraSettings(defaults: defaults()).streamOverride, 0)
    }

    func testTheStreamOverridePersists() {
        let d = defaults()
        let s = CameraSettings(defaults: d)
        s.streamOverride = 3
        XCTAssertEqual(d.integer(forKey: "streamOverride"), 3)
        XCTAssertEqual(CameraSettings(defaults: d).streamOverride, 3)
    }

    func testAnOutOfRangeSavedOverrideIsClamped() {
        let d = defaults()
        d.set(7, forKey: "streamOverride")
        XCTAssertEqual(CameraSettings(defaults: d).streamOverride, 3)
        d.set(-4, forKey: "streamOverride")
        XCTAssertEqual(CameraSettings(defaults: d).streamOverride, 0)
    }
}

@MainActor
final class SurveyHighlightsTests: XCTestCase {
    private let text = [
        "Kameranın cevaplarında pil / şarj alanı bulunamadı.",
        "GetDevInfo: {\"cmd\":\"GetDevInfo\"}",
        "GetDevExInfo: {\"cmd\":\"GetDevExInfo\",\"exposure\":1,\"shutter\":50}",
        "GetDevVideoInfo: {\"brightness\":30,\"cmd\":\"GetDevVideoInfo\",\"saturation\":30}",
        "GetDevStream: {\"cmd\":\"GetDevStream\",\"mainstream\":\"4K\"}",
        "GetBattery: cevap yok"
    ].joined(separator: "\n")

    func testOnlyTheExposureVideoAndStreamAnswersAreShown() {
        let lines = CameraCaptureController.probeHighlights(text)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("GetDevExInfo"))
        XCTAssertTrue(lines[1].contains("GetDevVideoInfo"))
        XCTAssertTrue(lines[2].contains("GetDevStream"))
        XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("Kamera cevabı · ") })
    }

    func testAnUnansweredExposureCommandIsShownAsUnanswered() {
        let lines = CameraCaptureController.probeHighlights("özet\nGetDevExInfo: cevap yok")
        XCTAssertEqual(lines, ["Kamera cevabı · GetDevExInfo: cevap yok"])
    }

    func testNoQueryTextSaysTheQueryDidNotRun() {
        let lines = CameraCaptureController.probeHighlights("")
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("bilgi sorgusu yapılamadı"), lines[0])
    }

    func testLongAnswersAreCutForTheScreen() {
        let long = "GetDevExInfo: " + String(repeating: "x", count: 900)
        let line = CameraCaptureController.probeHighlights("özet\n" + long)[0]
        XCTAssertLessThan(line.count, 360)
        XCTAssertTrue(line.hasSuffix("…"))
    }
}

/// Ayarlar > Kamera > "Akış denemesi": sınavdaki gibi kameraya geçilir, akışlar ölçülür, internete dönülür
@MainActor
final class StreamSurveyTesterTests: XCTestCase {
    private struct Rig {
        let tester: CameraTester
        let camera: FakeCamera
        let shortcuts: FakeShortcuts
    }

    private func rig(sessionActive: Bool = false, cameraShortcut: String = "Kameraya_Gec") -> Rig {
        let defaults = UserDefaults(suiteName: "g526.testler.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        let cameraSettings = CameraSettings(defaults: defaults)
        cameraSettings.cameraShortcutName = cameraShortcut
        cameraSettings.stayOnWifi = false   // bu sınamalar eski düzeni (kameraya geç, sonra hücresele dön) dener
        settings.internetShortcut = "Hücresele_Gec"
        let camera = FakeCamera()
        let shortcuts = FakeShortcuts()
        let tester = CameraTester(camera: camera, shortcuts: shortcuts, health: FakeHealth(), settings: settings, cameraSettings: cameraSettings,
                                  sessionActive: { sessionActive }, sleep: { _ in })
        return Rig(tester: tester, camera: camera, shortcuts: shortcuts)
    }

    func testTheSurveyRunsTheShortcutsAroundTheStreamMeasurement() async {
        let r = rig()
        r.camera.surveyLines = ["akış 1: 1920×1080, 9.0 kare/sn, 2100 kbit/sn (72 kare, 8.0 sn, 2 anahtar kare)",
                                "akış 2: 640×360, 9.0 kare/sn, 300 kbit/sn (72 kare, 8.0 sn, 2 anahtar kare)",
                                "akış 3: görüntü gelmedi"]
        await r.tester.runStreamSurvey()
        XCTAssertEqual(r.shortcuts.runs, ["Kameraya_Gec", "Hücresele_Gec"], "Önce kameraya geçilir, ölçümden sonra internete dönülür")
        XCTAssertEqual(r.camera.surveyCalls, 1)
        for line in r.camera.surveyLines { XCTAssertTrue(r.tester.lines.contains(line), "Ölçüm satırı ekranda görünmeli: \(line)") }
        XCTAssertEqual(r.tester.lines.last, "✓ İnternet geldi. Sınama tamam.")
        XCTAssertFalse(r.tester.running)
        XCTAssertFalse(r.tester.showsTrial, "Satırlar Ayarlar'da gösterilir, ana ekrandaki Deneme çekimi alanında değil")
    }

    func testTheSurveyDoesNotRunWhileAnExamIsGoingOn() async {
        let r = rig(sessionActive: true)
        await r.tester.runStreamSurvey()
        XCTAssertEqual(r.camera.surveyCalls, 0)
        XCTAssertTrue(r.shortcuts.runs.isEmpty)
        XCTAssertEqual(r.tester.lines.count, 1)
    }

    func testTheSurveyAsksForTheMissingShortcutNameFirst() async {
        let r = rig(cameraShortcut: "")
        await r.tester.runStreamSurvey()
        XCTAssertEqual(r.camera.surveyCalls, 0)
        XCTAssertTrue(r.tester.lines.first?.contains("“Kameraya geç” kestirmesinin adı") == true)
    }

    func testTheCameraTestShowsTheStreamMeasurementOfItsShot() async {
        let r = rig()
        r.camera.results = [.success(FakeCamera.shot())]
        r.camera.lastStreamSummary = "akış 1: 1920×1080, 8.9 kare/sn, 2000 kbit/sn (80 kare, 9.0 sn, 3 anahtar kare)"
        await r.tester.run()
        XCTAssertTrue(r.tester.lines.contains("Akış ölçümü: " + r.camera.lastStreamSummary!))
    }

    func testTheCameraTestShowsNoStreamLineWhenNothingWasMeasured() async {
        let r = rig()
        r.camera.results = [.success(FakeCamera.shot())]
        await r.tester.run()
        XCTAssertFalse(r.tester.lines.contains { $0.hasPrefix("Akış ölçümü") })
    }
}
