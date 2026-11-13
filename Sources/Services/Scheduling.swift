import Foundation

/// İptal edilebilir gecikmeli iş
final class ScheduledTask {
    private var cancelAction: (() -> Void)?

    init(cancel: @escaping () -> Void) {
        cancelAction = cancel
    }

    func cancel() {
        cancelAction?()
        cancelAction = nil
    }
}

/// "N saniye sonra yap" altyapısı. Gerçek uygulama DispatchQueue.main.asyncAfter kullanır; testler elle ilerletilen sahte zamanlayıcı verir.
@MainActor
protocol Scheduling: AnyObject {
    func after(_ seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ScheduledTask
}

@MainActor
final class DispatchScheduler: Scheduling {
    func after(_ seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ScheduledTask {
        let item = DispatchWorkItem {
            Task { @MainActor in action() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, seconds), execute: item)
        return ScheduledTask(cancel: { item.cancel() })
    }
}
