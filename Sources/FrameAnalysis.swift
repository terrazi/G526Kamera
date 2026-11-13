import Foundation
import CoreVideo

enum FrameAnalysis {
    static let signatureColumns = 32
    static let signatureRows = 18

    /// Netlik puanı = 2x2 küçültülmüş parlaklık düzleminde Laplace varyansı.
    /// `skipTop`: üstteki bu kadar satır puanlamaya katılmaz (kameranın saat yazısı).
    static func analyze(_ pixelBuffer: CVPixelBuffer, skipTop: Int = 0) -> (sharpness: Double, signature: [UInt8])? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 1,
              let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        if width < 64 || height < 64 { return nil }
        let luma = base.assumingMemoryBound(to: UInt8.self)

        // İmza: ızgara hücrelerinin ortalaması (hücre başına seyrek örnekleme)
        var signature = [UInt8](repeating: 0, count: signatureColumns * signatureRows)
        let cellW = width / signatureColumns
        let cellH = height / signatureRows
        for gy in 0..<signatureRows {
            // Üstteki saat yazısının olduğu satırlar sabit 0 kalır (değişim algılamayı bozmasın)
            if gy * cellH < skipTop { continue }
            for gx in 0..<signatureColumns {
                var sum = 0
                var count = 0
                var y = gy * cellH
                let yEnd = y + cellH
                while y < yEnd {
                    let row = luma + y * stride
                    var x = gx * cellW
                    let xEnd = x + cellW
                    while x < xEnd {
                        sum += Int(row[x])
                        count += 1
                        x += 4
                    }
                    y += 4
                }
                signature[gy * signatureColumns + gx] = UInt8(count > 0 ? sum / count : 0)
            }
        }

        // Netlik: 2x2 ortalama + Laplace varyansı
        let top = max(0, min(skipTop, height / 2)) & ~1
        let w2 = width / 2
        let h2 = (height - top) / 2
        if w2 < 8 || h2 < 8 { return (0, signature) }

        var binned = [Float](repeating: 0, count: w2 * h2)
        for y in 0..<h2 {
            let r0 = luma + (top + 2 * y) * stride
            let r1 = r0 + stride
            for x in 0..<w2 {
                let a = Int(r0[2 * x]) + Int(r0[2 * x + 1]) + Int(r1[2 * x]) + Int(r1[2 * x + 1])
                binned[y * w2 + x] = Float(a) * 0.25
            }
        }

        var sum: Double = 0
        var sumSq: Double = 0
        var n: Double = 0
        binned.withUnsafeBufferPointer { b in
            for y in 1..<(h2 - 1) {
                let o = y * w2
                for x in 1..<(w2 - 1) {
                    var lap: Float = 4 * b[o + x]
                    lap -= b[o + x - 1]
                    lap -= b[o + x + 1]
                    lap -= b[o + x - w2]
                    lap -= b[o + x + w2]
                    let v = Double(lap)
                    sum += v
                    sumSq += v * v
                    n += 1
                }
            }
        }
        if n == 0 { return (0, signature) }
        let mean = sum / n
        let variance = sumSq / n - mean * mean
        return (variance, signature)
    }

    /// Kareden 2x2 ortalamalı parlaklık düzlemi (NV12'de Y düzlemi; BGRA'da hesaplanır).
    static func binnedLuma(_ pixelBuffer: CVPixelBuffer) -> (w: Int, h: Int, px: [Float])? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        if CVPixelBufferGetPlaneCount(pixelBuffer) >= 1 {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
            let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let luma = base.assumingMemoryBound(to: UInt8.self)
            let w2 = width / 2, h2 = height / 2
            if w2 < 8 || h2 < 8 { return nil }
            var out = [Float](repeating: 0, count: w2 * h2)
            for y in 0..<h2 {
                let r0 = luma + 2 * y * stride, r1 = r0 + stride
                for x in 0..<w2 {
                    out[y * w2 + x] = Float(Int(r0[2 * x]) + Int(r0[2 * x + 1]) + Int(r1[2 * x]) + Int(r1[2 * x + 1])) * 0.25
                }
            }
            return (w2, h2, out)
        }
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let w2 = width / 2, h2 = height / 2
        if w2 < 8 || h2 < 8 { return nil }
        var out = [Float](repeating: 0, count: w2 * h2)
        for y in 0..<h2 {
            for x in 0..<w2 {
                var acc: Float = 0
                for dy in 0..<2 { for dx in 0..<2 {
                    let p = bytes + (2 * y + dy) * stride + (2 * x + dx) * 4
                    acc += 0.114 * Float(p[0]) + 0.587 * Float(p[1]) + 0.299 * Float(p[2])
                } }
                out[y * w2 + x] = acc * 0.25
            }
        }
        return (w2, h2, out)
    }

    /// İki imza arasındaki ortalama mutlak fark (0–255).
    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        if a.count != b.count || a.isEmpty { return 255 }
        var total = 0
        for i in 0..<a.count {
            total += abs(Int(a[i]) - Int(b[i]))
        }
        return Double(total) / Double(a.count)
    }
}
