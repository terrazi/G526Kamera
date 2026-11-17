import Foundation
import CoreVideo
import Vision

/// Toplu çekimde kare seçimi (kullanıcı kararı 2026-11-17). Kameranın verdiği HER kare ölçülür; 0,5 sn'lik pencerelerin en net karesi yazı tanımadan
/// (Vision) geçirilir. Yazı tanıma YALNIZ SIRALAMA YARDIMCISIDIR, hiçbir kareyi veto etmez (telefonun hızlı yazı tanıması küçük, eğik yazıda
/// başarısız olabilir; Gemini aynı kareyi çok daha iyi okur): okunan kareler öne geçer, aynı görünümün tekrarları elenir, okunan kare azsa en net
/// kareler tamamlayıcı olarak eklenir. Çekim hiçbir zaman "okunamadı" diye çöpe gitmez. Mantığın çoğu saf yapılardadır (birim testle denenir);
/// Vision ve görüntü işleme `SeriesCollector`'a dışarıdan verilir.
enum SeriesSelection {
    /// Pencere uzunluğu (sn): her pencerenin en net karesi aday olur
    static let window: TimeInterval = 0.5
    /// Adayın okunur sayılması için en az harf + rakam sayısı (güveni yeterli satırlardan)
    static let minChars = 25
    /// Gemini'ye giden en az sayfa sayısı: okunan kare bundan azsa en net (okunamayan) karelerle tamamlanır. Yazı tanıma zayıf kaldığında bile
    /// Gemini'nin göreceği kare olur; çekim hiçbir zaman boş gitmez
    static let minPages = 16
    /// İki ardışık adayın kelime örtüşmesi (Jaccard) bu orana ulaşırsa aynı görünüm sayılır
    static let sameWords = 0.75
    /// Yazısı okunamayan iki adayın imza farkı bunun altındaysa aynı görünüm sayılır (yedek ölçüt)
    static let sameSignature = 2.5
    /// Bir kare, ötekinde olmayan en az bu kadar kelime gösteriyorsa "yeni içerik" taşır (OKR gürültüsü birkaç kelimeyi oynatır)
    static let newWords = 8
    /// Kamera bu kadar sn durgun kaldıktan sonra gelen kare "durgun an" karesidir: hareket bulanıklığı yoktur, kodlayıcı görüntüyü tazelemiştir
    /// (kullanıcı kararı 2026-11-17: durgun anlara öncelik). Pencerede durgun kare varsa, hareketliler ne kadar net ölçülürse ölçülsün, o kazanır
    static let minStill: TimeInterval = 0.3
    /// Havuzda en çok bu kadar kare tutulur (bellek ve PDF boyutu)
    static let maxFrames = 60
    /// Son elemede en iyi puanın bu oranının altındakiler atılır
    static let relativeFloor = 0.15
    /// Aynı anda en çok bu kadar pencere işlenir; yazı tanıma yetişemezse pencere atlanır (ısınmayı sınırlar)
    static let maxPending = 2
}

/// Bir karedeki yazının ölçüsü (Vision yazı tanıma çıktısından)
struct TextScore: Equatable {
    /// Güveni yeterli satırlardaki harf ve rakam sayısı
    var chars = 0
    /// Görülen şık harfleri (A–E; "A)" biçiminde)
    var options: Set<Character> = []
    /// Görülen soru numaraları ("12." ya da "12)" biçiminde)
    var questionNumbers: Set<Int> = []
    /// Kullanılan satırların ortalama güveni (0–1)
    var confidence = 0.0
    /// Üç harften uzun küçük harfli kelimeler (aynı görünüm denetimi için)
    var words: Set<String> = []

    static let minConfidence: Float = 0.3

    /// Karenin değeri: okunan yazı + şıklar ve soru numaraları (soru ile şıkların birlikte görünmesi en çok puan alır)
    var value: Double {
        let base = Double(chars) * (0.5 + 0.5 * confidence)
        return base + 80 * Double(options.count) + 40 * Double(min(questionNumbers.count, 3))
    }

    var isReadable: Bool { return chars >= SeriesSelection.minChars }

