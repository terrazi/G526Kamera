import SwiftUI
import AVKit

/// Sistemin ses çıkışı seçicisi. Lightning mikrofon alıcısı çıkışı kapabilir; iOS bunu program içinden değiştirmeye izin vermez,
/// çıkış kullanıcının bu düğmeyle seçtiği yola gider (Bluetooth kulaklık seçilir).
struct RoutePickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.activeTintColor = .systemBlue
        view.tintColor = .label
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
