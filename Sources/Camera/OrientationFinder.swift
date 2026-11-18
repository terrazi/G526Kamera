import Foundation
import CoreVideo

/// Yazının yönünü bulur (kullanıcı isteği 2026-11-18: çekim bazen alttan, bazen yandan olabilir; yazı yan ya da ters dursa da okunsun, kaydederken dik çevrilsin).
/// Kare mevcut (tercih edilen) yönde yeterince okunuyorsa başka yön denenmez; okunmuyorsa öteki üç yön denenir ve yazı belirgin biçimde daha çok okunan yön
/// seçilir. Yanlış yönde okuma anlamsız birkaç harf verebilir: başka yön ancak yeterince harf ve tercih edilenin birkaç katı kadar harf okuyorsa seçilir.
/// Koç yönü kendi görünümü için bulur (ölçüm dik görüntüde yapılır, yön cümleleri kameranın duruşuna göre söylenir: `ViewDirection`); toplu çekimde her kare
/// kendi yönüyle PDF'e dik girer (`orientation(for:fallback:)`).
final class OrientationFinder {
    /// Bu kadar harf okunuyorsa yön doğrudur, başka yön denenmez
    static let enoughChars = 80
    /// Başka yönün seçilmesi için en az okunan harf
    static let minChars = 60
    /// Başka yön, tercih edilenin en az bu kadar katı harf okumalı
    static let ratio = 3

    /// Okunan yazıda en az bu kadar işlev sözcüğü ("the", "of", "bir", "için") varsa yazı dik okunuyor sayılır (bkz. `TextSense`)
    static let minSense = 3

