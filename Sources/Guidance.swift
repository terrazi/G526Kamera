import Foundation
import CoreVideo

// MARK: - Ölçüler

/// Yazı bloğunun (ya da bir sütunun / yan yana sayfanın) kadrajdaki kutusu, kare oranları 0–1.
struct ColumnBox: Equatable {
    var x0 = 0.0
    var x1 = 0.0
    var y0 = 0.0
    var y1 = 0.0
    var cells = 0
    var sharp = 0.0
    var center: Double { return (x0 + x1) / 2 }
}

/// Sayfanın ve yazı bloğunun kadrajdaki yeri (kare oranları 0–1). Kameranın üstteki saat bandı hesaba katılmaz.
struct PageMetrics: Equatable {
    var hasPage = false
    var hasText = false
    var x0 = 0.0
    var x1 = 0.0
    var y0 = 0.0
    var y1 = 0.0
    var cells = 0
    /// İnce ayrıntı / orta band enerjisi: keskin yazıda 1'in üstünde, bulanıkta 0,5'in altında
    var sharp = 0.0
    var paper = 0.0
    /// Aralarında boşluk olan ayrı bölümler (sütunlar ya da yan yana sayfalar), soldan sağa. Tek bölümde 1 öğe.
    var columns: [ColumnBox] = []
    /// Yazı kutusunun içinde, neredeyse tam beyaza doymuş (parlama) büyük lekenin kutuya oranı; yoksa 0
    var glare = 0.0
    /// Yazı hücrelerindeki harf boyutunda (küçük, derli toplu) mürekkep parçalarının sayısı. -1: ölçülmedi.
    /// Yazıda yüzlerce vardır; çizgili kumaş, tablo çizgisi, ızgara gibi desenlerde mürekkep uzun şeritlerdir.
    var glyphs = -1
    /// Mürekkebin ne kadarı harf boyutunda parçalardan oluşuyor (0–1)
    var glyphShare = 1.0
    /// Apple Vision'ın bulduğu kâğıt kenarları (kamera durunca, seyrek ölçülür); ölçülmediyse ya da bulunamadıysa nil
    var edges: PageEdges?

    var summary: String {
        if !hasText { return hasPage ? "sayfa var, yazı seçilemiyor" : "yazı bulunamadı" }
        func pct(_ v: Double) -> String { return "\(Int((v * 100).rounded()))" }
        var s = "yazı x %\(pct(x0))–\(pct(x1)) · y %\(pct(y0))–\(pct(y1)) · netlik \(String(format: "%.2f", sharp)) · bölüm \(columns.count)"
        if let e = edges { s += " · sayfa " + e.summary }
        return s
    }
}

// MARK: - Sayfa / yazı bloğu analizi

/// 2x2 küçültülmüş parlaklıktan (genelde 960x540) sayfayı ve yazı bloğunu bulur. Yalnızca basit döngüler kullanır.
enum GuidanceAnalyzer {
    static let cell = 8
    static let skipTop = 0.075

    /// `orientation`: ölçüm ekranda gördüğünüz (çevrilmiş) görüntü üzerinde yapılır; böylece sütunlar yan yana,
    /// "sol / sağ / yukarı / aşağı" ekrandaki yöne göre olur. Normal yönde kare olduğu gibi ölçülür.
    static func analyze(_ pixelBuffer: CVPixelBuffer, orientation: ImageOrientation = .normal) -> PageMetrics? {
        guard let b = FrameAnalysis.binnedLuma(pixelBuffer) else { return nil }
        if orientation == .normal { return analyze(luma: b.px, width: b.w, height: b.h) }
        let r = reorient(luma: b.px, width: b.w, height: b.h, orientation: orientation)
        return analyze(luma: r.px, width: r.w, height: r.h, skipTop: 0)
    }

