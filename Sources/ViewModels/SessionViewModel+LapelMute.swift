import Foundation

/// Çekimde yaka mikrofonunu kapatma (kullanıcı kararı 2026-11-17): BOYA yaka mikrofonu 2,4 GHz ile çalışır ve kameranın Wi-Fi'siyle (ve Bluetooth kulaklıkla)
/// aynı bandı paylaşır; günlükte yaka mikrofonu bağlıyken kamera paketlerinin %31–65'i yeniden gönderilmişti. iOS vericinin radyosunu uygulamaya bırakmaz,
/// bu yüzden vericiyi KULLANICI kapatır; program bunu sesle ister, süre tanır ve bu sürede telefonun kendi mikrofonunu geçerli sayar
/// (yoksa "yaka mikrofonu yok" diye duraklatıp onarım kestirmesi çalıştırırdı).
///
/// Akış: "Başla" → "Yaka mikrofonunu kapatın. N saniye sonra başlıyorum." → N sn beklenir → "Başladı." → çekim → internet ve kulaklık gelince
/// "Yaka mikrofonunu açın." → alıcı ses yoluna girene kadar (en çok `Timing.lapelBackWait` sn) beklenir → telefonun kendi mikrofonu yeniden geçersiz sayılır.
extension SessionViewModel {
    /// Çekimden ÖNCE çağrılır. Ayar kapalıysa hemen true döner. Dönen false: duyuru kesildi ya da iş iptal edildi (çekim başlamaz).
    func muteLapelForCapture() async -> Bool {
        guard cameraSettings.muteLapel else { return true }
        let seconds = cameraSettings.lapelOffSeconds
        AudioRouting.builtInMicAllowed = true
        tlog("[ses yolu] çekim için yaka mikrofonu kapatılıyor (2,4 GHz parazit): uyarı söylenir, \(seconds) sn beklenir; telefonun kendi mikrofonu geçici kabul edilir")
        statusNote = "Yaka mikrofonunu kapatın"
        guard await speakNotice(Say.lapelOff(seconds: seconds)) else {
            AudioRouting.builtInMicAllowed = false
            statusNote = ""
            return false
        }
        await deps.sleep(TimeInterval(seconds))
        statusNote = ""
        guard !Task.isCancelled else {
            AudioRouting.builtInMicAllowed = false
            return false
        }
        return true
    }

    /// Alıcı (Lightning/USB mikrofon) ses yolunda görünüyor mu
    private var lapelReceiverInRoute: Bool {
        return deps.route.snapshot().inputs.contains(where: { AudioRouting.externalMicPorts.contains($0) })
    }

    /// Çekim bitti (internet ve kulaklık geldi): yaka mikrofonunun açılması istenir. Telefonun kendi mikrofonu bu çağrının sonunda yeniden geçersiz olur;
    /// alıcı ses yoluna girmemişse en çok `Timing.lapelBackWait` sn beklenir (yoksa dinlemeye geçerken "mikrofon yok" duraklaması çıkardı).
    func releaseLapelAfterCapture() async {
        guard AudioRouting.builtInMicAllowed else { return }
        let wasAnswering = phase == .answering
        _ = await speakNotice(Say.lapelOn)
        var waited = 0.0
        while !lapelReceiverInRoute, waited < Timing.lapelBackWait, !Task.isCancelled {
            await Task.yield()
            await deps.sleep(0.5)
            waited += 0.5
        }
        AudioRouting.builtInMicAllowed = false
        tlog("[ses yolu] çekim bitti: yaka mikrofonu \(lapelReceiverInRoute ? "ses yolunda" : "ses yoluna girmedi") (\(Int(waited)) sn beklendi); telefonun kendi mikrofonu yeniden geçersiz")
        if wasAnswering, phase == .speaking { phase = .answering }
    }
}
