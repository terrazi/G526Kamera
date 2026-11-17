import Foundation

/// Çekimin türü: tek bir soru ya da birkaç soruya ortak paragraf
enum CaptureKind: String {
    case question
    case passage
    /// Toplu sayfa çekimi: bir çekim bir sayfadır, sayfadaki bütün sorular tek istekte cevaplanır (bekleyen klasöründe soru gibi durur)
    case page
}

/// Çekim klasörünün özeti (Ayarlar'da gösterilir)
struct CaptureFolderSummary: Equatable {
    /// Gönderilmeyi bekleyen çekimler
    var pending = 0
    /// Gemini'ye gönderilmiş çekimler
    var sent = 0
    /// Gönderilemeyen çekimler (Gemini reddetti, dosya okunamadı…)
    var unsendable = 0
    /// Ortak paragraf çekimleri
    var passages = 0
    /// Klasörün telefonda kapladığı yer (bayt)
    var bytes: Int64 = 0

    var total: Int { return pending + sent + unsendable + passages }

    /// Gönderilmiş sayılanlar (soru çekimleri + paragraf çekimleri): "Gönderilenleri sil" bunları siler
    var deletableSent: Int { return sent + passages }

    var sizeText: String {
        if bytes < 1_000_000 { return "\(bytes / 1000) KB" }
        return "\(bytes / 1_000_000) MB"
    }

    var text: String {
        return "Bekleyen \(pending), gönderilen \(sent), gönderilemeyen \(unsendable), paragraf \(passages) · \(sizeText)"
    }
}

/// Çekimlerin telefondaki KALICI klasörü. Çekilen her soru (fotoğraf + video) gönderilmeden önce buraya yazılır ve internet gelene kadar,
/// uygulama kapansa da kaybolmaz; gönderilince "Gönderilen"e taşınır. Hiçbir çekim kendiliğinden silinmez: yalnız kullanıcı Ayarlar'dan siler.
/// Testlerde `NoCaptureStore` (hiçbir şey saklamaz) ya da geçici klasörlü `FileCaptureStore` verilir.
protocol CaptureStoring: AnyObject {
    /// Çekimi kalıcı klasöre yazar; videosu varsa dosya oraya TAŞINIR. Dönen çekimin `video` adresi yeni yerdir ve `archived` doğrudur.
    /// Yazılamazsa (yer yok…) çekim olduğu gibi döner: bellekte ve eski yerinde kalır, kaybolmaz.
    func keep(_ shot: CapturedQuestion, kind: CaptureKind) -> CapturedQuestion
    /// Önceki çalışmalardan kalan, gönderilmemiş soru çekimleri (en eskiden yeniye)
    func restorePending() -> [CapturedQuestion]
    /// Çekim Gemini'ye gönderildi: "Bekleyen"den "Gönderilen"e taşınır; cevap yanına yazılır
    func markSent(_ shot: CapturedQuestion, answer: String)
    /// Çekim gönderilemeyecek (aynı sonucu verecek): "Gönderilemeyen"e taşınır, nedeni yanına yazılır. Silinmez.
    func markUnsendable(_ shot: CapturedQuestion, reason: String)
    func summary() -> CaptureFolderSummary
    /// Gönderilmiş çekimleri (ve paragraf çekimlerini) siler; silinen sayısı döner. Yalnız kullanıcı istediğinde çağrılır.
    @discardableResult func deleteSent() -> Int
    /// Bütün çekimleri siler (bekleyenler dahil); silinen sayısı döner. Yalnız kullanıcı istediğinde çağrılır.
    @discardableResult func deleteAll() -> Int
    /// `cutoff`'tan sonra çekilmiş çekimlerin sayısı, hangi bölümde olursa olsun (nil: hepsi). Ayarlar > Eski kayıtları sil
    func count(since cutoff: Date?) -> Int
    /// `cutoff`'tan sonra çekilmiş çekimleri siler (bekleyenler dahil; nil: hepsi); silinen sayısı döner. Yalnız kullanıcı istediğinde çağrılır.
    @discardableResult func delete(since cutoff: Date?) -> Int
}

