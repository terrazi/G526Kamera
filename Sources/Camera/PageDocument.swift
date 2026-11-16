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

    /// PDF'in sayfa sayısı (okunamazsa 0)
    static func pageCount(of pdf: Data) -> Int {
        guard let provider = CGDataProvider(data: pdf as CFData), let document = CGPDFDocument(provider) else { return 0 }
        return document.numberOfPages
    }
}
