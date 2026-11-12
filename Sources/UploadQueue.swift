import Foundation

/// Çekilen fotoğrafları diske yazar ve belge klasörüne ("G526 Belgeler") PDF/JPEG olarak kaydeder. Klasör seçilmemişse kuyrukta bekler,
/// uygulama kapansa bile kaybolmaz; başarısız kayıtlar artan aralıklarla yeniden denenir.
/// Gönderme biçimi ayarlardan seçilir: tek tek (her fotoğraf hemen) ya da toplu (biriksin, birlikte gitsin);
/// dosya türü PDF (JPEG yeniden işlenmeden sarılır) ya da JPEG olabilir.
@MainActor
final class UploadQueue: ObservableObject {
    static let shared = UploadQueue()

    @Published private(set) var pending = 0
    @Published private(set) var uploaded = 0
    /// Bu oturumda klasöre kaydedilen dosya (PDF ya da JPEG) sayısı
    @Published private(set) var uploadedDocs = 0
    @Published private(set) var status = ""
    @Published private(set) var lastError = ""

    private let fm = FileManager.default
    private let settings = AppSettings.shared
    private let pendingDir: URL
    private let folder = FolderClient()
    private var worker: Task<Void, Never>?
    private var retryNow = false
    private var flush = false        // "şimdi gönder" istendi
    private var draining = false     // toplu gönderim başladı: kuyruk boşalana kadar sürer
    private var lastEnqueue = Date.distantPast
    private var failures = 0
    private var captureLog = CaptureLog()
    private var inFlight = Set<String>()
    /// Deneme sınavı taraması: fotoğraflar gönderilmeden birikir
    private(set) var examHold = false
    /// Deneme sınavı: dosyalar ayardan bağımsız olarak PDF'e çevrilip toplu gönderilir
    private(set) var examMode = false
    /// Klasöre kaydedilen PDF'ler (eskiden yeniye; diskte tutulur, en çok 200)
    private(set) var sentLog: [ExamSentFile] = []
    private let sentLogURL: URL
    /// Art arda başarısız yükleme sayısı
    var failureCount: Int { return failures }

