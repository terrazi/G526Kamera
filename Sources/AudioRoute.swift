import AVFoundation

/// Ses yönlendirmesi: Bluetooth kulaklık yalnızca ÇIKIŞ olarak (A2DP, yüksek kalite), mikrofon ise telefonun
/// Lightning/USB girişine takılı harici (kablosuz alıcılı) mikrofondan alınır.
enum AudioRoute {
    /// Bluetooth'un konuşma profili (HFP) bilerek kapalı: açık olsaydı kulaklığın kendi mikrofonu devreye girer
    /// ve kulaklık düşük kaliteli telefon sesine düşerdi. Yalnız A2DP (çıkış) açıktır.
    static let categoryOptions: AVAudioSession.CategoryOptions = [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP]

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

    /// Harici (Lightning/USB/kablolu) mikrofon varsa girişi ona sabitler; yoksa sistemin seçimine (telefon mikrofonu) bırakır.
    static func preferExternalMic(_ session: AVAudioSession = AVAudioSession.sharedInstance()) {
        let wanted: [AVAudioSession.Port] = [.usbAudio, .headsetMic, .lineIn]
        let inputs = session.availableInputs ?? []
        let external = inputs.first(where: { wanted.contains($0.portType) })
        try? session.setPreferredInput(external)
    }
}
