import Foundation
import SwiftUI
import Combine
import AudioToolbox
import UIKit

/// Son çözülen karenin zamanı (çözücü başka iş parçacığında çalıştığı için kilitli).
private final class DecodeClock {
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

/// Uygulamanın orkestratörü: kamera → çözücü → ekran / kare deposu; ses ve değişim tetikleyicileri;
/// çekim → Drive kuyruğu.
@MainActor
final class AppModel: ObservableObject {
    let settings = AppSettings.shared
    let auth = GoogleAuth.shared
    let queue = UploadQueue.shared
    let logStore = AppLog.shared

    @Published private(set) var cameraState: CameraState = .stopped
    @Published private(set) var resolutionText = ""
    @Published private(set) var heardText = ""
    @Published private(set) var speechStatus = ""
    @Published private(set) var banner = ""
    @Published private(set) var lastPhoto: UIImage?
    @Published private(set) var lastPhotoInfo = ""
    @Published private(set) var capturing = false
    @Published private(set) var deviceInfo = ""
    /// Kameradan gelen görüntü gerçekten çözülüp ekrana veriliyor mu (son 3 sn içinde kare var mı)
    @Published private(set) var decoding = false

    private let client = CameraClient()
    private let decoder = H264Decoder()
    private let pipeline = FramePipeline()
    private let decodeClock = DecodeClock()
    private let speech = SpeechTrigger()
    private var videoHeight = 0
    private var started = false
    private var lastVoice: TimeInterval = 0
    private var bannerToken = 0
    private var cameraKey = ""
    private var speechKey = ""
    private var cancellables = Set<AnyCancellable>()

    var renderer: VideoRenderer { return pipeline.renderer }

    init() {
        let pipeline = self.pipeline
        let decoder = self.decoder
        let clock = self.decodeClock

        decoder.onDecoded = { pixelBuffer, time in
            clock.mark()
            pipeline.handle(pixelBuffer, time: time)
        }
        decoder.onResolution = { [weak self] width, height in
            Task { @MainActor in self?.resolutionChanged(width: width, height: height) }
        }
        client.onFrame = { frame in
            decoder.submit(frame)
        }
        client.onState = { [weak self] state in
            Task { @MainActor in self?.stateChanged(state) }
        }
        client.onDeviceInfo = { [weak self] info in
            let text = AppModel.describe(info)
            Task { @MainActor in self?.deviceInfo = text }
        }
        pipeline.onMotionTrigger = { [weak self] in
            Task { @MainActor in self?.capture(reason: "Görüntü değişti") }
        }
        speech.onTrigger = { [weak self] _ in
            Task { @MainActor in self?.voiceTriggered() }
        }
        speech.onStatus = { [weak self] text in
            Task { @MainActor in self?.speechStatus = text }
        }
        speech.onHeard = { [weak self] text in
            Task { @MainActor in self?.heardText = text }
        }

        // "Canlı" yalnızca çözülmüş kare geliyorsa yazılsın (kare gelip çözülemiyorsa yanıltmasın)
        Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshDecoding() }
            }
            .store(in: &cancellables)

        // Pil tasarrufu ayarları anında uygulanır
        Publishers.CombineLatest(settings.$previewOff, settings.$dimWhenPreviewOff)
            .sink { [weak self] _, _ in
                Task { @MainActor in self?.updatePowerSaving() }
            }
            .store(in: &cancellables)

        // Ayarlar değişince (yazmayı bitirince) kendiliğinden uygula
        settings.objectWillChange
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.applySettings() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Yaşam döngüsü

    func start() {
        if started {
            updatePowerSaving()
            return
        }
        started = true
        UIApplication.shared.isIdleTimerDisabled = true
        applySettings(force: true)
        updatePowerSaving()
    }

    /// Önizleme kapalıysa kare gönderimi ve analiz seyrekleşir, istenirse ekran kısılır.
    func updatePowerSaving() {
        pipeline.saving = settings.previewOff
        ScreenDimmer.shared.update(dim: started && settings.previewOff && settings.dimWhenPreviewOff)
    }

    /// Uygulama pasifleşirken (kilit, denetim merkezi, başka uygulama) kullanıcının parlaklığı geri verilir.
    func restoreScreen() {
        ScreenDimmer.shared.update(dim: false)
    }

    func stop() {
        if !started { return }
        started = false
        UIApplication.shared.isIdleTimerDisabled = false
        ScreenDimmer.shared.update(dim: false)
        client.stop()
        decoder.reset()
        speech.stop()
        cameraState = .stopped
        speechStatus = ""
    }

