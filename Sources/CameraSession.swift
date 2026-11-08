import Foundation

/// Kameraya tek bir bağlantı oturumu: el sıkışma, giriş, görüntü akışı, canlı tutma.
/// `run()` tek bir arka plan iş parçacığında çalışır ve oturum bitince nedenini döndürür.
/// Bütün durum bu iş parçacığına aittir; dışarıdan yalnızca `requestStop()` çağrılır.
final class CameraSession {
    struct Config {
        var uid: CameraUID
        var password: String
        var manualIP: String
        var videoState: Int
        var videoStream: Int
        var tzHours: Int
    }

    // Geri çağrılar oturum iş parçacığından gelir.
    var onFrame: ((VideoFrame) -> Void)?
    var onStatus: ((String) -> Void)?
    var onConnected: ((String) -> Void)?
    var onDeviceInfo: (([String: Any]) -> Void)?

    private let config: Config
    private let did: [UInt8]
    private var socket: UDPSocket?
    private var camAddr: UDPAddress?
    private var connected = false
    private var closedByCamera = false

    private let stopLock = NSLock()
    private var stopFlag = false

    private var replies: [String: [String: Any]] = [:]
    private var ackedCommands = Set<UInt16>()
    private var cmdIndex: UInt16 = 0
    private var cmdBytes: [UInt8] = []

    private let videoAssembler = DrwAssembler()
    private let commandAssembler = DrwAssembler()
    private let parser = VideoFrameParser()

    private var rxBuffer = [UInt8](repeating: 0, count: 65535)
    private var lastRx = Date()
    private var lastVideoRx = Date.distantPast

    private(set) var videoPackets = 0
    private(set) var framesDelivered = 0

    init(config: Config) {
        self.config = config
        self.did = config.uid.devicePayload
    }

    func requestStop() {
        stopLock.lock()
        stopFlag = true
        stopLock.unlock()
    }

