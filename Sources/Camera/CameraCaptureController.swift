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

/// Kamera iş parçacığından gelen bilgi sorgusu metni (kilitli)
final class ProbeTextBox {
    private let lock = NSLock()
    private var text = ""

    func set(_ value: String) {
        lock.lock()
        text = value
        lock.unlock()
    }

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return text
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
    /// Sabit süreli çekimin başlangıç cümlesi: süre söylenir, cümle bitince çekim başlar
    static func countdownIntro(seconds: Int) -> String { return "\(seconds) saniye boyunca çekim yapabilirsiniz. Başlıyorum." }
    /// Geri sayımın sayısı: kalan saniye
    static func countdownNumber(_ remaining: Int) -> String { return "\(remaining)" }
}

/// Kamera çekimi (CameraClient, H264Decoder, FramePipeline, GuidanceEngine, CaptureEngine, VideoRecorder). Çekim tek bir sorudur ve
/// bittiğinde kamera KAPATILIR.
///
/// Akış: kameraya bağlan → görüntü gelince sesle konumlandır (odak kipi: kadrajın ortasındaki soru; kenarlardan yarım görünen diğer
/// sorular sorun sayılmaz) → konum uygun olunca (ya da `positionSeconds` sonunda yine de) aynı anda fotoğraf çek ve `pageVideoSeconds` sn
/// video kaydet → kamerayı kapat. Hücresel/Wi-Fi geçişleri bu sınıfın değil, çağıranın (Kestirmeler) işidir.
@MainActor
final class CameraCaptureController: ObservableObject, CameraCapturing {
    var onSayWait: ((String) async -> Void)?
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
    /// El sıkışma yapıldıktan sonra görüntü bu kadar sn içinde gelmezse beklenmez (sn). Günlükte görüntü el sıkışmadan en geç 10 sn sonra geldi;
    /// bağlantı kurulduğu halde görüntü gelmeyen kötü bağlantıda 40 sn beklemek yerine hemen yeniden denenir
    static let videoWaitSeconds: TimeInterval = 20
    /// Konumlandırma sürerken görüntü bu kadar saniye kesilirse beklenmeden vazgeçilir
    static let lostSeconds = 8
    /// Toplu çekim sürerken görüntü bu kadar saniye kesilirse oturum bırakılır. Kamera istemcisi sessizliği 6 sn'de fark edip kendiliğinden yeniden bağlanır
    /// (el sıkışma + ilk anahtar kare ≈ 4–6 sn): 8 sn bunun hemen öncesinde keserdi (günlükte 75 sn'lik oturum 37. saniyede, 28 fotoğrafla bırakıldı).
    /// Kesinti anında fotoğraf alınmaz; görüntü dönünce çekim kalan süre boyunca sürer.
    static let seriesLostSeconds = 20

    let settings: CameraSettings
    private let client = CameraClient()
    private let decoder = H264Decoder()
    private let pipeline = FramePipeline()
    private let videoRecorder = VideoRecorder()
    private let guidance = GuidanceEngine()
    private let decodeClock = DecodeClock()
    private let batteryMonitor = CameraBatteryMonitor()
    private var lowBattery = CameraLowBatteryWatcher()
    /// Akışın gerçek boyutu / kare hızı / bitrate ölçümü (günlüğe "akış ölçümü" diye yazılır)
    private let meter = StreamMeter()
    /// Son oturumun akış ölçümü özeti (kamera kapanınca yazılır; yeterli kare gelmediyse boş): "Kamerayı dene" ve "Deneme çekimi" satırlarında gösterilir
    private(set) var lastStreamSummary: String?

    private enum Trigger { case positioned, forced, manual, lost, cancelled }
    private var waiter: CheckedContinuation<Trigger, Never>?

    // Kadraj koçu (Ayarlar > "Toplu çekimde sesli konumlandırma"): toplu çekim sürerken kısa cümlelerle konuşur; çekimi başlatmaz / bitirmez
    private var coach = FramingCoachTimer()
    private var coachOn = false
    private var coachConfig = GuidanceConfig()
    private var coachSharpFloor = 0.45
    private var coachLines: (lines: ViewLines, time: TimeInterval)?
    private var coachOCRBusy = false
    private var coachOCRTime: TimeInterval = -100
    /// Satır tarifi için yazı tanıma en sık bu aralıkla (sn) yapılır; sonucun geçerlilik süresi de
    static let coachOCRGap: TimeInterval = 2.5
    static let coachLinesMaxAge: TimeInterval = 4
    private var timeoutTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var running = false
    private var cancelled = false
    private var shooting = false
    private var cancellables = Set<AnyCancellable>()
    /// Kameraya el sıkışılan an (systemUptime); bağlantı kopunca ya da kamera kapanınca boşalır
    private var handshakeAt: TimeInterval?

    var renderer: VideoRenderer { return pipeline.renderer }

