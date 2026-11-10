import Foundation

/// Drive'daki bir PDF'in özeti
struct DriveFileInfo: Equatable {
    let id: String
    let name: String
    let size: Int
    let created: String
}

/// Belge kaynağı (sohbet mantığı sahte kaynakla sınanabilsin diye)
protocol GeminiDocProviding: AnyObject {
    /// En yeni belgeler önce. notes: kullanıcıya söylenecek uyarılar (atlanan belge, PDF yok…)
    func fetch(count: Int) async throws -> (docs: [GeminiDoc], notes: [String])
}

protocol GeminiDriveSource: AnyObject {
    func listPDFs(count: Int) async throws -> [DriveFileInfo]
    func download(fileID: String) async throws -> Data
}

extension DriveClient: GeminiDriveSource {}

/// Drive'daki son PDF'leri indirir; aynı dosya (kimlik + boyut) yeniden indirilmesin diye önbelleğe koyar.
final class GeminiDocStore: GeminiDocProviding {
    private let source: GeminiDriveSource
    private let cacheDirectory: URL
    private let keep: Int
    private let budget: Int

    init(source: GeminiDriveSource, cacheDirectory: URL? = nil, keep: Int = 40, budget: Int = GeminiConfig.inlineBudget) {
        self.source = source
        self.cacheDirectory = cacheDirectory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("gemini-belge", isDirectory: true)
        self.keep = keep
        self.budget = budget
    }

    private func cacheURL(_ id: String) -> URL {
        let safe = String(id.unicodeScalars.map { scalar -> Character in
            let c = Character(scalar)
            return (c.isASCII && (c.isLetter || c.isNumber)) || c == "_" || c == "-" ? c : "_"
        })
        return cacheDirectory.appendingPathComponent(safe + ".pdf")
    }

    private func cached(_ file: DriveFileInfo) -> Data? {
        let url = cacheURL(file.id)
        guard file.size > 0, let data = try? Data(contentsOf: url), data.count == file.size else { return nil }
        return data
    }

    private func store(_ data: Data, id: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: cacheURL(id), options: .atomic)
        guard let names = try? fm.contentsOfDirectory(atPath: cacheDirectory.path), names.count > keep else { return }
        let dated = names.map { name -> (Date, String) in
            let path = cacheDirectory.appendingPathComponent(name).path
            let attributes = (try? fm.attributesOfItem(atPath: path)) ?? [:]
            let date = (attributes[.modificationDate] as? Date) ?? Date.distantPast
            return (date, name)
        }.sorted { $0.0 < $1.0 }
        for (_, name) in dated.prefix(names.count - keep) {
            try? fm.removeItem(at: cacheDirectory.appendingPathComponent(name))
        }
    }

    func fetch(count: Int) async throws -> (docs: [GeminiDoc], notes: [String]) {
        let listing = try await source.listPDFs(count: count)
        if listing.isEmpty {
            return ([], ["Drive klasöründe PDF bulunamadı. Belgeler bu uygulamayla ve aynı Google kimliğiyle PDF olarak yüklenmiş olmalı; Drive’da elle açılan klasör ya da elle atılan dosyalar görünmez."])
        }
        let picked = GeminiSupport.selectDocs(listing.map { (name: $0.name, size: $0.size) }, budget: budget)
        var notes: [String] = []
        if !picked.skipped.isEmpty {
            notes.append("\(picked.skipped.count) belge boyut sınırı nedeniyle atlandı.")
        }
        var docs: [GeminiDoc] = []
        for index in picked.chosen {
            let file = listing[index]
            if let data = cached(file) {
                docs.append(GeminiDoc(name: file.name, data: data))
                continue
            }
            try Task.checkCancellation()
            let data = try await source.download(fileID: file.id)
            store(data, id: file.id)
            docs.append(GeminiDoc(name: file.name, data: data))
        }
        return (docs, notes)
    }
}
