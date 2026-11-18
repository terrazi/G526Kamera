import Foundation

/// Sürüm 4: bir sorunun kamera ile çekilmiş hâli (fotoğraf + kısa video). Kamera kapatıldıktan sonra Gemini'ye hücresel veriyle gönderilir.
struct CapturedQuestion: Equatable {
    var id = UUID()
    /// Soru sayfasının fotoğrafı (JPEG)
    var photo: Data
    /// Çekim süresince saniyede bir alınan fotoğrafların (en net kareler) tek PDF'i; Gemini'ye fotoğraf yerine bu gider. Yoksa (PDF kurulamadı,
    /// eski çekim) `photo` gider.
    var pdf: Data?
    /// PDF'teki sayfa (fotoğraf) sayısı
    var pageCount = 0
    /// Aynı sayfanın kısa videosu (H.264 MP4); yoksa nil
    var video: URL?
    /// Video dosyasının boyutu (bayt)
    var videoBytes: Int = 0
    /// Videonun kaydedilen süresi (sn)
    var videoSeconds: Double = 0
    var date: Date = Date()
    /// Kullanıcının Ayarlar'da yazdığı ek talimat (boş olabilir)
    var extraInstruction: String = ""
    /// Videoyu yüksek çözünürlükle oku (küçük yazı)
    var highResolution = true
    /// Sesle kaydedilmiş ortak paragraf varsa gönderim sırasında eklenen not (çekim telefonda beklerken paragraf değişebilir, o yüzden
    /// çekimle birlikte saklanmaz; her gönderimde yeniden yazılır)
    var passageNote = ""
    /// Kamerayla çekilmiş ortak paragraf varsa gönderim sırasında eklenen görüntüleri (aynı gerekçeyle çekimle birlikte saklanmaz)
    var passageMedia: PassageMedia?
    /// Çekim telefondaki kalıcı klasöre yazıldı (`CaptureStoring`): video dosyası orada durur ve kullanıcı silene kadar SİLİNMEZ
    var archived = false
    /// Toplu sayfa çekiminin bir sayfası: sayfadaki BÜTÜN sorular cevaplanır (tek soru değil); Gemini'ye sayfa komutuyla gider
    var isPage = false
    /// Çekimde telefonun yazı tanımasının gördüğü soru numaraları (artan): cevaplar okunduktan sonra görünüp cevaplanamayanlar söylenir
    var seenNumbers: [Int] = []
    /// Ritimli toplu çekimde PDF'in her sayfasının etiketi ("2. sayfa, orta üst"), PDF sırasıyla; ritimsiz çekimde boş. Gemini'ye giden istemde sayılır:
    /// hangi görüntünün kitapçık sayfasının tamamı, hangisinin hangi parçası olduğu bilinsin, parçalar doğru birleşsin
    var rhythmLabels: [String] = []

    /// Gemini'ye satır içi gönderilebilen fotoğraf + video toplamı (bayt). İstek sınırı 20 MB'tır ve veri base64 ile üçte bir şişer
    /// (14 MB → ~18,7 MB); metin ve talimat payı için de yer kalır. Video sığmazsa yalnız fotoğraf gider.
    static let maxInlineVideoBytes = 14_000_000

    /// Gemini'ye giden görüntü verisinin boyutu: PDF varsa o, yoksa tek fotoğraf
    var visualBytes: Int { return pdf?.count ?? photo.count }

    /// Sorunun videosu gider mi: önce sorunun kendi görüntüsü (PDF ya da fotoğraf) ve paragrafın görüntüsü yer açar, sığarsa video eklenir (soru, paragraftan önceliklidir)
    var canSendVideo: Bool {
        return video != nil && videoBytes > 0
            && videoBytes + visualBytes + (passageMedia?.visualBytes ?? 0) <= CapturedQuestion.maxInlineVideoBytes
    }

    /// Paragrafın videosu gider mi: yalnız sorunun fotoğraf + videosundan sonra hâlâ yer kalıyorsa
    var canSendPassageVideo: Bool {
        guard let media = passageMedia, media.canHaveVideo else { return false }
        let used = visualBytes + media.visualBytes + (canSendVideo ? videoBytes : 0)
        return used + media.videoBytes <= CapturedQuestion.maxInlineVideoBytes
    }

