import Foundation
import AVFoundation

/// Sesli yönlendirmeyi Türkçe sentezleyen küçük sarmalayıcı. Konuşma sürerken `onSpeakingChange(true)`,
/// sıradaki bütün cümleler bitince `onSpeakingChange(false)` çağrılır; konuşma tanıma bu sürede kendi
/// sesimizi duymasın diye susturulur.
final class GuidanceSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    var onSpeakingChange: ((Bool) -> Void)?
    /// Konuşma tanıma çalışmıyorsa ses oturumunu biz hazırlarız (sessiz anahtarı çalmayı engellemesin)
    var needsPlaybackSession = false
    /// Son söylenen cümleler (tanı ve test için)
    private(set) var recent: [String] = []

    /// Şu an (ya da sırada) söylenecek cümle var mı
    var isSpeaking: Bool { return pending > 0 }

    private let synth = AVSpeechSynthesizer()
    private var pending = 0
    private var generation = 0

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String, interrupt: Bool = false) {
        if interrupt && (synth.isSpeaking || pending > 0) { synth.stopSpeaking(at: .immediate) }
        if needsPlaybackSession {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
            try? session.setActive(true)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "tr-TR")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        utterance.volume = 1.0
        utterance.postUtteranceDelay = 0.05
        pending += 1
        if pending == 1 { onSpeakingChange?(true) }
        recent.append(text)
        if recent.count > 20 { recent.removeFirst(recent.count - 20) }
        synth.speak(utterance)

        // Bitiş bildirimi gelmezse (ses çıkışı yok, kesinti) susturma sonsuza dek sürmesin
        generation += 1
        let mine = generation
        let limit = Double(text.count) * 0.12 + 4.0
        DispatchQueue.main.asyncAfter(deadline: .now() + limit) { [weak self] in
            guard let self = self, self.generation == mine, self.pending > 0 else { return }
            self.pending = 0
            self.onSpeakingChange?(false)
        }
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
    }

    private func finished() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.pending > 0 else { return }
            self.pending -= 1
            if self.pending == 0 { self.onSpeakingChange?(false) }
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { finished() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { finished() }
}
