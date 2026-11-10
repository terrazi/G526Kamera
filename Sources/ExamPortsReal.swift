import Foundation

/// Deneme sınavının Gemini istekleri: belgeleri yükler, görevleri sorar; dosya kaybolduysa yeniden yükler, model yoğunsa
/// (503) ya da kotası dolduysa (429) hesabın yedek modeline geçer (sohbetteki mantığın sınav için sadeleştirilmiş hâli).
@MainActor
final class ExamAsker {
    private let client: GeminiTasking
    private let memory: GeminiMemoryProviding?
    private let overloadFallback: () -> Bool
    /// Yeniden yüklenen belgeler (eşleme anahtarına göre): sonraki isteklerde eski, kaybolmuş adresler kullanılmaz
    private var refreshed: [String: GeminiDoc] = [:]

    init(client: GeminiTasking, memory: GeminiMemoryProviding?, overloadFallback: @escaping () -> Bool) {
        self.client = client
        self.memory = memory
        self.overloadFallback = overloadFallback
    }

    /// Belgeleri Gemini'ye hazırlar: büyük setler dosya olarak yüklenir (bir kez; eşleme diskte tutulur), küçükler inline gider.
    func prepare(_ input: [GeminiDoc]) async throws -> [GeminiDoc] {
        refreshed = [:]
        guard let mem = memory, mem.wanted(input) else { return input }
        do {
            return try await mem.upload(input, progress: { _, _ in })
        } catch let e as GeminiError {
            if e.kind == .key || e.kind == .quota || e.kind == .cap || e.kind == .network { throw e }
            tlog("[sinav] hafızaya alınamadı, belgeler doğrudan gönderilecek: \(e.message)")
            return input.map { doc in
                var d = doc
                d.uri = ""
                d.remote = ""
                return d
            }
        }
    }

    func ask(_ task: ExamTask, docs input: [GeminiDoc]) async throws -> String {
        let docs = input.map { refreshed[$0.key] ?? $0 }
        do {
            return try await client.runTask(task, docs: docs, model: nil, serverRetries: nil)
        } catch let first as GeminiError {
            if first.status == 400 || first.status == 403 || first.status == 404, GeminiSupport.allRemote(docs), let mem = memory {
                // Dosya Gemini'de kaybolmuş olabilir (süresi dolmuş): eksikleri yeniden yükleyip bir kez daha dene
                let checked = await mem.revalidate(docs)
                guard checked.lost > 0 else { throw first }
                let again = try await mem.upload(checked.docs, progress: { _, _ in })
                for d in again { refreshed[d.key] = d }
                return try await client.runTask(task, docs: again, model: nil, serverRetries: nil)
            }
            guard GeminiChat.backupWorthy(first), overloadFallback() else { throw first }
            let models = await client.fallbackModels()
            var errors = [first]
            for model in models {
                if Task.isCancelled { throw CancellationError() }
                do {
                    tlog("[sinav] seçili model yanıt vermedi (\(first.status)), yedek model deneniyor: \(model)")
                    return try await client.runTask(task, docs: docs, model: model, serverRetries: 0)
                } catch let e as GeminiError {
                    errors.append(e)
                }
            }
            throw errors.first(where: { $0.kind == .quota }) ?? first
        }
    }
}

/// Deneme sınavının gerçek dış dünyası: kamera/kuyruk/ses/Gemini bağlantıları
@MainActor
final class ExamPortsReal: ExamPorts {
    struct Hooks {
        /// Okutur, bitene kadar bekler
        var speak: (String) async -> Void
        var stopSpeaking: () -> Void
        var setGuide: (Bool?) -> Void
        var cameraLive: () -> Bool
        var speechOn: () -> Bool
        /// Bekleyen bir sayfa silindi (çekim sayacı düşer)
        var pageRemoved: () -> Void
    }

    private let hooks: Hooks
    private let queue: UploadQueue
    private let settings: AppSettings
    private let auth: GoogleAuth
    private let docStore: GeminiDocStore
    private let asker: ExamAsker

    init(hooks: Hooks, queue: UploadQueue, settings: AppSettings, auth: GoogleAuth, docStore: GeminiDocStore, asker: ExamAsker) {
        self.hooks = hooks
        self.queue = queue
        self.settings = settings
        self.auth = auth
        self.docStore = docStore
        self.asker = asker
    }

    func preflight(needCamera: Bool) -> String {
        if !hooks.speechOn() { return "Sesli komut kapalı. Ayarlardan sesle çekimi ya da sesle konumlandırmayı açın." }
        if settings.activeGeminiProfile.key.isEmpty { return "Gemini API anahtarı girilmemiş. Ayarlardan yapıştırın." }
        if !settings.geminiPrivacyOK { return "Gemini gizlilik onayı verilmemiş. Ayarlardan onaylayın." }
        if !auth.isSignedIn { return "Drive'a giriş yapılmamış. Ayarlardan giriş yapın." }
        if needCamera && !hooks.cameraLive() { return "Kamera görüntüsü yok. Kameraya bağlanınca tekrar söyleyin." }
        return ""
    }

    func say(_ text: String) async { await hooks.speak(text) }

    func stopSpeaking() { hooks.stopSpeaking() }

    func guide(_ on: Bool?) { hooks.setGuide(on) }

    func hold(_ on: Bool) {
        queue.setExam(hold: on, exam: on || queue.examMode)
    }

    func pending() -> [String] { return queue.pendingNames() }

    func removePending(_ name: String) -> Bool {
        let ok = queue.removePending(name)
        if ok { hooks.pageRemoved() }
        return ok
    }

    func flush(aborted: () -> Bool) async -> Int {
        queue.setExam(hold: false, exam: true)
        return await queue.flushAndWait(timeout: 120, aborted: aborted)
    }

    func canGuide() -> Bool { return true }

    func sendError() -> String {
        if !auth.isSignedIn { return "Drive'a giriş yapılmamış" }
        return queue.lastError
    }

    func sent(since: Double) -> [ExamSentFile] { return queue.sent(since: since) }

    func docs(for files: [ExamSentFile]) async throws -> (docs: [GeminiDoc], notes: [String]) {
        let infos = files.map { DriveFileInfo(id: $0.id, name: $0.name, size: $0.size, created: "") }
        return try await docStore.docs(for: infos)
    }

    func prepare(_ docs: [GeminiDoc]) async throws -> [GeminiDoc] {
        return try await asker.prepare(docs)
    }

    func ask(_ task: ExamTask, docs: [GeminiDoc]) async throws -> String {
        return try await asker.ask(task, docs: docs)
    }

    func codes() -> [(letter: String, word: String)] {
        return GeminiSupport.parseOptionCodes(settings.geminiOptionCodes)
    }

    func release() async {
        queue.setExam(hold: false, exam: false)
    }

    func saveKey(_ name: String, _ text: String) async -> String {
        guard auth.isSignedIn else { return "" }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("anahtar-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try Data(text.utf8).write(to: file, options: .atomic)
            let result = try await DriveClient(auth: auth).uploadFile(.text(file), name: name)
            tlog("[sinav] cevap anahtarı Drive'a yüklendi: \(name)")
            return result.id.isEmpty ? "" : "https://drive.google.com/file/d/\(result.id)/view"
        } catch {
            tlog("[sinav] cevap anahtarı yüklenemedi: \(error.localizedDescription)")
            return ""
        }
    }
}
