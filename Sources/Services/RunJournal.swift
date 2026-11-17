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
    /// Soru, kamerayla çekilmiş ortak paragrafın görüntüleriyle birlikte gönderilmişti: yeniden sorulurken kayıtlı paragraf fotoğrafı yine eklenir
    var withPassagePhoto: Bool?
}

/// Kayıtlı ortak paragrafın kalıcı hâli (ses kaydı kalıcı tutulmaz: yalnız metin; kamerayla çekilmişse fotoğrafı, videosu değil).
/// Uygulama beklenmedik kapanırsa sonraki sorular yine paragrafla gider.
struct SavedPassage: Equatable {
    var text: String
    var english: String
    var all: [Int]
    var remaining: [Int]
    /// Kamerayla çekilen paragrafın fotoğrafı (JPEG). Büyük olduğu için ayarlarda değil ayrı bir dosyada durur (bkz. `RunJournal`)
    var photo: Data?
}

extension SavedPassage: Codable {
    /// Fotoğraf JSON'a girmez; `RunJournal` onu ayrı dosyada saklar ve `hasPhoto` ile yeniden bağlar
    private enum CodingKeys: String, CodingKey { case text, english, all, remaining, hasPhoto }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        english = try c.decode(String.self, forKey: .english)
        all = try c.decode([Int].self, forKey: .all)
        remaining = try c.decode([Int].self, forKey: .remaining)
        photo = nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encode(english, forKey: .english)
        try c.encode(all, forKey: .all)
        try c.encode(remaining, forKey: .remaining)
        try c.encode(photo != nil, forKey: .hasPhoto)
    }
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
    /// Oturum sürerken kayıtlı ortak paragraf (varsa)
    var passage: SavedPassage? = nil

    static let fresh = RunStart(exit: .firstRun, pending: nil, nextNumber: 1, folder: nil, downSeconds: nil, loop: false)
}

/// Beklenmedik kapanmadan sonra oturumu sürdürmek için gereken bilgi
struct ResumeInfo: Equatable {
    var cause: String
    var downSeconds: Int?
    var pending: PendingWork?
    var nextNumber: Int
    var folder: String?
    var passage: SavedPassage? = nil
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
    /// Kayıtlı ortak paragraf değişti (nil: yok)
    func savePassage(_ passage: SavedPassage?)
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
    func savePassage(_ passage: SavedPassage?) {}
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

/// Panodaki işaretin durumu (açılışta günlüğe yazılır)
enum ClipboardState: Equatable {
    /// Bizim işaretimiz yok (hiç yazılmadı ya da oturum için silindi): otomasyon uygulamayı açabilir
    case clean
    /// İşaret panoda duruyor: otomasyon uygulamayı açmaz
    case marker(String)
    /// İşaretten sonra pano başka bir şeyle değişmiş (işaret gitti)
    case overwritten

    var text: String {
        switch self {
        case .clean: return "yok (otomasyon açabilir)"
        case let .marker(name): return "\(name) (otomasyon açmaz)"
        case .overwritten: return "başkası değiştirmiş (işaret yok)"
        }
    }
}

/// Panodaki işaret. Kestirmeler'deki "uygulama kapanınca yeniden aç" otomasyonu panoyu okur: `SESLIKONTROL-` ile başlayan bir şey varsa
/// uygulamayı açmaz. iOS "Kapatıldı" tetikleyicisini uygulamadan başka uygulamaya geçildiğinde de çalıştırır; bu yüzden işaret yalnız
/// iki anda yazılır: "Programı kapat" düğmesi (KAPALI) ve uygulama kestirme çalıştırmak için bilerek başka uygulamaya geçerken (ONARIM).
/// Başka her durumda (oturum sürerken, oturum yokken, "Testi Bitir"den sonra) panoda işaret yoktur: uygulama bu düğme dışında
/// kapanırsa ya da ekrandan çıkılırsa otomasyon onu geri açar. İşaret her açılışta silinir.
/// Kullanıcının panosuna saygı: işaret ancak panoyu başka biri değiştirmediyse (değişim sayacı aynıysa) silinir.
final class ClipboardFlag {
    static let prefix = "SESLIKONTROL-"
    /// Oturum yok ya da kullanıcı bilerek kapattı
    static let closed = "SESLIKONTROL-KAPALI"
    /// Uygulama kestirme çalıştırmak için bilerek başka uygulamaya geçti
    static let repair = "SESLIKONTROL-ONARIM"