    /// Günlük için kısa özet: "180 harf %92, şıklar ABCDE, soru 7"
    var summary: String {
        let letters = String(options.sorted())
        let numbers = questionNumbers.sorted().map { String($0) }.joined(separator: ",")
        return "\(chars) harf %\(Int((confidence * 100).rounded()))" + (letters.isEmpty ? "" : ", şıklar \(letters)") + (numbers.isEmpty ? "" : ", soru \(numbers)")
    }

    private static let optionPattern = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9])([A-E])\\s?\\)", options: [])
    private static let numberPattern = try? NSRegularExpression(pattern: "(?:^|\\s)(\\d{1,2})\\s?[\\.\\)](?=\\s*[A-Za-z])", options: [])

    /// Vision satırlarından puan çıkarır (satır metni, güven 0–1). Güveni düşük satırlar sayılmaz.
    static func make(lines: [(text: String, confidence: Float)]) -> TextScore {
        var score = TextScore()
        var confidenceSum = 0.0
        var used = 0
        for line in lines where line.confidence >= minConfidence {
            let text = line.text
            let letters = text.filter { $0.isLetter || $0.isNumber }.count
            if letters == 0 { continue }
            score.chars += letters
            confidenceSum += Double(line.confidence)
            used += 1
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let pattern = optionPattern {
                for match in pattern.matches(in: text, options: [], range: range) where match.numberOfRanges > 1 {
                    if let r = Range(match.range(at: 1), in: text), let ch = text[r].first { score.options.insert(ch) }
                }
            }
            if let pattern = numberPattern {
                for match in pattern.matches(in: text, options: [], range: range) where match.numberOfRanges > 1 {
                    if let r = Range(match.range(at: 1), in: text), let n = Int(text[r]) { score.questionNumbers.insert(n) }
                }
            }
            for word in text.lowercased().split(whereSeparator: { !$0.isLetter }) where word.count >= 3 {
                score.words.insert(String(word))
            }
        }
        score.confidence = used == 0 ? 0 : confidenceSum / Double(used)
        return score
    }

    /// İki kelime kümesinin örtüşmesi (0–1); biri boşsa 0
    static func overlap(_ a: Set<String>, _ b: Set<String>) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }
}

/// Vision ile bir karedeki yazıyı okur. Hata verirse (ör. simülatörde model yok) nil döner; seçici o zaman yalnız netliğe bakar.
enum SeriesTextReader {
    static func read(_ pixelBuffer: CVPixelBuffer, orientation: ImageOrientation) -> TextScore? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.012
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation.cgOrientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        var lines: [(text: String, confidence: Float)] = []
        for case let observation as VNRecognizedTextObservation in (request.results ?? []) {
            if let top = observation.topCandidates(1).first {
                lines.append((text: top.string, confidence: top.confidence))
            }
        }
        return TextScore.make(lines: lines)
    }
}

/// Zaman pencerelerinin en netini seçer (saf mantık). Pencere `start` anından başlar, `length` sn uzunluğundadır.
struct WindowBest<Payload> {
    let start: TimeInterval
    let length: TimeInterval
    private var index = -1
    private var best: (sharpness: Double, payload: Payload)?

    init(start: TimeInterval, length: TimeInterval) {
        self.start = start
        self.length = length
    }

    /// Kareyi verir. Kare yeni bir pencereye düştüyse ÖNCEKİ pencerenin kazananı döner. Başlangıçtan önceki ve geç gelen (eski pencereye ait) kareler yok sayılır.
    mutating func offer(time: TimeInterval, sharpness: Double, payload: Payload) -> Payload? {
        guard time >= start, length > 0 else { return nil }
        let i = Int((time - start) / length)
        if i < index { return nil }
        var finished: Payload?
        if i > index {
            finished = best?.payload
            best = nil
            index = i
        }
        if let current = best {
            if sharpness > current.sharpness { best = (sharpness, payload) }
        } else {
            best = (sharpness, payload)
        }
        return finished
    }

    /// Açık pencerenin kazananını verir ve pencereyi kapatır
    mutating func flush() -> Payload? {
        let payload = best?.payload
        best = nil
        return payload
    }
}

