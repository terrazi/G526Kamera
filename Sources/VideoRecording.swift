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
    /// Elle başlatılan video kaydı en çok bu kadar sürer (kareler bu süreden sonra yazılmaz)
    static let maxSeconds: TimeInterval = 90
    /// Deneme sınavının video aşaması (onaylı tasarım: tek, 30 sn'lik kayıt)
    static let examMaxSeconds: TimeInterval = 30
    /// Ayarlarda seçilebilen kayıt süresi aralıkları (sn) ve adım; varsayılanlar yukarıdaki iki değerdir
    static let manualSecondsRange = 10...300
    static let examSecondsRange = 10...120
    static let secondsStep = 10
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
        }
        lock.lock()
        armed = true
        lock.unlock()
    }

    /// Çözülen her kare netlik puanıyla buraya verilir (kayıt kapalıyken hemen döner).
    /// Her `1/fps` saniyelik pencereden en yüksek puanlı kare yazılır; eşit puanda pencerenin ilk karesi kalır.
    func offer(_ buffer: CVPixelBuffer, time: TimeInterval, sharpness: Double) {
        lock.lock()
        let on = armed
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
        }
        let t = time - firstTime
        // süre sınırı: bundan sonraki kareler hiç yazılmaz
        if t < 0 || t >= limit { return }
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

/// Biten videoları belge klasörüne ("G526 Belgeler") kaydeder. Klasör seçilmemişse ya da yazılamazsa dosya diskte bekler;
/// uygulama açılınca ve yeni video kaydedilince yeniden denenir.
@MainActor
final class VideoOutbox {
    static let shared = VideoOutbox()

    private let fm = FileManager.default
    private let pendingDir: URL
    /// Çekilmekte olan kayıtlar burada durur; bitince gönderime alınırken bekleyenler klasörüne taşınır (yarım dosya yüklenmesin)
    private let recordingDir: URL
    private let folder = FolderClient()
    private var busy = false
    private var waiters: [String: (Bool, String) -> Void] = [:]

    init() {
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        pendingDir = support.appendingPathComponent("G526/BekleyenVideolar", isDirectory: true)
        recordingDir = support.appendingPathComponent("G526/KayitVideolar", isDirectory: true)
        try? fm.createDirectory(at: pendingDir, withIntermediateDirectories: true)
        try? fm.removeItem(at: recordingDir)        // önceki oturumdan kalan yarım kayıtlar
        try? fm.createDirectory(at: recordingDir, withIntermediateDirectories: true)
    }

    /// Yeni kaydın yazılacağı (benzersiz adlı) dosya
    func newFileURL(date: Date) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let base = "Video_" + f.string(from: date)
        var name = base + ".mp4"
        var n = 2
        while fm.fileExists(atPath: pendingDir.appendingPathComponent(name).path)
            || fm.fileExists(atPath: recordingDir.appendingPathComponent(name).path) {
            name = "\(base)_\(n).mp4"
            n += 1
        }
        return recordingDir.appendingPathComponent(name)
    }

    private func pendingFiles() -> [URL] {
        let urls = (try? fm.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "mp4" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Biten videoyu gönderime alır; `done` gönderim bitince (başarı, hata metni) ile çağrılır.
    func submit(_ url: URL, done: ((Bool, String) -> Void)? = nil) {
        var file = url
        if url.deletingLastPathComponent().standardizedFileURL != pendingDir.standardizedFileURL {
            let target = pendingDir.appendingPathComponent(url.lastPathComponent)
            try? fm.removeItem(at: target)
            if (try? fm.moveItem(at: url, to: target)) != nil { file = target }
        }
        // Dosya bekleyenler arasına giremediyse (taşınamadı / silinmiş) bekleyen sonuçsuz kalmasın
        guard fm.fileExists(atPath: file.path),
              file.deletingLastPathComponent().standardizedFileURL == pendingDir.standardizedFileURL else {
            tlog("[video] dosya gönderime alınamadı: \(file.lastPathComponent)")
            done?(false, "dosya gönderime alınamadı")
            return
        }
        if let done = done { waiters[file.lastPathComponent] = done }
        flush()
    }

    /// Gönderilmeyecek kaydı siler
    func discard(_ url: URL) {
        try? fm.removeItem(at: url)
    }

    /// Bekleyen tüm videoları sırayla yüklemeyi dener.
    func flush() {
        guard !busy else { return }
        guard !pendingFiles().isEmpty else { return }
        busy = true
        Task { [weak self] in
            // Her turda klasör yeniden taranır: yükleme sürerken gelen yeni video da aynı turda gönderilir
            var tried = Set<String>()
            while let self = self {
                guard let file = self.pendingFiles().first(where: { !tried.contains($0.lastPathComponent) }) else { break }
                tried.insert(file.lastPathComponent)
                await self.send(file)
            }
            self?.busy = false
        }
    }

    private func send(_ file: URL) async {
        let name = file.lastPathComponent
        guard fm.fileExists(atPath: file.path) else {
            finish(name, ok: false, message: "dosya bulunamadı")
            return
        }
        var message = ""
        for attempt in 0..<3 {
            do {
                let saved = try await folder.save(.video(file))
                try? fm.removeItem(at: file)
                tlog("[video] klasöre kaydedildi: \(saved.id)")
                finish(name, ok: true, message: "")
                return
            } catch {
                message = error.localizedDescription
                tlog("[video] kaydetme hatası (\(attempt + 1)/3): \(message)")
                if !folder.isReady { break }
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
    /// Sıradaki videoları sırayla Gemini'ye gönderir ("gemini" kelimesi geçmez: Gemini çağrı komutuyla karışmasın)
    static let send = "videoları gönder, videoları yolla, videoları analiz et, videoları okut, videoları sırayla gönder, "
        + "videoyu gönder, videoyu analiz et"
    static let stop = "kapat, kaydı kapat, kayıt kapat, video kaydını kapat, video kaydı kapat, videoyu kapat, "
        + "kaydı durdur, videoyu durdur, video kaydını durdur"
}
