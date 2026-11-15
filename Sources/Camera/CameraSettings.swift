import Foundation
import Combine

/// Kamera ayarları (Sürüm 4). V1'deki kamera ayarlarının tamamı, V1'deki anahtar adları ve varsayılanlarıyla taşındı: V1/V3 kurulu bir
/// telefonda kullanıcının daha önce yazdığı değerler (kamera adı, parola, yön…) kendiliğinden gelir. Sapmalar `CameraSettings.deviations`
/// listesinde gerekçesiyle durur ve testle denetlenir.
///
/// V1'de olup V4'e ALINMAYAN ayarlar `CameraSettings.excluded` listesinde gerekçesiyle durur (belge klasörüne yükleme, Gemini belge sohbeti,
/// sınav modu, V1'in kendi okuma sesi ve dinleyicisi; V3'ünkiler kullanılır). V1'deki her ayar ya alınmıştır ya da bu listededir.
final class CameraSettings: ObservableObject {
    /// Ayar anahtarları (V1'dekiyle aynı)
    enum Key {
        static let uid = "uid"
        static let cameraIP = "cameraIP"
        static let cameraPassword = "cameraPassword"   // Keychain
        static let streamQuality = "streamQuality"
        static let triggerWord = "triggerWord"
        static let voiceEnabled = "voiceEnabled"
        static let cooldown = "cooldown"
        static let jpegQuality = "jpegQuality"
        static let enhancement = "enhancement"
        static let deskew = "deskew"
        static let upscale = "upscale"
        static let timestampMode = "timestampMode"
        static let multiFrame = "multiFrame"
        static let documentOnly = "documentOnly"
        static let burstBefore = "burstBefore"
        static let burstAfter = "burstAfter"
        static let motionEnabled = "motionEnabled"
        static let motionSensitivity = "motionSensitivity"
        static let previewOff = "previewOff"
        static let lastShotOff = "lastShotOff"
        static let guidanceEnabled = "guidanceEnabled"
        static let guidanceVoice = "guidanceVoice"
        static let videoGuidance = "videoGuidance"
        static let statusNotices = "statusNotices"
        static let guidanceAutoCapture = "guidanceAutoCapture"
        static let imageOrientation = "imageOrientation"
        static let guidanceFrame = "guidanceFrame"
        static let guidanceSharpness = "guidanceSharpness"
        static let guidanceGlare = "guidanceGlare"
        static let guidanceDescribe = "guidanceDescribe"
        static let guidancePageEdges = "guidancePageEdges"
        static let guidanceAutoPick = "guidanceAutoPick"
        static let examVideoMaxSeconds = "examVideoMaxSeconds"
        static let pageVideoSeconds = "pageVideoSeconds"
        static let videoToGemini = "videoToGemini"
        static let videoQuestion = "videoQuestion"
        static let videoHighRes = "videoHighRes"
        static let cameraShortcutName = "cameraShortcutName"
    }

    /// Ayarlar ekranındaki kamera bölümleri (V1'deki bölümler). Her ayar tam bir bölümde görünür; testle denetlenir.
    enum Group: String, CaseIterable {
        case camera, video, photo, motion, voice, guidance, power, shortcuts

        var title: String {
            switch self {
            case .camera: return "Kamera"
            case .video: return "Video kaydı"
            case .photo: return "Fotoğraf"
            case .motion: return "Otomatik çekim"
            case .voice: return "Sesle çekim (okey)"
            case .guidance: return "Sesli konumlandırma"
            case .power: return "Pil ve ısınma"
            case .shortcuts: return "Kamera kestirmesi"
            }
        }

