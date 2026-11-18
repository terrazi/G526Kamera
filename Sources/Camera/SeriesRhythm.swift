import Foundation

/// Toplu çekimin ritmi (kullanıcı kararı 2026-11-18): koç artık kadraj aramaz, tempo tutar. Her kitapçık sayfası için sabit bir sıra vardır:
/// tüm sayfa → üst → orta üst → orta alt → alt (dilim başına `slotSeconds` sn) → sayfa çevirme (`turnSeconds` sn). Varsayılan 4 sn dilim ve 5 sn çevirme
/// sayfa başına 25 sn eder: 125 sn = 5 sayfa. Her dilimin en net karesi alınır; dilimin ilk `settleSeconds` saniyesi (kullanıcı hâlâ yerleşiyor) sayılmaz.
/// Ritim saf bir hesaptır (birim testle denenir); ses ve kare seçimi onu `CameraCaptureController` / `SeriesCollector` üzerinden kullanır.
struct SeriesRhythm: Equatable {
    /// Bir sayfanın dilimleri, zaman sırasıyla
    enum Part: Int, CaseIterable {
        case whole, top, upperMiddle, lowerMiddle, bottom, turn

        /// Bir kare alınan dilim mi (sayfa çevirme alınmaz)
        var isShot: Bool { return self != .turn }

        /// Günlük ve Gemini notu için ad
        var title: String {
            switch self {
            case .whole: return "tüm sayfa"
            case .top: return "üst"
            case .upperMiddle: return "orta üst"
            case .lowerMiddle: return "orta alt"
            case .bottom: return "alt"
            case .turn: return "sayfa çevirme"
            }
        }
    }

    struct Position: Equatable {
        /// 1'den başlar
        var page: Int
        var part: Part
        /// Diliminin başı ve sonu (çekim başından beri sn) ve içinde geçen süre
        var start: TimeInterval
        var end: TimeInterval
        var into: TimeInterval
    }

    var slotSeconds: TimeInterval = 4
    var turnSeconds: TimeInterval = 5
    /// Dilim başladıktan sonra bu kadar sn kare sayılmaz: sesli komut söylenir, kullanıcı telefonu yeni yere götürür
    var settleSeconds: TimeInterval = 1.5

    static let standard = SeriesRhythm()

    /// Bir sayfadaki alınan dilim sayısı (tüm sayfa + dört parça)
    static let shotsPerPage = 5
    /// Her diliminden alınan kare sayısı (kullanıcı kararı 2026-11-18: sayfa başına 10, beş sayfada 50 görüntü): dilimin yerleşmeden sonraki süresi bu kadar eşit
    /// parçaya bölünür, her parçanın en net karesi alınır. Biri bulanık ya da bozuk çıkarsa öteki Gemini'ye yetişir
    static let framesPerSlot = 2
    /// "Tüm sayfa" karesi PDF'e bu ölçek ve JPEG kalitesiyle girer: yalnız düzeni ve soru numaralarını göstermesi yeter
    static let wholeScale = 0.75
    static let wholeQuality = 0.75

    var pageSeconds: TimeInterval { return slotSeconds * Double(SeriesRhythm.shotsPerPage) + turnSeconds }

    /// Süreye sığan tam sayfa sayısı (en az 1)
    func pages(in seconds: Int) -> Int {
        return max(1, Int((Double(seconds) / pageSeconds).rounded(.down)))
    }

    /// Süre sayfa sayısına tamamlanır: ritim yarım sayfa bırakmaz. 125 → 125 (5 sayfa), 130 → 125, 10 → 25
    func roundedSeconds(_ seconds: Int) -> Int {
        return Int((Double(pages(in: seconds)) * pageSeconds).rounded())
    }

