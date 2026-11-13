import Foundation
import Combine

/// Ayarlar ekranındaki değerler. Modül 1: başlama saati, Gemini API anahtarı, 3 kestirme adı. Modül 6: tekrar boşluğu.
/// Anahtar Keychain'de, diğerleri UserDefaults'ta saklanır.
final class AppSettings: ObservableObject {
    enum Key {
        static let startEnabled = "v3.startEnabled"
        static let startMinutes = "v3.startMinutes"
        static let shortcutWifi = "v3.shortcut.wifi"
        static let shortcutCellular = "v3.shortcut.cellular"
        static let shortcutReset = "v3.shortcut.reset"
        static let replayGap = "v3.replayGap"
        static let sendAudio = "v3.sendAudio"
        static let geminiVoice = "v3.geminiVoice"
    }

    static let apiKeyName = "geminiKeyV3"
    /// Tekrar modunda iki cevap arasındaki boşluk (sn): Ayarlar'daki kaydırıcının aralığı
    static let replayGapRange: ClosedRange<Double> = 0...10
    static let defaultReplayGap: Double = 3
    static let defaultStartMinutes = 9 * 60

    private let defaults: UserDefaults

    /// Zamanlı başlatma açık mı (kapalıyken saat dikkate alınmaz)
    @Published var startEnabled: Bool {
        didSet { defaults.set(startEnabled, forKey: Key.startEnabled) }
    }

    /// Başlama saati: gece yarısından beri geçen dakika (0...1439)
    @Published var startMinutes: Int {
        didSet {
            let fixed = AppSettings.clampMinutes(startMinutes)
            if fixed != startMinutes { startMinutes = fixed; return }
            defaults.set(startMinutes, forKey: Key.startMinutes)
        }
    }

    @Published var wifiShortcut: String {
        didSet { defaults.set(wifiShortcut, forKey: Key.shortcutWifi) }
    }

    @Published var cellularShortcut: String {
        didSet { defaults.set(cellularShortcut, forKey: Key.shortcutCellular) }
    }

    @Published var resetShortcut: String {
        didSet { defaults.set(resetShortcut, forKey: Key.shortcutReset) }
    }

    /// Tekrar modunda iki cevap arasında beklenecek saniye (0...10)
    @Published var replayGap: Double {
        didSet {
            let fixed = AppSettings.clampGap(replayGap)
            if fixed != replayGap { replayGap = fixed; return }
            defaults.set(replayGap, forKey: Key.replayGap)
        }
    }

    /// Soru sesi de Gemini'ye gönderilsin mi (dikte metniyle birlikte; ses asıl kaynak olur)
    @Published var sendAudio: Bool {
        didSet { defaults.set(sendAudio, forKey: Key.sendAudio) }
    }

    /// Cevaplar Gemini'nin ses modeliyle mi okunsun (kapalıysa telefonun sesi)
    @Published var geminiVoice: Bool {
        didSet { defaults.set(geminiVoice, forKey: Key.geminiVoice) }
    }

    @Published var apiKey: String {
        didSet { Keychain.set(apiKey.trimmed, for: AppSettings.apiKeyName) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        startEnabled = defaults.bool(forKey: Key.startEnabled)
        startMinutes = AppSettings.clampMinutes(defaults.object(forKey: Key.startMinutes) as? Int ?? AppSettings.defaultStartMinutes)
        wifiShortcut = defaults.string(forKey: Key.shortcutWifi) ?? ""
        cellularShortcut = defaults.string(forKey: Key.shortcutCellular) ?? ""
        resetShortcut = defaults.string(forKey: Key.shortcutReset) ?? ""
        replayGap = AppSettings.clampGap(defaults.object(forKey: Key.replayGap) as? Double ?? AppSettings.defaultReplayGap)
        sendAudio = defaults.object(forKey: Key.sendAudio) as? Bool ?? true
        geminiVoice = defaults.object(forKey: Key.geminiVoice) as? Bool ?? true
        apiKey = Keychain.get(AppSettings.apiKeyName) ?? ""
    }

    // MARK: Yardımcılar

    static func clampMinutes(_ minutes: Int) -> Int {
        return min(max(minutes, 0), 24 * 60 - 1)
    }

    static func clampGap(_ seconds: Double) -> Double {
        return min(max(seconds, replayGapRange.lowerBound), replayGapRange.upperBound)
    }

    static func timeText(minutes: Int) -> String {
        let m = clampMinutes(minutes)
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    /// DatePicker için: başlama saati bugünün bir saati olarak
    var startTime: Date {
        get {
            return Calendar.current.date(bySettingHour: startMinutes / 60, minute: startMinutes % 60, second: 0, of: Date()) ?? Date()
        }
        set {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            startMinutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
    }

    /// Adımın kestirme adı (boşluklar kırpılmış; boşsa o adım kapalıdır)
    func shortcutName(for step: RecoveryStep) -> String {
        switch step {
        case .wifi: return wifiShortcut.trimmed
        case .cellular: return cellularShortcut.trimmed
        case .reset: return resetShortcut.trimmed
        }
    }

    /// Adı yazılmamış kestirmeler
    var missingShortcuts: [RecoveryStep] {
        return RecoveryStep.allCases.filter { shortcutName(for: $0).isEmpty }
    }
}
