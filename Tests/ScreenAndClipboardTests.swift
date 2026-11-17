import XCTest
import AVFoundation
@testable import G526CameraDrive

/// Sahte ekran: parlaklık ataması yok sayılabilir, sistem kendi başına parlaklığı değiştirebilir, örtü görünür/gizli
@MainActor
final class FakeDimHardware: DimHardware {
    private var level: CGFloat
    /// iOS parlaklık atamasını sessizce yok sayıyor
    var ignoresBrightnessWrites = false
    private(set) var writes = 0
    private(set) var overlayVisible = false

    init(brightness: CGFloat = 0.7) { level = brightness }

    var brightness: CGFloat {
        get { return level }
        set {
            writes += 1
            if !ignoresBrightnessWrites { level = newValue }
        }
    }

    func setOverlay(_ visible: Bool) { overlayVisible = visible }

    /// Otomatik parlaklık ya da kullanıcı parlaklığı kendi başına değiştirdi (atama sayılmaz)
    func systemSets(_ value: CGFloat) { level = value }
    /// Pencere/sahne değişince örtü kayboldu
    func overlayVanishes() { overlayVisible = false }
}

/// "Ekranı kıs": parlaklık, koyu örtü, sistemin parlaklığı geri yükseltmesi, çökmeden sonra geri verme, karar nedenleri
/// ve açılışta pano işaretinin durumu (yeniden açılma otomasyonunun neden açmadığını anlamak için)
@MainActor
final class ScreenAndClipboardTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        return UserDefaults(suiteName: "g526.ekran.\(UUID().uuidString)")!
    }

    private func makeDimmer(_ hardware: FakeDimHardware, defaults: UserDefaults? = nil) -> ScreenDimmer {
        return ScreenDimmer(hardware: hardware, defaults: defaults ?? freshDefaults(), monitorInterval: 0)
    }

    // MARK: Parlaklık ve örtü

    func testDimLowersBrightnessAndDarkensThenRestoresTheUsersBrightness() {
        let hw = FakeDimHardware(brightness: 0.7)
        let dimmer = makeDimmer(hw)
        dimmer.update(dim: true)
        XCTAssertEqual(hw.brightness, ScreenDimmer.dimLevel, accuracy: 0.0001)
        XCTAssertTrue(hw.overlayVisible, "Parlaklık düşerken ekranın üstüne koyu örtü de gelir")
        XCTAssertTrue(dimmer.isDimmed)
        dimmer.update(dim: false)
        XCTAssertEqual(hw.brightness, 0.7, accuracy: 0.0001, "Kullanıcının parlaklığı geri verilir")
        XCTAssertFalse(hw.overlayVisible, "Örtü kalkar")
        XCTAssertFalse(dimmer.isDimmed)
    }

    func testDimmingAgainDoesNotOverwriteTheSavedBrightness() {
        let hw = FakeDimHardware(brightness: 0.7)
        let dimmer = makeDimmer(hw)
        dimmer.update(dim: true)
        dimmer.update(dim: true)
        dimmer.update(dim: true)
        dimmer.update(dim: false)
        XCTAssertEqual(hw.brightness, 0.7, accuracy: 0.0001, "Art arda kısma çağrıları kısık değeri 'kullanıcı parlaklığı' diye saklamaz")
    }

    func testUndimWithoutDimmingChangesNothing() {
        let hw = FakeDimHardware(brightness: 0.7)
        let dimmer = makeDimmer(hw)
        dimmer.update(dim: false)
        XCTAssertEqual(hw.writes, 0)
        XCTAssertFalse(hw.overlayVisible)
        XCTAssertEqual(hw.brightness, 0.7, accuracy: 0.0001)
    }

    func testSystemRaisingTheBrightnessIsLoweredAgain() {
        let hw = FakeDimHardware(brightness: 0.7)
        let dimmer = makeDimmer(hw)
        dimmer.update(dim: true)
        XCTAssertFalse(dimmer.reassertIfNeeded(), "Parlaklık kısıkken denetim bir şey yapmaz")
        hw.systemSets(0.6)   // otomatik parlaklık geri yükseltti
        XCTAssertTrue(dimmer.reassertIfNeeded())
        XCTAssertEqual(hw.brightness, ScreenDimmer.dimLevel, accuracy: 0.0001)
        XCTAssertEqual(dimmer.reapplied, 1)
        XCTAssertFalse(dimmer.reassertIfNeeded())
        dimmer.update(dim: false)
        XCTAssertEqual(hw.brightness, 0.7, accuracy: 0.0001, "Geri yükseltmeler kullanıcının parlaklığının yerine geçmez")
    }

    func testSmallBrightnessDriftIsIgnored() {
        let hw = FakeDimHardware(brightness: 0.7)
        let dimmer = makeDimmer(hw)
        dimmer.update(dim: true)
        let writes = hw.writes
        hw.systemSets(ScreenDimmer.dimLevel + ScreenDimmer.tolerance / 2)
        XCTAssertFalse(dimmer.reassertIfNeeded())
        XCTAssertEqual(hw.writes, writes, "Önemsiz oynamada parlaklık yeniden atanmaz")
    }

    func testWhenIOSIgnoresBrightnessWritesTheOverlayStillDarkensTheScreen() {
        let hw = FakeDimHardware(brightness: 0.7)
        hw.ignoresBrightnessWrites = true
        let dimmer = makeDimmer(hw)
        dimmer.update(dim: true)
        XCTAssertEqual(hw.brightness, 0.7, accuracy: 0.0001, "Sahte iOS atamayı yok saydı")
        XCTAssertTrue(hw.overlayVisible, "Yine de ekran örtüyle kararır")
        dimmer.update(dim: false)
        XCTAssertFalse(hw.overlayVisible)
        XCTAssertFalse(dimmer.isDimmed)
    }

    func testReassertBringsTheOverlayBackIfItVanished() {
        let hw = FakeDimHardware()
        let dimmer = makeDimmer(hw)
        dimmer.update(dim: true)
        hw.overlayVanishes()
        _ = dimmer.reassertIfNeeded()
        XCTAssertTrue(hw.overlayVisible)
    }

    func testReassertDoesNothingWhenNotDimmed() {
        let hw = FakeDimHardware()
        let dimmer = makeDimmer(hw)
        XCTAssertFalse(dimmer.reassertIfNeeded())
        XCTAssertEqual(hw.writes, 0)
        XCTAssertFalse(hw.overlayVisible)
    }

    func testBrightnessIsGivenBackAfterACrashWhileDimmed() {
        let defaults = freshDefaults()
        let hw = FakeDimHardware(brightness: 0.8)
        makeDimmer(hw, defaults: defaults).update(dim: true)
        XCTAssertEqual(hw.brightness, ScreenDimmer.dimLevel, accuracy: 0.0001)
        // Program kısıkken çöktü; yeni çalışma
        let next = makeDimmer(hw, defaults: defaults)
        next.restoreIfLeftDimmed()
        XCTAssertEqual(hw.brightness, 0.8, accuracy: 0.0001)
        XCTAssertNil(defaults.object(forKey: ScreenDimmer.savedKey))
        let writes = hw.writes
        next.restoreIfLeftDimmed()
        XCTAssertEqual(hw.writes, writes, "Saklı değer yoksa bir şey yapılmaz")
    }

    // MARK: Kısma kararı ve nedeni

    func testDecisionOrderAndReasons() {
        typealias D = DimDecision
        XCTAssertEqual(D.decide(enabled: false, active: true, warnings: []), .settingOff)
        XCTAssertEqual(D.decide(enabled: true, active: false, warnings: []), .inactive)
        XCTAssertEqual(D.decide(enabled: true, active: true, warnings: ["Mikrofon yok", "Şarj az"]), .warning("Mikrofon yok", 2))
        XCTAssertEqual(D.decide(enabled: true, active: true, warnings: []), .dim, "Test başlamamış olsa da ayar açıksa ekran kısılır")
        XCTAssertTrue(D.dim.shouldDim)
        for other in [D.settingOff, .inactive, .warning("x", 1)] { XCTAssertFalse(other.shouldDim) }
    }

    /// Kısma hafiftir: parlaklık en alta inmez, örtü ekranı kapatmaz; yazılar az da olsa görünür
    func testDimIsLightEnoughToStillSeeTheScreen() {
        XCTAssertGreaterThanOrEqual(ScreenDimmer.dimLevel, 0.1)
        XCTAssertLessThanOrEqual(ScreenDimmer.overlayAlpha, 0.5)
        XCTAssertGreaterThan(ScreenDimmer.dimLevel * (1 - ScreenDimmer.overlayAlpha), 0.08, "Etkin ışık çok düşük olmamalı")
    }

    func testStatusTextsNameTheBlockingWarning() {
        let blocked = DimDecision.warning("Telefon düşük güç modunda.", 2).statusText
        XCTAssertTrue(blocked.contains("Telefon düşük güç modunda."), "Neden kısılmadığı uyarı metniyle yazılır")
        XCTAssertTrue(blocked.contains("+1 uyarı daha"))
        XCTAssertFalse(DimDecision.warning("Tek", 1).statusText.contains("daha"))
        let long = DimDecision.warning(String(repeating: "a", count: 300), 1).statusText
        XCTAssertLessThan(long.count, 200, "Uzun uyarı metni kısaltılır")
        XCTAssertEqual(DimDecision.settingOff.statusText, "", "Ayar kapalıyken Ayarlar'da bir şey yazılmaz")
        XCTAssertFalse(DimDecision.dim.statusText.isEmpty)
        XCTAssertFalse(DimDecision.inactive.statusText.isEmpty)
    }

    // MARK: Pano işaretinin durumu

    func testClipboardStateReportsCleanMarkerAndOverwritten() {
        let board = RelaunchTests.FakePasteboard()
        let flag = ClipboardFlag(defaults: freshDefaults(), write: { board.write($0) }, changeCount: { board.changeCount })
        XCTAssertEqual(flag.state(), .clean)
        flag.set(ClipboardFlag.closed)
        XCTAssertEqual(flag.state(), .marker(ClipboardFlag.closed))
        flag.set(ClipboardFlag.repair)
        XCTAssertEqual(flag.state(), .marker(ClipboardFlag.repair))
        board.userCopies("kendi metnim")
        XCTAssertEqual(flag.state(), .overwritten, "İşaretten sonra kullanıcı başka şey kopyaladı")
        flag.clearIfOurs()
        XCTAssertEqual(board.value, "kendi metnim", "Kullanıcının panosuna dokunulmaz")
        XCTAssertEqual(flag.state(), .clean)
        flag.set(ClipboardFlag.closed)
        flag.clearIfOurs()
        XCTAssertEqual(board.value, "")
        XCTAssertEqual(flag.state(), .clean)
    }

    func testClipboardStateTextsTellWhetherTheAutomationCanReopen() {
        XCTAssertTrue(ClipboardState.clean.text.contains("açabilir"))
        XCTAssertTrue(ClipboardState.marker("SESLIKONTROL-KAPALI").text.contains("açmaz"))
        XCTAssertTrue(ClipboardState.marker("SESLIKONTROL-KAPALI").text.contains("SESLIKONTROL-KAPALI"))
        XCTAssertTrue(ClipboardState.overwritten.text.contains("değiştirmiş"))
    }

    func testBeginRunReadsTheClipboardStateWithoutChangingTheClipboard() {
        let defaults = freshDefaults()
        let board = RelaunchTests.FakePasteboard()
        func journal() -> RunJournal {
            let flag = ClipboardFlag(defaults: defaults, write: { board.write($0) }, changeCount: { board.changeCount })
            return RunJournal(defaults: defaults, previousLog: [], clipboard: flag)
        }
        let first = journal()
        _ = first.beginRun()
        first.setSessionOpen(true)   // oturum sürerken panoda işaret yok
        let count = board.changeCount
        _ = journal().beginRun()
        XCTAssertEqual(board.changeCount, count, "Açılışta pano yalnız sayaçla yoklanır; yazılmaz, okunmaz")
    }
}

