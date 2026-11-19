import Foundation
import Network

/// Telefonun internete çıktığı yol türü ("internet raporu" bunu söyler)
enum NetworkKind: Equatable {
    case wifi, cellular, wired, unknown

    /// Söylenen kısa ad
    var spoken: String {
        switch self {
        case .wifi: return "Wi-Fi"
        case .cellular: return "hücresel veri"
        case .wired: return "kablolu bağlantı"
        case .unknown: return ""
        }
    }
}

/// Bir bağlantının (Wi-Fi, hücresel veri, kulaklık, kamera akışı) var / yok geçişlerini ve her durumun ne kadar sürdüğünü izler (saf mantık).
/// Kullanıcı isteği 2026-11-19: kopmalar ayrıntılı olarak günlüğe işlensin (ne zaman koptu, ne kadar bağlıydı, kaçıncı kopma, ne kadar sonra döndü).
struct LinkTimeline: Equatable {
    let name: String
    private(set) var up: Bool?
    private(set) var since: TimeInterval = 0
    /// Bu çalıştırmada görülen kopma sayısı
    private(set) var drops = 0

    init(name: String) {
        self.name = name
    }

    /// Durum değiştiyse günlüğe yazılacak satır; değişmediyse nil. `detail`: bağlıyken eklenen bilgi (ör. "adres 192.168.100.23")
    mutating func update(up now: Bool, at time: TimeInterval, detail: String = "") -> String? {
        let tail = detail.isEmpty ? "" : " (\(detail))"
        guard let before = up else {
            up = now
            since = time
            return now ? "\(name): bağlı\(tail)" : "\(name): YOK"
        }
        if before == now { return nil }
        let lasted = Int((time - since).rounded())
        up = now
        since = time
        if now { return "\(name) geri geldi: \(lasted) sn yoktu\(tail)" }
        drops += 1
        return "\(name) KOPTU: \(lasted) sn bağlıydı; bu çalıştırmada \(drops). kopma"
    }
}

/// Bağlantı günlüğü yardımcıları (ana aktöre bağlı değildir: ağ izleyicinin kendi sırasından çağrılır)
enum LinkLog {
    static func typeName(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi: return "Wi-Fi"
        case .cellular: return "hücresel"
        case .wiredEthernet: return "kablolu"
        case .loopback: return "iç döngü"
        case .other: return "diğer"
        @unknown default: return "bilinmiyor"
        }
    }

    /// iOS'un ağ yolu hükmü: "durum uygun; kullanılan: hücresel; arayüzler: en0 (Wi-Fi), pdp_ip0 (hücresel); pahalı yol"
    static func describe(_ path: NWPath) -> String {
        var parts: [String] = []
        switch path.status {
        case .satisfied: parts.append("durum uygun")
        case .unsatisfied: parts.append("durum YOL YOK")
        case .requiresConnection: parts.append("durum bağlantı gerekiyor")
        @unknown default: parts.append("durum bilinmiyor")
        }
        if path.status != .satisfied {
            switch path.unsatisfiedReason {
            case .cellularDenied: parts.append("neden: hücresel veri bu uygulamaya kapalı")
            case .wifiDenied: parts.append("neden: Wi-Fi bu uygulamaya kapalı")
            case .localNetworkDenied: parts.append("neden: yerel ağ izni yok")
            case .notAvailable: parts.append("neden: kullanılabilir ağ yok")
            default: parts.append("neden: bilinmiyor")
            }
        }
        // iOS aynı arayüzü birden çok kez sayabiliyor (gerçek günlük: "en0 (Wi-Fi), en0 (Wi-Fi)"): her ad bir kez yazılır
        let used = unique(path.availableInterfaces.filter { path.usesInterfaceType($0.type) }.map { typeName($0.type) })
        if !used.isEmpty { parts.append("kullanılan: " + used.joined(separator: ", ")) }
        let all = unique(path.availableInterfaces.map { "\($0.name) (\(typeName($0.type)))" })
        parts.append("arayüzler: " + (all.isEmpty ? "yok" : all.joined(separator: ", ")))
        if path.isExpensive { parts.append("pahalı yol") }
        if path.isConstrained { parts.append("düşük veri kipi") }
        return parts.joined(separator: "; ")
    }

    /// Sırayı bozmadan yinelenenleri atar
    static func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in items where !seen.contains(item) {
            seen.insert(item)
            result.append(item)
        }
        return result
    }

    /// Telefonun Wi-Fi (en0) adresi; Wi-Fi'ye bağlı değilse nil. Kameranın ağı internetsiz olduğu için "Wi-Fi var mı" buradan anlaşılır
    static func wifiAddress() -> String? {
        return LocalNetwork.wifi().map { LocalNetwork.string($0.ip) }
    }
}

