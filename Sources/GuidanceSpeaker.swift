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
    /// `onSpeakingChange(false)` geldiğinde: konuşma kesilmeden sonuna kadar okundu mu (kesildi, iptal edildi ya da bitiş haberi gelmedi → false).
    /// Yalnız SON okunan cümlenin akıbeti sayılır: araya girip eskisini kesen yeni cümle tam okunduysa sonuç temizdir.
    private(set) var endedCleanly = true

    /// Şu an (ya da sırada) söylenecek cümle var mı
    var isSpeaking: Bool { return !inFlight.isEmpty }

    private let synth = AVSpeechSynthesizer()
    /// Sentezleyiciye verilip henüz bitmemiş cümleler (kimlikle izlenir: gecikmiş eski bildirimler yeni okumayı bitmiş göstermesin)
    private var inFlight = Set<ObjectIdentifier>()
    private var lastUtterance: AVSpeechUtterance?
    private var lastCleanly = true
    private var generation = 0

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String, interrupt: Bool = false) {
        if interrupt && (synth.isSpeaking || !inFlight.isEmpty) {
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
        inFlight.insert(ObjectIdentifier(utterance))
        lastUtterance = utterance
        lastCleanly = true
        if inFlight.count == 1 {
            onSpeakingChange?(true)
        }
        recent.append(text)
        if recent.count > 20 { recent.removeFirst(recent.count - 20) }
        synth.speak(utterance)

        // Bitiş bildirimi gelmezse (ses çıkışı yok, kesinti) susturma sonsuza dek sürmesin.
        // Süre okuma hızına göre uzar; süre dolduğunda ses hâlâ çıkıyorsa (uzun cevap, yavaş okuma) beklemek yeterince uzatılır.
        generation += 1
        let slow = min(max(rateFactor, 0.6), 1.0)
        let limit = Double(text.count) * 0.12 / slow + 4.0
        armWatchdog(generation, after: limit, extensionsLeft: 2, extra: limit * 0.5)
    }

    private func armWatchdog(_ mine: Int, after seconds: Double, extensionsLeft: Int, extra: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self = self, self.generation == mine, !self.inFlight.isEmpty else { return }
            if self.synth.isSpeaking && extensionsLeft > 0 {
                self.armWatchdog(mine, after: extra, extensionsLeft: extensionsLeft - 1, extra: extra)
                return
            }
            self.inFlight.removeAll()
            self.endedCleanly = false
            self.onSpeakingChange?(false)
        }
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
    }

    private func finished(_ utterance: AVSpeechUtterance, cancelled: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.inFlight.remove(ObjectIdentifier(utterance)) != nil else { return }
            if utterance === self.lastUtterance { self.lastCleanly = !cancelled }
            if self.inFlight.isEmpty {
                self.endedCleanly = self.lastCleanly
                self.onSpeakingChange?(false)
            }
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finished(utterance, cancelled: false)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finished(utterance, cancelled: true)
    }
}
