import Foundation

/// Toplu çekimin ritmi. Kullanıcı kararı 2026-11-18 akşam (ilk cihaz denemesinden sonra): bölüm, köşe, sıra ve "tüm sayfa" tarifleri KALKTI (neresi olduğu
/// anlaşılmıyordu; sayfayı sığdırmak için uzaklaşınca yazı okunmuyor; sayfadaki soru sayısı ve paragraf boyu değişir, sabit bölme her zaman tutmaz).
/// Kullanıcı sayfaları SERBESTÇE tarar (hedef: oturum başına 2 sayfa), program komut vermez; yalnız her `slotSeconds` saniyede geçen süreyi söyler
/// ("10 saniye", "20 saniye"…). Tarama boyunca saniyede 2 kare (her yarım saniyenin en net karesi) alınır: 60 sn'de en çok 120 kare. Az sayfa, çok kare:
/// önemli olan soruların doğru okunmasıdır. "Dilim" artık 10 sn'lik bir zaman aralığıdır ("sayfa" hesabı = dilim sayısı); sayfa çevirme payı yoktur.
/// Ritim saf bir hesaptır (birim testle denenir); ses ve kare seçimi onu `CameraCaptureController` / `SeriesCollector` üzerinden kullanır.
struct SeriesRhythm: Equatable {
    /// Bir sayfanın dilimleri, zaman sırasıyla
    enum Part: Int, CaseIterable {
        case scan, turn

        /// Bir kare alınan dilim mi (sayfa çevirme alınmaz)
        var isShot: Bool { return self != .turn }

