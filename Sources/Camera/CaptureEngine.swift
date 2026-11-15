import Foundation
import CoreVideo

struct CaptureOptions {
    var before: Double
    var after: Double
    var multiFrame: Bool
    var enhance: EnhanceOptions
    /// Yalnız belge görünüyorsa çek (kâğıt + yazı); değilse `notDocument` ile reddedilir
    var documentOnly = false
}

struct CapturedPhoto {
    let jpeg: Data
    let date: Date
    let sharpness: Double
    let width: Int
    let height: Int
    let framesUsed: Int
    let candidates: Int
    let reason: String
}

enum CaptureError: Error {
    case noFrames
    case renderFailed
    /// Kadrajda belge yok; açıklama günlük içindir
    case notDocument(String)

    var message: String {
        switch self {
        case .noFrames: return "Görüntü akışı yok, fotoğraf çekilemedi."
        case .renderFailed: return "Fotoğraf oluşturulamadı."
        case .notDocument: return "Belge görünmüyor — fotoğraf çekilmedi."
        }
    }
}

/// Tetikleme anının çevresindeki kareleri toplar, en netini seçer, gerekirse birkaçını birleştirip iyileştirir.
final class CaptureEngine {
    let store: FrameStore
    private let work = DispatchQueue(label: "g526.capture", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false

    init(store: FrameStore) {
        self.store = store
    }

    /// Tetikleme anından `after` saniye sonra çalışır. Meşgulse false döner.
    @discardableResult
    func capture(reason: String, options: CaptureOptions,
                 completion: @escaping (Result<CapturedPhoto, CaptureError>) -> Void) -> Bool {
        lock.lock()
        if busy {
            lock.unlock()
            return false
        }
        busy = true
        lock.unlock()

        let t0 = ProcessInfo.processInfo.systemUptime
        work.asyncAfter(deadline: .now() + max(0, options.after)) { [weak self] in
            guard let self = self else { return }
            let result = self.process(t0: t0, reason: reason, options: options)
            self.lock.lock()
            self.busy = false
            self.lock.unlock()
            completion(result)
        }
        return true
    }

    private func process(t0: TimeInterval, reason: String, options: CaptureOptions) -> Result<CapturedPhoto, CaptureError> {
        var candidates = store.frames(from: t0 - options.before, to: t0 + options.after + 0.2)
        if candidates.isEmpty, let latest = store.latest,
           ProcessInfo.processInfo.systemUptime - latest.time < 3 {
            candidates = [latest]
        }
        let ranked = candidates.sorted { $0.sharpness > $1.sharpness }
        guard var best = ranked.first else {
            return .failure(.noFrames)
        }

        // Belge denetimi: en net üç kareden ilk "belge" olanı seçilir; hiçbiri belge değilse fotoğraf çekilmez
        if options.documentOnly {
            var chosen: StoredFrame?
            var why = ""
            for frame in ranked.prefix(3) {
                guard let m = GuidanceAnalyzer.analyze(frame.buffer) else {
                    chosen = frame                      // ölçülemeyen kareyi engelleme: sayfa kaybetmektense çek
                    break
                }
                let v = DocumentGate.verdict(m)
                if v == .document {
                    chosen = frame
                    break
                }
                why = DocumentGate.describe(m, v)
            }
            guard let accepted = chosen else {
                tlog("[belge] çekim reddedildi: \(why)")
                return .failure(.notDocument(why))
            }
            best = accepted
        }

        var selected = [best]
        if options.multiFrame {
            let similar = candidates
                .filter { $0.id != best.id
                    && $0.sharpness >= best.sharpness * 0.85
                    && FrameAnalysis.difference($0.signature, best.signature) < 2.5 }
                .sorted { $0.sharpness > $1.sharpness }
            selected.append(contentsOf: similar.prefix(3))
        }

        tlog("[çekim] \(candidates.count) aday kare, en net puan \(Int(best.sharpness)), birleştirme için seçilen \(selected.count)")
        guard let rendered = Enhancer.render(buffers: selected.map { $0.buffer }, options: options.enhance) else {
            return .failure(.renderFailed)
        }
        return .success(CapturedPhoto(jpeg: rendered.data, date: Date(), sharpness: best.sharpness,
                                      width: rendered.width, height: rendered.height,
                                      framesUsed: rendered.used, candidates: candidates.count, reason: reason))
    }
}
