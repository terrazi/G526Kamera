import Foundation

/// Modül 4: "ölümcül sessizlik" bekçisi. Dinleme sırasında 30 saniye boyunca tek kelime gelmezse `onExpire` çağrılır.
/// Her yeni kelime `kick()` ile süreyi baştan başlatır; dinleme dışındaki anlarda (Gemini bekleniyor, cevap okunuyor) kapalıdır.
@MainActor
final class SilenceWatchdog {
    static let limit: TimeInterval = 30

    var onExpire: (@MainActor () -> Void)?

    private let scheduler: Scheduling
    private let limit: TimeInterval
    private var task: ScheduledTask?

    init(scheduler: Scheduling, limit: TimeInterval = SilenceWatchdog.limit) {
        self.scheduler = scheduler
        self.limit = limit
    }

    var isArmed: Bool { return task != nil }

    /// Süreyi baştan başlatır (ilk çağrıda bekçiyi kurar)
    func kick() {
        task?.cancel()
        task = scheduler.after(limit) { [weak self] in
            self?.task = nil
            self?.onExpire?()
        }
    }

    func disarm() {
        task?.cancel()
        task = nil
    }
}
