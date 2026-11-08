import Foundation
import CoreImage
import CoreVideo
import ImageIO
import Vision

struct EnhanceOptions {
    var level: Int          // 0 kapalı, 1 hafif, 2 güçlü
    var deskew: Bool
    var upscale: Double
    var cropTop: Int        // kaynak karede üstten atılacak piksel (saat yazısı)
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

        // 2) Üstteki saat yazısını kırp
        if options.cropTop > 0 {
            let e = image.extent
            let h = e.height - CGFloat(options.cropTop)
            if h > 64 {
                image = image.cropped(to: CGRect(x: e.minX, y: e.minY, width: e.width, height: h))
            }
        }
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
