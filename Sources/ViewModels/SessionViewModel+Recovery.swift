import Foundation

/// Modül 2 ve 4: fail-safe (ses donanımı koparsa anında sessiz ve duraklat), ölümcül sessizlik bekçisi, ağ izleme ve
/// Kestirmelerle kendi kendini onarma.
extension SessionViewModel {
    // MARK: Fail-safe (Modül 2)

    /// Bluetooth kulaklık ya da yaka mikrofonu koptu: ses anında susar, mikrofon kapanır, her iş durur. Donanım dönene
    /// (ya da `grace` sonra sıfırlama kestirmesi çalışana) kadar hiçbir şey çalınmaz. `grace` nil ise sıfırlama denenmez.
    func enterHardwarePause(_ verdict: RouteVerdict, grace: TimeInterval? = Timing.hardwareGrace) {
        var detail = verdict.hint.isEmpty ? verdict.summary : "\(verdict.summary). \(verdict.hint)"
        if detail.isEmpty { detail = "ses yolu kararsız" }
        pauseForHardware(summary: verdict.summary, detail: detail, grace: grace)
    }

    func pauseForHardware(summary: String, detail: String, grace: TimeInterval?) {
        if outageStart == nil { outageStart = deps.now() }
        work?.cancel()
        work = nil
        deps.speaker.stop()
        deps.listener.pause()
        watchdog.disarm()
        cancelTimers()
        retryTask?.cancel()
        retryTask = nil
        warn("donanim", "Duraklatıldı: \(detail)")
        statusNote = ""
        phase = .paused(.hardware(summary))
        if let grace = grace {
            hardwareGrace = deps.scheduler.after(grace) { [weak self] in self?.hardwareGraceExpired() }
            scheduleQuickOutputFix()
        }
    }