        /// Bölümde görünen ayarların anahtarları (ekrandaki sırayla)
        var keys: [String] {
            switch self {
            case .camera:
                return [Key.uid, Key.cameraIP, Key.cameraPassword, Key.streamQuality, Key.guidanceFrame, Key.imageOrientation]
            case .video:
                return [Key.examVideoMaxSeconds, Key.pageVideoSeconds, Key.videoToGemini, Key.videoQuestion, Key.videoHighRes]
            case .photo:
                return [Key.enhancement, Key.multiFrame, Key.documentOnly, Key.deskew, Key.timestampMode, Key.upscale, Key.jpegQuality,
                        Key.burstBefore, Key.burstAfter]
            case .motion:
                return [Key.motionEnabled, Key.motionSensitivity]
            case .voice:
                return [Key.voiceEnabled, Key.triggerWord, Key.cooldown]
            case .guidance:
                return [Key.guidanceEnabled, Key.guidanceVoice, Key.videoGuidance, Key.statusNotices, Key.guidanceAutoCapture,
                        Key.guidanceSharpness, Key.guidanceGlare, Key.guidanceDescribe, Key.guidancePageEdges, Key.guidanceAutoPick]
            case .power:
                return [Key.previewOff, Key.lastShotOff]
            case .shortcuts:
                return [Key.cameraShortcutName]
            }
        }
    }

    /// Bütün kamera ayarlarının anahtarları
    static var allKeys: [String] { return Group.allCases.flatMap { $0.keys } }

    /// İlk açılışta Ayarlar'da hazır yazılı gelen kamera adı (UID)
    static let defaultCameraUID = "G526029XJPDT"
    /// Kadraj yönünün varsayılanı: yatay (kullanıcı kararı 2026-11-13)
    static let defaultFrame = 0

    /// V1'e göre bilerek değiştirilen varsayılanlar (anahtar, V1 değeri, V4 değeri, gerekçe). Başka sapma olmamalı.
    static let deviations: [(key: String, v1: String, v4: String, reason: String)] = [
        ("guidanceEnabled", "false", "true",
         "V4'te her kamera çekimi sesli konumlandırmayla başlar; kapalı varsayılan çekimi sessiz ve yönsüz bırakırdı"),
        ("guidanceDescribe", "true", "false",
         "Kullanıcı kararı (2026-11-15): kadraj tarifi ve \"soru bölünüyor\" uyarıları verilmesin; odak çalışılan sorudur")
    ]

