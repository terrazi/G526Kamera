import Foundation

/// Bir kare, okunmuş ve ölçülmüş hâliyle
struct AnalyzedFrame: Equatable {
    /// Çekimdeki kare sırası (zaman sırasıyla 0'dan)
    var index: Int
    var lines: [OCRLine]
    /// GuidanceAnalyzer ölçüleri: yazı netliği ve parlama oranı
    var sharp: Double
    var glare: Double
}

/// Bir çekimin (≈10 kare) karelerini soru soru toplar: her sorunun bütün adaylarından en iyi kareleri seçer. Saf mantıktır.
enum CaptureAnalyzer {
    static func analyze(_ frames: [AnalyzedFrame], total: Int, optionCount: Int, config: QualityConfig) -> CaptureAnalysis {
        var byNumber: [Int: [ShotCandidate]] = [:]
        var leading: [ShotCandidate] = []
        var firstSeen: [Int: Int] = [:]
        var layouts = frames.map { QuestionLayout.analyze(lines: $0.lines, total: total, optionCount: optionCount) }
        // Aynı yerdeki numara satırı kareden kareye farklı okunabilir (örn. 13 → 18): oy çokluğuyla düzeltilir. Yanlış okunan tek kare
        // sahte bir soru ("18. soru") olarak alınmasın diye.
        var observations: [NumberVoting.Observation] = []
        for (fi, layout) in layouts.enumerated() {
            for (bi, b) in layout.blocks.enumerated() {
                observations.append(NumberVoting.Observation(frame: fi, block: bi, column: b.column, y: b.contentTop, number: b.number))
            }
        }
        let limit = total > 0 ? total : QuestionLayout.maxQuestionNumber
        let fixed = NumberVoting.corrected(observations, limit: limit)
        for (k, o) in observations.enumerated() where fixed[k] != o.number {
            layouts[o.frame].blocks[o.block].number = fixed[k]
        }
        for (fi, f) in frames.enumerated() {
            let layout = layouts[fi]
            // Karedeki ilk (en üstteki, ilk sütundaki) numaralı soru: baştaki numarasız parçanın sahibini belirler
            if let top = layout.blocks.filter({ $0.column == 0 }).first ?? layout.blocks.first {
                firstSeen[top.number, default: 0] += 1
            }
            for b in layout.blocks {
                byNumber[b.number, default: []].append(ShotCandidate(frame: f.index, block: b, sharp: f.sharp, glare: f.glare))
            }
            // Numarasız başlangıç parçası yalnız şık içeriyorsa devam parçası sayılır (başlık / sayfa numarası satırları değil)
            if let l = layout.leading, !l.options.isEmpty {
                leading.append(ShotCandidate(frame: f.index, block: l, sharp: f.sharp, glare: f.glare))
            }
        }
        var outcomes: [QuestionOutcome] = []
        for n in byNumber.keys.sorted() {
            let cands = byNumber[n] ?? []
            let full = QualityGate.select(cands, config: config)
            var open = ShotSelection(picks: [], problems: [])
            let openCands = cands.filter { $0.block.opensBelow }
            if full.picks.isEmpty && !openCands.isEmpty {
                open = QualityGate.select(openCands, config: config, allowOpen: true)
            }
            outcomes.append(QuestionOutcome(number: n, full: full, open: open))
        }
        var contFull: ShotSelection?
        var contOpen: ShotSelection?
        if !leading.isEmpty {
            contFull = QualityGate.select(leading, config: config)
            contOpen = QualityGate.select(leading, config: config, allowOpen: true)
        }
        return CaptureAnalysis(outcomes: outcomes, continuationFull: contFull, continuationOpen: contOpen,
                               frameCount: frames.count, generalProblems: generalProblems(frames, config: config),
                               firstNumber: mostSeen(firstSeen))
    }

    /// En çok karede görülen numara (eşitlikte küçük olan): tek karedeki yanlış okuma sonucu bozmaz
    static func mostSeen(_ counts: [Int: Int]) -> Int? {
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.first?.key
    }

    /// Hiçbir soru bulunamadığında nedeni: yazı hiç okunmuyor, bulanık ya da parlama
    static func generalProblems(_ frames: [AnalyzedFrame], config: QualityConfig) -> [ShotProblem] {
        guard !frames.isEmpty else { return [.unreadable] }
        let sharp = frames.map { $0.sharp }.reduce(0, +) / Double(frames.count)
        let glare = frames.map { $0.glare }.max() ?? 0
        let lineMax = frames.map { $0.lines.count }.max() ?? 0
        if lineMax >= 5 && glare >= config.glareLimit { return [.glare] }
        if sharp < config.sharpFloor { return [.blurry] }
        return [.unreadable]
    }
}

/// Bir çekimdeki kareler arasında aynı yerdeki numara satırının oylanması
enum NumberVoting {
    struct Observation: Equatable {
        var frame: Int
        var block: Int
        var column: Int
        /// Numara satırının üst kenarı (kadraj yüksekliği oranı)
        var y: Double
        var number: Int
    }

    /// Aynı sütunda ve bu kadar yakın (kadraj oranı) numara satırları aynı sorunun satırı sayılır
    static let positionTolerance = 0.03

    /// Her gözlemin düzeltilmiş numarası (girdiyle aynı sırada). Aynı yerdeki gözlemlerden çoğunluk numarası (en az 2 kare) sayılır;
    /// kendisinden en az iki kat az oy alan başka numaralar çoğunluğa çevrilir. Eşit ya da yakın oyda dokunulmaz (sayfa çevrilmiş olabilir).
    static func corrected(_ obs: [Observation], limit: Int) -> [Int] {
        var out = obs.map { $0.number }
        let order = obs.indices.sorted { obs[$0].y < obs[$1].y }
        var clusters: [[Int]] = []
        var means: [Double] = []
        for i in order {
            var placed = false
            for c in clusters.indices {
                guard obs[clusters[c][0]].column == obs[i].column, abs(means[c] - obs[i].y) <= positionTolerance else { continue }
                clusters[c].append(i)
                means[c] = clusters[c].map { obs[$0].y }.reduce(0, +) / Double(clusters[c].count)
                placed = true
                break
            }
            if !placed {
                clusters.append([i])
                means.append(obs[i].y)
            }
        }
        for members in clusters where members.count >= 3 {
            var counts: [Int: Int] = [:]
            for i in members { counts[obs[i].number, default: 0] += 1 }
            guard let top = counts.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }),
                  top.value >= 2, top.key >= 1, top.key <= limit else { continue }
            for i in members where obs[i].number != top.key {
                if (counts[obs[i].number] ?? 0) * 2 <= top.value { out[i] = top.key }
            }
        }
        return out
    }
}