    /// Parlaklık düzlemini ekranda görünen yöne çevirir. Kameranın saat bandı (karenin üst %7,5'i) çevirmeden önce atılır,
    /// çünkü çevrilince bant kenara geçer; çevrilmiş düzlemde bant yoktur (ölçümde `skipTop: 0` kullanılır).
    /// Normal yönde düzlem değişmez. Küçültülmüş düzlemde (genelde 960×540) çevirme birkaç milisaniyedir.
    static func reorient(luma L: [Float], width W: Int, height H: Int,
                         orientation: ImageOrientation) -> (px: [Float], w: Int, h: Int) {
        guard orientation != .normal, W > 0, H > 0, L.count == W * H else { return (L, W, H) }
        let top = min(Int(Double(H) * skipTop), H - 1)
        let h = H - top
        var out = [Float](repeating: 0, count: W * h)
        L.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                switch orientation {
                case .right90:      // saat yönünde: kare (x, y) → ekran (h-1-y, x); yeni genişlik h, yükseklik W
                    for y in 0..<h {
                        let row = (y + top) * W
                        let xd = h - 1 - y
                        for x in 0..<W { dst[x * h + xd] = src[row + x] }
                    }
                case .left90:       // saat yönünün tersine: kare (x, y) → ekran (y, W-1-x)
                    for y in 0..<h {
                        let row = (y + top) * W
                        for x in 0..<W { dst[(W - 1 - x) * h + y] = src[row + x] }
                    }
                case .rotate180:    // kare (x, y) → ekran (W-1-x, h-1-y)
                    for y in 0..<h {
                        let row = (y + top) * W
                        let rowD = (h - 1 - y) * W
                        for x in 0..<W { dst[rowD + (W - 1 - x)] = src[row + x] }
                    }
                case .normal:
                    break
                }
            }
        }
        return orientation.isQuarterTurn ? (out, h, W) : (out, W, h)
    }

    static func boxBlur(_ src: [Float], w: Int, h: Int, r: Int) -> [Float] {
        var out = [Float](repeating: 0, count: w * h)
        if w < 2 || h < 2 || r < 1 { return src }
        var tmp = [Float](repeating: 0, count: w * h)
        let inv = 1.0 / Float(2 * r + 1)
        src.withUnsafeBufferPointer { s in
            tmp.withUnsafeMutableBufferPointer { t in
                for y in 0..<h {
                    let row = y * w
                    var sum: Float = 0
                    for k in -r...r { sum += s[row + min(max(k, 0), w - 1)] }
                    t[row] = sum * inv
                    for x in 1..<w {
                        sum += s[row + min(x + r, w - 1)] - s[row + max(x - 1 - r, 0)]
                        t[row + x] = sum * inv
                    }
                }
            }
        }
        var col = [Float](repeating: 0, count: w)
        tmp.withUnsafeBufferPointer { t in
            out.withUnsafeMutableBufferPointer { o in
                for k in -r...r {
                    let yy = min(max(k, 0), h - 1) * w
                    for x in 0..<w { col[x] += t[yy + x] }
                }
                for x in 0..<w { o[x] = col[x] * inv }
                for y in 1..<h {
                    let add = min(y + r, h - 1) * w
                    let sub = max(y - 1 - r, 0) * w
                    let base = y * w
                    for x in 0..<w {
                        col[x] += t[add + x] - t[sub + x]
                        o[base + x] = col[x] * inv
                    }
                }
            }
        }
        return out
    }

    /// Kapama (önce genişlet, sonra aşındır). Çerçeve dışı: genişletmede yok sayılır, aşındırmada engel olmaz.
    static func closeMask(_ src: [Bool], gw: Int, gh: Int, r: Int) -> [Bool] {
        func pass(_ a: [Bool], horizontal: Bool, erode: Bool) -> [Bool] {
            var out = [Bool](repeating: false, count: a.count)
            for y in 0..<gh {
                for x in 0..<gw {
                    var result = erode
                    for k in -r...r {
                        let xx = horizontal ? x + k : x
                        let yy = horizontal ? y : y + k
                        if xx < 0 || xx >= gw || yy < 0 || yy >= gh { continue }
                        let v = a[yy * gw + xx]
                        if erode {
                            if !v {
                                result = false
                                break
                            }
                        } else if v {
                            result = true
                            break
                        }
                    }
                    out[y * gw + x] = result
                }
            }
            return out
        }
        var d = pass(src, horizontal: true, erode: false)
        d = pass(d, horizontal: false, erode: false)
        var e = pass(d, horizontal: true, erode: true)
        e = pass(e, horizontal: false, erode: true)
        return e
    }

    static let gutterMin = 2
    static let columnMinWidth = 8
    static let columnMinCells = 30

    /// Yazı bölgesinde ince ayrıntı enerjisi / orta band enerjisi (keskin ≈ 1+, bulanık < 0,5)
    static func sharpness(_ L: [Float], width W: Int, px0: Int, px1: Int, py0: Int, py1: Int) -> Double {
        let rw = px1 - px0
        let rh = py1 - py0
        guard rw >= 16, rh >= 16 else { return 0 }
        var region = [Float](repeating: 0, count: rw * rh)
        L.withUnsafeBufferPointer { p in
            for y in 0..<rh {
                let src = (py0 + y) * W + px0
                for x in 0..<rw { region[y * rw + x] = p[src + x] }
            }
        }
        let b1 = boxBlur(region, w: rw, h: rh, r: 1)
        let b2 = boxBlur(region, w: rw, h: rh, r: 3)
        var e1 = 0.0
        var e2 = 0.0
        for i in 0..<(rw * rh) {
            e1 += Double(abs(region[i] - b1[i]))
            e2 += Double(abs(b1[i] - b2[i]))
        }
        return e1 / (e2 + 1e-6 * Double(rw * rh))
    }

    /// Yazı hücrelerinin dikey izdüşümündeki boşluklardan sütun / yan yana sayfa kutuları
    static func findColumns(kept: [Bool], gw: Int, r0: Int, rows gh: Int, width W: Int, height H: Int, luma L: [Float]) -> [ColumnBox] {
        var cnt = [Int](repeating: 0, count: gw)
        for cy in r0..<gh {
            for cx in 0..<gw where kept[cy * gw + cx] { cnt[cx] += 1 }
        }
        let positives = cnt.filter { $0 > 0 }.sorted()
        if positives.isEmpty { return [] }
        let valleyLimit = 0.25 * Double(positives[positives.count / 2])
        var runs: [(Int, Int)] = []
        var cx = 0
        while cx < gw {
            if Double(cnt[cx]) > valleyLimit {
                let start = cx
                while cx < gw && Double(cnt[cx]) > valleyLimit { cx += 1 }
                runs.append((start, cx - 1))
            } else {
                cx += 1
            }
        }
        var merged: [(Int, Int)] = []
        for r in runs {
            if let last = merged.last, r.0 - last.1 - 1 < gutterMin {
                merged[merged.count - 1].1 = r.1
            } else {
                merged.append(r)
            }
        }
        var out: [ColumnBox] = []
        for (s, e) in merged {
            if e - s + 1 < columnMinWidth { continue }
            var n = 0
            var xs0 = Int.max
            var xs1 = -1
            for x in s...e {
                n += cnt[x]
                if cnt[x] >= 2 {
                    xs0 = min(xs0, x)
                    xs1 = max(xs1, x)
                }
            }
            if n < columnMinCells || xs1 < 0 { continue }
            var ry0 = -1
            var ry1 = -1
            for cy in r0..<gh {
                var c = 0
                for x in s...e where kept[cy * gw + x] { c += 1 }
                if c >= 2 {
                    if ry0 < 0 { ry0 = cy }
                    ry1 = cy
                }
            }
            if ry0 < 0 { continue }
            var b = ColumnBox(x0: Double(xs0 * cell) / Double(W), x1: Double((xs1 + 1) * cell) / Double(W),
                              y0: Double(ry0 * cell) / Double(H), y1: Double((ry1 + 1) * cell) / Double(H),
                              cells: n, sharp: 0)
            b.sharp = sharpness(L, width: W, px0: xs0 * cell, px1: (xs1 + 1) * cell, py0: ry0 * cell, py1: (ry1 + 1) * cell)
            out.append(b)
        }
        return out
    }

    /// Parlama: yazı kutusunun (8 hücre genişletilmiş) içinde, yazı olmayan ve neredeyse tam beyaza doymuş
    /// (hücre ortalaması ≥ 250) kompakt büyük leke: en az 12 hücre, 3x3'ten büyük, yazı kutusunun %4'ü; lekenin en az
    /// dörtte biri gerçek yazı kutusunun içinde olmalı. Parlak kâğıt, boş kenar boşlukları ve satır araları parlama sayılmaz.
    /// Dönen değer: leke hücreleri / yazı kutusu hücreleri (yoksa 0).
    static func glareFraction(mean: [Float], kept: [Bool], eroded: [Bool], gw: Int,
                              rows: Range<Int>, cols: Range<Int>) -> Double {
        guard rows.count >= 4, cols.count >= 4, gw > 0 else { return 0 }
        let gh = mean.count / gw
        let er0 = max(0, rows.lowerBound - 8)
        let er1 = min(gh, rows.upperBound + 8)
        let ec0 = max(0, cols.lowerBound - 8)
        let ec1 = min(gw, cols.upperBound + 8)
        let bw = ec1 - ec0
        let bh = er1 - er0
        guard bw > 0, bh > 0 else { return 0 }
        let boxCells = rows.count * cols.count
        var blown = [Bool](repeating: false, count: bw * bh)
        for y in 0..<bh {
            for x in 0..<bw {
                let i = (er0 + y) * gw + ec0 + x
                if mean[i] >= 250 && !kept[i] && eroded[i] { blown[y * bw + x] = true }
            }
        }
        var seen = [Bool](repeating: false, count: bw * bh)
        var best = 0
        var stack: [Int] = []
        for start in 0..<(bw * bh) where blown[start] && !seen[start] {
            seen[start] = true
            stack.append(start)
            var area = 0
            var inside = 0
            var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
            while let i = stack.popLast() {
                area += 1
                let x = i % bw
                let y = i / bw
                if rows.contains(er0 + y) && cols.contains(ec0 + x) { inside += 1 }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                if x > 0, blown[i - 1], !seen[i - 1] { seen[i - 1] = true; stack.append(i - 1) }
                if x < bw - 1, blown[i + 1], !seen[i + 1] { seen[i + 1] = true; stack.append(i + 1) }
                if y > 0, blown[i - bw], !seen[i - bw] { seen[i - bw] = true; stack.append(i - bw) }
                if y < bh - 1, blown[i + bw], !seen[i + bw] { seen[i + bw] = true; stack.append(i + bw) }
            }
            let w = maxX - minX + 1
            let h = maxY - minY + 1
            if area >= 12 && w >= 3 && h >= 3
                && Double(area) >= 0.04 * Double(boxCells)
                && Double(area) >= 0.45 * Double(w * h)
                && Double(inside) >= 0.25 * Double(area) {
                best = max(best, area)
            }
        }
        return Double(best) / Double(boxCells)
    }

    /// Yazı hücrelerindeki mürekkep parçalarını (8 komşuluklu bağlı bileşenler) sayar. Harf boyutunda parça: en çok 60x60 piksel
    /// ve 1800 pikselden küçük. `share`: mürekkep piksellerinin harf boyutundaki parçalara düşen oranı.
    static func glyphStats(ink: [UInt8], kept: [Bool], gw: Int, gh: Int, width W: Int) -> (count: Int, share: Double) {
        var px = ink
        let limitX = gw * cell
        let limitY = gh * cell
        var total = 0
        var compact = 0
        var count = 0
        var stack: [Int] = []
        for sy in 0..<limitY {
            for sx in 0..<limitX {
                let s = sy * W + sx
                if px[s] != 1 || !kept[(sy / cell) * gw + (sx / cell)] { continue }
                px[s] = 2
                stack.append(s)
                var minX = sx
                var maxX = sx
                var minY = sy
                var maxY = sy
                var area = 0
                while let i = stack.popLast() {
                    area += 1
                    let x = i % W
                    let y = i / W
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                    for dy in -1...1 {
                        for dx in -1...1 where dx != 0 || dy != 0 {
                            let nx = x + dx
                            let ny = y + dy
                            if nx < 0 || ny < 0 || nx >= limitX || ny >= limitY { continue }
                            if !kept[(ny / cell) * gw + (nx / cell)] { continue }
                            let j = ny * W + nx
                            if px[j] == 1 {
                                px[j] = 2
                                stack.append(j)
                            }
                        }
                    }
                }
                total += area
                if area >= 3 && maxX - minX + 1 <= 60 && maxY - minY + 1 <= 60 && area <= 1800 {
                    compact += area
                    count += 1
                }
            }
        }
        return (count, total > 0 ? Double(compact) / Double(total) : 0)
    }

    /// `skipTop`: üstteki bu orandaki satırlar ölçüme girmez (kameranın saat yazısı); çevrilmiş düzlemde 0.
    static func analyze(luma L: [Float], width W: Int, height H: Int, skipTop band: Double = GuidanceAnalyzer.skipTop) -> PageMetrics {
        var m = PageMetrics()
        guard W >= 64, H >= 64, L.count == W * H else { return m }
        let top = Int(Double(H) * band)

        // Parlaklık dağılımı (üst saat bandı hariç): kâğıt beyazı = %90, koyu uç = %5
        var hist = [Int](repeating: 0, count: 256)
        L.withUnsafeBufferPointer { p in
            for i in (top * W)..<(W * H) {
                let v = Int(p[i])
                hist[v < 0 ? 0 : (v > 255 ? 255 : v)] += 1
            }
        }
        let total = (H - top) * W
        func percentile(_ q: Double) -> Double {
            var cum = 0
            for t in 0..<256 {
                cum += hist[t]
                if Double(cum) / Double(total) >= q { return Double(t) }
            }
            return 255
        }
        let p90 = percentile(0.90)
        let p5 = percentile(0.05)
        let range = p90 - p5
        m.paper = p90
        if p90 < 90 || range < 40 { return m }

        // 8x8 hücre ortalamaları
        let gw = W / cell
        let gh = H / cell
        let r0 = Int((Double(top) / Double(cell)).rounded(.up))
        var mean = [Float](repeating: 0, count: gw * gh)
        L.withUnsafeBufferPointer { p in
            for cy in 0..<gh {
                for cx in 0..<gw {
                    var sum: Float = 0
                    for y in 0..<cell {
                        let o = (cy * cell + y) * W + cx * cell
                        for x in 0..<cell { sum += p[o + x] }
                    }
                    mean[cy * gw + cx] = sum / Float(cell * cell)
                }
            }
        }

        // Sayfa/arka plan ayrımı: hücre ortalamalarında Otsu eşiği
        var h2 = [Double](repeating: 0, count: 256)
        var tot = 0.0
        var sumAll = 0.0
        if r0 < gh {
            for i in (r0 * gw)..<(gh * gw) {
                let v = Int(mean[i])
                let c = v < 0 ? 0 : (v > 255 ? 255 : v)
                h2[c] += 1
                tot += 1
                sumAll += Double(c)
            }
        }
        if tot < 10 { return m }
        var wb = 0.0
        var sb = 0.0
        var best = -1.0
        var thr = 0
        for t in 0..<256 {
            wb += h2[t]
            sb += h2[t] * Double(t)
            if wb == 0 || wb == tot { continue }
            let wf = tot - wb
            let mb = sb / wb
            let mf = (sumAll - sb) / wf
            let v = wb * wf * (mb - mf) * (mb - mf)
            if v > best {
                best = v
                thr = t
            }
        }
        let threshold = Float(max(Double(thr), 0.45 * p90))
        var page = [Bool](repeating: false, count: gw * gh)
        for cy in r0..<gh {
            for cx in 0..<gw where mean[cy * gw + cx] > threshold { page[cy * gw + cx] = true }
        }
        // Yoğun yazının koyu hücreleri sayfada delik açmasın: 5x5 kapama (üstteki saat bandı yine dışarıda kalır)
        page = closeMask(page, gw: gw, gh: gh, r: 2)
        for i in 0..<min(r0 * gw, page.count) { page[i] = false }

        // Bağlı (4 komşuluk) parlak bölgeler: en büyüğü sayfa; en büyüğün %30'undan büyükler
        // (dikişle ayrılmış yan yana ikinci sayfa) de sayfa sayılır
        var label = [Int32](repeating: 0, count: gw * gh)
        var sizes: [Int] = [0]
        var bestSize = 0
        var nextLabel: Int32 = 0
        var stack: [Int] = []
        for start in 0..<(gw * gh) where page[start] && label[start] == 0 {
            nextLabel += 1
            var size = 0
            stack.append(start)
            label[start] = nextLabel
            while let i = stack.popLast() {
                size += 1
                let cx = i % gw
                let cy = i / gw
                if cx > 0, page[i - 1], label[i - 1] == 0 { label[i - 1] = nextLabel; stack.append(i - 1) }
                if cx < gw - 1, page[i + 1], label[i + 1] == 0 { label[i + 1] = nextLabel; stack.append(i + 1) }
                if cy > 0, page[i - gw], label[i - gw] == 0 { label[i - gw] = nextLabel; stack.append(i - gw) }
                if cy < gh - 1, page[i + gw], label[i + gw] == 0 { label[i + gw] = nextLabel; stack.append(i + gw) }
            }
            sizes.append(size)
            if size > bestSize { bestSize = size }
        }
        if bestSize == 0 { return m }
        var keepLabel = [Bool](repeating: false, count: sizes.count)
        var keptSize = 0
        for l in 1..<sizes.count where Double(sizes[l]) >= 0.3 * Double(bestSize) {
            keepLabel[l] = true
            keptSize += sizes[l]
        }
        m.hasPage = Double(keptSize) / Double(gw * gh) > 0.12

        // Sayfayı 2 hücre aşındır (çerçeve kenarına dayanan yerler aşınmaz: dışarısı sayfa sayılır)
        var eroded = [Bool](repeating: false, count: gw * gh)
        for cy in r0..<gh {
            for cx in 0..<gw {
                var all = true
                search: for dy in -2...2 {
                    let yy = min(max(cy + dy, 0), gh - 1)
                    for dx in -2...2 {
                        let xx = min(max(cx + dx, 0), gw - 1)
                        let l = label[yy * gw + xx]
                        if l == 0 || !keepLabel[Int(l)] {
                            all = false
                            break search
                        }
                    }
                }
                eroded[cy * gw + cx] = all
            }
        }

        // Yerel ortalama (15x15)
        let loc = boxBlur(L, w: W, h: H, r: 7)

        // Sayfa kenarı: büyük ölçekte parlaklık sıçraması olan hücreler yazı sayılmaz.
        // Mürekkep: yerel ortalamadan belirgin koyu ve kâğıda göre mutlak koyu pikseller.
        var edgeCell = [Bool](repeating: false, count: gw * gh)
        var inkCount = [Int](repeating: 0, count: gw * gh)
        var inkPx = [UInt8](repeating: 0, count: W * H)      // mürekkep pikselleri (harf parçası sayımı için)
        let edgeLimit = Float(0.55 * range)
        let inkAbs = Float(0.62 * p90)
        L.withUnsafeBufferPointer { p in
            loc.withUnsafeBufferPointer { q in
                for y in 0..<(gh * cell) {
                    let cy = y / cell
                    let row = y * W
                    for x in 0..<(gw * cell) {
                        let cx = x / cell
                        let ci = cy * gw + cx
                        let i = row + x
                        let v = p[i]
                        let l = q[i]
                        if v < l - 35 && v < inkAbs {
                            inkCount[ci] += 1
                            inkPx[i] = 1
                        }
                        if !edgeCell[ci] {
                            var strong = false
                            if x >= 8 && x < W - 8 && abs(q[i + 8] - q[i - 8]) > edgeLimit { strong = true }
                            if !strong && y >= 8 && y < H - 8 && abs(q[i + 8 * W] - q[i - 8 * W]) > edgeLimit { strong = true }
                            if strong { edgeCell[ci] = true }
                        }
                    }
                }
            }
        }

        var textCell = [Bool](repeating: false, count: gw * gh)
        for i in 0..<(gw * gh) where eroded[i] && !edgeCell[i] {
            let d = Double(inkCount[i]) / Double(cell * cell)
            if d > 0.04 && d < 0.85 { textCell[i] = true }
        }
        // Satırda yan yana en az iki komşu metin hücresi olmalı (yazı satırları geniştir; toz/gölge değil)
        var kept = [Bool](repeating: false, count: gw * gh)
        var cells = 0
        for cy in r0..<gh {
            for cx in 0..<gw where textCell[cy * gw + cx] {
                var n = 0
                for dx in -3...3 where dx != 0 {
                    let xx = cx + dx
                    if xx >= 0 && xx < gw && textCell[cy * gw + xx] { n += 1 }
                }
                if n >= 2 {
                    kept[cy * gw + cx] = true
                    cells += 1
                }
            }
        }
        // Satır uzatma: kameranın kenarında ışık düşüşü (vinyet) sayfa maskesini karartabilir ve kenara dayanan yazı
        // satırı kısa görünür. Mürekkep yoğunluğu sürdükçe (en çok 1 hücre boşlukla) satır sola/sağa uzatılır;
        // sayfa kenarı (parlaklık sıçraması) uzatmayı durdurur. Gerçek kamera karelerinde saptandı.
        for cy in r0..<gh {
            var first = -1
            var last = -1
            var n = 0
            for cx in 0..<gw where kept[cy * gw + cx] {
                if first < 0 { first = cx }
                last = cx
                n += 1
            }
            if n < 3 { continue }
            for (step, start) in [(-1, first), (1, last)] {
                var x = start
                var gap = 0
                while true {
                    let nx = x + step
                    if nx < 0 || nx >= gw { break }
                    let i = cy * gw + nx
                    let d = Double(inkCount[i]) / Double(cell * cell)
                    if d > 0.04 && d < 0.85 && !edgeCell[i] {
                        if !kept[i] {
                            kept[i] = true
                            cells += 1
                        }
                        gap = 0
                    } else {
                        gap += 1
                        if gap > 1 { break }
                    }
                    x = nx
                }
            }
        }
        m.cells = cells
        if cells < 12 { return m }

        var firstRow = -1
        var lastRow = -1
        var firstCol = Int.max
        var lastCol = -1
        for cy in 0..<gh {
            var count = 0
            for cx in 0..<gw where kept[cy * gw + cx] {
                count += 1
                if cx < firstCol { firstCol = cx }
                if cx > lastCol { lastCol = cx }
            }
            if count >= 2 {
                if firstRow < 0 { firstRow = cy }
                lastRow = cy
            }
        }
        if firstRow < 0 || lastCol < 0 { return m }
        let px0 = firstCol * cell
        let px1 = (lastCol + 1) * cell
        let py0 = firstRow * cell
        let py1 = (lastRow + 1) * cell
        m.hasText = true
        let gl = glyphStats(ink: inkPx, kept: kept, gw: gw, gh: gh, width: W)
        m.glyphs = gl.count
        m.glyphShare = gl.share
        m.glare = glareFraction(mean: mean, kept: kept, eroded: eroded, gw: gw,
                                rows: firstRow..<(lastRow + 1), cols: firstCol..<(lastCol + 1))
        m.x0 = Double(px0) / Double(W)
        m.x1 = Double(px1) / Double(W)
        m.y0 = Double(py0) / Double(H)
        m.y1 = Double(py1) / Double(H)

        m.columns = findColumns(kept: kept, gw: gw, r0: r0, rows: gh, width: W, height: H, luma: L)
        if m.columns.count == 1 {
            m.sharp = m.columns[0].sharp
        } else {
            m.sharp = sharpness(L, width: W, px0: px0, px1: px1, py0: py0, py1: py1)
        }
        return m
    }
}

