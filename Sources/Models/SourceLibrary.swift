import Foundation
import CoreGraphics

/// Kaynaklar klasöründeki bir dosya: ad, boyut ve (PDF ise) sayfa sayısı
struct SourceFile: Equatable, Codable {
    var name: String
    var bytes: Int
    /// PDF'in sayfa sayısı; PDF değilse ya da okunamadıysa 0
    var pages: Int = 0
}

/// Gemini'deki kaynak deposunda (File Search store) duran bir belge
struct SourceDocument: Equatable {
    /// "fileSearchStores/…/documents/…": silmek için
    var id: String
    /// Yüklerken verilen ad (dosyanın adı)
    var title: String
    /// "STATE_ACTIVE" (aranabilir), "STATE_PENDING" (Google işliyor), "STATE_FAILED" (işlenemedi)
    var state: String
    /// Google'ın bildirdiği boyut (bildirmezse nil)
    var bytes: Int?

    var isActive: Bool { return state == "STATE_ACTIVE" }
    var isFailed: Bool { return state == "STATE_FAILED" }
}

/// Klasör ile deponun farkı: yüklenecek dosyalar, depodan silinecek belgeler, yerinde kalanlar
struct SourcePlan: Equatable {
    var upload: [SourceFile] = []
    var remove: [SourceDocument] = []
    var keep: [SourceDocument] = []

    var isEmpty: Bool { return upload.isEmpty && remove.isEmpty }
}

/// Bir senkronun sonucu (bir anahtarın deposu için): bitince kullanıcıya verilen rapor bundan yazılır
struct SourceReport: Equatable {
    /// Bu seferde yüklenen dosyalar
    var uploaded: [SourceFile] = []
    /// Depodan silinen belge sayısı (klasörden kaldırılan, değişen ya da bozuk olanlar)
    var removed = 0
    /// Depoda zaten bulunan, değişmediği için yeniden gönderilmeyen dosya sayısı
    var unchanged = 0
    /// Senkron sonunda depoda hazır (aranabilir) olan klasör dosyaları
    var ready: [SourceFile] = []
    /// Google'ın hâlâ işlediği dosya sayısı
    var pending = 0
    /// Yüklenemeyen ya da işlenemeyen dosyalar: ad → neden
    var failed: [String: String] = [:]
    /// Senkron hiç yapılamadıysa nedeni (internet yok, anahtar geçersiz…)
    var problem = ""
    /// Test başladığı için yarıda kaldı
    var stopped = false
}

/// Bir API anahtarının (Google projesinin) kaynak deposu ve son eşitlemenin sonucu. Depo anahtarın projesine aittir: başka anahtar onu göremez,
/// bu yüzden her ayrı anahtarın kendi deposu ve kendi durumu vardır.
struct SourceState: Codable, Equatable {
    /// "fileSearchStores/…"; boşsa depo henüz açılmadı
    var store = ""
    /// Bu programın yüklediği dosyalar: ad → bayt (aynı adla değiştirilen dosyayı anlamak için)
    var uploaded: [String: Int] = [:]
    /// Depoda aranabilir (hazır) belgelerin adları
    var active: [String] = []
    /// Yüklendi, Google hâlâ işliyor
    var pending: [String] = []
    /// Yüklenemeyen ya da işlenemeyen dosyalar: ad → neden
    var failed: [String: String] = [:]
    /// Son eşitlemede klasörde bulunan dosyalar (klasör sonradan değişti mi diye bakılır)
    var synced: [SourceFile] = []
    /// Depoya en son bakıldığı an
    var date: Date?
    /// Eşitleme hiç yapılamadıysa nedeni (internet yok, anahtar geçersiz…); başarılı eşitlemede boşalır
    var problem = ""
    /// Gemini bu depoyla gelen isteği geri çevirdiyse nedeni; bir sonraki eşitlemede boşalır
    var rejected = ""
}

