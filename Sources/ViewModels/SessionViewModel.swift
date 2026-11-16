import Foundation
import Combine
import UIKit

/// Oturumun beyni (MVVM'deki ViewModel). Durum makinesi: kontrol → dinle → Gemini → seslendir → dinle … ;
/// donanım koparsa duraklat (fail-safe), bağlantı koparsa Kestirmelerle onar. Dış dünya SessionDependencies üzerinden gelir.
///
/// Dosyalar: bu dosya yaşam döngüsü, dinleme ve cevaplama; +Checkup açılış kontrolü; +Recovery fail-safe, sessizlik, ağ ve onarım;
/// +Replay test sonu tekrar.
@MainActor
final class SessionViewModel: ObservableObject {
    enum Timing {
        /// Tetikleyici sözcük bu kadar değişmeden kalırsa gerçekten söylenmiş sayılır ("gönder" → "gönderi" yanlış alarmını önler)
        static let triggerConfirm: TimeInterval = 0.5
        /// Ağ bu kadar süre kesik kalırsa onarım başlar. Onarım önce bağlantıyı sınar, sağlamsa Kestirme çalıştırmaz; bu yüzden kısa tutulur.
        static let offlineDebounce: TimeInterval = 1
        /// Kulaklık/mikrofon bu kadar süre dönmezse sıfırlama kestirmesi çalışır
        static let hardwareGrace: TimeInterval = 20
        /// Mikrofon eksikken (duraklatılmış) yönlendirme her bu kadar kontrolde (`hardwareGrace` aralıklı, yani yaklaşık dakikada bir) yeniden
        /// söylenir: kullanıcı dakikalarca sessizlikte kalmaz
        static let pausedGuidanceEvery = 3
        /// Donanım geri geldikten sonra bu kadar süre sabit kalırsa devam edilir
        static let routeStable: TimeInterval = 1
        /// Yarım okuma kesilince (kesinti sonrası) devam ettirmek için eldeki metnin en az sözcük sayısı
        static let partialMinWords = 4
        /// Numara istenince söylenen numara bu kadar sn sabit kalırsa soru gönderilir; numara hiç söylenmezse en çok bu kadar kez hatırlatılır
        static let numberConfirm: TimeInterval = 1.5
        static let numberReminderLimit = 2
        /// Numara beklenirken anlaşılmayan kısa bir söz bu süre değişmezse numara yeniden sorulur (30 sn beklenmez)
        static let numberUnclear: TimeInterval = 4
        /// Paragrafın soru numaraları bu kadar kez anlaşılamazsa paragraf yalnız sıradaki soruya bağlanır
        static let targetReminderLimit = 2
        /// Konuşmada bu kadar sessizlik olursa sonraki söz yeni bir sözdür (komut yalnız son sözden aranır; eski anlaşılmayan söz engel olmaz)
        static let utteranceGap: TimeInterval = 1
        /// Komut gibi duyulan ama anlaşılmayan söz bu süre değişmezse "anlayamadım" denir
        static let attemptConfirm: TimeInterval = 2.5
        /// Soru metni geldikten sonra bu süre hiçbir şey söylenmezse ve "Cevapla" duyulmadıysa hatırlatılır; bir soruda en çok bu kadar kez
        static let questionIdle: TimeInterval = 20
        static let idleReminderLimit = 2
        /// Paragraf numaraları söylendikten sonra bu süre "Tamam" duyulmazsa program kendisi sorar
        static let targetsIdle: TimeInterval = 4
        /// Cevap beklerken "cevap bekleniyor" anonsu bu aralıkla (sn) söylenir; bu süre dolarsa (sn) bekleme bırakılır
        static let answerCueEvery: TimeInterval = 15
        static let answerCap: TimeInterval = 180
        /// Sessizlikte dinlemeyi yenileyip sağlığa bakmadan önce beklenen süre
        static let silenceProbe: TimeInterval = 4
        /// Bağlantı onarılamazsa yeniden deneme aralığı
        static let connectionRetry: TimeInterval = 60
        /// Üst üste bu kadar donanım onarımı arada tek kelime tanınmadan yapıldıysa sıfırlama döngüsü kesilir
        static let maxHardwareRecoveries = 3
        /// Döngü kesilince bir sonraki deneme için bekleme
        static let hardwareCapRetry: TimeInterval = 60
        /// Cevap okunamayınca ikinci okuma denemesinden önceki kısa bekleme (sn)
        static let speakRetryDelay: TimeInterval = 1
        /// Kesinti sürerken (arama vb.) ses oturumunun yeniden açılıp açılamadığına bakma aralığı; bitiş bildirimi gelmezse yedek
        static let interruptionPoll: TimeInterval = 15
        /// Aynı uyarı cümlesi bu süre içinde kulaklıktan yeniden söylenmez (yol dalgalanınca konuşma yağmuru olmasın)
        static let announceRepeat: TimeInterval = 300
        /// Bu kadar saniyedir bekleyen uyarı eskimiştir, söylenmez
        static let announceMaxAge: TimeInterval = 180
        /// Aynı anda bekleyebilecek sesli uyarı sayısı
        static let maxQueuedAnnouncements = 6
        /// Art arda kaç denemede yol düzelmezse "çıkışı kulaklığa al" kestirmesinin bırakılıp eski onarım sırasına dönüleceği
        /// (yol her düzelişte sayaç sıfırlanır; çözmeyen kestirme sonsuz döngü olmasın)
        static let maxOutputTries = 6
        /// Kulaklık yoldan çıkınca "çıkışı kulaklığa al" kestirmesinin ilk kez çalıştırılacağı süre (yol bildirimleri otursun diye kısa bir bekleme;
        /// 20 sn'lik donanım beklemesini beklemez)
        static let outputQuickDelay: TimeInterval = 1
        /// Anında tespit (nabız): aralık, mikrofonun "takıldı" sayılacağı sessiz tampon süresi ve dinleme başlayınca beklenen nabız sayısı
        static let sentinelTick: TimeInterval = 0.5
        static let micStallLimit: TimeInterval = 1.2
        static let micWarmupTicks = 4
        /// Mikrofon art arda bu kadar yeniden kurulduysa Kestirmeler çalışır; bu kadar nabız sağlıklıysa sayaç sıfırlanır
        static let maxMicHeals = 3
        static let micHealthyTicks = 10
        /// İnternet yoklaması her bu kadar nabızda bir (dinlerken); bağlantı yokken (duraklatılmış) daha sık
        static let netBeatEvery = 10
        static let netPausedBeatEvery = 4
        /// Yoklama başarısızsa bir sonrakine kalan nabız sayısı ve art arda kaç başarısız yoklamada onarım başlayacağı
        static let netRetryTicks = 2
        static let netFailLimit = 2
        /// Ses servisi sıfırlanınca ses oturumunun yeniden kurulmasına kadar bekleme
        static let mediaHealDelay: TimeInterval = 0.3
        /// Bu süreden kısa kesintiden sonra kısa "Hazır" anonsu
        static let briefOutage: TimeInterval = 8
        /// Konuşma tanıma onarımı: dinlemenin gerçekten çalıştığı kanıtlanırken yoklama aralığı, en az ve en çok yoklama sayısı
        /// (ilk yoklamalarda görev hemen düşüyorsa kanıtlanmış sayılmaz), bir onarımdaki tur sayısı ve açılamıyorsa yeniden deneme aralığı
        static let proofPoll: TimeInterval = 0.5
        static let proofMinPolls = 5
        static let proofMaxPolls = 14
        static let recognizerRounds = 3
        static let recognizerRetry: TimeInterval = 15
        /// Sistem sağlığı: iOS'un kapatma eşiğine bu kadar bellek (MB) kalınca yük azaltılır, bu kadar toparlanınca geri açılır
        static let lowMemoryMB = 250
        static let memoryOKMB = 400
        /// Boş yer bu kadar MB'ın altına inince uyarılır (ses kayıtları yazılamayabilir)
        static let lowDiskMB = 200
        /// Çıkış ses seviyesi bunun altındaysa (yüzde 10; iPhone'da en alttan ikinci adım) cevaplar duyulmayabilir: uyarılır
        static let lowVolume: Float = 0.10
        /// Sesle ses ayarı: bir "aç / kıs" adımı (iPhone'da iki ses adımı), izin verilen en düşük düzey (yüzde 15: duyulur kalsın) ve ayardan sonra
        /// seviyenin yeniden okunmasından önce beklenen süre
        static let volumeStep: Float = 0.125
        static let minVolume: Float = 0.15
        static let volumeSettle: TimeInterval = 0.5
        /// Kaynak durumu her bu kadar nabızda bir (60 sn) günlüğe yazılıp denetlenir
        static let systemEveryTicks = 120
        /// Nabız bu kadar saniyeden geç gelirse günlüğe yazılır (ana iş parçacığı takıldı ya da uygulama askıya alındı)
        static let tickLateLog: TimeInterval = 3
        /// Uygulamanın yaşadığı her bu kadar nabızda bir deftere işlenir (5 sn)
        static let heartbeatEveryTicks = 10
        /// Kamera akışı sürerken "cevap hazırlanıyor" aşamasının takılma sınırına eklenen süre (sn)
        static let cameraStuckExtra: TimeInterval = 600
        /// Beklenmedik kapanma: bu süre (sn) içinde bu kadar kez olursa otomatik başlatma durdurulur (açılış döngüsü)
        static let loopWindow: TimeInterval = 120
        static let loopLimit = 3
        /// Önceki kayıt bu süreden (12 saat) eskiyse sesli soruya cevap gelmezse "yeni sınav" sayılır (eski cevapların üzerine yazılmasın)
        static let rememberWindow: TimeInterval = 12 * 3600
        /// Evet/hayır ve menü soruları ("devam mı, yeni mi", testi bitirme onayı, cevap menüsü, yeni bölüm…) cevapsız ya da anlaşılmaz kalırsa
        /// en çok bu kadar yeniden sorulur ("ikinci defa soruyorum", "üçüncü defa soruyorum"); üçüncüde de cevap gelmezse varsayılan uygulanır
        static let choiceReminderLimit = 2
        /// Sürüm 4: internete dönüşte beklenen en uzun süre (sn) ve Gemini gönderiminde ağ hatasından sonra deneme sayısı
        static let cameraInternetWait: TimeInterval = 30
        static let cameraInternetTries = 2
        static let cameraSendTries = 2
        /// Kameraya bağlanılamazsa kamera bağlantısı onarımının (Wi-Fi adımı) en çok kaç kez çalışıp çekimin yeniden deneneceği
        static let cameraRepairs = 4   // ilk deneme + 4 onarım = 5 deneme; sonra sesle devam edilir ve kamera yoklanır
        /// Bu kadar deneme sonuçsuz kalınca BİR kez bağlantı sıfırlama kestirmesi (uçak modu aç/kapa) çalışır, sonra "Kameraya Geç" ile yeniden denenir
        /// (kullanıcı önerisi 2026-11-16: kamera bağlantısı Wi-Fi onarımıyla düzelmiyorsa telsizleri baştan kur)
        static let cameraResetAfter = 2
        /// Sıfırlamadan sonra Bluetooth kulaklığın dönmesi için en çok beklenecek süre (sn): uçak modu kulaklığı da düşürür (günlükte ≈ 25 sn)
        static let cameraResetHeadsetWait: TimeInterval = 45
        /// Toplu çekim oturumundan sonra kulaklığın (Bluetooth) geri gelmesi için en çok beklenecek süre (sn); oturum boyunca ses yolu değişikliği duraklatma sayılmaz
        static let seriesHeadsetWait: TimeInterval = 60
        /// Oturum başında kameraya bağlanırken en çok kaç onarım yapılacağı (ilk deneme + 2 onarım = 3 deneme); olmazsa sesle devam edilir ve kamera yoklanır
        static let cameraStartRepairs = 2
        /// Oturum başında ilk bağlanma denemesinde en çok beklenen süre (sn): "Kameraya geç" telefonu kameranın ağına sokamadıysa 40 sn beklenmez,
        /// onarım kestirmesine geçilir (onarımdan sonrakilerde varsayılan süre)
        static let cameraStartFirstConnect: TimeInterval = 15
        /// Kamera bağlandıktan sonra görüntü ekranda en az bu kadar sn daha akar (anons bittikten sonra), sonra bağlantı kapanır
        static let cameraStartShow: TimeInterval = 3
        /// "Wi-Fi'de kal" kipi: telefon zaten kameranın ağındadır; ilk denemede kameraya bağlanmak için en çok beklenecek süre (sn). Bağlanamazsa onarım kestirmesi çalışır
        static let stayConnectSeconds: TimeInterval = 15
        /// "Wi-Fi'de kal" kipi: çekimden sonra internetin varlığına bakılan süre (sn). İnternet varsa hiçbir kestirme çalışmaz
        static let stayInternetCheck: TimeInterval = 6
        /// Kameraya ulaşılamıyorken yoklama aralığı (sn) ve yoklama için uygun an yoksa yeniden bakma aralığı
        static let cameraProbeEvery: TimeInterval = 300
        static let cameraProbeRetry: TimeInterval = 20
        /// Kestirmeler uygulamasının geçici ret hatasında ("Çalma Hedefi aygıt bulunamadı") aynı kestirmenin en çok kaç kez, kaç sn arayla yeniden çalıştırılacağı
        static let shortcutTransientRetries = 2
        /// "Bu soruyu kamera ile çekmek ister misiniz?" en çok bu kadar sorulur; cevap gelmezse (ya da anlaşılmazsa) sonuncudan sonra kameraya kendiliğinden geçilir
        static let cameraAsks = 3
        static let shortcutTransientPause: TimeInterval = 2.5
        /// Kamera çekimi gönderilirken cevap beklemeye eklenen süre (sn). Telefonda bekleyen çekim sayısına SINIR YOK: çekimler silinmez.
        static let cameraExtraWait: TimeInterval = 180
        /// Bekleyen bir çekim, internet çalışırken bile bu kadar kez gönderilemezse (hep hata ya da zaman aşımı) o test için beklemeye alınır:
        /// her soru sınırında yeniden denemek sınavı yavaşlatırdı. Çekim SİLİNMEZ; klasörde durur ve sonraki testte yeniden denenir.
        static let pendingSendAttempts = 3
        /// "Programı kapat" düğmesi: basılı tutma süresi (sn) ve günlüğün/panonun yazılması için kapanıştan önceki kısa bekleme
        static let closeHold: TimeInterval = 3
        static let closeDelay: TimeInterval = 0.4

