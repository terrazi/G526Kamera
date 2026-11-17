import Foundation

/// Kameradan gelen video akışının GERÇEK özelliklerini ölçer: çözülen karenin boyutu, saniyedeki kare sayısı ve bitrate.
///
/// Neden: kamera akış adlarını "4K / 2K / 1080P" diye bildiriyor ama ölçülen boyutlar 1920×1080 (akış 1) ve 640×360 (akış 2) çıktı; adlar boyutu
/// yansıtmıyor. Akış 3 hiç ölçülmedi. Her oturumun sonunda ölçüm günlüğe yazılır ("akış ölçümü"), böylece hangi akışın ne verdiği günlükten okunur.
/// Kare sayacı paket iş parçacığından, boyut çözücü iş parçacığından gelir; hepsi kilitlidir.
final class StreamMeter {
    struct Snapshot: Equatable {
        /// Ölçülen akışın numarası (kameraya istenen `stream` değeri)
        var stream = 0
        /// Çözülen son karenin boyutu (hiç kare çözülmediyse 0)
        var width = 0
        var height = 0
        /// Kameradan gelen tam kare sayısı, bunların anahtar kare olanları ve toplam yük (bayt)
        var frames = 0
        var keyFrames = 0
        var bytes = 0
        /// İlk kareden son kareye geçen süre (sn)
        var seconds: Double = 0
    }

    private let lock = NSLock()
    private var snap = Snapshot()
    private var firstAt: TimeInterval?
    private var lastAt: TimeInterval = 0

    /// Yeni ölçüm: sayaçlar sıfırlanır ve ölçülen akışın numarası yazılır
    func begin(stream: Int) {
        lock.lock()
        defer { lock.unlock() }
        snap = Snapshot()
        snap.stream = stream
        firstAt = nil
        lastAt = 0
    }

    /// Sayaçlar sıfırlanır, akış numarası kalır (bağlantı koptu: kopukluk süresi kare hızını düşürmesin)
    func reset() {
        lock.lock()
        let stream = snap.stream
        lock.unlock()
        begin(stream: stream)
    }

    /// Kameradan bir kare geldi (`time`: saat, sn)
    func addFrame(bytes: Int, keyFrame: Bool, at time: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        if firstAt == nil { firstAt = time }
        lastAt = time
        snap.frames += 1
        snap.bytes += bytes
        if keyFrame { snap.keyFrames += 1 }
    }

    /// Bir kare çözüldü: boyutu yazılır
    func addDecoded(width: Int, height: Int) {
        lock.lock()
        defer { lock.unlock() }
        snap.width = width
        snap.height = height
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        var s = snap
        s.seconds = firstAt.map { max(0, lastAt - $0) } ?? 0
        return s
    }
}

/// Ölçümün okunur özeti (günlük ve "Kamerayı dene" satırları için)
enum StreamReport {
    /// Bundan az kare ya da kısa süre ölçülürse sayılar güvenilmez: özet yazılmaz
    static let minFrames = 5
    static let minSeconds = 1.0

    /// Saniyedeki kare sayısı: ilk kare sayılmaz (süre ilk karenin gelişinden başlar)
    static func framesPerSecond(_ s: StreamMeter.Snapshot) -> Double {
        guard s.seconds > 0 else { return 0 }
        return Double(max(0, s.frames - 1)) / s.seconds
    }

    /// Saniyedeki kilobit
    static func kilobitsPerSecond(_ s: StreamMeter.Snapshot) -> Double {
        guard s.seconds > 0 else { return 0 }
        return Double(s.bytes) * 8 / 1000 / s.seconds
    }

    /// "akış 3: 1280×720, 9.1 kare/sn, 1850 kbit/sn (54 kare, 6.0 sn, 3 anahtar kare)"; yeterli kare yoksa nil
    static func text(_ s: StreamMeter.Snapshot) -> String? {
        guard s.frames >= minFrames, s.seconds >= minSeconds else { return nil }
        let size = s.width > 0 ? "\(s.width)×\(s.height)" : "boyut okunamadı"
        let fps = String(format: "%.1f", framesPerSecond(s))
        let kbps = Int(kilobitsPerSecond(s).rounded())
        let span = String(format: "%.1f", s.seconds)
        return "akış \(s.stream): \(size), \(fps) kare/sn, \(kbps) kbit/sn (\(s.frames) kare, \(span) sn, \(s.keyFrames) anahtar kare)"
    }
}
