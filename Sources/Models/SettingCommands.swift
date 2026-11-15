import Foundation

/// Sesle istenen rapor türü: "internet raporu", "mikrofon durumu", "şarj kaç", "ısındı mı", "ram durumu", "genel rapor"
enum ReportKind: Equatable {
    case internet
    case microphone
    case headphones
    case sound
    /// Kamera ve görüntü ayarları, kamera pili, bekleyen çekim
    case camera
    case battery
    case thermal
    /// RAM (kalan bellek) ve boş depolama
    case memory
    /// Hepsi birden
    case general
}

/// Sesle ses seviyesi: "sesi aç", "sesi kıs", "sesi yüzde elli yap"
enum VolumeAction: Equatable {
    case up
    case down
    /// Yüzde (0–100; alt sınırı uygulama koyar)
    case set(Int)
}

/// Sesle kamera ayarı: "kamera sorusunu kapat", "görüntü kalitesini yüksek yap", "video süresini sekiz saniye yap", "kadrajı dikey yap"…
enum CameraAction: Equatable {
    /// Her soruda "kamera ile çekmek ister misiniz?" sorulsun mu
    case askQuestion(Bool)
    /// Görüntü kalitesi: yüksek 1920×1080, düşük 640×360
    case quality(high: Bool)
    /// Soru videosu da Gemini'ye gitsin mi
    case sendVideo(Bool)
    case videoSeconds(Int)
    /// Kadraj yönü: dikey (tam sayfa) ya da yatay
    case frame(vertical: Bool)
    case orientation(ImageOrientation)
    /// Sesle konumlandırma
    case guidance(Bool)
    /// 0 kapalı, 1 hafif, 2 güçlü
    case enhancement(Int)
    /// Canlı önizleme açık mı
    case preview(Bool)
}

extension VoiceCommand {
    /// "N. sorunun cevabını tekrarla"
    var isRepeatNumber: Bool {
        if case .repeatNumber = self { return true }
        return false
    }

    /// Yanıtı anlık bilgi ya da ayar değişikliği gerektiren komutlar (ağ yoklaması, ses seviyesi okuması…): yanıt söylenmeden önce hazırlanır
    var isLive: Bool {
        switch self {
        case .report, .volume, .camera: return true
        default: return false
        }
    }
}

/// Rapor ve ayar komutlarının çözümü. Bilgi komutları gibi (bkz. `parseInfo`) metnin TAMAMI bu sözcüklerden oluşmalıdır: soru metni komut sayılmaz.
/// Rapor komutlarında sözcüklerin yanında bir "rapor / durum / kaç / nasıl / var mı" sözcüğü de aranır ("ses seviyesi" tek başına soru başı olabilir).
extension VoiceCommand {
    // MARK: Ortak sözlükler

    /// Her komutta serbestçe geçebilen nezaket ve dolgu sözcükleri
    static let settingPolite: Set<String> = [
        "lutfen", "bana", "bir", "misin", "misiniz", "musun", "musunuz", "mi", "mu", "ya", "hadi", "simdi", "su", "bu", "ver", "verin", "et", "edin", "biraz"
    ]
    /// Ayar komutlarındaki dolgu fiiller: "yap", "olsun", "ayarla"
    static let settingFiller: Set<String> = ["yap", "yapin", "olsun", "ayarla", "ayarlayin", "al", "alin", "getir", "getirin", "cek", "cekin", "kaydet", "kaydedin"]
    static let onWords: Set<String> = [
        "ac", "acin", "acik", "acilsin", "etkinlestir", "etkinlestirin", "gonder", "gonderin", "gonderilsin", "kullan", "kullanin", "baslat"
    ]
    static let offWords: Set<String> = [
        "kapat", "kapatin", "kapali", "kapansin", "devre", "disi", "birak", "birakin", "gonderme", "gondermeyin", "kullanma", "kullanmayin", "iptal"
    ]

    // MARK: Raporlar

