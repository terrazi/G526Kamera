import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

/// Kameranın çözülmüş karelerini küçük boyutlu H.264 MP4 dosyasına yazar.
///
/// Neden bu ayarlar: Gemini videoyu (bildiğim kadarıyla) saniyede 1 kare örnekler; saniyede 2 kare yeterlidir.
/// Kare sayısı azaltılıp her kareye daha çok bit verilir ve her yarım saniyelik pencereden o penceredeki EN NET kare seçilir
/// (netlik puanı çözme hattında zaten hesaplanır, ek iş yoktur). Böylece bir yanı bulanık, bir yanı net karelerden netleri yazılır.
/// Çözünürlük kameranınkiyle aynı kalır (1920x1080); boyutu bit hızı belirler (hedef ≈ 1,2 Mbit/sn; kodlayıcı bunu bir miktar aşabilir,
/// o yüzden 30 sn için ≈ 4,5–8 MB, 90 sn için ≈ 14–24 MB beklenir, durağan belge sahnesinde daha küçük çıkar). H.264 (High) + MP4, Gemini'nin ve Dosyalar
/// uygulamasının en güvenli biçimidir.
/// Ses yoktur (kameranın akışında ses yok; telefon mikrofonu sesli komutlara ayrılmıştır).
final class VideoRecorder {
    /// Bir kaydın en uzun süresi (sn); `start(maxSeconds:)` ile kısaltılır (otomatik taramada her çekim 5 sn)
    static let maxSeconds: TimeInterval = 90
    static let fps: Double = 2
    static let bitsPerPixel: Double = 0.28
    static let minBitrate: Double = 250_000
    static let maxBitrate: Double = 1_500_000

    struct Output {
        let url: URL
        let seconds: Double
        let frames: Int
        let bytes: Int
    }

    enum Failure: Error {
        case noFrames
        case writer(String)
    }

    private let queue = DispatchQueue(label: "g526.videorec", qos: .userInitiated)
    private let lock = NSLock()
    private var armed = false
    /// Duraklatıldı: kareler yazılmaz, dosya açık kalır (kilitle korunur)
    private var paused = false
    /// Şimdiye dek dosyaya yazılan video süresi (sn; duraklamalar sayılmaz). Kilitle korunur.
    private var recorded: Double = 0

    // Yalnızca `queue` üzerinde kullanılır
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var fileURL: URL?
    private var orientation: ImageOrientation = .normal
    private var firstTime: TimeInterval = 0
    private var lastPTS: Double = -1
    private var frames = 0
    private var failed: String?
    private var limit: TimeInterval = VideoRecorder.maxSeconds
    /// Duraklamalarda atlanan kaynak süresi (video zamanı = kaynak zamanı − firstTime − skipped)
    private var skipped: Double = 0
    /// En son değerlendirilen karenin video zamanı (devamda bir pencere sonrasından sürdürülür)
    private var lastT: Double = -1
    private var resumePending = false

    /// Şu anki yarım saniyelik pencerenin şimdiye dek gelen en net karesi (yalnızca `queue` üzerinde).
    private struct Candidate {
        let buffer: CVPixelBuffer
        let sharpness: Double
        let window: Int
    }
    private var pending: Candidate?

