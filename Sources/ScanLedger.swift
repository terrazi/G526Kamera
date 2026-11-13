import Foundation

/// Bir sorunun bir çekimdeki sonucu: tam (eksiksiz) seçim ve (altta sürüyorsa) parça olarak seçim
struct QuestionOutcome: Equatable {
    var number: Int
    /// Soru eksiksiz ve okunaklı görüldü: seçilen kareler (boşsa nedenler `problems`te)
    var full: ShotSelection
    /// Soru sayfanın altında sürüyor (devamı sonraki sayfada olabilir) ve görünen kısım okunaklı: parça olarak seçilen kareler
    var open: ShotSelection
}

/// Bir çekimin (5 sn, ≈10 kare) çözümlemesi
struct CaptureAnalysis: Equatable {
    var outcomes: [QuestionOutcome]
    /// Sayfanın başındaki numarasız parça (açık bir sorunun devamı olabilir)
    var continuationFull: ShotSelection?
    var continuationOpen: ShotSelection?
    var frameCount: Int
    /// Hiçbir soru numarası bulunamadıysa en baskın sorun (bulanık, parlama, yazı okunmuyor)
    var generalProblems: [ShotProblem]
    /// Sayfadaki ilk (en üstteki) numaralı sorunun numarası: baştaki numarasız parça bundan bir öncekinin devamıdır.
    /// nil ise çekimdeki en küçük numara kullanılır.
    var firstNumber: Int? = nil
}

/// Çekim sonucunda yapılacak iş
enum LedgerAction: Equatable {
    /// Soru eksiksiz alındı. `continuing`: önceki sayfadaki açık parçaya eklenerek tamamlandı
    case accept(number: Int, picks: [ShotCandidate], continuing: Bool)
    /// Soru sayfanın altında sürüyor: görünen kısım parça olarak saklanır, "devamını tutun" denir
    case startOpen(number: Int, picks: [ShotCandidate])
    /// Açık sorunun devam parçası alındı ama soru hâlâ bitmedi (üç sayfaya yayılan soru)
    case extendOpen(number: Int, picks: [ShotCandidate])
    /// Sorunun alt kısmı (devamı) başından önce çekildi: soru numarasıyla saklanır, başı gelince birleştirilir
    case stashTail(number: Int, picks: [ShotCandidate])
    case reject(number: Int, problems: [ShotProblem])
    case duplicate(number: Int)
    /// Hiçbir soru bulunamadı
    case unidentified(problems: [ShotProblem])
}

/// Taramanın kayıt defteri: hangi sorular alındı, hangileri eksik, kaç kez denendi. Saf mantıktır (dosyalar yalnız adres olarak tutulur).
struct ScanLedger: Equatable {
    /// Taranacak soru sayısı (0 = girilmemiş)
    var total: Int
    /// Soru başına şık sayısı (4 ya da 5)
    var optionCount: Int
    /// Bir soru için en çok deneme (0 = sınırsız)
    var maxAttempts: Int

    /// Alınan soruların sayfa görüntüleri (JPEG dosyaları), sayfa sırasıyla
    private(set) var pages: [Int: [URL]] = [:]
    private(set) var attempts: [Int: Int] = [:]
    private(set) var unreadable: Set<Int> = []
    /// Başı alınmış, devamı bekleyen sorular (soru numarası → sayfa görüntüleri) ve açılış sırası (en son açılan sonda)
    private(set) var openParts: [Int: [URL]] = [:]
    private(set) var openOrder: [Int] = []
    /// Devamı (alt kısmı) alınmış, başı bekleyen sorular: sorular karışık sırada çekilince oluşur
    private(set) var tails: [Int: [URL]] = [:]
    /// Alınan soruların telefonda okunan metni (Gemini'ye PDF yerine metin göndermek için); metni birleştirilemeyen sorunun metni yoktur
    private(set) var texts: [Int: QuestionText] = [:]
    private var openTexts: [Int: QuestionText] = [:]
    private var tailTexts: [Int: QuestionText] = [:]
    private(set) var duplicates = 0

