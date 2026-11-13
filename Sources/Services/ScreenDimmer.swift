import UIKit

/// Test sürerken (ayar açıksa) ve kırmızı uyarı yokken ekranı kısar, pil tasarrufu için; uygulama arka plana/pasife geçince kullanıcının
/// parlaklığını geri verir. (İlk sürümden alındı.)
@MainActor
final class ScreenDimmer {
    static let shared = ScreenDimmer()
    static let dimLevel: CGFloat = 0.05

    /// Kısılmadan önceki parlaklık diske de yazılır: program kısılıyken çökerse ya da zorla kapatılırsa sonraki açılışta geri verilir
    static let savedKey = "dimSavedBrightness"

    private let defaults = UserDefaults.standard
    private(set) var saved: CGFloat?
    var isDimmed: Bool { return saved != nil }

    func update(dim: Bool) {
        let screen = UIScreen.main
        if dim {
            if saved == nil {
                saved = screen.brightness
                defaults.set(Double(screen.brightness), forKey: ScreenDimmer.savedKey)
            }
            screen.brightness = ScreenDimmer.dimLevel
        } else if let value = saved {
            screen.brightness = value
            saved = nil
            defaults.removeObject(forKey: ScreenDimmer.savedKey)
        }
    }

    /// Önceki oturum parlaklık kısılıyken kapandıysa kullanıcının parlaklığını geri verir
    func restoreIfLeftDimmed() {
        guard saved == nil, let value = defaults.object(forKey: ScreenDimmer.savedKey) as? Double else { return }
        UIScreen.main.brightness = CGFloat(min(max(value, 0.05), 1.0))
        defaults.removeObject(forKey: ScreenDimmer.savedKey)
    }
}
