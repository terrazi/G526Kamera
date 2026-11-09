import Foundation

/// "Rapor ver" komutunda söylenen özet cümleleri (saf fonksiyon; birim testle denenir).
enum SpokenReport {
    static func make(captured: Int, sentPhotos: Int, sentDocs: Int, waiting: Int,
                     signedIn: Bool, hasError: Bool, pdf: Bool, batchMode: Bool) -> String {
        var parts: [String] = []
        if captured == 0 {
            parts.append("Bugün henüz fotoğraf çekilmedi.")
        } else {
            parts.append("Bugün \(captured) sayfanın fotoğrafı çekildi.")
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
    /// `batchSize`: ayarlanan toplu gönderim sayfa sayısı (0 = yalnız komutla); PDF'e en çok 30 sayfa girer.
    static func afterCapture(part: String?, waiting: Int, signedIn: Bool, batchMode: Bool, batchSize: Int = 0) -> String {
        var s = part.map { "\($0) bölüm çekildi." } ?? "Çekim tamamlandı."
        if !signedIn {
            s += " Drive'a giriş yapılmadığı için dosya bekliyor."
        } else if batchMode {
            s += " \(max(waiting, 1)) sayfa gönderilmeyi bekliyor."
        } else {
            s += " Dosya gönderiliyor."
        }
        if batchMode {
            if batchSize > 0 && waiting >= batchSize && signedIn {
                s += " PDF dolduğu için gönderiliyor, sonraki sayfalar yeni PDF olacak."
            } else if batchSize == 0 && waiting > 0 && waiting % maxPagesPerPDF == 0 {
                s += " PDF'e en çok \(maxPagesPerPDF) sayfa girer, sonraki sayfalar yeni PDF olacak."
            }
        }
        return s
    }

    /// Bir PDF'e giren en çok sayfa sayısı (UploadQueue ile aynı)
    static let maxPagesPerPDF = 30

    /// "Son fotoğrafı sil" / "yeniden çek" sonucu. `retake`: silindikten sonra yeniden çekilecek;
    /// `guided`: sesli konumlandırma açık (kendiliğinden çeker), değilse tetik sözcüğü söylenir.
    static func afterDelete(_ outcome: CaptureLog.Outcome, waiting: Int, retake: Bool, part: String?,
                            guided: Bool, trigger: String) -> String {
        switch outcome {
        case .removed:
            var s = "Son fotoğraf silindi."
            if retake {
                if guided {
                    s += part.map { " \($0) bölümü yeniden kadraja alın." } ?? " Sayfayı yeniden kadraja alın."
                } else {
                    s += " Yeniden çekmek için \(trigger) deyin."
                }
            } else {
                s += waiting > 0 ? " \(waiting) sayfa gönderilmeyi bekliyor." : " Bekleyen sayfa yok."
            }
            return s
        case .alreadySent:
            return "Son sayfa zaten Drive'a gönderildi, silemem."
        case .uploading:
            return "Son sayfa şu an gönderiliyor, silemem."
        case .none:
            return "Bu oturumda silinecek fotoğraf yok."
        }
    }

    /// "Hepsi tamamlandı" gönderimi bitince söylenen cümle
    static func finished(photos: Int, docs: Int, pdf: Bool) -> String {
        if photos <= 0 { return "Gönderim tamamlandı." }
        if pdf { return "Tamamlandı. \(photos) sayfa \(max(docs, 1)) PDF olarak Drive'a gönderildi." }
        return "Tamamlandı. \(photos) fotoğraf Drive'a gönderildi."
    }
}
