import Foundation
import CoreGraphics
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
    /// Kamera oynamadan alınmış aynı görünüm: imza farkı bunun altında ve kelimelerin en az `stillWords` oranı ortak (küçük kümeye göre). Gerçek günlük
    /// 2026-11-18: hızlı yazı tanıma aynı sayfayı her karede başka bozuyor (Jaccard %40'a düşüyor), bu yüzden 60 sayfalık PDF'in 39'u aynı görünümdü
    static let stillSignature = 3.0
    static let stillWords = 0.45
    /// Yeni aday, havuzun son bu kadar adayıyla karşılaştırılır (yalnız sonuncuyla değil)
    static let lookback = 3
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

    // Temiz an ve tekrar azaltma (kullanıcı kararı 2026-11-19: "tüm tekrarları atmak yerine azaltabiliriz")

    /// Blok ölçüsü bunun altındaysa kare temizdir. Gerçek günlük 2026-11-19 (477 kare): blok 1,00–1,05 arası karelerin ortanca netliği 3111,
    /// 1,15–1,22 arası (bozuk eşiğinin hemen altı) karelerin 173: kamera oynarken kodlayıcı görüntüyü bloklaştırıyor ve yazı dağılıyor
    static let cleanBlockiness = 1.05
    /// Temiz eşiğinin üstündeki her 0,1 blok, karenin puanını bu kadar kat böler (1,15'te ikiye, 1,22'de ≈2,7'ye)
    static let blockPenalty = 10.0
    /// Blok ölçüsü bunun üstündeki kare "kirli"dir (yarı bozuk): içeriği komşu temiz karelerde zaten varsa gönderilmez
    static let dirtyBlockiness = 1.15
    /// Kirli karenin komşuları en çok bu kadar sn uzakta aranır
    static let neighborSeconds: TimeInterval = 2.0
    /// Kirli karenin sözcüklerinin en çok bu oranı komşularda yoksa kare "komşularında var" sayılır (yazı tanıma gürültüsü payı)
    static let coveredShare = 0.10
    /// Tekrar: iki karenin sözcük örtüşmesi (Jaccard) en az bu kadar, gösterdikleri şık harfleri ve soru numaraları aynı
    static let repeatWords = 0.85
    /// Tekrar ve kirli kare denetimi için karede en az bu kadar sözcük okunmuş olmalı (az yazılı karede hüküm verilmez, kare kalır)
    static let minRepeatWords = 20
    /// Art arda gelen aynı içerikli karelerden en iyi bu kadarı kalır (hepsi atılmaz: bir kare bozuk çıkarsa öteki yedektir)
    static let repeatKeep = 2

    /// Blok bozulmasına göre puan böleni (temiz karede 1)
    static func blockFactor(_ blockiness: Double) -> Double {
        return 1 + blockPenalty * max(0, blockiness - cleanBlockiness)
    }

    /// Pencere / dilim kazananı için netlik puanı: aynı netlikte daha az bloklaşmış kare öne geçer
    static func cleanScore(sharpness: Double, blockiness: Double) -> Double {
        return sharpness / blockFactor(blockiness)
    }
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
    /// Okunan yazıdaki sık kullanılan işlev sözcüklerinin ("the", "of", "bir", "için") sayısı: yazı baş aşağı okunduğunda harf sayısı yüksek kalabilir ama
    /// anlamlı sözcük çıkmaz (bkz. `TextSense`, `OrientationFinder`)
    var sense = 0
    /// Karedeki soru parçaları (numara, kök, şıklar; bkz. `QuestionSpotter.pieces`): yalnız güçlü yazı okumada doldurulur, taramanın sonunda hangi sorunun
    /// tam görülmediği bunlardan çıkarılır (bkz. `QuestionCoverage`)
    var pieces: [QuestionPiece] = []
    /// Soru parçaları çıkarıldı mı (güçlü okuma): çıkarıldıysa "karede görülen sorular" sıkı kuralla sayılır (bkz. `shownNumbers`)
    var piecesRead = false

    /// Karede görülen soru numaraları. Güçlü okumada yalnız sıkı kuralla görülenler (satır başında numara + kök + altında en az iki şık): metnin
    /// içindeki "7. yüzyıl", "43-46" gibi sayılar soru sayılmaz (kullanıcı 2026-11-19: koç taranmayan soruları söylüyordu). Hızlı okumada parça
    /// çıkarılmaz; eski gevşek kural kullanılır.
    var shownNumbers: Set<Int> {
        if !piecesRead { return questionNumbers }
        var result = Set<Int>()
        for piece in pieces where piece.isStrict {
            if let number = piece.number { result.insert(number) }
        }
        return result
    }

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
        let parts = pieces.filter { $0.isStrict || $0.number == nil }.map { $0.summary }.joined(separator: " ")
        let base = "\(chars) harf %\(Int((confidence * 100).rounded()))" + (letters.isEmpty ? "" : ", şıklar \(letters)") + (numbers.isEmpty ? "" : ", soru \(numbers)")
        return parts.isEmpty ? base : base + ", parça \(parts)"
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
            score.sense += TextSense.count(text)
        }
        score.confidence = used == 0 ? 0 : confidenceSum / Double(used)
        return score
    }

    /// Küçük kümenin ne kadarının ötekinde de bulunduğu (0–1); biri boşsa 0
    static func containment(_ a: Set<String>, _ b: Set<String>) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        return Double(a.intersection(b).count) / Double(min(a.count, b.count))
    }

    /// İki kelime kümesinin örtüşmesi (0–1); biri boşsa 0
    static func overlap(_ a: Set<String>, _ b: Set<String>) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }
}