    static let reportWords: Set<String> = [
        "rapor", "raporu", "raporunu", "durum", "durumu", "durumunu", "bilgi", "bilgisi", "bilgisini", "kontrol", "kontrolu", "ayar", "ayari", "ayarlari", "ayarlarini", "ayarlar", "durumda", "seviye", "seviyesi", "seviyesini"
    ]
    /// Ölçü / durum soran sözcükler. "ne / nedir" burada YOK: "Bellek nedir", "Isı nedir" gibi sınav sorusu başlıkları rapor komutu sayılmasın
    static let reportAsk: Set<String> = [
        "nasil", "nasildir", "kac", "kacdir", "kactir", "var", "yeterli", "iyi", "calisiyor", "bagli", "hazir", "kadar", "yuzde",
        "soyle", "soyler", "soyleyin", "oku", "okur", "okuyun", "anlat", "anlatin", "bildir", "bildirin", "ogren"
    ]
    /// Yalnız bir rapor sözcüğüyle birlikte kabul edilir ("ram ne durumda", "durum nedir")
    static let reportWhat: Set<String> = ["ne", "nedir", "neler"]
    static let deviceWords: Set<String> = ["telefon", "telefonun", "telefonum", "telefonumun", "cihaz", "cihazin"]
    static let internetNouns: Set<String> = ["internet", "interneti", "internetin", "internetim", "baglanti", "baglantisi", "baglantiyi", "baglantinin", "wifi"]
    static let microphoneNouns: Set<String> = ["mikrofon", "mikrofonu", "mikrofonun", "mikrofonum", "mikrofonumu", "mikrofonumuz"]
    static let headphoneNouns: Set<String> = ["kulaklik", "kulakligi", "kulakligin", "kulakligim", "kulakligimi", "bluetooth"]
    static let soundNouns: Set<String> = ["ses", "sesi", "sesin", "sesim", "seviye", "seviyesi", "seviyesini"]
    static let cameraNouns: Set<String> = ["kamera", "kamerayi", "kameranin", "kameram", "goruntu", "goruntuyu", "goruntunun", "goruntusu"]
    static let batteryNouns: Set<String> = ["sarj", "sarji", "sarjim", "sarjimi", "sarjin", "pil", "pili", "pilim", "pilimi", "pilin", "batarya", "bataryayi", "bataryasi", "bataryam"]
    static let thermalNouns: Set<String> = ["isi", "isisi", "isinma", "isinmasi", "sicaklik", "sicakligi", "sicakligini"]
    /// "Telefon ısındı mı": kendi başına soru biçimli sözcükler
    static let thermalAsk: Set<String> = ["isindi", "isiniyor", "isinmis", "sicak", "sicakmi"]
    static let memoryNouns: Set<String> = [
        "ram", "rami", "ramin", "ramim", "bellek", "bellegi", "bellegim", "hafiza", "hafizasi", "hafizayi", "hafizam", "depolama", "depolamasi", "depolamayi", "disk", "diski"
    ]
    static let generalWords: Set<String> = [
        "genel", "sistem", "sistemin", "tum", "tumu", "tumunu", "butun", "butunu", "hepsi", "hepsini", "kisa", "ozet",
        "rapor", "raporu", "raporunu", "raporlar", "raporlari", "raporlarini", "telefon", "telefonun"
    ]
    static let reportNounWords: Set<String> = ["rapor", "raporu", "raporunu", "raporlar", "raporlari", "raporlarini"]
    static let generalVerbs: Set<String> = [
        "soyle", "soyler", "soyleyin", "oku", "okur", "okuyun", "anlat", "anlatin", "bildir", "bildirin", "istiyorum", "isterim"
    ]
    /// "Beni duyuyor musun": mikrofon raporu
    static let hearWords: Set<String> = ["beni", "duyuyor", "duyabiliyor", "duyuyorsun", "duyuyorsunuz", "duyabiliyorsun"]

    /// Rapor, ses seviyesi ve kamera ayarı komutları (sırası önemli değildir: üç söz dağarcığı birbirinden ayrıdır)
    static func parseSetting(_ raw: [String]) -> VoiceCommand? {
        // Tanıyıcı "RAM'i", "Wi-Fi", "interneti" gibi sözcüklerde kesme işareti ya da tire yazabilir: sözcük içindeki işaretler atılır ("ram'i" → "rami")
        let all = raw.map { $0.filter { $0 != "'" && $0 != "’" && $0 != "-" } }.filter { !$0.isEmpty }
        return parseReport(all) ?? parseVolume(all) ?? parseCameraSetting(all)
    }