    init(settings: CameraSettings) {
        self.settings = settings
        let pipeline = self.pipeline
        let clock = self.decodeClock
        let recorder = self.videoRecorder
        let decoder = self.decoder
        let meter = self.meter
        decoder.onDecoded = { pixelBuffer, time in
            clock.mark()
            meter.addDecoded(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
            pipeline.handle(pixelBuffer, time: time)
        }
        // Video kaydı kareleri netlik puanıyla alır: her yarım saniyeden en net kare yazılır
        pipeline.onAnalyzed = { pixelBuffer, time, sharpness in
            recorder.offer(pixelBuffer, time: time, sharpness: sharpness)
        }
        let monitor = self.batteryMonitor
        client.onFrame = { [weak self] frame in
            meter.addFrame(bytes: frame.payload.count, keyFrame: frame.isKeyFrame, at: ProcessInfo.processInfo.systemUptime)
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
        let now = ProcessInfo.processInfo.systemUptime
        switch state {
        case .connected:
            handshakeAt = now
        case .reconnecting, .stopped:
            handshakeAt = nil
        case .streaming:
            if let at = handshakeAt { tlog("[kamera] ilk görüntü: el sıkışmadan \(String(format: "%.1f", now - at)) sn sonra") }
        default:
            break
        }
        switch state {
        case .connecting, .reconnecting:
            meter.reset()
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
        let live = await awaitLive(limit: connectLimit)
        if cancelled { return .failure(.cancelled) }
        guard live else { return .failure(connectFailure()) }

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

        // 3) Sabit süreli çekim: her saniyenin en net karesi (fotoğraf) + aynı sürenin videosu
        pipeline.guidanceOn = false
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

    /// İstenecek video akışı: 1 = ana akış (1920×1080), 2 = alt akış (640×360). `override` (Ayarlar > "Çekim akışı", 0 = otomatik) 1, 2 ya da 3 ise
    /// HER ZAMAN o akış istenir (deneme için; kullanıcı kararı 2026-11-17). Otomatikte toplu çekim açıkken ayardan bağımsız hep ana akış: 640×360'ta soru
    /// yazısı okunmaz (kullanıcı kararı 2026-11-17: kameranın verebildiği en çok kare 1080p alınır, en iyileri seçilir).
    /// `state` LookCam'deki "seviye": akış 1 → 1, akış 2 ve 3 → 2 (LookCam kalite penceresi: HD = akış 1 / seviye 1, SD = akış 2 / seviye 2, VGA = akış 3 / seviye 2).
    static func streamChoice(quality: Int, series: Bool, override: Int = 0) -> (state: Int, stream: Int) {
        switch override {
        case 1: return (state: 1, stream: 1)
        case 2: return (state: 2, stream: 2)
        case 3: return (state: 2, stream: 3)
        default: break
        }
        if quality == 2 && !series { return (state: 2, stream: 2) }
        return (state: 1, stream: 1)
    }

    // MARK: Akış denemesi

    /// Denenecek akışlar sırayla: (seviye, akış). LookCam'in kalite penceresindeki HD / SD / VGA ile aynı eşleme.
    static let surveyChoices: [(state: Int, stream: Int)] = [(1, 1), (2, 2), (2, 3)]
    /// Her akışta, görüntü gelince bu kadar sn ölçülür
    static let surveySeconds: TimeInterval = 8
    /// İki akış arasında kameraya soluk aldırılır (hemen yeniden bağlanınca eski oturum açık kalabiliyor: günlükte "connectNum: 2")
    static let surveyPause: TimeInterval = 1.5

    /// Akış denemesi (kullanıcı kararı 2026-11-17): 1, 2 ve 3 numaralı akışlar sırayla açılır; her birinin gerçek boyutu, kare hızı ve bitrate'i ölçülür.
    /// İlk bağlantıda kameranın YALNIZ OKUMA bilgi komutları da sorgulanır (pozlama bilgisi `GetDevExInfo` dahil); cevaplar günlüğe "sorgu:" satırlarıyla
    /// yazılır. Kameranın hiçbir ayarı DEĞİŞTİRİLMEZ. Sonuç satırları ekranda gösterilir; çekim yapılmaz, hiçbir şey kaydedilmez.
    func surveyStreams() async -> [String] {
        closeHeld()
        guard !running, CameraUID(settings.uid) != nil else {
            return ["Akış denemesi yapılamadı: çekim sürüyor ya da kamera adı (UID) yazılı değil."]
        }
        running = true
        cancelled = false
        shooting = false
        active = true
        let probeText = ProbeTextBox()
        client.onProbe = { text in probeText.set(text) }
        defer {
            client.onProbe = nil
            teardown()
            running = false
            active = false
        }
        pipeline.saving = true
        guard let uid = CameraUID(settings.uid) else { return [] }
        var lines: [String] = []
        for (index, choice) in CameraCaptureController.surveyChoices.enumerated() {
            if cancelled { break }
            if index > 0 { try? await Task.sleep(nanoseconds: UInt64(CameraCaptureController.surveyPause * 1_000_000_000)) }
            status("Akış \(choice.stream) deneniyor")
            startClient(uid: uid, choice: choice, probe: index == 0)
            // İlk akışta bilgi sorgusu da yapılır (≈10 sn), görüntü onun ardından gelir: bağlanma süresi kadar beklenir
            let limit = index == 0 ? CameraCaptureController.connectSeconds : CameraCaptureController.probeSeconds
            let live = await waitUntil(seconds: limit) { self.isLive }
            if live && !cancelled {
                meter.begin(stream: choice.stream)   // ölçüm görüntü gelince başlar (bağlanma süresi kare hızını düşürmesin)
                _ = await waitUntil(seconds: CameraCaptureController.surveySeconds) { false }
            }
            let reached = live && !cancelled
            teardown()   // ölçümü günlüğe yazar ve `lastStreamSummary`'ye koyar; kamera bu akış için kapanır
            if cancelled { break }
            if !reached {
                lines.append("akış \(choice.stream): \(Int(limit)) sn içinde görüntü gelmedi (kamera bu akışı vermiyor olabilir).")
            } else if let summary = lastStreamSummary {
                lines.append(summary)
            } else {
                lines.append("akış \(choice.stream): görüntü geldi ama ölçülemeyecek kadar az kare geldi.")
            }
        }
        if !cancelled { lines.append(contentsOf: CameraCaptureController.probeHighlights(probeText.value)) }
        for line in lines { tlog("[kamera] akış denemesi: " + line) }
        return lines
    }

    /// Bilgi sorgusunun cevap satırlarından ekranda gösterilecekler: pozlama, video ve akış bilgisi (hepsi günlükte de var).
    /// Sorgu hiç çalışmadıysa (ilk akışın görüntüsü gelmedi) bunu söyler.
    static func probeHighlights(_ text: String) -> [String] {
        let wanted = ["GetDevExInfo", "GetDevVideoInfo", "GetDevStream"]
        let all = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !all.isEmpty else { return ["Kamera bilgi sorgusu yapılamadı (ilk akışın görüntüsü gelmedi)."] }
        return wanted.compactMap { name in
            guard let line = all.first(where: { $0.hasPrefix(name + ":") }) else { return nil }
            return "Kamera cevabı · " + (line.count > 320 ? String(line.prefix(320)) + "…" : line)
        }
    }

    /// Kameraya bağlanır (görüntü kareleri akmaya başlar): kare belleği ve ölçümler sıfırlanır, bağlantı kurulur
    /// `choice`: istenecek akış (boşsa ayarlardan); `probe`: görüntü açılınca kameranın bilgi komutlarını da sorgular (yalnız okuma)
    private func startClient(uid: CameraUID, choice: (state: Int, stream: Int)? = nil, probe: Bool = false) {
        decoder.reset()
        pipeline.reset()
        decodeClock.clear()
        batteryMonitor.reset()
        handshakeAt = nil
        lastStreamSummary = nil
        let quality = choice ?? CameraCaptureController.streamChoice(quality: settings.streamQuality, series: settings.pageSeries,
                                                                      override: settings.streamOverride)
        meter.begin(stream: quality.stream)
        tlog("[kamera] istenen akış: \(quality.stream) (seviye \(quality.state))" + (choice == nil && settings.streamOverride != 0 ? ", Ayarlar'dan seçildi" : ""))
        client.start(config: CameraSession.Config(uid: uid,
                                                  password: settings.cameraPassword,
                                                  manualIP: settings.cameraIP.trimmed,
                                                  videoState: quality.state,
                                                  videoStream: quality.stream,
                                                  tzHours: TimeZone.current.secondsFromGMT() / 3600,
                                                  probe: probe))
        cameraState = .connecting("Kameraya bağlanılıyor…")
    }

    // MARK: Oturum başında açık tutulan bağlantı

    /// Bağlantı `holdOpen()` ile açık tutuluyor mu
    private(set) var holding = false

    /// Bağlantı açık tutuluyor ve görüntü geliyor (son 3 sn içinde kare var): kopmuş bağlantıda süre başlatılmaz, kamera yeniden hazırlanır
    var holdingLive: Bool { return holding && isLive }

    /// Telefonun Wi-Fi'sinde (en0) IPv4 adresi var mı
    var phoneHasWiFiAddress: Bool { return LocalNetwork.wifi() != nil }

    /// Sürüm 4: oturum başlarken kameraya hemen bağlanılır; görüntü gelince döner ve bağlantı AÇIK kalır (ana ekrandaki kutuda görüntü akar,
    /// kamera pili düşükse sesli uyarı verilir). Hiçbir şey çekilmez, konumlandırma yapılmaz. İlk hücresel bağlantıdan önce `closeHeld()` kapatır.
    func holdOpen(connectLimit: TimeInterval?) async -> Result<Void, CameraFailure> {
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
        let live = await awaitLive(limit: connectLimit)
        if cancelled || !live {
            let failure: CameraFailure = cancelled ? .cancelled : connectFailure()
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
        if coachOn {
            coachSample(sample)
            return
        }
        guard running, !shooting, !cancelled, isLive, waiter != nil else { return }
        let out = guidance.step(sample.metrics, time: sample.time, stillFor: sample.stillFor)
        if out.status != statusText { status(out.status) }
        if let text = out.speak { say(text) }
        if out.capture { resolve(.positioned) }
    }

    // MARK: Kadraj koçu (toplu çekimde sesli konumlandırma desteği)

    /// Koçun ölçü eşikleri ayarlardan: tek soru çekimindeki yönlendirmeyle aynı netlik ve parlama istekleri
    private func coachGuidanceConfig() -> (config: GuidanceConfig, sharpFloor: Double) {
        var c = GuidanceConfig()
        c.topBand = settings.imageOrientation == .normal ? GuidanceAnalyzer.skipTop : 0
        c.glareLimit = settings.guidanceGlare ? 0.04 : 2
        let floors = [0.30, 0.45, 0.60]
        return (c, floors[min(max(settings.guidanceSharpness, 0), 2)])
    }

    /// Toplu çekim başlarken: koç açılır. Sürekli kâğıt algılaması (Vision) ağırdır, açılmaz; koç yazı ölçüsünü ve satırları kullanır.
    private func startCoach() {
        let g = coachGuidanceConfig()
        coachConfig = g.config
        coachSharpFloor = g.sharpFloor
        coach.reset()
        coachLines = nil
        coachOCRBusy = false
        coachOCRTime = -100
        pipeline.guidanceOrientation = settings.imageOrientation
        pipeline.pageEdgesOn = false
        coachOn = true
        pipeline.guidanceOn = true
        tlog("[kamera] kadraj koçu açık (toplu çekimde sesli konumlandırma)")
    }

    /// Koç durur: ölçüm kapanır, bekleyen yazı tanıma sonucu atılır (süre dolunca ve temizlikte)
    private func stopCoach() {
        guard coachOn else { return }
        coachOn = false
        coachLines = nil
        pipeline.guidanceOn = false
    }

    private func coachSample(_ sample: FramePipeline.GuidanceSample) {
        guard coachOn, !cancelled, isLive else { return }
        if sample.stillFor >= coach.config.stillNeeded, !coachOCRBusy, sample.time - coachOCRTime >= CameraCaptureController.coachOCRGap {
            requestCoachLines(at: sample.time)
        }
        var lines: ViewLines?
        if let cached = coachLines, sample.time - cached.time <= CameraCaptureController.coachLinesMaxAge { lines = cached.lines }
        if let text = coach.step(metrics: sample.metrics, lines: lines, time: sample.time, stillFor: sample.stillFor,
                                 guidance: coachConfig, sharpFloor: coachSharpFloor) {
            sayCoach(text)
        }
    }

    /// En taze karenin satırları arka planda okunur (kamera durgunken, seyrek); sonuç koçun sonraki değerlendirmelerinde kullanılır
    private func requestCoachLines(at time: TimeInterval) {
        let now = ProcessInfo.processInfo.systemUptime
        let fresh = pipeline.store.frames(from: now - 1.0, to: now + 1)
        guard let best = fresh.max(by: { $0.sharpness < $1.sharpness }) else { return }
        coachOCRBusy = true
        coachOCRTime = time
        let buffer = best.buffer
        let orientation = settings.imageOrientation
        Task { [weak self] in
            let lines = await Task.detached(priority: .utility) { ViewLinesReader.read(buffer, orientation: orientation) }.value
            guard let self = self else { return }
            self.coachOCRBusy = false
            if let lines = lines, self.coachOn { self.coachLines = (lines: lines, time: time) }
        }
    }

    /// Koç cümlesi: "Uyarıları sesli söyle" ayarından bağımsızdır (kullanıcı toplu çekimde sesli konumlandırmayı kendisi açtı)
    private func sayCoach(_ text: String) {
        onSay?(text)
        tlog("[kamera] koç: \(text)")
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

    /// Deneme çekiminin geçici video adresi (klasöre taşınınca burada kalmaz)
    static func newTrialVideoURL() -> URL {
        let folder = videoFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("deneme-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).mp4")
    }

    /// Uygulama açılırken önceki çalışmadan kalan videolar silinir: bekleyen çekim listesi bellekte durur, uygulama kapanınca dosyalar sahipsiz kalırdı
    static func purgeLeftoverVideos() {
        let files = (try? FileManager.default.contentsOfDirectory(at: videoFolder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "mp4" { try? FileManager.default.removeItem(at: file) }
    }

    /// Sabit süreli çekim: `pageVideoSeconds` sn boyunca video yazılır ve her saniyenin EN NET karesi bir fotoğraf olur (kareler aynı akıştan,
    /// ikisi birlikte). 10 sn = 10 fotoğraf: tek PDF'e dizilir, video ayrıca gider. Önce "N saniye boyunca çekim yapabilirsiniz. Başlıyorum."
    /// söylenir (bitince süre başlar); çekim sırasında sessizdir. "Sesli geri sayım" açıksa ayrıca N, N-1 … 1 sayılır. Kullanıcı kâğıdı kadraja sığdırmak zorunda değildir: kamerayı gezdirir.
    private func shoot(reason: String) async -> Result<CapturedQuestion, CameraFailure> {
        shooting = true
        status("Çekiliyor")
        let wantVideo = settings.videoToGemini
        let seconds = max(1, settings.pageVideoSeconds)
        let countdown = settings.countdown && settings.guidanceVoice   // sayılan saniyeler yalnız ayar açıkken (varsayılan KAPALI: çekim sırasında sessiz)
        if settings.guidanceVoice {
            // Başlangıç cümlesi her zaman söylenir (kullanıcı süreyi bilsin) ve çekim başlamadan BİTER; çekim sırasında konuşma yoktur
            let intro = CameraSay.countdownIntro(seconds: seconds)
            if let speak = onSayWait {
                await speak(intro)   // cümle bitince süre başlar
            } else {
                say(intro)
            }
        }
        if cancelled { return .failure(.cancelled) }
        var videoURL: URL?
        if wantVideo {
            let url = CameraCaptureController.newVideoURL()
            videoRecorder.start(to: url, orientation: settings.imageOrientation, maxSeconds: Double(seconds) + 1)
            videoURL = url
        }
        let options = captureOptions()
        let engine = pipeline.engine
        let t0 = ProcessInfo.processInfo.systemUptime
        var pending: [Task<Result<CapturedPhoto, CaptureError>, Never>] = []
        for second in 1...seconds {
            if cancelled { break }
            status("Çekiliyor: \(second)/\(seconds)")
            if countdown { say(CameraSay.countdownNumber(seconds - second + 1)) }
            // saniyenin sonu: o saniyedeki en net kare fotoğraf olur (işleme arka planda sürer, sayım gecikmez)
            let target = t0 + Double(second)
            while !cancelled {
                let rest = target - ProcessInfo.processInfo.systemUptime
                if rest <= 0 { break }
                try? await Task.sleep(nanoseconds: UInt64(min(rest, 0.25) * 1_000_000_000))
            }
            if cancelled { break }
            let from = target - 1.0
            pending.append(Task<Result<CapturedPhoto, CaptureError>, Never> {
                await withCheckedContinuation { (continuation: CheckedContinuation<Result<CapturedPhoto, CaptureError>, Never>) in
                    engine.photo(from: from, to: target, reason: reason, options: options) { continuation.resume(returning: $0) }
                }
            })
        }
        var output: VideoRecorder.Output?
        if wantVideo {
            output = await withCheckedContinuation { (continuation: CheckedContinuation<VideoRecorder.Output?, Never>) in
                videoRecorder.finish { result in
                    if case .success(let out) = result { continuation.resume(returning: out) } else { continuation.resume(returning: nil) }
                }
            }
        }
        var photos: [CapturedPhoto] = []
        var failures: [CaptureError] = []
        for task in pending {
            switch await task.value {
            case .success(let photo): photos.append(photo)
            case .failure(let error): failures.append(error)
            }
        }
        if cancelled {
            if let url = output?.url ?? videoURL { try? FileManager.default.removeItem(at: url) }
            return .failure(.cancelled)
        }
        guard let best = photos.max(by: { $0.sharpness < $1.sharpness }) else {
            if let url = output?.url ?? videoURL { try? FileManager.default.removeItem(at: url) }
            if failures.contains(where: { if case .noFrames = $0 { return true } else { return false } }) { return .failure(.noFrames) }
            return .failure(.captureFailed(failures.first?.message ?? ""))
        }
        if photos.count < seconds { tlog("[kamera] \(seconds) saniyenin \(photos.count) tanesinde fotoğraf alınabildi (görüntü kesintili)") }
        let jpegs = photos.map { $0.jpeg }
        let pdf = await Task.detached(priority: .userInitiated) { PageDocument.make(jpegs: jpegs) }.value
        if wantVideo && output == nil { tlog("[kamera] video yazılamadı; yalnız fotoğraflar gönderilecek") }
        tlog("[kamera] \(photos.count) fotoğraf (\(best.width)×\(best.height), toplam \(jpegs.reduce(0) { $0 + $1.count } / 1024) KB) → PDF \(pdf.map { "\($0.count / 1024) KB" } ?? "kurulamadı"); video \(output.map { "\($0.bytes / 1024) KB, \(Int($0.seconds.rounded())) sn" } ?? "yok")")
        var shot = CapturedQuestion(photo: best.jpeg)
        shot.pdf = pdf
        shot.pageCount = pdf == nil ? 0 : photos.count
        shot.date = best.date
        shot.video = output?.url
        shot.videoBytes = output?.bytes ?? 0
        shot.videoSeconds = output?.seconds ?? 0
        return .success(shot)
    }

    // MARK: Toplu sayfa çekimi

    /// Toplu çekim: bağlanır, hiç konuşmadan `seconds` sn ARALIKSIZ çeker. Saniyede bir fotoğraf (o saniyenin en net karesi) alınır. Sayfa sayısı yoktur:
    /// kullanıcı sayfaları kendi hızında gösterir (biri 3 sn, biri 8 sn); bütün oturumun fotoğrafları TEK PDF olur, video yoktur.
    /// Kameradan görüntü `seriesLostSeconds` sn kesilirse oturum bırakılır, o ana kadar alınan fotoğraflar döner (`failure` dolu).
    func captureSeries(seconds: Int, connectLimit: TimeInterval?) async -> Result<PageSeries, CameraFailure> {
        return await runSeries(seconds: seconds, connectLimit: connectLimit, trial: false)
    }

    /// Deneme çekimi: toplu çekimin aynısı, ek olarak video kaydedilir (el hareketi ve mesafe izlensin); sonuç Gemini'ye gönderilmez (çağıran klasöre yazar)
    func captureTrial(seconds: Int, connectLimit: TimeInterval?) async -> Result<PageSeries, CameraFailure> {
        return await runSeries(seconds: seconds, connectLimit: connectLimit, trial: true)
    }

    /// Kadraj kontrolü (Başla'dan önce): hazır bekleyen canlı kamerada 1,5 sn taze kare toplanır, en netinin yazısı okunur. Çekim yapılmaz.
    func checkView() async -> ViewCheck? {
        guard holdingLive, !shooting else { return nil }
        let from = ProcessInfo.processInfo.systemUptime
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard holdingLive, !shooting else { return nil }
        let fresh = pipeline.store.frames(from: from, to: ProcessInfo.processInfo.systemUptime + 1)
        guard let best = fresh.max(by: { $0.sharpness < $1.sharpness }) else { return ViewCheck(frames: 0, sharpness: 0, text: nil) }
        let orientation = settings.imageOrientation
        let buffer = best.buffer
        let text = await Task.detached(priority: .userInitiated) { SeriesTextReader.read(buffer, orientation: orientation) }.value
        tlog("[kamera] kadraj kontrolü: \(fresh.count) taze kare, en net kare netlik \(Int(best.sharpness.rounded())), \(text.map { $0.summary } ?? "yazı tanıma yok")")
        var check = ViewCheck(frames: fresh.count, sharpness: best.sharpness, text: text)
        // Toplu çekimde sesli konumlandırma açıksa kadrajın tarifi de verilir: kaç sayfa, kesik kenar, kayma yönü, üstte ve altta hangi satır
        if settings.seriesGuidance, text?.isReadable == true {
            let g = coachGuidanceConfig()
            let edgesOn = settings.guidancePageEdges
            let framing = await Task.detached(priority: .userInitiated) { () -> (text: String, correction: Bool)? in
                guard var metrics = GuidanceAnalyzer.analyze(buffer, orientation: orientation) else { return nil }
                if edgesOn && metrics.hasText { metrics.edges = PageEdgeDetector.detect(buffer, orientation: orientation) }
                let lines = ViewLinesReader.read(buffer, orientation: orientation)
                let note = FramingCoach.note(metrics, lines: lines, config: g.config, sharpFloor: g.sharpFloor)
                let spoken = FramingCoach.describe(metrics, lines: lines, config: g.config, sharpFloor: g.sharpFloor)
                return (text: spoken, correction: note.isCorrection)
            }.value
            if let framing = framing {
                check.framing = framing.text
                check.framingIsCorrection = framing.correction
                tlog("[kamera] kadraj tarifi: \(framing.text)")
            }
        }
        return check
    }

    private func runSeries(seconds: Int, connectLimit: TimeInterval?, trial: Bool) async -> Result<PageSeries, CameraFailure> {
        // "Başla" denince kamera zaten bağlı ve görüntü akıyorsa (hazır bekleme, bkz. `holdOpen`) o bağlantı kullanılır: yeniden bağlanma yoktur,
        // süre hemen başlar. Bağlantı kopmuşsa kapatılır ve baştan bağlanılır.
        let adopted = holdingLive
        if adopted {
            holding = false   // bağlantı artık bu çekimindir; aşağıdaki `defer` kapatır
            cancelled = false
            shooting = false
            tlog("[kamera] toplu çekim: hazır bekleyen bağlantı kullanılıyor, süre hemen başlıyor")
        } else {
            closeHeld()
            guard !running else { return .failure(.captureFailed("çekim zaten sürüyor")) }
            running = true
            cancelled = false
            shooting = false
            active = true
        }
        defer {
            teardown()
            running = false
            active = false
        }
        guard DiskGuard.level(freeMB: DiskGuard.freeMB()) != .critical else { return .failure(.lowDisk) }
        guard let uid = CameraUID(settings.uid) else { return .failure(.notConnected) }
        pipeline.saving = settings.previewOff
        if !adopted {
            status("Kameraya bağlanılıyor")
            lowBattery = CameraLowBatteryWatcher()
            startClient(uid: uid)
            let live = await awaitLive(limit: connectLimit)
            if cancelled { return .failure(.cancelled) }
            guard live else { return .failure(connectFailure()) }
        }
        if settings.seriesGuidance {
            startCoach()
        } else {
            pipeline.guidanceOn = false
        }
        return await shootSeries(seconds: max(1, seconds), trial: trial)
    }

    /// Kameranın verdiği HER kare ölçülür; 0,5 sn'lik pencerelerin en net karesi yazı tanımadan geçer, okunabilenler PDF'e girer (bkz. `SeriesSelection`).
    /// Yazı tanıma yalnız sıralama yardımcısıdır, hiçbir kareyi veto etmez: okunan kare azsa en net kareler eklenir, çekim "okunamadı" diye çöpe gitmez
    /// (kare geldiyse PDF kurulur, telefondaki klasöre yazılır ve Gemini'ye gider; hiç soru yoksa Gemini "soru yok" der).
    private func shootSeries(seconds: Int, trial: Bool = false) async -> Result<PageSeries, CameraFailure> {
        shooting = true
        let total = seconds
        let options = captureOptions()
        let enhance = options.enhance
        let orientation = enhance.orientation
        let t0 = ProcessInfo.processInfo.systemUptime
        let collector = SeriesCollector(
            start: t0,
            reader: { SeriesTextReader.read($0, orientation: orientation) },
            renderer: { buffer in
                guard let rendered = Enhancer.render(buffers: [buffer], options: enhance) else { return nil }
                return (data: rendered.data, width: rendered.width, height: rendered.height)
            },
            log: { tlog($0) })
        let rawBefore = pipeline.framesSeen
        pipeline.seriesSink = collector
        pipeline.fullRate = true   // pil tasarrufu açık olsa bile her kare ölçülür: seçim ne kadar çok kareden yapılırsa o kadar iyi olur
        defer {
            pipeline.seriesSink = nil
            pipeline.fullRate = false
        }
        var videoURL: URL?
        if trial {
            // Deneme çekimi: aynı kareler ayrıca videoya yazılır (saniyede 8 kare; kullanıcı el hareketini ve mesafeyi izler)
            let url = CameraCaptureController.newTrialVideoURL()
            videoRecorder.start(to: url, orientation: settings.imageOrientation, maxSeconds: Double(total) + 1,
                                fps: VideoRecorder.trialFps, maxBitrate: VideoRecorder.trialMaxBitrate)
            videoURL = url
        }
        var lostFor = 0
        var cutAt: Int?
        tlog("[kamera] \(trial ? "deneme çekimi" : "toplu çekim") başladı: \(seconds) sn (konuşma ve titreşim yok; her kare ölçülür, \(SeriesSelection.window) sn'lik pencerelerin en iyisi yazı tanımadan geçer)")
        for second in 1...total {
            if cancelled { break }
            status("Çekim: \(second)/\(total) sn")
            let target = t0 + Double(second)
            while !cancelled {
                let rest = target - ProcessInfo.processInfo.systemUptime
                if rest <= 0 { break }
                try? await Task.sleep(nanoseconds: UInt64(min(rest, 0.25) * 1_000_000_000))
            }
            if cancelled { break }
            lostFor = isLive ? 0 : lostFor + 1
            if lostFor >= CameraCaptureController.seriesLostSeconds {
                cutAt = second
                tlog("[kamera] toplu çekim: görüntü \(lostFor) sn kesildi (\(second). saniye); oturum bırakılıyor")
                break
            }
        }
        pipeline.seriesSink = nil
        // Süre doldu: koç susar (PDF hazırlanırken ve cevaplar okunurken konuşmaz, ölçüm de durur)
        stopCoach()
        if cancelled {
            if trial { videoRecorder.cancel() }
            return .failure(.cancelled)
        }
        var videoOutput: VideoRecorder.Output?
        if trial {
            videoOutput = await withCheckedContinuation { (continuation: CheckedContinuation<VideoRecorder.Output?, Never>) in
                videoRecorder.finish { result in
                    if case .success(let out) = result { continuation.resume(returning: out) } else { continuation.resume(returning: nil) }
                }
            }
        }
        let outcome = await collector.finish()
        if cancelled {
            if let url = videoOutput?.url ?? videoURL { try? FileManager.default.removeItem(at: url) }
            return .failure(.cancelled)
        }
        let stats = outcome.stats
        let elapsed = max(1.0, ProcessInfo.processInfo.systemUptime - t0)
        let rawFrames = max(0, pipeline.framesSeen - rawBefore)
        tlog("[kamera] toplu çekim özeti: kameradan \(rawFrames) kare geldi (≈\(Int((Double(rawFrames) / elapsed).rounded()))/sn), \(stats.offered) kare ölçüldü (≈\(Int((Double(stats.offered) / elapsed).rounded()))/sn), \(stats.windows) pencere: \(stats.weak) tanesinin yazısı okunamadı (zayıf aday), \(stats.busySkipped) atlandı, \(stats.merged) tekrar birleşti, \(stats.kept) aday → \(outcome.items.count) fotoğraf (\(outcome.readable) tanesi okunan); yazı tanıma \(stats.read) kez çalıştı, \(stats.readFailed) kez çalışmadı; bozuk (bloklaşmış) kare \(stats.damagedFrames), tamamen bozuk pencere \(stats.damagedWindows), durgun anda alınan pencere \(stats.stillWindows); görülen soru numaraları: \(outcome.questionNumbers.map { String($0) }.joined(separator: ","))")
        // Kare geldiği halde hiç aday çıkmadıysa (hepsinin fotoğrafı oluşturulamadı) ya da görüntü baştan kesildiyse çekim yoktur
        guard let best = outcome.items.max(by: { $0.rank < $1.rank }) else {
            if let url = videoOutput?.url ?? videoURL { try? FileManager.default.removeItem(at: url) }
            return .failure(.noFrames)
        }
        if outcome.readable == 0 { tlog("[kamera] toplu çekim: hiçbir karede yazı okunamadı; en net \(outcome.items.count) kare yine de gönderilecek (yazı tanıma zayıf kalmış olabilir)") }
        // Seçilen fotoğraflar zaman sırasıyla TEK PDF olur; toplam bütçeyi aşarsa fotoğraflar yeniden sıkıştırılır
        let raw = outcome.items.map { $0.jpeg }
        let (pdf, fitted) = await Task.detached(priority: .userInitiated) { () -> (Data?, Int) in
            let fit = PageDocument.fit(raw)
            return (PageDocument.make(jpegs: fit, title: "Toplu çekim"), fit.reduce(0) { $0 + $1.count })
        }.value
        tlog("[kamera] toplu çekim: \(outcome.items.count) fotoğraf (\(best.width)×\(best.height), ham \(raw.reduce(0) { $0 + $1.count } / 1024) KB → \(fitted / 1024) KB) → PDF \(pdf.map { "\($0.count / 1024) KB" } ?? "kurulamadı")")
        var shot = CapturedQuestion(photo: best.jpeg)
        shot.pdf = pdf
        shot.pageCount = pdf == nil ? 0 : outcome.items.count
        shot.date = Date()
        shot.isPage = true
        shot.seenNumbers = outcome.questionNumbers
        shot.video = videoOutput?.url
        shot.videoBytes = videoOutput?.bytes ?? 0
        shot.videoSeconds = videoOutput?.seconds ?? 0
        if trial { tlog("[kamera] deneme çekimi: video \(videoOutput.map { "\($0.bytes / 1024) KB, \(Int($0.seconds.rounded())) sn" } ?? "yazılamadı")") }
        let report = trial ? outcome.diagnosis.report(seconds: Int(elapsed.rounded()), measured: stats.offered, selected: outcome.items.count, readable: outcome.readable) : ""
        // Görüntü akışı kesildiyse oturum yarımdır (planlanan süre dolmadı); değilse "planlanan" = seçilen fotoğraf sayısı: seçim süreyle değil kaliteyle yapılır
        let failure: CameraFailure? = cutAt != nil ? .noFrames : nil
        return .success(PageSeries(shot: shot, planned: cutAt != nil ? total : outcome.items.count, failure: failure, readable: outcome.readable > 0,
                                  diagnosis: outcome.diagnosis, report: report))
    }

    // MARK: Yardımcılar

    /// Beklemenin bırakılıp bırakılmayacağı (saf karar; testlenir). `elapsed`: bağlanma denemesinin başından beri geçen süre, `limit`: toplam süre sınırı,
    /// `handshakeAge`: el sıkışmadan beri geçen süre (el sıkışma yoksa nil), `grace`: sınır dolduğunda el sıkışılmışsa ek süre tanınsın mı.
    /// Görüntü gelmeyen kötü bağlantı el sıkışmadan `videoWait` sn sonra bırakılır; sınır hiçbir zaman uzatılmaz, yalnız kısaltılır
    /// (ek süre dışında: el sıkışılmış ama görüntü henüz gelmemişse sınırdan sonra `connectGraceSeconds` kadar beklenir).
    static func shouldGiveUp(elapsed: TimeInterval, limit: TimeInterval, handshakeAge: TimeInterval?, grace: Bool,
                             videoWait: TimeInterval = CameraCaptureController.videoWaitSeconds,
                             graceSeconds: TimeInterval = CameraCaptureController.connectGraceSeconds) -> Bool {
        if let age = handshakeAge, age >= videoWait { return true }
        if elapsed >= limit {
            if grace, handshakeAge != nil, elapsed < limit + graceSeconds { return false }
            return true
        }
        return false
    }

    /// Kameraya bağlanıp görüntünün gelmesini bekler. `limit` verilmezse `connectSeconds` ve ek süre geçerlidir; verilirse sınır kesindir.
    private func awaitLive(limit: TimeInterval?) async -> Bool {
        let started = ProcessInfo.processInfo.systemUptime
        let total = limit ?? CameraCaptureController.connectSeconds
        var graceLogged = false
        while !cancelled {
            if isLive { return true }
            let now = ProcessInfo.processInfo.systemUptime
            let age = handshakeAt.map { now - $0 }
            let elapsed = now - started
            if CameraCaptureController.shouldGiveUp(elapsed: elapsed, limit: total, handshakeAge: age, grace: limit == nil) {
                if let age = age, age >= CameraCaptureController.videoWaitSeconds {
                    tlog("[kamera] el sıkışıldı ama \(Int(age)) sn içinde görüntü gelmedi; bağlantı bırakılıyor (yeniden denenecek)")
                }
                break
            }
            if !graceLogged, elapsed >= total, age != nil {
                graceLogged = true
                tlog("[kamera] el sıkışıldı, görüntü bekleniyor: en çok \(Int(CameraCaptureController.connectGraceSeconds)) sn ek süre")
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return isLive
    }

    /// Görüntü gelmeden bırakılınca nedeni: el sıkışılmışsa kamera görüntü vermedi, yoksa kameraya ulaşılamadı
    private func connectFailure() -> CameraFailure {
        if handshakeAt != nil { return .noFrames }
        switch cameraState {
        case .connected, .streaming: return .noFrames
        default: return .notConnected
        }
    }

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
        if cameraState != .stopped {
            // Her oturumun sonunda kamera pili günlüğe yazılır: bağlantı sorunlarının düşük pille birlikte gelip gelmediği görülsün
            tlog("[kamera] oturum özeti: \((cameraBattery ?? lastBattery)?.shortText ?? "kamera pili okunamadı"), görüntü \(isLive ? "akıyordu" : "akmıyordu")")
        }
        // Akışın gerçek boyutu / kare hızı / bitrate'i her oturumun sonunda günlüğe yazılır (hangi akışın ne verdiği günlükten okunur).
        // Sayaç yazılınca sıfırlanır: teardown ikinci kez çalışırsa aynı satır tekrar yazılmaz.
        if let measured = StreamReport.text(meter.snapshot()) {
            tlog("[kamera] akış ölçümü: " + measured)
            lastStreamSummary = measured
            meter.reset()
        }
        timeoutTask?.cancel()
        timeoutTask = nil
        liveTask?.cancel()
        liveTask = nil
        if let continuation = waiter {
            waiter = nil
            continuation.resume(returning: .cancelled)
        }
        stopCoach()
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
