import Foundation
import Combine
import CryptoKit

/// Açılış denetiminin gördüğü kaynak durumu (seçenek kapalıyken hiç sorulmaz)
struct SourceReadiness: Equatable {
    var ok: Bool
    /// Denetim satırının ayrıntısı ("8 kaynak hazır")
    var detail: String
    /// Kırmızı kutuya yazılacak uyarı; sorun yoksa nil
    var warning: String?
}

/// Kaynakları senkronize eden bileşen (kullanıcı isteği 2026-11-20): kayıt klasörünün içindeki "Kaynaklar" klasörü Gemini'deki dosya arama
/// deposuna işlenir. Klasöre konan (ya da değişen) dosya yüklenir, klasörden silinen dosya depodan da silinir; depoda eksilen belge yeniden
/// yüklenir; değişmemiş dosya yeniden gönderilmez. KENDİLİĞİNDEN ÇALIŞMAZ (kullanıcı kararı 2026-11-20: otomatik güncelleme olmasın): yalnız
/// Ayarlar'daki "Dosyaları senkronize et" düğmesiyle çalışır; test sürerken çalışmaz (cevapların yüklemesiyle yarışmasın).
/// "Soruları verilen kaynaklara göre cevapla" kapalıyken hiçbir şey yapmaz.
@MainActor
final class SourceSync: ObservableObject {
    /// Ayarlar ekranındaki durum satırları
    @Published private(set) var lines: [String] = []
    /// Senkron sürerken ne yapıldığı ("yükleniyor 3/8: …"); boşsa senkron sürmüyor
    @Published private(set) var progress = ""
    @Published private(set) var busy = false
    /// Son senkronun raporu ("63 MB boyutunda 8 dosya senkronize edildi…"); senkron yapılmadıysa boş
    @Published private(set) var report: [String] = []

    static let statesKey = "v4.sourceStates"
    /// Google'ın dosyayı işlemesi için son bekleme: 5 sn arayla en çok bu kadar yoklama
    static let settlePolls = 24
    static let settlePause: TimeInterval = 5

    /// Yükleme için süre sınırı: 120 sn + MB başına 10 sn (24 MB ≈ 6 dk; yavaş hücreselde de yetsin)
    static func uploadLimit(bytes: Int) -> TimeInterval {
        return 120 + Double(bytes) / 1_000_000 * 10
    }

    /// Google'ın yüklenen dosyayı parçalayıp dizinlemesi için bekleme: 90 sn + MB başına 8 sn
    static func indexLimit(bytes: Int) -> TimeInterval {
        return 90 + Double(bytes) / 1_000_000 * 8
    }

