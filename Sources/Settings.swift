import Foundation

/// Kullanıcı ayarları. Hepsi telefonda saklanır. Kamera adı (UID) ilk açılışta hazır gelir; Ayarlar'dan silinip başkası yazılabilir.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let d = UserDefaults.standard

    // MARK: Kamera
    /// İlk açılışta Ayarlar'da hazır yazılı gelen kamera adı (UID); kullanıcı silip yenisini yazarsa onun seçimi kalır
    static let defaultCameraUID = "G526029XJPDT"
    @Published var uid: String { didSet { d.set(uid, forKey: "uid") } }
    @Published var cameraIP: String { didSet { d.set(cameraIP, forKey: "cameraIP") } }
    @Published var cameraPassword: String { didSet { Keychain.set(cameraPassword, for: "cameraPassword") } }
    /// 1 = Yüksek (1920x1080), 2 = Düşük (640x360)
    @Published var streamQuality: Int { didSet { d.set(streamQuality, forKey: "streamQuality") } }

    // MARK: Ses
    @Published var voiceEnabled: Bool { didSet { d.set(voiceEnabled, forKey: "voiceEnabled") } }
    @Published var triggerWord: String { didSet { d.set(triggerWord, forKey: "triggerWord") } }
    @Published var cooldown: Double { didSet { d.set(cooldown, forKey: "cooldown") } }

    // MARK: Fotoğraf
    @Published var jpegQuality: Double { didSet { d.set(jpegQuality, forKey: "jpegQuality") } }
    /// 0 = kapalı, 1 = hafif, 2 = güçlü
    @Published var enhancement: Int { didSet { d.set(enhancement, forKey: "enhancement") } }
    @Published var deskew: Bool { didSet { d.set(deskew, forKey: "deskew") } }
    /// 1.0, 1.5 veya 2.0
    @Published var upscale: Double { didSet { d.set(upscale, forKey: "upscale") } }
    /// Kameranın görüntüye işlediği tarih/saat: bulanıklaştır (varsayılan), kes ya da olduğu gibi bırak
    @Published var timestampMode: TimestampMode { didSet { d.set(timestampMode.rawValue, forKey: "timestampMode") } }
    @Published var multiFrame: Bool { didSet { d.set(multiFrame, forKey: "multiFrame") } }
    /// Yalnız belge (kâğıt + yazı) görünüyorsa fotoğraf çek; el, yüz, boş masa gibi görüntüler çekilmez
    @Published var documentOnly: Bool { didSet { d.set(documentOnly, forKey: "documentOnly") } }
    /// Seri çekimde tetiklemeden önceki / sonraki pencere (saniye)
    @Published var burstBefore: Double { didSet { d.set(burstBefore, forKey: "burstBefore") } }
    @Published var burstAfter: Double { didSet { d.set(burstAfter, forKey: "burstAfter") } }

    // MARK: Otomatik çekim (görüntü değişince)
    @Published var motionEnabled: Bool { didSet { d.set(motionEnabled, forKey: "motionEnabled") } }
    /// 0 = düşük, 1 = orta, 2 = yüksek duyarlılık
    @Published var motionSensitivity: Int { didSet { d.set(motionSensitivity, forKey: "motionSensitivity") } }

    // MARK: Pil tasarrufu
    /// Canlı önizleme kapalı: ekrana video çizilmez, kare çözme/çekim/ses/kaydetme aynen sürer (varsayılan: önizleme açık)
    @Published var previewOff: Bool { didSet { d.set(previewOff, forKey: "previewOff") } }
    /// Program çalışırken ekran parlaklığını çok azalt (ekran pilin en büyük tüketicisidir); önizlemeden bağımsız
    @Published var dimScreen: Bool { didSet { d.set(dimScreen, forKey: "dimScreen") } }

    // MARK: Okuma sesi
    /// Seçilen konuşma sesi (boş = telefonda kurulu en kaliteli Türkçe ses)
    @Published var speechVoiceID: String { didSet { d.set(speechVoiceID, forKey: "speechVoiceID") } }
    /// Okuma hızı çarpanı: 1 = varsayılan hız
    @Published var speechRate: Double { didSet { d.set(speechRate, forKey: "speechRate") } }

    // MARK: Sesli konumlandırma
    /// Kamera sayfayı/sütunu ölçer; sesle "biraz sağa, uzaklaş…" der, uygun olunca kendisi çeker
    @Published var guidanceEnabled: Bool { didSet { d.set(guidanceEnabled, forKey: "guidanceEnabled") } }
    /// Uyarıları sesli söyle (kapalıysa yalnız ekranda yazar)
    @Published var guidanceVoice: Bool { didSet { d.set(guidanceVoice, forKey: "guidanceVoice") } }
    /// Sesli konumlandırma açıkken kamera / gönderim durumunu da sesle haber ver (kamera koptu, dosya gönderildi…)
    @Published var statusNotices: Bool { didSet { d.set(statusNotices, forKey: "statusNotices") } }
    /// Konum uygun olunca kendiliğinden çek (kapalıysa "okey" demenizi bekler)
    @Published var guidanceAutoCapture: Bool { didSet { d.set(guidanceAutoCapture, forKey: "guidanceAutoCapture") } }
    /// Görüntü yönü: önizleme, fotoğraf/PDF, video ve sesli yönlendirme bu yöne göre çevrilir
    @Published var imageOrientation: ImageOrientation { didSet { d.set(imageOrientation.rawValue, forKey: "imageOrientation") } }
    /// Yönlendirmenin hedef kadrajı: 1 = dikey tam sayfa (varsayılan), 0 = bütün kare
    @Published var guidanceFrame: Int {
        didSet {
            d.set(guidanceFrame, forKey: "guidanceFrame")
            // Kadraj yönü değişince görüntü yönü ona uydurulur (Dikey: 90° sağa / sola, Yatay: normal / 180°)
            let fixed = AppSettings.orientation(imageOrientation, forFrame: guidanceFrame)
            if fixed != imageOrientation { imageOrientation = fixed }
        }
    }
    /// 0 = gevşek, 1 = normal, 2 = sıkı netlik isteği
    @Published var guidanceSharpness: Int { didSet { d.set(guidanceSharpness, forKey: "guidanceSharpness") } }
    /// Sayfada parlama lekesi varsa uyar (birkaç uyarıdan sonra yine de çeker)
    @Published var guidanceGlare: Bool { didSet { d.set(guidanceGlare, forKey: "guidanceGlare") } }
    /// Bekleyen fotoğrafları tek PDF olarak gönderen sözcük (virgülle birden çok); hazır söylenişler de geçerlidir
    @Published var finishWord: String { didSet { d.set(finishWord, forKey: "finishWord") } }

    // MARK: Gemini (belgelerle sesli sohbet)
    /// "Gemini" deyince / düğmeyle sesli soru sorulabilsin
    @Published var geminiEnabled: Bool { didSet { d.set(geminiEnabled, forKey: "geminiEnabled") } }
    /// Google AI Studio API anahtarı (yalnız Keychain'de saklanır)
    /// Model profilleri (ad, model, ücretsiz mi); anahtarlar `geminiKeys` içinde, Keychain'de
    @Published var geminiProfiles: [GeminiProfile] {
        didSet { d.set(try? JSONEncoder().encode(geminiProfiles), forKey: "geminiProfiles") }
    }
    /// Profillerin API anahtarları (Keychain: geminiApiKey … geminiApiKey6); yalnız bu telefonda
    @Published var geminiKeys: [String] {
        didSet {
            for (i, key) in geminiKeys.enumerated() {
                Keychain.set(key.trimmed, for: GeminiProfiles.keychainName(slot: i + 1))
            }
        }
    }
    /// Kullanılan profil (1-6)
    @Published var geminiActive: Int { didSet { d.set(geminiActive, forKey: "geminiActive") } }
    /// Aylık harcama sınırı dolunca "ücretsiz" işaretli profile geç
    @Published var geminiAutoFallback: Bool { didSet { d.set(geminiAutoFallback, forKey: "geminiAutoFallback") } }
    /// Seçili model yoğunken (503) ya da kotası dolunca (429) aynı anahtarla hesabın başka bir hızlı modeline geç
    @Published var geminiOverloadFallback: Bool { didSet { d.set(geminiOverloadFallback, forKey: "geminiOverloadFallback") } }
    /// Model zinciri: kota dolunca / hata olunca / cevap gecikince aynı soru sıradaki profilin modeline kendiliğinden gider (sesli bilgiyle)
    @Published var geminiChainFallback: Bool { didSet { d.set(geminiChainFallback, forKey: "geminiChainFallback") } }
    /// Bir model bu kadar saniyede cevap vermezse sıradaki modele geçilir (0-600; 0 = sınırsız). Son modele sınır konmaz.
    @Published var geminiWaitLimit: Int { didSet { d.set(geminiWaitLimit, forKey: "geminiWaitLimit") } }
    /// Video kaydı bitince video Gemini'ye de gönderilir ("Bu videoda ne oluyor?"); cevap sesle okunur
    @Published var videoToGemini: Bool { didSet { d.set(videoToGemini, forKey: "videoToGemini") } }
    /// Videoların Gemini'ye ne zaman gideceği: 1 = "videoları gönder" deyince, sırayla tek tek (varsayılan); 0 = her video bitince hemen
    @Published var videoSendMode: Int { didSet { d.set(videoSendMode, forKey: "videoSendMode") } }
    /// Video sorusu (boşsa varsayılan talimat: videodaki yazıları oku, soruları çöz)
    @Published var videoQuestion: String { didSet { d.set(videoQuestion, forKey: "videoQuestion") } }
    /// Videoyu yüksek çözünürlükle oku (küçük yazı için; kare başına token ≈ 4 kat). Varsayılan açık.
    @Published var videoHighRes: Bool { didSet { d.set(videoHighRes, forKey: "videoHighRes") } }
    /// Harcama sınırı yüzünden yedeğe geçilen ay ("202611"); yeni ayda eski profile dönülür
    @Published var geminiCapMonth: String { didSet { d.set(geminiCapMonth, forKey: "geminiCapMonth") } }
    /// Yedeğe geçmeden önceki profil
    @Published var geminiCapPrev: Int { didSet { d.set(geminiCapPrev, forKey: "geminiCapPrev") } }
    /// Oturumda bu kadar saniye konuşulmazsa oturum kapanır; 0 = hiç kapanmaz (varsayılan)
    @Published var geminiSessionTimeout: Int { didSet { d.set(geminiSessionTimeout, forKey: "geminiSessionTimeout") } }
    /// Oturum: çağrı sözcüğüyle "N belge hazır" der, her cevaptan sonra yeni soruyu kendiliğinden dinler
    @Published var geminiSession: Bool { didSet { d.set(geminiSession, forKey: "geminiSession") } }
    /// Gemini'yi çağıran sözcük(ler), virgülle ("dostum, gemini"); boşsa "dinle" ve "gemini"
    @Published var geminiCallWord: String { didSet { d.set(geminiCallWord, forKey: "geminiCallWord") } }
    /// Düşünme modu: "auto" (Gemma modellerinde açık, Gemini'de modelin kendi varsayılanı) | "high" | "minimal"
    @Published var geminiThinking: String { didSet { d.set(geminiThinking, forKey: "geminiThinking") } }
    /// "Dinle" kaydını ne bitirir: "word" ("tamam" deyince; sessizlik de bitirir) | "silence" (konuşma bitince)
    @Published var listenEnd: String { didSet { d.set(listenEnd, forKey: "listenEnd") } }
    /// "Tamam" modunda konuşmadan sonra bu kadar saniye sessizlik olursa kayıt kendiliğinden biter (5-60)
    @Published var listenSilence: Int { didSet { d.set(listenSilence, forKey: "listenSilence") } }
    /// Belgelerin ve ses kaydının Google'a gönderileceğinin onayı (onay olmadan soru sorulmaz)
    @Published var geminiPrivacyOK: Bool { didSet { d.set(geminiPrivacyOK, forKey: "geminiPrivacyOK") } }
    /// Gemini'ye gönderilecek en yeni PDF sayısı
    @Published var geminiDocCount: Int { didSet { d.set(geminiDocCount, forKey: "geminiDocCount") } }
    /// Büyük belge setlerini Gemini'ye bir kez yükle (Files API) ve oturumda önbelleğe al
    @Published var geminiMemory: Bool { didSet { d.set(geminiMemory, forKey: "geminiMemory") } }
    /// Şık harfi yerine sesli okunan kod sözcükleri ("A=ADANA, B=BURSA…"); boş = harfin kendisi okunur
    @Published var geminiOptionCodes: String { didSet { d.set(geminiOptionCodes, forKey: "geminiOptionCodes") } }
    /// Toplu cevapta (10'arlı gruplar) kullanıcıya ulaşan son soru numarası; kalıcıdır, "ilk on soru" deyince yeniden başlar
    @Published var geminiBatchLast: Int { didSet { d.set(geminiBatchLast, forKey: "geminiBatchLast") } }

    // MARK: Deneme sınavı
    /// Cevaplar bu kadarlık gruplar halinde okunur (3-20)
    /// Gemini'den bir seferde en çok bu kadar sorunun cevabı istenir (5-40)
    /// "Tarama tamamlandı"dan sonra gönderimden önce vazgeçme süresi, sn (0-15)
    @Published var examCancelWindow: Int { didSet { d.set(examCancelWindow, forKey: "examCancelWindow") } }
    /// Cevap grupları arasındaki duraklama, sn (0-10); bu sürede "duraklat" denebilir
    @Published var examGap: Int { didSet { d.set(examGap, forKey: "examGap") } }
    /// Deneme sınavı önce video çeker (evrak görününce başlar, en çok 30 sn); kapalıysa sınav doğrudan fotoğraf taramasıyla başlar
    @Published var examVideoFirst: Bool { didSet { d.set(examVideoFirst, forKey: "examVideoFirst") } }
    /// Sınav açılırken ses, mikrofon, internet ve Gemini sınanır
    @Published var examSelfCheck: Bool { didSet { d.set(examSelfCheck, forKey: "examSelfCheck") } }
    /// Bağlantı kestirmesinin adı (Kestirmeler uygulamasındaki kestirme: hücresel veriyi kapat-aç). İnternet gidince çalışır; boşsa kapalı
    @Published var connectionShortcutName: String { didSet { d.set(connectionShortcutName, forKey: "connectionShortcutName") } }
    /// Ses kestirmesinin adı (Bluetooth'u kapat-aç). Mikrofon uzun süre sessiz kalınca ya da ses mikrofon alıcısına gidince çalışır; boşsa kapalı
    @Published var audioShortcutName: String { didSet { d.set(audioShortcutName, forKey: "audioShortcutName") } }

    // MARK: Kaydetme (belge klasörü)
    /// "single": her fotoğraf hemen gider · "batch": biriksin, toplu gitsin
    @Published var sendMode: String { didSet { d.set(sendMode, forKey: "sendMode") } }
    /// Toplu modda bu kadar fotoğraf birikince gönder (0 = yalnızca düğmeyle)
    @Published var batchSize: Int { didSet { d.set(batchSize, forKey: "batchSize") } }
    /// Toplu modda son çekimden bu kadar saniye sonra gönder (0 = kapalı)
    @Published var batchIdle: Int { didSet { d.set(batchIdle, forKey: "batchIdle") } }
    /// Klasöre kaydedilen dosya türü: "pdf" ya da "jpeg"
    @Published var uploadFormat: String { didSet { d.set(uploadFormat, forKey: "uploadFormat") } }

    init() {
        uid = d.string(forKey: "uid") ?? AppSettings.defaultCameraUID
        cameraIP = d.string(forKey: "cameraIP") ?? ""
        cameraPassword = Keychain.get("cameraPassword") ?? "123456"
        streamQuality = d.object(forKey: "streamQuality") as? Int ?? 1

        voiceEnabled = d.object(forKey: "voiceEnabled") as? Bool ?? true
        triggerWord = d.string(forKey: "triggerWord") ?? "okey"
        cooldown = d.object(forKey: "cooldown") as? Double ?? 4.0

        jpegQuality = d.object(forKey: "jpegQuality") as? Double ?? 0.92
        enhancement = d.object(forKey: "enhancement") as? Int ?? 1
        deskew = d.object(forKey: "deskew") as? Bool ?? false
        upscale = d.object(forKey: "upscale") as? Double ?? 1.0
        if let raw = d.string(forKey: "timestampMode"), let mode = TimestampMode(rawValue: raw) {
            timestampMode = mode
        } else if d.bool(forKey: "cropTimestamp") {
            timestampMode = .crop          // eski sürümdeki "saat yazısını kes" ayarı
        } else {
            timestampMode = .blur
        }
        multiFrame = d.object(forKey: "multiFrame") as? Bool ?? true
        documentOnly = d.object(forKey: "documentOnly") as? Bool ?? true
        burstBefore = d.object(forKey: "burstBefore") as? Double ?? 0.4
        burstAfter = d.object(forKey: "burstAfter") as? Double ?? 0.8

        motionEnabled = d.object(forKey: "motionEnabled") as? Bool ?? false
        motionSensitivity = d.object(forKey: "motionSensitivity") as? Int ?? 1

        AppSettings.removeOldGoogleData(d)
        sendMode = d.string(forKey: "sendMode") ?? "single"
        batchSize = d.object(forKey: "batchSize") as? Int ?? 10
        batchIdle = d.object(forKey: "batchIdle") as? Int ?? 0
        uploadFormat = d.string(forKey: "uploadFormat") ?? "pdf"
        guidanceEnabled = d.object(forKey: "guidanceEnabled") as? Bool ?? false
        guidanceVoice = d.object(forKey: "guidanceVoice") as? Bool ?? true
        speechVoiceID = d.string(forKey: "speechVoiceID") ?? ""
        speechRate = d.object(forKey: "speechRate") as? Double ?? 1.0
        statusNotices = d.object(forKey: "statusNotices") as? Bool ?? true
        guidanceAutoCapture = d.object(forKey: "guidanceAutoCapture") as? Bool ?? true
        // Kadraj yönü ile görüntü yönü uyumlu olmalı (bkz. orientation(_:forFrame:))
        let frameValue = d.object(forKey: "guidanceFrame") as? Int ?? 1
        let orient = AppSettings.orientation(AppSettings.migratedOrientation(d), forFrame: frameValue)
        d.set(orient.rawValue, forKey: "imageOrientation")
        imageOrientation = orient
        guidanceFrame = frameValue
        guidanceSharpness = d.object(forKey: "guidanceSharpness") as? Int ?? 1
        guidanceGlare = d.object(forKey: "guidanceGlare") as? Bool ?? true
        finishWord = d.string(forKey: "finishWord") ?? "hepsi tamamlandı"
        geminiEnabled = d.object(forKey: "geminiEnabled") as? Bool ?? false
        geminiKeys = (1...GeminiProfiles.slotCount).map { Keychain.get(GeminiProfiles.keychainName(slot: $0)) ?? "" }
        if let data = d.data(forKey: "geminiProfiles"), let saved = try? JSONDecoder().decode([GeminiProfile].self, from: data),
           saved.count >= 3 && saved.count <= GeminiProfiles.slotCount {
            // Boş kalmış profil modelleri varsayılanla dolar (anahtar girilene kadar etkisiz); kullanıcının yazdıkları korunur
            geminiProfiles = GeminiProfiles.migrated(saved)
        } else {
            // Eski sürümden: tek model ayarı 1. profil olur
            var list = GeminiProfiles.defaults()
            if let old = d.string(forKey: "geminiModel"), !old.trimmed.isEmpty { list[0].model = old.trimmed }
            geminiProfiles = list
        }
        geminiActive = min(max(d.object(forKey: "geminiActive") as? Int ?? 1, 1), GeminiProfiles.slotCount)
        geminiChainFallback = d.object(forKey: "geminiChainFallback") as? Bool ?? true
        geminiWaitLimit = min(max(d.object(forKey: "geminiWaitLimit") as? Int ?? 30, 0), 600)
        geminiAutoFallback = d.object(forKey: "geminiAutoFallback") as? Bool ?? true
        videoToGemini = d.object(forKey: "videoToGemini") as? Bool ?? true
        videoSendMode = d.object(forKey: "videoSendMode") as? Int == 0 ? 0 : 1
        videoQuestion = d.string(forKey: "videoQuestion") ?? ""
        videoHighRes = d.object(forKey: "videoHighRes") as? Bool ?? true
        geminiOverloadFallback = d.object(forKey: "geminiOverloadFallback") as? Bool ?? true
        geminiCapMonth = d.string(forKey: "geminiCapMonth") ?? ""
        geminiCapPrev = min(max(d.object(forKey: "geminiCapPrev") as? Int ?? 1, 1), GeminiProfiles.slotCount)
        geminiSessionTimeout = min(max(d.object(forKey: "geminiSessionTimeout") as? Int ?? 0, 0), 86400)
        geminiSession = d.object(forKey: "geminiSession") as? Bool ?? true
        // Eski varsayılan ("gemini") "dinle, gemini"ye yükselir; kullanıcının kendi yazdığı sözcükler korunur
        let savedCall = d.string(forKey: "geminiCallWord")
        geminiCallWord = AppSettings.migratedCallWord(savedCall)
        geminiThinking = AppSettings.validThinking(d.string(forKey: "geminiThinking"))
        listenEnd = (d.string(forKey: "listenEnd") == "silence") ? "silence" : "word"
        listenSilence = min(max(d.object(forKey: "listenSilence") as? Int ?? 15, 5), 60)
        // Kullanıcı kararı: gizlilik onayı varsayılan olarak işaretli gelir (her kurulumda yeniden işaretlemek zorunda kalınmasın)
        geminiPrivacyOK = d.object(forKey: "geminiPrivacyOK") as? Bool ?? true
        geminiDocCount = min(max(d.object(forKey: "geminiDocCount") as? Int ?? 3, 1), GeminiConfig.maxPages)
        geminiMemory = d.object(forKey: "geminiMemory") as? Bool ?? true
        let storedCodes = d.string(forKey: "geminiOptionCodes")
        if let stored = storedCodes, stored != GeminiConfig.previousDefaultOptionCodes {
            geminiOptionCodes = stored
        } else {
            geminiOptionCodes = GeminiConfig.defaultOptionCodes
        }
        geminiBatchLast = min(max(d.object(forKey: "geminiBatchLast") as? Int ?? 0, 0), 100000)
        examCancelWindow = min(max(d.object(forKey: "examCancelWindow") as? Int ?? 5, 0), 15)
        examGap = min(max(d.object(forKey: "examGap") as? Int ?? 3, 0), 10)
        examVideoFirst = d.object(forKey: "examVideoFirst") as? Bool ?? true
        examSelfCheck = d.object(forKey: "examSelfCheck") as? Bool ?? true
        connectionShortcutName = AppSettings.migratedConnectionShortcutName(d)
        audioShortcutName = d.string(forKey: "audioShortcutName") ?? ""
        previewOff = d.object(forKey: "previewOff") as? Bool ?? false
        dimScreen = d.object(forKey: "dimScreen") as? Bool ?? false
    }
}

