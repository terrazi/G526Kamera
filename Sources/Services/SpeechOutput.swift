import Foundation
import AVFoundation

enum SpeakError: Error, Equatable {
    /// Ses yolu güvenli değil (Bluetooth kulaklık yok): hiçbir şey çalınmadı
    case routeUnsafe
    /// Konuşma dışarıdan durduruldu (fail-safe, test sonu)
    case stopped
    case failed(String)
}

/// Modül 5: cevabı sese çevirir, dosyaya kaydeder ve Bluetooth kulaklıktan çalar
@MainActor
protocol AnswerSpeaking: AnyObject {
    /// `text` sese çevrilir. `fileBase` verilirse (uzantısız yol) ses o dosyaya kaydedilir ve AYNI dosya çalınır; dönen değer kaydedilen dosyadır.
    /// `fileBase` nil ise (kısa anonslar) ses geçici dosyaya yazılır, çalınır ve silinir.
    @discardableResult func speak(_ text: String, saveAs fileBase: URL?) async throws -> URL?
    /// Anında susturur; çalan ve bekleyen her şey iptal olur
    func stop()
}

// MARK: - Dosyaya sentez

/// Metni ses dosyasına çeviren motor (Gemini sesi ya da telefonun Apple sesi). Hiçbiri sesi çalmaz; yalnız dosya üretir.
@MainActor
protocol SpeechSynthesizing: AnyObject {
    /// Metni sese çevirip `base` + uzantı dosyasına yazar; yazılan dosyayı döndürür
    func synthesize(_ text: String, to base: URL) async throws -> URL
    /// Süren sentezi iptal eder
    func cancel()
}

enum RenderError: Error, Equatable {
    case empty
    case timeout
}

/// AVSpeechSynthesizer.write tamponlarını dosyaya yazan, iş parçacığı güvenli kutu
private final class RenderSink: @unchecked Sendable {
    private let lock = NSLock()
    private let base: URL
    private var file: AVAudioFile?
    private var url: URL?
    private var frames: Int64 = 0
    private var finished = false
    var completion: ((Result<URL, Error>) -> Void)?

    init(base: URL) {
        self.base = base
    }

    func handle(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        if pcm.frameLength == 0 {
            complete()
            return
        }
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        do {
            if file == nil { try openFile(for: pcm.format) }
            try file?.write(from: pcm)
            frames += Int64(pcm.frameLength)
            lock.unlock()
        } catch {
            lock.unlock()
            fail(error)
        }
    }

    /// Sentez bitti: yazılmış dosya varsa başarı, yoksa boş hatası
    func complete() {
        finish { [self] in
            if frames > 0, let url = url { return .success(url) }
            return .failure(RenderError.empty)
        }
    }

    func fail(_ error: Error) {
        finish { .failure(error) }
    }

    private func finish(_ make: () -> Result<URL, Error>) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let result = make()
        file = nil   // AVAudioFile kapanır, dosya tamamlanır
        let done = completion
        completion = nil
        lock.unlock()
        done?(result)
    }

    /// Önce AAC (.m4a, küçük); olmazsa ham PCM (.caf)
    private func openFile(for format: AVAudioFormat) throws {
        let aacURL = base.appendingPathExtension("m4a")
        let aac: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        do {
            file = try AVAudioFile(forWriting: aacURL, settings: aac,
                                   commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            url = aacURL
        } catch {
            try? FileManager.default.removeItem(at: aacURL)
            let cafURL = base.appendingPathExtension("caf")
            file = try AVAudioFile(forWriting: cafURL, settings: format.settings,
                                   commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            url = cafURL
        }
    }
}

private final class SynthDelegate: NSObject, AVSpeechSynthesizerDelegate {
    private let lock = NSLock()
    private var sink: RenderSink?

    func attach(_ sink: RenderSink?) {
        lock.lock()
        self.sink = sink
        lock.unlock()
    }

    private func current() -> RenderSink? {
        lock.lock()
        defer { lock.unlock() }
        return sink
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        current()?.complete()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        current()?.complete()
    }
}

/// Metni dosyaya çevirir (hoparlörden ses çıkmaz: write yalnız tampon üretir)
@MainActor
final class SpeechRenderer: SpeechSynthesizing {
    static let timeout: TimeInterval = 20

    private let synthesizer = AVSpeechSynthesizer()
    private let delegate = SynthDelegate()
    private let voice: () -> AVSpeechSynthesisVoice?

    init(voice: @escaping () -> AVSpeechSynthesisVoice? = { SpeechVoiceChooser.voice(preferredID: "") }) {
        self.voice = voice
        synthesizer.delegate = delegate
    }

    func synthesize(_ text: String, to base: URL) async throws -> URL {
        return try await render(text, voice: voice(), to: base)
    }

    /// `base`: uzantısız hedef yol. Dönen değer gerçekten yazılan dosyadır (.m4a ya da .caf).
    func render(_ text: String, voice: AVSpeechSynthesisVoice?, to base: URL) async throws -> URL {
        let sink = RenderSink(base: base)
        delegate.attach(sink)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            sink.completion = { continuation.resume(with: $0) }
            synthesizer.write(utterance) { buffer in sink.handle(buffer) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(SpeechRenderer.timeout * 1_000_000_000))
                sink.fail(RenderError.timeout)
            }
        }
    }

    func cancel() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }
}

