import Foundation
import UIKit

/// Yarım kalan iş: Gemini'ye giden ama cevabı kulaklıktan tam duyulmamış soru. Uygulama kapanırsa yeniden açılışta tamamlanır.
struct PendingWork: Codable, Equatable {
    var question: String
    var english: String
    /// Kullanıcının okuduğu soru numarası (okunmadıysa nil)
    var spokenNumber: Int?
    /// Cevap geldiyse kaydedilen numara
    var number: Int?
    /// Cevap geldiyse ve kaydedildiyse okunacak cümle (nil: cevap henüz gelmemişti, soru yeniden sorulur)
    var spoken: String?
}

/// Önceki çalışmanın nasıl bittiği
enum PreviousExit: Equatable {
    /// Uygulama ilk kez açılıyor
    case firstRun
    /// Oturum yoktu ya da "Testi bitir" ile düzgün bitmişti
    case clean
    /// Kullanıcı "Programı kapat" düğmesine basılı tutarak kapattı
    case deliberate
    /// Oturum sürerken kapandı (iOS bellek için kapattı, çöktü, pil bitti ya da elle kapatıldı)
    case unexpected(cause: String)

    var logText: String {
        switch self {
        case .firstRun: return "ilk açılış"
        case .clean: return "düzgün bitmişti"
        case .deliberate: return "kullanıcı kapatmıştı"
        case .unexpected(let cause): return "BEKLENMEDİK KAPANMA: \(cause)"
        }
    }
}

/// Uygulama açılırken önceki çalışmadan öğrenilenler
struct RunStart: Equatable {
    var exit: PreviousExit
    var pending: PendingWork?
    var nextNumber: Int
    /// Önceki oturumun cevap klasörünün adı (kapanma sonrası aynı klasöre devam edilir)
    var folder: String?
    /// Önceki çalışmanın son nabzından bu yana geçen süre (sn); bilinmiyorsa nil
    var downSeconds: Int?
    /// Kısa sürede art arda beklenmedik kapanma oldu: açılış döngüsüne girmemek için otomatik başlatma yapılmaz
    var loop: Bool

    static let fresh = RunStart(exit: .firstRun, pending: nil, nextNumber: 1, folder: nil, downSeconds: nil, loop: false)
}

/// Beklenmedik kapanmadan sonra oturumu sürdürmek için gereken bilgi
struct ResumeInfo: Equatable {
    var cause: String
    var downSeconds: Int?
    var pending: PendingWork?
    var nextNumber: Int
    var folder: String?
}

/// Çalışmalar arası kalıcı defter: oturum açık mı, yarım kalan iş, sıradaki soru numarası, son nabız. Beklenmedik kapanma buradan ve
/// günlükten anlaşılır. (Gerçeği RunJournal, testlerde sahtesi.)
@MainActor
protocol RunJournaling: AnyObject {
    /// Uygulama açılırken bir kez: önceki çalışmanın nasıl bittiğini çözer
    func beginRun() -> RunStart
    func setSessionOpen(_ open: Bool)
    /// Uygulamanın yaşadığının işareti (kapalı kalma süresini hesaplamak için)
    func heartbeat()
    func savePending(_ work: PendingWork?)
    func saveNextNumber(_ number: Int)
    func saveFolder(_ name: String?)
    /// Kullanıcı kapattı: bir sonraki açılış bunu beklenmedik saymaz, Kestirmeler otomasyonu da yeniden açmaz
    func markDeliberateClose()
    /// Uygulama bilerek başka uygulamaya geçiyor (Kestirme çalıştırmak için) ya da döndü: "Kapatıldı" otomasyonu uygulamayı bu sırada geri çekmesin
    func setAway(_ away: Bool)
}

/// Defter tutmayan ortam (varsayılan)
@MainActor
final class NoJournal: RunJournaling {
    func beginRun() -> RunStart { return .fresh }
    func setSessionOpen(_ open: Bool) {}
    func heartbeat() {}
    func savePending(_ work: PendingWork?) {}
    func saveNextNumber(_ number: Int) {}
    func saveFolder(_ name: String?) {}
    func markDeliberateClose() {}
    func setAway(_ away: Bool) {}
}

/// Önceki çalışmanın günlüğünü tarayıp nasıl bittiğini ve olası nedenini çıkarır (saf işlev, kolay denenir)
enum ExitAnalyzer {
    static let deliberateMark = "[kapanış] kullanıcı kapattı"
    static let startedMark = "[oturum] BAŞLADI"
    static let endedMark = "[oturum] BİTTİ"

    static let causeMemory = "telefonun belleği dolmuş olabilir"
    static let causeHot = "telefon aşırı ısınmış olabilir"
    static let causeStuck = "bir adım takılmıştı"
    static let causeBackground = "uygulama arka plandayken kapanmış, iOS kapatmış ya da elle kapatılmış olabilir"
    static let causeUnknown = "nedeni günlükte görünmüyor, çökme, iOS ya da elle kapatma olabilir"