/// Kaynaklara göre cevaplama (kullanıcı isteği 2026-11-20): kayıt klasörünün içindeki "Kaynaklar" klasörüne konan belgeler, kullanıcı
/// "Dosyaları senkronize et"e basınca Gemini'nin dosya arama deposuna yüklenir; seçenek açıkken sorular bu belgelere göre cevaplanır.
/// Buradaki kurallar ağdan bağımsızdır ve sınanabilir.
enum SourceRules {
    /// Kayıt klasörünün içindeki kaynak klasörünün adı
    static let folderName = "Kaynaklar"
    /// Gemini'deki deponun görünen adı (uygulama silinip yeniden kurulsa da depo bu adla bulunur)
    static let storeTitle = "Sesli Kontrol Kaynaklar"
    /// Google'ın dosya başına sınırı: 100 MB (sayfa sınırı yoktur)
    static let maxBytes = 100_000_000

    /// Desteklenen dosya türleri: uzantı → MIME türü
    static let mimeTypes: [String: String] = [
        "pdf": "application/pdf",
        "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "txt": "text/plain",
        "md": "text/markdown"
    ]

    static func mimeType(for name: String) -> String? {
        return mimeTypes[(name as NSString).pathExtension.lowercased()]
    }

    /// PDF'in sayfa sayısı (PDF değilse ya da açılamıyorsa 0)
    static func pageCount(_ url: URL) -> Int {
        guard url.pathExtension.lowercased() == "pdf", let document = CGPDFDocument(url as CFURL) else { return 0 }
        return document.numberOfPages
    }

    /// Klasördeki kaynak dosyaları (ada göre sıralı) ve yüklenmeyecek olanlar (nedeniyle). Gizli dosyalar ve alt klasörler sayılmaz.
    static func scan(_ dir: URL, fileManager: FileManager = .default) -> (files: [SourceFile], skipped: [String]) {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        let items = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let sorted = items.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var files: [SourceFile] = []
        var skipped: [String] = []
        for item in sorted {
            let name = item.lastPathComponent
            let values = try? item.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            guard mimeType(for: name) != nil else {
                skipped.append("\(name): desteklenmeyen tür (PDF, Word .docx ya da metin olmalı)")
                continue
            }
            let bytes = values?.fileSize ?? 0
            guard bytes > 0 else {
                skipped.append("\(name): boş dosya")
                continue
            }
            guard bytes <= maxBytes else {
                skipped.append("\(name): 100 MB'tan büyük (\(sizeText(bytes)))")
                continue
            }
            files.append(SourceFile(name: name, bytes: bytes, pages: pageCount(item)))
        }
        return (files, skipped)
    }

    /// Klasördeki dosya ile depodaki belge aynı içerik mi: önce bu programın yükleme kaydına, o yoksa Google'ın bildirdiği boyuta bakılır;
    /// ikisi de yoksa ad yeter
    static func sameContent(_ file: SourceFile, _ document: SourceDocument, uploaded: [String: Int]) -> Bool {
        if let known = uploaded[document.title] { return known == file.bytes }
        if let bytes = document.bytes, bytes > 0 { return bytes == file.bytes }
        return true
    }

    /// Depo klasörün aynası olur: klasörde olmayan, içeriği değişmiş, işlenememiş ya da ikinci kez duran belge depodan silinir; depoda karşılığı
    /// olmayan dosya yüklenir.
    static func plan(local: [SourceFile], remote: [SourceDocument], uploaded: [String: Int]) -> SourcePlan {
        var plan = SourcePlan()
        var covered: [String] = []
        for document in remote {
            guard let file = local.first(where: { $0.name == document.title }), !covered.contains(document.title), !document.isFailed,
                  sameContent(file, document, uploaded: uploaded) else {
                plan.remove.append(document)
                continue
            }
            covered.append(document.title)
            plan.keep.append(document)
        }
        plan.upload = local.filter { !covered.contains($0.name) }
        return plan
    }

    /// Depo klasörden geri kalmış mı (ağa çıkmadan bakılır; yalnız durum yazısı ve uyarı içindir, kendiliğinden yükleme yapılmaz): hiç
    /// senkronize edilmemiş, klasör son senkrondan beri değişmiş, Google hâlâ işliyordu ya da yüklenemeyen dosya kalmış
    static func outOfDate(state: SourceState?, files: [SourceFile]) -> Bool {
        guard let state = state else { return !files.isEmpty }
        if state.synced != files { return true }
        return !state.pending.isEmpty || !state.failed.isEmpty || !state.problem.isEmpty
    }

    // MARK: Ekrandaki yazılar

