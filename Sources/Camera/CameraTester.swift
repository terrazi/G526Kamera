import Foundation

/// Sürüm 4: kamera yolunun sınavdan ÖNCE uçtan uca sınanması (Ayarlar > Kamera > "Kamerayı dene").
///
/// Sınav sırasında kamera ilk kez açılırsa iOS "yerel ağ" izni kutusunu gösterir ve kulaklıktan yönetilen akış orada kilitlenir; kestirmelerin
/// Wi-Fi ile hücreseli gerçekten değiştirip değiştirmediği de ancak cihazda görülür. Bu sınama, sınav akışının aynı adımlarını sırayla yürütür:
/// (1) "Kameraya geç" kestirmesi, (2) kameraya bağlanıp bir çekim (fotoğraf + video, hiçbir yere gönderilmez ve silinir), (3) "Hücresele geç"
/// kestirmesi ve internetin gelmesi. Her adımın sonucu ekranda yazar; izin kutusu çıkarsa 40 sn içinde "İzin ver"e basılması yeter.
@MainActor
final class CameraTester: ObservableObject {
    /// Sınama sürüyor mu (düğme "Durdur" olur)
    @Published private(set) var running = false
    /// Adım adım sonuç satırları
    @Published private(set) var lines: [String] = []
    /// Deneme çekiminin fotoğrafı (ekranda küçük resim olarak gösterilir: kadraj ve netlik gözle görülsün). Hiçbir yere gönderilmez, dosyası silinir.
    @Published private(set) var lastPhoto: Data?
    /// Son çalışma ana ekrandaki "Deneme çekimi" miydi (satırlar ana ekranda gösterilir; Ayarlar'daki sınama satırları karışmasın)
    @Published private(set) var showsTrial = false
    /// Deneme çekiminin süren aşaması ("Çekim: 12/75 sn"); çalışma bitince boş
    @Published private(set) var progress = ""

    /// İnternetin gelmesi için en çok bu kadar yoklanır (2 sn arayla)
    static let internetPolls = 15
    static let pollInterval: TimeInterval = 2

    private let camera: CameraCapturing
    private let shortcuts: ShortcutRunning
    private let health: HealthChecking
    private let settings: AppSettings
    private let cameraSettings: CameraSettings
    private let captureStore: CaptureStoring
    private let sessionActive: () -> Bool
    private let sleep: (TimeInterval) async -> Void
    private var stopped = false

    init(camera: CameraCapturing, shortcuts: ShortcutRunning, health: HealthChecking, settings: AppSettings,
         cameraSettings: CameraSettings, captureStore: CaptureStoring = NoCaptureStore(), sessionActive: @escaping () -> Bool,
         sleep: @escaping (TimeInterval) async -> Void = { seconds in
             try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
         }) {
        self.camera = camera
        self.shortcuts = shortcuts
        self.health = health
        self.settings = settings
        self.cameraSettings = cameraSettings
        self.captureStore = captureStore
        self.sessionActive = sessionActive
        self.sleep = sleep
    }

    /// Sınamayı durdurur (kamerayı kapatır; kalan adımlar yapılmaz, ama internet kestirmesi yine çalışır: telefon kamera ağında kalmasın)
    func stop() {
        guard running else { return }
        stopped = true
        camera.cancel()
    }

    func run() async {
        guard !running else { return }
        guard !sessionActive() else {
            lines = ["Sınav sürerken kamera denenmez: önce testi bitirin."]
            return
        }
        let cameraName = cameraSettings.cameraShortcutName.trimmed
        let internetName = settings.internetShortcut.trimmed
        var missing: [String] = []
        if CameraUID(cameraSettings.uid) == nil { missing.append("kamera adı (UID)") }
        if cameraName.isEmpty { missing.append("“Kameraya geç” kestirmesinin adı") }
        if internetName.isEmpty { missing.append("“Hücresele geç” kestirmesinin adı") }
        guard missing.isEmpty else {
            lines = ["Önce şunları yazın: " + missing.joined(separator: ", ") + "."]
            return
        }
        running = true
        stopped = false
        showsTrial = false
        lines = []
        lastPhoto = nil
        defer { running = false }

        // 1) Kameraya geç
        await switchToCamera(cameraName)

        // 2) Kameraya bağlan ve çek (kestirme çalışmadıysa da denenir: ağ elle de kameraya geçmiş olabilir)
        if !stopped {
            lines.append("2/3 Kameraya bağlanılıyor (iOS yerel ağ izni sorarsa “İzin ver”e basın)…")
            switch await camera.capture() {
            case .success(let shot):
                lines.append("✓ Kamera çalıştı: fotoğraf \(shot.photo.count / 1024) KB"
                             + (shot.video == nil ? "" : ", video \(shot.videoBytes / 1024) KB / \(Int(shot.videoSeconds.rounded())) sn") + ". (Hiçbir yere gönderilmedi.)")
                lastPhoto = shot.photo
                shot.discard()
            case .failure(let failure):
                lines.append("✗ " + failure.message + CameraTester.hint(for: failure))
            }
        }

        // Kamera pili: görüntü karelerinden okunabildiyse yazılır (kamera yüzde vermez, 5 kademe + şarjda)
        if let level = camera.lastBattery {
            lines.append("🔋 " + level.shortText + " (son görüntü karesinden okundu).")
        }
        if let stream = camera.lastStreamSummary { lines.append("Akış ölçümü: " + stream) }

        await backToInternet(internetName: internetName)
    }