/// PDF'e girecek bir aday kare
struct SeriesItem {
    var time: TimeInterval
    var jpeg: Data
    var width: Int
    var height: Int
    var sharpness: Double
    /// nil: yazı tanıma çalışmadı
    var text: TextScore?
    var signature: [UInt8]
    /// Bozuk (bloklaşmış / önceki sahneyle karışmış) kare: yazısı okunsa bile "yararlı" sayılmaz, yalnız sağlam kare yetmezse tamamlayıcı olarak gider
    var damaged = false

    /// Karede soru görünüyor mu: yazı okunabilir (yeterli harf) ya da bir şık harfi / soru numarası görülmüş. Okunan kareler her zaman alınır;
    /// öteki (zayıf) kareler yalnız okunan kare azsa en nete göre tamamlanır. Bozuk kare hiçbir zaman yararlı sayılmaz (karışık yazı Gemini'yi yanıltır).
    var isUseful: Bool {
        guard !damaged, let text = text else { return false }
        return text.isReadable || !text.options.isEmpty || !text.questionNumbers.isEmpty
    }

    /// Sıralama puanı: yararlı karede yazının değeri (netlik küçük katkı); zayıf karede netlik + okunan harf (yazı tanıma bir şey görmüşse kâğıt vardır)
    var quality: Double {
        if isUseful, let text = text { return text.value + min(sharpness, 400) * 0.1 }
        return min(sharpness, 400) + 10 * Double(text?.chars ?? 0)
    }

    /// Karşılaştırma puanı: yararlı kare, ne kadar net olursa olsun zayıf kareden önce gelir (birleştirme ve havuz tavanında)
    var rank: Double { return (isUseful ? 1_000_000 : 0) + quality }
}

/// Adayları tutar: ardışık aynı görünümlerde en iyisini bırakır, tavanı aşınca en düşük puanlıyı atar (saf mantık)
struct SeriesPool {
    private(set) var items: [SeriesItem] = []
    /// Aynı görünüm diye birleştirilen aday sayısı
    private(set) var merged = 0
    var capacity = SeriesSelection.maxFrames

    /// Aynı görünüm: ikisinin de yazısı okunduysa kelime örtüşmesi; değilse kare imzalarının farkı. (İmza tek başına yetmez: iki farklı yazılı sayfa
    /// 32×18 ızgarada birbirine çok benzer; yazı bulunduğunda kelimelere bakılır.)
    static func sameView(_ a: SeriesItem, _ b: SeriesItem) -> Bool {
        if let ta = a.text, let tb = b.text, !ta.words.isEmpty, !tb.words.isEmpty {
            return TextScore.overlap(ta.words, tb.words) >= SeriesSelection.sameWords
        }
        return FrameAnalysis.difference(a.signature, b.signature) < SeriesSelection.sameSignature
    }

    /// `a`, `b`'nin gösterdiği her şeyi gösteriyor mu: `b`'de görülen şık harflerinin ve soru numaralarının hepsi `a`'da da var ve `b`'nin `a`'da olmayan
    /// kelime sayısı az. Kamera yavaş kayarken ardışık kareler çok benzer olur ama sonrakinde yeni bir şık (ör. E) belirmiş olabilir; böyle bir kare
    /// "tekrar" diye atılmaz (bölünmüş soruyu birleştirebilmek için). Yazısı okunmamış karelerde denetim yapılmaz (true).
    static func covers(_ a: SeriesItem, _ b: SeriesItem) -> Bool {
        guard let ta = a.text, let tb = b.text else { return true }
        return ta.options.isSuperset(of: tb.options)
            && ta.questionNumbers.isSuperset(of: tb.questionNumbers)
            && tb.words.subtracting(ta.words).count < SeriesSelection.newWords
    }

