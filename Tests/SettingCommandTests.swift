import XCTest
@testable import G526CameraDrive

/// Rapor komutları ("internet raporu", "şarj kaç", "ısındı mı", "ram durumu", "genel rapor"), ses seviyesi ("sesi aç", "sesi yüzde elli yap") ve
/// kamera ayarları ("görüntü kalitesini yüksek yap"…): her biri her kipte söylenebilir, soru metnini ve kipi korur, Gemini'ye
/// gitmez ve yaptığını ya da yapamadığını kısaca söyler.
@MainActor
final class SettingCommandTests: XCTestCase {
    private typealias T = SessionViewModel.Timing

    private let reportPhrases: [(VoiceCommand, [String])] = [
        (.report(.internet), ["internet raporu", "internet durumu", "internet var mı", "interneti söyle", "internet bağlantısı nasıl", "bağlantı durumu", "internet çalışıyor mu", "internet bağlı mı", "internet raporunu söyle", "lütfen internet durumunu söyle", "internet bağlantısı var mı", "wifi durumu", "bağlantı raporu", "internet nasıl", "interneti kontrol et"]),
        (.report(.microphone), ["mikrofon raporu", "mikrofon durumu", "mikrofon çalışıyor mu", "mikrofon var mı", "mikrofonu söyle", "mikrofon bağlı mı", "mikrofon nasıl", "mikrofon kontrolü", "beni duyuyor musun", "beni duyuyor mu", "mikrofon durumunu söyle", "mikrofonum çalışıyor mu"]),
        (.report(.headphones), ["kulaklık raporu", "kulaklık durumu", "kulaklık bağlı mı", "kulaklık var mı", "kulaklık çalışıyor mu", "kulaklığı söyle", "bluetooth durumu", "kulaklık nasıl", "kulaklık durumunu söyle", "bluetooth bağlı mı", "kulaklık kontrolü"]),
        (.report(.sound), ["ses raporu", "ses durumu", "ses seviyesi kaç", "ses seviyesi nedir", "ses seviyesi nasıl", "sesi söyle", "ses kaç", "ses seviyesini söyle", "ses seviyesi yüzde kaç", "ses çalışıyor mu", "ses var mı", "ses durumunu söyle"]),
        (.report(.camera), ["kamera raporu", "kamera durumu", "görüntü raporu", "görüntü durumu", "kamera nasıl", "kamera ayarları", "kamera ayarlarını söyle", "kamera bağlı mı", "kamera çalışıyor mu", "görüntü nasıl", "kamera durumunu söyle", "kamera var mı", "kamera ayarlarını oku", "görüntü ayarları"]),
        (.report(.battery), ["şarj durumu", "şarj kaç", "pil durumu", "pil kaç", "şarj yüzde kaç", "pil yüzde kaç", "şarjım kaç", "telefonun şarjı kaç", "telefonun şarj durumu", "pil raporu", "şarj raporu", "batarya durumu", "şarj ne kadar", "şarj nasıl", "şarj var mı", "telefonun pili nasıl", "pil durumunu söyle", "şarjı söyle", "şarj ne durumda"]),
        (.report(.thermal), ["ısınma durumu", "ısı durumu", "telefon ısındı mı", "ısındı mı", "sıcaklık durumu", "ısı nasıl", "telefonun ısısı nasıl", "ısınma raporu", "ısı raporu", "sıcaklık kaç", "telefon sıcak mı", "ısınma var mı", "telefonun sıcaklığı nasıl", "ısı durumunu söyle", "ısınma nasıl"]),
        (.report(.memory), ["ram durumu", "ram kaç", "bellek durumu", "hafıza durumu", "ram raporu", "ram nasıl", "bellek kaç", "telefonun ram durumu", "hafıza nasıl", "bellek raporu", "depolama durumu", "ram yeterli mi", "bellek yeterli mi", "hafıza ne kadar", "ram ne durumda", "telefonun hafıza durumu", "depolama kaç", "ram'i söyle"]),
        (.report(.general), ["genel rapor", "tüm raporları söyle", "rapor ver", "sistem raporu", "genel raporu söyle", "tüm rapor", "raporları söyle", "rapor söyle", "telefon raporu", "kısa rapor", "tüm raporları oku", "raporu söyle", "özet rapor", "tüm sistem raporu"]),
        (.volume(.up), ["sesi aç", "sesi artır", "sesi yükselt", "ses seviyesini artır", "sesi biraz aç", "sesi arttır", "lütfen sesi aç", "sesi daha çok aç", "ses seviyesini yükselt", "sesi açın"]),
        (.volume(.down), ["sesi kıs", "sesi azalt", "sesi düşür", "ses seviyesini azalt", "sesi biraz kıs", "lütfen sesi kıs", "sesi alçalt", "ses seviyesini düşür", "sesi kısın"])
    ]
    private let volumeSetPhrases: [(String, Int)] = [("sesi yüzde elli yap", 50), ("ses seviyesini yüzde yetmiş yap", 70), ("sesi 50 yap", 50), ("sesi yüzde 80 yap", 80), ("sesi yüzde yüz yap", 100), ("sesi yüzde otuz olsun", 30), ("ses seviyesini yüzde on yap", 10), ("sesi yüzde yirmi beş yap", 25), ("sesi yüzde altmış ayarla", 60), ("ses seviyesini 70 yap", 70), ("sesi sonuna kadar aç", 100), ("sesi tamamen aç", 100), ("sesi yüzde peş yap", 5)]
    private let cameraPhrases: [(VoiceCommand, [String])] = [
        (.camera(.quality(high: true)), ["görüntü kalitesini yüksek yap", "kamera kalitesini yüksek yap", "kaliteyi yüksek yap", "görüntü kalitesini artır", "çözünürlüğü yüksek yap", "kalite yüksek olsun", "görüntü kalitesi yüksek"]),
        (.camera(.quality(high: false)), ["görüntü kalitesini düşük yap", "kamera kalitesini düşür", "kaliteyi düşük yap", "çözünürlüğü düşür", "kalite düşük olsun"]),
        (.camera(.sendVideo(true)), ["videoyu gönder", "videoyu geminiye gönder", "video gönderilsin", "videoyu aç", "video de gönder", "videoyu kullan"]),
        (.camera(.sendVideo(false)), ["videoyu gönderme", "videoyu kapat", "video gönderme", "videoyu geminiye gönderme", "video kapalı olsun", "videoyu devre dışı bırak"]),
        (.camera(.frame(vertical: true)), ["kadrajı dikey yap", "kadraj dikey olsun", "kadrajı dikeye al"]),
        (.camera(.frame(vertical: false)), ["kadrajı yatay yap", "kadraj yatay olsun", "kadrajı yataya al"]),
        (.camera(.orientation(.rotate180)), ["görüntüyü ters çevir", "görüntüyü 180 çevir", "görüntü yönünü ters yap", "görüntüyü ters döndür"]),
        (.camera(.orientation(.right90)), ["görüntüyü sağa çevir", "görüntüyü sağa döndür", "görüntü yönünü sağa yap"]),
        (.camera(.orientation(.left90)), ["görüntüyü sola çevir", "görüntüyü sola döndür", "görüntü yönünü sola yap"]),
        (.camera(.orientation(.normal)), ["görüntüyü normal yap", "görüntü yönünü normal yap", "görüntü yönünü düz yap"]),
        (.camera(.guidance(true)), ["sesle konumlandırmayı aç", "sesli yönlendirmeyi aç", "yönlendirmeyi aç", "konumlandırmayı aç", "sesle yönlendirme açık olsun"]),
        (.camera(.guidance(false)), ["sesle konumlandırmayı kapat", "sesli yönlendirmeyi kapat", "yönlendirmeyi kapat", "konumlandırmayı kapat", "yönlendirme kapalı olsun"]),
        (.camera(.seriesGuidance(true)), ["toplu çekimde konumlandırmayı aç", "toplu çekimde sesle konumlandırmayı aç", "toplu çekim konumlandırması açık olsun", "konumlandırma desteğini aç", "sesli konumlandırma desteğini aç", "toplu çekimde yönlendirme açık olsun"]),
        (.camera(.seriesGuidance(false)), ["toplu çekimde konumlandırmayı kapat", "toplu çekimde sesle konumlandırmayı kapat", "konumlandırma desteğini kapat", "sesli konumlandırma desteğini kapat", "toplu çekimde yönlendirme kapalı olsun", "konumlandırma desteği kapalı olsun"]),
        (.camera(.enhancement(0)), ["iyileştirmeyi kapat", "fotoğraf iyileştirmeyi kapat", "iyileştirme kapalı olsun"]),
        (.camera(.enhancement(1)), ["iyileştirmeyi hafif yap", "iyileştirmeyi aç", "iyileştirme hafif olsun"]),
        (.camera(.enhancement(2)), ["iyileştirmeyi güçlü yap", "iyileştirme güçlü olsun"]),
        (.camera(.preview(false)), ["önizlemeyi kapat", "canlı önizlemeyi kapat", "önizleme kapalı olsun"]),
        (.camera(.preview(true)), ["önizlemeyi aç", "canlı önizlemeyi aç", "önizleme açık olsun"])
    ]
    private let videoSecondsPhrases: [(String, Int)] = [("video süresini sekiz saniye yap", 8), ("video süresini on beş saniye yap", 15), ("videoyu on saniye yap", 10), ("video süresi beş saniye olsun", 5), ("video süresini yirmi saniye ayarla", 20), ("video süresini 30 saniye yap", 30), ("videoyu yedi saniyelik yap", 7)]
    private let notSettingPhrases: [String] = ["Ses nedir", "İnternet nedir", "Bellek nedir", "Pil nedir", "Isı nedir", "Hafıza nedir", "Mikrofon nedir", "Kulaklık nedir", "Rapor nedir", "Raporu kim yazdı", "Ram nedir", "Sistem nedir", "Görüntü nedir", "Bluetooth nedir", "Isınma nedir", "Depolama nedir", "ses", "kamera", "internet", "rapor", "şarj", "pil", "ısı", "ram", "video", "kalite", "kadraj", "önizleme", "sesi", "aç", "kapat", "sesi kısma", "sesi açma", "sesi açmayın", "kamerayı kapat", "kamerayı aç", "videoyu sil", "yüksek", "düşük", "sol", "sağ", "hayır", "evet", "kamera istemiyorum", "kamera evet", "kamerayla çek", "kamera ile çekelim", "kamera olmasın", "kamera değil sesle", "internet yok", "ses yok", "mikrofon yok", "sorunun cevabı nedir", "rapor yaz", "Ses dalgaları", "Işığın hızı kaçtır", "Sesin hızı kaçtır", "Telefonun şarjı nasıl yapılır", "Kamera ne işe yarar", "İnternet nasıl çalışır", "Bellek nasıl çalışır", "Ses nasıl yayılır", "Bir sesi kısmak için", "Videoyu izleyin", "Kadraj nedir", "Görüntü işleme nedir", "Pil kaç volttur", "Isı ve sıcaklık nedir", "Genel rapor yazınız", "Sistem raporu hazırlayınız"]

