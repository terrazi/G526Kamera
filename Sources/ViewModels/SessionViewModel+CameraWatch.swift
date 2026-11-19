import Foundation

/// Kameraya ulaşılamıyor (kapalı, şarjı bitti, menzil dışı): 5 denemeden sonra kamera sistemden çıkar ve sınav sesle sürer (V3 gibi). Bu sırada
/// kamera 5 dakikada bir yoklanır. Yoklama telefonu kameranın Wi-Fi'sine geçirir, yani interneti birkaç saniye keser; bu yüzden yalnız sorular
/// arasında yapılır (soru okunmuyor, cevap beklenmiyor, hiçbir iş sürmüyor). Uygun an yoksa kısa süre sonra yeniden bakılır. Kamera dönünce kullanıcıya
/// "Kameraya N dakika M saniye boyunca ulaşılamıyordu, şu an itibarıyla düzeldi ve kamera kullanılabiliyor" denir ve kamera sorusu yeniden sorulmaya başlar.
extension SessionViewModel {
    /// 5 denemede kameraya ulaşılamadı: kamera sistemden çıkarılır, yoklama kurulur
    func markCameraDown(since: Date, attempts: Int = Timing.cameraRepairs + 1) {
        guard cameraDownSince == nil else { return }
        cameraDownSince = since
        tlog("[kamera] kameraya \(attempts) denemede ulaşılamadı; sesle devam ediliyor, \(Int(cameraProbeInterval)) sn'de bir yoklanacak")
        scheduleCameraProbe()
    }

    /// Kameranın yeniden kontrol aralığı: Ayarlar'daki dakika (1...60; varsayılan 5)
    var cameraProbeInterval: TimeInterval {
        return TimeInterval(AppSettings.clampCameraCheckMinutes(settings.cameraCheckMinutes) * 60)
    }

    func scheduleCameraProbe(after seconds: TimeInterval? = nil) {
        cameraProbeTask?.cancel()
        cameraProbeTask = deps.scheduler.after(seconds ?? cameraProbeInterval) { [weak self] in self?.cameraProbeDue() }
    }

    /// Yoklama zamanı geldi: uygun bir an mı (sorular arası boşluk), değilse kısa süre sonra yeniden bakılır
    func cameraProbeDue() {
        cameraProbeTask = nil
        guard cameraDownSince != nil else { return }
        switch phase {
        case .idle, .finished: return   // oturum bitti: yoklama durur
        default: break
        }
        guard cameraProbeIsSafe else {
            scheduleCameraProbe(after: Timing.cameraProbeRetry)
            return
        }
        work = Task { [weak self] in await self?.probeCamera() }
    }

    /// Hiçbir soru okunmuyor, cevap beklenmiyor, bekleyen iş yok: interneti kesmek kimseyi bölmez
    var cameraProbeIsSafe: Bool {
        return phase == .listening && listenMode == .question && accumulator.text.trimmed.isEmpty
            && heldQuestion == nil && passageDraft == nil && !cameraBusy && !reviewing && !interruptionActive
            && resendablePending == nil
    }

    /// Kameraya geçer, görüntü gelip gelmediğine bakar, internete döner ve sonucu söyler
    func probeCamera() async {
        guard let since = cameraDownSince, cameraConfigured, !cameraBusy else { return }
        cameraBusy = true
        defer { cameraBusy = false }
        closeListening()
        guard await speakNotice(Say.cameraChecking) else {
            tlog("[kamera] yoklama anonsu kesildi (kulaklık, arama ya da onarım); kısa süre sonra yeniden denenecek")
            scheduleCameraProbe(after: Timing.cameraProbeRetry)
            return
        }
        phase = .answering
        networkMayBeOnCamera = true   // kestirme çalışınca hücresel kapanır; internete dönüş doğrulanana kadar bayrak durur
        let stay = cameraSettings.stayOnWifi
        statusNote = stay ? "Kamera kontrol ediliyor" : "Kamera kontrol ediliyor (hücresel kesiliyor)"
        let cameraName = cameraSettings.cameraShortcutName.trimmed
        let internetName = settings.internetShortcut.trimmed
        let camera = deps.camera
        func probeOnce() async -> Bool {
            return await withTaskCancellationHandler {
                await camera.probe()
            } onCancel: {
                Task { @MainActor in camera.cancel() }
            }
        }
        var outcome: ShortcutOutcome = .success
        var reachable = false
        if stay {
            // Bağlantılar hep açık: telefon kameranın Wi-Fi'sindedir, önce doğrudan bakılır; görünmezse Wi-Fi onarım kestirmesi (Wi-Fi kapat-aç) bir kez
            // çalışır ve yeniden bakılır. Hücreseli kapatan "Kameraya geç" yalnız onarım kestirmesi yazılı değilse çalışır.
            tlog("[kamera] yoklama (bağlantılar hep açık): doğrudan bağlanılıyor")
            reachable = await probeOnce()
            if !reachable, !Task.isCancelled, phase == .answering {
                let repair = settings.shortcutName(for: .wifi)
                let name = repair.isEmpty ? cameraName : repair
                tlog("[kamera] yoklama: kamera görünmedi; kestirme “\(name)” çalıştırılıyor")
                outcome = await runShortcutRetryingTransient(name: name)
                if !Task.isCancelled, phase == .answering, outcome == .success || outcome == .timedOut {
                    reachable = await probeOnce()
                }
            }
        } else {
            tlog("[kamera] yoklama: kameraya geçiliyor, kestirme “\(cameraName)”")
            outcome = await runShortcutRetryingTransient(name: cameraName)
            if !Task.isCancelled, phase == .answering, outcome == .success || outcome == .timedOut {
                reachable = await probeOnce()
            }
        }
        tlog("[kamera] yoklama sonucu: kestirme \(outcome), kamera \(reachable ? "göründü" : "yok")")
        statusNote = internetNote
        guard !Task.isCancelled, phase == .answering else {
            statusNote = ""
            scheduleCameraProbe(after: Timing.cameraProbeRetry)   // kesinti (kulaklık, arama, onarım): internete dönüşü onarım üstlenir
            return
        }
        let online = await returnToInternet(shortcut: internetName)
        if online { networkMayBeOnCamera = false }
        statusNote = ""
        guard !Task.isCancelled, phase == .answering else {
            scheduleCameraProbe(after: Timing.cameraProbeRetry)
            return
        }
        let text: String
        if reachable {
            let seconds = max(0, Int(deps.now().timeIntervalSince(since).rounded()))
            tlog("[kamera] kamera döndü (\(seconds) sn ulaşılamamıştı); yeniden sisteme alındı")
            cameraDownSince = nil
            clearWarning("kamera")
            armCameraOffer()   // sıradaki soru için kamera sorusu yeniden sorulur
            text = Say.cameraBack(seconds: seconds)
        } else {
            scheduleCameraProbe()
            text = Say.cameraStillDown
        }
        if online {
            guard await speakNotice(text) else { return }
            beginListening(mode: .question)
        } else {
            await repairInternetAfterCamera(text)
        }
    }
}
