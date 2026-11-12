import Foundation
import CoreGraphics

/// Sesli yönlendirmenin hedef kadrajı: karenin içinde, kare oranlarıyla (sensör yönünde) yatay aralık.
/// Dikey (portre) bir tam sayfa kadraj: sayfa kadrajı doldurunca "tamam" denir; yazı bu kadrajın dışına çıkarsa kaydırma önerilir.
/// Kamera karesi yatay 16:9 olduğundan dikey sayfa karenin yalnız ortadaki bölümünü kaplar. Fotoğraf bu kadraja kırpılmaz;
/// yalnız yönlendirme kararları bu kadrajı esas alır.
struct PageFrame: Equatable {
    var x0 = 0.0
    var x1 = 1.0

    var width: Double { return x1 - x0 }

    /// Bütün kare (eski davranış)
    static let full = PageFrame()

    /// A4 gibi dikey sayfanın en/boy oranı
    static let pageRatio = 1.0 / 2.0.squareRoot()

    /// Dikey tam sayfa. Ekranda gördüğünüz yönde sayfa görüntüyü boyuna (normal / 180°) ya da enine (90°) doldurur;
    /// 90° çevrilmiş görüntüde sensör karesinin dar kenarı sayfanın eni, geniş kenarı boyu olur.
    /// `aspect`: sensör karesinin en/boy oranı (kamera 16:9).
    static func verticalPage(orientation: ImageOrientation, aspect: Double = 16.0 / 9.0) -> PageFrame {
        let share = orientation.isQuarterTurn ? (1.0 / pageRatio) / aspect : pageRatio / aspect
        let w = min(1.0, max(0.05, share))
        return PageFrame(x0: (1 - w) / 2, x1: (1 + w) / 2)
    }
}

extension PageFrame {
    /// Ana ekrandaki dikey önizleme alanı (nokta): A4 oranlı; genişlik ekrana, boy ekranın yarısına sığar.
    static func previewBox(screen: CGSize, sideMargin: CGFloat = 32, maxHeightShare: CGFloat = 0.5) -> CGSize {
        let ratio = CGFloat(pageRatio)
        let h = max(60, min((screen.width - sideMargin) / ratio, screen.height * maxHeightShare))
        return CGSize(width: h * ratio, height: h)
    }
}

extension PageMetrics {
    /// Ölçüleri kadraj oranlarına çevirir: 0 kadrajın sol kenarı, 1 sağ kenarı. Kadrajın dışındaki yazı 0'ın altına / 1'in üstüne düşer.
    /// Dikey eksen değişmez (kadraj karenin bütün boyunu kaplar).
    func inFrame(_ f: PageFrame) -> PageMetrics {
        guard f != .full, f.width > 0 else { return self }
        func map(_ v: Double) -> Double { return (v - f.x0) / f.width }
        var m = self
        m.x0 = map(x0)
        m.x1 = map(x1)
        m.columns = columns.map { c in
            var b = c
            b.x0 = map(c.x0)
            b.x1 = map(c.x1)
            return b
        }
        return m
    }
}
