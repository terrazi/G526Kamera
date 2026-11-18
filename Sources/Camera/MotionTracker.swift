import Foundation
import CoreVideo
import Vision

/// Bir zaman aralığındaki kamera hareketinin özeti (bkz. `MotionTracker`). Kayma birimi "kare boyu"dur: yatayda kare genişliğinin, dikeyde kare
/// yüksekliğinin oranı (1,0 = görüntü tam bir kare kaydı). Saf veri; birim testle denenir.
struct MotionSummary: Equatable {
    /// Hizalanabilen ardışık kare çifti
    var samples = 0
    /// Hizalanamayan çift (sayfa çevirme, çok hızlı hareket, bozuk kare)
    var failures = 0
    /// Ortanca hız (kare boyu / sn)
    var medianSpeed = 0.0
    /// Hızı `MotionTracker.fastSpeed`'i aşan ölçümlerin oranı (0–1)
    var fastShare = 0.0
    /// Belirgin biçimde kıpırdayan ölçümlerin oranı (0–1): 0 ise ya kamera hiç oynamadı ya da ölçüm çalışmıyor
    var movingShare = 0.0
    /// Kameranın gezdiği alan: birikimli yolun yatay ve dikey açıklığı (kare boyu)
    var extentX = 0.0
    var extentY = 0.0

    /// Kamera çoğunlukla hızlı kaydırıldı (bulanıklığın olası nedeni)
    var isFast: Bool { return samples >= MotionTracker.minSamples && fastShare >= MotionTracker.fastShareLimit }

    /// Kamera oynadı ama hep aynı yerde kaldı: sayfanın tamamı taranmamış olabilir. Ölçüm hiç hareket görmediyse hüküm verilmez (ölçüm çalışmıyor olabilir)
    var barelyMoved: Bool {
        return samples >= MotionTracker.minCoverageSamples && movingShare >= MotionTracker.aliveShare
            && max(extentX, extentY) < MotionTracker.smallExtent
    }

    /// Günlük satırı
    var logText: String {
        return String(format: "%d ölçüm, %d başarısız, ortanca hız %.2f kare/sn, hızlı pay %%%d, kıpırdayan pay %%%d, gezilen alan yatay %.2f dikey %.2f kare",
                      samples, failures, medianSpeed, Int((fastShare * 100).rounded()), Int((movingShare * 100).rounded()), extentX, extentY)
    }
}

/// Hareket takibi (kullanıcı isteği 2026-11-18 akşam: "en modern teknoloji"): ardışık kareleri birbirine hizalayıp (Apple Vision,
/// `VNTranslationalImageRegistrationRequest`) kameranın sayfa üzerinde ne kadar ve ne hızla kaydığını ölçer. Kullanıcının gerçek deneme videolarında
/// (OpenCV ile, 2 × 600 kare) ardışık karelerin %95–97'si hizalanabildi; 1 sn'lik zincirde sapma ≈1–2 piksel.
///
/// BU SÜRÜMDE YALNIZ DANIŞMANDIR: sayfa denetiminde "kamera hızlı kaydırıldı" / "kamera az kaydırıldı" notunu ve günlükteki ölçüm satırını üretir; hiçbir
/// kareyi elemez, hiçbir sayfayı kendi başına "kötü" saymaz. Vision'ın bu kameranın görüntüsündeki isabeti cihazda ölçülmedi: eşikler ilk günlüklerle
/// ayarlanacak. Ayarlar > "Hareket takibi" ile kapatılır.
///
/// Hizalama kendi sırasında çalışır; meşgulken gelen kare atlanır (kare hızına yetişemezse ölçüm seyrekleşir, çekim etkilenmez).
final class MotionTracker {
    /// Bu hızın (kare boyu / sn) üstü "hızlı" sayılır. Kullanıcının okunaklı çekimlerinde ortanca hız 0,11–0,17, en hızlı onda birlik 0,57 kare/sn idi
    static let fastSpeed = 0.5
    static let fastShareLimit = 0.4
    static let minSamples = 20
    /// "Az kaydırıldı" hükmü için en az ölçüm (30 sn'de ≈300 çift beklenir)
    static let minCoverageSamples = 50
    /// Ölçümlerin en az bu kadarı kıpırdama görmüşse ölçüm çalışıyor sayılır
    static let aliveShare = 0.2
    /// Kıpırdama eşiği (kare boyu, çift başına): 1920 pikselde ≈4 piksel
    static let movingShift = 0.002
    /// Gezilen alan bu kadar kare boyundan küçükse kamera aynı yerde kalmıştır (kamera sayfa yüksekliğinin ≈%40'ını görür)
    static let smallExtent = 0.5
    /// Ardışık iki kare arasında bundan uzun ara varsa (kare atlandı / görüntü kesildi) çift ölçülmez
    static let maxGap: TimeInterval = 0.6

    struct Sample: Equatable {
        var time: TimeInterval
        /// Önceki kareye göre kayma (kare boyu) ve iki kare arasındaki süre
        var dx: Double
        var dy: Double
        var dt: TimeInterval
        var speed: Double { return dt > 0 ? (dx * dx + dy * dy).squareRoot() / dt : 0 }
    }

    typealias Aligner = (CVPixelBuffer, CVPixelBuffer) -> (dx: Double, dy: Double)?

    private let queue = DispatchQueue(label: "g526.motion", qos: .utility)
    private let lock = NSLock()
    private let align: Aligner
    private var busy = false
    private var previous: CVPixelBuffer?
    private var previousTime: TimeInterval = 0
    private var samples: [Sample] = []
    private var failureTimes: [TimeInterval] = []
    private var skippedCount = 0

