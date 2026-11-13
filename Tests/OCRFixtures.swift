import Foundation
import CoreGraphics
@testable import G526CameraDrive

/// Testlerde kullanılan sahte OCR satırları (kutular 0–1, üst-sol başlangıçlı)
enum OCRFixtures {
    static func line(_ text: String, y: Double, x: Double = 0.1, w: Double = 0.8, h: Double = 0.02, conf: Double = 0.9) -> OCRLine {
        return OCRLine(text: text, box: CGRect(x: x, y: y, width: w, height: h), confidence: conf)
    }

    /// Numara satırı, bir devam satırı ve 0,03 aralıklı şıklar
    static func question(_ n: Int, y0: Double, x: Double = 0.1, w: Double = 0.8, options: String = "ABCDE") -> [OCRLine] {
        var out = [line("\(n). Soru metni burada", y: y0, x: x, w: w), line("devam eden ikinci satır", y: y0 + 0.03, x: x, w: w)]
        for (i, c) in options.enumerated() {
            out.append(line("\(c)) seçenek \(i)", y: y0 + 0.06 + 0.03 * Double(i), x: x, w: w))
        }
        return out
    }

    /// Bir sorunun (ilk bloğun) yerleşimi
    static func block(_ n: Int = 12, y0: Double = 0.20, options: String = "ABCDE", extra: [OCRLine] = [], conf: Double = 0.9,
                      total: Int = 40) -> QuestionBlock {
        let lines = (question(n, y0: y0, options: options) + extra).map { l -> OCRLine in
            var copy = l
            copy.confidence = conf
            return copy
        }
        return QuestionLayout.analyze(lines: lines, total: total, optionCount: 5).blocks[0]
    }
}
