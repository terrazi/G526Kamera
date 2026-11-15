import Foundation

/// Kulaklıktan söylenen ve ekranda yazan Türkçe metinlerin tek yeri
enum Say {
    /// Modül 1: donanım kontrolü sorunsuz bitince
    static let ready = "Ben hazırım, sistem kontrol edildi ve problem yok, şimdi ilk soruyu okumanı bekliyorum."
    /// Modül 4: kestirme çalışıp bağlantı düzelince
    static let recovered = "Bağlantı sorunu giderildi ve sistem yeniden hazır. Lütfen en son kaldığın soruyu tekrar oku."
    /// Kısa kesintide (birkaç saniye) uzun anons yerine
    static let recoveredShort = "Hazır. Son soruyu tekrar oku."

    // MARK: Soru gönderme, numara, ortak paragraf, kesinti sonrası devam

    /// "Cevapla" denince, soru Gemini'ye gittiği anda
    static let questionSent = "Soru başarıyla alınıp Gemini'ye gönderildi, cevap bekleniyor."
    /// Cevap uzun süre gelmezse arada
    static let stillWaiting = "Cevap bekleniyor."
    static let geminiSlow = "Gemini üç dakikada cevap vermedi. Soruyu tekrar okuyun."
    /// Çekilen soru için: kamera sorusu ya da telefonda bekleyen çekimin yeniden gönderimi hemen ardından gelir
    static let geminiSlowCamera = "Gemini üç dakikada cevap vermedi."
    static let cameraSlowKept = "Gemini çekilen soruya yine cevap vermedi. Soru telefonda duruyor; internet düzelince sırayla gönderilecek."
    /// Soru Gemini'ye gittikten sonra kesinti olup düzelince (yarım kalmış olabilir)
    static let recoveredAfterSend = "Bağlantı yeniden onarıldı. Sorunuz yarım kaldıysa son soruyu tekrar okuyunuz."

    /// Yalnız "Cevapla" denmiş, soru metni yok (tanıyıcı soruyu duymamış ya da soru okunmamış)
    static let noQuestionHeard = "Soruyu duymadım. Lütfen soruyu okuyup Cevapla deyin."
    static let confirmEndAgain = "Cevap alamadım, ikinci defa soruyorum. Testi bitirmek için evet, devam etmek için hayır deyin."
    /// Sesli "testi bitir" komutu: önce onay istenir; "evet" denirse kısa bilgi verilir ve test biter
    static let confirmEnd = "Testi bitirmek istiyor musunuz? Bitirmek için evet, devam etmek için hayır deyin."
    /// Soru numarası ya da paragraf numaraları beklenirken "testi bitir" denince: bekleyen iş bitirmeyle gönderilmeden kalır, bu da söylenir
    static let confirmEndHeldQuestion = "Okuduğunuz soru henüz gönderilmedi; bitirirseniz gönderilmeyecek. Testi bitirmek istiyor musunuz? Bitirmek için evet, devam etmek için hayır deyin."
    static let confirmEndHeldPassage = "Ortak paragraf henüz kaydedilmedi; bitirirseniz kaydedilmeyecek. Testi bitirmek istiyor musunuz? Bitirmek için evet, devam etmek için hayır deyin."
    static let endCancelled = "Tamam, test devam ediyor. Soruyu okuyabilirsiniz."
    /// Kamera sorusu hemen ardından sorulacaksa "soruyu okuyabilirsiniz" denmez (çelişir)
    static let endCancelledCamera = "Tamam, test devam ediyor."
    /// Program açılırken önceki kayıt bulundu: hazır anonsu ve soru bir arada
    static func readyAskContinue(answers: Int, next: Int) -> String {
        return "Ben hazırım, sistem kontrol edildi ve problem yok. Önceki kayıtta \(answers) cevap var, sıradaki soru \(next). Önceki kayıttan devam mı, yeni sınav mı? Devam ya da yeni deyin."
    }
    static let askChoiceAgain = "Cevap alamadım, ikinci defa soruyorum. Önceki kayıttan devam mı, yeni sınav mı? Devam ya da yeni deyin."
    static func continuingPrevious(next: Int, camera: Bool = false) -> String {
        return "Önceki kayıttan devam ediliyor. Sıradaki soru \(next)." + (camera ? "" : " Soruyu okuyabilirsiniz.")
    }
    static let startingNew = "Yeni sınav başladı. İlk soruyu okuyabilirsiniz."
    static let startingNewCamera = "Yeni sınav başladı."
    // MARK: Cevapları okuma ("cevapları tekrarla", "testi bitir" onayından sonra)

