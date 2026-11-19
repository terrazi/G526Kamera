import Foundation

/// Otomatik zamanlı başlatma (kullanıcı kararı 2026-11-19): "Başlat"a basılınca program hazır bekler, kameraya bağlanmaz. Kamera AÇILIŞ SAATİNDE açılır ve
/// kulaklıktan "Kameranın başlaması için lütfen 1. soruyu okutunuz" denir. İlk tarama şu üç tetikten hangisi önce gelirse onunla başlar:
/// (1) kamera beklenen SORUYU görür (numara + metin + en az iki şık): beşten geri sayılır; (2) EN GEÇ BAŞLAMA SAATİ gelir: duyurulur, on beşten geri sayılır;
/// (3) kullanıcı "Başla" / "Başlat" der (saatlerden bağımsız). Tetikler birbirini iptal eder. Bir kez tetiklendikten sonra taramalar sırayla sürer: her iki
/// sayfalık taramanın cevapları okununca kamera yeniden açılır, "Yeni iki sayfalık tarama 15 saniye sonra başlayacak" denir, son 5 saniyede beşten geri
/// sayılır ve tarama başlar. Ayarlardaki soru sayısı tamamlanınca bütün cevaplar baştan okunur ve sınav kapanır.
enum AutoStart {
    /// Soru görülünce geri sayım (sn)
    static let questionCountdown = 5
    /// En geç başlama saati (ya da sonraki taramalarda bekleme süresi) dolunca geri sayım (sn)
    static let deadlineCountdown = 15
    /// Karede soru yapısı görünüyor ama beklenen numara bu kadar süredir okunamıyor: söylenir ve yine de başlanır (yazı tanıma "1."i "l." okuyabilir)
    static let unreadSeconds: TimeInterval = 20
    /// Art arda bu kadar bakışta soru yapısı görünmezse "okunamıyor" süresi baştan sayılır (kâğıt çekilmiş)
    static let unreadResetLooks = 3
    /// "Soruyu okutunuz" dendikten sonra en geç başlama tetiği en erken bu kadar sn sonra çalışır (saat çoktan geçmiş olsa da kullanıcıya fırsat kalır)
    static let minGap: TimeInterval = 30
    /// Kapının nabzı (sn)
    static let tick: TimeInterval = 1
    /// Geçmişte kalmış bir saat en çok bu kadar eskiyse "saati geldi, hemen" sayılır; daha eskiyse bir sonraki gün kastedilmiştir
    static let recentPast: TimeInterval = 6 * 3600

    /// İki sayfalık taramalar arasındaki boşluk (sn; kullanıcı kararı 2026-11-19): duyurulur, son `questionCountdown` saniyesinde geri sayılır
    static let gapSeconds = 15
    static let firstNumberRange = 1...300
    /// Sınavın soru sayısı (0: belirtilmedi) ve sınav sonunda cevaplar baştan okunurken iki cevap arasındaki boşluk (sn)
    static let questionCountRange = 0...300
    static let finalGap: Double = 2

    /// Art arda bu kadar taramada soru bulunamazsa sınav kendiliğinden kapanır (kullanıcı kararı 2026-11-19: program sesli komut istemez; boş taramalar
    /// da sonsuza dek sürmez). Soru sayısı girilmemişse 2 (sayfalar bitmiş demektir); girilmişse 5 (soruların tamamı taranmadan kolay vazgeçilmez).
    static func emptyScanLimit(count: Int) -> Int {
        return count > 0 ? 5 : 2
    }

    /// Sıradaki istenecek soru: başlangıç sorusundan itibaren cevabı alınmamış en küçük numara (arada cevapsız kalan soru varsa o istenir)
    static func nextMissing(first: Int, answered: Set<Int>) -> Int {
        var number = max(1, first)
        while answered.contains(number) { number += 1 }
        return number
    }

    /// Sınav tamamlandı mı (kullanıcı kararı 2026-11-19: ayarlardaki soruların tamamı taranmadan program işine devam eder): soru sayısı belirtilmişse
    /// ve o sayıya kadar cevapsız soru kalmadıysa
    static func examComplete(count: Int, nextMissing: Int) -> Bool {
        return count > 0 && nextMissing > count
    }

