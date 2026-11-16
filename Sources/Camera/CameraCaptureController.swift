import Foundation
import Combine
import AVFoundation
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

/// Telefonun boş yer koruması: çok azalınca çekim başlamaz (dolu disk video yazamaz, telefonu da yavaşlatır)
enum DiskGuard {
    static let lowMB = 1500
    static let criticalMB = 400

    enum Level: Equatable { case ok, low, critical }

    /// freeMB < 0: ölçülemedi (sorun sayılmaz)
    static func level(freeMB: Int) -> Level {
        if freeMB < 0 { return .ok }
        if freeMB < criticalMB { return .critical }
        if freeMB < lowMB { return .low }
        return .ok
    }

    /// Uygulamanın bulunduğu bölümdeki boş yer (MB); -1 = ölçülemedi
    static func freeMB() -> Int {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage else { return -1 }
        return Int(bytes / 1_048_576)
    }
}

/// Kamera çekimi sırasında söylenen cümleler (konumlandırma cümleleri Guidance.swift'ten gelir)
enum CameraSay {
    static let ready = "Kamera hazır. Soruyu kadraja alın."
    /// Ortak paragraf çekilirken (Sürüm 4)
    static let readyPassage = "Kamera hazır. Ortak paragrafı kadraja alın."
    static func readyLine(_ subject: CaptureSubject) -> String { return subject == .passage ? readyPassage : ready }
    static func framing(_ subject: CaptureSubject) -> String { return subject == .passage ? "Paragrafı kadraja alın" : "Soruyu kadraja alın" }
    static let shooting = "Çekiyorum, kamerayı sabit tutun."
    static let forced = "Yine de çekiyorum, kamerayı sabit tutun."
    static let manual = "Çekiyorum, kamerayı sabit tutun."
}

/// Kamera çekimi (CameraClient, H264Decoder, FramePipeline, GuidanceEngine, CaptureEngine, VideoRecorder). Çekim tek bir sorudur ve
/// bittiğinde kamera KAPATILIR.
///
/// Akış: kameraya bağlan → görüntü gelince sesle konumlandır (odak kipi: kadrajın ortasındaki soru; kenarlardan yarım görünen diğer
/// sorular sorun sayılmaz) → konum uygun olunca (ya da `positionSeconds` sonunda yine de) aynı anda fotoğraf çek ve `pageVideoSeconds` sn
/// video kaydet → kamerayı kapat. Hücresel/Wi-Fi geçişleri bu sınıfın değil, çağıranın (Kestirmeler) işidir.
@MainActor
final class CameraCaptureController: ObservableObject, CameraCapturing {
    var onSay: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    var subject: CaptureSubject = .question

    /// Ekranda: kamera görüntüsü gösterilsin mi (çekim sürerken)
    @Published private(set) var active = false
    @Published private(set) var cameraState: CameraState = .stopped
    @Published private(set) var statusText = ""
    @Published private(set) var cameraBattery: CameraBatteryLevel?
    /// Kamera kapanınca `cameraBattery` silinir; bu son okunan değeri tutar ("kamera raporu", "Kamerayı dene")
    private(set) var lastBattery: CameraBatteryLevel?

    /// Konumlandırma için en çok beklenecek süre (sn); dolunca kadrajda belge varsa yine de çekilir
    static let positionSeconds: TimeInterval = 30
    /// Kameraya bağlanıp görüntü gelmesi için en çok beklenecek süre (sn)
    static let connectSeconds: TimeInterval = 40
    /// Süre dolarken kameraya el sıkışılmış ama görüntü henüz gelmemişse tanınan ek süre (kamera bazen sınırın hemen sonunda bağlanır)
    static let connectGraceSeconds: TimeInterval = 15
    /// Konumlandırma sürerken görüntü bu kadar saniye kesilirse beklenmeden vazgeçilir
    static let lostSeconds = 8

    let settings: CameraSettings
    private let client = CameraClient()
    private let decoder = H264Decoder()
    private let pipeline = FramePipeline()
    private let videoRecorder = VideoRecorder()
    private let guidance = GuidanceEngine()
    private let decodeClock = DecodeClock()
    private let batteryMonitor = CameraBatteryMonitor()
    private var lowBattery = CameraLowBatteryWatcher()

    private enum Trigger { case positioned, forced, manual, lost, cancelled }
    private var waiter: CheckedContinuation<Trigger, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var running = false
    private var cancelled = false
    private var shooting = false
    private var cancellables = Set<AnyCancellable>()

