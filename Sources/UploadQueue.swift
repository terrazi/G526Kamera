import Foundation
import Network

/// Çekilen fotoğrafları diske yazar ve Drive'a yükler. Bağlantı yoksa kuyrukta bekler,
/// uygulama kapansa bile kaybolmaz; başarısız yüklemeler artan aralıklarla yeniden denenir.
/// Gönderme biçimi ayarlardan seçilir: tek tek (her fotoğraf hemen) ya da toplu (biriksin, birlikte gitsin);
/// dosya türü PDF (JPEG yeniden işlenmeden sarılır) ya da JPEG olabilir.
@MainActor
final class UploadQueue: ObservableObject {
    static let shared = UploadQueue()

    @Published private(set) var pending = 0
    @Published private(set) var uploaded = 0
    /// Bu oturumda Drive'a giden dosya (PDF ya da JPEG) sayısı
    @Published private(set) var uploadedDocs = 0
    @Published private(set) var status = ""
    @Published private(set) var lastError = ""

    private let fm = FileManager.default
    private let settings = AppSettings.shared
    private let pendingDir: URL
    private let localDir: URL
    private lazy var drive = DriveClient(auth: GoogleAuth.shared)
    private var worker: Task<Void, Never>?
    private var retryNow = false
    private var flush = false        // "şimdi gönder" istendi
    private var draining = false     // toplu gönderim başladı: kuyruk boşalana kadar sürer
    private var lastEnqueue = Date.distantPast
    private var failures = 0
    private let monitor = NWPathMonitor()
    private var captureLog = CaptureLog()
    private var inFlight = Set<String>()

