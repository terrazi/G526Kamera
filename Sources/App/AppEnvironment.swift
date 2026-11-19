import Foundation
import Combine
import UserNotifications

/// Uygulamanın kurulum noktası: gerçek servisleri yaratır, birbirine bağlar. İş mantığı burada değil, SessionViewModel'dedir.
@MainActor
final class AppEnvironment: ObservableObject {
    let settings: AppSettings
    /// Kamera ayarları
    let camera: CameraSettings
    /// Sürüm 4: soruyu kamera ile çeken bileşen (çekim sürerken ana ekranda canlı görüntü gösterir)
    let cameraController: CameraCaptureController
    /// Sürüm 4: sınavdan önce kamera yolunu uçtan uca sınar (Ayarlar > Kamera > "Kamerayı dene")
    let cameraTester: CameraTester
    let session: SessionViewModel
    let settingsModel: SettingsViewModel
    private let folderStore: FolderStore
    /// Pano işareti (kapanma engeli ayarı ve uygulamadan çıkış bunu eşitler)
    private let journal: RunJournal
    /// Uygulama önde mi (pano işareti öndeyken kullanıcının kopyaladığı metnin üstüne yazılmaz)
    private let foreground: ForegroundFlag

    private let starter = StartScheduler()
    private let notificationRouter = StartNotificationRouter()
    private var cancellables = Set<AnyCancellable>()

    init() {
        let settings = AppSettings()
        let camera = CameraSettings()
        BackgroundGrace.enabled = true   // ağ işleri arka plana geçilse de bitsin (gönderim yarıda kesilmesin)
        CameraCaptureController.purgeLeftoverVideos()
        let cameraController = CameraCaptureController(settings: camera)
        settings.applyShortcutPresetOnce()
        settings.applyCameraPresetOnce(camera: camera)
        settings.moveInternetPresetOnce()
        settings.applyPaidLineupOnce()
        camera.applyAlwaysOnOnce()
        let folderStore = FolderStore()
        let recorder = PCMRecorder()
        let route = AudioSessionGuard()
        let listener = OnDeviceSpeechListener(recorder: recorder, wantsEnglish: { false })   // sesli sınav kaldırıldı: yardımcı İngilizce tanıyıcı çalıştırılmaz (yalnız Türkçe komut dinlenir)
        let phoneVoice = SpeechRenderer(voice: { SpeechVoiceChooser.voice(preferredID: settings.phoneVoiceID) })
        let geminiVoice = GeminiVoice(keys: { settings.usableGeminiProfiles.map { $0.key } })
        let speaker = HeadphoneSpeaker(
            // Çıkış yalnız Bluetooth kulaklıksa çalınır (KURAL 1)
            isRouteSafe: { AudioRouting.verdict(route.snapshot()).headphonesOK },
            // Kaydedilen cevaplar Gemini sesiyle (ayar açıksa), kısa anonslar hızlı olsun diye telefonun sesiyle
            engines: { saving in saving && settings.geminiVoice ? [geminiVoice, phoneVoice] : [phoneVoice] },
            voice: { SpeechVoiceChooser.voice(preferredID: settings.phoneVoiceID) })
        let shortcuts = ShortcutRunner()
        let health = NetworkHealth()
        let journal = RunJournal()
        journal.closeGuardEnabled = { settings.closeGuard }
        let foreground = ForegroundFlag()
        journal.appInForeground = { foreground.value }
        let captureStore = FileCaptureStore(root: FileCaptureStore.documentsRoot())
        captureStore.prepare()
        shortcuts.onLeaving = { journal.setAway(true) }
        shortcuts.onReturned = { journal.setAway(false) }
        let answering = GeminiAnswerService(profiles: { settings.geminiProfileInfos() })
        answering.largeFiles = { camera.largeUpload }
        var deps = SessionDependencies(route: route,
                                       listener: listener,
                                       recorder: recorder,
                                       speaker: speaker,
                                       network: NetworkWatcher(),
                                       health: health,
                                       shortcuts: shortcuts,
                                       answering: answering,
                                       permissions: SystemPermissions(),
                                       replayPlayer: speaker.filePlayer,
                                       screen: SystemScreen(),
                                       scheduler: DispatchScheduler(),
                                       library: AnswerLibrary(resolver: { folderStore.resolution() }, refresh: { folderStore.refresh() }),
                                       camera: cameraController,
                                       captureStore: captureStore,
                                       battery: SystemBattery(),
                                       system: SystemHealthMonitor(),
                                       volume: SystemVolumeControl(),
                                       journal: journal)
        // Bağlantı onarımı (kullanıcı kararı 2026-11-19): kopan aygıtın kestirmesi 3 kez, açılmazsa uçak modu kestirmesi; tur başarısızsa beklenip
        // yeniden denenir (en çok 3 saat; bkz. `SessionViewModel.Timing.outageLimit`)
        deps.recoveryConfig = RecoveryCoordinator.Config(maxCycles: 1, deviceTries: 3)
        let session = SessionViewModel(settings: settings, deps: deps, camera: camera)
        self.settings = settings
        self.camera = camera
        self.cameraController = cameraController
        self.cameraTester = CameraTester(camera: cameraController, shortcuts: shortcuts, health: health, settings: settings,
                                         cameraSettings: camera, captureStore: captureStore,
                                         sessionActive: { [weak session] in session?.phase.isRunning ?? false })
        self.session = session
        self.folderStore = folderStore
        self.journal = journal
        self.foreground = foreground
        self.settingsModel = SettingsViewModel(settings: settings, shortcuts: shortcuts, folder: folderStore,
                                               sessionActive: { [weak session] in session?.phase.isRunning ?? false })
        ScreenDimmer.shared.restoreIfLeftDimmed()
        wireStartTriggers()
        wireDimming()
        wireCellularRoute()
        wireCloseGuard()
    }