    private var shouldStop: Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopFlag
    }

    var statistics: String {
        return "paket \(videoPackets), kare \(framesDelivered), kayıp \(videoAssembler.lostPackets), tekrar \(videoAssembler.duplicates)"
    }

    private func log(_ s: String) { tlog("[kamera] " + s) }
    private func status(_ s: String) { onStatus?(s) }

    // MARK: - Ana akış

    func run() -> String {
        guard let sock = UDPSocket() else { return "Ağ soketi açılamadı" }
        socket = sock
        defer { sock.close() }

        status("Kameraya bağlanılıyor…")
        if !connect(timeout: 40) {
            return shouldStop ? "Durduruldu" : "Kamera bulunamadı. Telefon kameranın Wi-Fi ağında mı?"
        }
        guard let cam = camAddr else { return "Kamera adresi alınamadı" }
        onConnected?("\(cam.ip):\(cam.port)")

        sock.send(PPPP.drwSetup(), to: cam)
        pump(for: 0.3)

        status("Giriş yapılıyor…")
        let login = command(CameraCommand.login(password: config.password), wait: "LoginDev")
        if let login = login {
            if let result = login["result"] as? Int, result != 0 {
                return "Kamera girişi reddetti (şifre yanlış olabilir)"
            }
        } else {
            log("LoginDev cevabı gelmedi, devam ediliyor")
        }
        _ = command(CameraCommand.appoint(password: config.password, tzHours: config.tzHours),
                    wait: "AppointDev", tries: 3)
        if let info = command(CameraCommand.deviceInfo(), wait: "GetDevInfo", tries: 3) {
            onDeviceInfo?(info)
        }

        status("Görüntü isteniyor…")
        let userID = Int.random(in: 1...100)
        openVideo(userID: userID)

        var lastKeepalive = Date()
        var streamStart = Date()
        var openRetries = 0
        var packetsAtStart = videoPackets

        while !shouldStop {
            pump(for: 0.1)
            if closedByCamera { return "Kamera bağlantıyı kapattı" }

            let now = Date()
            if now.timeIntervalSince(lastKeepalive) > 2 {
                sock.send(PPPP.packet(PPPP.alive), to: cam)
                lastKeepalive = now
            }
            if now.timeIntervalSince(lastRx) > 6 {
                return "Kameradan 6 sn cevap gelmedi"
            }
            if videoPackets != packetsAtStart {
                packetsAtStart = videoPackets
                streamStart = now
                openRetries = 0
            } else if now.timeIntervalSince(max(lastVideoRx, streamStart)) > 4 {
                if openRetries < 2 {
                    openRetries += 1
                    log("Görüntü gelmiyor, OpenVideo yeniden gönderiliyor (\(openRetries))")
                    openVideo(userID: userID)
                    streamStart = now
                } else {
                    return "Görüntü akışı durdu"
                }
            }
        }

        // Düzgün kapanış (en iyi çaba): akışı kapat, bağlantıyı kapat.
        let closeJSON = CameraCommand.openVideo(state: 0, password: config.password,
                                                stream: config.videoStream, userID: userID)
        let closePacket = PPPP.drwCommand(channel: PPPP.chCmd, index: cmdIndex,
                                          json: closeJSON, tzHours: config.tzHours)
        sock.send(closePacket, to: cam)
        sock.send(closePacket, to: cam)
        sock.send(PPPP.packet(PPPP.close), to: cam)
        return "Durduruldu"
    }

    private func openVideo(userID: Int) {
        _ = command(CameraCommand.openVideo(state: config.videoState, password: config.password,
                                            stream: config.videoStream, userID: userID),
                    wait: nil, tries: 3, gap: 0.3)
    }

    // MARK: - Bağlantı kurma

    private func connect(timeout: TimeInterval) -> Bool {
        guard let sock = socket else { return false }

        let wifi = LocalNetwork.wifi()
        var targets: [String] = []
        let manual = config.manualIP.trimmingCharacters(in: .whitespaces)
        if !manual.isEmpty, LocalNetwork.parse(manual) != nil { targets.append(manual) }
        if let w = wifi {
            let net = w.ip & w.mask
            targets.append(LocalNetwork.string(net + 1))
        }
        targets.append("192.168.100.1")
        var unique: [String] = []
        for t in targets where !unique.contains(t) { unique.append(t) }
        targets = unique

        log("Telefon Wi-Fi: \(wifi.map { LocalNetwork.string($0.ip) } ?? "bulunamadı"), denenecek: \(targets.joined(separator: ", "))")
        if wifi == nil {
            log("Uyarı: Wi-Fi adresi yok. Kameranın Wi-Fi ağına bağlı olmalısınız.")
        }

        let punch = PPPP.packet(PPPP.punch, did)
        let lan = PPPP.packet(PPPP.lanSearch)
        let request = PPPP.packet(PPPP.p2pReq,
                                  config.uid.p2pRequestPayload(localPort: sock.localPort,
                                                               localIPv4: wifi.map { LocalNetwork.bytes($0.ip) }))

        let started = Date()
        var scans = 0
        while !connected && !shouldStop && Date().timeIntervalSince(started) < timeout {
            for t in targets {
                sock.send(punch, to: UDPAddress(ip: t, port: PPPP.devPort))
                sock.send(request, to: UDPAddress(ip: t, port: PPPP.devPort))
                sock.send(lan, to: UDPAddress(ip: t, port: PPPP.lanPort))
            }
            // Yayın adresleri: iOS özel izin vermezse sessizce başarısız olur, sorun değil.
            if let w = wifi {
                sock.send(lan, to: UDPAddress(ip: LocalNetwork.string(w.ip | ~w.mask), port: PPPP.lanPort))
            }
            sock.send(lan, to: UDPAddress(ip: "255.255.255.255", port: PPPP.lanPort))

            let elapsed = Date().timeIntervalSince(started)
            if (scans == 0 && elapsed > 4) || (scans == 1 && elapsed > 12) {
                scans += 1
                scanSubnet(wifi: wifi, punch: punch)
            }
            pump(for: 0.4) { self.connected }
        }
        return connected
    }

    private func scanSubnet(wifi: (ip: UInt32, mask: UInt32)?, punch: [UInt8]) {
        guard let sock = socket else { return }
        let ownIP = wifi?.ip ?? 0
        let net24 = (wifi?.ip ?? 0xC0A8_6414) & 0xFFFF_FF00
        log("Doğrudan adreslerden cevap yok, \(LocalNetwork.string(net24 + 1)) – \(LocalNetwork.string(net24 + 254)) taranıyor")
        for host in 1...254 {
            let ip = net24 + UInt32(host)
            if ip == ownIP { continue }
            sock.send(punch, to: UDPAddress(ip: LocalNetwork.string(ip), port: PPPP.devPort))
        }
    }

    // MARK: - Komutlar

    /// `wait` verilirse o adlı cevabı bekler (ve yeniden gönderir); verilmezse tek yönlü komuttur.
    @discardableResult
    private func command(_ json: String, wait name: String?, tries: Int = 6, gap: TimeInterval = 0.4) -> [String: Any]? {
        guard let cam = camAddr else { return nil }
        let index = cmdIndex
        cmdIndex &+= 1
        let packet = PPPP.drwCommand(channel: PPPP.chCmd, index: index, json: json, tzHours: config.tzHours)
        if let name = name { replies[name] = nil }

        for _ in 0..<tries {
            if shouldStop { break }
            socket?.send(packet, to: cam)
            if let name = name {
                pump(for: gap) { self.replies[name] != nil }
                if let r = replies[name] { return r }
            } else {
                pump(for: gap) { self.ackedCommands.contains(index) }
                if ackedCommands.contains(index) { break }
            }
        }
        if let name = name { return replies[name] }
        return nil
    }

    // MARK: - Paket işleme

    private func pump(for duration: TimeInterval, until: () -> Bool = { false }) {
        guard let sock = socket else { return }
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline && !shouldStop {
            if let r = sock.receive(buffer: &rxBuffer) {
                handle(count: r.count, from: r.from)
            }
            if until() { return }
        }
    }

    private func handle(count n: Int, from: UDPAddress) {
        guard n >= 4, rxBuffer[0] == PPPP.magic else { return }
        if let cam = camAddr, cam.ip != from.ip { return }

        let type = rxBuffer[1]
        let plen = (Int(rxBuffer[2]) << 8) | Int(rxBuffer[3])
        let end = min(n, 4 + plen)
        lastRx = Date()

        switch type {
        case PPPP.punch, PPPP.p2pRdy:
            camAddr = from
            socket?.send(PPPP.packet(PPPP.p2pRdy, did), to: from)
            socket?.send(PPPP.packet(PPPP.p2pRdyAck, did), to: from)
            if !connected {
                connected = true
                log("El sıkışma tamam, kamera \(from.ip):\(from.port)")
            }
        case PPPP.p2pRdyAck:
            camAddr = from
            if !connected {
                connected = true
                log("Bağlantı onaylandı, kamera \(from.ip):\(from.port)")
            }
        case PPPP.alive:
            socket?.send(PPPP.packet(PPPP.aliveAck), to: from)
        case PPPP.close:
            closedByCamera = true
            log("Kamera CLOSE gönderdi")
        case PPPP.drwAck:
            handleDrwAck(Array(rxBuffer[4..<end]))
        case PPPP.drw:
            handleDrw(Array(rxBuffer[4..<end]), from: from)
        default:
            break
        }
    }

    private func handleDrwAck(_ p: [UInt8]) {
        guard p.count >= 4, p[0] == 0xD1, p[1] == PPPP.chCmd else { return }
        let count = (Int(p[2]) << 8) | Int(p[3])
        var i = 4
        for _ in 0..<count {
            if i + 1 >= p.count { break }
            ackedCommands.insert((UInt16(p[i]) << 8) | UInt16(p[i + 1]))
            i += 2
        }
    }

    private func handleDrw(_ p: [UInt8], from: UDPAddress) {
        guard p.count >= 4, p[0] == 0xD1 else { return }
        let channel = p[1]
        let index = (UInt16(p[2]) << 8) | UInt16(p[3])
        // Her paketi onayla (tekrar gönderimi durdurur); tekrarlar da onaylanır.
        socket?.send(PPPP.drwAcknowledge(channel: channel, index: index), to: from)

        let body = Array(p[4...])
        let now = ProcessInfo.processInfo.systemUptime

        if channel == PPPP.chCmd {
            let out = commandAssembler.push(index: index, body: body, now: now)
            if !out.data.isEmpty { processCommandBytes(out.data) }
        } else if channel == PPPP.chVideo {
            videoPackets += 1
            lastVideoRx = Date()
            let out = videoAssembler.push(index: index, body: body, now: now)
            if !out.data.isEmpty || out.gapSkipped {
                let frames = parser.append(out.data, gapBefore: out.gapSkipped)
                for f in frames {
                    framesDelivered += 1
                    onFrame?(f)
                }
            }
        }
    }

    private func processCommandBytes(_ bytes: [UInt8]) {
        cmdBytes.append(contentsOf: bytes)
        let extracted = PPPP.mykjExtract(from: cmdBytes)
        cmdBytes = extracted.rest
        for json in extracted.jsons {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
                  let name = obj["cmd"] as? String else {
                log("Çözülemeyen cevap: \(json.prefix(120))")
                continue
            }
            replies[name] = obj
            let compact = json.replacingOccurrences(of: "\t", with: "")
                .replacingOccurrences(of: "\n", with: "")
            log("Cevap \(name): \(compact.prefix(200))")
        }
    }
}
