import Foundation
import CoreImage
import CoreVideo
import ImageIO

/// Kamera tarih/saati görüntünün içine işler; silinemez. Bulanıklaştır: yazı okunmaz olur, Olduğu gibi: dokunulmaz.
enum TimestampMode: String, CaseIterable {
    case blur, keep
}

/// Core Image ile soru görüntüsü üretimi.
enum Enhancer {
    static let context = CIContext(options: [CIContextOption.cacheIntermediates: false])

    /// Tek kareden bir bölgeyi (0–1, üst-sol başlangıçlı; görüntü yönü uygulanmış görüntüye göre) kırpıp JPEG üretir.
    /// Soru PDF'lerinin sayfaları bununla yapılır. Tarih/saat yazısı ayara göre bulanıklaştırılır.
    static func renderCrop(buffer: CVPixelBuffer, crop: CGRect, orientation: ImageOrientation, timestamp: TimestampMode,
                           quality: Double, sharpen: Bool) -> (data: Data, width: Int, height: Int)? {
        var image = normalizeOrigin(CIImage(cvPixelBuffer: buffer))
        image = normalizeOrigin(hideTimestamp(image, mode: timestamp))
        if orientation != .normal {
            image = normalizeOrigin(image.oriented(orientation.cgOrientation))
        }
        let e = image.extent
        let wanted = CGRect(x: e.minX + crop.minX * e.width, y: e.minY + (1 - crop.maxY) * e.height,
                            width: crop.width * e.width, height: crop.height * e.height).integral
        let rect = wanted.intersection(e)
        guard !rect.isNull, rect.width > 8, rect.height > 8 else { return nil }
        image = normalizeOrigin(image.cropped(to: rect))
        if sharpen {
            image = image.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.25, "inputRadius": 0.9])
        }
        let extent = image.extent.integral
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let key = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        guard let data = context.jpegRepresentation(of: image.cropped(to: extent), colorSpace: colorSpace,
                                                    options: [key: max(0.5, min(1.0, quality))]) else { return nil }
        return (data, Int(extent.width), Int(extent.height))
    }

    /// "Bulanıklaştır" modu yalnızca tarih/saat yazısının olduğu kutuyu bulanıklaştırır (kare genişliği/yüksekliği oranları, sol-üst başlangıç).
    /// 1080p'de yazı 39–64. satır, 1561–1900. sütun; kutu ona pay bırakır: satır 24–80, sütun 1536–1920. Windows sürümüyle aynı.
    static let timestampBox = (x0: 0.800, y0: 0.022, x1: 1.000, y1: 0.074)

    /// Kutunun Core Image koordinatlarındaki (başlangıç sol alt) dikdörtgeni.
    static func boxRect(in e: CGRect) -> CGRect {
        let x = e.minX + (e.width * CGFloat(timestampBox.x0)).rounded()
        let top = (e.height * CGFloat(timestampBox.y0)).rounded()
        let bottom = (e.height * CGFloat(timestampBox.y1)).rounded()
        return CGRect(x: x, y: e.maxY - bottom, width: e.maxX - x, height: bottom - top)
    }

    /// Kameranın videoya gömdüğü tarih/saati gizler. Core Image'de başlangıç noktası sol alttır.
    static func hideTimestamp(_ image: CIImage, mode: TimestampMode) -> CIImage {
        let e = image.extent
        guard mode == .blur else { return image }
        let box = boxRect(in: e)
        guard box.width >= 16, box.height >= 8, e.height >= 64 else { return image }

        // Önce mozaik (12 pikselik bloklar), sonra bulanıklık: harfler hiçbir şekilde seçilemez.
        let mosaic = image.clampedToExtent().applyingFilter("CIPixellate", parameters: [
            kCIInputScaleKey: 12.0,
            kCIInputCenterKey: CIVector(x: e.minX, y: e.minY)])
        let blurred = mosaic.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 6.0]).cropped(to: e)

        // Kutunun kenarlarında yumuşak geçiş (sert dikdörtgen görünmesin). Sağ kenar karenin kenarı olduğu için
        // maske sağa taşırılır, orada geçiş olmaz.
        let fade = CGFloat(max(2.0, min(10.0, (box.height / 5.0).rounded(.down))))
        let inset = fade / 2
        var maskRect = box.insetBy(dx: 0, dy: inset)
        maskRect.origin.x += inset
        maskRect.size.width = e.maxX + 60 - maskRect.origin.x
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: maskRect)
        let feathered = white.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: Double(inset)])
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: e)
        let mask = feathered.composited(over: black).cropped(to: e)
        return blurred.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: mask]).cropped(to: e)
    }

    private static func normalizeOrigin(_ image: CIImage) -> CIImage {
        let e = image.extent
        if e.minX == 0 && e.minY == 0 { return image }
        return image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
    }
}