        /// Bir aşama bu süreden (sn) uzun hiç değişmezse takıldığı varsayılır (nil: o aşama sınırsız bekleyebilir, örn. dinleme ve duraklatmalar).
        /// Sınırlar, aşamanın kendi en uzun meşru süresinin üstündedir (örn. Gemini zincirinin en kötü sessiz bekleyişi ~10 dk).
        /// `camera`: Sürüm 4 kamera akışı sürüyor. Akış "cevap hazırlanıyor" aşamasında geçer: kestirmeler (30 sn ×2 ×3 deneme), kameraya bağlanma
        /// (40 sn) ve konumlandırma (30 sn) Gemini bekleyişinin önüne eklenir; bu süre ayrıca tanınır (en kötü durum ~450 sn).
        static func stuckLimit(for phase: SessionPhase, camera: Bool = false) -> TimeInterval? {
            switch phase {
            case .checking: return 240 + (camera ? cameraStuckExtra : 0)   // açılışta kameraya bağlanma (kestirmeler + 3 deneme) bu sınırı aşabilir
            case .answering: return 660 + (camera ? cameraStuckExtra : 0)
            case .speaking: return 180
            case .recovering: return 360
            default: return nil
            }
        }
    }

    // MARK: Ekranın gördüğü durum

    @Published var phase: SessionPhase = .idle {
        didSet {
            if phase != oldValue {
                tlog("[oturum] \(phase.title)")
                trackInterruption(from: oldValue)
                if case .paused(.hardware) = phase {} else { pausedGuidanceTicks = 0 }
                let open = SessionViewModel.countsAsSession(phase)
                if open != SessionViewModel.countsAsSession(oldValue) {
                    // Oturumun açık olduğu deftere ve günlüğe işlenir: uygulama bu arada kapanırsa sonraki açılış bunu görür
                    deps.journal.setSessionOpen(open)
                    tlog(open ? ExitAnalyzer.startedMark : "\(ExitAnalyzer.endedMark): \(phase.title)")
                    if !open {
                        // Oturum kapandı: bir sonraki başlatma eski bir kapanmanın "devamı" sayılmasın (kendiliğinden başlayan oturum
                        // kontrolde takılıp bittiyse "kaldığınız yerden sürüyorum" demesin, eski yarım iş yeniden sorulmasın)
                        resume = nil
                        deps.journal.savePending(nil)
                        deps.journal.savePassage(nil)
                    }
                }
                drainAnnouncementsIfQuiet()
            }
        }
    }
    /// Dikte edilen (ve kırpılmış) soru metni
    @Published var liveText = ""
    @Published var answers: [AnswerRecord] = []
    /// Yüklenen sorular ve her birinin Gemini'ye gidiş durumu (ana ekrandaki tek liste; yükleme sırasıyla)
    @Published var questions: [QuestionEntry] = []
    /// "Sesi dene" sonucu ve çalışıyor mu
    @Published var soundTest = ""
    /// Kameranın son çektiği sayfanın küçük resmi ve bilgisi (ana ekranda "Son fotoğraf"); fotoğraf okunamazsa değişmez
    @Published var lastShot: UIImage?
    @Published var lastShotInfo = ""
    @Published var testingSound = false
    @Published var warnings: [SessionWarning] = []
    @Published var checkup: [CheckItem] = []
    @Published var statusNote = ""
    @Published var canReplay = false
    /// Seçilebilir harici mikrofonlar (ana ekrandaki mikrofon listesi)
    @Published var inputs: [InputChoice] = []
    @Published var routeVerdict: RouteVerdict?
    /// Şu anki ses yolu, ana ekranda küçük yazıyla ("Çıkış: Bluetooth kulaklık. Giriş: Lightning/USB mikrofon.")
    @Published var routeText = ""
    /// "Canlı: Kulaklık ✓ · Mikrofon ✓ · İnternet ✓" (anında tespit açıksa)
    @Published var liveStatus = ""
    /// Okunmakta olan sorunun İngilizce tanıyıcıdan çıkan hâli (ana ekranda küçük yazıyla)
    @Published var liveEnglish = ""
    /// Mikrofonun şu an ne için açık olduğu (soru, ortak paragraf, paragrafın soru numaraları, eksik soru numarası)
    @Published var listenMode: ListenMode = .question
    /// Kayıtlı ortak paragraf (ait olduğu sorular cevaplanınca bırakılır)
    @Published var passage: PassageContext? {
        didSet {
            guard passage != oldValue else { return }
            // Uygulama beklenmedik kapanırsa paragraf (yazı olarak; kamerayla çekildiyse fotoğraf olarak) defterde durur ve yeniden açılışta geri yüklenir
            deps.journal.savePassage(passage.map { SavedPassage(text: $0.text, english: $0.english, all: $0.all, remaining: $0.remaining, photo: $0.shot?.photo) })
            releasePassageShot(oldValue?.shot)
        }
    }

    // MARK: Bağımlılıklar

    let settings: AppSettings
    let deps: SessionDependencies
    let watchdog: SilenceWatchdog
    let recovery: RecoveryCoordinator
    let replay: ReplayController

    // MARK: İç durum (uzantı dosyaları da kullanır)

    var accumulator = TranscriptAccumulator()
    /// Yardımcı İngilizce tanıyıcının metni (tetikleyici aramasında kullanılmaz; Gemini'ye ikinci metin olarak gider)
    var englishAccumulator = TranscriptAccumulator()
    var sessionFolder: URL?
    /// Sınavın üst klasörü (adı: tarih ve saat). Bölümlü sınavda cevaplar bunun içindeki bölüm klasörüne (`sessionFolder`) yazılır; bölümsüzde ikisi aynıdır.
    var examFolder: URL?
    /// Oturum başında ayarlardan alınan etkin bölümlerin soru sayıları (0: girilmemiş); boşsa sınav bölümsüzdür
    var sectionPlan: [Int] = []
    /// Sınavın şu anki bölümü (1...); 0: bölümsüz sınav
    var sectionIndex = 0
    /// "Testi bitir" mi, "bölümü tamamla" mı denmiş: onay, cevapları okuma ve menü ikisinde de aynı yürür; bitişte hangisinin yapılacağını bu belirler
    var endScope: EndScope = .test
    /// "Yeni bölüm mü, testi tamamlama mı?" sorusunun hatırlatma sayısı
    var sectionReminders = 0
    var nextNumber = 1
    /// Cevapların kaydedilme sırası (son kaydedilen sonda); "son soruyu sil" en son kaydedilen soruyu bulur. Önceki kayıttan devam edilince düz yazıdaki sıradır.
    var answerOrder: [Int] = []
    /// "Son soruyu sil" onayı bekleniyor: silinecek sorunun numarası (onay "testi bitir" onayıyla aynı kipte sorulur; bitince nil olur)
    var pendingDelete: Int?
    /// "Soru numarası düzelt" / "istenen soruyu sil" sürüyor: hangi adımda olunduğu (numara beklenirken dinleme kipi `.missingNumber` kullanılır; bekleyen soru yoksa)
    var numberEdit: NumberEdit?
    /// "Soru numarası düzelt" onayı bekleniyor (onay "testi bitir" onayıyla aynı kipte sorulur)
    var pendingRenumber: PendingRenumber?
    /// Silme onayı hangi bölümün kaydı için bekleniyor (0: bölümsüz sınav) ve silinecek soru kullanıcının seçtiği soru mu ("son soru" değil)
    var pendingEditSection = 0
    var pendingDeleteChosen = false
    /// Önceki oturumdan hatırlanan klasör ve sıradaki numara: uygulama açılırken defterden, "Testi bitir"de bellekten. Yeni başlatmada
    /// içinde cevap varsa "önceki kayıttan devam mı, yeni sınav mı?" diye sorulur.
    struct Carry: Equatable {
        var folder: String
        var nextNumber: Int
        var at: Date
    }
    var carry: Carry?
    /// Başlatırken bulunan ve henüz cevaplanmamış "devam mı, yeni mi?" sorusu
    struct ChoiceOffer: Equatable {
        var answers: Int
        var next: Int
        var recent: Bool
    }
    var choiceOffer: ChoiceOffer?
    var choiceReminders = 0
    /// Kulaklıktan söylenmeyi bekleyen uyarılar, şu an çalan söyleme görevi, her cümlenin son söylenme zamanı ve söylenenlerin kaydı
    var voiceQueue: [PendingAnnouncement] = []
    var voiceTask: Task<Void, Never>?
    var lastVoiced: [String: Date] = [:]
    var announced: [String] = []
    /// Yol düzelmeden "çıkışı kulaklığa al" kestirmesi art arda kaç kez çalıştı (yol düzelince sıfırlanır)
    var outputTries = 0
    /// Kulaklık yoldan çıkınca kestirmeyi hemen çalıştıracak zamanlayıcı ve çalışan deneme
    var outputQuick: ScheduledTask?
    var outputQuickRun: Task<Void, Never>?
    var pendingStart = false
    /// Alındığı ve kaydedildiği hâlde kulaklıktan duyulamamış cevap (okunurken ses yolu koptu); yol dönünce yeniden okunur
    var unheard: AnswerRecord?
    /// Şu an Gemini'ye giden sorunun satırı (yoksa nil) ve satır sayacı
    var currentEntry: Int?
    var entrySeq = 0
    /// Düşük şarj uyarısının hangi eşikleri söylediğini tutar
    var batteryWatcher = LowBatteryWatcher()
    /// Arada tek kelime tanınmadan art arda yapılan donanım onarımı sayısı
    var hardwareRecoveries = 0
    var work: Task<Void, Never>?
    var confirmTask: ScheduledTask?
    var offlineCheck: ScheduledTask?
    var hardwareGrace: ScheduledTask?
    /// Duraklatma yönlendirmesi için yapılan kontrol sayısı (duraklatma bitince sıfırlanır)
    var pausedGuidanceTicks = 0
    var stableTask: ScheduledTask?
    var retryTask: ScheduledTask?
    /// Arama/alarm/Siri kesintisi sürüyor
    var interruptionActive = false
    var interruptionPoll: ScheduledTask?
    /// Anında tespit (nabız) durumu: döngü, mikrofon sağlığı ve onarım sayacı, internet nabzı
    var sentinel: ScheduledTask?
    var micCooldown = 0
    var micOKTicks = 0
    var micHealCount = 0
    var micAlive = true
    var netBeatTicks = 0
    var netFails = 0
    var netProbeBusy = false
    var netReconnecting = false
    var netPulse: NetPulse = .unknown
    /// Duraklama/onarım ilk başladığı an (kısa kesintide kısa anons için)
    var outageStart: Date?
    /// Sınır duraklaması (art arda onarım işe yaramadı): ses yolu sağlam görünse de süre dolana kadar devam edilmez. Yoksa nabız,
    /// "yol sağlam" diye hemen devam edip aynı onarım döngüsünü yeniden başlatır.
    var holdForRetry = false
    /// Hızlı nabız yoklaması bir kez boşuna alarm verdi (tam yoklama bağlantıyı sağlam buldu): nabız bu oturumda daha uzun sınırlı
    /// tam internet yoklamasıyla bakar. Onarım susturulmaz; gerçek kopma yine aynı hızda yakalanır.
    var netProbeSlow = false
    /// Son ağ onarımı çağrısı yanlış alarmdı (bağlantı sağlamdı, hiçbir şey durdurulmadı)
    var lastNetworkAlarmWasFalse = false
    /// Konuşma tanıma onarımı: arada tek kelime tanınmadan kaç kez düştü; bekleme zamanlayıcısı
    var recognizerRepairs = 0
    var recognizerRetryTask: ScheduledTask?
    /// Beklenmedik kapanmadan sonra oturum sürdürülüyor: anons edilip tüketilene kadar durur
    var resume: ResumeInfo?
    var launchHandled = false
    /// Sistem sağlığı: bellek yükü azaltılmış mı, dakikalık sayaç, takılma gözcüsü ve nabız gecikmesi
    var memoryLowActive = false
    var thermalTrimmed = false
    var systemTicks = 0
    var watchedPhase: SessionPhase?
    var watchedTicks = 0
    var stuckTrips = 0
    var lastTickAt: Date?
    var heartbeatTicks = 0
    /// Numarası okunmadığı için numara beklenen soru; "Tamamlandı" denmiş ama soru numaraları beklenen paragraf; numara hatırlatma sayısı
    var heldQuestion: HeldQuestion?
    var passageDraft: PassageDraft? {
        didSet { releasePassageShot(oldValue?.shot) }
    }
    var numberReminders = 0
    var targetReminders = 0
    var targetDoneReminders = 0
    var endReminders = 0
    /// "Testi bitir" onayında "hayır" (ya da cevapsızlık) denirse dönülecek kip: soru; numara ya da paragraf numarası beklenirken söylendiyse o bekleme (tutulan soru / paragraf taslağı korunur)
    var endReturn: ListenMode = .question
    /// Söz bölümleri: son sözün metindeki ilk sözcük sırası, son sessizlikte metinde kaç sözcük vardı, sessizlik geçti mi ve sessizlik zamanlayıcısı
    var utteranceStart = 0
    /// Önceki sözlerin başlangıç sırası ("son cümleyi sil" son sözü bulur)
    var utteranceStarts: [Int] = []
    var settledCount = 0
    var gapPassed = false
    var gapTask: ScheduledTask?
    /// Üst üste anlaşılmayan komut denemesi sayısı; soru başına "Cevapla" hatırlatma sayısı
    var attemptFails = 0
    /// Programın en son söylediği anonslar (en çok ikisi, ör. cevap + kamera sorusu): kullanıcı "anlamadım", "duyamadım", "bir daha söyle" derse
    /// yeniden söylenir. Mikrofon kullanıcı için açıldıktan sonra söylenen ilk anons yeni bir grup başlatır (`speechSealed`).
    var recentSpeech: [String] = []
    var speechSealed = false
    var idleReminders = 0
    /// Cevaplar baştan okunuyor (oturum açık kalır; okuma bitince "Devam, Tekrar ya da Bitir" sorulur)
    var reviewing = false
    /// Okunan cevap dosyası sayısı (okuma sonunda "N sorunun cevabı okundu" raporu için)
    var reviewCount = 0
    /// Okuma bitince "Devam" denirse dönülecek dinleme kipi
    var reviewReturn: ListenMode = .question
    /// Okumayı kim istedi: testi bitirme isteği mi, yalnız cevapları tekrarlama isteği mi (sessizlikte varsayılan buna göre seçilir)
    var reviewOrigin: ReviewOrigin = .repeatRequest
    var reviewReminders = 0
    /// Tanıyıcının son kısmi metindeki sözcükler için alternatif okumaları (her sözcük için en iyi okuma önde)
    var heardOptions: [[String]] = []
    /// Kesinti (onarım, donanım beklemesi) hangi aşamadayken başladı: dinlerken mi, soru gitmişken (cevap beklenirken) mi
    var interruptedFrom: SessionPhase?
    /// Cevap beklenirken "cevap bekleniyor" anonsu ve 3 dakikalık bekleme sınırı için zamanlayıcı
    var answerWait: ScheduledTask?
    /// Boşluk bilgisi zamanlayıcısı, programın son konuşmasından beri geçen sessiz adım sayısı ve dinlerken art arda söylenen "Dinliyorum" sayısı
    /// (bkz. `SessionViewModel+Narration`)
    var narrationTask: ScheduledTask?
    var quietTicks = 0
    var idleCuesInRow = 0
    /// "Dinliyorum" söylenirken yenisi başlatılmaz (konuşma bir adımdan uzun sürerse üst üste binmesin)
    var idleCueBusy = false

