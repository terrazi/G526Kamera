import Foundation
import CoreGraphics
import ImageIO

/// Bir sorunun ardışık fotoğraflarını TEK PDF'e dizer (her fotoğraf bir sayfa). Fotoğraflar JPEG olarak olduğu gibi gömülür
/// (yeniden sıkıştırılmaz): PDF'in boyutu fotoğrafların toplamı kadardır, yazı keskinliği kaybolmaz. Gemini PDF'i sayfa sayfa okur.
enum PageDocument {
    /// JPEG'lerden PDF üretir; hiçbiri okunamazsa nil. Sayfa boyutu fotoğrafın piksel boyutudur (yön zaten fotoğrafa işlenmiştir).
    static func make(jpegs: [Data], title: String = "Soru çekimi") -> Data? {
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else { return nil }
        var firstBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let info = [kCGPDFContextTitle as String: title, kCGPDFContextCreator as String: "Sesli Kontrol"] as CFDictionary
        guard let context = CGContext(consumer: consumer, mediaBox: &firstBox, info) else { return nil }
        var pages = 0
        for data in jpegs {
            guard let provider = CGDataProvider(data: data as CFData),
                  let image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { continue }
            var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            let pageInfo = [kCGPDFContextMediaBox as String: NSData(bytes: &box, length: MemoryLayout<CGRect>.size)] as CFDictionary
            context.beginPDFPage(pageInfo)
            context.draw(image, in: box)
            context.endPDFPage()
            pages += 1
        }
        context.closePDF()
        return pages > 0 ? output as Data : nil
    }

    /// Toplu çekimde bütün oturumun fotoğrafları TEK PDF'e girer (75 fotoğraf): toplam `budget` baytı aşarsa fotoğraflar sırayla daha düşük JPEG kalitesine
    /// (gerekirse biraz küçültülerek) yeniden sıkıştırılır; sığan en yüksek düzey seçilir. Gemini'nin PDF sınırı 50 MB, istek 100 MB'dır ama telefonun
    /// hücresel yüklemesi yavaş olabilir: bütçe 16 MB (base64 ile ≈ 21 MB).
    static let budgetBytes = 16_000_000
    /// (JPEG kalitesi, ölçek) düzeyleri: önce yalnız kalite düşer, olmazsa görüntü küçülür
    static let fitLevels: [(quality: Double, scale: Double)] = [(0.85, 1), (0.75, 1), (0.65, 1), (0.55, 1), (0.45, 1), (0.6, 0.8), (0.55, 0.65)]

    static func fit(_ jpegs: [Data], budget: Int = budgetBytes) -> [Data] {
        guard !jpegs.isEmpty, jpegs.reduce(0, { $0 + $1.count }) > budget else { return jpegs }
        // Örnek: eşit aralıklı en çok 6 fotoğraf her düzeyde denenir, toplam tahmin edilir (bütün oturumu her düzeyde yeniden sıkıştırmaktan ucuzdur)
        let step = max(1, jpegs.count / 6)
        let sample = stride(from: 0, to: jpegs.count, by: step).map { jpegs[$0] }
        for (quality, scale) in fitLevels {
            let sampled = sample.map { recompress($0, quality: quality, scale: scale)?.count ?? $0.count }
            let estimate = Double(sampled.reduce(0, +)) / Double(sample.count) * Double(jpegs.count)
            guard estimate <= Double(budget) * 0.97 else { continue }
            let all = jpegs.map { recompress($0, quality: quality, scale: scale) ?? $0 }
            if all.reduce(0, { $0 + $1.count }) <= budget { return all }
        }
        // En düşük düzey bile sığmadıysa en küçük düzeyin sonucu kullanılır (PDF yine kurulur, istek sunucu sınırının çok altında kalır)
        let last = fitLevels[fitLevels.count - 1]
        return jpegs.map { recompress($0, quality: last.quality, scale: last.scale) ?? $0 }
    }

    /// JPEG'i verilen kalite ve ölçekle yeniden kodlar; okunamazsa nil
    static func recompress(_ jpeg: Data, quality: Double, scale: Double) -> Data? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        let image: CGImage?
        if scale < 1 {
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let width = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
            let height = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
            guard width > 0, height > 0 else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: false,
                                            kCGImageSourceThumbnailMaxPixelSize: Int(Double(max(width, height)) * scale)]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let cg = image else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// PDF'in sayfa sayısı (okunamazsa 0)
    static func pageCount(of pdf: Data) -> Int {
        guard let provider = CGDataProvider(data: pdf as CFData), let document = CGPDFDocument(provider) else { return 0 }
        return document.numberOfPages
    }
}
