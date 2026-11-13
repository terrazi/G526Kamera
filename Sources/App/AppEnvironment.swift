import Foundation
import Combine
import UserNotifications

/// Uygulamanın kurulum noktası: gerçek servisleri yaratır, birbirine bağlar. İş mantığı burada değil, SessionViewModel'dedir.
@MainActor
final class AppEnvironment: ObservableObject {
    let settings: AppSettings
    let session: SessionViewModel
    let settingsModel: SettingsViewModel
    private let folderStore: FolderStore

    private let starter = StartScheduler()
    private let notificationRouter = StartNotificationRouter()
    private var cancellables = Set<AnyCancellable>()

    init() {
        let settings = AppSettings()
        let folderStore = FolderStore()
        let recorder = PCMRecorder()
        let route = AudioSessionGuard()
        let listener = OnDeviceSpeechListener(recorder: recorder)
        let phoneVoice = SpeechRenderer()
        let geminiVoice = GeminiVoice(keys: { settings.usableGeminiProfiles.map { $0.key } })
        let speaker = HeadphoneSpeaker(
            // Çıkış yalnız Bluetooth kulaklıksa çalınır (KURAL 1)
            isRouteSafe: { AudioRouting.verdict(route.snapshot()).headphonesOK },
            // Kaydedilen cevaplar Gemini sesiyle (ayar açıksa), kısa anonslar hızlı olsun diye telefonun sesiyle
            engines: { saving in saving && settings.geminiVoice ? [geminiVoice, phoneVoice] : [phoneVoice] })
        let shortcuts = ShortcutRunner()
        let deps = SessionDependencies(route: route,
                                       listener: listener,
                                       recorder: recorder,
                                       speaker: speaker,
                                       network: NetworkWatcher(),
                                       health: NetworkHealth(),
                                       shortcuts: shortcuts,
                                       answering: GeminiAnswerService(profiles: { settings.geminiProfileInfos() }),
                                       permissions: SystemPermissions(),
                                       replayPlayer: speaker.filePlayer,
                                       screen: SystemScreen(),
                                       scheduler: DispatchScheduler(),
                                       library: AnswerLibrary(resolver: { folderStore.resolution() }, refresh: { folderStore.refresh() }))
        let session = SessionViewModel(settings: settings, deps: deps)
        self.settings = settings
        self.session = session
        self.folderStore = folderStore
        self.settingsModel = SettingsViewModel(settings: settings, shortcuts: shortcuts, folder: folderStore,
                                               sessionActive: { [weak session] in session?.phase.isRunning ?? false })
        wireStartTriggers()
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
        starter.apply(enabled: settings.startEnabled, minutes: settings.startMinutes)
        session.recheckHardware()
        session.refreshInputs()
        settingsModel.refreshFolderStatus()
    }
}