    // MARK: Çözümleme

    private func isSetting(_ command: VoiceCommand?) -> Bool {
        switch command {
        case .report?, .volume?, .camera?: return true
        default: return false
        }
    }

    func testManyWaysOfAskingForEachReportAreUnderstood() {
        for (command, texts) in reportPhrases {
            for text in texts {
                XCTAssertEqual(VoiceCommand.parse(text), command, text)
                XCTAssertEqual(VoiceCommand.parseLenient(text), command, text)
                XCTAssertEqual(VoiceCommand.parse(text)?.isInfo, true, text)
            }
        }
    }

    func testVolumeCommandsAreUnderstood() {
        for (text, percent) in volumeSetPhrases {
            XCTAssertEqual(VoiceCommand.parse(text), .volume(.set(percent)), text)
        }
        // Nokta, büyük harf ve ünlem tanıyıcı çıktısında olabilir
        XCTAssertEqual(VoiceCommand.parse("Sesi aç."), .volume(.up))
        XCTAssertEqual(VoiceCommand.parse("Sesi kıs!"), .volume(.down))
    }

    func testCameraSettingCommandsAreUnderstood() {
        for (command, texts) in cameraPhrases {
            for text in texts {
                XCTAssertEqual(VoiceCommand.parse(text), command, text)
                XCTAssertEqual(VoiceCommand.parse(text)?.isInfo, true, text)
            }
        }
        for (text, seconds) in videoSecondsPhrases {
            XCTAssertEqual(VoiceCommand.parse(text), .camera(.videoSeconds(seconds)), text)
        }
    }

