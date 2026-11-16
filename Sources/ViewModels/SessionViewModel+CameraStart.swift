import Foundation

/// Sürüm 4: oturum başında kameraya hemen bağlanma (kullanıcı kararı 2026-11-16)
extension SessionViewModel {
    /// "Başlat"a basılınca (ses yolu doğrulandıktan sonra, internet adımından ÖNCE) telefon kameranın Wi-Fi'sine geçer (hücresel kapanır), kameraya
    /// bağlanır ve görüntü ana ekrandaki kutuda akar. Bağlantı, ilk hücresel bağlantı kurulmadan önce kapatılır; sonra internete dönülür ve
    /// her soruda eski düzen sürer (kameraya geç → çek → kamerayı kapat → hücresel). Bağlanılamazsa (kapalı, şarjı bitti, menzil dışı) birkaç onarım
    /// denenir; olmazsa kamera sistemden çıkarılır, sorular sesle okunur ve kamera yoklanır (çekim sırasındaki gibi).
    ///
    /// Dönen değer: false → açılış kesildi (kulaklık, arama, iptal); açılış kontrolü yol dönünce baştan yapılır.
    func connectCameraAtStart() async -> Bool {
        guard cameraSettings.connectAtStart, resume == nil, !cameraStartDone, cameraOfferAvailable else { return true }
        let cameraName = cameraSettings.cameraShortcutName.trimmed
        let internetName = settings.internetShortcut.trimmed
        let startedAt = deps.now()
        let camera = deps.camera
        pendingStart = true
        guard await speakNotice(Say.cameraConnecting) else {
            tlog("[kamera] oturum başı: “Kameraya geçiliyor” anonsu kesildi; açılış kontrolü yol dönünce baştan yapılacak")
            return false
        }
        phase = .checking
        cameraBusy = true   // kamera akışı sürüyor: takılma gözcüsü uzun sınır tanır, yönlendirme cümleleri söylenebilir
        networkMayBeOnCamera = true   // kestirme çalışınca hücresel kapanır; internete dönüş doğrulanana kadar bayrak durur
        camera.onSay = { [weak self] text in self?.sayGuidance(text) }
        camera.onStatus = { [weak self] text in self?.statusNote = text }
        defer {
            camera.onSay = nil
            camera.onStatus = nil
            camera.closeHeld()
            cameraBusy = false
        }
        statusNote = "Kameraya geçiliyor (hücresel kesiliyor)"
        tlog("[kamera] oturum başı: hücresel kesilip kameranın Wi-Fi ağına geçiliyor, kestirme “\(cameraName)”")

        var connected = false
        var repairMissing = false
        for attempt in 0...Timing.cameraStartRepairs {
            var name = cameraName
            if attempt > 0 {
                let repair = settings.shortcutName(for: .wifi)
                name = repair.isEmpty || repairMissing ? cameraName : repair
                statusNote = "Kamera bağlantısı onarılıyor (\(attempt). deneme)"
                tlog("[kamera] oturum başı: bağlantı onarımı \(attempt). deneme, kestirme “\(name)”")
                sayGuidance(Say.cameraRepairing)
            }
            let outcome = await runShortcutRetryingTransient(name: name)
            tlog("[kamera] oturum başı: kestirme sonucu \(outcome)")
            if case .failed(let message) = outcome, SessionViewModel.isMissingShortcutError(message), attempt > 0, name != cameraName {
                repairMissing = true
                tlog("[kamera] “\(name)” kestirmesi bu telefonda yok; sonraki denemede kameraya geçiş kestirmesi çalışır")
            }
            guard !Task.isCancelled, phase == .checking else {
                tlog("[kamera] oturum başı: kestirmeden dönüşte iş iptal edilmiş ya da durum değişmiş (\(phase)); açılış kontrolü baştan yapılacak")
                return false
            }
            // Kestirme çalışmasa da denenir: telefon kameranın ağına elle geçmiş olabilir (Ayarlar'daki deneme de böyle yapar)
            let result = await withTaskCancellationHandler {
                await camera.holdOpen()
            } onCancel: {
                Task { @MainActor in camera.cancel() }
            }
            await waitForGuidanceSpeech()   // kamera pili düşükse söylenen uyarı bitsin
            guard !Task.isCancelled, phase == .checking else { return false }
            if case .success = result {
                connected = true
                break
            }
            if case .failure(let failure) = result { tlog("[kamera] oturum başı: bağlanılamadı: \(failure.message)") }
        }

        if connected {
            clearWarning("kamera")
            setCheck("kameraBaglanti", "Kamera bağlantısı", ok: true, detail: "bağlandı, görüntü geldi")
            // Görüntü ekranda akarken söylenir; sonra bağlantı kapanır ve internete geçilir
            guard await speakNotice(Say.cameraStartOK) else { return false }
            phase = .checking
        } else {
            setCheck("kameraBaglanti", "Kamera bağlantısı", ok: false, detail: "bağlanılamadı; sorular sesle okunacak")
        }
        camera.closeHeld()   // ilk hücresel bağlantıdan önce kamera bağlantısı kapanır
        statusNote = internetNote
        tlog("[kamera] oturum başı: kamera bağlantısı kapatıldı, internete geçiliyor")
        let online = await returnToInternet(shortcut: internetName)
        if online { networkMayBeOnCamera = false }
        statusNote = ""
        guard !Task.isCancelled, phase == .checking else { return false }
        if !connected { markCameraDown(since: startedAt, attempts: Timing.cameraStartRepairs + 1) }
        cameraStartDone = true
        pendingStart = false
        return true
    }
}
