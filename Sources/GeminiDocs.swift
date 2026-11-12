import Foundation

/// Belge kaynağı (sohbet mantığı sahte kaynakla sınanabilsin diye)
protocol GeminiDocProviding: AnyObject {
    /// En yeni belgeler önce. notes: kullanıcıya söylenecek uyarılar (atlanan belge, PDF yok…)
    func fetch(count: Int) async throws -> (docs: [GeminiDoc], notes: [String])
}

/// Belge klasöründeki PDF kaynağı (sohbet mantığı sahte kaynakla sınanabilsin diye)
protocol GeminiFileSource: AnyObject {
    func listPDFs(count: Int) async throws -> [StoredFileInfo]
    func download(fileID: String) async throws -> Data
}

/// Belge klasöründeki son PDF'leri okuyup önbelleğe alır; aynı dosya (kimlik + boyut) yeniden indirilmesin diye önbelleğe koyar.
/// En yeni belgelerden başlayıp toplam `maxPages` sayfaya kadar alır; sayfa sayıları diskte tutulur (her soruda yeniden okunmaz).
/// 500 sayfalık set belleğe doldurulmaz: belgeler dosya adresiyle ve gerektiğinde okunur.
final class GeminiDocStore: GeminiDocProviding, @unchecked Sendable {
    static let workers = 6
    static let pageIndexKeep = 3000

    private let source: GeminiFileSource
    private let cacheDirectory: URL
    private let keep: Int
    private let maxPages: Int

    init(source: GeminiFileSource, cacheDirectory: URL? = nil, keep: Int = GeminiConfig.maxPages + 100,
         maxPages: Int = GeminiConfig.maxPages) {
        self.source = source
        self.cacheDirectory = cacheDirectory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("gemini-belge", isDirectory: true)
        self.keep = keep
        self.maxPages = maxPages
    }

    private func cacheURL(_ id: String) -> URL {
        let safe = String(id.unicodeScalars.map { scalar -> Character in
            let c = Character(scalar)
            return (c.isASCII && (c.isLetter || c.isNumber)) || c == "_" || c == "-" ? c : "_"
        })
        return cacheDirectory.appendingPathComponent(safe + ".pdf")
    }

    private var pagesURL: URL { return cacheDirectory.appendingPathComponent("sayfalar.json") }

    private func pkey(_ file: StoredFileInfo) -> String { return "\(file.id):\(file.size)" }

    private func cached(_ file: StoredFileInfo) -> Data? {
        let url = cacheURL(file.id)
        guard file.size > 0, let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count == file.size else { return nil }
        return data
    }

    private func store(_ data: Data, id: String) {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: cacheURL(id), options: .atomic)
    }

    private func trim() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: cacheDirectory.path) else { return }
        let pdfs = names.filter { $0.hasSuffix(".pdf") }
        guard pdfs.count > keep else { return }
        let dated = pdfs.map { name -> (Date, String) in
            let path = cacheDirectory.appendingPathComponent(name).path
            let attributes = (try? fm.attributesOfItem(atPath: path)) ?? [:]
            return ((attributes[.modificationDate] as? Date) ?? Date.distantPast, name)
        }.sorted { $0.0 < $1.0 }
        for (_, name) in dated.prefix(pdfs.count - keep) {
            try? fm.removeItem(at: cacheDirectory.appendingPathComponent(name))
        }
    }

    private func loadPages() -> [String: Int] {
        guard let data = try? Data(contentsOf: pagesURL),
              let obj = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
        return obj
    }

    private func savePages(_ index: [String: Int], order: [String]) {
        var kept = index
        if kept.count > GeminiDocStore.pageIndexKeep {
            // en yeni listedekiler kalsın, kalanlardan rastgele fazlalık atılsın
            let protected = Set(order)
            for key in kept.keys where !protected.contains(key) && kept.count > GeminiDocStore.pageIndexKeep { kept[key] = nil }
        }
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(kept) { try? data.write(to: pagesURL, options: .atomic) }
    }

    /// Belge baytları: önbellekteyse oradan, değilse belge klasöründen okuyup önbelleğe yazar
    private func bytes(_ file: StoredFileInfo) async throws -> Data {
        if let data = cached(file) { return data }
        try Task.checkCancellation()
        let data = try await source.download(fileID: file.id)
        store(data, id: file.id)
        return data
    }

    /// Sayfa sayısı bilinmeyen PDF'leri paralel indirir ve sayar
    private func countMissing(_ todo: [StoredFileInfo]) async throws -> [String: Int] {
        var found: [String: Int] = [:]
        var failure: Error?
        var cursor = 0
        var running = 0
        await withTaskGroup(of: (String, Int?, Error?).self) { group in
            while cursor < todo.count || running > 0 {
                while failure == nil && running < GeminiDocStore.workers && cursor < todo.count {
                    let file = todo[cursor]
                    cursor += 1
                    running += 1
                    group.addTask { [self] in
                        do {
                            let data = try await bytes(file)
                            return (pkey(file), GeminiSupport.countPages(data, size: file.size), nil)
                        } catch {
                            return (pkey(file), nil, error)
                        }
                    }
                }
                if running == 0 { break }
                guard let result = await group.next() else { break }
                running -= 1
                if let pages = result.1 {
                    found[result.0] = pages
                } else if failure == nil {
                    failure = result.2
                }
            }
        }
        if let failure = failure { throw failure }
        return found
    }

    func fetch(count: Int) async throws -> (docs: [GeminiDoc], notes: [String]) {
        let listing = try await source.listPDFs(count: count)
        if listing.isEmpty {
            return ([], ["Belge klasöründe PDF bulunamadı. Ayarlardan belge klasörünü seçtiğinizden ve taramayı bitirip PDF yaptırdığınızdan emin olun."])
        }
        return try await build(listing)
    }

    /// Verilen PDF'lerin belgeleri, verilen sırayla (deneme sınavı: tarama sırası; Belge 1 ilk taranandır)
    func docs(for files: [StoredFileInfo]) async throws -> (docs: [GeminiDoc], notes: [String]) {
        if files.isEmpty { return ([], ["Gönderilmiş belge bulunamadı."]) }
        return try await build(files)
    }

    private func build(_ listing: [StoredFileInfo]) async throws -> (docs: [GeminiDoc], notes: [String]) {
        var index = loadPages()
        let todo = listing.filter { index[pkey($0)] == nil }
        if !todo.isEmpty {
            tlog("[belge] \(todo.count) belgenin sayfa sayısı için okunuyor")
            let found = try await countMissing(todo)
            for (k, v) in found { index[k] = v }
            trim()
            savePages(index, order: listing.map { pkey($0) })
        }
        var notes: [String] = []
        var docs: [GeminiDoc] = []
        var used = 0
        for (i, file) in listing.enumerated() {
            let pages = max(1, index[pkey(file)] ?? 1)
            if used + pages > maxPages {
                notes.append("\(listing.count - i) belge \(maxPages) sayfa sınırı nedeniyle atlandı.")
                break
            }
            docs.append(GeminiDoc(name: file.name, fileURL: cacheURL(file.id), size: file.size, pages: pages,
                                  key: "d:" + pkey(file), loader: { [self] in try await bytes(file) }))
            used += pages
        }
        return (docs, notes)
    }
}
