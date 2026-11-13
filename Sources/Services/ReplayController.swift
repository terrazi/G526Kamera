import Foundation

/// Bir ses dosyasını çalan katman (gerçeği AVAudioPlayer, testlerde sahtesi)
@MainActor
protocol AudioFilePlaying: AnyObject {
    /// Dosyayı çalar; bitince `completion` ana iş parçacığında bir kez çağrılır: normal bitişte true, durdurulunca ya da hatada false
    func play(_ url: URL, completion: @escaping @MainActor (Bool) -> Void)
    func stop()
}

/// Modül 6: test sonu çevrimdışı tekrar. Dosyalar sırayla çalınır; her dosya bitince ayarlardaki süre (0-10 sn) beklenir,
/// bekleme `DispatchQueue.main.asyncAfter` ile yapılır, sonra sıradaki dosya çalar. Liste bitince durur.
@MainActor
final class ReplayController {
    enum State: Equatable {
        case idle
        case playing(index: Int, total: Int)
        case gap(next: Int, total: Int)
        case finished
        case stopped(String)

        var isActive: Bool {
            switch self {
            case .playing, .gap: return true
            default: return false
            }
        }
    }

    var onState: (@MainActor (State) -> Void)?
    private(set) var state: State = .idle {
        didSet { onState?(state) }
    }

    private let player: AudioFilePlaying
    private let scheduler: Scheduling
    private let canPlay: () -> Bool
    private var files: [URL] = []
    private var gap: TimeInterval = AppSettings.defaultReplayGap
    private var index = 0
    private var generation = 0
    private var pendingGap: ScheduledTask?

    /// `canPlay`: her dosyadan önce sorulur; Bluetooth kulaklık yoksa tekrar durur (ses telefondan çıkmaz)
    init(player: AudioFilePlaying, scheduler: Scheduling, canPlay: @escaping () -> Bool) {
        self.player = player
        self.scheduler = scheduler
        self.canPlay = canPlay
    }

    func start(files: [URL], gap: TimeInterval) {
        cancelPending()
        self.files = files
        self.gap = AppSettings.clampGap(gap)
        index = 0
        playCurrent()
    }

    /// Tekrarı durdurur (çalan dosya susar, bekleyen boşluk iptal olur)
    func stop(reason: String = "Tekrar durduruldu.") {
        let wasActive = state.isActive
        cancelPending()
        if wasActive { state = .stopped(reason) }
    }

    private func cancelPending() {
        generation += 1
        pendingGap?.cancel()
        pendingGap = nil
        player.stop()
    }

    private func playCurrent() {
        guard index < files.count else {
            state = .finished
            return
        }
        guard canPlay() else {
            state = .stopped(Say.noHeadphonesForReplay)
            return
        }
        let mine = generation
        state = .playing(index: index + 1, total: files.count)
        player.play(files[index]) { [weak self] ok in
            self?.fileFinished(ok, generation: mine)
        }
    }

    private func fileFinished(_ ok: Bool, generation mine: Int) {
        guard mine == generation else { return }
        guard ok else {
            state = .stopped("Dosya çalınamadı.")
            return
        }
        index += 1
        if index >= files.count {
            state = .finished
            return
        }
        state = .gap(next: index + 1, total: files.count)
        pendingGap = scheduler.after(gap) { [weak self] in
            guard let self = self, mine == self.generation else { return }
            self.pendingGap = nil
            self.playCurrent()
        }
    }
}
