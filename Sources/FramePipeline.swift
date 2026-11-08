import Foundation
import CoreVideo

/// Çözülen karelerin gittiği yer: ekrana gönderir, netlik/imza hesaplar, ring tampona koyar,
/// görüntü değişimini izler. Arka plan iş parçacıklarında çalışır (ana iş parçacığına bağlı değildir).
final class FramePipeline {
    let renderer = VideoRenderer()
    let store = FrameStore(capacity: 20)
    let engine: CaptureEngine
    private let motion = MotionDetector()
    private let queue = DispatchQueue(label: "g526.analysis", qos: .utility)
    private let lock = NSLock()
    private var backlog = 0
    private(set) var framesSeen = 0
    private var _saving = false

    /// Pil tasarrufu (önizleme kapalı): ekrana kare gönderilmez, analiz kareler seyreltilerek yapılır.
    var saving: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _saving }
        set { lock.lock(); _saving = newValue; lock.unlock() }
    }

    /// Görüntü değişti ve sahne durulduysa çağrılır (analiz kuyruğundan).
    var onMotionTrigger: (() -> Void)?

    init() {
        engine = CaptureEngine(store: store)
    }

    func handle(_ pixelBuffer: CVPixelBuffer, time: TimeInterval) {
        let power = saving
        if !power { renderer.enqueue(pixelBuffer) }
        framesSeen += 1
        // Pil tasarrufunda her ikinci kare analiz edilir (netlik/değişim hesabı işlemciyi en çok yoran iştir)
        if power && framesSeen % 2 == 0 { return }

        lock.lock()
        if backlog >= 3 {
            lock.unlock()
            return
        }
        backlog += 1
        lock.unlock()

        queue.async {
            let height = CVPixelBufferGetHeight(pixelBuffer)
            if let result = FrameAnalysis.analyze(pixelBuffer, skipTop: Int(Double(height) * 0.05)) {
                self.store.add(buffer: pixelBuffer, time: time,
                               sharpness: result.sharpness, signature: result.signature)
                if self.motion.process(signature: result.signature, time: time, busy: self.engine.isBusy) {
                    self.onMotionTrigger?()
                }
            }
            self.lock.lock()
            self.backlog -= 1
            self.lock.unlock()
        }
    }

    func configureMotion(enabled: Bool, sensitivity: Int) {
        queue.async {
            if self.motion.enabled != enabled || self.motion.sensitivity != sensitivity {
                self.motion.enabled = enabled
                self.motion.sensitivity = sensitivity
                self.motion.reset()
            }
        }
    }

    /// Bağlantı yenilenince eski kareleri ve değişim referansını temizler.
    func reset() {
        store.clear()
        queue.async { self.motion.reset() }
    }
}