    func applySettings(force: Bool = false) {
        guard started else { return }
        let cKey = "\(settings.uid)|\(settings.cameraIP)|\(settings.cameraPassword)|\(settings.streamQuality)"
        if force || cKey != cameraKey {
            cameraKey = cKey
            restartCamera()
        }
        let sKey = "\(settings.voiceEnabled)|\(settings.triggerWord)"
        if force || sKey != speechKey {
            speechKey = sKey
            restartSpeech()
        }
        pipeline.configureMotion(enabled: settings.motionEnabled, sensitivity: settings.motionSensitivity)
    }

    private func restartCamera() {
        client.stop()
        guard let uid = CameraUID(settings.uid) else {
            cameraState = .stopped
            resolutionText = ""
            flash("Ayarlar'dan kamera UID'sini girin", seconds: 6)
            return
        }
        decoder.reset()
        pipeline.reset()
        decodeClock.clear()
        decoding = false
        let quality = settings.streamQuality == 2 ? (state: 2, stream: 2) : (state: 1, stream: 1)
        let config = CameraSession.Config(uid: uid,
                                          password: settings.cameraPassword,
                                          manualIP: settings.cameraIP.trimmed,
                                          videoState: quality.state,
                                          videoStream: quality.stream,
                                          tzHours: TimeZone.current.secondsFromGMT() / 3600)
        cameraState = .connecting("Kameraya bağlanılıyor…")
        client.start(config: config)
    }

    private func restartSpeech() {
        speech.stop()
        heardText = ""
        guard settings.voiceEnabled else {
            speechStatus = "Sesli komut kapalı"
            return
        }
        speech.start(trigger: settings.triggerWord)
    }

    // MARK: - Olaylar

    private func stateChanged(_ state: CameraState) {
        guard started || state == .stopped else { return }
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

    private func refreshDecoding() {
        let ok = cameraState.isLive && decodeClock.age() < 3.0
        if ok != decoding { decoding = ok }
    }

    /// Görüntü gerçekten akıyor mu (bağlantı + çözülmüş kare)
    var isLive: Bool { return cameraState.isLive && decoding }

    /// Ekranda gösterilecek kamera durumu
    var statusText: String {
        if cameraState.isLive && !decoding { return "Görüntü çözülüyor…" }
        return cameraState.text
    }

    private func resolutionChanged(width: Int, height: Int) {
        videoHeight = height
        resolutionText = "\(width)×\(height)"
    }

    private func voiceTriggered() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastVoice < settings.cooldown { return }
        lastVoice = now
        capture(reason: "Sesli komut")
    }

    // MARK: - Çekim

    func capture(reason: String) {
        guard isLive else {
            flash("Kamera görüntüsü yok — fotoğraf çekilemedi")
            return
        }
        let s = settings
        let options = CaptureOptions(
            before: s.burstBefore,
            after: s.burstAfter,
            multiFrame: s.multiFrame,
            enhance: EnhanceOptions(level: s.enhancement, deskew: s.deskew, upscale: s.upscale,
                                    timestamp: s.timestampMode, quality: s.jpegQuality))
        let accepted = pipeline.engine.capture(reason: reason, options: options) { [weak self] result in
            Task { @MainActor in self?.captureFinished(result, reason: reason) }
        }
        if accepted {
            capturing = true
            AudioServicesPlaySystemSound(1108)
        } else {
            flash("Önceki fotoğraf işleniyor…", seconds: 1.5)
        }
    }

    private func captureFinished(_ result: Result<CapturedPhoto, CaptureError>, reason: String) {
        capturing = false
        switch result {
        case .success(let photo):
            lastPhoto = UIImage(data: photo.jpeg)
            lastPhotoInfo = "\(photo.width)×\(photo.height) · \(photo.jpeg.count / 1024) KB · \(reason)"
            if queue.enqueue(jpeg: photo.jpeg, date: photo.date) == nil {
                flash("Fotoğraf kaydedilemedi (depolama dolu olabilir)", seconds: 5)
            } else {
                flash("Fotoğraf çekildi")
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .failure(let error):
            flash(error.message, seconds: 4)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    func flash(_ text: String, seconds: Double = 3) {
        banner = text
        bannerToken += 1
        let mine = bannerToken
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self = self, self.bannerToken == mine else { return }
            self.banner = ""
        }
    }

    // MARK: - Tanı

    func currentStats() -> String {
        let session = client.sessionStatistics
        return "Çözülen kare: \(decoder.decodedFrames) · Depodaki kare: \(pipeline.framesSeen)\n\(session)"
    }

    nonisolated static func describe(_ info: [String: Any]) -> String {
        var lines: [String] = []
        for key in info.keys.sorted() {
            if key == "pwd" || key == "cmd" { continue }
            let value = info[key]
            if value is [String: Any] || value is [Any] { continue }
            lines.append("\(key): \(value ?? "")")
        }
        return lines.joined(separator: "\n")
    }
}
