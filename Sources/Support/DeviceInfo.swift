import Foundation
import UIKit

/// "Tanı ve günlük" ekranındaki cihaz özeti. Biçim saf bir işlevdir (sınanır); okuma `current()` içindedir.
enum DeviceInfo {
    static func thermalText(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "normal"
        case .fair: return "biraz ısındı"
        case .serious: return "ısındı (yavaşlayabilir)"
        case .critical: return "çok sıcak"
        @unknown default: return "bilinmiyor"
        }
    }

    static func summary(build: String, model: String, system: String, battery: Int?, charging: Bool,
                        thermal: String, freeBytes: Int64?) -> String {
        var lines = ["Sürüm: \(build)", "Cihaz: \(model), \(system)"]
        if let battery = battery {
            lines.append("Şarj: yüzde \(battery)" + (charging ? " (şarjda)" : ""))
        } else {
            lines.append("Şarj: okunamıyor")
        }
        lines.append("Isı: \(thermal)")
        if let free = freeBytes {
            lines.append("Boş yer: " + ByteCountFormatter.string(fromByteCount: free, countStyle: .file))
        } else {
            lines.append("Boş yer: okunamıyor")
        }
        return lines.joined(separator: "\n")
    }

    /// Cihazda boş kalan yer (bayt)
    static func freeBytes() -> Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    @MainActor
    static func current() -> String {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel
        let percent: Int? = level < 0 ? nil : Int((level * 100).rounded())
        let charging = device.batteryState == .charging || device.batteryState == .full
        return summary(build: BuildInfo.version, model: device.model, system: "\(device.systemName) \(device.systemVersion)",
                       battery: percent, charging: charging,
                       thermal: thermalText(ProcessInfo.processInfo.thermalState), freeBytes: freeBytes())
    }
}
