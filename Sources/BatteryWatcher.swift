import Foundation

/// Telefon şarjı düşünce her eşikte (yüzde 20, 10, 5) yalnız bir kez uyarmak için karar verir (saf mantık; birim testle denenir).
/// Şarja takılınca ya da yüzde 25'in üstüne çıkınca sıfırlanır.
struct LowBatteryWatcher {
    static let thresholds = [5, 10, 20]      // küçükten büyüğe
    static let resetAbove = 25

    private var announced = 100

    /// Uyarılacaksa şu anki yüzdeyi döndürür
    mutating func update(percent: Int?, charging: Bool) -> Int? {
        guard let p = percent else { return nil }
        if charging || p > Self.resetAbove {
            announced = 100
            return nil
        }
        for t in Self.thresholds where p <= t && t < announced {
            announced = t
            return p
        }
        return nil
    }
}
