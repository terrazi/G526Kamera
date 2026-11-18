import Foundation

/// Kamera çalışırken ses girişinin OTOMATİK telefonun kendi mikrofonuna alınması (kullanıcı kararı 2026-11-17: yaka mikrofonunu program devre dışı
/// bıraksın, el ile kapatılmasın). BOYA yaka mikrofonu 2,4 GHz ile çalışır ve kameranın Wi-Fi'siyle aynı bandı paylaşır; günlükte yaka mikrofonu
/// bağlıyken oturumların %42'si koptu, alıcı çıkıkken %14. iOS alıcının ve vericinin radyosunu uygulamaya bırakmaz: program yalnız SES GİRİŞİNİ
/// değiştirir (alıcı takılı kalır, verici açık kalır). Bu parazit kaynağını ortadan kaldırmayabilir; etkisi çekim başlangıcında yazılan ses yolu satırlarındaki
/// paket tekrarı oranından anlaşılır.
///
/// Akış (toplu çekim): "Başla" → telefonun mikrofonu seçilir (`enterPhoneMic`; "Başla"yı yaka mikrofonu duymuştur) → "Kamera açılıyor." → kameraya geçilir →
/// "Başladı." → çekim → internet ve kulaklık gelince yaka mikrofonuna dönülür (`leavePhoneMic`).
extension SessionViewModel {
    /// Telefonun mikrofonu kipini açar (ayar kapalıysa ya da zaten açıksa hiçbir şey yapmaz). Önce bayrak açılır: yol değişince telefonun mikrofonu geçerli
    /// sayılsın ve "yaka mikrofonu yok" diye duraklatılmasın. Yola girene kadar en çok `Timing.phoneMicSettle` sn beklenir.
    func enterPhoneMic() async {
        guard cameraSettings.phoneMic, !AudioRouting.headsetMicMode else { return }
        let wasLeaving = phoneMicSettleTask != nil
        phoneMicSettleTask?.cancel()
        phoneMicSettleTask = nil
        guard !AudioRouting.phoneMicInUse || wasLeaving else { return }
        AudioRouting.phoneMicInUse = true
        tlog("[ses yolu] kamera için telefonun kendi mikrofonu seçiliyor; yaka mikrofonu alıcısı takılı kalsa da kullanılmaz (2,4 GHz parazit önlemi). Önceki yol: \(AudioRouting.describe(deps.route.snapshot()))")
        deps.route.setBuiltInInputMode(true)
        var waited = 0.0
        while !deps.route.snapshot().inputs.contains(.builtInMic), waited < Timing.phoneMicSettle, !Task.isCancelled {
            await deps.sleep(0.25)
            waited += 0.25
        }
        let inRoute = deps.route.snapshot().inputs.contains(.builtInMic)
        tlog("[ses yolu] telefonun mikrofonu \(inRoute ? "yolda" : "yola girmedi") (\(Int(waited)) sn beklendi); şimdiki yol: \(AudioRouting.describe(deps.route.snapshot()))")
    }

    /// Kipi kapatır: yaka mikrofonu yeniden tercih edilir. Alıcı yola girene (en çok `Timing.lapelBackWait` sn) telefonun mikrofonu geçerli sayılmaya devam
    /// eder; yoksa dinlemeye geçerken "mikrofon yok" duraklaması çıkardı. Alıcı yola girmişse ya da hiç takılı değilse hemen kapanır. Kip açık değilse hiçbir şey yapmaz.
    func leavePhoneMic() {
        guard AudioRouting.phoneMicInUse else { return }
        deps.route.setBuiltInInputMode(false)
        if lapelReceiverInRoute || !deps.route.availableInputs().contains(where: { $0.isExternal }) {
            finishPhoneMic()
            return
        }
        phoneMicSettleTask?.cancel()
        phoneMicSettleTask = Task { @MainActor [weak self] in
            var waited = 0.0
            while let owner = self, !owner.lapelReceiverInRoute, waited < Timing.lapelBackWait, !Task.isCancelled {
                await owner.deps.sleep(0.5)
                waited += 0.5
            }
            guard let owner = self, !Task.isCancelled else { return }
            owner.finishPhoneMic()
        }
    }

    private func finishPhoneMic() {
        phoneMicSettleTask = nil
        AudioRouting.phoneMicInUse = false
        tlog("[ses yolu] kamera işi bitti: yaka mikrofonu alıcısı \(lapelReceiverInRoute ? "ses yolunda" : "ses yolunda değil"); telefonun kendi mikrofonu yeniden geçersiz")
        routeChanged(deps.route.snapshot())
    }
}
