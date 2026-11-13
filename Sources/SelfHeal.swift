import Foundation
import Network

/// İnternet var mı kararı: ardışık yoklamalardan. Saf mantıktır (zaman dışarıdan verilir), kolayca sınanır.
struct OfflineTracker {
    enum Action: Equatable {
        case none
        /// İnternet yok: kullanıcıya haber ver (bir kesinti için bir kez)
        case warn
        /// İnternet yok ve onarım (hücresel yenileme kestirmesi) denenmeli
        case repair
        /// İnternet geri geldi
        case recovered
    }

    /// Üst üste bu kadar yoklama başarısızsa "internet yok" denir
    var failuresToWarn = 2
    /// Kestirme, internet bu kadar "sayılan" yoklamada art arda yoksa çalışır (Ayarlar; varsayılan 3)
    var repairChecks = 3
    /// İki sayılan yoklama arası en az bu kadar saniye (Ayarlar; varsayılan 60). Yoklama daha sık yapılsa da sayılan yoklamalar
    /// bu aralıkla sayılır: "1'er dakika arayla 3 yoklamada internet yoksa kestirme çalışsın"
    var checkInterval: TimeInterval = 60
    /// İki onarım denemesi arası en az bu kadar saniye (Ayarlar; varsayılan 60)
    var repairCooldown: TimeInterval = 60
    /// Bir kesinti süresince en çok bu kadar onarım denemesi
    var maxRepairsPerOutage = 3

    /// Zamanlayıcı birkaç yüz ms oynayabilir ("60 sn" yoklaması 59,9'da gelirse bir tur kaybolmasın): süre karşılaştırmasında bu pay tanınır
    static let slack: TimeInterval = 2

    private(set) var failures = 0
    private(set) var counted = 0
    private(set) var warned = false
    private(set) var repairs = 0
    private var lastRepair: TimeInterval?
    private var lastCounted: TimeInterval?

    /// Uygulama arka plana geçince (kestirme çalışırken de geçer) yoklama sayacı ve uyarı sıfırlanır; deneme sayısı, sayılan
    /// yoklamalar ve bekleme süresi KORUNUR: yoksa her kestirme dönüşünde sayaç sıfırlanır ve kestirme sonsuza dek yeniden çalışırdı.
    mutating func suspend() {
        failures = 0
        warned = false
    }

    mutating func record(online: Bool, now: TimeInterval, canRepair: Bool) -> Action {
        if online {
            let wasDown = warned
            failures = 0
            counted = 0
            lastCounted = nil
            warned = false
            repairs = 0
            lastRepair = nil
            return wasDown ? .recovered : .none
        }
        failures += 1
        if lastCounted.map({ now - $0 >= checkInterval - OfflineTracker.slack }) ?? true {
            counted += 1
            lastCounted = now
        }
        guard failures >= failuresToWarn else { return .none }
        let due = lastRepair.map { now - $0 >= repairCooldown - OfflineTracker.slack } ?? true
        if canRepair && counted >= repairChecks && repairs < maxRepairsPerOutage && due {
            repairs += 1
            lastRepair = now
            warned = true
            return .repair
        }
        if !warned {
            warned = true
            return .warn
        }
        return .none
    }
}

/// Ses motoru sağlığı: tampon geliyor mu, mikrofon tamamen sessiz mi. Sessiz kalmak (komut gelmemesi) hata sayılmaz;
/// yalnız ses motorundan hiç veri gelmemesi ya da mikrofonun uzun süre sayısal sıfır vermesi bakılır.
enum AudioHealth {
    enum Verdict: Equatable {
        case ok
        /// Motor çalışıyor görünüyor ama tampon gelmiyor: yeniden kurulmalı
        case noBuffers
        /// Tamponlar geliyor ama hepsi sıfır: mikrofon kapalı / sessizde / bağlantısı kopuk
        case silent
    }

    /// Bu süre boyunca tampon gelmezse motor ölü sayılır
    static let bufferTimeout: TimeInterval = 8
    /// Bu süre boyunca bütün örnekler sıfırsa mikrofon sessiz sayılır
    static let silenceTimeout: TimeInterval = 90
    /// Bundan küçük tepe değeri "sıfır" sayılır
    static let signalFloor: Float = 0.0005

    static func evaluate(now: TimeInterval, engineRunning: Bool, startedAt: TimeInterval,
                         lastBuffer: TimeInterval?, lastSignal: TimeInterval?) -> Verdict {
        guard engineRunning else { return .ok }
        let sinceStart = now - startedAt
        if let last = lastBuffer {
            if now - last > bufferTimeout { return .noBuffers }
        } else if sinceStart > bufferTimeout {
            return .noBuffers
        }
        let signalRef = lastSignal ?? startedAt
        if sinceStart > silenceTimeout && now - signalRef > silenceTimeout { return .silent }
        return .ok
    }

    /// Tamponun en büyük mutlak örnek değeri (0...1); 16 bit tamponlarda ölçeklenir
    static func peak(of samples: UnsafePointer<Float>, count: Int) -> Float {
        var m: Float = 0
        for i in 0..<count {
            let v = abs(samples[i])
            if v > m { m = v }
        }
        return m
    }
}

/// Kullanıcının Kestirmeler uygulamasında yaptığı kestirmeleri çalıştıran bağlantı (Kestirmeler uygulamasının URL şeması).
/// İki kestirme vardır; adları Ayarlar'dan yazılır, ad boşsa o kestirme kapalıdır:
/// bağlantı kestirmesi (hücresel veriyi kapat-aç) ve ses kestirmesi (Bluetooth'u kapat-aç).
enum ShortcutKind: String {
    case connection = "baglanti"
    case audio = "ses"
    case camera = "kamera"

