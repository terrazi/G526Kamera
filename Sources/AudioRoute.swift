import AVFoundation

/// Ses yönlendirmesi: Bluetooth kulaklık yalnızca ÇIKIŞ olarak (A2DP, yüksek kalite), mikrofon ise telefonun
/// Lightning/USB girişine takılı harici (kablosuz alıcılı) mikrofondan alınır.
enum AudioRoute {
    /// Bluetooth'un konuşma profili (HFP) bilerek kapalı: açık olsaydı kulaklığın kendi mikrofonu devreye girer
    /// ve kulaklık düşük kaliteli telefon sesine düşerdi. Yalnız A2DP (çıkış) açıktır.
    static let categoryOptions: AVAudioSession.CategoryOptions = [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP]

    /// Harici (Lightning/USB/kablolu) mikrofon varsa girişi ona sabitler; yoksa sistemin seçimine (telefon mikrofonu) bırakır.
    static func preferExternalMic(_ session: AVAudioSession = AVAudioSession.sharedInstance()) {
        let wanted: [AVAudioSession.Port] = [.usbAudio, .headsetMic, .lineIn]
        let inputs = session.availableInputs ?? []
        let external = inputs.first(where: { wanted.contains($0.portType) })
        try? session.setPreferredInput(external)
    }
}