extension AppSettings {
    /// Kayıtlı çağrı sözcüğü: yok → yeni varsayılan; eski varsayılan ("gemini") → "dinle, gemini"; başka bir şey → olduğu gibi
    static func migratedCallWord(_ saved: String?) -> String {
        guard let saved = saved else { return GeminiText.defaultCallSetting }
        if saved.trimmed.lowercased() == GeminiText.defaultCallWord { return GeminiText.defaultCallSetting }
        return saved
    }

    static func validThinking(_ value: String?) -> String {
        guard let v = value, ["auto", "high", "minimal"].contains(v) else { return "auto" }
        return v
    }

    /// Altı profil (anahtarlarıyla)
    func geminiProfileInfos() -> [GeminiProfileInfo] {
        return geminiProfiles.enumerated().map { i, p in
            GeminiProfileInfo(slot: i + 1, name: p.name.trimmed.isEmpty ? "Model \(i + 1)" : p.name.trimmed,
                              model: p.model.trimmed, key: i < geminiKeys.count ? geminiKeys[i].trimmed : "", free: p.free)
        }
    }

    /// Şu an kullanılan profil (seçili boşsa ilk dolu profil)
    var activeGeminiProfile: GeminiProfileInfo {
        return GeminiProfiles.active(geminiProfileInfos(), active: geminiActive)
    }

