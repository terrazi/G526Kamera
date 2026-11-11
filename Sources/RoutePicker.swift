import SwiftUI
import AVKit

/// iOS'un kendi ses çıkışı seçme düğmesi (AirPlay / Bluetooth kulaklık listesi). Çıkışı program değil sistem seçtirir;
/// Lightning mikrofon alıcısı sesi kendine çektiğinde kulaklığı buradan seçersiniz.
struct RoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.activeTintColor = .systemBlue
        view.tintColor = .label
        view.prioritizesVideoDevices = false
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Ses çıkışını seç"
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