    /// Ayarlar > "Kapanma engeli" değişince pano işareti hemen eşitlenir (@Published değişmeden önce yayınlar: ana kuyrukta okunur)
    private func wireCloseGuard() {
        settings.$closeGuard
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.journal.syncCloseGuard() }
            .store(in: &cancellables)
        // "Pano işaretini kullan" kapatılınca panodaki işaret hemen silinir (yalnız kalıcı bayrak kalır)
        settings.$clipboardMarker
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.journal.syncCloseGuard() }
            .store(in: &cancellables)
    }

    /// Toplu çekim kipi açıkken Gemini ve internet yoklaması, telefon kameranın Wi-Fi'sindeyse hücresel yoldan da gidebilir (bkz. `CellularRoute`)
    private func wireCellularRoute() {
        camera.$pageSeries
            .sink { CellularRoute.enabled = $0 }
            .store(in: &cancellables)
    }

    /// Ekran yalnız şu durumda kısılır: ayar açık, uygulama önde ve kırmızı uyarı yok (uyarı görünsün). Test sürmesi şart değildir.
    private var isActive = true

    private func wireDimming() {
        Publishers.CombineLatest(session.$warnings, settings.$dimScreen)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.syncDimming() }
            .store(in: &cancellables)
    }

    /// Son verilen karar (günlüğe yalnız değişince yazılır)
    private var lastDimDecision: DimDecision?

    func syncDimming() {
        let decision = DimDecision.decide(enabled: settings.dimScreen, active: isActive, warnings: session.warnings.map { $0.text })
        if decision != lastDimDecision {
            lastDimDecision = decision
            if decision != .settingOff { tlog("[ekran] \(decision.statusText)") }
        }
        settingsModel.dimStatus = decision.statusText
        ScreenDimmer.shared.update(dim: decision.shouldDim)
    }

    /// Uygulama arka plana ya da pasife geçerken kullanıcının parlaklığı geri verilir
    func appBecameInactive() {
        tlog("[uygulama] arka plana ya da pasife geçti")
        isActive = false
        foreground.value = false
        syncDimming()
        journal.syncCloseGuard()   // engel kapalıysa: çıkarken pano işareti yerinde olsun (kopyalanmış günlük korunur)
    }

    /// Zamanlı başlatma: uygulama açıkken saat dolunca, ya da bildirime dokunulunca oturum başlar
    private func wireStartTriggers() {
        starter.onFire = { [weak self] in self?.session.start() }
        notificationRouter.onTap = { [weak self] in self?.session.start() }
        UNUserNotificationCenter.current().delegate = notificationRouter
        Publishers.CombineLatest(settings.$startEnabled, settings.$startMinutes)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled, minutes in
                Task { @MainActor in self?.starter.apply(enabled: enabled, minutes: minutes) }
            }
            .store(in: &cancellables)
    }

    /// Uygulama öne gelince zamanlayıcı yeniden kurulur (arka planda zamanlayıcılar duraklar); duraklatılmışsa ses yoluna yeniden bakılır
    func appBecameActive() {
        tlog("[uygulama] öne geldi")
        isActive = true
        foreground.value = true
        syncDimming()
        journal.syncCloseGuard(releasingPasteHold: true)   // günlük yapıştırıldı sayılır: işaret kalkar, pano yalnız günlük olur
        starter.apply(enabled: settings.startEnabled, minutes: settings.startMinutes)
        session.recheckHardware()
        session.refreshRouteText()
        settingsModel.refreshFolderStatus()
    }
}