// MARK: - Bölüm seçimi

/// Kadrajda birden fazla bölüm (sütun ya da yan yana sayfa) varken kullanıcının sesle seçtiği hedef.
enum ColumnChoice: String, CaseIterable {
    case left, right, middle, all

    var title: String {
        switch self {
        case .left: return "Sol"
        case .right: return "Sağ"
        case .middle: return "Orta"
        case .all: return "Hepsi"
        }
    }
}

// MARK: - Karar

enum GuidanceAdvice: String, Equatable {
    case noText, chooseColumn, moveLeft, moveRight, moveUp, moveDown, farther, closer, blurry, glare, ok

    /// Kamerayı sola / sağa / yukarı / aşağı kaydırma önerisi mi
    var isMove: Bool {
        switch self {
        case .moveLeft, .moveRight, .moveUp, .moveDown: return true
        default: return false
        }
    }

    /// Konumu düzelten öneri (kaydır, yaklaş, uzaklaş): gidişi izlenir
    var isCorrection: Bool { return isMove || self == .closer || self == .farther }

    var isHorizontal: Bool { return self == .moveLeft || self == .moveRight }

    /// Ters öneri: sola ↔ sağa, yukarı ↔ aşağı, yaklaş ↔ uzaklaş
    var opposite: GuidanceAdvice? {
        switch self {
        case .moveLeft: return .moveRight
        case .moveRight: return .moveLeft
        case .moveUp: return .moveDown
        case .moveDown: return .moveUp
        case .closer: return .farther
        case .farther: return .closer
        default: return nil
        }
    }