/// Bir sayfalık taramanın karelerinin dökümü (bkz. `SeriesCollector.quality`): geçerli / bozuk / bulanık kare sayısı ve geçerli karelerde okunan soru
/// numaralarının kaç karede görüldüğü
struct PageQuality: Equatable {
    var valid = 0
    var damaged = 0
    var blurry = 0
    /// Geçerli karelerden yarı bozuk (belirgin bloklaşmış) olanlar (bkz. `SeriesSelection.dirtyBlockiness`)
    var dirty = 0
    var numbers: [Int: Int] = [:]
}

/// Vision ile bir karedeki yazıyı okur. Hata verirse (ör. simülatörde model yok) nil döner; seçici o zaman yalnız netliğe bakar.
enum SeriesTextReader {
    /// `accurate`: Vision'ın güçlü (yavaş) kipi; soru numaraları ve küçük yazı daha doğru okunur (bkz. `ReadPace`)
    static func read(_ pixelBuffer: CVPixelBuffer, orientation: ImageOrientation, accurate: Bool = false) -> TextScore? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accurate ? .accurate : .fast
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.012
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation.cgOrientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        var lines: [(text: String, confidence: Float)] = []
        var boxed: [(text: String, box: CGRect)] = []
        for case let observation as VNRecognizedTextObservation in (request.results ?? []) {
            if let top = observation.topCandidates(1).first {
                lines.append((text: top.string, confidence: top.confidence))
                if top.confidence >= TextScore.minConfidence { boxed.append((text: top.string, box: observation.boundingBox)) }
            }
        }
        var score = TextScore.make(lines: lines)
        // Soru bütünlüğü yalnız güçlü okumada çıkarılır: hızlı kip numaraları ve şık harflerini sık kaçırır, "şık görülmedi" hükmü yanlış çıkar
        if accurate {
            score.pieces = QuestionSpotter.pieces(boxed)
            score.piecesRead = true
        }
        return score
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

/// Ritim modunda dilimin en iyisini seçer (saf mantık): kare, ait olduğu dilimin numarasıyla verilir; dilim değişince ÖNCEKİ dilimin kazananı döner
struct SlotBest<Payload> {
    private var index = -1
    private var best: (score: Double, payload: Payload)?

    /// Geç gelen (eski dilime ait) kareler yok sayılır
    mutating func offer(slot: Int, score: Double, payload: Payload) -> Payload? {
        if slot < index { return nil }
        var finished: Payload?
        if slot > index {
            finished = best?.payload
            best = nil
            index = slot
        }
        if let current = best {
            if score > current.score { best = (score, payload) }
        } else {
            best = (score, payload)
        }
        return finished
    }

    /// Açık dilimin kazananını verir ve dilimi kapatır
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
    /// Ritim modunda karenin dilim numarası (bkz. `SeriesRhythm.slotIndex`); klasik seçimde nil
    var slot: Int?
    /// Ritimde dilimin kaçıncı karesi (0 ya da 1)
    var sub = 0
    /// Ritimde bulanık ya da soru içermeyen (geçersiz) bulunan kare; bozuk kare `damaged` ile ayrı tutulur. Dilimde geçerli kare varsa bunlar gitmez
    var problem: SlotProblem?
    /// Blok ölçüsü (bkz. `FrameAnalysis.blockiness`); 1 civarı temiz
    var blockiness = 1.0

    /// Yarı bozuk kare: bozuk eşiğini aşmamış ama belirgin biçimde bloklaşmış (bkz. `SeriesSelection.dirtyBlockiness`)
    var isDirty: Bool { return !damaged && blockiness >= SeriesSelection.dirtyBlockiness }

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

