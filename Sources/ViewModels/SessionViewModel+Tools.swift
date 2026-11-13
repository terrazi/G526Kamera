import Foundation

/// İlk sürümden alınan yardımcı araçlar: düşük şarj uyarısı, elle duraklat / devam et, "Sesi dene"
extension SessionViewModel {
    // MARK: Düşük şarj

    /// Telefon şarjı 20 / 10 / 5'e düşünce (şarjda değilse) kırmızı kutuda bir kez uyarır; şarja takılınca ya da %25'in üstüne çıkınca kalkar.
    /// Konuşarak uyarmaz: soru okunurken araya girmesin.
    func batteryChanged() {
        guard phase.isRunning else { return }
        let percent = deps.battery.percent
        let charging = deps.battery.charging
        if let low = batteryWatcher.update(percent: percent, charging: charging) {
            warn("pil", Say.lowBattery(low))
        } else if charging || (percent ?? 0) > LowBatteryWatcher.resetAbove {
            clearWarning("pil")
        }
    }

    // MARK: Duraklat / devam et

    /// "Duraklat" düğmesi şu aşamalarda çalışır
    var canPauseByUser: Bool {
        switch phase {
        case .listening, .answering, .speaking: return true
        default: return false
        }
    }

    /// Kullanıcı testi elle duraklatır (ör. görevli ile konuşmak için): mikrofon kapanır, konuşma yazıya çevrilmez, hiçbir şey gönderilmez.
    /// Gemini'ye gitmekte olan soru kesilir ("gitmedi" olur, yeniden okunur); okunmakta olan cevap kaydedilmiştir, devam edince yeniden okunur.
    func pauseByUser() {
        switch phase {
        case .listening, .answering, .speaking: break
        default: return
        }
        cancelWork()
        deps.speaker.stop()
        deps.listener.pause()
        watchdog.disarm()
        accumulator.clear()
        liveText = ""
        phase = .paused(.manual)
        statusNote = "Duraklatıldı: mikrofon kapalı. Devam etmek için “Devam et”e basın."
    }

    /// Elle duraklatılmış testi sürdürür: ses yolu denetlenir; sağlamsa (bekleyen cevap varsa önce o söylenip) dinlemeye dönülür
    func resumeByUser() {
        guard phase == .paused(.manual) else { return }
        statusNote = ""
        work = Task { [weak self] in
            guard let self = self else { return }
            try? self.deps.route.configure()
            self.deps.route.preferExternalInput()
            let verdict = AudioRouting.verdict(self.deps.route.snapshot())
            self.routeVerdict = verdict
            guard verdict.isSafe else {
                self.enterHardwarePause(verdict)
                return
            }
            if let record = self.unheard {
                guard await self.speakNotice(record.spoken) else { return }
                self.unheard = nil
            }
            guard !Task.isCancelled else { return }
            self.beginListening()
        }
    }

    // MARK: Sesi dene

    /// Test başlamadan kulaklığı ve mikrofonu denemek için: ses yolunu denetler, kulaklıktan kısa bir cümle çalar ve sonucu yazar.
    /// Çıkış Bluetooth kulaklık değilse hiçbir şey çalınmaz (KURAL 1).
    func testSound() {
        guard phase.isAtRest, !testingSound else { return }
        testingSound = true
        soundTest = "Ses yolu denetleniyor…"
        work = Task { [weak self] in
            guard let self = self else { return }
            defer { self.testingSound = false }
            do {
                try self.deps.route.configure()
            } catch {
                self.soundTest = "Ses oturumu açılamadı: \(error.localizedDescription)"
                return
            }
            self.deps.route.preferExternalInput()
            let snapshot = self.deps.route.snapshot()
            let verdict = AudioRouting.verdict(snapshot)
            self.routeVerdict = verdict
            self.refreshInputs()
            let route = AudioRouting.describe(snapshot)
            tlog("[ses denemesi] \(route)")
            guard verdict.headphonesOK else {
                self.soundTest = "\(route) Kulaklıktan ses çalınamaz: \(verdict.hint)"
                return
            }
            self.soundTest = "\(route) Kulaklıktan bir cümle çalınıyor…"
            do {
                try await self.deps.speaker.speak(Say.soundTest, saveAs: nil)
                self.soundTest = verdict.micOK
                    ? "\(route) Cümleyi kulaklıkta duydunuz mu? Mikrofon da görünüyor."
                    : "\(route) Ses çalındı ama yaka mikrofonu görünmüyor: alıcının takılı ve mikrofonun açık olduğundan emin olun."
            } catch SpeakError.routeUnsafe {
                self.soundTest = "Çalma sırasında ses yolu güvenli olmaktan çıktı. Kulaklığı kontrol edin."
            } catch is CancellationError {
                self.soundTest = ""
            } catch {
                self.soundTest = "Ses çalınamadı: \(error.localizedDescription)"
            }
        }
    }
}
