import Foundation
import AVFoundation

/// Sesli yönlendirmeyi Türkçe sentezleyen küçük sarmalayıcı. Konuşma sürerken `onSpeakingChange(true)`,
/// sıradaki bütün cümleler bitince `onSpeakingChange(false)` çağrılır; konuşma tanıma bu sürede kendi
/// sesimizi duymasın diye susturulur.
final class GuidanceSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    var onSpeakingChange: ((Bool) -> Void)?
    /// Konuşma tanıma çalışmıyorsa ses oturumunu biz hazırlarız (sessiz anahtarı çalmayı engellemesin)
    var needsPlaybackSession = false
    /// Kullanıcının seçtiği ses (boş = telefonda kurulu en kaliteli Türkçe ses)
    var voiceID = ""
    /// Okuma hızı çarpanı (1 = varsayılan hız)
    var rateFactor = 1.0
    /// Son söylenen cümleler (tanı ve test için)
    private(set) var recent: [String] = []
    /// `onSpeakingChange(false)` geldiğinde: konuşma kesilmeden sonuna kadar okundu mu (kesildi, iptal edildi ya da bitiş haberi gelmedi → false)
    private(set) var endedCleanly = true
    private var interrupted = false

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
        if interrupt && (synth.isSpeaking || pending > 0) {
            interrupted = true
            synth.stopSpeaking(at: .immediate)
        }
        // Ses oturumu çalma yapabilen bir türde değilse (varsayılan tür sessiz anahtara uyar ve sesi keser) çalma oturumu aç
        let session = AVAudioSession.sharedInstance()
        let playable = session.category == .playAndRecord || session.category == .playback
        if needsPlaybackSession || !playable {
            try? session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
            try? session.setActive(true)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = SpeechVoiceChooser.voice(preferredID: voiceID)
        let rate = AVSpeechUtteranceDefaultSpeechRate * 1.05 * Float(min(max(rateFactor, 0.6), 1.5))
        utterance.rate = min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
        utterance.volume = 1.0
        utterance.postUtteranceDelay = 0.05
        pending += 1
        if pending == 1 {
            interrupted = false
            onSpeakingChange?(true)
        }
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
            self.endedCleanly = false
            self.onSpeakingChange?(false)
        }
    }

    func stop() {
        if pending > 0 { interrupted = true }
        synth.stopSpeaking(at: .immediate)
    }

    private func finished() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.pending > 0 else { return }
            self.pending -= 1
            if self.pending == 0 {
                self.endedCleanly = !self.interrupted
                self.onSpeakingChange?(false)
            }
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { finished() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in self?.interrupted = true }
        finished()
    }
}
