import Foundation

/// Pil cümleleri (V1'in `SpokenReport`ından yalnız kamera ve telefon pili): "pil durumu" ve düşük şarj uyarıları.
/// V1'in belge / PDF / klasör raporları V4'e alınmadı (bkz. docs/SURUM4_TASIMA.md).
enum SpokenReport {

    /// "Batarya kontrol": telefon şarjı yüzde olarak, kamera şarjı tahmini yüzde aralığı olarak. `camera` nil ise kameradan henüz pil bilgisi gelmemiştir.
    static func battery(phone: Int?, charging: Bool, camera: CameraBatteryLevel?) -> String {
        var parts: [String] = []
        if let p = phone {
            parts.append("Telefon yüzde \(p)" + (charging ? " ve şarjda" : ""))
        } else {
            parts.append("Telefonun şarjı okunamıyor")
        }
        if let c = camera {
            parts.append(CameraBattery.phrase(c))
        } else {
            parts.append("kameranın şarj bilgisi henüz gelmedi")
        }
        var out = [parts.joined(separator: ", ") + "."]
        if let p = phone, p <= 20, !charging { out.append("Telefon şarjı düşük.") }
        if let c = camera, c.isLow { out.append("Kamerayı şarja takın.") }
        return out.joined(separator: " ")
    }

    /// Telefon şarjı düşünce kendiliğinden söylenen uyarı
    static func phoneLow(percent: Int) -> String {
        return "Telefon şarjı yüzde \(percent). Şarja takın."
    }
}
