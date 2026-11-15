import Foundation
import UIKit
import MediaPlayer

/// Telefonun çıkış ses seviyesini ayarlamayı deneyen katman ("sesi aç", "sesi yüzde elli yap").
/// iOS uygulamalara sistem sesini doğrudan ayarlama izni vermez; bilinen tek yol ekran dışında duran bir `MPVolumeView`in çubuğudur.
/// Bu yöntemin işe yarayıp yaramadığı HER ZAMAN okunarak doğrulanır (bkz. `SystemSnapshot.outputVolume`): değişmediyse kullanıcıya
/// "değiştirilemedi, telefonun ses tuşlarını kullanın" denir. Sonuç iOS sürümüne bağlıdır ve gerçek telefonda sınanmalıdır.
@MainActor
protocol VolumeControlling: AnyObject {
    /// Çıkış sesini 0...1 arasında istenen düzeye getirmeyi dener (sonucu bu işlev bildirmez; ses seviyesi yeniden okunur)
    func requestOutputVolume(_ level: Float)
}

/// Ses ayarı yapılamayan ortam (varsayılan, testler): hiçbir şey yapmaz
@MainActor
final class NoVolumeControl: VolumeControlling {
    func requestOutputVolume(_ level: Float) {}
}

/// Gerçek yol: görünmez bir `MPVolumeView`in `UISlider`ı
@MainActor
final class SystemVolumeControl: VolumeControlling {
    private let volumeView = MPVolumeView(frame: CGRect(x: -3000, y: -3000, width: 120, height: 40))

    func requestOutputVolume(_ level: Float) {
        attachIfNeeded()
        let value = min(1, max(0, level))
        guard let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first else { return }
        slider.setValue(value, animated: false)
        slider.sendActions(for: .touchUpInside)
        slider.sendActions(for: .valueChanged)
    }

    /// Görünüm bir pencerede değilse çubuk sistemi değiştirmez: ekran dışına ama pencereye eklenir
    private func attachIfNeeded() {
        guard volumeView.superview == nil else { return }
        volumeView.alpha = 0.01
        volumeView.isUserInteractionEnabled = false
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.windows.first }.first
        window?.addSubview(volumeView)
        volumeView.layoutIfNeeded()
    }
}
