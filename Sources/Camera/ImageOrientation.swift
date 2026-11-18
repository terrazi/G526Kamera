import Foundation
import CoreGraphics
import ImageIO

/// Görüntü yönü: kamera yan ya da ters takıldığında resmi kullanıcının gördüğü gibi çevirir.
/// Önizleme, fotoğraf/PDF, video ve sesli yönlendirme aynı ayarı kullanır.
/// Ucuz yol: önizlemede katman dönüşümü, fotoğrafta tek CIImage dönüşümü, videoda dosya başlığındaki dönüş bilgisi;
/// kare kare piksel çevirme yoktur (ısınma ve pil için).
enum ImageOrientation: Int, CaseIterable {
    case normal = 0
    case right90 = 1      // resim saat yönünde 90° çevrilir
    case left90 = 2       // resim saat yönünün tersine 90° çevrilir
    case rotate180 = 3

    var title: String {
        switch self {
        case .normal: return "Normal"
        case .right90: return "90° sağa"
        case .left90: return "90° sola"
        case .rotate180: return "180°"
        }
    }

    /// Saat yönünde çeyrek dönüş sayısı (0, 1, 2, 3)
    var quarterTurns: Int {
        switch self {
        case .normal: return 0
        case .right90: return 1
        case .rotate180: return 2
        case .left90: return 3
        }
    }

    /// Sesli yönlendirmede dönüş: yazının okunduğu dik görüntüden (`detected` yönüyle çevrilmiş) kullanıcının gördüğü görüntüye (`base`) saat yönünde çeyrek
    /// dönüş sayısı. Kamera yazıdan farklı yönde tutulduğunda yön cümleleri kameranın duruşuna göre söylenir (bkz. `ViewDirection`).
    static func turn(base: ImageOrientation, detected: ImageOrientation) -> Int {
        return ((base.quarterTurns - detected.quarterTurns) % 4 + 4) % 4
    }

    /// Aynı eksende ters yön (yazı bir yönde dik okunuyorsa öbüründe baş aşağı okunur): normal ↔ 180°, 90° sağa ↔ 90° sola
    var opposite: ImageOrientation {
        switch self {
        case .normal: return .rotate180
        case .rotate180: return .normal
        case .right90: return .left90
        case .left90: return .right90
        }
    }

    /// Dik açıyla çevrilince en/boy yer değiştirir
    var isQuarterTurn: Bool { return self == .right90 || self == .left90 }

    /// Ekranda saat yönünde dönüş açısı (radyan; UIKit'te pozitif = saat yönü)
    var angle: CGFloat {
        switch self {
        case .normal: return 0
        case .right90: return .pi / 2
        case .left90: return -.pi / 2
        case .rotate180: return .pi
        }
    }

    /// CIImage.oriented için EXIF yönü: `.right` resmi saat yönünde 90° çevirir
    var cgOrientation: CGImagePropertyOrientation {
        switch self {
        case .normal: return .up
        case .right90: return .right
        case .left90: return .left
        case .rotate180: return .down
        }
    }

    /// Video dosyasının oynatma dönüşümü (AVAssetWriterInput.transform): çevrilmiş kare pozitif bölgeye oturur.
    func videoTransform(width: CGFloat, height: CGFloat) -> CGAffineTransform {
        switch self {
        case .normal: return .identity
        case .right90: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0)
        case .left90: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width)
        case .rotate180: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width, ty: height)
        }
    }
}