    // MARK: Sürüm 4: kamera
    /// Kamera ayarları
    let cameraSettings: CameraSettings
    /// Bir sonraki soru dinlemesinde önce "kamera ile çekmek ister misiniz?" sorulacak
    var offerCamera = false
    /// Kamera akışı (kestirme + çekim + internete dönüş + gönderim) sürüyor
    var cameraBusy = false
    /// Kameraya 5 denemede de ulaşılamadı: ne zamandan beri (nil: kamera kullanılabilir). Bu süre içinde kamera sorusu sorulmaz, soru sesle okunur;
    /// kamera 5 dakikada bir sorular arasında yoklanır, dönünce kullanıcıya haber verilir ve kamera yeniden sisteme girer.
    var cameraDownSince: Date?
    var cameraProbeTask: ScheduledTask?
    /// Kamera akışı başladı ama internete dönüş doğrulanmadı: telefon kameranın Wi-Fi'sinde, hücresel kapalı kalmış olabilir
    var networkMayBeOnCamera = false
    /// Kamera için bağlantı sıfırlama (uçak modu) sürüyor: kulaklığın düşmesi beklenen bir durumdur, ses yolu değişince duraklatılmaz
    var connectionResetActive = false
    /// Oturum başında kameraya bağlanma (bkz. SessionViewModel+CameraStart): nil → henüz denenmedi; true/false → bağlanıldı / bağlanılamadı.
    /// `cameraStartDone`: internete dönüş de tamamlandı. Açılış kontrolü kulaklık kopmasıyla baştan yapılırsa adımlar tekrarlanmaz.
    var cameraStartConnected: Bool?
    var cameraStartDone = false
    /// "Kamera bağlandı" anonsu yapıldı mı; açık bağlantı sürerken kameranın verdiği uyarılar (düşük pil gibi) ses yolu doğrulanana kadar burada bekler
    var cameraStartSpoken = false
    var cameraStartNotes: [String] = []
    /// Çekilen bir soru (fotoğraf + video) Gemini'ye gönderiliyor: bekleme sınırı V3'ün sesli sorusundan daha geniştir (bkz. `Timing.cameraExtraWait`)
    var sendingShotID: UUID?
    var sendingShot: Bool { return sendingShotID != nil }
    var cameraReminders = 0
    var cameraGuidanceSpeaking = false
    /// Kullanıcı "hayır" dedi ya da kamera akışı olmadı: bu soru sesle okunur, aynı soru için kamera yeniden sorulmaz
    var cameraOfferSuppressed = false
    /// Çekilmiş ama internet olmadığı için gönderilememiş sorular (en eskisi önce, sırayla gönderilir). Dosyaları telefondaki kalıcı
    /// klasörde durur (`CaptureStoring`); uygulama kapansa da bir sonraki başlatmada klasörden geri yüklenir.
    var pendingShots: [CapturedQuestion] = []
    /// Kamera sorusu kapalıyken bekleyen çekimler gönderilemedi: sıradaki dinleme bekleyenleri yeniden denemeden soruyu bekler (döngü olmasın)
    var pendingDrainSkipped = false
    /// Çevrimdışı çekim kipi (SIM kart yok): internet yokken çekimler telefonda birikir. Bekleyen çekimler varken internet gelince
    /// dinleme açıksa gönderilir (bkz. `drainPendingWhenOnline`). Yalnız internet yokluğu görüldüyse kurulur.
    var offlineHeld = false
    /// Telefonda biriken çekimler sırayla gönderiliyor (eskiden yeniye, her biri gönderilip cevabı okunur ve kaydedilir). Toplu gönderimin başında
    /// bir kez "internet tekrar kuruldu" denir, sonunda "tüm bekleyenler gönderildi" denir; ara çekimler için tekrar konuşulmaz.
    /// Toplu çekimde Gemini'nin bir sayfa için verdiği, henüz okunmamış cevaplar (ilki okunurken kalanlar burada bekler; sırayla okunur)
    var queuedReplies: [GeminiReply] = []
    /// Cevapları okunmakta olan sayfa: hepsi duyulunca bekleyenlerden çıkar ("Gönderilen"e taşınır); yarıda kalırsa bekler ve yeniden gönderilir
    var pageBeingRead: CapturedQuestion?
    /// O sayfanın bütün cevap cümleleri ("Gönderilen" klasörüne yazılır)
    var pageSpokenAll: [String] = []
    var drainActive = false
    /// Toplu gönderimin başındaki bekleyen sayısı ve şimdiye dek sıraya giren çekim sayısı ("Bekleyen 3 sorudan ikinci gönderiliyor")
    var drainTotal = 0
    var drainIndex = 0
    /// Bekleyen çekimlerin bu testteki başarısız gönderim sayısı (bkz. `Timing.pendingSendAttempts`)
    var sendFailures: [UUID: Int] = [:]
    /// Kendiliğinden yeniden gönderilmesi denenmiş bekleyen çekimler (bkz. `resendablePending`)
    var retriedShots = Set<UUID>()
    var answerWaitElapsed: TimeInterval = 0

    init(settings: AppSettings, deps: SessionDependencies, camera: CameraSettings = CameraSettings()) {
        self.settings = settings
        self.cameraSettings = camera
        self.deps = deps
        watchdog = SilenceWatchdog(scheduler: deps.scheduler)
        recovery = RecoveryCoordinator(shortcuts: deps.shortcuts,
                                       name: { step in settings.shortcutName(for: step) },
                                       config: deps.recoveryConfig,
                                       sleep: deps.sleep)
        let route = deps.route
        replay = ReplayController(player: deps.replayPlayer, scheduler: deps.scheduler,
                                  canPlay: { AudioRouting.verdict(route.snapshot()).headphonesOK })
        deps.route.onChange = { [weak self] snapshot in self?.routeChanged(snapshot) }
        deps.route.onInterruption = { [weak self] began in self?.interrupted(began) }
        deps.network.onChange = { [weak self] online in self?.networkChanged(online) }
        deps.network.onPathChange = { [weak self] in self?.networkPathChanged() }
        deps.route.onMediaServicesReset = { [weak self] in self?.mediaServicesReset() }
        deps.battery.onChange = { [weak self] in self?.batteryChanged() }
        deps.system.onMemoryWarning = { [weak self] in self?.memoryWarningReceived() }
        deps.system.onThermalChange = { [weak self] in self?.thermalChanged() }
        deps.system.onPowerModeChange = { [weak self] in self?.powerModeChanged() }
        deps.listener.onEvent = { [weak self] event in self?.handleSpeech(event) }
        watchdog.onExpire = { [weak self] in self?.silenceExpired() }
        replay.onState = { [weak self] state in self?.replayChanged(state) }
        refreshReplayAvailability()
        refreshInputs()
    }

    /// Ana ekrandaki mikrofon listesi: yalnız harici (Lightning/USB/kablolu) mikrofonlar seçilebilir
    func refreshInputs() {
        inputs = deps.route.availableInputs().filter { $0.isExternal }
        let snapshot = deps.route.snapshot()
        var text = AudioRouting.describe(snapshot)
        // Mikrofon alıcısı takılı ama ses yoluna girmediyse nedeni yazılır ("giriş yok" tek başına yanıltıcıdır)
        if !snapshot.inputs.contains(where: { AudioRouting.externalMicPorts.contains($0) }), let receiver = inputs.first {
            text += phase.isAtRest
                ? " Mikrofon alıcısı (\(receiver.name)) takılı; “Sesi dene” ya da “Başlat” ile devreye girer."
                : " Mikrofon alıcısı (\(receiver.name)) takılı ama ses yoluna girmedi."
        }
        routeText = text
    }

    /// Kullanıcı listeden bir mikrofon seçti
    func chooseInput(_ uid: String) {
        if deps.route.selectInput(uid: uid) {
            clearWarning("giris")
        } else {
            warn("giris", "Mikrofon seçilemedi. Alıcının takılı ve mikrofonun açık olduğundan emin olun.")
        }
        refreshInputs()
        routeVerdict = AudioRouting.verdict(deps.route.snapshot())
    }

    // MARK: Başlat / bitir

    /// Oturumu başlatır: donanım kontrolü, sonra dinleme. El ile düğme, seslikontrol://basla, saat ya da bildirim çağırır.
    func start() {
        guard phase.isAtRest else { return }
        resetSession()
        restorePendingShots()   // önceki çalışmadan telefonda kalan çekimler (gönderilmemişler) sırayla gönderilmek üzere geri yüklenir
        // Beklenmedik kapanmadan sonra ortak paragraf yazı olarak (kamerayla çekildiyse fotoğraf olarak) geri gelir: ses kaydı ve video bellekteydi, kayboldu
        if let saved = resume?.passage, !saved.remaining.isEmpty {
            let photoShot = saved.photo.map { CapturedQuestion(photo: $0) }
            passage = PassageContext(text: saved.text, english: saved.english, audio: nil, all: saved.all, remaining: saved.remaining, shot: photoShot)
            tlog("[paragraf] kapanmadan önceki ortak paragraf \(photoShot == nil ? "yazı" : "fotoğraf") olarak geri yüklendi (\(QuestionComposer.listText(saved.remaining)) numaralı sorular)")
        }
        phase = .checking
        deps.screen.keepAwake(true)
        deps.network.start()
        startSentinel()
        startGapNarration()
        work = Task { [weak self] in await self?.runStartup() }
    }

    /// "Testi bitir": her şeyi durdurur; cevaplar klasörde kalır, "Cevapları Tekrarla" açılır
    func endTest() {
        guard phase.isRunning else { return }
        let onCameraNetwork = cameraBusy || networkMayBeOnCamera   // kamera akışı sürerken (ya da yarıda kalıp doğrulanmadan) bitirilirse telefon kameranın Wi-Fi'sinde kalmış olabilir
        cancelWork()
        replay.stop()
        deps.speaker.stop()
        deps.listener.pause()
        deps.network.stop()
        deps.screen.keepAwake(false)
        phase = .finished
        if let name = locationName {
            carry = Carry(folder: name, nextNumber: nextNumber, at: deps.now())
        }
        choiceOffer = nil
        passage = nil
        heldQuestion = nil
        passageDraft = nil
        listenMode = .question
        statusNote = "Test bitti. \(answers.count) cevap kaydedildi."
        noteUnsentShots()
        refreshReplayAvailability()
        if onCameraNetwork { restoreInternetAfterCamera() }
    }

    /// seslikontrol://basla (zamanlı başlatma), seslikontrol://yeniden (Kestirmeler "uygulama kapanınca aç" otomasyonu) ve Kestirmeler dönüşleri
    func handleURL(_ url: URL) {
        if ShortcutLink.isStartURL(url) {
            start()
            return
        }
        if ShortcutLink.isReopenURL(url) {
            // Yeniden açılış: uygulama kapanmışsa `launched` önceki oturumu zaten sürdürür; açıksa yalnız öne gelir
            tlog("[açılış] otomasyon uygulamayı yeniden açtı (seslikontrol://yeniden)")
            return
        }
        deps.shortcuts.handleCallback(url)
    }

    // MARK: Açılış ve kapanış

    /// Oturumun "açık" sayıldığı aşamalar: tekrar (replay) bir oturum değildir
    static func countsAsSession(_ phase: SessionPhase) -> Bool {
        return phase.isRunning && phase != .replaying
    }

    /// Uygulama açılınca bir kez çağrılır. Önceki çalışma oturum sürerken beklenmedik kapandıysa (iOS belleği, çökme, elle kapatma)
    /// oturum kendiliğinden yeniden başlar ve yarım kalan iş tamamlanır. Kullanıcı "Programı kapat" ile kapattıysa ya da oturum düzgün
    /// bittiyse hiçbir şey başlamaz. Kısa sürede art arda kapanma varsa (açılış döngüsü) otomatik başlatma yapılmaz.
    func launched() {
        guard !launchHandled else { return }
        launchHandled = true
        let run = deps.journal.beginRun()
        tlog("[açılış] önceki çalışma: \(run.exit.logText)")
        // Önceki oturumun klasörü ve numarası hatırlanır: yeni başlatmada içinde cevap varsa "devam mı, yeni mi?" diye sorulur
        if let folder = run.folder {
            carry = Carry(folder: folder, nextNumber: run.nextNumber, at: deps.now().addingTimeInterval(-Double(run.downSeconds ?? 0)))
        }
        guard case .unexpected(let cause) = run.exit else { return }
        guard !run.loop else {
            deps.journal.setSessionOpen(false)
            deps.journal.savePending(nil)
            deps.journal.savePassage(nil)
            warn("kapanma", Say.restartLoop)
            tlog("[açılış] kısa sürede art arda beklenmedik kapanma: otomatik başlatma durduruldu")
            return
        }
        guard phase.isAtRest else { return }
        resume = ResumeInfo(cause: cause, downSeconds: run.downSeconds, pending: run.pending, nextNumber: run.nextNumber, folder: run.folder,
                            passage: run.passage)
        tlog("[açılış] oturum kendiliğinden yeniden başlatılıyor (kapalı kalma: \(run.downSeconds.map { "\($0) sn" } ?? "bilinmiyor"), yarım iş: \(run.pending == nil ? "yok" : "var"))")
        start()
    }

    /// "Programı kapat" düğmesine 3 saniye basıldı: oturum kapanır, defter ve pano "kullanıcı kapattı" olarak işaretlenir (yeniden açılmasın),
    /// günlük diske yazılır ve program gerçekten çıkar.
    func closeByUser() {
        tlog("[kapanış] kullanıcı kapattı (düğmeye \(Int(Timing.closeHold)) sn basıldı)")
        deps.journal.markDeliberateClose()
        deps.journal.savePending(nil)
        if phase == .replaying { stopReplay() }
        if phase.isRunning { endTest() }
        AppLog.shared.flush()
        Task { [weak self] in
            guard let self = self else { return }
            await self.deps.sleep(Timing.closeDelay)
            AppLog.shared.flush()
            self.deps.terminate()
        }
    }