    /// "sola" / "sağa" / "yukarı" / "aşağı" (kaydırma dışındaki öneriler için boş)
    var directionWord: String {
        switch self {
        case .moveLeft: return "sola"
        case .moveRight: return "sağa"
        case .moveUp: return "yukarı"
        case .moveDown: return "aşağı"
        default: return ""
        }
    }
}

/// Düzeltmenin gidişi: kamera durunca önceki durumla karşılaştırılır
enum GuidanceTrend: Equatable {
    case steady
    /// Doğru yöne gidildi, kalan miktar azaldı
    case better
    /// Ters yöne gidildi, kalan miktar arttı
    case worse
    /// Fazla gidildi: öneri tersine döndü (sağa kaydırırken fazla kaçtı → artık sola)
    case overshoot
}

/// Aynı düzeltme önerisinin ardışık ölçümlerini karşılaştırır. Kamera hareket ederken ölçüm yoktur; durgunlaşınca ilk ölçüm hareket
/// öncesindeki ölçümle kıyaslanır ve sonuç, söylenene (ya da süresi dolana) kadar saklanır.
struct GuidanceTrendTracker {
    private var refAdvice: GuidanceAdvice?
    private var refNeed = 0.0
    private var refTime: TimeInterval = -1000
    private var pending: GuidanceTrend = .steady
    private var pendingTime: TimeInterval = -1000

    mutating func reset() {
        refAdvice = nil
        refNeed = 0
        refTime = -1000
        pending = .steady
        pendingTime = -1000
    }

    private mutating func rebase(_ a: GuidanceAdvice, _ need: Double?, _ time: TimeInterval) {
        refAdvice = a
        refNeed = need ?? 0
        refTime = time
    }

    /// `need`: düzeltmeden kalan miktar (kaydırmada kadraj oranı, yaklaşmada gereken büyütme − 1); ölçülemiyorsa nil
    mutating func observe(_ a: GuidanceAdvice, need: Double?, time: TimeInterval, config c: GuidanceConfig) {
        guard a.isCorrection else {
            // Konum uygun oldu ya da yazı hiç görünmüyor: düzeltme bitti, eski karşılaştırma geçersiz
            if a == .ok || a == .noText { reset() }
            return
        }
        guard let ra = refAdvice, time - refTime <= c.trendWindow else {
            rebase(a, need, time)
            return
        }
        if ra == a {
            if let n = need {
                let step = a == .closer ? c.trendScaleStep : c.trendStep
                let delta = n - refNeed
                if delta <= -step {
                    pending = .better
                    pendingTime = time
                    rebase(a, n, time)
                    return
                }
                if delta >= step {
                    pending = .worse
                    pendingTime = time
                    rebase(a, n, time)
                    return
                }
            }
            // Yavaş kayma birikebilsin ama karşılaştırma noktası da çok eskimesin
            if time - refTime >= c.trendRebase { rebase(a, need, time) }
        } else if ra.opposite == a {
            pending = .overshoot
            pendingTime = time
            rebase(a, need, time)
        } else {
            rebase(a, need, time)
        }
    }

    /// Söylenmeyi bekleyen gidiş var mı (söylenmeden tüketilmez)
    func peek(at time: TimeInterval, config c: GuidanceConfig) -> GuidanceTrend {
        return time - pendingTime <= c.trendWindow ? pending : .steady
    }

    /// Bekleyen gidişi verir ve siler
    mutating func take(at time: TimeInterval, config c: GuidanceConfig) -> GuidanceTrend {
        let t = peek(at: time, config: c)
        pending = .steady
        return t
    }
}

/// Kadrajın sesli tarifi: kaç sayfa görünüyor, hangisi tam sığıyor, hangisi kesik ("İki sayfa görünüyor. Soldaki tam sığıyor,
/// sağdakinin bir bölümü görünüyor."). Ölçüm yazı bölümlerinindir: yan yana iki sayfa ile iki sütunlu tek sayfa ayırt edilemez.
enum GuidanceScene {
    /// Bir bölümün hangi kadraj kenarına dayalı (kesik) olduğu
    struct Part: Equatable {
        var left = false
        var right = false
        var top = false
        var bottom = false
        var cut: Bool { return left || right || top || bottom }
    }

    /// Soldan sağa bölümler. Yazı yoksa boş.
    static func parts(_ m: PageMetrics, config c: GuidanceConfig) -> [Part] {
        guard m.hasText else { return [] }
        var boxes: [(x0: Double, x1: Double, y0: Double, y1: Double)] = m.columns.map {
            (x0: $0.x0, x1: $0.x1, y0: $0.y0, y1: $0.y1)
        }
        if boxes.isEmpty { boxes = [(x0: m.x0, x1: m.x1, y0: m.y0, y1: m.y1)] }
        return boxes.map { b in
            Part(left: b.x0 < c.edgeMargin, right: 1 - b.x1 < c.edgeMargin,
                 top: b.y0 - c.topBand < c.edgeMargin, bottom: 1 - b.y1 < c.edgeMargin)
        }
    }

    private static let countWords = ["sıfır", "bir", "iki", "üç", "dört", "beş", "altı", "yedi", "sekiz", "dokuz"]

    private static func countWord(_ n: Int) -> String {
        return n >= 0 && n < countWords.count ? countWords[n] : String(n)
    }

    private static func capital(_ s: String) -> String {
        return String(s.prefix(1)).uppercased(with: Locale(identifier: "tr_TR")) + String(s.dropFirst())
    }

    /// "sol tarafı", "iki yanı", "alt ve üst kısmı"…
    private static func edgeList(_ p: Part) -> String {
        var pieces: [String] = []
        if p.left && p.right {
            pieces.append("iki yanı")
        } else if p.left {
            pieces.append("sol tarafı")
        } else if p.right {
            pieces.append("sağ tarafı")
        }
        if p.top && p.bottom {
            pieces.append("alt ve üst kısmı")
        } else if p.top {
            pieces.append("üst kısmı")
        } else if p.bottom {
            pieces.append("alt kısmı")
        }
        return pieces.joined(separator: " ve ")
    }

    /// Kesik bölümün tarifi: yandan kesikse "bir bölümü görünüyor", yalnız alttan / üstten kesikse "alt kısmı kesik"
    private static func partial(_ p: Part) -> String {
        if p.left || p.right { return "bir bölümü görünüyor" }
        return edgeList(p) + " kesik"
    }

    private static func two(_ a: Part, _ b: Part) -> String {
        let head = "İki sayfa görünüyor"
        switch (a.cut, b.cut) {
        case (false, false):
            return head + ", ikisi de tam sığıyor."
        case (false, true):
            return head + ". Soldaki tam sığıyor, sağdakinin " + partial(b) + "."
        case (true, false):
            return head + ". Sağdaki tam sığıyor, soldakinin " + partial(a) + "."
        case (true, true):
            if partial(a) == partial(b) { return head + ", ikisinin de " + partial(a) + "." }
            return head + ". Soldakinin " + partial(a) + ", sağdakinin " + partial(b) + "."
        }
    }

    private static func many(_ parts: [Part]) -> String {
        let n = parts.count
        let head = capital(countWord(n)) + " bölüm görünüyor"
        let cutCount = parts.filter { $0.cut }.count
        if cutCount == 0 { return head + ", hepsi tam sığıyor." }
        if cutCount == n { return head + ", hepsi kesik." }
        guard n == 3 else { return head + ", bazıları kesik." }
        let names = ["soldaki", "ortadaki", "sağdaki"]
        let genitives = ["soldakinin", "ortadakinin", "sağdakinin"]
        var fit: [String] = []
        var partials: [String] = []
        for (i, p) in parts.enumerated() {
            if p.cut {
                partials.append(genitives[i] + " " + partial(p))
            } else {
                fit.append(names[i])
            }
        }
        var text = head + ". "
        if !fit.isEmpty { text += capital(fit.joined(separator: " ve ")) + " tam sığıyor, " }
        return text + partials.joined(separator: ", ") + "."
    }

    /// Vision'ın kâğıt kenarları, yalnız tarifte kullanılacaksa: güvenilir olmalı ve yazı bloğunu her yönde en az %1 aşmalı.
    /// Yazıya yapışık bir dörtgen kâğıt değil yazı bölgesidir ("kenarlarıyla birlikte tam sığıyor" diye yanlış söylenmesin);
    /// sayfanın bir parçası bulunmuşsa da yazıyı kapsamaz. Yazı kutusu, çevrilmiş görüntüde saat bandı payı hesaba katılarak kareye çevrilir.
    static func usableEdges(_ m: PageMetrics) -> PageEdges? {
        guard m.hasText, let e = m.edges, e.isReliable else { return nil }
        let t = e.inFrame(x0: m.x0, x1: m.x1, y0: m.y0, y1: m.y1)
        return e.surrounds(x0: t.x0, x1: t.x1, y0: t.y0, y1: t.y1, margin: 0.01) ? e : nil
    }

