import Foundation

/// Kendini onarma sırasında çalıştırılan Kestirme adımları (Modül 4). Sıra: önce Wi-Fi, olmazsa hücresel, olmazsa sistem sıfırlama.
enum RecoveryStep: String, CaseIterable, Equatable {
    case wifi
    case cellular
    case reset

    var title: String {
        switch self {
        case .wifi: return "Wi-Fi"
        case .cellular: return "Hücresel veri"
        case .reset: return "Sistem sıfırlama"
        }
    }
}

/// Onarımın nedeni: internet/Gemini erişimi koptu ya da donanım (mikrofon/ses motoru) kilitlendi
enum RecoveryReason: Equatable {
    case network
    case hardware

    /// Bu neden için denenecek adımlar, sırasıyla. Donanım kilidinde internet kestirmeleri işe yaramaz; yalnız sıfırlama denenir.
    var steps: [RecoveryStep] {
        switch self {
        case .network: return [.wifi, .cellular, .reset]
        case .hardware: return [.reset]
        }
    }

    var title: String {
        switch self {
        case .network: return "internet"
        case .hardware: return "donanım"
        }
    }
}