    /// V1'de olup V4'e alınmayan ayarlar ve nedenleri. V1'deki her ayar ya `allKeys` içindedir ya da burada; üçüncü bir durum yoktur (testle denetlenir).
    static let excluded: [(key: String, reason: String)] = [
        ("dimScreen", "V3'te aynı işi `AppSettings.dimScreen` (v3.dimScreen) yapıyor"),
        ("speechVoiceID", "Okuma sesini V3'ün `phoneVoiceID` ayarı belirler"),
        ("speechRate", "Okuma hızını V3 konuşma çıkışı yönetir"),
        ("videoMaxSeconds", "Elle video çekimi V4 akışında yok; soru videosunun sınırı `examVideoMaxSeconds`"),
        ("examPageVideo", "V4'te soru her zaman sayfa videosuyla çekilir; kapatılacak bir eski yöntem yok"),
        ("videoSendMode", "V4 her soruyu tek tek, hemen gönderir; sıra bekletme kipi anlamsız"),
        ("finishWord", "Fotoğrafları toplu PDF yapma komutu: V4'te toplu gönderim yok"),
        ("sendMode", "Belge klasörüne tek tek / toplu yükleme: V4'te belge yükleme yok"),
        ("batchSize", "Toplu yükleme eşiği: V4'te belge yükleme yok"),
        ("batchIdle", "Toplu yükleme bekleme süresi: V4'te belge yükleme yok"),
        ("uploadFormat", "Klasöre PDF / JPEG yükleme biçimi: V4'te belge yükleme yok"),
        ("geminiEnabled", "V1'in belge sohbeti anahtarı; V4'te Gemini V3'ün profilleriyle çalışır"),
        ("geminiActive", "V1'in aktif Gemini profili; V3 profil zinciri kullanılıyor"),
        ("geminiProfiles", "V3'te `v3.geminiProfiles` olarak var"),
        ("geminiAutoFallback", "V3 zinciri yedeğe kendisi geçer"),
        ("geminiOverloadFallback", "V3 zinciri yedeğe kendisi geçer"),
        ("geminiChainFallback", "V3 zinciri yedeğe kendisi geçer"),
        ("geminiWaitLimit", "V3'ün kendi bekleme sınırları var"),
        ("geminiCapMonth", "V1 aylık kota sayacı; V3'te yok"),
        ("geminiCapPrev", "V1 aylık kota sayacı; V3'te yok"),
        ("geminiSessionTimeout", "V1 belge sohbeti oturumu; V4'te oturum yok"),
        ("geminiSession", "V1 belge sohbeti oturumu; V4'te oturum yok"),
        ("geminiCallWord", "V1'de \"Gemini\" deyince soru sorma; V4'te soru akışı V3'ün"),
        ("geminiThinking", "V1 düşünme düzeyi; V3 profil modeli belirler"),
        ("geminiPrivacyOK", "V1 gizlilik onayı; V4 yalnız kullanıcının başlattığı soruyu gönderir"),
        ("geminiDocCount", "V1 belge sayısı; V4'te belge yok"),
        ("geminiMemory", "V1 Files API belge önbelleği; V4'te belge seti yok"),
        ("geminiOptionCodes", "V1 şık kod sözcükleri; V3'ün cevap biçimi geçerli"),
        ("geminiBatchLast", "V1 toplu cevap sayacı; V4'te toplu cevap yok"),
        ("listenEnd", "V1 dinleyicisinin bitiş ayarı; V3 kendi dinleyicisini kullanır"),
        ("listenSilence", "V1 dinleyicisinin sessizlik ayarı; V3 kendi dinleyicisini kullanır"),
        ("audioLayout", "V1 ses yerleşimi; V3 ses yönlendirmesi sabit (kulaklık + Lightning mikrofon)"),
        ("examCancelWindow", "V1 sınav modu; V4 akışı V3 oturumudur"),
        ("examGap", "V1 sınav modu; V4 akışı V3 oturumudur"),
        ("examVideoFirst", "V1 sınav modu; V4 akışı V3 oturumudur"),
        ("examSelfCheck", "V1 sınav modu; V3'ün kendi açılış sınaması var"),
        ("examEnabled", "V1 sınav modu anahtarı; V4 her zaman sınav akışıdır"),
        ("connectionShortcutName", "V1 internet kestirmesi; V4'te bağlantı kestirmeleri yeniden düzenleniyor (Wi-Fi/hücresel)"),
        ("repairChecks", "V1 kendini onarma yoklaması; V3 `RecoveryCoordinator` kullanılıyor"),
        ("repairCheckSeconds", "V1 kendini onarma yoklaması; V3 `RecoveryCoordinator` kullanılıyor"),
        ("repairWaitSeconds", "V1 kendini onarma yoklaması; V3 `RecoveryCoordinator` kullanılıyor"),
        ("audioShortcutName", "V1 ses kestirmesi; V3'te `bluetoothShortcut` / `resetShortcut` var")
    ]

    private let defaults: UserDefaults

    // MARK: Kamera
    @Published var uid: String { didSet { defaults.set(uid, forKey: Key.uid) } }
    @Published var cameraIP: String { didSet { defaults.set(cameraIP, forKey: Key.cameraIP) } }
    @Published var cameraPassword: String { didSet { Keychain.set(cameraPassword, for: Key.cameraPassword) } }
    /// 1 = Yüksek (1920x1080), 2 = Düşük (640x360)
    @Published var streamQuality: Int { didSet { defaults.set(streamQuality, forKey: Key.streamQuality) } }

    // MARK: Sesle çekim ("okey")
    @Published var voiceEnabled: Bool { didSet { defaults.set(voiceEnabled, forKey: Key.voiceEnabled) } }
    @Published var triggerWord: String { didSet { defaults.set(triggerWord, forKey: Key.triggerWord) } }
    @Published var cooldown: Double { didSet { defaults.set(cooldown, forKey: Key.cooldown) } }

