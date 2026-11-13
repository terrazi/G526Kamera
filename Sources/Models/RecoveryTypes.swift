import Foundation

/// Kendini onarma sırasında çalıştırılan Kestirme adımları (Modül 4). İnternette: Wi-Fi, hücresel, sistem sıfırlama.
/// Ses yolunda: önce hafif Bluetooth yenileme, olmazsa sistem sıfırlama.
enum RecoveryStep: String, CaseIterable, Equatable {
    case wifi
    case cellular
    case bluetooth
    case reset

    var title: String {
        switch self {
        case .wifi: return "Wi-Fi"
        case .cellular: return "Hücresel veri"
        case .bluetooth: return "Bluetooth yenileme"
        case .reset: return "Sistem sıfırlama"
        }
    }
}

/// Onarımın nedeni: internet/Gemini erişimi koptu ya da donanım (mikrofon/ses motoru) kilitlendi
enum RecoveryReason: Equatable {
    case network
    case hardware

    /// Bu neden için denenecek adımlar, sırasıyla. Donanımda internet kestirmeleri işe yaramaz: önce Bluetooth yenileme
    /// (internete dokunmaz), olmazsa sıfırlama.
    var steps: [RecoveryStep] {
        switch self {
        case .network: return [.wifi, .cellular, .reset]
        case .hardware: return [.bluetooth, .reset]
        }
    }

    /// `force`: sorun ses yolunda görünmüyor (ör. yol güvenli ama mikrofon ses vermiyor). Sınama yalnız ses yoluna baktığı için
    /// Bluetooth yenileme "düzeldi" gibi görünür ama mikrofonu düzeltmez; bu durumda yalnız sıfırlama çalışır.
    func steps(force: Bool) -> [RecoveryStep] {
        if self == .hardware, force { return [.reset] }
        return steps
    }

    var title: String {
        switch self {
        case .network: return "internet"
        case .hardware: return "donanım"
        }
    }
}
