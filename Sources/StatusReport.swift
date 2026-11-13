import Foundation

/// "Durum bilgisi ver", "duraklat" ve "devam et" komutlarında söylenen cümleler (saf fonksiyonlar; birim testle denenir).
enum StatusReport {
    /// Duraklatılmışken "durum bilgisi ver" denince söylenen tek cümle (başka bilgi eklenmez)
    static let pausedNotice = "İşlemler duraklatıldı. Kaldığınız yerden devam etmek için lütfen devam et komutunu verin."
    /// "Duraklat" denince
    static let pausing = "Duraklatıldı. Devam etmek için devam et deyin."
    /// "Devam et" denince
    static let resuming = "Devam ediyorum."

    /// Kamera bağlantısı
    enum Camera: Equatable {
        case live
        /// Bağlandı ama görüntü gelmiyor / çözülmüyor
        case noPicture
        case connecting
        case reconnecting
        case off
    }

    /// Telefonun durumu ve performansı
    struct Phone: Equatable {
        /// 0 normal, 1 hafif, 2 ciddi, 3 kritik (HealthMath.thermalLevel)
        var thermal = 0
        /// Programın bellek kullanımı (MB); -1: ölçülemedi
        var memoryMB = -1
        /// Boş yer (MB); -1: ölçülemedi
        var freeMB = -1
        var battery: Int?
        var charging = false
        var lowPower = false
        /// Son dakikada ekranın 1 sn'den uzun takıldığı aralık sayısı
        var stalls = 0
        /// Yük azaltıldı (canlı önizleme kapalı)
        var lightMode = false
    }

    /// Programın o an ne yaptığı
    struct Work: Equatable {
        var camera = Camera.live
        var internetDown = false
        /// Deneme sınavı cümlesi (sınav sürüyorsa aşaması, mod açıksa "sınav başlamadı"); mod kapalıysa boş
        var examLine = ""
        var recording = false
        /// Sayfa sayfa video sürüyorsa şimdiye dek kaydedilen sayfa sayısı
        var pageVideoPages: Int?
        var capturing = false
        /// Sesli konumlandırma açık
        var guided = false
        /// Gemini ile konuşma / soru sürüyor
        var gemini = false
        var sendingVideos = false
        /// Gemini sırasında bekleyen video sayısı
        var queuedVideos = 0
        var waitingPages = 0
        /// Bir dosya şu an klasöre kaydediliyor
        var saving = false
        var folderReady = true
        var uploadError = false
    }

    // MARK: Cümleler

