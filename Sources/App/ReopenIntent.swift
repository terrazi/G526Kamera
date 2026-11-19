import AppIntents
import Foundation

/// Kestirmeler'deki "Sesli Kontrol kapatılınca yeniden aç" otomasyonu panoya bakmak yerine programa sorar (kullanıcı isteği 2026-11-19: pano işareti
/// kopyalanan metnin üstüne yazılıyor, yapıştırınca "SESLIKONTROL-KAPALI" çıkıyordu). Eylem programı öne getirmez; "Evet" dönerse otomasyon
/// "Uygulamayı Aç" adımını çalıştırır. Cevap kalıcı bir bayraktan okunur (`ClipboardFlag.reopenAllowed`): program düğmeyle bilerek kapatıldıysa, bir
/// kestirme çalıştırmak için ayrıldıysa, günlük yapıştırılmak üzere kopyalandıysa ya da "Kapanma engeli" kapalıysa Hayır; başka her kapanmada Evet.
/// Bayrak yalnız program öne gelince kalkar: iOS bu eylem için programı arka planda başlatsa da cevap değişmez.
@available(iOS 16.0, *)
struct ReopenQuestionIntent: AppIntent {
    static var title: LocalizedStringResource = "Yeniden açılsın mı"
    static var description = IntentDescription("Sesli Kontrol bilerek kapatıldıysa ya da bir kestirme için ayrıldıysa Hayır, başka her kapanmada Evet döner. Otomasyonda: Evet ise Sesli Kontrol'ü aç.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let reason = ClipboardFlag.reopenBlockReason()
        tlog("[otomasyon] \"Yeniden açılsın mı\" soruldu: \(reason == nil ? "evet" : "hayır (\(reason ?? ""))")")
        return .result(value: reason == nil)
    }
}