    /// İstekte kare hızı ayarı (videoMetadata.fps) taşıyan bir video gidiyor mu: sorunun ya da paragrafın. Model bu ayarı reddederse
    /// (400) istek ayarsız yeniden denenir.
    var sendsFrameRate: Bool { return canSendVideo || canSendPassageVideo }

    /// Aynı çekim mi (fotoğraf baytlarını karşılaştırmak yerine kimlik)
    static func == (a: CapturedQuestion, b: CapturedQuestion) -> Bool { return a.id == b.id }

    /// Gönderim bitti ya da vazgeçildi: telefonda tutulan GEÇİCİ video dosyası silinir. Kalıcı klasöre yazılmış çekime dokunulmaz
    /// (kullanıcı silene kadar durur).
    func discard() {
        guard !archived, let url = video else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// Kamerayla çekilmiş ortak paragrafın Gemini'ye giden görüntüleri (fotoğraf + kısa video)
struct PassageMedia: Equatable {
    var photo: Data
    /// Paragraf çekiminin PDF'i (varsa fotoğraf yerine o gider)
    var pdf: Data?
    var video: URL?
    var videoBytes: Int
    /// Aynı çekim mi (fotoğraf baytlarını karşılaştırmak yerine kimlik)
    var id: UUID

    init(_ shot: CapturedQuestion) {
        photo = shot.photo
        pdf = shot.pdf
        video = shot.video
        videoBytes = shot.videoBytes
        id = shot.id
    }

    var canHaveVideo: Bool { return video != nil && videoBytes > 0 }
    var visualBytes: Int { return pdf?.count ?? photo.count }
}

/// Kamera çekimi neden olmadı
enum CameraFailure: Error, Equatable {
    /// Kameraya bağlanılamadı (kamera kapalı, Wi-Fi'ye geçilemedi, parola yanlış…)
    case notConnected
    /// Bağlandı ama görüntü gelmedi / çözülemedi
    case noFrames
    /// Sayfa süre içinde konumlandırılamadı
    case noPosition
    /// Telefonda boş yer çok az
    case lowDisk
    /// Çekim işlenemedi
    case captureFailed(String)
    /// Kullanıcı ya da program iptal etti
    case cancelled
    /// Bu sürümde kamera yok (test / yapılandırılmamış)
    case unavailable

    var message: String {
        switch self {
        case .notConnected: return "Kameraya bağlanılamadı."
        case .noFrames: return "Kameradan görüntü gelmedi."
        case .noPosition: return "Sayfa kadraja alınamadı."
        case .lowDisk: return "Telefonda boş yer çok az."
        case .captureFailed(let why): return why.isEmpty ? "Çekim yapılamadı." : "Çekim yapılamadı: \(why)"
        case .cancelled: return "Çekim iptal edildi."
        case .unavailable: return "Kamera kullanılamıyor."
        }
    }
}

/// Çekilen şey: tek bir soru ya da birkaç soruya ortak paragraf
enum CaptureSubject: Equatable {
    case question
    case passage
}

/// Toplu çekimin sonucu: bütün oturumun fotoğrafları TEK PDF'tir (`shot`, `pageCount` = alınan fotoğraf sayısı); `failure` doluysa oturum yarıda
/// kesilmiştir (planlanan fotoğrafların yalnız bir kısmı alındı)
struct PageSeries: Equatable {
    var shot: CapturedQuestion
    /// Planlanan fotoğraf sayısı: oturum tam bittiyse seçilen (PDF'e giren) fotoğraf sayısı, görüntü akışı kesildiyse oturumun süresi (sn)
    var planned: Int
    var failure: CameraFailure?
    /// Seçilen karelerde okunan yazı var mı. false: telefonun yazı tanıması hiçbir karede yazı okuyamadı (küçük, eğik, bulanık yazı); en net kareler yine de
    /// Gemini'ye gider (o daha iyi okur), kullanıcıya bu söylenir
    var readable = true
    /// Çekimin teşhisi (bulanık / çok yakın / yazı yok / numara boşluğu); sorun yoksa söyleyecek bir şey çıkmaz
    var diagnosis: CaptureDiagnosis?
    /// Deneme çekiminin raporu (rapor.txt); gerçek çekimde boş
    var report = ""
}

/// Kamerayı açıp soruyu çeken bileşen. Gerçeği `CameraCaptureController` ile çalışır, testler sahtesini kullanır.
@MainActor
protocol CameraCapturing: AnyObject {
    /// Konumlandırma cümleleri (kulaklıktan söylenir); çağıran söylemeye uygun değilse yutabilir
    var onSay: ((String) -> Void)? { get set }
    /// Ekranda görünen kısa durum satırı ("Kameraya bağlanılıyor", "Sayfa kadrajda"…)
    var onStatus: ((String) -> Void)? { get set }
    /// Sıralı söylenecek cümle (çekim öncesi duyuru): önceki cümle bitince söylenir ve BU cümle bitince döner. `onSay` gibi atlanmaz.
    /// Atanmamışsa (testler, kamera yok) duyuru `onSay` ile söylenir ve beklenmez.
    var onSayWait: ((String) async -> Void)? { get set }
    /// Neyin çekildiği: konumlandırma cümleleri buna göre söylenir ("Soruyu kadraja alın" / "Paragrafı kadraja alın"). Her çekimden önce ayarlanır.
    var subject: CaptureSubject { get set }
    /// Kamerayı açar, bağlanır, sesle konumlandırır, soruyu videoya ve fotoğrafa alır ve BİTİNCE kamerayı kapatır (başarısız da olsa).
    func capture() async -> Result<CapturedQuestion, CameraFailure>
    /// Aynı çekim; kameraya bağlanma beklemesi `connectLimit` sn ile sınırlanır (nil: varsayılan süre). "Wi-Fi'de kal" kipinde telefon zaten kameranın
    /// ağındadır: bağlanamıyorsa uzun beklenmez, onarım kestirmesine geçilir.
    func capture(connectLimit: TimeInterval?) async -> Result<CapturedQuestion, CameraFailure>
    /// Toplu çekim: kameraya bağlanır, `seconds` sn aralıksız çeker (her saniyenin en net karesi), konuşmaz ve konumlandırma yapmaz, bitince
    /// kamerayı kapatır. Tek sınır süredir (sayfa sayısı yok); bütün fotoğraflar TEK PDF olur. Bağlanamazsa `.failure`; bağlanıp bir kısım fotoğraf
    /// alındıktan sonra kesilirse `.success` ve `failure` dolu döner (alınanlar kaybolmaz).
    func captureSeries(seconds: Int, connectLimit: TimeInterval?) async -> Result<PageSeries, CameraFailure>
    /// Deneme çekimi (kullanıcı kararı 2026-11-17): toplu çekimle AYNI yoldan `seconds` sn çeker ama ayrıca video kaydeder; sonuç Gemini'ye GÖNDERİLMEZ,
    /// çağıran klasöre yazar. Bitince kamera kapanır. `PageSeries.shot.video` videodur, `report` rapordur.
    func captureTrial(seconds: Int, connectLimit: TimeInterval?) async -> Result<PageSeries, CameraFailure>
    /// Kadraj kontrolü: hazır bekleyen (canlı) kamerada kısa süre taze kareler toplanır, en netinin yazısı okunur. Çekim yapılmaz, bağlantı açık kalır.
    /// Kamera hazır değilse nil.
    func checkView() async -> ViewCheck?
    /// Son oturumun akış ölçümü özeti ("akış 1: 1920×1080, 9.0 kare/sn, 2100 kbit/sn …"); yeterli kare gelmediyse nil. Kamera kapanınca yazılır.
    var lastStreamSummary: String? { get }
    /// Akış denemesi (kullanıcı kararı 2026-11-17): 1, 2 ve 3 numaralı akışlar sırayla açılır, her birinin gerçek boyutu / kare hızı / bitrate'i ölçülür ve
    /// kameranın YALNIZ OKUMA bilgi komutları (pozlama dahil) sorgulanır. Çekim yapılmaz, hiçbir ayar değiştirilmez. Sonuç satırlarını döndürür.
    func surveyStreams() async -> [String]
    /// Süren çekimi (ya da açık tutulan bağlantıyı) iptal eder (kamera kapanır)
    func cancel()
    /// Sürüm 4: oturum başlarken kameraya hemen bağlanır; görüntü gelince döner ve bağlantıyı AÇIK bırakır (ana ekrandaki kutuda görüntü akar).
    /// Konumlandırma söylenmez, hiçbir şey çekilmez. `closeHeld()` kapatır; ilk hücresel bağlantıdan önce çağrılır.
    /// `connectLimit`: kameraya bağlanma beklemesi bu kadar sn ile sınırlanır (nil: varsayılan süre). "Kameraya geç" kestirmesi telefonu kameranın
    /// ağına bazen sokamaz (günlükte 40 sn boşuna beklendi); ilk denemede kısa beklenip onarım kestirmesine geçilir.
    func holdOpen(connectLimit: TimeInterval?) async -> Result<Void, CameraFailure>
    /// `holdOpen()` ile açık tutulan bağlantıyı kapatır (hiç açık değilse bir şey yapmaz)
    func closeHeld()
    /// Bağlantı `holdOpen()` ile açık tutuluyor mu (toplu çekimde "Başla"yı bekleyen hazır kamera)
    var holding: Bool { get }
    /// Hazır bekleyen bağlantı açık VE görüntü geliyor mu (kopmuş bağlantı "hazır" sayılmaz)
    var holdingLive: Bool { get }
    /// Telefonun Wi-Fi'sinde IPv4 adresi var mı (bir ağa girilmiş mi). Kameraya geç kestirmesinden sonra telefon kameranın ağına girmeli;
    /// iPhone ağı kendisi seçer ve bazen seçmez (kamera ağında internet yok): adres yoksa beklenmeden Wi-Fi onarımına geçilir
    var phoneHasWiFiAddress: Bool { get }
    /// Kameraya ulaşılabiliyor mu: bağlanır, görüntü gelirse doğru döner. Konumlandırma söylenmez, hiçbir şey çekilmez; kamera hemen kapanır.
    func probe() async -> Bool
    /// Kameranın son görüntü karelerinden okunan pil durumu (kamera kapandıktan sonra da son bilinen değer kalır); hiç okunmadıysa nil
    var lastBattery: CameraBatteryLevel? { get }
}

extension CameraCapturing {
    func capture(connectLimit: TimeInterval?) async -> Result<CapturedQuestion, CameraFailure> { return await capture() }
    var lastBattery: CameraBatteryLevel? { return nil }
    func holdOpen(connectLimit: TimeInterval?) async -> Result<Void, CameraFailure> { return .failure(.unavailable) }
    func holdOpen() async -> Result<Void, CameraFailure> { return await holdOpen(connectLimit: nil) }
    func closeHeld() {}
    var holding: Bool { return false }
    var holdingLive: Bool { return holding }
    var phoneHasWiFiAddress: Bool { return true }
    func probe() async -> Bool { return false }
    func captureSeries(seconds: Int, connectLimit: TimeInterval?) async -> Result<PageSeries, CameraFailure> { return .failure(.unavailable) }
    func captureTrial(seconds: Int, connectLimit: TimeInterval?) async -> Result<PageSeries, CameraFailure> { return .failure(.unavailable) }
    func checkView() async -> ViewCheck? { return nil }
    var lastStreamSummary: String? { return nil }
    func surveyStreams() async -> [String] { return ["Kamera yok: akış denenemedi."] }
}

/// Kamera yapılandırılmamış oturumlar (ve eski testler) için
@MainActor
final class NoCamera: CameraCapturing {
    var onSayWait: ((String) async -> Void)?
    var onSay: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    var subject: CaptureSubject = .question
    func capture() async -> Result<CapturedQuestion, CameraFailure> { return .failure(.unavailable) }
    func cancel() {}
}
