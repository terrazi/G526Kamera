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
    /// Numaranın nereden geldiği: okunan (dikte metninde "soru 7"), Gemini'nin sesten/metinden duyduğu, ya da okunmadığı için sıradaki
    enum NumberSource: Equatable {
        case spoken, heard, sequence

        var logName: String {
            switch self {
            case .spoken: return "okunan"
            case .heard: return "Gemini'nin duyduğu"
            case .sequence: return "sıradaki (numara okunmadı)"
            }
        }
    }

    /// Cevap gelene kadar beklenen soru numarası, gelince kaydedilen numara
    var number: Int
    /// Cevap gelince numaranın kaynağı
    var numberSource: NumberSource?
    /// Cevabı veren model (cevap gelince)
    var model: String = ""
    var state: State = .sending
}
