import Foundation

/// Deneme sınavı modu (Windows sürümündeki g526/exam.py'nin Swift karşılığı).
///
/// Akış: "deneme sınavı modu" → soru sayfaları program yönlendirmesiyle taranır (fotoğraflar gönderilmeden bekletilir) →
/// "tarama tamamlandı" → PDF'ler klasöre gider → yalnız bu oturumun PDF'leri Gemini'ye verilir → belge/sayfa/soru sayısı sesli
/// teyit edilir → sorular 10'arlı gruplar halinde cevaplanır (her grup bir kez tekrar okunur, sonraki grup arka planda hazırlanır)
/// → soru numarasıyla kayıttan tekrar → "sınav tamamlandı".
///
/// Her adım diske kaydedilir (sinav.json): uygulama kapansa ya da internet kopsa kalınan yerden devam edilir. Cevaplar bir kez
/// üretilip saklanır: tekrar ve "neden" istekleri Gemini'ye gitmez (kota harcanmaz, cevap değişmez).

struct ExamStop: Error {}

struct ExamBadReply: Error {
    let message: String
}

struct ExamSettings: Equatable {
    var group = 10
    var fetch = 20
    var cancelWindow = 5
    var gap = 3
}

/// klasöre giden bir dosya (PDF)
struct ExamSentFile: Codable, Equatable {
    var id: String
    var name: String
    var size: Int
    var photos: Int
    var time: Double = 0
}

struct ExamQuestion: Codable, Equatable {
    var bolum: String
    var no: Int
}

/// "Emin değilim" sorusunun bağımsız ikinci çözümü
struct ExamAlt: Codable, Equatable {
    var sik: String
    var deger: String
    var durum: String
}

struct ExamAnswer: Codable, Equatable {
    var bolum: String
    var no: Int
    var durum: String
    var sik: String
    var deger: String
    var gerekce: String
    /// İkinci çözüm (yalnız "belirsiz" cevaplarda, varsa)
    var alt: ExamAlt?
    /// İkinci çözüm denendi (başarısız olsa da bir kez denenir)
    var altTried: Bool?
}

/// Cevap anahtarı satırı (ekranda gösterilir, klasöre yazılı dosya olur)
struct ExamKeyRow: Equatable, Identifiable {
    var id: String
    var bolum: String
    var no: Int
    var durum: String
    var sik: String
    var word: String
    var deger: String
    var altSik: String
    var altWord: String
    var altDeger: String
}

enum ExamStatus {
    static let ok = "tamam"
    static let unsure = "belirsiz"
    static let unread = "okunamadi"
    static let missing = "alinamadi"
}

/// Diske kaydedilen sınav durumu
struct ExamState: Codable {
    var v = 1
    var id = ""
    var stage = "scan"
    var photos: [String] = []
    var scanned = 0
    var sent: [ExamSentFile] = []
    var questions: [ExamQuestion] = []
    var answers: [String: ExamAnswer] = [:]
    var todo: [String]?
    var pos = 0
    var notes: [String] = []
    var started: Double = 0
    var ended: Double = 0
    var announced = false
    var extra = false
    var adopted = false
    var adoptTold = false

    init() {}

    enum CodingKeys: String, CodingKey {
        case v, id, stage, photos, scanned, sent, questions, answers, todo, pos, notes, started, ended
        case announced, extra, adopted, adoptTold
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        stage = try c.decodeIfPresent(String.self, forKey: .stage) ?? "scan"
        photos = try c.decodeIfPresent([String].self, forKey: .photos) ?? []
        scanned = try c.decodeIfPresent(Int.self, forKey: .scanned) ?? 0
        sent = try c.decodeIfPresent([ExamSentFile].self, forKey: .sent) ?? []
        questions = try c.decodeIfPresent([ExamQuestion].self, forKey: .questions) ?? []
        answers = try c.decodeIfPresent([String: ExamAnswer].self, forKey: .answers) ?? [:]
        todo = try c.decodeIfPresent([String].self, forKey: .todo)
        pos = try c.decodeIfPresent(Int.self, forKey: .pos) ?? 0
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
        started = try c.decodeIfPresent(Double.self, forKey: .started) ?? 0
        ended = try c.decodeIfPresent(Double.self, forKey: .ended) ?? 0
        announced = try c.decodeIfPresent(Bool.self, forKey: .announced) ?? false
        extra = try c.decodeIfPresent(Bool.self, forKey: .extra) ?? false
        adopted = try c.decodeIfPresent(Bool.self, forKey: .adopted) ?? false
        adoptTold = try c.decodeIfPresent(Bool.self, forKey: .adoptTold) ?? false
    }
}

/// Arayüzde gösterilen özet
struct ExamInfo: Equatable {
    var active = false
    var stage = "idle"
    var photos = 0
    var scanned = 0
    var files = 0
    var questions = 0
    var answered = 0
    var saved = false
}

/// Sınavın dış dünyası. Gerçekte AppModel'deki ExamPortsReal, testte sahte. Çağrılar bekleyebilir.
@MainActor
/// Sınavın video aşamasındaki durum (kayıt telefonda, kameranın karelerinden yapılır)
enum ExamVideoPhase: Equatable {
    case idle
    /// Evrak kadraja girmesi bekleniyor (belge görünmeden kayıt başlamaz)
    case waiting
    case recording
    /// Kayıt bitti (durdur ya da 30 sn doldu), dosya hazır
    case finished
    case failed(String)
}

protocol ExamPorts: AnyObject {
    /// Eksik bir şey varsa sesli söylenecek metin (boş = hazır)
    func preflight(needCamera: Bool) -> String
    /// Okutur, bitince döner
    func say(_ text: String) async
    func stopSpeaking()
    /// true/false: sesli konumlandırmayı zorla aç/kapat; nil: ayara dön
    func guide(_ on: Bool?)
    /// true: taranan fotoğraflar gönderilmeden birikir
    func hold(_ on: Bool)
    /// Gönderilmeyi bekleyen fotoğraf adları (eskiden yeniye)
    func pending() -> [String]
    func removePending(_ name: String) -> Bool
    /// Şimdi gönder, bitene kadar bekle; gönderilemeyen fotoğraf sayısını döndür
    func flush(aborted: () -> Bool) async -> Int
    /// Sesli konumlandırma kullanılabilir mi
    func canGuide() -> Bool
    /// Sınav açılırken ses, internet ve Gemini sınansın mı
    func selfCheckOn() -> Bool
    /// Yeni sınav başlarken ve sınav bitince: Gemini'ye eklenmek üzere saklanan sınav videolarını siler
    func videosClear()
    /// Açılış sınaması: internet ve Gemini'ye ulaşılıyor mu. Boş = sorun yok, doluysa okunacak sorun metni
    func checkSystem() async -> String
    func sendError() -> String
    /// since'ten sonra klasöre giden PDF'ler (eskiden yeniye)
    func sent(since: Double) -> [ExamSentFile]
    /// Gönderilen PDF'lerin Gemini belgeleri (tarama sırasıyla)
    func docs(for files: [ExamSentFile]) async throws -> (docs: [GeminiDoc], notes: [String])
    /// Belgeleri Gemini'ye hazırlar (büyük setlerde dosya yükler)
    func prepare(_ docs: [GeminiDoc]) async throws -> [GeminiDoc]
    func ask(_ task: ExamTask, docs: [GeminiDoc]) async throws -> String
    /// [(harf, kod sözcüğü)]
    func codes() -> [(letter: String, word: String)]
    func release() async
    /// Cevap anahtarı metnini klasöre düz metin dosyası olarak yükler; bağlantı (yoksa boş) döndürür. Başarısızlık sınavı etkilemez.
    func saveKey(_ name: String, _ text: String) async -> String
    /// "Dinle": mikrofonu açıp "tamam" denene (ya da ayardaki sessizlik süresi dolana) kadar kaydeder; 16 kHz WAV. nil: duyulmadı / kesildi.
    func listen() async -> Data?
    /// Sürmekte olan "dinle" kaydını keser (listen() nil döner)
    func stopListening()
    /// Sınav ilk aşamada video çeksin mi (ayar açık ve kamera hazır)
    func videoEnabled() -> Bool
    /// Yeni video için hazırlanır: evrak kadraja girince kayıt kendiliğinden başlar (en çok 30 sn)
    func videoArm()
    func videoPhase() -> ExamVideoPhase
    /// Kayıt sürüyorsa bitirir (dosya hazır olur)
    func videoStop()
    /// Hazır ya da çekilmekte olan videoyu göndermeden siler
    func videoDiscard()
    /// Hazır videoyu klasöre gönderir, bitene kadar bekler; hata metni ("" = gönderildi)
    func videoSend() async -> String
}