    init(total: Int, optionCount: Int = 5, maxAttempts: Int = 5) {
        self.total = max(total, 0)
        self.optionCount = optionCount
        self.maxAttempts = max(maxAttempts, 0)
    }

    /// En son açılan (devamı beklenen) soru
    var openNumber: Int? { return openOrder.last }
    /// Devamı beklenen bütün sorular, küçükten büyüğe
    var openNumbers: [Int] { return openOrder.sorted() }
    /// Yarım kalan sorular: başı ya da sonu alınmış, henüz tamamlanmamış
    var waitingNumbers: [Int] { return Array(Set(openParts.keys).union(tails.keys)).filter { pages[$0] == nil }.sorted() }
    func isOpen(_ n: Int) -> Bool { return openParts[n] != nil }
    func hasTail(_ n: Int) -> Bool { return tails[n] != nil }

    var acceptedNumbers: [Int] { return pages.keys.sorted() }
    func isAccepted(_ n: Int) -> Bool { return pages[n] != nil }

    /// Alınmamış ve "okunamadı" işaretlenmemiş sorular (soru sayısı girilmemişse boş)
    var missing: [Int] {
        guard total > 0 else { return [] }
        return (1...total).filter { pages[$0] == nil && !unreadable.contains($0) }
    }

    /// Okunamadı diye bırakılan sorular (deneme sınırı doldu ya da tarama süre / bekleme nedeniyle bitti)
    var unreadableNumbers: [Int] { return unreadable.filter { pages[$0] == nil }.sorted() }

    /// Bütün sorular alındı ya da (sınır dolduğu için) okunamadı sayıldı
    var isComplete: Bool { return total > 0 && missing.isEmpty }

    func attemptCount(_ n: Int) -> Int { return attempts[n] ?? 0 }

    /// Alttan kesik görünen soru için bu kadar uyarı yapılır; hâlâ sığmıyorsa (sayfa sonunda gerçekten bölünen soru) parça olarak kabul edilir
    static let warningsBeforePartial = 2

    /// Alttan kesik soru artık parça olarak alınabilir mi: yeterince uyarılmış ya da alt kısmı zaten çekilmiş
    func partialAllowed(_ n: Int) -> Bool {
        let need = maxAttempts > 0 ? min(ScanLedger.warningsBeforePartial, maxAttempts - 1) : ScanLedger.warningsBeforePartial
        return hasTail(n) || attemptCount(n) >= need
    }

    // MARK: Değişiklikler

    /// `continuing`: bu çekim, daha önce alınmış bir parçayla birleşir. Başı bekleyen soruya devam parçası eklenir; devamı bekleyen soruya baş eklenir.
    mutating func accept(number: Int, pages newPages: [URL], continuing: Bool, text: QuestionText? = nil) {
        var all = newPages
        var combined = text
        if continuing {
            if let head = openParts[number] {
                all = head + newPages
                combined = Self.join(openTexts[number], text)
            } else if let tail = tails[number] {
                all = newPages + tail
                combined = Self.join(text, tailTexts[number])
            }
        }
        pages[number] = all
        texts[number] = combined
        unreadable.remove(number)
        openParts[number] = nil
        openTexts[number] = nil
        openOrder.removeAll { $0 == number }
        tails[number] = nil
        tailTexts[number] = nil
    }

    /// İki parçanın metni birleşir; biri yoksa birleşik metin de yoktur (o soru PDF olarak gider)
    private static func join(_ first: QuestionText?, _ second: QuestionText?) -> QuestionText? {
        guard let a = first, let b = second else { return nil }
        return QuestionText.merged([a, b])
    }

    mutating func startOpen(number: Int, pages newPages: [URL], text: QuestionText? = nil) {
        openParts[number] = newPages
        openTexts[number] = text
        openOrder.removeAll { $0 == number }
        openOrder.append(number)
    }

    mutating func extendOpen(number: Int, pages newPages: [URL], text: QuestionText? = nil) {
        guard let head = openParts[number] else { return }
        openParts[number] = head + newPages
        openTexts[number] = Self.join(openTexts[number], text)
    }