    /// Anın (çekim başından beri sn) hangi sayfada hangi dilimde olduğu; çekim başlamadıysa nil
    func position(at time: TimeInterval) -> Position? {
        guard time >= 0, pageSeconds > 0 else { return nil }
        let page = Int(time / pageSeconds)
        var cursor = Double(page) * pageSeconds
        for part in Part.allCases {
            let length = part == .turn ? turnSeconds : slotSeconds
            if time < cursor + length {
                return Position(page: page + 1, part: part, start: cursor, end: cursor + length, into: time - cursor)
            }
            cursor += length
        }
        // Kayan nokta payı: sayfanın son anı bir sonraki sayfanın başı sayılır
        return Position(page: page + 2, part: .whole, start: cursor, end: cursor + slotSeconds, into: 0)
    }

    /// Dilimin sıra numarası: sayfa başına 6 dilim (sayfa çevirme dahil), 0'dan başlar
    static func slotIndex(page: Int, part: Part) -> Int {
        return (page - 1) * Part.allCases.count + part.rawValue
    }

    /// Bu anda gelen karenin ait olduğu dilim: yalnız alınan bir diliminin yerleşme süresinden sonraki kısmı; sayfa çevirmede ve yerleşirken nil.
    /// `sub`: dilimin kaçıncı parçası (0'dan `framesPerSlot - 1`'e); her parçanın en net karesi alınır
    func shotSlot(at time: TimeInterval) -> (index: Int, page: Int, part: Part, sub: Int)? {
        guard let p = position(at: time), p.part.isShot, p.into >= settleSeconds else { return nil }
        let width = max(0.001, (slotSeconds - settleSeconds) / Double(SeriesRhythm.framesPerSlot))
        let sub = min(max(0, Int((p.into - settleSeconds) / width)), SeriesRhythm.framesPerSlot - 1)
        return (SeriesRhythm.slotIndex(page: p.page, part: p.part), p.page, p.part, sub)
    }

    /// Bu anda biten alınan dilim (anın ±0,05 sn'si içinde sonu olan); sayfa çevirme ve dilim ortası için nil. Bozuk kare tekrarı bu anda kararlaştırılır
    func endingSlot(at time: TimeInterval) -> (index: Int, page: Int, part: Part)? {
        guard time > 0, let p = position(at: time - 0.01), p.part.isShot, abs(p.end - time) <= 0.05 else { return nil }
        return (SeriesRhythm.slotIndex(page: p.page, part: p.part), p.page, p.part)
    }

    /// Dilim numarasından sayfa ve dilim
    static func slot(index: Int) -> (page: Int, part: Part)? {
        guard index >= 0 else { return nil }
        let count = Part.allCases.count
        guard let part = Part(rawValue: index % count) else { return nil }
        return (index / count + 1, part)
    }

    /// Gemini'ye ve günlüğe giden kare etiketi: "2. sayfa, orta üst"
    static func label(page: Int, part: Part) -> String {
        return "\(page). sayfa, \(part.title)"
    }

    /// Dilimin kaçıncı karesi olduğuyla: "2. sayfa, orta üst, 2. kare"
    static func label(page: Int, part: Part, sub: Int) -> String {
        return label(page: page, part: part) + ", \(sub + 1). kare"
    }

    /// Dilim başında kulaklıktan söylenecek kısa komut. `time` bir dilimin başlangıcıysa (±0,05 sn) söylenir, değilse nil. Son sayfanın çevirme payı sessizdir
    /// (çekim biter). Sayfa numarası "tüm sayfa" diliminde söylenir: kullanıcı hangi sayfada olduğunu bilir
    func cue(at time: TimeInterval, totalPages: Int) -> String? {
        guard let p = position(at: time), abs(time - p.start) <= 0.05 else { return nil }
        switch p.part {
        case .whole: return "\(Say.ordinalCapital(p.page)) sayfa, tüm sayfa."
        case .top: return "Üst."
        case .upperMiddle: return "Orta üst."
        case .lowerMiddle: return "Orta alt."
        case .bottom: return "Alt."
        case .turn: return p.page >= totalPages ? nil : "Sayfayı çevirin."
        }
    }
}

