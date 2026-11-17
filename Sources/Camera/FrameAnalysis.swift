import Foundation
import CoreVideo

/// Çözülmüş bir kare ve netlik bilgileri.
struct StoredFrame {
    let id: Int
    let time: TimeInterval
    let buffer: CVPixelBuffer
    let sharpness: Double
    /// 32x18 ızgaralık ortalama parlaklık imzası (hareket / değişim algılama için)
    let signature: [UInt8]
    /// Kare bozuk çözülmüş (16 pikselik bloklar belirgin; kamera akışında paket kaybı ya da sahne değişiminde kodlayıcının yetişememesi). Bozuk kare
    /// bloklardaki keskin kenarlar yüzünden yapay olarak "çok net" ölçülür: en net kare seçilirken geriye alınır (bkz. `pickScore`)
    var damaged = false

    /// En net kareyi seçerken kullanılan puan: bozuk kare, sağlam hiçbir kareyle yarışamaz
    var pickScore: Double { return damaged ? sharpness - 1_000_000 : sharpness }
}

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

    // MARK: - Bozuk (bloklaşmış) kare ölçütü

    /// Bu değerin üstündeki kare bozuk sayılır. Ölçü 1.0 civarında sağlam karedir: kameranın ham akışında sağlam karelerde 1.02–1.09, PDF'teki sağlam
    /// sayfalarda en çok 1.16, bozuk karelerde 1.3–1.9 çıktı (2026-11-17, 60 sayfalık çekim ve 8 Kasım ham akış kaydı). Bozuk sayılan kare atılmaz,
    /// yalnız sağlam kareler yetmediğinde kullanılır.
    static let damagedBlockiness = 1.22

    /// Parlaklık düzleminde 16 pikselik blok (makroblok) sınırlarındaki ortalama kenar şiddetinin, bloğun içindeki (8 piksel kaymış) aynı ölçüme oranı;
    /// yatay ve dikey yönün geometrik ortalaması. Sağlam görüntüde ≈1, bozulup bloklaşmış (düz renkli kareler, önceki sahnenin parçaları) görüntüde
    /// belirgin biçimde büyüktür. 8 piksel kaymış konum karşılaştırma alınır ki JPEG gibi 8'lik ızgaralar sonucu etkilemesin. `skipTop`: üstteki bu kadar
    /// satır (kameranın saat yazısı) ölçülmez. Seyrek örnekleme: 1080p karede yüz binden az okuma.
    static func blockiness(luma: UnsafePointer<UInt8>, width: Int, height: Int, stride: Int, skipTop: Int = 0) -> Double {
        let top = max(0, min(skipTop, height / 2))
        let eps = 1.0   // düz alanlarda (kenar yok) oran 1'e yaklaşsın

        // Dikey kenarlar: x = 16, 32, ... sınırı ile x + 8 konumu; her ikinci satır
        var edgeV = 0, refV = 0, countV = 0
        var y = (top + 1) & ~1
        while y < height {
            let row = luma + y * stride
            var x = 16
            while x + 8 < width {
                edgeV += abs(Int(row[x]) - Int(row[x - 1]))
                refV += abs(Int(row[x + 8]) - Int(row[x + 7]))
                countV += 1
                x += 16
            }
            y += 2
        }

        // Yatay kenarlar: y = 16, 32, ... sınırı ile y + 8 konumu; her ikinci sütun
        var edgeH = 0, refH = 0, countH = 0
        var by = ((top + 15) / 16 + 1) * 16
        while by + 8 < height {
            let a = luma + by * stride
            let b = luma + (by - 1) * stride
            let c = luma + (by + 8) * stride
            let d = luma + (by + 7) * stride
            var x = 0
            while x < width {
                edgeH += abs(Int(a[x]) - Int(b[x]))
                refH += abs(Int(c[x]) - Int(d[x]))
                countH += 1
                x += 2
            }
            by += 16
        }
        if countV == 0 || countH == 0 { return 1 }
        let v = (Double(edgeV) / Double(countV) + eps) / (Double(refV) / Double(countV) + eps)
        let h = (Double(edgeH) / Double(countH) + eps) / (Double(refH) / Double(countH) + eps)
        return (v * h).squareRoot()
    }

    /// Kare tamponunun parlaklık düzleminde `blockiness`; ölçülemezse 1 (sağlam sayılır)
    static func blockiness(_ pixelBuffer: CVPixelBuffer, skipTop: Int = 0) -> Double {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 1,
              let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return 1 }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        if width < 64 || height < 64 { return 1 }
        return blockiness(luma: base.assumingMemoryBound(to: UInt8.self), width: width, height: height, stride: stride, skipTop: skipTop)
    }

    // MARK: - Kare birleştirme denetimi (gölge/hayalet yazıyı önler)

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

    /// Referansın keskin kenarlarında iki kare arasındaki ortalama mutlak fark. Kare kayıksa 30+, yalnız gürültü varsa 1–5 çıkar.
    static func edgeError(ref: (w: Int, h: Int, px: [Float]), other: (w: Int, h: Int, px: [Float]), skipRows: Int) -> Double {
        guard ref.w == other.w, ref.h == other.h else { return .infinity }
        var sum: Double = 0
        var n = 0
        ref.px.withUnsafeBufferPointer { r in
            other.px.withUnsafeBufferPointer { o in
                let w = ref.w
                for y in min(max(0, skipRows), ref.h - 1)..<(ref.h - 1) {
                    for x in 0..<(w - 1) {
                        let i = y * w + x
                        let v = r[i]
                        if max(abs(r[i + 1] - v), abs(r[i + w] - v)) > 30 {
                            sum += Double(abs(v - o[i]))
                            n += 1
                        }
                    }
                }
            }
        }
        return n < 200 ? 0 : sum / Double(n)
    }

    static let edgeErrorMax = 10.0

    /// İlk kare (en net) esas alınır; ona gerçekten uyan (kıpırdamamış) kareler tutulur, kayık olanlar atılır.
    static func staticFrames(_ buffers: [CVPixelBuffer], skipFraction: Double) -> [CVPixelBuffer] {
        guard buffers.count > 1, let first = buffers.first, let ref = binnedLuma(first) else { return Array(buffers.prefix(1)) }
        let skipRows = Int((Double(ref.h) * skipFraction).rounded())
        var kept = [first]
        for buffer in buffers.dropFirst() {
            guard let other = binnedLuma(buffer) else { continue }
            if edgeError(ref: ref, other: other, skipRows: skipRows) <= edgeErrorMax {
                kept.append(buffer)
            }
        }
        return kept
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

/// Son çözülmüş kareleri tutan halka tampon.
final class FrameStore {
    private let lock = NSLock()
    private var frames: [StoredFrame] = []
    private let capacity: Int
    private var nextID = 0

    init(capacity: Int = 20) {
        self.capacity = capacity
    }

    var latest: StoredFrame? {
        lock.lock()
        defer { lock.unlock() }
        return frames.last
    }

    func add(buffer: CVPixelBuffer, time: TimeInterval, sharpness: Double, signature: [UInt8], damaged: Bool = false) {
        lock.lock()
        nextID += 1
        frames.append(StoredFrame(id: nextID, time: time, buffer: buffer, sharpness: sharpness, signature: signature, damaged: damaged))
        if frames.count > capacity {
            frames.removeFirst(frames.count - capacity)
        }
        lock.unlock()
    }

    func frames(from start: TimeInterval, to end: TimeInterval) -> [StoredFrame] {
        lock.lock()
        defer { lock.unlock() }
        return frames.filter { $0.time >= start && $0.time <= end }
    }

    func clear() {
        lock.lock()
        frames.removeAll()
        lock.unlock()
    }
}