    /// Harcama sınırı yüzünden yedeğe geçilen ay bittiyse eski profile döner
    func refreshGeminiCapFallback(now: Date = Date()) {
        guard !geminiCapMonth.isEmpty, geminiCapMonth != GeminiProfiles.monthKey(now) else { return }
        if activeGeminiProfile.free { geminiActive = geminiCapPrev }
        geminiCapMonth = ""
    }

    /// Bağlantı kestirmesi adı: yeni anahtar varsa o; yoksa eski sürümde kutu açıktıysa eski ad, değilse boş (kapalı).
    /// Sonuç yeni anahtara yazılır, eski anahtarlar silinir.
    static func migratedConnectionShortcutName(_ d: UserDefaults) -> String {
        let name: String
        if let current = d.string(forKey: "connectionShortcutName") {
            name = current
        } else if d.object(forKey: "cellularShortcutOn") as? Bool == true {
            name = d.string(forKey: "cellularShortcutName") ?? "Hücresel Yenile"
        } else {
            name = ""
        }
        d.set(name, forKey: "connectionShortcutName")
        d.removeObject(forKey: "cellularShortcutOn")
        d.removeObject(forKey: "cellularShortcutName")
        return name
    }

    /// Dikey kadrajda (1) yatay kamera karesi dik çevrilir ki dikey kutuya kırpılmadan tam otursun: 90° sağa ya da sola.
    /// Yatay kadrajda (0) çevrilmez ya da 180° olur.
    static func orientation(_ o: ImageOrientation, forFrame frame: Int) -> ImageOrientation {
        if frame == 1 { return o.isQuarterTurn ? o : .right90 }
        return o.isQuarterTurn ? .normal : o
    }

