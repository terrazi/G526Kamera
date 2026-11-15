import Foundation

/// Kameranın pil bilgisi. Kamera yüzde vermez; her görüntü karesinin başlığında 5 kademe ve "şarjda" bayrağı gönderir
/// (LookCam'in pil simgesi de bu değerden çizilir).
enum CameraBatteryLevel: Equatable {
    /// 0 (bitmek üzere) … 4 (dolu)
    case level(Int)
    /// Şarjda / dış güçte
    case charging

    /// Şarj düşük mü (kademe 0 ya da 1)
    var isLow: Bool {
        if case .level(let n) = self { return n <= 1 }
        return false
    }

    /// Tahmini yüzde aralığı (alt, üst). 5 kademe eşit beşe bölünmüş varsayılır; kamera gerçek yüzdeyi vermez, bu yalnız tahmindir.
    var estimatedRange: (low: Int, high: Int)? {
        if case .level(let n) = self { return (n * 20, n * 20 + 20) }
        return nil
    }

    /// Ekranda kısa gösterim
    var shortText: String {
        switch self {
        case .charging: return "Kamera şarjda"
        case .level(let n): return "Kamera pili ≈ %\(n * 20)–\(n * 20 + 20)"
        }
    }
}

enum CameraBattery {
    /// Kare başlığında pil değerinin (float32, küçük sonlu) yeri
    static let headerOffset = 25
    /// Şarjda / dış güç kodu
    static let chargingCode = 99

    /// Başlıktaki değeri kademeye çevirir. Kod 1…5 → kademe 0…4, 99 → şarjda; 0 ya da başka bir değer → bilinmiyor (nil).
    static func decode(header: [UInt8]) -> CameraBatteryLevel? {
        guard header.count >= headerOffset + 4 else { return nil }
        var bits: UInt32 = 0
        for k in 0..<4 { bits |= UInt32(header[headerOffset + k]) << UInt32(8 * k) }
        let value = Float(bitPattern: bits)
        guard value.isFinite, value >= 0, value < 1000 else { return nil }
        return decode(code: Int(value))      // kesirli kısım atılır (kameranın kendi uygulaması gibi)
    }

    static func decode(code: Int) -> CameraBatteryLevel? {
        if code == chargingCode { return .charging }
        if (1...5).contains(code) { return .level(code - 1) }
        return nil
    }

    /// Sesli rapordaki cümle parçası. Kamera yüzde vermediği için aralık söylenir ve "tahminen" denir.
    static func phrase(_ level: CameraBatteryLevel) -> String {
        switch level {
        case .charging: return "kamera şarjda"
        case .level(let n):
            switch n {
            case 4...: return "kamera şarjı tahminen yüzde 80'in üzerinde"
            case 0: return "kamera şarjı tahminen yüzde 20'nin altında, kapanabilir"
            default: return "kamera şarjı tahminen yüzde \(n * 20) ile \(n * 20 + 20) arasında"
            }
        }
    }

    /// Kendiliğinden söylenen düşük şarj uyarısı (`level`: 0 ya da 1)
    static func lowWarning(level: Int) -> String {
        if level <= 0 { return "Kamera şarjı tahminen yüzde 20'nin altında, kapanabilir. Kamerayı şarja takın." }
        return "Kamera şarjı tahminen yüzde 20 ile 40 arasında, düşük. Kamerayı şarja takın."
    }
}

/// Her karenin başlığından gelen pil değerini süzer: aynı değer art arda `stableFrames` kare görülmeden kabul edilmez
/// (bozuk tek bir kare yanlış uyarı vermesin). Kareler ağ iş parçacığında geldiği için kilitlidir.
final class CameraBatteryMonitor {
    static let stableFrames = 8
    /// Bu süreden eski değer güncel sayılmaz (kamera kopmuş olabilir)
    static let maxAge: TimeInterval = 60

    private let lock = NSLock()
    private var candidate: CameraBatteryLevel?
    private var count = 0
    private var stable: CameraBatteryLevel?
    private var lastSeen: TimeInterval = 0

    /// Bir kare başlığı verir. Kabul edilen değer değiştiyse yeni değeri döndürür, yoksa nil.
    func feed(header: [UInt8], now: TimeInterval) -> CameraBatteryLevel? {
        guard let value = CameraBattery.decode(header: header) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        lastSeen = now
        if value == candidate {
            count = min(count + 1, 1000)
        } else {
            candidate = value
            count = 1
        }
        if count >= Self.stableFrames && value != stable {
            stable = value
            return value
        }
        return nil
    }

    /// Şu an geçerli (yeterince yeni) pil bilgisi
    func current(now: TimeInterval) -> CameraBatteryLevel? {
        lock.lock()
        defer { lock.unlock() }
        guard let s = stable, now - lastSeen <= Self.maxAge else { return nil }
        return s
    }

    func reset() {
        lock.lock()
        candidate = nil
        count = 0
        stable = nil
        lastSeen = 0
        lock.unlock()
    }
}

/// Kamera şarjı düşünce her kademede (1, sonra 0) yalnız bir kez uyarmak için karar verir; şarja takılınca ya da kademe 2'ye çıkınca sıfırlanır.
struct CameraLowBatteryWatcher {
    private var announced = 5

    /// Uyarılacaksa kademeyi (0 ya da 1) döndürür
    mutating func update(_ level: CameraBatteryLevel) -> Int? {
        switch level {
        case .charging:
            announced = 5
            return nil
        case .level(let n):
            if n >= 2 {
                announced = 5
                return nil
            }
            if n < announced {
                announced = n
                return n
            }
            return nil
        }
    }
}
