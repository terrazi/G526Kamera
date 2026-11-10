import Foundation

/// Kullanıcı ayarları. Hepsi telefonda saklanır; kamera kimliği (UID) koda yazılmaz.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let d = UserDefaults.standard

    // MARK: Kamera
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
    /// Canlı önizleme kapalı: ekrana video çizilmez, kare çözme/çekim/ses/Drive aynen sürer (varsayılan: önizleme açık)
    @Published var previewOff: Bool { didSet { d.set(previewOff, forKey: "previewOff") } }
    /// Önizleme kapalıyken ekranı çok kıs (ekran pilin en büyük tüketicisidir)
    @Published var dimWhenPreviewOff: Bool { didSet { d.set(dimWhenPreviewOff, forKey: "dimWhenPreviewOff") } }

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
    /// Kamera ters takılıysa sağ/sol ve yukarı/aşağı yönleri çevrilir
    @Published var guidanceFlip: Bool { didSet { d.set(guidanceFlip, forKey: "guidanceFlip") } }
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
    /// Profillerin API anahtarları (Keychain: geminiApiKey, geminiApiKey2, geminiApiKey3); yalnız bu telefonda
    @Published var geminiKeys: [String] {
        didSet {
            for (i, key) in geminiKeys.enumerated() {
                Keychain.set(key.trimmed, for: GeminiProfiles.keychainName(slot: i + 1))
            }
        }
    }
    /// Kullanılan profil (1-3)
    @Published var geminiActive: Int { didSet { d.set(geminiActive, forKey: "geminiActive") } }
    /// Aylık harcama sınırı dolunca "ücretsiz" işaretli profile geç
    @Published var geminiAutoFallback: Bool { didSet { d.set(geminiAutoFallback, forKey: "geminiAutoFallback") } }
    /// Harcama sınırı yüzünden yedeğe geçilen ay ("202611"); yeni ayda eski profile dönülür
    @Published var geminiCapMonth: String { didSet { d.set(geminiCapMonth, forKey: "geminiCapMonth") } }
    /// Yedeğe geçmeden önceki profil
    @Published var geminiCapPrev: Int { didSet { d.set(geminiCapPrev, forKey: "geminiCapPrev") } }
    /// Oturumda bu kadar saniye konuşulmazsa oturum kapanır; 0 = hiç kapanmaz (varsayılan)
    @Published var geminiSessionTimeout: Int { didSet { d.set(geminiSessionTimeout, forKey: "geminiSessionTimeout") } }
    /// Oturum: çağrı sözcüğüyle "N belge hazır" der, her cevaptan sonra yeni soruyu kendiliğinden dinler
    @Published var geminiSession: Bool { didSet { d.set(geminiSession, forKey: "geminiSession") } }
    /// Gemini'yi çağıran sözcük(ler), virgülle ("dostum, gemini"); boşsa "gemini"
    @Published var geminiCallWord: String { didSet { d.set(geminiCallWord, forKey: "geminiCallWord") } }
    /// Belgelerin ve ses kaydının Google'a gönderileceğinin onayı (onay olmadan soru sorulmaz)
    @Published var geminiPrivacyOK: Bool { didSet { d.set(geminiPrivacyOK, forKey: "geminiPrivacyOK") } }
    /// Gemini'ye gönderilecek en yeni PDF sayısı
    @Published var geminiDocCount: Int { didSet { d.set(geminiDocCount, forKey: "geminiDocCount") } }

    // MARK: Drive
    @Published var driveFolderName: String { didSet { d.set(driveFolderName, forKey: "driveFolderName") } }
    @Published var driveFolderID: String { didSet { d.set(driveFolderID, forKey: "driveFolderID") } }
    @Published var googleClientID: String { didSet { Keychain.set(googleClientID, for: "googleClientID") } }
    @Published var googleClientSecret: String { didSet { Keychain.set(googleClientSecret, for: "googleClientSecret") } }
    @Published var keepLocalCopies: Bool { didSet { d.set(keepLocalCopies, forKey: "keepLocalCopies") } }
    /// "single": her fotoğraf hemen gider · "batch": biriksin, toplu gitsin
    @Published var sendMode: String { didSet { d.set(sendMode, forKey: "sendMode") } }
    /// Toplu modda bu kadar fotoğraf birikince gönder (0 = yalnızca düğmeyle)
    @Published var batchSize: Int { didSet { d.set(batchSize, forKey: "batchSize") } }
    /// Toplu modda son çekimden bu kadar saniye sonra gönder (0 = kapalı)
    @Published var batchIdle: Int { didSet { d.set(batchIdle, forKey: "batchIdle") } }
    /// Drive'a giden dosya türü: "pdf" ya da "jpeg" (telefondaki kopya her zaman JPEG)
    @Published var uploadFormat: String { didSet { d.set(uploadFormat, forKey: "uploadFormat") } }
    /// Fotoğraftaki yazıyı oku (OCR) ve PDF'in sonuna ayrı metin sayfaları olarak ekle (varsayılan kapalı)
    @Published var ocrEnabled: Bool { didSet { d.set(ocrEnabled, forKey: "ocrEnabled") } }
    /// OCR'ı Gemini yapsın (anahtar + gizlilik onayı varsa); yoksa cihazdaki Vision OCR'ı kullanılır
    @Published var ocrUseGemini: Bool { didSet { d.set(ocrUseGemini, forKey: "ocrUseGemini") } }

    init() {
        uid = d.string(forKey: "uid") ?? ""
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

        driveFolderName = d.string(forKey: "driveFolderName") ?? "G526 Belgeler"
        driveFolderID = d.string(forKey: "driveFolderID") ?? ""
        googleClientID = Keychain.get("googleClientID") ?? ""
        googleClientSecret = Keychain.get("googleClientSecret") ?? ""
        keepLocalCopies = d.object(forKey: "keepLocalCopies") as? Bool ?? true
        sendMode = d.string(forKey: "sendMode") ?? "single"
        batchSize = d.object(forKey: "batchSize") as? Int ?? 10
        batchIdle = d.object(forKey: "batchIdle") as? Int ?? 0
        uploadFormat = d.string(forKey: "uploadFormat") ?? "pdf"
        ocrEnabled = d.object(forKey: "ocrEnabled") as? Bool ?? false
        ocrUseGemini = d.object(forKey: "ocrUseGemini") as? Bool ?? true
        guidanceEnabled = d.object(forKey: "guidanceEnabled") as? Bool ?? false
        guidanceVoice = d.object(forKey: "guidanceVoice") as? Bool ?? true
        speechVoiceID = d.string(forKey: "speechVoiceID") ?? ""
        speechRate = d.object(forKey: "speechRate") as? Double ?? 1.0
        statusNotices = d.object(forKey: "statusNotices") as? Bool ?? true
        guidanceAutoCapture = d.object(forKey: "guidanceAutoCapture") as? Bool ?? true
        guidanceFlip = d.object(forKey: "guidanceFlip") as? Bool ?? false
        guidanceSharpness = d.object(forKey: "guidanceSharpness") as? Int ?? 1
        guidanceGlare = d.object(forKey: "guidanceGlare") as? Bool ?? true
        finishWord = d.string(forKey: "finishWord") ?? "hepsi tamamlandı"
        geminiEnabled = d.object(forKey: "geminiEnabled") as? Bool ?? false
        geminiKeys = (1...GeminiProfiles.slotCount).map { Keychain.get(GeminiProfiles.keychainName(slot: $0)) ?? "" }
        if let data = d.data(forKey: "geminiProfiles"), let saved = try? JSONDecoder().decode([GeminiProfile].self, from: data),
           saved.count == GeminiProfiles.slotCount {
            geminiProfiles = saved
        } else {
            // Eski sürümden: tek model ayarı 1. profil olur
            var list = GeminiProfiles.defaults()
            if let old = d.string(forKey: "geminiModel"), !old.trimmed.isEmpty { list[0].model = old.trimmed }
            geminiProfiles = list
        }
        geminiActive = min(max(d.object(forKey: "geminiActive") as? Int ?? 1, 1), GeminiProfiles.slotCount)
        geminiAutoFallback = d.object(forKey: "geminiAutoFallback") as? Bool ?? true
        geminiCapMonth = d.string(forKey: "geminiCapMonth") ?? ""
        geminiCapPrev = min(max(d.object(forKey: "geminiCapPrev") as? Int ?? 1, 1), GeminiProfiles.slotCount)
        geminiSessionTimeout = min(max(d.object(forKey: "geminiSessionTimeout") as? Int ?? 0, 0), 86400)
        geminiSession = d.object(forKey: "geminiSession") as? Bool ?? true
        geminiCallWord = d.string(forKey: "geminiCallWord") ?? GeminiText.defaultCallWord
        geminiPrivacyOK = d.object(forKey: "geminiPrivacyOK") as? Bool ?? false
        geminiDocCount = min(max(d.object(forKey: "geminiDocCount") as? Int ?? 3, 1), 30)
        previewOff = d.object(forKey: "previewOff") as? Bool ?? false
        dimWhenPreviewOff = d.object(forKey: "dimWhenPreviewOff") as? Bool ?? true
    }
}

extension AppSettings {
    /// Üç profil (anahtarlarıyla)
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
}
