import Foundation

/// Modül 5 ve 6: cevap sesleri cihazın içinde, o güne ait bir klasöre kaydedilir (soru_1, soru_2, …).
/// Klasör uygulamanın Belgeler dizinindedir; Dosyalar uygulamasında "Bu iPhone > G526 Ses" altında görünür.
struct AnswerLibrary {
    static let transcriptName = "cevaplar.txt"
    static let audioExtensions: Set<String> = ["m4a", "caf", "mp3", "wav", "aac"]

    let root: URL
    private let fileManager: FileManager

    init(root: URL = AnswerLibrary.documentsDirectory, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    static var documentsDirectory: URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    // MARK: Klasör adları

    /// "2026-11-13"
    static func folderName(for date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// "2026-11-13" → (gün, 1); "2026-11-13_2" → (gün, 2); başka ad nil
    static func parseFolderName(_ name: String) -> (day: String, part: Int)? {
        guard name.range(of: "^\\d{4}-\\d{2}-\\d{2}(_\\d+)?$", options: .regularExpression) != nil else { return nil }
        let pieces = name.split(separator: "_", maxSplits: 1).map(String.init)
        let part = pieces.count > 1 ? (Int(pieces[1]) ?? 1) : 1
        return (pieces[0], part)
    }

    /// "soru_12.m4a" → 12
    static func questionNumber(fromFileName name: String) -> Int? {
        let url = URL(fileURLWithPath: name)
        guard audioExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        let stem = url.deletingPathExtension().lastPathComponent
        guard stem.hasPrefix("soru_") else { return nil }
        return Int(stem.dropFirst("soru_".count))
    }

    // MARK: Klasör işlemleri

    /// Yeni oturum için günün klasörünü açar. O gün içinde cevap dosyası olan bir klasör varsa ezilmesin diye "_2", "_3" … açılır.
    func newSessionFolder(for date: Date, calendar: Calendar = .current) throws -> URL {
        let base = AnswerLibrary.folderName(for: date, calendar: calendar)
        var part = 1
        while true {
            let name = part == 1 ? base : "\(base)_\(part)"
            let url = root.appendingPathComponent(name, isDirectory: true)
            if !fileManager.fileExists(atPath: url.path) || answerFiles(in: url).isEmpty {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
                return url
            }
            part += 1
        }
    }

    /// İçinde cevap dosyası olan en yeni gün klasörü (tekrar modu için); yoksa nil
    func latestFolder() -> URL? {
        let names = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        let candidates = names.compactMap { name -> (name: String, key: (String, Int))? in
            guard let parsed = AnswerLibrary.parseFolderName(name) else { return nil }
            return (name, (parsed.day, parsed.part))
        }
        let sorted = candidates.sorted { a, b in
            a.key.0 != b.key.0 ? a.key.0 < b.key.0 : a.key.1 < b.key.1
        }
        for candidate in sorted.reversed() {
            let url = root.appendingPathComponent(candidate.name, isDirectory: true)
            if !answerFiles(in: url).isEmpty { return url }
        }
        return nil
    }

    // MARK: Cevap dosyaları

    /// Soru için dosya yolu, uzantısız ("…/soru_3"); uzantıyı kaydeden belirler
    func fileBase(question number: Int, in folder: URL) -> URL {
        return folder.appendingPathComponent("soru_\(number)")
    }

    /// Aynı numaralı eski kayıtları siler (soru yeniden okunup cevaplanınca çift dosya kalmasın)
    func removeExisting(question number: Int, in folder: URL) {
        for url in answerFiles(in: folder) where AnswerLibrary.questionNumber(fromFileName: url.lastPathComponent) == number {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Klasördeki cevap sesleri, soru numarasına göre sıralı (soru_2, soru_10'dan önce gelir)
    func answerFiles(in folder: URL) -> [URL] {
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        let numbered = names.compactMap { name -> (Int, String)? in
            guard let number = AnswerLibrary.questionNumber(fromFileName: name) else { return nil }
            return (number, name)
        }
        return numbered
            .sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
            .map { folder.appendingPathComponent($0.1) }
    }

    /// Cevapları düz yazı olarak da tutar: sesler silinse de cevaplar okunabilir kalır
    func appendTranscript(_ line: String, in folder: URL) {
        let url = folder.appendingPathComponent(AnswerLibrary.transcriptName)
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}
