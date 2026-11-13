import Foundation

/// Sayfa çekiminde (kamera sayfanın üstünde yakından gezdirilirken) toplanan bir kare, ölçüleriyle
struct SweepFrame: Equatable {
    /// Çekimdeki kare sırası (zaman sırasıyla 0'dan)
    var index: Int
    var time: TimeInterval
    /// GuidanceAnalyzer ölçüleri: yazı netliği (keskinde 1'in üstü) ve parlama oranı
    var sharp: Double
    var glare: Double
    /// Apple Vision'ın bulduğu kâğıt kenarları; bulunamadıysa nil
    var edges: PageEdges?
}

/// Sayfa kenarı denetimi kipi (Ayarlar > Tarama)
enum CoverageMode: Int {
    case off = 0
    case topBottom = 1
    case fourSides = 2

    /// Videoda görülmesi gereken kenarlar
    var required: [PageEdges.Side] {
        switch self {
        case .off: return []
        case .topBottom: return [.top, .bottom]
        case .fourSides: return [.top, .bottom, .left, .right]
        }
    }
}

/// Videonun bütününde sayfanın hangi kenarları görüldü. Kamera sayfada gezdirilince tek kareye bütün sayfa sığmaz; üst kenar bir karede,
/// alt kenar başka karede görülebilir. Kenarlar sürekli videoda göründüyse aradaki sayfa da kameradan geçmiş sayılır.
struct SweepCoverage: Equatable {
    /// En az bir karede kadrajın içinde (kesik olmayan) görünen kenarlar
    var seen: Set<PageEdges.Side>
    /// Kâğıt kenarı güvenilir bulunan kare sayısı
    var measured: Int
    var frameCount: Int

    /// Bundan az karede kenar bulunduysa sonuç güvenilmez sayılır ve denetim atlanır
    static let minMeasured = 3

    /// Eksik kenarlar (üst, alt, sol, sağ sırasıyla). Denetim kapalıysa, kenar yeterince ölçülemediyse ya da hepsi görüldüyse boş.
    func missing(_ mode: CoverageMode) -> [PageEdges.Side] {
        guard mode != .off, measured >= SweepCoverage.minMeasured else { return [] }
        return [PageEdges.Side.top, .bottom, .left, .right].filter { mode.required.contains($0) && !seen.contains($0) }
    }
}

enum PageSweep {
    static func coverage(_ frames: [SweepFrame]) -> SweepCoverage {
        var seen = Set<PageEdges.Side>()
        var measured = 0
        for f in frames {
            guard let e = f.edges, e.isReliable else { continue }
            measured += 1
            for side in PageEdges.Side.allCases where e.state(side) != .cut { seen.insert(side) }
        }
        return SweepCoverage(seen: seen, measured: measured, frameCount: frames.count)
    }

    /// Karenin Gemini'ye gidecek "net kare" olmaya uygunluğu (büyük = iyi): netlik ödüllendirilir, parlama cezalandırılır
    static func stillScore(_ f: SweepFrame) -> Double {
        return min(max(f.sharp / 1.2, 0), 1) - 1.5 * min(max(f.glare * 10, 0), 1)
    }

    /// Videodan seçilecek net kareler: zaman çizgisi `maxCount` eşit dilime bölünür, her dilimin en net karesi alınır (sayfanın bütün
    /// bölgeleri temsil edilsin). Kare sayısı `maxCount` ya da altındaysa hepsi alınır. Sonuç kare sırasıyla (zamana göre) verilir.
    static func stills(_ frames: [SweepFrame], maxCount: Int) -> [Int] {
        let sorted = frames.sorted { $0.index < $1.index }
        let limit = max(maxCount, 1)
        guard sorted.count > limit else { return sorted.map { $0.index } }
        var picks: [Int] = []
        for k in 0..<limit {
            let lo = k * sorted.count / limit
            let hi = (k + 1) * sorted.count / limit
            guard lo < hi else { continue }
            let slice = sorted[lo..<hi]
            if let best = slice.max(by: { stillScore($0) < stillScore($1) }) { picks.append(best.index) }
        }
        return picks.sorted()
    }
}

/// Alınmış bir sayfa: gezdirme videosu ve videodan seçilen net karelerin PDF'i (geçici dosyalar; Gemini'ye bunlar gider)
struct ScannedPage: Equatable {
    /// 1'den başlar
    var number: Int
    var pdf: URL?
    var video: URL?
    /// Deneme sınırı dolduğu için eksik görünmesine rağmen alınan sayfada görülmeyen kenarlar
    var missing: [PageEdges.Side]
}
