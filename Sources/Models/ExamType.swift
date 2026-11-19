import Foundation

/// Soruların programa geliş yolu. Program yalnız görüntülü sınavı bilir (kullanıcı kararı 2026-11-19: sesli ve hibrit sınav kaldırıldı): uygulamada
/// değer hep `camera`dır; ayarı, sesli komutu ve ekranı yoktur.
/// - `camera` (görüntülü): her soru kamerayla taranır; "hayır" sesle okumaya geçirmez, sesle okunan soru Gemini'ye gönderilmez.
/// - `voice`, `hybrid`: yalnız sınamalar verir. Dinleme, onarım, cevap okuma ve kayıt çekirdeği bu iki yolla da sınanır (sınamaların çoğu soruyu
///   sesle verir); uygulamada bu değerlere giden yol yoktur.
enum ExamType: String, CaseIterable, Equatable {
    case camera
    case voice
    case hybrid

    /// Kamera kullanılan yollar
    var usesCamera: Bool { return self != .voice }
}