    /// - sessionOpen: defterdeki "oturum açık" bayrağı (oturum başlayınca yazılır, bitince silinir)
    /// - deliberate: defterdeki "kullanıcı kapattı" bayrağı
    /// - previous: önceki çalışmanın günlük satırları
    static func analyze(sessionOpen: Bool, deliberate: Bool, previous: [String]) -> PreviousExit {
        if deliberate || previous.contains(where: { $0.contains(deliberateMark) }) { return .deliberate }
        guard sessionOpen else { return .clean }
        // Günlük oturumun düzgün bittiğini gösteriyorsa bayrak silinememiş demektir
        let started = previous.lastIndex(where: { $0.contains(startedMark) })
        let ended = previous.lastIndex(where: { $0.contains(endedMark) })
        if let s = started, let e = ended, e > s { return .clean }
        return .unexpected(cause: cause(from: previous))
    }

    /// Son satırlara bakıp kapanmanın olası nedenini söyler (kesin değil, günlüğün gösterdiği en güçlü ipucu)
    static func cause(from previous: [String]) -> String {
        let tail = Array(previous.suffix(80))
        if tail.contains(where: { $0.contains("[sistem] iOS bellek uyarısı") || $0.contains("[sistem] bellek az") }) { return causeMemory }
        if let left = lastAvailableMemoryMB(in: tail), left < SessionViewModel.Timing.lowMemoryMB { return causeMemory }
        if let thermal = tail.last(where: { $0.contains("[sistem] ısı değişti") }),
           thermal.contains("çok sıcak") || thermal.contains("ısındı (yavaşlayabilir)") { return causeHot }
        if tail.contains(where: { $0.contains("[gözcü] aşama") }) { return causeStuck }
        if let lifecycle = tail.last(where: { $0.contains("[uygulama]") }), lifecycle.contains("arka plana") { return causeBackground }
        return causeUnknown
    }

    /// Günlükteki son "kalan N MB" değeri
    static func lastAvailableMemoryMB(in lines: [String]) -> Int? {
        for line in lines.reversed() where line.contains("[sistem]") {
            guard let range = line.range(of: "kalan ") else { continue }
            let digits = line[range.upperBound...].prefix(while: { $0.isNumber })
            if let value = Int(digits) { return value }
        }
        return nil
    }
}

/// Panodaki işaret. Kestirmeler'deki "uygulama kapanınca yeniden aç" otomasyonu panoyu okur: `SESLIKONTROL-` ile başlayan bir şey varsa
/// uygulamayı açmaz. iOS "Kapatıldı" tetikleyicisini uygulamadan başka uygulamaya geçildiğinde de çalıştırır; bu yüzden işaret şu
/// anlarda yazılır: oturum yokken (kapat düğmesi, test bitti), uygulama kestirme çalıştırmak için bilerek başka uygulamaya geçerken.
/// Oturum sürerken panoda işaret yoktur: o sırada uygulama kapanırsa otomasyon onu geri açar.
/// Kullanıcının panosuna saygı: işaret ancak panoyu başka biri değiştirmediyse (değişim sayacı aynıysa) silinir.
final class ClipboardFlag {
    static let prefix = "SESLIKONTROL-"
    /// Oturum yok ya da kullanıcı bilerek kapattı
    static let closed = "SESLIKONTROL-KAPALI"
    /// Uygulama kestirme çalıştırmak için bilerek başka uygulamaya geçti
    static let repair = "SESLIKONTROL-ONARIM"

    private static let tokenKey = "journal.clipboardToken"
    private let defaults: UserDefaults
    private let write: (String) -> Void
    private let changeCount: () -> Int

    init(defaults: UserDefaults = .standard,
         write: @escaping (String) -> Void = { UIPasteboard.general.string = $0 },
         changeCount: @escaping () -> Int = { UIPasteboard.general.changeCount }) {
        self.defaults = defaults
        self.write = write
        self.changeCount = changeCount
    }

    /// İşareti panoya yazar ve o andaki değişim sayacını saklar (sonradan başkası panoyu değiştirirse anlaşılsın diye)
    func set(_ marker: String) {
        write(marker)
        defaults.set(changeCount(), forKey: ClipboardFlag.tokenKey)
    }

    /// Pano hâlâ bizim yazdığımızsa siler; kullanıcı arada başka bir şey kopyaladıysa dokunmaz
    func clearIfOurs() {
        guard defaults.object(forKey: ClipboardFlag.tokenKey) != nil else { return }
        if defaults.integer(forKey: ClipboardFlag.tokenKey) == changeCount() { write("") }
        defaults.removeObject(forKey: ClipboardFlag.tokenKey)
    }
}

