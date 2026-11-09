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

    // Sesli konumlandırma ve rapor
    @Published private(set) var guidanceStatus = ""
    @Published private(set) var guidanceSaid = ""
    @Published private(set) var guidanceNotice = ""
    @Published private(set) var guidanceAwaiting = false
    @Published private(set) var guidanceOptions: [ColumnChoice] = []
    /// Bu oturumda çekilen (kuyruğa alınan) fotoğraf sayısı
    @Published private(set) var capturedCount = 0

    private let guidance = GuidanceEngine()
    private let speaker = GuidanceSpeaker()
    private var guidanceWasOn = false
    private var speechActive = false
    private var finishRequested = false
    private var lastUnrecognizedAt: TimeInterval = 0
    /// Sesli konumlandırmanın çektiği bölüm (çekim bitince "Sol bölüm çekildi" demek için)
    private var capturePart: ColumnChoice?
    /// Tek tek gönderimde çekimden sonra "dosya gönderildi" demek için çekim anındaki yüklenen sayısı
    private var uploadWatchBase: Int?

    private struct FinishWatch {
        var docs: Int
        var photos: Int
        var errorSpoken = false
    }
    private var finishWatch: FinishWatch?

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
        speech.onCommand = { [weak self] id, text in
            Task { @MainActor in self?.voiceCommand(id, heard: text) }
        }
        speech.onUnrecognized = { [weak self] text in
            Task { @MainActor in self?.voiceUnrecognized(text) }
        }
        pipeline.onGuidance = { [weak self] sample in
            Task { @MainActor in self?.guidanceSample(sample) }
        }
        speaker.onSpeakingChange = { [weak self] speaking in
            Task { @MainActor in self?.speech.suppressed = speaking }
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

        // Sesli konumlandırma ayarları anında uygulanır
        Publishers.CombineLatest4(settings.$guidanceEnabled, settings.$guidanceFlip,
                                  settings.$guidanceAutoCapture, settings.$guidanceSharpness)
            .sink { [weak self] _, _, _, _ in
                Task { @MainActor in self?.updateGuidance() }
            }
            .store(in: &cancellables)

        settings.$guidanceGlare
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateGuidance() }
            }
            .store(in: &cancellables)

        // "Hepsi tamamlandı" gönderimi bitince / başarısız olunca sesli haber ver
        Publishers.CombineLatest3(queue.$pending, queue.$uploaded, queue.$lastError)
            .sink { [weak self] _, _, _ in
                Task { @MainActor in self?.finishProgress() }
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
        updateGuidance()
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
        speaker.stop()
        speechActive = false
        pipeline.guidanceOn = false
        guidanceWasOn = false
        guidanceStatus = ""
        guidanceAwaiting = false
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
        let sKey = "\(settings.voiceEnabled)|\(settings.triggerWord)|\(settings.guidanceEnabled)|\(settings.finishWord)"
        if force || sKey != speechKey {
            speechKey = sKey
            restartSpeech()
        }
        pipeline.configureMotion(enabled: settings.motionEnabled && !settings.guidanceEnabled,
                                 sensitivity: settings.motionSensitivity)
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
        // "Rapor ver" ve "hepsi tamamlandı" her zaman dinlenir; sol/sağ seçimi yalnız sesli konumlandırma açıkken
        var commands: [SpeechTrigger.Command] = []
        let finish = [settings.finishWord, GuidanceVocabulary.finish].filter { !$0.trimmed.isEmpty }.joined(separator: ", ")
        commands.append(SpeechTrigger.Command(id: "finish", phrases: finish, intent: GuidanceVocabulary.finishIntent))
        commands.append(SpeechTrigger.Command(id: "report", phrases: GuidanceVocabulary.report, intent: GuidanceVocabulary.reportIntent))
        commands.append(SpeechTrigger.Command(id: "deleteLast", phrases: GuidanceVocabulary.deleteLast,
                                              intent: GuidanceVocabulary.deleteLastIntent))
        commands.append(SpeechTrigger.Command(id: "retake", phrases: GuidanceVocabulary.retake,
                                              intent: GuidanceVocabulary.retakeIntent))
        if settings.guidanceEnabled {
            commands.append(SpeechTrigger.Command(id: "rechoose", phrases: GuidanceVocabulary.rechoose,
                                                  intent: GuidanceVocabulary.rechooseIntent))
            for c in ColumnChoice.allCases {
                commands.append(SpeechTrigger.Command(id: "choice.\(c.rawValue)", tokens: c.tokens, looseTokens: c.looseTokens))
            }
            commands.append(SpeechTrigger.Command(id: "choice.first", tokens: GuidanceVocabulary.first))
            commands.append(SpeechTrigger.Command(id: "choice.second", tokens: GuidanceVocabulary.second))
            commands.append(SpeechTrigger.Command(id: "choice.last", tokens: GuidanceVocabulary.last))
        }
        speech.setCommands(commands)
        guard settings.voiceEnabled || settings.guidanceEnabled else {
            speechActive = false
            speechStatus = "Sesli komut kapalı"
            return
        }
        speechActive = true
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
        guard settings.voiceEnabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastVoice < settings.cooldown { return }
        lastVoice = now
        capture(reason: "Sesli komut")
    }

    // MARK: - Çekim

    @discardableResult
    func capture(reason: String) -> Bool {
        guard isLive else {
            flash("Kamera görüntüsü yok — fotoğraf çekilemedi")
            return false
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
        return accepted
    }

    private func captureFinished(_ result: Result<CapturedPhoto, CaptureError>, reason: String) {
        capturing = false
        switch result {
        case .success(let photo):
            lastPhoto = UIImage(data: photo.jpeg)
            lastPhotoInfo = "\(photo.width)×\(photo.height) · \(photo.jpeg.count / 1024) KB · \(reason)"
            if queue.enqueue(jpeg: photo.jpeg, date: photo.date) == nil {
                flash("Fotoğraf kaydedilemedi (depolama dolu olabilir)", seconds: 5)
                if guidanceWasOn { say("Fotoğraf kaydedilemedi. Depolama dolu olabilir.", interrupt: true) }
            } else {
                capturedCount += 1
                DailyStatsStore.shared.recordCapture()
                flash("Fotoğraf çekildi")
                if guidanceWasOn && !finishRequested { announceCapture() }
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .failure(let error):
            flash(error.message, seconds: 4)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            if guidanceWasOn {
                guidance.rearm()
                say("Çekim başarısız oldu. Kamerayı sabit tutup tekrar deneyin.", interrupt: true)
            }
        }
        capturePart = nil
        // "Hepsi tamamlandı" son fotoğraf işlenirken söylendiyse, şimdi gönder
        if finishRequested { flushNow() }
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

    // MARK: - Sesli konumlandırma

    private var triggerDisplay: String {
        let first = settings.triggerWord.split(whereSeparator: { $0 == "," || $0 == ";" }).first.map(String.init) ?? "okey"
        return first.trimmed.isEmpty ? "okey" : first.trimmed
    }

    private func updateGuidance() {
        let on = started && settings.guidanceEnabled
        pipeline.guidanceOn = on
        guidance.flip = settings.guidanceFlip
        guidance.autoCapture = settings.guidanceAutoCapture
        guidance.triggerWord = triggerDisplay
        let floors = [0.30, 0.45, 0.60]
        guidance.sharpFloor = floors[min(max(settings.guidanceSharpness, 0), 2)]
        guidance.config.glareLimit = settings.guidanceGlare ? 0.04 : 2
        pipeline.configureMotion(enabled: settings.motionEnabled && !settings.guidanceEnabled,
                                 sensitivity: settings.motionSensitivity)
        if on != guidanceWasOn {
            guidanceWasOn = on
            guidance.reset()
            guidanceStatus = on ? "Sesli konumlandırma açık — sayfayı kadraja alın" : ""
            guidanceAwaiting = false
            guidanceNotice = ""
            speech.choiceMode = false
            if on { say("Sesli konumlandırma açık.") }
        }
    }

    /// Ekranda göster, istenirse (ya da zorunluysa) sesli söyle. Konuşurken mikrofon bastırılır.
    private func say(_ text: String, interrupt: Bool = false, force: Bool = false) {
        guidanceSaid = text
        guard force || settings.guidanceVoice else { return }
        speaker.needsPlaybackSession = !speechActive
        speech.suppressed = true
        speaker.speak(text, interrupt: interrupt)
    }

    private func guidanceSample(_ sample: FramePipeline.GuidanceSample) {
        guard started, settings.guidanceEnabled, isLive else { return }
        if capturing || pipeline.engine.isBusy { return }
        let out = guidance.step(sample.metrics, time: sample.time, stillFor: sample.stillFor,
                                diffToCapture: sample.diffToCapture)
        if out.status != guidanceStatus { guidanceStatus = out.status }
        if out.awaitingChoice != guidanceAwaiting { guidanceAwaiting = out.awaitingChoice }
        if out.awaitingChoice { guidanceOptions = out.options }
        if speech.choiceMode != out.awaitingChoice { speech.choiceMode = out.awaitingChoice }
        if !out.awaitingChoice && !guidanceNotice.isEmpty { guidanceNotice = "" }
        if let text = out.speak { say(text) }
        if out.capture { guidanceCapture() }
    }

    private func guidanceCapture() {
        capturePart = guidance.lastCaptured
        if capture(reason: "Sesli konumlandırma") {
            pipeline.markCaptured()
        } else {
            capturePart = nil
            guidance.rearm()
        }
    }

    /// Ekrandaki düğme (yedek) ya da sesli seçim
    func chooseColumn(_ choice: ColumnChoice) {
        let reply = guidance.setChoice(choice)
        guidanceNotice = ""
        guidanceAwaiting = false
        speech.choiceMode = false
        say(reply, interrupt: true)
    }

    private func voiceCommand(_ id: String, heard: String) {
        switch id {
        case "finish":
            finishAll()
        case "report":
            giveReport()
        case "deleteLast":
            deleteLast(retake: false)
        case "retake":
            deleteLast(retake: true)
        case "rechoose":
            guard settings.guidanceEnabled else { return }
            guidanceNotice = ""
            say(guidance.clearChoice(), interrupt: true)
        default:
            guard id.hasPrefix("choice."), settings.guidanceEnabled else { return }
            voiceChoice(String(id.dropFirst("choice.".count)))
        }
    }

    private func voiceChoice(_ name: String) {
        // Soru bekleniyorken ya da bir seçim varken (seçimi değiştirmek için) kabul edilir
        guard guidance.awaitingChoice || guidance.choice != nil else {
            guidanceNotice = "Şu an seçim gerekmiyor"
            return
        }
        let options = guidance.currentOptions
        var choice: ColumnChoice?
        switch name {
        case "first": choice = .left
        case "last": choice = .right
        case "second": choice = options.contains(.middle) ? .middle : .right
        default: choice = ColumnChoice(rawValue: name)
        }
        guard let c = choice else { return }
        if c == .middle && !options.contains(.middle) {
            guidanceNotice = "Orta bölüm yok"
            say("Orta bölüm yok. Sol ya da sağ deyin.", interrupt: true)
            return
        }
        chooseColumn(c)
    }

    /// "Son fotoğrafı sil" ve "yeniden çek": gönderilmemiş son fotoğrafı siler; yeniden çekmede aynı bölümü yeniden kadraja aldırır
    private func deleteLast(retake: Bool) {
        // Soru beklenirken "sol"un "sil" diye yanlış duyulması fotoğraf silmesin
        if guidance.awaitingChoice {
            guidanceNotice = "Önce bölümü seçin (sol / sağ)"
            return
        }
        if capturing || pipeline.engine.isBusy {
            say("Çekim işleniyor, bitince tekrar söyleyin.", interrupt: true, force: true)
            return
        }
        let part = guidance.lastCaptured
        let outcome = queue.removeLast()
        if case .removed = outcome {
            capturedCount = max(0, capturedCount - 1)
            DailyStatsStore.shared.undoCapture()
            if retake && guidanceWasOn {
                guidance.rearm()
                if let p = part { _ = guidance.setChoice(p) }
                pipeline.markCaptured()
            }
        }
        let text = SpokenReport.afterDelete(outcome, waiting: queue.pending, retake: retake, part: part?.title,
                                            guided: guidanceWasOn, trigger: triggerDisplay)
        flash(text, seconds: 6)
        say(text, interrupt: true, force: true)
    }

    /// Çekim bitti: ne çekildi, dosya gönderiliyor mu / bekliyor mu (sayfa çevrilebilir)
    private func announceCapture() {
        let batch = settings.sendMode == "batch"
        let signedIn = auth.isSignedIn
        say(SpokenReport.afterCapture(part: capturePart?.title, waiting: queue.pending,
                                      signedIn: signedIn, batchMode: batch, batchSize: settings.batchSize))
        // Tek tek gönderimde dosya yüklenince "dosya gönderildi" de denir
        uploadWatchBase = (!batch && signedIn) ? queue.uploaded : nil
    }

    /// Soru beklenirken komut olmayan konuşma duyuldu: açıkça belirt
    private func voiceUnrecognized(_ text: String) {
        guard settings.guidanceEnabled, guidance.awaitingChoice else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastUnrecognizedAt < 3 { return }
        lastUnrecognizedAt = now
        guidanceNotice = "Anlaşılmadı: “\(text)”"
        let options = guidance.currentOptions
        say(options.contains(.middle) ? "Komutu anlayamadım. Sol, orta ya da sağ deyin."
                                      : "Komutu anlayamadım. Sol ya da sağ deyin.", interrupt: true)
    }

    // MARK: - "Hepsi tamamlandı" ve rapor

    /// Bekleyen bütün fotoğrafları şimdi gönder (toplu modda tek PDF)
    func finishAll() {
        if capturing {
            finishRequested = true
            say("Son fotoğraf işleniyor, bitince göndereceğim.", interrupt: true, force: true)
            return
        }
        flushNow()
    }

    private func flushNow() {
        finishRequested = false
        let waiting = queue.pending
        if waiting == 0 {
            say("Gönderilecek sayfa yok.", interrupt: true, force: true)
            return
        }
        guard auth.isSignedIn else {
            say("Drive'a giriş yapılmamış. \(waiting) sayfa bekliyor. Ayarlardan giriş yapın.", interrupt: true, force: true)
            return
        }
        finishWatch = FinishWatch(docs: queue.uploadedDocs, photos: queue.uploaded)
        queue.retry()
        let pdf = settings.uploadFormat == "pdf"
        say(pdf ? "\(waiting) sayfa PDF'e çevrilip gönderiliyor." : "\(waiting) fotoğraf gönderiliyor.",
            interrupt: true, force: true)
    }

    private func finishProgress() {
        if let base = uploadWatchBase, queue.pending == 0, queue.uploaded > base {
            uploadWatchBase = nil
            say("Dosya gönderildi.")
        } else if uploadWatchBase != nil && queue.pending > 0 && !queue.lastError.isEmpty {
            uploadWatchBase = nil
            say("Dosya gönderilemedi, bağlantı gelince yeniden denenecek.")
        }
        guard var watch = finishWatch else { return }
        if queue.pending == 0 && queue.uploaded > watch.photos {
            finishWatch = nil
            say(SpokenReport.finished(photos: queue.uploaded - watch.photos,
                                      docs: queue.uploadedDocs - watch.docs,
                                      pdf: settings.uploadFormat == "pdf"), interrupt: true, force: true)
        } else if queue.pending > 0 && !queue.lastError.isEmpty && !watch.errorSpoken {
            watch.errorSpoken = true
            finishWatch = watch
            say("Gönderim başarısız oldu. Bağlantı gelince yeniden denenecek.", interrupt: true, force: true)
        }
    }

    func reportText() -> String {
        let today = DailyStatsStore.shared.today()
        return SpokenReport.make(captured: today.captured, sentPhotos: today.sentPhotos, sentDocs: today.sentDocs,
                                 waiting: queue.pending, signedIn: auth.isSignedIn,
                                 hasError: !queue.lastError.isEmpty, pdf: settings.uploadFormat == "pdf",
                                 batchMode: settings.sendMode == "batch")
    }

    /// "Rapor ver": kaç sayfa çekildi, kaçı PDF olarak gitti, kaçı bekliyor
    func giveReport() {
        let text = reportText()
        flash(text, seconds: 10)
        say(text, interrupt: true, force: true)
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
