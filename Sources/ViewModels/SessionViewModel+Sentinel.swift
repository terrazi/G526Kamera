import Foundation

/// İnternet yolunun nabız durumu (ana ekrandaki "Canlı" satırı için)
enum NetPulse: Equatable {
    case unknown, up, suspect, down
}

/// Anında tespit ("nabız"). iOS bildirimleri kopmayı geç ya da hiç bildirmeyebilir: ses servisi çökünce önceden hiçbir bildirim gelmez,
/// Wi-Fi "bağlı" görünüp ölü olabilir, ses motoru sessizce durabilir. Bu yüzden kopma olay beklenmeden, kısa aralıklarla ölçülür:
/// - Mikrofon: dinlerken yarım saniyede bir ses tamponunun geldiğine bakılır; bir saniyeden uzun gelmezse dinleme hemen yeniden kurulur
///   (yarım metin korunur). Art arda başarısız olursa Kestirmeler çalışır.
/// - Ses servisi çökmesi ve motor yapılandırma değişimi bildirimi gelir gelmez aynı onarım başlar.
/// - İnternet: her 5 saniyede bir (ağ yolu değişince hemen) hafif yoklama; art arda iki nabız yoksa onarım başlar. Bağlantı yokken
///   (duraklatılmış) her 2 saniyede bir bakılır: internet dönünce dönüş bildirimi ya da 60 sn'lik yeniden deneme beklenmez.
/// - Donanım duraklamasında yolun geri geldiği bildirim gelmese de görülür.
/// Her şey `settings.instantDetection` ile kapatılabilir.
extension SessionViewModel {
    // MARK: Nabız döngüsü

    /// Oturum başlayınca kurulur (zaten kuruluysa dokunmaz). Oturum bitince döngü kendiliğinden durur.
    func startSentinel() {
        guard settings.instantDetection, sentinel == nil else { return }
        sentinel = deps.scheduler.after(Timing.sentinelTick) { [weak self] in self?.sentinelTick() }
    }

    func sentinelTick() {
        sentinel = nil
        guard settings.instantDetection, phase.isRunning else {
            if !liveStatus.isEmpty { liveStatus = "" }
            return
        }
        watchMic()
        watchReturns()
        netBeatTicks += 1
        var every = Timing.netBeatEvery
        if case .paused(.noConnection) = phase { every = Timing.netPausedBeatEvery }
        if netBeatTicks >= every {
            netBeatTicks = 0
            netBeat("nabız")
        }
        refreshLiveStatus()
        sentinel = deps.scheduler.after(Timing.sentinelTick) { [weak self] in self?.sentinelTick() }
    }

    // MARK: Mikrofon

    /// Dinlerken mikrofon tamponları kesildiyse hemen onarır
    func watchMic() {
        guard phase == .listening else { return }
        if micCooldown > 0 {
            micCooldown -= 1
            return
        }
        let age = deps.listener.secondsSinceAudio
        let stalled = !deps.listener.isRunning || (age ?? .infinity) > Timing.micStallLimit
        guard stalled else {
            micAlive = true
            micOKTicks += 1
            if micOKTicks >= Timing.micHealthyTicks { micHealCount = 0 }
            return
        }
        micAlive = false
        micOKTicks = 0
        let seen = age.map { String(format: "%.1f sn", $0) } ?? "hiç"
        healMic("ses tamponu \(seen) gelmedi")
    }

    /// Dinlemeyi hemen yeniden kurar. Eldeki yarım metin korunur (soru sesi de kayda devam eder). Yol güvenli değilse donanım
    /// beklemesine geçilir; art arda `maxMicHeals` onarım işe yaramazsa Kestirmelere başvurulur.
    func healMic(_ reason: String, counted: Bool = true) {
        guard settings.instantDetection, phase == .listening else { return }
        if counted { micHealCount += 1 }
        micCooldown = Timing.micWarmupTicks
        tlog("[tespit] mikrofon: \(reason) (\(micHealCount). onarım)")
        if micHealCount > Timing.maxMicHeals {
            micHealCount = 0
            warn("mikrofon", "Mikrofon art arda yeniden kurulamadı; Kestirmelerle onarılıyor.")
            work = Task { [weak self] in await self?.runRecovery(.hardware, force: true) }
            return
        }
        accumulator.commitCurrent()
        englishAccumulator.commitCurrent()
        deps.listener.pause()
        try? deps.route.configure()
        deps.route.preferExternalInput()
        let verdict = AudioRouting.verdict(deps.route.snapshot())
        guard verdict.isSafe else {
            enterHardwarePause(verdict)
            return
        }
        do {
            try deps.listener.start()
        } catch {
            listenerFailed(error)
            return
        }
        watchdog.kick()
    }

    // MARK: Donanım dönüşü ve ses servisi

    /// Donanım duraklamasında yol bildirimi gelmeden düzeldiyse devam edilmesini başlatır
    func watchReturns() {
        guard case .paused(.hardware) = phase, work == nil, stableTask == nil, !interruptionActive, !holdForRetry,
              AudioRouting.verdict(deps.route.snapshot()).isSafe else { return }
        tlog("[tespit] ses yolu geri geldi (bildirim gelmeden); devam ediliyor")
        stableTask = deps.scheduler.after(Timing.routeStable) { [weak self] in self?.hardwareReturned() }
    }

