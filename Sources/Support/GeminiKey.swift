import Foundation

/// Gemini API anahtarı yardımcıları: ipucu, biçim denetimi, panodan ayıklama, "Anahtarı dene" sonucu
enum GeminiKey {
    /// Hata iletilerinde anahtarın kendisini göstermeden hangi anahtarın kullanıldığını tanıtır: "AIza…x7Qd, 39 karakter"
    static func keyHint(_ key: String) -> String {
        let k = key.trimmed
        if k.isEmpty { return "anahtar boş" }
        if k.count <= 8 { return "\(k.count) karakter" }
        return "\(k.prefix(4))…\(k.suffix(4)), \(k.count) karakter"
    }

    /// Yapıştırılan anahtarda bilinen hatalar (boşluk, tırnak, kırpılmış ya da başka bir şey yapıştırılmış); sorun yoksa nil.
    /// Eski AI Studio anahtarları "AIza" ile başlar ve 39 karakterdir; yenileri "AQ." ile başlar.
    static func keyShapeProblem(_ key: String) -> String? {
        let k = key.trimmed
        if k.isEmpty { return nil }
        if k.contains(where: { $0.isWhitespace }) { return "Anahtarın içinde boşluk ya da satır sonu var; tek parça yapıştırın." }
        if k.contains(where: { "\"'“”‘’`".contains($0) }) { return "Anahtarın içinde tırnak işareti var; tırnaksız yapıştırın." }
        // Google 2026'da AI Studio'da yeni "AQ." biçimli (kimlik doğrulama) anahtarlara geçti; uzunlukları sabit değildir
        if k.hasPrefix("AQ.") { return k.count < 20 ? "“AQ.” ile başlayan anahtar çok kısa; eksik yapışmış olabilir." : nil }
        if !k.hasPrefix("AIza") { return "AI Studio anahtarları “AIza” ya da “AQ.” ile başlar; bu başka bir şey olabilir." }
        if k.count != 39 { return "AI Studio anahtarı 39 karakterdir; bu \(k.count) karakter (eksik ya da fazla yapışmış olabilir)." }
        return nil
    }

    /// Panodan yapıştırılan metinden anahtarı ayıklar: metinde bir "AIza…" anahtarı varsa o alınır (başında "API key:" gibi
    /// sözcükler ya da tırnak olsa da); yoksa baştaki/sondaki boşluk ve tırnaklar atılır. Boşsa nil.
    static func cleanedKey(fromClipboard text: String?) -> String? {
        guard let text = text else { return nil }
        if let range = text.range(of: "AIza[0-9A-Za-z_\\-]{35}", options: .regularExpression) {
            return String(text[range])
        }
        if let range = text.range(of: "AQ\\.[0-9A-Za-z_.\\-]{20,}", options: .regularExpression) {
            return String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        let quotes = CharacterSet(charactersIn: "\"'“”‘’`")
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: quotes)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Yeni biçimli ("AQ.") anahtar Google'ın REST uç noktasında bazı hesaplarda reddedilebiliyor; anahtar hatasında bu bilgi eklenir
    static func keyFormatNote(key: String) -> String? {
        guard key.trimmed.hasPrefix("AQ.") else { return nil }
        return "Bu anahtar yeni “AQ.” biçiminde; Google bunu bazı hesaplarda reddediyor. Google Cloud Console’da Generative Language API’ye kısıtlı yeni bir anahtar (AIza…) oluşturmayı deneyin."
    }

    /// Google'ın yanıtı anahtarın kendisinin reddedildiği anlamına mı geliyor (yoksa anahtar geçmiş, başka bir şey takılmış mı)
    static func isKeyRejection(_ probe: KeyProbe) -> Bool {
        if probe.status == 401 || probe.status == 403 { return true }
        let low = probe.message.lowercased()
        return probe.status == 400 && (low.contains("api key") || low.contains("credential") || low.contains("api_key"))
    }

    private static func briefMessage(_ probe: KeyProbe) -> String {
        let text = probe.message.isEmpty ? "ileti yok" : String(probe.message.prefix(140))
        return "HTTP \(probe.status) – \(text)"
    }

    /// "Anahtarı dene" sonucu. `header` anahtarın başlıkla, `query` (yalnız başlık reddedilince denenir) adreste gönderilmesinin sonucudur.
    /// Google'ın 429 / 5xx / 404 gibi yanıtları anahtarın kabul edildiğini gösterir (kimliği doğrulanmadan bu yanıtlar gelmez).
    static func keyProbeText(model: String, key: String, header: KeyProbe, query: KeyProbe?) -> (ok: Bool, text: String) {
        func accepted(_ probe: KeyProbe, how: String) -> (ok: Bool, text: String)? {
            switch probe.status {
            case 200..<300: return (true, "✓ Anahtar ve model çalışıyor\(how).")
            case 429: return (true, "✓ Anahtar kabul edildi\(how), ama kota şu an dolu: \(briefMessage(probe))")
            case 500..<600: return (true, "✓ Anahtar kabul edildi\(how); model şu an yoğun (\(probe.status)), biraz sonra yine deneyin.")
            case 404: return (false, "✓ Anahtar kabul edildi\(how) ama “\(model.trimmed)” modeli bulunamadı. “Modelleri listele” ile doğru adı bulun.")
            default: return nil
            }
        }
        if let ok = accepted(header, how: "") { return ok }
        if header.status == 0 { return (false, "✗ İnternete ulaşılamadı: \(header.message)") }
        if let query = query, let ok = accepted(query, how: " (anahtar adreste gönderilince)") { return ok }
        if !isKeyRejection(header) {
            return (false, "✗ Google isteği kabul etmedi: \(briefMessage(header))")
        }
        var text = "✗ Google anahtarı reddetti. Başlıkla: \(briefMessage(header))"
        if let query = query { text += " · Adreste: " + (query.status == 0 ? query.message : briefMessage(query)) }
        text += "."
        if let note = keyFormatNote(key: key) { text += " " + note }
        return (false, text)
    }
}
