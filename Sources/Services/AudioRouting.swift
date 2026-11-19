import AVFoundation

/// Ses yolunun anlık görüntüsü: şu an sesin gittiği ve geldiği portlar
struct RouteSnapshot: Equatable {
    var outputs: [AVAudioSession.Port]
    var inputs: [AVAudioSession.Port]
}

/// Ses yolunun değerlendirmesi. Güvenli = çıkış yalnız Bluetooth kulaklık. Giriş kulaklığın kendi mikrofonudur ve ARANMAZ: mikrofon çalışmasa da
/// oturum sürer; kulaklık yoksa ses telefona düşeceği için güvenliği çıkış belirler.
struct RouteVerdict: Equatable {
    var headphonesOK: Bool
    /// Sorun varsa tek cümlelik ipucu ("" = sorun yok)
    var hint: String

    var isSafe: Bool { return headphonesOK }

    /// Ekranda ve duraklatma nedeninde görünen kısa metin
    var summary: String {
        return headphonesOK ? "" : "Bluetooth kulaklık yok"
    }
}

/// KURAL 1 ("ses telefondan sızmaz") için saf mantık: portlara bakıp güvenli mi diye karar verir.
enum AudioRouting {
    /// Sesin gidebileceği tek yer: Bluetooth kulaklık. Telefonun hoparlörü/ahizesi ve kablolu çıkış güvenli sayılmaz.
    static let headphonePorts: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE]

    static func verdict(_ snapshot: RouteSnapshot) -> RouteVerdict {
        let outputs = snapshot.outputs
        let headphonesOK = !outputs.isEmpty && outputs.allSatisfy { headphonePorts.contains($0) }
        return RouteVerdict(headphonesOK: headphonesOK, hint: hint(outputs: outputs, headphonesOK: headphonesOK))
    }

    /// Port adının Türkçe kısa karşılığı ("Sesi dene" ve günlük için)
    static func portName(_ port: AVAudioSession.Port) -> String {
        switch port {
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE: return "Bluetooth kulaklık"
        case .usbAudio: return "Lightning/USB mikrofon"
        case .headsetMic: return "kablolu kulaklık mikrofonu"
        case .lineIn: return "hat girişi"
        case .lineOut: return "hat çıkışı"
        case .builtInMic: return "telefonun kendi mikrofonu"
        case .builtInSpeaker: return "telefon hoparlörü"
        case .builtInReceiver: return "telefon ahizesi"
        default: return port.rawValue
        }
    }

    /// Giriş portunun adı: Bluetooth kulaklık girişte kendi mikrofonudur ("Giriş: kulaklık mikrofonu")
    static func inputName(_ port: AVAudioSession.Port) -> String {
        switch port {
        case .bluetoothHFP, .bluetoothLE: return "kulaklık mikrofonu"
        default: return portName(port)
        }
    }

    /// "Çıkış: Bluetooth kulaklık. Giriş: kulaklık mikrofonu."
    static func describe(_ snapshot: RouteSnapshot) -> String {
        func list(_ ports: [AVAudioSession.Port], _ name: (AVAudioSession.Port) -> String) -> String {
            return ports.isEmpty ? "yok" : ports.map(name).joined(separator: ", ")
        }
        return "Çıkış: \(list(snapshot.outputs, portName)). Giriş: \(list(snapshot.inputs, inputName))."
    }

    /// Ham port adları ("BluetoothA2DPOutput", "USBAudio"…): Türkçe karşılıklar farklı portları aynı adla gösterebilir; günlükte kesin ne
    /// görüldüğü bununla anlaşılır (kulaklık çalışıyor ama program sorun görüyorsa hangi portun neden güvenli sayılmadığı)
    static func describeRaw(_ snapshot: RouteSnapshot) -> String {
        func list(_ ports: [AVAudioSession.Port]) -> String {
            return ports.isEmpty ? "yok" : ports.map { $0.rawValue }.joined(separator: ", ")
        }
        return "ham çıkış: \(list(snapshot.outputs)); ham giriş: \(list(snapshot.inputs))"
    }

    private static func hint(outputs: [AVAudioSession.Port], headphonesOK: Bool) -> String {
        if headphonesOK { return "" }
        if outputs.contains(where: { $0 == .usbAudio || $0 == .lineOut }) {
            return "Ses Lightning'e takılı bir aygıta gidiyor. Ekrandaki ses çıkışı düğmesinden Bluetooth kulaklığı seçin."
        }
        if outputs.contains(where: { $0 == .builtInSpeaker || $0 == .builtInReceiver }) {
            return "Ses şu an telefona gidiyor; telefondan ses verilmez. Kulaklık bağlıysa ses çıkışı düğmesinden onu seçin."
        }
        return "Bluetooth kulaklık bulunamadı."
    }
}

/// Ses oturumunu ve izlenen ses yolunu veren katman (gerçeği AudioSessionGuard, testlerde sahtesi)
@MainActor
protocol AudioRouteProviding: AnyObject {
    /// Yol her değiştiğinde çağrılır
    var onChange: (@MainActor (RouteSnapshot) -> Void)? { get set }
    /// Ses kesintisi (arama, alarm, Siri) başlayınca true, bitince false ile çağrılır
    var onInterruption: (@MainActor (Bool) -> Void)? { get set }
    /// iOS'un ses servisi (mediaserviced) kayboldu ya da sıfırlandı: ses oturumu, motor ve çalan her şey baştan kurulmalıdır
    var onMediaServicesReset: (@MainActor () -> Void)? { get set }
    func configure() throws
    func snapshot() -> RouteSnapshot
    /// Girişi Bluetooth kulaklığın kendi mikrofonuna sabitler (Lightning'e takılı bir mikrofon alıcısı olsa da kullanılmaz)
    func preferHeadsetInput()
}