    /// Bakışta taramayı başlatacak soru var mı; varsa numarası. Hiç cevap yokken yalnız istenen (başlangıç) soru tetikler; sonrasında istenen numara ya da
    /// daha ilerisindeki CEVAPSIZ bir soru yeter (cevaplanmış eski sayfa yeniden taranmasın).
    static func accepted(_ seen: Set<Int>, ask: Int, answered: Set<Int>) -> Int? {
        if answered.isEmpty { return seen.contains(ask) ? ask : nil }
        return seen.filter { $0 >= ask && !answered.contains($0) }.min()
    }

    /// İlk taramayı başlatan tetik
    enum Trigger: Equatable {
        /// Açılış saati geldi: kamera açılır (tarama başlamaz)
        case open
        /// Beklenen soru görüldü
        case question(Int)
        /// En geç başlama saati / bekleme süresi doldu
        case deadline
        /// Soru yapısı görünüyor ama numarası okunamadı
        case unreadable
        /// Sonraki taramalar: iki tarama arasındaki boşluk doldu
        case gap

        var logName: String {
            switch self {
            case .open: return "açılış saati geldi, kamera açılıyor"
            case .question(let number): return "\(number). soru görüldü"
            case .deadline: return "en geç başlama süresi doldu"
            case .unreadable: return "soru görünüyor ama numarası okunamadı"
            case .gap: return "taramalar arası boşluk doldu"
            }
        }
    }

    /// Gün içi dakikanın (0–1439) kastettiği an. Bugün henüz gelmediyse bugünkü saat; son `recentPast` içinde geçtiyse o geçmiş an (saati gelmiş sayılır);
    /// daha eskiyse yarınki saat (akşamdan "Başlat"a basılıp sabah saati beklenebilsin).
    static func moment(minutes: Int, now: Date, calendar: Calendar = .current) -> Date {
        let clamped = min(max(minutes, 0), 24 * 60 - 1)
        let today = calendar.date(bySettingHour: clamped / 60, minute: clamped % 60, second: 0, of: now) ?? now
        if today > now {
            // Gece yarısını yeni geçtiysek dünkü saat az önce geçmiş olabilir (23.50 saati, şimdi 00.10)
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), now.timeIntervalSince(yesterday) <= recentPast { return yesterday }
            return today
        }
        if now.timeIntervalSince(today) <= recentPast { return today }
        return calendar.date(byAdding: .day, value: 1, to: today) ?? today
    }

    /// Kulaklıktan söylenen saat: "9:05"
    static func clockText(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// Kapının durumu (oturum boyunca `SessionViewModel.auto` içinde tutulur)
    struct State: Equatable {
        /// Bu oturumda başlamış toplu çekim sayısı (hangi tetikle olursa olsun)
        var rounds = 0
        /// Art arda soru bulunamayan tarama sayısı ve o sayım yapılırken kayıtlı cevap sayısı (yeni cevap gelince sayı sıfırlanır)
        var emptyScans = 0
        var answersSeen = 0
        /// İlk taramanın saatleri hesaplandı mı
        var planned = false
        /// Kamera açılış anı (nil: hemen)
        var openAt: Date?
        /// En geç başlama anı (nil: yok)
        var latestAt: Date?
        /// "Soruyu okutunuz" dendiği an (kamera açık bekliyor)
        var promptedAt: Date?
        /// Soru yapısı görünüp numarası okunamayan ilk bakışın anı
        var unreadSince: Date?
        /// Art arda soru yapısı görünmeyen bakış sayısı
        var missed = 0
        /// Kameraya bakış sürüyor (üst üste bakılmaz)
        var looking = false
        /// Mikrofon çalışmıyor: komutsuz, yalnız otomatik tetiklerle sürülüyor
        var micGivenUp = false
        /// Soru sayısına ulaşıldı: cevaplar baştan okunuyor, bitince sınav kendiliğinden kapanır (menü sorulmaz)
        var finishing = false
    }
}