    /// Saf karar: `read` bir yönde okunan değeri ve harf sayısını verir. Tercih edilen yön yetiyorsa yalnız o okunur.
    /// `hint` (tercih edilen yön okunmadıktan sonra, yalnız gerekirse çağrılır) yazının hangi eksende durduğunu söyler (bkz. `OrientationProbe`): önce o yönler
    /// denenir; hiçbiri yetmezse öteki yönler de denenir (ipucu yanılsa da sonuç yanlış olmaz, yalnız yavaşlar). `hinted`: sonuç ipucu yönlerinden mi (true),
    /// ipucu dışından mı (false); ipucu yok ya da tercih edilen yön kalıyorsa nil.
    /// `sense`: okunan değerdeki işlev sözcüğü sayısı. Gerçek günlük 2026-11-18: baş aşağı okunan yazı da 80'den çok harf veriyordu ("questlons accordlng"),
    /// ilk yeterli görünen yön seçilince sayfalar 180° ters kaydedildi. Bu yüzden harf sayısı tek başına yetmez: anlamlı sözcüğü olmayan okuma şüphelidir,
    /// aynı eksendeki karşı yön (ve gerekirse öteki yönler) de okunur, anlamlı sözcüğü belirgin çok olan yön seçilir. Varsayılan `sense` her yönü anlamlı sayar.
    static func find<T>(preferred: ImageOrientation, hint: () -> [ImageOrientation]? = { nil },
                        sense: (T?) -> Int = { _ in OrientationFinder.minSense },
                        read: (ImageOrientation) -> (value: T?, chars: Int)) -> (orientation: ImageOrientation, value: T?, hinted: Bool?) {
        var cache: [ImageOrientation: (value: T?, chars: Int)] = [:]
        func reading(_ orientation: ImageOrientation) -> (value: T?, chars: Int) {
            if let known = cache[orientation] { return known }
            let result = read(orientation)
            cache[orientation] = result
            return result
        }
        func senseOf(_ orientation: ImageOrientation) -> Int { return sense(reading(orientation).value) }
        func meaningful(_ orientation: ImageOrientation) -> Bool { return senseOf(orientation) >= minSense }
        /// `candidate`, `current`'tan belirgin daha anlamlı mı (en az `minSense` ve iki katı sözcük)
        func clearlyBetter(_ candidate: ImageOrientation, than current: ImageOrientation) -> Bool {
            return senseOf(candidate) >= minSense && senseOf(candidate) >= 2 * senseOf(current)
        }
        /// Seçilen yön anlamlı sözcük vermiyorsa ters yöne (`deep` ise öteki yönlere de) bakılır; belirgin daha anlamlı bir yön varsa o seçilir
        func verified(_ chosen: ImageOrientation, deep: Bool) -> ImageOrientation {
            if meaningful(chosen) { return chosen }
            let alternatives = [chosen.opposite] + (deep ? ImageOrientation.allCases.filter { $0 != chosen && $0 != chosen.opposite } : [])
            var best = chosen
            for orientation in alternatives {
                if clearlyBetter(orientation, than: best) { best = orientation }
                // Karşı yön yeterince anlamlıysa öteki yönlere bakılmaz (çoğu zaman bir okuma daha)
                if best != chosen && meaningful(best) && orientation == chosen.opposite { break }
            }
            return best
        }

        let first = reading(preferred)
        if first.chars >= enoughChars {
            let result = verified(preferred, deep: false)
            return (result, reading(result).value, nil)
        }
        let needed = max(minChars, ratio * max(first.chars, 1))
        let others = ImageOrientation.allCases.filter { $0 != preferred }
        var hinted: [ImageOrientation] = []
        if let list = hint() { hinted = list.filter { others.contains($0) } }
        let phases: [[ImageOrientation]] = hinted.isEmpty ? [others] : [hinted, others.filter { !hinted.contains($0) }]
        func better(_ a: (orientation: ImageOrientation, chars: Int), than b: (orientation: ImageOrientation, chars: Int)) -> Bool {
            let am = meaningful(a.orientation), bm = meaningful(b.orientation)
            if am != bm { return am }
            return a.chars > b.chars
        }
        var best: (orientation: ImageOrientation, chars: Int)?
        for (index, phase) in phases.enumerated() {
            for orientation in phase {
                let result = reading(orientation)
                // Açıkça ve anlamlı okunan ilk yön yeter (en çok üç okuma yerine çoğu zaman bir)
                if result.chars >= max(enoughChars, needed) && meaningful(orientation) {
                    return (orientation, result.value, hinted.isEmpty ? nil : (index == 0))
                }
                let candidate = (orientation: orientation, chars: result.chars)
                if best == nil || better(candidate, than: best!) { best = candidate }
            }
            // İpucu yönlerinden biri yeterince ve anlamlı okunduysa öteki yönlere bakılmaz
            if index == 0, !hinted.isEmpty, let b = best, b.chars >= needed, meaningful(b.orientation) {
                return (b.orientation, reading(b.orientation).value, true)
            }
        }
        if let b = best, b.chars >= needed {
            let result = verified(b.orientation, deep: true)
            return (result, reading(result).value, hinted.isEmpty ? nil : hinted.contains(result))
        }
        return (preferred, first.value, nil)
    }

    private let lock = NSLock()
    private var current: ImageOrientation = .normal
    private var chosen: [UnsafeMutableRawPointer: ImageOrientation] = [:]
    private var trust = ProbeTrust()
    /// Metin kutusu taraması (sınamada sahtesi verilir); `nil` döndürürse ipucu yoktur
    var probe: (CVPixelBuffer) -> [CGRect]? = { OrientationProbe.boxes(in: $0) }

    /// Çekim başlarken: ilk denenecek yön kullanıcının ayarladığı yöndür; önceki karelerin kayıtları silinir
    func reset(base: ImageOrientation) {
        lock.lock()
        current = base
        chosen.removeAll()
        trust = ProbeTrust()
        lock.unlock()
    }

    /// İpucu isabet / ıska sayıları (günlük ve sınama için)
    var probeTrust: ProbeTrust {
        lock.lock()
        defer { lock.unlock() }
        return trust
    }

