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
    /// Sınav videolarının baytları (soruları okuyan görevlere eklenir)
    var videoProvider: () -> [Data] = { [] }

    /// Videoların hangileri istek boyutuna sığar: PDF baytları (dosya adresiyle gitmeyenler) düşüldükten sonra kalan yere sırayla
    nonisolated static func pickVideos(_ videos: [Data], docs: [GeminiDoc], budget: Int = GeminiConfig.inlineBudget) -> [Data] {
        var room = budget - docs.filter { !$0.isRemote }.reduce(0) { $0 + $1.size }
        var chosen: [Data] = []
        for video in videos where video.count <= room {
            chosen.append(video)
            room -= video.count
        }
        return chosen
    }

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

    func ask(_ original: ExamTask, docs input: [GeminiDoc]) async throws -> String {
        let docs = input.map { refreshed[$0.key] ?? $0 }
        var task = original
        if original.useVideo {
            task.videos = ExamAsker.pickVideos(videoProvider(), docs: docs)
            if !task.videos.isEmpty { tlog("[sinav] Gemini'ye \(task.videos.count) sınav videosu da ekleniyor") }
        }
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
        /// "Dinle": "tamam" denene kadar kaydeder; 16 kHz WAV (nil: duyulmadı / kesildi)
        var listen: () async -> Data? = { nil }
        var stopListening: () -> Void = {}
        /// Sınav ilk aşamada video çeksin mi (ayar açık ve kamera görüntüsü var)
        var videoEnabled: () -> Bool = { false }
        var videoArm: () -> Void = {}
        var videoPhase: () -> ExamVideoPhase = { .idle }
        var videoStop: () -> Void = {}
        var videoDiscard: () -> Void = {}
        /// Hazır videoyu belge klasörüne kaydeder, bitene kadar bekler; hata metni ("" = kaydedildi)
        var videoSend: () async -> String = { "" }
        /// Açılış sınaması: internet ve Gemini (boş = sorun yok)
        var checkSystem: () async -> String = { "" }
        /// Gemini'ye eklenmek üzere saklanan sınav videolarını siler
        var videosClear: () -> Void = {}
    }

    private let hooks: Hooks
    private let queue: UploadQueue
    private let settings: AppSettings
    private let folder = FolderClient()
    private let docStore: GeminiDocStore
    private let asker: ExamAsker

    init(hooks: Hooks, queue: UploadQueue, settings: AppSettings, docStore: GeminiDocStore, asker: ExamAsker) {
        self.hooks = hooks
        self.queue = queue
        self.settings = settings
        self.docStore = docStore
        self.asker = asker
    }

    func preflight(needCamera: Bool) -> String {
        if !hooks.speechOn() { return "Sesli komut kapalı. Ayarlardan sesle çekimi ya da sesle konumlandırmayı açın." }
        if settings.activeGeminiProfile.key.isEmpty { return "Gemini API anahtarı girilmemiş. Ayarlardan yapıştırın." }
        if !settings.geminiPrivacyOK { return "Gemini gizlilik onayı verilmemiş. Ayarlardan onaylayın." }
        if !folder.isReady { return "Belge klasörü seçilmemiş. Ayarlardan klasörü seçin." }
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

    func videoEnabled() -> Bool { return hooks.videoEnabled() }
    func videoArm() { hooks.videoArm() }
    func videoPhase() -> ExamVideoPhase { return hooks.videoPhase() }
    func videoStop() { hooks.videoStop() }
    func videoDiscard() { hooks.videoDiscard() }
    func videoSend() async -> String { return await hooks.videoSend() }
    func selfCheckOn() -> Bool { return settings.examSelfCheck }
    func videosClear() { hooks.videosClear() }
    func checkSystem() async -> String { return await hooks.checkSystem() }

    func sendError() -> String {
        if !folder.isReady { return "Belge klasörü seçilmemiş" }
        return queue.lastError
    }

    func sent(since: Double) -> [ExamSentFile] { return queue.sent(since: since) }

    func docs(for files: [ExamSentFile]) async throws -> (docs: [GeminiDoc], notes: [String]) {
        let infos = files.map { StoredFileInfo(id: $0.id, name: $0.name, size: $0.size, created: "") }
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

    func listen() async -> Data? { return await hooks.listen() }

    func stopListening() { hooks.stopListening() }

    func release() async {
        queue.setExam(hold: false, exam: false)
    }

    func saveKey(_ name: String, _ text: String) async -> String {
        guard folder.isReady else { return "" }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("anahtar-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try Data(text.utf8).write(to: file, options: .atomic)
            let result = try await folder.save(.text(file))
            tlog("[sinav] cevap anahtarı klasöre kaydedildi: \(result.id)")
            return result.id
        } catch {
            tlog("[sinav] cevap anahtarı kaydedilemedi: \(error.localizedDescription)")
            return ""
        }
    }
}
