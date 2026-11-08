import UIKit

/// Önizleme kapalıyken ekranı kısar; uygulama arka plana/pasife geçince kullanıcının parlaklığını geri verir.
@MainActor
final class ScreenDimmer {
    static let shared = ScreenDimmer()
    static let dimLevel: CGFloat = 0.05

    private(set) var saved: CGFloat?
    var isDimmed: Bool { return saved != nil }

    func update(dim: Bool) {
        let screen = UIScreen.main
        if dim {
            if saved == nil { saved = screen.brightness }
            screen.brightness = ScreenDimmer.dimLevel
        } else if let value = saved {
            screen.brightness = value
            saved = nil
        }
    }
}
