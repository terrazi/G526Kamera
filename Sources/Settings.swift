import Foundation

/// Kullanıcı ayarları. Hepsi telefonda saklanır (API anahtarları ve kamera parolası Keychain'de). Kamera adı (UID) ilk açılışta
/// hazır gelir; Ayarlar'dan silinip başkası yazılabilir.
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
    /// Görüntü yönü: önizleme, soru görüntüleri, video ve yönlendirme bu yöne göre çevrilir
    @Published var imageOrientation: ImageOrientation { didSet { d.set(imageOrientation.rawValue, forKey: "imageOrientation") } }
    /// Kadraj yönü: 0 = yatay (varsayılan; kamera görüntüsü olduğu gibi), 1 = dikey tam sayfa
    @Published var guidanceFrame: Int {
        didSet {
            d.set(guidanceFrame, forKey: "guidanceFrame")
            // Kadraj yönü değişince görüntü yönü ona uydurulur (Dikey: 90° sağa / sola, Yatay: normal / 180°)
            let fixed = AppSettings.orientation(imageOrientation, forFrame: guidanceFrame)
            if fixed != imageOrientation { imageOrientation = fixed }
        }
    }

    // MARK: Tarama
    /// Taranacak soru sayısı (her sınavdan önce girilir; 0 = girilmemiş)
    @Published var questionTotal: Int { didSet { d.set(questionTotal, forKey: "questionTotal") } }
    /// Soru başına şık sayısı: 4 (A–D) ya da 5 (A–E)
    @Published var optionCount: Int { didSet { d.set(optionCount, forKey: "optionCount") } }
    /// Gemini'ye giden PDF kaç sorudan oluşsun (1 = her soru ayrı PDF)
    @Published var groupSize: Int { didSet { d.set(groupSize, forKey: "groupSize") } }
    /// Gemini'ye ne gitsin: 0 = akıllı (telefonda temiz okunan soru metin, şüpheli soru PDF), 1 = hep PDF (görüntü), 2 = yalnız metin
    @Published var geminiInput: Int { didSet { d.set(geminiInput, forKey: "geminiInput") } }
    /// Kamera hazırken "evrakı kameraya tutun" uyarısı bu kadar saniyede bir tekrarlanır
    @Published var readyRepeatSeconds: Int { didSet { d.set(readyRepeatSeconds, forKey: "readyRepeatSeconds") } }
    /// Evrak bu kadar dakikada tutulmazsa taramadan vazgeçilir
    @Published var readyMaxMinutes: Int { didSet { d.set(readyMaxMinutes, forKey: "readyMaxMinutes") } }
    /// Bir soru için en çok deneme; dolunca soru "okunamadı" sayılır, tarama sürer (0 = sınırsız)
    @Published var maxAttempts: Int { didSet { d.set(maxAttempts, forKey: "maxAttempts") } }
    /// Taramanın toplam süre sınırı (dakika): dolunca eksikler "okunamadı" sayılıp tarama biter
    @Published var scanMaxMinutes: Int { didSet { d.set(scanMaxMinutes, forKey: "scanMaxMinutes") } }
    /// Sayfa boşalınca eksik sorular varsa bu kadar saniye beklenir (eksik sayfayı tutmanız istenir), sonra tarama biter
    @Published var missingWaitSeconds: Int { didSet { d.set(missingWaitSeconds, forKey: "missingWaitSeconds") } }
    /// Netlik isteği: 0 = gevşek, 1 = normal, 2 = sıkı
    @Published var guidanceSharpness: Int { didSet { d.set(guidanceSharpness, forKey: "guidanceSharpness") } }

    // MARK: Kestirmeler ve internet
    /// Kamera Wi-Fi'sini açan kestirmenin adı (Kestirmeler uygulamasındaki ad); boşsa kamera ağına elle bağlanılmış varsayılır
    @Published var cameraShortcutName: String { didSet { d.set(cameraShortcutName, forKey: "cameraShortcutName") } }
    /// Tarama bitince çalışan internet kestirmesi (Wi-Fi'yi kapat, 2 sn bekle, hücresel veriyi aç); boşsa internetin kendiliğinden geleceği varsayılır
    @Published var connectionShortcutName: String { didSet { d.set(connectionShortcutName, forKey: "connectionShortcutName") } }
    /// Kamera ve internet için kestirme deneme sayısı (1–1000) ve denemeler arası bekleme (sn)
    @Published var shortcutTries: Int { didSet { d.set(shortcutTries, forKey: "shortcutTries") } }
    @Published var shortcutWaitSeconds: Int { didSet { d.set(shortcutWaitSeconds, forKey: "shortcutWaitSeconds") } }
    static let questionTotalRange = 0...300
    static let shortcutTriesRange = 1...1000
    static let shortcutWaitRange = 10...3600

    // MARK: Gemini
    /// Model profilleri (ad, model, ücretsiz mi); anahtarlar `geminiKeys` içinde, Keychain'de
    @Published var geminiProfiles: [GeminiProfile] {
        didSet { d.set(try? JSONEncoder().encode(geminiProfiles), forKey: "geminiProfiles") }
    }
    /// Profillerin API anahtarları (Keychain: geminiApiKey … geminiApiKey4); yalnız bu telefonda
    @Published var geminiKeys: [String] {
        didSet {
            for (i, key) in geminiKeys.enumerated() {
                Keychain.set(key.trimmed, for: GeminiProfiles.keychainName(slot: i + 1))
            }
        }
    }
    /// İlk denenen profil (1–4); kota dolunca / hata olunca / cevap gecikince sıradakine geçilir
    @Published var geminiActive: Int { didSet { d.set(geminiActive, forKey: "geminiActive") } }
    /// Bir model bu kadar saniyede cevap vermezse sıradaki modele geçilir (0–600; 0 = sınırsız). Son modele sınır konmaz.
    @Published var geminiWaitLimit: Int { didSet { d.set(geminiWaitLimit, forKey: "geminiWaitLimit") } }
    /// Şık harfi yerine sesli okunan kod sözcükleri ("A=ADANA, B=BURSA…"); boş = harfin kendisi okunur
    @Published var geminiOptionCodes: String { didSet { d.set(geminiOptionCodes, forKey: "geminiOptionCodes") } }

    // MARK: Kayıt (belge klasörü)
    @Published var jpegQuality: Double { didSet { d.set(jpegQuality, forKey: "jpegQuality") } }
    /// Soru görüntülerine hafif keskinleştirme uygulansın
    @Published var sharpenImages: Bool { didSet { d.set(sharpenImages, forKey: "sharpenImages") } }
    /// Kameranın görüntüye işlediği tarih/saat: bulanıklaştır (varsayılan) ya da olduğu gibi bırak
    @Published var timestampMode: TimestampMode { didSet { d.set(timestampMode.rawValue, forKey: "timestampMode") } }

    // MARK: Ses (yalnız kulaklığa verilir; telefon hoparlöründen hiç konuşulmaz)
    /// Seçilen konuşma sesi (boş = telefonda kurulu en kaliteli Türkçe ses)
    @Published var speechVoiceID: String { didSet { d.set(speechVoiceID, forKey: "speechVoiceID") } }
    /// Okuma hızı çarpanı: 1 = varsayılan hız
    @Published var speechRate: Double { didSet { d.set(speechRate, forKey: "speechRate") } }
    /// İlk okumada cevaplar arasındaki bekleme (sn)
    @Published var answerPauseSeconds: Int { didSet { d.set(answerPauseSeconds, forKey: "answerPauseSeconds") } }
    /// Tekrar okumada cevaplar arasındaki bekleme (sn)
    @Published var repeatPauseSeconds: Int { didSet { d.set(repeatPauseSeconds, forKey: "repeatPauseSeconds") } }

    // MARK: Pil tasarrufu
    /// Canlı önizleme kapalı: ekrana video çizilmez, kare çözme/çekim/ses/kaydetme aynen sürer
    @Published var previewOff: Bool { didSet { d.set(previewOff, forKey: "previewOff") } }
    /// Program çalışırken ekran parlaklığını çok azalt (ekran pilin en büyük tüketicisidir)
    @Published var dimScreen: Bool { didSet { d.set(dimScreen, forKey: "dimScreen") } }

    /// Kayıtlı sayıyı izin verilen aralığa çeker (kayıt yoksa varsayılan)
    static func clamp(_ value: Int?, range: ClosedRange<Int>, fallback: Int) -> Int {
        return min(max(value ?? fallback, range.lowerBound), range.upperBound)
    }

    init() {
        uid = d.string(forKey: "uid") ?? AppSettings.defaultCameraUID
        cameraIP = d.string(forKey: "cameraIP") ?? ""
        cameraPassword = Keychain.get("cameraPassword") ?? "123456"
        streamQuality = d.object(forKey: "streamQuality") as? Int ?? 1
        // Kadraj yönü ile görüntü yönü uyumlu olmalı (bkz. orientation(_:forFrame:))
        let frameValue = d.object(forKey: "guidanceFrame") as? Int ?? AppSettings.defaultFrame
        let savedOrientation = ImageOrientation(rawValue: d.object(forKey: "imageOrientation") as? Int ?? 0) ?? .normal
        let orient = AppSettings.orientation(savedOrientation, forFrame: frameValue)
        d.set(orient.rawValue, forKey: "imageOrientation")
        imageOrientation = orient
        guidanceFrame = frameValue

        questionTotal = AppSettings.clamp(d.object(forKey: "questionTotal") as? Int, range: AppSettings.questionTotalRange, fallback: 0)
        optionCount = d.object(forKey: "optionCount") as? Int == 4 ? 4 : 5
        groupSize = AppSettings.clamp(d.object(forKey: "groupSize") as? Int, range: 1...3, fallback: 1)
        geminiInput = AppSettings.clamp(d.object(forKey: "geminiInput") as? Int, range: 0...2, fallback: 0)
        readyRepeatSeconds = AppSettings.clamp(d.object(forKey: "readyRepeatSeconds") as? Int, range: 10...300, fallback: 30)
        readyMaxMinutes = AppSettings.clamp(d.object(forKey: "readyMaxMinutes") as? Int, range: 1...120, fallback: 10)
        maxAttempts = AppSettings.clamp(d.object(forKey: "maxAttempts") as? Int, range: 0...50, fallback: 5)
        scanMaxMinutes = AppSettings.clamp(d.object(forKey: "scanMaxMinutes") as? Int, range: 2...240, fallback: 15)
        missingWaitSeconds = AppSettings.clamp(d.object(forKey: "missingWaitSeconds") as? Int, range: 10...600, fallback: 60)
        guidanceSharpness = AppSettings.clamp(d.object(forKey: "guidanceSharpness") as? Int, range: 0...2, fallback: 1)

        cameraShortcutName = d.string(forKey: "cameraShortcutName") ?? ""
        connectionShortcutName = d.string(forKey: "connectionShortcutName") ?? ""
        shortcutTries = AppSettings.clamp(d.object(forKey: "shortcutTries") as? Int, range: AppSettings.shortcutTriesRange, fallback: 30)
        shortcutWaitSeconds = AppSettings.clamp(d.object(forKey: "shortcutWaitSeconds") as? Int, range: AppSettings.shortcutWaitRange, fallback: 60)

        // Eski 6 profilli düzenden geçiş (kullanıcı kararı 2026-11-13: eski anahtarlar silinsin, yeniden girilecek):
        // Keychain'de düzen işareti yoksa eski anahtarlar silinir, profiller (ad/model/ücretsiz) yeni 4 yuvaya taşınır.
        // Güvenlik: işaret okunamasa bile (Keychain geçici hatası) kayıtlı profil sayısı zaten 4 ise yeni düzendir, anahtarlar silinmez.
        let savedProfiles = d.data(forKey: "geminiProfiles").flatMap { try? JSONDecoder().decode([GeminiProfile].self, from: $0) }
        let markerOK = Keychain.get(GeminiProfiles.layoutMarker) == GeminiProfiles.layoutVersion
        let legacyLayout = !markerOK && savedProfiles?.count != GeminiProfiles.slotCount
        if legacyLayout {
            for slot in 1...GeminiProfiles.legacySlotCount { Keychain.remove(GeminiProfiles.keychainName(slot: slot)) }
        }
        if !markerOK { Keychain.set(GeminiProfiles.layoutVersion, for: GeminiProfiles.layoutMarker) }
        geminiKeys = (1...GeminiProfiles.slotCount).map { Keychain.get(GeminiProfiles.keychainName(slot: $0)) ?? "" }
        if legacyLayout, let saved = savedProfiles {
            let list = GeminiProfiles.profiles(fromLegacy: saved)
            geminiProfiles = list
            d.set(try? JSONEncoder().encode(list), forKey: "geminiProfiles")
        } else if let saved = savedProfiles, saved.count >= 3 && saved.count <= GeminiProfiles.slotCount {
            // Boş kalmış profil modelleri varsayılanla dolar (anahtar girilene kadar etkisiz); kullanıcının yazdıkları korunur
            geminiProfiles = GeminiProfiles.migrated(saved)
        } else {
            geminiProfiles = GeminiProfiles.defaults()
        }
        let storedActive = d.object(forKey: "geminiActive") as? Int ?? 1
        let startActive = min(max(legacyLayout ? GeminiProfiles.newSlot(fromLegacy: storedActive) : storedActive, 1), GeminiProfiles.slotCount)
        geminiActive = startActive
        if legacyLayout { d.set(startActive, forKey: "geminiActive") }
        geminiWaitLimit = min(max(d.object(forKey: "geminiWaitLimit") as? Int ?? 30, 0), 600)
        let storedCodes = d.string(forKey: "geminiOptionCodes")
        geminiOptionCodes = storedCodes ?? GeminiConfig.defaultOptionCodes

        jpegQuality = d.object(forKey: "jpegQuality") as? Double ?? 0.92
        sharpenImages = d.object(forKey: "sharpenImages") as? Bool ?? true
        if let raw = d.string(forKey: "timestampMode"), let mode = TimestampMode(rawValue: raw) {
            timestampMode = mode
        } else {
            timestampMode = .blur
        }

        speechVoiceID = d.string(forKey: "speechVoiceID") ?? ""
        speechRate = d.object(forKey: "speechRate") as? Double ?? 1.0
        answerPauseSeconds = AppSettings.clamp(d.object(forKey: "answerPauseSeconds") as? Int, range: 0...60, fallback: 3)
        repeatPauseSeconds = AppSettings.clamp(d.object(forKey: "repeatPauseSeconds") as? Int, range: 0...60, fallback: 5)

        previewOff = d.object(forKey: "previewOff") as? Bool ?? false
        dimScreen = d.object(forKey: "dimScreen") as? Bool ?? false
    }
}

extension AppSettings {
    /// Dört profil (anahtarlarıyla)
    func geminiProfileInfos() -> [GeminiProfileInfo] {
        return geminiProfiles.enumerated().map { i, p in
            GeminiProfileInfo(slot: i + 1, name: p.name.trimmed.isEmpty ? "Model \(i + 1)" : p.name.trimmed,
                              model: p.model.trimmed, key: i < geminiKeys.count ? geminiKeys[i].trimmed : "", free: p.free)
        }
    }

    /// İlk denenecek profil (seçili boşsa ilk dolu profil)
    var activeGeminiProfile: GeminiProfileInfo {
        return GeminiProfiles.active(geminiProfileInfos(), active: geminiActive)
    }

    /// Kadraj yönünün varsayılanı: yatay (kullanıcı kararı 2026-11-13; daha önce dikeydi)
    static let defaultFrame = 0

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
}
