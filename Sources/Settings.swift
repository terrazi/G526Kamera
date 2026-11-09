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
        guidanceEnabled = d.object(forKey: "guidanceEnabled") as? Bool ?? false
        guidanceVoice = d.object(forKey: "guidanceVoice") as? Bool ?? true
        statusNotices = d.object(forKey: "statusNotices") as? Bool ?? true
        guidanceAutoCapture = d.object(forKey: "guidanceAutoCapture") as? Bool ?? true
        guidanceFlip = d.object(forKey: "guidanceFlip") as? Bool ?? false
        guidanceSharpness = d.object(forKey: "guidanceSharpness") as? Int ?? 1
        guidanceGlare = d.object(forKey: "guidanceGlare") as? Bool ?? true
        finishWord = d.string(forKey: "finishWord") ?? "hepsi tamamlandı"
        previewOff = d.object(forKey: "previewOff") as? Bool ?? false
        dimWhenPreviewOff = d.object(forKey: "dimWhenPreviewOff") as? Bool ?? true
    }
}