    /// Sınav sorusunun başlığı olabilecek sözler ("Bellek nedir"), olumsuz söyleyişler ve tek başına belirsiz sözler komut değildir
    func testQuestionTitlesAndNegatedOrVagueWordsAreNotReportsOrSettings() {
        for text in notSettingPhrases {
            XCTAssertFalse(isSetting(VoiceCommand.parse(text)), text)
            XCTAssertFalse(isSetting(VoiceCommand.parseLenient(text)), text)
        }
    }

    func testEarlierCommandsKeepTheirMeaning() {
        XCTAssertEqual(VoiceCommand.parse("durum"), .status)
        XCTAssertEqual(VoiceCommand.parse("durum raporu"), .status)
        XCTAssertEqual(VoiceCommand.parse("yardım"), .help)
        XCTAssertEqual(VoiceCommand.parse("testi bitir"), .endTest)
        XCTAssertEqual(VoiceCommand.parse("cevapları tekrarla"), .replayAnswers)
        XCTAssertEqual(VoiceCommand.parse("beşinci sorunun cevabını tekrarla"), .repeatNumber(5))
        XCTAssertEqual(VoiceCommand.parse("soruyu iptal et"), .cancelQuestion)
        XCTAssertEqual(VoiceCommand.parse("anlamadım"), .repeatSpeech)
        XCTAssertNil(VoiceCommand.parse("testi bitirme"))
        XCTAssertFalse(VoiceCommand.endTest.isInfo)
    }

    func testNewCommandsAreHintedToTheRecognizer() {
        for word in ["İnternet raporu", "Şarj durumu", "Ram durumu", "Genel rapor", "Sesi aç", "Sesi kıs"] {
            XCTAssertTrue(ListenHints.dictation.strings.contains(word), word)
        }
        for word in ["Sesi aç", "Sesi kıs", "Genel rapor"] {
            XCTAssertTrue(ListenHints.choice.strings.contains(word), word)
        }
        // Başla beklenirken (kamera seçimi kipi) söylenen yeni komutlar
        for word in ["Kadraj kontrolü", "Konumlandırmayı aç", "Konumlandırmayı kapat", "Konumlandırma desteğini aç", "Konumlandırma desteğini kapat"] {
            XCTAssertTrue(ListenHints.choice.strings.contains(word), word)
            XCTAssertTrue(ListenHints.dictation.strings.contains(word), word)
        }
        XCTAssertLessThanOrEqual(OnDeviceSpeechListener.contextualStrings.count, 100)
        XCTAssertTrue(Say.helpCommands.contains("genel rapor"))
        XCTAssertTrue(Say.helpCommands.contains("Sesi aç"))
        XCTAssertFalse(Say.helpCommands.contains("kamera sorusunu"), "Kamera sorusu komutu kaldırıldı")
        XCTAssertFalse(Say.helpCommands.lowercased().contains("sınav başlat"), "Sınav türü komutları kaldırıldı")
        XCTAssertTrue(Say.helpCommands.contains("konumlandırma desteğini aç"))
        XCTAssertTrue(Say.helpCommands.contains("kadraj kontrolü"))
    }

    // MARK: Söylenen cümleler

