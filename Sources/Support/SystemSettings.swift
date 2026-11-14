import UIKit

/// iPhone Ayarlar uygulamasına kısayol. iOS bir uygulamanın Bluetooth bağlantısını kendi başına kesip kurmasına izin vermez; düşen kulaklığı
/// elle yeniden bağlamak için Ayarlar > Bluetooth > "Aygıtlarım" altındaki aygıta bir kez dokunmak gerekir. Bu düğme o sayfayı açar.
enum SystemSettings {
    /// iOS'un belgelenmemiş Bluetooth sayfası bağlantısı. Yeni iOS sürümlerinde açılmayabilir; o zaman uygulamanın kendi ayar sayfası açılır.
    static let bluetoothURL = "App-Prefs:root=Bluetooth"

    @MainActor
    static func openBluetooth() {
        guard let url = URL(string: bluetoothURL) else { return }
        UIApplication.shared.open(url, options: [:]) { opened in
            guard !opened, let fallback = URL(string: UIApplication.openSettingsURLString) else { return }
            Task { @MainActor in UIApplication.shared.open(fallback, options: [:], completionHandler: nil) }
        }
    }
}