    mutating func add(_ item: SeriesItem) {
        if let last = items.last, SeriesPool.sameView(last, item) {
            if item.damaged != last.damaged {
                // Aynı görünümün bozuk ve sağlam hâli: sağlam olan kalır (bozuk karenin "ötekinde olmayan kelimeleri" karışık yazıdan gelir)
                merged += 1
                if last.damaged { items[items.count - 1] = item }
                return
            }
            let keptCovers = SeriesPool.covers(last, item)
            let newCovers = SeriesPool.covers(item, last)
            if keptCovers && newCovers {
                // Aynı içerik: en iyisi kalır
                merged += 1
                if item.rank > last.rank { items[items.count - 1] = item }
            } else if newCovers {
                // Yeni kare ötekinin gösterdiği her şeyi ve fazlasını gösteriyor: onun yerini alır
                merged += 1
                items[items.count - 1] = item
            } else if keptCovers {
                // Yeni karede yeni bir şey yok
                merged += 1
            } else {
                // İkisinin de ötekinde olmayan içeriği var (kamera kaydı): ikisi de kalır
                items.append(item)
            }
        } else {
            items.append(item)
        }
        while items.count > capacity {
            guard let lowest = items.indices.min(by: { items[$0].rank < items[$1].rank }) else { break }
            items.remove(at: lowest)
        }
    }

    /// Son seçim, zaman sırasıyla: (1) yararlı (okunan) kareler; en iyi puanın `relativeFloor` oranının altındakiler atılır. (2) Bunlar `minPages`'ten
    /// azsa kalan yer, okunamayan (zayıf) karelerin en netleriyle doldurulur: yazı tanıma zayıf kalmış olabilir, Gemini bu kareleri çoğu zaman okur.
    /// Hiç yararlı kare yoksa yalnız zayıf kareler gider. Çekim boş dönmez (kare varsa).
    func selected(minPages: Int = SeriesSelection.minPages) -> [SeriesItem] {
        let useful = items.filter { $0.isUseful }
        var chosen: [SeriesItem] = []
        if let best = useful.map({ $0.quality }).max() {
            chosen = useful.filter { $0.quality >= best * SeriesSelection.relativeFloor }
        }
        let room = minPages - chosen.count
        if room > 0 {
            // Zayıf kareler arasında sağlam olanlar önce gelir; bozuklar yalnız hâlâ yer varsa tamamlar
            let weak = items.filter { !$0.isUseful }.sorted {
                if $0.damaged != $1.damaged { return !$0.damaged }
                return $0.quality > $1.quality
            }
            chosen += weak.prefix(room)
        }
        return chosen.sorted { $0.time < $1.time }
    }
}

/// Çekim boyunca kameranın kareleriyle beslenir (analiz kuyruğundan `offer`), pencerelerin en iyisini arka planda yazı tanımadan geçirip havuza koyar.
/// Yazı tanıma (`reader`) ve JPEG üretimi (`renderer`) dışarıdan verilir: testler sahtesini kullanır.
final class SeriesCollector {
    typealias Reader = (CVPixelBuffer) -> TextScore?
    typealias Renderer = (CVPixelBuffer) -> (data: Data, width: Int, height: Int)?

    struct Frame {
        let buffer: CVPixelBuffer
        let time: TimeInterval
        let sharpness: Double
        let signature: [UInt8]
        /// Blok sınırı ölçüsü (bkz. `FrameAnalysis.blockiness`); 1 civarı sağlam
        var blockiness = 1.0
        var damaged: Bool { return blockiness > FrameAnalysis.damagedBlockiness }
        /// Kamera bu kareden önce kaç sn durgundu (bir önceki kareyle imza farkı `FramePipeline.stillDiff` altında kaldığı süre)
        var stillFor: TimeInterval = 0
        var still: Bool { return stillFor >= SeriesSelection.minStill }
    }

