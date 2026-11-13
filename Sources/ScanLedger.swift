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
}

/// Çekim sonucunda yapılacak iş
enum LedgerAction: Equatable {
    /// Soru eksiksiz alındı. `continuing`: önceki sayfadaki açık parçaya eklenerek tamamlandı
    case accept(number: Int, picks: [ShotCandidate], continuing: Bool)
    /// Soru sayfanın altında sürüyor: görünen kısım parça olarak saklanır, "devamını tutun" denir
    case startOpen(number: Int, picks: [ShotCandidate])
    /// Açık sorunun devam parçası alındı ama soru hâlâ bitmedi (üç sayfaya yayılan soru)
    case extendOpen(picks: [ShotCandidate])
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
    private(set) var openNumber: Int?
    private(set) var openPages: [URL] = []
    private(set) var duplicates = 0

    init(total: Int, optionCount: Int = 5, maxAttempts: Int = 5) {
        self.total = max(total, 0)
        self.optionCount = optionCount
        self.maxAttempts = max(maxAttempts, 0)
    }

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

    // MARK: Değişiklikler

    mutating func accept(number: Int, pages newPages: [URL], continuing: Bool) {
        let all = (continuing && openNumber == number) ? openPages + newPages : newPages
        pages[number] = all
        unreadable.remove(number)
        if openNumber == number {
            openNumber = nil
            openPages = []
        }
    }

    mutating func startOpen(number: Int, pages newPages: [URL]) {
        openNumber = number
        openPages = newPages
    }

    mutating func extendOpen(pages newPages: [URL]) {
        guard openNumber != nil else { return }
        openPages += newPages
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
        openNumber = nil
        openPages = []
    }
}

/// Bir çekimin çözümlemesinden, kayıt defterine göre yapılacak işleri çıkarır (saf)
enum ScanPlanner {
    static func plan(_ a: CaptureAnalysis, ledger: ScanLedger) -> [LedgerAction] {
        var actions: [LedgerAction] = []
        var continued: Int?
        // 1) Sayfanın başındaki parça: açık soru varsa onun devamıdır
        if let open = ledger.openNumber {
            if let full = a.continuationFull, !full.picks.isEmpty {
                actions.append(.accept(number: open, picks: full.picks, continuing: true))
                continued = open
            } else if let part = a.continuationOpen, !part.picks.isEmpty {
                actions.append(.extendOpen(picks: part.picks))
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
                actions.append(.startOpen(number: o.number, picks: o.open.picks))
            } else {
                actions.append(.reject(number: o.number, problems: o.full.problems))
            }
        }
        // 3) Hiçbir şey bulunamadı
        if actions.isEmpty { actions.append(.unidentified(problems: a.generalProblems)) }
        return actions
    }
}
