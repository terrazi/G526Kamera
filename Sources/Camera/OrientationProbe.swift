import Foundation
import CoreVideo
import CoreGraphics
import Vision

/// Yazının yan mı dik mi durduğunu ucuz bir taramayla anlar (kullanıcı isteği 2026-11-18: yan duran yazıyı okumayı hızlandır; koç hangisi işe yararsa onu kullansın).
/// Yazı satırlarının kutuları (Vision metin kutusu bulucu, harf okumaz) yataysa yazı dik ya da ters (0° / 180°), dikeyse yan (90° / 270°) duruyordur.
/// Böylece yazı tanıma dört yön yerine çoğu kez en fazla iki yönde denenir (`OrientationFinder`). Tarama yanılırsa sonuç yanlış olmaz, yalnız yavaşlar:
/// ipucu yönleri okunmazsa öteki yönler de denenir ve ipucu art arda yanılıyorsa kullanılmaz (`ProbeTrust`).
enum OrientationProbe {
    /// Bu kadar kutudan azıyla karar verilmez
    static let minBoxes = 6
    /// Kutu en/boy oranı bu değerin üstündeyse yatay, tersinin altındaysa dikey sayılır (tek harf / kare kutular sayılmaz)
    static let lineRatio = 1.5
    /// Baskın yönün alan payı bu orandan azsa karar verilmez
    static let dominance = 0.8

    /// Saf karar: kutular (0–1 oranlarında, `aspect` = kare genişliği / yüksekliği) baskın biçimde yataysa [normal, ters], dikeyse [sağa 90°, sola 90°];
    /// önceki karede bulunan yön (`preferred`) aynı eksendeyse başa alınır. Karar verilemiyorsa nil.
    static func hint(boxes: [CGRect], aspect: Double, preferred: ImageOrientation) -> [ImageOrientation]? {
        var horizontal = 0.0, vertical = 0.0
        var counted = 0
        for box in boxes {
            let w = Double(box.width) * aspect
            let h = Double(box.height)
            guard w > 0, h > 0 else { continue }
            let ratio = w / h
            if ratio >= lineRatio {
                horizontal += w * h
                counted += 1
            } else if ratio <= 1 / lineRatio {
                vertical += w * h
                counted += 1
            }
        }
        let total = horizontal + vertical
        guard counted >= minBoxes, total > 0, max(horizontal, vertical) / total >= dominance else { return nil }
        var axis: [ImageOrientation] = horizontal >= vertical ? [.normal, .rotate180] : [.right90, .left90]
        if let index = axis.firstIndex(of: preferred), index > 0 { axis.swapAt(0, index) }
        return axis
    }

    /// Karedeki metin kutuları (Vision); okunamazsa nil. Harf okunmadığı için yazı tanımadan çok daha ucuzdur.
    static func boxes(in buffer: CVPixelBuffer) -> [CGRect]? {
        let request = VNDetectTextRectanglesRequest()
        request.reportCharacterBoxes = false
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        var result: [CGRect] = []
        for case let observation as VNTextObservation in (request.results ?? []) { result.append(observation.boundingBox) }
        return result
    }

    static func aspect(of buffer: CVPixelBuffer) -> Double {
        let h = CVPixelBufferGetHeight(buffer)
        return h > 0 ? Double(CVPixelBufferGetWidth(buffer)) / Double(h) : 16.0 / 9.0
    }
}

/// İpucunun işe yarayıp yaramadığı: ipucu yönlerinden biri okunduysa isabet, ipucu dışındaki bir yön okunduysa ıska. Art arda yanılıyorsa ipucu bırakılır
/// (tarama süresi boşa gitmesin); yeni çekimde ya da yeni koç oturumunda yeniden denenir.
struct ProbeTrust: Equatable {
    var hits = 0
    var misses = 0
    /// Bu kadar ıskadan sonra ve ıska sayısı isabetten fazlaysa ipucu kullanılmaz
    static let missLimit = 3

    var isTrusted: Bool { return !(misses >= ProbeTrust.missLimit && misses > hits) }

    mutating func record(hit: Bool) {
        if hit { hits += 1 } else { misses += 1 }
    }
}