    /// Okuma başlarken: bitirme isteğiyle geldiyse test henüz bitmemiştir, cevaplar okununca ne yapılacağı sorulacaktır
    static func reviewStart(_ count: Int, ending: Bool) -> String {
        return ending ? "\(count) cevap kaydedildi. Bitirmeden önce cevaplar sırayla okunuyor."
                      : "Cevaplar baştan sona okunuyor. Toplam \(count) cevap."
    }
    /// Okuma bitince: ne kadarının okunduğu
    static func reviewReport(count: Int, failed: Int) -> String {
        guard failed > 0 else { return "\(count) sorunun cevabı okundu. Başka cevap yok." }
        return "\(count) cevaptan \(max(count - failed, 0)) tanesi okundu, \(failed) cevap dosyası çalınamadı. Başka cevap yok."
    }
    static let reviewStopped = "Cevaplar okunamadı."
    /// Rapordan hemen sonra: üç seçenek, birbirine benzemeyen üç sözcükle
    static let reviewMenu = "Ne yapmak istersiniz? Teste kaldığınız yerden devam etmek için Devam, cevapları yeniden dinlemek için Tekrar, testi tamamlamak için Bitir deyin."
    static let reviewMenuAgain = "Cevap alamadım, ikinci defa soruyorum. Devam, Tekrar ya da Bitir deyin."
    /// İki hatırlatmaya da cevap gelmedi
    static let reviewNoAnswer = "Yanıt alınamadı."
    /// Okuma ya da menü sırasında kesinti oldu ve düzeldi
    static let reviewResume = "Kesinti bitti. Teste devam etmek için Devam, cevapları yeniden dinlemek için Tekrar, testi tamamlamak için Bitir deyin."
    static let reviewBackToQuestion = "Teste devam ediyoruz. Lütfen sonraki soruyu okuyun."
    static let reviewBackToCamera = "Teste devam ediyoruz."
    static let reviewBackToNumber = "Teste devam ediyoruz. Lütfen okuduğunuz sorunun numarasını söyleyin."
    static let reviewBackToTargets = "Teste devam ediyoruz. Ortak paragraf hangi sorulara ait? Soru numaralarını söyleyip Tamam deyin."
    /// Test sesle tamamlandı
    /// `missing`: 1'den en yüksek cevaplanan numaraya kadar cevabı olmayan sorular; varsa kapanışta söylenir (atlanan soru sınavda fark edilmeden kalmasın)
    static func testCompleted(_ answers: Int, missing: [Int] = []) -> String {
        let base = answers > 0 ? "Test tamamlandı. \(answers) cevap kaydedildi." : "Test tamamlandı."
        guard !missing.isEmpty else { return base }
        let shown = Array(missing.prefix(12))
        return base + " Cevabı olmayan sorular: \(QuestionComposer.listText(shown))" + (missing.count > shown.count ? " ve devamı." : ".")
    }
    /// Aynı numaralı soru yeniden cevaplandı: eski cevap ezildi (numara yanlış okunmuş olabilir; kullanıcı fark etsin)
    static func answerReplaced(_ number: Int) -> String {
        return "\(number) numaralı sorunun önceki cevabı yenisiyle değiştirildi."
    }
    /// Duyulan söz komuta benziyor ama anlaşılamadı: program anladığını sanıp susmaz, açıkça söyler ve tekrar ister
    static let commandNotUnderstood = "Komutu anlayamadım. Lütfen komutu bir kez daha söyleyin."
    static let commandHelp = "Yine anlayamadım. Cevapları tekrarla, son cevabı tekrarla, soruyu iptal et ya da testi bitir diyebilirsiniz."
    /// Soru metni geldi, uzun süre konuşulmadı ve "Cevapla" duyulmadı: kullanıcı söylediyse tanıyıcı kaçırmıştır
    static let noTriggerHeard = "Cevapla komutunu duyamadım. Soru bittiyse lütfen Cevapla deyin."
    /// Paragraf numaraları söylendi ama "Tamam" duyulmadı
    static func passageTargetsConfirm(_ numbers: [Int]) -> String {
        return "\(QuestionComposer.listText(numbers)) numaralı sorular için duydum. Doğruysa Tamam deyin; değilse numaraları yeniden söyleyin."
    }
    /// Cevap duyulduktan sonra, dinlemeye geçmeden: program sıradaki soruyu kendisi ister
    static let nextQuestion = "Lütfen sonraki soruyu okuyun."
    /// Cevapsız ya da anlaşılmayan soru yeniden sorulurken sıra sayısı söylenir: ikinci soruşta "ikinci defa soruyorum" (metinlerin kendisinde),
    /// üçüncü soruşta "üçüncü defa soruyorum". Üçüncüde de cevap gelmezse ilgili kipin güvenli varsayılanı uygulanır.
    static func reask(_ text: String, attempt: Int) -> String {
        return attempt >= 3 ? text.replacingOccurrences(of: "ikinci defa", with: "üçüncü defa") : text
    }
    static let askNumber = "Lütfen okuduğunuz sorunun numarasını söyleyin."
    /// Bölümün soru sayısı biliniyorken numara anlaşılamadı: aralık söylenir (yanlış girilmiş soru sayısı da buradan fark edilir)
    static func askNumberAgainInSection(_ questions: Int) -> String {
        return "Soru numarasını anlayamadım, ikinci defa soruyorum. Bu bölümde 1'den \(questions)'e kadar soru var. Lütfen sorunun numarasını söyleyin. Numarayı bilmiyorsanız sıradaki deyin, sıradaki numara verilir."
    }
    static let askNumberAgain = "Soru numarasını duyamadım, ikinci defa soruyorum. Lütfen sorunun numarasını söyleyin. Numarayı bilmiyorsanız sıradaki deyin, sıradaki numara verilir."
    static let recoveredAskNumber = "Bağlantı yeniden onarıldı. Lütfen okuduğunuz sorunun numarasını söyleyin."

