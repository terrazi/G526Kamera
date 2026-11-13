import Foundation

/// Ekranın ve oturumun ihtiyaç duyduğu tüm dış bağımlılıklar. Gerçek uygulama AppEnvironment'ta gerçekleriyle, testler sahteleriyle kurar.
@MainActor
struct SessionDependencies {
    let route: AudioRouteProviding
    let listener: SpeechListening
    let recorder: QuestionRecording
    let speaker: AnswerSpeaking
    let network: NetworkWatching
    let health: HealthChecking
    let shortcuts: ShortcutRunning
    let answering: Answering
    let permissions: PermissionProviding
    let replayPlayer: AudioFilePlaying
    let screen: ScreenKeeping
    let scheduler: Scheduling
    let library: AnswerLibrary
    var now: () -> Date = { Date() }
    var sleep: (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
    var recoveryConfig = RecoveryCoordinator.Config()
}

/// Donanım kontrolü maddesi (ekranda ✓ / ✗)
struct CheckItem: Identifiable, Equatable {
    let id: String
    var title: String
    var ok: Bool
    var detail: String
}

/// Ekrandaki kırmızı uyarı kutusunun bir satırı
struct SessionWarning: Identifiable, Equatable {
    let id: String
    var text: String
}