    private static func settingKnown(_ words: [String], _ vocabularies: [Set<String>]) -> Bool {
        return words.allSatisfy { word in vocabularies.contains { SpokenWords.matches(word, $0) } }
    }

    private static func settingHas(_ words: [String], _ vocabulary: Set<String>) -> Bool {
        return words.contains { SpokenWords.matches($0, vocabulary) }
    }

    /// "İnternet raporu", "mikrofon çalışıyor mu", "kulaklık bağlı mı", "ses seviyesi kaç", "kamera durumu", "şarj kaç", "telefon ısındı mı",
    /// "ram durumu", "genel rapor". Her tür için sözcüklerin yalnız o türün sözlüğünden olması ve bir rapor/soru sözcüğü bulunması gerekir.
    static func parseReport(_ all: [String]) -> VoiceCommand? {
        guard !all.isEmpty, all.count <= 7 else { return nil }
        let words = all.filter { !SpokenWords.exactly($0, settingPolite) }
        guard !words.isEmpty else { return nil }
        let asks = settingHas(words, reportWords) || settingHas(words, reportAsk)
        let kinds: [(ReportKind, Set<String>)] = [
            (.internet, internetNouns), (.microphone, microphoneNouns), (.headphones, headphoneNouns), (.battery, batteryNouns),
            (.thermal, thermalNouns), (.memory, memoryNouns), (.camera, cameraNouns), (.sound, soundNouns)
        ]
        for (kind, nouns) in kinds {
            guard settingKnown(words, [nouns, reportWords, reportAsk, reportWhat, deviceWords]), settingHas(words, nouns), asks else { continue }
            return .report(kind)
        }
        // "Telefon ısındı mı", "ısındı mı": soru biçimli sözcük kendi başına soru sayılır
        if settingKnown(words, [thermalAsk, deviceWords, reportAsk]), settingHas(words, thermalAsk) { return .report(.thermal) }
        // "Beni duyuyor musun": mikrofon
        if settingKnown(words, [hearWords]), words.count >= 2, settingHas(words, ["beni"]) { return .report(.microphone) }
        // "Genel rapor", "tüm raporları söyle", "rapor ver", "sistem raporu"
        if all.count >= 2, settingKnown(words, [generalWords, generalVerbs]), settingHas(words, reportNounWords) { return .report(.general) }
        return nil
    }

    // MARK: Ses seviyesi

    static let volumeNouns: Set<String> = ["ses", "sesi", "sesin", "sesim", "sesimi", "seviye", "seviyesi", "seviyesini", "seviyeyi"]
    static let volumeUp: Set<String> = ["ac", "acin", "artir", "artirin", "arttir", "arttirin", "yukselt", "yukseltin", "artsin", "yukselsin"]
    static let volumeDown: Set<String> = ["kis", "kisin", "kissin", "azalt", "azaltin", "azalsin", "dusur", "dusurun", "alcalt", "alcaltin"]
    static let volumeSetVerbs: Set<String> = ["yap", "yapin", "olsun", "ayarla", "ayarlayin", "al", "alin", "getir", "getirin"]
    static let volumeMaxWords: Set<String> = ["sonuna", "tamamen", "maksimum", "maximum"]
    static let volumeExtras: Set<String> = ["kadar", "daha", "cok", "epey", "azicik", "birazcik"]
    static let percentWords: Set<String> = ["yuzde"]

    /// "Sesi aç", "sesi kıs", "sesi yüzde elli yap", "ses seviyesini 70 yap", "sesi sonuna kadar aç"
    static func parseVolume(_ all: [String]) -> VoiceCommand? {
        guard all.count >= 2, all.count <= 8 else { return nil }
        let words = all.filter { !SpokenWords.exactly($0, settingPolite) }
        guard settingHas(words, volumeNouns) else { return nil }
        var up = false, down = false, setVerb = false, maxWord = false, percent = false
        var numberTokens: [String] = []
        for word in words {
            if SpokenWords.matches(word, volumeNouns) { continue }
            if SpokenWords.matches(word, volumeUp) {
                up = true
            } else if SpokenWords.matches(word, volumeDown) {
                down = true
            } else if SpokenWords.matches(word, volumeSetVerbs) {
                setVerb = true
            } else if SpokenWords.matches(word, volumeMaxWords) {
                maxWord = true
            } else if SpokenWords.matches(word, volumeExtras) {
                continue
            } else if SpokenWords.matches(word, percentWords) {
                percent = true
            } else {
                numberTokens.append(word)
            }
        }
        var number: Int?
        if !numberTokens.isEmpty {
            number = SpokenNumber.standalone(from: numberTokens.joined(separator: " "))
            if number == nil { return nil }   // tanınmayan sözcük: komut değil
        }
        if up && down { return nil }
        if let value = number {
            guard !up, !down, setVerb || percent else { return nil }
            return .volume(.set(value))
        }
        if maxWord, up || setVerb { return .volume(.set(100)) }
        if up { return .volume(.up) }
        if down { return .volume(.down) }
        return nil
    }

