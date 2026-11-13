import Foundation

/// Modül 2 ve 4: fail-safe (ses donanımı koparsa anında sessiz ve duraklat), ölümcül sessizlik bekçisi, ağ izleme ve
/// Kestirmelerle kendi kendini onarma.
extension SessionViewModel {
    // MARK: Fail-safe (Modül 2)

    /// Bluetooth kulaklık ya da yaka mikrofonu koptu: ses anında susar, mikrofon kapanır, her iş durur. Donanım dönene
    /// (ya da `hardwareGrace` sonra sıfırlama kestirmesi çalışana) kadar hiçbir şey çalınmaz.
    func enterHardwarePause(_ verdict: RouteVerdict) {
        work?.cancel()
        work = nil
        deps.speaker.stop()
        deps.listener.pause()
        watchdog.disarm()
        cancelTimers()
        retryTask?.cancel()
        retryTask = nil
        let detail = verdict.hint.isEmpty ? verdict.summary : "\(verdict.summary). \(verdict.hint)"
        warn("donanim", "Duraklatıldı: \(detail)")
        statusNote = ""
        phase = .paused(.hardware(verdict.summary))
        hardwareGrace = deps.scheduler.after(Timing.hardwareGrace) { [weak self] in self?.hardwareGraceExpired() }
    }

    func routeChanged(_ snapshot: RouteSnapshot) {
        let verdict = AudioRouting.verdict(snapshot)
        routeVerdict = verdict
        switch phase {
        case .listening, .answering, .speaking:
            if !verdict.isSafe { enterHardwarePause(verdict) }
        case .paused(.hardware):
            stableTask?.cancel()
            stableTask = nil
            if verdict.isSafe {
                // Hemen değil, kısa süre sabit kalırsa devam et (yol bildirimleri art arda gelir)
                stableTask = deps.scheduler.after(Timing.routeStable) { [weak self] in self?.hardwareReturned() }
            }
        case .replaying:
            if !verdict.headphonesOK { replay.stop(reason: Say.noHeadphonesForReplay) }
        default:
            break
        }
    }

    func hardwareReturned() {
        stableTask = nil
        guard case .paused(.hardware) = phase, AudioRouting.verdict(deps.route.snapshot()).isSafe else { return }
        hardwareGrace?.cancel()
        hardwareGrace = nil
        clearWarning("donanim")
        work = Task { [weak self] in await self?.resumeAfterRecovery() }
    }

    func hardwareGraceExpired() {
        hardwareGrace = nil
        guard case .paused(.hardware) = phase else { return }
        work = Task { [weak self] in await self?.runRecovery(.hardware) }
    }

    // MARK: Ölümcül sessizlik (Modül 4)

    func silenceExpired() {
        guard phase == .listening else { return }
        work = Task { [weak self] in await self?.handleSilence() }
    }

    /// 30 sn tek kelime yok. Kullanıcı soruyu düşünüyor da olabilir; bu yüzden hemen Kestirme çalıştırılmaz:
    /// önce dinleme sessizce yenilenir (eldeki metin korunur) ve mikrofonun gerçekten ses verip vermediğine bakılır.
    /// Mikrofon canlıysa sorun yoktur, bekçi yeniden kurulur; değilse donanım kilitlenmiş sayılır ve onarım başlar.
    func handleSilence() async {
        accumulator.commitCurrent()
        deps.listener.pause()
        do {
            try deps.listener.start()
        } catch {
            await runRecovery(.hardware, force: true)
            return
        }
        await deps.sleep(Timing.silenceProbe)
        guard !Task.isCancelled, phase == .listening else { return }
        let alive = deps.listener.isRunning && (deps.listener.secondsSinceAudio ?? .infinity) < 3
        if alive && AudioRouting.verdict(deps.route.snapshot()).isSafe {
            watchdog.kick()
            return
        }
        await runRecovery(.hardware, force: true)
    }

    // MARK: Ağ (Modül 4)

    func networkChanged(_ online: Bool) {
        offlineCheck?.cancel()
        offlineCheck = nil
        if online {
            if case .paused(.noConnection) = phase {
                work = Task { [weak self] in await self?.reconnectIfHealthy() }
            }
            return
        }
        // Gemini beklenirken (.answering) kopma zaten istek hatasıyla yakalanır; okunurken (.speaking) dinlemeye dönünce bakılır
        if phase == .listening { scheduleOfflineCheck() }
    }