    func routeChanged(_ snapshot: RouteSnapshot) {
        let verdict = AudioRouting.verdict(snapshot)
        routeVerdict = verdict
        tlog("[ses yolu] \(AudioRouting.describe(snapshot)) \(verdict.isSafe ? "Güvenli." : "Güvenli değil: " + verdict.summary)")
        refreshInputs()
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

    /// Arama, alarm ya da Siri sesi böldü: her şey susar ve durur (sıfırlama kestirmesi denenmez; aramayı keserdi).
    /// Kesinti bitince kendiliğinden devam edilir.
    func interrupted(_ began: Bool) {
        tlog("[kesinti] \(began ? "başladı (arama, alarm ya da Siri)" : "bitti")")
        guard began else {
            interruptionEnded()
            return
        }
        switch phase {
        case .listening, .answering, .speaking:
            interruptionActive = true
            pauseForHardware(summary: "ses kesintisi",
                             detail: "ses kesintisi (arama, alarm ya da Siri). Bitince kendiliğinden devam edilir.",
                             grace: nil)
            scheduleInterruptionPoll()
        case .paused(.hardware):
            // Zaten kulaklık/mikrofon beklemesinde: kesinti bitene kadar sıfırlama kestirmesi çalıştırılmaz
            interruptionActive = true
            hardwareGrace?.cancel()
            hardwareGrace = nil
            scheduleInterruptionPoll()
        case .replaying:
            replay.stop(reason: "Ses kesintisi yüzünden tekrar durdu.")
        default:
            break
        }
    }

    /// Kesinti bitti. Sistem ses oturumunu kapatmış olabilir: yeniden etkinleştirilip yol bakılır. Yol güvenli değilse
    /// normal donanım beklemesi (süre sonunda sıfırlama kestirmesi) başlar.
    private func interruptionEnded() {
        interruptionActive = false
        interruptionPoll?.cancel()
        interruptionPoll = nil
        guard case .paused(.hardware) = phase else { return }
        try? deps.route.configure()
        deps.route.preferExternalInput()
        if hardwareGrace == nil {
            hardwareGrace = deps.scheduler.after(Timing.hardwareGrace) { [weak self] in self?.hardwareGraceExpired() }
            scheduleQuickOutputFix()
        }
        recheckHardware()
    }

    /// Bitiş bildirimi hiç gelmezse yedek: ses oturumu yeniden açılabiliyorsa kesinti bitmiştir (aramada açılamaz)
    private func scheduleInterruptionPoll() {
        interruptionPoll?.cancel()
        interruptionPoll = deps.scheduler.after(Timing.interruptionPoll) { [weak self] in self?.pollInterruption() }
    }

    private func pollInterruption() {
        interruptionPoll = nil
        guard interruptionActive, case .paused(.hardware) = phase else { return }
        if (try? deps.route.configure()) != nil {
            interruptionEnded()
        } else {
            scheduleInterruptionPoll()
        }
    }

    /// Duraklatılmışsa ses yoluna yeniden bakar (kesinti bitti, uygulama öne geldi); güvenliyse sabit kalınca devam edilir
    func recheckHardware() {
        guard case .paused(.hardware) = phase else { return }
        if interruptionActive {
            // Kesinti sürüyor görünüyor: ses oturumu yeniden açılabiliyorsa bitiş bildirimi kaçırılmış demektir
            if (try? deps.route.configure()) != nil { interruptionEnded() }
            return
        }
        routeChanged(deps.route.snapshot())
    }

    func hardwareReturned() {
        stableTask = nil
        guard !interruptionActive, case .paused(.hardware) = phase,
              AudioRouting.verdict(deps.route.snapshot()).isSafe else { return }
        hardwareGrace?.cancel()
        hardwareGrace = nil
        outputQuick?.cancel()
        outputQuick = nil
        outputTries = 0          // yol döndü: çıkış kestirmesinin hakkı yenilenir
        hardwareRecoveries = 0   // kullanıcı donanımı düzeltti: sayaç sıfırlanır
        clearWarning("donanim")
        work = Task { [weak self] in await self?.resumeAfterRecovery() }
    }

    func hardwareGraceExpired() {
        hardwareGrace = nil
        guard !interruptionActive, case .paused(.hardware) = phase else { return }
        // Kulaklık sağlam, mikrofon alıcısı takılı, yalnız giriş yola girmemiş: bu bir kopma değil yönlendirme sorunudur. Bluetooth'u ya da
        // uçak modunu kapatıp açan Kestirme kulaklığı da koparıp sorunu büyütür ("ikide bir Kestirme çalışıyor"). Onun yerine mikrofon
        // tercihi yeniden verilir, nedeni yazılır ve beklenir; yol oturunca kendiliğinden devam edilir.
        let snapshot = deps.route.snapshot()
        if AudioRouting.verdict(snapshot).headphonesOK, snapshot.inputs.isEmpty,
           deps.route.availableInputs().contains(where: { $0.isExternal }) {
            tlog("[onarım] alıcı takılı ama girişte yok; Kestirme çalıştırılmadı, mikrofon yeniden seçiliyor")
            deps.route.preferExternalInput()
            warn("donanim", "Duraklatıldı: \(Say.receiverNotRouted)")
            hardwareGrace = deps.scheduler.after(Timing.hardwareGrace) { [weak self] in self?.hardwareGraceExpired() }
            routeChanged(deps.route.snapshot())
            return
        }
        work = Task { [weak self] in
            guard let self = self else { return }
            // Hemen çalıştırılan çıkış kestirmesi sürüyorsa bitmesi beklenir (iki kestirme iç içe çalışmaz); yol düzeldiyse devam edilir
            await self.outputQuickRun?.value
            guard !Task.isCancelled, case .paused(.hardware) = self.phase else { return }
            if AudioRouting.verdict(self.deps.route.snapshot()).isSafe { return }
            // Kulaklık yolda değilse önce hafif çare: çıkışı kulaklığa alan kestirme (Bluetooth'a dokunmaz)
            if await self.outputShortcutFixedRoute() { return }
            await self.runRecovery(.hardware)
        }
    }

    // MARK: Ölümcül sessizlik (Modül 4)

    func silenceExpired() {
        guard phase == .listening else { return }
        work = Task { [weak self] in await self?.handleSilence() }
    }

    /// 30 sn tek kelime yok. Kullanıcı soruyu düşünüyor da olabilir; bu yüzden hemen Kestirme çalıştırılmaz:
    /// önce dinleme sessizce yenilenir (eldeki metin korunur), mikrofonun gerçekten ses verdiğine ve bağlantının sağlam olduğuna
    /// bakılır. İkisi de sağlamsa sorun yoktur, bekçi yeniden kurulur; mikrofon donmuşsa ya da bağlantı takılmışsa onarım başlar.
    func handleSilence() async {
        accumulator.commitCurrent()
        englishAccumulator.commitCurrent()
        deps.listener.pause()
        do {
            try deps.listener.start()
        } catch {
            listenerFailed(error)
            return
        }
        await deps.sleep(Timing.silenceProbe)
        guard !Task.isCancelled, phase == .listening else { return }
        let micAlive = deps.listener.isRunning && (deps.listener.secondsSinceAudio ?? .infinity) < 3
        guard micAlive, AudioRouting.verdict(deps.route.snapshot()).isSafe else {
            await runRecovery(.hardware, force: true)
            return
        }
        // İnternet "var" görünüp takılmış olabilir: soru gelmeden önce bağlantıyı da yokla
        let healthy = await deps.health.connectionHealthy(key: settings.primaryKey)
        guard !Task.isCancelled, phase == .listening else { return }
        guard healthy else {
            await runRecovery(.network)
            return
        }
        watchdog.kick()
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

    func reconnectIfHealthy() async {
        guard await verify(.network, key: settings.primaryKey) else { return }
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
        if outageStart == nil { outageStart = deps.now() }
        deps.listener.pause()
        watchdog.disarm()
        cancelTimers()
        phase = .recovering(reason)
        statusNote = "Sorun giderilmeye çalışılıyor…"
        announce(reason == .network ? Say.networkLost : Say.hardwareRepairing)
        let key = settings.primaryKey
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
        if reason == .hardware, hardwareRecoveries >= Timing.maxHardwareRecoveries {
            // Art arda onarıldı ama mikrofon yine çalışmıyor: sonsuz sıfırlama döngüsüne girme, uyar, bir süre sonra bir kez daha dene
            hardwareRecoveries = Timing.maxHardwareRecoveries - 1
            warn("onarim", "Mikrofon art arda onarıldı ama çalışmıyor. Kulaklığı ve mikrofon alıcısını kontrol edin.")
            enterHardwarePause(AudioRouting.verdict(deps.route.snapshot()), grace: Timing.hardwareCapRetry)
            return
        }
        let result = await performRecovery(reason, force: force)
        guard !Task.isCancelled, case .recovering = phase else { return }
        switch result {
        case .recovered:
            if reason == .hardware { hardwareRecoveries += 1 }
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
            // Başarısız onarımdan sonra sıfırlamayı hemen değil, daha seyrek dene (her 20 sn'de uçak modu açıp kapatılmasın)
            enterHardwarePause(AudioRouting.verdict(deps.route.snapshot()), grace: Timing.connectionRetry)
        }
    }

    private func retryConnection() {
        retryTask = nil
        guard case .paused(.noConnection) = phase else { return }
        work = Task { [weak self] in await self?.runRecovery(.network) }
    }

    /// Sorun giderildi. Kestirme ya da kesinti sistemin ses oturumunu kapatmış olabilir, o yüzden önce yeniden etkinleştirilir.
    /// Ses yolu güvenliyse: açılış sırasında koptuysa kontrol baştan yapılır; cevap duyulamadan koptuysa o cevap yeniden okunur;
    /// aksi hâlde "yeniden hazır" anonsu ve dinleme. Güvenli değilse sessizce donanım beklenir.
    func resumeAfterRecovery() async {
        try? deps.route.configure()
        deps.route.preferExternalInput()
        let verdict = await settledRoute().verdict
        guard !Task.isCancelled else { return }
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
        if let record = unheard {
            // Cevap alınmış ve kaydedilmişti, yalnız kulaklıktan duyulamamıştı: soruyu yeniden okutmadan cevabı tekrar söyle
            guard await speakNotice(record.spoken) else { return }
            unheard = nil
            beginListening()
            return
        }
        let brief = settings.instantDetection && SessionViewModel.isBriefOutage(since: outageStart, now: deps.now())
        guard await speakNotice(brief ? Say.recoveredShort : Say.recovered) else { return }
        beginListening()
    }
}
