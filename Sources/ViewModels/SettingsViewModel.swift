import Foundation
import UIKit

/// "Anahtarı dene" sonucu
struct KeyTestResult: Equatable {
    var ok: Bool
    var text: String
}

/// Ayarlar ekranının ViewModel'i: her profilin anahtarını yapıştır / dene, kayıt klasörünü seç, kestirmeleri dene
@MainActor
final class SettingsViewModel: ObservableObject {
    /// Profil numarası (1…4) → son "Anahtarı dene" / yapıştırma sonucu
    @Published var keyResults: [Int: KeyTestResult] = [:]
    /// Şu an denenen profil (0 = yok)
    @Published var testingKeySlot = 0
    @Published var shortcutResults: [RecoveryStep: String] = [:]
    @Published var runningShortcut: RecoveryStep?
    /// Profil numarası → anahtarın gördüğü, metin üretebilen modeller ("Modelleri listele")
    @Published var modelLists: [Int: [String]] = [:]
    /// Şu an modelleri listelenen profil (0 = yok)
    @Published var listingModelsSlot = 0
    @Published var folderStatus = ""
    @Published var folderMessage = ""

    let settings: AppSettings
    let folder: FolderStore
    private let shortcuts: ShortcutRunning
    /// Oturum sürerken klasör değiştirilemez (yazılmakta olan dosyaların yeri değişmesin)
    private let sessionActive: () -> Bool

    init(settings: AppSettings, shortcuts: ShortcutRunning, folder: FolderStore = FolderStore(),
         sessionActive: @escaping () -> Bool = { false }) {
        self.settings = settings
        self.shortcuts = shortcuts
        self.folder = folder
        self.sessionActive = sessionActive
        folderStatus = folder.statusText()
    }

    // MARK: Gemini anahtarları

    func pasteKey(slot: Int) {
        guard (1...GeminiProfiles.slotCount).contains(slot) else { return }
        guard let key = GeminiKey.cleanedKey(fromClipboard: UIPasteboard.general.string) else {
            keyResults[slot] = KeyTestResult(ok: false, text: "Panoda anahtar bulunamadı.")
            return
        }
        settings.geminiKeys[slot - 1] = key
        let problem = GeminiKey.keyShapeProblem(key)
        keyResults[slot] = KeyTestResult(ok: problem == nil, text: problem ?? "Yapıştırıldı. “Anahtarı dene” ile sınayın.")
    }

    func testKey(slot: Int) async {
        guard let profile = settings.geminiProfileInfos().first(where: { $0.slot == slot }) else { return }
        guard !profile.key.isEmpty else {
            keyResults[slot] = KeyTestResult(ok: false, text: Say.noKeyShort)
            return
        }
        guard !profile.model.isEmpty else {
            keyResults[slot] = KeyTestResult(ok: false, text: "Önce model adını yazın.")
            return
        }
        testingKeySlot = slot
        keyResults[slot] = KeyTestResult(ok: true, text: "Google'a soruluyor…")
        defer { testingKeySlot = 0 }
        let client = GeminiClient(key: { profile.key }, model: { profile.model })
        let header = await client.probeKey(model: profile.model, key: profile.key, viaQuery: false)
        var query: KeyProbe?
        if GeminiKey.isKeyRejection(header) { query = await client.probeKey(model: profile.model, key: profile.key, viaQuery: true) }
        let result = GeminiKey.keyProbeText(model: profile.model, key: profile.key, header: header, query: query)
        keyResults[slot] = KeyTestResult(ok: result.ok, text: result.text)
    }

    /// Anahtarın görebildiği modelleri Google'dan getirir; yanlış yazılmış model adı böylece seçilerek düzeltilir
    func listModels(slot: Int) async {
        guard let profile = settings.geminiProfileInfos().first(where: { $0.slot == slot }), !profile.key.isEmpty else {
            keyResults[slot] = KeyTestResult(ok: false, text: Say.noKeyShort)
            return
        }
        listingModelsSlot = slot
        defer { listingModelsSlot = 0 }
        keyResults[slot] = KeyTestResult(ok: true, text: "Modeller Google'a soruluyor…")
        let client = GeminiClient(key: { profile.key }, model: { profile.model })
        do {
            let names = try await client.listModels()
            modelLists[slot] = names
            keyResults[slot] = names.isEmpty
                ? KeyTestResult(ok: false, text: "Bu anahtarın görebildiği, metin üretebilen model bulunamadı.")
                : KeyTestResult(ok: true, text: "\(names.count) model bulundu. “Model seç”ten birini seçin.")
        } catch let error as GeminiError {
            keyResults[slot] = KeyTestResult(ok: false, text: error.message)
        } catch {
            keyResults[slot] = KeyTestResult(ok: false, text: error.localizedDescription)
        }
    }

    func chooseModel(_ name: String, slot: Int) {
        guard (1...GeminiProfiles.slotCount).contains(slot) else { return }
        settings.geminiProfiles[slot - 1].model = name
        keyResults[slot] = KeyTestResult(ok: true, text: "Model: \(name). “Anahtarı dene” ile sınayın.")
    }

    // MARK: Kayıt klasörü

    func refreshFolderStatus() {
        if !sessionActive() { folder.refresh() }
        folderStatus = folder.statusText()
    }

    func chooseFolder() {
        folderMessage = ""
        guard !sessionActive() else {
            folderMessage = "Test sürerken klasör değiştirilemez. Önce testi bitirin."
            return
        }
        let opened = FolderPicker.shared.present(onPick: { [weak self] url in self?.folderPicked(url) })
        if !opened { folderMessage = "Klasör seçici açılamadı. Uygulamayı kapatıp yeniden açın." }
    }

    private func folderPicked(_ url: URL) {
        do {
            try folder.choose(url)
            folderMessage = ""
        } catch {
            folderMessage = "Klasör hatırlanamadı: \(error.localizedDescription)"
        }
        folderStatus = folder.statusText()
    }

    func writeFolderTest() {
        do {
            let url = try folder.writeTestFile()
            folderMessage = "Yazıldı: \(url.lastPathComponent). Dosyalar uygulamasında klasöre bakıp görüp görmediğinizi kontrol edin."
        } catch {
            folderMessage = "Yazılamadı: \(error.localizedDescription)"
        }
        folderStatus = folder.statusText()
    }

    // MARK: Kestirmeler

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
