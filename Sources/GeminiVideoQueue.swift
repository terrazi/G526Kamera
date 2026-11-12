import Foundation

/// Gemini'ye gönderilmeyi bekleyen videolar. Diskte durur (uygulama kapansa da kalır); dosyalar adlarına (tarihli) göre sırayla gider.
/// Video klasöre ayrıca kaydedilir; buradaki kopya (sabit bağ, olmazsa kopya) yalnız Gemini cevabı gelene dek durur.
@MainActor
final class GeminiVideoQueue {
    static let shared = GeminiVideoQueue()

    private let fm = FileManager.default
    let directory: URL

    convenience init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.init(directory: support.appendingPathComponent("G526/GeminiVideoKuyrugu", isDirectory: true))
    }

    init(directory: URL) {
        self.directory = directory
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Bekleyen videolar, eskiden yeniye
    var files: [URL] {
        let urls = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "mp4" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    var count: Int { return files.count }

    /// Videoyu sıraya alır (aynı adlı kayıt varsa yenisi geçer). Dosya boyutu iki katına çıkmasın diye önce sabit bağ denenir.
    @discardableResult
    func add(_ source: URL) -> Bool {
        let target = directory.appendingPathComponent(source.lastPathComponent)
        try? fm.removeItem(at: target)
        if (try? fm.linkItem(at: source, to: target)) != nil { return true }
        return (try? fm.copyItem(at: source, to: target)) != nil
    }

    func remove(_ url: URL) {
        try? fm.removeItem(at: url)
    }
}
