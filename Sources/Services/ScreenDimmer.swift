import UIKit

/// Ekranın şu an kısılıp kısılmayacağı ve nedeni. Ayarlar'da "neden kısılmıyor" sorusunun cevabı olarak da yazılır.
enum DimDecision: Equatable {
    case dim
    case settingOff
    case notRunning
    case inactive
    /// İlk kırmızı uyarının metni ve toplam uyarı sayısı
    case warning(String, Int)

    /// Karar sırası: ayar kapalı → test sürmüyor → uygulama önde değil → kırmızı uyarı var → kıs
    static func decide(enabled: Bool, running: Bool, active: Bool, warnings: [String]) -> DimDecision {
        if !enabled { return .settingOff }
        if !running { return .notRunning }
        if !active { return .inactive }
        if let first = warnings.first { return .warning(first, warnings.count) }
        return .dim
    }

    var shouldDim: Bool { return self == .dim }

    /// Ayarlar'da ve günlükte görünen cümle
    var statusText: String {
        switch self {
        case .dim: return "Ekran şu an kısık."
        case .settingOff: return ""
        case .notRunning: return "Test sürmüyor; test başlayınca ekran kısılır."
        case .inactive: return "Uygulama önde değil; öne gelince ekran kısılır."
        case let .warning(text, count):
            let short = text.count > 90 ? String(text.prefix(90)) + "…" : text
            let more = count > 1 ? " (+\(count - 1) uyarı daha)" : ""
            return "Kırmızı uyarı olduğu için ekran kısılmıyor: \(short)\(more)"
        }
    }
}

/// Parlaklık ve karartma örtüsü: gerçek ekran ya da testte sahte
@MainActor
protocol DimHardware: AnyObject {
    var brightness: CGFloat { get set }
    /// Ekranın üstüne dokunuşları geçiren yarı saydam siyah örtü koyar / kaldırır (örtü yoksa ya da zaten varsa bir şey yapmaz)
    func setOverlay(_ visible: Bool)
}

@MainActor
final class SystemDimHardware: DimHardware {
    private var overlay: UIWindow?

    var brightness: CGFloat {
        get { return UIScreen.main.brightness }
        set { UIScreen.main.brightness = newValue }
    }

    func setOverlay(_ visible: Bool) {
        if !visible {
            overlay?.isHidden = true
            overlay = nil
            return
        }
        guard overlay == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = UIWindow.Level.alert + 1
        window.backgroundColor = UIColor.black.withAlphaComponent(ScreenDimmer.overlayAlpha)
        window.isUserInteractionEnabled = false   // dokunuşlar altındaki uygulamaya geçer ("Programı kapat" düğmesi çalışır)
        window.rootViewController = UIViewController()
        window.rootViewController?.view.backgroundColor = .clear
        window.isHidden = false                   // anahtar pencere yapılmaz
        overlay = window
    }
}

/// Test sürerken (ayar açıksa) ve kırmızı uyarı yokken ekranı kısar, pil tasarrufu için; uygulama arka plana/pasife geçince kullanıcının
/// parlaklığını geri verir. iOS `UIScreen.brightness` atamasını sessizce yok sayabilir ya da otomatik parlaklık değeri geri yükseltebilir;
/// bu yüzden (1) parlaklık düşürülür, (2) ekranın üstüne yarı saydam siyah örtü konur (OLED'de siyah piksel yanmaz: parlaklık atanmasa
/// bile ekran kararır) ve (3) kısık kaldığı sürece birkaç saniyede bir parlaklık denetlenip gerekirse yeniden düşürülür.
@MainActor
final class ScreenDimmer {
    static let shared = ScreenDimmer()
    static let dimLevel: CGFloat = 0.05
    /// Örtünün koyuluğu (0 saydam, 1 tam siyah). Ekran kısıkken de görülebilsin, dokunuşlar yine geçsin diye tam siyah değil.
    static let overlayAlpha: CGFloat = 0.8
    /// Parlaklık bu kadardan fazla yükselmişse sistem geri yükseltmiş sayılır
    static let tolerance: CGFloat = 0.03

    /// Kısılmadan önceki parlaklık diske de yazılır: program kısılıyken çökerse ya da zorla kapatılırsa sonraki açılışta geri verilir
    static let savedKey = "dimSavedBrightness"

    private let hardware: DimHardware
    private let defaults: UserDefaults
    private let monitorInterval: TimeInterval
    private var monitor: Timer?
    private(set) var saved: CGFloat?
    /// Sistem parlaklığı geri yükselttiği için yeniden kısılan kez (bu çalışmada)
    private(set) var reapplied = 0
    var isDimmed: Bool { return saved != nil }

    /// `hardware` verilmezse gerçek ekran kullanılır (varsayılan değer init gövdesinde kurulur: SystemDimHardware ana iş parçacığına bağlıdır)
    init(hardware: DimHardware? = nil, defaults: UserDefaults = .standard, monitorInterval: TimeInterval = 5) {
        self.hardware = hardware ?? SystemDimHardware()
        self.defaults = defaults
        self.monitorInterval = monitorInterval
    }

    func update(dim: Bool) {
        if dim {
            if saved == nil {
                let before = hardware.brightness
                saved = before
                defaults.set(Double(before), forKey: ScreenDimmer.savedKey)
                tlog("[ekran] kısılıyor (önceki parlaklık %\(Int((before * 100).rounded())))")
                startMonitor()
            }
            apply()
        } else if let value = saved {
            stopMonitor()
            hardware.setOverlay(false)
            hardware.brightness = value
            saved = nil
            defaults.removeObject(forKey: ScreenDimmer.savedKey)
            tlog("[ekran] önceki parlaklık geri verildi (%\(Int((value * 100).rounded())))")
        }
    }

    private func apply() {
        hardware.setOverlay(true)
        if abs(hardware.brightness - ScreenDimmer.dimLevel) > 0.001 { hardware.brightness = ScreenDimmer.dimLevel }
    }

    /// Kısık kalırken sistem parlaklığı yükselttiyse (otomatik parlaklık, ekran uyanması) yeniden düşürür; örtü kaybolduysa geri koyar.
    /// Parlaklık yeniden düşürüldüyse true.
    @discardableResult
    func reassertIfNeeded() -> Bool {
        guard isDimmed else { return false }
        hardware.setOverlay(true)
        guard hardware.brightness > ScreenDimmer.dimLevel + ScreenDimmer.tolerance else { return false }
        hardware.brightness = ScreenDimmer.dimLevel
        reapplied += 1
        if reapplied == 1 || reapplied % 20 == 0 {
            tlog("[ekran] sistem parlaklığı yükseltti, yeniden kısıldı (\(reapplied). kez)")
        }
        return true
    }

    private func startMonitor() {
        guard monitor == nil, monitorInterval > 0 else { return }
        let timer = Timer(timeInterval: monitorInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reassertIfNeeded() }
        }
        RunLoop.main.add(timer, forMode: .common)
        monitor = timer
    }

    private func stopMonitor() {
        monitor?.invalidate()
        monitor = nil
    }

    /// Önceki oturum parlaklık kısılıyken kapandıysa kullanıcının parlaklığını geri verir
    func restoreIfLeftDimmed() {
        guard saved == nil, let value = defaults.object(forKey: ScreenDimmer.savedKey) as? Double else { return }
        hardware.brightness = CGFloat(min(max(value, 0.05), 1.0))
        defaults.removeObject(forKey: ScreenDimmer.savedKey)
        tlog("[ekran] önceki çalışma kısıkken kapanmıştı; parlaklık geri verildi")
    }
}