/// Gerçek defter: UserDefaults + önceki çalışmanın günlüğü + pano işareti (iOS uygulamanın kendini yeniden açmasına izin vermez;
/// yeniden açmayı yalnız Kestirmeler otomasyonu yapar, işareti de o okur).
@MainActor
final class RunJournal: RunJournaling {
    private enum Key {
        static let hasRun = "journal.hasRun"
        static let open = "journal.sessionOpen"
        static let deliberate = "journal.deliberateClose"
        static let alive = "journal.lastAlive"
        static let pending = "journal.pending"
        static let next = "journal.nextNumber"
        static let folder = "journal.folder"
        static let unexpected = "journal.unexpectedTimes"
        static let markerInit = "journal.clipboardMarkerInit"
    }

    private let defaults: UserDefaults
    private let previousLog: [String]
    private let now: () -> Date
    private let clipboard: ClipboardFlag
    /// Şu an oturum açık mı (yalnız bu çalışma için; pano işareti buna göre yönetilir)
    private var open = false

    init(defaults: UserDefaults = .standard,
         previousLog: [String] = AppLog.shared.previousRun,
         now: @escaping () -> Date = { Date() },
         clipboard: ClipboardFlag? = nil) {
        self.defaults = defaults
        self.previousLog = previousLog
        self.now = now
        self.clipboard = clipboard ?? ClipboardFlag(defaults: defaults)
    }

    func beginRun() -> RunStart {
        let hadRun = defaults.bool(forKey: Key.hasRun)
        let wasOpen = defaults.bool(forKey: Key.open)
        let deliberate = defaults.bool(forKey: Key.deliberate)
        let alive = defaults.object(forKey: Key.alive) as? Double
        defaults.set(true, forKey: Key.hasRun)
        defaults.set(false, forKey: Key.deliberate)
        // Pano işareti hiç yazılmamışsa (ilk kurulum ya da bu özellikten önceki sürümden güncelleme) oturum yokken otomasyon uygulamayı
        // geri çekmesin diye bir kez yazılır; sonraki açılışlarda kullanıcının panosuna dokunulmaz (anahtar kopyalayıp açtıysa kaybolmasın)
        if !defaults.bool(forKey: Key.markerInit) {
            defaults.set(true, forKey: Key.markerInit)
            if !wasOpen { clipboard.set(ClipboardFlag.closed) }
        }

        let exit: PreviousExit = hadRun ? ExitAnalyzer.analyze(sessionOpen: wasOpen, deliberate: deliberate, previous: previousLog) : .firstRun
        let stamp = now().timeIntervalSince1970
        var loop = false
        if case .unexpected = exit {
            var times = (defaults.array(forKey: Key.unexpected) as? [Double]) ?? []
            times = times.filter { stamp - $0 < SessionViewModel.Timing.loopWindow } + [stamp]
            defaults.set(times, forKey: Key.unexpected)
            loop = times.count >= SessionViewModel.Timing.loopLimit
        } else {
            defaults.removeObject(forKey: Key.unexpected)
        }
        var pending: PendingWork?
        if let data = defaults.data(forKey: Key.pending) { pending = try? JSONDecoder().decode(PendingWork.self, from: data) }
        let next = max(1, defaults.integer(forKey: Key.next))
        return RunStart(exit: exit,
                        pending: pending,
                        nextNumber: next,
                        folder: defaults.string(forKey: Key.folder),
                        downSeconds: alive.map { Int(max(0, stamp - $0)) },
                        loop: loop)
    }

    func setSessionOpen(_ open: Bool) {
        self.open = open
        defaults.set(open, forKey: Key.open)
        if open {
            heartbeat()
            clipboard.clearIfOurs()   // oturum sürerken panoda işaret olmaz: uygulama kapanırsa otomasyon geri açar
        } else {
            clipboard.set(ClipboardFlag.closed)
        }
    }

    func setAway(_ away: Bool) {
        if away {
            clipboard.set(ClipboardFlag.repair)
        } else if open {
            clipboard.clearIfOurs()
        } else {
            clipboard.set(ClipboardFlag.closed)
        }
    }

    func heartbeat() {
        defaults.set(now().timeIntervalSince1970, forKey: Key.alive)
    }

    func savePending(_ work: PendingWork?) {
        if let work = work, let data = try? JSONEncoder().encode(work) {
            defaults.set(data, forKey: Key.pending)
        } else {
            defaults.removeObject(forKey: Key.pending)
        }
    }

    func saveNextNumber(_ number: Int) {
        defaults.set(number, forKey: Key.next)
    }

    func saveFolder(_ name: String?) {
        if let name = name { defaults.set(name, forKey: Key.folder) } else { defaults.removeObject(forKey: Key.folder) }
    }

    func markDeliberateClose() {
        open = false
        defaults.set(true, forKey: Key.deliberate)
        defaults.set(false, forKey: Key.open)
        clipboard.set(ClipboardFlag.closed)
        defaults.synchronize()   // program hemen çıkacak: bayrakların diske yazılması beklenir
    }
}
