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

    /// Kameranın gördüğü yön (sensör) → kullanıcının ekranda gördüğü yön.
    /// Örnek: resim saat yönünde 90° çevrilince sensörün solu ekranda yukarı olur.
    func displayed(_ advice: GuidanceAdvice) -> GuidanceAdvice {
        switch self {
        case .normal:
            return advice
        case .rotate180:
            switch advice {
            case .moveLeft: return .moveRight
            case .moveRight: return .moveLeft
            case .moveUp: return .moveDown
            case .moveDown: return .moveUp
            default: return advice
            }
        case .right90:
            switch advice {
            case .moveLeft: return .moveUp
            case .moveUp: return .moveRight
            case .moveRight: return .moveDown
            case .moveDown: return .moveLeft
            default: return advice
            }
        case .left90:
            switch advice {
            case .moveLeft: return .moveDown
            case .moveDown: return .moveRight
            case .moveRight: return .moveUp
            case .moveUp: return .moveLeft
            default: return advice
            }
        }
    }

    /// Kullanıcının söylediği bölüm → sensördeki bölüm. Dik çevrilmiş resimde sensörün sol/sağ bölümleri
    /// ekranda üst/alt görünür; bu durumda `.left` = ekranda üstteki, `.right` = ekranda alttaki bölümdür.
    func sensorChoice(_ c: ColumnChoice) -> ColumnChoice {
        switch self {
        case .normal, .right90:
            return c
        case .rotate180, .left90:
            switch c {
            case .left: return .right
            case .right: return .left
            default: return c
            }
        }
    }

    /// Bölümün kullanıcıya söylenen adı
    func title(_ c: ColumnChoice) -> String {
        guard isQuarterTurn else { return c.title }
        switch c {
        case .left: return "Üst"
        case .right: return "Alt"
        default: return c.title
        }
    }
}