    /// Karedeki yazının yönünü bulur: önce `preferred`; okunmuyorsa metin kutusu taramasının ipucuyla öteki yönler. İpucunun isabeti kaydedilir,
    /// art arda yanılıyorsa tarama yapılmaz.
    func locate<T>(_ buffer: CVPixelBuffer, preferred: ImageOrientation, sense: (T?) -> Int = { _ in OrientationFinder.minSense },
                   read: (ImageOrientation) -> (value: T?, chars: Int)) -> (orientation: ImageOrientation, value: T?) {
        let found = OrientationFinder.find(preferred: preferred, hint: { [self] () -> [ImageOrientation]? in
            lock.lock()
            let trusted = trust.isTrusted
            lock.unlock()
            guard trusted, let boxes = probe(buffer) else { return nil }
            return OrientationProbe.hint(boxes: boxes, aspect: OrientationProbe.aspect(of: buffer), preferred: preferred)
        }, sense: sense, read: read)
        if let hit = found.hinted {
            lock.lock()
            trust.record(hit: hit)
            lock.unlock()
        }
        return (found.orientation, found.value)
    }

    /// Karedeki yazıyı okur; `enabled` açıksa yönü de bulur ve kareye kaydeder (sonraki kare önce bu yönü dener)
    func readScore(_ buffer: CVPixelBuffer, base: ImageOrientation, enabled: Bool,
                   reader: (CVPixelBuffer, ImageOrientation) -> TextScore?) -> TextScore? {
        guard enabled else { return reader(buffer, base) }
        lock.lock()
        let start = current
        lock.unlock()
        let found = locate(buffer, preferred: start, sense: { (score: TextScore?) in score?.sense ?? 0 }) { orientation -> (value: TextScore?, chars: Int) in
            let score = reader(buffer, orientation)
            return (score, score?.chars ?? 0)
        }
        lock.lock()
        current = found.orientation
        if chosen.count > 2000 { chosen.removeAll() }
        chosen[Unmanaged.passUnretained(buffer).toOpaque()] = found.orientation
        lock.unlock()
        return found.value
    }

    /// Karenin dik görünmesi için çevrilecek yön; kare okunmadıysa `fallback`
    func orientation(for buffer: CVPixelBuffer, fallback: ImageOrientation) -> ImageOrientation {
        lock.lock()
        defer { lock.unlock() }
        return chosen[Unmanaged.passUnretained(buffer).toOpaque()] ?? fallback
    }
}

/// Yazının dik okunup okunmadığını anlamak için sık kullanılan işlev sözcüklerini sayar (İngilizce ve Türkçe). Baş aşağı ya da yan okunan yazı çoğu zaman
/// çok harf verir ama bu sözcükler çıkmaz; dik okunan yoğun bir sayfada ise onlarca kez geçer. Sözcük listesi kısa tutulur: amaç yazıyı anlamak değil,
/// iki yönden hangisinin gerçek metin verdiğini seçmektir.
enum TextSense {
    static let common: Set<String> = [
        "the", "of", "and", "to", "in", "is", "that", "for", "it", "as", "with", "was", "on", "are", "be", "by", "this", "which", "from", "or", "an", "not",
        "have", "has", "but", "they", "their", "at", "were", "can", "been", "these", "such", "than", "more", "also", "may", "will", "would", "its", "if", "who",
        "bir", "ve", "bu", "için", "ile", "de", "da", "çok", "gibi", "daha", "olarak", "ne", "ya", "ki", "mi", "olan", "kadar", "her", "ama", "veya", "ise"
    ]

    /// Metindeki işlev sözcüklerinin sayısı (küçük harfe çevrilip harf olmayanlardan bölünür)
    static func count(_ text: String) -> Int {
        var total = 0
        for word in text.lowercased().split(whereSeparator: { !$0.isLetter }) where word.count >= 2 && word.count <= 5 {
            if common.contains(String(word)) { total += 1 }
        }
        return total
    }
}