    func resetSession() {
        cancelWork()
        accumulator.clear()
        englishAccumulator.clear()
        liveText = ""
        liveEnglish = ""
        answers = []
        answerOrder = []
        pendingDelete = nil
        pendingRenumber = nil
        pendingDeleteChosen = false
        numberEdit = nil
        cameraProbeTask?.cancel()
        cameraProbeTask = nil
        narrationTask?.cancel()
        narrationTask = nil
        idleCuesInRow = 0
        idleCueBusy = false
        cameraDownSince = nil
        questions = []
        currentEntry = nil
        entrySeq = 0
        batteryWatcher = LowBatteryWatcher()
        warnings = []
        checkup = []
        statusNote = ""
        cameraStartConnected = nil
        cameraStartDone = false
        cameraStartSpoken = false
        cameraStartNotes = []
        offlineHeld = false
        drainActive = false
        nextNumber = 1
        choiceOffer = nil
        choiceReminders = 0
        targetReminders = 0
        reviewing = false
        reviewReminders = 0
        heardOptions = []
        pendingStart = false
        unheard = nil
        hardwareRecoveries = 0
        interruptionActive = false
        sessionFolder = nil
        examFolder = nil
        sectionPlan = []
        sectionIndex = 0
        endScope = .test
        sectionReminders = 0
        voiceQueue = []
        lastVoiced = [:]
        outputTries = 0
        outputQuick?.cancel()
        outputQuick = nil
        outputQuickRun?.cancel()
        outputQuickRun = nil
        micCooldown = 0
        micOKTicks = 0
        micHealCount = 0
        micAlive = true
        netBeatTicks = 0
        netFails = 0
        netProbeBusy = false
        netReconnecting = false
        netPulse = .unknown
        outageStart = nil
        liveStatus = ""
        holdForRetry = false
        netProbeSlow = false
        lastNetworkAlarmWasFalse = false
        recognizerRepairs = 0
        recognizerRetryTask?.cancel()
        recognizerRetryTask = nil
        if memoryLowActive || thermalTrimmed { deps.listener.trimMemory(false) }
        memoryLowActive = false
        thermalTrimmed = false
        systemTicks = 0
        watchedPhase = nil
        watchedTicks = 0
        lastTickAt = nil
        heartbeatTicks = 0
        listenMode = .question
        passage = nil
        heldQuestion = nil
        passageDraft = nil
        numberReminders = 0
        interruptedFrom = nil
        answerWait?.cancel()
        answerWait = nil
        answerWaitElapsed = 0
    }

    func cancelWork() {
        abortReview()
        abandonEntry("Kesildi: cevap gelmeden iş durdu. Soruyu yeniden okuyun.")
        work?.cancel()
        work = nil
        if cameraBusy {
            deps.camera.cancel()
            cameraBusy = false
        }
        cancelTimers()
        retryTask?.cancel()
        retryTask = nil
        watchdog.disarm()
    }

    /// Kısa ömürlü bekleyen işleri iptal eder (çalışan `work` görevine dokunmaz)
    func cancelTimers() {
        confirmTask?.cancel()
        confirmTask = nil
        offlineCheck?.cancel()
        offlineCheck = nil
        hardwareGrace?.cancel()
        hardwareGrace = nil
        stableTask?.cancel()
        stableTask = nil
        interruptionPoll?.cancel()
        interruptionPoll = nil
        outputQuick?.cancel()
        outputQuick = nil
        answerWait?.cancel()
        answerWait = nil
    }

    // MARK: Uyarılar ve kontrol maddeleri

    /// Kulaklıktan zaten başka yerde söylenen ("start": Kontrol başarısız, "cevap": Gemini hatası) ya da kulaklıktan söylenemeyen
    /// ("ses": okuma hatası) uyarılar ayrıca söylenmez
    private static let silentWarnings: Set<String> = ["start", "cevap", "ses", "kapanma", "gozcu", "yedek", "numara", "duyulan"]

    /// Uyarıyı ekrana yazar; yeni ya da değişmişse kulaklıktan da söyler (`announce`)
    func warn(_ id: String, _ text: String) {
        var changed = true
        if let index = warnings.firstIndex(where: { $0.id == id }) {
            changed = warnings[index].text != text
            if changed { tlog("[uyarı] \(id): \(text)") }
            warnings[index].text = text
        } else {
            tlog("[uyarı] \(id): \(text)")
            warnings.append(SessionWarning(id: id, text: text))
        }
        if changed, !SessionViewModel.silentWarnings.contains(id) { announce(text) }
    }

    func clearWarning(_ id: String) {
        warnings.removeAll { $0.id == id }
    }

    func setCheck(_ id: String, _ title: String, ok: Bool, detail: String = "") {
        let item = CheckItem(id: id, title: title, ok: ok, detail: detail)
        if let index = checkup.firstIndex(where: { $0.id == id }) {
            checkup[index] = item
        } else {
            checkup.append(item)
        }
    }

    /// Tekrarlanacak klasör: bu oturumun cevapları varsa o, yoksa (yeni oturum açılıp boş kaldıysa) cevap içeren en yeni gün klasörü
    func replayFolder() -> URL? {
        // Bölümlü sınavda sınav klasörü verilir: tekrar bütün bölümleri sırayla okur
        if let folder = examFolder ?? sessionFolder, !deps.library.answerFiles(in: folder).isEmpty { return folder }
        return deps.library.latestFolder()
    }

    func refreshReplayAvailability() {
        canReplay = replayFolder() != nil
    }

    // MARK: Dinleme (Modül 3)

    /// Mikrofonu açar ve yeni soruyu bekler. Eldeki yarım metin ve ses silinir; yalnız `keepPartial` ise (kesinti sonrası, okunan soru ya da
    /// paragraf yarıda kalmışsa) korunur ve devam edilen okuma ona eklenir. `mode`: mikrofonun ne için açıldığı.
    func beginListening(mode: ListenMode = .question, keepPartial: Bool = false) {
        queuedReplies = []   // dinlemeye dönüldü: yarıda kalan sayfanın kalan cevapları bayatlar (sayfa bekleyende durur, yeniden gönderilir)
        pageBeingRead = nil
        if mode != .confirmEnd {   // silme / numara düzeltme onayı yalnız onay kipinde geçerlidir; başka kipe geçilince bayat kalmaz
            pendingDelete = nil
            pendingRenumber = nil
            pendingDeleteChosen = false
        }
        if mode != .missingNumber { numberEdit = nil }   // numara düzeltme / silme adımları yalnız numara kipinde sürer
        // Sürüm 4: yeni bir soru sınırında önce "kamera ile çekmek ister misiniz?" sorulur (evet / hayır dinlemesi buradan açılır)
        // Telefonda bekleyen çekim, kamera sorusu kapalı olsa da yeni bir soru sınırında önce gönderilir (askCameraChoice yönlendirir)
        let drainPending = resendablePending != nil && !pendingDrainSkipped
        pendingDrainSkipped = false
        if mode == .question, !keepPartial, !cameraOfferSuppressed, offerCamera || drainPending {
            offerCamera = false
            if cameraOfferAvailable || drainPending {
                deps.journal.savePending(nil)   // önceki cevap duyuldu ve dinlemeye dönülüyor: kapanma olursa o cevap yeniden okunmaz
                work = Task { [weak self] in await self?.askCameraChoice() }
                return
            }
        }
        drainActive = false   // buraya gelindiyse bekleyen çekimlerin toplu gönderimi sürmüyor (sürerken yukarıda kamera akışına yönlenilir)
        cancelTimers()
        abandonEntry("Cevap alınamadı. Soruyu yeniden okuyun.")
        deps.journal.savePending(nil)   // dinlemeye dönüldüyse yarım kalan iş yoktur
        unheard = nil
        heardOptions = []
        if keepPartial, !accumulator.isEmpty {
            accumulator.commitCurrent()   // eski görevin yarım metni bölüm olur; yeni görevin metni onun arkasına eklenir
            englishAccumulator.commitCurrent()
            liveText = accumulator.text
            liveEnglish = englishAccumulator.text
            beginNewUtterance()   // yeni görevin sözü, eldeki metnin arkasında yeni bir sözdür
        } else {
            resetUtterances()
            idleReminders = 0
            accumulator.clear()
            englishAccumulator.clear()
            liveText = ""
            liveEnglish = ""
            deps.recorder.reset()
            if mode == .question {
                heldQuestion = nil
                passageDraft = nil
            }
        }
        listenMode = mode
        deps.listener.hints = ListenHints.hints(for: mode)
        do {
            try deps.listener.start()
        } catch {
            listenerFailed(error)
            return
        }
        clearWarning("mikrofon")
        phase = .listening
        quietTicks = 0   // sessizlik buradan sayılır (bkz. `SessionViewModel+Narration`)
        speechSealed = true   // kullanıcı söz sırasında: bundan sonra söylenen ilk anons yeni bir "son söz" grubu başlatır
        statusNote = ""
        micCooldown = Timing.micWarmupTicks
        micOKTicks = 0
        micAlive = true
        outageStart = nil
        watchdog.kick()
        if !deps.network.isOnline { scheduleOfflineCheck() }
        batteryChanged()
    }

    func handleSpeech(_ event: SpeechEvent) {
        guard phase == .listening else { return }
        switch event {
        case .partial(let text):
            guard accumulator.update(partial: text) else { return }
            hardwareRecoveries = 0   // mikrofon gerçekten çalışıyor
            recognizerRepairs = 0    // tanıma gerçekten çalışıyor
            liveText = accumulator.text
            noteUtterance()
            watchdog.kick()
            if listenMode == .cameraChoice, wordCount(accumulator.text) > 8 {
                // Kullanıcı kamera sorusunu beklemeden soruyu okumaya başladı (V3 alışkanlığı): sesle okumayı seçmiş sayılır, okunan metin korunur
                // ve "Cevapla" ile Gemini'ye gider; bu soru için kamera yeniden sorulmaz
                tlog("[kamera] kamera sorusuna soru metniyle cevap verildi; bu soru sesle okunuyor")
                cameraOfferSuppressed = true
                cameraReminders = 0
                listenMode = .question
                deps.listener.hints = ListenHints.hints(for: .question)
            }
            if listenMode == .question || listenMode == .cameraChoice, PassageCommand.startsWith(accumulator.text) {
                // "ortak paragraf": paragraf okunuyor ya da (kamera varsa, yalnız "ortak paragraf" denip duraklanırsa) kamera sorulur;
                // kamera sorusuna da bu sözle cevap verilebilir
                if listenMode == .cameraChoice {
                    cameraReminders = 0
                    deps.listener.hints = ListenHints.hints(for: .passage)
                }
                listenMode = .passage
                tlog("[paragraf] ortak paragraf kipi açıldı")
            }
            reevaluateTrigger()
        case .alternatives(let options):
            heardOptions = options
        case .taskEnded:
            accumulator.commitCurrent()
            heardOptions = []
        case .englishPartial(let text):
            guard englishAccumulator.update(partial: text) else { return }
            liveEnglish = englishAccumulator.text
        case .englishTaskEnded:
            englishAccumulator.commitCurrent()
        case .failure(let message):
            warn("mikrofon", message)
            // Ses yolu sağlamsa sorun donanımda değil konuşma tanıyıcıdadır: Bluetooth/uçak modu Kestirmeleri onu düzeltmez, kulaklığı koparır.
            // Dinleme yeniden kurulur; art arda olursa (healMic) Kestirmelere başvurulur.
            if settings.instantDetection, AudioRouting.verdict(deps.route.snapshot()).isSafe {
                healMic("konuşma tanıma hata verdi")
            } else {
                work = Task { [weak self] in await self?.runRecovery(.hardware, force: true) }
            }
        case .recognizerDown(let message, let permanent):
            tlog("[mikrofon] tanıyıcı düştü (\(permanent ? "kalıcı" : "geçici")): \(message)")
            if permanent {
                stopForGood(message)   // Dikte kapalı ya da model yok: yeniden denemek işe yaramaz, ne yapılacağı söylenir
            } else if AudioRouting.verdict(deps.route.snapshot()).isSafe {
                // Ses yolu sağlam: sorun tanıyıcıdadır. Bluetooth/uçak modu Kestirmeleri onu düzeltmez, kulaklığı koparır.
                work?.cancel()
                work = Task { [weak self] in await self?.repairRecognizer(message) }
            } else {
                work = Task { [weak self] in await self?.runRecovery(.hardware, force: true) }
            }
        case .engineStopped:
            // Dinleme yeni (yeniden) başladıysa bekleme süresinde yok sayılır; gerçekten durduysa nabız yine yakalar.
            // Motor bildirimi tek başına onarım sayacına sayılmaz (tamponlar gerçekten kesilirse nabız sayar).
            guard settings.instantDetection, micCooldown == 0 else { return }
            healMic("ses motoru durdu", counted: false)
        }
    }

    /// Dinleme açılamadı ya da durdu. Kalıcı eksikse (izin, dikte modeli) oturum kapanır; donanımsa Kestirmelerle onarılır.
    func listenerFailed(_ error: Error) {
        if let known = error as? ListenerError, !known.isHardware {
            stopForGood(known.localizedDescription)
            return
        }
        warn("mikrofon", error.localizedDescription)
        work = Task { [weak self] in await self?.runRecovery(.hardware, force: true) }
    }