    init() {
        let manager = FileManager.default
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let pendingURL = support.appendingPathComponent("G526/Bekleyen", isDirectory: true)
        try? manager.createDirectory(at: pendingURL, withIntermediateDirectories: true)
        pendingDir = pendingURL
        sentLogURL = support.appendingPathComponent("G526/gonderilenler.json")
        if let data = try? Data(contentsOf: sentLogURL),
           let list = try? JSONDecoder().decode([ExamSentFile].self, from: data) {
            sentLog = list
        }
        pending = pendingFiles().count
        status = pending > 0 ? "\(pending) fotoğraf kaydedilmeyi bekliyor" : ""
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
        while fm.fileExists(atPath: pendingDir.appendingPathComponent(name).path) {
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
            pending = pendingFiles().count
            status = pending > 0 ? "\(pending) fotoğraf kaydedilmeyi bekliyor" : ""
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

    /// Gemini'ye sormadan önce: biriken (toplu modda bekleyen) fotoğrafları şimdi klasöre kaydeder ve bitmesini bekler.
    /// En fazla `timeout` sn bekler; art arda 2 yeni hata olursa vazgeçer. Hâlâ kaydedilmeyen sayıyı döndürür.
    func flushAndWait(timeout: TimeInterval = 90, aborted: () -> Bool = { false }) async -> Int {
        guard !pendingFiles().isEmpty, folder.isReady else {
            pending = pendingFiles().count
            return pending
        }
        let failuresAtStart = failures
        retry()
        let end = Date().addingTimeInterval(max(0, timeout))
        while Date() < end && !Task.isCancelled && !aborted() {
            if pendingFiles().isEmpty { break }
            if failures >= failuresAtStart + 2 { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        pending = pendingFiles().count
        return pending
    }

    // MARK: Deneme sınavı

    /// Deneme sınavı taramasında fotoğraflar gönderilmeden birikir (hold); exam: PDF'e çevrilip toplu gönderilir
    func setExam(hold: Bool, exam: Bool) {
        examHold = hold
        examMode = exam
        if !hold { kick() }
    }

    /// Gönderilmeyi bekleyen fotoğraf adları (eskiden yeniye)
    func pendingNames() -> [String] {
        return pendingFiles().map { $0.lastPathComponent }
    }

    /// Bekleyen belirli bir fotoğrafı (ve OCR metnini) siler; yüklenmekte olansa ya da yoksa false
    func removePending(_ name: String) -> Bool {
        guard !inFlight.contains(name) else { return false }
        let url = pendingDir.appendingPathComponent(name)
        guard fm.fileExists(atPath: url.path) else { return false }
        OcrCenter.shared.forget(url)
        remove(url)
        captureLog.forget(name)
        pending = pendingFiles().count
        status = pending > 0 ? "\(pending) fotoğraf kaydedilmeyi bekliyor" : ""
        tlog("[kuyruk] silindi: \(name)")
        return true
    }

    /// since'ten (Unix saniyesi) sonra klasöre kaydedilen PDF'ler, eskiden yeniye
    func sent(since: Double) -> [ExamSentFile] {
        return sentLog.filter { $0.time >= since }
    }

    private func recordSent(id: String, name: String, size: Int, photos: Int) {
        guard !id.isEmpty else { return }
        sentLog.append(ExamSentFile(id: id, name: name, size: size, photos: photos, time: Date().timeIntervalSince1970))
        if sentLog.count > 200 { sentLog.removeFirst(sentLog.count - 200) }
        if let data = try? JSONEncoder().encode(sentLog) {
            try? data.write(to: sentLogURL, options: .atomic)
        }
    }

    /// Deneme sınavında dosyalar PDF olarak gider
    private var usePDF: Bool { return settings.uploadFormat == "pdf" || examMode }

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
        if !usePDF {
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
                status = uploaded > 0 ? "Tüm fotoğraflar klasöre kaydedildi" : ""
                return
            }
            if examHold {
                status = "Deneme sınavı: \(files.count) sayfa tarandı, gönderim bekletiliyor"
                return
            }
            guard folder.isReady else {
                status = "Belge klasörü seçilmedi — \(files.count) fotoğraf bekliyor"
                return
            }

            let batch = settings.sendMode == "batch" || examMode
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

            status = "Kaydediliyor… (\(files.count) bekliyor)"
            retryNow = false
            if settings.ocrEnabled && usePDF {
                let count = batch ? (settings.batchSize > 0 ? settings.batchSize : 30) : 1
                let group = Array(files.prefix(count))
                if group.contains(where: { OcrCenter.shared.isPending($0) }) {
                    status = "Metin okunuyor (OCR)…"
                    await OcrCenter.shared.waitFor(group, timeout: OcrCenter.shared.uploadWait)
                }
            }
            guard let job = prepareJob(files: files, batch: batch) else {
                try? await Task.sleep(nanoseconds: 500_000_000)   // hepsi bozuktu/taşınamadı: ana iş parçacığını meşgul etmesin
                continue
            }
            inFlight = Set(job.files.map { $0.lastPathComponent })
            defer { inFlight = [] }
            do {
                let result = try await folder.save(job.payload)
                for file in job.files { remove(file) }
                uploaded += job.files.count
                uploadedDocs += 1
                recordSent(id: result.id, name: job.name, size: result.size, photos: job.files.count)
                DailyStatsStore.shared.recordSent(photos: job.files.count, docs: 1)
                failures = 0
                lastError = ""
                tlog("[klasör] kaydedildi: \(result.id) (\(job.files.count) fotoğraf)")
                if pendingFiles().isEmpty { draining = false }
            } catch {
                inFlight = []
                failures += 1
                lastError = error.localizedDescription
                let wait = min(5.0 * pow(2.0, Double(failures - 1)), 300.0)
                tlog("[klasör] kaydetme hatası: \(lastError)")
                if !folder.isReady {
                    status = "Belge klasörü seçilmedi — \(files.count) fotoğraf bekliyor"
                    return
                }
                var waited = 0.0
                while waited < wait && !retryNow && !Task.isCancelled {
                    status = "Kaydedilemedi (\(lastError)) — \(Int(wait - waited)) sn sonra yeniden"
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    waited += 1
                }
            }
        }
    }
}
