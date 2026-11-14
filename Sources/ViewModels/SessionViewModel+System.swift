import Foundation

/// Öngörülemeyen sistem sorunlarına karşı genel güvenlik ağları. Belirli bir arızayı tek tek tahmin etmek yerine telefonun kaynak durumu izlenir
/// (bellek, ısı, güç modu, boş yer), beklenmedik kapanma bir sonraki açılışta bildirilir ve hiçbir aşamanın sonsuza dek takılı kalmasına izin verilmez.
///
/// - Bellek: iOS bellek uyarısı verince (ya da kalan bellek azalınca) ağır olan yardımcı İngilizce tanıyıcı bırakılır, kullanıcıya söylenir.
///   Bellek yeniden rahatlayınca (ya da yeni oturumda) tanıyıcı geri açılır. Bellek durumu dakikada bir günlüğe yazılır.
/// - Isı: "ciddi" ve "kritik" düzeyde uyarılır, yük azaltılır; normale dönünce uyarı silinir.
/// - Düşük güç modu ve az boş yer: oturum açılırken ve (yer için) dakikada bir denetlenir.
/// - Beklenmedik kapanma (RunJournal, ExitAnalyzer, `launched`): oturum açıkken deftere bayrak ve her 5 sn'de nabız yazılır; günlük diske
///   yazılır. Uygulama yeniden açılınca bayrak duruyorsa günlük taranıp olası neden bulunur, oturum kendiliğinden yeniden başlar ve
///   yarım kalan soru tamamlanır.
/// - Takılma gözcüsü: "kontrol ediliyor", "cevap bekleniyor", "okunuyor" ve "onarılıyor" aşamaları belirli süreden uzun hiç değişmezse
///   iş iptal edilir ve oturum kendiliğinden yeniden kurulur. Duraklatmalar (donanım, bağlantı, elle) sınırsız bekleyebilir.
extension SessionViewModel {
    // MARK: Oturum açılırken

    /// Oturum açılırken kaynak durumuna bakılır: az bellek, ısı, düşük güç modu ve az boş yer uyarılır, gerekirse yük azaltılır
    func checkSystemAtStart() {
        let snapshot = deps.system.snapshot()
        tlog("[sistem] açılış: \(snapshot.line)")
        if snapshot.lowPowerMode { warn("guc", Say.lowPowerMode) } else { clearWarning("guc") }
        applyThermal(snapshot.thermal)
        applyDisk(snapshot.freeDiskMB)
        if let left = snapshot.availableMemoryMB, left < Timing.lowMemoryMB { handleLowMemory("açılışta kalan bellek \(left) MB") }
    }

    // MARK: Sistemin bildirimleri

    func memoryWarningReceived() {
        let snapshot = deps.system.snapshot()
        tlog("[sistem] iOS bellek uyarısı verdi: \(snapshot.line)")
        guard phase.isRunning else { return }
        handleLowMemory("iOS bellek uyarısı")
    }

    func thermalChanged() {
        let snapshot = deps.system.snapshot()
        tlog("[sistem] ısı değişti: \(DeviceInfo.thermalText(snapshot.thermal))")
        guard phase.isRunning else { return }
        applyThermal(snapshot.thermal)
    }

    func powerModeChanged() {
        let snapshot = deps.system.snapshot()
        tlog("[sistem] güç modu: \(snapshot.lowPowerMode ? "düşük güç açıldı" : "normale döndü")")
        guard phase.isRunning else { return }
        if snapshot.lowPowerMode { warn("guc", Say.lowPowerMode) } else { clearWarning("guc") }
    }

    // MARK: Tepkiler

    /// Yükü azaltır (yardımcı İngilizce tanıyıcı bırakılır), kullanıcıya söyler. Oturum sürer.
    private func handleLowMemory(_ why: String) {
        tlog("[sistem] bellek az (\(why)); yük azaltılıyor")
        if !memoryLowActive {
            memoryLowActive = true
            deps.listener.trimMemory(true)
        }
        warn("bellek", Say.memoryLow)
    }

    private func applyThermal(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .serious, .critical:
            if !thermalTrimmed {
                thermalTrimmed = true
                deps.listener.trimMemory(true)
            }
            warn("isi", state == .critical ? Say.veryHot : Say.hot)
        default:
            clearWarning("isi")
            if thermalTrimmed {
                thermalTrimmed = false
                if !memoryLowActive { deps.listener.trimMemory(false) }
            }
        }
    }

    private func applyDisk(_ freeMB: Int?) {
        if let free = freeMB, free < Timing.lowDiskMB {
            warn("yer", Say.lowDisk(free))
        } else {
            clearWarning("yer")
        }
    }

    // MARK: Dakikada bir

    /// Nabız döngüsünden her vuruşta çağrılır: kaynak durumu dakikada bir günlüğe yazılıp denetlenir
    func systemTick() {
        systemTicks += 1
        guard systemTicks >= Timing.systemEveryTicks else { return }
        systemTicks = 0
        let snapshot = deps.system.snapshot()
        tlog("[sistem] \(snapshot.line)")
        if let left = snapshot.availableMemoryMB, left < Timing.lowMemoryMB {
            handleLowMemory("kalan bellek \(left) MB")
        } else if memoryLowActive, (snapshot.availableMemoryMB ?? Int.max) >= Timing.memoryOKMB {
            memoryLowActive = false
            clearWarning("bellek")
            if !thermalTrimmed { deps.listener.trimMemory(false) }
            tlog("[sistem] bellek rahatladı; yardımcı tanıyıcı geri açıldı")
        }
        applyDisk(snapshot.freeDiskMB)
        if snapshot.lowPowerMode { warn("guc", Say.lowPowerMode) } else { clearWarning("guc") }
    }

    // MARK: Takılma gözcüsü

    /// Nabız vuruşlarında çağrılır: aşama sınırdan uzun süre hiç değişmediyse işi iptal edip oturumu yeniden kurar
    func superviseStuck() {
        guard watchedPhase == phase else {
            watchedPhase = phase
            watchedTicks = 0
            return
        }
        watchedTicks += 1
        guard let limit = Timing.stuckLimit(for: phase), Double(watchedTicks) * Timing.sentinelTick >= limit else { return }
        unstick(limit)
    }

    private func unstick(_ limit: TimeInterval) {
        let stuck = phase
        watchedTicks = 0
        stuckTrips += 1
        tlog("[gözcü] aşama \(stuck) \(Int(limit)) sn boyunca değişmedi (\(stuckTrips). kez); takıldığı varsayılıp yeniden kuruluyor")
        cancelWork()
        voiceTask?.cancel()
        voiceTask = nil
        deps.speaker.stop()
        deps.listener.pause()
        if case .checking = stuck { pendingStart = true }
        warn("gozcu", Say.stuckRestarting)
        work = Task { [weak self] in await self?.resumeAfterRecovery() }
    }

    /// Nabız vuruşu beklenenden çok geç geldiyse (ana iş parçacığı takıldı ya da uygulama askıya alındı) günlüğe yazılır
    func noteTickLateness() {
        let now = deps.now()
        if let last = lastTickAt {
            let gap = now.timeIntervalSince(last)
            if gap > Timing.tickLateLog { tlog("[gözcü] nabız \(String(format: "%.1f", gap)) sn gecikti: ana iş parçacığı takılmış ya da uygulama askıya alınmış olabilir") }
        }
        lastTickAt = now
    }
}