    /// Tekrarlardan hangisinin kalacağına bakılırken kullanılan puan: aynı değerde daha az bloklaşmış kare öne geçer
    var cleanRank: Double { return (isUseful ? 1_000_000 : 0) + quality / SeriesSelection.blockFactor(blockiness) }
}

/// Adayları tutar: ardışık aynı görünümlerde en iyisini bırakır, tavanı aşınca en düşük puanlıyı atar (saf mantık)
struct SeriesPool {
    private(set) var items: [SeriesItem] = []
    /// Aynı görünüm diye birleştirilen aday sayısı
    private(set) var merged = 0
    var capacity = SeriesSelection.maxFrames
    /// Ritim modu: her dilimin kazananı kalır, hiçbiri "aynı görünüm" diye birleşmez ya da elenmez (dört parça kasten birbirini örter)
    var keepAll = false
    /// Serbest taramada son seçimde kirli ve tekrar kareler azaltılır (bkz. `thinned`); Ayarlar'dan kapatılabilir
    var thinFrames = true

    /// Azaltmada atılan kare sayıları (günlük için)
    struct ThinReport: Equatable {
        /// İçeriği komşu temiz karelerde bulunan kirli (yarı bozuk) kareler
        var dirty = 0
        /// Art arda gelen aynı içerikten fazla olanlar
        var repeats = 0
    }

    /// Tekrar: ikisinin de yazısı yeterince okunmuş, gösterdikleri şık harfleri ve soru numaraları aynı, sözcükleri büyük oranda ortak
    static func isRepeat(_ a: SeriesItem, _ b: SeriesItem) -> Bool {
        guard let ta = a.text, let tb = b.text else { return false }
        if ta.words.count < SeriesSelection.minRepeatWords || tb.words.count < SeriesSelection.minRepeatWords { return false }
        if ta.options != tb.options || ta.questionNumbers != tb.questionNumbers { return false }
        return TextScore.overlap(ta.words, tb.words) >= SeriesSelection.repeatWords
    }

    /// `list[index]` karesinin gösterdiği her şey, önceki ve sonraki en yakın temiz (kirli olmayan) karelerde zaten var mı: şık harfleri ve soru
    /// numaralarının hepsi, sözcüklerinin de neredeyse tamamı. Yazısı az okunmuş karede ya da yakında temiz kare yoksa false (kare kalır)
    static func coveredByNeighbors(_ list: [SeriesItem], _ index: Int) -> Bool {
        let item = list[index]
        guard let text = item.text, text.words.count >= SeriesSelection.minRepeatWords else { return false }
        var words = Set<String>()
        var options = Set<Character>()
        var numbers = Set<Int>()
        var found = 0
        var before = index - 1
        while before >= 0 && item.time - list[before].time <= SeriesSelection.neighborSeconds {
            if !list[before].isDirty, let other = list[before].text {
                words.formUnion(other.words)
                options.formUnion(other.options)
                numbers.formUnion(other.questionNumbers)
                found += 1
                break
            }
            before -= 1
        }
        var after = index + 1
        while after < list.count && list[after].time - item.time <= SeriesSelection.neighborSeconds {
            if !list[after].isDirty, let other = list[after].text {
                words.formUnion(other.words)
                options.formUnion(other.options)
                numbers.formUnion(other.questionNumbers)
                found += 1
                break
            }
            after += 1
        }
        if found == 0 { return false }
        if !options.isSuperset(of: text.options) || !numbers.isSuperset(of: text.questionNumbers) { return false }
        let extra = text.words.subtracting(words).count
        return Double(extra) <= SeriesSelection.coveredShare * Double(text.words.count)
    }

    /// Serbest taramanın son seçimini azaltır (kareler zaman sırasıyla verilir, zaman sırasıyla döner). SINIRLI bir ayıklamadır:
    /// (1) kirli (yarı bozuk) kare yalnız içeriği komşu temiz karelerde zaten varsa atılır; (2) art arda gelen aynı içerikli karelerden en iyi
    /// `repeatKeep` tanesi kalır. Yazısı okunmamış ya da az okunmuş kareye dokunulmaz; yeni bir şık harfi ya da soru numarası gösteren kare tekrar sayılmaz.
    static func thinned(_ list: [SeriesItem]) -> (kept: [SeriesItem], report: ThinReport) {
        var report = ThinReport()
        var cleaned: [SeriesItem] = []
        for index in list.indices {
            if list[index].isDirty && coveredByNeighbors(list, index) {
                report.dirty += 1
            } else {
                cleaned.append(list[index])
            }
        }
        var kept: [SeriesItem] = []
        var group: [SeriesItem] = []
        for item in cleaned {
            if let anchor = group.first, isRepeat(anchor, item) {
                group.append(item)
            } else {
                kept.append(contentsOf: strongest(group))
                group = [item]
            }
        }
        kept.append(contentsOf: strongest(group))
        report.repeats = cleaned.count - kept.count
        return (kept: kept, report: report)
    }

