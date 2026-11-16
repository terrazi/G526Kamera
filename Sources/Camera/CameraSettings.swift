import Foundation
import Combine

/// Kamera ayarları: kamera bağlantısı, video, fotoğraf, sesli konumlandırma ve pil. Anahtar adları sabittir; önceki sürümden kalan
/// telefonda kullanıcının yazdığı değerler (kamera adı, parola, yön…) kendiliğinden gelir.
final class CameraSettings: ObservableObject {
    /// Ayar anahtarları (UserDefaults)
    enum Key {
        static let uid = "uid"
        static let cameraIP = "cameraIP"
        static let cameraPassword = "cameraPassword"   // Keychain
        static let streamQuality = "streamQuality"
        static let jpegQuality = "jpegQuality"
        static let enhancement = "enhancement"
        static let deskew = "deskew"
        static let upscale = "upscale"
        static let timestampMode = "timestampMode"
        static let multiFrame = "multiFrame"
        static let documentOnly = "documentOnly"
        static let burstBefore = "burstBefore"
        static let burstAfter = "burstAfter"
        static let previewOff = "previewOff"
        static let lastShotOff = "lastShotOff"
        static let guidanceEnabled = "guidanceEnabled"
        static let guidanceVoice = "guidanceVoice"
        static let statusNotices = "statusNotices"
        static let imageOrientation = "imageOrientation"
        static let guidanceFrame = "guidanceFrame"
        static let guidanceSharpness = "guidanceSharpness"
        static let guidanceGlare = "guidanceGlare"
        static let guidanceDescribe = "guidanceDescribe"
        static let guidancePageEdges = "guidancePageEdges"
        static let pageVideoSeconds = "pageVideoSeconds"
        static let videoToGemini = "videoToGemini"
        static let videoQuestion = "videoQuestion"
        static let videoHighRes = "videoHighRes"
        static let cameraShortcutName = "cameraShortcutName"
        static let stayOnWifi = "stayOnWifi"
        static let connectAtStart = "connectAtStart"
    }

    /// İlk açılışta Ayarlar'da hazır yazılı gelen kamera adı (UID)
    static let defaultCameraUID = "G526029XJPDT"
    /// Kadraj yönünün varsayılanı: yatay (kullanıcı kararı 2026-11-13)
    static let defaultFrame = 0

    private let defaults: UserDefaults

    // MARK: Kamera
    @Published var uid: String { didSet { defaults.set(uid, forKey: Key.uid) } }
    @Published var cameraIP: String { didSet { defaults.set(cameraIP, forKey: Key.cameraIP) } }
    @Published var cameraPassword: String { didSet { Keychain.set(cameraPassword, for: Key.cameraPassword) } }
    /// 1 = Yüksek (1920x1080), 2 = Düşük (640x360)
    @Published var streamQuality: Int { didSet { defaults.set(streamQuality, forKey: Key.streamQuality) } }

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

    // MARK: Pil tasarrufu (ekran kısma `AppSettings.dimScreen` ayarıdır)
    /// Canlı önizleme kapalı: ekrana video çizilmez, kare çözme/çekim/kaydetme aynen sürer
    @Published var previewOff: Bool { didSet { defaults.set(previewOff, forKey: Key.previewOff) } }
    /// Ana ekranda "Son fotoğraf" (kameranın son çektiği sayfanın küçük resmi) gösterilmez ve saklanmaz
    @Published var lastShotOff: Bool { didSet { defaults.set(lastShotOff, forKey: Key.lastShotOff) } }

    // MARK: Sesli konumlandırma
    @Published var guidanceEnabled: Bool { didSet { defaults.set(guidanceEnabled, forKey: Key.guidanceEnabled) } }
    /// Uyarıları sesli söyle (kapalıysa yalnız ekranda yazar)
    @Published var guidanceVoice: Bool { didSet { defaults.set(guidanceVoice, forKey: Key.guidanceVoice) } }
    /// Kamera / gönderim durumunu da sesle haber ver
    @Published var statusNotices: Bool { didSet { defaults.set(statusNotices, forKey: Key.statusNotices) } }
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

    // MARK: Video
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
    /// Telefon kameranın Wi-Fi'sinde kalır: çekimde "Kameraya geç" kestirmesi çalışmaz, çekimden sonra Wi-Fi bırakılmaz; internet hücreselden gelir
    /// ve yalnız yoksa hücresel kestirmesi çalışır. Varsayılan KAPALI (kullanıcı kararı 2026-11-16): her çekimde kameraya geçilir (Wi-Fi açık, hücresel kapalı),
    /// sonra Wi-Fi bırakılıp hücresel açılır.
    @Published var stayOnWifi: Bool { didSet { defaults.set(stayOnWifi, forKey: Key.stayOnWifi) } }
    /// Oturum başlarken kameraya hemen bağlanılır (kullanıcı kararı 2026-11-16): "Kameraya geç" kestirmesi çalışır, görüntü ana ekranda akar ve
    /// bağlantı ilk hücresel bağlantıdan önce kapanır. Sonra her soruda eski düzen sürer.
    @Published var connectAtStart: Bool { didSet { defaults.set(connectAtStart, forKey: Key.connectAtStart) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        uid = defaults.string(forKey: Key.uid) ?? CameraSettings.defaultCameraUID
        cameraIP = defaults.string(forKey: Key.cameraIP) ?? ""
        cameraPassword = Keychain.get(Key.cameraPassword) ?? "123456"
        streamQuality = defaults.object(forKey: Key.streamQuality) as? Int ?? 1

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

        previewOff = defaults.object(forKey: Key.previewOff) as? Bool ?? false
        lastShotOff = defaults.object(forKey: Key.lastShotOff) as? Bool ?? false

        guidanceEnabled = defaults.object(forKey: Key.guidanceEnabled) as? Bool ?? true
        guidanceVoice = defaults.object(forKey: Key.guidanceVoice) as? Bool ?? true
        statusNotices = defaults.object(forKey: Key.statusNotices) as? Bool ?? true
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

        pageVideoSeconds = CameraSettings.clampSeconds(defaults.object(forKey: Key.pageVideoSeconds) as? Int,
                                                       range: VideoRecorder.pageSecondsRange, fallback: VideoRecorder.pageSegmentSeconds)
        videoToGemini = defaults.object(forKey: Key.videoToGemini) as? Bool ?? true
        videoQuestion = defaults.string(forKey: Key.videoQuestion) ?? ""
        videoHighRes = defaults.object(forKey: Key.videoHighRes) as? Bool ?? true
        cameraShortcutName = defaults.string(forKey: Key.cameraShortcutName) ?? ""
        stayOnWifi = defaults.object(forKey: Key.stayOnWifi) as? Bool ?? false
        connectAtStart = defaults.object(forKey: Key.connectAtStart) as? Bool ?? true
    }

    // MARK: Yardımcılar

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