/// Bir diliminin neden geçerli kare vermediği (kullanıcı kararı 2026-11-18: bulanık kare, bozuk kare ve bir sorunun tamamını ya da çoğunu içine almayan kare
/// doğru kabul edilmez; dilimde geçerli kare yoksa dilim yeniden çektirilir). Sıra önceliktir: bir dilimde birden çok neden varsa küçük numaralısı söylenir
enum SlotProblem: Int, Comparable, CaseIterable {
    /// Blok bozulması (bloklaşmış kare)
    case damaged = 0
    /// Bulanık: kamera oynuyordu ya da yazı hiç okunamıyor (odak dışı, boş)
    case blurry = 1
    /// Yazı okunuyor ama kadrajda baştan sona görünen soru (ya da paragraf) yok: yalnız kesik soru parçaları
    case noQuestion = 2
    /// Parça bir önceki parçayla hiç ortak satır göstermiyor: arada atlanmış yer olabilir (parçalar kasten birbirini örter, Gemini onları ortak satırlardan birleştirir)
    case noOverlap = 3

    static func < (a: SlotProblem, b: SlotProblem) -> Bool { return a.rawValue < b.rawValue }

    /// Günlükte ve Gemini'ye giden etikette (geçerli kare yoksa dilimin yine de gönderilen karesi için)
    var note: String {
        switch self {
        case .damaged: return "bozuk kare"
        case .blurry: return "bulanık kare"
        case .noQuestion: return "soru tam görünmüyor"
        case .noOverlap: return "önceki parçayla örtüşmüyor"
        }
    }

    /// Bu nedenle bir dilim en çok kaç kez tekrarlanır. Soru bütünlüğü ve örtüşme telefonun hızlı yazı okumasına dayanır (gerçek günlüklerde karelerin
    /// yalnız üçte birinde bir sorunun numarası ve şıkları birlikte okunabildi): yanlış alarm süreyi yemesin diye bir kez; bozuk ve bulanık ölçümü kesindir
    func retryLimit(_ maxPerSlot: Int) -> Int {
        switch self {
        case .damaged, .blurry: return maxPerSlot
        case .noQuestion, .noOverlap: return min(1, maxPerSlot)
        }
    }
}

/// Bir karenin geçerli olup olmadığına karar verir (saf mantık; birim testle denenir). nil: geçerli.
/// Tüm sayfa dilimi yalnız bozuk ve bulanıklığa bakar (küçük yazıdan soru aranmaz: sayfa haritasıdır). Parça dilimlerinde ayrıca telefonun yazı okuyuşu
/// (`ViewLines`, kadraj koçunun soru bütünlüğü denetimi) istenir: yazı okunmalı ve baştan sona görünen en az bir soru ya da paragraf olmalı. Yazı okuma hiç
/// çalışmadıysa (`lines` nil) kare ELENMEZ: hızlı yazı tanıma bu kamerada zayıf kalabilir, bu yüzden "okuyamadım" tek başına veto sayılmaz
enum SlotCheck {
    /// Karede bu kadar harf okunabiliyorsa kare bulanık DEĞİLDİR, kamera o an oynuyor olsa bile (gerçek günlük 2026-11-18 21:01: elde tutulan kamera
    /// neredeyse hiç "durgun" ölçülmedi; 500–600 harfi okunan net kareler bulanık sayıldı, 42 karenin 29'u boşuna geçersiz oldu)
    static let readableChars = 60

    static func problem(damaged: Bool, still: Bool, part: SeriesRhythm.Part?, lines: ViewLines?, chars: Int? = nil) -> SlotProblem? {
        if damaged { return .damaged }
        let readable = (chars ?? 0) >= readableChars
        if !still && !readable { return .blurry }
        guard let part = part, part.isShot, part != .whole, let lines = lines else { return nil }
        if !lines.isReadable && !readable { return .blurry }
        if lines.completeQuestions >= 1 || lines.paragraph { return nil }
        return .noQuestion
    }

    /// Örtüşme ölçülebilmesi için iki parçada da en az bu kadar okunmuş sözcük gerekir; azsa hüküm verilmez
    static let minOverlapWords = 12
    /// Ortak sözcük oranı (küçük kümeye göre) bunun altındaysa parçalar örtüşmüyor sayılır. Parçalar yarı yarıya örtüşecek biçimde çekilir; hızlı yazı
    /// okuma aynı satırı her karede biraz başka okuduğu için eşik düşük tutulur (yalnız "hiç ortak satır yok" yakalanır)
    static let minOverlap = 0.08

