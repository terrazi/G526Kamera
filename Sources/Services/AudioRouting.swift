import AVFoundation

/// Ses yolunun anlık görüntüsü: şu an sesin gittiği ve geldiği portlar
struct RouteSnapshot: Equatable {
    var outputs: [AVAudioSession.Port]
    var inputs: [AVAudioSession.Port]
}

/// Ses yolunun değerlendirmesi. Güvenli = çıkış yalnız Bluetooth kulaklık VE giriş yalnız harici (Lightning) yaka mikrofonu.
struct RouteVerdict: Equatable {
    var headphonesOK: Bool
    var micOK: Bool
    /// Sorun varsa tek cümlelik ipucu ("" = sorun yok)
    var hint: String

    var isSafe: Bool { return headphonesOK && micOK }

    /// Ekranda ve duraklatma nedeninde görünen kısa metin
    var summary: String {
        var parts: [String] = []
        if !headphonesOK { parts.append("Bluetooth kulaklık yok") }
        if !micOK { parts.append("yaka mikrofonu yok") }
        return parts.joined(separator: ", ")
    }
}

/// KURAL 1 ("ses telefondan sızmaz") için saf mantık: portlara bakıp güvenli mi diye karar verir.
enum AudioRouting {
    /// Sesin gidebileceği tek yer: Bluetooth kulaklık. Telefonun hoparlörü/ahizesi ve kablolu çıkış güvenli sayılmaz.
    static let headphonePorts: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE]
    /// Girişin geleceği tek yer: Lightning/USB/kablolu harici mikrofon. Telefonun kendi mikrofonu ve Bluetooth mikrofon güvenli sayılmaz.
    static let externalMicPorts: Set<AVAudioSession.Port> = [.usbAudio, .headsetMic, .lineIn]

    static func verdict(_ snapshot: RouteSnapshot) -> RouteVerdict {
        let outputs = snapshot.outputs
        let inputs = snapshot.inputs
        let headphonesOK = !outputs.isEmpty && outputs.allSatisfy { headphonePorts.contains($0) }
        let micOK = !inputs.isEmpty && inputs.allSatisfy { externalMicPorts.contains($0) }
        return RouteVerdict(headphonesOK: headphonesOK, micOK: micOK, hint: hint(outputs: outputs, headphonesOK: headphonesOK))
    }

    private static func hint(outputs: [AVAudioSession.Port], headphonesOK: Bool) -> String {
        if headphonesOK { return "" }
        if outputs.contains(where: { $0 == .usbAudio || $0 == .lineOut }) {
            return "Ses yaka mikrofonu alıcısına (Lightning) gidiyor. Ekrandaki ses çıkışı düğmesinden Bluetooth kulaklığı seçin."
        }
        if outputs.contains(where: { $0 == .builtInSpeaker || $0 == .builtInReceiver }) {
            return "Bluetooth kulaklık bağlı değil; telefondan ses verilmez."
        }
        return "Bluetooth kulaklık bulunamadı."
    }
}

/// Ses oturumunu ve izlenen ses yolunu veren katman (gerçeği AudioSessionGuard, testlerde sahtesi)
@MainActor
protocol AudioRouteProviding: AnyObject {
    /// Yol her değiştiğinde çağrılır
    var onChange: (@MainActor (RouteSnapshot) -> Void)? { get set }
    func configure() throws
    func snapshot() -> RouteSnapshot
    /// Harici mikrofon varsa girişi ona sabitler (Bluetooth kulaklığın kendi mikrofonuna düşmesin)
    func preferExternalInput()
}

/// Modül 2 (Kalkan): AVAudioSession .playAndRecord, seçenekler yalnız [.allowBluetooth, .allowBluetoothA2DP].
/// `.defaultToSpeaker` HİÇBİR yerde yoktur; çıkış `overrideOutputAudioPort` ile de hoparlöre çevrilmez.
@MainActor
final class AudioSessionGuard: AudioRouteProviding {
    static let category: AVAudioSession.Category = .playAndRecord
    static let options: AVAudioSession.CategoryOptions = [.allowBluetooth, .allowBluetoothA2DP]

    var onChange: (@MainActor (RouteSnapshot) -> Void)?

    private let session: AVAudioSession
    private var observer: NSObjectProtocol?

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
        observer = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.routeDidChange() }
        }
    }

    deinit {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
    }

    func configure() throws {
        try session.setCategory(AudioSessionGuard.category, mode: .default, options: AudioSessionGuard.options)
        try session.setActive(true)
    }

    func snapshot() -> RouteSnapshot {
        let route = session.currentRoute
        return RouteSnapshot(outputs: route.outputs.map { $0.portType }, inputs: route.inputs.map { $0.portType })
    }

    func preferExternalInput() {
        let external = (session.availableInputs ?? []).first(where: { AudioRouting.externalMicPorts.contains($0.portType) })
        // Zaten seçiliyse dokunma: gereksiz yönlendirme değişikliği yeni bir yol bildirimi doğurur
        if session.preferredInput?.uid == external?.uid { return }
        try? session.setPreferredInput(external)
    }

    private func routeDidChange() {
        preferExternalInput()
        onChange?(snapshot())
    }
}
