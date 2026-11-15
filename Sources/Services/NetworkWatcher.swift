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

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let kind: NetworkKind = path.usesInterfaceType(.wifi) ? .wifi : path.usesInterfaceType(.cellular) ? .cellular
                : path.usesInterfaceType(.wiredEthernet) ? .wired : .unknown
            Task { @MainActor in
                self?.kind = kind
                self?.update(online)
                self?.pathChanged()
            }
        }
        monitor.start(queue: DispatchQueue(label: "g526.network"))
        self.monitor = monitor
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
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