    /// Parça bir öncekiyle ortak satır gösteriyor mu? Ölçülemiyorsa (sözcük az) true: şüphede tekrar istenmez
    static func overlaps(previous: Set<String>, current: Set<String>) -> Bool {
        guard previous.count >= minOverlapWords, current.count >= minOverlapWords else { return true }
        return TextScore.containment(previous, current) >= minOverlap
    }
}

/// Ritim saati (kullanıcı kararı 2026-11-18: kamerada blok bozulmaları olur; kullanıcı bunu bilmeli, sayfadan ayrılmamalı, o yerin temiz çekimi yeniden yapılabilmeli).
/// Bir alınan dilim bittiğinde dilimde YALNIZ bozuk kare görüldüyse dilim tekrarlanır: saat `slotSeconds` geri alınır (aynı dilim yeniden başlar), oturum o kadar uzar.
/// Dilim başına en çok `maxPerSlot`, oturumda en çok `maxTotal` tekrar; sınırlar dolunca ritim kaldığı yerden sessizce sürer.
/// Saat iki iş parçacığından okunur (kare toplayıcı kare zamanından dilimi bulur, kontrol döngüsü her saniye `step` çağırır); kilidin içinden dışarı çağrı yapılmaz.
final class RhythmClock {
    enum Step: Equatable {
        /// Bu saniyede söylenecek bir şey yok
        case silent
        /// Dilim başı komutu
        case cue(String)
        /// Bozuk kare: dilim tekrarlanıyor (söylenecek cümle, dilim numarası, kaçıncı deneme)
        case retry(String, slot: Int, attempt: Int)
    }

    let rhythm: SeriesRhythm
    let pages: Int
    let maxPerSlot: Int
    let maxTotal: Int
    private let lock = NSLock()
    private var shift: TimeInterval = 0
    private var attempts: [Int: Int] = [:]
    private var retried = 0
    private var held: TimeInterval = 0
    /// Görüntü kesilince saat en çok bu kadar sn bekletilir (sonra oturum zaten bırakılır)
    static let maxHoldSeconds: TimeInterval = 20

    init(rhythm: SeriesRhythm = .standard, pages: Int, maxPerSlot: Int = 2, maxTotal: Int = 6) {
        self.rhythm = rhythm
        self.pages = max(1, pages)
        self.maxPerSlot = maxPerSlot
        self.maxTotal = maxTotal
    }

