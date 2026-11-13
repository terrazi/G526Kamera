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
        for f in frames {
            let layout = QuestionLayout.analyze(lines: f.lines, total: total, optionCount: optionCount)
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
                               frameCount: frames.count, generalProblems: generalProblems(frames, config: config))
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