    /// "Sayfanın alt kenarı kadrajın dışında kalıyor." (kâğıt taşıyor ama yazı tam görünüyor)
    private static func overflow(_ e: PageEdges) -> String? {
        let cut = e.cutSides
        switch cut.count {
        case 0: return nil
        case 1: return "Sayfanın " + cut[0].word + " kenarı kadrajın dışında kalıyor."
        case 2: return "Sayfanın " + cut[0].word + " ve " + cut[1].word + " kenarları kadrajın dışında kalıyor."
        default: return "Sayfa kadraja sığmıyor, yalnız bir kısmı görünüyor."
        }
    }

    /// Konuşulacak tarif; yazı yoksa nil. `edges`: tek sayfa görünüyorsa ve yazı tam sığıyorsa kâğıdın kenarları da söylenir
    /// (yazı kesikse, ya da birden çok bölüm varsa yazı ölçümü esastır; Vision tek belge çerçevesi verir).
    static func describe(_ parts: [Part], edges: PageEdges? = nil) -> String? {
        switch parts.count {
        case 0:
            return nil
        case 1:
            let p = parts[0]
            if p.cut { return "Tek sayfa görünüyor, " + edgeList(p) + " kesik." }
            if let e = edges {
                if e.allClear { return "Tek sayfa görünüyor, kenarlarıyla birlikte tam sığıyor." }
                if let o = overflow(e) { return "Tek sayfa görünüyor, yazı tam sığıyor. " + o }
            }
            return "Tek sayfa görünüyor, tam sığıyor."
        case 2:
            return two(parts[0], parts[1])
        default:
            return many(parts)
        }
    }
}

struct GuidanceConfig {
    /// Yazı ile kadraj kenarı arası bu orandan azsa taşıyor sayılır
    var edgeMargin = 0.02
    /// Bir kenardan taşarken karşı kenar boşluğu bundan azsa kaydırmak yetmez, uzaklaşmak gerekir
    var oppositeMargin = 0.05
    /// Yazı bloğu hem eninde hem boyunda bundan küçükse yaklaşmak önerilir (birden çok bölümde bölüm payıyla çarpılır)
    var minFill = 0.55
    var minCellsForCloser = 100
    /// Ardışık kaç ölçüm aynı kalınca karar verilir / çekilir
    var stableEvaluations = 3
    var speakGap: TimeInterval = 2.5
    var repeatGap: TimeInterval = 6
    var maxRepeats = 4
    /// Bölüm sorusu: tekrar aralığı ve en çok kaç kez sorulacağı
    var questionGap: TimeInterval = 9
    var maxQuestions = 3
    /// Kamera bu kadar süre durgunsa değerlendirilir
    var stillNeeded: TimeInterval = 0.45
    /// Çekimden sonra sahne bu kadar değişince (sayfa çevrilince) yeniden hazırlanır
    var changeToRearm = 4.0
    /// Yazı kutusunun bu oranından büyük parlama lekesi varsa uyarılır (1'den büyük: parlama denetimi kapalı)
    var glareLimit = 0.04
    /// Parlama için en çok kaç kez uyarılır; sonra yine de çekilir (parlama her zaman giderilemez)
    var glareWarnings = 2
    /// "Yaklaşın" derken hedeflenen doluluk: yazı bloğunun en büyük boyutu kadrajın bu oranına varmalı
    var closerTarget = 0.70
    /// Yakınlaşmanın büyüklüğü en çok bu kadar sayılır (çok küçük bloklarda aşırı beklenti olmasın)
    var closerMaxScale = 1.6
    /// Bu kadar ya da fazla büyütme gerekiyorsa "biraz" denmez: "Yaklaşın."
    var closerBigScale = 1.35
    /// Yakınlaşınca yazının kenarda kalması istenen en az boşluk, `edgeMargin`e eklenir
    var predictMargin = 0.01
    /// Kameranın saat yazısı bandı: ölçülen karenin üstünden bu oranda yer ölçüye girmez. Görüntü çevrilmişse
    /// (90° / 180°) bant ölçümden önce atılır; bu değer 0 olur.
    var topBand = GuidanceAnalyzer.skipTop
    /// Kaydırma miktarı sözcüğü: bu orandan azsa "azıcık", `bigShift`ten azsa "biraz", fazlaysa "epey" (kadraj boyutunun oranı)
    var slightShift = 0.05
    var bigShift = 0.14
    /// Önceki ölçüme göre kalan kaydırma bu kadar (kadraj oranı) azalırsa "doğru", artarsa "ters yöne gittiniz" denir
    var trendStep = 0.03
    /// Aynısı "yaklaşın" için (gereken büyütme − 1)
    var trendScaleStep = 0.08
    /// Bu süreden eski karşılaştırma ve gidiş bilgisi (sn) geçersiz sayılır
    var trendWindow: TimeInterval = 15
    /// Karşılaştırma noktası bu kadar saniyede bir yenilenir (yavaş kayma birikebilsin, ama nokta eskimesin)
    var trendRebase: TimeInterval = 4
    /// Kadrajda tam olarak bir bölüm dört kenardan da içerideyse "Sol mu, sağ mı?" diye sormadan o bölüm seçilir (ayardan gelir)
    var autoPick = false
    /// Otomatik seçilecek bölümün en az yazı hücresi ve eni (kadraj oranı): küçük bir yazı parçası (sayfa numarası, başlık) seçilmesin
    var autoPickMinCells = 150
    var autoPickMinWidth = 0.15
}

struct GuidanceDecision: Equatable {
    var advice: GuidanceAdvice
    var options: [ColumnChoice] = []
    /// Yazı bloğunun doluluğu (en büyük boyutu, kadraj oranı; birden çok bölümde bölüm payına göre). 0: bilinmiyor.
    var fill = 0.0
    /// "Yaklaşın" kararında gereken büyütme oranı (1: yok)
    var scale = 1.0
    /// Kaydırma önerilerinde (sola/sağa/yukarı/aşağı) yazı bloğunu ortalamak için gereken kaydırma, kadraj boyutunun oranı (0: yok)
    var shift = 0.0
    /// Yazı iki kenara birden dayalıysa (köşe) ikinci yön ve kaydırması: "sola ve yukarı"
    var also: GuidanceAdvice?
    var alsoShift = 0.0
    /// Soru sorulmadan kendiliğinden seçilen bölüm (kadrajda biri tam sığıyor, diğerleri kesik); sorulmuş/seçilmişse nil
    var picked: ColumnChoice?
}

/// Ölçülerden öneri çıkarır (saf fonksiyon; birim testle denenir).
enum GuidanceAdvisor {
    static func options(forColumnCount n: Int) -> [ColumnChoice] {
        return n >= 3 ? [.left, .middle, .right, .all] : [.left, .right, .all]
    }

    /// Dört kenardan da içeride (kadraj payı ve saat bandı payıyla) belirgin boyutta TEK bölüm varsa onun seçimi; yoksa nil.
    /// Bölümler soldan sağadır; en soldaki `.left`, en sağdaki `.right`, üç bölümde ortadaki `.middle` (dört ve üstünde ortadakiler seçilemez).
    static func fittingChoice(_ cols: [ColumnBox], config c: GuidanceConfig) -> ColumnChoice? {
        guard cols.count >= 2 else { return nil }
        var fitting: [Int] = []
        for (i, b) in cols.enumerated() {
            let inside = b.x0 >= c.edgeMargin && b.x1 <= 1 - c.edgeMargin
                && b.y0 - c.topBand >= c.edgeMargin && b.y1 <= 1 - c.edgeMargin
            if inside && b.cells >= c.autoPickMinCells && b.x1 - b.x0 >= c.autoPickMinWidth { fitting.append(i) }
        }
        guard fitting.count == 1, let i = fitting.first else { return nil }
        if i == 0 { return .left }
        if i == cols.count - 1 { return .right }
        return cols.count == 3 ? .middle : nil
    }

    /// `skipping`: en son çekilen bölüm; kendiliğinden seçimde tekrar seçilmez (aynı bölümü ikinci kez çekmemek için soru sorulur).
    static func decide(_ m: PageMetrics, choice: ColumnChoice?, config c: GuidanceConfig = GuidanceConfig(),
                       sharpFloor: Double, skipping: ColumnChoice? = nil) -> GuidanceDecision {
        if !m.hasText { return GuidanceDecision(advice: m.hasPage ? .blurry : .noText) }
        // Yazıya benzemeyen desen (çizgili kumaş, tablo çizgisi…) belge sayılmaz
        if DocumentGate.verdict(m) != .document { return GuidanceDecision(advice: .noText) }
        let cols = m.columns
        if cols.count >= 2 {
            let allFit = cols.allSatisfy { $0.x0 >= c.edgeMargin && $0.x1 <= 1 - c.edgeMargin }
            var chosen = choice
            var picked: ColumnChoice?
            if !allFit && choice == nil {
                guard c.autoPick, let p = fittingChoice(cols, config: c), p != skipping else {
                    return GuidanceDecision(advice: .chooseColumn, options: options(forColumnCount: cols.count))
                }
                chosen = p
                picked = p
            }
            var targets = cols
            switch chosen {
            case .some(.left):
                if let t = cols.min(by: { $0.x0 < $1.x0 }) { targets = [t] }
            case .some(.right):
                if let t = cols.max(by: { $0.x1 < $1.x1 }) { targets = [t] }
            case .some(.middle):
                if let t = cols.min(by: { abs($0.center - 0.5) < abs($1.center - 0.5) }) { targets = [t] }
            default:
                break
            }
            let frac = Double(targets.count) / Double(cols.count)
            let sharp = targets.count == 1 ? targets[0].sharp : m.sharp
            var r = evaluateDetailed(x0: targets.map { $0.x0 }.min() ?? 0,
                                     x1: targets.map { $0.x1 }.max() ?? 1,
                                     y0: targets.map { $0.y0 }.min() ?? 0,
                                     y1: targets.map { $0.y1 }.max() ?? 1,
                                     cells: targets.reduce(0) { $0 + $1.cells },
                                     sharp: sharp, frac: frac, glare: m.glare, config: c, sharpFloor: sharpFloor)
            r.picked = picked
            return r
        }
        // Tek bölüm (ya da bölünemedi): bütün yazı bloğu
        return evaluateDetailed(x0: m.x0, x1: m.x1, y0: m.y0, y1: m.y1, cells: m.cells,
                                sharp: m.sharp, frac: 1, glare: m.glare, config: c, sharpFloor: sharpFloor)
    }

