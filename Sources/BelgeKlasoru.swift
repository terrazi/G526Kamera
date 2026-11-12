import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Dosya adı: oluşturulma anı, yıl-ay-gün-saat-dakika-saniye (örnek 20261112091245)
enum FileStamp {
    static func stamp(_ date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMddHHmmss"
        return f.string(from: date)
    }

    /// 20261112091245.pdf; aynı adda dosya varsa 20261112091245-2.pdf, -3 ...
    static func uniqueName(stamp: String, ext: String, exists: (String) -> Bool) -> String {
        let e = ext.hasPrefix(".") ? String(ext.dropFirst()) : ext
        var name = "\(stamp).\(e)"
        var n = 2
        while exists(name) {
            name = "\(stamp)-\(n).\(e)"
            n += 1
        }
        return name
    }
}

struct DocumentFolderError: LocalizedError {
    let message: String
    var errorDescription: String? { return message }
}

/// Programın silinmesinden etkilenmeyen, kullanıcının seçtiği tek belge klasörü ("G526 Belgeler").
/// iOS bir programa kendi klasörü dışında yazma izni ancak kullanıcı klasörü seçerse verir;
/// seçim bir yer imi (bookmark) olarak saklanır.
final class DocumentFolder {
    static let shared = DocumentFolder()
    static let folderName = "G526 Belgeler"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "documentFolderBookmark") {
        self.defaults = defaults
        self.key = key
    }

    var hasChoice: Bool { return defaults.data(forKey: key) != nil }

    /// Seçici ekranından gelen klasörü hatırlar
    func choose(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(data, forKey: key)
    }

    func forget() {
        defaults.removeObject(forKey: key)
    }

    private func resolved() throws -> URL {
        guard let data = defaults.data(forKey: key) else {
            throw DocumentFolderError(message: "Belge klasörü seçilmedi.")
        }
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            throw DocumentFolderError(message: "Seçilen klasöre ulaşılamıyor (silinmiş ya da taşınmış olabilir). Klasörü yeniden seçin.")
        }
        if stale { try? choose(url) }
        return url
    }

    /// Klasöre erişim açıkken işi yapar (iş bitince erişim kapanır)
    func withAccess<T>(_ body: (URL) throws -> T) throws -> T {
        let url = try resolved()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DocumentFolderError(message: "Belge klasörü bulunamadı. Klasörü yeniden seçin.")
        }
        return try body(url)
    }

    /// Verilen dosyanın kopyasını zaman damgalı adla klasöre koyar (kaynak dosya silinmez)
    @discardableResult
    func store(file source: URL, ext: String, date: Date = Date()) throws -> URL {
        return try withAccess { dir in
            let target = dir.appendingPathComponent(Self.freeName(in: dir, ext: ext, date: date))
            try FileManager.default.copyItem(at: source, to: target)
            return target
        }
    }

    /// Verilen içeriği zaman damgalı adla klasöre yazar
    @discardableResult
    func store(data: Data, ext: String, date: Date = Date()) throws -> URL {
        return try withAccess { dir in
            let target = dir.appendingPathComponent(Self.freeName(in: dir, ext: ext, date: date))
            try data.write(to: target, options: .atomic)
            return target
        }
    }

    private static func freeName(in dir: URL, ext: String, date: Date) -> String {
        return FileStamp.uniqueName(stamp: FileStamp.stamp(date), ext: ext) {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
    }

    /// Klasöre gerçekten yazılabiliyor mu: nil = evet, değilse Türkçe neden
    func probe() -> String? {
        do {
            try withAccess { dir in
                let test = dir.appendingPathComponent(".g526-deneme-\(UUID().uuidString)")
                try Data("x".utf8).write(to: test)
                try FileManager.default.removeItem(at: test)
            }
            return nil
        } catch let error as DocumentFolderError {
            return error.message
        } catch {
            return "Klasöre yazılamadı: \(error.localizedDescription)"
        }
    }

    /// Seçilen klasörün adı (ekranda göstermek için)
    func displayName() -> String? {
        return try? withAccess { $0.lastPathComponent }
    }

    /// Ayarlar ekranındaki tek satırlık durum
    func statusText() -> String {
        guard hasChoice else { return "Klasör seçilmedi" }
        if let problem = probe() { return problem }
        return "\(displayName() ?? Self.folderName): yazılabiliyor"
    }
}

/// Klasör seçici (Dosyalar uygulaması)
struct FolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { return Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
}

/// Ayarlarda "Belge klasörü" bölümü: seç, durum, deneme dosyası yaz
struct DocumentFolderSection: View {
    @State private var picking = false
    @State private var status = DocumentFolder.shared.statusText()
    @State private var message = ""

    var body: some View {
        Section(header: Text("Belge klasörü"),
                footer: Text("Dosyalar uygulamasında “Bu iPhone” altında “G526 Belgeler” adlı yeni bir klasör açıp seçin. Sınav dosyaları (PDF, video) buraya kaydedilir; program silinse de kalır.")) {
            HStack {
                Text("Durum")
                Spacer()
                Text(status)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            Button("Klasör seç") { picking = true }
            Button("Deneme dosyası yaz") { writeTest() }
                .disabled(!DocumentFolder.shared.hasChoice)
            if !message.isEmpty {
                Text(message).font(.footnote)
            }
        }
        .sheet(isPresented: $picking) {
            FolderPicker { url in
                picking = false
                do {
                    try DocumentFolder.shared.choose(url)
                    message = ""
                } catch {
                    message = "Klasör hatırlanamadı: \(error.localizedDescription)"
                }
                status = DocumentFolder.shared.statusText()
            }
        }
        .onAppear { status = DocumentFolder.shared.statusText() }
    }

    private func writeTest() {
        do {
            let text = "G526 deneme dosyası. Bu dosyayı silebilirsiniz.\n"
            let url = try DocumentFolder.shared.store(data: Data(text.utf8), ext: "txt")
            message = "Yazıldı: \(url.lastPathComponent). Dosyalar uygulamasında klasöre bakıp görüp görmediğinizi kontrol edin."
        } catch {
            message = "Yazılamadı: \(error.localizedDescription)"
        }
        status = DocumentFolder.shared.statusText()
    }
}