    /// Kipe göre tetikleyici sabit kalırsa ateşler: soru ve paragraf numaralarında metnin sonu "Cevapla"/"Gönder", ortak paragrafta "Tamam";
    /// eksik soru numarası beklenirken kısa bir numara cevabı ("soru yedi") ya da "sıradaki"
    private func reevaluateTrigger() {
        confirmTask?.cancel()
        confirmTask = nil
        let text = accumulator.text
        var delay = Timing.triggerConfirm
        // "Cevapları tekrarla": soru, onay, numara ve paragraf numarası beklenirken her an söylenebilir; kısa süre sabit kalırsa çalışır
        if [ListenMode.question, .confirmEnd, .missingNumber, .passageTargets].contains(listenMode), spokenCommand() == .replayAnswers {
            confirmTask = deps.scheduler.after(Timing.numberConfirm) { [weak self] in self?.fireVoiceCommand() }
            return
        }
        // "Beşinci sorunun cevabını tekrarla": soru numarası ya da paragraf numaraları beklenirken de söylenebilir (kısa numara cevabı sanılmasın);
        // cevap okunur ve aynı soru yeniden sorulur
        if [ListenMode.missingNumber, .passageTargets].contains(listenMode), let waiting = spokenCommand(),
           waiting.isRepeatNumber || waiting.isEnding || (listenMode == .missingNumber && waiting == .deleteLastQuestion) {
            confirmTask = deps.scheduler.after(Timing.numberConfirm) { [weak self] in self?.fireVoiceCommand() }
            return
        }
        // "Anlamadım", "duyamadım", "bir daha söyle": her kipte söylenebilir; program son sözünü yeniden söyler ve aynı kipte dinler
        if repeatSpeechRequested() {
            confirmTask = deps.scheduler.after(Timing.numberConfirm) { [weak self] in self?.fireRepeatSpeech() }
            return
        }
        // "Yardım", "ne duydun", "son cümleyi sil", "durum", "cevapsız soruları söyle": her kipte söylenebilir; program yaptığını ya da yapamadığını söyler
        if infoRequested() != nil {
            confirmTask = deps.scheduler.after(Timing.numberConfirm) { [weak self] in self?.fireInfoCommand() }
            return
        }
        // "Paragrafı iptal et": paragraf okunurken ve numaraları beklenirken söylenebilir (öteki komutlar paragraf metnine karışır)
        if listenMode == .passage || listenMode == .passageTargets, spokenCommand() == .cancelPassage {
            confirmTask = deps.scheduler.after(Timing.numberConfirm) { [weak self] in self?.fireVoiceCommand() }
            return
        }
        // "Soruyu iptal et": numarası söylenmediği için numara beklenen soru da vazgeçilebilir (yanlış okunan soru boşuna Gemini'ye gitmesin)
        if listenMode == .missingNumber, spokenCommand()?.isCancelQuestion == true {
            confirmTask = deps.scheduler.after(Timing.numberConfirm) { [weak self] in self?.fireVoiceCommand() }
            return
        }
        switch listenMode {
        case .question:
            // Tek başına söylenen komut ("testi bitir"): kısa süre sabit kalırsa çalışır, "Cevapla" demek gerekmez
            if spokenCommand() != nil {
                confirmTask = deps.scheduler.after(Timing.numberConfirm) { [weak self] in self?.fireVoiceCommand() }
                return
            }
            guard TriggerDetector.match(in: text) != nil else {
                scheduleQuestionChecks()   // komut gibi ama anlaşılmadı mı, "Cevapla" mı duyulmadı: susmak yerine söylenir
                return
            }
        case .passageTargets:
            guard interpret({ TriggerDetector.match(in: $0, words: PassageCommand.targetWords) }) != nil else {
                // Numaralar söylendi ama "Tamam" duyulmadı (ya da hiçbir şey anlaşılmadı): program kendisi sorar
                confirmTask = deps.scheduler.after(Timing.targetsIdle) { [weak self] in self?.targetsIdle() }
                return
            }
        case .passage:
            // Yalnız "ortak paragraf" denmiş, paragraf henüz okunmaya başlanmamış: kısa süre sabit kalırsa kulaklıktan okuma istenir
            if PassageCommand.startsWith(text), PassageCommand.stripStart(text).isEmpty {
                confirmTask = deps.scheduler.after(Timing.numberConfirm) { [weak self] in self?.firePassagePrompt() }
                return
            }
            guard let match = TriggerDetector.match(in: text, words: PassageCommand.finishWords) else { return }
            // "tamam" paragrafın içinde de geçebilir (cümle sonunda): kısa duraklamada bitmez, daha uzun sabit kalmalı
            if TriggerDetector.fold(match.word) == "tamam" { delay = Timing.numberConfirm }
        case .missingNumber:
            guard heldQuestion != nil || numberEdit != nil else { return }
            if numberHeard() {
                delay = Timing.numberConfirm
            } else {
                // Kısa ama numara olmayan bir söz duyuldu ("peş", "yedi mi"): 30 sn beklemeden yeniden sorulur. Uzun metin, kullanıcının
                // sonraki soruyu okumaya başladığı demektir; ona karışılmaz.
                guard text.split(whereSeparator: { $0.isWhitespace }).count <= 6 else { return }
                confirmTask = deps.scheduler.after(Timing.numberUnclear) { [weak self] in self?.numberUnclear() }
                return
            }
        case .confirmEnd:
            guard interpret(SpokenReply.yesNo) != nil else { scheduleChoiceUnclear(); return }
            delay = Timing.numberConfirm
        case .startChoice:
            guard interpret(SpokenReply.start) != nil else { scheduleChoiceUnclear(); return }
            delay = Timing.numberConfirm
        case .reviewMenu:
            guard interpret(SpokenReply.review) != nil else { scheduleChoiceUnclear(); return }
            delay = Timing.numberConfirm
        case .passageCameraChoice:
            if interpret(SpokenReply.cameraChoice) != nil {
                delay = Timing.numberConfirm
            } else if spokenCommand() != nil {
                // Kamera sorusundaki gibi: V3'ün sesli komutları ("testi bitir", "cevapları tekrarla", "paragrafı iptal et"…) burada da çalışır
                confirmTask = deps.scheduler.after(Timing.numberConfirm) { [weak self] in self?.fireVoiceCommand() }
                return
            } else {
                scheduleChoiceUnclear()
                return
            }
        case .cameraChoice:
            if interpret(SpokenReply.cameraChoice) != nil {
                delay = Timing.numberConfirm
            } else if spokenCommand() != nil {
                // Her soruda kamera sorusu sorulduğu için V3'ün sesli komutları ("testi bitir", "cevapları tekrarla", "son cevabı tekrarla")
                // burada da çalışır: yoksa program çoğu zaman komut alamaz
                confirmTask = deps.scheduler.after(Timing.numberConfirm) { [weak self] in self?.fireVoiceCommand() }
                return
            } else {
                scheduleChoiceUnclear()
                return
            }
        case .captureKindChoice:
            if interpret(SpokenReply.captureKind) != nil {
                delay = Timing.numberConfirm
            } else if spokenCommand() != nil {
                // Kamera sorusundaki gibi: V3'ün sesli komutları ("testi bitir", "cevapları tekrarla"…) burada da çalışır
                confirmTask = deps.scheduler.after(Timing.numberConfirm) { [weak self] in self?.fireVoiceCommand() }
                return
            } else {
                scheduleChoiceUnclear()
                return
            }
        case .nextSectionChoice:
            guard interpret(SpokenReply.nextSection) != nil else { scheduleChoiceUnclear(); return }
            delay = Timing.numberConfirm
        }
        confirmTask = deps.scheduler.after(delay) { [weak self] in self?.fireTrigger() }
    }

    func fireTrigger() {
        confirmTask = nil
        guard phase == .listening else { return }
        switch listenMode {
        case .question: fireQuestion()
        case .passage: firePassage()
        case .passageTargets: fireTargets()
        case .missingNumber: fireNumber()
        case .confirmEnd: fireConfirmEnd()
        case .startChoice: fireStartChoice()
        case .reviewMenu: fireReview()
        case .cameraChoice: fireCameraChoice()
        case .passageCameraChoice: firePassageCameraChoice()
        case .captureKindChoice: fireCaptureKind()
        case .nextSectionChoice: fireNextSection()
        }
    }

    /// Mikrofonu kapatır (ses kaydı ve İngilizce metin `fire*` işlevlerinde önceden alınır; dinleme yeniden açılırken metin silinir)
    func closeListening() {
        deps.listener.pause()
        watchdog.disarm()
    }

    /// Tek başına söylenen sesli komutu uygular (soru olarak Gemini'ye gitmez). Soru dinlenirken her komut, onay ve numara beklenirken yalnız
    /// "cevapları tekrarla" çalışır.
    func fireVoiceCommand() {
        confirmTask = nil
        guard phase == .listening, let command = spokenCommand() else { return }
        if command.isInfo {
            fireInfoCommand()
            return
        }
        switch listenMode {
        case .question, .cameraChoice, .passageCameraChoice, .captureKindChoice:
            break
        case .passage:
            guard command == .cancelPassage else { return }
        case .passageTargets:
            guard command == .replayAnswers || command == .cancelPassage || command.isRepeatNumber || command.isEnding else { return }
        case .missingNumber:
            if numberEdit != nil {
                guard command.isCancelQuestion else { return }   // numara düzeltme / silme sürerken yalnız "soruyu iptal et" (vazgeçme) çalışır
            } else {
                guard command == .replayAnswers || command.isCancelQuestion || command == .deleteLastQuestion || command.isRepeatNumber || command.isEnding else { return }
            }
        case .confirmEnd:
            guard command == .replayAnswers else { return }
        default:
            return
        }
        run(command)
    }

    private func run(_ command: VoiceCommand) {
        if command == .repeatSpeech {
            repeatSpeech(keepPartial: false)   // "Anlamadım, Cevapla" gibi: kipi bozmadan programın son sözü yeniden söylenir
            return
        }
        if command.isInfo {
            performInfo(command, question: "", keepText: false)   // bilgi komutları normalde fireInfoCommand / fireQuestion'da ele alınır
            return
        }
        var back = listenMode   // cevaplar okunduktan sonra "Devam" denirse buraya dönülür
        let from = listenMode
        // "Soruyu iptal et": komuttan önce okunmuş soru metni var mıydı (komutun kendi sözcükleri sayılmaz); yoksa silinecek bir şey olmadığı söylenir
        let hadQuestionText = from == .question && utteranceStart > 0 && utteranceStart < wordCount(accumulator.text)
        // "Ortak paragrafı iptal et" diye başlandıysa paragraf okunmaya hiç başlanmamıştır (komutun kendisi dışında ≤ 3 sözcük)
        let phraseOnly = from == .passage && PassageCommand.startsWith(accumulator.text)
            && PassageCommand.stripStart(accumulator.text).split(whereSeparator: { $0.isWhitespace }).count <= 3
        if back == .cameraChoice || back == .passageCameraChoice || back == .captureKindChoice {
            // Komut kamera sorusu açıkken söylendi: iş bitince (cevap tekrarı, "Devam", vazgeçilen bitirme) bu soru için kamera yeniden sorulur
            back = .question
            armCameraOffer()
        }
        closeListening()
        attemptFails = 0
        clearWarning("duyulan")
        accumulator.clear()
        englishAccumulator.clear()
        liveText = ""
        liveEnglish = ""
        deps.recorder.reset()
        phase = .speaking
        switch command {
        case .endSection:
            guard sectionIndex > 0 else {
                // Bölümsüz sınavda "bölümü tamamla": ne olduğu söylenir, aynı kipte dinlemeye dönülür
                tlog("[komut] sesli komut: bölümü tamamla; bu sınavda bölüm yok")
                let target = back
                work = Task { [weak self] in
                    guard let self = self, await self.speakNotice(Say.noSections) else { return }
                    self.beginListening(mode: target)
                }
                return
            }
            // Testi bitirmeyle aynı yol: önce onay, sonra bölümün cevapları okunur, sonra yeni bölüm sorulur
            tlog("[komut] sesli komut: bölümü tamamla; onay isteniyor")
            endReminders = 0
            endScope = .section
            endReturn = (from == .missingNumber || from == .passageTargets) ? from : .question
            let ask = from == .missingNumber ? Say.confirmSectionHeldQuestion : (from == .passageTargets ? Say.confirmSectionHeldPassage : Say.confirmSectionEnd)
            work = Task { [weak self] in
                guard let self = self, await self.speakNotice(ask) else { return }
                self.beginListening(mode: .confirmEnd)
            }
        case .endTest:
            // Yanlış tanımaya karşı önce onay istenir: "evet" bitirir, "hayır" (ya da cevapsızlık) devam ettirir
            tlog("[komut] sesli komut: testi bitir; onay isteniyor")
            endScope = .test
            endReminders = 0
            // Numara ya da paragraf numarası beklenirken söylendiyse bekleyen iş (tutulan soru / paragraf taslağı) korunur; vazgeçilirse oraya dönülür
            endReturn = (from == .missingNumber || from == .passageTargets) ? from : .question
            let ask = from == .missingNumber ? Say.confirmEndHeldQuestion : (from == .passageTargets ? Say.confirmEndHeldPassage : Say.confirmEnd)
            work = Task { [weak self] in
                guard let self = self, await self.speakNotice(ask) else { return }
                self.beginListening(mode: .confirmEnd)
            }
        case .repeatLast:
            tlog("[komut] sesli komut: son cevabı tekrarla")
            work = Task { [weak self] in
                guard let self = self else { return }
                guard await self.speakNotice(self.answers.last?.spoken ?? Say.nothingToReplay) else { return }
                self.beginListening()
            }
        case .replayAnswers:
            tlog("[komut] sesli komut: cevapları tekrarla")
            work = Task { [weak self] in await self?.beginReview(origin: .repeatRequest, returnTo: back) }
        case .repeatNumber(let number):
            tlog("[komut] sesli komut: \(number). sorunun cevabını tekrarla")
            let text = answers.first(where: { $0.number == number })?.spoken ?? Say.noAnswerFor(number)
            // Numara ya da paragraf numaraları beklenirken söylendiyse (tutulan soru / paragraf taslağı korunur) cevap okunduktan sonra aynı soru yeniden sorulur
            let waiting: ListenMode? = (from == .missingNumber || from == .passageTargets) ? from : nil
            work = Task { [weak self] in
                guard let self = self, await self.speakNotice(text) else { return }
                guard let target = waiting else {
                    self.beginListening()
                    return
                }
                guard await self.speakNotice(target == .missingNumber ? Say.reviewBackToNumber : Say.reviewBackToTargets) else { return }
                self.beginListening(mode: target)
            }
        case .cancelQuestion, .skipQuestion:
            // Okunan soru (metin ve ses kaydı yukarıda temizlendi) vazgeçilir; kamera sorusundayken silinecek bir şey yoktur.
            // "Soruyu atla" aynı işi yapar (yarım kalan ya da yanlış anlaşılan soru bırakılır, sıradaki okunur); yalnız söylenen cümle farklıdır.
            if from == .missingNumber, numberEdit != nil {
                work = Task { [weak self] in await self?.cancelNumberEdit() }   // numara düzeltme / silme sırasında "iptal": işlem bırakılır
                return
            }
            let skipping = command == .skipQuestion
            tlog(skipping ? "[komut] sesli komut: soruyu atla" : "[komut] sesli komut: soruyu iptal et")
            let choice = from == .cameraChoice || from == .passageCameraChoice || from == .captureKindChoice
            if from == .missingNumber {
                heldQuestion = nil   // numarası beklenen soru da bırakılır
                numberReminders = 0
            }
            let nothingToCancel = choice || !(from == .missingNumber || hadQuestionText)
            let notice: String
            if nothingToCancel {
                notice = skipping ? Say.nothingToSkipQuestion : Say.nothingToCancelQuestion
            } else if skipping {
                notice = cameraQuestionWillBeAsked ? Say.questionSkippedCamera : Say.questionSkipped
            } else {
                notice = cameraQuestionWillBeAsked ? Say.questionCancelledCamera : Say.questionCancelled
            }
            work = Task { [weak self] in
                guard let self = self, await self.speakNotice(notice) else { return }
                self.beginListening(mode: .question)
            }
        case .deleteLastQuestion:
            guard let target = lastRecordedAnswer else {
                tlog("[komut] sesli komut: son soruyu sil; silinecek kayıtlı soru yok")
                let waiting: ListenMode? = from == .missingNumber ? from : nil
                let returnMode = back
                work = Task { [weak self] in
                    guard let self = self, await self.speakNotice(Say.nothingToDeleteLast) else { return }
                    if let waiting = waiting {
                        guard await self.speakNotice(Say.reviewBackToNumber) else { return }
                        self.beginListening(mode: waiting)
                    } else {
                        self.beginListening(mode: returnMode)
                    }
                }
                return
            }
            // Geri alınamaz bir iş: önce onay istenir. "Evet" silmeyi tamamlar; "hayır", cevapsızlık ve anlaşılmayan söz silmez.
            tlog("[komut] sesli komut: son soruyu sil (soru \(target.number)); onay isteniyor")
            pendingDelete = target.number
            pendingDeleteChosen = false
            pendingEditSection = sectionIndex
            endReminders = 0
            endReturn = from == .missingNumber ? from : .question
            let promptSection = sectionIndex
            work = Task { [weak self] in
                guard let self = self, await self.speakNotice(Say.confirmDeleteLast(target.number, section: promptSection)) else { return }
                self.beginListening(mode: .confirmEnd)
            }
        case .deleteChosenQuestion, .renumberQuestion:
            startNumberEdit(command == .renumberQuestion ? .renumber : .delete)
        case .repeatSpeech, .help, .whatHeard, .deleteLast, .status, .missingAnswers, .report, .volume, .camera:
            break   // yukarıda ele alındı
        case .cancelPassage:
            let notice = cancelPassage(from: from, phraseOnly: phraseOnly)
            work = Task { [weak self] in
                guard let self = self, await self.speakNotice(notice) else { return }
                self.beginListening(mode: .question)
            }
        }
    }

