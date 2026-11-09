import Foundation

/// Kendiliğinden gelen durum bildirimlerinin ("kamera koptu", "dosya gönderildi") sıraya konup ne zaman söyleneceğine karar verir.
/// Amaç: dinleyiciyi yormamak ve karıştırmamak.
///  • Konuşma sürerken ya da hemen ardından söylenmez (konumlandırma / komut cevapları her zaman önce gelir).
///  • Müdahale gerektiren "uyarı"lar önce söylenir, iyi haberler ("dosya gönderildi") ancak sessizlikte, en çok 8 sn'de bir.
///  • Bayatlayan haber söylenmez (iyi haber 10 sn, uyarı 60 sn sonra düşer). Aynı cümle 30 sn içinde tekrarlanmaz.
///  • Aynı gruptaki yeni haber eskisinin yerine geçer (kopma bildirimi söylenmeden bağlantı gelirse ikisi de atlanır).
struct NoticeQueue {
    enum Priority { case alert, status }

    private struct Item {
        var text: String
        var group: String
        var priority: Priority
        var added: TimeInterval
        var expires: TimeInterval
    }

    static let statusLife: TimeInterval = 10
    static let alertLife: TimeInterval = 60
    /// Son konuşmanın üstünden bu kadar sessizlik geçmeden haber söylenmez
    static let quietGap: TimeInterval = 2
    /// Uyarı bu kadar beklediyse sessizlik koşulu aranmaz (yine de konuşma bitince söylenir)
    static let alertStarve: TimeInterval = 15
    static let statusGap: TimeInterval = 8
    static let repeatGap: TimeInterval = 30

    private var items: [Item] = []
    private var spokenAt: [String: TimeInterval] = [:]
    private var lastStatusAt: TimeInterval = -1000

    var isEmpty: Bool { return items.isEmpty }

    mutating func add(_ text: String, _ priority: Priority, group: String, now: TimeInterval) {
        if let last = spokenAt[text], now - last < Self.repeatGap { return }
        items.removeAll { $0.group == group }
        let life = priority == .alert ? Self.alertLife : Self.statusLife
        items.append(Item(text: text, group: group, priority: priority, added: now, expires: now + life))
    }

    mutating func clear() {
        items.removeAll()
    }

    /// Şimdi söylenecek bildirim varsa döndürür. `speaking`: şu an konuşuyor mu; `lastSpeechAt`: herhangi bir konuşmanın başladığı son an.
    mutating func next(now: TimeInterval, speaking: Bool, lastSpeechAt: TimeInterval) -> String? {
        items.removeAll { $0.expires <= now }
        if speaking || items.isEmpty { return nil }
        let quiet = now - lastSpeechAt
        if let i = items.firstIndex(where: { $0.priority == .alert }) {
            guard quiet >= Self.quietGap || now - items[i].added >= Self.alertStarve else { return nil }
            return take(i, now)
        }
        if let i = items.firstIndex(where: { $0.priority == .status }), quiet >= Self.quietGap, now - lastStatusAt >= Self.statusGap {
            lastStatusAt = now
            return take(i, now)
        }
        return nil
    }

    private mutating func take(_ i: Int, _ now: TimeInterval) -> String {
        let item = items.remove(at: i)
        spokenAt[item.text] = now
        return item.text
    }
}
