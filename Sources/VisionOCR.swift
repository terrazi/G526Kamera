import Foundation
import Vision
import CoreVideo

/// Apple Vision ile telefonda (internetsiz) yazı okuma. Yalnız soru numaralarını ve şık harflerini bulmak için kullanılır;
/// soruyu çözmek Gemini'nin işidir.
enum VisionOCR {
    /// Okunacak en küçük yazı yüksekliği (kadraj yüksekliği oranı). Vision'ın varsayılanı 1/32'dir; tam sayfa kadrajında satırlar
    /// bundan küçüktür.
    static let minimumTextHeight: Float = 0.008

    /// Karedeki yazı satırları. `orientation`: ekrandaki (kullanıcının gördüğü) yön; kutular bu yöne göre verilir.
    /// Uzun sürer (kare başına yarım saniye – birkaç saniye): ana iş parçacığında çağrılmaz.
    static func recognize(_ buffer: CVPixelBuffer, orientation: ImageOrientation) -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = minimumTextHeight
        if let supported = try? request.supportedRecognitionLanguages() {
            let wanted = ["tr-TR", "en-US"].filter { supported.contains($0) }
            if !wanted.isEmpty { request.recognitionLanguages = wanted }
        }
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation.cgOrientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            tlog("[ocr] okunamadı: \(error.localizedDescription)")
            return []
        }
        var lines: [OCRLine] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let b = observation.boundingBox          // Vision: alt-sol başlangıçlı
            let box = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
            lines.append(OCRLine(text: candidate.string, box: box, confidence: Double(candidate.confidence)))
        }
        return lines
    }
}