/// Ses yolu günlüğünde ham port adları (kulaklık çalışırken program sorun görüyorsa nedeni bulmak için)
final class RouteRawLogTests: XCTestCase {
    func testRawDescriptionNamesEveryPortExactly() {
        let snapshot = RouteSnapshot(outputs: [.bluetoothA2DP, .usbAudio], inputs: [.usbAudio])
        let text = AudioRouting.describeRaw(snapshot)
        XCTAssertTrue(text.contains(AVAudioSession.Port.bluetoothA2DP.rawValue))
        XCTAssertTrue(text.contains(AVAudioSession.Port.usbAudio.rawValue))
        XCTAssertTrue(text.contains("ham çıkış"))
        XCTAssertTrue(text.contains("ham giriş"))
    }

    func testRawDescriptionSaysNoneForEmptyLists() {
        let text = AudioRouting.describeRaw(RouteSnapshot(outputs: [], inputs: []))
        XCTAssertEqual(text, "ham çıkış: yok; ham giriş: yok")
    }

    func testTwoOutputsAreNeverSafeEvenWhenOneIsTheHeadphones() {
        // Kulaklık çalışırken program sorun görüyorsa olası nedenlerden biri: yolda ikinci bir çıkış (ör. Lightning alıcı) görünüyor
        let both = RouteSnapshot(outputs: [.bluetoothA2DP, .usbAudio], inputs: [.usbAudio])
        let verdict = AudioRouting.verdict(both)
        XCTAssertFalse(verdict.headphonesOK, "Çıkışların hepsi kulaklık olmalı (KURAL 1): biri başka yerse güvenli sayılmaz")
        XCTAssertTrue(verdict.micOK)
    }