    /// Kaydırma miktarının sözcüğü: "azıcık" / "biraz" / "epey"
    static func amountWord(shift: Double, config c: GuidanceConfig = GuidanceConfig()) -> String {
        if shift < c.slightShift { return "azıcık" }
        if shift < c.bigShift { return "biraz" }
        return "epey"
    }

    static func evaluate(x0: Double, x1: Double, y0: Double, y1: Double, cells: Int, sharp: Double, frac: Double,
                         glare: Double = 0, config c: GuidanceConfig, sharpFloor: Double) -> GuidanceAdvice {
        return evaluateDetailed(x0: x0, x1: x1, y0: y0, y1: y1, cells: cells, sharp: sharp, frac: frac,
                                glare: glare, config: c, sharpFloor: sharpFloor).advice
    }

    /// "Yaklaşın" demeden önce: yakınlaşınca yazı kadrajdan taşacaksa (blok merkezden uzaktaysa) önce yazıyı ortaya almak gerekir.
    /// Yakınlaşma kadraj merkezinden büyütme gibi düşünülür; taşacak kenar varsa o yöne kaydırma önerilir.
    /// `shift`: yakınlaşmadan önce gereken kaydırma (kadraj oranı; büyütme kaydırmayı `s` kat büyüttüğü için ona bölünür).
    static func recentre(x0: Double, x1: Double, y0: Double, y1: Double, scale s: Double,
                         config c: GuidanceConfig) -> (advice: GuidanceAdvice, shift: Double)? {
        let need = c.edgeMargin + c.predictMargin
        func grow(_ v: Double) -> Double { return 0.5 + s * (v - 0.5) }
        let after: [(GuidanceAdvice, Double)] = [
            (.moveLeft, grow(x0)),
            (.moveRight, 1 - grow(x1)),
            (.moveUp, grow(y0) - c.topBand),
            (.moveDown, 1 - grow(y1)),
        ]
        let bad = after.filter { $0.1 < need }
        guard let worst = bad.min(by: { $0.1 < $1.1 }) else { return nil }
        return (worst.0, max(0, (need - worst.1) / max(s, 1)))
    }

    static func evaluateDetailed(x0: Double, x1: Double, y0: Double, y1: Double, cells: Int, sharp: Double, frac: Double,
                                 glare: Double = 0, config c: GuidanceConfig,
                                 sharpFloor: Double) -> GuidanceDecision {
        let fill = max((x1 - x0) / max(frac, 0.01), y1 - y0)
        // (öneri, o kenardaki boşluk, karşı kenardaki boşluk)
        let margins: [(GuidanceAdvice, Double, Double)] = [
            (.moveLeft, x0, 1 - x1),          // sol kenardan taşıyorsa kamera sola
            (.moveRight, 1 - x1, x0),
            (.moveUp, y0 - c.topBand, 1 - y1),
            (.moveDown, 1 - y1, y0 - c.topBand),
        ]
        let cut = margins.filter { $0.1 < c.edgeMargin }
        let leftRight = cut.contains { $0.0 == .moveLeft } && cut.contains { $0.0 == .moveRight }
        let topBottom = cut.contains { $0.0 == .moveUp } && cut.contains { $0.0 == .moveDown }
        if leftRight || topBottom { return GuidanceDecision(advice: .farther, fill: fill) }
        if let worst = cut.min(by: { $0.1 < $1.1 }) {
            if worst.2 < c.oppositeMargin { return GuidanceDecision(advice: .farther, fill: fill) }
            // Gereken kaydırma: yazı bloğunu iki kenar arasında ortalamak (kesik kalan kısım bilinmediği için alt sınırdır)
            var d = GuidanceDecision(advice: worst.0, fill: fill, shift: max(0, (worst.2 - worst.1) / 2))
            // Köşeye dayalı yazı: dik eksende de taşan, kaydırmaya yeri olan bir kenar varsa ikinci yön ("sola ve yukarı")
            let others = cut.filter { $0.0.isHorizontal != worst.0.isHorizontal && $0.2 >= c.oppositeMargin }
            if let other = others.min(by: { $0.1 < $1.1 }) {
                d.also = other.0
                d.alsoShift = max(0, (other.2 - other.1) / 2)
            }
            return d
        }
        if x1 - x0 < c.minFill * frac && y1 - y0 < c.minFill && Double(cells) >= Double(c.minCellsForCloser) * frac {
            let scale = min(c.closerMaxScale, c.closerTarget / max(fill, 0.01))
            if let side = recentre(x0: x0, x1: x1, y0: y0, y1: y1, scale: scale, config: c) {
                return GuidanceDecision(advice: side.advice, fill: fill, scale: scale, shift: side.shift)
            }
            return GuidanceDecision(advice: .closer, fill: fill, scale: scale)
        }
        if sharp < sharpFloor { return GuidanceDecision(advice: .blurry, fill: fill) }
        if glare >= c.glareLimit { return GuidanceDecision(advice: .glare, fill: fill) }
        return GuidanceDecision(advice: .ok, fill: fill)
    }

    /// Eski imza: bütün yazıyı tek bölüm sayar.
    static func advice(for m: PageMetrics, config c: GuidanceConfig = GuidanceConfig(), sharpFloor: Double) -> GuidanceAdvice {
        var single = m
        single.columns = []
        return decide(single, choice: nil, config: c, sharpFloor: sharpFloor).advice
    }
}

// MARK: - Durum makinesi

final class GuidanceEngine {
    struct Output {
        var advice: GuidanceAdvice?
        var speak: String?
        var capture = false
        var status = ""
        var awaitingChoice = false
        var options: [ColumnChoice] = []
    }

    var config = GuidanceConfig()
    var sharpFloor = 0.45
    var autoCapture = true
    var triggerWord = "okey"

    private(set) var armed = true
    /// Verilirse bölüm sorusu sorulmaz, hep bu seçim kullanılır (sayfa sayfa videoda `.all`: sayfanın hepsi hedeflenir)
    var forcedChoice: ColumnChoice?
    /// Kullanıcının sesle seçtiği bölüm (kullanıcının gözünden sol/sağ)
    private(set) var choice: ColumnChoice?
    /// Soru ekranda bekliyor mu (sesle ya da dokunarak yanıt verilebilir)
    private(set) var awaitingChoice = false
    /// Son çekilen bölüm: bir sonraki soruda "Sol bölüm çekildi" diye hatırlatılır
    private(set) var lastCaptured: ColumnChoice?
    /// Son çekimden önceki `lastCaptured`: çekim başarısız olursa ya da fotoğraf silinirse (`rearm`) geri yüklenir
    private var capturedBefore: ColumnChoice?
    private var last: GuidanceAdvice?
    private var consecutive = 0
    private var lastSpoken: GuidanceAdvice?
    private var lastSpokenTime: TimeInterval = -1000
    private var repeats = 0
    private var muted: GuidanceAdvice?
    private var blurSpeaks = 0
    private var glareSpoken = 0
    private var questionsAsked = 0
    private var lastQuestionTime: TimeInterval = -1000
    private var lastOptions: [ColumnChoice] = []
    /// Son kararın yazı doluluğu ve gereken büyütme: bulanıklık ve "yaklaşın" cümlelerini seçmek için
    private var lastFill = 0.0
    private var lastScale = 1.0
    /// Son kararın kaydırma miktarı ve (köşedeyse) ikinci yönü: cümledeki "azıcık / biraz / epey" ve "sola ve yukarı" için
    private var lastShift = 0.0
    private var lastAlso: GuidanceAdvice?
    private var lastAlsoShift = 0.0
    /// Düzeltmenin gidişi (doğru yöne mi gidiliyor): fotoğraf ve video tarifi ayrı izlenir
    private var trendTracker = GuidanceTrendTracker()
    private var vTrend = GuidanceTrendTracker()
    /// Kadrajı sesli tarif et (kaç sayfa görünüyor, hangisi sığıyor…): ayardan gelir; kapalıyken cümleler yalnız yönlendirir
    var describeScene = false
    /// Son ölçümün tarifi ve bu sayfa için söylenen son tarif (aynı tarif tekrar söylenmez, değişince yeniden söylenir)
    private var lastScene: String?
    private var toldScene: String?
    private var vToldScene: String?
    /// Soru sorulmadan kendiliğinden seçilen bölüm (son kararda) ve bu sayfa için söylenen seçim (bir kez söylenir)
    private var lastPick: ColumnChoice?
    private var toldPick: ColumnChoice?
    /// Son değerlendirilen kadrajdaki bölüm sayısı (elle çekimde "çekilen bölüm" kaydı için)
    private var lastColumns = 0
    /// Kendiliğinden seçilmiş bölüm şu an çekilmeyi bekliyor (kullanıcı "sağ" / "ikisi birden" diyerek değiştirebilir)
    var pendingPick: ColumnChoice? { return armed ? lastPick : nil }
    /// Son sorulan / sorulabilecek seçenekler (bölüm sayısına göre sol-sağ ya da sol-orta-sağ)
    var currentOptions: [ColumnChoice] { return lastOptions.isEmpty ? [.left, .right, .all] : lastOptions }

