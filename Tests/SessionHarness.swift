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
    let camera = FakeCamera()
    let cameraSettings: CameraSettings
    /// Sürüm 4 olay sırası: "kestirme:<ad>", "çekim", "gönderim"
    private(set) var events: [String] = []
    let permissions = FakePermissions()
    let player = FakePlayer()
    let screen = FakeScreen()
    let battery = FakeBattery()
    let system = FakeSystem()
    let volume = FakeVolume()
    let journal = FakeJournal()
    let exits = ExitCounter()
    let scheduler = ManualScheduler()
    let root: URL
    let settings: AppSettings
    let vm: SessionViewModel

    init(shortcutNames: Bool = true, library: AnswerLibrary? = nil, cameraFlow: Bool = false) {
        root = makeTempFolder("g526-oturum")
        let defaults = UserDefaults(suiteName: "g526.testler.\(UUID().uuidString)")!
        settings = AppSettings(defaults: defaults)
        // Anında tespit (nabız) varsayılan olarak açıktır; eski testlerin zamanlaması bozulmasın diye burada kapalı, ona ait testler açar
        settings.instantDetection = false
        // Numara sorma ve "gönderildi" anonsu varsayılan olarak açıktır; eski testlerin akışı bozulmasın diye burada kapalı, ona ait testler açar
        settings.askMissingNumber = false
        // "Lütfen sonraki soruyu okuyun" anonsu varsayılan olarak açıktır; eski testlerin konuşma dizileri bozulmasın diye burada kapalı, ona ait testler açar
        settings.askNextQuestion = false
        settings.spokenProgress = false
        settings.smartResume = false
        // Sürüm 4: her soruda "kamera ile çekmek ister misiniz?" varsayılan olarak açıktır; V3 testlerinin akışı bozulmasın diye burada kapalı
        settings.askCamera = cameraFlow
        cameraSettings = CameraSettings(defaults: defaults)
        if shortcutNames {
            settings.wifiShortcut = "WiFi_Ac"
            settings.cellularShortcut = "Hücresel_Ac"
            settings.bluetoothShortcut = "Bluetooth_Yenile"
            settings.resetShortcut = "Sistemi_Sifirla"
        }
        if cameraFlow {
            settings.internetShortcut = "Hücresele_Gec"
            cameraSettings.cameraShortcutName = "Kameraya_Gec"
            settings.wifiShortcut = "Kamera_Onar"   // Sürüm 4: Wi-Fi adımı kamera bağlantısını onarır
        }
        let exitCounter = exits
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
                                       camera: camera,
                                       battery: battery,
                                       system: system,
                                       volume: volume,
                                       journal: journal,
                                       terminate: { exitCounter.count += 1 })
        vm = SessionViewModel(settings: settings, deps: deps, camera: cameraSettings)
        // Varsayılan: ses çubuğu isteği ses seviyesine yansır (gerçek telefondaki başarılı durum); sınanacak testler `volume.apply = nil` yapar
        let fakeSystem = system
        volume.apply = { level in fakeSystem.current.outputVolume = level }
        let announcedBy = vm
        speaker.isAnnouncement = { text in announcedBy.announced.contains(text) }
    }

    /// Sürüm 4 olay sırasını kaydeder: kestirme çalışınca "kestirme:<ad>", kamera çekerken "çekim", Gemini'ye giderken "gönderim".
    /// `onShortcut`: kestirme çalışınca dünyada olacak değişiklik (ör. interneti geri getirmek).
    func trackEvents(onShortcut: ((String) -> Void)? = nil) {
        shortcuts.onRun = { [unowned self] name in
            self.events.append("kestirme:\(name)")
            onShortcut?(name)
        }
        camera.onCapture = { [unowned self] in self.events.append("çekim") }
        answering.onCall = { [unowned self] name in self.events.append(name) }
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