    /// "Paragrafı iptal et": okunmakta ya da numaraları beklenen paragraf (taslak) vazgeçilir, taslağın video dosyası silinir; taslak yoksa
    /// kayıtlı ortak paragraf silinir. `phraseOnly`: "ortak paragrafı iptal et" diye başlandı (paragraf okunmaya hiç başlanmadı): kayıtlı
    /// paragrafı siler. Bu soru için kamera yeniden sorulur. Söylenecek cümle döner.
    private func cancelPassage(from mode: ListenMode, phraseOnly: Bool) -> String {
        armCameraOffer()
        let next = cameraQuestionWillBeAsked
        if mode == .passageTargets || mode == .passageCameraChoice || (mode == .passage && !phraseOnly) {
            tlog("[komut] sesli komut: paragrafı iptal et (okunan paragraf bırakıldı)")
            passageDraft = nil
            targetReminders = 0
            targetDoneReminders = 0
            return Say.passageCancelled(cameraNext: next)
        }
        if passage != nil {
            tlog("[komut] sesli komut: paragrafı iptal et (kayıtlı ortak paragraf silindi)")
            passage = nil
            return Say.storedPassageCancelled(cameraNext: next)
        }
        return Say.noPassageToCancel(cameraNext: next)
    }

    /// "Testi bitirmek istiyor musunuz?" sorusuna cevap: evet bitirir (önce cevaplar okunur), hayır devam ettirir
    private func fireConfirmEnd() {
        if interpret(VoiceCommand.parse) == .replayAnswers {
            fireVoiceCommand()
            return
        }
        guard let reply = interpret(SpokenReply.yesNo) else { return }
        clearWarning("duyulan")
        closeListening()
        accumulator.clear()
        englishAccumulator.clear()
        liveText = ""
        liveEnglish = ""
        deps.recorder.reset()
        phase = .speaking
        if let renumber = pendingRenumber {
            confirmRenumber(renumber, reply: reply)
            return
        }
        if let number = pendingDelete {
            confirmDeleteLast(number, reply: reply)
            return
        }
        switch reply {
        case .yes:
            let count = answers.count
            let reading = settings.readAnswersAtEnd && count > 0
            let what = endScope == .section ? "bölümü tamamlama" : "testi bitirme"
            tlog("[komut] \(what) onaylandı (\(count) cevap\(reading ? ", cevaplar okunacak" : ""))")
            // Prosedür: bitirmeden önce kaydedilen cevaplar sırayla okunur, ardından "Devam, Tekrar ya da Bitir" sorulur (Modül 6)
            work = Task { [weak self] in
                guard let self = self else { return }
                if reading {
                    await self.beginReview(origin: .endRequest, returnTo: self.endReturn)
                } else {
                    await self.finishEnding()
                }
            }
        case .no:
            tlog(endScope == .section ? "[komut] bölümü tamamlamaktan vazgeçildi" : "[komut] testi bitirmekten vazgeçildi")
            work = Task { [weak self] in
                guard let self = self, await self.speakNotice(self.endCancelledNotice) else { return }
                self.beginListening(mode: self.endReturn)
            }
        }
    }

    /// En son kaydedilen soru ("son soruyu sil" bunu siler). Önce kaydedilme sırasına, yoksa en büyük numaraya bakılır.
    var lastRecordedAnswer: AnswerRecord? {
        for number in answerOrder.reversed() {
            if let record = answers.first(where: { $0.number == number }) { return record }
        }
        return answers.last
    }

    /// "Son soruyu silmek istiyor musunuz?" sorusuna cevap: evet kaydı siler, hayır (ya da cevapsızlık) hiçbir şeyi silmez
    private func confirmDeleteLast(_ number: Int, reply: SpokenReply.YesNo) {
        let chosen = pendingDeleteChosen
        let section = pendingEditSection
        pendingDelete = nil
        pendingDeleteChosen = false
        if chosen {
            confirmChosenDelete(number, section: section, reply: reply)   // kullanıcının seçtiği soru (bölüm ve numara söylendi)
            return
        }
        switch reply {
        case .yes:
            tlog("[komut] son soruyu silme onaylandı (soru \(number))")
            deleteRecordedQuestion(number)
            if endReturn != .missingNumber { armCameraOffer() }   // silinen soru yeniden okunacak: kamera açıksa o soru için yeniden sorulur
            let notice = endReturn == .missingNumber ? Say.lastQuestionDeleted(number, cameraNext: true) + " " + Say.reviewBackToNumber
                : Say.lastQuestionDeleted(number, cameraNext: cameraQuestionWillBeAsked)
            work = Task { [weak self] in
                guard let self = self, await self.speakNotice(notice) else { return }
                self.beginListening(mode: self.endReturn)
            }
        case .no:
            tlog("[komut] son soruyu silmekten vazgeçildi (soru \(number)); hiçbir şey silinmedi")
            work = Task { [weak self] in
                guard let self = self, await self.speakNotice(self.deleteCancelledNotice) else { return }
                self.beginListening(mode: self.endReturn)
            }
        }
    }

    /// Silme vazgeçilince ya da onay cevapsız kalınca söylenen cümle
    private var deleteCancelledNotice: String {
        if endReturn == .missingNumber { return Say.deleteCancelledCamera + " " + Say.reviewBackToNumber }
        return cameraQuestionWillBeAsked ? Say.deleteCancelledCamera : Say.deleteCancelled
    }

    /// Soru kaydını siler: cevap satırı, düz yazı satırı, ses dosyası ve ana ekrandaki satır. Sıradaki numara silinen soruya geri döner (soru yeniden okunur).
    /// `clearPending`: telefonda bekleyen (gönderilmemiş) iş de bırakılır; yalnız en son sorunun silinmesinde doğrudur. Eski bir soruyu silerken
    /// bekleyen iş başka bir soruya aittir ve korunur.
    func deleteRecordedQuestion(_ number: Int, clearPending: Bool = true) {
        answers.removeAll { $0.number == number }
        answerOrder.removeAll { $0 == number }
        if let folder = sessionFolder {
            deps.library.removeExisting(question: number, in: folder)
            if !deps.library.removeTranscript(number: number, in: folder) { warn("yazi", Say.transcriptFailed) }
        }
        questions.removeAll { entry in
            guard entry.number == number else { return false }
            if case .answered = entry.state { return true }
            return false
        }
        if unheard?.number == number { unheard = nil }
        if clearPending { deps.journal.savePending(nil) }
        if nextNumber == number + 1 {
            nextNumber = number
            deps.journal.saveNextNumber(number)
            carry?.nextNumber = number
        }
        refreshReplayAvailability()
        tlog("[kayıt] soru \(number) silindi (cevap, düz yazı satırı ve ses dosyası)")
    }

    /// "Testi bitir" onayından vazgeçilince (ya da onay cevapsız kalınca) söylenen cümle: bekleyen numara / paragraf numarası varsa ona dönüldüğü söylenir
    private var endCancelledNotice: String {
        switch endReturn {
        case .missingNumber: return Say.reviewBackToNumber
        case .passageTargets: return Say.reviewBackToTargets
        default:
            if endScope == .section { return cameraQuestionWillBeAsked ? Say.sectionEndCancelledCamera : Say.sectionEndCancelled }
            return cameraQuestionWillBeAsked ? Say.endCancelledCamera : Say.endCancelled
        }
    }

    /// Evet/hayır ya da devam/yeni beklenirken anlaşılmayan kısa bir söz duyuldu: 30 sn beklemeden yeniden sorulur
    private func scheduleChoiceUnclear() {
        guard accumulator.text.split(whereSeparator: { $0.isWhitespace }).count <= 8 else { return }
        confirmTask = deps.scheduler.after(Timing.numberUnclear) { [weak self] in self?.choiceUnclear() }
    }

    func choiceUnclear() {
        confirmTask = nil
        guard phase == .listening, [ListenMode.confirmEnd, .startChoice, .reviewMenu, .cameraChoice, .passageCameraChoice, .captureKindChoice, .nextSectionChoice].contains(listenMode) else { return }
        let heard = accumulator.text
        if listenMode == .confirmEnd, interpret(SpokenReply.yesNo) != nil { return }
        if listenMode == .startChoice, interpret(SpokenReply.start) != nil { return }
        if listenMode == .reviewMenu, interpret(SpokenReply.review) != nil { return }
        if listenMode == .cameraChoice, interpret(SpokenReply.cameraChoice) != nil || spokenCommand() != nil { return }
        if listenMode == .passageCameraChoice, interpret(SpokenReply.cameraChoice) != nil || spokenCommand() != nil { return }
        if listenMode == .captureKindChoice, interpret(SpokenReply.captureKind) != nil || spokenCommand() != nil { return }
        if listenMode == .nextSectionChoice, interpret(SpokenReply.nextSection) != nil { return }
        tlog("[komut] cevap anlaşılamadı; duyulan: \"\(heard)\"")
        warn("duyulan", "Duyulan: “\(heard)”. Cevap anlaşılamadı.")
        work = Task { [weak self] in await self?.choiceSilence(unclear: true) }
    }

    /// Cevap gelmedi ("evet/hayır" ya da "devam/yeni" denmedi): testi bitirme sorusunda bitirilmez; başlangıç sorusunda bir kez hatırlatılır,
    /// yine olmazsa varsayılan uygulanır (önceki kayıt 12 saatten yeniyse devam, değilse yeni sınav)
    /// `unclear`: bir şey söylendi ama anlaşılmadı (hiç ses gelmediyse false)
    func choiceSilence(unclear: Bool = false) async {
        closeListening()
        phase = .speaking
        switch listenMode {
        case .confirmEnd:
            endReminders += 1
            if let renumber = pendingRenumber {
                await renumberSilence(renumber)
                return
            }
            if let number = pendingDelete {
                if endReminders <= Timing.choiceReminderLimit {
                    guard await speakNotice(Say.reask(Say.confirmDeleteLastAgain(number, section: pendingEditSection), attempt: endReminders + 1)) else { return }
                    beginListening(mode: .confirmEnd)
                } else {
                    tlog("[komut] silme sorusu cevapsız kaldı; hiçbir şey silinmedi")
                    clearWarning("duyulan")
                    pendingDelete = nil
                    pendingDeleteChosen = false
                    guard await speakNotice(deleteCancelledNotice) else { return }
                    beginListening(mode: endReturn)
                }
                return
            }
            if endReminders <= Timing.choiceReminderLimit {
                let again = endScope == .section ? Say.confirmSectionEndAgain : Say.confirmEndAgain
                guard await speakNotice(Say.reask(again, attempt: endReminders + 1)) else { return }
                beginListening(mode: .confirmEnd)
            } else {
                tlog(endScope == .section ? "[komut] bölümü tamamlama sorusu cevapsız kaldı; bölüm devam ediyor" : "[komut] testi bitirme sorusu cevapsız kaldı; test devam ediyor")
                clearWarning("duyulan")
                guard await speakNotice(endCancelledNotice) else { return }
                beginListening(mode: endReturn)
            }
        case .startChoice:
            choiceReminders += 1
            if choiceReminders <= Timing.choiceReminderLimit {
                guard await speakNotice(Say.reask(Say.askChoiceAgain, attempt: choiceReminders + 1)) else { return }
                beginListening(mode: .startChoice)
            } else {
                await applyStartChoice(continuePrevious: choiceOffer?.recent ?? true)
            }
        case .reviewMenu:
            await reviewSilence()
        case .cameraChoice:
            await cameraChoiceSilence(unclear: unclear)
        case .passageCameraChoice:
            await passageCameraChoiceSilence()
        case .captureKindChoice:
            await captureKindSilence(unclear: unclear)
        case .nextSectionChoice:
            await nextSectionSilence()
        default:
            beginListening(mode: .question)
        }
    }

    /// "Önceki kayıttan devam mı, yeni sınav mı?" sorusuna cevap
    private func fireStartChoice() {
        guard let reply = interpret(SpokenReply.start) else { return }
        clearWarning("duyulan")
        closeListening()
        phase = .speaking
        work = Task { [weak self] in await self?.applyStartChoice(continuePrevious: reply == .continuePrevious) }
    }

