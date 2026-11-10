import Foundation
import CryptoKit

/// Sohbetin kullandığı hafıza arayüzü (sahte hafızayla sınanabilsin diye).
@MainActor
protocol GeminiMemoryProviding: AnyObject {
    /// Hafıza bu belge seti için kullanılacak mı (kapalıysa ya da set küçükse false)
    func wanted(_ docs: [GeminiDoc]) -> Bool
    /// Belgeleri Gemini'ye yükler; oturumdaysa açık önbellek kurar. Dönüş: uri atanmış belgeler ve önbellek adı ("" = yok).
    func prepare(_ docs: [GeminiDoc], session: Bool, progress: @escaping (Int, Int) -> Void) async throws -> (docs: [GeminiDoc], cache: String)
    /// Yalnız eksik belgeleri yükler (önbelleğe dokunmaz)
    func upload(_ docs: [GeminiDoc], progress: @escaping (Int, Int) -> Void) async throws -> [GeminiDoc]
    /// Bir istek dosya/önbellek yüzünden reddedilince: Gemini'de kaybolan dosyaların eşlemesini siler
    func revalidate(_ docs: [GeminiDoc]) async -> (docs: [GeminiDoc], lost: Int)
    func dropCache() async
    /// Oturum bitti: önbelleği sil (saklama ücreti işlemesin)
    func release() async
}

/// Belgeleri Gemini'nin "hafızasına" koyar.
/// 1) Files API: her PDF Gemini'ye BİR KEZ yüklenir (48 saat saklanır); eşleme diskte tutulur, uygulama kapanıp açılsa da yeniden yüklenmez.
///    Dosyalar API anahtarının projesine aittir: anahtar değişirse eşleme ayrı tutulur.
/// 2) Açık önbellek (cachedContents): oturum boyunca belgeler + sistem yönergesi önbellekte durur, her soruda yalnız soru gider.
/// Herhangi bir adım başarısız olursa sohbet belgeleri eski yöntemle (inline) göndermeye döner.
@MainActor
final class GeminiMemory: GeminiMemoryProviding {
    struct Entry: Codable, Equatable {
        var name: String
        var uri: String
        var at: Double
    }

    static let workers = 4
    /// Bundan eski eşleme kullanılmadan önce Gemini'ye sorulur
    static let verifyAfter: Double = 12 * 3600

    private let remote: GeminiRemote
    private let indexURL: URL
    private let enabled: () -> Bool
    private let now: () -> Double
    private var cacheName = ""
    private var cacheSignature = ""

    init(remote: GeminiRemote, indexURL: URL? = nil, enabled: @escaping () -> Bool = { true },
         now: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.remote = remote
        self.enabled = enabled
        self.now = now
        if let url = indexURL {
            self.indexURL = url
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            self.indexURL = base.appendingPathComponent("gemini-dosyalar.json")
        }
    }

    // MARK: Yardımcılar