    func testReportSentences() {
        XCTAssertEqual(Say.megabytes(412), "412 megabayt")
        XCTAssertEqual(Say.megabytes(999), "999 megabayt")
        XCTAssertEqual(Say.megabytes(1536), "1,5 gigabayt")
        XCTAssertEqual(Say.megabytes(2048), "2 gigabayt")
        XCTAssertEqual(Say.reportBattery(percent: 12, charging: false, lowPower: false), "Telefonun şarjı yüzde 12. Şarj düşük; telefonu şarja takın.")
        XCTAssertEqual(Say.reportBattery(percent: 80, charging: true, lowPower: true), "Telefonun şarjı yüzde 80, şarjda. Düşük güç modu açık.")
        XCTAssertEqual(Say.reportBattery(percent: 15, charging: true, lowPower: false), "Telefonun şarjı yüzde 15, şarjda.", "Şarjdayken düşük uyarısı verilmez")
        XCTAssertEqual(Say.reportBattery(percent: nil, charging: false, lowPower: false), "Telefonun şarj durumu okunamıyor.")
        XCTAssertEqual(Say.reportThermal(.nominal), "Telefonun ısısı normal.")
        XCTAssertEqual(Say.reportThermal(.fair), "Telefon biraz ısındı.")
        XCTAssertTrue(Say.reportThermal(.serious).hasPrefix("Telefon ısındı ve yavaşlayabilir."))
        XCTAssertTrue(Say.reportThermal(.critical).hasPrefix("Telefon çok sıcak."))
        XCTAssertEqual(Say.reportMemory(availableMB: 180, footprintMB: 200, freeDiskMB: 5000, memoryLow: true, diskLow: false),
                       "Kalan bellek yaklaşık 180 megabayt. Bellek az. Program 200 megabayt kullanıyor. Boş depolama 4,9 gigabayt.")
        XCTAssertEqual(Say.reportMemory(availableMB: nil, footprintMB: nil, freeDiskMB: nil, memoryLow: false, diskLow: false), "Bellek bilgisi okunamadı.")
        XCTAssertEqual(Say.reportInternet(kind: .wifi, reachable: true, gemini: .ok), "İnternet var. Bağlantı türü: Wi-Fi. Gemini'ye ulaşılıyor.")
        XCTAssertEqual(Say.reportInternet(kind: .cellular, reachable: false, gemini: nil),
                       "Ağa bağlısınız ama internete ulaşılamıyor. Bağlantı türü: hücresel veri.")
        XCTAssertEqual(Say.reportInternet(kind: .unknown, reachable: true, gemini: .keyRejected("x")), "İnternet var. Gemini anahtarı kabul edilmedi.")
        XCTAssertEqual(Say.reportInternet(kind: .unknown, reachable: true, gemini: .unreachable("x")), "İnternet var. Gemini'ye ulaşılamıyor.")
        XCTAssertEqual(Say.reportSound(percent: 50, low: false, headphonesOK: true), "Ses seviyesi yüzde 50. Ses Bluetooth kulaklığa gidiyor.")
        XCTAssertEqual(Say.reportSound(percent: 5, low: true, headphonesOK: false),
                       "Ses seviyesi yüzde 5. Çok düşük; sesi aç diyebilirsiniz. Ses kulaklığa gitmiyor.")
        XCTAssertEqual(Say.reportMicrophone(ok: true, inputs: ["kulaklık mikrofonu"]), "Mikrofon bağlı: kulaklık mikrofonu. Sizi duyuyorum.")
        XCTAssertTrue(Say.reportMicrophone(ok: false, inputs: []).hasPrefix("Mikrofon bulunamadı."))
        XCTAssertTrue(Say.reportMicrophone(ok: false, inputs: []).contains("görünmüyor"))
        XCTAssertTrue(Say.reportMicrophone(ok: false, inputs: []).contains("mikrofon olmadan da"), "Mikrofon zorunlu değil: tarama sürer")
        XCTAssertEqual(Say.reportHeadphones(ok: true, outputs: ["Bluetooth kulaklık"], hint: ""), "Kulaklık bağlı: Bluetooth kulaklık.")
        XCTAssertTrue(Say.reportHeadphones(ok: false, outputs: ["telefon hoparlörü"], hint: "").hasPrefix("Kulaklıkta sorun var."))
    }

    // MARK: Akış yardımcıları

    private func say(_ h: SessionHarness, _ text: String) {
        h.listener.say(text)
        h.scheduler.advance(by: T.numberConfirm + 0.1)
    }

    /// Komutu söyler; program tam bir cümle söyleyip beklenen kipte dinlemeye dönene kadar bekler ve söylediği cümleyi verir
    private func command(_ h: SessionHarness, _ text: String, mode: ListenMode = .question,
                         file: StaticString = #filePath, line: UInt = #line) async -> String? {
        let before = h.speaker.spoken.count
        say(h, text)
        let done = await waitUntil(45) { h.speaker.spoken.count == before + 1 && h.vm.phase == .listening && h.vm.listenMode == mode }
        XCTAssertTrue(done, "'\(text)' sonrası program bir cümle söyleyip dinlemeye dönmedi: \(h.speaker.spoken)", file: file, line: line)
        return h.speaker.spoken.last
    }

    // MARK: Raporlar