    /// Kadraj yönüne göre seçilebilen görüntü yönleri
    static func orientations(forFrame frame: Int) -> [ImageOrientation] {
        return frame == 1 ? [.right90, .left90] : [.normal, .rotate180]
    }

    /// Görüntü yönü: yeni anahtar varsa o; yoksa eski "kamera ters takılı" kutusu açıksa 180°, değilse normal.
    /// Sonuç yeni anahtara yazılır, eski anahtar silinir.
    static func migratedOrientation(_ d: UserDefaults) -> ImageOrientation {
        let value: ImageOrientation
        if let raw = d.object(forKey: "imageOrientation") as? Int, let o = ImageOrientation(rawValue: raw) {
            value = o
        } else if d.object(forKey: "guidanceFlip") as? Bool == true {
            value = .rotate180
        } else {
            value = .normal
        }
        d.set(value.rawValue, forKey: "imageOrientation")
        d.removeObject(forKey: "guidanceFlip")
        return value
    }

    /// Eski sürümlerden kalan Google/Drive bilgilerini (jeton, istemci kimliği, klasör) siler
    static func removeOldGoogleData(_ d: UserDefaults) {
        for key in ["googleRefreshToken", "googleClientID", "googleClientSecret"] { Keychain.remove(key) }
        for key in ["googleEmail", "driveFolderName", "driveFolderID", "keepLocalCopies", "driveFolderResolvedName", "ocrEnabled", "ocrUseGemini",
                    "examGroup", "examFetch"] {
            d.removeObject(forKey: key)
        }
        // Sınav videosu artık Gemini'ye eklenmez: eski sürümlerin sakladığı kopyalar silinir
        if let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(at: base.appendingPathComponent("G526", isDirectory: true)
                .appendingPathComponent("SinavVideolari", isDirectory: true))
        }
    }
}
