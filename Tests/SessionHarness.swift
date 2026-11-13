import XCTest
@testable import G526CameraDrive

/// SessionViewModel'i tüm sahtelerle kuran düzenek
@MainActor
final class SessionHarness {
    let route = FakeRoute()
    let listener = FakeListener()
    let recorder = FakeRecorder()
    let speaker = FakeSpeaker()
    let network = FakeNetwork()
    let health = FakeHealth()
    let shortcuts = FakeShortcuts()
    let answering = FakeAnswering()
    let permissions = FakePermissions()
    let player = FakePlayer()
    let screen = FakeScreen()
    let battery = FakeBattery()
    let scheduler = ManualScheduler()
    let root: URL
    let settings: AppSettings
    let vm: SessionViewModel

    init(shortcutNames: Bool = true, library: AnswerLibrary? = nil) {
        root = makeTempFolder("g526-oturum")
        let defaults = UserDefaults(suiteName: "g526.testler.\(UUID().uuidString)")!
        settings = AppSettings(defaults: defaults)
        if shortcutNames {
            settings.wifiShortcut = "WiFi_Ac"
            settings.cellularShortcut = "Hücresel_Ac"
            settings.bluetoothShortcut = "Bluetooth_Yenile"
            settings.resetShortcut = "Sistemi_Sifirla"
        }
        let deps = SessionDependencies(route: route,
                                       listener: listener,
                                       recorder: recorder,
                                       speaker: speaker,
                                       network: network,
                                       health: health,
                                       shortcuts: shortcuts,
                                       answering: answering,
                                       permissions: permissions,
                                       replayPlayer: player,
                                       screen: screen,
                                       scheduler: scheduler,
                                       library: library ?? AnswerLibrary(root: root),
                                       now: { Date(timeIntervalSince1970: 1_800_000_000) },
                                       sleep: { _ in },
                                       recoveryConfig: RecoveryCoordinator.Config(settle: 0, verifyWindow: 0, verifyInterval: 1,
                                                                                  cycleGap: 0, maxCycles: 1),
                                       battery: battery)
        vm = SessionViewModel(settings: settings, deps: deps)
    }

    /// Oturumu başlatır ve "Ben hazırım" anonsundan sonra dinleme açılana kadar bekler
    func startListening() async -> Bool {
        vm.start()
        return await waitUntil { self.vm.phase == .listening }
    }

    /// Kullanıcı soruyu okur ve "Cevapla" der; tetikleyicinin sabit kalma süresi geçirilir
    func ask(_ question: String) {
        listener.say(question + " Cevapla")
        scheduler.advance(by: SessionViewModel.Timing.triggerConfirm + 0.1)
    }

    var isHardwarePause: Bool {
        if case .paused(.hardware) = vm.phase { return true }
        return false
    }

    var isConnectionPause: Bool {
        if case .paused(.noConnection) = vm.phase { return true }
        return false
    }
}