    /// Aynı içerikli kare grubundan kalacaklar: en iyi `repeatKeep` tanesi, zaman sırasıyla
    static func strongest(_ group: [SeriesItem]) -> [SeriesItem] {
        if group.count <= SeriesSelection.repeatKeep { return group }
        let ranked = group.sorted { $0.cleanRank > $1.cleanRank }
        return Array(ranked.prefix(SeriesSelection.repeatKeep)).sorted { $0.time < $1.time }
    }

    /// Serbest taramada gönderilecek kareler (azaltmadan önce), zaman sırasıyla; `good`: aralarında geçerli kare var (yoksa eldekiler olduğu gibi gider)
    private func freeScanList() -> (list: [SeriesItem], good: Bool) {
        let good = items.filter { !$0.damaged && $0.problem == nil }
        let kept = good.isEmpty ? items : good
        return (list: kept.sorted { $0.time < $1.time }, good: !good.isEmpty)
    }

    /// Serbest taramanın son seçiminde kaç kare azaltıldı (günlük için); azaltma kapalıysa ya da klasik seçimde sıfır
    func thinReport() -> ThinReport {
        guard keepAll, thinFrames else { return ThinReport() }
        let free = freeScanList()
        return free.good ? SeriesPool.thinned(free.list).report : ThinReport()
    }

    /// Aynı görünüm: ikisinin de yazısı okunduysa kelime örtüşmesi; değilse kare imzalarının farkı. (İmza tek başına yetmez: iki farklı yazılı sayfa
    /// 32×18 ızgarada birbirine çok benzer; yazı bulunduğunda kelimelere bakılır.)
    static func sameView(_ a: SeriesItem, _ b: SeriesItem) -> Bool {
        if let ta = a.text, let tb = b.text, !ta.words.isEmpty, !tb.words.isEmpty {
            return TextScore.overlap(ta.words, tb.words) >= SeriesSelection.sameWords || isStillView(a, b)
        }
        return FrameAnalysis.difference(a.signature, b.signature) < SeriesSelection.sameSignature
    }

    /// Kamera oynamadan alınmış aynı görünüm: ikisinin de yazısı okunmuş, imzaları çok yakın ve kelimelerinin yarıya yakını ortak
    static func isStillView(_ a: SeriesItem, _ b: SeriesItem) -> Bool {
        guard let ta = a.text, let tb = b.text, !ta.words.isEmpty, !tb.words.isEmpty else { return false }
        return FrameAnalysis.difference(a.signature, b.signature) < SeriesSelection.stillSignature
            && TextScore.containment(ta.words, tb.words) >= SeriesSelection.stillWords
    }

