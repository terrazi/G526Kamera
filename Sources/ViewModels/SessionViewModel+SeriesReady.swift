import Foundation

/// Toplu çekim kipinde HAZIR BEKLEME (kullanıcı kararı 2026-11-16): Ayarlar'da "Toplu çekim" işaretliyse program açılışta DİREKT kameraya geçer
/// (telefon kameranın Wi-Fi'sinde, hücresel kapalı, kulaklık ve mikrofon açık), kamera bağlanır ve görüntü akarken kullanıcıya talimatı beklediği söylenir:
/// "Başla deyince N saniyelik süreniz başlayacak." Açılışta internet ve Gemini sınanmaz. "Başla" denince kamera zaten bağlı olduğu için süre HEMEN başlar
/// (bkz. `runPageSeries`); çekim bitince internet gelir, tek PDF gönderilir, cevaplar okunur ve sıradaki oturum için kamera aynı şekilde yeniden hazırlanır
/// (`prepareSeriesCamera`). Hazır bekleyen bağlantı kopmuşsa "Başla" denince aynı Wi-Fi'de yeniden bağlanılır; o da olmazsa süre BAŞLAMAZ: kamera baştan hazırlanır ve talimat yeniden sorulur. Hazır beklerken internet BİLEREK kapalıdır: internet onarımı çalışmaz, bekleyen çekimler çekimden sonra gönderilir.
extension SessionViewModel {
    /// Toplu çekim kipi: ayar açık ve kamera kullanılabilir (yapılandırılmış, ulaşılabilir)
    var seriesMode: Bool {
        return cameraSettings.pageSeries && cameraOfferAvailable
    }

    /// Toplu çekimde kamera "Başla"dan SONRA açılır (kullanıcı kararı 2026-11-17): açılışta kameraya bağlanılmaz, talimat beklenirken kamera kapalıdır, internet
    /// açıktır; "Başla" denince kameraya geçilir (bkz. `runPageSeries`). Hazır bekleme düzeni (aşağıdaki `seriesCameraReady`) bu durumda hiç kurulmaz.
    var seriesAfterGo: Bool {
        return cameraSettings.pageSeries && cameraSettings.cameraAfterGo
    }

    /// Kamera "Başla"dan sonra açıldı, süre başlamadan önce: "Hazır olun." ve `Timing.seriesCountdown` sn geri sayım (saniyede bir sayı). Dönen false: duyuru kesildi
    /// ya da iş iptal edildi (süre başlamaz).
    func speakSeriesCountdown() async -> Bool {
        guard await speakNotice(Say.seriesGetReady, remember: false) else { return false }
        var number = Timing.seriesCountdown
        while number >= 1 {
            let started = deps.now()
            guard await speakNotice(Say.seriesCountdownNumber(number), remember: false) else { return false }
            let rest = 1.0 - deps.now().timeIntervalSince(started)
            if rest > 0 { await deps.sleep(rest) }
            guard !Task.isCancelled else { return false }
            number -= 1
        }
        return true
    }

    /// Kamera hazır bekliyor: toplu çekim açık ve kamera bağlantısı açık tutuluyor (telefon kameranın ağında, internet bilerek kapalı)
    var seriesCameraReady: Bool {
        return cameraSettings.pageSeries && deps.camera.holding
    }

    /// Açılışta kamera bağlandı (`connectCameraAtStart`) ve toplu çekim açık: bağlantı AÇIK kalır. Kamera geri bildirimleri bırakılır
    /// (uyarılar `cameraStartNotes` içinde birikmişti, ilk anonsta söylenir), kamera "meşgul" sayılmaz: sesli komutla iş iptal edilse de bağlantı kapanmaz.
    func seriesStartChecks() {
        let camera = deps.camera
        camera.onSay = nil
        camera.onStatus = nil
        cameraBusy = false
        statusNote = ""
        clearWarning("kamera")
        var detail = "bağlandı, görüntü geldi; hücresel kapalı, çekimden sonra açılacak"
        if let level = camera.lastBattery {
            detail += "; " + level.shortText
            tlog("[kamera] oturum başı: kamera pili: \(level.shortText)")
        }
        setCheck("kameraBaglanti", "Kamera bağlantısı", ok: true, detail: detail)
        tlog("[kamera] oturum başı: toplu çekim kipi; kamera açık bekliyor, internet ve Gemini sınanmadı")
    }

