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

    /// Her analiz edilen kare için (kare, zaman, netlik puanı) çağrılır (analiz kuyruğundan). Video kaydı en net kareyi seçmek için kullanır.
    var onAnalyzed: ((CVPixelBuffer, TimeInterval, Double) -> Void)?

    /// Sesli konumlandırma: sayfa/yazı ölçüsü + kameranın ne kadar süredir durgun olduğu (analiz kuyruğundan).
    struct GuidanceSample {
        var metrics: PageMetrics
        var time: TimeInterval
        /// Kare imzası bu süredir önemli ölçüde değişmedi
        var stillFor: TimeInterval
        /// Son çekimin imzasına göre sahne farkı (sayfa çevrildi mi / bölüm değişti mi)
        var diffToCapture: Double
    }
    var onGuidance: ((GuidanceSample) -> Void)?
    /// Ölçümler en sık bu aralıkla (saniye) yapılır
    static let guidanceInterval: TimeInterval = 0.3
    /// Ardışık imzalar arası ortalama fark bunun altındaysa kare "durgun" sayılır
    static let stillDiff = 2.0

    private var _guidance = false
    // Aşağıdakiler yalnızca analiz kuyruğunda değişir
    private var prevSignature: [UInt8]?
    private var latestSignature: [UInt8]?
    private var captureSignature: [UInt8]?
    private var lastMoveTime: TimeInterval = 0
    private var lastGuidanceTime: TimeInterval = -100

    private var _guidanceOrientation = ImageOrientation.normal
    /// Sayfa ölçümü bu yönde çevrilmiş görüntü üzerinde yapılır (bkz. GuidanceAnalyzer.reorient)
    var guidanceOrientation: ImageOrientation {
        get { lock.lock(); defer { lock.unlock() }; return _guidanceOrientation }
        set { lock.lock(); _guidanceOrientation = newValue; lock.unlock() }
    }

    var guidanceOn: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _guidance }
        set { lock.lock(); _guidance = newValue; lock.unlock() }
    }

    private var _pageEdges = false
    /// Kamera durunca Vision ile kâğıdın kenarları da bulunur (kadraj tarifi için); kapalıyken Vision hiç çalışmaz
    var pageEdgesOn: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _pageEdges }
        set { lock.lock(); _pageEdges = newValue; lock.unlock() }
    }
    /// Vision'a girmek için kameranın en az bu kadar sn durgun olması gerekir (değerlendirme eşiğinin hemen altı)
    static let edgeStill: TimeInterval = 0.4
    // Yalnızca analiz kuyruğunda değişir
    private var edgeTracker = PageEdgeTracker()
    private var edgeOrientation = ImageOrientation.normal

    /// Çekim yapıldı: sahne farkı bu ana göre ölçülür (sayfa çevrilince yeniden hazırlanmak için).
    func markCaptured() {
        queue.async { self.captureSignature = self.latestSignature }
    }

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
                self.onAnalyzed?(pixelBuffer, time, result.sharpness)
                if self.motion.process(signature: result.signature, time: time, busy: self.engine.isBusy) {
                    self.onMotionTrigger?()
                }
                if self.guidanceOn { self.guidanceStep(pixelBuffer, signature: result.signature, time: time) }
            }
            self.lock.lock()
            self.backlog -= 1
            self.lock.unlock()
        }
    }

    private func guidanceStep(_ pixelBuffer: CVPixelBuffer, signature sig: [UInt8], time: TimeInterval) {
        if let prev = prevSignature {
            if FrameAnalysis.difference(prev, sig) > FramePipeline.stillDiff { lastMoveTime = time }
        } else {
            lastMoveTime = time
        }
        prevSignature = sig
        latestSignature = sig
        // Kamera hareket ederken ağır ölçüm yapılmaz; durgunlaşınca ve aralık dolunca ölçülür
        if time - lastGuidanceTime < FramePipeline.guidanceInterval { return }
        lastGuidanceTime = time
        let still = time - lastMoveTime
        var metrics = PageMetrics()
        if still >= 0.2, let m = GuidanceAnalyzer.analyze(pixelBuffer, orientation: guidanceOrientation) { metrics = m }
        metrics.edges = pageEdges(for: pixelBuffer, still: still, time: time, hasText: metrics.hasText)
        let diff = captureSignature.map { FrameAnalysis.difference($0, sig) } ?? 100
        onGuidance?(GuidanceSample(metrics: metrics, time: time, stillFor: still, diffToCapture: diff))
    }

    /// Kâğıdın kenarları (Vision): yalnız ayar açıkken, pil tasarrufunda değilken, kamera durgunken ve kadrajda yazı varken; seyrek çalışır.
    /// Kamera oynarsa, yazı kaybolursa ya da görüntü yönü değişirse eski sonuç silinir.
    private func pageEdges(for pixelBuffer: CVPixelBuffer, still: TimeInterval, time: TimeInterval, hasText: Bool) -> PageEdges? {
        let orientation = guidanceOrientation
        if orientation != edgeOrientation {
            edgeOrientation = orientation
            edgeTracker.reset()
        }
        guard pageEdgesOn, !saving, hasText, still >= FramePipeline.edgeStill else {
            edgeTracker.reset()
            return nil
        }
        if edgeTracker.due(at: time) {
            edgeTracker.ingest(PageEdgeDetector.detect(pixelBuffer, orientation: orientation), at: time)
        }
        return edgeTracker.current
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
        queue.async {
            self.motion.reset()
            self.prevSignature = nil
            self.latestSignature = nil
            self.captureSignature = nil
            self.lastMoveTime = 0
            self.edgeTracker.reset()
        }
    }
}
