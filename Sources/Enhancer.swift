import Foundation
import CoreImage
import CoreVideo
import ImageIO
import Vision

/// Kamera tarih/saati görüntünün içine işler; silinemez. Bulanıklaştır: üst şerit okunmaz olur,
/// Kes: üst şerit atılır, Olduğu gibi: dokunulmaz.
enum TimestampMode: String, CaseIterable {
    case blur, crop, keep
}

struct EnhanceOptions {
    var level: Int          // 0 kapalı, 1 hafif, 2 güçlü
    var deskew: Bool
    var upscale: Double
    var timestamp: TimestampMode   // kameranın görüntüye işlediği tarih/saat
    var quality: Double     // JPEG kalitesi 0.5–1.0
}

/// Core Image ile belge iyileştirme ve JPEG üretimi.
enum Enhancer {
    static let context = CIContext(options: [CIContextOption.cacheIntermediates: false])

    /// `used`: gerçekten birleştirilen kare sayısı (kayık kareler atılır, bkz. FrameAnalysis.staticFrames).
    static func render(buffers: [CVPixelBuffer], options: EnhanceOptions) -> (data: Data, width: Int, height: Int, used: Int)? {
        guard let first = buffers.first else { return nil }
        let reference = CIImage(cvPixelBuffer: first)
        var image = reference

        // 1) Yalnızca birbirinin aynısı (kıpırdamamış) kareleri ortala. Birkaç piksel kayık kareyi ortalamak
        //    her yazının yanında "gölge" (çift/hayalet yazı) bırakır; bu kareler atılır, en kötü durumda tek kare kalır.
        let merged = FrameAnalysis.staticFrames(buffers, skipFraction: timestampBox.y1 + 0.01)
        if merged.count < buffers.count {
            tlog("[çekim] \(buffers.count - merged.count) kare kayık olduğu için birleştirmeden çıkarıldı")
        }
        if merged.count > 1 {
            for (k, buffer) in merged.dropFirst().enumerated() {
                let next = CIImage(cvPixelBuffer: buffer)
                if let filter = CIFilter(name: "CIDissolveTransition") {
                    filter.setValue(image, forKey: kCIInputImageKey)
                    filter.setValue(next, forKey: kCIInputTargetImageKey)
                    filter.setValue(1.0 / Double(k + 2), forKey: kCIInputTimeKey)
                    if let out = filter.outputImage { image = out }
                }
            }
            // tarih/saat kutusu: saniyesi farklı kareler üst üste binmesin
            let r = reference.extent
            image = reference.cropped(to: boxRect(in: r)).composited(over: image).cropped(to: r)
        }

        // 2) Tarih/saat yazısını bulanıklaştır ya da kes
        image = normalizeOrigin(image)
        image = hideTimestamp(image, mode: options.timestamp)
        image = normalizeOrigin(image)

        // 3) Belgeyi bul, kırp ve perspektifi düzelt
        if options.deskew, let corrected = deskew(image) {
            image = normalizeOrigin(corrected)
        }

        // 4) Gürültü azaltma
        if options.level >= 1 {
            let noise = options.level >= 2 ? 0.02 : 0.01
            image = image.applyingFilter("CINoiseReduction",
                                         parameters: ["inputNoiseLevel": noise, "inputSharpness": 0.4])
        }

        // 5) Büyütme (Lanczos)
        if options.upscale > 1.01 {
            image = image.applyingFilter("CILanczosScaleTransform",
                                         parameters: [kCIInputScaleKey: options.upscale,
                                                      kCIInputAspectRatioKey: 1.0])
        }

        // 6) Hafif keskinleştirme: kenar yanında belirgin hale/gölge oluşmayacak kadar (Windows sürümüyle aynı ilke)
        let sharpScale = max(1.0, options.upscale)
        if options.level == 1 {
            image = image.applyingFilter("CISharpenLuminance",
                                         parameters: [kCIInputSharpnessKey: 0.25, "inputRadius": 0.9 * sharpScale])
        } else if options.level >= 2 {
            image = image.applyingFilter("CIUnsharpMask",
                                         parameters: [kCIInputRadiusKey: 1.0 * sharpScale, kCIInputIntensityKey: 0.5])
            image = image.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.04])
        }

        let extent = image.extent.integral
        guard extent.width > 1, extent.height > 1,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let key = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        let quality = max(0.5, min(1.0, options.quality))
        guard let data = context.jpegRepresentation(of: image.cropped(to: extent),
                                                    colorSpace: colorSpace,
                                                    options: [key: quality]) else { return nil }
        return (data, Int(extent.width), Int(extent.height), merged.count)
    }

    /// "Kes" modu: karenin üstten bu kadarı atılır (1080p'de 81 satır; yazı 39–64. satırlarda). Windows sürümüyle aynı.
    static let timestampBand = 0.075

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
        if mode == .crop {
            let band = (Double(e.height) * timestampBand).rounded()
            guard band >= 4, Double(e.height) - band >= 64 else { return image }
            return image.cropped(to: CGRect(x: e.minX, y: e.minY, width: e.width, height: e.height - CGFloat(band)))
        }
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

    /// Vision ile belge dörtgenini bulup CIPerspectiveCorrection uygular. Emin değilse nil döner.
    private static func deskew(_ image: CIImage) -> CIImage? {
        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first, observation.confidence > 0.6 else { return nil }
        let area = observation.boundingBox.width * observation.boundingBox.height
        if area < 0.25 { return nil }

        let e = image.extent
        func point(_ p: CGPoint) -> CIVector {
            return CIVector(x: e.minX + p.x * e.width, y: e.minY + p.y * e.height)
        }
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(point(observation.topLeft), forKey: "inputTopLeft")
        filter.setValue(point(observation.topRight), forKey: "inputTopRight")
        filter.setValue(point(observation.bottomLeft), forKey: "inputBottomLeft")
        filter.setValue(point(observation.bottomRight), forKey: "inputBottomRight")
        return filter.outputImage
    }
}