/// Modül 4: ağı sürekli dinler. "Çevrimiçi" = iOS'a göre kullanılabilir bir yol var (gerçek erişim ayrıca HealthChecking ile sınanır).
@MainActor
protocol NetworkWatching: AnyObject {
    var isOnline: Bool { get }
    /// Şu an kullanılan yol türü (bilinmiyorsa `.unknown`)
    var kind: NetworkKind { get }
    /// Çevrimiçi durumu her değiştiğinde çağrılır
    var onChange: (@MainActor (Bool) -> Void)? { get set }
    /// Ağ yolu her değiştiğinde (Wi-Fi ↔ hücresel dahil, çevrimiçi durumu aynı kalsa da) çağrılır; hemen bir nabız atılır
    var onPathChange: (@MainActor () -> Void)? { get set }
    func start()
    func stop()
}

extension NetworkWatching {
    var kind: NetworkKind { return .unknown }
}

@MainActor
final class NetworkWatcher: NetworkWatching {
    var onChange: (@MainActor (Bool) -> Void)?
    var onPathChange: (@MainActor () -> Void)?
    private(set) var isOnline = true
    private(set) var kind: NetworkKind = .unknown
    private var monitor: NWPathMonitor?
    // Kopma günlüğü: Wi-Fi ve hücresel ayrı ayrı izlenir (kameranın Wi-Fi'si internetsizdir; genel yol hücreselden gider ve Wi-Fi kopsa da "çevrimiçi" kalır)
    private var wifiMonitor: NWPathMonitor?
    private var cellularMonitor: NWPathMonitor?
    private var wifiLine = LinkTimeline(name: "Wi-Fi")
    private var cellularLine = LinkTimeline(name: "Hücresel veri")
    private var lastPathText = ""
    private var lastPathTime: TimeInterval = 0
    private var lastWifiPathText = ""

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let kind: NetworkKind = path.usesInterfaceType(.wifi) ? .wifi : path.usesInterfaceType(.cellular) ? .cellular
                : path.usesInterfaceType(.wiredEthernet) ? .wired : .unknown
            let text = LinkLog.describe(path)
            Task { @MainActor in
                self?.kind = kind
                self?.update(online)
                self?.pathChanged()
                self?.logPath(text)
            }
        }
        monitor.start(queue: DispatchQueue(label: "g526.network"))
        self.monitor = monitor

        let wifi = NWPathMonitor(requiredInterfaceType: .wifi)
        wifi.pathUpdateHandler = { [weak self] path in
            let text = LinkLog.describe(path)
            Task { @MainActor in self?.wifiPathChanged(text) }
        }
        wifi.start(queue: DispatchQueue(label: "g526.network.wifi"))
        wifiMonitor = wifi

        let cellular = NWPathMonitor(requiredInterfaceType: .cellular)
        cellular.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            let text = LinkLog.describe(path)
            Task { @MainActor in self?.cellularPathChanged(available, text) }
        }
        cellular.start(queue: DispatchQueue(label: "g526.network.cellular"))
        cellularMonitor = cellular
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        wifiMonitor?.cancel()
        wifiMonitor = nil
        cellularMonitor?.cancel()
        cellularMonitor = nil
    }

    // MARK: Kopma günlüğü

    /// Genel ağ yolu değişti: yeni hüküm ve önceki durumun ne kadar sürdüğü yazılır (aynı hüküm yinelenmez)
    private func logPath(_ text: String) {
        guard monitor != nil else { return }
        checkWifiAddress()
        if text == lastPathText { return }
        let now = ProcessInfo.processInfo.systemUptime
        let lasted = lastPathText.isEmpty ? "" : " (önceki durum \(Int((now - lastPathTime).rounded())) sn sürdü)"
        lastPathText = text
        lastPathTime = now
        tlog("[bağlantı] ağ yolu: \(text)\(lasted)")
    }

    /// Wi-Fi'nin varlığı telefonun Wi-Fi adresinden anlaşılır; kopma ve geri gelme süreleriyle yazılır
    private func checkWifiAddress() {
        guard monitor != nil else { return }
        let address = LinkLog.wifiAddress()
        let detail = address.map { "adres \($0)" } ?? ""
        if let line = wifiLine.update(up: address != nil, at: ProcessInfo.processInfo.systemUptime, detail: detail) {
            tlog("[bağlantı] \(line)")
        }
    }

    private func wifiPathChanged(_ text: String) {
        guard monitor != nil else { return }
        if text != lastWifiPathText {
            lastWifiPathText = text
            tlog("[bağlantı] Wi-Fi yolu (iOS): \(text); Wi-Fi adresi \(LinkLog.wifiAddress() ?? "yok")")
        }
        checkWifiAddress()
        // Adres, bağlantı bildiriminden birkaç saniye sonra atanabilir (ya da düşebilir): iki kez daha bakılır
        for delay in [2.0, 6.0] {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                self?.checkWifiAddress()
            }
        }
    }

    private func cellularPathChanged(_ available: Bool, _ text: String) {
        guard monitor != nil else { return }
        if let line = cellularLine.update(up: available, at: ProcessInfo.processInfo.systemUptime) {
            tlog("[bağlantı] \(line) [\(text)]")
        }
    }

    private func pathChanged() {
        guard monitor != nil else { return }
        onPathChange?()
    }

    private func update(_ online: Bool) {
        guard monitor != nil, online != isOnline else { return }
        isOnline = online
        onChange?(online)
    }
}
