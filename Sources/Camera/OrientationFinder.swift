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
    static func find<T>(preferred: ImageOrientation, read: (ImageOrientation) -> (value: T?, chars: Int)) -> (orientation: ImageOrientation, value: T?) {
        let first = read(preferred)
        if first.chars >= enoughChars { return (preferred, first.value) }
        let needed = max(minChars, ratio * max(first.chars, 1))
        var best: (orientation: ImageOrientation, result: (value: T?, chars: Int))?
        for orientation in ImageOrientation.allCases where orientation != preferred {
            let result = read(orientation)
            // Açıkça okunan ilk yön yeter (en çok üç okuma yerine çoğu zaman bir)
            if result.chars >= max(enoughChars, needed) { return (orientation, result.value) }
            if best == nil || result.chars > best!.result.chars { best = (orientation, result) }
        }
        if let b = best, b.result.chars >= needed { return (b.orientation, b.result.value) }
        return (preferred, first.value)
    }

    private let lock = NSLock()
    private var current: ImageOrientation = .normal
    private var chosen: [UnsafeMutableRawPointer: ImageOrientation] = [:]

    /// Çekim başlarken: ilk denenecek yön kullanıcının ayarladığı yöndür; önceki karelerin kayıtları silinir
    func reset(base: ImageOrientation) {
        lock.lock()
        current = base
        chosen.removeAll()
        lock.unlock()
    }

    /// Karedeki yazıyı okur; `enabled` açıksa yönü de bulur ve kareye kaydeder (sonraki kare önce bu yönü dener)
    func readScore(_ buffer: CVPixelBuffer, base: ImageOrientation, enabled: Bool,
                   reader: (CVPixelBuffer, ImageOrientation) -> TextScore?) -> TextScore? {
        guard enabled else { return reader(buffer, base) }
        lock.lock()
        let start = current
        lock.unlock()
        let found = OrientationFinder.find(preferred: start) { orientation -> (value: TextScore?, chars: Int) in
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