    /// "Ortak paragraf" denince (başka bir şey söylenmeden duraklanırsa) kulaklıktan söylenir
    static let passagePrompt = "Lütfen ortak paragrafı okuyun, bitince Tamam deyin."
    static let passageTaken = "Paragraf metnini aldım. Bu paragraf hangi sorular için? Soru numaralarını söyleyip Tamam deyin."
    static let passageTargetsAgain = "Numaraları anlayamadım, ikinci defa soruyorum. Örneğin beş altı yedi deyip Tamam deyin."
    /// Numaralar üst üste anlaşılamadı: paragraf yalnız sıradaki soruya bağlanır (kaybolmasın, döngü bitsin)
    static func passageFallback(_ next: Int, cameraNext: Bool = false) -> String {
        return "Numaraları anlayamadım. Paragraf yalnız sıradaki soru, yani \(next). soru için kaydedildi."
            + (cameraNext ? "" : " Şimdi soruyu okuyabilirsiniz.")
    }
    static let recoveredAskTargets = "Bağlantı yeniden onarıldı. Paragraf metnini aldım. Hangi sorulara ait olduğunu söyleyip Tamam deyin."
    static let passageEmpty = "Paragraf metni boş kaldı. Ortak paragraf deyip paragrafı yeniden okuyun."
    /// `cameraNext`: sıradaki adım kamera sorusu (ayrıca söylenir); "soruları okuyabilirsiniz" denmez
    static func passageReady(_ numbers: [Int], cameraNext: Bool = false) -> String {
        return "Ortak paragraf \(QuestionComposer.listText(numbers)) numaralı sorular için kaydedildi."
            + (cameraNext ? "" : " Şimdi soruları okuyabilirsiniz.")
    }

    /// Yarım okuma kesilip bağlantı düzelince: en son okunan cümle tekrarlanır, kullanıcı oradan devam eder (söyledikleri birleştirilir)
    static func continuePartial(passage: Bool, number: Int?, sentence: String) -> String {
        var text = "Bağlantı yeniden onarıldı. "
        if passage {
            if sentence.isEmpty { return text + "Ortak paragraf kipindesiniz. Paragrafı okuyun, bitirince tamam deyin." }
            return text + "Ortak paragrafta en son şu cümleyi okudunuz: \(sentence). Buradan devam edebilirsiniz; bitirince tamam deyin."
        }
        if let number = number {
            text += "En son \(TurkishOrdinal.inQuestion(number)) şu cümleyi okudunuz: \(sentence). "
        } else {
            text += "En son şu cümleyi okudunuz: \(sentence). "
        }
        return text + "Buradan devam edebilirsiniz."
    }

    // MARK: Beklenmedik kapanma, sistem sağlığı, takılma

    /// Program beklenmedik kapanıp yeniden açılınca (sesli): ne oldu, yarım iş ne olacak
    static func resumed(cause: String, downSeconds: Int?, pending: PendingWork?, camera: Bool = false) -> String {
        var text = "Program beklenmedik biçimde kapanıp yeniden açıldı"
        if let seconds = downSeconds, seconds >= 3 { text += ", yaklaşık \(duration(seconds)) kapalı kaldı" }
        text += ". Olası neden: \(cause)."
        if let pending = pending {
            text += pending.spoken != nil
                ? " Son sorunun cevabını yeniden okuyorum."
                : " Son sorunuz Gemini'ye gitmişti, cevabı yeniden alıyorum."
        } else {
            text += camera ? " Sistem hazır." : " Sistem hazır. Soru yarım kaldıysa lütfen son soruyu baştan okuyun."
        }
        return text
    }

    /// Kapanmadan önceki ortak paragraf geri yüklendi (ses kaydı kayboldu, metin kaldı)
    /// `photo`: paragraf kamerayla çekilmişti; kapanmada videosu kayboldu, yalnız fotoğrafı korundu
    static func resumedPassage(_ numbers: [Int], photo: Bool = false) -> String {
        return "Ortak paragraf \(photo ? "fotoğraf olarak" : "yazı olarak") korundu: \(QuestionComposer.listText(numbers)) numaralı sorular için geçerli."
    }

    static func duration(_ seconds: Int) -> String {
        return seconds < 90 ? "\(seconds) saniye" : "\(seconds / 60) dakika"
    }

    static let restartLoop = "Program kısa sürede art arda beklenmedik biçimde kapandı; açılış döngüsüne girmemek için otomatik başlatma durduruldu. Hazır olunca Başlat'a basın."
    static let memoryLow = "Telefonun belleği azaldı. Yük azaltıldı: yardımcı İngilizce tanıma kapatıldı. Test sürüyor."
    static let hot = "Telefon ısındı ve yavaşlayabilir. Mümkünse serin tutun. Test sürüyor."
    static let veryHot = "Telefon çok ısındı ve kapanabilir. Mümkünse hemen serin bir yere alın."
    static let lowPowerMode = "Telefon düşük güç modunda. Arka plandaki işler kısıtlanır; Ayarlar'dan düşük güç modunu kapatın."
    static func lowDisk(_ megabytes: Int) -> String {
        return "Telefonda yalnız \(megabytes) megabayt boş yer kaldı. Ses kayıtları yazılamayabilir."
    }
    /// Çıkış ses seviyesi çok düşük: cevaplar duyulmaz. iOS uygulamanın sesi kendiliğinden açmasına izin vermez; kullanıcı tuşla açar.
    static func lowVolume(_ percent: Int) -> String {
        return "Telefonun ses seviyesi yüzde \(percent), çok düşük. Cevapları duyamayabilirsiniz; telefonun ses artırma tuşuna basın."
    }
    static let stuckRestarting = "Bir adım beklenenden uzun sürdü; sistem yeniden kuruluyor."