/// Çekimleri saklamayan bileşen (kamera akışı olmayan oturumlar ve eski testler): çekim bellekte kalır, gönderilince video dosyası silinir
final class NoCaptureStore: CaptureStoring {
    func keep(_ shot: CapturedQuestion, kind: CaptureKind) -> CapturedQuestion { return shot }
    func restorePending() -> [CapturedQuestion] { return [] }
    func markSent(_ shot: CapturedQuestion, answer: String) {}
    func markUnsendable(_ shot: CapturedQuestion, reason: String) {}
    func summary() -> CaptureFolderSummary { return CaptureFolderSummary() }
    func deleteSent() -> Int { return 0 }
    func deleteAll() -> Int { return 0 }
    func count(since cutoff: Date?) -> Int { return 0 }
    func delete(since cutoff: Date?) -> Int { return 0 }
}

/// Dosya sistemindeki klasör: `Documents/Cekimler` (Dosyalar uygulamasında "Bu iPhone'da > Sesli Kontrol > Cekimler").
///
///     Cekimler/Bekleyen/<tarih>_<kimlik>/foto.jpg (en net kare), sayfalar.pdf (saniyede bir fotoğraf), video.mp4, bilgi.json
///     Cekimler/Gonderilen/…      (cevap.txt da yazılır)
///     Cekimler/Gonderilemeyen/…  (neden.txt da yazılır)
///     Cekimler/Paragraf/…        (ortak paragraf çekimleri)
final class FileCaptureStore: CaptureStoring {
    static let rootName = "Cekimler"

    enum Bucket: String, CaseIterable {
        case pending = "Bekleyen"
        case sent = "Gonderilen"
        case unsendable = "Gonderilemeyen"
        case passage = "Paragraf"
    }

    /// bilgi.json: çekimin kendisinden başka her şey (çekim kapanıp açılınca geri yüklenir)
    private struct Info: Codable {
        var id: String
        var date: TimeInterval
        var kind: String
        var extraInstruction: String
        var highResolution: Bool
        var videoBytes: Int
        var videoSeconds: Double
        var state: String
    }

    let root: URL
    private let fm = FileManager.default
    /// Çekimin klasörü (kimlik → klasör): taşınınca güncellenir. Bilinmiyorsa klasör adının kimlik ekinden bulunur.
    private var folders: [UUID: URL] = [:]

    init(root: URL) {
        self.root = root
    }

