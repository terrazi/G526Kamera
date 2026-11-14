import Foundation
import UIKit
import os

/// Telefonun kaynak durumunun anlık görüntüsü: bellek, ısı, güç modu, boş yer
struct SystemSnapshot: Equatable {
    /// iOS'un bu uygulamayı kapatmadan önce ayırabileceği kalan bellek (MB); okunamıyorsa nil
    var availableMemoryMB: Int?
    /// Uygulamanın şu an kullandığı bellek (MB); okunamıyorsa nil
    var footprintMB: Int?
    var thermal: ProcessInfo.ThermalState
    var lowPowerMode: Bool
    /// Cihazda boş kalan yer (MB); okunamıyorsa nil
    var freeDiskMB: Int?

    /// Günlük satırı: "bellek kullanımı 180 MB, kalan 1900 MB; ısı normal; güç modu normal; boş yer 5200 MB"
    var line: String {
        let used = footprintMB.map { "\($0) MB" } ?? "okunamadı"
        let left = availableMemoryMB.map { "\($0) MB" } ?? "okunamadı"
        let disk = freeDiskMB.map { "\($0) MB" } ?? "okunamadı"
        return "bellek kullanımı \(used), kalan \(left); ısı \(DeviceInfo.thermalText(thermal)); güç modu \(lowPowerMode ? "düşük güç" : "normal"); boş yer \(disk)"
    }
}

/// Telefonun kaynak durumunu veren ve sistemin uyarılarını ileten katman (gerçeği SystemHealthMonitor, testlerde sahtesi)
@MainActor
protocol SystemHealthProviding: AnyObject {
    func snapshot() -> SystemSnapshot
    /// iOS "bellek azaldı" uyarısı verdi
    var onMemoryWarning: (() -> Void)? { get set }
    /// Isı düzeyi değişti
    var onThermalChange: (() -> Void)? { get set }
    /// Düşük güç modu açıldı ya da kapandı
    var onPowerModeChange: (() -> Void)? { get set }
}

/// Sistem bilgisi olmayan ortam (varsayılan; uyarı çıkmaz)
@MainActor
final class NoSystemHealth: SystemHealthProviding {
    var onMemoryWarning: (() -> Void)?
    var onThermalChange: (() -> Void)?
    var onPowerModeChange: (() -> Void)?

    func snapshot() -> SystemSnapshot {
        return SystemSnapshot(availableMemoryMB: nil, footprintMB: nil, thermal: .nominal, lowPowerMode: false, freeDiskMB: nil)
    }
}

@MainActor
final class SystemHealthMonitor: SystemHealthProviding {
    var onMemoryWarning: (() -> Void)?
    var onThermalChange: (() -> Void)?
    var onPowerModeChange: (() -> Void)?
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onMemoryWarning?() }
        })
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onThermalChange?() }
        })
        observers.append(center.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onPowerModeChange?() }
        })
    }

    func snapshot() -> SystemSnapshot {
        let info = ProcessInfo.processInfo
        let available = os_proc_available_memory()
        return SystemSnapshot(availableMemoryMB: available > 0 ? available / 1_048_576 : nil,
                              footprintMB: SystemHealthMonitor.footprintBytes().map { Int($0 / 1_048_576) },
                              thermal: info.thermalState,
                              lowPowerMode: info.isLowPowerModeEnabled,
                              freeDiskMB: DeviceInfo.freeBytes().map { Int($0 / 1_048_576) })
    }

    /// Uygulamanın fiziksel bellek ayak izi (iOS'un bellek baskısında esas aldığı değer)
    static func footprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : nil
    }
}