    static let soundTest = "Ses denemesi. Beni kulaklığınızdan duyuyorsanız ses yolu çalışıyor."
    static func lowBattery(_ percent: Int) -> String {
        return "Telefonun şarjı yüzde \(percent). Telefonu şarja takın."
    }

    static let noEnglishDictation = "Telefonda çevrimdışı İngilizce dikte yüklü değil; İngilizce sorular yalnız ses kaydından çözülür. Ayarlar, Genel, Klavye, Dikte bölümünden İngilizce'yi de ekleyip internetteyken bir kez indirin."
    /// Onarım başlarken kulaklıktan söylenen kısa bilgiler
    static let networkLost = "İnternet bağlantısı yok. Test duraklatıldı, bağlantı onarılıyor."
    static let hardwareRepairing = "Kulaklık ya da mikrofon sorunu var. Test duraklatıldı, onarılıyor."
    /// Konuşma tanıma düştü; kulaklık ve mikrofon sağlam. Kullanıcı neyin onarıldığını bilsin, sessizlik kesinti gibi görünmesin.
    static let recognizerRestarting = "Konuşma tanıma durdu, yeniden kuruluyor. Kulaklık ve mikrofon sağlam."
    static let recognizerAgain = "Konuşma tanıma yine düştü, yeniden kuruluyor."
    static let recognizerStuck = "Konuşma tanıma açılamıyor. On beş saniyede bir yeniden deniyorum. Düzelmezse telefonu yeniden başlatın."
    static let dictationOff = "Konuşma tanıma kapalı. Ayarlar, Genel, Klavye bölümünde Dikteyi Etkinleştir seçeneğini açın."
    static func recordingFailed(_ number: Int) -> String {
        return "Soru \(number) cevabının ses kaydı klasöre yazılamadı. Telefonda yer kalmamış ya da kayıt klasörüne erişim gitmiş olabilir. Cevap okundu."
    }
    static let transcriptFailed = "Cevaplar yazı dosyasına eklenemedi. Telefonda yer kalmamış ya da kayıt klasörüne erişim gitmiş olabilir."
    static let answerFailed = "Cevap alınamadı. Soruyu yeniden oku."
    static let receiverNotRouted = "Mikrofon alıcısı takılı ama ses yoluna girmiyor. Alttaki mikrofon listesinden alıcıya bir kez dokunun. Kulaklık sağlam göründüğü için Kestirme çalıştırılmıyor (bağlantıyı koparırdı)."
    /// Kulaklık sağlam, mikrofon alıcısı hiç görünmüyor (yaka mikrofonu çıkarıldı ya da gevşedi)
    static let micMissing = "Yaka mikrofonu görünmüyor. Mikrofonu ve alıcıyı kontrol edin; takılınca kendiliğinden devam edilir. Kulaklık sağlam olduğu için Kestirme çalıştırılmıyor."
    /// Kulaklık sağlam, mikrofon tarafı onarılıyor (Kestirme çalışmaz)
    static let micRepairing = "Mikrofon sorunu var. Test duraklatıldı, mikrofon yeniden kuruluyor."
    /// Cevap diğer modeller yanıt vermeyince ÜCRETLİ modelden geldi (para harcandı); söylenen tek cümle budur
    static let paidModelUsed = "Ücretli modelden cevaplandı."
    static let noKeyShort = "Gemini API anahtarı girilmemiş. Ayarlardan yapıştırın."
    static let noOnDevice = "Bu telefonda çevrimdışı Türkçe dikte yüklü değil. Ayarlar, Genel, Klavye, Dikte bölümünden Türkçe'yi ekleyip internetteyken bir kez indirin."
    static let permissionDenied = "Mikrofon ve konuşma tanıma izni gerekli. Ayarlar, Sesli Kontrol bölümünden izin verin."
    static let notConfigured = "Kestirme adları boş; kendi kendini onarma kapalı. Ayarlardan kestirmelerin adını yazın."
    static let nothingToReplay = "Tekrarlanacak cevap yok."
    /// "Anlamadım / bir daha söyle" denince söylenecek hiçbir anons ve cevap yoksa
    static let nothingToRepeat = "Tekrar edilecek bir şey yok."
    /// Belirli bir sorunun cevabı istendi ("5. sorunun cevabını tekrarla") ama o numara için kayıt yok
    static func noAnswerFor(_ number: Int) -> String { return "\(number) numaralı soru için kayıtlı cevap yok." }

