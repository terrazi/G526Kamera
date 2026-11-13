import Foundation

/// Duraklatma nedeni: ses donanımı (kulaklık / yaka mikrofonu) yok ya da bağlantı onarılamadı
enum PauseReason: Equatable {
    case hardware(String)
    case noConnection
}

/// Oturumun durumu (durum makinesi). Ekran bu değere bakarak çizilir.
enum SessionPhase: Equatable {
    case idle
    case checking
    case listening
    case answering
    case speaking
    case paused(PauseReason)
    case recovering(RecoveryReason)
    case finished
    case replaying

    var title: String {
        switch self {
        case .idle: return "Başlatılmadı"
        case .checking: return "Donanım kontrol ediliyor"
        case .listening: return "Dinliyorum. Soruyu okuyun, bitince “Cevapla” deyin"
        case .answering: return "Gemini cevabı hazırlıyor"
        case .speaking: return "Kulaklıktan okunuyor"
        case .paused(.hardware): return "Duraklatıldı: kulaklık ya da mikrofon bağlantısı yok"
        case .paused(.noConnection): return "Duraklatıldı: bağlantı yok"
        case .recovering: return "Bağlantı onarılıyor (Kestirmeler)"
        case .finished: return "Test bitti"
        case .replaying: return "Cevaplar çevrimdışı tekrarlanıyor"
        }
    }

    /// Bir oturum sürüyor mu (başlatma düğmesi kapalı, "Testi bitir" açık)
    var isRunning: Bool {
        switch self {
        case .idle, .finished: return false
        default: return true
        }
    }

    /// Yeni oturum ya da tekrar başlatılabilir mi
    var isAtRest: Bool { return !isRunning }
}
