import Foundation

/// Kullanıcının Kestirmeler uygulamasında yaptığı kestirmeleri çalıştıran bağlantı (Kestirmeler uygulamasının URL şeması).
/// İki kestirme vardır; adları Ayarlar'dan yazılır, ad boşsa o kestirme kapalıdır:
/// kamera kestirmesi (kameranın Wi-Fi ağına bağlanır) ve internet kestirmesi (Wi-Fi'ı kapatıp hücresel veriyi açar).
enum ShortcutKind: String {
    case connection = "baglanti"
    case camera = "kamera"

    var title: String {
        switch self {
        case .connection: return "İnternet"
        case .camera: return "Kamera"
        }
    }
}

enum ShortcutLink {
    static let callbackScheme = "g526kamera"
    /// Kullanıcının bir kez Kestirmeler uygulamasında yapacağı yardımcı kestirmenin adı: kestirmelerin listesini gösterir, seçilen adı
    /// g526kamera://sec?tur=baglanti&ad=… bağlantısıyla uygulamaya geri gönderir (iOS uygulamalara kestirme listesini vermez)
    static let pickerName = "G526 Kestirme Seç"

    /// Yardımcı kestirmeyi çalıştırır; girdi olarak hangi kestirmenin seçileceğini ("baglanti" / "kamera") verir
    static func pickerURL(kind: ShortcutKind) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#?/:")
        guard let name = pickerName.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "shortcuts://run-shortcut?name=\(name)&input=text&text=\(kind.rawValue)")
    }

    /// Yardımcı kestirmeden dönen bağlantı: g526kamera://sec?tur=baglanti&ad=H%C3%BCcresel%20Yenile → (bağlantı, "Hücresel Yenile")
    static func selection(from url: URL) -> (kind: ShortcutKind, name: String)? {
        guard url.scheme == callbackScheme, url.host == "sec",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let kindText = items.first(where: { $0.name == "tur" })?.value,
              let kind = ShortcutKind(rawValue: kindText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()),
              let rawName = items.first(where: { $0.name == "ad" })?.value else { return nil }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : (kind, name)
    }

    /// shortcuts://x-callback-url/run-shortcut?name=…: kestirme bitince uygulamaya geri dönülür
    static func url(name: String) -> URL? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#?/:")
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        let back = "\(callbackScheme)://kestirme"
        return URL(string: "shortcuts://x-callback-url/run-shortcut?name=\(encoded)&x-success=\(back)&x-cancel=\(back)&x-error=\(back)")
    }
}

/// İnternet yoklaması: küçük "204" adreslerine istek; kameranın internetsiz Wi-Fi ağında da doğru sonuç verir.
/// Tek adrese ve 6 sn'ye bağlı kalınmaz: soğuk hücresel bağlantı (DNS + TLS) birkaç saniye sürebilir, tek adres engelli olabilir.
enum InternetProbe {
    struct Target: Equatable {
        let url: String
        let okCodes: [Int]
        var host: String { return URL(string: url)?.host ?? url }
    }

    static let targets = [
        Target(url: "https://www.gstatic.com/generate_204", okCodes: [204, 200]),
        Target(url: "https://captive.apple.com/hotspot-detect.html", okCodes: [200]),
        Target(url: "https://www.google.com/generate_204", okCodes: [204, 200])
    ]
    static let address = targets[0].url
    static let timeout: TimeInterval = 10

    static func isOnline() async -> Bool {
        return await check().online
    }

    /// İlk adres olmazsa diğer ikisi aynı anda denenir; biri olursa internet var. Olmazsa kısa neden döner ("gstatic.com hata -1001, …").
    static func check() async -> (online: Bool, detail: String) {
        let first = await attempt(targets[0])
        if first.ok { return (true, "") }
        var reasons = ["\(targets[0].host) \(first.reason)"]
        let others = Array(targets.dropFirst())
        let result: (Bool, [String]) = await withTaskGroup(of: (Bool, String).self) { group in
            for t in others {
                group.addTask {
                    let r = await attempt(t)
                    return (r.ok, "\(t.host) \(r.reason)")
                }
            }
            var list: [String] = []
            for await r in group {
                if r.0 {
                    group.cancelAll()
                    return (true, [])
                }
                list.append(r.1)
            }
            return (false, list)
        }
        if result.0 { return (true, "") }
        reasons.append(contentsOf: result.1)
        return (false, reasons.joined(separator: ", "))
    }

    private static func attempt(_ target: Target) async -> (ok: Bool, reason: String) {
        guard let url = URL(string: target.url) else { return (false, "adres hatalı") }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return target.okCodes.contains(code) ? (true, "") : (false, "kod \(code)")
        } catch {
            return (false, "hata \((error as NSError).code)")
        }
    }
}
