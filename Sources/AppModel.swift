import Foundation
import SwiftUI
import Combine
import UIKit

/// Son çözülen karenin zamanı (çözücü başka iş parçacığında çalıştığı için kilitli).
final class DecodeClock {
    private let lock = NSLock()
    private var last: TimeInterval = 0

    func mark() {
        lock.lock()
        last = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    func clear() {
        lock.lock()
        last = 0
        lock.unlock()
    }

    /// Son çözülen kareden bu yana geçen süre (hiç kare yoksa sonsuz)
    func age() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return last == 0 ? .infinity : ProcessInfo.processInfo.systemUptime - last
    }
}

/// Taramanın aşaması (ekranda başlık olarak görünür)
enum ScanPhase: Equatable {
    case idle, startingCamera, waitingForPage, scanning, restoringInternet, asking, reading, done, failed

    var title: String {
        switch self {
        case .idle: return "Hazır"
        case .startingCamera: return "Kamera açılıyor"
        case .waitingForPage: return "Evrak bekleniyor"
        case .scanning: return "Taranıyor"
        case .restoringInternet: return "İnternet bağlanıyor"
        case .asking: return "Cevaplar hazırlanıyor"
        case .reading: return "Cevaplar okunuyor"
        case .done: return "Tamamlandı"
        case .failed: return "Durdu"
        }
    }

    var isRunning: Bool {
        switch self {
        case .idle, .done, .failed: return false
        default: return true
        }
    }
}

/// Kırmızı kutudaki bir uyarı (anahtarı aynı olan uyarı yenisiyle değişir)
struct ProblemNote: Equatable {
    let key: String
    let text: String
}

/// Analiz kuyruğundan gelen son sayfa ölçümü
struct PageSample {
    var metrics: PageMetrics
    var stillFor: TimeInterval
    var diffToCapture: Double
    /// Ölçümün geldiği an (systemUptime)
    var arrived: TimeInterval
}

/// Programın orkestratörü: kamera → çözücü → ekran / kare toplama; tarama akışı (AppModel+Scan), internet ve cevaplar (AppModel+Answers).
/// Yayınlanan alanlar yalnız AppModel içinden değiştirilir; ekranlar yalnız okur.
@MainActor
final class AppModel: ObservableObject {
    let settings = AppSettings.shared
    let voice = Voice()

    @Published var cameraState: CameraState = .stopped
    @Published var decoding = false
    @Published var resolutionText = ""
    @Published var phase: ScanPhase = .idle
    @Published var statusText = "Hazır"
    @Published var banner = ""
    /// Kırmızı kutudaki uyarılar
    @Published var notes: [ProblemNote] = []
    @Published var acceptedNumbers: [Int] = []
    /// Yarım kalan (üst ya da alt kısmı alınmış, tamamlanmayı bekleyen) sorular
    @Published var waitingQuestions: [Int] = []
    @Published var answers: [AnswerRecord] = []
    @Published var lastSaid = ""

    let client = CameraClient()
    let decoder = H264Decoder()
    let pipeline = FramePipeline()
    let recorder = VideoRecorder()
    let collector = FrameCollector()
    let guidance = GuidanceEngine()
    let decodeClock = DecodeClock()
    var cancellables = Set<AnyCancellable>()

    /// Çalışan tarama görevi
    var runTask: Task<Void, Never>?
    /// Bu taramanın kayıt defteri, geçici dosyaları ve klasör adı
    var ledger = ScanLedger(total: 0)
    var files: ScanFiles?
    var runName = ""
    var latestSample: PageSample?
    /// Konum tarifi şu an söylensin mi (yalnız yeni çekim beklenirken)
    var guidanceActive = false
    var lastDocAt: TimeInterval?
    /// Konum tarifi motorunun kamera durgunken verdiği son öneri ve zamanı: çekim, yazı kadraja tam sığınca başlar
    var lastAdvice: GuidanceAdvice?
    var lastAdviceAt: TimeInterval = 0
    var repeatGate = RepeatGate()
    /// Kestirmeden dönüş sayacı (g526kamera://kestirme gelince artar)
    var shortcutReturns = 0
    var jpegSerial = 0
    var videoCount = 0
    var bannerToken = 0

    var renderer: VideoRenderer { return pipeline.renderer }
    var folderReady: Bool { return DocumentFolder.shared.hasChoice }