    // MARK: Kamera ayarları

    static let askNouns: Set<String> = ["soru", "sorusu", "sorusunu", "soruda", "sormayi"]
    static let askExtras: Set<String> = ["her"]
    static let askOffWords: Set<String> = ["sorma", "sormayin", "sormasin"]
    static let qualityNouns: Set<String> = ["kalite", "kalitesi", "kalitesini", "cozunurluk", "cozunurlugu", "cozunurlugunu"]
    static let qualityHigh: Set<String> = ["yuksek", "yuksege", "artir", "arttir", "yukselt"]
    static let qualityLow: Set<String> = ["dusuk", "dusuge", "dusur", "azalt"]
    static let videoNouns: Set<String> = ["video", "videoyu", "videonun", "videoda"]
    static let videoExtras: Set<String> = ["gemini", "geminiye", "de", "da", "birlikte"]
    static let secondWords: Set<String> = ["sure", "suresi", "suresini", "saniye", "saniyelik", "saniyeye", "sn"]
    static let frameNouns: Set<String> = ["kadraj", "kadraji", "kadrajin", "kadrajini", "kadrajda"]
    static let frameVertical: Set<String> = ["dikey", "dikeye"]
    static let frameHorizontal: Set<String> = ["yatay", "yataya"]
    static let orientationNouns: Set<String> = ["goruntu", "goruntuyu", "goruntunun", "goruntusu", "yon", "yonu", "yonunu"]
    static let orientationTurn: Set<String> = ["cevir", "cevirin", "dondur", "dondurun", "cevrilsin"]
    static let orientationRotate180: Set<String> = ["ters", "tersine", "yuzseksen", "180"]
    static let orientationRight: Set<String> = ["sag", "saga", "sagina"]
    static let orientationLeft: Set<String> = ["sol", "sola", "solu"]
    static let orientationNormal: Set<String> = ["normal", "duz"]
    static let guidanceNouns: Set<String> = ["konumlandirma", "konumlandirmayi", "konumlandirmasi", "yonlendirme", "yonlendirmeyi", "yonlendirmesi"]
    static let guidanceExtras: Set<String> = ["sesle", "sesli"]
    static let enhanceNouns: Set<String> = ["iyilestirme", "iyilestirmeyi", "iyilestirmesi"]
    static let enhanceLight: Set<String> = ["hafif", "hafifce"]
    static let enhanceStrong: Set<String> = ["guclu", "kuvvetli"]
    static let enhanceExtras: Set<String> = ["fotograf", "fotografi", "fotografin", "foto"]
    static let previewNouns: Set<String> = ["onizleme", "onizlemeyi", "onizlemesi", "onizlemenin"]
    static let previewExtras: Set<String> = ["canli"]

    /// Açma/kapama yönü: yalnız biri varsa değeri, ikisi de ya da hiçbiri yoksa nil
    private static func direction(_ words: [String], extraOff: Set<String> = []) -> Bool? {
        let on = settingHas(words, onWords)
        let off = settingHas(words, offWords) || (!extraOff.isEmpty && settingHas(words, extraOff))
        if on == off { return nil }
        return on
    }

