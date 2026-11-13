import Foundation
import UIKit

/// Telefon şarjı düşünce her eşikte (yüzde 20, 10, 5) yalnız bir kez uyarmak için karar verir (saf mantık; birim testle denenir).
/// Şarja takılınca ya da yüzde 25'in üstüne çıkınca sıfırlanır. (İlk sürümden alındı.)
struct LowBatteryWatcher {
    static let thresholds = [5, 10, 20]      // küçükten büyüğe
    static let resetAbove = 25

    private var announced = 100

    /// Uyarılacaksa şu anki yüzdeyi döndürür
    mutating func update(percent: Int?, charging: Bool) -> Int? {
        guard let p = percent else { return nil }
        if charging || p > Self.resetAbove {
            announced = 100
            return nil
        }
        for t in Self.thresholds where p <= t && t < announced {
            announced = t
            return p
        }
        return nil
    }
}

/// Telefonun şarjını veren katman (gerçeği SystemBattery, testlerde sahtesi)
@MainActor
protocol BatteryProviding: AnyObject {
    /// Şarj yüzdesi (okunamıyorsa nil)
    var percent: Int? { get }
    /// Şarja takılı mı (dolu da sayılır)
    var charging: Bool { get }
    /// Şarj düzeyi ya da şarj durumu değişince çağrılır
    var onChange: (() -> Void)? { get set }
}

/// Pil bilgisi olmayan ortam (varsayılan; uyarı çıkmaz)
@MainActor
final class NoBattery: BatteryProviding {
    var percent: Int? { return nil }
    var charging: Bool { return false }
    var onChange: (() -> Void)?
}

@MainActor
final class SystemBattery: BatteryProviding {
    var onChange: (() -> Void)?
    private var observers: [NSObjectProtocol] = []

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.onChange?() }
            })
        }
    }

    var percent: Int? {
        let level = UIDevice.current.batteryLevel
        return level < 0 ? nil : Int((level * 100).rounded())
    }

    var charging: Bool {
        let state = UIDevice.current.batteryState
        return state == .charging || state == .full
    }
}