    var renderer: VideoRenderer { return pipeline.renderer }

    init(settings: CameraSettings) {
        self.settings = settings
        let pipeline = self.pipeline
        let clock = self.decodeClock
        let recorder = self.videoRecorder
        let decoder = self.decoder
        decoder.onDecoded = { pixelBuffer, time in
            clock.mark()
            pipeline.handle(pixelBuffer, time: time)
        }
        // Video kaydı kareleri netlik puanıyla alır: her yarım saniyeden en net kare yazılır
        pipeline.onAnalyzed = { pixelBuffer, time, sharpness in
            recorder.offer(pixelBuffer, time: time, sharpness: sharpness)
        }
        let monitor = self.batteryMonitor
        client.onFrame = { [weak self] frame in
            decoder.submit(frame)
            if let level = monitor.feed(header: frame.header, now: ProcessInfo.processInfo.systemUptime) {
                Task { @MainActor in self?.batteryChanged(level) }
            }
        }
        client.onState = { [weak self] state in
            Task { @MainActor in self?.stateChanged(state) }
        }
        pipeline.onGuidance = { [weak self] sample in
            Task { @MainActor in self?.guidanceSample(sample) }
        }
        // Çekim dışında hiçbir şey çalışmaz: önizleme ve ölçüm kapalıdır
        pipeline.guidanceOn = false
    }

    // MARK: Durum

    /// Çözülmüş kare gerçekten geliyor mu (son 3 sn içinde)
    var isLive: Bool { return cameraState.isLive && decodeClock.age() < 3.0 }

    private func stateChanged(_ state: CameraState) {
        guard running || state == .stopped else { return }
        cameraState = state
        switch state {
        case .connecting, .reconnecting:
            decoder.reset()
            pipeline.reset()
            decodeClock.clear()
            batteryMonitor.reset()
            cameraBattery = nil
            pipeline.renderer.clear()   // akış koptu: eski kare "canlı" görünüp donmuş kalmasın
        default:
            break
        }
    }

    private func batteryChanged(_ level: CameraBatteryLevel) {
        cameraBattery = level
        lastBattery = level
        if running, let n = lowBattery.update(level) { say(CameraBattery.lowWarning(level: n), status: true) }
    }

    private func status(_ text: String) {
        statusText = text
        onStatus?(text)
    }

    /// `status`: kamera / gönderim durumu haberi (yalnız "Kamera ve gönderim durumunu da söyle" açıkken söylenir); diğerleri konumlandırma cümleleridir
    private func say(_ text: String, status: Bool = false) {
        guard settings.guidanceVoice, !status || settings.statusNotices else { return }
        onSay?(text)
        tlog("[kamera] \(text)")
    }

    // MARK: Çekim

    func capture() async -> Result<CapturedQuestion, CameraFailure> {
        return await capture(connectLimit: nil)
    }

    func capture(connectLimit: TimeInterval?) async -> Result<CapturedQuestion, CameraFailure> {
        closeHeld()   // oturum başından kalan açık bağlantı varsa kapanır: çekim kendi bağlantısını kurar
        guard !running else { return .failure(.captureFailed("çekim zaten sürüyor")) }
        running = true
        cancelled = false
        shooting = false
        active = true
        defer {
            teardown()
            running = false
            active = false
        }
        guard DiskGuard.level(freeMB: DiskGuard.freeMB()) != .critical else { return .failure(.lowDisk) }
        guard let uid = CameraUID(settings.uid) else { return .failure(.notConnected) }

        pipeline.saving = settings.previewOff   // pil tasarrufu: ekrana kare gönderilmez, analiz seyreltilir

        // 1) Bağlan
        status("Kameraya bağlanılıyor")
        lowBattery = CameraLowBatteryWatcher()
        startClient(uid: uid)
        var live = await waitUntil(seconds: connectLimit ?? CameraCaptureController.connectSeconds) { self.isLive }
        if !live, !cancelled, case .connected = cameraState {
            tlog("[kamera] el sıkışıldı, görüntü bekleniyor: \(Int(CameraCaptureController.connectGraceSeconds)) sn ek süre")
            live = await waitUntil(seconds: CameraCaptureController.connectGraceSeconds) { self.isLive }
        }
        if cancelled { return .failure(.cancelled) }
        guard live else {
            switch cameraState {
            case .connected, .streaming: return .failure(.noFrames)
            default: return .failure(.notConnected)
            }
        }

        // 2) Konumlandır ("Sesle konumlandır" kapalıysa konumlandırma yok: bağlanır bağlanmaz çekilir)
        let trigger: Trigger
        if settings.guidanceEnabled {
            configureGuidance()
            status(CameraSay.framing(subject))
            say(CameraSay.readyLine(subject))
            trigger = await awaitTrigger(seconds: CameraCaptureController.positionSeconds)
        } else {
            trigger = .manual
        }
        if trigger == .cancelled || cancelled { return .failure(.cancelled) }
        if trigger == .lost {
            say("Kamera görüntüsü kesildi.", status: true)
            return .failure(.noFrames)
        }
        guard isLive else { return .failure(.noFrames) }

        // 3) Fotoğraf + video
        pipeline.guidanceOn = false
        switch trigger {
        case .forced: say(CameraSay.forced)
        default: say(CameraSay.shooting)
        }
        return await shoot(reason: trigger == .positioned ? "Sesli konumlandırma" : (trigger == .manual ? "Elle" : "Süre doldu"))
    }