    // MARK: Fotoğraf
    @Published var jpegQuality: Double { didSet { defaults.set(jpegQuality, forKey: Key.jpegQuality) } }
    /// 0 = kapalı, 1 = hafif, 2 = güçlü
    @Published var enhancement: Int { didSet { defaults.set(enhancement, forKey: Key.enhancement) } }
    @Published var deskew: Bool { didSet { defaults.set(deskew, forKey: Key.deskew) } }
    /// 1.0, 1.5 veya 2.0
    @Published var upscale: Double { didSet { defaults.set(upscale, forKey: Key.upscale) } }
    /// Kameranın görüntüye işlediği tarih/saat: bulanıklaştır (varsayılan), kes ya da olduğu gibi bırak
    @Published var timestampMode: TimestampMode { didSet { defaults.set(timestampMode.rawValue, forKey: Key.timestampMode) } }
    @Published var multiFrame: Bool { didSet { defaults.set(multiFrame, forKey: Key.multiFrame) } }
    /// Yalnız belge (kâğıt + yazı) görünüyorsa fotoğraf çek
    @Published var documentOnly: Bool { didSet { defaults.set(documentOnly, forKey: Key.documentOnly) } }
    /// Seri çekimde tetiklemeden önceki / sonraki pencere (saniye)
    @Published var burstBefore: Double { didSet { defaults.set(burstBefore, forKey: Key.burstBefore) } }
    @Published var burstAfter: Double { didSet { defaults.set(burstAfter, forKey: Key.burstAfter) } }

    // MARK: Otomatik çekim (görüntü değişince)
    @Published var motionEnabled: Bool { didSet { defaults.set(motionEnabled, forKey: Key.motionEnabled) } }
    /// 0 = düşük, 1 = orta, 2 = yüksek duyarlılık
    @Published var motionSensitivity: Int { didSet { defaults.set(motionSensitivity, forKey: Key.motionSensitivity) } }

    // MARK: Pil tasarrufu (ekran kısma V3'ün `dimScreen` ayarıdır)
    /// Canlı önizleme kapalı: ekrana video çizilmez, kare çözme/çekim/kaydetme aynen sürer
    @Published var previewOff: Bool { didSet { defaults.set(previewOff, forKey: Key.previewOff) } }
    /// Ana ekranda "Son fotoğraf" (kameranın son çektiği sayfanın küçük resmi) gösterilmez ve saklanmaz
    @Published var lastShotOff: Bool { didSet { defaults.set(lastShotOff, forKey: Key.lastShotOff) } }

    // MARK: Sesli konumlandırma
    @Published var guidanceEnabled: Bool { didSet { defaults.set(guidanceEnabled, forKey: Key.guidanceEnabled) } }
    /// Uyarıları sesli söyle (kapalıysa yalnız ekranda yazar)
    @Published var guidanceVoice: Bool { didSet { defaults.set(guidanceVoice, forKey: Key.guidanceVoice) } }
    /// Video kaydı sürerken de konum tarifi ver
    @Published var videoGuidance: Bool { didSet { defaults.set(videoGuidance, forKey: Key.videoGuidance) } }
    /// Kamera / gönderim durumunu da sesle haber ver
    @Published var statusNotices: Bool { didSet { defaults.set(statusNotices, forKey: Key.statusNotices) } }
    /// Konum uygun olunca kendiliğinden çek (kapalıysa "okey" demenizi bekler)
    @Published var guidanceAutoCapture: Bool { didSet { defaults.set(guidanceAutoCapture, forKey: Key.guidanceAutoCapture) } }
    /// Görüntü yönü: önizleme, fotoğraf, video ve sesli yönlendirme bu yöne göre çevrilir
    @Published var imageOrientation: ImageOrientation { didSet { defaults.set(imageOrientation.rawValue, forKey: Key.imageOrientation) } }
    /// Kadraj: 0 = yatay (varsayılan), 1 = dikey tam sayfa
    @Published var guidanceFrame: Int {
        didSet {
            defaults.set(guidanceFrame, forKey: Key.guidanceFrame)
            // Kadraj yönü değişince görüntü yönü ona uydurulur (Dikey: 90° sağa / sola, Yatay: normal / 180°)
            let fixed = CameraSettings.orientation(imageOrientation, forFrame: guidanceFrame)
            if fixed != imageOrientation { imageOrientation = fixed }
        }
    }
    /// 0 = gevşek, 1 = normal, 2 = sıkı netlik isteği
    @Published var guidanceSharpness: Int { didSet { defaults.set(guidanceSharpness, forKey: Key.guidanceSharpness) } }
    /// Sayfada parlama lekesi varsa uyar
    @Published var guidanceGlare: Bool { didSet { defaults.set(guidanceGlare, forKey: Key.guidanceGlare) } }
    /// Kadrajı sesli tarif et (tek/iki sayfa, hangisi sığıyor)
    @Published var guidanceDescribe: Bool { didSet { defaults.set(guidanceDescribe, forKey: Key.guidanceDescribe) } }
    /// Kadraj tarifine kâğıdın kenarlarını da kat (Apple belge algılaması)
    @Published var guidancePageEdges: Bool { didSet { defaults.set(guidancePageEdges, forKey: Key.guidancePageEdges) } }
    /// Kadrajda tek bölüm tam sığıyor, diğerleri kesikse sormadan tam sığanı seç ve çek
    @Published var guidanceAutoPick: Bool { didSet { defaults.set(guidanceAutoPick, forKey: Key.guidanceAutoPick) } }