    var title: String {
        switch self {
        case .connection: return "Bağlantı"
        case .audio: return "Ses"
        case .camera: return "Kamera"
        }
    }
}

enum ShortcutLink {
    static let callbackScheme = "g526kamera"
    /// Kullanıcının bir kez Kestirmeler uygulamasında yapacağı yardımcı kestirmenin adı: kestirmelerin listesini gösterir, seçilen adı
    /// g526kamera://sec?tur=baglanti&ad=… bağlantısıyla uygulamaya geri gönderir (iOS uygulamalara kestirme listesini vermez)
    static let pickerName = "G526 Kestirme Seç"

    /// Yardımcı kestirmeyi çalıştırır; girdi olarak hangi kestirmenin seçileceğini ("baglanti" / "ses") verir
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

/// Ses motoru yeniden başlatmalarının art arda kaçıncı olduğunu sayar. Son yeniden başlatmadan beri `healthyGap` sn'den
/// uzun süre geçtiyse ses sağlıklı sayılır ve sayaç sıfırlanır. Böylece bekleme süresi, sorun sürdükçe uzar ve sürekli
/// yeniden başlatma (ses servisini yoran döngü) oluşmaz.
struct RestartStreak {
    static let healthyGap: TimeInterval = 60
    private(set) var count = 0
    private var last: TimeInterval?

    /// Yeni bir yeniden başlatmayı sayar; art arda kaçıncı olduğunu döndürür
    mutating func note(now: TimeInterval) -> Int {
        if let last = last, now - last > RestartStreak.healthyGap { count = 0 }
        count += 1
        last = now
        return count
    }
}

/// Aynı onarımın arka arkaya çalıştırılmasını sınırlar: iki deneme arası en az `cooldown` sn, bir arıza süresince en çok
/// `maxTries` deneme; sorun giderilince (`reset`) sayaç sıfırlanır. Saf mantıktır (zaman dışarıdan verilir).
struct RepairThrottle {
    var cooldown: TimeInterval
    var maxTries: Int
    private(set) var tries = 0
    private var last: TimeInterval?

    init(cooldown: TimeInterval, maxTries: Int) {
        self.cooldown = cooldown
        self.maxTries = maxTries
    }

    /// allow çağrılsaydı izin verilir miydi (deneme sayılmaz)
    func wouldAllow(now: TimeInterval) -> Bool {
        guard tries < maxTries else { return false }
        if let last = last, now - last < cooldown { return false }
        return true
    }

    /// true: şimdi denenebilir (deneme sayılır)
    mutating func allow(now: TimeInterval) -> Bool {
        guard tries < maxTries else { return false }
        if let last = last, now - last < cooldown { return false }
        tries += 1
        last = now
        return true
    }

    mutating func reset() {
        tries = 0
        last = nil
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

/// Ağ yolu bilgisi (yalnız teşhis için): hangi arayüzler var, internet "Wi-Fi" üzerinden mi gidiyor, hücreseller doğrudan ulaşıyor mu.
/// Kameranın internetsiz Wi-Fi ağında iOS istekleri hücresele yönlendirmezse internet yoklaması başarısız olur; bu bilgi onu ayırt eder.
enum NetworkPathInfo {
    private final class Once { var fired = false }

    static func interfaceName(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi: return "Wi-Fi"
        case .cellular: return "hücresel"
        case .wiredEthernet: return "kablolu"
        case .loopback: return "yerel"
        default: return "diğer"
        }
    }

    static func statusName(_ status: NWPath.Status) -> String {
        switch status {
        case .satisfied: return "var"
        case .unsatisfied: return "yok"
        case .requiresConnection: return "bağlantı gerekiyor"
        @unknown default: return "bilinmiyor"
        }
    }

    /// Örn. "ağ yolu: internet var; arayüzler: Wi-Fi, hücresel; ilk tercih: Wi-Fi"
    static func describe() async -> String {
        return await withCheckedContinuation { cont in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "g526.pathinfo")
            let once = Once()
            func finish(_ text: String) {
                if once.fired { return }
                once.fired = true
                monitor.cancel()
                cont.resume(returning: text)
            }
            monitor.pathUpdateHandler = { path in
                let names = path.availableInterfaces.map { interfaceName($0.type) }
                let first = path.availableInterfaces.first.map { interfaceName($0.type) } ?? "yok"
                finish("ağ yolu: internet \(statusName(path.status)); arayüzler: \(names.isEmpty ? "yok" : names.joined(separator: ", ")); ilk tercih: \(first)")
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 2) { finish("ağ yolu bilgisi alınamadı") }
        }
    }

    /// Yalnız hücresel arayüzden bir TCP bağlantısı açılabiliyor mu (internet hücreselde var mı)
    static func cellularReachable(timeout: TimeInterval = 8) async -> Bool {
        return await withCheckedContinuation { cont in
            let params = NWParameters.tcp
            params.requiredInterfaceType = .cellular
            let conn = NWConnection(host: "www.gstatic.com", port: 443, using: params)
            let queue = DispatchQueue(label: "g526.cellprobe")
            let once = Once()
            func finish(_ ok: Bool) {
                if once.fired { return }
                once.fired = true
                conn.cancel()
                cont.resume(returning: ok)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed: finish(false)
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }
}

/// Isınma: iOS "ciddi" ya da "kritik" derse program yükünü azaltır
enum ThermalGuard {
    static func isHot(_ state: ProcessInfo.ThermalState) -> Bool {
        return state == .serious || state == .critical
    }
}
