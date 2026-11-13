import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Kullanıcının Dosyalar uygulamasında seçtiği kayıt klasörü (cevap sesleri ve cevaplar.txt buraya gider).
/// iOS bir uygulamaya kendi klasörü dışında yazma izni ancak kullanıcı klasörü seçerse verir; seçim bir yer imi (bookmark)
/// olarak saklanır. Klasör uygulamanın dışında olduğundan uygulama silinse de dosyalar kalır.
final class FolderStore {
    enum State: Equatable {
        case notChosen
        case unavailable(String)
        case ready(URL)
    }

    /// Dosyalar uygulamasında açılması önerilen klasörün adı
    static let suggestedName = "Sesli Kontrol Cevaplar"

    private let defaults: UserDefaults
    private let key: String
    private var accessing: URL?
    private(set) var state: State = .notChosen

    init(defaults: UserDefaults = .standard, key: String = "v3.folderBookmark") {
        self.defaults = defaults
        self.key = key
        refresh()
    }

    deinit { stopAccess() }

    var hasChoice: Bool { return defaults.data(forKey: key) != nil }

    /// Seçici ekranından gelen klasörü hatırlar
    func choose(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(data, forKey: key)
        refresh()
    }

    func forget() {
        defaults.removeObject(forKey: key)
        refresh()
    }

    /// Yer imini çözer, klasöre erişimi açık tutar (oturum boyunca dosyalar okunup yazılır) ve gerçekten yazılabiliyor mu bakar
    func refresh() {
        stopAccess()
        guard let data = defaults.data(forKey: key) else {
            state = .notChosen
            return
        }
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            state = .unavailable("Seçilen klasöre ulaşılamıyor (silinmiş ya da taşınmış olabilir). Klasörü yeniden seçin.")
            return
        }
        if url.startAccessingSecurityScopedResource() { accessing = url }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            fail("Kayıt klasörü bulunamadı. Klasörü yeniden seçin.")
            return
        }
        if let problem = FolderStore.writeProblem(in: url) {
            fail(problem)
            return
        }
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(fresh, forKey: key)
        }
        state = .ready(url)
    }

    private func fail(_ message: String) {
        stopAccess()
        state = .unavailable(message)
    }

    private func stopAccess() {
        if let url = accessing { url.stopAccessingSecurityScopedResource() }
        accessing = nil
    }

    /// Klasöre yazılabiliyor mu: nil = evet, değilse Türkçe neden
    static func writeProblem(in dir: URL) -> String? {
        let test = dir.appendingPathComponent(".sesli-kontrol-deneme-\(UUID().uuidString)")
        do {
            try Data("x".utf8).write(to: test)
            try FileManager.default.removeItem(at: test)
            return nil
        } catch {
            return "Klasöre yazılamadı: \(error.localizedDescription)"
        }
    }

    /// Kayıtlar için kullanılacak kök: seçili klasör hazırsa o, değilse uygulamanın kendi klasörü ve sebebini anlatan uyarı
    func resolution(fallback: URL = AnswerLibrary.documentsDirectory) -> AnswerLibrary.Resolution {
        switch state {
        case .ready(let url):
            return (url: url, warning: nil)
        case .notChosen:
            return (url: fallback, warning: "Kayıt klasörü seçilmedi: cevaplar uygulamanın kendi klasörüne kaydediliyor ve uygulama silinirse gider. Ayarlar > Kayıt klasörü'nden klasör seçin.")
        case .unavailable(let message):
            return (url: fallback, warning: "\(message) Şimdilik uygulamanın kendi klasörü kullanılıyor.")
        }
    }

    /// Ayarlar ekranındaki tek satırlık durum
    func statusText() -> String {
        switch state {
        case .notChosen: return "Klasör seçilmedi"
        case .unavailable(let message): return message
        case .ready(let url): return "\(url.lastPathComponent): yazılabiliyor"
        }
    }

    /// Seçilen klasöre küçük bir deneme dosyası yazar (Dosyalar uygulamasında görülüp görülmediği kontrol edilsin diye)
    func writeTestFile(date: Date = Date()) throws -> URL {
        guard case .ready(let dir) = state else {
            throw NSError(domain: "FolderStore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Önce klasör seçin."])
        }
        let url = dir.appendingPathComponent("deneme.txt")
        let text = "Sesli Kontrol deneme dosyası (\(date)). Bu dosyayı silebilirsiniz.\n"
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }
}

/// Klasör seçici (Dosyalar uygulaması). SwiftUI "sheet" yerine doğrudan UIKit'ten, en üstteki ekranın üzerine açılır;
/// çünkü Ayarlar zaten bir sayfa içinde ve iç içe sayfada seçici kendiliğinden kapanabiliyor.
@MainActor
final class FolderPicker: NSObject, UIDocumentPickerDelegate {
    static let shared = FolderPicker()
    private var onPick: ((URL) -> Void)?
    private var onCancel: (() -> Void)?

    static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap { $0.windows }
        let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    /// Seçiciyi açar; açılamazsa false
    @discardableResult
    func present(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void = {}) -> Bool {
        guard let top = FolderPicker.topController() else { return false }
        self.onPick = onPick
        self.onCancel = onCancel
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        top.present(picker, animated: true)
        return true
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let handler = onPick
        onPick = nil
        onCancel = nil
        if let url = urls.first { handler?(url) }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        let handler = onCancel
        onPick = nil
        onCancel = nil
        handler?()
    }
}