    /// Toplu çekimde "Kameraya Geç" kestirmesi uçak modunu açar ve Bluetooth kulaklığı düşürür (kullanıcı kararı 2026-11-16): hemen ardından
    /// `Bluetooth` kestirmesi (kapat, bekle, aç) çalışır, kulaklık düşmüş kalmaz. Kestirme yazılı değilse ya da kameraya geçiş kestirmesi çalışmadıysa
    /// hiçbir şey yapılmaz; kulaklığın dönmesini çağıran bekler (ses yolu değişikliği o sırada duraklatma sayılmaz).
    func bringHeadsetBackAfterCameraShortcut(_ cameraOutcome: ShortcutOutcome) async {
        guard cameraSettings.pageSeries, !Task.isCancelled else { return }
        guard cameraOutcome == .success || cameraOutcome == .timedOut else { return }
        let name = settings.shortcutName(for: .bluetooth)
        guard !name.isEmpty else {
            tlog("[kamera] toplu çekim: Bluetooth kestirmesi yazılı değil; kulaklık kameraya geçişte düşerse kendiliğinden dönmesi beklenir")
            return
        }
        let note = statusNote
        statusNote = "Kulaklık için Bluetooth açılıyor"
        tlog("[kamera] toplu çekim: kameraya geçildi, kulaklık düşmesin diye Bluetooth kestirmesi “\(name)” çalıştırılıyor")
        let outcome = await runShortcutRetryingTransient(name: name)
        tlog("[kamera] toplu çekim: Bluetooth kestirmesi sonucu \(outcome)")
        statusNote = note
    }

    /// Telefonun Wi-Fi adresi gelene kadar en çok `seconds` sn bekler (yarım sn aralıkla); dönen: adres var mı
    func waitForPhoneWiFi(seconds: TimeInterval) async -> Bool {
        var waited = 0.0
        while !deps.camera.phoneHasWiFiAddress {
            if waited >= seconds || Task.isCancelled { return false }
            await Task.yield()
            await deps.sleep(0.5)
            waited += 0.5
        }
        return true
    }

    /// "Kameraya Geç" kestirmesinden sonra çağrılır. Kestirmeler Wi-Fi'ye bağlanamaz, yalnız açıp kapatır: kamera ağına girmeyi iPhone kendisi seçer ve
    /// bazen seçmez (kamera ağında internet yok; günlükte 8 denemenin 3'ünde girmedi, elle dokununca girdi). `Timing.wifiJoinWait` sn içinde Wi-Fi adresi
    /// yoksa 15 sn'lik bağlanma ve tarama beklenmez: Wi-Fi onarım kestirmesi ("Kamera Bağlantısını Onar": Wi-Fi kapat-aç) hemen çalışır.
    func ensureWiFiAfterCameraShortcut() async {
        guard cameraSettings.pageSeries, !Task.isCancelled else { return }
        if await waitForPhoneWiFi(seconds: Timing.wifiJoinWait) { return }
        let name = settings.shortcutName(for: .wifi)
        guard !name.isEmpty else {
            tlog("[kamera] kameraya geçildi ama \(Int(Timing.wifiJoinWait)) sn içinde telefon bir Wi-Fi ağına girmedi; Wi-Fi onarım kestirmesi yazılı değil")
            return
        }
        tlog("[kamera] kameraya geçildi ama \(Int(Timing.wifiJoinWait)) sn içinde telefon Wi-Fi ağına girmedi; bağlanma beklenmeden Wi-Fi onarım kestirmesi “\(name)” çalıştırılıyor")
        let note = statusNote
        statusNote = "Wi-Fi yenileniyor (kamera ağına girilmedi)"
        let outcome = await runShortcutRetryingTransient(name: name)
        guard !Task.isCancelled else { return }
        let joined = await waitForPhoneWiFi(seconds: Timing.wifiJoinWaitAfterRepair)
        tlog("[kamera] Wi-Fi onarım kestirmesi sonucu \(outcome); telefon Wi-Fi ağına \(joined ? "girdi" : "yine girmedi")")
        statusNote = note
    }

