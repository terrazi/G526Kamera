import Foundation

/// Sürüm 4: bir sorunun kamera ile çekilmiş hâli (fotoğraf + kısa video). Kamera kapatıldıktan sonra Gemini'ye hücresel veriyle gönderilir.
struct CapturedQuestion: Equatable {
    var id = UUID()
    /// Soru sayfasının fotoğrafı (JPEG)
    var photo: Data
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

    /// Gemini'ye satır içi gönderilebilen fotoğraf + video toplamı (bayt). İstek sınırı 20 MB'tır ve veri base64 ile üçte bir şişer
    /// (14 MB → ~18,7 MB); metin ve talimat payı için de yer kalır. Video sığmazsa yalnız fotoğraf gider.
    static let maxInlineVideoBytes = 14_000_000

    /// Sorunun videosu gider mi: önce sorunun kendi fotoğrafı ve paragrafın fotoğrafı yer açar, sığarsa video eklenir (soru, paragraftan önceliklidir)
    var canSendVideo: Bool {
        return video != nil && videoBytes > 0
            && videoBytes + photo.count + (passageMedia?.photo.count ?? 0) <= CapturedQuestion.maxInlineVideoBytes
    }

    /// Paragrafın videosu gider mi: yalnız sorunun fotoğraf + videosundan sonra hâlâ yer kalıyorsa
    var canSendPassageVideo: Bool {
        guard let media = passageMedia, media.canHaveVideo else { return false }
        let used = photo.count + media.photo.count + (canSendVideo ? videoBytes : 0)
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
    var video: URL?
    var videoBytes: Int
    /// Aynı çekim mi (fotoğraf baytlarını karşılaştırmak yerine kimlik)
    var id: UUID

    init(_ shot: CapturedQuestion) {
        photo = shot.photo
        video = shot.video
        videoBytes = shot.videoBytes
        id = shot.id
    }

    var canHaveVideo: Bool { return video != nil && videoBytes > 0 }
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

/// Kamerayı açıp soruyu çeken bileşen. Gerçeği V1'in kamera altyapısıyla çalışır (`CameraCaptureController`), testler sahtesini kullanır.
@MainActor
protocol CameraCapturing: AnyObject {
    /// Konumlandırma cümleleri (kulaklıktan söylenir); çağıran söylemeye uygun değilse yutabilir
    var onSay: ((String) -> Void)? { get set }
    /// Ekranda görünen kısa durum satırı ("Kameraya bağlanılıyor", "Sayfa kadrajda"…)
    var onStatus: ((String) -> Void)? { get set }
    /// Neyin çekildiği: konumlandırma cümleleri buna göre söylenir ("Soruyu kadraja alın" / "Paragrafı kadraja alın"). Her çekimden önce ayarlanır.
    var subject: CaptureSubject { get set }
    /// Kamerayı açar, bağlanır, sesle konumlandırır, soruyu videoya ve fotoğrafa alır ve BİTİNCE kamerayı kapatır (başarısız da olsa).
    func capture() async -> Result<CapturedQuestion, CameraFailure>
    /// Süren çekimi iptal eder (kamera kapanır)
    func cancel()
    /// Kameranın son görüntü karelerinden okunan pil durumu (kamera kapandıktan sonra da son bilinen değer kalır); hiç okunmadıysa nil
    var lastBattery: CameraBatteryLevel? { get }
}

extension CameraCapturing {
    var lastBattery: CameraBatteryLevel? { return nil }
}

/// Kamera yapılandırılmamış oturumlar (ve eski testler) için
@MainActor
final class NoCamera: CameraCapturing {
    var onSay: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    var subject: CaptureSubject = .question
    func capture() async -> Result<CapturedQuestion, CameraFailure> { return .failure(.unavailable) }
    func cancel() {}
}