    nonisolated static func fingerprint(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private func key(_ doc: GeminiDoc) -> String {
        if !doc.key.isEmpty { return doc.key }
        let digest = SHA256.hash(data: doc.data)
        return "h:" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func loadIndex() -> [String: [String: Entry]] {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode([String: [String: Entry]].self, from: data) else { return [:] }
        return index
    }

    private func saveIndex(_ index: [String: [String: Entry]]) {
        let limit = now() - 48 * 3600
        var clean: [String: [String: Entry]] = [:]
        for (fp, entries) in index {
            let alive = entries.filter { $0.value.at > limit }
            if !alive.isEmpty { clean[fp] = alive }
        }
        if let data = try? JSONEncoder().encode(clean) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    // MARK: Arayüz

    func wanted(_ docs: [GeminiDoc]) -> Bool {
        guard !docs.isEmpty, enabled() else { return false }
        let pages = docs.reduce(0) { $0 + $1.pageEstimate }
        let size = docs.reduce(0) { $0 + $1.size }
        return pages >= GeminiConfig.memoryMinPages || size > GeminiConfig.inlineBudget
    }

    func prepare(_ docs: [GeminiDoc], session: Bool, progress: @escaping (Int, Int) -> Void) async throws -> (docs: [GeminiDoc], cache: String) {
        let uploaded = try await upload(docs, progress: progress)
        if session {
            return (uploaded, await ensureCache(uploaded))
        }
        await dropCache()
        return (uploaded, "")
    }

    func upload(_ docs: [GeminiDoc], progress: @escaping (Int, Int) -> Void) async throws -> [GeminiDoc] {
        var list = docs
        let fp = remote.keyFingerprint
        var index = loadIndex()
        var entries = index[fp] ?? [:]
        let current = now()
        var todo: [Int] = []
        var stale: [Int] = []
        for i in list.indices {
            let k = key(list[i])
            if let e = entries[k], current - e.at < GeminiConfig.fileKeepSeconds {
                list[i].uri = e.uri
                list[i].remote = e.name
                if current - e.at > GeminiMemory.verifyAfter { stale.append(i) }
            } else {
                todo.append(i)
            }
        }
        for i in stale {
            // try? iç içe Optional'ı düzleştirir: erişim hatası da "yok" sayılır ve dosya yeniden yüklenir
            let info = try? await remote.getFile(name: list[i].remote)
            if let file = info, file.state == "ACTIVE" { continue }
            list[i].uri = ""
            list[i].remote = ""
            todo.append(i)
        }
        let total = todo.count
        guard total > 0 else { return list }
        tlog("[hafıza] \(total) belge Gemini'ye yükleniyor")

        let items = todo.map { (index: $0, doc: list[$0]) }
        let remote = self.remote
        var cursor = 0
        var running = 0
        var done = 0
        var failure: Error?
        await withTaskGroup(of: (Int, RemoteFile?, Error?).self) { group in
            while cursor < items.count || running > 0 {
                while failure == nil && running < GeminiMemory.workers && cursor < items.count {
                    let item = items[cursor]
                    cursor += 1
                    running += 1
                    group.addTask {
                        do {
                            let data = try await item.doc.load()
                            if data.isEmpty { throw GeminiError("Belge okunamadı: \(item.doc.name)", .error) }
                            var file = try await remote.uploadFile(name: item.doc.name, data: data)
                            file = try await remote.waitActive(file)
                            return (item.index, file, nil)
                        } catch {
                            return (item.index, nil, error)
                        }
                    }
                }
                if running == 0 { break }
                guard let result = await group.next() else { break }
                running -= 1
                if let file = result.1 {
                    list[result.0].uri = file.uri
                    list[result.0].remote = file.name
                    entries[key(list[result.0])] = Entry(name: file.name, uri: file.uri, at: now())
                    done += 1
                    progress(done, total)
                } else if failure == nil {
                    failure = result.2
                }
            }
        }
        index[fp] = entries
        saveIndex(index)
        if let failure = failure { throw failure }
        return list
    }

    func revalidate(_ docs: [GeminiDoc]) async -> (docs: [GeminiDoc], lost: Int) {
        var list = docs
        var lost = 0
        let fp = remote.keyFingerprint
        var index = loadIndex()
        var entries = index[fp] ?? [:]
        for i in list.indices where !list[i].uri.isEmpty {
            do {
                if let file = try await remote.getFile(name: list[i].remote), file.state == "ACTIVE" { continue }
            } catch {
                continue                     // erişim hatası (kota, ağ): dosyanın kaybolduğu kanıtlanmadı
            }
            entries[key(list[i])] = nil
            list[i].uri = ""
            list[i].remote = ""
            lost += 1
        }
        if lost > 0 {
            index[fp] = entries
            saveIndex(index)
            tlog("[hafıza] \(lost) dosya Gemini'de bulunamadı, yeniden yüklenecek")
        }
        return (list, lost)
    }

    // MARK: Açık önbellek

    private func signature(_ docs: [GeminiDoc]) -> String {
        let text = ([remote.cacheIdentity] + docs.map { key($0) }).joined(separator: "|")
        return GeminiMemory.fingerprint(text)
    }

    private func ensureCache(_ docs: [GeminiDoc]) async -> String {
        let pages = docs.reduce(0) { $0 + $1.pageEstimate }
        if pages * GeminiConfig.tokensPerPage < GeminiConfig.cacheMinTokens || !GeminiSupport.allRemote(docs) { return "" }
        let sig = signature(docs)
        if !cacheName.isEmpty && sig == cacheSignature {
            do {
                try await remote.touchCache(cacheName)
                return cacheName
            } catch {
                tlog("[hafıza] önbellek uzatılamadı (\(error.localizedDescription)), yenisi kuruluyor")
            }
        }
        await dropCache()
        do {
            cacheName = try await remote.createCache(docs: docs)
            cacheSignature = sig
            tlog("[hafıza] önbellek kuruldu: \(cacheName) (\(pages) sayfa)")
            return cacheName
        } catch {
            tlog("[hafıza] önbellek kurulamadı, belgeler dosya adresiyle gönderilecek: \(error.localizedDescription)")
            cacheName = ""
            cacheSignature = ""
            return ""
        }
    }

    func dropCache() async {
        let name = cacheName
        cacheName = ""
        cacheSignature = ""
        if !name.isEmpty { await remote.deleteCache(name) }
    }

    func release() async {
        await dropCache()
    }
}
