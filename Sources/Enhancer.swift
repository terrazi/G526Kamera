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

    static func render(buffers: [CVPixelBuffer], options: EnhanceOptions) -> (data: Data, width: Int, height: Int)? {
        guard let first = buffers.first else { return nil }
        var image = CIImage(cvPixelBuffer: first)

        // 1) Birkaç sabit kareyi ortalayarak gürültüyü azalt
        if buffers.count > 1 {
            for (k, buffer) in buffers.dropFirst().enumerated() {
                let next = CIImage(cvPixelBuffer: buffer)
                if let filter = CIFilter(name: "CIDissolveTransition") {
                    filter.setValue(image, forKey: kCIInputImageKey)
                    filter.setValue(next, forKey: kCIInputTargetImageKey)
                    filter.setValue(1.0 / Double(k + 2), forKey: kCIInputTimeKey)
                    if let out = filter.outputImage { image = out }
                }
            }
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

        // 6) Keskinleştirme ve kontrast
        if options.level == 1 {
            image = image.applyingFilter("CISharpenLuminance",
                                         parameters: [kCIInputSharpnessKey: 0.5, "inputRadius": 1.2])
            image = image.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.06])
        } else if options.level >= 2 {
            image = image.applyingFilter("CIUnsharpMask",
                                         parameters: [kCIInputRadiusKey: 2.0, kCIInputIntensityKey: 1.0])
            image = image.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.15])
        }

        let extent = image.extent.integral
        guard extent.width > 1, extent.height > 1,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let key = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        let quality = max(0.5, min(1.0, options.quality))
        guard let data = context.jpegRepresentation(of: image.cropped(to: extent),
                                                    colorSpace: colorSpace,
                                                    options: [key: quality]) else { return nil }
        return (data, Int(extent.width), Int(extent.height))
    }

    /// Karenin üstten bu kadarı tarih/saat şeridi sayılır (1080p'de 81 satır; yazı 39–64. satırlarda). Windows sürümüyle aynı.
    static let timestampBand = 0.075

    /// Kameranın videoya gömdüğü tarih/saati gizler. Core Image'de başlangıç noktası sol alttır; şerit görüntünün ÜST satırlarıdır.
    static func hideTimestamp(_ image: CIImage, mode: TimestampMode) -> CIImage {
        let e = image.extent
        let band = (Double(e.height) * timestampBand).rounded()
        guard mode != .keep, band >= 4, Double(e.height) - band >= 64 else { return image }
        let bandH = CGFloat(band)

        if mode == .crop {
            return image.cropped(to: CGRect(x: e.minX, y: e.minY, width: e.width, height: e.height - bandH))
        }

        // Önce mozaik (12 pikselik bloklar), sonra bulanıklık: harfler hiçbir şekilde seçilemez.
        let mosaic = image.clampedToExtent().applyingFilter("CIPixellate", parameters: [
            kCIInputScaleKey: 12.0,
            kCIInputCenterKey: CIVector(x: e.minX, y: e.minY)])
        let blurred = mosaic.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 6.0]).cropped(to: e)

        // Şeridin alt kenarında yumuşak geçiş (sert çizgi görünmesin): üstte beyaz, şerit sınırında siyah.
        let fade = CGFloat(max(2.0, (band / 6.0).rounded(.down)))
        let edgeY = e.maxY - bandH
        guard let gradient = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: e.minX, y: edgeY + fade),
            "inputPoint1": CIVector(x: e.minX, y: edgeY),
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 1)])?.outputImage else { return image }
        let mask = gradient.cropped(to: e)
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
