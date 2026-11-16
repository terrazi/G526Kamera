import Foundation
import CoreTelephony

/// Telefonda hücresel hizmet (SIM / eSIM) var mı? SIM yokken "Hücresel Veri" kestirmesi yalnız Wi-Fi'yi kapatır ve hiçbir zaman
/// internet getirmez; program bunu bilmezse 30 sn bekler, onarım ve sistem sıfırlama döngüsüne girer.
///
/// Karar iki işarete bakar ve yalnız ikisi de boşsa "yok" der (şüphede "var" denir: eski davranış korunur):
/// - abone sağlayıcıları (`serviceSubscriberCellularProviders`): takılı SIM/eSIM başına bir kayıt
/// - radyo teknolojisi (`serviceCurrentRadioAccessTechnology`): hizmet alan hat başına bir kayıt
enum CellularService {
    /// `providers` ve `radios` kayıt sayılarıdır; saf karar mantığı (denenebilir)
    static func isAvailable(providers: Int, radios: Int) -> Bool {
        return providers > 0 || radios > 0
    }

    static func status() -> (available: Bool, detail: String) {
        let info = CTTelephonyNetworkInfo()
        let providers = info.serviceSubscriberCellularProviders?.count ?? 0
        let radios = info.serviceCurrentRadioAccessTechnology?.count ?? 0
        return (isAvailable(providers: providers, radios: radios), "sağlayıcı \(providers), radyo \(radios)")
    }
}
