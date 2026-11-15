import UIKit

extension SessionViewModel {
    /// Çekim başarılı olunca ana ekrandaki "Son fotoğraf" için küçük resim ve bilgi saklanır (tam boyutlu fotoğraf bellekte tutulmaz)
    func rememberShot(_ shot: CapturedQuestion) {
        guard let image = UIImage(data: shot.photo) else { return }
        lastShot = image.preparingThumbnail(of: CGSize(width: 480, height: 480)) ?? image
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
        var info = "\(clock.string(from: shot.date)) · fotoğraf \(shot.photo.count / 1024) KB"
        if shot.video != nil { info += " · video var" }
        lastShotInfo = info
    }
}