    // MARK: Sesli iptal komutları
    /// "Soruyu iptal et": okunan soru silindi; ardından kamera sorusu geliyorsa "baştan okuyun" denmez
    static let questionCancelled = "Okunan soru silindi. Lütfen soruyu baştan okuyun."
    static let questionCancelledCamera = "Okunan soru silindi."
    static let nothingToCancelQuestion = "Silinecek soru yok."
    /// "Paragrafı iptal et": okunan ya da numaraları beklenen paragraf vazgeçildi / kayıtlı ortak paragraf silindi / silinecek paragraf yok.
    /// `cameraNext`: bu soru için kamera yeniden sorulacak ("soruyu okuyun" denmez)
    static func passageCancelled(cameraNext: Bool) -> String {
        return "Ortak paragraf iptal edildi." + (cameraNext ? "" : " Lütfen sonraki soruyu okuyun.")
    }
    static func storedPassageCancelled(cameraNext: Bool) -> String {
        return "Kayıtlı ortak paragraf silindi." + (cameraNext ? "" : " Lütfen sonraki soruyu okuyun.")
    }
    static func noPassageToCancel(cameraNext: Bool) -> String {
        return "Silinecek ortak paragraf yok." + (cameraNext ? "" : " Lütfen sonraki soruyu okuyun.")
    }
    static let noHeadphonesForReplay = "Bluetooth kulaklık bağlı değil; tekrar için kulaklığı bağlayın."

