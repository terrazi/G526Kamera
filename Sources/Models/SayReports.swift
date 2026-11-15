import Foundation

/// Sesle istenen raporların ve ses / kamera ayarı komutlarının yanıt cümleleri. Her ayar komutu yaptığını ya da yapamadığını söyler.
extension Say {
    // MARK: Raporlar

    /// "412 megabayt", "1,9 gigabayt" (bin megabayt ve üstü gigabayt olarak)
    static func megabytes(_ mb: Int) -> String {
        guard mb >= 1000 else { return "\(max(0, mb)) megabayt" }
        let gb = Double(mb) / 1024
        let text = String(format: "%.1f", gb).replacingOccurrences(of: ".", with: ",")
        return "\(text.hasSuffix(",0") ? String(text.dropLast(2)) : text) gigabayt"
    }

    static let reportInternetOffline = "İnternet yok. Telefon hiçbir ağa bağlı değil."

    /// `gemini`: nil ise Gemini yoklanmamıştır
    static func reportInternet(kind: NetworkKind, reachable: Bool, gemini: GeminiHealth?) -> String {
        let way = kind == .unknown ? "" : " Bağlantı türü: \(kind.spoken)."
        guard reachable else { return "Ağa bağlısınız ama internete ulaşılamıyor." + way }
        var text = "İnternet var." + way
        switch gemini {
        case .ok?: text += " Gemini'ye ulaşılıyor."
        case .keyRejected?: text += " Gemini anahtarı kabul edilmedi."
        case .unreachable?: text += " Gemini'ye ulaşılamıyor."
        case nil: break
        }
        return text
    }

    static func reportHeadphones(ok: Bool, outputs: [String], hint: String) -> String {
        if ok { return "Kulaklık bağlı: \(outputs.joined(separator: ", "))." }
        return "Kulaklıkta sorun var. " + (hint.isEmpty ? "Bluetooth kulaklık bulunamadı." : hint)
    }

    static func reportMicrophone(ok: Bool, inputs: [String]) -> String {
        if ok { return "Mikrofon bağlı: \(inputs.joined(separator: ", ")). Sizi duyuyorum." }
        if inputs.isEmpty { return "Mikrofon bulunamadı. Yaka mikrofonu alıcısının telefona takılı olduğunu kontrol edin." }
        return "Mikrofon yaka mikrofonu değil: \(inputs.joined(separator: ", ")). Yaka mikrofonu alıcısını kontrol edin."
    }

    /// Ses seviyesi ve sesin gittiği yer
    static func reportSound(percent: Int?, low: Bool, headphonesOK: Bool) -> String {
        var text = percent.map { "Ses seviyesi yüzde \($0)." } ?? "Ses seviyesi okunamadı."
        if low { text += " Çok düşük; sesi aç diyebilirsiniz." }
        text += headphonesOK ? " Ses Bluetooth kulaklığa gidiyor." : " Ses kulaklığa gitmiyor."
        return text
    }

    static func reportBattery(percent: Int?, charging: Bool, lowPower: Bool) -> String {
        guard let percent = percent else { return "Telefonun şarj durumu okunamıyor." }
        var text = "Telefonun şarjı yüzde \(percent)" + (charging ? ", şarjda." : ".")
        if percent <= 20, !charging { text += " Şarj düşük; telefonu şarja takın." }
        if lowPower { text += " Düşük güç modu açık." }
        return text
    }

