import Foundation
import AVFoundation

/// Kulaklığa konuşan küçük sarmalayıcı. Ses YALNIZCA kulaklığa (ya da Bluetooth çıkışa) verilir; çıkış telefon hoparlörüyse
/// söylenecekler hiç okunmaz (GuidanceSpeaker bunu zaten yapar). Mikrofon yoktur: bu program hiçbir şey dinlemez.
@MainActor
final class Voice {
    private let speaker = GuidanceSpeaker()
    /// Son söylenen cümleler (tanı ve ekran için)
    private(set) var lastSaid = ""

    init() {
        speaker.needsPlaybackSession = true
    }

    /// Ayarlardaki ses ve hız
    func configure(voiceID: String, rate: Double) {
        speaker.voiceID = voiceID
        speaker.rateFactor = rate
    }

    /// Kulaklık (ya da telefon hoparlörü dışında bir çıkış) bağlı mı
    var headphonesReady: Bool { return AudioRoute.canPlaySound(AudioRoute.currentOutputs()) }

    var isSpeaking: Bool { return speaker.isSpeaking }

    /// Söyler; konuşma sürüyorsa sıraya girer (`interrupt` true ise sürmekte olanı keser)
    func say(_ text: String, interrupt: Bool = false) {
        let clean = text.trimmed
        guard !clean.isEmpty else { return }
        lastSaid = clean
        speaker.speak(clean, interrupt: interrupt)
        tlog("[konuşma] \(clean)")
    }

    /// Yalnız şu an hiç konuşulmuyorsa söyler (yönlendirme cümleleri üst üste binmesin); söylediyse true
    @discardableResult
    func sayIfIdle(_ text: String) -> Bool {
        guard !speaker.isSpeaking else { return false }
        say(text)
        return true
    }

    /// Söyler ve bitene kadar bekler (en çok `timeout` sn). Çıkış kulaklık değilse söylenmez, hemen döner.
    func sayAndWait(_ text: String, timeout: TimeInterval = 120) async {
        say(text)
        await waitUntilIdle(timeout: timeout)
    }

    func waitUntilIdle(timeout: TimeInterval = 120) async {
        var waited = 0.0
        while speaker.isSpeaking && waited < timeout && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
    }

    func stop() {
        speaker.stop()
    }
}