    private static let tokenKey = "journal.clipboardToken"
    private static let nameKey = "journal.clipboardMarker"
    /// Panodaki değişim sayacı bu değerse pano hâlâ bizim kopyaladığımız günlüğü (ve belki altında işareti) taşır
    private static let logCountKey = "journal.clipboardLogCount"
    private let defaults: UserDefaults
    private let write: (String) -> Void
    private let changeCount: () -> Int
    /// Kopyalanan günlüğün saklandığı dosya (işaret panoya yazılırken günlüğün üstüne yazılıp kaybolmasın diye)
    private let logFile: URL

    static var defaultLogFile: URL {
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("kopyalanan-gunluk.txt")
    }

    init(defaults: UserDefaults = .standard,
         write: @escaping (String) -> Void = { UIPasteboard.general.string = $0 },
         changeCount: @escaping () -> Int = { UIPasteboard.general.changeCount },
         logFile: URL = ClipboardFlag.defaultLogFile) {
        self.defaults = defaults
        self.write = write
        self.changeCount = changeCount
        self.logFile = logFile
    }

    /// Panoya kopyalanacak serbest metinden (günlük) işaret önekini çıkarır. Kestirmeler otomasyonu "pano SESLIKONTROL- içeriyorsa dur" der; kopyalanan
    /// günlükteki "pano işareti: SESLIKONTROL-KAPALI" satırları da bu koşulu sağlar ve pano o metinle dolu kaldıkça uygulama yukarı kaydırılarak
    /// kapatılınca otomasyon onu geri AÇMAZ (17.11.2026: günlük kopyalandıktan sonra kapanma engellenemedi). Önekin tire'si iki noktayla değişir.
    static func defused(_ text: String) -> String {
        return text.replacingOccurrences(of: prefix, with: "SESLIKONTROL:", options: .caseInsensitive)
    }

    /// "Günlüğü kopyala" ile panoya konan metin: cihaz özeti ve günlük satırları, işaret öneki çıkarılmış olarak (`defused`)
    static func logText(info: String, lines: [String]) -> String {
        return defused(info + "\n\n" + lines.joined(separator: "\n"))
    }

    /// "Günlüğü kopyala": günlüğü panoya koyar ve bir kopyasını saklar. Sonradan kapanma / kestirme işareti yazılırken günlük silinmez:
    /// işaret günlüğün altına eklenir, işaret kalkınca günlük geri konur (17.11.2026: günlük kopyalanıp program kapatılınca yapıştırılan
    /// şey yalnız "SESLIKONTROL-KAPALI" idi).
    func copyLog(_ text: String) {
        write(text)
        if (try? text.write(to: logFile, atomically: true, encoding: .utf8)) != nil {
            defaults.set(changeCount(), forKey: ClipboardFlag.logCountKey)
        } else {
            forgetLog()
        }
    }

    /// "Günlüğü kopyala" düğmesi: günlüğün ALTINA kapanma işareti de eklenir ve işaret bu etiketle tutulur. Kullanıcı günlüğü başka uygulamaya yapıştırmak için
    /// ana ekrana çıkacaktır; panoda işaret yoksa Kestirmeler otomasyonu programı hemen geri açar (17.11.2026: "ana ekrana gelemiyor, program yeniden açılıyor").
    /// Oturum olayları bu işareti silmez; uygulama yeniden öne gelince ya da açılışta silinir ve pano yalnız günlük olarak kalır.
    static let pasteHold = "GUNLUK-YAPISTIRMA"

    func copyLogForPaste(_ text: String) {
        copyLog(text)
        guard logOnBoard else { return }
        set(ClipboardFlag.closed)
        defaults.set(ClipboardFlag.pasteHold, forKey: ClipboardFlag.nameKey)
    }

    /// Pano şu an bizim kopyaladığımız günlüğü taşıyor mu (başkası panoyu değiştirmediyse sayaç aynıdır)
    private var logOnBoard: Bool {
        return defaults.object(forKey: ClipboardFlag.logCountKey) != nil && defaults.integer(forKey: ClipboardFlag.logCountKey) == changeCount()
    }

