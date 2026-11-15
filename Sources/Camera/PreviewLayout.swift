import Foundation
import CoreGraphics

/// Ana ekrandaki önizleme kutusunun boyutu. Kamera karesi kırpılmaz, yalnız çevrilir: oran (16:9) değişmez,
/// Yatay kadrajda kutu yatay (16:9), Dikey kadrajda kutu dikey (9:16) olur ve kare 90° çevrilip kutuya tam oturur.
enum PreviewLayout {
    /// Kutu boyutu (nokta). Yatay: ekran genişliğinde 16:9. Dikey: 9:16, boyu ekranın en çok %60'ı.
    static func box(screen: CGSize, portrait: Bool = false, sideMargin: CGFloat = 32,
                    maxHeightShare: CGFloat = 0.6) -> CGSize {
        let available = max(60, screen.width - sideMargin)
        if !portrait {
            return CGSize(width: available, height: available * 9.0 / 16.0)
        }
        let h = max(60, min(available * 16.0 / 9.0, screen.height * maxHeightShare))
        return CGSize(width: h * 9.0 / 16.0, height: h)
    }
}
