import Foundation
import CoreVideo

/// Bir çekim penceresinde toplanan kare
struct CollectedFrame {
    let buffer: CVPixelBuffer
    let time: TimeInterval
    let sharpness: Double
}

/// Çekim penceresinin karelerini toplar: her yarım saniyelik dilimden en net kare tutulur (5 sn → en çok 10 kare).
/// Çözme hattının kuyruğundan çağrılır; kilitlidir.
final class FrameCollector {
    /// Bir dilimin uzunluğu (sn); 2 kare/sn
    static let slice: TimeInterval = 0.5

    private let lock = NSLock()
    private var active = false
    private var origin: TimeInterval?
    private var best: [Int: CollectedFrame] = [:]

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    /// Toplamayı başlatır (öncekiler silinir)
    func begin() {
        lock.lock()
        active = true
        origin = nil
        best = [:]
        lock.unlock()
    }

    /// Kare verilir; toplama kapalıysa hemen döner. Dilimin şimdiye dek en net karesi kalır (eşitte ilki).
    func offer(_ buffer: CVPixelBuffer, time: TimeInterval, sharpness: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        if origin == nil { origin = time }
        let index = max(0, Int(((time - (origin ?? time)) / FrameCollector.slice).rounded(.down)))
        if let old = best[index], old.sharpness >= sharpness { return }
        best[index] = CollectedFrame(buffer: buffer, time: time, sharpness: sharpness)
    }

    /// Toplamayı bitirir; kareleri zaman sırasıyla verir
    func end() -> [CollectedFrame] {
        lock.lock()
        defer { lock.unlock() }
        active = false
        let list = best.keys.sorted().compactMap { best[$0] }
        best = [:]
        origin = nil
        return list
    }

    /// Toplamayı bırakır
    func cancel() {
        lock.lock()
        active = false
        best = [:]
        origin = nil
        lock.unlock()
    }
}

/// Bir taramanın geçici dosyaları: sayfa JPEG'leri, PDF'ler ve videolar. İş bitince silinir; kalıcı kayıt belge klasörüne yazılır.
final class ScanFiles {
    let root: URL

    init(runName: String, base: URL = FileManager.default.temporaryDirectory) {
        root = base.appendingPathComponent("g526-\(runName)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Geçici klasörleri ve önceki taramalardan kalanları siler
    static func removeAll(base: URL = FileManager.default.temporaryDirectory) {
        let items = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        for url in items where url.lastPathComponent.hasPrefix("g526-Sinav-") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func jpegURL(question: Int, part: Int, serial: Int) -> URL {
        return root.appendingPathComponent("S\(question)-\(part)-\(serial).jpg")
    }

    /// Sayfa çekiminden seçilen net karenin JPEG adresi
    func jpegURL(page: Int, serial: Int) -> URL {
        return root.appendingPathComponent("Sayfa\(page)-\(serial).jpg")
    }

    /// JPEG'i yazar ve adresini verir
    func writeJPEG(_ data: Data, question: Int, part: Int, serial: Int) throws -> URL {
        let url = jpegURL(question: question, part: part, serial: serial)
        try data.write(to: url, options: .atomic)
        return url
    }

    func videoURL(index: Int) -> URL {
        return root.appendingPathComponent(String(format: "V%02d.mp4", index))
    }


    /// JPEG'leri çok sayfalı PDF'e sarar (her sayfa bir JPEG; yeniden sıkıştırma yok)
    func buildPDF(name: String, jpegs: [URL]) throws -> URL {
        let url = root.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw PDFWrap.WrapError.unsupported("PDF dosyası oluşturulamadı")
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try PDFWrap.write(jpegs: jpegs, title: (name as NSString).deletingPathExtension, to: handle)
        return url
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
