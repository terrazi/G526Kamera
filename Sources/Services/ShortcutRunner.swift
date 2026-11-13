import Foundation
import UIKit

enum ShortcutOutcome: Equatable {
    case success
    case cancelled
    case failed(String)
    /// Kestirme açıldı ama süre içinde geri dönüş gelmedi
    case timedOut
    /// Kestirme adı boş
    case notConfigured
}

/// Kestirmeler uygulamasının x-callback-url bağlantıları (Modül 4)
enum ShortcutLink {
    static let scheme = "g526kamera"
    /// Kestirme bitince Kestirmeler'in uygulamaya dönmek için açtığı adresler
    static let successURL = "\(scheme)://kestirme/ok"
    static let cancelURL = "\(scheme)://kestirme/iptal"
    static let errorURL = "\(scheme)://kestirme/hata"

    /// Adreste (RFC 3986) kaçışsız kalabilecek karakterler; Türkçe harfler de yüzde-kodlanır
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ text: String) -> String {
        return text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    /// shortcuts://x-callback-url/run-shortcut?name=…&x-success=…&x-cancel=…&x-error=…
    static func runURL(name: String) -> URL? {
        let trimmed = name.trimmed
        guard !trimmed.isEmpty else { return nil }
        let text = "shortcuts://x-callback-url/run-shortcut?name=\(encode(trimmed))"
            + "&x-success=\(encode(successURL))&x-cancel=\(encode(cancelURL))&x-error=\(encode(errorURL))"
        return URL(string: text)
    }

    enum Callback: Equatable {
        case success
        case cancelled
        case failed(String)
    }

    /// g526kamera://kestirme/ok | /iptal | /hata?errorMessage=… → geri dönüş türü (başka adres nil)
    static func callback(from url: URL) -> Callback? {
        guard url.scheme == scheme, url.host == "kestirme" else { return nil }
        switch url.lastPathComponent {
        case "ok": return .success
        case "iptal": return .cancelled
        case "hata":
            let message = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "errorMessage" })?.value ?? ""
            return .failed(message)
        default: return nil
        }
    }

    /// g526kamera://basla: zamanlı başlatma (Kestirmeler'deki "Günün saati" otomasyonu bu adresi açar)
    static func isStartURL(_ url: URL) -> Bool {
        return url.scheme == scheme && url.host == "basla"
    }
}

@MainActor
protocol ShortcutRunning: AnyObject {
    func run(name: String) async -> ShortcutOutcome
    /// Kestirmeler'den dönen adresi işler; bu bir kestirme dönüşüyse true
    @discardableResult func handleCallback(_ url: URL) -> Bool
}

/// Kestirmeyi çalıştırır: Kestirmeler uygulaması öne gelir, iş bitince x-success ile bu uygulamaya döner.
/// (Telefon kilitliyken ya da uygulama arka plandayken iOS başka uygulama açtırmaz; oturum boyunca ekran açık tutulur.)
@MainActor
final class ShortcutRunner: ShortcutRunning {
    /// Geri dönüş gelmezse beklenecek en uzun süre (sn)
    var timeout: TimeInterval = 30

    private var pending: CheckedContinuation<ShortcutOutcome, Never>?
    private var token = 0
    /// Kestirme, `open` dönmeden önce biten çok hızlı bir kestirme olabilir: geri dönüş o sırada gelirse burada saklanır
    private var opening = false
    private var earlyOutcome: ShortcutOutcome?

    func run(name: String) async -> ShortcutOutcome {
        guard let url = ShortcutLink.runURL(name: name) else { return .notConfigured }
        if pending != nil { finish(.cancelled) }
        opening = true
        earlyOutcome = nil
        let opened = await UIApplication.shared.open(url)
        opening = false
        guard opened else { return .failed("Kestirmeler uygulaması açılamadı") }
        if let early = earlyOutcome {
            earlyOutcome = nil
            return early
        }
        token += 1
        let mine = token
        return await withCheckedContinuation { (continuation: CheckedContinuation<ShortcutOutcome, Never>) in
            pending = continuation
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                try? await Task.sleep(nanoseconds: UInt64(self.timeout * 1_000_000_000))
                if self.token == mine { self.finish(.timedOut) }
            }
        }
    }

    @discardableResult
    func handleCallback(_ url: URL) -> Bool {
        guard let callback = ShortcutLink.callback(from: url) else { return false }
        switch callback {
        case .success: finish(.success)
        case .cancelled: finish(.cancelled)
        case .failed(let message): finish(.failed(message))
        }
        return true
    }

    private func finish(_ outcome: ShortcutOutcome) {
        guard let continuation = pending else {
            if opening { earlyOutcome = outcome }
            return
        }
        pending = nil
        token += 1
        continuation.resume(returning: outcome)
    }
}
