import Foundation

/// Uygulama içi günlük. "Tanı" ekranında görünür; Mac olmadan hata ayıklamayı sağlar.
/// Satırlar ayrıca dosyaya yazılır: uygulama beklenmedik kapanırsa bir sonraki açılışta önceki çalışmanın günlüğü taranıp nedeni anlaşılır
/// (`previousRun`, `ExitAnalyzer`). Dosya şişmesin diye eski satırlar kırpılır.
final class AppLog: ObservableObject {
    static let shared = AppLog()

    /// Her çalışmanın ilk satırı; önceki çalışmanın günlüğü bu satırdan başlar
    static let startMarker = "=== AÇILIŞ"

    @Published private(set) var lines: [String] = []
    /// Önceki çalışmanın günlüğü (dosyadan okunur; bu çalışmanın satırları buna karışmaz)
    let previousRun: [String]

    private let maxLines = 500
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private let file: URL?
    private let queue = DispatchQueue(label: "sesli-kontrol.gunluk")
    private var handle: FileHandle?
    /// Dosya bu boyutu aşarsa en yeni yarısı korunur
    private static let maxBytes = 400_000

    init(file: URL? = AppLog.defaultFile()) {
        self.file = file
        var previous: [String] = []
        if let file = file {
            let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            var all = existing.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            if existing.utf8.count > AppLog.maxBytes {
                all = Array(all.suffix(all.count / 2))
                try? (all.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
            }
            previous = AppLog.lastRun(in: all)
        }
        previousRun = previous
        let stamp = ISO8601DateFormatter().string(from: Date())
        write("\(AppLog.startMarker) \(stamp) ===")
    }

    /// Dosyadaki satırların son çalışma bloğu (son açılış işaretinden sonrası; işaret yoksa hepsi)
    static func lastRun(in lines: [String]) -> [String] {
        guard let index = lines.lastIndex(where: { $0.hasPrefix(startMarker) }) else { return lines }
        return Array(lines[index...])
    }

    static func defaultFile() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = base.appendingPathComponent("SesliKontrol", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("gunluk.txt")
    }

    func log(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)"
        write(line)
        DispatchQueue.main.async {
            self.lines.append(line)
            if self.lines.count > self.maxLines {
                self.lines.removeFirst(self.lines.count - self.maxLines)
            }
        }
        #if DEBUG
        print(line)
        #endif
    }

    func clear() {
        DispatchQueue.main.async { self.lines.removeAll() }
    }

    /// Dosyadaki son satırlar: önceki çalışmaların sonu ve bu çalışma, açılış işaretleriyle ayrılmış. Uygulama beklenmedik kapanıp yeniden
    /// açıldıysa kapanmanın kanıtı (kalan bellek, ısı, takılma gecikmeleri, son olaylar) önceki çalışmanın sonundadır; ekrandaki liste onu göstermez.
    /// Dosya okunamazsa ekrandaki satırlar döner.
    func recentLines(maxLines: Int) -> [String] {
        flush()
        guard let file = file, let text = try? String(contentsOf: file, encoding: .utf8) else { return Array(lines.suffix(maxLines)) }
        let all = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return Array(all.suffix(maxLines))
    }

    /// Bekleyen satırların dosyaya yazılmasını bekler (uygulama kendini kapatmadan önce)
    func flush() {
        queue.sync { }
    }

    private func write(_ line: String) {
        guard let file = file else { return }
        queue.async { [weak self] in
            guard let self = self, let data = (line + "\n").data(using: .utf8) else { return }
            if self.handle == nil {
                if !FileManager.default.fileExists(atPath: file.path) {
                    FileManager.default.createFile(atPath: file.path, contents: nil)
                }
                self.handle = try? FileHandle(forWritingTo: file)
                _ = try? self.handle?.seekToEnd()
            }
            try? self.handle?.write(contentsOf: data)
        }
    }
}

func tlog(_ message: String) {
    AppLog.shared.log(message)
}
