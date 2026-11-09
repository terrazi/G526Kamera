import Foundation

/// Kamera bağlantısının durumunu sesle haber vermek için karar veren saf mantık (birim testle denenir).
/// Her saniye `tick` çağrılır; konuşulacak bir şey varsa cümleyi döndürür. Kısa takılmalar (6 sn'den az) söylenmez,
/// uzun kopuklukta hatırlatma aralıklı ve sınırlıdır, böylece sesli kullanımda rahatsız etmez.
struct ConnectionAnnouncer {
    enum Message: Equatable {
        case ready, lost, restored, unreachable, stillDown

        var text: String {
            switch self {
            case .ready: return "Kamera hazır."
            case .lost: return "Kamera bağlantısı koptu."
            case .restored: return "Kamera geri geldi."
            case .unreachable: return "Kameraya bağlanılamıyor. Kamera açık mı, telefon kameranın Wi-Fi ağında mı, bakın."
            case .stillDown: return "Kamera hâlâ bağlı değil."
            }
        }
    }

    /// Görüntü bu kadar süre gelmezse "koptu" denir
    static let lostAfter: TimeInterval = 6
    /// Hiç bağlanılamadıysa bu süreden sonra uyarılır
    static let unreachableAfter: TimeInterval = 25
    /// Hatırlatma aralığı ve en çok kaç kez hatırlatılacağı
    static let remindEvery: TimeInterval = 60
    static let maxReminders = 3

    private var downSince: TimeInterval?
    private var everLive = false
    private var announcedLost = false
    private var reminders = 0
    private var lastReminder: TimeInterval = 0

    mutating func reset() {
        self = ConnectionAnnouncer()
    }

    /// `live`: görüntü şu an gerçekten akıyor mu
    mutating func tick(now: TimeInterval, live: Bool) -> Message? {
        if live {
            downSince = nil
            reminders = 0
            if announcedLost {
                announcedLost = false
                everLive = true
                return .restored
            }
            if !everLive {
                everLive = true
                return .ready
            }
            return nil
        }

        let since = downSince ?? now
        downSince = since
        let down = now - since

        if everLive && !announcedLost {
            if down >= Self.lostAfter {
                announcedLost = true
                lastReminder = now
                return .lost
            }
            return nil
        }
        if !everLive && reminders == 0 {
            if down >= Self.unreachableAfter {
                reminders = 1
                lastReminder = now
                return .unreachable
            }
            return nil
        }
        if reminders < Self.maxReminders && now - lastReminder >= Self.remindEvery {
            reminders += 1
            lastReminder = now
            return .stillDown
        }
        return nil
    }
}
