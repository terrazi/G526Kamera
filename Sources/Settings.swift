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
    /// Seri çekimde tetiklemeden önceki / sonraki pencere (saniye)
    @Published var burstBefore: Double { didSet { d.set(burstBefore, forKey: "burstBefore") } }
    @Published var burstAfter: Double { didSet { d.set(burstAfter, forKey: "burstAfter") } }

    // MARK: Otomatik çekim (görüntü değişince)
    @Published var motionEnabled: Bool { didSet { d.set(motionEnabled, forKey: "motionEnabled") } }
    /// 0 = düşük, 1 = orta, 2 = yüksek duyarlılık
    @Published var motionSensitivity: Int { didSet { d.set(motionSensitivity, forKey: "motionSensitivity") } }

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
    }
}
