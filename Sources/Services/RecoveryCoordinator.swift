import Foundation

/// Modül 4: Kestirmelerle kendi kendini onarma. Sırayla Wi-Fi, hücresel, sistem sıfırlama kestirmesini çalıştırır;
/// her birinden sonra bağlantı düzeldi mi diye bakar. Düzelirse durur.
@MainActor
final class RecoveryCoordinator {
    struct Config: Equatable {
        /// Kestirme bittikten sonra ağın oturması için beklenen süre
        var settle: TimeInterval = 3
        /// Doğrulama için toplam bekleme penceresi ve yoklama aralığı
        var verifyWindow: TimeInterval = 20
        var verifyInterval: TimeInterval = 2.5
        /// Üç adım da başarısız olursa yeni tur öncesi bekleme ve en çok tur sayısı
        var cycleGap: TimeInterval = 20
        var maxCycles = 3
    }

    enum Result: Equatable {
        /// Sorun giderildi. `by` = düzelten adım (kestirme gerekmeden kendiliğinden düzeldiyse nil)
        case recovered(by: RecoveryStep?)
        case gaveUp
        /// Hiçbir adım için kestirme adı yazılmamış
        case notConfigured
    }

    enum Update: Equatable {
        case checking
        case running(RecoveryStep)
        case verifying(RecoveryStep)
        case waiting(cycle: Int)
    }

    private let shortcuts: ShortcutRunning
    private let name: (RecoveryStep) -> String
    private let sleep: (TimeInterval) async -> Void
    let config: Config

    init(shortcuts: ShortcutRunning,
         name: @escaping (RecoveryStep) -> String,
         config: Config = Config(),
         sleep: @escaping (TimeInterval) async -> Void = { seconds in
             try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
         }) {
        self.shortcuts = shortcuts
        self.name = name
        self.config = config
        self.sleep = sleep
    }

    /// `verify`: nedene göre "sorun bitti mi" sınaması (ağ için internet+Gemini ping, donanım için ses yolu).
    /// `force`: sorun `verify` ile görülemiyorsa (ör. ses yolu güvenli ama mikrofon ses vermiyor) ilk sınama atlanır ve
    /// adımlar en az bir kez çalıştırılır.
    func recover(reason: RecoveryReason,
                 force: Bool = false,
                 verify: @escaping (RecoveryReason) async -> Bool,
                 update: @escaping (Update) -> Void) async -> Result {
        update(.checking)
        // Kendiliğinden düzelmiş olabilir: boşuna kestirme çalıştırma
        if !force, await verify(reason) { return .recovered(by: nil) }

        let steps = reason.steps.filter { !name($0).trimmed.isEmpty }
        guard !steps.isEmpty else { return .notConfigured }

        for cycle in 1...max(1, config.maxCycles) {
            for step in steps {
                if Task.isCancelled { return .gaveUp }
                update(.running(step))
                let outcome = await shortcuts.run(name: name(step).trimmed)
                tlog("[onarım] \(reason.title) / \(step.title): \(outcome)")
                if Task.isCancelled { return .gaveUp }
                update(.verifying(step))
                if await waitUntilHealthy(reason: reason, verify: verify) { return .recovered(by: step) }
            }
            if cycle < config.maxCycles {
                update(.waiting(cycle: cycle))
                await sleep(config.cycleGap)
            }
        }
        return .gaveUp
    }

    private func waitUntilHealthy(reason: RecoveryReason, verify: (RecoveryReason) async -> Bool) async -> Bool {
        await sleep(config.settle)
        var waited: TimeInterval = 0
        while true {
            if Task.isCancelled { return false }
            if await verify(reason) { return true }
            if waited >= config.verifyWindow { return false }
            await sleep(config.verifyInterval)
            waited += config.verifyInterval
        }
    }
}