extension ExamPorts {
    func listen() async -> Data? { return nil }
    func stopListening() {}
    func videoEnabled() -> Bool { return false }
    func videoArm() {}
    func videoPhase() -> ExamVideoPhase { return .idle }
    func videoStop() {}
    func videoDiscard() {}
    func videoSend() async -> String { return "" }
    func selfCheckOn() -> Bool { return false }
    func videosClear() {}
    func checkSystem() async -> String { return "" }
}

@MainActor
final class ExamMode: ObservableObject {
    static let stateFile = "sinav.json"
    /// Mod dışı taramada, PDF olarak çoktan gönderilmiş sayfaların sınava alınabileceği süre (sn)
    static let adoptWindow: Double = 30 * 60
    private static let idleValid: Set<String> = ["start", "scan_done", "end", "undo"]

    @Published private(set) var stage = "idle"
    @Published private(set) var status = ""
    @Published private(set) var said: [String] = []
    @Published private(set) var info = ExamInfo()
    /// Cevap anahtarı (kayıtlı cevaplardan; sınav sırasıyla)
    @Published private(set) var key: [ExamKeyRow] = []
    /// Cevap anahtarı klasöre yüklendiyse bağlantısı
    private(set) var keyLink = ""
    private(set) var keyTask: Task<Void, Never>?

    /// Konuşma bitince bu kadar sn içindeki sesli komutlar yok sayılır (kendi sesimizin yankısı)
    var echoGuard: Double = 1.0

    private let ports: ExamPorts
    private let settings: () -> ExamSettings
    private let url: URL?
    private let now: () -> Double
    private let uptime: () -> Double

    private var st = ExamState()
    private var hasState = false
    private var running = false
    private var runTask: Task<Void, Never>?
    private var cmds: [(name: String, text: String)] = []
    private var valid: Set<String> = []
    private var wantText = false
    private var aborted = false
    private var saidAt: Double = -1000
    private var prefetch: Task<Void, Never>?
    private var docs: [GeminiDoc]?
    private var lastEnd: Double = 0
    /// Bu oturumda video aşaması yapıldı (tarama aşaması "Deneme sınavı modu açık" demeden başlasın)
    private var videoDone = false
    /// Açılış sınaması sürüyor (bu sırada kapanırsa boş sınav kaydedilmez)
    private var checking = false
    /// Açılış sınamasında "tamam" beklenen süreler (sn): ilk deneme, ikinci deneme
    var checkTimeouts: (first: Double, second: Double) = (15, 12)
    private var checkProblem = ""
    /// "Dinle": sınav sırasında her an Gemini ile serbest sesli konuşma
    private var freeActive = false
    private var freeRestart = false
    private var freeTask: Task<Void, Never>?

    init(ports: ExamPorts, settings: @escaping () -> ExamSettings, directory: URL?,
         now: @escaping () -> Double = { Date().timeIntervalSince1970 },
         uptime: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.ports = ports
        self.settings = settings
        self.url = directory?.appendingPathComponent(ExamMode.stateFile)
        self.now = now
        self.uptime = uptime
        if let saved = loadState() { lastEnd = saved.ended }
        refreshInfo()
    }

    // MARK: Kayıt

    var active: Bool { return running }

    private func loadState() -> ExamState? {
        guard let url = url, let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(ExamState.self, from: data), state.v == 1 else { return nil }
        return state
    }

