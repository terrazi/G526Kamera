import Foundation
import Network

/// Çekilen fotoğrafları diske yazar ve Drive'a sırayla yükler. Bağlantı yoksa kuyrukta bekler,
/// uygulama kapansa bile kaybolmaz; başarısız yüklemeler artan aralıklarla yeniden denenir.
@MainActor
final class UploadQueue: ObservableObject {
    static let shared = UploadQueue()

    @Published private(set) var pending = 0
    @Published private(set) var uploaded = 0
    @Published private(set) var status = ""
    @Published private(set) var lastError = ""

    private let fm = FileManager.default
    private let settings = AppSettings.shared
    private let pendingDir: URL
    private let localDir: URL
    private lazy var drive = DriveClient(auth: GoogleAuth.shared)
    private var worker: Task<Void, Never>?
    private var retryNow = false
    private var failures = 0
    private let monitor = NWPathMonitor()

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
        kick()
        return name
    }

    func retry() {
        retryNow = true
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

    private func run() async {
        while true {
            let files = pendingFiles()
            pending = files.count
            guard let file = files.first else {
                status = uploaded > 0 ? "Tüm fotoğraflar yüklendi" : ""
                return
            }
            guard GoogleAuth.shared.isSignedIn else {
                status = "Drive'a giriş yapılmadı — \(files.count) fotoğraf bekliyor"
                return
            }

            status = "Yükleniyor… (\(files.count) bekliyor)"
            retryNow = false
            do {
                let data = try Data(contentsOf: file)
                try await drive.upload(jpeg: data, name: file.lastPathComponent)
                try? fm.removeItem(at: file)
                uploaded += 1
                failures = 0
                lastError = ""
                tlog("[drive] yüklendi: \(file.lastPathComponent)")
            } catch {
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
            _ = try await drive.ensureFolder()
            return "Bağlantı tamam. Klasör hazır: “\(settings.driveFolderName)”"
        } catch {
            return error.localizedDescription
        }
    }
}