    mutating func stashTail(number: Int, pages newPages: [URL], text: QuestionText? = nil) {
        guard pages[number] == nil else { return }
        tails[number] = newPages
        tailTexts[number] = text
    }

    /// Soru bu çekimde gönderime uygun çıkmadı. Deneme sınırı dolduysa soru "okunamadı" işaretlenir ve true döner.
    @discardableResult
    mutating func noteReject(number: Int) -> Bool {
        let n = (attempts[number] ?? 0) + 1
        attempts[number] = n
        if maxAttempts > 0 && n >= maxAttempts && !unreadable.contains(number) {
            unreadable.insert(number)
            return true
        }
        return false
    }

    mutating func noteDuplicate() { duplicates += 1 }

    /// Süre ya da bekleme doldu: kalan eksikler "okunamadı" sayılır
    mutating func giveUpOnMissing() {
        for n in missing { unreadable.insert(n) }
        openParts = [:]
        openTexts = [:]
        openOrder = []
        tails = [:]
        tailTexts = [:]
    }
}

/// Bir çekimin çözümlemesinden, kayıt defterine göre yapılacak işleri çıkarır (saf)
enum ScanPlanner {
    /// Sayfanın başındaki numarasız parçanın sahibi: sayfadaki ilk numaralı sorudan bir önceki soru. Soru numarasına bakıldığı için
    /// sorular hangi sırayla çekilirse çekilsin parça doğru soruya eklenir. Numaralı soru yoksa tek açık soru varsa o sayılır.
    static func tailOwner(_ a: CaptureAnalysis, ledger: ScanLedger) -> Int? {
        if let first = a.firstNumber ?? a.outcomes.map({ $0.number }).min() {
            return first >= 2 ? first - 1 : nil
        }
        let open = ledger.openNumbers
        return open.count == 1 ? open[0] : nil
    }

    static func plan(_ a: CaptureAnalysis, ledger: ScanLedger) -> [LedgerAction] {
        var actions: [LedgerAction] = []
        var continued: Int?
        // 1) Sayfanın başındaki parça: bir önceki sorunun devamıdır
        if let owner = tailOwner(a, ledger: ledger), !ledger.isAccepted(owner) {
            let full = a.continuationFull?.picks ?? []
            let part = a.continuationOpen?.picks ?? []
            if ledger.isOpen(owner) {
                if !full.isEmpty {
                    actions.append(.accept(number: owner, picks: full, continuing: true))
                    continued = owner
                } else if !part.isEmpty {
                    actions.append(.extendOpen(number: owner, picks: part))
                }
            } else if !full.isEmpty {
                // Sorunun başı henüz çekilmemiş (karışık sıra): sonu soru numarasıyla saklanır
                actions.append(.stashTail(number: owner, picks: full))
            }
        }
        // 2) Numaralı sorular
        for o in a.outcomes {
            if o.number == continued { continue }
            if ledger.isAccepted(o.number) {
                actions.append(.duplicate(number: o.number))
            } else if !o.full.picks.isEmpty {
                actions.append(.accept(number: o.number, picks: o.full.picks, continuing: false))
            } else if !o.open.picks.isEmpty {
                if ledger.hasTail(o.number) {
                    // sonu daha önce çekilmişse baş ile birleşip soru tamamlanır
                    actions.append(.accept(number: o.number, picks: o.open.picks, continuing: true))
                } else if ledger.partialAllowed(o.number) {
                    actions.append(.startOpen(number: o.number, picks: o.open.picks))
                } else {
                    // Yarım soru istenmez: önce "alttan kesilmiş" uyarısı verilir; birkaç uyarıya rağmen sığmazsa parça alınır
                    actions.append(.reject(number: o.number, problems: [.cutBottom]))
                }
            } else {
                actions.append(.reject(number: o.number, problems: o.full.problems))
            }
        }
        // 3) Hiçbir şey bulunamadı
        if actions.isEmpty { actions.append(.unidentified(problems: a.generalProblems)) }
        return actions
    }
}
