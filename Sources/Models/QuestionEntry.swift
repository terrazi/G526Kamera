import Foundation

/// Ana ekrandaki tek listenin satırı: okunup yüklenen soru ve Gemini'ye gidişinin durumu (yanındaki işaret)
struct QuestionEntry: Identifiable, Equatable {
    enum State: Equatable {
        /// Soru Gemini'ye gidiyor, cevap bekleniyor
        case sending
        /// Gitti ve cevap geldi; değer kulaklıktan okunan cevap cümlesi
        case answered(String)
        /// Gitmedi ya da cevap alınamadı; değer nedeni
        case failed(String)
    }

    /// Yükleme sırası (1'den başlar); satırın kimliği
    let id: Int
    /// Dikteyle yazıya çevrilen soru (tetikleyici sözcük atılmış)
    let text: String
    /// Soru, ses kaydıyla birlikte mi gitti
    let withAudio: Bool
    /// Cevap gelene kadar beklenen soru numarası, gelince cevaptaki numara
    var number: Int
    /// Cevabı veren model (cevap gelince)
    var model: String = ""
    var state: State = .sending
}