    init(align: @escaping Aligner = MotionTracker.visionAlign) {
        self.align = align
    }

    /// Meşgulken atlanan kare sayısı
    var skipped: Int {
        lock.lock()
        defer { lock.unlock() }
        return skippedCount
    }

    /// Kameradan gelen her kare (analiz sırasından çağrılır; hemen döner)
    func offer(_ buffer: CVPixelBuffer, time: TimeInterval) {
        lock.lock()
        if busy {
            skippedCount += 1
            lock.unlock()
            return
        }
        busy = true
        lock.unlock()
        queue.async { [weak self] in
            self?.measure(buffer, time: time)
        }
    }

    private func measure(_ buffer: CVPixelBuffer, time: TimeInterval) {
        lock.lock()
        let before = previous
        let beforeTime = previousTime
        lock.unlock()
        var sample: Sample?
        var failed = false
        if let before = before, time > beforeTime, time - beforeTime <= MotionTracker.maxGap {
            if let shift = align(before, buffer) {
                sample = Sample(time: time, dx: shift.dx, dy: shift.dy, dt: time - beforeTime)
            } else {
                failed = true
            }
        }
        lock.lock()
        previous = buffer
        previousTime = time
        if let sample = sample { samples.append(sample) }
        if failed { failureTimes.append(time) }
        busy = false
        lock.unlock()
    }

    /// Bekleyen ölçüm bitene kadar bekler (özetten önce; en çok bir çift)
    func drain() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }

    /// `from`–`to` (karelerin zaman damgasıyla aynı saat) arasındaki hareketin özeti
    func summary(from: TimeInterval, to: TimeInterval) -> MotionSummary {
        lock.lock()
        let window = samples.filter { $0.time >= from && $0.time < to }
        let failures = failureTimes.filter { $0 >= from && $0 < to }.count
        lock.unlock()
        return MotionTracker.summarize(window, failures: failures)
    }

    /// Saf hesap (birim testle denenir)
    static func summarize(_ samples: [Sample], failures: Int) -> MotionSummary {
        var result = MotionSummary()
        result.samples = samples.count
        result.failures = failures
        guard !samples.isEmpty else { return result }
        let speeds = samples.map { $0.speed }.sorted()
        result.medianSpeed = speeds[speeds.count / 2]
        result.fastShare = Double(speeds.filter { $0 > fastSpeed }.count) / Double(speeds.count)
        let moving = samples.filter { ($0.dx * $0.dx + $0.dy * $0.dy).squareRoot() > movingShift }.count
        result.movingShare = Double(moving) / Double(samples.count)
        var x = 0.0, y = 0.0
        var minX = 0.0, maxX = 0.0, minY = 0.0, maxY = 0.0
        for sample in samples {
            x += sample.dx
            y += sample.dy
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }
        result.extentX = maxX - minX
        result.extentY = maxY - minY
        return result
    }

    /// Apple Vision ile iki kareyi hizalar: ikinci karenin birinciye göre kayması (kare boyu). Hizalanamazsa nil.
    static func visionAlign(_ first: CVPixelBuffer, _ second: CVPixelBuffer) -> (dx: Double, dy: Double)? {
        let width = Double(CVPixelBufferGetWidth(first))
        let height = Double(CVPixelBufferGetHeight(first))
        guard width > 0, height > 0 else { return nil }
        let request = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: second, options: [:])
        let handler = VNImageRequestHandler(cvPixelBuffer: first, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        for case let observation as VNImageTranslationAlignmentObservation in (request.results ?? []) {
            let transform = observation.alignmentTransform
            return (dx: Double(transform.tx) / width, dy: Double(transform.ty) / height)
        }
        return nil
    }
}

/// Güçlü yazı okumanın (Vision "accurate" kipi) hızını izler (kullanıcı isteği 2026-11-18 akşam). Saniyede 2 kare okunur; okuma ortalaması
/// `slowSeconds`'ı aşarsa telefon yetişemiyor demektir: o oturumun kalanında hızlı kipe dönülür (çekim gecikmesin). Saf mantık; birim testle denenir.
final class ReadPace {
    /// Okuma ortalaması bunu aşarsa güçlü kip bırakılır (iki kare/sn için kare başına 0,5 sn'den az kalmalı; fotoğraf oluşturma payı da var)
    static let slowSeconds = 0.4
    /// Karar için en az okuma
    static let minSamples = 4

    private let lock = NSLock()
    private let enabled: Bool
    private var total = 0.0
    private var count = 0
    private var gaveUp = false

    init(enabled: Bool) {
        self.enabled = enabled
    }

    /// Sıradaki okuma güçlü kiple mi yapılsın?
    var useAccurate: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled && !gaveUp
    }

    /// Güçlü kiple yapılan bir okumanın süresi; bu okumayla güçlü kip bırakıldıysa true döner (bir kez)
    func record(seconds: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        total += max(0, seconds)
        count += 1
        if !gaveUp, count >= ReadPace.minSamples, total / Double(count) > ReadPace.slowSeconds {
            gaveUp = true
            return true
        }
        return false
    }

    /// Güçlü kiple okunan kare sayısı ve ortalama süre (günlük için)
    var report: (count: Int, average: Double, gaveUp: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (count, count > 0 ? total / Double(count) : 0, gaveUp)
    }
}