    /// Tekrarlar yüzünden eklenen süre (sn)
    var offset: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return shift
    }

    /// Bu oturumda yapılan tekrar sayısı
    var retries: Int {
        lock.lock()
        defer { lock.unlock() }
        return retried
    }

    /// Tekrarsız süre: sayfa sayısı × sayfa süresi
    var baseSeconds: Int { return Int((Double(pages) * rhythm.pageSeconds).rounded()) }

    /// Şu ana kadarki toplam süre (tekrarlar dahil)
    var totalSeconds: Int { return baseSeconds + Int(offset.rounded()) }

    /// En çok eklenebilecek süre (sn)
    var maxExtraSeconds: Int { return Int((Double(maxTotal) * rhythm.slotSeconds + RhythmClock.maxHoldSeconds).rounded()) }

    /// Kameradan görüntü gelmiyor: saat bir saniye bekletilir (ritim ilerlemez, oturum o kadar uzar). Sınır dolduysa false döner
    @discardableResult
    func hold() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard held < RhythmClock.maxHoldSeconds else { return false }
        held += 1
        shift += 1
        return true
    }

    /// Oturum zamanından (çekim başından beri sn) ritim zamanına: tekrarlar kadar geri
    func rhythmTime(_ time: TimeInterval) -> TimeInterval { return time - offset }

    /// Bu saniyede biten dilimin numarası (yoksa nil): toplayıcı, tekrar kararından önce o dilimin karelerini değerlendirir (`SeriesCollector.settle`)
    func endingSlotIndex(at second: Int) -> Int? {
        lock.lock()
        let time = Double(second) - shift
        lock.unlock()
        return rhythm.endingSlot(at: time)?.index
    }

    func position(at time: TimeInterval) -> SeriesRhythm.Position? { return rhythm.position(at: rhythmTime(time)) }

    /// `generation`: o ana dek yapılan tekrar sayısı. Tekrarda saat geri alınır, aynı dilim yeniden başlar; kare toplayıcı anahtarı buna göre ayırır ki
    /// tekrardaki kareler ilk denemenin açık diliminin gerisinde sayılıp atılmasın
    func shotSlot(at time: TimeInterval) -> (index: Int, page: Int, part: SeriesRhythm.Part, sub: Int, generation: Int)? {
        lock.lock()
        let shifted = time - shift
        let generation = retried
        lock.unlock()
        guard let s = rhythm.shotSlot(at: shifted) else { return nil }
        return (index: s.index, page: s.page, part: s.part, sub: s.sub, generation: generation)
    }

    /// Her saniye çağrılır (`second`: çekim başından beri tam saniye). Biten dilimde yalnız bozuk kare varsa (`needsRetry`) dilim tekrarlanır ve saat geri alınır;
    /// yoksa dilim başı komutu verilir (varsa). `needsRetry` kilidin dışında çağrılır.
    func step(at second: Int, needsRetry: (Int) -> Bool) -> Step {
        return step(at: second, problem: { needsRetry($0) ? .damaged : nil })
    }

    /// Dilimde geçerli kare yoksa (`problem` nedeni verir) dilim tekrarlanır; söylenen cümle nedene göre değişir
    func step(at second: Int, problem: (Int) -> SlotProblem?) -> Step {
        lock.lock()
        let time = Double(second) - shift
        let used = retried
        lock.unlock()
        if let ending = rhythm.endingSlot(at: time), used < maxTotal {
            lock.lock()
            let tried = attempts[ending.index] ?? 0
            lock.unlock()
            if tried < maxPerSlot, let why = problem(ending.index), tried < why.retryLimit(maxPerSlot) {
                lock.lock()
                attempts[ending.index] = tried + 1
                retried += 1
                shift += rhythm.slotSeconds
                lock.unlock()
                return .retry(RhythmClock.retryText(problem: why, attempt: tried + 1), slot: ending.index, attempt: tried + 1)
            }
        }
        if let cue = rhythm.cue(at: time, totalPages: pages) { return .cue(cue) }
        return .silent
    }

    /// Nedene göre söylenen cümle: kullanıcı sayfadan ayrılmamalı, aynı yeri bir daha göstermeli
    static func retryText(problem: SlotProblem, attempt: Int) -> String {
        switch problem {
        case .damaged:
            return retryText(attempt: attempt)
        case .blurry:
            if attempt <= 1 { return "Görüntü bulanık. Sayfadan ayrılmayın, telefonu sabit tutup bu yeri tekrar gösterin." }
            return "Hâlâ bulanık. Sayfadan ayrılmayın, telefonu sabit tutup bir kez daha gösterin."
        case .noQuestion:
            if attempt <= 1 { return "Soru tam görünmüyor. Sayfadan ayrılmayın, soruyu ekrana alıp bu yeri tekrar gösterin." }
            return "Hâlâ soru tam değil. Sayfadan ayrılmayın, soruyu ortalayıp bir kez daha gösterin."
        case .noOverlap:
            if attempt <= 1 { return "Önceki parçayla örtüşmedi, arada yer kalmış olabilir. Sayfadan ayrılmayın, biraz yukarıdan bu yeri tekrar gösterin." }
            return "Hâlâ örtüşmüyor. Sayfadan ayrılmayın, biraz daha yukarıdan bir kez daha gösterin."
        }
    }

    /// Bozuk görüntüde söylenen cümle
    static func retryText(attempt: Int) -> String {
        if attempt <= 1 { return "Görüntü bozuldu. Sayfadan ayrılmayın, bu yeri tekrar gösterin." }
        return "Hâlâ bozuk. Sayfadan ayrılmayın, bir kez daha gösterin."
    }
}