    struct Stats: Equatable {
        /// Analizden geçip toplayıcıya verilen kare
        var offered = 0
        /// Kapanan pencere
        var windows = 0
        /// Yazı tanıma çalıştı / çalışmadı
        var read = 0
        var readFailed = 0
        /// Yazısı okunabilen pencere
        var readable = 0
        /// Yazısı okunamayan (bulanık, küçük, eğik ya da boş) pencere: elenmez, zayıf aday olarak havuza girer
        var weak = 0
        /// Yazı tanıma yetişemediği için atlanan pencere
        var busySkipped = 0
        var renderFailed = 0
        /// Havuza giren aday ve aynı görünüm diye birleşenler
        var kept = 0
        var merged = 0
        /// Bozuk (bloklaşmış) ölçülen kare ve penceredeki en iyi karesi bile bozuk olan pencere
        var damagedFrames = 0
        var damagedWindows = 0
        /// Penceredeki en iyi kare kamera durgunken gelmişse (durgun an) sayılır
        var stillWindows = 0
    }

    struct Outcome {
        var items: [SeriesItem]
        /// Seçilenlerden yazısı okunan (yararlı) kare sayısı; 0 ise Gemini'ye yalnız en net kareler gidiyor
        var readable: Int
        var stats: Stats
        /// Karelerde görülen soru numaraları (günlük için)
        var questionNumbers: [Int]
        /// Çekimin teşhisi: bulanık / çok yakın / yazı yok / numara boşluğu (bkz. `CaptureDiagnosis`)
        var diagnosis: CaptureDiagnosis
    }

    private let lock = NSLock()
    private var windows: WindowBest<Frame>
    private var pool = SeriesPool()
    private var stats = Stats()
    private var pending = 0
    private var finished = false
    private var numbers = Set<Int>()
    /// Durgunluk ölçümü için bir önceki karenin imzası ve kameranın son hareket ettiği an
    private var lastSignature: [UInt8]?
    private var lastMoveTime: TimeInterval = 0
    /// Yazı tanımadan geçen pencere kazananlarının netliği (teşhis için)
    private var sharpnesses: [Double] = []
    private let start: TimeInterval
    private let queue = DispatchQueue(label: "g526.series", qos: .userInitiated)
    private let reader: Reader
    private let renderer: Renderer
    private let log: (String) -> Void
    private let maxPending: Int
    private let minPages: Int

    init(start: TimeInterval, maxPending: Int = SeriesSelection.maxPending, minPages: Int = SeriesSelection.minPages,
         reader: @escaping Reader, renderer: @escaping Renderer, log: @escaping (String) -> Void = { _ in }) {
        self.start = start
        self.maxPending = maxPending
        self.minPages = minPages
        self.windows = WindowBest<Frame>(start: start, length: SeriesSelection.window)
        self.reader = reader
        self.renderer = renderer
        self.log = log
    }