    private func keptLog() -> String? {
        guard let text = try? String(contentsOf: logFile, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }

    private func forgetLog() {
        guard defaults.object(forKey: ClipboardFlag.logCountKey) != nil else { return }
        defaults.removeObject(forKey: ClipboardFlag.logCountKey)
        try? FileManager.default.removeItem(at: logFile)
    }

    /// İşareti panoya yazar ve o andaki değişim sayacını saklar (sonradan başkası panoyu değiştirirse anlaşılsın diye).
    /// Pano kullanıcının kopyaladığı günlüğü taşıyorsa günlük korunur, işaret son satır olarak eklenir (otomasyon "SESLIKONTROL-" içeriyor mu diye
    /// metnin her yerine bakar, işaret nerede olursa olsun görür).
    func set(_ marker: String) {
        if logOnBoard, let log = keptLog() {
            write(log + "\n" + marker)
            defaults.set(changeCount(), forKey: ClipboardFlag.logCountKey)
        } else {
            forgetLog()
            write(marker)
        }
        defaults.set(changeCount(), forKey: ClipboardFlag.tokenKey)
        defaults.set(marker, forKey: ClipboardFlag.nameKey)
    }

    /// Panonun şu anki durumu (içeriği okunmaz: iOS'un "yapıştırmaya izin ver" sorusu çıkmaz). Açılışta günlüğe yazılır:
    /// yeniden açılma otomasyonu işe yaramadıysa işaretin engel olup olmadığı buradan anlaşılır.
    func state() -> ClipboardState {
        guard defaults.object(forKey: ClipboardFlag.tokenKey) != nil else { return .clean }
        if defaults.integer(forKey: ClipboardFlag.tokenKey) == changeCount() {
            return .marker(defaults.string(forKey: ClipboardFlag.nameKey) ?? "?")
        }
        return .overwritten
    }

    /// Pano hâlâ bizim yazdığımızsa işareti siler (altında kullanıcının kopyaladığı günlük varsa onu geri koyar, yoksa panoyu boşaltır);
    /// kullanıcı arada başka bir şey kopyaladıysa dokunmaz
    func clearIfOurs() {
        let logHere = logOnBoard
        if defaults.object(forKey: ClipboardFlag.tokenKey) != nil {
            if defaults.integer(forKey: ClipboardFlag.tokenKey) == changeCount() {
                if logHere, let log = keptLog() {
                    write(log)
                    defaults.set(changeCount(), forKey: ClipboardFlag.logCountKey)
                } else {
                    write("")
                }
            }
            defaults.removeObject(forKey: ClipboardFlag.tokenKey)
            defaults.removeObject(forKey: ClipboardFlag.nameKey)
        }
        // Pano artık günlüğü taşımıyorsa (kullanıcı başka şey kopyaladı) saklanan kopya da silinir
        if !logOnBoard { forgetLog() }
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
        static let passage = "journal.passage"
        static let next = "journal.nextNumber"
        static let folder = "journal.folder"
        static let unexpected = "journal.unexpectedTimes"
    }

    private let defaults: UserDefaults
    private let previousLog: [String]
    private let now: () -> Date
    private let clipboard: ClipboardFlag
    /// Uygulama onarım için bilerek Kestirmeler'e geçmiş durumda (yalnız bu çalışma için): pano işareti `ONARIM` kalır
    private var away = false
    /// "Programı kapat" düğmesi basıldı, program çıkıyor (yalnız bu çalışma için): pano işareti `KAPALI` kalır, bir daha değişmez
    private var closing = false
    /// Ayarlar > "Kapanma engeli": açıkken (varsayılan) kapanma yalnız "Programı kapat" düğmesiyle serbesttir, başka her kapanmayı otomasyon geri açar.
    /// Kapalıyken pano işareti (KAPALI) hep yerinde tutulur: otomasyon hiçbir kapanmada geri açmaz.
    var closeGuardEnabled: () -> Bool = { true }

    /// Pano işaretini ayara göre eşitler: engel açıkken işaret kalkar, kapalıyken KAPALI işareti yerinde durur (kullanıcı panoyu değiştirdiyse yeniden yazılır;
    /// panodaki kopyalanmış günlük korunur). Kestirmeye geçerken (`away`) ve düğmeyle kapatırken (`closing`) işarete dokunulmaz.
    func syncCloseGuard(releasingPasteHold: Bool = false) {
        if away || closing { return }
        if closeGuardEnabled() {
            // Günlük yeni kopyalandıysa işaret, kullanıcı başka uygulamaya geçip yapıştırana kadar kalır (program geri açılmasın)
            if !releasingPasteHold, case let .marker(name) = clipboard.state(), name == ClipboardFlag.pasteHold { return }
            clipboard.clearIfOurs()
        } else if clipboard.state() != .marker(ClipboardFlag.closed) {
            clipboard.set(ClipboardFlag.closed)
            tlog("[kapanma engeli] kapalı: pano işareti \(ClipboardFlag.closed) yazıldı; hiçbir kapanma otomasyonla geri açılmaz")
        }
    }

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
        if hadRun { tlog("[açılış] pano işareti: \(clipboard.state().text); önceki çalışmada oturum \(wasOpen ? "açıktı" : "kapalıydı")") }
        // Kapanma yalnız "Programı kapat" düğmesiyle serbesttir. Her açılışta eski işaret (düğmeyle kapatmadan ya da eski sürümden kalan
        // KAPALI) silinir; böylece oturum yokken ve "Testi Bitir"den sonra da bu düğme dışındaki her kapanma/çıkış otomasyonla geri açılır.
        // Kullanıcı arada kendi metnini kopyaladıysa o silinmez. (Kapanma engeli ayarı kapalıysa işaret hemen yeniden yazılır.)
        clipboard.clearIfOurs()
        syncCloseGuard()

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
        var passage: SavedPassage?
        if let data = defaults.data(forKey: Key.passage) {
            passage = try? JSONDecoder().decode(SavedPassage.self, from: data)
            if passage != nil, let had = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["hasPhoto"] as? Bool, had {
                passage?.photo = try? Data(contentsOf: RunJournal.passagePhotoURL)
            }
        }
        let next = max(1, defaults.integer(forKey: Key.next))
        return RunStart(exit: exit,
                        pending: pending,
                        nextNumber: next,
                        folder: defaults.string(forKey: Key.folder),
                        downSeconds: alive.map { Int(max(0, stamp - $0)) },
                        loop: loop,
                        passage: passage)
    }