    /// Kameraya ulaşılabiliyor mu: bağlanıp görüntü gelirse true. Kamerası kapalı ya da şarjı bitmiş bir sınavda kamera dönene kadar 5 dakikada bir
    /// yoklanır; konumlandırma söylenmez, hiçbir şey çekilmez, kamera hemen kapanır.
    static let probeSeconds: TimeInterval = 25

    func probe() async -> Bool {
        closeHeld()
        guard !running, CameraUID(settings.uid) != nil else { return false }
        running = true
        cancelled = false
        shooting = false
        active = true
        defer {
            teardown()
            running = false
            active = false
        }
        pipeline.saving = true
        status("Kamera kontrol ediliyor")
        guard let uid = CameraUID(settings.uid) else { return false }
        startClient(uid: uid)
        let live = await waitUntil(seconds: CameraCaptureController.probeSeconds) { self.isLive }
        return live && !cancelled
    }

    /// Kameraya bağlanır (görüntü kareleri akmaya başlar): kare belleği ve ölçümler sıfırlanır, bağlantı kurulur
    private func startClient(uid: CameraUID) {
        decoder.reset()
        pipeline.reset()
        decodeClock.clear()
        batteryMonitor.reset()
        let quality = settings.streamQuality == 2 ? (state: 2, stream: 2) : (state: 1, stream: 1)
        client.start(config: CameraSession.Config(uid: uid,
                                                  password: settings.cameraPassword,
                                                  manualIP: settings.cameraIP.trimmed,
                                                  videoState: quality.state,
                                                  videoStream: quality.stream,
                                                  tzHours: TimeZone.current.secondsFromGMT() / 3600,
                                                  probe: false))
        cameraState = .connecting("Kameraya bağlanılıyor…")
    }

    // MARK: Oturum başında açık tutulan bağlantı

    /// Bağlantı `holdOpen()` ile açık tutuluyor mu
    private(set) var holding = false

    /// Sürüm 4: oturum başlarken kameraya hemen bağlanılır; görüntü gelince döner ve bağlantı AÇIK kalır (ana ekrandaki kutuda görüntü akar,
    /// kamera pili düşükse sesli uyarı verilir). Hiçbir şey çekilmez, konumlandırma yapılmaz. İlk hücresel bağlantıdan önce `closeHeld()` kapatır.
    func holdOpen() async -> Result<Void, CameraFailure> {
        if holding { return .success(()) }
        guard !running else { return .failure(.captureFailed("çekim zaten sürüyor")) }
        guard let uid = CameraUID(settings.uid) else { return .failure(.notConnected) }
        running = true
        cancelled = false
        shooting = false
        active = true
        pipeline.saving = settings.previewOff   // pil tasarrufu açıksa ekrana kare gönderilmez
        status("Kameraya bağlanılıyor")
        lowBattery = CameraLowBatteryWatcher()
        startClient(uid: uid)
        var live = await waitUntil(seconds: CameraCaptureController.connectSeconds) { self.isLive }
        if !live, !cancelled, case .connected = cameraState {
            tlog("[kamera] el sıkışıldı, görüntü bekleniyor: \(Int(CameraCaptureController.connectGraceSeconds)) sn ek süre")
            live = await waitUntil(seconds: CameraCaptureController.connectGraceSeconds) { self.isLive }
        }
        if cancelled || !live {
            let failure: CameraFailure
            if cancelled {
                failure = .cancelled
            } else {
                switch cameraState {
                case .connected, .streaming: failure = .noFrames
                default: failure = .notConnected
                }
            }
            teardown()
            running = false
            active = false
            return .failure(failure)
        }
        holding = true
        status("Kamera bağlı")
        tlog("[kamera] oturum başı: kamera bağlı, görüntü geliyor (bağlantı açık tutuluyor)")
        return .success(())
    }

