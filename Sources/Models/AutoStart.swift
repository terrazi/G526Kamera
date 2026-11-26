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
    /// Sonraki taramalar (kullanıcı kararı 2026-11-19 öğleden sonra): boşluk dolunca beklenen soru kamerada görülünce başlanır; soru görülmese de boşluk
    /// dolduktan en geç bu kadar sn sonra başlanır (gerçek günlük: ikinci tarama kullanıcı hazır olmadan başlamış, ilk 11 saniyenin kareleri boşa gitmişti)
    static let sequentialMaxWait: TimeInterval = 30
    static let firstNumberRange = 1...300
    /// Son aşamada eksik soruları okutmak için verilen süre (sn; kullanıcı kararı 2026-11-26: "kullanıcının mikrofondan talimatı olmayacak; yalnız
    /// eksik soruyu okutmak için süre verilmeli"). Bu sürede cevapsız bir soru kamerada görülürse taranır ve süre yeniden başlar; görülmezse bölüm /
    /// sınav kendiliğinden tamamlanır
    static let missingWindow: TimeInterval = 120
    /// Sınavın soru sayısı (0: belirtilmedi) ve sınav sonunda cevaplar baştan okunurken iki cevap arasındaki boşluk (sn)
    static let questionCountRange = 0...300
    static let finalGap: Double = 2

    /// Art arda bu kadar taramada soru bulunamazsa sınav kendiliğinden kapanır (kullanıcı kararı 2026-11-19: program sesli komut istemez; boş taramalar
    /// da sonsuza dek sürmez). Soru sayısı girilmemişse 10, girilmişse 20 tarama. Kapanan sınav bir sonraki "Başlat"ta kaldığı yerden sürer.
    static func emptyScanLimit(count: Int) -> Int {
        return count > 0 ? 20 : 10
    }

    /// "Başlat"ta önceki kayıt varken yeni sınav mı açılır (kullanıcı kararı 2026-11-19: kapanan sınav yarıda kaldığı yerden sürer, "Başlat" yeni sınav
    /// açmaz). Yeni sınav yalnız iki durumda açılır: kullanıcı "Yeni sınav başlat" düğmesine bastıysa, ya da önceki sınav TAMAMLANDIYSA (soru sayısına
    /// ulaşılıp cevaplar baştan okunarak kapandıysa; `finished` o sınavın klasör adıdır).
    static func startsNewExam(force: Bool, finished: String, previous: String?) -> Bool {
        if force { return true }
        guard let previous = previous, !finished.isEmpty else { return false }
        return finished == previous
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
    /// daha ilerisindeki CEVAPSIZ bir soru yeter (cevaplanmış eski sayfa yeniden taranmasın). `limit`: soru sayısı biliniyorsa ondan büyük numara soru
    /// sayılmaz (0: sınır yok).
    static func accepted(_ seen: Set<Int>, ask: Int, answered: Set<Int>, limit: Int = 0) -> Int? {
        if answered.isEmpty { return seen.contains(ask) ? ask : nil }
        return seen.filter { $0 >= ask && !answered.contains($0) && (limit <= 0 || $0 <= limit) }.min()
    }

    // MARK: Eksik sorular (kullanıcı kararı 2026-11-26)
    //
    // Kullanıcı eksik kalan soruyu okutmaya ZORLANMAZ: program sıradaki yeni soruyu ister, eksikleri yalnız hatırlatır; kullanıcı istediği soruyu
    // istediği sırayla gösterebilir, her cevap kendi numarasına kaydedilir. Sonda eksikler söylenir ve okutulmaları için süre verilir.

    /// Sıradaki YENİ soru: cevabı alınmış en büyük numaranın bir fazlası; hiç cevap yoksa başlangıç sorusu
    static func nextNew(first: Int, answered: Set<Int>) -> Int {
        let start = max(1, first)
        guard let highest = answered.max() else { return start }
        return max(start, highest + 1)
    }

    /// Başlangıç sorusundan `upTo` numarasına kadar cevabı olmayan sorular
    static func missing(first: Int, upTo: Int, answered: Set<Int>) -> [Int] {
        let start = max(1, first)
        guard upTo >= start else { return [] }
        return (start...upTo).filter { !answered.contains($0) }
    }

    /// Eksik listesinin üst sınırı: soru sayısı biliniyorsa ve son soruya ulaşıldıysa soru sayısı (sondaki eksikler de sayılır), yoksa cevabı alınmış
    /// en büyük numara (yalnız aradaki boşluklar eksiktir; henüz gelinmemiş sorular eksik sayılmaz). Soru sayısından büyük numaralar hesaba katılmaz.
    static func missingLimit(count: Int, answered: Set<Int>) -> Int {
        let valid = count > 0 ? answered.filter { $0 <= count } : answered
        return valid.max() ?? 0
    }

    /// Sona yakın sayılma eşiği: cevabı alınmış en büyük numara soru sayısına en çok bu kadar uzaksa ve art arda `tailStaleScans` tarama yeni cevap
    /// getirmediyse de son aşamaya geçilir (son soru hiç okunamazsa bölüm / sınav sonsuza dek açık kalmasın; mikrofonsuz kullanıcı bölümü elle bitiremez)
    static let tailQuestions = 5
    static let tailStaleScans = 2

    /// Son aşama mı: soru sayısı belli, sona gelinmiş ama eksik kalan var. Sona gelmek: son soru cevaplandı; ya da sona yakın (`tailQuestions`) olup
    /// art arda `tailStaleScans` tarama yeni cevap getirmedi (`staleScans`). Son aşamada eksikler söylenir ve okutulmaları için `missingWindow` kadar
    /// süre verilir. Soru sayısı belirtilmemişse son aşama yoktur.
    static func closing(count: Int, first: Int, answered: Set<Int>, staleScans: Int = 0) -> Bool {
        guard count > 0 else { return false }
        let highest = missingLimit(count: count, answered: answered)
        let reached = highest >= count || (highest >= 1 && highest >= count - tailQuestions && staleScans >= tailStaleScans)
        return reached && !missing(first: first, upTo: count, answered: answered).isEmpty
    }

    /// Ayarlar > Video kaydı: bölümlü sınavda soru sayısı Ayarlar > Sınav bölümleri'nden alınır; ekranda bunun nasıl yazıldığı ("50 + 50 = 100").
    /// `plan`: etkin bölümlerin soru sayıları (0: girilmemiş)
    static func sectionSummary(_ plan: [Int]) -> String {
        guard !plan.isEmpty else { return "" }
        if plan.contains(where: { $0 <= 0 }) {
            let parts = plan.enumerated().map { item -> String in
                let count = item.element > 0 ? String(item.element) : "girilmemiş"
                return "\(item.offset + 1). bölüm \(count)"
            }
            return "Sınavın soru sayısı bölümlerden alınıyor: " + parts.joined(separator: ", ") + ". Sayısı girilmemiş bölüm kendiliğinden tamamlanmaz."
        }
        if plan.count == 1 { return "Sınavın soru sayısı bölümden alınıyor: \(plan[0])" }
        return "Sınavın soru sayısı bölümlerden alınıyor: " + plan.map { String($0) }.joined(separator: " + ") + " = \(plan.reduce(0, +))"
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
        /// Son aşama: eksik sorular için verilen süre doldu (tarama başlamaz; bölüm / sınav tamamlanır)
        case windowOver

        var logName: String {
            switch self {
            case .open: return "açılış saati geldi, kamera açılıyor"
            case .question(let number): return "\(number). soru görüldü"
            case .deadline: return "en geç başlama süresi doldu"
            case .unreadable: return "soru görünüyor ama numarası okunamadı"
            case .gap: return "taramalar arası boşluk doldu"
            case .windowOver: return "eksik sorular için verilen süre doldu"
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
        /// En son yeni cevap geldiğinde başlamış tarama sayısı: `rounds` ile farkı, art arda yeni cevap getirmeyen tarama sayısıdır
        var roundsAtNew = 0
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
        /// Bölümün sonuna gelindi ve sırada bölüm var: cevaplar okunduktan sonra sormadan sonraki bölüme geçilir (kullanıcı kararı 2026-11-26)
        var advancing = false
        /// Son aşama: eksik sorular için verilen sürenin biteceği an (nil: son aşamada değil)
        var closingUntil: Date?
        /// Eksikler için verilen süre doldu: bölüm / sınav eksikleriyle tamamlanıyor
        var closingExpired = false
        /// En son hatırlatılan eksik sorular: liste değişmedikçe her taramada yeniden söylenmez
        var reminded: [Int] = []
        /// Gönderilen taramadan ÖNCE eksik olan sorular: cevapları bu taramada gelirse "tamamlandı" denir
        var missingBefore: [Int] = []
    }
}