    var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return armed
    }

    var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return armed && paused
    }

    /// Dosyaya şimdiye dek yazılan video süresi (sn); duraklamalar sayılmaz
    var recordedSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// Hedef bit hızı (bit/sn): çözünürlükle orantılı, alt ve üst sınırlı.
    static func bitrate(width: Int, height: Int) -> Int {
        let raw = Double(width * height) * fps * bitsPerPixel
        return Int(min(max(raw, minBitrate), maxBitrate))
    }

    /// Kaydı hazırlar; dosya ilk kare gelince, kare boyutuna göre açılır.
    /// `orientation`: video dosyasına yalnız oynatma dönüşümü yazılır (kareler çevrilmez; ısınma yok).
    func start(to url: URL, orientation: ImageOrientation = .normal, maxSeconds: TimeInterval = VideoRecorder.maxSeconds) {
        queue.sync {
            self.discardWriter()
            self.limit = maxSeconds
            self.orientation = orientation
            self.fileURL = url
            self.firstTime = 0
            self.lastPTS = -1
            self.frames = 0
            self.failed = nil
            self.skipped = 0
            self.lastT = -1
            self.resumePending = false
        }
        lock.lock()
        armed = true
        paused = false
        recorded = 0
        lock.unlock()
    }

    /// Kaydı duraklatır: dosya açık kalır, kareler yazılmaz. Süre sınırı yalnız yazılan saniyeleri sayar.
    func pause() {
        lock.lock()
        guard armed, !paused else {
            lock.unlock()
            return
        }
        paused = true
        lock.unlock()
        queue.sync {
            // bu ana dek gelen son (yarım kalmış) pencerenin en net karesi de yazılır
            if let last = self.pending {
                self.pending = nil
                self.commit(last)
            }
        }
    }

    /// Duraklatılmış kayda devam eder: sonraki kare, önceki karenin bir pencere sonrasına yazılır (arada boşluk kalmaz).
    func resume() {
        lock.lock()
        let ok = armed && paused
        lock.unlock()
        guard ok else { return }
        queue.sync { self.resumePending = true }
        lock.lock()
        paused = false
        lock.unlock()
    }

    /// Çözülen her kare netlik puanıyla buraya verilir (kayıt kapalıyken hemen döner).
    /// Her `1/fps` saniyelik pencereden en yüksek puanlı kare yazılır; eşit puanda pencerenin ilk karesi kalır.
    func offer(_ buffer: CVPixelBuffer, time: TimeInterval, sharpness: Double) {
        lock.lock()
        let on = armed && !paused
        lock.unlock()
        guard on else { return }
        queue.async { self.consider(buffer, time: time, sharpness: sharpness) }
    }

    /// Netlik puanı olmayan kare (hepsi eşit sayılır: her pencerenin ilk karesi yazılır).
    func append(_ buffer: CVPixelBuffer, time: TimeInterval) {
        offer(buffer, time: time, sharpness: 0)
    }

    /// Kaydı bitirir ve dosyayı kapatır.
    func finish(_ done: @escaping (Result<Output, Failure>) -> Void) {
        lock.lock()
        armed = false
        paused = false
        lock.unlock()
        queue.async {
            // son (yarım kalmış) pencerenin en net karesi de yazılır
            if let last = self.pending {
                self.pending = nil
                self.commit(last)
            }
            guard let w = self.writer, let inp = self.input, let url = self.fileURL, self.frames > 0 else {
                self.discardWriter()
                if let url = self.fileURL { try? FileManager.default.removeItem(at: url) }
                done(.failure(.noFrames))
                return
            }
            guard w.status == .writing else {
                let message = w.error?.localizedDescription ?? self.failed ?? "yazıcı durdu"
                self.discardWriter()
                try? FileManager.default.removeItem(at: url)
                done(.failure(.writer(message)))
                return
            }
            let seconds = min(self.lastPTS + 1.0 / VideoRecorder.fps, self.limit)
            let count = self.frames
            inp.markAsFinished()
            w.endSession(atSourceTime: CMTime(seconds: seconds, preferredTimescale: 600))
            self.writer = nil
            self.input = nil
            self.adaptor = nil
            w.finishWriting {
                if w.status == .completed {
                    let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
                    let bytes = (attrs[.size] as? NSNumber)?.intValue ?? 0
                    done(.success(Output(url: url, seconds: seconds, frames: count, bytes: bytes)))
                } else {
                    try? FileManager.default.removeItem(at: url)
                    done(.failure(.writer(w.error?.localizedDescription ?? "dosya tamamlanamadı")))
                }
            }
        }
    }

    /// Kaydı atar ve yarım dosyayı siler.
    func cancel() {
        lock.lock()
        armed = false
        paused = false
        lock.unlock()
        queue.async {
            let url = self.fileURL
            self.discardWriter()
            if let url = url { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: - queue üzerinde

    private func discardWriter() {
        if let w = writer, w.status == .writing { w.cancelWriting() }
        pending = nil
        writer = nil
        input = nil
        adaptor = nil
    }

    /// Kareyi pencerelerine göre değerlendirir: yeni pencere başlarsa öncekinin en net karesi yazılır.
    private func consider(_ buffer: CVPixelBuffer, time: TimeInterval, sharpness: Double) {
        guard let url = fileURL, failed == nil else { return }
        if writer == nil {
            guard open(url: url, buffer: buffer) else { return }
            firstTime = time
            resumePending = false
        }
        var t = time - firstTime - skipped
        if resumePending {
            // duraklamadan sonraki ilk kare: önceki karenin tam bir pencere sonrasına oturur
            resumePending = false
            if lastT >= 0 {
                let next = lastT + 1.0 / VideoRecorder.fps
                skipped = (time - firstTime) - next
                t = next
            }
        }
        // süre sınırı: bundan sonraki kareler hiç yazılmaz
        if t < 0 || t >= limit { return }
        lastT = t
        let window = Int(t * VideoRecorder.fps)
        if let p = pending {
            if window < p.window { return }          // geç gelen eski kare
            if window > p.window {
                pending = nil
                commit(p)
            }
        }
        if let p = pending, p.sharpness >= sharpness { return }
        pending = Candidate(buffer: buffer, sharpness: sharpness, window: window)
    }

    /// Seçilen kareyi pencerenin başlangıç zamanıyla yazar (zamanlar düzenli aralıklıdır; oynatma gerçek hızdadır).
    private func commit(_ c: Candidate) {
        guard let w = writer, let inp = input, let ad = adaptor, w.status == .writing else { return }
        // Kodlayıcı o an yetişemiyorsa kısa süre beklenir; yine de hazır değilse kare atılır
        var waited = 0
        while !inp.isReadyForMoreMediaData && waited < 60 {
            Thread.sleep(forTimeInterval: 0.005)
            waited += 1
        }
        guard inp.isReadyForMoreMediaData else { return }
        let t = Double(c.window) / VideoRecorder.fps
        if ad.append(c.buffer, withPresentationTime: CMTime(seconds: t, preferredTimescale: 600)) {
            frames += 1
            lastPTS = t
            lock.lock()
            recorded = t + 1.0 / VideoRecorder.fps
            lock.unlock()
        } else {
            failed = w.error?.localizedDescription ?? "kare yazılamadı"
        }
    }

    private func open(url: URL, buffer: CVPixelBuffer) -> Bool {
        try? FileManager.default.removeItem(at: url)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else { failed = "kare boyutu geçersiz"; return false }
        do {
            let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let compression: [String: Any] = [
                AVVideoAverageBitRateKey: VideoRecorder.bitrate(width: width, height: height),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: Int(VideoRecorder.fps),
                AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
                AVVideoExpectedSourceFrameRateKey: Int(VideoRecorder.fps)
            ]
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: compression
            ]
            let inp = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            inp.expectsMediaDataInRealTime = true
            inp.transform = orientation.videoTransform(width: CGFloat(width), height: CGFloat(height))
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(CVPixelBufferGetPixelFormatType(buffer))
            ]
            let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: inp, sourcePixelBufferAttributes: attributes)
            guard w.canAdd(inp) else { failed = "video girişi eklenemedi"; return false }
            w.add(inp)
            w.shouldOptimizeForNetworkUse = true
            guard w.startWriting() else {
                failed = w.error?.localizedDescription ?? "yazma başlatılamadı"
                return false
            }
            w.startSession(atSourceTime: .zero)
            writer = w
            input = inp
            adaptor = ad
            tlog("[video] kayıt açıldı: \(width)x\(height), \(VideoRecorder.bitrate(width: width, height: height) / 1000) kbit/sn")
            return true
        } catch {
            failed = error.localizedDescription
            return false
        }
    }
}