    // MARK: Video
    /// Sınav / soru videosu en çok kaç saniye sürsün (10–300)
    @Published var examVideoMaxSeconds: Int { didSet { defaults.set(examVideoMaxSeconds, forKey: Key.examVideoMaxSeconds) } }
    /// Sayfa sayfa videoda her sayfanın kaydedilen süresi (2–15)
    @Published var pageVideoSeconds: Int { didSet { defaults.set(pageVideoSeconds, forKey: Key.pageVideoSeconds) } }
    /// Video Gemini'ye de gönderilir; cevap sesle okunur
    @Published var videoToGemini: Bool { didSet { defaults.set(videoToGemini, forKey: Key.videoToGemini) } }
    /// Video sorusu (boşsa varsayılan talimat)
    @Published var videoQuestion: String { didSet { defaults.set(videoQuestion, forKey: Key.videoQuestion) } }
    /// Videoyu yüksek çözünürlükle oku (küçük yazı için)
    @Published var videoHighRes: Bool { didSet { defaults.set(videoHighRes, forKey: Key.videoHighRes) } }

    // MARK: Kestirme
    /// Kamera (Wi-Fi) kestirmesinin adı; boşsa kapalı
    @Published var cameraShortcutName: String { didSet { defaults.set(cameraShortcutName, forKey: Key.cameraShortcutName) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        uid = defaults.string(forKey: Key.uid) ?? CameraSettings.defaultCameraUID
        cameraIP = defaults.string(forKey: Key.cameraIP) ?? ""
        cameraPassword = Keychain.get(Key.cameraPassword) ?? "123456"
        streamQuality = defaults.object(forKey: Key.streamQuality) as? Int ?? 1

        voiceEnabled = defaults.object(forKey: Key.voiceEnabled) as? Bool ?? true
        triggerWord = defaults.string(forKey: Key.triggerWord) ?? "okey"
        cooldown = defaults.object(forKey: Key.cooldown) as? Double ?? 4.0

        jpegQuality = defaults.object(forKey: Key.jpegQuality) as? Double ?? 0.92
        enhancement = defaults.object(forKey: Key.enhancement) as? Int ?? 1
        deskew = defaults.object(forKey: Key.deskew) as? Bool ?? false
        upscale = defaults.object(forKey: Key.upscale) as? Double ?? 1.0
        if let raw = defaults.string(forKey: Key.timestampMode), let mode = TimestampMode(rawValue: raw) {
            timestampMode = mode
        } else if defaults.bool(forKey: "cropTimestamp") {
            timestampMode = .crop          // eski sürümdeki "saat yazısını kes" ayarı
        } else {
            timestampMode = .blur
        }
        multiFrame = defaults.object(forKey: Key.multiFrame) as? Bool ?? true
        documentOnly = defaults.object(forKey: Key.documentOnly) as? Bool ?? true
        burstBefore = defaults.object(forKey: Key.burstBefore) as? Double ?? 0.4
        burstAfter = defaults.object(forKey: Key.burstAfter) as? Double ?? 0.8

        motionEnabled = defaults.object(forKey: Key.motionEnabled) as? Bool ?? false
        motionSensitivity = defaults.object(forKey: Key.motionSensitivity) as? Int ?? 1
        previewOff = defaults.object(forKey: Key.previewOff) as? Bool ?? false
        lastShotOff = defaults.object(forKey: Key.lastShotOff) as? Bool ?? false

        guidanceEnabled = defaults.object(forKey: Key.guidanceEnabled) as? Bool ?? true
        guidanceVoice = defaults.object(forKey: Key.guidanceVoice) as? Bool ?? true
        videoGuidance = defaults.object(forKey: Key.videoGuidance) as? Bool ?? true
        statusNotices = defaults.object(forKey: Key.statusNotices) as? Bool ?? true
        guidanceAutoCapture = defaults.object(forKey: Key.guidanceAutoCapture) as? Bool ?? true
        // Kadraj yönü ile görüntü yönü uyumlu olmalı (bkz. orientation(_:forFrame:))
        let frameValue = defaults.object(forKey: Key.guidanceFrame) as? Int ?? CameraSettings.defaultFrame
        let orient = CameraSettings.orientation(CameraSettings.migratedOrientation(defaults), forFrame: frameValue)
        defaults.set(orient.rawValue, forKey: Key.imageOrientation)
        imageOrientation = orient
        guidanceFrame = frameValue
        guidanceSharpness = defaults.object(forKey: Key.guidanceSharpness) as? Int ?? 1
        guidanceGlare = defaults.object(forKey: Key.guidanceGlare) as? Bool ?? true
        guidanceDescribe = defaults.object(forKey: Key.guidanceDescribe) as? Bool ?? false
        guidancePageEdges = defaults.object(forKey: Key.guidancePageEdges) as? Bool ?? true
        guidanceAutoPick = defaults.object(forKey: Key.guidanceAutoPick) as? Bool ?? true

        examVideoMaxSeconds = CameraSettings.clampSeconds(defaults.object(forKey: Key.examVideoMaxSeconds) as? Int,
                                                          range: VideoRecorder.examSecondsRange, fallback: Int(VideoRecorder.examMaxSeconds))
        pageVideoSeconds = CameraSettings.clampSeconds(defaults.object(forKey: Key.pageVideoSeconds) as? Int,
                                                       range: VideoRecorder.pageSecondsRange, fallback: VideoRecorder.pageSegmentSeconds)
        videoToGemini = defaults.object(forKey: Key.videoToGemini) as? Bool ?? true
        videoQuestion = defaults.string(forKey: Key.videoQuestion) ?? ""
        videoHighRes = defaults.object(forKey: Key.videoHighRes) as? Bool ?? true
        cameraShortcutName = defaults.string(forKey: Key.cameraShortcutName) ?? ""
    }

    // MARK: Yardımcılar (V1'deki gibi)

    /// Kayıtlı süreyi izin verilen aralığa çeker (kayıt yoksa varsayılan)
    static func clampSeconds(_ value: Int?, range: ClosedRange<Int>, fallback: Int) -> Int {
        return min(max(value ?? fallback, range.lowerBound), range.upperBound)
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
        if let raw = d.object(forKey: Key.imageOrientation) as? Int, let o = ImageOrientation(rawValue: raw) {
            value = o
        } else if d.object(forKey: "guidanceFlip") as? Bool == true {
            value = .rotate180
        } else {
            value = .normal
        }
        d.set(value.rawValue, forKey: Key.imageOrientation)
        d.removeObject(forKey: "guidanceFlip")
        return value
    }
}
