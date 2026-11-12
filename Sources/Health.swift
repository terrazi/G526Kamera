import Foundation
import UIKit

/// 10 saniyede bir alınan sağlık örneği (ısı, bellek, takılma, pil)
struct HealthSample: Codable, Equatable {
    var time: Double       // 1970'ten beri saniye
    var thermal: Int       // 0 normal, 1 hafif, 2 ciddi, 3 kritik
    var memoryMB: Int      // programın bellek kullanımı (MB); bilinmiyorsa -1
    var stallMs: Int       // bu aralıkta ekranın en uzun donuk kaldığı süre (ms)
    var battery: Int       // yüzde; bilinmiyorsa -1
    var lowPower: Bool
}

struct HealthEvent: Codable, Equatable {
    var time: Double
    var text: String
}

struct HealthStore: Codable, Equatable {
    var samples: [HealthSample] = []
    var events: [HealthEvent] = []
}

/// Saf hesaplar (birim testle denenir)
enum HealthMath {
    static let stallThresholdMs = 1000        // bundan uzun donukluk "takılma" sayılır
    static let sampleCap = 360                // 10 sn × 360 = son 1 saat
    static let eventCap = 60
    /// Art arda bu kadar beklenmedik kapanıştan sonra program "hafif mod"da açılır (önizleme kapalı, yük az)
    static let safeModeAfterUncleanExits = 2
    static let safeModeSeconds = 600.0

    static func needsSafeMode(uncleanStreak: Int) -> Bool { return uncleanStreak >= safeModeAfterUncleanExits }

    static let hangThresholdMs = 3000         // bundan uzun donukluk raporda ayrı olay olarak yazılır (son işlemle birlikte)

    /// Ekran uzun süre donuk kaldığında rapora yazılan olay metni; son işlem biliniyorsa eklenir
    static func hangText(ms: Int, activity: String) -> String {
        let seconds = String(format: "%.1f", Double(ms) / 1000).replacingOccurrences(of: ".", with: ",")
        let tail = activity.isEmpty ? "" : " (son işlem: \(activity))"
        return "ekran \(seconds) sn donuk kaldı\(tail)"
    }

    static func thermalLevel(_ state: ProcessInfo.ThermalState) -> Int {
        switch state {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        @unknown default: return 1
        }
    }

    static func thermalName(_ level: Int) -> String {
        switch level {
        case 0: return "normal"
        case 1: return "hafif ısınmış"
        case 2: return "ciddi ısınmış"
        default: return "kritik"
        }
    }

    static func seconds(_ ms: Int) -> String {
        return String(format: "%.1f sn", Double(ms) / 1000.0)
    }

