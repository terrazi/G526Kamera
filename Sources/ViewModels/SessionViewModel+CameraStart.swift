import Foundation

/// Sürüm 4: oturum başında kameraya hemen bağlanma (kullanıcı kararı 2026-11-16). Ayarlar'daki "Kamerayı dene" yolunun aynısı, "Başlat"a gömülüdür:
/// kameraya geç kestirmesi, kameraya bağlanma (görüntü ana ekranda akar), kamerayı kapatma, hücresele geç kestirmesi ve internetin gelmesi.
extension SessionViewModel {
    /// 1. adım: "Başlat"a basılınca açılış kontrolünün EN BAŞINDA, kulaklık ve mikrofon beklenmeden çalışır. Telefon kameranın Wi-Fi'sine geçer
    /// (hücresel kapanır), kameraya bağlanır; görüntü ana ekrandaki kutuda akar ve bağlantı AÇIK kalır. Bu adım sessizdir (ses yolu henüz doğrulanmadı):
    /// kameranın uyarıları biriktirilir, 2. adımda söylenir. Bağlanılamazsa en çok `Timing.cameraStartRepairs` onarım denenir.
    ///
    /// Dönen değer: false → açılış kesildi (iptal, durum değişti); açılış kontrolü yol dönünce baştan yapılır.
    func connectCameraAtStart() async -> Bool {
        // Toplu çekim açıksa her zaman: program DİREKT kameraya geçer ("Başlatınca kameraya hemen bağlan" ayarına bakılmaz)
        // Kamera "Başla"dan sonra açılıyorsa (toplu çekim, kullanıcı kararı 2026-11-17) açılışta kameraya HİÇ bağlanılmaz: kamera yalnız çekimde açıktır
        let wanted = seriesAfterGo ? false : (cameraSettings.connectAtStart || cameraSettings.pageSeries)
        guard wanted, resume == nil, cameraStartConnected == nil, cameraOfferAvailable else { return true }
        let cameraName = cameraSettings.cameraShortcutName.trimmed
        let camera = deps.camera
        cameraBusy = true   // kamera akışı sürüyor: takılma gözcüsü uzun sınır tanır; iş iptal edilirse kamera da kapanır
        networkMayBeOnCamera = true   // kestirme çalışınca hücresel kapanır; internete dönüş doğrulanana kadar bayrak durur
        cameraStartNotes = []
        camera.onSay = { [weak self] text in self?.cameraStartNotes.append(text) }
        camera.onStatus = { [weak self] text in self?.statusNote = text }
        statusNote = "Kameraya geçiliyor (hücresel kesiliyor)"
        tlog("[kamera] oturum başı: hücresel kesilip kameranın Wi-Fi ağına geçiliyor, kestirme “\(cameraName)”")

        var connected = false
        var repairMissing = false
        var resetDone = false
        for attempt in 0...Timing.cameraStartRepairs {
            var name = cameraName
            if attempt > 0 {
                let repair = settings.shortcutName(for: .wifi)
                name = repair.isEmpty || repairMissing ? cameraName : repair
                var afterReset = false
                if attempt == Timing.cameraResetAfter, !resetDone, !settings.shortcutName(for: .reset).isEmpty {
                    // İki deneme sonuçsuz: uçak moduyla telsizler baştan kurulur (oturum başı sessizdir: duyuru yok), sonra kameraya geç kestirmesi
                    resetDone = true
                    afterReset = true
                    await resetConnectionsForCamera(announce: false)
                    guard !Task.isCancelled, phase == .checking else {
                        abandonCameraStart()
                        return false
                    }
                    name = cameraName
                }
                statusNote = "Kamera bağlantısı onarılıyor (\(attempt). deneme)"
                tlog("[kamera] oturum başı: bağlantı onarımı \(attempt). deneme, kestirme “\(name)”\(afterReset ? " (bağlantı sıfırlamadan sonra)" : "")")
            }
            let outcome = await runShortcutRetryingTransient(name: name)
            tlog("[kamera] oturum başı: kestirme sonucu \(outcome)")
            if name == cameraName {
                await bringHeadsetBackAfterCameraShortcut(outcome)   // toplu çekim: uçak modu kulaklığı düşürdü, Bluetooth yeniden açılır
                if outcome == .success || outcome == .timedOut { await ensureWiFiAfterCameraShortcut() }   // telefon kamera ağına girmediyse Wi-Fi kapat-aç hemen
            }
            if case .failed(let message) = outcome, SessionViewModel.isMissingShortcutError(message), attempt > 0, name != cameraName {
                repairMissing = true
                tlog("[kamera] “\(name)” kestirmesi bu telefonda yok; sonraki denemede kameraya geçiş kestirmesi çalışır")
            }
            guard !Task.isCancelled, phase == .checking else {
                tlog("[kamera] oturum başı: kestirmeden dönüşte iş iptal edilmiş ya da durum değişmiş (\(phase)); açılış kontrolü baştan yapılacak")
                abandonCameraStart()
                return false
            }
            // Kestirme çalışmasa da denenir: telefon kameranın ağına elle geçmiş olabilir (Ayarlar'daki deneme de böyle yapar)
            let limit: TimeInterval? = attempt == 0 ? Timing.cameraStartFirstConnect : nil
            let result = await withTaskCancellationHandler {
                await camera.holdOpen(connectLimit: limit)
            } onCancel: {
                Task { @MainActor in camera.cancel() }
            }
            guard !Task.isCancelled, phase == .checking else {
                abandonCameraStart()
                return false
            }
            if case .success = result {
                connected = true
                break
            }
            if case .failure(let failure) = result { tlog("[kamera] oturum başı: bağlanılamadı: \(failure.message)") }
        }
        cameraStartConnected = connected
        statusNote = connected ? "Kamera bağlı, görüntü geliyor" : ""
        return true
    }