    // MARK: Bilgi ve düzeltme komutları ("yardım", "ne duydun", "son cümleyi sil", "durum", "cevapsız soruları söyle")
    /// Her komut yaptığını ya da yapamadığını kısaca söyler
    static let helpCommands = "Komutlar: Cevapla ya da Gönder, soruyu gönderir. Testi bitir. Cevapları tekrarla. Son cevabı tekrarla. Soruyu iptal et. Paragrafı iptal et. Ortak paragraf. Son cümleyi sil. Ne duydun. Durum. Cevapsız soruları söyle. Raporlar için internet, mikrofon, kulaklık, ses, kamera, şarj, ısı ya da ram durumu deyin; hepsi için genel rapor deyin. Sesi aç ya da sesi kıs deyin. Kamera ayarları için kamera sorusunu kapat, görüntü kalitesini yüksek yap ya da kadrajı dikey yap deyin. Duyamadığınız her şeyi bir daha söyle diyerek tekrarlatabilirsiniz."
    /// "Ne duydun": soru metni yoksa
    static let nothingHeard = "Henüz bir şey duymadım."
    /// "Ne duydun" soru dinlenmediği bir anda söylendi (evet/hayır, numara, menü…)
    static let noQuestionText = "Şu anda dinlenen bir soru metni yok."
    /// Duyulan metin: uzunsa yalnız son sözcükler okunur
    static func heard(_ text: String, limit: Int = 30) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count > limit else { return "Duyduğum: " + words.joined(separator: " ") + "." }
        return "Metin uzun. Duyduğum son \(limit) sözcük: " + words.suffix(limit).joined(separator: " ") + "."
    }
    /// "Son cümleyi sil": silinecek bir şey yok
    static let nothingToDelete = "Silinecek cümle yok."
    /// Silinen sözün başı okunur (ilk sekiz sözcük); soru metninden bir şey kaldıysa devam edilir, kalmadıysa baştan okunur
    static func lastSentenceDeleted(_ removed: [String], remaining: Bool) -> String {
        let shown = removed.prefix(8).joined(separator: " ") + (removed.count > 8 ? " ve devamı" : "")
        return "Son cümle silindi: \(shown). " + (remaining ? "Soruyu okumaya devam edebilirsiniz." : "Soru metni boş kaldı, baştan okuyabilirsiniz.")
    }
    /// "Durum": yalnız bilinen bilgiler söylenir (kulaklık, internet, pil bilinmiyorsa atlanır)
    static func status(answers: Int, next: Int, headphones: Bool?, internet: NetPulse, battery: Int?, charging: Bool) -> String {
        var parts: [String] = [answers == 0 ? "Henüz cevaplanan soru yok." : "\(answers) soru cevaplandı.", "Sıradaki soru numarası \(next)."]
        if let headphones = headphones { parts.append(headphones ? "Kulaklık bağlı." : "Kulaklıkta sorun var.") }
        switch internet {
        case .up: parts.append("İnternet var.")
        case .down: parts.append("İnternet yok.")
        case .suspect: parts.append("İnternet kararsız.")
        case .unknown: break
        }
        if let battery = battery { parts.append("Pil yüzde \(battery)" + (charging ? ", şarjda." : ".")) }
        return parts.joined(separator: " ")
    }
    /// "Cevapsız soruları söyle": 1'den en yüksek cevaplanan numaraya kadar cevabı olmayanlar
    static func missingAnswers(_ numbers: [Int], highest: Int) -> String {
        if highest == 0 { return "Henüz cevaplanan soru yok." }
        guard !numbers.isEmpty else { return "Cevapsız soru yok. \(highest) numaraya kadar hepsi cevaplandı." }
        let shown = Array(numbers.prefix(12))
        return "Cevabı olmayan sorular: \(QuestionComposer.listText(shown))" + (numbers.count > shown.count ? " ve devamı." : ".")
    }

    /// Gemini hata verince kulaklıktan söylenen kısa cümle
    static func geminiFailure(_ error: GeminiError) -> String {
        switch error.kind {
        case .quota: return "Gemini kotası doldu. Soruyu biraz sonra tekrar oku."
        case .key: return "Gemini API anahtarı reddedildi. Ayarlardan anahtarı kontrol et."
        case .cap: return "Gemini harcama sınırı doldu."
        case .blocked: return "Gemini bu soruyu güvenlik nedeniyle engelledi. Soruyu tekrar oku."
        case .tooBig: return "Soru çok uzun geldi. Daha kısa oku."
        case .model: return "Gemini modeli bulunamadı."
        case .empty: return "Gemini boş cevap verdi. Soruyu tekrar oku."
        default: return "Gemini cevap veremedi. Soruyu tekrar oku."
        }
    }

    // MARK: Sürüm 4: kamera
    static let askCamera = "Bu soruyu kamera ile çekip göndermek ister misiniz? Evet ya da hayır deyin."
    static let askCameraAfterRecovery = "Bağlantı yeniden onarıldı. Bu soruyu kamera ile çekip göndermek ister misiniz? Evet ya da hayır deyin."
    static let askCameraAgain = "Anlayamadım, ikinci defa soruyorum. Bu soruyu kamera ile çekip göndermek ister misiniz? Evet ya da hayır deyin."
    static let readyCamera = "Ben hazırım, sistem kontrol edildi ve problem yok."
    /// Kamera sorusu açık ama kamera adı ya da kestirme adları yazılmamış: sessizce V3'e dönülmez, kullanıcıya söylenir
    static let readyCameraMissing = "Ben hazırım, sistem kontrol edildi. Kamera ayarları eksik olduğu için sorular sesle okunacak."
    static let cameraDeclined = "Tamam. Soruyu okuyun, bitince Cevapla deyin."
    /// Kamera sorusu cevapsız kaldıkça sıra sayısıyla yeniden sorulur (2. ve 3. soruş); üçüncüde de cevap gelmezse kameraya kendiliğinden geçilir
    static func askCameraRepeat(_ attempt: Int) -> String {
        let ordinal = attempt >= 3 ? "üçüncü" : "ikinci"
        return "Cevap vermediniz, \(ordinal) defa soruyorum. Bu soruyu kamera ile çekip göndermek ister misiniz? Evet ya da hayır deyin."
    }
    /// "Evet" denince (ya da üçüncü soruşta cevap gelmeyince): çekilecek şeyin soru mu paragraf mı olduğu sorulur
    static let askCaptureKind = "Soru mu, ortak paragraf mı çekeceksiniz? Birinci seçenek soru, ikinci seçenek paragraf."
    static let askCaptureKindAfterRecovery = "Bağlantı yeniden onarıldı. " + askCaptureKind
    static let askCaptureKindAgain = "Anlayamadım, ikinci defa soruyorum. " + askCaptureKind
    static func askCaptureKindRepeat(_ attempt: Int) -> String {
        let ordinal = attempt >= 3 ? "üçüncü" : "ikinci"
        return "Cevap vermediniz, \(ordinal) defa soruyorum. " + askCaptureKind
    }
    static let captureKindDefault = "Cevap vermediniz. Soru olarak çekiyorum."
    static let cameraAutoStart = "Cevap vermediniz. Üç defa sordum, kamera ile devam ediyorum."
    static let cameraConnecting = "Kameraya geçiliyor. Birkaç saniye bekleyin."
    static let cameraShortcutsMissing = "Kamera için kestirme adları yazılmamış. Ayarlardan yazın. Şimdilik soruyu okuyun, bitince Cevapla deyin."
    static let cameraRepairing = "Kameraya bağlanılamadı. Bağlantı onarılıyor."
    /// Çekim başarılı: kullanıcı neyin tamamlandığını ve sıradaki adımı duyar
    static let cameraCaptured = "Soru için video ve fotoğraf çekimi başarıyla yapıldı. Kamera kapatıldı, internete geçiliyor."
    static let cameraSending = "İnternet geldi. Soru Gemini'ye gönderiliyor, cevabı bekleyin."
    static let cameraSendingWithPassage = "İnternet geldi. Soru, ortak paragrafın görüntüleriyle birlikte Gemini'ye gönderiliyor, cevabı bekleyin."
    static let questionSentWithPassage = "Soru, ortak paragrafın görüntüleriyle birlikte Gemini'ye gönderildi, cevap bekleniyor."
    static let cameraEntryText = "Kamera ile çekilen soru"
    static let cameraSavedOffline = "Soru çekildi ama internet gelmedi. Telefonda saklandı; bağlantı onarılıyor, düzelince gönderilecek."
    static let recoveredPendingShot = "Bağlantı yeniden onarıldı."
    static let cameraSlowParked = "Gemini çekilen soruya birkaç kez cevap vermedi. Soru telefondaki klasörde duruyor; bu testte artık denenmeyecek, sonraki testte yeniden gönderilecek."
    static let cameraPendingParked = "Önceki çekilen soru birkaç kez gönderilemedi. Telefondaki klasörde duruyor; bu testte artık denenmeyecek, sonraki testte yeniden gönderilecek."
    static let cameraPendingKept = "Önceki çekilen soru yine gönderilemedi. Telefonda duruyor; internet düzelince sırayla gönderilecek."
    static let cameraPendingSending = "Önceki çekilen soru telefonda bekliyordu, şimdi gönderiyorum."

    // MARK: Sürüm 4: kamerayla ortak paragraf
    static let askPassageCamera = "Ortak paragraf. Paragrafı kamera ile çekmek ister misiniz? Evet ya da hayır deyin."
    static let askPassageCameraAgain = "Cevap alamadım, ikinci defa soruyorum. Ortak paragrafı kamera ile çekmek ister misiniz? Evet ya da hayır deyin."
    static let askPassageCameraAfterRecovery = "Bağlantı yeniden onarıldı. Ortak paragrafı kamera ile çekmek ister misiniz? Evet ya da hayır deyin."
    /// "Hayır": paragraf V3'teki gibi sesle okunur
    static let passageCameraDeclined = "Tamam. Lütfen ortak paragrafı okuyun, bitince Tamam deyin."
    static let passageCameraDefaultVoice = "Cevap alamadım. Ortak paragrafı okuyarak devam ediyoruz. Lütfen paragrafı okuyun, bitince Tamam deyin."
    static let passageShortcutsMissing = "Kamera için kestirme adları yazılmamış. Ayarlardan yazın. Şimdilik ortak paragrafı okuyun, bitince Tamam deyin."
    static let passageCameraConnecting = "Ortak paragraf için kameraya geçiliyor. Birkaç saniye bekleyin."
    static let passageCaptured = "Paragraf için video ve fotoğraf çekimi başarıyla yapıldı. Kamera kapatıldı, internete geçiliyor."
    /// İnternet geldi, paragraf alındı: hangi sorulara ait olduğu sorulur (V3'teki paragraf adımı)
    static let passageTakenCamera = "İnternet geldi. Paragrafın video ve fotoğrafı alındı. Bu paragraf hangi sorular için? Soru numaralarını söyleyip Tamam deyin."
    static let passageSavedOffline = "Paragraf çekildi ama internet gelmedi. Görüntüler telefonda saklandı; bağlantı onarılıyor, düzelince hangi sorulara ait olduğunu soracağım."
    static let recoveredAskTargetsCamera = "Bağlantı yeniden onarıldı. Paragrafın video ve fotoğrafı alındı. Hangi sorulara ait olduğunu söyleyip Tamam deyin."
    /// Kamera paragrafı çekemedi: neden ve sesle devam yolu (V3'teki gibi okunur)
    static func passageCameraFailed(_ failure: CameraFailure) -> String {
        return "\(failure.message) Şimdilik ortak paragrafı okuyun, bitince Tamam deyin."
    }

    /// Kamera çekimi olmadı (internet geldi): neden ve sesle devam yolu
    static func cameraFailed(_ failure: CameraFailure) -> String {
        return "\(failure.message) Şimdilik soruyu okuyun, bitince Cevapla deyin."
    }

    /// Kamera çekimi olmadı ve internet de gelmedi: neden; bağlantı onarılır
    static func cameraFailedOffline(_ failure: CameraFailure) -> String {
        return "\(failure.message) İnternet de gelmedi, bağlantı onarılıyor."
    }


    // MARK: Sınav bölümleri

    /// "birinci", "ikinci"… (rakam okunuşuna bırakılmaz); sözcüğü olmayan sıralar için "7."
    static func ordinal(_ n: Int) -> String {
        return TurkishOrdinal.word(n) ?? "\(n)."
    }

    /// "Birinci" (cümle başı)
    static func ordinalCapital(_ n: Int) -> String {
        let word = ordinal(n)
        return word.prefix(1).uppercased(with: Locale(identifier: "tr_TR")) + word.dropFirst()
    }

    /// Cevapsız numaralar kısa söylenir: ardışık dört ya da daha fazlası aralık olur ("5, 12 ve 31 ile 40 arası")
    static func compactList(_ numbers: [Int], limit: Int = 10) -> String {
        let sorted = Array(Set(numbers)).sorted()
        var parts: [String] = []
        var index = 0
        while index < sorted.count {
            var end = index
            while end + 1 < sorted.count, sorted[end + 1] == sorted[end] + 1 { end += 1 }
            if end - index >= 3 {
                parts.append("\(sorted[index]) ile \(sorted[end]) arası")
            } else {
                parts.append(contentsOf: sorted[index...end].map { String($0) })
            }
            index = end + 1
        }
        let shown = Array(parts.prefix(limit))
        var text: String
        if shown.count <= 1 {
            text = shown.first ?? ""
        } else {
            text = shown.dropLast().joined(separator: ", ") + " ve " + (shown.last ?? "")
        }
        if parts.count > shown.count { text += " ve devamı" }
        return text
    }

    /// Sınav başlarken / yeni bölüme geçilirken
    static func sectionStart(_ section: Int, questions: Int) -> String {
        return "\(ordinalCapital(section)) bölüme başlıyorum." + (questions > 0 ? " Bu bölümde \(questions) soru var." : "")
    }

    /// Önceki kayıttan devam edilirken ve "durum" denince: hangi bölümde olunduğu
    static func sectionHere(_ section: Int, questions: Int) -> String {
        return "Şu an \(ordinal(section)) bölümdesiniz." + (questions > 0 ? " Bu bölümde \(questions) soru var." : "")
    }

    static func readyAskContinueSection(section: Int, answers: Int, next: Int) -> String {
        return "Ben hazırım, sistem kontrol edildi ve problem yok. Önceki kayıtta \(ordinal(section)) bölümde \(answers) cevap var, sıradaki soru \(next). Önceki kayıttan devam mı, yeni sınav mı? Devam ya da yeni deyin."
    }

    /// "Bölümü tamamla" ama sınavda bölüm yok
    static let noSections = "Bu sınavda bölüm tanımlı değil. Bölümleri Ayarlar ekranından açabilirsiniz."

    // "Bölümü tamamla" onayı (testi bitirme onayının bölüm biçimi)
    static let confirmSectionEnd = "Bölümü tamamlamak istiyor musunuz? Tamamlamak için evet, devam etmek için hayır deyin."
    static let confirmSectionEndAgain = "Cevap alamadım, ikinci defa soruyorum. Bölümü tamamlamak için evet, devam etmek için hayır deyin."
    static let confirmSectionHeldQuestion = "Okuduğunuz soru henüz gönderilmedi; tamamlarsanız gönderilmeyecek. Bölümü tamamlamak istiyor musunuz? Tamamlamak için evet, devam etmek için hayır deyin."
    static let confirmSectionHeldPassage = "Ortak paragraf henüz kaydedilmedi; tamamlarsanız kaydedilmeyecek. Bölümü tamamlamak istiyor musunuz? Tamamlamak için evet, devam etmek için hayır deyin."
    static let sectionEndCancelled = "Tamam, bölüm devam ediyor. Soruyu okuyabilirsiniz."
    static let sectionEndCancelledCamera = "Tamam, bölüm devam ediyor."

    /// Bölüm tamamlanırken cevapların okunması ve menü (Devam / Tekrar / Bitir)
    static func reviewStartSection(_ count: Int) -> String {
        return "\(count) cevap kaydedildi. Bölümü tamamlamadan önce cevaplar sırayla okunuyor."
    }
    static let reviewMenuSection = "Ne yapmak istersiniz? Bölümde kaldığınız yerden devam etmek için Devam, cevapları yeniden dinlemek için Tekrar, bölümü tamamlamak için Bitir deyin."

    /// Bölüm tamamlandı: kaç cevap kaydedildi ve (soru sayısı biliniyorsa) hangi sorular cevapsız
    static func sectionCompleted(_ section: Int, answers: Int, missing: [Int]) -> String {
        var text = "\(ordinalCapital(section)) bölüm tamamlandı."
        if answers > 0 { text += " \(answers) cevap kaydedildi." }
        if !missing.isEmpty { text += " Cevabı olmayan sorular: \(compactList(missing))." }
        return text
    }

    /// "Yeni bir bölüm ile devam etmek ister misiniz, yoksa testi tamamlayalım mı?"
    static func askNextSection(_ next: Int) -> String {
        return "Yeni bir bölüm ile devam etmek ister misiniz, yoksa testi tamamlayalım mı? \(ordinalCapital(next)) bölüme geçmek için evet, testi tamamlamak için hayır deyin."
    }
    static func askNextSectionAgain(_ next: Int) -> String {
        return "Cevap alamadım, ikinci defa soruyorum. \(ordinalCapital(next)) bölüme geçmek için evet, testi tamamlamak için hayır deyin."
    }
    static let nextSectionDefault = "Cevap alamadım. Yeni bölüme geçiyorum."
    static let allSectionsDone = "Bütün bölümler tamamlandı."

    /// Test bölümlü sınavda tamamlandı: bölüm başına cevap sayıları; bitirilen bölümde cevapsız soru varsa onlar
    static func testCompletedSections(_ counts: [Int], current: Int, missing: [Int]) -> String {
        let total = counts.reduce(0, +)
        guard total > 0 else { return "Test tamamlandı." }
        var parts: [String] = []
        for (index, count) in counts.enumerated() where count > 0 {
            parts.append("\(ordinal(index + 1)) bölümde \(count)")
        }
        var text = "Test tamamlandı. " + parts.joined(separator: ", ") + " cevap kaydedildi."
        if !missing.isEmpty { text += " \(ordinalCapital(current)) bölümde cevabı olmayan sorular: \(compactList(missing))." }
        return text
    }


    static func askNextSectionAfterRecovery(_ next: Int) -> String {
        return "Kesinti bitti. \(ordinalCapital(next)) bölüme geçmek için evet, testi tamamlamak için hayır deyin."
    }
    static let sectionFolderFailed = "Yeni bölümün klasörü açılamadı. Test tamamlanıyor."

    /// "Cevapsız soruları söyle" (bölümün soru sayısı biliniyorken)
    static func sectionMissing(_ numbers: [Int], questions: Int) -> String {
        guard !numbers.isEmpty else { return "Cevapsız soru yok. \(questions) sorunun hepsi cevaplandı." }
        return "Cevabı olmayan sorular: \(compactList(numbers))."
    }

}
