import Foundation
import Vision

/// OCR (yazı okuma) sabitleri. Telefonu yavaşlatmamak ve kilitlememek için sınırlar burada.
enum OcrConfig {
    static let timeout: TimeInterval = 30       // bir fotoğrafın OCR'ı en fazla bu kadar sürer
    static let slowSeconds: TimeInterval = 20   // bundan uzun süren iş "yavaş" sayılır
    static let maxSlow = 2                      // bu kadar yavaş iş olursa OCR kapanır
    static let maxFailures = 3                  // art arda bu kadar hata olursa OCR kapanır
    static let maxQueue = 4
    static let uploadWait: TimeInterval = 25    // yükleme, OCR bitsin diye en fazla bu kadar bekler
}

/// Vision ile tek bir JPEG'deki yazıyı okur. Arka plan önceliğinde çalışır; süre aşılırsa istek iptal edilir.
enum OcrRecognizer {
    enum OcrError: Error {
        case timeout
        case failed(String)
    }

    private final class Once<T> {
        private let lock = NSLock()
        private var done = false
        private let handler: (T) -> Void
        init(_ handler: @escaping (T) -> Void) { self.handler = handler }
        func finish(_ value: T) {
            lock.lock()
            if done { lock.unlock(); return }
            done = true
            lock.unlock()
            handler(value)
        }
    }

    /// Bu cihazda tanınabilen dillerden, Latin harfli ve Türkçe harfleri en iyi koruyanları seçer.
    static func chooseLanguages(_ request: VNRecognizeTextRequest) -> (chosen: [String], supported: [String]) {
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let wish = ["tr-TR", "en-US", "de-DE", "fr-FR"]
        let chosen = wish.filter { w in supported.contains { $0.lowercased() == w.lowercased() } }
        return (chosen, supported)
    }

    static func recognize(url: URL, timeout: TimeInterval, languages: [String]? = nil) async -> Result<String, OcrError> {
        return await withCheckedContinuation { (continuation: CheckedContinuation<Result<String, OcrError>, Never>) in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false      // Türkçe için İngilizce düzeltme sözcükleri bozar
            #if targetEnvironment(simulator)
            // Sanal makinede (GitHub Actions) GPU/Neural Engine yok; iste yalnız işlemciyi kullan, yoksa istek takılır.
            // Gerçek telefonda bu satır derlenmez, Apple'ın kendi seçimi kullanılır.
            request.usesCPUOnly = true
            #endif
            let langs = languages ?? chooseLanguages(request).chosen
            if !langs.isEmpty { request.recognitionLanguages = langs }

            let once = Once<Result<String, OcrError>> { continuation.resume(returning: $0) }
            DispatchQueue.global(qos: .background).async {
                do {
                    try VNImageRequestHandler(url: url, options: [:]).perform([request])
                    let observations = (request.results ?? []).sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
                    let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                    once.finish(.success(lines.joined(separator: "\n")))
                } catch {
                    once.finish(.failure(.failed(error.localizedDescription)))
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                request.cancel()
                once.finish(.failure(.timeout))
            }
        }
    }
}

/// İsteğe bağlı OCR: sonuç, fotoğrafın yanına "<ad>.jpg.txt" olarak yazılır; PDF oluşturulurken sonuna metin sayfaları eklenir.
/// Tek iş, en çok `OcrConfig.maxQueue` bekleyen iş; cihaz ısındıysa ya da düşük güç modundaysa atlanır;
/// art arda hata ya da aşırı yavaşlıkta kendini kapatır (fotoğraf çekme ve Drive'a gönderme etkilenmez).
@MainActor
final class OcrCenter: ObservableObject {
    static let shared = OcrCenter()

    @Published private(set) var status = ""
    private(set) var disabledReason = ""
    private var queue: [URL] = []
    private var current: URL?
    private var running = false
    private var failures = 0
    private var slow = 0
    private var languagesLogged = false
    private var firstRun = true             // ilk okuma modeli yüklediği için daha uzun sürebilir
    private let settings = AppSettings.shared

    nonisolated static func sidecar(_ url: URL) -> URL { url.appendingPathExtension("txt") }

