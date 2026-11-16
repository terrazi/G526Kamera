import Foundation

/// Boşluk bilgisi: program sessiz bir işle meşgulken ya da dinlerken uzun süre ses çıkmadığında kısa bir cümleyle durumu söyler; kullanıcı
/// "acaba hat mı düştü, bağlantı mı gitti" diye tedirgin olmaz. Ayarlar'daki "Boşluklarda kısa bilgi ver" anahtarıyla açılır / kapanır.
///
/// - Meşgulken (sistem kontrolü, onarım, kameraya / internete geçiş) her `gapNarrationSeconds` saniyede bir ne yapıldığı söylenir.
/// - Dinlerken hiçbir şey duyulmadıysa ve hiçbir iş sürmüyorsa (bkz. `cameraProbeIsSafe`) bunun üç katı aralıkla "Dinliyorum" denir;
///   bir soruda en çok `Timing.idleCueLimit` kez.
/// - Cevap beklerken "Cevap bekleniyor" ayrıca `Timing.answerCueEvery` aralığıyla söylenir (bkz. `startAnswerWait`).
extension SessionViewModel {
    /// Bir soruda art arda en çok kaç kez "Dinliyorum" denir
    var idleCueLimit: Int { return 3 }

    /// Zamanlayıcı adımı: ayardaki saniye
    var gapStep: TimeInterval {
        return TimeInterval(AppSettings.clampGapNarrationSeconds(settings.gapNarrationSeconds))
    }

    /// Oturum başlarken kurulur; `resetSession` iptal eder, oturum bitince kendiliğinden durur
    func startGapNarration() {
        narrationTask?.cancel()
        narrationTask = nil
        idleCuesInRow = 0
        quietTicks = 0
        guard settings.gapNarration else { return }
        scheduleGapTick()
    }

    private func scheduleGapTick() {
        narrationTask = deps.scheduler.after(gapStep) { [weak self] in self?.gapTick() }
    }

    /// Meşgul durumun kısa tarifi; meşgul değilse nil. Yalnız bilinen sessiz işler söylenir (kamera yönlendirmesi ve cevap bekleme kendi
    /// cümlelerini söyler).
    var busyPhrase: String? {
        switch phase {
        case .checking: return cameraGapPhrase(statusNote) ?? Say.gapChecking   // açılışta kameraya geçilirken de kameranın bilgisi söylenir
        case .recovering: return Say.gapRepairing
        case .answering: return cameraGapPhrase(statusNote)
        default:
            return nil
        }
    }

    /// Kamera akışının durum notuna göre söylenecek boşluk bilgisi (nil: kamera akışı yok)
    private func cameraGapPhrase(_ note: String) -> String? {
        if note.contains("Kameraya geçiliyor") || note.contains("Kamera kontrol ediliyor") { return Say.gapCameraSwitch }
        if note.contains("İnternete geçiliyor") { return Say.gapInternetSwitch }
        if note.contains("Kamera bağlantısı onarılıyor") { return Say.gapCameraRepair }
        // Kameraya geçildi, telefon kameranın ağına girip görüntü gelene kadar (yarım dakikayı bulabilir)
        if note.contains("bağlanılıyor") || note.contains("Giriş yapılıyor") || note.contains("Görüntü isteniyor")
            || note.contains("sorgulanıyor") { return Say.gapCameraConnect }
        return nil
    }

    private func gapTick() {
        narrationTask = nil
        guard phase.isRunning, settings.gapNarration else { return }   // oturum bitti ya da ayar kapandı: durur
        defer { scheduleGapTick() }
        // Sessiz adım sayısı: program konuşunca (anons, cevap, yönlendirme, bilgi cümlesi) sıfırlanır. Böylece bilgi cümlesi en erken
        // bir adım tam sessizlikten sonra söylenir, her an dinlenen sözün hemen ardına binmez.
        let quiet = quietTicks
        quietTicks += 1
        if let text = busyPhrase {
            if quiet >= 1 { speakProgress(text) }
            return
        }
        if quiet >= 3, !idleCueBusy, cameraProbeIsSafe, idleCuesInRow < idleCueLimit {
            idleCuesInRow += 1
            idleCueBusy = true
            work = Task { [weak self] in await self?.speakIdleCue() }
        }
    }

    /// "Dinliyorum": mikrofon kısa süre kapanır (kendi sesini duymasın), söylenir, aynı kipte yeniden açılır
    func speakIdleCue() async {
        defer { idleCueBusy = false }
        guard cameraProbeIsSafe else { return }
        closeListening()
        guard await speakNotice(Say.listeningNow, remember: false) else { return }
        beginListening(mode: .question)
    }
}
