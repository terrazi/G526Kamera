import Foundation

enum CameraState: Equatable {
    case stopped
    case connecting(String)
    case connected(String)
    case streaming
    case reconnecting(String)

    var text: String {
        switch self {
        case .stopped: return "Kamera kapalı"
        case .connecting(let s): return s
        case .connected(let a): return "Bağlandı (\(a)), görüntü bekleniyor…"
        case .streaming: return "Canlı"
        case .reconnecting(let s): return s
        }
    }

    var isLive: Bool {
        if case .streaming = self { return true }
        return false
    }
}

/// Oturumu yönetir: bağlantı koparsa kendiliğinden yeniden dener.
final class CameraClient {
    var onState: ((CameraState) -> Void)?
    var onFrame: ((VideoFrame) -> Void)?
    var onDeviceInfo: (([String: Any]) -> Void)?
    var onProbe: ((String) -> Void)?

    private let lock = NSLock()
    private var running = false
    private var generation = 0
    private var currentSession: CameraSession?

    var sessionStatistics: String {
        lock.lock()
        let s = currentSession
        lock.unlock()
        return s?.statistics ?? ""
    }

    func start(config: CameraSession.Config) {
        stop()
        lock.lock()
        running = true
        generation += 1
        let gen = generation
        lock.unlock()

        let thread = Thread { [weak self] in
            self?.loop(config: config, generation: gen)
        }
        thread.name = "g526.camera"
        thread.qualityOfService = .userInitiated
        thread.stackSize = 1 << 20
        thread.start()
    }

    func stop() {
        lock.lock()
        running = false
        let s = currentSession
        lock.unlock()
        s?.requestStop()
    }

    private func isCurrent(_ gen: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running && generation == gen
    }

    private func loop(config: CameraSession.Config, generation gen: Int) {
        var attempt = 0
        while isCurrent(gen) {
            let session = CameraSession(config: config)
            var gotFrame = false

            session.onStatus = { [weak self] text in
                guard let self = self, self.isCurrent(gen) else { return }
                self.onState?(.connecting(text))
            }
            session.onConnected = { [weak self] addr in
                guard let self = self, self.isCurrent(gen) else { return }
                self.onState?(.connected(addr))
            }
            session.onDeviceInfo = { [weak self] info in
                self?.onDeviceInfo?(info)
            }
            session.onProbe = { [weak self] text in
                self?.onProbe?(text)
            }
            session.onFrame = { [weak self] frame in
                guard let self = self, self.isCurrent(gen) else { return }
                if !gotFrame {
                    gotFrame = true
                    self.onState?(.streaming)
                }
                self.onFrame?(frame)
            }

            lock.lock()
            currentSession = session
            lock.unlock()

            let reason = session.run()
            tlog("[kamera] oturum bitti: \(reason) (\(session.statistics))")

            lock.lock()
            currentSession = nil
            lock.unlock()

            if !isCurrent(gen) { break }
            attempt = gotFrame ? 1 : attempt + 1
            let wait = min(2.0 * Double(attempt), 8.0)
            onState?(.reconnecting("\(reason) · \(Int(wait)) sn sonra yeniden denenecek"))

            var waited = 0.0
            while waited < wait && isCurrent(gen) {
                Thread.sleep(forTimeInterval: 0.2)
                waited += 0.2
            }
        }

        lock.lock()
        let isLatest = (generation == gen)
        lock.unlock()
        if isLatest {
            onState?(.stopped)
        }
    }
}