    /// Akış denemesi (Ayarlar > Kamera > "Akış denemesi", kullanıcı kararı 2026-11-17): sınavdaki gibi kameraya geçilir, 1 / 2 / 3 numaralı akışlar sırayla
    /// açılıp gerçek boyutları, kare hızları ve bitrate'leri ölçülür; kameranın yalnız okuma bilgi komutları (pozlama dahil) sorgulanır. Hiçbir ayar
    /// değiştirilmez, hiçbir şey kaydedilmez ya da gönderilmez; sonuç ekrana ve günlüğe yazılır. Sonra internete dönülür.
    func runStreamSurvey() async {
        guard !running else { return }
        guard !sessionActive() else {
            lines = ["Sınav sürerken akış denenmez: önce testi bitirin."]
            return
        }
        let cameraName = cameraSettings.cameraShortcutName.trimmed
        let internetName = settings.internetShortcut.trimmed
        var missing: [String] = []
        if CameraUID(cameraSettings.uid) == nil { missing.append("kamera adı (UID)") }
        if cameraName.isEmpty { missing.append("“Kameraya geç” kestirmesinin adı") }
        if internetName.isEmpty { missing.append("“Hücresele geç” kestirmesinin adı") }
        guard missing.isEmpty else {
            lines = ["Önce şunları yazın: " + missing.joined(separator: ", ") + "."]
            return
        }
        running = true
        stopped = false
        showsTrial = false
        lines = []
        lastPhoto = nil
        defer { running = false }

        await switchToCamera(cameraName)

        if !stopped {
            lines.append("2/3 Akışlar deneniyor (3 akış × yaklaşık \(Int(CameraCaptureController.surveySeconds)) sn ve kamera bilgi sorgusu; 1 dakika kadar sürer). iOS yerel ağ izni sorarsa “İzin ver”e basın…")
            let results = await camera.surveyStreams()
            lines.append(contentsOf: results)
        }

        await backToInternet(internetName: internetName)
    }

