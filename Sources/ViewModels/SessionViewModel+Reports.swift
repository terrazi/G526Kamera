import Foundation
import AVFoundation

/// Sesle istenen raporlar ("internet raporu", "şarj kaç", "ram durumu", "genel rapor") ve ayar komutları ("sesi aç", "kamera sorusunu kapat").
/// Hepsi bilgi komutları gibi her kipte söylenebilir, soru metnini korur ve yaptığını ya da yapamadığını söyler (bkz. `performInfo`).
extension SessionViewModel {
    /// Canlı bilgi ya da ayar gerektiren komutun yanıtı. `leaveCameraChoice`: kamera sorusu kapatıldı ve kamera sorusu açıkken söylendi;
    /// bekleyen evet/hayır sorusu bırakılır, soru sesle okunur
    struct LiveReply {
        var text: String
        var leaveCameraChoice = false
    }

    func liveReply(_ command: VoiceCommand, mode: ListenMode) async -> LiveReply {
        switch command {
        case .report(let kind): return LiveReply(text: await reportText(kind))
        case .volume(let action): return LiveReply(text: await changeVolume(action))
        case .camera(let action): return changeCameraSetting(action, mode: mode)
        default: return LiveReply(text: Say.nothingToRepeat)
        }
    }

    // MARK: Raporlar

    func reportText(_ kind: ReportKind) async -> String {
        switch kind {
        case .internet: return await internetReport()
        case .microphone: return microphoneReport()
        case .headphones: return headphonesReport()
        case .sound: return soundReport()
        case .camera: return cameraReport()
        case .battery: return batteryReport()
        case .thermal: return thermalReport()
        case .memory: return memoryReport()
        case .general:
            let internet = await internetReport()
            return Say.reportGeneral([internet, headphonesReport(), microphoneReport(), soundReport(), batteryReport(), thermalReport(), memoryReport()])
        }
    }

    /// Telefon ağa bağlı mı, internete gerçekten çıkılıyor mu (tek hafif yoklama) ve Gemini'ye ulaşılıyor mu
    private func internetReport() async -> String {
        guard deps.network.isOnline else { return Say.reportInternetOffline }
        guard await deps.health.quickProbe() else { return Say.reportInternet(kind: deps.network.kind, reachable: false, gemini: nil) }
        let gemini = await checkGemini()
        return Say.reportInternet(kind: deps.network.kind, reachable: true, gemini: gemini)
    }

    private func portNames(_ ports: [AVAudioSession.Port]) -> [String] {
        var seen: [String] = []
        for port in ports {
            let name = AudioRouting.portName(port)
            if !seen.contains(name) { seen.append(name) }
        }
        return seen
    }

    private func headphonesReport() -> String {
        let snapshot = deps.route.snapshot()
        let verdict = AudioRouting.verdict(snapshot)
        return Say.reportHeadphones(ok: verdict.headphonesOK, outputs: portNames(snapshot.outputs), hint: verdict.hint)
    }

    private func microphoneReport() -> String {
        let snapshot = deps.route.snapshot()
        return Say.reportMicrophone(ok: AudioRouting.verdict(snapshot).micOK, inputs: portNames(snapshot.inputs))
    }

    private func soundReport() -> String {
        let level = deps.system.snapshot().outputVolume
        let headphonesOK = AudioRouting.verdict(deps.route.snapshot()).headphonesOK
        return Say.reportSound(percent: level.map { volumePercent($0) }, low: level.map { $0 < Timing.lowVolume } ?? false, headphonesOK: headphonesOK)
    }

    private func batteryReport() -> String {
        return Say.reportBattery(percent: deps.battery.percent, charging: deps.battery.charging, lowPower: deps.system.snapshot().lowPowerMode)
    }

    private func thermalReport() -> String {
        return Say.reportThermal(deps.system.snapshot().thermal)
    }

    private func memoryReport() -> String {
        let snapshot = deps.system.snapshot()
        return Say.reportMemory(availableMB: snapshot.availableMemoryMB, footprintMB: snapshot.footprintMB, freeDiskMB: snapshot.freeDiskMB,
                                memoryLow: snapshot.availableMemoryMB.map { $0 < Timing.lowMemoryMB } ?? false,
                                diskLow: snapshot.freeDiskMB.map { $0 < Timing.lowDiskMB } ?? false)
    }

    private func cameraReport() -> String {
        let c = cameraSettings
        return Say.reportCamera(configured: cameraConfigured, ask: settings.askCamera, highQuality: c.streamQuality == 1, vertical: c.guidanceFrame == 1,
                                orientation: c.imageOrientation, guidance: c.guidanceEnabled, pageSeconds: c.pageVideoSeconds, video: c.videoToGemini,
                                enhancement: c.enhancement, preview: !c.previewOff, pending: pendingShots.count, battery: deps.camera.lastBattery)
    }

    private func volumePercent(_ level: Float) -> Int {
        return Int((level * 100).rounded())
    }

    // MARK: Ses seviyesi

