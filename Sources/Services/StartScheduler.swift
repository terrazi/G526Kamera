import Foundation
import UserNotifications

/// Modül 1: zamanlı başlatma. iOS bir uygulamanın kendi kendine tam saatinde uyanmasına izin vermez; bu yüzden üç yol birlikte kullanılır:
/// 1) Kestirmeler'deki "Günün saati" otomasyonu g526kamera://basla adresini açar (asıl yol; KURULUM.md anlatır),
/// 2) uygulama açıksa bu sınıftaki zamanlayıcı saati bekler,
/// 3) sessiz bir bildirim saat gelince çıkar, dokununca uygulama açılıp başlar (yedek).
enum StartSchedule {
    /// `now`dan sonraki ilk başlama zamanı (bugün henüz geçmediyse bugün, geçtiyse yarın)
    static func nextFire(after now: Date, minutes: Int, calendar: Calendar = .current) -> Date? {
        let clamped = AppSettings.clampMinutes(minutes)
        let parts = DateComponents(hour: clamped / 60, minute: clamped % 60, second: 0)
        return calendar.nextDate(after: now, matching: parts, matchingPolicy: .nextTime)
    }
}

@MainActor
final class StartScheduler {
    static let notificationID = "g526.zamanli-baslat"

    var onFire: (@MainActor () -> Void)?
    private var timer: Timer?

    /// Ayar ya da uygulama durumu değişince çağrılır: zamanlayıcıyı ve bildirimi yeniden kurar
    func apply(enabled: Bool, minutes: Int, now: Date = Date()) {
        timer?.invalidate()
        timer = nil
        guard enabled, let fire = StartSchedule.nextFire(after: now, minutes: minutes) else {
            StartScheduler.cancelNotification()
            return
        }
        let timer = Timer(fire: fire, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.onFire?()
                self.apply(enabled: enabled, minutes: minutes, now: Date().addingTimeInterval(1))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        StartScheduler.scheduleNotification(minutes: minutes)
    }

    // MARK: Yedek bildirim (sessiz)

    static func scheduleNotification(minutes: Int) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Sesli Kontrol"
            content.body = "Başlama saati geldi. Oturumu başlatmak için dokunun."
            content.sound = nil
            let clamped = AppSettings.clampMinutes(minutes)
            let parts = DateComponents(hour: clamped / 60, minute: clamped % 60)
            let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: true)
            center.removePendingNotificationRequests(withIdentifiers: [StartScheduler.notificationID])
            center.add(UNNotificationRequest(identifier: StartScheduler.notificationID, content: content, trigger: trigger))
        }
    }

    static func cancelNotification() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationID])
    }
}

/// Bildirime dokunulunca oturumu başlatır; uygulama açıkken bildirim göstermez (zamanlayıcı zaten başlatır)
final class StartNotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    var onTap: (@MainActor () -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.identifier == StartScheduler.notificationID {
            Task { @MainActor in self.onTap?() }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])
    }
}