    /// Anahtarın kendisi saklanmaz: durumlar anahtarın özetiyle (SHA-256'nın ilk 8 baytı) eşlenir
    static func keyID(_ key: String) -> String {
        let digest = SHA256.hash(data: Data(key.trimmed.utf8))
        return Array(digest).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Kullanılabilir profillerin ayrı anahtarları (yuva sırasıyla). Depo anahtarın projesine aittir: her ayrı anahtar kendi deposunu ister.
    static func keyGroups(_ profiles: [GeminiProfileInfo]) -> [(key: String, profiles: [GeminiProfileInfo])] {
        var groups: [(key: String, profiles: [GeminiProfileInfo])] = []
        for profile in GeminiProfiles.usable(profiles) {
            let key = profile.key.trimmed
            if let index = groups.firstIndex(where: { $0.key == key }) {
                groups[index].profiles.append(profile)
            } else {
                groups.append((key: key, profiles: [profile]))
            }
        }
        return groups
    }

    /// Birden çok anahtar varsa durum satırının başına yazılan ad: "1., 2. ve 3. profilin anahtarı"
    static func groupLabel(_ profiles: [GeminiProfileInfo]) -> String {
        let slots = profiles.map { "\($0.slot)." }
        if slots.count <= 1 { return (slots.first ?? "") + " profilin anahtarı" }
        return slots.dropLast().joined(separator: ", ") + " ve " + (slots.last ?? "") + " profilin anahtarı"
    }

    private let settings: AppSettings
    private let defaults: UserDefaults
    /// Kayıt klasörünün kökü (kullanıcının seçtiği klasör; seçilmediyse uygulamanın kendi klasörü)
    private let root: () -> URL
    private let makeClient: (GeminiProfileInfo) -> GeminiClient
    private let now: () -> Date
    private let pause: (TimeInterval) async -> Void
    private let fileManager: FileManager
    private var states: [String: SourceState]
    private var task: Task<Void, Never>?
    /// Test sürüyor mu: sürerken senkron başlatılmaz, süren senkron sıradaki dosyada durur
    var sessionActive: () -> Bool = { false }
    /// Senkron bitti: cevap servisi "kaynak reddedildi" kayıtlarını siler
    var onChange: () -> Void = {}

    init(settings: AppSettings,
         defaults: UserDefaults = .standard,
         root: @escaping () -> URL,
         fileManager: FileManager = .default,
         now: @escaping () -> Date = { Date() },
         pause: @escaping (TimeInterval) async -> Void = { seconds in
             try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
         },
         makeClient: ((GeminiProfileInfo) -> GeminiClient)? = nil) {
        self.settings = settings
        self.defaults = defaults
        self.root = root
        self.fileManager = fileManager
        self.now = now
        self.pause = pause
        self.makeClient = makeClient ?? { profile in GeminiClient(key: { profile.key }, model: { profile.model }) }
        let saved = defaults.data(forKey: SourceSync.statesKey).flatMap { try? JSONDecoder().decode([String: SourceState].self, from: $0) }
        self.states = saved ?? [:]
    }

    // MARK: Klasör

    var sourceFolder: URL {
        return root().appendingPathComponent(SourceRules.folderName, isDirectory: true)
    }

    /// Ekranda gösterilen yer: "Sesli Kontrol Cevaplar › Kaynaklar"
    var folderText: String {
        return root().lastPathComponent + " › " + SourceRules.folderName
    }

    /// Kaynaklar klasörünü (yoksa) açar: kullanıcı Dosyalar uygulamasında görüp içine dosya koyabilsin
    @discardableResult
    func prepareFolder() -> Bool {
        do {
            try fileManager.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
            return true
        } catch {
            tlog("[kaynak] Kaynaklar klasörü açılamadı: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Durum

    func saved(forKey key: String) -> SourceState? {
        return states[SourceSync.keyID(key)]
    }

    private func save(_ state: SourceState, forKey key: String) {
        states[SourceSync.keyID(key)] = state
        defaults.set(try? JSONEncoder().encode(states), forKey: SourceSync.statesKey)
    }

    /// Bu anahtarla cevap istenirken kullanılacak depo: seçenek açık ve depoda hazır kaynak varsa adı; yoksa nil (istek kaynaksız gider)
    func store(forKey key: String) -> String? {
        guard settings.useSources, let state = saved(forKey: key), !state.store.isEmpty, !state.active.isEmpty else { return nil }
        return state.store
    }

    /// Gemini bu anahtarın deposuyla gelen isteği geri çevirdi: durum satırında görünür; depo bulunamadıysa (404) bir daha kullanılmaz ve
    /// bir sonraki senkronda yeniden kurulur
    func noteRejection(key: String, status: Int, message: String) {
        guard var state = saved(forKey: key) else { return }
        state.rejected = String(message.prefix(160))
        if status == 404 {
            state.store = ""
            state.active = []
            state.uploaded = [:]
        }
        save(state, forKey: key)
        refreshLines()
    }

    private var groups: [(key: String, profiles: [GeminiProfileInfo])] {
        return SourceSync.keyGroups(settings.geminiProfileInfos())
    }

    /// Açılış denetimi: seçenek kapalıysa nil; açıksa kaynakların hazır olup olmadığı ve gerekiyorsa uyarı
    func readiness() -> SourceReadiness? {
        guard settings.useSources else { return nil }
        let files = SourceRules.scan(sourceFolder, fileManager: fileManager).files
        let all = groups
        guard !files.isEmpty else {
            return SourceReadiness(ok: false, detail: "klasör boş",
                                   warning: "Kaynaklara göre cevaplama açık ama Kaynaklar klasöründe dosya yok. Sorular kaynaksız cevaplanacak.")
        }
        let ready = all.filter { store(forKey: $0.key) != nil }
        guard !ready.isEmpty else {
            return SourceReadiness(ok: false, detail: "Gemini'ye yüklenmemiş",
                                   warning: "Kaynaklar Gemini'ye yüklenmemiş. Sorular kaynaksız cevaplanacak. Test bitince Ayarlar, Gemini bölümünden dosyaları senkronize edin.")
        }
        let stale = all.contains { group in
            let state = saved(forKey: group.key)
            return SourceRules.outOfDate(state: state, files: files) || (state?.active.count ?? 0) < files.count
        }
        let count = ready.compactMap { saved(forKey: $0.key)?.active.count }.max() ?? 0
        if stale {
            return SourceReadiness(ok: false, detail: "\(count) kaynak hazır, klasörle eşit değil",
                                   warning: "Kaynaklar senkronize değil: cevaplar depodaki \(count) kaynağa göre verilecek. Test bitince Ayarlar, Gemini bölümünden dosyaları senkronize edin.")
        }
        return SourceReadiness(ok: true, detail: "\(count) kaynak hazır", warning: nil)
    }

    /// Ayarlar ekranındaki satırları yeniden kurar
    func refreshLines() {
        if !busy { progress = "" }
        guard settings.useSources else {
            lines = []
            report = []
            return
        }
        let scan = SourceRules.scan(sourceFolder, fileManager: fileManager)
        var out = ["Klasör: \(folderText)"]
        out.append(scan.files.isEmpty ? "Klasörde kaynak yok." : "Klasörde \(SourceRules.summary(scan.files)).")
        out.append(contentsOf: scan.skipped.map { "Yüklenmeyecek: \($0)" })
        let all = groups
        if all.isEmpty { out.append("Gemini anahtarı yok: kaynaklar yüklenemez.") }
        for group in all {
            let text = SourceRules.stateText(saved(forKey: group.key), files: scan.files)
            out.append(all.count > 1 ? "\(SourceSync.groupLabel(group.profiles)): \(text)" : "Gemini deposu: \(text)")
        }
        lines = out
    }

    // MARK: Senkron

    /// "Soruları verilen kaynaklara göre cevapla" açıldı ya da kapandı. Açılınca yalnız klasör hazırlanır ve durum yazılır; yükleme yapılmaz
    /// (kullanıcı "Dosyaları senkronize et"e basar).
    func optionChanged() {
        if settings.useSources {
            tlog("[kaynak] kaynaklara göre cevaplama AÇILDI (klasör: \(folderText))")
        } else {
            tlog("[kaynak] kaynaklara göre cevaplama kapatıldı: sorular eskisi gibi kaynaksız cevaplanır")
        }
        refresh()
    }

    /// Durumu tazeler (uygulama öne gelince, Ayarlar açılınca): seçenek açıksa Kaynaklar klasörü yoksa açılır ve satırlar yeniden yazılır.
    /// Ağa çıkılmaz, hiçbir dosya yüklenmez ya da silinmez.
    func refresh() {
        if settings.useSources { prepareFolder() }
        refreshLines()
    }

    /// Ayarlar'daki "Dosyaları senkronize et" düğmesi: depo Google'dan okunur ve klasörle arasındaki fark kapatılır
    func syncNow() {
        guard settings.useSources, !busy else { return }
        prepareFolder()
        guard !sessionActive() else {
            progress = "Test sürerken senkron yapılmaz. Önce testi bitirin."
            return
        }
        start()
    }

    /// Süren senkronun bitmesini bekler (sınamalar için)
    func waitUntilIdle() async {
        _ = await task?.value
    }

    private func start() {
        busy = true
        report = []
        progress = "Senkron başlıyor…"
        task = Task { [weak self] in
            guard let self = self else { return }
            await self.run()
        }
    }

    private func run() async {
        let dir = sourceFolder
        let scan = SourceRules.scan(dir, fileManager: fileManager)
        let all = groups
        tlog("[kaynak] senkron başladı: klasörde \(SourceRules.summary(scan.files)); \(all.count) ayrı anahtar"
             + (scan.skipped.isEmpty ? "" : "; yüklenmeyecek: " + scan.skipped.joined(separator: " | ")))
        var texts: [String] = []
        if all.isEmpty { texts.append("Senkron yapılamadı: Gemini API anahtarı girilmemiş.") }
        for group in all {
            if Task.isCancelled { break }
            let result = await sync(group: group, files: scan.files, dir: dir, labelled: all.count > 1)
            let label = all.count > 1 ? SourceSync.groupLabel(group.profiles) + ": " : ""
            texts.append(label + SourceRules.reportText(result))
        }
        busy = false
        progress = ""
        refreshLines()
        report = texts
        onChange()
        tlog("[kaynak] senkron bitti: " + texts.joined(separator: " | "))
    }

    private func sync(group: (key: String, profiles: [GeminiProfileInfo]), files: [SourceFile], dir: URL, labelled: Bool) async -> SourceReport {
        let key = group.key
        let prefix = labelled ? SourceSync.groupLabel(group.profiles) + ": " : ""
        var state = saved(forKey: key) ?? SourceState()
        var result = SourceReport()
        // Klasör boş ve depo hiç açılmamışsa Google'a gidilmez
        if files.isEmpty && state.store.isEmpty {
            state = SourceState()
            state.date = now()
            save(state, forKey: key)
            return result
        }
        let client = makeClient(group.profiles[0])
        do {
            progress = prefix + "Gemini deposuna bakılıyor…"
            let store = try await client.sourceStore(saved: state.store, title: SourceRules.storeTitle, key: key)
            if store != state.store { state.uploaded = [:] }   // başka (yeni) depo: eski yükleme kayıtları onun için geçerli değil
            state.store = store
            save(state, forKey: key)
            var remote = try await client.sourceDocuments(store: store, key: key)
            let plan = SourceRules.plan(local: files, remote: remote, uploaded: state.uploaded)
            tlog("[kaynak] \(prefix)depo \(store): \(remote.count) belge; yüklenecek \(plan.upload.count), silinecek \(plan.remove.count), yerinde \(plan.keep.count)")

            // 1) Klasörde olmayan (ya da değişmiş, bozuk, çift) belgeler depodan silinir
            for document in plan.remove {
                try Task.checkCancellation()
                progress = prefix + "depodan siliniyor: \(document.title)"
                do {
                    try await client.deleteSourceDocument(document.id, key: key)
                    if !plan.keep.contains(where: { $0.title == document.title }) { state.uploaded[document.title] = nil }
                    result.removed += 1
                    tlog("[kaynak] \(prefix)depodan silindi: \(document.title)")
                } catch {
                    tlog("[kaynak] \(prefix)depodan silinemedi: \(document.title) (\(SourceSync.text(error)))")
                }
            }
            save(state, forKey: key)

            // 2) Depoda karşılığı olmayan dosyalar yüklenir
            result.unchanged = plan.keep.count
            var sent: [SourceFile] = []
            var failed: [String: String] = [:]
            var stopped = false
            for (index, file) in plan.upload.enumerated() {
                try Task.checkCancellation()
                if sessionActive() {
                    stopped = true
                    tlog("[kaynak] \(prefix)test başladı: kalan \(plan.upload.count - index) dosya yüklenmedi; test bitince yeniden senkronize edilmeli")
                    break
                }
                let place = "\(index + 1)/\(plan.upload.count): \(file.name) (\(SourceRules.sizeText(file.bytes)))"
                progress = prefix + "yükleniyor " + place
                let began = now()
                do {
                    let data = try Data(contentsOf: dir.appendingPathComponent(file.name), options: .mappedIfSafe)
                    let operation = try await client.uploadSource(data, mimeType: SourceRules.mimeType(for: file.name) ?? "application/octet-stream",
                                                                 title: file.name, store: store, key: key,
                                                                 timeout: SourceSync.uploadLimit(bytes: file.bytes))
                    state.uploaded[file.name] = file.bytes
                    save(state, forKey: key)
                    sent.append(file)
                    tlog("[kaynak] \(prefix)yüklendi (\(Int(now().timeIntervalSince(began))) sn) \(place)")
                    var problem: String? = operation.error.isEmpty ? nil : operation.error
                    if problem == nil && !operation.done {
                        progress = prefix + "Google işliyor " + place
                        problem = await client.waitForSourceOperation(operation.name, key: key, limit: SourceSync.indexLimit(bytes: file.bytes))
                    }
                    if let problem = problem {
                        failed[file.name] = problem
                        tlog("[kaynak] \(prefix)Google işleyemedi: \(file.name) (\(problem))")
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failed[file.name] = SourceSync.text(error)
                    tlog("[kaynak] \(prefix)yüklenemedi: \(file.name) (\(SourceSync.text(error)))")
                }
            }

            // 3) Son durum depodan okunur; Google hâlâ işliyorsa bir süre beklenir
            remote = try await client.sourceDocuments(store: store, key: key)
            var polls = 0
            while SourceSync.pendingNames(files: files, remote: remote).count > 0 && polls < SourceSync.settlePolls && !sessionActive() {
                try Task.checkCancellation()
                progress = prefix + "Google \(SourceSync.pendingNames(files: files, remote: remote).count) kaynağı işliyor…"
                await pause(SourceSync.settlePause)
                polls += 1
                remote = try await client.sourceDocuments(store: store, key: key)
            }
            state.active = files.filter { file in remote.contains { $0.title == file.name && $0.isActive } }.map { $0.name }
            state.pending = SourceSync.pendingNames(files: files, remote: remote)
            for file in files where failed[file.name] == nil {
                if remote.contains(where: { $0.title == file.name && $0.isFailed }) && !state.active.contains(file.name) {
                    failed[file.name] = "Google dosyayı işleyemedi"
                } else if !remote.contains(where: { $0.title == file.name }) && !stopped {
                    failed[file.name] = "depoda görünmüyor"
                }
            }
            let activeNames = state.active
            state.failed = failed.filter { !activeNames.contains($0.key) }
            // Test başladığı için yarım kalan senkron "tamam" sayılmaz: durum satırı ve açılış uyarısı yeniden senkron ister
            if !stopped { state.synced = files }
            state.problem = ""
            state.rejected = ""
            state.date = now()
            save(state, forKey: key)
            result.uploaded = sent.filter { state.failed[$0.name] == nil }
            result.ready = files.filter { activeNames.contains($0.name) }
            result.pending = state.pending.count
            result.failed = state.failed
            result.stopped = stopped
        } catch is CancellationError {
            tlog("[kaynak] \(prefix)senkron yarıda kesildi")
            result.problem = "senkron yarıda kesildi"
        } catch {
            state.problem = SourceSync.text(error)
            state.date = now()
            save(state, forKey: key)
            tlog("[kaynak] \(prefix)senkronize edilemedi: \(state.problem)")
            result.problem = state.problem
        }
        return result
    }

    /// Klasördeki dosyalardan depoda hâlâ işlenenler (hazır kopyası olmayanlar)
    static func pendingNames(files: [SourceFile], remote: [SourceDocument]) -> [String] {
        return files.filter { file in
            let own = remote.filter { $0.title == file.name }
            return !own.contains(where: { $0.isActive }) && own.contains(where: { !$0.isActive && !$0.isFailed })
        }.map { $0.name }
    }

    static func text(_ error: Error) -> String {
        return String(((error as? GeminiError)?.message ?? error.localizedDescription).prefix(200))
    }
}