    /// `a`, `b`'nin gösterdiği şık harflerinin ve soru numaralarının hepsini gösteriyor mu (kelimelere bakılmaz; yazısı okunmamış karede true)
    static func coversMarks(_ a: SeriesItem, _ b: SeriesItem) -> Bool {
        guard let ta = a.text, let tb = b.text else { return true }
        return ta.options.isSuperset(of: tb.options) && ta.questionNumbers.isSuperset(of: tb.questionNumbers)
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
        if keepAll {
            items.append(item)
            return
        }
        // Yalnız sonuncuyla değil, son birkaç adayla karşılaştırılır (A, B, A' sırasında A' birinciyle birleşir)
        let recent = items.indices.suffix(SeriesSelection.lookback)
        if let index = recent.reversed().first(where: { SeriesPool.sameView(items[$0], item) }) {
            let last = items[index]
            if item.damaged != last.damaged {
                // Aynı görünümün bozuk ve sağlam hâli: sağlam olan kalır (bozuk karenin "ötekinde olmayan kelimeleri" karışık yazıdan gelir)
                merged += 1
                if last.damaged { items[index] = item }
                return
            }
            let keptCovers = SeriesPool.covers(last, item)
            let newCovers = SeriesPool.covers(item, last)
            if keptCovers && newCovers {
                // Aynı içerik: en iyisi kalır
                merged += 1
                if item.rank > last.rank { items[index] = item }
            } else if newCovers {
                // Yeni kare ötekinin gösterdiği her şeyi ve fazlasını gösteriyor: onun yerini alır
                merged += 1
                items[index] = item
            } else if keptCovers {
                // Yeni karede yeni bir şey yok
                merged += 1
            } else if SeriesPool.isStillView(last, item), SeriesPool.coversMarks(last, item) {
                // Kamera oynamadan okunan iki kare: yazı tanıma gürültüsü kelimeleri farklı bozmuş ama yeni şık / numara yok: tekrar (en iyisi kalır)
                merged += 1
                if SeriesPool.coversMarks(item, last), item.rank > last.rank { items[index] = item }
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

    /// Aynı görünümün tekrarlarını eler: puanı yüksek olandan başlanır; kamera oynamadan alınmış ve yeni şık / numara göstermeyen kare atılır (ardışık
    /// olmasa da: yazı tanıma gürültüsü kareleri ardışık birleştirmeyi kaçırmış olabilir). Gerçek günlük 2026-11-18: 60 sayfalık PDF 11–15 MB oldu, Gemini zaman aşımına düştü
    static func distinct(_ list: [SeriesItem]) -> [SeriesItem] {
        var kept: [SeriesItem] = []
        for item in list.sorted(by: { $0.rank > $1.rank }) {
            if kept.contains(where: { SeriesPool.isStillView($0, item) && SeriesPool.coversMarks($0, item) }) { continue }
            kept.append(item)
        }
        return kept
    }

    /// Son seçim, zaman sırasıyla: (1) yararlı (okunan) kareler; en iyi puanın `relativeFloor` oranının altındakiler atılır. (2) Bunlar `minPages`'ten
    /// azsa kalan yer, okunamayan (zayıf) karelerin en netleriyle doldurulur: yazı tanıma zayıf kalmış olabilir, Gemini bu kareleri çoğu zaman okur.
    /// Hiç yararlı kare yoksa yalnız zayıf kareler gider. Çekim boş dönmez (kare varsa).
    func selected(minPages: Int = SeriesSelection.minPages) -> [SeriesItem] {
        if keepAll {
            // Serbest tarama (kullanıcı kararı 2026-11-18 akşam): kötü görüntü saklanmaz. Bozuk ve bulanık kareler hiç gönderilmez; yalnız oturumda tek bir
            // geçerli kare bile yoksa (çekim boş dönmesin diye) eldekiler etiketleriyle gider
            // Geçerli kareler arasından kirli ve tekrar olanlar SINIRLI biçimde azaltılır (kullanıcı kararı 2026-11-19; bkz. `thinned`)
            let free = freeScanList()
            return thinFrames && free.good ? SeriesPool.thinned(free.list).kept : free.list
        }
        let useful = items.filter { $0.isUseful }
        var chosen: [SeriesItem] = []
        if let best = useful.map({ $0.quality }).max() {
            chosen = SeriesPool.distinct(useful.filter { $0.quality >= best * SeriesSelection.relativeFloor })
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
    /// Ritim: karedeki satırlardan soru bütünlüğünü okur (bkz. `ViewLinesReader`); nil dönerse ya da verilmezse kare bu yüzden elenmez
    typealias Coverage = (CVPixelBuffer) -> ViewLines?

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
        /// Ritim modunda karenin dilim numarası ve dilimin kaçıncı parçası
        var slot: Int?
        var sub = 0
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
        /// Ritim: geçersiz bulunan kazanan kareler, nedene göre (bozuklar `damagedWindows` içinde)
        var blurryWindows = 0
        var noQuestionWindows = 0
        var noOverlapWindows = 0
        /// Serbest taramanın son seçiminde azaltılan kareler: içeriği komşu temiz karede olan kirli kareler ve fazla tekrarlar (bkz. `SeriesPool.thinned`)
        var thinnedDirty = 0
        var thinnedRepeats = 0
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
        /// Ritim modunda her fotoğrafın etiketi ("2. sayfa, orta üst"), `items` ile aynı sırada; klasik seçimde boş
        var labels: [String] = []
        /// Hangi soru taramada tam görülmedi (bkz. `QuestionCoverage`); güçlü yazı okuma çalışmadıysa boş
        var coverage = QuestionCoverage()
        /// Ardışık karelerin imza farkının çeyrekleri (günlük için): "ölçüm 1180; çeyrekler 0.8 / 1.6 / 3.9; durgun eşiği 2.0 (altında kalan %58)"
        var motionNote = ""
    }

    private let lock = NSLock()
    private var windows: WindowBest<Frame>
    /// Ritim modu: pencereler yerine dilimlerin en iyisi seçilir; saat dilimi kare zamanından bulur ve bozuk kare tekrarını yönetir (bkz. `RhythmClock`)
    private let clock: RhythmClock?
    private var slots = SlotBest<Frame>()
    /// Ritimde dilimlerde görülen sağlam ve bozuk kareler: yalnız bozuk görülen dilim tekrarlanır (`slotNeedsRetry`)
    private var cleanSlots = Set<Int>()
    private var damagedSlots = Set<Int>()
    /// Ritimde değerlendirilen kazananlardan: geçerli kare görülen dilimler ve dilim başına görülen sorunlar (bkz. `slotProblem`)
    private var goodSlots = Set<Int>()
    private var slotProblems: [Int: Set<SlotProblem>] = [:]
    /// Ritim: her parça diliminde okunan sözcükler (bir sonraki parçanın bununla örtüştüğü denetlenir)
    private var slotWords: [Int: Set<String>] = [:]
    /// Son karenin geldiği an (görüntü kesildi mi diye bakılır)
    private var lastOfferTime: TimeInterval?
    /// Ritim: değerlendirilen her kazanan karenin zamanı, hükmü (nil = geçerli) ve karede okunan soru numaraları (sayfa denetimi için)
    private var verdicts: [(time: TimeInterval, problem: SlotProblem?, numbers: Set<Int>, dirty: Bool)] = []
    /// Ardışık karelerin imza farkları (durgunluk eşiğini cihaz günlüğünden ayarlayabilmek için; en çok `maxDiffSamples` ölçüm)
    private var signatureDiffs: [Double] = []
    private static let maxDiffSamples = 4000
    /// Hareket takibi (varsa): kameradan gelen her kare ona da verilir. Çekim başlamadan önce atanır
    var motion: MotionTracker?
    private var pool = SeriesPool()
    private var stats = Stats()
    private var pending = 0
    private var finished = false
    private var numbers = Set<Int>()
    /// Geçerli karelerde görülen soru parçaları, kare kare (çekim bitince soru bütünlüğü bunlardan çıkarılır)
    private var questionPieces: [[QuestionPiece]] = []
    /// Durgunluk ölçümü için bir önceki karenin imzası ve kameranın son hareket ettiği an
    private var lastSignature: [UInt8]?
    private var lastMoveTime: TimeInterval = 0
    /// Yazı tanımadan geçen pencere kazananlarının netliği (teşhis için)
    private var sharpnesses: [Double] = []
    private let start: TimeInterval
    private let queue = DispatchQueue(label: "g526.series", qos: .userInitiated)
    private let reader: Reader
    private let renderer: Renderer
    private let coverage: Coverage?
    private let log: (String) -> Void
    private let maxPending: Int
    private let minPages: Int

    init(start: TimeInterval, maxPending: Int = SeriesSelection.maxPending, minPages: Int = SeriesSelection.minPages, rhythm: SeriesRhythm? = nil, clock: RhythmClock? = nil,
         reader: @escaping Reader, renderer: @escaping Renderer, coverage: Coverage? = nil, thin: Bool = true,
         log: @escaping (String) -> Void = { _ in }) {
        self.start = start
        // Ritimde her dilimin kazananı gerekir: yazı tanıma yetişemese de dilim atlanmaz (dilimler 4 sn arayla kapanır, kuyruk birikmez)
        let clock = clock ?? rhythm.map { RhythmClock(rhythm: $0, pages: 1) }
        self.maxPending = clock == nil ? maxPending : Int.max
        self.clock = clock
        self.minPages = minPages
        self.windows = WindowBest<Frame>(start: start, length: SeriesSelection.window)
        self.reader = reader
        self.renderer = renderer
        self.coverage = coverage
        self.log = log
        pool.keepAll = clock != nil
        pool.thinFrames = thin
    }

    /// Analiz edilmiş bir kare (analiz kuyruğundan çağrılır; hızlı döner)
    func offer(buffer: CVPixelBuffer, time: TimeInterval, sharpness: Double, signature: [UInt8], blockiness: Double = 1.0) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        stats.offered += 1
        lastOfferTime = time
        let tracker = motion
        // Durgunluk: önceki kareyle fark eşiği aşınca kamera hareket ediyor sayılır (imza karşılaştırılamazsa da hareketli sayılır)
        let moved = lastSignature.map { FrameAnalysis.difference($0, signature) }
        if let moved = moved, signatureDiffs.count < SeriesCollector.maxDiffSamples { signatureDiffs.append(moved) }
        if let moved = moved, moved <= FramePipeline.stillDiff {
            // durgun: son hareket anı değişmez
        } else {
            lastMoveTime = time
        }
        lastSignature = signature
        var frame = Frame(buffer: buffer, time: time, sharpness: sharpness, signature: signature, blockiness: blockiness,
                          stillFor: max(0, time - lastMoveTime))
        if frame.damaged { stats.damagedFrames += 1 }
        // Pencere kazananı: önce sağlam ve durgun an karesi, sonra sağlam hareketli kare, en son bozuk kare; aynı sınıfta en net VE en temiz olan.
        // (Bozuk kare bloklardaki keskin kenarlar yüzünden yapay olarak çok net ölçülür; hareketli kare bulanık olma eğilimindedir. Bozuk eşiğinin
        // altında kalan yarı bloklaşmış kare de aynı yüzden olduğundan net ölçülür: netliği blok ölçüsüyle kırpılır, temiz an öne geçer.)
        let tier = frame.damaged ? 0.0 : (frame.still ? 2.0 : 1.0)
        let score = tier * 1_000_000 + SeriesSelection.cleanScore(sharpness: sharpness, blockiness: blockiness)
        var closed: Frame?
        if let clock = clock {
            // Ritim: yalnız bir dilimin yerleşme süresinden sonraki kareleri sayılır (sayfa çevirirken ve yeni yere giderken gelenler atılır)
            if let slot = clock.shotSlot(at: time - start) {
                frame.slot = slot.index
                frame.sub = slot.sub
                if frame.damaged { damagedSlots.insert(slot.index) } else { cleanSlots.insert(slot.index) }
                // Her dilimin her parçasından (yerleşmeden sonraki sürenin yarısı) en net kare. Anahtar zamanla artar: tekrar (saat geri alınır) yeni bir
                // "nesil" başlatır, böylece tekrardaki kareler ilk denemenin açık diliminin gerisinde sayılıp atılmaz
                closed = slots.offer(slot: slot.generation * 100_000 + slot.index * SeriesRhythm.framesPerSlot + slot.sub, score: score, payload: frame)
            }
        } else {
            closed = windows.offer(time: time, sharpness: score, payload: frame)
        }
        lock.unlock()
        tracker?.offer(buffer, time: time)
        if let closed = closed { submit(closed) }
    }

    /// Ritim: dilimde geçerli kare yok mu, nedeni ne? Bozuk kare görüldü ama hiç sağlam kare yoksa hemen bilinir; bulanık ya da soru içermeyen kare ise
    /// kazanan kareler yazı tanımadan geçtikten sonra (bkz. `settle`) bilinir. Hiç kare görülmeyen dilim (kamera durmuş olabilir) sorunlu sayılmaz.
    /// Sorun varsa kullanıcıya "sayfadan ayrılmayın, tekrar gösterin" denir ve dilim tekrarlanır
    func slotProblem(_ index: Int) -> SlotProblem? {
        lock.lock()
        defer { lock.unlock() }
        if damagedSlots.contains(index) && !cleanSlots.contains(index) { return .damaged }
        if goodSlots.contains(index) { return nil }
        // Dilimde sağlam kare görüldüyse bir yarının bozuk kazananı "bozuk" sebebi sayılmaz (sağlam kare henüz değerlendirilmemiş olabilir)
        let seen = (slotProblems[index] ?? []).filter { $0 != .damaged || !cleanSlots.contains(index) }
        return seen.min()
    }

    func slotNeedsRetry(_ index: Int) -> Bool { return slotProblem(index) != nil }

    /// Çekimin `from`–`to` saniyeleri (çekim başından beri, gerçek süre) arasında alınan karelerin dökümü. Önce `settle` çağrılmalıdır
    func quality(from: TimeInterval, to: TimeInterval) -> PageQuality {
        lock.lock()
        defer { lock.unlock() }
        var result = PageQuality()
        for v in verdicts where v.time - start >= from && v.time - start < to {
            switch v.problem {
            case nil:
                result.valid += 1
                if v.dirty { result.dirty += 1 }
                for number in v.numbers { result.numbers[number, default: 0] += 1 }
            case .damaged?: result.damaged += 1
            default: result.blurry += 1
            }
        }
        return result
    }

    /// Son kareden beri geçen süre (sn); hiç kare gelmediyse çekim başından beri
    func secondsSinceFrame(now: TimeInterval) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return max(0, now - (lastOfferTime ?? start))
    }

    /// Ritim: biten dilimin açık kazananını kapatır ve yazı tanıma işlerinin bitmesini bekler; bundan sonra `slotProblem` o dilimin bütün karelerini bilir.
    /// Dilim sonunda bir kez çağrılır (yeni kare o dilime artık gelmez)
    func settle() async {
        lock.lock()
        let open = finished ? nil : slots.flush()
        lock.unlock()
        if let open = open { submit(open) }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
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
        // Ritim: kare geçerli mi? Yalnız dilimde okunan, bozuk olmayan ve durgun kareler için ikinci (satır) okuması yapılır; ötekiler zaten geçersizdir
        var problem: SlotProblem?
        if clock != nil, let slotIndex = frame.slot {
            let part = SeriesRhythm.slot(index: slotIndex)?.part
            var lines: ViewLines?
            let readable = (text?.chars ?? 0) >= SlotCheck.readableChars
            if let part = part, part.isShot, !damaged, frame.still || readable { lines = coverage?(frame.buffer) }
            problem = SlotCheck.problem(damaged: damaged, still: frame.still, part: part, lines: lines, chars: text?.chars)
        }
        lock.lock()
        switch problem {
        case .blurry?: stats.blurryWindows += 1
        case .noQuestion?: stats.noQuestionWindows += 1
        case .noOverlap?: stats.noOverlapWindows += 1
        default: break
        }
        if clock != nil, frame.slot != nil {
            verdicts.append((time: frame.time, problem: problem, numbers: problem == nil ? (text?.shownNumbers ?? []) : [],
                             dirty: !damaged && frame.blockiness >= SeriesSelection.dirtyBlockiness))
        }
        // Soru bütünlüğü yalnız geçerli karelerden çıkarılır (bozuk karenin karışık yazısı parçaları bozar)
        if !damaged, problem == nil, let found = text?.pieces, !found.isEmpty { questionPieces.append(found) }
        if let slotIndex = frame.slot, clock != nil {
            if let problem = problem { slotProblems[slotIndex, default: []].insert(problem) } else { goodSlots.insert(slotIndex) }
        }
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
                              sharpness: frame.sharpness, text: text, signature: frame.signature, damaged: damaged, slot: frame.slot, sub: frame.sub,
                              problem: problem == .damaged ? nil : problem, blockiness: frame.blockiness)
        lock.lock()
        let mergedBefore = pool.merged
        pool.add(item)
        stats.kept += 1
        if let text = text, !damaged { numbers.formUnion(text.shownNumbers) }
        let wasMerged = pool.merged > mergedBefore
        lock.unlock()
        let verdict = damaged ? "BOZUK kare (bloklaşmış), yalnız sağlam kare yetmezse alınır"
            : (problem.map { "GEÇERSİZ kare (\($0.note)), yalnız geçerli kare yetmezse alınır" } ?? (item.isUseful ? "alındı" : "zayıf aday (okunamadı)"))
        let place = frame.slot.flatMap { SeriesRhythm.slot(index: $0) }.map { "\(SeriesRhythm.label(page: $0.page, part: $0.part, sub: frame.sub)): " } ?? ""
        log("[seri] \(place)\(stamp(frame.time)): \(wasMerged ? "aynı görünüm, en iyisi kaldı" : verdict) (net \(sharp), blok \(String(format: "%.2f", frame.blockiness)), durgun \(String(format: "%.1f", frame.stillFor)) sn, \(text.map { $0.summary } ?? "yazı tanıma yok"))")
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
        return clock == nil ? windows.flush() : slots.flush()
    }

    private func snapshot() -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        var result = stats
        result.merged = pool.merged
        let chosen = pool.selected(minPages: minPages)
        let thinning = pool.thinReport()
        result.thinnedDirty = thinning.dirty
        result.thinnedRepeats = thinning.repeats
        let seen = numbers.sorted()
        // Yazı tanıma hiç çalışmadıysa (read == 0) teşhis konmaz: pencere sayısı 0 kalır
        let diagnosis = CaptureDiagnosis(windows: result.read, readableWindows: result.readable,
                                         medianSharpness: CaptureDiagnosis.median(sharpnesses), questionNumbers: seen,
                                         damagedWindows: result.damagedWindows)
        var outcome = Outcome(items: chosen, readable: chosen.filter { $0.isUseful }.count, stats: result, questionNumbers: seen, diagnosis: diagnosis)
        outcome.coverage = QuestionCoverage.make(questionPieces)
        outcome.motionNote = SeriesCollector.diffNote(signatureDiffs)
        if clock != nil {
            outcome.labels = chosen.map { item in
                let base = item.slot.flatMap { SeriesRhythm.slot(index: $0) }.map { SeriesRhythm.label(page: $0.page, part: $0.part, sub: item.sub) } ?? ""
                if base.isEmpty { return base }
                // Geçerli kare çıkmayan dilimin yine de gönderilen karesi: Gemini bunun zayıf olduğunu bilsin
                if item.damaged { return base + " (\(SlotProblem.damaged.note))" }
                return item.problem.map { base + " (\($0.note))" } ?? base
            }
        }
        return outcome
    }

    /// Ardışık kare imza farklarının dökümü (saf): çeyrekler ve durgun eşiğinin altında kalanların payı. Ölçüm yoksa boş
    static func diffNote(_ diffs: [Double]) -> String {
        if diffs.isEmpty { return "" }
        let sorted = diffs.sorted()
        func at(_ share: Double) -> Double {
            return sorted[min(sorted.count - 1, Int(share * Double(sorted.count - 1)))]
        }
        let still = sorted.filter { $0 <= FramePipeline.stillDiff }.count
        let percent = Int((100 * Double(still) / Double(sorted.count)).rounded())
        return "ölçüm \(sorted.count); çeyrekler \(String(format: "%.1f", at(0.25))) / \(String(format: "%.1f", at(0.5))) / \(String(format: "%.1f", at(0.75))); "
            + "durgun eşiği \(String(format: "%.1f", FramePipeline.stillDiff)) (altında kalan %\(percent))"
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
