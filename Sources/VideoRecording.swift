import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import Network

/// Kameranın çözülmüş karelerini küçük boyutlu H.264 MP4 dosyasına yazar.
///
/// Neden bu ayarlar: Gemini videoyu saniyede 1 kare örnekler; 5 kare/sn hem insan gözüyle akıcı hem çok küçüktür.
/// Çözünürlük kameranınkiyle aynı kalır (1920x1080), böylece yazı okunur; boyutu bit hızı sınırlar
/// (1080p'de yaklaşık 1 Mbit/sn: 30 sn ≈ 4 MB). H.264 (High) + MP4, Gemini'nin ve Drive önizlemesinin en güvenli biçimidir.
/// Ses yoktur (kameranın akışında ses yok; telefon mikrofonu sesli komutlara ayrılmıştır).
final class VideoRecorder {
    /// Bir kayıt en çok bu kadar sürer (kareler bu süreden sonra yazılmaz)
    static let maxSeconds: TimeInterval = 30
    static let fps: Double = 5
    static let bitsPerPixel: Double = 0.10
    static let minBitrate: Double = 250_000
    static let maxBitrate: Double = 1_200_000

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

    // Yalnızca `queue` üzerinde kullanılır
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var fileURL: URL?
    private var firstTime: TimeInterval = 0
    private var lastPTS: Double = -1
    private var frames = 0
    private var failed: String?