    /// Açık tutulan bağlantıyı kapatır (kamera görüntüyü kapatır, boşa geçer); açık bağlantı yoksa bir şey yapmaz
    func closeHeld() {
        guard holding else { return }
        holding = false
        teardown()
        running = false
        active = false
        statusText = ""
        tlog("[kamera] oturum başı: açık bağlantı kapatıldı")
    }

    /// Ekrandaki "Şimdi çek" düğmesi (yardım eden biri için yedek): konumlandırma beklenmeden çeker
    func captureNow() {
        resolve(.manual)
    }

    func cancel() {
        cancelled = true
        resolve(.cancelled)
        if holding {
            closeHeld()
            return
        }
        if running {
            // Video yazıcısı ve kamera kapanır; capture() geri dönerken `teardown` yeniden çalışır
            teardown()
        }
    }

    // MARK: Konumlandırma

    /// Konumlandırma: kadrajın ortasındaki soru hedeflenir, bölüm sorulmaz, konum uygun olunca kendiliğinden çekilir
    private func configureGuidance() {
        guidance.reset()
        pipeline.guidanceOrientation = settings.imageOrientation
        guidance.config.topBand = settings.imageOrientation == .normal ? GuidanceAnalyzer.skipTop : 0
        let floors = [0.30, 0.45, 0.60]
        guidance.sharpFloor = floors[min(max(settings.guidanceSharpness, 0), 2)]
        guidance.config.glareLimit = settings.guidanceGlare ? 0.04 : 2
        guidance.describeScene = settings.guidanceDescribe
        pipeline.pageEdgesOn = settings.guidanceDescribe && settings.guidancePageEdges
        pipeline.guidanceOn = true
    }

    private func guidanceSample(_ sample: FramePipeline.GuidanceSample) {
        guard running, !shooting, !cancelled, isLive, waiter != nil else { return }
        let out = guidance.step(sample.metrics, time: sample.time, stillFor: sample.stillFor)
        if out.status != statusText { status(out.status) }
        if let text = out.speak { say(text) }
        if out.capture { resolve(.positioned) }
    }