    func reset() {
        armed = true
        choice = nil
        awaitingChoice = false
        lastCaptured = nil
        capturedBefore = nil
        lastColumns = 0
        clearSpeech()
    }

    private func clearSpeech() {
        last = nil
        consecutive = 0
        lastSpoken = nil
        lastSpokenTime = -1000
        repeats = 0
        muted = nil
        blurSpeaks = 0
        glareSpoken = 0
        questionsAsked = 0
        lastQuestionTime = -1000
        trendTracker.reset()
        toldScene = nil
        toldPick = nil
        lastPick = nil
    }

    /// Çekim başarısız oldu / yapılamadı / fotoğraf silindi: yeniden denenebilsin. Çekilmeyen bölüm "çekildi" sayılmaz
    /// (yoksa kendiliğinden seçim aynı bölümü yeniden seçmez ve soru yanlış "Sol bölüm çekildi" der).
    func rearm() {
        armed = true
        consecutive = 0
        last = nil
        lastCaptured = capturedBefore
    }

    /// Kullanıcı motoru beklemeden çekti ("okey" sesli komutu ya da "Fotoğraf Çek" düğmesi): kendiliğinden çekimdeki gibi bu sayfa
    /// bitmiş sayılır. Motor sayfa değişene kadar susar (aynı sayfa ikinci kez çekilmez; sayfa çevrilince söylenenler sıfırlanır),
    /// çekilen bölüm kaydedilir ve bekleyen soru kapanır. Çekim başarısız olursa `rearm()` geri alır.
    /// Motor kendisi çekmişse (`armed` zaten kapalı) yapılacak bir şey yoktur.
    func manualCaptured() {
        guard armed else { return }
        armed = false
        consecutive = 0
        last = nil
        capturedBefore = lastCaptured
        lastCaptured = (lastColumns >= 2) ? (choice ?? lastPick) : nil
        choice = nil
        awaitingChoice = false
    }

    /// Sesle ya da düğmeyle yapılan bölüm seçimi. Döndürülen cümle hemen söylenir.
    @discardableResult
    func setChoice(_ c: ColumnChoice) -> String {
        choice = c
        awaitingChoice = false
        let q = questionsAsked
        clearSpeech()
        questionsAsked = q
        switch c {
        case .all: return "Tamam, hepsini kadraja alalım."
        default: return "Tamam, \(c.title.lowercased(with: Locale(identifier: "tr_TR"))) bölüm."
        }
    }

    /// "Yeniden seç": seçim silinir, kadrajda birden çok bölüm varsa yeniden sorulur.
    @discardableResult
    func clearChoice() -> String {
        choice = nil
        lastCaptured = nil
        capturedBefore = nil
        awaitingChoice = false
        clearSpeech()
        return "Tamam, yeniden seçelim."
    }

    func questionText(options: [ColumnChoice], first: Bool) -> String {
        var s = ""
        let scene = describeScene ? lastScene : nil
        if let l = lastCaptured {
            s += "\(l.title) bölüm çekildi. "
            if let sc = scene { s += sc + " " }
        } else if first {
            s += (scene ?? "Kadrajda ayrı bölümler var ve biri yarım kalıyor.") + " "
        }
        if options.contains(.middle) {
            s += "Hangisini çekeyim? Sol mu, orta mı, sağ mı, yoksa tamamı mı?"
        } else {
            s += "Hangisini çekeyim? Sol mu, sağ mı, yoksa ikisi birden mi?"
        }
        return s
    }

    /// "azıcık" → "Azıcık" (Türkçe büyük harfle)
    private func capitalised(_ s: String) -> String {
        return String(s.prefix(1)).uppercased(with: Locale(identifier: "tr_TR")) + String(s.dropFirst())
    }

    /// `again`: aynı uyarı ardı ardına tekrarlanıyor ("Biraz daha sola…" diye ilerleme beklenir); `stuck`: ikiden fazla tekrar, hâlâ düzelmedi.
    /// `trend`: kamera durunca önceki ölçümle kıyas (doğru yöne gidildi / ters yöne gidildi / fazla kaçtı).
    func phrase(for advice: GuidanceAdvice, again: Bool = false, trend: GuidanceTrend = .steady, stuck: Bool = false) -> String {
        switch advice {
        case .moveLeft, .moveRight, .moveUp, .moveDown:
            // Köşeye dayalıysa iki yön tek cümlede; miktar sözcüğü büyük olana göre
            var dir = advice.directionWord
            var amount = lastShift
            if let other = lastAlso {
                dir += " ve " + other.directionWord
                amount = max(amount, lastAlsoShift)
            }
            let word = GuidanceAdvisor.amountWord(shift: amount, config: config)
            switch trend {
            case .better: return "Doğru. \(capitalised(word)) daha \(dir) kaydırın."
            case .worse: return "Ters yöne gittiniz. Kamerayı \(word) \(dir) kaydırın."
            case .overshoot:
                let back = advice.opposite?.directionWord ?? ""
                return "Fazla \(back) kaydırdınız. \(capitalised(word)) \(dir) kaydırın."
            case .steady:
                if stuck { return "Hâlâ aynı yönde. Daha fazla \(dir) kaydırın." }
                return again ? "Biraz daha \(dir) kaydırın." : "Kamerayı \(word) \(dir) kaydırın."
            }
        case .farther:
            if trend == .overshoot { return "Fazla yaklaştınız. Biraz uzaklaşın." }
            if stuck { return "Hâlâ taşıyor. Daha fazla uzaklaşın." }
            return again ? "Biraz daha uzaklaşın." : "Biraz uzaklaşın, yazı kadrajdan taşıyor."
        case .closer:
            switch trend {
            case .better: return "Doğru. Biraz daha yaklaşın."
            case .worse: return "Ters yöne gittiniz. Yaklaşın."
            case .overshoot: return "Fazla uzaklaştınız. Biraz yaklaşın."
            case .steady: break
            }
            if stuck { return "Hâlâ küçük. Daha fazla yaklaşın." }
            if again { return "Biraz daha yaklaşın." }
            return lastScale >= config.closerBigScale ? "Yaklaşın, yazı küçük kalıyor." : "Biraz yaklaşın."
        case .noText: return "Yazı görünmüyor. Kamerayı belgeye çevirin."
        case .chooseColumn: return questionText(options: lastOptions, first: questionsAsked == 0)
        case .blurry:
            // Yazı kadrajı dolduruyorsa büyük olasılıkla fazla yakındır: önce uzaklaşmak; küçükse önce sabit tutup beklemek
            let options: [String]
            if lastFill >= 0.9 {
                options = ["Görüntü net değil, çok yakınsınız. Biraz uzaklaşın.",
                           "Yine de net değil. Kamerayı sabit tutup bekleyin.",
                           "Net değil. Biraz yaklaşın."]
            } else if lastFill >= 0.7 {
                options = ["Görüntü net değil. Biraz uzaklaşın.",
                           "Yine de net değil. Kamerayı sabit tutup bekleyin.",
                           "Net değil. Biraz yaklaşın."]
            } else {
                options = ["Görüntü net değil. Kamerayı sabit tutup bekleyin.",
                           "Yine de net değil. Biraz yaklaşın.",
                           "Net değil. Biraz uzaklaşın."]
            }
            return options[blurSpeaks % options.count]
        case .glare: return "Sayfada parlama var. Kamerayı biraz eğin ya da ışığı değiştirin."
        case .ok: return "Çekiyorum."
        }
    }

    /// Kendiliğinden seçilen bölümün duyurusu: "Soldaki bölüm tam sığıyor, onu çekiyorum." Kadraj tarifi açıksa tarif başa gelir.
    func pickAnnouncement(_ pick: ColumnChoice) -> String {
        let names: (adjective: String, accusative: String)
        switch pick {
        case .left: names = ("Soldaki", "Soldakini")
        case .right: names = ("Sağdaki", "Sağdakini")
        case .middle: names = ("Ortadaki", "Ortadakini")
        case .all: names = ("Hepsi", "Hepsini")
        }
        let act = autoCapture ? "çekiyorum" : "çekmek için \(triggerWord) deyin"
        if describeScene, let sc = lastScene { return "\(sc) \(names.accusative) \(act)." }
        return "\(names.adjective) bölüm tam sığıyor, onu \(act)."
    }

    func statusText(for advice: GuidanceAdvice) -> String {
        let prefix = choice.map { "\($0.title): " } ?? ""
        switch advice {
        case .ok: return prefix + (autoCapture ? "Konum uygun — sabit tutun" : "Konum uygun — “\(triggerWord)” deyin")
        case .blurry: return prefix + "Görüntü net değil"
        case .glare: return prefix + "Parlama var — açıyı ya da ışığı değiştirin"
        case .chooseColumn: return "Hangisini çekeyim? “Sol” ya da “sağ” deyin"
        default: return prefix + String(phrase(for: advice).dropLast())
        }
    }

    // MARK: Video kaydı sırasında yalnız konum tarifi

    private var vLast: GuidanceAdvice?
    private var vConsecutive = 0
    private var vLastSpoken: GuidanceAdvice?
    private var vLastSpokenTime: TimeInterval = -1000
    private var vRepeats = 0
    private var vMuted: GuidanceAdvice?
    /// Bir düzeltme söylenmişti ve kadraj uygun oldu: "Tamam, böyle." denmesi bekleniyor
    private var vTellOK = false

    /// Video başlarken / biterken: video tarifinin sayaçları sıfırlanır (fotoğraf durumuna dokunulmaz)
    func resetVideo() {
        vLast = nil
        vConsecutive = 0
        vLastSpoken = nil
        vLastSpokenTime = -1000
        vRepeats = 0
        vMuted = nil
        vTellOK = false
        vTrend.reset()
        vToldScene = nil
    }

