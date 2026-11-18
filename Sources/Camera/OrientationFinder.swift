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

    /// Saf karar: `read` bir yönde okunan değeri ve harf sayısını verir. Tercih edilen yön yetiyorsa yalnız o okunur.
    /// `hint` (tercih edilen yön okunmadıktan sonra, yalnız gerekirse çağrılır) yazının hangi eksende durduğunu söyler (bkz. `OrientationProbe`): önce o yönler
    /// denenir; hiçbiri yetmezse öteki yönler de denenir (ipucu yanılsa da sonuç yanlış olmaz, yalnız yavaşlar). `hinted`: sonuç ipucu yönlerinden mi (true),
    /// ipucu dışından mı (false); ipucu yok ya da tercih edilen yön kalıyorsa nil.
    static func find<T>(preferred: ImageOrientation, hint: () -> [ImageOrientation]? = { nil },
                        read: (ImageOrientation) -> (value: T?, chars: Int)) -> (orientation: ImageOrientation, value: T?, hinted: Bool?) {
        let first = read(preferred)
        if first.chars >= enoughChars { return (preferred, first.value, nil) }
        let needed = max(minChars, ratio * max(first.chars, 1))
        let others = ImageOrientation.allCases.filter { $0 != preferred }
        var hinted: [ImageOrientation] = []
        if let list = hint() { hinted = list.filter { others.contains($0) } }
        let phases: [[ImageOrientation]] = hinted.isEmpty ? [others] : [hinted, others.filter { !hinted.contains($0) }]
        var best: (orientation: ImageOrientation, result: (value: T?, chars: Int))?
        for (index, phase) in phases.enumerated() {
            for orientation in phase {
                let result = read(orientation)
                // Açıkça okunan ilk yön yeter (en çok üç okuma yerine çoğu zaman bir)
                if result.chars >= max(enoughChars, needed) { return (orientation, result.value, hinted.isEmpty ? nil : (index == 0)) }
                if best == nil || result.chars > best!.result.chars { best = (orientation, result) }
            }
            // İpucu yönlerinden biri yeterince okunduysa öteki yönlere bakılmaz
            if index == 0, !hinted.isEmpty, let b = best, b.result.chars >= needed { return (b.orientation, b.result.value, true) }
        }
        if let b = best, b.result.chars >= needed { return (b.orientation, b.result.value, hinted.isEmpty ? nil : hinted.contains(b.orientation)) }
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
    func locate<T>(_ buffer: CVPixelBuffer, preferred: ImageOrientation,
                   read: (ImageOrientation) -> (value: T?, chars: Int)) -> (orientation: ImageOrientation, value: T?) {
        let found = OrientationFinder.find(preferred: preferred, hint: { [self] () -> [ImageOrientation]? in
            lock.lock()
            let trusted = trust.isTrusted
            lock.unlock()
            guard trusted, let boxes = probe(buffer) else { return nil }
            return OrientationProbe.hint(boxes: boxes, aspect: OrientationProbe.aspect(of: buffer), preferred: preferred)
        }, read: read)
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
        let found = locate(buffer, preferred: start) { orientation -> (value: TextScore?, chars: Int) in
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