    private func awaitTrigger(seconds: TimeInterval) async -> Trigger {
        if cancelled { return .cancelled }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Trigger, Never>) in
            waiter = continuation
            timeoutTask?.cancel()
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.resolve(.forced) }
            }
            // Görüntü kesilirse (kamera kapandı, Wi-Fi koptu) 30 sn beklenmez
            liveTask?.cancel()
            liveTask = Task { [weak self] in
                var lost = 0
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    let live = await MainActor.run { self?.isLive ?? true }
                    lost = live ? 0 : lost + 1
                    if lost >= CameraCaptureController.lostSeconds {
                        await MainActor.run { self?.resolve(.lost) }
                        return
                    }
                }
            }
        }
    }

    private func resolve(_ trigger: Trigger) {
        guard let continuation = waiter else { return }
        waiter = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        liveTask?.cancel()
        liveTask = nil
        continuation.resume(returning: trigger)
    }

    // MARK: Fotoğraf ve video

    private func captureOptions() -> CaptureOptions {
        let s = settings
        return CaptureOptions(before: s.burstBefore,
                              after: s.burstAfter,
                              multiFrame: s.multiFrame,
                              enhance: EnhanceOptions(level: s.enhancement, deskew: s.deskew, upscale: s.upscale,
                                                      timestamp: s.timestampMode, quality: s.jpegQuality,
                                                      orientation: s.imageOrientation),
                              documentOnly: s.documentOnly)
    }

    /// Çekilen soru videolarının geçici klasörü (telefonun önbelleği: iOS gerekirse kendisi temizler)
    static var videoFolder: URL {
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("sorular", isDirectory: true)
    }

    static func newVideoURL() -> URL {
        let folder = videoFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("soru-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).mp4")
    }

    /// Uygulama açılırken önceki çalışmadan kalan videolar silinir: bekleyen çekim listesi bellekte durur, uygulama kapanınca dosyalar sahipsiz kalırdı
    static func purgeLeftoverVideos() {
        let files = (try? FileManager.default.contentsOfDirectory(at: videoFolder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "mp4" { try? FileManager.default.removeItem(at: file) }
    }

    /// Fotoğraf ve video AYNI ANDA alınır (kareler aynı akıştan): video `pageVideoSeconds` sn sürer, fotoğraf bu sırada çekilir
    private func shoot(reason: String) async -> Result<CapturedQuestion, CameraFailure> {
        shooting = true
        status("Çekiliyor")
        let wantVideo = settings.videoToGemini
        let videoSeconds = TimeInterval(settings.pageVideoSeconds)
        var videoURL: URL?
        if wantVideo {
            let url = CameraCaptureController.newVideoURL()
            videoRecorder.start(to: url, orientation: settings.imageOrientation, maxSeconds: videoSeconds + 3)
            videoURL = url
        }
        let started = Date()
        let options = captureOptions()
        let engine = pipeline.engine
        let photo: Result<CapturedPhoto, CaptureError> = await withCheckedContinuation { continuation in
            let accepted = engine.capture(reason: reason, options: options) { result in
                continuation.resume(returning: result)
            }
            if !accepted { continuation.resume(returning: .failure(.noFrames)) }
        }
        if wantVideo {
            let rest = videoSeconds - Date().timeIntervalSince(started)
            if rest > 0, !cancelled { try? await Task.sleep(nanoseconds: UInt64(rest * 1_000_000_000)) }
        }
        var output: VideoRecorder.Output?
        if wantVideo {
            output = await withCheckedContinuation { (continuation: CheckedContinuation<VideoRecorder.Output?, Never>) in
                videoRecorder.finish { result in
                    if case .success(let out) = result { continuation.resume(returning: out) } else { continuation.resume(returning: nil) }
                }
            }
        }
        if cancelled {
            if let url = output?.url ?? videoURL { try? FileManager.default.removeItem(at: url) }
            return .failure(.cancelled)
        }
        switch photo {
        case .success(let p):
            if wantVideo && output == nil { tlog("[kamera] video yazılamadı; yalnız fotoğraf gönderilecek") }
            tlog("[kamera] fotoğraf \(p.width)×\(p.height), \(p.jpeg.count / 1024) KB; video \(output.map { "\($0.bytes / 1024) KB, \(Int($0.seconds.rounded())) sn" } ?? "yok")")
            var shot = CapturedQuestion(photo: p.jpeg)
            shot.date = p.date
            shot.video = output?.url
            shot.videoBytes = output?.bytes ?? 0
            shot.videoSeconds = output?.seconds ?? 0
            return .success(shot)
        case .failure(let error):
            if let url = output?.url { try? FileManager.default.removeItem(at: url) }
            if case .notDocument = error { return .failure(.noPosition) }
            if case .noFrames = error { return .failure(.noFrames) }
            return .failure(.captureFailed(error.message))
        }
    }

    // MARK: Yardımcılar

    private func waitUntil(seconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !cancelled && Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return condition()
    }

    /// Kamera kapatılır: bağlantı, ölçüm, yazıcı ve kare belleği; Wi-Fi'ye dokunulmaz (kestirme onu yapar)
    private func teardown() {
        timeoutTask?.cancel()
        timeoutTask = nil
        liveTask?.cancel()
        liveTask = nil
        if let continuation = waiter {
            waiter = nil
            continuation.resume(returning: .cancelled)
        }
        pipeline.guidanceOn = false
        pipeline.pageEdgesOn = false
        client.stop()
        decoder.reset()
        pipeline.reset()
        decodeClock.clear()
        cameraState = .stopped
        shooting = false
        pipeline.renderer.clear()   // kamera kapandı: son kare donmuş kalmaz
    }
}

#if DEBUG
extension CameraCaptureController {
    /// Yalnız ekran görüntüsü testi için: kamera çekimi sürüyormuş gibi ana ekrandaki kamera kartını gösterir (gerçek bağlantı kurulmaz)
    func showForScreenshots(state: CameraState, status: String, battery: CameraBatteryLevel?) {
        active = true
        cameraState = state
        statusText = status
        cameraBattery = battery
    }
}
#endif