    func scheduleOfflineCheck() {
        offlineCheck?.cancel()
        offlineCheck = deps.scheduler.after(Timing.offlineDebounce) { [weak self] in self?.offlineConfirmed() }
    }

    func offlineConfirmed() {
        offlineCheck = nil
        guard phase == .listening, !deps.network.isOnline else { return }
        work = Task { [weak self] in await self?.runRecovery(.network) }
    }

    private func reconnectIfHealthy() async {
        guard await verify(.network, key: settings.apiKey) else { return }
        guard !Task.isCancelled, case .paused(.noConnection) = phase else { return }
        retryTask?.cancel()
        retryTask = nil
        await resumeAfterRecovery()
    }

    // MARK: Onarım (Modül 4)

    /// Onarım doğrulaması: ağda "internet var ve Gemini'ye ulaşılıyor", donanımda "ses yolu güvenli"
    func verify(_ reason: RecoveryReason, key: String) async -> Bool {
        switch reason {
        case .network: return await deps.health.connectionHealthy(key: key)
        case .hardware: return AudioRouting.verdict(deps.route.snapshot()).isSafe
        }
    }

    /// Mikrofon kapanır, Kestirmeler sırayla çalışır (Wi-Fi → hücresel → sıfırlama). Sonucu çağıran işler.
    func performRecovery(_ reason: RecoveryReason, force: Bool = false) async -> RecoveryCoordinator.Result {
        deps.listener.pause()
        watchdog.disarm()
        cancelTimers()
        phase = .recovering(reason)
        statusNote = "Sorun giderilmeye çalışılıyor…"
        let key = settings.apiKey
        return await recovery.recover(reason: reason,
                                      force: force,
                                      verify: { [weak self] reason in await self?.verify(reason, key: key) ?? false },
                                      update: { [weak self] update in self?.recoveryUpdated(update) })
    }

    func recoveryUpdated(_ update: RecoveryCoordinator.Update) {
        switch update {
        case .checking: statusNote = "Bağlantı sınanıyor…"
        case .running(let step): statusNote = "\(step.title) kestirmesi çalışıyor…"
        case .verifying(let step): statusNote = "\(step.title) kestirmesi bitti, bağlantı sınanıyor…"
        case .waiting(let cycle): statusNote = "\(cycle). tur başarısız, biraz sonra yeniden denenecek…"
        }
    }

    var canRecover: Bool {
        switch phase {
        case .listening, .answering, .speaking, .paused: return true
        default: return false
        }
    }

    /// `force`: sorun ses yoluna bakarak görülemiyorsa (mikrofon donmuş) Kestirmeler yine de çalıştırılır
    func runRecovery(_ reason: RecoveryReason, force: Bool = false) async {
        guard canRecover else { return }
        let result = await performRecovery(reason, force: force)
        guard !Task.isCancelled, case .recovering = phase else { return }
        switch result {
        case .recovered:
            await resumeAfterRecovery()
        case .notConfigured:
            warn("onarim", Say.notConfigured)
            pauseAfterFailedRecovery(reason)
        case .gaveUp:
            warn("onarim", "Kestirmeler sorunu gideremedi; \(Int(Timing.connectionRetry)) saniyede bir yeniden denenecek.")
            pauseAfterFailedRecovery(reason)
        }
    }

    private func pauseAfterFailedRecovery(_ reason: RecoveryReason) {
        switch reason {
        case .network:
            phase = .paused(.noConnection)
            statusNote = ""
            retryTask = deps.scheduler.after(Timing.connectionRetry) { [weak self] in self?.retryConnection() }
        case .hardware:
            enterHardwarePause(AudioRouting.verdict(deps.route.snapshot()))
        }
    }

    private func retryConnection() {
        retryTask = nil
        guard case .paused(.noConnection) = phase else { return }
        work = Task { [weak self] in await self?.runRecovery(.network) }
    }

    /// Sorun giderildi: ses yolu güvenliyse "yeniden hazır" anonsu ve dinleme; değilse sessizce donanım beklenir.
    /// Açılış kontrolü sırasında koptuysa kontrol baştan yapılır.
    func resumeAfterRecovery() async {
        let verdict = AudioRouting.verdict(deps.route.snapshot())
        guard verdict.isSafe else {
            enterHardwarePause(verdict)
            return
        }
        clearWarning("onarim")
        clearWarning("cevap")
        clearWarning("donanim")
        if pendingStart {
            pendingStart = false
            phase = .checking
            await runStartup()
            return
        }
        guard await speakNotice(Say.recovered) else { return }
        beginListening()
    }
}