    static func grouped(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = "."
        formatter.groupingSize = 3
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }

    static func sizeText(_ bytes: Int) -> String {
        let megabytes = Double(bytes) / 1_000_000
        if megabytes >= 10 { return "\(Int(megabytes.rounded())) MB" }
        if megabytes >= 1 { return String(format: "%.1f MB", megabytes).replacingOccurrences(of: ".", with: ",") }
        return "\(max(1, bytes / 1_000)) KB"
    }

    /// "8 kaynak, 1.602 sayfa, 63 MB" (sayfa sayısı bilinmiyorsa yazılmaz)
    static func summary(_ files: [SourceFile]) -> String {
        var parts = ["\(files.count) kaynak"]
        let pages = files.reduce(0) { $0 + $1.pages }
        if pages > 0 { parts.append("\(grouped(pages)) sayfa") }
        parts.append(sizeText(files.reduce(0) { $0 + $1.bytes }))
        return parts.joined(separator: ", ")
    }

    static func dateText(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "d.MM HH:mm"
        return formatter.string(from: date)
    }

    /// Senkron bitince kullanıcıya verilen rapor (kullanıcı isteği 2026-11-20): kaç dosyanın, ne kadar boyutla senkronize edildiği; bu seferde
    /// yüklenen, depodan silinen ve değişmediği için yeniden gönderilmeyen dosya sayıları; varsa eksik kalanlar ve nedeni
    static func reportText(_ report: SourceReport) -> String {
        if !report.problem.isEmpty { return "Senkron yapılamadı: \(report.problem)" }
        let complete = report.failed.isEmpty && report.pending == 0 && !report.stopped
        var text = complete ? "Senkron tamamlandı: " : "Senkron eksik kaldı: "
        if report.ready.isEmpty && report.uploaded.isEmpty && complete {
            text += report.removed > 0 ? "klasör boş; depodaki \(report.removed) kaynak silindi." : "klasör boş, depoda kaynak yok."
            return text
        }
        let readyBytes = report.ready.reduce(0) { $0 + $1.bytes }
        var loaded = "yüklenen \(report.uploaded.count)"
        if !report.uploaded.isEmpty { loaded += " (\(sizeText(report.uploaded.reduce(0) { $0 + $1.bytes })))" }
        text += "\(sizeText(readyBytes)) boyutunda \(report.ready.count) dosya senkronize edildi"
        text += " (\(loaded), depodan silinen \(report.removed), değişmeyen \(report.unchanged))."
        if report.pending > 0 { text += " \(report.pending) dosyayı Google hâlâ işliyor; biraz sonra yeniden senkronize edin." }
        if !report.failed.isEmpty {
            let list = report.failed.sorted { $0.key < $1.key }.map { "\($0.key) (\($0.value))" }.joined(separator: "; ")
            text += " Yüklenemeyen \(report.failed.count) dosya: \(list)."
        }
        if report.stopped { text += " Test başladığı için yarıda kaldı; test bitince yeniden senkronize edin." }
        return text
    }

    /// Bir anahtarın deposunun tek satırlık durumu (Ayarlar ekranı)
    static func stateText(_ state: SourceState?, files: [SourceFile], calendar: Calendar = .current) -> String {
        guard let state = state, state.date != nil || !state.problem.isEmpty else {
            return files.isEmpty ? "depoda kaynak yok" : "henüz yüklenmedi, senkronize edin"
        }
        var text = state.active.isEmpty ? "depoda hazır kaynak yok" : "\(state.active.count) kaynak hazır"
        if !state.pending.isEmpty { text += ", \(state.pending.count) kaynağı Google işliyor" }
        if !state.failed.isEmpty {
            let first = state.failed.sorted { $0.key < $1.key }[0]
            text += ", \(state.failed.count) dosya yüklenemedi (\(first.key): \(first.value))"
        }
        if !state.problem.isEmpty { text += "; senkronize edilemedi: \(state.problem)" }
        if !state.rejected.isEmpty { text += "; Gemini depoyu kabul etmedi: \(state.rejected)" }
        if state.synced != files { text += "; klasör değişmiş, senkronize edin" }
        if let date = state.date { text += " (son senkron \(dateText(date, calendar: calendar)))" }
        return text
    }
}