    init() {
        ScreenDimmer.shared.restoreIfLeftDimmed()
        let pipeline = self.pipeline
        let decoder = self.decoder
        let clock = self.decodeClock
        let recorder = self.recorder
        let collector = self.collector
        decoder.onDecoded = { buffer, time in
            clock.mark()
            pipeline.handle(buffer, time: time)
        }
        // Her analiz edilen kare hem videoya (en net kare) hem çekim penceresine (yarım saniyede en net kare) verilir
        pipeline.onAnalyzed = { buffer, time, sharpness in
            recorder.offer(buffer, time: time, sharpness: sharpness)
            collector.offer(buffer, time: time, sharpness: sharpness)
        }
        decoder.onResolution = { [weak self] width, height in
            Task { @MainActor in self?.resolutionText = "\(width)×\(height)" }
        }
        client.onFrame = { frame in decoder.submit(frame) }
        client.onState = { [weak self] state in
            Task { @MainActor in self?.cameraStateChanged(state) }
        }
        pipeline.onGuidance = { [weak self] sample in
            Task { @MainActor in self?.guidanceSample(sample) }
        }
        // "Canlı" yalnızca çözülmüş kare geliyorsa yazılır
        Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshDecoding() }
            }
            .store(in: &cancellables)
        Publishers.CombineLatest(settings.$previewOff, settings.$dimScreen)
            .sink { [weak self] _, _ in
                Task { @MainActor in self?.updatePowerSaving() }
            }
            .store(in: &cancellables)
        Publishers.CombineLatest(settings.$speechVoiceID, settings.$speechRate)
            .sink { [weak self] _, _ in
                Task { @MainActor in self?.configureVoice() }
            }
            .store(in: &cancellables)
        configureVoice()
    }

    // MARK: - Yaşam döngüsü

    /// Uygulama öne gelince: ekran uyumasın
    func appActive() {
        UIApplication.shared.isIdleTimerDisabled = true
        updatePowerSaving()
    }

    /// Uygulama pasifleşirken (kilit, denetim merkezi, kestirme) kullanıcının parlaklığı geri verilir. Çalışan tarama durmaz.
    func restoreScreen() {
        ScreenDimmer.shared.update(dim: false)
    }

    func updatePowerSaving() {
        pipeline.saving = settings.previewOff
        ScreenDimmer.shared.update(dim: phase.isRunning && settings.dimScreen)
    }

    func configureVoice() {
        voice.configure(voiceID: settings.speechVoiceID, rate: settings.speechRate)
    }

    /// Ayarlardaki "Bu sesi dene"
    func previewVoice() {
        configureVoice()
        voice.say("Bu, okuma sesinin denemesidir. Birinci soru, ADANA, kırk iki.", interrupt: true)
    }

    // MARK: - Kamera

    func cameraStateChanged(_ state: CameraState) {
        cameraState = state
        switch state {
        case .connecting, .reconnecting:
            decoder.reset()
            pipeline.reset()
            decodeClock.clear()
            decoding = false
        default:
            break
        }
    }

    func refreshDecoding() {
        let ok = cameraState.isLive && decodeClock.age() < 3.0
        if ok != decoding { decoding = ok }
        if voice.headphonesReady { removeNote("kulaklik") }
    }

    /// Kamera istemcisini (yeniden) başlatır; UID girilmemişse false
    @discardableResult
    func startCameraClient() -> Bool {
        client.stop()
        guard let uid = CameraUID(settings.uid) else {
            cameraState = .stopped
            return false
        }
        decoder.reset()
        pipeline.reset()
        decodeClock.clear()
        decoding = false
        let quality = settings.streamQuality == 2 ? 2 : 1
        let config = CameraSession.Config(uid: uid,
                                          password: settings.cameraPassword,
                                          manualIP: settings.cameraIP.trimmed,
                                          videoState: quality,
                                          videoStream: quality,
                                          tzHours: TimeZone.current.secondsFromGMT() / 3600,
                                          probe: false)
        cameraState = .connecting("Kameraya bağlanılıyor…")
        client.start(config: config)
        return true
    }

    /// Kamerayı kapatır (tarama bitince ya da durdurulunca)
    func stopCamera() {
        client.stop()
        decoder.reset()
        pipeline.reset()
        decodeClock.clear()
        decoding = false
        cameraState = .stopped
    }

    // MARK: - Konum tarifi

    /// Analiz kuyruğundan gelen ölçüm: son ölçüm saklanır; yeni çekim beklenirken yönlendirme cümlesi söylenir
    func guidanceSample(_ sample: FramePipeline.GuidanceSample) {
        let now = ProcessInfo.processInfo.systemUptime
        latestSample = PageSample(metrics: sample.metrics, stillFor: sample.stillFor, diffToCapture: sample.diffToCapture, arrived: now)
        if DocumentGate.isDocument(sample.metrics) { lastDocAt = now }
        guard guidanceActive, phase == .scanning || phase == .waitingForPage else { return }
        let out = guidance.videoStep(sample.metrics, time: sample.time, stillFor: sample.stillFor)
        lastAdvice = out.advice
        lastAdviceAt = now
        // Kadraj boşken ("Yazı görünmüyor") konuşulmaz: evrak bekleme ve eksik soru uyarıları zaten bunu söyler; sayfa çevrilirken susulur
        if out.advice == .noText { return }
        if let text = out.speak, voice.sayIfIdle(text) { lastSaid = text }
    }

    /// Konum tarifi motorunu ayarlardan kurar
    func configureGuidance() {
        pipeline.guidanceOrientation = settings.imageOrientation
        pipeline.guidanceOn = true
        pipeline.pageEdgesOn = false
        guidance.config.topBand = settings.imageOrientation == .normal ? GuidanceAnalyzer.skipTop : 0
        guidance.describeScene = false
        guidance.config.autoPick = false
        guidance.resetVideo()
    }

    // MARK: - Uyarılar ve duyurular

    func addNote(_ key: String, _ text: String) {
        if let i = notes.firstIndex(where: { $0.key == key }) {
            if notes[i].text != text { notes[i] = ProblemNote(key: key, text: text) }
        } else {
            notes.append(ProblemNote(key: key, text: text))
        }
        tlog("[uyarı] \(text)")
    }

    func removeNote(_ key: String) {
        if notes.contains(where: { $0.key == key }) { notes.removeAll { $0.key == key } }
    }

    func setStatus(_ text: String) {
        if statusText != text { statusText = text }
    }

    /// Kısa süreli ekran yazısı
    func flash(_ text: String, seconds: Double = 4) {
        banner = text
        bannerToken += 1
        let token = bannerToken
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            Task { @MainActor in
                if self?.bannerToken == token { self?.banner = "" }
            }
        }
    }

    /// Sesle söyler ve son söyleneni ekranda tutar
    func say(_ text: String, interrupt: Bool = false) {
        voice.say(text, interrupt: interrupt)
        lastSaid = text
        if !voice.headphonesReady {
            addNote("kulaklik", "Kulaklık bağlı değil: sesli uyarılar verilmiyor (telefon hoparlöründen hiç konuşulmaz). Kulaklığı bağlayın.")
        }
    }

    /// Söyler ve bitmesini bekler
    func sayAndWait(_ text: String) async {
        say(text)
        await voice.waitUntilIdle()
    }

    func pause(_ seconds: Double) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func now() -> TimeInterval { return ProcessInfo.processInfo.systemUptime }

    // MARK: - Kestirmeler

    /// g526kamera://basla (otomasyon) / kestirme (kestirmeden dönüş) / sec (liste seçici)
    func handleIncomingURL(_ url: URL) {
        guard url.scheme == ShortcutLink.callbackScheme else { return }
        switch url.host {
        case "basla":
            tlog("[akış] otomasyon başlatma bağlantısı geldi")
            beginScan(auto: true)
        case "kestirme":
            shortcutReturns += 1
        case "sec":
            guard let pick = ShortcutLink.selection(from: url) else { return }
            switch pick.kind {
            case .connection: settings.connectionShortcutName = pick.name
            case .camera: settings.cameraShortcutName = pick.name
            }
            flash("\(pick.kind.title) kestirmesi seçildi: \(pick.name)", seconds: 6)
        default:
            break
        }
    }

    /// Ayarlardaki "Dene"
    func testShortcut(named name: String) {
        _ = openShortcut(named: name)
    }

    /// Kestirmeler uygulamasında adlı kestirmeyi açar; bitince uygulamaya g526kamera://kestirme ile dönülür
    @discardableResult
    func openShortcut(named name: String) -> Bool {
        guard let url = ShortcutLink.url(name: name) else { return false }
        tlog("[kestirme] çalıştırılıyor: \(name)")
        UIApplication.shared.open(url) { opened in
            if !opened { tlog("[kestirme] Kestirmeler açılamadı") }
        }
        return true
    }

    /// Kestirmeyi çalıştırır ve (en çok `ScanRules.shortcutReturnSeconds`) dönüşünü bekler; ad boşsa ya da açılamazsa false
    func runShortcutAndWait(_ name: String) async -> Bool {
        let before = shortcutReturns
        guard openShortcut(named: name) else { return false }
        let deadline = now() + ScanRules.shortcutReturnSeconds
        while shortcutReturns == before && now() < deadline && !Task.isCancelled {
            await pause(0.5)
        }
        return shortcutReturns != before
    }
}
