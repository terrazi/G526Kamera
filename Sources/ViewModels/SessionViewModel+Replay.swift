import Foundation

/// Modül 6: test sonu çevrimdışı tekrar. Ağ izleme kapanır, mikrofon açılmaz; yalnız klasördeki cevap dosyaları aralarında
/// ayardaki boşlukla (varsayılan 3 sn) sırayla çalınır.
extension SessionViewModel {
    func startReplay() {
        guard phase.isAtRest else { return }
        do {
            try deps.route.configure()
        } catch {
            warn("tekrar", "Ses oturumu açılamadı: \(error.localizedDescription)")
            return
        }
        let verdict = AudioRouting.verdict(deps.route.snapshot())
        guard verdict.headphonesOK else {
            warn("tekrar", [Say.noHeadphonesForReplay, verdict.hint].filter { !$0.isEmpty }.joined(separator: " "))
            return
        }
        let files = replayFolder().map { deps.library.answerFiles(in: $0) } ?? []
        guard !files.isEmpty else {
            warn("tekrar", Say.nothingToReplay)
            return
        }
        clearWarning("tekrar")
        deps.network.stop()
        deps.screen.keepAwake(true)
        phase = .replaying
        replay.start(files: files, gap: settings.replayGap)
    }

    func stopReplay() {
        replay.stop()
    }

    func replayChanged(_ state: ReplayController.State) {
        guard phase == .replaying else { return }
        switch state {
        case .idle:
            break
        case .playing(let index, let total):
            statusNote = "Cevap \(index)/\(total) okunuyor"
        case .gap(let next, let total):
            statusNote = "Sıradaki cevap \(next)/\(total), bekleniyor"
        case .finished:
            finishReplay("Tekrar bitti.")
        case .stopped(let reason):
            finishReplay(reason)
        }
    }

    private func finishReplay(_ note: String) {
        phase = .finished
        statusNote = note
        deps.screen.keepAwake(false)
        refreshReplayAvailability()
    }
}
