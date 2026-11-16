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

    /// İnternetin gelmesi için en çok bu kadar yoklanır (2 sn arayla)
    static let internetPolls = 15
    static let pollInterval: TimeInterval = 2

    private let camera: CameraCapturing
    private let shortcuts: ShortcutRunning
    private let health: HealthChecking
    private let settings: AppSettings
    private let cameraSettings: CameraSettings
    private let sessionActive: () -> Bool
    private let sleep: (TimeInterval) async -> Void
    private var stopped = false

    init(camera: CameraCapturing, shortcuts: ShortcutRunning, health: HealthChecking, settings: AppSettings,
         cameraSettings: CameraSettings, sessionActive: @escaping () -> Bool,
         sleep: @escaping (TimeInterval) async -> Void = { seconds in
             try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
         }) {
        self.camera = camera
        self.shortcuts = shortcuts
        self.health = health
        self.settings = settings
        self.cameraSettings = cameraSettings
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
        lines = []
        lastPhoto = nil
        defer { running = false }

        // 1) Kameraya geç
        lines.append("1/3 Kameraya geçiliyor: “\(cameraName)”…")
        let toCamera = await shortcuts.run(name: cameraName)
        lines.append(SettingsViewModel.text(for: toCamera))

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

        // 3) Hücresele geç ve internetin gelmesini bekle. SIM kart yoksa hücresel kestirme internet getirmez, yalnız Wi-Fi'yi kapatır: atlanır
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