    func setSessionOpen(_ open: Bool) {
        defaults.set(open, forKey: Key.open)
        if open { heartbeat() }
        // Oturum sürerken de, "Testi Bitir"den sonra da panoda işaret yoktur: program bu düğme dışında kapanırsa otomasyon geri açar.
        // (Onarım için Kestirmeler'e geçilirken ya da bilerek kapatılırken işarete dokunulmaz.)
        syncCloseGuard()
    }

    func setAway(_ away: Bool) {
        self.away = away
        if closing { return }
        if away {
            clipboard.set(ClipboardFlag.repair)
        } else {
            clipboard.clearIfOurs()
            syncCloseGuard()   // engel kapalıysa onarım işareti yerine KAPALI işareti geri konur
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

    func savePassage(_ passage: SavedPassage?) {
        if let passage = passage, let data = try? JSONEncoder().encode(passage) {
            defaults.set(data, forKey: Key.passage)
            if let photo = passage.photo {
                try? FileManager.default.createDirectory(at: RunJournal.passagePhotoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? photo.write(to: RunJournal.passagePhotoURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: RunJournal.passagePhotoURL)
            }
        } else {
            defaults.removeObject(forKey: Key.passage)
            try? FileManager.default.removeItem(at: RunJournal.passagePhotoURL)
        }
    }

    /// Kamerayla çekilen ortak paragrafın fotoğrafı (kalıcı klasör: önbellek gibi sistem tarafından silinmez, uygulama açılışında da silinmez)
    static var passagePhotoURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("paragraf", isDirectory: true).appendingPathComponent("paragraf.jpg")
    }

    func saveNextNumber(_ number: Int) {
        defaults.set(number, forKey: Key.next)
    }

    func saveFolder(_ name: String?) {
        if let name = name { defaults.set(name, forKey: Key.folder) } else { defaults.removeObject(forKey: Key.folder) }
    }

    func markDeliberateClose() {
        closing = true
        defaults.set(true, forKey: Key.deliberate)
        defaults.set(false, forKey: Key.open)
        clipboard.set(ClipboardFlag.closed)
        defaults.synchronize()   // program hemen çıkacak: bayrakların diske yazılması beklenir
    }
}