    /// iOS uygulamaların sistem sesini doğrudan ayarlamasına izin vermez; `deps.volume` gizli ses çubuğunu dener ve sonuç yeniden okunur.
    /// Değişmediyse ayar yapılmış gibi söylenmez: "değiştirilemedi" denir.
    private func changeVolume(_ action: VolumeAction) async -> String {
        guard let before = deps.system.snapshot().outputVolume else { return Say.volumeUnreadable }
        let floor = Timing.minVolume
        var flooredTo: Int?
        let target: Float
        switch action {
        case .up:
            if before >= 0.995 { return Say.volumeAlreadyMax }
            target = min(1, before + Timing.volumeStep)
        case .down:
            if before <= floor + 0.005 { return Say.volumeAlreadyMin(volumePercent(before)) }
            target = max(floor, before - Timing.volumeStep)
        case .set(let percent):
            let asked = Float(min(100, max(0, percent))) / 100
            if asked < floor {
                flooredTo = volumePercent(floor)
                target = floor
            } else {
                target = asked
            }
            if abs(target - before) < 0.005 { return Say.volumeSame(volumePercent(before)) }
        }
        tlog("[ayar] ses seviyesi isteği: yüzde \(volumePercent(before)) → yüzde \(volumePercent(target))")
        deps.volume.requestOutputVolume(target)
        await deps.sleep(Timing.volumeSettle)
        let after = deps.system.snapshot().outputVolume
        applyVolume(after)
        guard let now = after else { return Say.volumeUnreadable }
        if abs(now - before) < 0.005 {
            tlog("[ayar] ses seviyesi değişmedi (iOS ses çubuğunu kabul etmedi)")
            return Say.volumeNotChanged(volumePercent(now))
        }
        return Say.volumeChanged(volumePercent(now), action: action, floored: flooredTo)
    }

    // MARK: Kamera ayarları

    /// Ayar anında kaydedilir ve bir sonraki çekimde kullanılır. Kamera çalışırken (çekim sürerken) değiştirilmez.
    private func changeCameraSetting(_ action: CameraAction, mode: ListenMode) -> LiveReply {
        guard !cameraBusy else { return LiveReply(text: Say.cameraSettingBusy) }
        let c = cameraSettings
        switch action {
        case .askQuestion(let on):
            if settings.askCamera == on { return LiveReply(text: Say.cameraAskAlready(on)) }
            settings.askCamera = on
            let choice = !on && (mode == .cameraChoice || mode == .passageCameraChoice)
            if !on { offerCamera = false }
            tlog("[ayar] her soruda kamera sorusu: \(on ? "açık" : "kapalı")")
            return LiveReply(text: Say.cameraAskChanged(on: on, configured: cameraConfigured, leavingChoice: choice), leaveCameraChoice: choice)
        case .quality(let high):
            let value = high ? 1 : 2
            let already = c.streamQuality == value
            c.streamQuality = value
            tlog("[ayar] görüntü kalitesi: \(high ? "yüksek" : "düşük")")
            return LiveReply(text: Say.cameraQuality(high: high, already: already))
        case .sendVideo(let on):
            let already = c.videoToGemini == on
            c.videoToGemini = on
            tlog("[ayar] video Gemini'ye: \(on ? "gider" : "gitmez")")
            return LiveReply(text: Say.cameraVideoSend(on: on, already: already))
        case .videoSeconds(let seconds):
            let range = VideoRecorder.pageSecondsRange
            let value = min(max(seconds, range.lowerBound), range.upperBound)
            let already = c.pageVideoSeconds == value
            c.pageVideoSeconds = value
            tlog("[ayar] soru videosu sayfa başına \(value) sn")
            return LiveReply(text: Say.cameraVideoSeconds(value, clamped: value != seconds, already: already, range: range))
        case .frame(let vertical):
            let value = vertical ? 1 : 0
            let already = c.guidanceFrame == value
            c.guidanceFrame = value   // görüntü yönü kadraja uydurulur
            tlog("[ayar] kadraj: \(vertical ? "dikey" : "yatay"); görüntü yönü \(c.imageOrientation.title)")
            return LiveReply(text: Say.cameraFrame(vertical: vertical, orientation: c.imageOrientation, already: already))
        case .orientation(let orientation):
            guard CameraSettings.orientation(orientation, forFrame: c.guidanceFrame) == orientation else {
                return LiveReply(text: Say.cameraOrientationRefused(verticalFrame: c.guidanceFrame == 1))
            }
            let already = c.imageOrientation == orientation
            c.imageOrientation = orientation
            tlog("[ayar] görüntü yönü: \(orientation.title)")
            return LiveReply(text: Say.cameraOrientation(orientation, already: already))
        case .guidance(let on):
            let already = c.guidanceEnabled == on
            c.guidanceEnabled = on
            tlog("[ayar] sesle konumlandırma: \(on ? "açık" : "kapalı")")
            return LiveReply(text: Say.cameraGuidance(on: on, already: already))
        case .enhancement(let level):
            let already = c.enhancement == level
            c.enhancement = level
            tlog("[ayar] fotoğraf iyileştirme: \(Say.enhancementName(level))")
            return LiveReply(text: Say.cameraEnhancement(level, already: already))
        case .preview(let on):
            let already = c.previewOff == !on
            c.previewOff = !on
            tlog("[ayar] canlı önizleme: \(on ? "açık" : "kapalı")")
            return LiveReply(text: Say.cameraPreview(on: on, already: already))
        }
    }
}