    /// Uygulamanın Belgeler klasöründeki gerçek yer
    static func documentsRoot() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent(rootName, isDirectory: true)
    }

    /// Klasörler açılışta kurulur: Dosyalar uygulamasında ilk çekimden önce de görünür
    func prepare() {
        for bucket in Bucket.allCases {
            try? fm.createDirectory(at: url(of: bucket), withIntermediateDirectories: true)
        }
    }

    func url(of bucket: Bucket) -> URL {
        return root.appendingPathComponent(bucket.rawValue, isDirectory: true)
    }

    // MARK: Yazma

    func keep(_ shot: CapturedQuestion, kind: CaptureKind) -> CapturedQuestion {
        let bucket: Bucket = kind == .passage ? .passage : .pending
        let dir = url(of: bucket).appendingPathComponent(FileCaptureStore.folderName(for: shot), isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try shot.photo.write(to: dir.appendingPathComponent("foto.jpg"), options: .atomic)
            if let pdf = shot.pdf { try pdf.write(to: dir.appendingPathComponent("sayfalar.pdf"), options: .atomic) }
        } catch {
            try? fm.removeItem(at: dir)   // yarım kalmış boş klasör bırakılmaz
            tlog("[çekim klasörü] çekim yazılamadı, bellekte tutuluyor: \(error.localizedDescription)")
            return shot
        }
        var stored = shot
        if let video = shot.video, fm.fileExists(atPath: video.path) {
            let target = dir.appendingPathComponent("video.mp4")
            if relocate(video, to: target) { stored.video = target }
        }
        stored.archived = true
        write(info(for: stored, kind: kind, state: kind == .passage ? "paragraf" : "bekliyor"), to: dir)
        folders[stored.id] = dir
        tlog("[çekim klasörü] çekim kaydedildi (\(bucket.rawValue)): fotoğraf \(stored.photo.count / 1024) KB\(stored.pdf == nil ? "" : ", PDF \(stored.pageCount) sayfa \((stored.pdf?.count ?? 0) / 1024) KB")\(stored.video == nil ? "" : ", video \(stored.videoBytes / 1024) KB")")
        return stored
    }

    func restorePending() -> [CapturedQuestion] {
        var found: [CapturedQuestion] = []
        for dir in subfolders(of: url(of: .pending)) {
            guard let photo = try? Data(contentsOf: dir.appendingPathComponent("foto.jpg")), !photo.isEmpty else {
                // Silinmez: kullanıcı görsün diye "Gönderilemeyen"e taşınır
                move(dir, to: .unsendable, note: "Fotoğraf dosyası okunamadı; çekim gönderilemedi.", noteFile: "neden.txt")
                continue
            }
            var shot = CapturedQuestion(photo: photo)
            if let pdf = try? Data(contentsOf: dir.appendingPathComponent("sayfalar.pdf")), !pdf.isEmpty {
                shot.pdf = pdf
                shot.pageCount = PageDocument.pageCount(of: pdf)
            }
            let saved = readInfo(in: dir)
            if let saved = saved {
                shot.id = UUID(uuidString: saved.id) ?? shot.id
                shot.date = Date(timeIntervalSince1970: saved.date)
                shot.extraInstruction = saved.extraInstruction
                shot.highResolution = saved.highResolution
                shot.videoSeconds = saved.videoSeconds
                shot.isPage = saved.kind == CaptureKind.page.rawValue   // toplu çekimin sayfası: yeniden açılınca da sayfa olarak (tüm sorular) gönderilir
            } else if let created = (try? dir.resourceValues(forKeys: [.creationDateKey]))?.creationDate {
                shot.date = created
            }
            let video = dir.appendingPathComponent("video.mp4")
            let size = fileSize(video)
            if size > 0 {
                shot.video = video
                shot.videoBytes = size
            }
            shot.archived = true
            folders[shot.id] = dir
            found.append(shot)
        }
        // En eski çekim önce: tarih eşitse klasör adı (tarih + kimlik) sırası belirler
        return found.sorted { a, b in
            if a.date != b.date { return a.date < b.date }
            return (folders[a.id]?.lastPathComponent ?? "") < (folders[b.id]?.lastPathComponent ?? "")
        }
    }

    func markSent(_ shot: CapturedQuestion, answer: String) {
        guard let dir = folder(of: shot, in: .pending) else { return }
        move(dir, to: .sent, note: answer, noteFile: "cevap.txt", state: "gonderildi", id: shot.id)
    }

    func markUnsendable(_ shot: CapturedQuestion, reason: String) {
        guard let dir = folder(of: shot, in: .pending) else { return }
        move(dir, to: .unsendable, note: reason, noteFile: "neden.txt", state: "gonderilemedi", id: shot.id)
    }

    // MARK: Özet ve silme

    func summary() -> CaptureFolderSummary {
        var result = CaptureFolderSummary()
        for bucket in Bucket.allCases {
            let items = subfolders(of: url(of: bucket))
            switch bucket {
            case .pending: result.pending = items.count
            case .sent: result.sent = items.count
            case .unsendable: result.unsendable = items.count
            case .passage: result.passages = items.count
            }
            for item in items { result.bytes += folderSize(item) }
        }
        return result
    }

    func deleteSent() -> Int {
        return remove([.sent, .passage])
    }

    func deleteAll() -> Int {
        return remove(Bucket.allCases)
    }

    /// Çekimin zamanı: bilgi.json'daki tarih; yoksa klasör adındaki tarih ("20261115-223912_ab12cd34"); o da yoksa klasörün oluşturulma tarihi.
    /// Hiçbiri okunamazsa en eski sayılır (süreli aralıklarda silinmez, yalnız "tümü"nde silinir).
    private func captureDate(of dir: URL) -> Date {
        if let saved = readInfo(in: dir) { return Date(timeIntervalSince1970: saved.date) }
        let stamp = dir.lastPathComponent.split(separator: "_", maxSplits: 1).first.map(String.init) ?? ""
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        if let named = formatter.date(from: stamp) { return named }
        return (try? dir.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
    }

    private func captureFolders(since cutoff: Date?) -> [URL] {
        var found: [URL] = []
        for bucket in Bucket.allCases {
            for dir in subfolders(of: url(of: bucket)) {
                if let cutoff = cutoff, captureDate(of: dir) < cutoff { continue }
                found.append(dir)
            }
        }
        return found
    }

    func count(since cutoff: Date?) -> Int {
        return captureFolders(since: cutoff).count
    }

    func delete(since cutoff: Date?) -> Int {
        var removed = 0
        for dir in captureFolders(since: cutoff) {
            if (try? fm.removeItem(at: dir)) != nil { removed += 1 }
        }
        folders = folders.filter { fm.fileExists(atPath: $0.value.path) }
        tlog("[çekim klasörü] kullanıcı isteğiyle \(removed) çekim silindi (\(cutoff == nil ? "tümü" : "aralıktakiler"))")
        return removed
    }

    private func remove(_ buckets: [Bucket]) -> Int {
        var count = 0
        for bucket in buckets {
            for dir in subfolders(of: url(of: bucket)) {
                if (try? fm.removeItem(at: dir)) != nil { count += 1 }
            }
        }
        folders = folders.filter { fm.fileExists(atPath: $0.value.path) }
        tlog("[çekim klasörü] kullanıcı isteğiyle \(count) çekim silindi")
        return count
    }

    // MARK: Yardımcılar

    /// Klasör adı: çekim tarihi + kimliğin ilk 8 hanesi (alfabetik sıra = zaman sırası)
    static func folderName(for shot: CapturedQuestion) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(formatter.string(from: shot.date))_\(shot.id.uuidString.prefix(8))"
    }

    private func folder(of shot: CapturedQuestion, in bucket: Bucket) -> URL? {
        if let known = folders[shot.id], fm.fileExists(atPath: known.path), known.deletingLastPathComponent().lastPathComponent == bucket.rawValue {
            return known
        }
        let suffix = "_\(shot.id.uuidString.prefix(8))"
        return subfolders(of: url(of: bucket)).first { $0.lastPathComponent.hasSuffix(suffix) }
    }

    /// Klasörü başka bir bölüme taşır (ad çakışırsa sayı eklenir); nedeni/cevabı yanına yazar. Taşınamazsa yerinde kalır, kaybolmaz.
    private func move(_ dir: URL, to bucket: Bucket, note: String, noteFile: String, state: String? = nil, id: UUID? = nil) {
        try? fm.createDirectory(at: url(of: bucket), withIntermediateDirectories: true)
        if !note.isEmpty { try? note.write(to: dir.appendingPathComponent(noteFile), atomically: true, encoding: .utf8) }
        if let state = state, var saved = readInfo(in: dir) {
            saved.state = state
            write(saved, to: dir)
        }
        var target = url(of: bucket).appendingPathComponent(dir.lastPathComponent, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = url(of: bucket).appendingPathComponent("\(dir.lastPathComponent)-\(n)", isDirectory: true)
            n += 1
        }
        do {
            try fm.moveItem(at: dir, to: target)
            if let id = id { folders[id] = target }
            tlog("[çekim klasörü] çekim \(bucket.rawValue) klasörüne taşındı")
        } catch {
            tlog("[çekim klasörü] çekim taşınamadı (yerinde kaldı): \(error.localizedDescription)")
        }
    }

    /// Dosyayı taşır; olmazsa kopyalayıp aslını siler. Başarılıysa true.
    private func relocate(_ source: URL, to target: URL) -> Bool {
        if (try? fm.moveItem(at: source, to: target)) != nil { return true }
        if (try? fm.copyItem(at: source, to: target)) != nil {
            try? fm.removeItem(at: source)
            return true
        }
        return false
    }

    private func info(for shot: CapturedQuestion, kind: CaptureKind, state: String) -> Info {
        return Info(id: shot.id.uuidString, date: shot.date.timeIntervalSince1970, kind: kind.rawValue,
                    extraInstruction: shot.extraInstruction, highResolution: shot.highResolution,
                    videoBytes: shot.videoBytes, videoSeconds: shot.videoSeconds, state: state)
    }

    private func write(_ info: Info, to dir: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(info) else { return }
        try? data.write(to: dir.appendingPathComponent("bilgi.json"), options: .atomic)
    }

    private func readInfo(in dir: URL) -> Info? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("bilgi.json")) else { return nil }
        return try? JSONDecoder().decode(Info.self, from: data)
    }

    private func subfolders(of dir: URL) -> [URL] {
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func fileSize(_ url: URL) -> Int {
        let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
        return size?.intValue ?? 0
    }

    private func folderSize(_ dir: URL) -> Int64 {
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.reduce(Int64(0)) { $0 + Int64(fileSize($1)) }
    }
}
