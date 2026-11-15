import Foundation
import CoreVideo

/// Bir görüntünün "belge" olup olmadığına karar verir: kâğıt gibi açık bir bölge, üzerinde yeterince yazı ve bu yazının
/// harf boyutunda küçük parçalardan oluşması (çizgili kumaş, tablo çizgisi, ızgara gibi desenler elenir).
/// Program yalnız belge taramak için olduğundan el, yüz, boş masa, duvar gibi görüntüler çekilmez.
enum DocumentVerdict: Equatable {
    case document
    /// Kâğıt gibi açık bir bölge yok (karanlık / düz sahne)
    case noPage
    /// Açık bölge var ama yazı yok ya da çok az (boş kâğıt, el, yüz…)
    case noText
    /// Yazı gibi görünen ama harf parçası olmayan desen
    case notTextLike

    var reason: String {
        switch self {
        case .document: return "belge"
        case .noPage: return "kâğıt görünmüyor"
        case .noText: return "yazı yok ya da çok az"
        case .notTextLike: return "yazıya benzemeyen desen"
        }
    }
}

enum DocumentGate {
    /// En az bu kadar yazı hücresi (960x540 karede 8x8 piksellik hücre); gerçek karelerde yüzlerce çıkar
    static let minCells = 30
    /// En az bu kadar harf boyutunda parça (gerçek kart karelerinde 400+, çizgili desenlerde 0); küçük/yoğun yazıyı
    /// yanlışlıkla reddetmemek için eşikler kasıtlı olarak gevşek tutuldu
    static let minGlyphs = 10
    /// Mürekkebin en az bu kadarı harf boyutundaki parçalardan oluşmalı (gerçek karelerde 0,44–1,0; çizgili desenlerde 0)
    static let minGlyphShare = 0.25

    static func verdict(_ m: PageMetrics) -> DocumentVerdict {
        if !m.hasText { return m.hasPage ? .noText : .noPage }
        if m.cells < minCells { return .noText }
        // glyphs < 0: ölçülmemiş (elle kurulmuş ölçüler); ölçülmüşse harf parçası koşulu aranır
        if m.glyphs >= 0 && (m.glyphs < minGlyphs || m.glyphShare < minGlyphShare) { return .notTextLike }
        return .document
    }

    static func isDocument(_ m: PageMetrics) -> Bool {
        return verdict(m) == .document
    }

    /// Günlük için kısa dökümü
    static func describe(_ m: PageMetrics, _ v: DocumentVerdict) -> String {
        return "\(v.reason) — \(m.summary), yazı hücresi \(m.cells), harf parçası \(m.glyphs), harf payı \(String(format: "%.2f", m.glyphShare))"
    }
}