    var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return armed
    }

    /// Hedef bit hızı (bit/sn): çözünürlükle orantılı, alt ve üst sınırlı.
    static func bitrate(width: Int, height: Int) -> Int {
        let raw = Double(width * height) * fps * bitsPerPixel
        return Int(min(max(raw, minBitrate), maxBitrate))
    }

    /// Kaydı hazırlar; dosya ilk kare gelince, kare boyutuna göre açılır.
    func start(to url: URL) {
        queue.sync {
            self.discardWriter()
            self.fileURL = url
            self.firstTime = 0
            self.lastPTS = -1
            self.frames = 0
            self.failed = nil
        }
        lock.lock()
        armed = true
        lock.unlock()
    }

    /// Çözülen her kare buraya verilir (kayıt kapalıyken hemen döner).
    func append(_ buffer: CVPixelBuffer, time: TimeInterval) {
        lock.lock()
        let on = armed
        lock.unlock()
        guard on else { return }
        queue.async { self.write(buffer, time: time) }
    }

    /// Kaydı bitirir ve dosyayı kapatır.
    func finish(_ done: @escaping (Result<Output, Failure>) -> Void) {
        lock.lock()
        armed = false
        lock.unlock()
        queue.async {
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
            let seconds = min(self.lastPTS + 1.0 / VideoRecorder.fps, VideoRecorder.maxSeconds)
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
        writer = nil
        input = nil
        adaptor = nil
    }

    private func write(_ buffer: CVPixelBuffer, time: TimeInterval) {
        guard let url = fileURL, failed == nil else { return }
        if writer == nil {
            guard open(url: url, buffer: buffer) else { return }
            firstTime = time
        }
        let t = time - firstTime
        // 30 saniye sınırı: bundan sonraki kareler hiç yazılmaz
        if t > VideoRecorder.maxSeconds { return }
        // Kare hızını seyrelt (kamera genelde daha hızlıdır)
        if lastPTS >= 0 && t - lastPTS < 1.0 / VideoRecorder.fps - 0.02 { return }
        guard let w = writer, let inp = input, let ad = adaptor, w.status == .writing, inp.isReadyForMoreMediaData else { return }
        let pts = CMTime(seconds: t, preferredTimescale: 600)
        if ad.append(buffer, withPresentationTime: pts) {
            frames += 1
            lastPTS = t
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
                AVVideoMaxKeyFrameIntervalKey: Int(VideoRecorder.fps * 2),
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

/// Biten videoları Drive'a yükler. Yükleme olmazsa dosya diskte bekler; ağ gelince, uygulama açılınca
/// ve yeni video kaydedilince yeniden denenir.
@MainActor
final class VideoOutbox {
    static let shared = VideoOutbox()

    private let fm = FileManager.default
    private let pendingDir: URL
    private let localDir: URL
    private lazy var drive = DriveClient(auth: GoogleAuth.shared)
    private var busy = false
    private var waiters: [String: (Bool, String) -> Void] = [:]
    private let monitor = NWPathMonitor()

    init() {
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        pendingDir = support.appendingPathComponent("G526/BekleyenVideolar", isDirectory: true)
        localDir = docs.appendingPathComponent("Videolar", isDirectory: true)
        try? fm.createDirectory(at: pendingDir, withIntermediateDirectories: true)
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.flush() }
        }
        monitor.start(queue: DispatchQueue(label: "g526.videonet"))
    }

    /// Yeni kaydın yazılacağı (benzersiz adlı) dosya
    func newFileURL(date: Date) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let base = "Video_" + f.string(from: date)
        var name = base + ".mp4"
        var n = 2
        while fm.fileExists(atPath: pendingDir.appendingPathComponent(name).path) {
            name = "\(base)_\(n).mp4"
            n += 1
        }
        return pendingDir.appendingPathComponent(name)
    }

    var pendingCount: Int { return pendingFiles().count }

    private func pendingFiles() -> [URL] {
        let urls = (try? fm.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "mp4" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Biten videoyu gönderime alır; `done` gönderim bitince (başarı, hata metni) ile çağrılır.
    func submit(_ url: URL, done: ((Bool, String) -> Void)? = nil) {
        if AppSettings.shared.keepLocalCopies {
            try? fm.createDirectory(at: localDir, withIntermediateDirectories: true)
            let copy = localDir.appendingPathComponent(url.lastPathComponent)
            try? fm.removeItem(at: copy)
            try? fm.copyItem(at: url, to: copy)
        }
        if let done = done { waiters[url.lastPathComponent] = done }
        flush()
    }

    /// Bekleyen tüm videoları sırayla yüklemeyi dener.
    func flush() {
        guard !busy else { return }
        let files = pendingFiles()
        guard !files.isEmpty else { return }
        busy = true
        Task { [weak self] in
            for file in files {
                guard let self = self else { return }
                await self.send(file)
            }
            self?.busy = false
        }
    }

    private func send(_ file: URL) async {
        let name = file.lastPathComponent
        guard fm.fileExists(atPath: file.path) else { return }
        var message = ""
        for attempt in 0..<3 {
            do {
                _ = try await drive.uploadFile(.video(file), name: name)
                try? fm.removeItem(at: file)
                tlog("[video] Drive'a gönderildi: \(name)")
                finish(name, ok: true, message: "")
                return
            } catch {
                message = error.localizedDescription
                tlog("[video] yükleme hatası (\(attempt + 1)/3): \(message)")
                if let drv = error as? DriveError, case .notSignedIn = drv { break }
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: UInt64((attempt == 0 ? 3 : 10) * 1_000_000_000))
                }
            }
        }
        finish(name, ok: false, message: message)
    }

    private func finish(_ name: String, ok: Bool, message: String) {
        guard let done = waiters.removeValue(forKey: name) else { return }
        done(ok, message)
    }
}

/// Sesli video komutları. "kapat" yalnız kayıt açıkken işe yarar. "bitir" bilerek yok: "Hepsini gönder" komutunun
/// (bitir → PDF gönder) anlamıyla karışır.
enum VideoVocabulary {
    static let start = "video kaydını aç, video kaydı aç, video kaydını başlat, video kaydı başlat, videoyu aç, videoyu başlat, "
        + "video çek, video çekmeye başla, kaydı aç, kaydı başlat, kayıt aç, kayıt başlat"
    static let stop = "kapat, kaydı kapat, kayıt kapat, video kaydını kapat, video kaydı kapat, videoyu kapat, "
        + "kaydı durdur, videoyu durdur, video kaydını durdur"
}