    /// iOS'un ses servisi çöktü ya da sıfırlandı: her şey durur, ses oturumu hemen baştan kurulur ve devam edilir
    func mediaServicesReset() {
        guard settings.instantDetection else { return }
        switch phase {
        case .listening, .answering, .speaking:
            tlog("[tespit] ses servisi sıfırlandı; ses oturumu yeniden kuruluyor")
            pauseForHardware(summary: "ses servisi", detail: "ses servisi yeniden kuruluyor", grace: Timing.hardwareGrace)
            _ = deps.scheduler.after(Timing.mediaHealDelay) { [weak self] in self?.healAfterMediaReset() }
        case .paused(.hardware):
            _ = deps.scheduler.after(Timing.mediaHealDelay) { [weak self] in self?.healAfterMediaReset() }
        default:
            break
        }
    }

    /// Ses oturumunu yeniden etkinleştirir; servis henüz dönmediyse (hata) 1 sn arayla 5 kez dener, sonra eski süre dolumu sürer
    func healAfterMediaReset(attempt: Int = 1) {
        guard case .paused(.hardware) = phase else { return }
        do {
            try deps.route.configure()
        } catch {
            guard attempt < 5 else { return }
            _ = deps.scheduler.after(1) { [weak self] in self?.healAfterMediaReset(attempt: attempt + 1) }
            return
        }
        deps.route.preferExternalInput()
        recheckHardware()
    }

    // MARK: İnternet

    /// Ağ yolu değişti (Wi-Fi ↔ hücresel, bağlandı, koptu): nabız beklenmeden hemen yoklanır
    func networkPathChanged() {
        guard settings.instantDetection else { return }
        netBeat("ağ yolu değişti")
    }

    /// Tek hafif yoklama. Dinlerken art arda `netFailLimit` yoklama başarısızsa onarım başlar; bağlantı yokken (duraklatılmış)
    /// bir yoklama başarılı olursa devam edilir.
    func netBeat(_ reason: String) {
        guard settings.instantDetection, !netProbeBusy else { return }
        switch phase {
        case .listening, .paused(.noConnection): break
        default: return
        }
        netProbeBusy = true
        Task { [weak self] in
            guard let self = self else { return }
            let ok = await self.deps.health.quickProbe()
            self.netProbeBusy = false
            self.netBeatDone(ok: ok, reason: reason)
        }
    }

    private func netBeatDone(ok: Bool, reason: String) {
        guard settings.instantDetection else { return }
        if ok {
            if netPulse != .up { tlog("[tespit] internet nabzı var (\(reason))") }
            netPulse = .up
            netFails = 0
            if case .paused(.noConnection) = phase, !netReconnecting {
                tlog("[tespit] internet geri geldi; bağlantı sınanıp devam ediliyor")
                netReconnecting = true
                work = Task { [weak self] in
                    await self?.reconnectIfHealthy()
                    self?.netReconnecting = false
                }
            }
            return
        }
        guard phase == .listening else { return }
        if let until = netMutedUntil, deps.now() < until {
            netFails = 0
            return   // nabız yakın zamanda boşuna alarm verdi: bir süre onarım başlatmaz (ağ yolu ve istek hataları yine yakalar)
        }
        netFails += 1
        guard netFails >= Timing.netFailLimit else {
            netPulse = .suspect
            netBeatTicks = max(0, Timing.netBeatEvery - Timing.netRetryTicks)   // bir sonraki yoklama ~1 sn sonra
            return
        }
        netPulse = .down
        netFails = 0
        tlog("[tespit] internet nabzı yok (\(reason)); bağlantı sınanıyor")
        work = Task { [weak self] in
            guard let self = self else { return }
            self.lastNetworkAlarmWasFalse = false
            await self.runRecovery(.network)
            if self.lastNetworkAlarmWasFalse { self.noteFalseNetAlarm() }
        }
    }

    /// Nabız "internet yok" dedi ama tam sınama (internet + Gemini) sağlam çıktı: yoklama yanlış alarm verdi. Art arda olursa nabızla
    /// onarım `netMuteSeconds` boyunca susturulur; dinleme hiç kesilmez.
    func noteFalseNetAlarm() {
        lastNetworkAlarmWasFalse = false
        netFalseAlarms += 1
        netPulse = .up
        tlog("[tespit] nabız yanlış alarm verdi (\(netFalseAlarms). kez): internet ve Gemini sağlam, dinleme sürüyor")
        if netFalseAlarms >= Timing.netFalseAlarmLimit {
            netFalseAlarms = 0
            netMutedUntil = deps.now().addingTimeInterval(Timing.netMuteSeconds)
            tlog("[tespit] nabızla internet onarımı \(Int(Timing.netMuteSeconds)) sn susturuldu")
        }
    }

    // MARK: Canlı durum

    /// Ana ekrandaki "Canlı: Kulaklık ✓ · Mikrofon ✓ · İnternet ✓" satırı
    func refreshLiveStatus() {
        let headphones: String
        switch routeVerdict?.headphonesOK {
        case .some(true): headphones = "Kulaklık ✓"
        case .some(false): headphones = "Kulaklık ✗"
        case .none: headphones = "Kulaklık —"
        }
        let mic: String
        switch phase {
        case .listening: mic = micAlive ? "Mikrofon ✓" : "Mikrofon ✗"
        case .paused(.hardware): mic = "Mikrofon ✗"
        default: mic = "Mikrofon —"
        }
        let net: String
        switch netPulse {
        case .up: net = "İnternet ✓"
        case .down: net = "İnternet ✗"
        case .suspect: net = "İnternet ?"
        case .unknown: net = "İnternet —"
        }
        let text = "Canlı: " + [headphones, mic, net].joined(separator: " · ")
        if liveStatus != text { liveStatus = text }
    }

    // MARK: Kısa kesinti

    /// Kesinti kısaysa dönüşte uzun anons yerine kısa anons söylenir
    static func isBriefOutage(since start: Date?, now: Date) -> Bool {
        guard let start = start else { return false }
        return now.timeIntervalSince(start) < Timing.briefOutage
    }
}
