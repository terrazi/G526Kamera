import Foundation
import UIKit

/// Ayarlar ekranının ViewModel'i: anahtarı yapıştır / dene, kestirmeleri dene
@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var keyResult = ""
    @Published var keyResultOK = false
    @Published var testingKey = false
    @Published var shortcutResults: [RecoveryStep: String] = [:]
    @Published var runningShortcut: RecoveryStep?

    let settings: AppSettings
    private let shortcuts: ShortcutRunning

    init(settings: AppSettings, shortcuts: ShortcutRunning) {
        self.settings = settings
        self.shortcuts = shortcuts
    }

    func pasteKey() {
        guard let key = GeminiKey.cleanedKey(fromClipboard: UIPasteboard.general.string) else {
            keyResult = "Panoda anahtar bulunamadı."
            keyResultOK = false
            return
        }
        settings.apiKey = key
        keyResult = GeminiKey.keyShapeProblem(key) ?? "Yapıştırıldı. “Anahtarı dene” ile sınayın."
        keyResultOK = GeminiKey.keyShapeProblem(key) == nil
    }

    func testKey() async {
        let key = settings.apiKey.trimmed
        guard !key.isEmpty else {
            keyResult = Say.noKeyShort
            keyResultOK = false
            return
        }
        testingKey = true
        defer { testingKey = false }
        let model = GeminiAnswerService.models[0]
        let client = GeminiClient(key: { key }, model: { model })
        let header = await client.probeKey(model: model, key: key, viaQuery: false)
        var query: KeyProbe?
        if GeminiKey.isKeyRejection(header) { query = await client.probeKey(model: model, key: key, viaQuery: true) }
        let result = GeminiKey.keyProbeText(model: model, key: key, header: header, query: query)
        keyResult = result.text
        keyResultOK = result.ok
    }

    func testShortcut(_ step: RecoveryStep) async {
        let name = settings.shortcutName(for: step)
        guard !name.isEmpty else {
            shortcutResults[step] = "Önce kestirmenin adını yazın."
            return
        }
        runningShortcut = step
        defer { runningShortcut = nil }
        shortcutResults[step] = SettingsViewModel.text(for: await shortcuts.run(name: name))
    }

    static func text(for outcome: ShortcutOutcome) -> String {
        switch outcome {
        case .success: return "✓ Kestirme çalıştı ve uygulamaya döndü."
        case .cancelled: return "Kestirme iptal edildi."
        case .failed(let message): return "✗ Kestirme çalışmadı" + (message.isEmpty ? "." : ": \(message)")
        case .timedOut: return "Kestirme açıldı ama geri dönüş gelmedi (adı doğru mu, Kestirmeler'de var mı?)."
        case .notConfigured: return "Önce kestirmenin adını yazın."
        }
    }
}
