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
    /// Soru Gemini'ye gittikten sonra kesinti olup düzelince (yarım kalmış olabilir)
    static let recoveredAfterSend = "Bağlantı yeniden onarıldı. Sorunuz yarım kaldıysa son soruyu tekrar okuyunuz."

    /// Sesli "testi bitir" komutu: önce onay istenir; "evet" denirse kısa bilgi verilir ve test biter
    static let confirmEnd = "Testi bitirmek istiyor musunuz? Bitirmek için evet, devam etmek için hayır deyin."
    static let endCancelled = "Tamam, test devam ediyor. Soruyu okuyabilirsiniz."
    /// Program açılırken önceki kayıt bulundu: hazır anonsu ve soru bir arada
    static func readyAskContinue(answers: Int, next: Int) -> String {
        return "Ben hazırım, sistem kontrol edildi ve problem yok. Önceki kayıtta \(answers) cevap var, sıradaki soru \(next). Önceki kayıttan devam mı, yeni sınav mı? Devam ya da yeni deyin."
    }
    static let askChoiceAgain = "Önceki kayıttan devam mı, yeni sınav mı? Devam ya da yeni deyin."
    static func continuingPrevious(next: Int) -> String {
        return "Önceki kayıttan devam ediliyor. Sıradaki soru \(next). Soruyu okuyabilirsiniz."
    }
    static let startingNew = "Yeni sınav başladı. İlk soruyu okuyabilirsiniz."
    /// Sesli "testi bitir" komutu onaylandı: kısa bilgi, sonra test biter
    static func endingTest(_ answers: Int) -> String {
        return answers > 0 ? "Test bitiriliyor. \(answers) cevap kaydedildi." : "Test bitiriliyor."
    }
    /// Cevap duyulduktan sonra, dinlemeye geçmeden: program sıradaki soruyu kendisi ister
    static let nextQuestion = "Lütfen sonraki soruyu okuyun."
    static let askNumber = "Lütfen okuduğunuz sorunun numarasını söyleyin."
    static let askNumberAgain = "Soru numarasını duyamadım. Lütfen sorunun numarasını söyleyin. Numarayı bilmiyorsanız sıradaki deyin, sıradaki numara verilir."
    static let recoveredAskNumber = "Bağlantı yeniden onarıldı. Lütfen okuduğunuz sorunun numarasını söyleyin."

    static let passageTaken = "Paragraf metnini aldım. Bu paragraf hangi sorular için? Soru numaralarını söyleyip Tamam deyin."
    static let passageTargetsAgain = "Soru numaralarını anlayamadım. Paragrafın hangi sorulara ait olduğunu numaralarla söyleyip Tamam deyin."
    static let recoveredAskTargets = "Bağlantı yeniden onarıldı. Paragraf metnini aldım. Hangi sorulara ait olduğunu söyleyip Tamam deyin."
    static let passageEmpty = "Paragraf metni boş kaldı. Ortak paragraf deyip paragrafı yeniden okuyun."
    static func passageReady(_ numbers: [Int]) -> String {
        return "Ortak paragraf \(QuestionComposer.listText(numbers)) numaralı sorular için kaydedildi. Şimdi soruları okuyabilirsiniz."
    }

    /// Yarım okuma kesilip bağlantı düzelince: en son okunan cümle tekrarlanır, kullanıcı oradan devam eder (söyledikleri birleştirilir)
    static func continuePartial(passage: Bool, number: Int?, sentence: String) -> String {
        var text = "Bağlantı yeniden onarıldı. "
        if passage {
            if sentence.isEmpty { return text + "Ortak paragraf kipindesiniz. Paragrafı okuyun, bitirince tamamlandı deyin." }
            return text + "Ortak paragrafta en son şu cümleyi okudunuz: \(sentence). Buradan devam edebilirsiniz; bitirince tamamlandı deyin."
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
    static func resumed(cause: String, downSeconds: Int?, pending: PendingWork?) -> String {
        var text = "Program beklenmedik biçimde kapanıp yeniden açıldı"
        if let seconds = downSeconds, seconds >= 3 { text += ", yaklaşık \(duration(seconds)) kapalı kaldı" }
        text += ". Olası neden: \(cause)."
        if let pending = pending {
            text += pending.spoken != nil
                ? " Son sorunun cevabını yeniden okuyorum."
                : " Son sorunuz Gemini'ye gitmişti, cevabı yeniden alıyorum."
        } else {
            text += " Sistem hazır. Soru yarım kaldıysa lütfen son soruyu baştan okuyun."
        }
        return text
    }

    /// Kapanmadan önceki ortak paragraf geri yüklendi (ses kaydı kayboldu, metin kaldı)
    static func resumedPassage(_ numbers: [Int]) -> String {
        return "Ortak paragraf yazı olarak korundu: \(QuestionComposer.listText(numbers)) numaralı sorular için geçerli."
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
    static let noHeadphonesForReplay = "Bluetooth kulaklık bağlı değil; tekrar için kulaklığı bağlayın."

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
}