    /// 2. adım: ses yolu doğrulandıktan sonra, internet adımından ÖNCE. Kameranın biriken uyarıları ve "Kamera bağlandı" söylenir (görüntü hâlâ ekranda akar),
    /// sonra kamera bağlantısı kapanır (ilk hücresel bağlantıdan önce), hücresele geç kestirmesi çalışır ve internetin gelmesi beklenir.
    /// Kameraya ulaşılamadıysa kamera sistemden çıkar (sorular sesle okunur, kamera yoklanır).
    ///
    /// Dönen değer: false → açılış kesildi; açılış kontrolü yol dönünce baştan yapılır.
    func finishCameraStart() async -> Bool {
        guard let connected = cameraStartConnected, !cameraStartDone else { return true }
        let camera = deps.camera
        let internetName = settings.internetShortcut.trimmed
        pendingStart = true
        defer {
            camera.onSay = nil
            camera.onStatus = nil
            camera.closeHeld()
            cameraBusy = false
        }
        if connected {
            clearWarning("kamera")
            var detail = "bağlandı, görüntü geldi"
            if let level = camera.lastBattery {
                detail += "; " + level.shortText
                tlog("[kamera] oturum başı: kamera pili: \(level.shortText)")
            }
            setCheck("kameraBaglanti", "Kamera bağlantısı", ok: true, detail: detail)
            if !cameraStartSpoken {
                for note in cameraStartNotes + [Say.cameraStartOK] {
                    guard await speakNotice(note) else { return false }
                }
                cameraStartSpoken = true
                phase = .checking
                await deps.sleep(Timing.cameraStartShow)   // görüntü gözle görülsün: anonsla birlikte en az birkaç sn ekranda akar
                guard !Task.isCancelled, phase == .checking else { return false }
            }
        } else {
            setCheck("kameraBaglanti", "Kamera bağlantısı", ok: false, detail: "bağlanılamadı; sorular sesle okunacak")
        }
        cameraStartNotes = []
        camera.closeHeld()   // ilk hücresel bağlantıdan önce kamera bağlantısı kapanır
        statusNote = internetNote
        tlog("[kamera] oturum başı: kamera bağlantısı kapatıldı, internete geçiliyor")
        let online = await returnToInternet(shortcut: internetName)
        if online { networkMayBeOnCamera = false }
        statusNote = ""
        guard !Task.isCancelled, phase == .checking else { return false }
        if !connected { markCameraDown(since: deps.now(), attempts: Timing.cameraStartRepairs + 1) }
        cameraStartDone = true
        pendingStart = false
        return true
    }

    /// Açılış kontrolü kesilince: açık bağlantı kapanır, kamera akışı bitmiş sayılır (kontrol baştan yapılırken yeniden denenir)
    private func abandonCameraStart() {
        let camera = deps.camera
        camera.closeHeld()
        camera.onSay = nil
        camera.onStatus = nil
        cameraBusy = false
    }
}
