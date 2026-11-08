import XCTest

/// Uygulamanın GERÇEK ekran görüntülerini alır (simülatörde çalışan gerçek uygulama; çizim/montaj yok).
/// Kamera ekranları için Tools/test_kamerasi.py "test kamerası" çalışmalıdır; ilk test kamera olmadan çalışır.
final class EkranGoruntuleriUITests: XCTestCase {
    private static var counter = 0

    private lazy var outDir: String = {
        let env = ProcessInfo.processInfo.environment
        if let d = env["G526_SHOT_DIR"], !d.isEmpty { return d }
        if let h = env["SIMULATOR_HOST_HOME"], !h.isEmpty { return h + "/G526_ekran" }
        return NSTemporaryDirectory() + "/G526_ekran"
    }()

    private let turkish = ["-AppleLanguages", "(tr)", "-AppleLocale", "tr_TR"]

    override func setUp() {
        continueAfterFailure = true
    }

    // MARK: - Yardımcılar

    private static var lastShot: Data?

    /// Ekran görüntüsünü kaydeder. `skipSame` doğruysa, bir öncekiyle aynıysa (kaydırma sona ermişse) kaydetmez ve false döner.
    @discardableResult
    private func shot(_ name: String, skipSame: Bool = false) -> Bool {
        let screenshot = XCUIScreen.main.screenshot()
        let data = screenshot.pngRepresentation
        if skipSame, let last = Self.lastShot, last == data { return false }
        Self.lastShot = data
        Self.counter += 1
        let file = String(format: "%02d_%@.png", Self.counter, name)
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: outDir + "/" + file))
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = file
        attachment.lifetime = .keepAlways
        add(attachment)
        return true
    }

    private func note(_ text: String) {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: outDir + "/notlar.txt")
        let line = text + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func installPermissionMonitor() {
        addUIInterruptionMonitor(withDescription: "izin pencereleri") { [unowned self] alert in
            self.shot("sistem-izin-penceresi")
            self.note("Sistem penceresi: " + alert.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: " | "))
            for label in ["İzin Ver", "Uygulamayı Kullanırken İzin Ver", "Tamam", "Allow", "Allow While Using App", "OK"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
    }

    /// Sistem izin pencereleri varsa izleyici yakalasın diye kenar boşluğuna dokunur (zararsız bölge).
    private func poke(_ app: XCUIApplication, times: Int = 4) {
        for _ in 0..<times {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.55)).tap()
            sleep(1)
        }
    }

    private func firstMatch(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        let predicate = NSPredicate(format: "label BEGINSWITH %@ OR label CONTAINS %@", text, text)
        let candidates = [app.buttons.matching(predicate).firstMatch,
                          app.staticTexts.matching(predicate).firstMatch,
                          app.cells.matching(predicate).firstMatch,
                          app.otherElements.matching(predicate).firstMatch,
                          app.switches.matching(predicate).firstMatch]
        return candidates.first(where: { $0.exists }) ?? candidates[0]
    }

    private func drag(_ app: XCUIApplication, up: Bool) {
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.82 : 0.30))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.30 : 0.82))
        from.press(forDuration: 0.05, thenDragTo: to)
        usleep(500_000)
    }

    @discardableResult
    private func scrollTo(_ app: XCUIApplication, _ text: String, maxTries: Int = 10) -> XCUIElement {
        for _ in 0..<maxTries {
            let element = firstMatch(app, text)
            if element.exists && element.isHittable { return element }
            drag(app, up: true)
        }
        return firstMatch(app, text)
    }

    private func scrollToTop(_ app: XCUIApplication) {
        for _ in 0..<8 { drag(app, up: false) }
    }

    private func openSettings(_ app: XCUIApplication) {
        var button = app.buttons["ayarlar"]
        if !button.waitForExistence(timeout: 5) { button = app.navigationBars.buttons.firstMatch }
        button.tap()
        _ = app.navigationBars["Ayarlar"].waitForExistence(timeout: 8)
        sleep(1)
    }

    private func closeSettings(_ app: XCUIApplication) {
        let done = app.buttons["Bitti"]
        if done.waitForExistence(timeout: 5) { done.tap() }
        sleep(1)
    }

    private func goBack(_ app: XCUIApplication) {
        // Ayarlar sayfasının arkasındaki ana ekranın dişli düğmesi de "Ayarlar" etiketli; geri düğmesini ondan ayır.
        let predicate = NSPredicate(format: "(identifier == 'BackButton' OR label == 'Ayarlar') AND identifier != 'ayarlar'")
        let back = app.navigationBars.buttons.matching(predicate).firstMatch
        if back.exists && back.isHittable {
            back.tap()
        } else {
            // Kenardan sürükleyerek geri dön
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)))
        }
        sleep(1)
    }

    /// Öğe varsa dokunur; yoksa testi düşürmeden not düşer (ekran görüntüleri yine de alınsın).
    @discardableResult
    private func safeTap(_ element: XCUIElement, _ what: String) -> Bool {
        if element.waitForExistence(timeout: 4) { element.tap(); return true }
        note("Bulunamadı, atlandı: " + what)
        return false
    }

    /// Ayarlar sayfasını kapatıp yeniden açar; liste en üstte başlar (aşağı sürüklemek sayfayı kapatabilir).
    private func reopenSettings(_ app: XCUIApplication) {
        closeSettings(app)
        openSettings(app)
    }

    private func chooseTimestamp(_ app: XCUIApplication, option: String) {
        let row = scrollTo(app, "Tarih/saat yazısı")
        safeTap(row, "Tarih/saat yazısı")
        sleep(1)
        shot("tarih-saat-secenekleri")
        let item = firstMatch(app, option)
        if item.exists { item.tap() } else { note("Seçenek bulunamadı: " + option) }
        sleep(1)
    }

    private func waitForLive(_ app: XCUIApplication, timeout: TimeInterval = 90) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", "Fotoğraf Çek")
        let button = app.buttons.matching(predicate).firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if button.exists && button.isEnabled { return true }
            sleep(1)
        }
        return false
    }

    private func capture(_ app: XCUIApplication) {
        let predicate = NSPredicate(format: "label CONTAINS %@", "Fotoğraf Çek")
        let button = app.buttons.matching(predicate).firstMatch
        _ = waitForLive(app, timeout: 30)
        if button.exists { button.tap() }
        sleep(7)   // seri çekim penceresi + işleme
    }

    // MARK: - 1) İlk açılış (kamera yok) ve tüm ayar ekranları

    func test1_ilkAcilisVeAyarlar() {
        installPermissionMonitor()
        let app = XCUIApplication()
        app.launchArguments = turkish
        app.launch()
        sleep(3)
        shot("ana-ekran-ilk-acilis")
        poke(app)
        sleep(1)
        shot("ana-ekran-kamera-yok")

        // Ayarlar: en üstten en alta kadar, ekran değişmeyene dek
        openSettings(app)
        shot("ayarlar-1")
        var page = 2
        while page <= 12 {
            drag(app, up: true)
            if !shot("ayarlar-\(page)", skipSame: true) { break }
            page += 1
        }

        // Tarih/saat seçeneği (üç seçenek de görünsün), sonra varsayılana dön
        reopenSettings(app)
        chooseTimestamp(app, option: "Olduğu gibi bırak")
        shot("tarih-saat-olduğu-gibi-secildi")
        chooseTimestamp(app, option: "Bulanıklaştır")

        // Toplu gönderme modu
        safeTap(scrollTo(app, "Toplu (biriksin)"), "Toplu (biriksin)")
        sleep(1)
        shot("drive-ayarlari-toplu-mod")
        safeTap(scrollTo(app, "Tek tek (hemen)"), "Tek tek (hemen)")
        sleep(1)

        // Drive kurulum ekranı
        if safeTap(scrollTo(app, "Google hesabı ve bağlantı"), "Google hesabı ve bağlantı") {
            sleep(2)
            shot("google-drive-baglanti")
            drag(app, up: true)
            shot("google-drive-baglanti-alt", skipSame: true)
            goBack(app)
        }

        // Tanı ve günlük
        if safeTap(scrollTo(app, "Tanı ve günlük"), "Tanı ve günlük") {
            sleep(3)
            shot("tani-ve-gunluk")
            drag(app, up: true)
            shot("tani-ve-gunluk-alt", skipSame: true)
            goBack(app)
        }
        closeSettings(app)
        shot("ana-ekran-ayarlardan-sonra")
    }

    // MARK: - 2) Test kamerasıyla canlı görüntü, çekim, tarih/saat seçenekleri

    func test2_kameraylaCalisma() {
        installPermissionMonitor()
        let app = XCUIApplication()
        app.launchArguments = turkish + ["-uid", "GHBB-000001-TESTX", "-cameraIP", "127.0.0.1",
                                        "-motionEnabled", "NO"]
        app.launch()
        sleep(2)
        poke(app, times: 2)
        shot("kameraya-baglaniliyor")
        let live = waitForLive(app)
        note("Canlı görüntü: \(live)")
        sleep(3)
        shot("canli-goruntu")
        guard live else { return }

        // Varsayılan: tarih/saat bulanık
        capture(app)
        shot("cekim-sonrasi-bulanik")
        drag(app, up: true)
        shot("son-fotograf-bulanik")
        drag(app, up: false)

        // Olduğu gibi bırak
        openSettings(app)
        chooseTimestamp(app, option: "Olduğu gibi bırak")
        closeSettings(app)
        capture(app)
        drag(app, up: true)
        shot("son-fotograf-oldugu-gibi")
        drag(app, up: false)

        // Kes
        openSettings(app)
        chooseTimestamp(app, option: "Kes")
        closeSettings(app)
        capture(app)
        drag(app, up: true)
        shot("son-fotograf-kesilmis")
        drag(app, up: false)

        // Varsayılana dön
        openSettings(app)
        chooseTimestamp(app, option: "Bulanıklaştır")
        closeSettings(app)

        // Otomatik çekim ayarı ve Drive durumu
        shot("ana-ekran-son-durum")
        openSettings(app)
        scrollTo(app, "Görüntü değişince çek")
        shot("ayarlar-otomatik-cekim")
        closeSettings(app)

        // OCR'ı aç, bir fotoğraf çek, durumu göster. (CI sanal makinesinde Apple'ın yazı okuyucusu çalışmaz;
        // burada amaç ayarı ve "metin okunuyor" durumunu göstermek, zaman aşımı korumasının uygulamayı kilitlemediğini görmek.)
        openSettings(app)
        _ = scrollTo(app, "Metni oku")
        drag(app, up: true)     // satırı ekranın ortasına getir (alt kenarda dokunuş tutmayabiliyor)
        _ = scrollTo(app, "Metni oku", maxTries: 2)
        shot("ocr-ayari-kapali")
        let ocrSwitch = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "Metni oku")).firstMatch
        // SwiftUI satırında dokunuş etiketin ortasına düşer; anahtar satırın sağ ucunda
        if ocrSwitch.waitForExistence(timeout: 4) {
            ocrSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        } else {
            note("Bulunamadı, atlandı: OCR anahtarı")
        }
        sleep(1)
        shot("ocr-ayari-acik")
        closeSettings(app)
        capture(app)
        shot("ocr-cekim-sonrasi")
        sleep(40)
        shot("ocr-durumu-sonra")
        capture(app)    // OCR yavaş/başarısız olsa da çekim ve uygulama çalışmaya devam etmeli
        drag(app, up: true)
        shot("ocr-sonrasi-son-fotograf", skipSame: true)

        // Önizlemeyi kapat (pil tasarrufu): ekranda video yok, ama çekim çalışmaya devam eder
        drag(app, up: false)
        openSettings(app)
        _ = scrollTo(app, "Canlı önizlemeyi kapat")
        drag(app, up: true)
        _ = scrollTo(app, "Canlı önizlemeyi kapat", maxTries: 2)
        shot("onizleme-ayari-kapali")
        let previewSwitch = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "Canlı önizlemeyi kapat")).firstMatch
        if previewSwitch.waitForExistence(timeout: 4) {
            previewSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        } else {
            note("Bulunamadı, atlandı: önizleme anahtarı")
        }
        sleep(1)
        shot("onizleme-ayari-acik")
        closeSettings(app)
        sleep(2)
        shot("onizleme-kapali-ana-ekran")
        capture(app)
        shot("onizleme-kapali-cekim-sonrasi")
        drag(app, up: true)
        shot("onizleme-kapali-son-fotograf", skipSame: true)
    }
}
