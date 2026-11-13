import Foundation

/// Kulaklıktan söylenen ve ekranda yazan Türkçe metinlerin tek yeri
enum Say {
    /// Modül 1: donanım kontrolü sorunsuz bitince
    static let ready = "Ben hazırım, sistem kontrol edildi ve problem yok, şimdi ilk soruyu okumanı bekliyorum."
    /// Modül 4: kestirme çalışıp bağlantı düzelince
    static let recovered = "Bağlantı sorunu giderildi ve sistem yeniden hazır. Lütfen en son kaldığın soruyu tekrar oku."

    static let soundTest = "Ses denemesi. Beni kulaklığınızdan duyuyorsanız ses yolu çalışıyor."
    static func lowBattery(_ percent: Int) -> String {
        return "Telefonun şarjı yüzde \(percent). Telefonu şarja takın."
    }

    static let noEnglishDictation = "Telefonda çevrimdışı İngilizce dikte yüklü değil; İngilizce sorular yalnız ses kaydından çözülür. Ayarlar, Genel, Klavye, Dikte bölümünden İngilizce'yi de ekleyip internetteyken bir kez indirin."
    static let receiverNotRouted = "Mikrofon alıcısı takılı ama ses yoluna girmiyor. Alttaki mikrofon listesinden alıcıya bir kez dokunun. Kulaklık sağlam göründüğü için Kestirme çalıştırılmıyor (bağlantıyı koparırdı)."
    static let noKeyShort = "Gemini API anahtarı girilmemiş. Ayarlardan yapıştırın."
    static let noOnDevice = "Bu telefonda çevrimdışı Türkçe dikte yüklü değil. Ayarlar, Genel, Klavye, Dikte bölümünden Türkçe'yi ekleyip internetteyken bir kez indirin."
    static let permissionDenied = "Mikrofon ve konuşma tanıma izni gerekli. Ayarlar, Sesli Kontrol bölümünden izin verin."
    static let notConfigured = "Kestirme adları boş; kendi kendini onarma kapalı. Ayarlardan kestirmelerin adını yazın."
    static let nothingToReplay = "Tekrarlanacak cevap yok."
    static let noHeadphonesForReplay = "Bluetooth kulaklık bağlı değil; tekrar için kulaklığı bağlayın."

    /// Gemini hata verince kulaklıktan söylenen kısa cümle
    static func geminiFailure(_ error: GeminiError) -> String {
        switch error.kind {
        case .quota: return "Gemini kotası doldu. Soruyu biraz sonra tekrar oku."
        case .key: return "Gemini API anahtarı reddedildi. Ayarlardan anahtarı kontrol et."
        case .cap: return "Gemini harcama sınırı doldu."
        case .blocked: return "Gemini bu soruyu güvenlik nedeniyle engelledi. Soruyu tekrar oku."
        case .tooBig: return "Soru çok uzun geldi. Daha kısa oku."
        case .model: return "Gemini modeli bulunamadı."
        case .empty: return "Gemini boş cevap verdi. Soruyu tekrar oku."
        default: return "Gemini cevap veremedi. Soruyu tekrar oku."
        }
    }
}
