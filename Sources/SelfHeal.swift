import Foundation

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
    /// İki onarım denemesi arası en az bu kadar saniye
    var repairCooldown: TimeInterval = 600
    /// Bir kesinti süresince en çok bu kadar onarım denemesi
    var maxRepairsPerOutage = 3

    private(set) var failures = 0
    private(set) var warned = false
    private(set) var repairs = 0
    private var lastRepair: TimeInterval?

    mutating func record(online: Bool, now: TimeInterval, canRepair: Bool) -> Action {
        if online {
            let wasDown = warned
            failures = 0
            warned = false
            repairs = 0
            lastRepair = nil
            return wasDown ? .recovered : .none
        }
        failures += 1
        guard failures >= failuresToWarn else { return .none }
        let due = lastRepair.map { now - $0 >= repairCooldown } ?? true
        if canRepair && repairs < maxRepairsPerOutage && due {
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
enum ShortcutLink {
    static let callbackScheme = "g526kamera"

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

/// İnternet yoklaması: küçük bir "204" adresine istek; kameranın internetsiz Wi-Fi ağında da doğru sonuç verir
enum InternetProbe {
    static let address = "https://www.gstatic.com/generate_204"

    static func isOnline() async -> Bool {
        guard let url = URL(string: address) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 6
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return code == 204 || code == 200
        } catch {
            return false
        }
    }
}

/// Isınma: iOS "ciddi" ya da "kritik" derse program yükünü azaltır
enum ThermalGuard {
    static func isHot(_ state: ProcessInfo.ThermalState) -> Bool {
        return state == .serious || state == .critical
    }
}
