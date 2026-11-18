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

    /// Bu anda gelen karenin ait olduğu dilim: yalnız alınan bir diliminin yerleşme süresinden sonraki kısmı; sayfa çevirmede ve yerleşirken nil
    func shotSlot(at time: TimeInterval) -> (index: Int, page: Int, part: Part)? {
        guard let p = position(at: time), p.part.isShot, p.into >= settleSeconds else { return nil }
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