    /// 17.11.2026: "Günlüğü kopyala" panoyu günlükle doldurdu; günlükteki "pano işareti: SESLIKONTROL-KAPALI" satırları Kestirmeler otomasyonunun
    /// "pano SESLIKONTROL- içeriyorsa dur" koşulunu sağladı ve uygulama yukarı kaydırılarak kapatılınca geri açılmadı
    func testACopiedLogNeverContainsTheAutomationMarker() {
        let lines = ["00:33:57.685 [açılış] pano işareti: SESLIKONTROL-KAPALI (otomasyon açmaz); önceki çalışmada oturum kapalıydı",
                     "00:35:40.938 [açılış] pano işareti: seslikontrol-onarim (otomasyon açmaz)",
                     "00:33:58.658 [açılış] otomasyon uygulamayı yeniden açtı (seslikontrol://yeniden)"]
        let copied = ClipboardFlag.logText(info: "Sürüm: abc · SESLIKONTROL-ONARIM", lines: lines)
        XCTAssertFalse(copied.lowercased().contains("seslikontrol-"), "Kopyalanan günlük işaret önekini taşımaz")
        XCTAssertTrue(copied.contains("SESLIKONTROL:KAPALI"), "Metin okunur kalır")
        XCTAssertTrue(copied.contains("seslikontrol://yeniden"), "Adres örnekleri bozulmaz")
        XCTAssertTrue(copied.contains("00:33:57.685 [açılış] pano işareti"))
        XCTAssertEqual(ClipboardFlag.defused("serbest metin"), "serbest metin")
        XCTAssertFalse(ClipboardFlag.defused(ClipboardFlag.closed).hasPrefix(ClipboardFlag.prefix))
        XCTAssertFalse(ClipboardFlag.defused(ClipboardFlag.repair).lowercased().contains(ClipboardFlag.prefix.lowercased()))
    }
}