    nonisolated static func readText(_ url: URL) -> String {
        return (try? String(contentsOf: sidecar(url), encoding: .utf8)) ?? ""
    }

    nonisolated static func clean(_ raw: String) -> String {
        var out: [String] = []
        var blank = 0
        for line in raw.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            blank = trimmed.isEmpty ? blank + 1 : 0
            if blank <= 1 { out.append(trimmed) }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var enabled: Bool { settings.ocrEnabled && disabledReason.isEmpty }

    func reset() {
        disabledReason = ""
        failures = 0
        slow = 0
        updateStatus()
    }

    func submit(_ url: URL) {
        guard enabled else { return }
        while queue.count >= OcrConfig.maxQueue {
            let dropped = queue.removeFirst()
            tlog("[ocr] kuyruk dolu, atlandı: \(dropped.lastPathComponent)")
        }
        queue.append(url)
        updateStatus()
        if !running {
            running = true
            Task { await self.loop() }
        }
    }

    func isPending(_ url: URL) -> Bool {
        return queue.contains(url) || current == url
    }

    /// Verilen dosyaların OCR'ı bitene (ya da süre dolana) kadar bekler.
    func waitFor(_ urls: [URL], timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && urls.contains(where: { isPending($0) }) {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func updateStatus() {
        if !settings.ocrEnabled { status = ""; return }
        if !disabledReason.isEmpty { status = "OCR kapalı: " + disabledReason; return }
        status = (current != nil || !queue.isEmpty) ? "OCR: metin okunuyor…" : "OCR açık"
    }

    private func disable(_ reason: String) {
        disabledReason = reason
        queue.removeAll()
        tlog("[ocr] kapatıldı: \(reason)")
        updateStatus()
    }

    private func loop() async {
        while !queue.isEmpty {
            let url = queue.removeFirst()
            current = url
            updateStatus()
            await process(url)
            current = nil
        }
        running = false
        updateStatus()
    }

    private func process(_ url: URL) async {
        guard enabled, FileManager.default.fileExists(atPath: url.path) else { return }
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .serious || thermal == .critical || ProcessInfo.processInfo.isLowPowerModeEnabled {
            tlog("[ocr] cihaz ısınmış ya da düşük güç modunda, atlandı: \(url.lastPathComponent)")
            return
        }
        if !languagesLogged {
            languagesLogged = true
            let probe = VNRecognizeTextRequest()
            probe.recognitionLevel = .accurate
            let info = OcrRecognizer.chooseLanguages(probe)
            tlog("[ocr] Vision dilleri: \(info.supported.joined(separator: ", ")) — seçilen: \(info.chosen.joined(separator: ", "))")
        }
        let started = Date()
        let isFirst = firstRun
        firstRun = false
        let outcome = await OcrRecognizer.recognize(url: url, timeout: isFirst ? OcrConfig.timeout * 2 : OcrConfig.timeout)
        let elapsed = Date().timeIntervalSince(started)
        switch outcome {
        case .success(let raw):
            failures = 0
            let text = OcrCenter.clean(raw)
            do {
                try text.write(to: OcrCenter.sidecar(url), atomically: true, encoding: .utf8)
            } catch {
                tlog("[ocr] metin yazılamadı: \(error.localizedDescription)")
                return
            }
            tlog("[ocr] \(url.lastPathComponent): \(text.count) karakter, \(String(format: "%.1f", elapsed)) sn")
            if !isFirst && elapsed > OcrConfig.slowSeconds {
                slow += 1
                if slow >= OcrConfig.maxSlow { disable("çok yavaş (\(OcrConfig.maxSlow) kez \(Int(OcrConfig.slowSeconds)) sn'den uzun)") }
            }
        case .failure(let error):
            failures += 1
            switch error {
            case .timeout: tlog("[ocr] \(url.lastPathComponent) süre aşımı (\(Int(OcrConfig.timeout)) sn), atlandı")
            case .failed(let m): tlog("[ocr] \(url.lastPathComponent) okunamadı: \(m)")
            }
            if failures >= OcrConfig.maxFailures { disable("art arda \(OcrConfig.maxFailures) hata/süre aşımı") }
        }
    }
}