    func testEachReportSpeaksTheCurrentStateAndGoesNowhere() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.battery.percent = 55
        h.battery.charging = true
        h.system.current = SystemSnapshot(availableMemoryMB: 180, footprintMB: 210, thermal: .serious, lowPowerMode: true, freeDiskMB: 5000, outputVolume: 0.5)
        var said = await command(h, "şarj durumu")
        XCTAssertEqual(said, "Telefonun şarjı yüzde 55, şarjda. Düşük güç modu açık.")
        said = await command(h, "ısınma durumu")
        XCTAssertEqual(said, Say.reportThermal(.serious))
        said = await command(h, "ram durumu")
        XCTAssertEqual(said, "Kalan bellek yaklaşık 180 megabayt. Bellek az. Program 210 megabayt kullanıyor. Boş depolama 4,9 gigabayt.")
        said = await command(h, "ses durumu")
        XCTAssertEqual(said, "Ses seviyesi yüzde 50. Ses Bluetooth kulaklığa gidiyor.")
        said = await command(h, "kulaklık durumu")
        XCTAssertEqual(said, "Kulaklık bağlı: Bluetooth kulaklık.")
        said = await command(h, "mikrofon durumu")
        XCTAssertEqual(said, "Mikrofon bağlı: kulaklık mikrofonu. Sizi duyuyorum.")
        XCTAssertTrue(h.answering.calls.isEmpty, "Raporlar Gemini'ye gitmez")
        XCTAssertEqual(h.vm.answers.count, 0)
    }

    func testReportsFollowTheRealStateNotTheStartState() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.battery.percent = 12
        h.battery.charging = false
        var said = await command(h, "pil kaç")
        XCTAssertEqual(said, "Telefonun şarjı yüzde 12. Şarj düşük; telefonu şarja takın.")
        h.battery.percent = 90
        said = await command(h, "pil kaç")
        XCTAssertEqual(said, "Telefonun şarjı yüzde 90.")
        h.system.current.thermal = .critical
        said = await command(h, "telefon ısındı mı")
        XCTAssertEqual(said, Say.reportThermal(.critical))
        h.system.current.thermal = .nominal
        said = await command(h, "telefon ısındı mı")
        XCTAssertEqual(said, "Telefonun ısısı normal.")
    }

    func testHeadphoneAndMicrophoneReportsNameTheProblem() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.route.current = FakeRoute.noHeadphones
        var said = await command(h, "kulaklık bağlı mı")
        XCTAssertTrue(said?.hasPrefix("Kulaklıkta sorun var.") == true, "\(String(describing: said))")
        XCTAssertTrue(said?.contains("telefona gidiyor") == true, "Neden de söylenir: \(String(describing: said))")
        h.route.current = RouteSnapshot(outputs: [.bluetoothHFP], inputs: [])
        said = await command(h, "mikrofon çalışıyor mu")
        XCTAssertTrue(said?.contains("görünmüyor") == true, "\(String(describing: said))")
        h.route.current = FakeRoute.good
        said = await command(h, "mikrofon çalışıyor mu")
        XCTAssertTrue(said?.contains("kulaklık mikrofonu") == true, "\(String(describing: said))")
        said = await command(h, "ses durumu")
        XCTAssertTrue(said?.hasSuffix("Ses Bluetooth kulaklığa gidiyor.") == true, "\(String(describing: said))")
    }

    func testInternetReportProbesTheNetworkAndGemini() async {
        let h = SessionHarness()
        _ = await h.startListening()
        let probes = h.health.quickCalls
        var said = await command(h, "internet raporu")
        XCTAssertEqual(said, "İnternet var. Bağlantı türü: Wi-Fi. Gemini'ye ulaşılıyor.")
        XCTAssertEqual(h.health.quickCalls, probes + 1, "Rapor internete gerçekten çıkıldığını yoklar")
        h.network.kind = .cellular
        h.health.geminiResult = .unreachable("zaman aşımı")
        said = await command(h, "internet var mı")
        XCTAssertEqual(said, "İnternet var. Bağlantı türü: hücresel veri. Gemini'ye ulaşılamıyor.")
        h.health.internet = false
        said = await command(h, "internet durumu")
        XCTAssertEqual(said, "Ağa bağlısınız ama internete ulaşılamıyor. Bağlantı türü: hücresel veri.")
        h.network.isOnline = false
        said = await command(h, "bağlantı durumu")
        XCTAssertEqual(said, Say.reportInternetOffline)
        XCTAssertTrue(h.answering.calls.isEmpty)
    }

    func testGeneralReportCoversEveryPart() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.battery.percent = 70
        let said = await command(h, "genel rapor") ?? ""
        for part in ["Genel rapor.", "İnternet var.", "Kulaklık bağlı", "Mikrofon bağlı", "Ses seviyesi", "Telefonun şarjı yüzde 70", "Telefonun ısısı normal", "Kalan bellek"] {
            XCTAssertTrue(said.contains(part), "\(part): \(said)")
        }
        XCTAssertEqual(h.speaker.spoken.filter { $0.hasPrefix("Genel rapor.") }.count, 1, "Tek konuşmada söylenir")
    }

    func testCameraReportSpeaksTheSettings() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.cameraSettings.streamQuality = 1
        h.cameraSettings.guidanceFrame = 0
        h.cameraSettings.guidanceEnabled = true
        h.cameraSettings.pageVideoSeconds = 5
        h.cameraSettings.videoToGemini = true
        h.cameraSettings.enhancement = 1
        h.cameraSettings.previewOff = false
        var said = await command(h, "kamera durumu")
        XCTAssertTrue(said?.hasPrefix("Görüntü kalitesi yüksek, kadraj yatay, görüntü yönü normal.") == true, "\(String(describing: said))")
        XCTAssertTrue(said?.contains("Soru videosu sayfa başına 5 saniye, Gemini'ye de gönderiliyor.") == true, "\(String(describing: said))")
        XCTAssertTrue(said?.contains("Her soruda kamera sorusu kapalı.") == true, "\(String(describing: said))")
        XCTAssertTrue(said?.contains("Kamera adı ya da kestirme adları eksik") == true, "Kamera yapılandırılmamışsa söylenir: \(String(describing: said))")
        h.cameraSettings.streamQuality = 2
        h.cameraSettings.previewOff = true
        said = await command(h, "görüntü raporu")
        XCTAssertTrue(said?.hasPrefix("Görüntü kalitesi düşük") == true, "\(String(describing: said))")
        XCTAssertTrue(said?.contains("Canlı önizleme kapalı.") == true, "\(String(describing: said))")
    }

    func testCameraReportAndTesterShowTheLastKnownCameraBattery() async {
        let h = SessionHarness()
        _ = await h.startListening()
        var said = await command(h, "kamera durumu")
        XCTAssertFalse(said?.contains("Son çekimde") == true, "Pil hiç okunmadıysa söylenmez: \(String(describing: said))")
        h.camera.lastBattery = .level(2)
        said = await command(h, "kamera durumu")
        XCTAssertTrue(said?.hasSuffix("Son çekimde kamera şarjı tahminen yüzde 40 ile 60 arasında görüldü.") == true, "\(String(describing: said))")
        h.camera.lastBattery = .charging
        said = await command(h, "kamera raporu")
        XCTAssertTrue(said?.hasSuffix("Son çekimde kamera şarjda görüldü.") == true, "\(String(describing: said))")
    }

    /// Rapor soru okunurken söylenirse okunan soru metni korunur; rapor soruya karışmaz ve soru normal gider
    func testReportInTheMiddleOfAQuestionKeepsTheQuestionText() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.listener.say("Soru 2 Ali eve gitti")
        h.scheduler.advance(by: T.utteranceGap + 0.1)
        h.battery.percent = 64
        let said = await command(h, "Soru 2 Ali eve gitti şarj durumu")
        XCTAssertEqual(said, "Telefonun şarjı yüzde 64.")
        XCTAssertEqual(h.vm.accumulator.text, "Soru 2 Ali eve gitti", "Yalnız komut atılır")
        XCTAssertTrue(h.answering.calls.isEmpty)
        h.answering.results = [.success(FakeAnswering.reply(2))]
        h.listener.say("Sonra okula yürüdü Cevapla")
        h.scheduler.advance(by: T.triggerConfirm + 0.1)
        let sent = await waitUntil(45) { h.answering.calls.count == 1 }
        XCTAssertTrue(sent, "\(h.speaker.spoken)")
        let question = h.answering.calls[0].question
        XCTAssertTrue(question.contains("Ali eve gitti Sonra okula yürüdü"), question)
        XCTAssertFalse(question.contains("şarj"), "Komut soruya karışmaz: \(question)")
    }

    func testReportAndSettingBeforeCevaplaAreNotSentAsAQuestion() async {
        let h = SessionHarness()
        _ = await h.startListening()
        let before = h.speaker.spoken.count
        h.battery.percent = 77
        h.listener.say("şarj durumu Cevapla")
        h.scheduler.advance(by: T.triggerConfirm + 0.1)
        let done = await waitUntil(45) { h.speaker.spoken.count == before + 1 && h.vm.phase == .listening && h.vm.listenMode == .question }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        XCTAssertEqual(h.speaker.spoken.last, "Telefonun şarjı yüzde 77.")
        XCTAssertTrue(h.answering.calls.isEmpty, "Komut soru gibi gitmez")
    }

    /// Onay beklenirken de rapor ve ayar söylenebilir; kip bozulmaz ve onay hâlâ beklenir
    func testReportsAndSettingsKeepTheConfirmationMode() async {
        let h = SessionHarness()
        _ = await h.startListening()
        say(h, "testi bitir")
        let asked = await waitUntil(45) { h.vm.listenMode == .confirmEnd && h.vm.phase == .listening && h.speaker.spoken.last == Say.confirmEnd }
        XCTAssertTrue(asked, "\(h.speaker.spoken)")
        h.battery.percent = 41
        var said = await command(h, "şarj durumu", mode: .confirmEnd)
        XCTAssertEqual(said, "Telefonun şarjı yüzde 41.")
        h.system.current.outputVolume = 0.5
        said = await command(h, "sesi aç", mode: .confirmEnd)
        XCTAssertEqual(said, Say.volumeChanged(63, action: .up, floored: nil))
        XCTAssertEqual(h.vm.answers.count, 0)
        say(h, "hayır")
        let back = await waitUntil(45) { h.vm.listenMode == .question && h.vm.phase == .listening }
        XCTAssertTrue(back, "Onay hâlâ çalışır: \(h.speaker.spoken)")
    }

    // MARK: Ses seviyesi

    func testVolumeUpDownAndSetAreAppliedAndVerified() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.system.current.outputVolume = 0.5
        var said = await command(h, "sesi aç")
        XCTAssertEqual(said, "Ses açıldı. Ses seviyesi yüzde 63.")
        XCTAssertEqual(h.volume.requests.last, 0.625)
        said = await command(h, "sesi kıs")
        XCTAssertEqual(said, "Ses kısıldı. Ses seviyesi yüzde 50.")
        said = await command(h, "sesi yüzde yetmiş yap")
        XCTAssertEqual(said, "Ses seviyesi yüzde 70 yapıldı.")
        XCTAssertEqual(h.system.current.outputVolume, 0.7)
        said = await command(h, "sesi yüzde yetmiş yap")
        XCTAssertEqual(said, "Ses zaten yüzde 70.")
        XCTAssertEqual(h.volume.requests.count, 3, "Zaten o düzeydeyse iOS'tan bir şey istenmez")
        XCTAssertTrue(h.answering.calls.isEmpty)
    }

    func testVolumeHasAFloorAndACeiling() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.system.current.outputVolume = 0.5
        var said = await command(h, "sesi yüzde beş yap")
        XCTAssertEqual(said, "Ses en az yüzde 15 olabilir. Ses seviyesi yüzde 15 yapıldı.", "Ses duyulmaz hâle getirilmez")
        said = await command(h, "sesi kıs")
        XCTAssertEqual(said, Say.volumeAlreadyMin(15))
        said = await command(h, "sesi yüzde yüz yap")
        XCTAssertEqual(said, "Ses seviyesi yüzde 100 yapıldı.")
        said = await command(h, "sesi aç")
        XCTAssertEqual(said, Say.volumeAlreadyMax)
        said = await command(h, "sesi yüzde 300 yap")
        XCTAssertEqual(said, Say.volumeSame(100), "Yüzü aşan istek yüze indirilir")
    }

    /// iOS ses çubuğunu kabul etmezse ayar yapılmış gibi söylenmez
    func testVolumeNotChangedByIOSIsSaidSo() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.system.current.outputVolume = 0.5
        h.volume.apply = nil
        let said = await command(h, "sesi aç")
        XCTAssertEqual(said, Say.volumeNotChanged(50))
        XCTAssertTrue(said?.contains("ses tuşlarını") == true)
        XCTAssertEqual(h.volume.requests.count, 1)
    }

    func testVolumeUnreadableIsSaidSo() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.system.current.outputVolume = nil
        var said = await command(h, "sesi aç")
        XCTAssertEqual(said, Say.volumeUnreadable)
        XCTAssertTrue(h.volume.requests.isEmpty, "Seviye okunamıyorsa ayar denenmez")
        said = await command(h, "ses durumu")
        XCTAssertTrue(said?.hasPrefix("Ses seviyesi okunamadı.") == true, "\(String(describing: said))")
    }

    /// Sesle ses açılınca düşük ses uyarısı hemen kalkar
    func testRaisingTheVolumeClearsTheLowVolumeWarning() async {
        let h = SessionHarness()
        h.system.current.outputVolume = 0.05
        _ = await h.startListening()
        XCTAssertTrue(h.vm.warnings.contains { $0.id == "seviye" }, "Başlangıçta düşük ses uyarısı var")
        say(h, "sesi yüzde elli yap")
        let cleared = await waitUntil(45) { !h.vm.warnings.contains { $0.id == "seviye" } && h.vm.phase == .listening }
        XCTAssertTrue(cleared, "Ses açılınca uyarı kalkar: \(h.vm.warnings)")
        XCTAssertEqual(h.system.current.outputVolume, 0.5)
    }

    // MARK: Kamera ayarları

    /// Düz "konumlandırmayı aç / kapat" hem tek soru yönlendirmesini hem toplu çekimdeki desteği değiştirir; "toplu çekimde …" ve "… desteğini …" yalnız desteği
    func testThePlainPositioningCommandsSwitchBothAndTheSeriesOnesOnlyTheSupport() async {
        let h = SessionHarness()
        _ = await h.startListening()
        let c = h.cameraSettings
        XCTAssertFalse(c.seriesGuidance, "Varsayılan: kapalı")
        var said = await command(h, "konumlandırmayı aç")
        XCTAssertEqual(said, "Sesle konumlandırma açıldı. Toplu çekimde de kamera sizi sesle yönlendirecek.")
        XCTAssertTrue(c.guidanceEnabled)
        XCTAssertTrue(c.seriesGuidance)
        said = await command(h, "konumlandırmayı aç")
        XCTAssertEqual(said, "Sesle konumlandırma zaten açık.")
        said = await command(h, "toplu çekimde konumlandırmayı kapat")
        XCTAssertEqual(said, "Toplu çekimde sesli konumlandırma kapatıldı. Çekim sırasında sessiz kalınacak.")
        XCTAssertFalse(c.seriesGuidance)
        XCTAssertTrue(c.guidanceEnabled, "Tek soru yönlendirmesine dokunulmaz")
        said = await command(h, "toplu çekimde konumlandırmayı kapat")
        XCTAssertEqual(said, "Toplu çekimde sesli konumlandırma zaten kapalı.")
        said = await command(h, "konumlandırma desteğini aç")
        XCTAssertEqual(said, "Toplu çekimde sesli konumlandırma açıldı. Çekim sürerken kamera kadrajı sesle tarif edecek.")
        XCTAssertTrue(c.seriesGuidance)
        said = await command(h, "konumlandırmayı kapat")
        XCTAssertEqual(said, "Sesle konumlandırma kapatıldı. Kamera sizi yönlendirmeyecek.")
        XCTAssertFalse(c.guidanceEnabled)
        XCTAssertFalse(c.seriesGuidance, "Düz kapatma desteği de kapatır")
    }

    func testTheCameraReportTellsWhetherThePositioningSupportIsOn() {
        let on = Say.reportCamera(configured: true, ask: true, highQuality: true, vertical: false, orientation: .normal, guidance: true, seriesGuidance: true,
                                  pageSeconds: 8, video: true, enhancement: 1, preview: true, pending: 0)
        XCTAssertTrue(on.contains("Toplu çekimde sesli konumlandırma desteği açık."), on)
        let off = Say.reportCamera(configured: true, ask: true, highQuality: true, vertical: false, orientation: .normal, guidance: true,
                                   pageSeconds: 8, video: true, enhancement: 1, preview: true, pending: 0)
        XCTAssertTrue(off.contains("Toplu çekimde sesli konumlandırma desteği kapalı."), off)
    }

    func testCameraSettingsAreAppliedAndSpoken() async {
        let h = SessionHarness()
        _ = await h.startListening()
        let c = h.cameraSettings
        var said = await command(h, "görüntü kalitesini düşük yap")
        XCTAssertEqual(said, "Görüntü kalitesi düşük yapıldı.")
        XCTAssertEqual(c.streamQuality, 2)
        said = await command(h, "görüntü kalitesini düşük yap")
        XCTAssertEqual(said, "Görüntü kalitesi zaten düşük.")
        said = await command(h, "kaliteyi yüksek yap")
        XCTAssertEqual(said, "Görüntü kalitesi yüksek yapıldı.")
        XCTAssertEqual(c.streamQuality, 1)
        said = await command(h, "videoyu gönderme")
        XCTAssertEqual(said, "Video Gemini'ye gönderilmeyecek; yalnız fotoğraf gider.")
        XCTAssertFalse(c.videoToGemini)
        said = await command(h, "videoyu geminiye gönder")
        XCTAssertEqual(said, "Video Gemini'ye de gönderilecek.")
        XCTAssertTrue(c.videoToGemini)
        said = await command(h, "video süresini sekiz saniye yap")
        XCTAssertEqual(said, "Soru videosu sayfa başına 8 saniye yapıldı.")
        XCTAssertEqual(c.pageVideoSeconds, 8)
        said = await command(h, "video süresini yirmi saniye yap")
        XCTAssertEqual(said, "Süre 2 ile 15 saniye arasında olabilir. Soru videosu sayfa başına 15 saniye yapıldı.")
        XCTAssertEqual(c.pageVideoSeconds, 15)
        said = await command(h, "sesle konumlandırmayı kapat")
        XCTAssertEqual(said, "Sesle konumlandırma kapatıldı. Kamera sizi yönlendirmeyecek.")
        XCTAssertFalse(c.guidanceEnabled)
        said = await command(h, "yönlendirmeyi aç")
        XCTAssertEqual(said, "Sesle konumlandırma açıldı. Toplu çekimde de kamera sizi sesle yönlendirecek.")
        XCTAssertTrue(c.guidanceEnabled)
        XCTAssertTrue(c.seriesGuidance, "Düz komut toplu çekimdeki desteği de açar")
        said = await command(h, "iyileştirmeyi güçlü yap")
        XCTAssertEqual(said, "Fotoğraf iyileştirme güçlü yapıldı.")
        XCTAssertEqual(c.enhancement, 2)
        said = await command(h, "iyileştirmeyi kapat")
        XCTAssertEqual(said, "Fotoğraf iyileştirme kapatıldı.")
        XCTAssertEqual(c.enhancement, 0)
        said = await command(h, "önizlemeyi kapat")
        XCTAssertEqual(said, "Canlı önizleme kapatıldı. Pil tasarrufu için ekranda görüntü görünmez.")
        XCTAssertTrue(c.previewOff)
        said = await command(h, "önizlemeyi aç")
        XCTAssertEqual(said, "Canlı önizleme açıldı.")
        XCTAssertFalse(c.previewOff)
        XCTAssertTrue(h.answering.calls.isEmpty)
    }

    func testFrameAndOrientationFollowEachOther() async {
        let h = SessionHarness()
        _ = await h.startListening()
        let c = h.cameraSettings
        c.guidanceFrame = 0
        c.imageOrientation = .normal
        var said = await command(h, "görüntüyü sağa çevir")
        XCTAssertEqual(said, Say.cameraOrientationRefused(verticalFrame: false), "Yatay kadrajda dik çevirme yapılmaz, nedeni söylenir")
        XCTAssertEqual(c.imageOrientation, .normal)
        said = await command(h, "görüntüyü ters çevir")
        XCTAssertEqual(said, "Görüntü yönü yüz seksen derece, ters yapıldı.")
        XCTAssertEqual(c.imageOrientation, .rotate180)
        said = await command(h, "kadrajı dikey yap")
        XCTAssertEqual(said, "Kadraj dikey yapıldı. Görüntü yönü doksan derece sağa.")
        XCTAssertEqual(c.guidanceFrame, 1)
        XCTAssertEqual(c.imageOrientation, .right90, "Kadraj değişince görüntü yönü ona uydurulur")
        said = await command(h, "görüntüyü ters çevir")
        XCTAssertEqual(said, Say.cameraOrientationRefused(verticalFrame: true))
        said = await command(h, "görüntüyü sola çevir")
        XCTAssertEqual(said, "Görüntü yönü doksan derece sola yapıldı.")
        XCTAssertEqual(c.imageOrientation, .left90)
        said = await command(h, "kadrajı dikey yap")
        XCTAssertEqual(said, "Kadraj zaten dikey.")
        said = await command(h, "kadrajı yatay yap")
        XCTAssertEqual(said, "Kadraj yatay yapıldı. Görüntü yönü normal.")
        XCTAssertEqual(c.imageOrientation, .normal)
    }

    func testCameraSettingsAreRefusedWhileTheCameraWorks() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.vm.cameraBusy = true
        let before = h.cameraSettings.streamQuality
        let said = await command(h, "görüntü kalitesini düşük yap")
        XCTAssertEqual(said, Say.cameraSettingBusy)
        XCTAssertEqual(h.cameraSettings.streamQuality, before, "Çekim sürerken ayar değişmez")
        h.vm.cameraBusy = false
    }



    /// Kamera sorusunda başka bir ayar söylenirse soru yine beklenir ("evet" kamerayı başlatır)
    func testOtherSettingsAtTheCameraQuestionKeepTheQuestionOpen() async {
        let h = SessionHarness(cameraFlow: true)
        h.trackEvents()
        _ = await h.startListening()
        let said = await command(h, "görüntü kalitesini düşük yap", mode: .cameraChoice)
        XCTAssertEqual(said, "Görüntü kalitesi düşük yapıldı.")
        XCTAssertEqual(h.vm.listenMode, .cameraChoice)
        XCTAssertEqual(h.camera.captures, 0, "Ayar komutu 'evet' sayılmaz, kamera başlamaz")
    }
}
