import Foundation

/// Sınav türü: soruların programa nasıl geldiği (kullanıcı kararı 2026-11-17).
/// - `camera` (görüntülü): her soru kamerayla çekilir; "kamera ile mi, sesle mi" diye sorulmaz, "hayır" sesle okumaya geçirmez.
/// - `voice` (sesli): kullanıcı soruyu mikrofona okur; kamera hiç kullanılmaz, kamera sorusu sorulmaz.
/// - `hybrid` (hibrit): her soruda "kamera ile çekmek ister misiniz?" diye sorulur; evet kamera, hayır sesle okuma.
/// Tür Ayarlar'dan seçilir ve sınav sırasında sesle değişir ("sesli sınav başlat"); kalan sorular yeni türle sürer.
enum ExamType: String, CaseIterable, Equatable {
    case camera
    case voice
    case hybrid

    var title: String {
        switch self {
        case .camera: return "Görüntülü"
        case .voice: return "Sesli"
        case .hybrid: return "Hibrit"
        }
    }

    /// Cümle içinde söylenen ad ("görüntülü sınav")
    var spoken: String {
        switch self {
        case .camera: return "görüntülü"
        case .voice: return "sesli"
        case .hybrid: return "hibrit"
        }
    }

    /// Ayarlar ekranındaki kısa açıklama
    var detail: String {
        switch self {
        case .camera: return "Sorular kamerayla çekilir; sesle okumaya geçmek için “sesli sınav başlat” ya da “hibrit sınav başlat” denir."
        case .voice: return "Sorular mikrofona okunur; kamera kullanılmaz."
        case .hybrid: return "Her soruda kamera ile mi sesle mi olacağı sorulur."
        }
    }

    /// Kamera kullanılabilen türler (sesli sınavda kamera hiç sorulmaz)
    var usesCamera: Bool { return self != .voice }
}
