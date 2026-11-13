import Foundation
import Network

/// Modül 4: ağı sürekli dinler. "Çevrimiçi" = iOS'a göre kullanılabilir bir yol var (gerçek erişim ayrıca HealthChecking ile sınanır).
@MainActor
protocol NetworkWatching: AnyObject {
    var isOnline: Bool { get }
    /// Çevrimiçi durumu her değiştiğinde çağrılır
    var onChange: (@MainActor (Bool) -> Void)? { get set }
    func start()
    func stop()
}

@MainActor
final class NetworkWatcher: NetworkWatching {
    var onChange: (@MainActor (Bool) -> Void)?
    private(set) var isOnline = true
    private var monitor: NWPathMonitor?

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.update(online) }
        }
        monitor.start(queue: DispatchQueue(label: "g526.network"))
        self.monitor = monitor
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }

    private func update(_ online: Bool) {
        guard monitor != nil, online != isOnline else { return }
        isOnline = online
        onChange?(online)
    }
}
