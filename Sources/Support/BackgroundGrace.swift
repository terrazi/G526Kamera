import UIKit

/// Uygulama arka plana geçse bile (örn. Kestirmeler uygulaması öne gelince, ekran kilitlenince) bir ağ işinin bitmesi için sistemden ek süre ister
/// (yaklaşık 30 sn). Günlükte yükleme sürerken uygulama 30 sn askıya alındı ve gönderim "ağ hatası" verdi. Süre dolarsa görev kapatılır
/// (kapatılmazsa sistem uygulamayı sonlandırır). Testlerde kapalıdır; gerçek uygulamada `AppEnvironment` açar.
enum BackgroundGrace {
    private static let lock = NSLock()
    private static var flag = false

    static var enabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return flag
        }
        set {
            lock.lock()
            flag = newValue
            lock.unlock()
        }
    }

    /// `work` sürerken sistemden arka plan süresi ister; sonucu ve hatayı olduğu gibi geçirir
    static func run<T>(_ name: String, _ work: () async throws -> T) async throws -> T {
        guard enabled else { return try await work() }
        let id = await begin(name)
        do {
            let result = try await work()
            await end(id)
            return result
        } catch {
            await end(id)
            throw error
        }
    }

    @MainActor private static func begin(_ name: String) -> UIBackgroundTaskIdentifier {
        var id = UIBackgroundTaskIdentifier.invalid
        id = UIApplication.shared.beginBackgroundTask(withName: name) {
            if id != .invalid {
                UIApplication.shared.endBackgroundTask(id)
                id = .invalid
            }
        }
        return id
    }

    @MainActor private static func end(_ id: UIBackgroundTaskIdentifier) {
        if id != .invalid { UIApplication.shared.endBackgroundTask(id) }
    }
}