    /// Devam: önceki klasör ve numara korunur, önceki cevaplar yüklenir. Yeni: yeni klasör, numara 1.
    func applyStartChoice(continuePrevious: Bool) async {
        let offer = choiceOffer
        clearWarning("duyulan")
        choiceOffer = nil
        choiceReminders = 0
        var goOn = continuePrevious
        if !goOn {
            do {
                // Yeni sınav kendi klasörünü alır (adı o anın tarihi ve saati); bölüm ayarlıysa 1. bölümle başlanır
                let exam = try deps.library.newSessionFolder(for: deps.now())
                try place(exam: exam, section: sectionPlan.isEmpty ? 0 : 1)
                nextNumber = 1
                answers = []
                answerOrder = []
                deps.journal.saveNextNumber(1)
                saveLocation()
                carry = nil
                tlog("[açılış] yeni sınav seçildi: yeni klasör, numara 1")
            } catch {
                goOn = true
                warn("klasor", "Yeni klasör açılamadı: \(error.localizedDescription). Önceki kayıttan devam ediliyor.")
            }
        }
        if goOn {
            if let folder = sessionFolder {
                answers = deps.library.transcriptRecords(in: folder)
                answerOrder = answers.map { $0.number }
            }
            deps.journal.saveNextNumber(nextNumber)
            tlog("[açılış] önceki kayıttan devam: \(offer?.answers ?? answers.count) cevap, sıradaki soru \(nextNumber)")
        }
        armCameraOffer()   // Sürüm 4: önceki kayıttan devam da olsa yeni sınav da olsa ilk soru için kamera sorulur
        let camera = cameraQuestionWillBeAsked
        var text = goOn ? Say.continuingPrevious(next: nextNumber, camera: camera) : (camera ? Say.startingNewCamera : Say.startingNew)
        if sectionIndex > 0 {
            // Bölümlü sınav: yeni sınavda ilk bölüme başlandığı, önceki kayıttan devamda hangi bölümde olunduğu söylenir
            text += " " + (goOn ? Say.sectionHere(sectionIndex, questions: sectionQuestionCount) : Say.sectionStart(sectionIndex, questions: sectionQuestionCount))
        }
        guard await speakNotice(text) else { return }
        beginListening(mode: .question)
    }

    private func fireQuestion() {
        guard let match = TriggerDetector.match(in: accumulator.text) else { return }
        // "Testi bitir, Cevapla": komut kısmı soru gibi gönderilmez
        if let command = commandIn(match.question) {
            if command.isInfo {
                // "Durum, Cevapla" gibi: komut soru gibi gönderilmez; komuttan önceki soru metni korunur
                let whole = VoiceCommand.parseLenient(match.question) == command
                var question = ""
                if whole {
                    accumulator.clear()
                } else {
                    accumulator.dropWords(from: utteranceStart)
                    question = accumulator.text
                }
                liveText = accumulator.text
                performInfo(command, question: question, keepText: !question.isEmpty)
                return
            }
            run(command)
            return
        }
        guard !match.question.isEmpty else {
            // Yalnız "cevapla" denmiş: boş soru gönderilmez; sesteki "cevapla" sözcüğü bir sonraki soruya karışmasın. Kullanıcıya söylenir:
            // soru duyulmadıysa (okunmadı ya da tanıyıcı kaçırdı) sessizce beklemek "program anlamıyor" izlenimi verir.
            closeListening()
            accumulator.clear()
            englishAccumulator.clear()
            liveText = ""
            liveEnglish = ""
            deps.recorder.reset()
            phase = .speaking
            tlog("[soru] yalnız tetikleyici duyuldu; soru metni yok")
            work = Task { [weak self] in
                guard let self = self, await self.speakNotice(Say.noQuestionHeard) else { return }
                self.beginListening(mode: .question)
            }
            return
        }
        // Mikrofon duraklar, tetikleyici sözcük metinden kırpılmıştır; ses kaydı da bu andan sonra durur
        let audio: Data? = settings.sendAudio ? deps.recorder.wavData() : nil
        let english = settings.englishDictation ? englishAccumulator.text : ""
        let question = match.question
        closeListening()
        attemptFails = 0
        clearWarning("duyulan")
        liveText = question
        // Kayıt, okunan numarayla yapılır: kullanıcı soruları sırayla okumak zorunda değildir
        let spoken = SpokenNumber.extract(from: question, limit: numberLimit)
        if spoken == nil, settings.askMissingNumber {
            heldQuestion = HeldQuestion(text: question, english: english, audio: audio)
            numberReminders = 0
            tlog("[soru] numara okunmadı; numara isteniyor")
            phase = .speaking
            work = Task { [weak self] in await self?.askForNumber(again: false) }
            return
        }
        phase = .answering
        statusNote = ""
        send(question: question, english: english, audio: audio, number: spoken, numberSpoken: true)
    }

    /// "Lütfen okuduğunuz sorunun numarasını söyleyin" der ve numarayı dinler
    func askForNumber(again: Bool, attempt: Int = 2) async {
        guard heldQuestion != nil else { return }
        let ask = again ? Say.reask(sectionQuestionCount > 0 ? Say.askNumberAgainInSection(sectionQuestionCount) : Say.askNumberAgain, attempt: attempt) : Say.askNumber
        guard await speakNotice(ask) else { return }
        beginListening(mode: .missingNumber)
    }

    /// Numara duyuldu ("soru yedi") ya da "sıradaki" denildi: bekleyen soru numarası başa yazılarak Gemini'ye gider
    private func fireNumber() {
        if let edit = numberEdit {
            fireEditNumber(edit)   // numara düzeltme / istenen soruyu silme: söylenen numara ya da bölüm
            return
        }
        guard let held = heldQuestion else {
            listenMode = .question
            return
        }
        let number: Int
        switch numberReply() {
        case .number(let heard)?: number = heard
        case .sequence?: number = nextNumber
        case nil: return
        }
        closeListening()
        heldQuestion = nil
        numberReminders = 0
        listenMode = .question
        liveText = held.text
        phase = .answering
        statusNote = ""
        clearWarning("numara")
        tlog("[soru] numara söylendi: \(number)")
        send(question: held.text, english: held.english, audio: held.audio, number: number, numberSpoken: false)
    }

    /// Numara beklenirken duyulan söz numara değildi: ne duyulduğu ekranda yazılır, numara yeniden sorulur
    func numberUnclear() {
        confirmTask = nil
        guard phase == .listening, listenMode == .missingNumber, heldQuestion != nil || numberEdit != nil else { return }
        let heard = accumulator.text
        guard !numberHeard() else { return }
        tlog("[soru] numara anlaşılamadı; duyulan: \"\(heard)\"")
        warn("numara", "Duyulan: “\(heard)”. Numara anlaşılamadı.")
        if let edit = numberEdit {
            work = Task { [weak self] in await self?.editReprompt(edit, heard: true) }   // bir şey söylendi ama anlaşılmadı: "Anlayamadım, ikinci defa soruyorum"
            return
        }
        work = Task { [weak self] in await self?.numberSilence() }
    }

    /// Numara hiç söylenmeden sessizlik sürerse: hatırlatılır; yine olmazsa eski davranış (sıradaki numara) uygulanır, soru kaybolmaz
    func numberSilence() async {
        if let edit = numberEdit {
            await editReprompt(edit, heard: false)
            return
        }
        guard let held = heldQuestion else { return }
        numberReminders += 1
        guard numberReminders <= Timing.numberReminderLimit else {
            closeListening()
            heldQuestion = nil
            numberReminders = 0
            listenMode = .question
            liveText = held.text
            phase = .answering
            statusNote = ""
            tlog("[soru] numara söylenmedi; sıradaki numara verilerek gönderiliyor")
            send(question: held.text, english: held.english, audio: held.audio, number: nil, numberSpoken: true)
            return
        }
        deps.listener.pause()
        watchdog.disarm()
        phase = .speaking
        await askForNumber(again: true, attempt: numberReminders + 1)
    }

    /// "Ortak paragraf" denip beklendi: "Lütfen ortak paragrafı okuyun, bitince Tamam deyin" der ve paragrafı dinler
    private func firePassagePrompt() {
        confirmTask = nil
        guard phase == .listening, listenMode == .passage,
              PassageCommand.startsWith(accumulator.text), PassageCommand.stripStart(accumulator.text).isEmpty else { return }
        closeListening()
        accumulator.clear()
        englishAccumulator.clear()
        liveText = ""
        liveEnglish = ""
        deps.recorder.reset()
        phase = .speaking
        tlog("[paragraf] ortak paragraf komutu duyuldu; paragrafı okuması isteniyor")
        work = Task { [weak self] in
            guard let self = self else { return }
            // Sürüm 4: kamera hazırsa paragraf sesle mi okunacak, kamerayla mı çekilecek önce sorulur
            if self.cameraOfferAvailable {
                guard await self.speakNotice(Say.askPassageCamera) else { return }
                self.beginListening(mode: .passageCameraChoice)
                return
            }
            guard await self.speakNotice(Say.passagePrompt) else { return }
            self.beginListening(mode: .passage)
        }
    }

    /// "Tamam" denince ortak paragraf alınır; hangi sorulara ait olduğu sorulur
    private func firePassage() {
        guard let match = TriggerDetector.match(in: accumulator.text, words: PassageCommand.finishWords) else { return }
        let text = PassageCommand.stripStart(match.question)
        let english = settings.englishDictation ? englishAccumulator.text : ""
        let audio: Data? = settings.sendAudio ? deps.recorder.wavData() : nil
        let audioTruncated = audio != nil && deps.recorder.truncated
        closeListening()
        liveText = ""
        phase = .speaking
        guard !text.isEmpty else {
            listenMode = .question
            tlog("[paragraf] paragraf metni boş kaldı")
            work = Task { [weak self] in
                guard let self = self, await self.speakNotice(Say.passageEmpty) else { return }
                self.beginListening(mode: .question)
            }
            return
        }
        passageDraft = PassageDraft(text: text, english: english, audio: audio, audioTruncated: audioTruncated)
        targetReminders = 0
        targetDoneReminders = 0
        listenMode = .passageTargets
        tlog("[paragraf] ortak paragraf alındı (\(text.count) karakter); hangi sorulara ait olduğu soruluyor")
        work = Task { [weak self] in
            guard let self = self, await self.speakNotice(Say.passageTaken) else { return }
            self.beginListening(mode: .passageTargets)
        }
    }

    /// Paragrafın ait olduğu soru numaraları ("beş altı yedi, Cevapla") alınır; paragraf o sorularla birlikte gider
    private func fireTargets() {
        guard let match = interpret({ TriggerDetector.match(in: $0, words: PassageCommand.targetWords) }) else { return }
        finishTargets(numbers: bestNumbers(primary: SpokenNumber.list(from: match.question, limit: numberLimit)), heard: match.question)
    }

    /// Paragraf numaraları belli oldu (ya da anlaşılamadı): kaydedilir; anlaşılamadıysa sınırlı sayıda yeniden sorulur, sonra sıradaki soruya bağlanır
    func finishTargets(numbers given: [Int], heard: String) {
        var numbers = given
        closeListening()
        liveText = ""
        phase = .speaking
        guard let draft = passageDraft else {
            listenMode = .question
            work = Task { [weak self] in self?.beginListening(mode: .question) }
            return
        }
        var notice: String?
        if numbers.isEmpty {
            targetReminders += 1
            tlog("[paragraf] soru numaraları anlaşılamadı (deneme \(targetReminders)); duyulan: \"\(heard)\"")
            warn("numara", "Duyulan: “\(heard)”. Soru numaraları anlaşılamadı.")
            guard targetReminders > Timing.targetReminderLimit else {
                work = Task { [weak self] in
                    guard let self = self, await self.speakNotice(Say.reask(Say.passageTargetsAgain, attempt: self.targetReminders + 1)) else { return }
                    self.beginListening(mode: .passageTargets)
                }
                return
            }
            // Üst üste anlaşılamadı: sonsuz tekrar yerine paragraf sıradaki soruya bağlanır ve bu açıkça söylenir
            numbers = [nextNumber]
            notice = Say.passageFallback(nextNumber, cameraNext: cameraNextAfterPassage)
            tlog("[paragraf] numaralar anlaşılamadı; paragraf sıradaki soruya (\(nextNumber)) bağlandı")
        }
        targetReminders = 0
        targetDoneReminders = 0
        clearWarning("numara")
        // Önce paragraf kurulur, sonra taslak boşaltılır: kamerayla çekilen görüntülerin video dosyası taslaktan paragrafa geçer, silinmez
        passage = PassageContext(text: draft.text, english: draft.english, audio: draft.audio, all: numbers, remaining: numbers,
                                 audioTruncated: draft.audioTruncated, shot: draft.shot)
        passageDraft = nil
        listenMode = .question
        tlog("[paragraf] ortak paragraf \(QuestionComposer.listText(numbers)) numaralı sorular için kaydedildi\(draft.shot == nil ? "" : " (kamerayla, görüntü olarak)")")
        // Paragraf sorusu kamera sorusunun yerine geçmişti: bu soru için ("hayır" denmediyse) kamera yeniden sorulur
        if !cameraOfferSuppressed { offerCamera = cameraOfferAvailable }
        let spokenNotice = notice ?? Say.passageReady(numbers, cameraNext: cameraNextAfterPassage)
        work = Task { [weak self] in
            guard let self = self, await self.speakNotice(spokenNotice) else { return }
            self.beginListening(mode: .question)
        }
    }

    /// Soruyu (varsa ortak paragrafıyla ve başına numarası yazılarak) Gemini'ye yollar
    func send(question: String, english: String, audio: Data?, number: Int?, numberSpoken: Bool, ack: Bool = true) {
        var text = question
        if let number = number, !numberSpoken { text = QuestionComposer.numbered(question, number: number) }
        var englishOut = english
        var audioOut = audio
        let effective = number ?? nextNumber
        var passageMedia: PassageMedia?
        if let context = passage, context.remaining.contains(effective) {
            if let shot = context.shot {
                // Paragraf kamerayla çekilmişti: yazı yerine görüntüleri (fotoğraf + video) soruyla birlikte gider
                text = QuestionComposer.withCameraPassage(question: text, passage: context)
                passageMedia = PassageMedia(shot)
                tlog("[paragraf] soru \(effective) ortak paragrafın görüntüleriyle birlikte gönderiliyor")
            } else {
                let joined = AudioJoin.join(passage: context.audio, question: audio)
                text = QuestionComposer.withPassage(question: text, passage: context, audioCombined: joined.combined)
                englishOut = QuestionComposer.english(passage: context, question: english)
                if joined.data != nil { audioOut = joined.data }
                tlog("[paragraf] soru \(effective) ortak paragrafla birlikte gönderiliyor")
            }
        }
        dispatchQuestion(text, english: englishOut, audio: audioOut, spokenNumber: number, display: question, ack: ack, passage: passageMedia)
    }