// MARK: - Dosya çalma

@MainActor
final class AudioFilePlayer: NSObject, AudioFilePlaying, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var completion: (@MainActor (Bool) -> Void)?

    func play(_ url: URL, completion: @escaping @MainActor (Bool) -> Void) {
        stop()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.volume = 1
            guard player.prepareToPlay(), player.play() else {
                completion(false)
                return
            }
            self.player = player
            self.completion = completion
        } catch {
            tlog("[ses] çalınamadı: \(error.localizedDescription)")
            completion(false)
        }
    }

    func stop() {
        let finish = completion
        completion = nil
        player?.delegate = nil
        player?.stop()
        player = nil
        finish?(false)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finished(flag) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.finished(false) }
    }

    private func finished(_ ok: Bool) {
        let done = completion
        completion = nil
        player = nil
        done?(ok)
    }
}

// MARK: - Yedek: canlı konuşma

/// Dosyaya sentez başarısız olursa (bazı sesler `write` desteklemez) cevap yine de okunsun diye canlı konuşma. Dosya kaydedilmez.
@MainActor
final class LiveSynth: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var current: AVSpeechUtterance?
    private var completion: ((Bool) -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, voice: AVSpeechSynthesisVoice?) async -> Bool {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            current = utterance
            completion = { continuation.resume(returning: $0) }
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        finish(nil, false)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish(utterance, true) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish(utterance, false) }
    }

    /// `utterance` nil ise geçerli konuşma bitirilir; değilse yalnız geçerli konuşmaysa (gecikmiş eski bildirimler yok sayılır)
    private func finish(_ utterance: AVSpeechUtterance?, _ ok: Bool) {
        if let utterance = utterance, utterance !== current { return }
        let done = completion
        completion = nil
        current = nil
        done?(ok)
    }
}

// MARK: - Kulaklık konuşmacısı

/// Önce sesi dosyaya sentezler (kaydedilir), sonra AYNI dosyayı AVAudioPlayer ile çalar. Sentez motorları sırayla denenir
/// (ör. Gemini sesi, olmazsa telefonun sesi). Çalmadan hemen önce ses yolu güvenli değilse (Bluetooth kulaklık yok) hiçbir şey çalmaz.
/// Ses `overrideOutputAudioPort` ile hoparlöre ASLA çevrilmez.
@MainActor
final class HeadphoneSpeaker: AnswerSpeaking {
    /// Dosyaya kaydedilecek cevaplar mı (`true`) yoksa kısa anonslar mı (`false`) için sentez motorlarının sırası
    typealias EngineChooser = (_ saving: Bool) -> [SpeechSynthesizing]

    private let player = AudioFilePlayer()
    private let live = LiveSynth()
    private let isRouteSafe: () -> Bool
    private let engines: EngineChooser
    private let voice: () -> AVSpeechSynthesisVoice?
    private var active: [SpeechSynthesizing] = []
    private var generation = 0

    init(isRouteSafe: @escaping () -> Bool,
         engines: @escaping EngineChooser,
         voice: @escaping () -> AVSpeechSynthesisVoice? = { SpeechVoiceChooser.voice(preferredID: "") }) {
        self.isRouteSafe = isRouteSafe
        self.engines = engines
        self.voice = voice
    }

    /// Tekrar modu aynı çalıcıyı kullanır
    var filePlayer: AudioFilePlaying { return player }

    @discardableResult
    func speak(_ text: String, saveAs fileBase: URL?) async throws -> URL? {
        stop()
        let mine = generation
        let target = fileBase ?? FileManager.default.temporaryDirectory.appendingPathComponent("anons-\(UUID().uuidString)")
        let chain = engines(fileBase != nil)
        active = chain
        var rendered: URL?
        for engine in chain {
            guard mine == generation else { break }
            do {
                rendered = try await engine.synthesize(text, to: target)
                break
            } catch {
                tlog("[ses] sentez olmadı (\(error.localizedDescription)); sıradaki motor deneniyor")
            }
        }
        // Sentez sırasında durdurulduysa yarım dosya bırakılmaz
        guard mine == generation else {
            if let url = rendered { try? FileManager.default.removeItem(at: url) }
            throw SpeakError.stopped
        }
        // Kayıt (varsa) dosyada kalır; ama ses yolu güvenli değilse hiçbir şey çalınmaz
        guard isRouteSafe() else {
            if fileBase == nil, let url = rendered { try? FileManager.default.removeItem(at: url) }
            throw SpeakError.routeUnsafe
        }
        if let url = rendered {
            let ok = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                player.play(url) { continuation.resume(returning: $0) }
            }
            if fileBase == nil { try? FileManager.default.removeItem(at: url) }
            guard ok else { throw mine == generation ? SpeakError.failed("Ses çalınamadı.") : SpeakError.stopped }
            return fileBase == nil ? nil : url
        }
        // Hiçbir motor dosya üretemedi: cevap yine de okunsun diye canlı konuşma (dosya kaydedilmez)
        let ok = await live.speak(text, voice: voice())
        guard ok else { throw mine == generation ? SpeakError.failed("Ses okunamadı.") : SpeakError.stopped }
        return nil
    }

    func stop() {
        generation += 1
        player.stop()
        live.stop()
        active.forEach { $0.cancel() }
    }
}
