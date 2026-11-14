import Foundation

/// Kulaklıktan söylenmeyi bekleyen bir uyarı cümlesi
struct PendingAnnouncement: Equatable {
    let text: String
    let at: Date
}

/// Uyarıların sesli verilmesi: ekrana yazılan her uyarı (internet yok, mikrofon yok, onarım başarısız, şarj azaldı, yedek modelden cevap…)
/// kullanıcı ekrana bakmasa da kulaklıktan kısaca söylenir.
///
/// Kurallar:
/// - Yalnız Bluetooth kulaklıktan çalar (KURAL 1); kulaklık yoksa duyan olmaz, bekleyenler atılır (eskiyen haber sonra tekrar edilmesin).
/// - Soru okunurken, Gemini beklenirken ve cevap okunurken araya girmez: sessiz anlarda (duraklatma, onarım, test bitti) hemen,
///   diğer zamanlarda sıradaki anons ya da cevap duyulduktan sonra söylenir.
/// - Aynı cümle 5 dakika içinde yeniden söylenmez; arama/Siri kesintisi sürerken hiçbir şey söylenmez.
extension SessionViewModel {
    /// Uyarı cümlesini söylenecekler sırasına koyar; sessiz bir andaysak hemen söyler
    func announce(_ text: String) {
        guard settings.spokenWarnings, !interruptionActive else { return }
        let sentence = text.trimmed
        guard !sentence.isEmpty, !voiceQueue.contains(where: { $0.text == sentence }) else { return }
        let now = deps.now()
        if let last = lastVoiced[sentence], now.timeIntervalSince(last) < Timing.announceRepeat { return }
        voiceQueue.append(PendingAnnouncement(text: sentence, at: now))
        if voiceQueue.count > Timing.maxQueuedAnnouncements { voiceQueue.removeFirst() }
        drainAnnouncementsIfQuiet()
    }

    /// Hiçbir şeyin söylenmediği ve mikrofonun kapalı olduğu aşamalar: uyarı hemen söylenebilir
    var announcementsQuiet: Bool {
        switch phase {
        case .idle, .finished, .recovering, .paused(.noConnection), .paused(.hardware): return true
        default: return false
        }
    }

    func drainAnnouncementsIfQuiet() {
        guard voiceTask == nil, !voiceQueue.isEmpty, announcementsQuiet else { return }
        voiceTask = Task { [weak self] in
            await self?.speakQueuedAnnouncements()
            self?.voiceTask = nil
            self?.drainAnnouncementsIfQuiet()   // konuşurken yenisi geldiyse
        }
    }

    /// Çalan uyarı varsa bitmesini bekler, kuyrukta kalanları da söyler (anons ve cevaptan önce/sonra çağrılır)
    func settleAnnouncements() async {
        if let task = voiceTask { await task.value }
        if !voiceQueue.isEmpty { await speakQueuedAnnouncements() }
    }

    /// Kuyruktakileri sırayla söyler. Her cümle söylenmeden kuyruktan çıkar, böylece hata olsa da döngü olmaz.
    func speakQueuedAnnouncements() async {
        while !Task.isCancelled, !voiceQueue.isEmpty {
            let item = voiceQueue.removeFirst()
            guard deps.now().timeIntervalSince(item.at) < Timing.announceMaxAge else { continue }
            guard AudioRouting.verdict(deps.route.snapshot()).headphonesOK else {
                voiceQueue.removeAll()
                return
            }
            lastVoiced[item.text] = deps.now()
            announced.append(item.text)
            tlog("[sesli uyarı] \(item.text)")
            do {
                try await deps.speaker.speak(item.text, saveAs: nil)
            } catch {
                return   // susturuldu ya da kulaklık gitti: sıradakini zorlamaz
            }
        }
    }
}

/// "Çıkışı kulaklığa al" kestirmesi: Kestirmeler'deki "Oynatma Hedefini Ayarla" eylemi çıkışı Bluetooth kulaklığa (listede "Bluetooth music"
/// gibi görünür) alır. iOS bir uygulamanın Bluetooth ayarlarında bağlantı kesip kurmasına izin vermez; bunu yalnız Kestirmeler yapabilir.
extension SessionViewModel {
    /// Kestirme tanımlıysa (ve bu oturumda hakkı bittiyse değilse) çalıştırır, ses oturumunu yeniler ve yeni yol değerlendirmesini verir.
    /// Tanımlı değilse ya da hak bittiyse nil.
    func switchOutputToHeadphones() async -> RouteVerdict? {
        let name = settings.outputShortcut.trimmed
        guard !name.isEmpty, outputTries < Timing.maxOutputTries else { return nil }
        outputTries += 1
        tlog("[çıkış] kulaklığa alma kestirmesi çalışıyor: \(name) (\(outputTries). deneme)")
        let outcome = await deps.shortcuts.run(name: name)
        tlog("[çıkış] \(name): \(outcome)")
        guard !Task.isCancelled else { return nil }
        try? deps.route.configure()
        deps.route.preferExternalInput()
        let verdict = await settledRoute().verdict
        tlog("[çıkış] kestirmeden sonra: \(AudioRouting.describe(deps.route.snapshot()))")
        return verdict
    }

    /// Duraklatılmışken kulaklık yolda değilse önce çıkış kestirmesi denenir. true: yol düzeldi, Bluetooth yenileme/sıfırlama gerekmez
    /// (yol sabit kalınca kendiliğinden devam edilir).
    func outputShortcutFixedRoute() async -> Bool {
        guard case .paused(.hardware) = phase, !AudioRouting.verdict(deps.route.snapshot()).headphonesOK,
              let verdict = await switchOutputToHeadphones() else { return false }
        guard !Task.isCancelled, case .paused(.hardware) = phase else { return true }
        routeChanged(deps.route.snapshot())
        return verdict.isSafe
    }
}
