import Foundation

/// "Rapor ver" komutunda söylenen özet cümleleri (saf fonksiyon; birim testle denenir).
enum SpokenReport {
    static func make(captured: Int, sentPhotos: Int, sentDocs: Int, waiting: Int,
                     signedIn: Bool, hasError: Bool, pdf: Bool, batchMode: Bool) -> String {
        var parts: [String] = []
        if captured == 0 {
            parts.append("Bu oturumda henüz fotoğraf çekilmedi.")
        } else {
            parts.append("Bu oturumda \(captured) sayfanın fotoğrafı çekildi.")
        }
        if sentPhotos > 0 {
            if pdf {
                parts.append("\(sentPhotos) sayfa \(max(sentDocs, 1)) PDF olarak Drive'a gönderildi.")
            } else {
                parts.append("\(sentPhotos) fotoğraf Drive'a gönderildi.")
            }
        } else if captured > 0 {
            parts.append("Henüz hiçbir şey Drive'a gönderilmedi.")
        }
        if waiting > 0 {
            parts.append("\(waiting) sayfa gönderilmeyi bekliyor.")
            if !signedIn {
                parts.append("Drive'a giriş yapılmadığı için gönderilemiyor.")
            } else if hasError {
                parts.append("Son gönderim denemesi başarısız oldu, yeniden denenecek.")
            } else if batchMode {
                parts.append("Göndermek için hepsi tamamlandı deyin.")
            }
        } else if captured > 0 || sentPhotos > 0 {
            parts.append("Bekleyen sayfa yok.")
        }
        return parts.joined(separator: " ")
    }

    /// Her çekim bitince söylenen kısa bilgi: ne çekildi, dosya gönderildi mi / bekliyor mu.
    /// `part`: seçilen bölümün adı ("Sol", "Sağ"…) ya da nil. Çekim cümlesi sayfayı çevirmenin güvenli olduğunu da bildirir.
    static func afterCapture(part: String?, waiting: Int, signedIn: Bool, batchMode: Bool) -> String {
        var s = part.map { "\($0) bölüm çekildi." } ?? "Çekim tamamlandı."
        if !signedIn {
            s += " Drive'a giriş yapılmadığı için dosya bekliyor."
        } else if batchMode {
            s += " \(max(waiting, 1)) sayfa gönderilmeyi bekliyor."
        } else {
            s += " Dosya gönderiliyor."
        }
        return s
    }

    /// "Hepsi tamamlandı" gönderimi bitince söylenen cümle
    static func finished(photos: Int, docs: Int, pdf: Bool) -> String {
        if photos <= 0 { return "Gönderim tamamlandı." }
        if pdf { return "Tamamlandı. \(photos) sayfa \(max(docs, 1)) PDF olarak Drive'a gönderildi." }
        return "Tamamlandı. \(photos) fotoğraf Drive'a gönderildi."
    }
}