    /// Sıradaki oturum için kamerayı hazırlar: kestirme (hücresel kapanır, telefon kameranın Wi-Fi'sine geçer), kameraya bağlanma ve görüntünün gelmesi;
    /// bağlantı AÇIK kalır. Kulaklık kestirmeyle düştüyse dönmesi beklenir. Kamera zaten hazırsa (açılışta bağlanılmıştır) hiçbir şey yapmaz.
    ///
    /// Dönen: true → kamera hazır, talimat sorulabilir; false → kesildi (onarımdan sonra yeniden hazırlanır) ya da kameraya ulaşılamadı
    /// (neden söylendi, internete dönüldü, sorular sesle okunur ve kamera yoklanır).
    func prepareSeriesCamera() async -> Bool {
        if deps.camera.holding { return true }
        let cameraName = cameraSettings.cameraShortcutName.trimmed
        let internetName = settings.internetShortcut.trimmed
        cameraBusy = true
        defer { cameraBusy = false }
        let attemptStart = deps.now()
        phase = .answering
        networkMayBeOnCamera = true   // kestirme çalışınca hücresel kapanır; internete dönüş doğrulanana kadar bayrak durur
        statusNote = "Kameraya geçiliyor (hücresel kesiliyor)"
        tlog("[kamera] toplu çekim: sıradaki oturum için kameraya geçiliyor, kestirme “\(cameraName)”")
        // Kestirme kulaklığı düşürebilir: ses yolu değişikliği donanım duraklatması sayılmaz
        let headsetWasThere = routeVerdict?.isSafe ?? true
        connectionResetActive = true
        defer { connectionResetActive = false }
        deps.camera.subject = .question
        let result = await repairLoop(cameraName: cameraName, speaks: false,
                                      operation: { camera, limit in await camera.holdOpen(connectLimit: limit) },
                                      interrupted: { _ in })
        guard !Task.isCancelled, phase == .answering else {
            offerCamera = true   // kesildi (kulaklık, arama, onarım): onarımdan sonra kamera yeniden hazırlanır
            return false
        }
        var online = false
        if case .failure = result {
            // Kameraya ulaşılamadı: telefon kameranın ağında kalmasın, internete dönülür
            statusNote = internetNote
            online = await returnToInternet(shortcut: internetName)
            if online { networkMayBeOnCamera = false }
        }
        var waited = 0.0
        while headsetWasThere, !Task.isCancelled, !(routeVerdict?.isSafe ?? true), waited < Timing.seriesHeadsetWait {
            await Task.yield()
            await deps.sleep(0.5)
            waited += 0.5
        }
        connectionResetActive = false
        statusNote = ""
        tlog("[kamera] toplu çekim: hazırlık bitti (kamera \((deps.camera.holding) ? "hazır" : "hazır değil"), kulaklık \((routeVerdict?.isSafe ?? true) ? "yerinde" : "dönmedi"), \(Int(waited)) sn beklendi)")
        guard !Task.isCancelled, phase == .answering else {
            offerCamera = true
            return false
        }
        switch result {
        case .success:
            return true
        case .failure(let failure):
            tlog("[kamera] toplu çekim: kameraya geçilemedi: \(failure.message)")
            clearWarning("kamera")
            let gaveUp = failure == .notConnected || failure == .noFrames
            if gaveUp { markCameraDown(since: attemptStart) }
            if online {
                await fallBackToVoice(Say.cameraFailed(failure, down: gaveUp, minutes: settings.cameraCheckMinutes))
            } else if offlineCapture {
                await continueOffline(Say.cameraFailedOfflineContinue(failure))
            } else {
                await repairInternetAfterCamera(Say.cameraFailedOffline(failure))
            }
            return false
        }
    }
}