    /// "Kamera sorusunu kapat", "görüntü kalitesini yüksek yap", "videoyu gönderme", "video süresini sekiz saniye yap", "kadrajı dikey yap",
    /// "görüntüyü ters çevir", "sesle konumlandırmayı aç", "iyileştirmeyi hafif yap", "önizlemeyi kapat"
    static func parseCameraSetting(_ all: [String]) -> VoiceCommand? {
        guard all.count >= 2, all.count <= 8 else { return nil }
        let words = all.filter { !SpokenWords.exactly($0, settingPolite) }
        guard words.count >= 2 else { return nil }
        let filler = settingFiller

        // Her soruda kamera sorusu: "kamera" ve "soru" birlikte (tek başına "kamerayı kapat" bu soruya verilen hayır olabilir)
        if settingKnown(words, [["kamera", "kamerayi", "kamerayla", "kameranin"], askNouns, askExtras, askOffWords, onWords, offWords, filler]),
           settingHas(words, ["kamera", "kamerayi", "kamerayla", "kameranin"]), settingHas(words, askNouns) || settingHas(words, askOffWords) {
            if let on = direction(words, extraOff: askOffWords) { return .camera(.askQuestion(on)) }
            return nil
        }
        // Video süresi: "video süresini beş saniye yap"
        if settingHas(words, videoNouns), settingHas(words, secondWords) {
            var numberTokens: [String] = []
            for word in words {
                if SpokenWords.matches(word, videoNouns) || SpokenWords.matches(word, secondWords) || SpokenWords.matches(word, filler) { continue }
                numberTokens.append(word)
            }
            guard !numberTokens.isEmpty, let seconds = SpokenNumber.standalone(from: numberTokens.joined(separator: " ")) else { return nil }
            return .camera(.videoSeconds(seconds))
        }
        // Videoyu Gemini'ye gönder / gönderme
        if settingKnown(words, [videoNouns, videoExtras, onWords, offWords, filler]), settingHas(words, videoNouns) {
            if let on = direction(words) { return .camera(.sendVideo(on)) }
            return nil
        }
        // Görüntü kalitesi
        if settingKnown(words, [qualityNouns, cameraNouns, qualityHigh, qualityLow, filler]), settingHas(words, qualityNouns) {
            let high = settingHas(words, qualityHigh), low = settingHas(words, qualityLow)
            if high != low { return .camera(.quality(high: high)) }
            return nil
        }
        // Kadraj yönü
        if settingKnown(words, [frameNouns, frameVertical, frameHorizontal, filler]), settingHas(words, frameNouns) {
            let vertical = settingHas(words, frameVertical), horizontal = settingHas(words, frameHorizontal)
            if vertical != horizontal { return .camera(.frame(vertical: vertical)) }
            return nil
        }
        // Görüntü yönü
        if settingKnown(words, [orientationNouns, orientationTurn, orientationRotate180, orientationRight, orientationLeft, orientationNormal, filler]),
           settingHas(words, orientationNouns) {
            var choices: [ImageOrientation] = []
            if settingHas(words, orientationRotate180) { choices.append(.rotate180) }
            if settingHas(words, orientationRight) { choices.append(.right90) }
            if settingHas(words, orientationLeft) { choices.append(.left90) }
            if settingHas(words, orientationNormal) { choices.append(.normal) }
            if choices.count == 1, let only = choices.first { return .camera(.orientation(only)) }
            return nil
        }
        // Sesle konumlandırma
        if settingKnown(words, [guidanceNouns, guidanceExtras, onWords, offWords, filler]), settingHas(words, guidanceNouns) {
            if let on = direction(words) { return .camera(.guidance(on)) }
            return nil
        }
        // Fotoğraf iyileştirme: kapat / hafif / güçlü
        if settingKnown(words, [enhanceNouns, enhanceExtras, enhanceLight, enhanceStrong, onWords, offWords, filler]), settingHas(words, enhanceNouns) {
            let light = settingHas(words, enhanceLight), strong = settingHas(words, enhanceStrong)
            let on = settingHas(words, onWords), off = settingHas(words, offWords)
            if off, !light, !strong, !on { return .camera(.enhancement(0)) }
            if strong, !light, !off { return .camera(.enhancement(2)) }
            if light, !strong, !off { return .camera(.enhancement(1)) }
            if on, !light, !strong, !off { return .camera(.enhancement(1)) }
            return nil
        }
        // Canlı önizleme
        if settingKnown(words, [previewNouns, previewExtras, onWords, offWords, filler]), settingHas(words, previewNouns) {
            if let on = direction(words) { return .camera(.preview(on)) }
            return nil
        }
        return nil
    }
}