    /// Soruyu listeye işler, "yarım kalan iş" olarak deftere yazar (uygulama bu arada kapanırsa yeniden sorulur) ve Gemini'ye gönderir.
    /// `display`: listede görünen metin (ortak paragraf eklenmiş hâli değil). `ack`: "soru gönderildi" anonsu yapılır mı.
    func dispatchQuestion(_ question: String, english: String, audio: Data?, spokenNumber: Int?, display: String? = nil, ack: Bool = false,
                          passage passageMedia: PassageMedia? = nil) {
        let announced = spokenNumber ?? nextNumber
        beginEntry(text: display ?? question, withAudio: audio != nil, number: announced)
        deps.journal.savePending(PendingWork(question: question, english: english, spokenNumber: spokenNumber, number: nil, spoken: nil,
                                             withPassagePhoto: passageMedia == nil ? nil : true))
        let withPassageImages = passageMedia == nil ? "" : "; paragraf görüntüsüyle"
        tlog("[soru \(announced)] Gemini'ye gönderildi (\(audio != nil ? "ses kaydıyla" : "yalnız metin"), \(question.count) karakter; numara \(spokenNumber != nil ? "okundu" : "okunmadı, sıradaki")\(withPassageImages))")
        work = Task { [weak self] in await self?.answer(question: question, english: english, audio: audio, spokenNumber: spokenNumber, passageMedia: passageMedia) }
        if ack, settings.spokenProgress { speakProgress(passageMedia == nil ? Say.questionSent : Say.questionSentWithPassage) }
        startAnswerWait()
    }

    /// Beklenmedik kapanmadan önce Gemini'ye gitmiş soru yeniden sorulur (ses kaydı kaybolduğu için yalnız metinle); cevabı alınmış ama
    /// duyulmamışsa yalnız cevap yeniden okunur
    func resumePending(_ pending: PendingWork) async {
        if let spoken = pending.spoken, let number = pending.number {
            tlog("[soru \(number)] kapanmadan önce alınan cevap yeniden okunuyor")
            guard await speakNotice(spoken) else { return }
            guard await promptNextQuestion() else { return }
            beginListening()
            return
        }
        phase = .answering
        statusNote = ""
        liveText = pending.question
        tlog("[soru] kapanmadan önce gönderilen soru yeniden soruluyor (yalnız metin)")
        // Soru kamerayla çekilmiş paragrafın görüntüleriyle gitmişse, geri yüklenen paragraf fotoğrafı yine eklenir (video kapanmada kayboldu)
        let media = pending.withPassagePhoto == true ? passage?.shot.map { PassageMedia($0) } : nil
        dispatchQuestion(pending.question, english: pending.english, audio: nil, spokenNumber: pending.spokenNumber, passage: media)
    }

    // MARK: Cevaplama ve seslendirme (Modül 5)

    func answer(question: String, english: String = "", audio: Data?, spokenNumber: Int? = nil,
                passageMedia: PassageMedia? = nil, fetch: (() async throws -> GeminiReply)? = nil) async {
        do {
            let reply: GeminiReply
            if let fetch = fetch {
                reply = try await fetch()   // Sürüm 4: kamera ile çekilen soru (görüntü + video) kendi isteğini yapar
            } else {
                reply = try await deps.answering.answer(question: question, english: english, expectedNumber: spokenNumber ?? nextNumber, audio: audio,
                                                        passage: passageMedia)
            }
            guard !Task.isCancelled, phase == .answering else { return }
            if reply.spoken.isEmpty, reply.number == nil {
                await finishEmptyPage()   // sayfada soru yok: cevap yok, numara tüketilmez
                return
            }
            // Numara önceliği: kullanıcının okuduğu (dikte metninden) > Gemini'nin metinden/sesten okuduğu > sıradaki
            let number = spokenNumber ?? reply.number ?? nextNumber
            let source: QuestionEntry.NumberSource = spokenNumber != nil ? .spoken : (reply.number != nil ? .heard : .sequence)
            nextNumber = number + 1
            // Cevap cümlesi (kulaklıktan okunan ve dosyaya yazılan) her zaman kaydedilen numarayı taşır
            let spoken = reply.number == number ? reply.spoken : AnswerParser.spokenLine(number: number, option: reply.option, text: reply.text, fallback: reply.spoken)
            let record = AnswerRecord(number: number, option: reply.option, text: reply.text, spoken: spoken)
            tlog("[soru \(number)] numara kaynağı: \(source.logName)")
            finishEntry(.answered(record.spoken), number: number, model: reply.model, source: source)
            retriedShots.removeAll()   // internet ve Gemini çalışıyor: telefonda bekleyen çekimler yeniden denenebilir (bkz. resendablePending)
            // Cevap yedek profilden geldiyse sebebi kırmızı kutuda yazılır; ilk profilden gelince silinir
            // Ekranda ayrıntılı not (sunucunun hata metinleri dahil) kalır; kulaklıktan hangi modelin cevapladığı söylenmez, yalnız
            // ücretli modelden geldiyse "Ücretli modelden cevaplandı." denir (hata metinleri hiç okunmaz)
            if reply.note.isEmpty {
                clearWarning("yedek")
            } else {
                let changed = warnings.first(where: { $0.id == "yedek" })?.text != reply.note
                warn("yedek", reply.note)
                if changed, !reply.spokenNote.isEmpty { announce(reply.spokenNote) }
            }
            let replacing = answers.contains { $0.number == number }   // aynı numaralı eski cevap ezilecek mi (numara yanlış okunmuş olabilir)
            store(record)
            if replacing {
                tlog("[soru \(number)] bu numaranın önceki cevabı yenisiyle değiştirildi")
                announce(Say.answerReplaced(number))
            }
            completePassage(for: number)
            deps.journal.saveNextNumber(nextNumber)
            deps.journal.savePending(PendingWork(question: question, english: english, spokenNumber: spokenNumber, number: number, spoken: record.spoken))
            phase = .speaking
            unheard = record
            var base: URL?
            if let folder = sessionFolder {
                deps.library.removeExisting(question: number, in: folder)
                base = deps.library.fileBase(question: number, in: folder)
            }
            if let task = voiceTask { await task.value }   // çalan bir uyarı varsa bitsin, üst üste konuşulmasın
            guard !Task.isCancelled, phase == .speaking else { return }
            speechSealed = true   // cevap yeni bir "son söz" grubu başlatır: "gönderildi, bekleniyor" gibi ara anonslar "bir daha söyle" ile tekrarlanmaz
            rememberSpeech(record.spoken)
            try await deps.speaker.speak(record.spoken, saveAs: base)
            // Okuma durdurulduysa (duraklatma, kulaklık kopması) cevap duyulmamış sayılır; devam edince yeniden okunur
            guard !Task.isCancelled else { return }
            unheard = nil
            clearWarning("cevap")
            clearWarning("ses")
            verifyRecording(number: number, requested: base != nil)
            refreshReplayAvailability()
            await settleAnnouncements()   // cevap duyulduktan sonra bekleyen uyarılar (şarj, ücretli model…) söylenir
            guard !Task.isCancelled, phase == .speaking else { return }
            // Toplu çekimde bir sayfanın kalan cevapları: "sonraki soruyu okuyun" denmeden sırayla okunur
            if pageBeingRead != nil, !queuedReplies.isEmpty {
                await readNextQueuedReply()
                return
            }
            completeReadPage()
            guard await promptNextQuestion() else { return }   // "Lütfen sonraki soruyu okuyun"; yarıda kesilirse akışı duraklama/onarım sürdürür
            beginListening()
        } catch is CancellationError {
            return
        } catch let error as SpeakError {
            await handleSpeakError(error)
        } catch let error as GeminiError {
            guard !Task.isCancelled else { return }   // iptal edilen istek (bekleme sınırı, duraklatma) onarım başlatmaz
            await handleGeminiError(error)
        } catch {
            guard !Task.isCancelled else { return }
            finishEntry(.failed(error.localizedDescription))
            warn("cevap", error.localizedDescription)
            if phase == .answering || phase == .speaking, await speakNotice(Say.answerFailed) { beginListening() }
        }
    }

    // MARK: Soru listesi (ana ekran)

    /// Tetikleyiciyle yüklenen soru listeye "gönderiliyor" işaretiyle girer
    func beginEntry(text: String, withAudio: Bool, number: Int? = nil) {
        abandonEntry("Cevap alınamadı. Soruyu yeniden okuyun.")
        entrySeq += 1
        currentEntry = entrySeq
        questions.append(QuestionEntry(id: entrySeq, text: text, withAudio: withAudio, number: number ?? nextNumber))
    }

    /// Giden sorunun işaretini günceller (cevap geldi / gitmedi)
    func finishEntry(_ state: QuestionEntry.State, number: Int? = nil, model: String = "", source: QuestionEntry.NumberSource? = nil) {
        guard let id = currentEntry, let index = questions.firstIndex(where: { $0.id == id }) else { return }
        questions[index].state = state
        switch state {
        case .answered: tlog("[soru \(number ?? questions[index].number)] cevap geldi (\(model))")
        case .failed(let reason):
            tlog("[soru \(questions[index].number)] gitmedi: \(reason)")
            deps.journal.savePending(nil)   // kullanıcıdan soruyu yeniden okuması istenir; yarım kalan iş kalmaz
        case .sending: break
        }
        if let number = number { questions[index].number = number }
        if let source = source { questions[index].numberSource = source }
        if !model.isEmpty { questions[index].model = model }
        currentEntry = nil
    }

    /// Cevabı gelmeden iş kesildiyse satır "gitmedi" olur
    func abandonEntry(_ reason: String) {
        if currentEntry != nil { finishEntry(.failed(reason)) }
    }

    private func store(_ record: AnswerRecord) {
        if let index = answers.firstIndex(where: { $0.number == record.number }) {
            answers[index] = record
        } else {
            answers.append(record)
            answers.sort { $0.number < $1.number }
        }
        answerOrder.removeAll { $0 == record.number }
        answerOrder.append(record.number)
        if let folder = sessionFolder, !deps.library.upsertTranscript(record.spoken, number: record.number, in: folder) {
            warn("yazi", Say.transcriptFailed)
        }
    }

    private func handleSpeakError(_ error: SpeakError) async {
        switch error {
        case .stopped:
            break
        case .routeUnsafe:
            enterHardwarePause(AudioRouting.verdict(deps.route.snapshot()))
        case .failed(let message):
            warn("ses", message)
            guard phase == .speaking else { return }
            // Cevap duyulmadan geçilmesin (sınavda cevap kaybı olur): bir kez, kayıtsız (dosya yazmadan) yeniden okunur.
            // Yine olmazsa cevabın metni kırmızı kutuda kalır; sesli söylenemediği için ayrıca anons edilmez.
            if let record = unheard {
                await deps.sleep(Timing.speakRetryDelay)
                guard !Task.isCancelled, phase == .speaking else { return }
                do {
                    try await deps.speaker.speak(record.spoken, saveAs: nil)
                    unheard = nil
                    clearWarning("ses")
                    tlog("[ses] okuma ikinci denemede oldu: soru \(record.number)")
                    verifyRecording(number: record.number, requested: sessionFolder != nil)   // yeniden okuma dosya yazmaz: eksikse kırmızı kutuda görünür
                    refreshReplayAvailability()
                } catch SpeakError.routeUnsafe {
                    enterHardwarePause(AudioRouting.verdict(deps.route.snapshot()))
                    return
                } catch SpeakError.failed(_) {
                    warn("cevap", "Cevap okunamadı: \(record.spoken)")
                    tlog("[ses] okuma ikinci denemede de olmadı: soru \(record.number)")
                } catch {
                    return
                }
            }
            guard !Task.isCancelled, phase == .speaking else { return }
            guard await promptNextQuestion() else { return }
            beginListening()
        }
    }

    /// Cevabın ses dosyası klasöre gerçekten yazıldı mı: yazılamadıysa (yer doldu, klasör erişimi gitti) kırmızı kutuda ve kulaklıktan bildirilir
    func verifyRecording(number: Int, requested: Bool) {
        guard requested, let folder = sessionFolder else { return }
        let saved = deps.library.answerFiles(in: folder).contains { AnswerLibrary.questionNumber(fromFileName: $0.lastPathComponent) == number }
        if saved {
            clearWarning("kayit")
        } else {
            warn("kayit", Say.recordingFailed(number))
        }
    }

    /// Ağ hatasında (istek düştü) Kestirmelerle onarım; diğer hatalarda kısa sesli bilgi ve yeniden dinleme
    private func handleGeminiError(_ error: GeminiError) async {
        guard phase == .answering else { return }
        finishEntry(.failed(error.kind == .network ? "Gemini'ye ulaşılamadı; bağlantı gelince soruyu yeniden okuyun." : error.message))
        if error.kind == .network {
            warn("cevap", "Gemini'ye ulaşılamadı: \(error.message)")
            await runRecovery(.network)
            return
        }
        warn("cevap", error.message)
        if await speakNotice(Say.geminiFailure(error)) { beginListening() }
    }

    /// Duyulmamış cevabı yeniden okur. Okuma sentez sırasında kesilmişse soru_N dosyası silinmiştir: bu okumada yeniden yazılır, yoksa test
    /// sonundaki tekrar bu cevabı atlardı. Dosya duruyorsa (kesinti çalma sırasında olduysa) üzerine yazılmaz. Sonuna kadar okunduysa true.
    func rereadUnheard(_ record: AnswerRecord) async -> Bool {
        var base: URL?
        if let folder = sessionFolder {
            let exists = deps.library.answerFiles(in: folder).contains { AnswerLibrary.questionNumber(fromFileName: $0.lastPathComponent) == record.number }
            if !exists { base = deps.library.fileBase(question: record.number, in: folder) }
        }
        guard await speakNotice(record.spoken, saveAs: base) else { return false }
        verifyRecording(number: record.number, requested: base != nil)
        refreshReplayAvailability()
        return true
    }

    /// Kısa anons: yalnız kulaklıktan çalar; `saveAs` verilmedikçe kaydedilmez. Sonuna kadar çalındıysa true.
    @discardableResult
    func speakNotice(_ text: String, saveAs: URL? = nil, remember: Bool = true) async -> Bool {
        if remember { rememberSpeech(text) }
        phase = .speaking
        await settleAnnouncements()   // önce bekleyen uyarılar, sonra bu anons
        guard !Task.isCancelled, phase == .speaking else { return false }
        defer { quietTicks = 0 }
        do {
            try await deps.speaker.speak(text, saveAs: saveAs)
        } catch SpeakError.routeUnsafe {
            enterHardwarePause(AudioRouting.verdict(deps.route.snapshot()))
            return false
        } catch SpeakError.failed(let message) {
            // Okunamayan duyuru işi durdurmaz (yoksa oturum sessizce takılırdı): sebep yazılır, sistem dinlemeye geçer
            warn("ses", message)
        } catch {
            return false
        }
        return !Task.isCancelled && phase == .speaking
    }

    /// Kurtarılamaz bir eksik (izin, dikte modeli): oturum kapanır, sebep ekranda kalır
    func stopForGood(_ message: String) {
        warn("durdu", message)
        cancelWork()
        deps.speaker.stop()
        deps.listener.pause()
        deps.network.stop()
        deps.screen.keepAwake(false)
        phase = .idle
    }
}
