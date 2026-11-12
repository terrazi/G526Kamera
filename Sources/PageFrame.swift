import Foundation
import CoreGraphics

/// Hedef kadraj: karenin içinde, kare oranlarıyla (sensör yönünde) yatay aralık. Ayarlarda "Kadraj yönü" ile seçilir:
/// Dikey: A4 gibi dikey bir tam sayfa; Yatay: kamera karesi gibi 16:9 yatay kadraj (ekranda gördüğünüz yöne göre).
/// Sayfa kadrajı doldurunca "tamam" denir; yazı kadrajın dışına çıkarsa kaydırma önerilir. Önizleme kutusu da aynı kadrajı gösterir.
/// Fotoğraf bu kadraja kırpılmaz; yalnız yönlendirme kararları ve önizleme bu kadrajı esas alır.
struct PageFrame: Equatable {
    var x0 = 0.0
    var x1 = 1.0

    var width: Double { return x1 - x0 }

    /// Bütün kare (eski davranış)
    static let full = PageFrame()

    /// A4 gibi dikey sayfanın en/boy oranı
    static let pageRatio = 1.0 / 2.0.squareRoot()

    /// Kadraj: dikey (A4 oranı) ya da yatay (kamera karesi oranı, 16:9). Ekranda gördüğünüz yönde kadraj görüntüyü
    /// boyuna (normal / 180°) ya da enine (90°) doldurur; sensörde yalnız ortadaki yatay pay kalır (dikey eksen tamdır).
    /// `aspect`: sensör karesinin en/boy oranı (kamera 16:9). Yatay kadraj normal / 180°'de bütün karedir.
    static func region(portrait: Bool, orientation: ImageOrientation, aspect: Double = 16.0 / 9.0) -> PageFrame {
        let ratio = portrait ? pageRatio : aspect      // ekranda görünen kadrajın en/boy oranı
        let share = orientation.isQuarterTurn ? 1.0 / (aspect * ratio) : ratio / aspect
        let w = min(1.0, max(0.05, share))
        return PageFrame(x0: (1 - w) / 2, x1: (1 + w) / 2)
    }

    /// Dikey tam sayfa kadrajı
    static func verticalPage(orientation: ImageOrientation, aspect: Double = 16.0 / 9.0) -> PageFrame {
        return region(portrait: true, orientation: orientation, aspect: aspect)
    }
}

extension PageFrame {
    /// Ana ekrandaki önizleme alanı (nokta). Dikey: A4 oranlı, genişlik ekrana, boy ekranın yarısına sığar.
    /// Yatay: ekran genişliğinde 16:9.
    static func previewBox(screen: CGSize, portrait: Bool = true, sideMargin: CGFloat = 32,
                           maxHeightShare: CGFloat = 0.5) -> CGSize {
        let available = max(60, screen.width - sideMargin)
        if !portrait {
            return CGSize(width: available, height: available * 9.0 / 16.0)
        }
        let ratio = CGFloat(pageRatio)
        let h = max(60, min(available / ratio, screen.height * maxHeightShare))
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
