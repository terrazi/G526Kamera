import AVFoundation

/// Ses yolunun anlık görüntüsü: şu an sesin gittiği ve geldiği portlar
struct RouteSnapshot: Equatable {
    var outputs: [AVAudioSession.Port]
    var inputs: [AVAudioSession.Port]
}

/// Seçilebilir bir ses girişi (mikrofon)
struct InputChoice: Equatable, Identifiable {
    let uid: String
    let name: String
    let port: AVAudioSession.Port
    var isCurrent: Bool

    var id: String { return uid }
    /// Yalnız harici (Lightning/USB/kablolu) mikrofonlar güvenli sayılır ve seçilebilir
    var isExternal: Bool { return AudioRouting.externalMicPorts.contains(port) }
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

    /// Port adının Türkçe kısa karşılığı ("Sesi dene" ve günlük için)
    static func portName(_ port: AVAudioSession.Port) -> String {
        switch port {
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE: return "Bluetooth kulaklık"
        case .usbAudio: return "Lightning/USB mikrofon"
        case .headsetMic: return "kulaklık mikrofonu"
        case .lineIn: return "hat girişi"
        case .lineOut: return "hat çıkışı"
        case .builtInMic: return "telefonun kendi mikrofonu"
        case .builtInSpeaker: return "telefon hoparlörü"
        case .builtInReceiver: return "telefon ahizesi"
        default: return port.rawValue
        }
    }

    /// "Çıkış: Bluetooth kulaklık. Giriş: Lightning/USB mikrofon."
    static func describe(_ snapshot: RouteSnapshot) -> String {
        func list(_ ports: [AVAudioSession.Port]) -> String {
            return ports.isEmpty ? "yok" : ports.map(portName).joined(separator: ", ")
        }
        return "Çıkış: \(list(snapshot.outputs)). Giriş: \(list(snapshot.inputs))."
    }

    private static func hint(outputs: [AVAudioSession.Port], headphonesOK: Bool) -> String {
        if headphonesOK { return "" }
        if outputs.contains(where: { $0 == .usbAudio || $0 == .lineOut }) {
            return "Ses yaka mikrofonu alıcısına (Lightning) gidiyor. Ekrandaki ses çıkışı düğmesinden Bluetooth kulaklığı seçin."
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
    func configure() throws
    func snapshot() -> RouteSnapshot
    /// Harici mikrofon varsa girişi ona sabitler (Bluetooth kulaklığın kendi mikrofonuna düşmesin)
    func preferExternalInput()
    /// Bağlı girişler (mikrofonlar)
    func availableInputs() -> [InputChoice]
    /// Kullanıcı bir mikrofon seçti: yalnız harici mikrofon seçilebilir; seçim hatırlanır ve sonraki yol değişikliklerinde de tercih edilir
    @discardableResult func selectInput(uid: String) -> Bool
}

/// Modül 2 (Kalkan): AVAudioSession .playAndRecord, seçenek yalnız [.allowBluetoothA2DP].
/// `.allowBluetooth` (HFP, telefon görüşmesi profili) BİLEREK yok: HFP kulaklığın kendi mikrofonunu da girişe alır ve Lightning
/// mikrofonla birlikte kullanılamaz; kullanıcı listeden kulaklığı seçince iOS HFP'ye geçip sesi iPhone'a düşürüyordu. A2DP yalnız
/// çıkıştır ve harici mikrofon girişiyle birlikte çalışır (giriş zaten hiçbir zaman Bluetooth olmamalı).
/// `.defaultToSpeaker` HİÇBİR yerde yoktur; çıkış `overrideOutputAudioPort` ile de hoparlöre çevrilmez.
@MainActor
final class AudioSessionGuard: AudioRouteProviding {
    static let category: AVAudioSession.Category = .playAndRecord
    static let options: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP]

    var onChange: (@MainActor (RouteSnapshot) -> Void)?
    var onInterruption: (@MainActor (Bool) -> Void)?

    private static let chosenInputKey = "v3.chosenInputUID"

    private let session: AVAudioSession
    private let defaults: UserDefaults
    private var chosenInputUID: String?
    private var observer: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?

    init(session: AVAudioSession = .sharedInstance(), defaults: UserDefaults = .standard) {
        self.session = session
        self.defaults = defaults
        self.chosenInputUID = defaults.string(forKey: AudioSessionGuard.chosenInputKey)
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
    }

    deinit {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
        if let observer = interruptionObserver { NotificationCenter.default.removeObserver(observer) }
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
        let externals = (session.availableInputs ?? []).filter { AudioRouting.externalMicPorts.contains($0.portType) }
        // Kullanıcının seçtiği mikrofon takılıysa o, değilse ilk harici mikrofon
        let external = externals.first(where: { $0.uid == chosenInputUID }) ?? externals.first
        // Zaten seçiliyse dokunma: gereksiz yönlendirme değişikliği yeni bir yol bildirimi doğurur
        if session.preferredInput?.uid == external?.uid { return }
        try? session.setPreferredInput(external)
    }

    func availableInputs() -> [InputChoice] {
        let current = Set(session.currentRoute.inputs.map { $0.uid })
        return (session.availableInputs ?? []).map {
            InputChoice(uid: $0.uid, name: $0.portName, port: $0.portType, isCurrent: current.contains($0.uid))
        }
    }

    @discardableResult
    func selectInput(uid: String) -> Bool {
        guard let input = (session.availableInputs ?? []).first(where: { $0.uid == uid }),
              AudioRouting.externalMicPorts.contains(input.portType) else { return false }
        do {
            try session.setPreferredInput(input)
        } catch {
            return false
        }
        chosenInputUID = uid
        defaults.set(uid, forKey: AudioSessionGuard.chosenInputKey)
        return true
    }

    private func routeDidChange() {
        preferExternalInput()
        onChange?(snapshot())
    }
}
