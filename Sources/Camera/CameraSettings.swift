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
        static let streamOverride = "streamOverride"
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
        static let autoOrientation = "autoOrientation"
        static let guidanceFrame = "guidanceFrame"
        static let guidanceSharpness = "guidanceSharpness"
        static let guidanceGlare = "guidanceGlare"
        static let guidanceDescribe = "guidanceDescribe"
        static let guidancePageEdges = "guidancePageEdges"
        static let seriesGuidance = "seriesGuidance"
        static let largeUpload = "largeUpload"
        static let accurateReading = "accurateReading"
        static let motionTracking = "motionTracking"
        static let thinFrames = "thinFrames"
        static let pageVideoSeconds = "pageVideoSeconds"
        static let countdown = "countdown"
        static let pageSeries = "pageSeries"
        /// 2026-11-18: ritimli çekimde süre 25 sn'lik sayfalardan oluşur (varsayılan 125 sn = 5 sayfa); eski "seriesTotalSeconds" (75 sn) anahtarı bırakıldı
        static let seriesSeconds = "seriesScanSeconds"   // eski "seriesSessionSeconds" (125 sn, 5 sayfa) bırakıldı: yeni varsayılan 60 sn geçerli olsun
        static let autoStart = "autoStart"
        static let autoOpenEnabled = "autoOpenEnabled"
        static let autoOpenMinutes = "autoOpenMinutes"
        static let autoLatestEnabled = "autoLatestEnabled"
        static let autoLatestMinutes = "autoLatestMinutes"
        static let autoFirstNumber = "autoFirstNumber"
        static let autoQuestionCount = "autoQuestionCount"
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
    /// Çekimde kullanılacak kamera akışı (deneme için, kullanıcı kararı 2026-11-17): 0 = otomatik (toplu çekimde akış 1, eski çekimde `streamQuality`),
    /// 1 / 2 / 3 = o akış her çekimde. Akış 3'ün ne verdiği bilinmiyordu; ölçüm günlüğe yazılır.
    @Published var streamOverride: Int { didSet { defaults.set(streamOverride, forKey: Key.streamOverride) } }
    static let streamOverrideRange = 0...3

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
    /// Yazının yönünü kendiliğinden bul (kullanıcı isteği 2026-11-18: çekim bazen alttan, bazen yandan olabilir): kare mevcut yönde okunmuyorsa yan ve ters yönler
    /// denenir; yazı okunan yönde ölçülür ve kaydedilirken dik çevrilir, sesli yön cümleleri ise kameranın duruşuna göre söylenir (bkz. `OrientationFinder`).
    /// Kapalıyken yalnız yukarıdaki "Görüntü yönü" geçerlidir.
    @Published var autoOrientation: Bool { didSet { defaults.set(autoOrientation, forKey: Key.autoOrientation) } }
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
    /// Toplu çekimde sesli konumlandırma (kullanıcı kararı 2026-11-17; 2026-11-18: sesli konumlandırmanın her bileşeni varsayılan AÇIK): çekim sürerken kadraj koçu kısa cümlelerle konuşur (kesik kenar,
    /// kayma yönü, yakın / bulanık, üstte ve altta hangi satır). İşaretlenince "sesli konumlandırma desteği" de açılır: kadraj tarifi, sayfa kenarı ve
    /// sesli uyarı. Kapalıyken toplu çekim sessizdir.
    /// Büyük PDF (kullanıcı isteği 2026-11-18 akşam): kareler sıkıştırılmadan (45 MB'a kadar) PDF olur ve Gemini'ye DOSYA olarak bir kez yüklenir
    /// (Files API); kapalıyken eski düzen (16 MB, isteğin içinde). Yükleme başarısız olursa PDF isteğin içinde gider
    @Published var largeUpload: Bool { didSet { defaults.set(largeUpload, forKey: Key.largeUpload) } }
    /// Güçlü yazı okuma: serbest taramada kareler Vision'ın "accurate" kipiyle okunur (soru numaraları daha doğru çıkar); telefon yetişemezse o
    /// oturumda kendiliğinden hızlı kipe dönülür (bkz. `ReadPace`)
    @Published var accurateReading: Bool { didSet { defaults.set(accurateReading, forKey: Key.accurateReading) } }
    /// Hareket takibi: ardışık kareler hizalanır, kaydırma hızı ve gezilen alan ölçülür (bkz. `MotionTracker`); bu sürümde yalnız danışmandır
    @Published var motionTracking: Bool { didSet { defaults.set(motionTracking, forKey: Key.motionTracking) } }
    /// Kare azaltma: serbest taramanın son seçiminde içeriği komşu temiz karede olan yarı bozuk kareler ve fazla tekrarlar gönderilmez
    /// (bkz. `SeriesPool.thinned`); kapalıyken geçerli karelerin hepsi gider
    @Published var thinFrames: Bool { didSet { defaults.set(thinFrames, forKey: Key.thinFrames) } }
    @Published var seriesGuidance: Bool {
        didSet {
            defaults.set(seriesGuidance, forKey: Key.seriesGuidance)
            if seriesGuidance && !oldValue {
                guidanceDescribe = true
                guidancePageEdges = true
                guidanceVoice = true
            }
        }
    }

    // MARK: Video
    /// Her soru ya da paragraf için çekim süresi (2–15 sn, varsayılan 10): video bu kadar sürer, her saniyenin en net karesi bir fotoğraf olur
    /// (10 sn = 10 fotoğraf = tek PDF). Anahtar adı eski sürümden kalmadır.
    @Published var pageVideoSeconds: Int { didSet { defaults.set(pageVideoSeconds, forKey: Key.pageVideoSeconds) } }
    /// Toplu çekim (kullanıcı kararı 2026-11-16): kamera sorusu "evet" olunca BİR OTURUM çekilir; oturumun TEK sınırı süredir (`seriesSeconds`, varsayılan 125 sn).
    /// Sayfa sayısı yoktur: sayfalar eşit sürede gösterilmez (biri 3 sn, biri 8 sn görünür; hızlı hareketle 10 sayfa da taranabilir), süre içinde ne kadar sayfa
    /// gösterilirse hepsi gönderilir. Oturum boyunca ses, mikrofon, hücresel ve kulaklık kapalıdır (titreşim ya da ses işareti YOK).
    /// Oturumdan sonra görüntülerdeki BÜTÜN sorular ve paragraflar Gemini'ye gider ve cevaplar numara sırasıyla okunur. Kapalıysa her çekim tek sorudur (eski düzen).
    @Published var pageSeries: Bool { didSet { defaults.set(pageSeries, forKey: Key.pageSeries) } }
    /// Oturumun toplam süresi (25–200 sn, varsayılan 125 = 5 sayfa; 25'in katı): ritimli çekimde (`SeriesRhythm`) sayfa başına 25 sn, kullanıcı kararı 2026-11-18
    @Published var seriesSeconds: Int { didSet { defaults.set(seriesSeconds, forKey: Key.seriesSeconds) } }
    static let seriesSecondsRange = 30...180
    static let seriesSecondsStep = 10
    /// Kullanıcı kararı 2026-11-18 akşam: oturum 60 sn, hedef 2 sayfa, saniyede 2 kare (en çok 120 kare)
    static let defaultSeriesSeconds = 60
    /// Otomatik zamanlı başlatma (kullanıcı kararı 2026-11-19; bkz. `AutoStart`): toplu çekimde program "Başla" komutunu beklemek zorunda kalmaz. Kamera açılış
    /// saatinde açılır, "Kameranın başlaması için lütfen 1. soruyu okutunuz" denir; tarama, kamera o soruyu görünce (5'ten sayım), en geç başlama saati gelince
    /// (15'ten sayım) ya da "Başla" denince başlar. Sonraki taramalar sırayla, aralarında 15 sn boşlukla kendiliğinden sürer. Kapalıyken eski düzen: her tarama "Başla" ile başlar.
    @Published var autoStart: Bool { didSet { defaults.set(autoStart, forKey: Key.autoStart) } }
    /// Kamera açılış saati kullanılsın mı (kapalıysa kamera "Başlat"tan hemen sonra açılır) ve saati (gün içi dakika)
    @Published var autoOpenEnabled: Bool { didSet { defaults.set(autoOpenEnabled, forKey: Key.autoOpenEnabled) } }
    @Published var autoOpenMinutes: Int { didSet { defaults.set(autoOpenMinutes, forKey: Key.autoOpenMinutes) } }
    /// En geç başlama saati kullanılsın mı (kapalıysa ilk tarama yalnız soru görülünce ya da "Başla" ile başlar) ve saati (gün içi dakika)
    @Published var autoLatestEnabled: Bool { didSet { defaults.set(autoLatestEnabled, forKey: Key.autoLatestEnabled) } }
    @Published var autoLatestMinutes: Int { didSet { defaults.set(autoLatestMinutes, forKey: Key.autoLatestMinutes) } }
    /// İlk taramayı başlatacak soru numarası (varsayılan 1)
    @Published var autoFirstNumber: Int { didSet { defaults.set(autoFirstNumber, forKey: Key.autoFirstNumber) } }
    /// Sınavın soru sayısı (kullanıcı kararı 2026-11-19): bu sayıya ulaşılınca yeni tarama istenmez; bütün cevaplar baştan, numara + şehir kodlu şık +
    /// doğru cevap metniyle, aralarında 2 sn boşlukla okunur ve sınav kapanır. 0: belirtilmedi (taramalar "Testi bitir" denene kadar sürer).
    @Published var autoQuestionCount: Int { didSet { defaults.set(autoQuestionCount, forKey: Key.autoQuestionCount) } }
    static let defaultAutoOpenMinutes = 9 * 60
    static let defaultAutoLatestMinutes = 9 * 60 + 5

    /// DatePicker için: saat bugünün bir saati olarak
    var autoOpenTime: Date {
        get { return CameraSettings.date(minutes: autoOpenMinutes) }
        set { autoOpenMinutes = CameraSettings.minutes(of: newValue) }
    }
    var autoLatestTime: Date {
        get { return CameraSettings.date(minutes: autoLatestMinutes) }
        set { autoLatestMinutes = CameraSettings.minutes(of: newValue) }
    }
    static func date(minutes: Int) -> Date {
        let clamped = min(max(minutes, 0), 24 * 60 - 1)
        return Calendar.current.date(bySettingHour: clamped / 60, minute: clamped % 60, second: 0, of: Date()) ?? Date()
    }
    static func minutes(of date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
    /// Kamera "Başla"dan SONRA açılır (kullanıcı kararı 2026-11-17: hazır beklerken açık tutulan kamera bağlantısı kopuyordu).
    /// "Başla" denince: "Kamera açılıyor", kameraya geçilir, görüntü gelince "Başladı" ve süre başlar. Ayarlarda GÖRÜNMEZ ve kaydedilmez: eski hazır bekleme
    /// düzeni (açılışta kameraya bağlanıp "Başla"yı beklemek) kullanıcı isteğiyle kapalıdır; yalnız sınamalar onu denemek için kapatır.
    var cameraAfterGo = true
    /// Çekimde sesli geri sayım: "N saniye boyunca çekim yapabilirsiniz. Başlıyorum." ve N, N-1 … 1 (kullanıcı kararı 2026-11-16)
    @Published var countdown: Bool { didSet { defaults.set(countdown, forKey: Key.countdown) } }
    /// Video Gemini'ye de gönderilir; cevap sesle okunur
    @Published var videoToGemini: Bool { didSet { defaults.set(videoToGemini, forKey: Key.videoToGemini) } }
    /// Video sorusu (boşsa varsayılan talimat)
    @Published var videoQuestion: String { didSet { defaults.set(videoQuestion, forKey: Key.videoQuestion) } }
    /// Videoyu yüksek çözünürlükle oku (küçük yazı için)
    @Published var videoHighRes: Bool { didSet { defaults.set(videoHighRes, forKey: Key.videoHighRes) } }

    // MARK: Kestirme
    /// Kamera (Wi-Fi) kestirmesinin adı; boşsa kapalı
    @Published var cameraShortcutName: String { didSet { defaults.set(cameraShortcutName, forKey: Key.cameraShortcutName) } }
    /// Bağlantılar hep açık (kullanıcı kararı 2026-11-19): telefon kameranın Wi-Fi'sinde kalır, hücresel veri ve Bluetooth kulaklık da hiç kapatılmaz.
    /// Tarama öncesi "Kameraya geç", sonrası "Hücresele geç" kestirmesi ÇALIŞMAZ; internet hücreselden gelir. Kestirmeler yalnız kopan bağlantıyı yeniden
    /// kurmak içindir (kamera için Wi-Fi onarımı, internet için hücresel, kulaklık için Bluetooth; olmazsa uçak modu). Varsayılan AÇIK. Kapalıyken eski
    /// düzen: her taramada kameraya geçilir (Wi-Fi açık, hücresel kapalı), sonra hücresele dönülür.
    @Published var stayOnWifi: Bool { didSet { defaults.set(stayOnWifi, forKey: Key.stayOnWifi) } }

    /// "Bağlantılar hep açık" düzenine bir kez geçilir (önceki sürümde ayar kapalı kaydedilmiş olabilir); sonra kullanıcı Ayarlar'dan değiştirebilir
    func applyAlwaysOnOnce() {
        guard !defaults.bool(forKey: "v4.alwaysOnApplied") else { return }
        defaults.set(true, forKey: "v4.alwaysOnApplied")
        if !stayOnWifi { stayOnWifi = true }
    }
    /// Oturum başlarken kameraya hemen bağlanılır (kullanıcı kararı 2026-11-16): "Kameraya geç" kestirmesi çalışır, görüntü ana ekranda akar ve
    /// bağlantı ilk hücresel bağlantıdan önce kapanır. Sonra her soruda eski düzen sürer.
    @Published var connectAtStart: Bool { didSet { defaults.set(connectAtStart, forKey: Key.connectAtStart) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        uid = defaults.string(forKey: Key.uid) ?? CameraSettings.defaultCameraUID
        cameraIP = defaults.string(forKey: Key.cameraIP) ?? ""
        cameraPassword = Keychain.get(Key.cameraPassword) ?? "123456"
        streamQuality = defaults.object(forKey: Key.streamQuality) as? Int ?? 1
        let savedOverride = defaults.object(forKey: Key.streamOverride) as? Int ?? 0
        streamOverride = min(max(savedOverride, CameraSettings.streamOverrideRange.lowerBound), CameraSettings.streamOverrideRange.upperBound)

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
        autoOrientation = defaults.object(forKey: Key.autoOrientation) as? Bool ?? false
        guidanceSharpness = defaults.object(forKey: Key.guidanceSharpness) as? Int ?? 1
        guidanceGlare = defaults.object(forKey: Key.guidanceGlare) as? Bool ?? true
        guidanceDescribe = defaults.object(forKey: Key.guidanceDescribe) as? Bool ?? true
        guidancePageEdges = defaults.object(forKey: Key.guidancePageEdges) as? Bool ?? true
        seriesGuidance = defaults.object(forKey: Key.seriesGuidance) as? Bool ?? true
        largeUpload = defaults.object(forKey: Key.largeUpload) as? Bool ?? true
        accurateReading = defaults.object(forKey: Key.accurateReading) as? Bool ?? true
        motionTracking = defaults.object(forKey: Key.motionTracking) as? Bool ?? true
        thinFrames = defaults.object(forKey: Key.thinFrames) as? Bool ?? true

        pageVideoSeconds = CameraSettings.clampSeconds(defaults.object(forKey: Key.pageVideoSeconds) as? Int,
                                                       range: VideoRecorder.pageSecondsRange, fallback: VideoRecorder.pageSegmentSeconds)
        countdown = defaults.object(forKey: Key.countdown) as? Bool ?? false   // kullanıcı kararı 2026-11-16: çekim sırasında sürekli konuşma Bluetooth/Wi-Fi çakışmasını artırabilir; varsayılan sessiz
        pageSeries = defaults.object(forKey: Key.pageSeries) as? Bool ?? true
        // Süre sayfa sayısına tamamlanır (ritim yarım sayfa bırakmaz): söylenen süre ile çekilen süre aynı olsun
        seriesSeconds = SeriesRhythm.standard.roundedSeconds(
            CameraSettings.clampSeconds(defaults.object(forKey: Key.seriesSeconds) as? Int,
                                        range: CameraSettings.seriesSecondsRange, fallback: CameraSettings.defaultSeriesSeconds))
        autoStart = defaults.object(forKey: Key.autoStart) as? Bool ?? true
        autoOpenEnabled = defaults.object(forKey: Key.autoOpenEnabled) as? Bool ?? false
        autoOpenMinutes = CameraSettings.clampSeconds(defaults.object(forKey: Key.autoOpenMinutes) as? Int,
                                                      range: 0...(24 * 60 - 1), fallback: CameraSettings.defaultAutoOpenMinutes)
        autoLatestEnabled = defaults.object(forKey: Key.autoLatestEnabled) as? Bool ?? false
        autoLatestMinutes = CameraSettings.clampSeconds(defaults.object(forKey: Key.autoLatestMinutes) as? Int,
                                                        range: 0...(24 * 60 - 1), fallback: CameraSettings.defaultAutoLatestMinutes)
        autoFirstNumber = CameraSettings.clampSeconds(defaults.object(forKey: Key.autoFirstNumber) as? Int,
                                                      range: AutoStart.firstNumberRange, fallback: 1)
        autoQuestionCount = CameraSettings.clampSeconds(defaults.object(forKey: Key.autoQuestionCount) as? Int,
                                                        range: AutoStart.questionCountRange, fallback: 0)
        videoToGemini = defaults.object(forKey: Key.videoToGemini) as? Bool ?? true
        videoQuestion = defaults.string(forKey: Key.videoQuestion) ?? ""
        videoHighRes = defaults.object(forKey: Key.videoHighRes) as? Bool ?? true
        cameraShortcutName = defaults.string(forKey: Key.cameraShortcutName) ?? ""
        stayOnWifi = defaults.object(forKey: Key.stayOnWifi) as? Bool ?? true
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