    /// Deneme çekimi (ana ekrandaki düğme, kullanıcı kararı 2026-11-17): sınavdaki gibi kameraya geçilir ve bir oturum süresi (Ayarlar > Toplu çekim süresi)
    /// çekilir; kareler ayrıca videoya yazılır. Video + PDF + rapor telefondaki `Cekimler/Deneme` klasörüne yazılır, Gemini'ye GİTMEZ, soru numarası
    /// tüketilmez. Sonra internete dönülür. Kullanıcı videodan elinin hareketini ve kameranın sayfaya uzaklığını izler, raporda ölçüleri görür.
    func runTrial() async {
        guard !running else { return }
        guard !sessionActive() else {
            lines = ["Sınav sürerken deneme çekimi yapılmaz: önce testi bitirin."]
            showsTrial = true
            return
        }
        let cameraName = cameraSettings.cameraShortcutName.trimmed
        let internetName = settings.internetShortcut.trimmed
        var missing: [String] = []
        if CameraUID(cameraSettings.uid) == nil { missing.append("kamera adı (UID)") }
        if cameraName.isEmpty { missing.append("“Kameraya geç” kestirmesinin adı") }
        if internetName.isEmpty { missing.append("“Hücresele geç” kestirmesinin adı") }
        guard missing.isEmpty else {
            lines = ["Önce şunları yazın (Ayarlar > Kamera): " + missing.joined(separator: ", ") + "."]
            showsTrial = true
            return
        }
        running = true
        stopped = false
        showsTrial = true
        lines = []
        lastPhoto = nil
        progress = ""
        defer {
            running = false
            progress = ""
        }
        let seconds = cameraSettings.seriesSeconds

        await switchToCamera(cameraName)

        if !stopped {
            lines.append("2/3 Deneme çekimi: \(seconds) sn. Sayfaları gerçek çekimdeki gibi gösterin (iOS yerel ağ izni sorarsa “İzin ver”e basın)…")
            camera.onStatus = { [weak self] text in self?.progress = text }
            let result = await camera.captureTrial(seconds: seconds, connectLimit: nil)
            camera.onStatus = nil
            switch result {
            case .success(let series):
                lastPhoto = series.shot.photo
                let video = series.shot.video == nil ? "video yazılamadı" : "video \(series.shot.videoBytes / 1024) KB"
                if captureStore.keepTrial(series.shot, report: series.report) != nil {
                    lines.append("✓ Deneme bitti: \(series.shot.pageCount) sayfalık PDF, \(video). Telefonda Dosyalar > Sesli Kontrol > Cekimler > Deneme klasörüne yazıldı (Gemini'ye gönderilmedi).")
                    lines.append(contentsOf: series.report.split(separator: "\n", omittingEmptySubsequences: true).dropFirst().map(String.init))
                } else {
                    lines.append("✗ Deneme çekimi klasöre yazılamadı (yer kalmamış olabilir).")
                }
                if series.failure != nil { lines.append("⚠ Görüntü akışı yarıda kesildi; çekim eksik.") }
                if let stream = camera.lastStreamSummary { lines.append("Akış ölçümü: " + stream) }
            case .failure(let failure):
                lines.append("✗ " + failure.message + CameraTester.hint(for: failure))
            }
        }

        await backToInternet(internetName: internetName)
    }

    /// 3) Hücresele geç ve internetin gelmesini bekle. SIM kart yoksa hücresel kestirme internet getirmez, yalnız Wi-Fi'yi kapatır: atlanır
    /// Kameraya geçiş. "Bağlantılar hep açık"ta kestirme çalışmaz: telefon zaten kameranın Wi-Fi'sindedir ve hücresel kapatılmaz
    private func switchToCamera(_ cameraName: String) async {
        if cameraSettings.stayOnWifi {
            lines.append("1/3 Bağlantılar hep açık: kestirme çalıştırılmadı, kameraya doğrudan bağlanılıyor.")
            return
        }
        lines.append("1/3 Kameraya geçiliyor: “\(cameraName)”…")
        let toCamera = await shortcuts.run(name: cameraName)
        lines.append(SettingsViewModel.text(for: toCamera))
    }

    private func backToInternet(internetName: String) async {
        // "Bağlantılar hep açık": hücresel hiç kapatılmadı; internet varsa hiçbir kestirme çalışmaz
        if cameraSettings.stayOnWifi, await health.internetReachable() {
            lines.append("3/3 ✓ İnternet var (hücresel açık kaldı; kestirme çalıştırılmadı). Sınama tamam.")
            return
        }
        if !health.hasCellularService() {
            lines.append("3/3 Telefonda SIM kart yok: “\(internetName)” kestirmesi çalıştırılmadı (yalnız Wi-Fi'yi kapatırdı). Kamera ağından çıkıp internet olan bir Wi-Fi ağına bağlanın.")
            return
        }
        lines.append("3/3 İnternete geçiliyor: “\(internetName)”…")
        let toInternet = await shortcuts.run(name: internetName)
        lines.append(SettingsViewModel.text(for: toInternet))
        var online = false
        for poll in 0..<CameraTester.internetPolls {
            if await health.internetReachable() { online = true; break }
            if poll < CameraTester.internetPolls - 1 { await sleep(CameraTester.pollInterval) }
        }
        lines.append(online ? "✓ İnternet geldi. Sınama tamam." : "✗ İnternet gelmedi: “Hücresele geç” kestirmesi Wi-Fi'yi kapatıp hücreseli açmıyor olabilir.")
    }

    /// Hatanın olası nedeni ve ne yapılacağı (kısa)
    static func hint(for failure: CameraFailure) -> String {
        switch failure {
        case .notConnected:
            return " Kamera açık mı? Telefon kameranın Wi-Fi ağına bağlandı mı (kestirme Wi-Fi'yi açıp ağa kendiliğinden bağlanmalı)? iOS'un yerel ağ izni verilmiş mi (iPhone Ayarlar > Gizlilik (ve Güvenlik) > Yerel Ağ)?"
        case .noFrames:
            return " Kameraya bağlanıldı ama görüntü gelmedi; kamerayı kapatıp açın."
        default:
            return ""
        }
    }
}
