import Foundation

/// Ayarlar > Eski kayıtları sil: hangi kayıtların silineceği (şimdiden geriye doğru süre). "Tüm kayıtlar" süre sınırı koymaz.
enum CleanupWindow: CaseIterable, Hashable {
    case lastHour, lastSixHours, lastDay, all

    var title: String {
        switch self {
        case .lastHour: return "Son 1 saat"
        case .lastSixHours: return "Son 6 saat"
        case .lastDay: return "Son 24 saat"
        case .all: return "Tüm kayıtlar"
        }
    }

    /// Geriye doğru kaç saniye (nil: sınırsız)
    var seconds: TimeInterval? {
        switch self {
        case .lastHour: return 3_600
        case .lastSixHours: return 6 * 3_600
        case .lastDay: return 24 * 3_600
        case .all: return nil
        }
    }

    /// Bu andan sonra başlayan kayıtlar silinir; nil: hepsi
    func cutoff(now: Date) -> Date? {
        return seconds.map { now.addingTimeInterval(-$0) }
    }
}

/// Silinen (ya da silinecek) kayıtların sayısı
struct CleanupCounts: Equatable {
    /// Sınav kayıtları: cevap sesleri ve cevaplar.txt içeren sınav klasörleri
    var exams = 0
    /// Telefondaki çekimler (Cekimler klasörü: bekleyen, gönderilen, gönderilemeyen, paragraf)
    var captures = 0

    var isEmpty: Bool { return exams == 0 && captures == 0 }

    var text: String {
        if isEmpty { return "kayıt yok" }
        return "\(exams) sınav kaydı, \(captures) çekim"
    }

    var doneText: String {
        if isEmpty { return "Bu aralıkta silinecek kayıt yoktu." }
        return "\(exams) sınav kaydı ve \(captures) çekim silindi."
    }
}

extension AnswerLibrary {
    /// Sınav klasörünün başladığı an: "2026-11-15-223912" (yerel saat), eski bitişik ad "20261115223912" ya da eski sürümlerin gün adı
    /// ("2026-11-13", o günün başı). Başka ad nil.
    static func startDate(ofFolderNamed name: String, calendar: Calendar = .current) -> Date? {
        guard let parsed = parseFolderName(name) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        switch parsed.day.count {
        case 17: formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        case 10: formatter.dateFormat = "yyyy-MM-dd"
        default: formatter.dateFormat = "yyyyMMddHHmmss"
        }
        return formatter.date(from: parsed.day)
    }

    /// Kayıt kökündeki sınav klasörleri (YALNIZ zaman damgalı / gün adlı olanlar: başka klasör ve dosyalara dokunulmaz); `cutoff`'tan sonra
    /// başlayanlar, nil ise hepsi
    func examFolders(since cutoff: Date?, calendar: Calendar = .current) -> [URL] {
        let base = root
        let items = (try? fileManager.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        var found: [URL] = []
        for item in items {
            guard (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let started = AnswerLibrary.startDate(ofFolderNamed: item.lastPathComponent, calendar: calendar) else { continue }
            if let cutoff = cutoff, started < cutoff { continue }
            found.append(item)
        }
        return found
    }

    /// Sınav klasörlerini (cevap sesleri ve cevaplar.txt dahil) siler; silinen sayısı döner
    @discardableResult
    func deleteExamFolders(since cutoff: Date?, calendar: Calendar = .current) -> Int {
        var removed = 0
        for folder in examFolders(since: cutoff, calendar: calendar) {
            if (try? fileManager.removeItem(at: folder)) != nil { removed += 1 }
        }
        tlog("[temizlik] \(removed) sınav kaydı silindi (\(cutoff == nil ? "tümü" : "aralıktakiler"))")
        return removed
    }
}