    func videoStatus(for advice: GuidanceAdvice) -> String {
        if advice == .ok { return "Video: kadraj uygun" }
        return "Video: " + String(phrase(for: advice).dropLast())
    }

    /// Video kaydı sırasında: yalnız konum tarifi (kamerayı sola/sağa/yukarı/aşağı kaydır, yaklaş, uzaklaş, yazı görünmüyor).
    /// Çekim, bölüm sorusu, netlik ve parlama uyarısı YOKTUR (video akarken sayfa çevrilir, kamera oynar). Kadrajda birden çok bölüm
    /// (yan yana sayfa) varsa hepsi hedeflenir. Kamera hareket ederken susar; durgunlaşınca ölçülür.
    func videoStep(_ metrics: PageMetrics, time: TimeInterval, stillFor: TimeInterval) -> Output {
        guard stillFor >= config.stillNeeded else {
            vLast = nil
            vConsecutive = 0
            return Output(status: "Video: kamera hareket ediyor…")
        }
        var c = config
        c.glareLimit = 2
        let d = GuidanceAdvisor.decide(metrics, choice: .all, config: c, sharpFloor: 0)
        lastFill = d.fill
        lastScale = d.scale
        lastShift = d.shift
        lastAlso = d.also
        lastAlsoShift = d.alsoShift
        lastScene = describeScene && d.advice != .noText
            ? GuidanceScene.describe(GuidanceScene.parts(metrics, config: config), edges: GuidanceScene.usableEdges(metrics)) : nil
        var a = d.advice
        if a == .blurry || a == .glare || a == .chooseColumn { a = .ok }
        vTrend.observe(a, need: trendNeed(d, a), time: time, config: config)
        if a == vLast {
            vConsecutive += 1
        } else {
            vLast = a
            vConsecutive = 1
            if a != vMuted { vMuted = nil }
        }
        var out = Output(advice: a, status: videoStatus(for: a))
        if a == .ok {
            // Bir düzeltme söylenmişse kadraj iki ölçüm üst üste uygun kalınca bir kez "Tamam" denir (tek ölçümlük titreme sayılmaz)
            if vLastSpoken != nil { vTellOK = true }
            vRepeats = 0
            vLastSpoken = nil
            vMuted = nil
            if vTellOK && vConsecutive >= 2 {
                vTellOK = false
                out.speak = "Tamam, böyle."
                if let sc = lastScene { out.speak = "Tamam, böyle. " + sc }
            }
            vToldScene = nil
            return out
        }
        vTellOK = false
        // "Yazı görünmüyor" sayfa çevrilirken de olur: daha uzun sürerse söylenir
        let needed = a == .noText ? 4 : 2
        guard vConsecutive >= needed, a != vMuted, time - vLastSpokenTime >= config.speakGap else { return out }
        // Kamera hareket edip durduysa (gidiş belli) aynı öneri tekrar aralığını beklemeden söylenir
        let moved = a.isCorrection && vTrend.peek(at: time, config: config) != .steady
        if a != vLastSpoken || time - vLastSpokenTime >= config.repeatGap || moved {
            let trend = a.isCorrection ? vTrend.take(at: time, config: config) : .steady
            if trend != .steady || a != vLastSpoken { vRepeats = 0 } else { vRepeats += 1 }
            if vRepeats >= config.maxRepeats {
                vMuted = a   // yeter: değişene kadar susar
            } else {
                var text = phrase(for: a, again: vRepeats > 0, trend: trend, stuck: vRepeats >= 2)
                if let sc = lastScene, sc != vToldScene {
                    text = sc + " " + text
                    vToldScene = sc
                }
                out.speak = text
            }
            vLastSpoken = a
            vLastSpokenTime = time
        }
        return out
    }

    /// Gidişin izlenmesi için düzeltmeden kalan miktar: kaydırmada kadraj oranı, yaklaşmada gereken büyütme − 1; ölçülemiyorsa nil
    private func trendNeed(_ d: GuidanceDecision, _ a: GuidanceAdvice) -> Double? {
        if a.isMove { return d.shift }
        if a == .closer { return d.scale - 1 }
        return nil
    }

    func step(_ metrics: PageMetrics, time: TimeInterval, stillFor: TimeInterval, diffToCapture: Double) -> Output {
        if !armed {
            if diffToCapture > config.changeToRearm && stillFor >= config.stillNeeded {
                armed = true
                let keep = lastCaptured
                clearSpeech()
                lastCaptured = keep
                lastColumns = 0
            } else {
                return Output(status: "Sayfayı çevirin ya da diğer bölüme geçin")
            }
        }
        if stillFor < config.stillNeeded {
            consecutive = 0
            last = nil
            return Output(status: choice == nil ? "Kamera hareket ediyor…" : "\(choice?.title ?? "") — kamera hareket ediyor…",
                          awaitingChoice: awaitingChoice, options: lastOptions)
        }

        let d = GuidanceAdvisor.decide(metrics, choice: forcedChoice ?? choice, config: config, sharpFloor: sharpFloor,
                                       skipping: lastCaptured)
        lastPick = d.picked
        lastColumns = metrics.columns.count
        lastFill = d.fill
        lastScale = d.scale
        lastShift = d.shift
        lastAlso = d.also
        lastAlsoShift = d.alsoShift
        lastScene = describeScene && d.advice != .noText
            ? GuidanceScene.describe(GuidanceScene.parts(metrics, config: config), edges: GuidanceScene.usableEdges(metrics)) : nil
        var a = d.advice
        // Parlama her zaman giderilemez: birkaç kez uyardıktan sonra yine de çekilir
        if a == .glare && glareSpoken >= config.glareWarnings { a = .ok }
        trendTracker.observe(a, need: trendNeed(d, a), time: time, config: config)
        if a == last {
            consecutive += 1
        } else {
            last = a
            consecutive = 1
            if a != muted { muted = nil }
        }
        awaitingChoice = (a == .chooseColumn)
        if awaitingChoice { lastOptions = d.options }
        var out = Output(advice: a, status: statusText(for: a), awaitingChoice: awaitingChoice, options: d.options)

        if a == .chooseColumn {
            guard consecutive >= 2 else { return out }
            if questionsAsked < config.maxQuestions && time - lastQuestionTime >= (questionsAsked == 0 ? 0 : config.questionGap) {
                out.speak = questionText(options: d.options, first: questionsAsked == 0)
                toldScene = lastScene
                questionsAsked += 1
                lastQuestionTime = time
            } else if questionsAsked == config.maxQuestions && time - lastQuestionTime >= config.questionGap {
                out.speak = "Sesli yanıt alamadım. “Sol” ya da “sağ” deyin, ya da ekrandaki düğmeye dokunun."
                questionsAsked += 1
                lastQuestionTime = time
            }
            return out
        }

        if a == .ok {
            // Bir düzeltme söylenmişti ve konum şimdi gerçekten uygun: kullanıcı hemen öğrenir ve kımıldamaz.
            // Tarif açıksa ve bu sayfa için henüz söylenmediyse, düzeltme gerekmese de kadrajda ne olduğu bir kez söylenir.
            if d.advice == .ok && consecutive == 1 {
                let hold = autoCapture ? "" : " " + capitalised("\(triggerWord) deyin.")
                if let pick = d.picked, pick != toldPick {
                    // Soru sorulmadı: tam sığan bölüm seçildi, hangisinin çekildiği söylenir
                    out.speak = (lastSpoken != nil ? "Tamam. " : "") + pickAnnouncement(pick)
                    toldPick = pick
                } else if lastSpoken != nil {
                    if let sc = lastScene, describeScene {
                        out.speak = "Tamam. " + sc + hold
                    } else {
                        out.speak = autoCapture ? "Tamam, sabit tutun." : "Tamam, \(triggerWord) deyin."
                    }
                } else if describeScene, let sc = lastScene, sc != toldScene {
                    out.speak = sc + hold
                }
                if out.speak != nil {
                    toldScene = lastScene
                    lastSpoken = nil
                    repeats = 0
                    muted = nil
                    lastSpokenTime = time
                }
            }
            if consecutive >= config.stableEvaluations && autoCapture {
                out.capture = true
                armed = false
                consecutive = 0
                last = nil
                capturedBefore = lastCaptured
                lastCaptured = (metrics.columns.count >= 2) ? (choice ?? d.picked) : nil
                choice = nil
            }
            return out
        }

        guard consecutive >= 2, time - lastSpokenTime >= config.speakGap, a != muted else { return out }
        // Kamera hareket edip durduysa (gidiş belli) aynı öneri tekrar aralığını beklemeden söylenir
        let moved = a.isCorrection && trendTracker.peek(at: time, config: config) != .steady
        if a != lastSpoken || time - lastSpokenTime >= config.repeatGap || moved {
            let trend = a.isCorrection ? trendTracker.take(at: time, config: config) : .steady
            if trend != .steady || a != lastSpoken { repeats = 0 } else { repeats += 1 }
            if repeats >= config.maxRepeats {
                out.speak = "Hâlâ uygun değil. \(triggerWord) diyerek yine de çekebilirsiniz."
                muted = a
            } else {
                var text = phrase(for: a, again: repeats > 0, trend: trend, stuck: repeats >= 2)
                if let sc = lastScene, sc != toldScene {
                    text = sc + " " + text
                    toldScene = sc
                }
                out.speak = text
                if a == .blurry { blurSpeaks += 1 }
                if a == .glare { glareSpoken += 1 }
            }
            lastSpoken = a
            lastSpokenTime = time
        }
        return out
    }
}