    private func save() {
        refreshInfo()
        guard let url = url, hasState else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(st)
            try data.write(to: url, options: .atomic)
        } catch {
            tlog("[sinav] kaydedilemedi: \(error.localizedDescription)")
        }
    }

    private func refreshInfo() {
        info = ExamInfo(active: running, stage: stage, photos: hasState ? st.photos.count : 0,
                        scanned: hasState ? st.scanned : 0, files: hasState ? st.sent.count : 0,
                        questions: hasState ? st.questions.count : 0, answered: hasState ? st.answers.count : 0,
                        saved: savedSummary() != nil)
        let rows = answerKey()
        if rows != key { key = rows }
    }

    private func fresh() -> ExamState {
        var s = ExamState()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        s.id = f.string(from: Date())
        s.started = now()
        // Yeni sınav önce video aşamasıyla başlar (ayar açık ve kamera hazırsa)
        s.stage = ports.videoEnabled() ? "video" : "scan"
        return s
    }

    /// Yarım kalan sınav varsa durumu, yoksa nil
    func savedSummary() -> ExamState? {
        guard let d = loadState() else { return nil }
        if d.stage == "done" || d.stage.isEmpty { return nil }
        return d
    }

    /// Son sınavın kayıtlı cevapları (soru ve cevap varsa)
    func lastAnswers() -> ExamState? {
        if hasState && !st.answers.isEmpty && !st.questions.isEmpty { return st }
        if let d = loadState(), !d.answers.isEmpty, !d.questions.isEmpty { return d }
        return nil
    }

    // MARK: Cevap anahtarı

    /// Cevap anahtarı satırları (sınav sırasıyla). Yalnız kayıtlı cevaplardan üretilir (Gemini'ye gitmez); cevabı henüz gelmemiş sorular yok.
    func answerKey() -> [ExamKeyRow] {
        guard let d = lastAnswers() else { return [] }
        var codes: [String: String] = [:]
        for c in ports.codes() { codes[c.letter] = c.word }
        var rows: [ExamKeyRow] = []
        for q in d.questions {
            let k = ExamMode.qkey(q.bolum, q.no)
            guard let a = d.answers[k] else { continue }
            let alt = a.alt
            rows.append(ExamKeyRow(id: k, bolum: q.bolum, no: q.no, durum: a.durum, sik: a.sik, word: codes[a.sik] ?? "",
                                   deger: a.deger, altSik: alt?.sik ?? "", altWord: codes[alt?.sik ?? ""] ?? "",
                                   altDeger: alt?.deger ?? ""))
        }
        return rows
    }

    private static func keyPart(_ sik: String, _ word: String, _ deger: String) -> String {
        var out = [sik, word].filter { !$0.isEmpty }.joined(separator: " - ")
        if !deger.isEmpty { out = out.isEmpty ? deger : "\(out), \(deger)" }
        return out
    }

    /// Cevap anahtarının yazılı hali (klasöre yüklenen dosya); cevap yoksa boş
    func answerKeyText() -> String {
        let rows = answerKey()
        if rows.isEmpty { return "" }
        let started = lastAnswers()?.started ?? now()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        var bad = 0
        var lines: [String] = []
        for r in rows {
            let head = r.bolum.isEmpty ? "\(r.no). soru" : "\(r.bolum), \(r.no). soru"
            if r.durum == ExamStatus.unread || r.durum == ExamStatus.missing {
                bad += 1
                lines.append("\(head): \(r.durum == ExamStatus.unread ? "okunamadı" : "alınamadı")")
                continue
            }
            let ans = ExamMode.keyPart(r.sik, r.word, r.deger)
            var line = "\(head): \(ans.isEmpty ? "-" : ans)"
            if r.durum == ExamStatus.unsure {
                line += " (emin değil"
                if !r.altSik.isEmpty || !r.altDeger.isEmpty {
                    line += "; ikinci çözüm: \(ExamMode.keyPart(r.altSik, r.altWord, r.altDeger))"
                }
                line += ")"
            }
            lines.append(line)
        }
        let count = "Soru sayısı: \(rows.count)" + (bad > 0 ? " (okunamayan ya da alınamayan: \(bad))" : "")
        let header = ["Deneme sınavı cevap anahtarı", "Tarih: " + f.string(from: Date(timeIntervalSince1970: started)), count, ""]
        return (header + lines).joined(separator: "\n") + "\n"
    }

    /// Sınav bitince cevap anahtarını klasöre yükler (en iyi gayret)
    private func uploadKey() async {
        let text = answerKeyText()
        if text.isEmpty { return }
        let id = hasState && !st.id.isEmpty ? st.id : "sinav"
        keyLink = await ports.saveKey("Cevap_Anahtari_\(id).txt", text)
    }

    // MARK: Dışarıdan gelenler

    /// Sesli komut ya da ekran düğmesi. Mod açıksa sıradaki adıma iletilir; değilse uygun bir karşılık verilir.
    @discardableResult
    func command(_ name: String, text: String = "", source: String = "voice") -> Bool {
        if source == "voice" && echoGuard > 0 && uptime() - saidAt < echoGuard {
            tlog("[sinav] komut yok sayıldı (kendi sesimizin yankısı olabilir): \(name)")
            return false
        }
        if !running { return outside(name, text) }
        if name == "end" {
            aborted = true
            ports.stopSpeaking()
            ports.stopListening()
        }
        cmds.append((name: name, text: text))
        return true
    }

    /// Serbest söylenen metin (ses tanımadan). Anlam olarak komuta çevrilir; yorumlandıysa true.
    @discardableResult
    func hear(_ text: String) -> Bool {
        if running {
            let ok = valid
            if ok.isEmpty { return false }
            if let name = ExamText.match(text, ok.union(["end"])) {
                return command(name, text: text)
            }
            if wantText && ExamMode.looksLikeQuestionRef(text) {
                if echoGuard > 0 && uptime() - saidAt < echoGuard { return false }
                cmds.append((name: "text", text: text))
                return true
            }
            return false
        }
        var name = ExamText.match(text, ExamMode.idleValid)
        if name == "scan_done" || name == "undo" {
            let hasPages = !ports.pending().isEmpty || !recentSent().isEmpty
            // Taranmış sayfa yokken serbest "bitti" / "sil" sözleri yok sayılır; "tamamlandı" gibi genel sözler ancak
            // "tarama" sözcüğüyle birlikte sınav sayılır (olağan "hepsi tamamlandı" gönderimi kendi yolunda kalır)
            if !hasPages || (name == "scan_done" && !ExamMode.mentionsScanning(text)) { name = nil }
        }
        if let n = name { return command(n, text: text) }
        if lastAnswers() != nil {
            let toks = ExamText.tokens(text)
            let numbered = !ExamText.parseNumbers(text).isEmpty && toks.contains(where: { $0.hasPrefix("soru") })
            if numbered || ExamText.wantsAll(text, needSubject: true) {
                if echoGuard > 0 && uptime() - saidAt < echoGuard { return false }
                bg { await self.readSaved(text) }
                return true
            }
        }
        return false
    }

    /// Mod kapalıyken söylenen "tarama tamamlandı" sınava alınabilir mi (olağan "hepsi tamamlandı" gönderimi araya girmesin diye)
    func wouldAdopt(_ text: String) -> Bool {
        if running { return false }
        guard ExamText.match(text, ["scan_done"]) == "scan_done", ExamMode.mentionsScanning(text) else { return false }
        return !ports.pending().isEmpty || !recentSent().isEmpty
    }

    static func mentionsScanning(_ text: String) -> Bool {
        return ExamText.tokens(text).contains(where: { $0.hasPrefix("tara") })
    }

    private static func looksLikeQuestionRef(_ text: String) -> Bool {
        let toks = ExamText.tokens(text)
        return !ExamText.parseNumbers(text).isEmpty || ExamText.wantsAll(text)
            || toks.contains(where: { $0.hasPrefix("soru") || $0.hasPrefix("neden") || $0.hasPrefix("acikla")
                || $0.hasPrefix("gerekce") || $0.hasPrefix("tekrar") })
    }

    /// Yeni bir sayfa tarandı
    func notePhoto(_ name: String) {
        guard running, hasState, stage == "scan" else { return }
        if !st.photos.contains(name) {
            st.photos.append(name)
            st.scanned += 1
        }
        status = "Tarama: \(st.photos.count) sayfa"
        save()
    }

    private func bg(_ work: @escaping @MainActor () async -> Void) {
        Task { await work() }
    }

    private func recentSince() -> Double {
        return max(lastEnd, now() - ExamMode.adoptWindow)
    }

    private func recentSent() -> [ExamSentFile] {
        return ports.sent(since: recentSince())
    }

    /// Mod kapalıyken gelen komutlar yok sayılmaz: gerekirse mod kendiliğinden açılır ya da kısa bir cevap verilir.
    private func outside(_ name: String, _ text: String) -> Bool {
        switch name {
        case "start":
            return start()
        case "scan_done":
            return adopt()
        case "end":
            bg { await self.sayNow("Açık bir deneme sınavı yok.") }
            return true
        case "undo":
            bg { await self.undoOutside() }
            return true
        default:
            return false                // devam / iptal / duraklat gibi genel sözler: sessizce yok sayılır
        }
    }

    // MARK: "Dinle": her an Gemini ile serbest konuşma

    /// "Dinle" sözcüğü / düğme: sınav açıkken her an Gemini'ye serbest sesli istek. Akıştaki konuşma kesilir; program "Dinliyorum" der,
    /// "tamam" denene kadar kaydeder ve ses dosyasını (belgeler ve kayıtlı cevaplarla) doğrudan Gemini'ye gönderir.
    /// Cevap okunur ya da işlem yapılır ("12. soruyu tekrar oku", "sıradaki on soru", "sınavı bitir"); sonra akış sürer.
    @discardableResult
    func listenRequest(source: String = "ui") -> Bool {
        guard running else { return false }
        if source == "voice" && echoGuard > 0 && uptime() - saidAt < echoGuard { return false }
        if freeActive {
            // Zaten sürüyor: okunan cevabı ya da kaydı keser, yeni isteği dinler
            freeRestart = true
            ports.stopListening()
            ports.stopSpeaking()
            return true
        }
        freeActive = true
        freeRestart = false
        ports.stopSpeaking()
        freeTask = Task { [weak self] in
            await self?.freeAsk()
        }
        return true
    }

    private func freeAsk() async {
        let before = status
        while !aborted && !Task.isCancelled {
            freeRestart = false
            await freeOnce()
            if !freeRestart { break }
        }
        freeActive = false
        freeTask = nil
        if running { status = before }
    }

    /// Dinle akışı sürerken sınav akışının sonraki cümleleri bekler
    private func waitFloor() async {
        while freeActive && !aborted && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func speakFree(_ text: String) async {
        said.append(text)
        if said.count > 30 { said.removeFirst(said.count - 30) }
        await ports.say(text)
        saidAt = uptime()
    }

    private func freeLines(_ lines: [String]) async {
        for l in lines {
            if freeRestart || aborted { return }
            if !l.isEmpty { await speakFree(l) }
        }
    }

    /// Sınav belgeleri hazırsa onlar, gönderilmişse hazırlanıp onlar; gönderilmiş belge yoksa belgesiz sorulur
    private func freeDocs() async throws -> [GeminiDoc] {
        if docs == nil && hasState && !st.sent.isEmpty {
            let r = try await ports.docs(for: st.sent)
            if !r.docs.isEmpty && docs == nil { docs = try await ports.prepare(r.docs) }
        }
        return docs ?? []
    }

    private func recordText() -> String {
        return answerKeyText().trimmed
    }

    private func freeOnce() async {
        setStatus("Dinliyorum…")
        await speakFree("Dinliyorum.")
        if freeRestart || aborted { return }
        let audio = await ports.listen()
        if freeRestart || aborted { return }
        guard let wav = audio, !wav.isEmpty else {
            await speakFree("Sizi duyamadım. Tekrar denemek için dinle deyin.")
            return
        }
        setStatus("Gemini düşünüyor…")
        let data: [String: Any]
        do {
            let list = try await freeDocs()
            let task = ExamTask(prompt: ExamPrompts.freePrompt(record: recordText()), schema: ExamPrompts.freeSchema,
                                maxTokens: 2048, audio: wav)
            let raw = try await ports.ask(task, docs: list)
            guard let obj = ExamMode.loads(raw) else { throw ExamBadReply(message: "Cevabı anlayamadım.") }
            data = obj
        } catch {
            if freeRestart || aborted || isStop(error) { return }
            let why = (error is ExamBadReply) ? "Cevabı anlayamadım." : message(error).trimmed
            await speakFree("\(why) Tekrar denemek için dinle deyin.")
            return
        }
        if freeRestart || aborted { return }
        await freeAct(data)
    }

    private func freeAct(_ data: [String: Any]) async {
        let islem = (data["islem"] as? String) ?? ""
        let reply = ((data["cevap"] as? String) ?? "").trimmed
        let saved = lastAnswers()
        switch islem {
        case "tekrar" where saved != nil:
            let nums = ((data["numaralar"] as? [Any]) ?? []).compactMap { ExamMode.intValue($0) }
            let lines = nums.isEmpty ? [] : linesFrom(saved!, all: false, nums: nums, reason: false)
            await freeLines(lines.isEmpty ? [reply.isEmpty ? "Bu sorunun kayıtlı cevabı yok." : ExamMode.cap(reply)] : lines)
        case "hepsi" where saved != nil:
            let lines = linesFrom(saved!, all: true, nums: [], reason: false)
            await freeLines(lines.isEmpty ? ["Henüz kayıtlı cevap yok."] : lines)
        case "devam":
            if valid.contains("continue") {
                cmds.append((name: "continue", text: ""))
                await speakFree("Devam ediyorum.")
            } else {
                await speakFree("Şu an devam edilecek bir duraklama yok.")
            }
        case "bitir":
            command("end", source: "ui")
        case "cevap" where !reply.isEmpty:
            await freeLines([reply])
        case "tekrar", "hepsi":
            await speakFree("Henüz kayıtlı cevap yok.")
        default:
            await speakFree("Anlayamadım. Tekrar denemek için dinle deyin.")
        }
    }

    /// Cümleyi (kapanış dahil her durumda) okutur
    func sayNow(_ text: String) async {
        await waitFloor()
        said.append(text)
        if said.count > 30 { said.removeFirst(said.count - 30) }
        await ports.say(text)
        saidAt = uptime()
    }

    private func undoOutside() async {
        let names = ports.pending()
        guard let last = names.last else {
            await sayNow("Silinecek bekleyen sayfa yok.")
            return
        }
        if ports.removePending(last) {
            await sayNow("Son sayfa silindi. \(names.count - 1) sayfa bekliyor.")
        } else {
            await sayNow("Son sayfa silinemedi.")
        }
    }

    private func readSaved(_ text: String) async {
        guard let d = lastAnswers() else { return }
        let lines = linesFor(d, text)
        await sayNow(lines.isEmpty ? "Soru bulunamadı." : lines.joined(separator: " "))
    }

    // MARK: Başlatma

    @discardableResult
    func start() -> Bool {
        if running {
            bg { await self.sayNow("Deneme sınavı zaten açık.") }
            return false
        }
        let why = ports.preflight(needCamera: true)
        if !why.isEmpty {
            // Ses çıkmıyorsa da neden görülsün: ekrana da yazılır
            setStatus(why)
            bg { await self.sayNow(why) }
            return false
        }
        if let saved = savedSummary() {
            st = saved
            hasState = true
            launch(resume: true)
        } else {
            st = fresh()
            hasState = true
            launch(resume: false)
        }
        return true
    }

    /// Mod kapalıyken "tarama tamamlandı" denince: son taramalarla gönderme adımından başlar.
    @discardableResult
    func adopt() -> Bool {
        let pending = ports.pending()
        let recent = recentSent()
        if pending.isEmpty && recent.isEmpty {
            bg { await self.sayNow("Henüz taranmış sayfa yok.") }
            return false
        }
        let why = ports.preflight(needCamera: false)
        if !why.isEmpty {
            bg { await self.sayNow(why) }
            return false
        }
        var s = fresh()
        s.stage = "send"
        s.photos = pending
        s.sent = recent
        s.scanned = pending.count + recent.reduce(0) { $0 + $1.photos }
        s.announced = true
        s.adopted = true
        st = s
        hasState = true
        launch(resume: false)
        return true
    }

    /// Ekran düğmesi: sınavı kapatır (kayıtlar saklanır)
    func stop() {
        if running { command("end", text: "", source: "ui") }
    }

    private func launch(resume: Bool) {
        aborted = false
        videoDone = false
        if !resume { ports.videosClear() }
        checking = false
        checkProblem = ""
        cmds.removeAll()
        docs = nil
        prefetch = nil
        running = true
        stage = st.stage
        refreshInfo()
        runTask = Task { [weak self] in
            guard let self = self else { return }
            await self.run(resume: resume)
        }
    }

    /// Sınav bitene kadar bekler (sınama için)
    func waitDone(timeout: Double = 10) async -> Bool {
        let end = uptime() + timeout
        while running && uptime() < end {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return !running
    }

    // MARK: Bekleme ilkelleri

    private func check() throws {
        if aborted || Task.isCancelled { throw ExamStop() }
    }

    private func isStop(_ error: Error) -> Bool {
        return error is ExamStop || error is CancellationError
    }

    private func message(_ error: Error) -> String {
        if let g = error as? GeminiError { return g.message }
        if let b = error as? ExamBadReply { return b.message }
        return error.localizedDescription
    }

    private func say(_ text: String) async throws {
        try check()
        await sayNow(text)
        try check()
    }

    /// Geçerli bir komut gelene kadar bekler: (ad, metin); zaman aşımında (nil, ""). "end" her zaman ExamStop fırlatır.
    private func wait(_ ok: Set<String>, timeout: Double? = nil, text: Bool = false) async throws -> (name: String?, text: String) {
        valid = ok
        wantText = text
        defer {
            valid = []
            wantText = false
        }
        let deadline = timeout.map { uptime() + $0 }
        while true {
            try check()
            if !cmds.isEmpty {
                let c = cmds.removeFirst()
                if c.name == "end" { throw ExamStop() }
                if ok.contains(c.name) || (text && c.name == "text") { return (c.name, c.text) }
                continue
            }
            if let d = deadline, uptime() >= d { return (nil, "") }
            do {
                try await Task.sleep(nanoseconds: 30_000_000)
            } catch {
                throw ExamStop()
            }
        }
    }

    private func setStatus(_ text: String) {
        status = text
    }

    // MARK: Ana döngü

    private func run(resume: Bool) async {
        do {
            if resume {
                try await resumePrompt()
            } else if !st.adopted && ports.selfCheckOn() {
                checking = true
                let problem = try await stageCheck()
                if !problem.isEmpty {
                    checkProblem = problem
                    throw ExamStop()
                }
                checking = false
            }
            while true {
                try check()
                let current = st.stage
                stage = current
                refreshInfo()
                let next: String?
                switch current {
                case "video": next = try await stageVideo()
                case "scan": next = try await stageScan()
                case "send": next = try await stageSend()
                case "prepare": next = try await stagePrepare()
                case "verify": next = try await stageVerify()
                case "answer": next = try await stageAnswer()
                case "review": next = try await stageReview()
                default: next = nil
                }
                guard let n = next else { break }
                st.stage = n
                save()
            }
        } catch {
            if !isStop(error) {
                tlog("[sinav] beklenmeyen hata: \(error.localizedDescription)")
                await sayNow("Deneme sınavında beklenmeyen bir hata oldu: \(error.localizedDescription). Kayıtlarınız saklandı.")
            }
        }
        await close()
    }

    private func close() async {
        let quiet = !checkProblem.isEmpty
        let leftDuringCheck = checking && !quiet
        if checking { hasState = false; checking = false }
        let finished = hasState && (st.stage == "review" || st.stage == "done")
        if hasState {
            if finished {
                st.stage = "done"
                st.ended = now()
                lastEnd = st.ended
            }
            save()
        }
        valid = []
        prefetch?.cancel()
        prefetch = nil
        ports.videoDiscard()
        ports.hold(false)
        ports.guide(nil)
        await ports.release()
        if finished {
            // Anahtar yüklemesi, mod kapandı görünmeden önce başlatılır (dışarıdan beklenirken görev hazır olsun)
            keyLink = ""
            keyTask = Task { [weak self] in
                guard let self = self else { return }
                await self.uploadKey()
            }
        }
        running = false
        stage = "idle"
        setStatus("")
        refreshInfo()
        let held = (hasState && st.stage == "scan") ? st.photos.count : 0
        if quiet {
            // Sorun zaten okundu; ekranda da kalsın
            setStatus(checkProblem)
        } else if leftDuringCheck {
            await sayNow("Deneme sınavı kapatıldı.")
        } else if finished {
            ports.videosClear()
            await sayNow("Deneme sınavı tamamlandı.")
        } else if held > 0 {
            await sayNow("Deneme sınavı kapatıldı. Taranan \(held) sayfa, ayarlarınızdaki yöntemle klasöre kaydedilecek.")
        } else {
            await sayNow("Deneme sınavı kapatıldı. Kayıtlarınız saklandı; deneme sınavı modu deyince kaldığınız yerden devam edebilirsiniz.")
        }
    }

    private func resumePrompt() async throws {
        let line = "Yarım kalan bir deneme sınavı var: \(st.scanned) sayfa, \(st.questions.count) soru, \(st.answers.count) cevap. "
            + "Devam etmek için devam, yenisini başlatmak için yeni sınav deyin."
        try await say(line)
        let r = try await wait(["continue", "new"])
        if r.name == "new" {
            st = fresh()
            stage = "scan"
        } else {
            st.announced = true
            let pend = Set(ports.pending())
            st.photos = st.photos.filter { pend.contains($0) }
        }
        save()
    }

    // MARK: 0) Video

    /// Sınavın ilk aşaması: evrak kadraja girince kayıt başlar (en çok 30 sn). "durdur" ya da süre dolması videoyu klasöre gönderir,
    /// "sil" göndermeden siler, "atla" video aşamasını geçer. Her videodan sonra "devam edeyim mi?": evet → yeni video, hayır → fotoğraf taraması.
    /// Açılış sınaması: ses çıkışı ve mikrofon (kullanıcı "tamam" der), internet ve Gemini (arka planda).
    /// Boş döner: her şey hazır. Doluysa okunan sorun metni.
    private func stageCheck() async throws -> String {
        setStatus("Hazırlık: ses, internet ve Gemini sınanıyor")
        let system = Task { await self.ports.checkSystem() }
        var heard = false
        do {
            try await say("Hazırlık sınaması başlıyor. Beni duyuyorsanız tamam deyin.")
            heard = try await wait(["yes"], timeout: checkTimeouts.first).name != nil
            if !heard {
                try await say("Sizi duyamadım. Beni duyuyorsanız bir kez daha tamam deyin.")
                heard = try await wait(["yes"], timeout: checkTimeouts.second).name != nil
            }
        } catch {
            system.cancel()
            throw error
        }
        let systemProblem = await system.value
        var problems: [String] = []
        if !heard {
            problems.append("Ses sınaması başarısız: sesinizi alamadım ya da sesimi duyamadınız. Ses çıkışı düğmesinden kulaklığı seçin, mikrofon alıcısının bağlı olduğunu kontrol edin; sonra deneme sınavı modu deyin.")
        }
        if !systemProblem.isEmpty { problems.append(systemProblem) }
        if !problems.isEmpty {
            let text = problems.joined(separator: " ")
            try await say(text)
            return text
        }
        try await say("Ses, internet ve Gemini hazır.")
        return ""
    }

    private func stageVideo() async throws -> String? {
        // Kamera ya da ayar video için hazır değilse (kaydedilmiş sınav devam ediyorsa) doğrudan fotoğraf taramasına geçilir
        if !ports.videoEnabled() {
            videoDone = true
            return "scan"
        }
        ports.guide(false)
        var round = 0
        while true {
            let intro = round == 0
                ? "Deneme sınavı modu açık. Önce video çekeceğiz. Evrakı kadraja alın; görününce kayıt kendiliğinden başlar ve en çok 30 saniye sürer. "
                    + "Durdurmak için durdur, silmek için sil deyin. Video istemiyorsanız atla deyin."
                : "Yeni video için evrakı kadraja alın. Durdurmak için durdur, silmek için sil deyin."
            try await say(intro)
            ports.videoArm()
            var deleted = false
            var failure = ""
            var told = false
            loop: while true {
                let r = try await wait(["vstop", "vdel", "vskip"], timeout: 0.3)
                switch r.name {
                case "vstop"?:
                    if ports.videoPhase() == .waiting {
                        if !told {
                            told = true
                            try await say("Kayıt henüz başlamadı. Evrakı kadraja alın; atlamak için atla deyin.")
                        }
                    } else {
                        ports.videoStop()
                    }
                case "vdel"?:
                    ports.videoDiscard()
                    deleted = true
                    break loop
                case "vskip"?:
                    ports.videoDiscard()
                    videoDone = true
                    return "scan"
                default:
                    break
                }
                switch ports.videoPhase() {
                case .waiting: setStatus("Video: evrak bekleniyor")
                case .recording: setStatus("Video kaydediliyor")
                case .finished: break loop
                case .failed(let why):
                    failure = why
                    break loop
                case .idle: break
                }
            }
            if deleted {
                try await say("Video silindi, gönderilmedi.")
            } else if !failure.isEmpty {
                try await say("Video kaydedilemedi: \(failure)")
            } else {
                setStatus("Video klasöre kaydediliyor...")
                try await say("Video klasöre kaydediliyor.")
                let err = await ports.videoSend()
                try check()
                if err.isEmpty {
                    try await say("Video klasöre kaydedildi.")
                } else {
                    try await say("Video gönderilemedi. Telefonda saklandı, internet gelince kendiliğinden gönderilecek.")
                }
            }
            round += 1
            videoDone = true
            setStatus("Video: devam edilsin mi?")
            try await say("Videoya devam edeyim mi? Evet ya da hayır deyin.")
            let a = try await wait(["yes", "no"])
            if a.name == "no" { return "scan" }
        }
    }

    // MARK: 1) Tarama

    private func stageScan() async throws -> String? {
        ports.hold(true)
        ports.guide(true)
        if !st.announced {
            let how = ports.canGuide() ? "" : " Konumlandırma kullanılamıyor: her sayfayı kadraja alıp çekim sözcüğünü söyleyin."
            if videoDone {
                try await say("Şimdi fotoğraf taraması. Soru sayfalarını sırayla tarayın. Bitince tarama tamamlandı deyin.\(how)")
            } else if st.extra {
                try await say("Eksik ya da okunamayan sayfaları tarayın. Bitince tarama tamamlandı deyin.\(how)")
            } else {
                try await say("Deneme sınavı modu açık. Soru sayfalarını sırayla tarayın. Bitince tarama tamamlandı deyin.\(how)")
            }
            st.announced = true
            save()
        }
        while true {
            setStatus("Tarama: \(st.photos.count) sayfa")
            let r = try await wait(["scan_done", "undo"])
            if r.name == "undo" {
                try await undo()
                continue
            }
            if st.photos.isEmpty && st.sent.isEmpty {
                try await say("Henüz tarama yapılmadı. Soru sayfalarını tarayın.")
                continue
            }
            return st.photos.isEmpty ? "prepare" : "send"
        }
    }

    private func undo() async throws {
        let names = ports.pending()
        guard let last = names.last else {
            try await say("Silinecek sayfa yok.")
            return
        }
        if ports.removePending(last) {
            st.photos.removeAll { $0 == last }
            st.scanned = max(0, st.scanned - 1)
            save()
            try await say("Son sayfa silindi. \(st.photos.count) sayfa kaldı.")
        } else {
            try await say("Son sayfa silinemedi.")
        }
    }

    // MARK: 2) Gönderim

    private func stageSend() async throws -> String? {
        ports.guide(false)
        let window = settings().cancelWindow
        let n = st.photos.count
        let done = st.sent.count
        var lead = ""
        if st.adopted && !st.adoptTold {
            lead = "Deneme sınavı modu açıldı. "
            st.adoptTold = true
        }
        var what: String
        let go: String
        let nowText: String
        if n > 0 {
            what = "\(n) sayfa taranmış"
            go = "klasöre kaydedilecek"
            nowText = "\(n) sayfa klasöre kaydediliyor."
            if st.adopted && done > 0 { what += ", son yarım saatte gönderilen \(done) PDF de sınava dahil" }
        } else {
            what = "\(done) PDF zaten klasörde"
            go = "sınava alınacak"
            nowText = "\(done) PDF sınava alınıyor."
        }
        if window > 0 {
            try await say("\(lead)\(what). \(window) saniye içinde \(go); vazgeçmek için iptal deyin.")
            let r = try await wait(["cancel", "more"], timeout: Double(window))
            if r.name != nil {
                st.announced = true
                try await say("Gönderim iptal edildi. Taramaya devam edebilirsiniz.")
                return "scan"
            }
        } else {
            try await say("\(lead)\(nowText)")
        }
        ports.hold(false)
        var told = false
        while true {
            setStatus("Klasöre kaydediliyor...")
            let left = await ports.flush(aborted: { self.aborted })
            try check()
            collectSent()
            let pend = Set(ports.pending())
            st.photos = st.photos.filter { pend.contains($0) }
            save()
            if left == 0 { break }
            if !told {
                let err = ports.sendError()
                let detail = err.isEmpty ? "" : " (\(err))"
                try await say("\(left) sayfa gönderilemedi\(detail). İnternet gelince kendiliğinden gönderilecek; bekliyorum. "
                              + "Hemen denemek için tarama tamamlandı deyin.")
                told = true
            }
            _ = try await wait(["scan_done", "continue"], timeout: 20)
        }
        try await say("Tüm sayfalar klasöre kaydedildi.")
        return "prepare"
    }

    private func collectSent() {
        var known = Set(st.sent.map { $0.id })
        for e in ports.sent(since: st.started) where !e.id.isEmpty && !known.contains(e.id) {
            st.sent.append(e)
            known.insert(e.id)
        }
    }

    // MARK: 3) Gemini'ye hazırlık

    /// Bir sorun var: söyler, kullanıcı "devam" deyince (ya da sınavı kapatınca) döner.
    private func blocked(_ text: String) async throws {
        try await say("\(text) Sorun giderilince devam deyin; bırakmak için sınav tamamlandı deyin, kayıtlarınız saklanır.")
        _ = try await wait(["continue"])
    }

    private func ensureDocs() async throws {
        while docs == nil {
            do {
                setStatus("Belgeler hazırlanıyor...")
                let r = try await ports.docs(for: st.sent)
                if r.docs.isEmpty { throw GeminiError("Gönderilmiş belge bulunamadı.", .error) }
                let ready = try await ports.prepare(r.docs)
                docs = ready
                st.notes = r.notes
                try check()
            } catch {
                if isStop(error) { throw error }
                docs = nil
                try await blocked(message(error))
            }
        }
    }

    private func stagePrepare() async throws -> String? {
        try await ensureDocs()
        return "verify"
    }

    // MARK: 4) Sayısal teyit

    static func loads(_ text: String) -> [String: Any]? {
        let t = GeminiSupport.stripFence(text).trimmed
        guard let data = t.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return obj
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s.trimmed) }
        return nil
    }

    /// Gemini'ye görev sorar; JSON cevabı doğrular (bozuksa bir kez daha). Hata ya da ExamBadReply fırlatır.
    private func askJSON(_ task: ExamTask, key: String) async throws -> [String: Any] {
        for attempt in 0..<2 {
            try check()
            let text = try await ports.ask(task, docs: docs ?? [])
            if let data = ExamMode.loads(text), data[key] is [Any] { return data }
            tlog("[sinav] cevap beklenen JSON değil (deneme \(attempt + 1))")
        }
        throw ExamBadReply(message: "Gemini'nin cevabı anlaşılamadı.")
    }

    private func stageVerify() async throws -> String? {
        try await ensureDocs()
        let task = ExamTask(prompt: ExamPrompts.verifyPrompt, schema: ExamPrompts.verifySchema, video: true)
        var data: [String: Any] = [:]
        while true {
            do {
                setStatus("Gemini belgeleri okuyor...")
                data = try await askJSON(task, key: "sorular")
                break
            } catch {
                if isStop(error) { throw error }
                try await blocked(message(error))
            }
        }
        var questions: [ExamQuestion] = []
        var seen = Set<String>()
        for item in (data["sorular"] as? [Any]) ?? [] {
            guard let q = item as? [String: Any], let no = ExamMode.intValue(q["no"]) else { continue }
            let bolum = ((q["bolum"] as? String) ?? "").trimmed
            let k = ExamMode.qkey(bolum, no)
            if no > 0 && !seen.contains(k) {
                seen.insert(k)
                questions.append(ExamQuestion(bolum: bolum, no: no))
            }
        }
        st.questions = questions
        save()
        var pages = 0
        for item in (data["belgeler"] as? [Any]) ?? [] {
            if let d = item as? [String: Any], let p = ExamMode.intValue(d["sayfa"]) { pages += max(0, p) }
        }
        let unread = max(0, ExamMode.intValue(data["okunamayan_sayfa"]) ?? 0)
        let scanned = st.scanned
        let report = "Gemini belgeleri okuyabildi: \(docs?.count ?? 0) belge, \(pages) sayfa, \(questions.count) soru görüyorum."
        var issues: [String] = []
        if scanned > 0 && Double(pages) < Double(scanned) * 0.9 {
            issues.append("Dikkat: \(scanned) sayfa taradınız ama Gemini \(pages) sayfa görüyor.")
        }
        if unread > 0 { issues.append("\(unread) sayfa okunamadı.") }
        if questions.isEmpty {
            try await say("\(report) Belgelerde soru bulamadım. Taramaya devam etmek için taramaya devam, kapatmak için sınav tamamlandı deyin.")
            _ = try await wait(["more"])
            return toExtra()
        }
        if !issues.isEmpty {
            try await say("\(report) \(issues.joined(separator: " ")) Devam etmek için devam, eksik sayfaları taramak için taramaya devam deyin.")
            let r = try await wait(["continue", "more"])
            if r.name == "more" { return toExtra() }
            return "answer"
        }
        try await say(report)
        return "answer"
    }

    private func toExtra() -> String {
        st.announced = false
        st.extra = true
        st.todo = nil
        docs = nil
        return "scan"
    }

    // MARK: 5) Cevaplar

    static func qkey(_ bolum: String, _ no: Int) -> String {
        return "\(bolum.trimmed)|\(no)"
    }

    private func needsAnswer(_ key: String) -> Bool {
        guard let a = st.answers[key] else { return true }
        return a.durum == ExamStatus.unread || a.durum == ExamStatus.missing
    }

    static func normalize(_ entry: [String: Any]) -> ExamAnswer? {
        guard let no = intValue(entry["no"]) else { return nil }
        var durum = ExamText.fold(((entry["durum"] as? String) ?? "").trimmed)
        if durum != ExamStatus.ok && durum != ExamStatus.unsure && durum != ExamStatus.unread {
            durum = durum.hasPrefix("bel") ? ExamStatus.unsure : ExamStatus.ok
        }
        var sik = String(((entry["sik"] as? String) ?? "").trimmed.prefix(1)).uppercased()
        var deger = ((entry["deger"] as? String) ?? "").trimmed
        if durum != ExamStatus.unread && sik.isEmpty && deger.isEmpty { durum = ExamStatus.unread }
        if durum == ExamStatus.unread {
            sik = ""
            deger = ""
        }
        return ExamAnswer(bolum: ((entry["bolum"] as? String) ?? "").trimmed, no: no, durum: durum, sik: sik, deger: deger,
                          gerekce: ((entry["gerekce"] as? String) ?? "").trimmed)
    }

    /// keys için cevapları Gemini'den alır ve saklar. Eksik kalanlar bir kez daha istenir; hâlâ eksikse "alinamadi" yazılır.
    private func fetch(_ keys: [String]) async throws {
        var qmap: [String: ExamQuestion] = [:]
        for q in st.questions { qmap[ExamMode.qkey(q.bolum, q.no)] = q }
        let want = keys.filter { qmap[$0] != nil }
        for _ in 0..<2 {
            let todo = want.filter { st.answers[$0] == nil || st.answers[$0]?.durum == ExamStatus.missing }
            if todo.isEmpty {
                try await secondSolve(want)
                return
            }
            var byNo: [Int: [String]] = [:]
            for k in todo {
                if let q = qmap[k] { byNo[q.no, default: []].append(k) }
            }
            let asked = todo.compactMap { k -> (bolum: String, no: Int)? in
                guard let q = qmap[k] else { return nil }
                return (bolum: q.bolum, no: q.no)
            }
            let task = ExamTask(prompt: ExamPrompts.answerPrompt(asked), schema: ExamPrompts.answerSchema, video: true)
            let data = try await askJSON(task, key: "cevaplar")
            var got = 0
            for item in (data["cevaplar"] as? [Any]) ?? [] {
                guard let entry = item as? [String: Any], var a = ExamMode.normalize(entry) else { continue }
                var k = ExamMode.qkey(a.bolum, a.no)
                if !todo.contains(k) {
                    let cands = byNo[a.no] ?? []
                    if cands.count != 1 { continue }
                    k = cands[0]
                    a.bolum = qmap[k]?.bolum ?? a.bolum
                }
                st.answers[k] = a
                got += 1
            }
            if got > 0 { save() }
        }
        for k in want where st.answers[k] == nil {
            if let q = qmap[k] {
                st.answers[k] = ExamAnswer(bolum: q.bolum, no: q.no, durum: ExamStatus.missing, sik: "", deger: "", gerekce: "")
            }
        }
        save()
        try await secondSolve(want)
    }

    /// "Emin değilim" diye işaretlenen soruları bağımsız bir ikinci istekle, özenli bir yönergeyle yeniden çözdürür; sonuç cevabın
    /// `alt` alanına yazılır (okunurken iki cevap da söylenir). En iyi gayret: başarısız olursa sınav aksamaz.
    private func secondSolve(_ keys: [String]) async throws {
        var qmap: [String: ExamQuestion] = [:]
        for q in st.questions { qmap[ExamMode.qkey(q.bolum, q.no)] = q }
        let todo = keys.filter { qmap[$0] != nil && st.answers[$0]?.durum == ExamStatus.unsure && st.answers[$0]?.altTried != true }
        for k in todo { st.answers[k]?.altTried = true }          // bir kez denenir (kota/bozuk cevapta her grupta tekrarlanmasın)
        if todo.isEmpty { return }
        var byNo: [Int: [String]] = [:]
        for k in todo {
            if let q = qmap[k] { byNo[q.no, default: []].append(k) }
        }
        let asked = todo.compactMap { k -> (bolum: String, no: Int)? in
            guard let q = qmap[k] else { return nil }
            return (bolum: q.bolum, no: q.no)
        }
        let task = ExamTask(prompt: ExamPrompts.recheckPrompt(asked), schema: ExamPrompts.answerSchema)
        let data: [String: Any]
        do {
            data = try await askJSON(task, key: "cevaplar")
        } catch {
            if isStop(error) { throw error }
            tlog("[sinav] ikinci çözüm alınamadı: \(message(error))")
            save()
            return
        }
        for item in (data["cevaplar"] as? [Any]) ?? [] {
            guard let entry = item as? [String: Any], let b = ExamMode.normalize(entry), b.durum != ExamStatus.unread else { continue }
            var k = ExamMode.qkey(b.bolum, b.no)
            if !todo.contains(k) {
                let cands = byNo[b.no] ?? []
                if cands.count != 1 { continue }
                k = cands[0]
            }
            st.answers[k]?.alt = ExamAlt(sik: b.sik, deger: b.deger, durum: b.durum)
        }
        save()
    }

    /// pos'tan başlayıp cevabı eksik olan en çok `fetch` soruluk dilim
    private func chunk(_ todo: [String], _ pos: Int) -> [String] {
        let limit = max(1, settings().fetch)
        var out: [String] = []
        for k in todo[min(pos, todo.count)...] {
            let a = st.answers[k]
            if a == nil || a?.durum == ExamStatus.missing { out.append(k) }
            if out.count >= limit { break }
        }
        return out
    }

    private func joinPrefetch() async {
        guard let t = prefetch else { return }
        prefetch = nil
        await t.value
    }

    private func startPrefetch(_ todo: [String], _ pos: Int) {
        guard pos < todo.count else { return }
        let keys = chunk(todo, pos)
        if keys.isEmpty { return }
        prefetch = Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.fetch(keys)
            } catch {
                // hata sonraki grupta ana akışta yeniden denenir ve sesli söylenir
                tlog("[sinav] arka plan hazırlığı başarısız: \(self.message(error))")
            }
        }
    }

    private func ensure(_ todo: [String], _ pos: Int, _ group: Int) async throws {
        let keys = Array(todo[pos..<min(pos + group, todo.count)])
        while true {
            await joinPrefetch()
            let missing = keys.filter { st.answers[$0] == nil || st.answers[$0]?.durum == ExamStatus.missing }
            if missing.isEmpty { return }
            do {
                setStatus("Gemini cevapları hazırlıyor...")
                try await fetch(chunk(todo, pos))
                // hâlâ eksik kalanlar "alinamadi" olarak yazıldı: sesli söylenir, sonraki turda yeniden istenir
                return
            } catch {
                if isStop(error) { throw error }
                try await blocked(message(error))
            }
        }
    }

    /// Bir sorunun sesli okunacak cümlesi
    func line(_ state: ExamState, _ key: String, reason: Bool = false) -> String {
        guard let q = state.questions.first(where: { ExamMode.qkey($0.bolum, $0.no) == key }) else { return "" }
        let a = state.answers[key]
        let label = ExamText.ordinal(q.no)
        let pre = q.bolum.isEmpty ? "" : "\(q.bolum), "
        guard let ans = a, ans.durum != ExamStatus.missing else {
            return ExamMode.cap("\(pre)\(label) sorunun cevabı alınamadı.")
        }
        if ans.durum == ExamStatus.unread { return ExamMode.cap("\(pre)\(label) soru okunamadı.") }
        var codes: [String: String] = [:]
        for c in ports.codes() { codes[c.letter] = c.word }
        let word = codes[ans.sik] ?? ans.sik
        var text = "\(pre)\(label) sorunun cevabı \(word)"
        if !ans.deger.isEmpty { text += ", \(ans.deger)" }
        text += "."
        if ans.durum == ExamStatus.unsure {
            text += " Emin değilim."
            if let alt = ans.alt {
                if ExamMode.sameAnswer(ans, alt) {
                    text += " İkinci çözümde de aynı çıktı."
                } else {
                    let aw = codes[alt.sik] ?? alt.sik
                    let av = (!aw.isEmpty && !alt.deger.isEmpty) ? "\(aw), \(alt.deger)" : (aw.isEmpty ? alt.deger : aw)
                    text += " İkinci çözümde cevap \(av) çıktı."
                }
            }
        }
        if reason && !ans.gerekce.isEmpty { text += " Gerekçe: \(ans.gerekce)" }
        return ExamMode.cap(text)
    }

    /// İkinci çözüm ilkiyle aynı mı: şık varsa şık, yoksa değer karşılaştırılır
    static func sameAnswer(_ a: ExamAnswer, _ alt: ExamAlt) -> Bool {
        if !a.sik.isEmpty || !alt.sik.isEmpty { return a.sik == alt.sik }
        return ExamText.fold(a.deger) == ExamText.fold(alt.deger)
    }

    /// Cümlenin ilk harfini büyütür (Türkçe: i → İ, ı → I)
    static func cap(_ text: String) -> String {
        guard let first = text.first else { return text }
        let head: String
        switch first {
        case "i": head = "İ"
        case "ı": head = "I"
        default: head = String(first).uppercased()
        }
        return head + text.dropFirst()
    }

    private func speakGroup(_ keys: [String], last: Bool) async throws {
        let lines = keys.map { line(st, $0) }
        for l in lines where !l.isEmpty { try await say(l) }
        try await say(keys.count != 1 ? "Bu \(keys.count) cevabı bir kez daha okuyorum." : "Bu cevabı bir kez daha okuyorum.")
        for l in lines where !l.isEmpty { try await say(l) }
        if !last { try await say("Sonraki sorulara geçiyorum.") }
    }

    private func gap() async throws {
        let g = settings().gap
        if g <= 0 { return }
        let r = try await wait(["pause", "continue"], timeout: Double(g))
        if r.name == "pause" {
            try await say("Duraklatıldı. Devam etmek için devam deyin.")
            _ = try await wait(["continue"])
        }
    }

    private func stageAnswer() async throws -> String? {
        try await ensureDocs()
        let group = max(1, settings().group)
        if st.todo == nil {
            let todo = st.questions.map { ExamMode.qkey($0.bolum, $0.no) }.filter { needsAnswer($0) }
            st.todo = todo
            for k in todo { st.answers[k] = nil }          // okunamayan / alınamayan eski kayıtlar (ek tarama sonrası) yeniden sorulur
            st.pos = 0
            save()
        }
        let todo = st.todo ?? []
        let total = todo.count
        prefetch = nil
        if total == 0 {
            st.todo = nil
            return "review"
        }
        while st.pos < total {
            let pos = st.pos
            let keys = Array(todo[pos..<min(pos + group, total)])
            try await ensure(todo, pos, group)
            startPrefetch(todo, pos + group)
            setStatus("Cevaplar okunuyor: \(min(total, pos + keys.count)) / \(total)")
            try await speakGroup(keys, last: pos + keys.count >= total)
            st.pos = pos + keys.count
            save()
            if st.pos < total { try await gap() }
        }
        await joinPrefetch()
        st.todo = nil
        return "review"
    }

    // MARK: 6) Gözden geçirme

    private static func wantsReason(_ text: String) -> Bool {
        return ExamText.tokens(text).contains(where: {
            $0.hasPrefix("neden") || $0.hasPrefix("acikla") || $0.hasPrefix("gerekce") || $0.hasPrefix("nicin") || $0.hasPrefix("nasil")
        })
    }

    /// Söylenene göre kayıttan okunacak cümleler: hepsi, aralık ya da tek tek numaralar. Gemini'ye gitmez.
    func linesFor(_ d: ExamState, _ text: String) -> [String] {
        let reason = ExamMode.wantsReason(text)
        if ExamText.wantsAll(text) { return linesFrom(d, all: true, nums: [], reason: reason) }
        var nums = ExamText.numberRange(text)
        if nums.isEmpty { nums = ExamText.parseNumbers(text) }
        return linesFrom(d, all: false, nums: nums, reason: reason)
    }

    /// Kayıttan okunacak cümleler: hepsi ya da verilen soru numaraları (bulunamayan numara için "… soru bulunamadı")
    func linesFrom(_ d: ExamState, all: Bool, nums: [Int], reason: Bool) -> [String] {
        let qs = d.questions
        var keys: [String] = []
        var missing: [Int] = []
        if all {
            keys = qs.map { ExamMode.qkey($0.bolum, $0.no) }
        } else {
            for n in nums {
                let ks = qs.filter { $0.no == n }.map { ExamMode.qkey($0.bolum, $0.no) }
                if ks.isEmpty { missing.append(n) } else { keys.append(contentsOf: ks) }
            }
        }
        var out = keys.map { line(d, $0, reason: reason) }.filter { !$0.isEmpty }
        out.append(contentsOf: missing.map { ExamMode.cap("\(ExamText.ordinal($0)) soru bulunamadı.") })
        return out
    }

    /// Cümleleri grup grup okur; gruplar arasında kısa bir boşluk bırakır ("duraklat" denebilir)
    private func speakLines(_ lines: [String]) async throws {
        let group = max(1, settings().group)
        var i = 0
        while i < lines.count {
            for l in lines[i..<min(i + group, lines.count)] { try await say(l) }
            if i + group < lines.count { try await gap() }
            i += group
        }
    }

    private func stageReview() async throws -> String? {
        let qs = st.questions
        let bad = qs.filter {
            let d = st.answers[ExamMode.qkey($0.bolum, $0.no)]?.durum
            return d == nil || d == ExamStatus.unread || d == ExamStatus.missing
        }
        var msg = "Gönderilen \(qs.count) sorunun tamamı cevaplandı."
        if !bad.isEmpty {
            let nums = bad.prefix(10).map { "\($0.bolum) \($0.no)".trimmed }.joined(separator: ", ")
            msg += " \(bad.count) soru okunamadı ya da alınamadı: \(nums). Bunları yeniden taramak için taramaya devam deyin."
        }
        msg += " Tekrar edilmesini istediğiniz sorunun numarasını söyleyin; hepsini baştan okumak için tüm cevapları oku deyin; "
            + "bitirmek için sınav tamamlandı deyin."
        try await say(msg)
        var misses = 0
        while true {
            setStatus("Soru numarası bekleniyor")
            let r = try await wait(["more"], timeout: 2.0, text: true)
            if r.name == "more" { return toExtra() }
            if r.text.isEmpty { continue }
            let lines = (ExamText.wantsAll(r.text) || !ExamText.parseNumbers(r.text).isEmpty) ? linesFor(st, r.text) : []
            if lines.isEmpty {
                misses += 1
                if misses <= 2 {
                    try await say("Anlayamadım. Soru numarasını ya da tüm cevapları oku deyin; bitirmek için sınav tamamlandı deyin.")
                }
                continue
            }
            misses = 0
            try await speakLines(lines)
            try await say("Başka soru var mı?")
        }
    }
}