/// Modül 2 (Kalkan): AVAudioSession .playAndRecord, seçenek yalnız [.allowBluetooth] (Bluetooth'un görüşme profili, HFP): çıkış da giriş de
/// kulaklıktır (kullanıcı kararı 2026-11-19: yaka mikrofonu iptal; kulaklık mikrofonuyla birlikte hep açık kalır). A2DP birlikte verilmez (iOS ikisi
/// varken HFP'yi seçer; tek seçenek yolun ne olacağını belirsiz bırakmaz). `.defaultToSpeaker` HİÇBİR yerde yoktur; çıkış
/// `overrideOutputAudioPort` ile de hoparlöre çevrilmez.
@MainActor
final class AudioSessionGuard: AudioRouteProviding {
    static let category: AVAudioSession.Category = .playAndRecord
    static let options: AVAudioSession.CategoryOptions = [.allowBluetooth]

    var onChange: (@MainActor (RouteSnapshot) -> Void)?
    var onInterruption: (@MainActor (Bool) -> Void)?
    var onMediaServicesReset: (@MainActor () -> Void)?

    private let session: AVAudioSession
    /// Kulaklık mikrofonu yola girmediği için tercihin art arda kaç kez yeniden verildiği (sınırsız yol bildirimi döngüsü olmasın)
    private var reassertCount = 0
    /// Son okumada giriş yoldan değil tercihten varsayıldı mı (günlüğe yalnız değişince yazılır)
    private var assumedInput = false
    private var observer: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var mediaObservers: [NSObjectProtocol] = []

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
        observer = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.routeDidChange() }
        }
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                                                      object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let began = type == .began
            Task { @MainActor in self?.onInterruption?(began) }
        }
        // Ses servisi çökünce bundan önce hiçbir yol ya da kesinti bildirimi gelmeyebilir; ayrıca dinlenir
        for name in [AVAudioSession.mediaServicesWereLostNotification, AVAudioSession.mediaServicesWereResetNotification] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                let lost = name == AVAudioSession.mediaServicesWereLostNotification
                Task { @MainActor in self?.mediaServicesEvent(lost: lost) }
            }
            mediaObservers.append(observer)
        }
    }

    deinit {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
        if let observer = interruptionObserver { NotificationCenter.default.removeObserver(observer) }
        for observer in mediaObservers { NotificationCenter.default.removeObserver(observer) }
    }

    func configure() throws {
        reassertCount = 0
        try session.setCategory(AudioSessionGuard.category, mode: .default, options: AudioSessionGuard.options)
        try session.setActive(true)
    }

    /// iOS, çıkışı Bluetooth'a alınca girişi çoğu kez hemen listelemez (giriş, ses motoru çalışınca yola girer). Yol girişi boş
    /// bildiriyorsa ve tercih edilen kulaklık mikrofonu bağlıysa o giriş sayılır (günlükte ve raporda "giriş yok" yazmasın).
    func snapshot() -> RouteSnapshot {
        let route = session.currentRoute
        var inputs = route.inputs.map { $0.portType }
        var assumed = false
        if inputs.isEmpty, let preferred = session.preferredInput, preferred.portType == .bluetoothHFP,
           (session.availableInputs ?? []).contains(where: { $0.uid == preferred.uid }) {
            inputs = [preferred.portType]
            assumed = true
        }
        if assumed != assumedInput {
            assumedInput = assumed
            tlog(assumed ? "[ses yolu] giriş yolda listelenmiyor; tercih edilen kulaklık mikrofonu varsayıldı" : "[ses yolu] giriş yolda görünüyor")
        }
        return RouteSnapshot(outputs: route.outputs.map { $0.portType }, inputs: inputs)
    }

    /// Giriş Bluetooth kulaklığın kendi mikrofonuna sabitlenir (Lightning'e takılı bir mikrofon alıcısı olsa da kullanılmaz). Tercih verilmişse ve
    /// mikrofon yoldaysa dokunmaz; yolda değilse en çok 3 kez yeniden verir (sınırsız yol bildirimi döngüsü olmasın).
    func preferHeadsetInput() {
        guard let headset = (session.availableInputs ?? []).first(where: { $0.portType == .bluetoothHFP }) else { return }
        if session.preferredInput?.uid == headset.uid {
            if session.currentRoute.inputs.contains(where: { $0.uid == headset.uid }) {
                reassertCount = 0
                return
            }
            guard reassertCount < 3 else { return }
            reassertCount += 1
            try? session.setPreferredInput(nil)
            try? session.setPreferredInput(headset)
            return
        }
        try? session.setPreferredInput(headset)
    }

    private func routeDidChange() {
        preferHeadsetInput()
        onChange?(snapshot())
    }

    private func mediaServicesEvent(lost: Bool) {
        tlog("[ses yolu] ses servisi \(lost ? "kayboldu" : "sıfırlandı")")
        onMediaServicesReset?()
    }
}
