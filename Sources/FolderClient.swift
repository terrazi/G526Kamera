import Foundation

extension String {
    var trimmed: String { return trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Kaydedilecek içerik: tek bir JPEG dosyası ya da bir veya birkaç JPEG'den yapılan PDF.
enum UploadPayload {
    case jpeg(URL)
    case pdf([URL], title: String)
    /// Düz metin dosyası (deneme sınavı cevap anahtarı): PDF olmadığı için Gemini belge sohbetine karışmaz
    case text(URL)
    /// Kısa video (H.264 MP4); dosya olduğu gibi kaydedilir
    case video(URL)

    /// Belge klasöründeki dosya uzantısı
    var ext: String {
        switch self {
        case .jpeg: return "jpg"
        case .pdf: return "pdf"
        case .text: return "txt"
        case .video: return "mp4"
        }
    }
}

/// Bir PDF'in özeti (belge klasöründeki dosya; kimlik = dosya adı)
struct StoredFileInfo: Equatable {
    let id: String
    let name: String
    let size: Int
    let created: String
}

/// Dosyaları kullanıcının seçtiği tek belge klasörüne ("G526 Belgeler") kaydeder; oradaki PDF'leri listeler ve okur.
/// Hiçbir ağ bağlantısı gerekmez. Dosya adı: kaydedilme anı (yyyyMMddHHmmss), çakışırsa -2, -3.
final class FolderClient: GeminiFileSource, @unchecked Sendable {
    private let folder: DocumentFolder

    init(folder: DocumentFolder = .shared) {
        self.folder = folder
    }

    /// Klasör seçilmiş mi
    var isReady: Bool { return folder.hasChoice }

    /// İçeriği klasöre kaydeder; dosya adını (kimlik) ve boyutunu döndürür. Ağ işi yok; ana iş parçacığı kullanılmaz.
    func save(_ payload: UploadPayload, date: Date = Date()) async throws -> (id: String, size: Int) {
        let target = folder
        return try await Task.detached(priority: .utility) {
            try FolderClient.write(payload, to: target, date: date)
        }.value
    }

    /// PDF uygulamanın geçici klasöründe sayfa sayfa yazılır (bellekte tüm görüntüler tutulmaz), sonra tek hamlede klasöre konur.
    static func write(_ payload: UploadPayload, to folder: DocumentFolder, date: Date) throws -> (id: String, size: Int) {
        let fm = FileManager.default
        let source: URL
        var temporary: URL?
        switch payload {
        case .pdf(let files, let title):
            let tmp = fm.temporaryDirectory.appendingPathComponent("g526-kaydet-\(UUID().uuidString).pdf")
            fm.createFile(atPath: tmp.path, contents: nil)
            let handle = try FileHandle(forWritingTo: tmp)
            do {
                try PDFWrap.write(jpegs: files, title: title, to: handle)
                try handle.close()
            } catch {
                try? handle.close()
                try? fm.removeItem(at: tmp)
                throw error
            }
            source = tmp
            temporary = tmp
        case .jpeg(let file), .text(let file), .video(let file):
            source = file
        }
        defer { if let tmp = temporary { try? fm.removeItem(at: tmp) } }
        let attributes = (try? fm.attributesOfItem(atPath: source.path)) ?? [:]
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let stored = try folder.store(file: source, ext: payload.ext, date: date)
        return (id: stored.lastPathComponent, size: size)
    }

    /// Ad sırası anahtarı: "20261112091245.pdf" < "20261112091245-2.pdf" < "20261112091246.pdf" (aynı saniyedeki -2, -3 sonradan yazılmıştır)
    static func sortKey(_ name: String) -> (stamp: String, number: Int) {
        let stem = (name as NSString).deletingPathExtension
        if let dash = stem.lastIndex(of: "-"), let number = Int(stem[stem.index(after: dash)...]) {
            return (String(stem[..<dash]), number)
        }
        return (stem, 1)
    }

    /// a adlı dosya b'den sonra mı kaydedilmiş
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = sortKey(a), y = sortKey(b)
        return x.stamp != y.stamp ? x.stamp > y.stamp : x.number > y.number
    }

    /// Listeden istenecek PDF sayısı (Gemini ayarındaki belge sayısı, en çok 50)
    static func listPageSize(_ count: Int) -> Int {
        return min(max(count, 1), 50)
    }

    /// Klasördeki en yeni PDF'ler (yeniden eskiye; adlar zaman damgası olduğundan ad sırası zaman sırasıdır)
    func listPDFs(count: Int) async throws -> [StoredFileInfo] {
        let limit = FolderClient.listPageSize(count)
        let target = folder
        return try await Task.detached(priority: .utility) {
            try target.withAccess { dir in
                let urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])
                let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
                    .sorted { FolderClient.isNewer($0.lastPathComponent, than: $1.lastPathComponent) }
                    .prefix(limit)
                return pdfs.map { url -> StoredFileInfo in
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    return StoredFileInfo(id: url.lastPathComponent, name: url.lastPathComponent, size: size, created: "")
                }
            }
        }.value
    }

    /// Dosyanın içeriğini okur (kimlik = klasördeki dosya adı)
    func download(fileID: String) async throws -> Data {
        let target = folder
        let name = (fileID as NSString).lastPathComponent
        return try await Task.detached(priority: .utility) {
            try target.withAccess { dir in
                let url = dir.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw DocumentFolderError(message: "Belge klasöründe \(name) bulunamadı.")
                }
                return try Data(contentsOf: url)
            }
        }.value
    }
}
