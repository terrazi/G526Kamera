import Foundation

/// Bu oturumda kuyruğa alınan fotoğrafların sırası. "Son fotoğrafı sil" yalnız bu oturumda çekilmiş,
/// henüz Drive'a gitmemiş fotoğrafı siler (saf mantık; birim testle denenir).
struct CaptureLog {
    enum Outcome: Equatable {
        /// Silindi (dosya adı)
        case removed(String)
        /// Son fotoğraf zaten Drive'a gitti
        case alreadySent
        /// Son fotoğraf şu an yükleniyor
        case uploading
        /// Bu oturumda silinecek fotoğraf yok
        case none
    }

    private(set) var names: [String] = []

    mutating func add(_ name: String) {
        names.append(name)
        if names.count > 50 { names.removeFirst(names.count - 50) }
    }

    /// Son çekilen fotoğrafı silmeye çalışır. `pending`: diskte bekleyen dosya adları, `inFlight`: yüklenmekte olanlar.
    mutating func takeLast(pending: Set<String>, inFlight: Set<String>) -> Outcome {
        guard let last = names.last else { return .none }
        if inFlight.contains(last) { return .uploading }
        if !pending.contains(last) {
            // Son fotoğraf gitmiş; eskilerini yanlışlıkla silmeyelim
            names.removeAll()
            return .alreadySent
        }
        names.removeLast()
        return .removed(last)
    }
}

/// Günlük sayaçlar: uygulama kapanıp açılsa da "bugün" için çekilen / gönderilen sayfalar korunur.
struct DailyStats: Codable, Equatable {
    var day = ""
    var captured = 0
    var sentPhotos = 0
    var sentDocs = 0

    /// Yerel takvim günü anahtarı ("2026-11-09")
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld-%02ld-%02ld", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Gün değiştiyse sayaçlar sıfırlanır
    mutating func roll(to key: String) {
        if day != key { self = DailyStats(day: key) }
    }
}

final class DailyStatsStore {
    static let shared = DailyStatsStore()

    private let defaults: UserDefaults
    private let key: String
    private let calendar: Calendar
    private var stats: DailyStats

    init(defaults: UserDefaults = .standard, key: String = "dailyStats", calendar: Calendar = .current) {
        self.defaults = defaults
        self.key = key
        self.calendar = calendar
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(DailyStats.self, from: data) {
            stats = saved
        } else {
            stats = DailyStats()
        }
    }

    /// Bugünün sayaçları (gün değiştiyse sıfırlanmış)
    func today(now: Date = Date()) -> DailyStats {
        stats.roll(to: DailyStats.dayKey(now, calendar: calendar))
        return stats
    }

    func recordCapture(now: Date = Date()) {
        _ = today(now: now)
        stats.captured += 1
        save()
    }

    func undoCapture(now: Date = Date()) {
        _ = today(now: now)
        stats.captured = max(0, stats.captured - 1)
        save()
    }

    func recordSent(photos: Int, docs: Int, now: Date = Date()) {
        _ = today(now: now)
        stats.sentPhotos += max(0, photos)
        stats.sentDocs += max(0, docs)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(stats) { defaults.set(data, forKey: key) }
    }
}