        /// Günlük ve Gemini notu için ad
        var title: String {
            switch self {
            case .scan: return "tarama"
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

    var slotSeconds: TimeInterval = 10
    /// Sayfa çevirme payı yok (0): kullanıcı sayfayı istediği an çevirir, o andaki bulanık kareler elenir
    var turnSeconds: TimeInterval = 0
    /// Dilim başında kare atlanmaz (0): komut yok, kullanıcı yer değiştirmiyor
    var settleSeconds: TimeInterval = 0

    static let standard = SeriesRhythm()

    /// "Sayfa" başına dilim sayısı (artık her 10 sn'lik aralık tek dilimdir)
    static let shotsPerPage = 1
    /// Her 10 sn'lik dilimden alınan kare sayısı (kullanıcı kararı 2026-11-18 akşam: saniyede 2 kare, 60 sn'de 120 kare): dilim yarım saniyelik parçalara
    /// bölünür, her parçanın en net ve bozuksuz karesi alınır. Kamera kaydırılırken bir kare bulanık ya da bozuk çıkarsa komşusu aynı yeri gösterir;
    /// dilimde geçerli kare varsa o dilimin geçersiz kareleri gönderilmez (sayfa çevirirken çekilenler böyle elenir)
    static let framesPerSlot = 20

    /// Sayfa denetimi (kullanıcı kararı 2026-11-18 akşam): her `reviewSeconds` saniyenin (bir sayfalık tarama) sonunda o sürede alınan karelere bakılır;
    /// kötüyse (geçerli kare `minGoodFrames`'ten az ya da karelerin `minGoodShare`'inden az) kullanıcıya neden söylenir (blok bozulması / bulanıklık) ve
    /// o sayfa bir kez yeniden taranır (oturum `reviewSeconds` uzar). Çekim sırasında başka uyarı verilmez
    static let reviewSeconds = 30
    static let minGoodFrames = 10
    static let minGoodShare = 1.0 / 3.0

    /// Bir sayfalık taramanın kareleri kötü mü? Hiç kare yoksa da kötüdür
    static func pageIsBad(valid: Int, damaged: Int, blurry: Int) -> Bool {
        let total = valid + damaged + blurry
        if valid < minGoodFrames { return true }
        return Double(valid) < Double(total) * minGoodShare
    }

    /// Bir soru numarası en az bu kadar karede okunduysa "görüldü" sayılır (yazı tanıma gürültüsü çoğu zaman tek karede kalır)
    static let confirmFrames = 2

    /// Sayfada görülen soru numaraları: en az `confirmFrames` karede okunanlar, küçükten büyüğe (`counts`: numara → kaç karede okundu)
    static func confirmedNumbers(_ counts: [Int: Int]) -> [Int] {
        return counts.filter { $0.key > 0 && $0.value >= confirmFrames }.keys.sorted()
    }

    /// Söylenecek "görülen sorular": art arda gelen numaraların en uzun dizisi, en az `minSpokenRun` numaraysa. Tek tük okunan sayılar (başka sayfanın
    /// numarası, şık / yıl / puan gibi yanlış okumalar) söylenmez (kullanıcı 2026-11-19: koç taranan sayfada olmayan numaraları söylüyordu).
    static let minSpokenRun = 3
    static func mainRun(_ numbers: [Int]) -> [Int] {
        var best: [Int] = []
        var current: [Int] = []
        for number in Array(Set(numbers)).sorted() {
            if let last = current.last, number == last + 1 { current.append(number) } else { current = [number] }
            if current.count > best.count { best = current }
        }
        return best.count >= minSpokenRun ? best : []
    }

    /// Sayfa işe yaradıysa (ya da ikinci taramada da zayıf kaldıysa) söylenen yönlendirme. `seen`: görülen soru numaraları (varsa söylenir);
    /// `barelyMoved`: hareket takibi kameranın hep aynı yerde kaldığını ölçtü (bkz. `MotionSummary.barelyMoved`)
    static func nextPageText(page: Int, good: Bool, seen: [Int] = [], barelyMoved: Bool = false) -> String {
        let name = Say.ordinalCapital(page)
        guard good else { return "\(name) sayfa yine zayıf; eldeki görüntüler gönderilecek. Sonraki sayfaya geçin." }
        var text = "\(name) sayfa tamam."
        if !seen.isEmpty { text += " Görülen sorular: \(Say.compactList(seen))." }
        if barelyMoved { text += " Kamera az kaydırıldı; sayfanın tamamı görünmemiş olabilir." }
        return text + " Sonraki sayfaya geçin."
    }

    /// Sayfa kötüyse söylenen cümle: neden (hangisi çoksa önce) ve ne yapılacağı
    static func reviewText(page: Int, damaged: Int, blurry: Int, fast: Bool = false) -> String {
        var why: String
        if damaged > 0 && blurry > 0 { why = damaged >= blurry ? "blok bozulmaları ve bulanıklık var" : "bulanıklık ve blok bozulmaları var" }
        else if damaged > 0 { why = "blok bozulmaları var" }
        else if blurry > 0 { why = "bulanıklık var" }
        else { why = "yeterli görüntü gelmedi" }
        // Hareket takibi kameranın hızlı kaydırıldığını ölçtüyse bulanıklığın nedeni söylenir
        if fast && blurry > 0 { why += "; kamera hızlı kaydırıldı" }
        return "\(Say.ordinalCapital(page)) sayfa okunamadı: \(why). Bu sayfayı yeniden, \(fast && blurry > 0 ? "daha yavaş" : "yavaşça") tarayın."
    }

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
        return Position(page: page + 2, part: .scan, start: cursor, end: cursor + slotSeconds, into: 0)
    }

    /// Dilimin sıra numarası: sayfa başına 2 dilim (kullanılmayan sayfa çevirme dahil), 0'dan başlar
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

    /// Gemini'ye ve günlüğe giden kare etiketi, karenin çekildiği zaman aralığıyla: "10–20. saniye"
    static func label(page: Int, part: Part) -> String {
        let length = Int(SeriesRhythm.standard.slotSeconds.rounded())
        return "\((page - 1) * length)–\(page * length). saniye"
    }

    /// Dilimin kaçıncı karesi olduğuyla: "10–20. saniye, 2. kare"
    static func label(page: Int, part: Part, sub: Int) -> String {
        return label(page: page, part: part) + ", \(sub + 1). kare"
    }

    /// Dilim başında kulaklıktan söylenecek kısa komut. `time` bir dilimin başlangıcıysa (±0,05 sn) söylenir, değilse nil. Son sayfanın çevirme payı sessizdir
    /// (çekim biter). Sayfa numarası "tüm sayfa" diliminde söylenir: kullanıcı hangi sayfada olduğunu bilir
    func cue(at time: TimeInterval, totalPages: Int) -> String? {
        guard let p = position(at: time), abs(time - p.start) <= 0.05 else { return nil }
        switch p.part {
        case .scan: return p.page <= 1 ? nil : "\(Int(p.start.rounded())) saniye."   // başta "Başladı" denir; sonra yalnız geçen süre
        case .turn: return nil
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
        guard let part = part, part.isShot, let lines = lines else { return nil }
        if !lines.isReadable && !readable { return .blurry }
        // Kamera kaydırılırken tek karede sorunun tamamı aranmaz: soru komşu karelerle tamamlanır (kullanıcı kararı 2026-11-18 akşam)
        return nil
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

    /// Varsayılan: tekrar yok (kullanıcı kararı 2026-11-18 akşam: komut verilmez). Tekrar düzeneği sınırlar verilince çalışır (testlerde ve ileride)
    init(rhythm: SeriesRhythm = .standard, pages: Int, maxPerSlot: Int = 0, maxTotal: Int = 0) {
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
    var maxExtraSeconds: Int {
        let redo = Double(baseSeconds)   // her sayfa en çok bir kez yeniden taranır
        return Int((Double(maxTotal) * rhythm.slotSeconds + RhythmClock.maxHoldSeconds + redo).rounded())
    }

    /// Sayfa yeniden taranacak: saat `seconds` geri alınır (aynı süre yeniden başlar), oturum o kadar uzar; kare anahtarı yeni "nesil"e geçer
    func redo(seconds: TimeInterval) {
        lock.lock()
        shift += seconds
        retried += 1
        lock.unlock()
    }

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