    static func clock(_ t: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    /// Ekranda ve panoya kopyalanan rapor
    static func summary(_ store: HealthStore, previous: HealthStore?, previousUnclean: Bool) -> String {
        var lines: [String] = []
        let s = store.samples
        if s.isEmpty {
            lines.append("Sağlık raporu: henüz örnek yok (ilk örnek 10 saniye sonra alınır).")
        } else {
            let minutes = max(1, Int((s.last!.time - s.first!.time) / 60.0 + 0.5))
            lines.append("Sağlık raporu (son \(minutes) dk, \(s.count) örnek)")
            let last = s.last!
            let worstThermal = s.map { $0.thermal }.max() ?? 0
            lines.append("Isı: şu an \(thermalName(last.thermal)); en yüksek \(thermalName(worstThermal))")
            let mem = s.map { $0.memoryMB }.filter { $0 >= 0 }
            if let peak = mem.max() {
                lines.append("Bellek: şu an \(last.memoryMB) MB; en yüksek \(peak) MB")
            }
            let stalled = s.filter { $0.stallMs >= stallThresholdMs }
            let longest = s.map { $0.stallMs }.max() ?? 0
            lines.append("Takılma (1 sn üstü): \(stalled.count) aralıkta; en uzunu \(seconds(longest))")
            var power = last.battery >= 0 ? "Pil: %\(last.battery)" : "Pil: bilinmiyor"
            if last.lowPower { power += " (düşük güç modu açık)" }
            lines.append(power)
        }
        if !store.events.isEmpty {
            lines.append("Olaylar:")
            for e in store.events.suffix(12) {
                lines.append("  \(clock(e.time)) \(e.text)")
            }
        }
        if previousUnclean {
            if let p = previous?.samples.last {
                lines.append("Önceki kullanım beklenmedik kapanmış. Son örnek \(clock(p.time)): ısı \(thermalName(p.thermal)), bellek \(p.memoryMB) MB, takılma \(seconds(p.stallMs)).")
            } else {
                lines.append("Önceki kullanım beklenmedik kapanmış (kayıt bulunamadı).")
            }
            if let events = previous?.events.suffix(5), !events.isEmpty {
                lines.append("Önceki kullanımın son olayları:")
                for e in events { lines.append("  \(clock(e.time)) \(e.text)") }
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Son bir dakikadaki takılmaları sayar
struct StallTracker {
    static let window = 60.0
    private var times: [Double] = []

    mutating func record(at time: Double) {
        times.append(time)
        prune(now: time)
    }

    mutating func count(now: Double) -> Int {
        prune(now: now)
        return times.count
    }

    private mutating func prune(now: Double) {
        times.removeAll { now - $0 > Self.window }
    }
}

/// Yük azaltma kararları
enum LoadGuard {
    static let stallsToShed = 3               // 1 dakikada bu kadar takılma olursa
    static let holdSeconds = 300.0            // yük azaltma en az bu kadar sürer
    static let memoryTrimMB = 1100            // bellek bu değeri aşarsa kare belleği boşaltılır
    static let trimCooldown = 30.0
    static let memoryCriticalMB = 1500        // bellek bu değeri aşarsa yük hemen azaltılır, video kaydı kapatılır (iOS programı kapatmasın)

    static func shedForStalls(count: Int) -> Bool { return count >= stallsToShed }
    static func memoryCritical(_ memoryMB: Int) -> Bool { return memoryMB >= memoryCriticalMB }
    static func shouldTrimMemory(memoryMB: Int, sinceLastTrim: Double) -> Bool {
        return memoryMB >= memoryTrimMB && sinceLastTrim >= trimCooldown
    }
}

/// Telefonun boş yer koruması: yer azalınca uyarır, çok azalınca video kaydını durdurur (dolu disk telefonu da yavaşlatır)
enum DiskGuard {
    static let lowMB = 1500
    static let criticalMB = 400

    enum Level: Equatable { case ok, low, critical }

    /// freeMB < 0: ölçülemedi (sorun sayılmaz)
    static func level(freeMB: Int) -> Level {
        if freeMB < 0 { return .ok }
        if freeMB < criticalMB { return .critical }
        if freeMB < lowMB { return .low }
        return .ok
    }

    static func notice(freeMB: Int) -> String {
        switch level(freeMB: freeMB) {
        case .ok: return ""
        case .low: return "Telefonda boş yer az (\(freeMB) MB). Yer açmazsanız kayıtlar yarıda kalabilir."
        case .critical: return "Telefonda boş yer çok az (\(freeMB) MB): video kaydı kapatıldı. Lütfen yer açın."
        }
    }

    /// Uygulamanın bulunduğu bölümdeki boş yer (MB); -1 = ölçülemedi
    static func freeMB() -> Int {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage else { return -1 }
        return Int(bytes / 1_048_576)
    }
}

/// Telefonun ısısını, belleğini ve ekranın takılmalarını sessizce ölçer ve dosyaya yazar.
/// Çok hafiftir: saniyede bir küçük bir ping, 10 saniyede bir örnek.
final class HealthMonitor {
    static let shared = HealthMonitor()

    /// Her örnekte ana iş parçacığında çağrılır: (örnek, son dakikadaki takılma sayısı)
    var onSample: ((HealthSample, Int) -> Void)?
    /// Önceki kullanım beklenmedik kapandıysa açılışta bir kez ana iş parçacığında çağrılır
    var onPreviousUnclean: ((String) -> Void)?
    /// Art arda beklenmedik kapanış sayısı eşiğe ulaştıysa açılışta bir kez ana iş parçacığında çağrılır (parametre: kaçıncı kapanış)
    var onSafeMode: ((Int) -> Void)?

    private static let activeKey = "health.foregroundActive"
    private static let uncleanStreakKey = "health.uncleanStreak"
    private let q = DispatchQueue(label: "g526.health", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var began = false
    private var tick = 0
    private var pending = false
    private var pingSentAt = 0.0
    private var worstStallMs = 0
    private var battery = -1
    private var store = HealthStore()
    private var previous: HealthStore?
    private var previousUnclean = false
    private var stalls = StallTracker()
    private let url: URL
    /// Programın o an yaptığı işin kısa adı (her iş parçacığından yazılabilir); ekran donarsa rapora "son işlem" olarak girer
    private let activityLock = NSLock()
    private var _activity = ""
    /// Donma anında (eşik aşılınca) görülen işlem; ekran düzelince olay olarak yazılır
    private var hangActivity: String?

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("saglik.json")
    }

    /// Ön plana gelince çağrılır (birden çok kez çağrılması zararsızdır)
    func start() {
        DispatchQueue.main.async { UIDevice.current.isBatteryMonitoringEnabled = true }
        q.async { [self] in
            if !began {
                began = true
                previousUnclean = UserDefaults.standard.bool(forKey: Self.activeKey)
                if let data = try? Data(contentsOf: url),
                   let old = try? JSONDecoder().decode(HealthStore.self, from: data) {
                    previous = old
                }
                let streak = previousUnclean ? UserDefaults.standard.integer(forKey: Self.uncleanStreakKey) + 1 : 0
                UserDefaults.standard.set(streak, forKey: Self.uncleanStreakKey)
                if HealthMath.needsSafeMode(uncleanStreak: streak) {
                    DispatchQueue.main.async { self.onSafeMode?(streak) }
                }
                if previousUnclean {
                    let full = HealthMath.summary(HealthStore(), previous: previous, previousUnclean: true)
                    let text = full.split(separator: "\n").dropFirst().joined(separator: "\n")
                    DispatchQueue.main.async { self.onPreviousUnclean?(text) }
                }
            }
            UserDefaults.standard.set(true, forKey: Self.activeKey)
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: q)
            t.schedule(deadline: .now() + 1, repeating: 1.0, leeway: .milliseconds(200))
            t.setEventHandler { [weak self] in self?.secondTick() }
            t.resume()
            timer = t
        }
    }

    /// Arka plana geçince çağrılır: temiz kapanış sayılır, ölçüm durur
    func pause() {
        q.async { [self] in
            UserDefaults.standard.set(false, forKey: Self.activeKey)
            UserDefaults.standard.set(0, forKey: Self.uncleanStreakKey)        // temiz kapanış: art arda sayacı sıfırlanır
            timer?.cancel()
            timer = nil
            pending = false
        }
    }

    /// Önemli bir olayı rapora yazar (ısı değişimi, bellek uyarısı…)
    func event(_ text: String) {
        q.async { [self] in addEvent(text) }
    }

    /// Şu an yapılan işi not eder ("" = boşta). Çok hafiftir; ağır işlerin başında çağrılır.
    func mark(_ text: String) {
        activityLock.lock()
        _activity = text
        activityLock.unlock()
    }

    private func currentActivity() -> String {
        activityLock.lock()
        defer { activityLock.unlock() }
        return _activity
    }

    private func addEvent(_ text: String) {
        store.events.append(HealthEvent(time: Date().timeIntervalSince1970, text: text))
        if store.events.count > HealthMath.eventCap {
            store.events.removeFirst(store.events.count - HealthMath.eventCap)
        }
        persist()
    }

    /// Ekrandaki ve panoya kopyalanan rapor
    func report() -> String {
        return q.sync {
            HealthMath.summary(store, previous: previous, previousUnclean: previousUnclean)
        }
    }

    // MARK: İç işler (hepsi q üzerinde)

    private func secondTick() {
        let now = ProcessInfo.processInfo.systemUptime
        if pending {
            let ms = Int((now - pingSentAt) * 1000)
            worstStallMs = max(worstStallMs, ms)
            // Ekran şu an donuk: o andaki işlem not edilir (düzelince olay olarak yazılır)
            if ms >= HealthMath.hangThresholdMs && hangActivity == nil { hangActivity = currentActivity() }
        } else {
            pending = true
            hangActivity = nil
            pingSentAt = now
            DispatchQueue.main.async { [weak self] in
                let level = UIDevice.current.batteryLevel
                self?.q.async { self?.pong(batteryLevel: level) }
            }
        }
        tick += 1
        if tick % 10 == 0 { sample() }
    }

    private func pong(batteryLevel: Float) {
        let now = ProcessInfo.processInfo.systemUptime
        if pending {
            let ms = Int((now - pingSentAt) * 1000)
            worstStallMs = max(worstStallMs, ms)
            if ms >= HealthMath.stallThresholdMs { stalls.record(at: now) }
            if ms >= HealthMath.hangThresholdMs {
                addEvent(HealthMath.hangText(ms: ms, activity: hangActivity ?? currentActivity()))
            }
            hangActivity = nil
            pending = false
        }
        battery = batteryLevel < 0 ? -1 : Int((batteryLevel * 100).rounded())
    }

    private func sample() {
        let now = ProcessInfo.processInfo.systemUptime
        let s = HealthSample(time: Date().timeIntervalSince1970,
                             thermal: HealthMath.thermalLevel(ProcessInfo.processInfo.thermalState),
                             memoryMB: Self.footprintMB(),
                             stallMs: worstStallMs,
                             battery: battery,
                             lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
        worstStallMs = 0
        store.samples.append(s)
        if store.samples.count > HealthMath.sampleCap {
            store.samples.removeFirst(store.samples.count - HealthMath.sampleCap)
        }
        persist()
        let recent = stalls.count(now: now)
        DispatchQueue.main.async { [weak self] in self?.onSample?(s, recent) }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(store) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Programın bellek kullanımı (MB); iOS'un bellek baskısında baktığı değer
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Int(info.phys_footprint / 1_048_576)
    }
}