    /// Tam cümle: önce ne yapıldığı, sonra kamera ve internet, sonra telefon. `paused`: yalnız duraklatma cümlesi söylenir.
    static func make(work: Work, phone: Phone, paused: Bool) -> String {
        if paused { return pausedNotice }
        return [activity(work), link(work), self.phone(phone)].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Sınav sürerken sınavın kendi cümlesi ayrı söylendiği için: kamera + internet + telefon
    static func system(work: Work, phone: Phone) -> String {
        return [link(work), self.phone(phone)].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// "Şu an ne yapıyorum"
    static func activity(_ w: Work) -> String {
        var parts: [String] = []
        if !w.examLine.isEmpty { parts.append(w.examLine) }
        if let pages = w.pageVideoPages {
            parts.append(pages > 0 ? "Sayfa sayfa video kaydı sürüyor, \(pages) sayfa kaydedildi." : "Sayfa sayfa video açık, ilk sayfayı bekliyorum.")
        } else if w.recording {
            parts.append("Video kaydediliyor.")
        }
        if w.capturing { parts.append("Fotoğraf işleniyor.") }
        if w.gemini { parts.append("Gemini ile konuşma sürüyor.") }
        if w.sendingVideos { parts.append("Videolar Gemini'ye gönderiliyor.") }
        if w.saving {
            parts.append(w.waitingPages > 1 ? "Sayfalar klasöre kaydediliyor, \(w.waitingPages) sayfa bekliyor." : "Sayfa klasöre kaydediliyor.")
        } else if w.waitingPages > 0 {
            var t = "\(w.waitingPages) sayfa gönderilmeyi bekliyor."
            if !w.folderReady {
                t += " Belge klasörü seçilmemiş."
            } else if w.uploadError {
                t += " Son gönderim başarısız oldu, yeniden denenecek."
            }
            parts.append(t)
        }
        if w.queuedVideos > 0 && !w.sendingVideos { parts.append("Sırada \(w.queuedVideos) video var.") }
        if parts.isEmpty {
            return w.guided ? "Boştayım, sesli konumlandırma açık, kadraja belge bekliyorum." : "Boştayım, komut bekliyorum."
        }
        return parts.joined(separator: " ")
    }

    /// Kamera ve internet
    static func link(_ w: Work) -> String {
        var parts: [String] = []
        switch w.camera {
        case .live: parts.append("Kamera bağlı.")
        case .noPicture: parts.append("Kameraya bağlandım ama görüntü gelmiyor.")
        case .connecting: parts.append("Kameraya bağlanılıyor.")
        case .reconnecting: parts.append("Kamera yeniden bağlanıyor.")
        case .off: parts.append("Kamera bağlı değil.")
        }
        if w.internetDown { parts.append("İnternet yok.") }
        return parts.joined(separator: " ")
    }

    /// Telefonun durumu: tek cümle; dikkat gerektiren bir şey varsa başta söylenir
    static func phone(_ p: Phone) -> String {
        var items: [String] = []
        var bad = false

        switch p.thermal {
        case 0: items.append("ısı normal")
        case 1: items.append("ısı hafif yüksek")
        case 2:
            items.append("ısı ciddi yüksek")
            bad = true
        default:
            items.append("ısı kritik")
            bad = true
        }

        if p.memoryMB >= 0 {
            if p.memoryMB >= LoadGuard.memoryCriticalMB {
                items.append("bellek kritik (\(p.memoryMB) megabayt)")
                bad = true
            } else if p.memoryMB >= LoadGuard.memoryTrimMB {
                items.append("bellek yüksek (\(p.memoryMB) megabayt)")
                bad = true
            } else {
                items.append("bellek rahat (\(p.memoryMB) megabayt)")
            }
        }

        if p.stalls <= 0 {
            items.append("ekran takılmıyor")
        } else {
            items.append("ekran son dakikada \(p.stalls) kez takıldı")
            if p.stalls >= LoadGuard.stallsToShed { bad = true }
        }

        if let b = p.battery {
            var t = "pil yüzde \(b)"
            if p.charging {
                t += ", şarjda"
            } else if b <= 20 {
                t += ", düşük"
                bad = true
            }
            items.append(t)
        } else {
            items.append("pil bilgisi okunamıyor")
        }
        if p.lowPower { items.append("düşük güç modu açık") }

        if p.freeMB >= 0 {
            switch DiskGuard.level(freeMB: p.freeMB) {
            case .ok: items.append("boş yer \(space(p.freeMB))")
            case .low:
                items.append("boş yer az (\(space(p.freeMB)))")
                bad = true
            case .critical:
                items.append("boş yer çok az (\(space(p.freeMB)))")
                bad = true
            }
        }

        if p.lightMode {
            items.append("yük azaltıldı, canlı önizleme kapalı")
            bad = true
        }

        let head = bad ? "Telefonda dikkat edilecek durum var" : "Telefon iyi durumda"
        return "\(head): \(items.joined(separator: ", "))."
    }

    /// Boş yer: 1000 MB üstü gigabayt (ondalık virgülle), altı megabayt
    static func space(_ mb: Int) -> String {
        if mb < 1000 { return "\(mb) megabayt" }
        let gb = Double(mb) / 1000.0
        if gb >= 10 { return "\(Int(gb.rounded())) gigabayt" }
        return String(format: "%.1f", gb).replacingOccurrences(of: ".", with: ",") + " gigabayt"
    }
}