    static func reportThermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Telefonun ısısı normal."
        case .fair: return "Telefon biraz ısındı."
        case .serious: return "Telefon ısındı ve yavaşlayabilir. Serin bir yere koyun."
        case .critical: return "Telefon çok sıcak. Hemen serin bir yere koyun; kapanabilir."
        @unknown default: return "Telefonun ısısı bilinmiyor."
        }
    }

    static func reportMemory(availableMB: Int?, footprintMB: Int?, freeDiskMB: Int?, memoryLow: Bool, diskLow: Bool) -> String {
        var parts: [String] = []
        if let available = availableMB {
            parts.append("Kalan bellek yaklaşık \(megabytes(available))." + (memoryLow ? " Bellek az." : " Bellek yeterli."))
        }
        if let used = footprintMB { parts.append("Program \(megabytes(used)) kullanıyor.") }
        if let disk = freeDiskMB { parts.append("Boş depolama \(megabytes(disk))." + (diskLow ? " Depolama az." : "")) }
        return parts.isEmpty ? "Bellek bilgisi okunamadı." : parts.joined(separator: " ")
    }

    /// Kamera ve görüntü ayarlarının özeti
    static func reportCamera(configured: Bool, ask: Bool, highQuality: Bool, vertical: Bool, orientation: ImageOrientation, guidance: Bool,
                             pageSeconds: Int, video: Bool, enhancement: Int, preview: Bool, pending: Int, battery: CameraBatteryLevel? = nil) -> String {
        var parts = ["Görüntü kalitesi \(highQuality ? "yüksek" : "düşük"), kadraj \(vertical ? "dikey" : "yatay"), görüntü yönü \(orientation.spoken)."]
        parts.append("Sesle konumlandırma \(guidance ? "açık" : "kapalı").")
        parts.append("Soru videosu sayfa başına \(pageSeconds) saniye" + (video ? ", Gemini'ye de gönderiliyor." : ", Gemini'ye gönderilmiyor."))
        parts.append("Fotoğraf iyileştirme \(enhancementName(enhancement)). Canlı önizleme \(preview ? "açık" : "kapalı").")
        parts.append("Her soruda kamera sorusu \(ask ? "açık" : "kapalı").")
        if !configured { parts.append("Kamera adı ya da kestirme adları eksik; kamera kullanılamaz.") }
        if pending > 0 { parts.append("\(pending) çekim gönderilmeyi bekliyor.") }
        if let level = battery { parts.append("Son çekimde \(CameraBattery.phrase(level)) görüldü.") }
        return parts.joined(separator: " ")
    }

    static func enhancementName(_ level: Int) -> String {
        switch level {
        case 0: return "kapalı"
        case 2: return "güçlü"
        default: return "hafif"
        }
    }

    /// "Genel rapor": parçalar sırayla söylenir
    static func reportGeneral(_ parts: [String]) -> String {
        return "Genel rapor. " + parts.joined(separator: " ")
    }

    // MARK: Ses seviyesi

    static let volumeUnreadable = "Ses seviyesi okunamadığı için ayarlanamadı. Telefonun ses tuşlarını kullanın."
    static let volumeAlreadyMax = "Ses zaten en yüksek düzeyde."
    static func volumeAlreadyMin(_ percent: Int) -> String {
        return "Ses zaten en düşük sınırda, yüzde \(percent). Daha fazla kısılmaz."
    }
    static func volumeSame(_ percent: Int) -> String { return "Ses zaten yüzde \(percent)." }
    static func volumeNotChanged(_ percent: Int) -> String {
        return "Ses seviyesi değiştirilemedi, yüzde \(percent) kaldı. Telefonun ses tuşlarını kullanın."
    }
    static func volumeChanged(_ percent: Int, action: VolumeAction, floored: Int?) -> String {
        var text: String
        switch action {
        case .up: text = "Ses açıldı. Ses seviyesi yüzde \(percent)."
        case .down: text = "Ses kısıldı. Ses seviyesi yüzde \(percent)."
        case .set: text = "Ses seviyesi yüzde \(percent) yapıldı."
        }
        if let floor = floored { text = "Ses en az yüzde \(floor) olabilir. " + text }
        return text
    }

    // MARK: Kamera ayarları

    static let cameraSettingBusy = "Kamera çalışırken ayar değiştirilemez. Çekim bitince tekrar söyleyin."
    static func cameraAskChanged(on: Bool, configured: Bool, leavingChoice: Bool) -> String {
        if !on { return "Kamera sorusu kapatıldı. Sorular sesle okunacak." + (leavingChoice ? " Soruyu sesle okuyun." : "") }
        if !configured {
            return "Kamera sorusu açıldı ama kamera adı ya da kestirme adları eksik; ayarlardan tamamlayın. Eksik olduğu sürece sorular sesle okunur."
        }
        return "Kamera sorusu açıldı. Sonraki sorudan başlayarak her soruda sorulacak."
    }
    static func cameraAskAlready(_ on: Bool) -> String { return "Kamera sorusu zaten \(on ? "açık" : "kapalı")." }

    static func cameraQuality(high: Bool, already: Bool) -> String {
        return already ? "Görüntü kalitesi zaten \(high ? "yüksek" : "düşük")." : "Görüntü kalitesi \(high ? "yüksek" : "düşük") yapıldı."
    }
    static func cameraVideoSend(on: Bool, already: Bool) -> String {
        if already { return on ? "Video zaten Gemini'ye gönderiliyor." : "Video zaten Gemini'ye gönderilmiyor." }
        return on ? "Video Gemini'ye de gönderilecek." : "Video Gemini'ye gönderilmeyecek; yalnız fotoğraf gider."
    }
    static func cameraVideoSeconds(_ seconds: Int, clamped: Bool, already: Bool, range: ClosedRange<Int>) -> String {
        if already { return "Soru videosu zaten sayfa başına \(seconds) saniye." }
        let note = clamped ? "Süre \(range.lowerBound) ile \(range.upperBound) saniye arasında olabilir. " : ""
        return note + "Soru videosu sayfa başına \(seconds) saniye yapıldı."
    }
    static func cameraFrame(vertical: Bool, orientation: ImageOrientation, already: Bool) -> String {
        if already { return "Kadraj zaten \(vertical ? "dikey" : "yatay")." }
        return "Kadraj \(vertical ? "dikey" : "yatay") yapıldı. Görüntü yönü \(orientation.spoken)."
    }
    static func cameraOrientation(_ orientation: ImageOrientation, already: Bool) -> String {
        return already ? "Görüntü yönü zaten \(orientation.spoken)." : "Görüntü yönü \(orientation.spoken) yapıldı."
    }
    static func cameraOrientationRefused(verticalFrame: Bool) -> String {
        return verticalFrame
            ? "Dikey kadrajda görüntü yalnızca doksan derece sağa ya da sola çevrilebilir."
            : "Yatay kadrajda görüntü yalnızca normal ya da yüz seksen derece olabilir. Sağa ya da sola çevirmek için önce kadrajı dikey yapın."
    }
    static func cameraGuidance(on: Bool, already: Bool) -> String {
        if already { return "Sesle konumlandırma zaten \(on ? "açık" : "kapalı")." }
        return on ? "Sesle konumlandırma açıldı." : "Sesle konumlandırma kapatıldı. Kamera sizi yönlendirmeyecek."
    }
    static func cameraEnhancement(_ level: Int, already: Bool) -> String {
        let name = enhancementName(level)
        if already { return "Fotoğraf iyileştirme zaten \(name)." }
        return level == 0 ? "Fotoğraf iyileştirme kapatıldı." : "Fotoğraf iyileştirme \(name) yapıldı."
    }
    static func cameraPreview(on: Bool, already: Bool) -> String {
        if already { return "Canlı önizleme zaten \(on ? "açık" : "kapalı")." }
        return on ? "Canlı önizleme açıldı." : "Canlı önizleme kapatıldı. Pil tasarrufu için ekranda görüntü görünmez."
    }
}

extension ImageOrientation {
    /// Sesle söylenen ad
    var spoken: String {
        switch self {
        case .normal: return "normal"
        case .right90: return "doksan derece sağa"
        case .left90: return "doksan derece sola"
        case .rotate180: return "yüz seksen derece, ters"
        }
    }
}
