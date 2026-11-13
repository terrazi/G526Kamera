import Foundation
import CoreVideo

/// Canlı kadraj denetiminin sonucu: görünen sorular kadraja tam sığıyor mu
struct LiveFramingResult: Equatable {
    /// Görünen bütün numaralı sorular kadraja tam sığıyor ve okunuyor
    var ready: Bool
    /// Sığmayan en önemli sorun (hazırsa nil) ve hangi soruda
    var problem: ShotProblem?
    var number: Int
    /// Görünen numaralı soru sayısı (0 = hiç soru bulunamadı: karar verilemez)
    var questions: Int
}

/// Canlı görüntüden okunan satırlardan "sorular kadraja tam sığıyor mu" kararı. Netlik ve parlama canlı ölçülmez (çekimde denetlenir);
/// burada yalnız sığma ve okunurluk bakılır. Saf mantıktır.
enum LiveFraming {
    static func evaluate(lines: [OCRLine], total: Int, optionCount: Int, config: QualityConfig) -> LiveFramingResult {
        let layout = QuestionLayout.analyze(lines: lines, total: total, optionCount: optionCount)
        guard !layout.blocks.isEmpty else { return LiveFramingResult(ready: false, problem: nil, number: 0, questions: 0) }
        var worst: (problem: ShotProblem, number: Int)?
        for b in layout.blocks {
            var problems = QualityGate.problems(ShotCandidate(frame: 0, block: b, sharp: 10, glare: 0), config: config)
            // Son şık yok ve yazı kadrajın altına dayanıyorsa "eksik şık" değil "alttan kesik"tir
            if b.opensBelow { problems = problems.map { $0 == .incomplete ? .cutBottom : $0 } }
            guard let top = problems.min(by: { $0.priority < $1.priority }) else { continue }
            if let w = worst, w.problem.priority <= top.priority { continue }
            worst = (top, b.number)
        }
        return LiveFramingResult(ready: worst == nil, problem: worst?.problem, number: worst?.number ?? 0, questions: layout.blocks.count)
    }
}

/// Canlı görüntüden sınırlı sıklıkta yazı okur (bir okuma sürerken yenisi başlamaz). Yalnız belge kadrajdayken ve açıkken çalışır:
/// pil ve ısınma için.
final class LiveOCR {
    /// İki okuma arasındaki en kısa süre (sn)
    static let minGap = 0.5

    private let queue = DispatchQueue(label: "g526.liveocr", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false
    private var enabled = false
    private var docPresent = false
    private var orientation: ImageOrientation = .normal
    private var lastFinished: TimeInterval = 0
    /// Okunan satırlar ve okunan karenin alındığı an (systemUptime); kuyruk iş parçacığında çağrılır
    var onResult: (([OCRLine], TimeInterval) -> Void)?

    func setEnabled(_ on: Bool, orientation: ImageOrientation) {
        lock.lock()
        enabled = on
        self.orientation = orientation
        lock.unlock()
    }

    func setDocPresent(_ present: Bool) {
        lock.lock()
        docPresent = present
        lock.unlock()
    }

    /// Her analiz edilen kare verilir; uygun değilse hemen döner
    func offer(_ buffer: CVPixelBuffer) {
        let taken = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard enabled, docPresent, !busy, taken - lastFinished >= LiveOCR.minGap else {
            lock.unlock()
            return
        }
        busy = true
        let o = orientation
        lock.unlock()
        queue.async { [weak self] in
            let lines = VisionOCR.recognize(buffer, orientation: o)
            guard let self = self else { return }
            self.lock.lock()
            self.busy = false
            self.lastFinished = ProcessInfo.processInfo.systemUptime
            let still = self.enabled
            self.lock.unlock()
            if still { self.onResult?(lines, taken) }
        }
    }
}