    init() {
        let manager = FileManager.default
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let docs = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let pendingURL = support.appendingPathComponent("G526/Bekleyen", isDirectory: true)
        let localURL = docs.appendingPathComponent("Belgeler", isDirectory: true)
        try? manager.createDirectory(at: pendingURL, withIntermediateDirectories: true)
        try? manager.createDirectory(at: localURL, withIntermediateDirectories: true)
        pendingDir = pendingURL
        localDir = localURL
        pending = pendingFiles().count
        status = pending > 0 ? "\(pending) fotoğraf yüklenmeyi bekliyor" : ""

        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.networkChanged() }
        }
        monitor.start(queue: DispatchQueue(label: "g526.netmon"))
    }

    private func networkChanged() {
        if pending > 0 && failures > 0 { retryNow = true }
        kick()
    }

    private func pendingFiles() -> [URL] {
        let urls = (try? fm.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func fileName(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let base = "Belge_" + f.string(from: date)
        var name = base + ".jpg"
        var n = 2
        while fm.fileExists(atPath: pendingDir.appendingPathComponent(name).path)
                || fm.fileExists(atPath: localDir.appendingPathComponent(name).path) {
            name = "\(base)_\(n).jpg"
            n += 1
        }
        return name
    }

    /// Fotoğrafı diske yazar ve yüklemeyi başlatır. Yazılamazsa nil döner.
    @discardableResult
    func enqueue(jpeg: Data, date: Date) -> String? {
        let name = fileName(for: date)
        do {
            try jpeg.write(to: pendingDir.appendingPathComponent(name), options: .atomic)
        } catch {
            tlog("[kuyruk] yazılamadı: \(error.localizedDescription)")
            return nil
        }
        if settings.keepLocalCopies {
            try? jpeg.write(to: localDir.appendingPathComponent(name), options: .atomic)
        }
        pending = pendingFiles().count
        lastEnqueue = Date()
        captureLog.add(name)
        if settings.ocrEnabled { OcrCenter.shared.submit(pendingDir.appendingPathComponent(name)) }
        kick()
        return name
    }

    /// "Son fotoğrafı sil": bu oturumda çekilmiş, henüz yüklenmemiş son fotoğrafı (ve OCR metnini) siler.
    func removeLast() -> CaptureLog.Outcome {
        let names = Set(pendingFiles().map { $0.lastPathComponent })
        let outcome = captureLog.takeLast(pending: names, inFlight: inFlight)
        if case .removed(let name) = outcome {
            let url = pendingDir.appendingPathComponent(name)
            OcrCenter.shared.forget(url)
            remove(url)
            try? fm.removeItem(at: localDir.appendingPathComponent(name))
            pending = pendingFiles().count
            status = pending > 0 ? "\(pending) fotoğraf yüklenmeyi bekliyor" : ""
            tlog("[kuyruk] silindi: \(name)")
        }
        return outcome
    }

    /// Hemen dene. Toplu modda biriken fotoğrafları da şimdi gönderir.
    func retry() {
        retryNow = true
        flush = true
        kick()
    }

    func kick() {
        if worker != nil { return }
        worker = Task { [weak self] in
            guard let self = self else { return }
            await self.run()
            self.worker = nil
        }
    }

    private struct Job {
        let files: [URL]
        let name: String
        let payload: UploadPayload
    }

    /// Fotoğrafı ve varsa OCR metin dosyasını siler.
    private func remove(_ url: URL) {
        try? fm.removeItem(at: url)
        try? fm.removeItem(at: OcrCenter.sidecar(url))
    }

    private func quarantine(_ url: URL) {
        try? fm.removeItem(at: OcrCenter.sidecar(url))
        let bad = url.appendingPathExtension("bozuk")
        do {
            try fm.moveItem(at: url, to: bad)
        } catch {
            try? fm.removeItem(at: url)   // taşınamıyorsa kuyruğu kilitlemesin
        }
    }

    /// Sıradaki yüklemeyi hazırlar. PDF modunda toplu gönderimde birçok fotoğraf tek PDF olur
    /// (en çok ayarlanan sayıda ve 15 MB'a kadar); tek tek modda her fotoğraf kendi PDF'i olur.
    private func prepareJob(files: [URL], batch: Bool) -> Job? {
        if settings.uploadFormat != "pdf" {
            guard let first = files.first else { return nil }
            return Job(files: [first], name: first.lastPathComponent, payload: .jpeg(first))
        }
        let limitCount = batch ? (settings.batchSize > 0 ? settings.batchSize : 30) : 1
        let limitBytes = 15 * 1024 * 1024
        var group: [URL] = []
        var total = 0
        for url in files {
            if group.count >= limitCount { break }
            guard PDFWrap.isWrappable(url) else {
                tlog("[kuyruk] bozuk JPEG atlandı: \(url.lastPathComponent)")
                quarantine(url)
                continue
            }
            let attrs = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            if !group.isEmpty && total + size > limitBytes { break }
            group.append(url)
            total += size
        }
        guard let first = group.first else { return nil }
        let stem = first.deletingPathExtension().lastPathComponent
        let name = group.count == 1
            ? stem + ".pdf"
            : stem.replacingOccurrences(of: "Belge_", with: "Belgeler_") + "_\(group.count)sayfa.pdf"
        var texts: [String] = []
        if settings.ocrEnabled {
            texts = group.map { OcrCenter.readText($0) }
            if !texts.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { texts = [] }
        }
        return Job(files: group, name: name, payload: .pdf(group, title: stem, texts: texts))
    }

    private func run() async {
        while true {
            let files = pendingFiles()
            pending = files.count
            guard !files.isEmpty else {
                draining = false
                flush = false
                status = uploaded > 0 ? "Tüm fotoğraflar yüklendi" : ""
                return
            }
            guard GoogleAuth.shared.isSignedIn else {
                status = "Drive'a giriş yapılmadı — \(files.count) fotoğraf bekliyor"
                return
            }

            let batch = settings.sendMode == "batch"
            if batch && !draining {
                let size = settings.batchSize
                let idle = settings.batchIdle
                let quiet = Date().timeIntervalSince(lastEnqueue)
                if flush || (size > 0 && files.count >= size) || (idle > 0 && quiet >= Double(idle)) {
                    draining = true
                } else {
                    var more: [String] = []
                    if size > 0 { more.append("\(size) olunca") }
                    if idle > 0 { more.append("\(idle) sn beklenince") }
                    more.append("“Şimdi gönder” ile")
                    status = "\(files.count) fotoğraf birikti — toplu gönderilecek (\(more.joined(separator: ", ")))"
                    if idle > 0 && !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        continue
                    }
                    return
                }
            }
            flush = false

            status = "Yükleniyor… (\(files.count) bekliyor)"
            retryNow = false
            if settings.ocrEnabled && settings.uploadFormat == "pdf" {
                let count = batch ? (settings.batchSize > 0 ? settings.batchSize : 30) : 1
                let group = Array(files.prefix(count))
                if group.contains(where: { OcrCenter.shared.isPending($0) }) {
                    status = "Metin okunuyor (OCR)…"
                    await OcrCenter.shared.waitFor(group, timeout: OcrCenter.shared.uploadWait)
                }
            }
            guard let job = prepareJob(files: files, batch: batch) else { continue }
            inFlight = Set(job.files.map { $0.lastPathComponent })
            defer { inFlight = [] }
            do {
                try await drive.upload(job.payload, name: job.name)
                for file in job.files { remove(file) }
                uploaded += job.files.count
                uploadedDocs += 1
                DailyStatsStore.shared.recordSent(photos: job.files.count, docs: 1)
                failures = 0
                lastError = ""
                tlog("[drive] yüklendi: \(job.name) (\(job.files.count) fotoğraf)")
                if pendingFiles().isEmpty { draining = false }
            } catch {
                inFlight = []
                failures += 1
                lastError = error.localizedDescription
                let wait = min(5.0 * pow(2.0, Double(failures - 1)), 300.0)
                tlog("[drive] yükleme hatası: \(lastError)")
                if let drv = error as? DriveError, case .notSignedIn = drv {
                    status = "Drive oturumu gerekli — \(files.count) fotoğraf bekliyor"
                    return
                }
                var waited = 0.0
                while waited < wait && !retryNow && !Task.isCancelled {
                    status = "Yükleme başarısız (\(lastError)) — \(Int(wait - waited)) sn sonra yeniden"
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    waited += 1
                }
            }
        }
    }

    /// Ayarlar ekranındaki "bağlantıyı sına" düğmesi.
    func testConnection() async -> String {
        do {
            let info = try await drive.diagnose()
            var lines = ["Bağlantı tamam. Klasör hazır: “\(info.folderName)” (kimlik \(info.folderID.prefix(8)))."]
            lines.append("İstemci kimliği: \(DriveClient.clientTag(settings.googleClientID)). Windows programında da AYNI kimlik girilmeli; farklıysa iki program birbirinin PDF’lerini göremez.")
            if info.folders > 1 {
                lines.append("Dikkat: bu kimlikle aynı adlı \(info.folders) klasör görünüyor; en eskisi kullanılıyor. Diğerlerini Drive’dan silin.")
            }
            if info.pdfs.isEmpty {
                lines.append("Klasörde henüz PDF görünmüyor. PDF’ler bu uygulamayla ya da AYNI Google kimliğiyle çalışan Windows programıyla yüklenmeli; Drive’da elle açılan klasör ve elle atılan dosyalar görünmez.")
            } else {
                lines.append("Klasörde \(info.pdfs.count) PDF görünüyor (Gemini bunları okur): " + info.pdfs.prefix(3).map { $0.name }.joined(separator: ", "))
            }
            return lines.joined(separator: "\n")
        } catch {
            return error.localizedDescription
        }
    }
}