    /// Analiz edilmiş bir kare (analiz kuyruğundan çağrılır; hızlı döner)
    func offer(buffer: CVPixelBuffer, time: TimeInterval, sharpness: Double, signature: [UInt8], blockiness: Double = 1.0) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        stats.offered += 1
        // Durgunluk: önceki kareyle fark eşiği aşınca kamera hareket ediyor sayılır (imza karşılaştırılamazsa da hareketli sayılır)
        if let previous = lastSignature, FrameAnalysis.difference(previous, signature) <= FramePipeline.stillDiff {
            // durgun: son hareket anı değişmez
        } else {
            lastMoveTime = time
        }
        lastSignature = signature
        let frame = Frame(buffer: buffer, time: time, sharpness: sharpness, signature: signature, blockiness: blockiness,
                          stillFor: max(0, time - lastMoveTime))
        if frame.damaged { stats.damagedFrames += 1 }
        // Pencere kazananı: önce sağlam ve durgun an karesi, sonra sağlam hareketli kare, en son bozuk kare; aynı sınıfta en net olan.
        // (Bozuk kare bloklardaki keskin kenarlar yüzünden yapay olarak çok net ölçülür; hareketli kare bulanık olma eğilimindedir.)
        let tier = frame.damaged ? 0.0 : (frame.still ? 2.0 : 1.0)
        let score = tier * 1_000_000 + sharpness
        let closed = windows.offer(time: time, sharpness: score, payload: frame)
        lock.unlock()
        if let closed = closed { submit(closed) }
    }

    private func submit(_ frame: Frame) {
        lock.lock()
        stats.windows += 1
        if pending >= maxPending {
            stats.busySkipped += 1
            lock.unlock()
            log("[seri] \(stamp(frame.time)): yazı tanıma yetişemedi, pencere atlandı")
            return
        }
        pending += 1
        lock.unlock()
        queue.async { [weak self] in
            self?.process(frame)
        }
    }

    private func stamp(_ time: TimeInterval) -> String {
        return String(format: "%.1f sn", max(0, time - start))
    }

    /// Pencerenin kazananı okunur ve havuza girer. Yazı okunamasa da (ya da yazı tanıma hiç çalışmasa da) kare ATILMAZ: zayıf aday olarak tutulur,
    /// kesin eleme çekim bitince `SeriesPool.selected` içinde yapılır (okunan kare azsa en net zayıf kareler Gemini'ye yine gider)
    private func process(_ frame: Frame) {
        let text = reader(frame.buffer)
        let damaged = frame.damaged
        lock.lock()
        if damaged { stats.damagedWindows += 1 }
        if frame.still && !damaged { stats.stillWindows += 1 }
        if let text = text {
            stats.read += 1
            // Bozuk karenin netliği ve soru numaraları (karışık yazı) teşhise ve numara listesine katılmaz
            if !damaged { sharpnesses.append(frame.sharpness) }
            if text.isReadable && !damaged { stats.readable += 1 } else { stats.weak += 1 }
        } else {
            stats.readFailed += 1
            stats.weak += 1
        }
        lock.unlock()
        let sharp = Int(frame.sharpness.rounded())
        guard let rendered = renderer(frame.buffer) else {
            lock.lock()
            stats.renderFailed += 1
            lock.unlock()
            log("[seri] \(stamp(frame.time)): fotoğraf oluşturulamadı")
            finishOne()
            return
        }
        let item = SeriesItem(time: frame.time, jpeg: rendered.data, width: rendered.width, height: rendered.height,
                              sharpness: frame.sharpness, text: text, signature: frame.signature, damaged: damaged)
        lock.lock()
        let mergedBefore = pool.merged
        pool.add(item)
        stats.kept += 1
        if let text = text, !damaged { numbers.formUnion(text.questionNumbers) }
        let wasMerged = pool.merged > mergedBefore
        lock.unlock()
        let verdict = damaged ? "BOZUK kare (bloklaşmış), yalnız sağlam kare yetmezse alınır" : (item.isUseful ? "alındı" : "zayıf aday (okunamadı)")
        log("[seri] \(stamp(frame.time)): \(wasMerged ? "aynı görünüm, en iyisi kaldı" : verdict) (net \(sharp), blok \(String(format: "%.2f", frame.blockiness)), durgun \(String(format: "%.1f", frame.stillFor)) sn, \(text.map { $0.summary } ?? "yazı tanıma yok"))")
        finishOne()
    }

    private func finishOne() {
        lock.lock()
        pending -= 1
        lock.unlock()
    }

    /// Çekim bitti: yeni kareler yok sayılır, açık pencerenin kazananı döner (kilit asenkron bağlamın dışında alınır)
    private func closeWindows() -> Frame? {
        lock.lock()
        defer { lock.unlock() }
        finished = true
        return windows.flush()
    }

    private func snapshot() -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        var result = stats
        result.merged = pool.merged
        let chosen = pool.selected(minPages: minPages)
        let seen = numbers.sorted()
        // Yazı tanıma hiç çalışmadıysa (read == 0) teşhis konmaz: pencere sayısı 0 kalır
        let diagnosis = CaptureDiagnosis(windows: result.read, readableWindows: result.readable,
                                         medianSharpness: CaptureDiagnosis.median(sharpnesses), questionNumbers: seen,
                                         damagedWindows: result.damagedWindows)
        return Outcome(items: chosen, readable: chosen.filter { $0.isUseful }.count, stats: result, questionNumbers: seen, diagnosis: diagnosis)
    }

    /// Açık pencereyi kapatır, bekleyen işlerin bitmesini bekler ve sonucu verir. Bundan sonra gelen kareler yok sayılır.
    func finish() async -> Outcome {
        if let last = closeWindows() { submit(last) }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
        return snapshot()
    }
}
