import AVFoundation

/// Ses yönlendirmesi: Bluetooth kulaklık yalnızca ÇIKIŞ olarak (A2DP, yüksek kalite), mikrofon ise telefonun
/// Lightning/USB girişine takılı harici (kablosuz alıcılı) mikrofondan alınır.
enum AudioRoute {
    /// Bluetooth'un konuşma profili (HFP) bilerek kapalı: açık olsaydı kulaklığın kendi mikrofonu devreye girer
    /// ve kulaklık düşük kaliteli telefon sesine düşerdi. Yalnız A2DP (çıkış) açıktır.
    static let categoryOptions: AVAudioSession.CategoryOptions = [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP]

    /// Ses düzeni 1 ("kulaklığın kendi mikrofonu"): Bluetooth konuşma profili (HFP) açılır; kulaklık hem çıkış hem giriş olur
    /// (tek cihaz, çakışma yok; ses telefon görüşmesi kalitesine düşer). Düzen 0 yukarıdaki seçenekleri kullanır.
    static func categoryOptions(layout: Int) -> AVAudioSession.CategoryOptions {
        return layout == 1 ? [.mixWithOthers, .defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP] : categoryOptions
    }

    /// Çıkış yoluna bakıp tek cümlelik ipucu verir ("" = sorun görünmüyor). Lightning/USB mikrofon alıcısı hem giriş hem çıkış
    /// cihazı gibi tanıtıldığından iOS sesi çoğu kez kulaklık yerine ona yollar; iOS bunun program içinden zorla
    /// değiştirilmesine izin vermez, çıkış sistemin ses çıkışı listesinden (düğme) seçilir.
    static func outputHint(_ outputs: [AVAudioSession.Port]) -> String {
        if outputs.contains(where: { $0 == .usbAudio || $0 == .lineOut }) {
            return "Ses, mikrofon alıcısına (Lightning/USB) gidiyor, kulaklığa gitmiyor. Yandaki ses çıkışı düğmesine basıp kulaklığınızı seçin."
        }
        if outputs.contains(where: { $0 == .builtInSpeaker || $0 == .builtInReceiver }) {
            return "Ses telefonun hoparlöründen çıkıyor. Kulaklıktan dinlemek için ses çıkışı düğmesine basıp kulaklığı seçin."
        }
        return ""
    }

    /// Ayarlar ilk ekranındaki kısa durum: ses şu an nereye gidiyor
    static func outputName(_ outputs: [AVAudioSession.Port]) -> String {
        if outputs.isEmpty { return "çıkış yok" }
        if outputs.contains(where: { $0 == .usbAudio || $0 == .lineOut }) { return "mikrofon alıcısı (kulaklık değil)" }
        if outputs.contains(where: { $0 == .bluetoothA2DP || $0 == .bluetoothHFP || $0 == .bluetoothLE || $0 == .headphones }) { return "kulaklık" }
        if outputs.contains(where: { $0 == .builtInSpeaker || $0 == .builtInReceiver }) { return "telefon hoparlörü" }
        return "diğer çıkış"
    }

    /// Ana ekran uyarısı: yalnız ses mikrofon alıcısına gidiyorsa ("" = uyarı yok; hoparlör kullanımı bilerek olabilir)
    static func routeWarning(_ outputs: [AVAudioSession.Port]) -> String {
        if outputs.contains(where: { $0 == .usbAudio || $0 == .lineOut }) {
            return "Ses mikrofon alıcısına gidiyor, kulaklıktan duyulmaz. Ses çıkışı simgesinden kulaklığı seçin."
        }
        return ""
    }

    /// Harici (Lightning/USB/kablolu) mikrofon varsa girişi ona sabitler; yoksa sistemin seçimine (telefon mikrofonu) bırakır.
    /// Ses düzeni 1'de giriş Bluetooth kulaklığın kendi mikrofonuna (HFP) sabitlenir.
    static func preferExternalMic(_ session: AVAudioSession = AVAudioSession.sharedInstance(), layout: Int = 0) {
        if layout == 1 {
            let headset = (session.availableInputs ?? []).first(where: { $0.portType == .bluetoothHFP })
            if session.preferredInput?.uid == headset?.uid { return }
            try? session.setPreferredInput(headset)
            return
        }
        let wanted: [AVAudioSession.Port] = [.usbAudio, .headsetMic, .lineIn]
        let inputs = session.availableInputs ?? []
        let external = inputs.first(where: { wanted.contains($0.portType) })
        // Zaten seçiliyse dokunma: gereksiz yönlendirme değişikliği ses motorunu yeniden başlatma döngüsüne sokabilir
        if session.preferredInput?.uid == external?.uid { return }
        try? session.setPreferredInput(external)
    }
}
