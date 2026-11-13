import Foundation

/// Bir karedeki bir soru adayı (ölçümlerle birlikte)
struct ShotCandidate: Equatable {
    /// Çekimdeki kare sırası (zaman sırasıyla 0'dan)
    var frame: Int
    var block: QuestionBlock
    /// Yazı netliği (GuidanceAnalyzer ölçüsü: keskinde 1'in üstü, bulanıkta 0,5'in altı) ve parlama oranı
    var sharp: Double
    var glare: Double
}

/// Bir sorunun gönderime uygun olmama nedeni
enum ShotProblem: Equatable {
    case cutTop, cutBottom, cutSide, incomplete, blurry, glare, unreadable, tooSmall

    /// Düşük sayı önce söylenir (aynı anda birden çok sorun varsa tek cümle söylenir)
    var priority: Int {
        switch self {
        case .cutBottom: return 0
        case .cutTop: return 1
        case .cutSide: return 2
        case .incomplete: return 3
        case .blurry: return 4
        case .glare: return 5
        case .unreadable: return 6
        case .tooSmall: return 7
        }
    }
}

struct QualityConfig: Equatable {
    /// Bundan az netlik bulanık sayılır (Ayarlar: gevşek 0,30 / normal 0,45 / sıkı 0,60)
    var sharpFloor = 0.45
    /// Yazı kutusundaki parlama oranı bundan büyükse parlama var
    var glareLimit = 0.04
    /// Satırların ortalama OCR güveni bundan azsa yazı net okunmuyor (el, gölge, bulanıklık)
    var minConfidence = 0.5
    /// Satır aralığı (kadraj yüksekliği oranı) bundan küçükse yazı çok küçük
    var minPitch = 0.011

    static func floor(forSharpness setting: Int) -> Double {
        let floors = [0.30, 0.45, 0.60]
        return floors[min(max(setting, 0), 2)]
    }
}

/// Seçilen kareler ve (kabul edilmediyse) nedenleri
struct ShotSelection: Equatable {
    /// En iyiden başlayarak en çok 2 kare (aralarında en az 2 kare fark); boşsa soru gönderime uygun değil
    var picks: [ShotCandidate]
    /// Kabul edilmediyse en iyi adayın sorunları (önem sırasıyla); kabul edildiyse boş
    var problems: [ShotProblem]
}

/// Gönderime uygunluk denetimi ve en iyi kareyi seçme. Hepsi telefonda yapılır (tarama sırasında internet yoktur).
enum QualityGate {
    /// Seçilen ikinci karenin birincisinden en az bu kadar kare uzakta olması istenir (neredeyse aynı kareler iki kez eklenmesin)
    static let minFrameGap = 2
    /// İkinci kare birincinin puanından en çok bu kadar düşük olabilir (kötü kare "ikinci" diye eklenmez)
    static let secondScoreSlack = 25.0

    /// `allowOpen`: soru sayfanın altında sürüyor (devamı sonraki sayfada olabilir): eksik şık ve alt kenar kesiği sorun sayılmaz
    static func problems(_ c: ShotCandidate, config: QualityConfig, allowOpen: Bool = false) -> [ShotProblem] {
        var out: [ShotProblem] = []
        let b = c.block
        if b.contentCutBottom && !allowOpen { out.append(.cutBottom) }
        if b.contentCutTop { out.append(.cutTop) }
        if b.contentCutSide { out.append(.cutSide) }
        if !b.complete && !allowOpen && out.isEmpty { out.append(.incomplete) }
        if c.sharp < config.sharpFloor { out.append(.blurry) }
        if c.glare >= config.glareLimit { out.append(.glare) }
        if b.confidence < config.minConfidence { out.append(.unreadable) }
        if b.pitch < config.minPitch { out.append(.tooSmall) }
        return out.sorted { $0.priority < $1.priority }
    }

    /// Aynı sorunun kareleri arasında sıralama puanı (büyük = iyi): eksiksizlik, kadrajda tam durması, okunurluk, netlik, parlamasızlık, yazı boyu
    static func score(_ c: ShotCandidate) -> Double {
        var s = 0.0
        if c.block.complete { s += 100 }
        if c.block.insideFrame { s += 50 }
        s += 30 * min(max(c.block.confidence, 0), 1)
        s += 20 * min(max(c.sharp / 1.2, 0), 1)
        s -= 30 * min(max(c.glare * 10, 0), 1)
        s += 10 * min(max(c.block.pitch / 0.03, 0), 1)
        return s
    }

    /// Bir sorunun bütün adaylarından en iyi (en çok) iki kareyi seçer. Sorunsuz aday varsa yalnız onlar arasından seçilir.
    static func select(_ candidates: [ShotCandidate], config: QualityConfig, allowOpen: Bool = false) -> ShotSelection {
        guard !candidates.isEmpty else { return ShotSelection(picks: [], problems: []) }
        let ranked = candidates.sorted { score($0) > score($1) }
        let good = ranked.filter { problems($0, config: config, allowOpen: allowOpen).isEmpty }
        guard let first = good.first else {
            return ShotSelection(picks: [], problems: problems(ranked[0], config: config, allowOpen: allowOpen))
        }
        var picks = [first]
        let floor = score(first) - secondScoreSlack
        if let second = good.dropFirst().first(where: { abs($0.frame - first.frame) >= minFrameGap && score($0) >= floor }) {
            picks.append(second)
        }
        return ShotSelection(picks: picks, problems: [])
    }

    /// Sorunlar arasından söylenecek tek cümle (en önemli sorun). `number`: soru numarası (0 = bilinmiyor)
    static func spoken(_ problems: [ShotProblem], number: Int) -> String {
        guard let top = problems.sorted(by: { $0.priority < $1.priority }).first else { return "" }
        let who = number > 0 ? TurkishNumbers.capitalised(TurkishNumbers.ordinal(number)) + " soru" : "Soru"
        switch top {
        case .cutBottom: return "\(who) alttan kesilmiş. Kamerayı biraz aşağı kaydırın."
        case .cutTop: return "\(who) üstten kesilmiş. Kamerayı biraz yukarı kaydırın."
        case .cutSide: return "\(who) yandan kesilmiş. Soruyu kadrajın ortasına alın."
        case .incomplete: return "\(who): şıklar eksik görünüyor. Kamerayı sabit tutun."
        case .blurry: return "Yazı bulanık. Kamerayı sabit tutun."
        case .glare: return "Parlama var. Kâğıdı hafifçe eğin."
        case .unreadable: return "Yazı net okunmuyor. Işığı ve kâğıdın düzgünlüğünü kontrol edin."
        case .tooSmall: return "Yazı çok küçük. Kamerayı kâğıda biraz yaklaştırın."
        }
    }
}
