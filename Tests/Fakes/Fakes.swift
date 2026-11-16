import XCTest
import AVFoundation
@testable import G526CameraDrive

// Sahte (fake) dış dünya: gerçek mikrofon, kulaklık, ağ ve Gemini olmadan ViewModel akışlarını sınamak için.

/// Elle ilerletilen zamanlayıcı: `advance(by:)` ile süre geçirilir, vadesi gelen işler sırayla çalışır
@MainActor
final class ManualScheduler: Scheduling {
    private struct Item {
        let id: Int
        let due: TimeInterval
        let action: @MainActor () -> Void
    }

    private(set) var now: TimeInterval = 0
    /// Şimdiye kadar istenen bekleme süreleri (kurulum sırasıyla)
    private(set) var requested: [TimeInterval] = []
    private var items: [Int: Item] = [:]
    private var counter = 0

    var pendingCount: Int { return items.count }

    func after(_ seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ScheduledTask {
        counter += 1
        let id = counter
        requested.append(seconds)
        items[id] = Item(id: id, due: now + max(0, seconds), action: action)
        return ScheduledTask(cancel: { [weak self] in self?.items[id] = nil })
    }

    /// Bir `advance` içinde çalışan iş sayısı için üst sınır: kendini 0 sn ile yeniden kuran bir zamanlayıcı testi sonsuza kadar kilitlerdi
    static let actionLimit = 50_000

    func advance(by seconds: TimeInterval) {
        let target = now + seconds
        var executed = 0
        while let next = items.values.filter({ $0.due <= target }).min(by: { ($0.due, $0.id) < ($1.due, $1.id) }) {
            items[next.id] = nil
            now = max(now, next.due)
            next.action()
            executed += 1
            if executed > ManualScheduler.actionLimit {
                XCTFail("Zamanlayıcı döngüsü: \(seconds) sn ilerletirken \(executed) iş çalıştı (kendini 0 sn ile yeniden kuran bir iş var)")
                break
            }
        }
        now = max(now, target)
    }
}

@MainActor
final class FakeRoute: AudioRouteProviding {
    static let good = RouteSnapshot(outputs: [.bluetoothA2DP], inputs: [.usbAudio])
    static let noHeadphones = RouteSnapshot(outputs: [.builtInSpeaker], inputs: [.usbAudio])
    static let noMic = RouteSnapshot(outputs: [.bluetoothA2DP], inputs: [.builtInMic])

    var onChange: (@MainActor (RouteSnapshot) -> Void)?
    var onInterruption: (@MainActor (Bool) -> Void)?
    var onMediaServicesReset: (@MainActor () -> Void)?
    var current = FakeRoute.good
    var configureError: Error?
    private(set) var configureCalls = 0
    private(set) var preferCalls = 0

    func configure() throws {
        configureCalls += 1
        if let error = configureError { throw error }
    }

    func snapshot() -> RouteSnapshot { return current }
    /// Yol ilk bakışta oturmamış olsun: bu kadar `preferExternalInput` çağrısından sonra güvenli yola geçer (nil = hiç)
    var settlesAfterPrefers: Int?
    func preferExternalInput() {
        preferCalls += 1
        if let n = settlesAfterPrefers, preferCalls >= n {
            current = FakeRoute.good
            settlesAfterPrefers = nil
        }
    }

    /// Bağlı mikrofonlar (varsayılan: Lightning alıcı) ve seçim denemeleri
    var inputs: [InputChoice] = [InputChoice(uid: "lightning", name: "Boya Mikrofon", port: .usbAudio, isCurrent: true)]
    private(set) var selectedUIDs: [String] = []
    func availableInputs() -> [InputChoice] { return inputs }
    func selectInput(uid: String) -> Bool {
        selectedUIDs.append(uid)
        guard let input = inputs.first(where: { $0.uid == uid }), input.isExternal else { return false }
        inputs = inputs.map { var c = $0; c.isCurrent = c.uid == uid; return c }
        return true
    }

    /// Arama/alarm/Siri sesi böldü (began) ya da bitti
    func interrupt(began: Bool) { onInterruption?(began) }

    /// Yol değişti (kulaklık takıldı/çıktı) ve iOS bildirimi geldi
    func change(to snapshot: RouteSnapshot) {
        current = snapshot
        onChange?(snapshot)
    }
}

@MainActor
final class FakeListener: SpeechListening {
    var onEvent: (@MainActor (SpeechEvent) -> Void)?
    var hints: ListenHints = .dictation
    /// Her `start()` çağrısında geçerli olan ipucu listesi (testler kipe göre ipucunu bundan okur)
    private(set) var startedHints: [ListenHints] = []
    private(set) var isRunning = false
    var secondsSinceAudio: TimeInterval? = 0.2
    /// Üst üste çabuk biten tanıma görevi sayısı (0: sağlam); testler artırarak tanıyıcının düştüğünü gösterir
    var recognitionStreak = 0
    private(set) var startCalls = 0
    private(set) var pauseCalls = 0
    /// Sırayla fırlatılacak başlatma hataları (boşsa başarılı)
    var startErrors: [Error] = []

    func start() throws {
        startCalls += 1
        startedHints.append(hints)
        if !startErrors.isEmpty { throw startErrors.removeFirst() }
        isRunning = true
    }

    func pause() {
        pauseCalls += 1
        isRunning = false
    }

    /// Bellek baskısında yardımcı İngilizce tanıyıcının kapatılıp açılması (true: kapatıldı)
    private(set) var trimStates: [Bool] = []
    func trimMemory(_ on: Bool) { trimStates.append(on) }

    /// Kullanıcı konuştu: dikte kısmi metni
    func say(_ text: String) { onEvent?(.partial(text)) }
}

final class FakeRecorder: QuestionRecording {
    var data: Data? = Data([1, 2, 3, 4])
    var truncated = false
    private(set) var resetCalls = 0
    var duration: TimeInterval { return data == nil ? 0 : 1 }
    func reset() { resetCalls += 1 }
    func wavData() -> Data? { return data }
}

@MainActor
final class FakeSpeaker: AnswerSpeaking {
    struct Call: Equatable {
        let text: String
        let saveAs: URL?
    }

    /// Uyarı anonsları (oturumun `announced` listesindeki cümleler) ayrı tutulur: cevap ve anons akışını sınayan testler onlardan etkilenmez
    var isAnnouncement: (String) -> Bool = { _ in false }
    private(set) var allCalls: [Call] = []
    var calls: [Call] { return allCalls.filter { !isAnnouncement($0.text) } }
    var announcements: [String] { return allCalls.filter { isAnnouncement($0.text) }.map { $0.text } }
    private(set) var stopCalls = 0
    /// Çağrı sırasına göre sonuç: nil = başarılı, hata = fırlatır (liste bitince başarılı)
    var script: [Error?] = []
    /// Başarılı kayıtlı çağrıda dosya gerçekten oluşturulsun mu
    var writeFiles = true
    /// true iken konuşma `release()` ya da `stop()` gelene kadar sürer
    var hold = false
    /// Yalnız bu koşulu sağlayan cümlede bekler (kesintinin tam o cümle söylenirken gelmesini sınamak için)
    var holdWhen: ((String) -> Bool)?
    private var continuation: CheckedContinuation<Void, Never>?

    var spoken: [String] { return calls.map { $0.text } }

    @discardableResult
    func speak(_ text: String, saveAs fileBase: URL?) async throws -> URL? {
        allCalls.append(Call(text: text, saveAs: fileBase))
        if isAnnouncement(text) { return nil }   // uyarı anonsu: bekletme ve hata senaryosu yalnız cevap/anons akışı içindir
        if hold || (holdWhen?(text) ?? false) { await withCheckedContinuation { continuation = $0 } }
        if !script.isEmpty, let error = script.removeFirst() { throw error }
        guard let base = fileBase else { return nil }
        let url = base.appendingPathExtension("m4a")
        if writeFiles { try? Data([0]).write(to: url) }
        return url
    }

    func stop() {
        stopCalls += 1
        release()
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class FakeNetwork: NetworkWatching {
    var isOnline = true
    var kind: NetworkKind = .wifi
    var onChange: (@MainActor (Bool) -> Void)?
    var onPathChange: (@MainActor () -> Void)?
    private(set) var startCalls = 0
    private(set) var stopCalls = 0

    func start() { startCalls += 1 }
    func stop() { stopCalls += 1 }

    func set(online: Bool) {
        isOnline = online
        onChange?(online)
    }
}

@MainActor
final class FakeHealth: HealthChecking {
    var internet = true
    var geminiResult: GeminiHealth = .ok
    /// Anahtara göre ayrı sonuç (yoksa geminiResult)
    var geminiResults: [String: GeminiHealth] = [:]
    private(set) var geminiKeysAsked: [String] = []
    private(set) var internetCalls = 0
    private(set) var geminiCalls = 0

    func internetReachable() async -> Bool {
        internetCalls += 1
        return internet
    }

    /// Telefonda SIM kart var mı (varsayılan: var)
    var hasCellular = true
    func hasCellularService() -> Bool { return hasCellular }

    func gemini(key: String) async -> GeminiHealth {
        geminiCalls += 1
        geminiKeysAsked.append(key)
        return geminiResults[key] ?? geminiResult
    }

    /// Nabız yoklaması: sırayla verilecek sonuçlar (boşsa `internet`) ve çağrı sayısı
    var quickResults: [Bool] = []
    private(set) var quickCalls = 0

    func quickProbe() async -> Bool {
        quickCalls += 1
        if !quickResults.isEmpty { return quickResults.removeFirst() }
        return internet
    }
}

@MainActor
final class FakeShortcuts: ShortcutRunning {
    private(set) var runs: [String] = []
    private(set) var callbacks: [URL] = []
    var outcome: ShortcutOutcome = .success
    /// Doluysa sıradaki çalıştırmalar sırayla bu sonuçları verir; bitince `outcome` döner
    var script: [ShortcutOutcome] = []
    /// Kestirme "çalışınca" dünyada olacak değişiklik (ör. interneti geri getirmek)
    var onRun: ((String) -> Void)?

    func run(name: String) async -> ShortcutOutcome {
        runs.append(name)
        onRun?(name)
        if !script.isEmpty { return script.removeFirst() }
        return outcome
    }

    @discardableResult
    func handleCallback(_ url: URL) -> Bool {
        callbacks.append(url)
        return ShortcutLink.callback(from: url) != nil
    }
}

@MainActor
final class FakeAnswering: Answering {
    struct Call {
        let question: String
        let english: String
        let expectedNumber: Int
        let audio: Data?
        /// Sesle okunan soruyla birlikte gönderilen, kamerayla çekilmiş ortak paragraf görüntüleri (varsa)
        var passage: PassageMedia?
    }

    private(set) var calls: [Call] = []
    var results: [Result<GeminiReply, Error>] = []
    /// true iken cevap `release()` gelene kadar bekler (Gemini takıldı)
    var hold = false
    /// Bekleme sınırı sınamasında iptal edilmiş eski istek ile yeniden gönderim aynı anda bekleyebilir: hepsi birlikte serbest kalır
    private var gates: [CheckedContinuation<Void, Never>] = []

    func release() {
        let waiting = gates
        gates = []
        for gate in waiting { gate.resume() }
    }

    static func reply(_ number: Int, option: String = "Denizli", text: String = "Örgütsel Davranış") -> GeminiReply {
        return GeminiReply(number: number, option: option, text: text, spoken: "Soru \(number), \(option), \(text)", model: "fake")
    }

    /// Sürüm 4: kamera ile çekilen sorular (sırayla) ve her çağrıda haber verilen kanca (olay sırası sınaması için)
    private(set) var captureCalls: [(shot: CapturedQuestion, expectedNumber: Int)] = []
    var onCall: ((String) -> Void)?

    func answer(capture: CapturedQuestion, expectedNumber: Int) async throws -> GeminiReply {
        captureCalls.append((capture, expectedNumber))
        onCall?("gönderim")
        if hold { await withCheckedContinuation { gates.append($0) } }
        guard !results.isEmpty else { throw GeminiError("Cevap hazırlanmadı.", .error) }
        return try results.removeFirst().get()
    }

    /// Toplu sayfa çekimi: sırayla verilecek sayfa cevapları (boşsa tek soruluk `results` kullanılır) ve yapılan çağrılar
    var pageResults: [Result<[GeminiReply], Error>] = []
    private(set) var pageCalls: [(shot: CapturedQuestion, expectedNumber: Int)] = []

    func answerPage(capture: CapturedQuestion, expectedNumber: Int) async throws -> [GeminiReply] {
        guard !pageResults.isEmpty else { return [try await answer(capture: capture, expectedNumber: expectedNumber)] }
        pageCalls.append((capture, expectedNumber))
        onCall?("sayfa gönderimi")
        if hold { await withCheckedContinuation { gates.append($0) } }
        return try pageResults.removeFirst().get()
    }

    func answer(question: String, english: String, expectedNumber: Int, audio: Data?, passage: PassageMedia?) async throws -> GeminiReply {
        calls.append(Call(question: question, english: english, expectedNumber: expectedNumber, audio: audio, passage: passage))
        if hold { await withCheckedContinuation { gates.append($0) } }
        guard !results.isEmpty else { throw GeminiError("Cevap hazırlanmadı.", .error) }
        return try results.removeFirst().get()
    }
}

/// Sürüm 4: kamera çekimini taklit eder
@MainActor
final class FakeCamera: CameraCapturing {
    var onSayWait: ((String) async -> Void)?
    var onSay: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    /// Her çekimde çekilen şey (soru ya da ortak paragraf) kaydedilir
    var subject: CaptureSubject = .question
    private(set) var subjects: [CaptureSubject] = []
    /// Sırayla verilecek çekim sonuçları (boşsa kamera yok)
    var results: [Result<CapturedQuestion, CameraFailure>] = []
    private(set) var captures = 0
    private(set) var cancels = 0
    /// Kameranın son bilinen pil durumu ("kamera raporu", "Kamerayı dene")
    var lastBattery: CameraBatteryLevel?
    /// Çekim başlarken haber verilir (olay sırası sınaması için)
    var onCapture: (() -> Void)?
    /// Oturum başında bağlantı açılırken / kapanırken haber verilir (olay sırası sınaması için)
    var onHold: (() -> Void)?
    var onCloseHeld: (() -> Void)?
    /// Sırayla verilecek "bağlantıyı açık tut" sonuçları (boşsa başarılı)
    var holdResults: [Result<Void, CameraFailure>] = []
    private(set) var holdOpens = 0
    private(set) var closes = 0
    private(set) var isHeld = false
    /// Konumlandırma sırasında söylenmiş gibi yapılacak cümle
    var guidance: String?
    /// Çekim öncesi duyuru gibi BEKLENEREK söylenecek cümle (gerçek kamerada geri sayım girişi): `onSayWait` ile söylenir, bitince çekim sürer
    var waitedGuidance: String?
    /// `onSayWait` cümle bitince döndüğünde kaydedilir (sıra sınaması için)
    var onWaitedSayDone: (() -> Void)?
    /// Doğruysa çekim `release()` çağrılana (ya da iptal edilene) kadar sürer: uzun süren çekim sınamaları için
    var hold = false
    private var gate: CheckedContinuation<Void, Never>?

    static func shot(video: Bool = true, bytes: Int = 200_000) -> CapturedQuestion {
        var s = CapturedQuestion(photo: Data([1, 2, 3]))
        if video {
            s.video = FileManager.default.temporaryDirectory.appendingPathComponent("fake-\(UUID().uuidString).mp4")
            try? Data([0]).write(to: s.video!)
            s.videoBytes = bytes
            s.videoSeconds = 5
        }
        return s
    }

    /// Toplu sayfa çekimi: sırayla verilecek oturum sonuçları (boşsa kamera yok), yapılan çağrılar ve oturum başlarken haber verilen kanca
    var seriesResults: [Result<PageSeries, CameraFailure>] = []
    private(set) var seriesCalls: [(seconds: Int, limit: TimeInterval?)] = []
    var onSeries: (() -> Void)?

    /// Toplu çekim hazır bekleyen bağlantıyı kullanır ve bitince kapatır (gerçek kamerada `captureSeries` bağlantıyı devralır)
    var holding: Bool { return isHeld }
    /// Doğruysa açık tutulan bağlantı kopmuştur (görüntü gelmiyor); yeni bir `holdOpen` bağlantıyı onarır
    var linkLost = false
    var holdingLive: Bool { return isHeld && !linkLost }
    /// Çekim başlarken bağlantı açık tutuluyor muydu (hazır bekleme)
    private(set) var seriesHeldAtStart: [Bool] = []

    func captureSeries(seconds: Int, connectLimit: TimeInterval?) async -> Result<PageSeries, CameraFailure> {
        seriesCalls.append((seconds, connectLimit))
        seriesHeldAtStart.append(holdingLive)
        isHeld = false
        onSeries?()
        guard !seriesResults.isEmpty else { return .failure(.unavailable) }
        return seriesResults.removeFirst()
    }

    /// Toplu çekimin tek PDF'i: `isPage` işaretli, `photos` fotoğraflık PDF'i varmış gibi
    static func page(_ tag: UInt8 = 1, photos: Int = 75) -> CapturedQuestion {
        var s = CapturedQuestion(photo: Data([tag, 2, 3]))
        s.pdf = Data([tag, 9, 9, 9])
        s.pageCount = photos
        s.isPage = true
        return s
    }

    /// Sırayla verilecek yoklama sonuçları (boşsa kamera yok); kamera kapalıyken dönüp dönmediğini yoklayan akış için
    var probeResults: [Bool] = []
    private(set) var probes = 0
    func probe() async -> Bool {
        probes += 1
        return probeResults.isEmpty ? false : probeResults.removeFirst()
    }

    /// Her çekimde verilen bağlanma sınırı ("Wi-Fi'de kal": ilk denemede kısa, onarımdan sonrakilerde nil)
    private(set) var connectLimits: [TimeInterval?] = []
    func capture(connectLimit: TimeInterval?) async -> Result<CapturedQuestion, CameraFailure> {
        connectLimits.append(connectLimit)
        return await capture()
    }

    func capture() async -> Result<CapturedQuestion, CameraFailure> {
        captures += 1
        subjects.append(subject)
        onCapture?()
        if let text = guidance { onSay?(text) }
        if let text = waitedGuidance {
            await onSayWait?(text)
            onWaitedSayDone?()
        }
        if hold { await withCheckedContinuation { gate = $0 } }
        guard !results.isEmpty else { return .failure(.unavailable) }
        return results.removeFirst()
    }

    func release() {
        hold = false
        gate?.resume()
        gate = nil
    }

    /// Her bağlanmada verilen bekleme sınırı (ilk denemede kısa, onarımdan sonrakilerde nil)
    private(set) var holdLimits: [TimeInterval?] = []
    func holdOpen(connectLimit: TimeInterval?) async -> Result<Void, CameraFailure> {
        holdLimits.append(connectLimit)
        holdOpens += 1
        onHold?()
        let result = holdResults.isEmpty ? Result<Void, CameraFailure>.success(()) : holdResults.removeFirst()
        if case .success = result { isHeld = true; linkLost = false }
        return result
    }

    func closeHeld() {
        guard isHeld else { return }
        isHeld = false
        closes += 1
        onCloseHeld?()
    }

    func cancel() {
        cancels += 1
        isHeld = false
        release()
    }
}

@MainActor
final class FakeBattery: BatteryProviding {
    var percent: Int? = 80
    var charging = false
    var onChange: (() -> Void)?

    /// Şarj değişti ve iOS bildirimi geldi
    func set(_ percent: Int?, charging: Bool = false) {
        self.percent = percent
        self.charging = charging
        onChange?()
    }
}

@MainActor
final class FakePermissions: PermissionProviding {
    var result = PermissionResult(microphone: true, speech: true, onDeviceSpeech: true)
    func request() async -> PermissionResult { return result }
}

@MainActor
final class FakeScreen: ScreenKeeping {
    private(set) var states: [Bool] = []
    func keepAwake(_ on: Bool) { states.append(on) }
}

@MainActor
final class FakePlayer: AudioFilePlaying {
    private(set) var played: [URL] = []
    private(set) var stopCalls = 0
    private var completion: (@MainActor (Bool) -> Void)?

    func play(_ url: URL, completion: @escaping @MainActor (Bool) -> Void) {
        played.append(url)
        self.completion = completion
    }

    func stop() {
        stopCalls += 1
        completion = nil
    }

    /// Çalan dosya bitti
    func finish(_ ok: Bool = true) {
        let done = completion
        completion = nil
        done?(ok)
    }
}

/// Geçici klasör (test bitince silinmesi gerekmez; sistem temizler)
func makeTempFolder(_ name: String = "g526-test") -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Koşul sağlanana kadar (en çok `timeout` sn) ana iş parçacığını başkalarına bırakarak bekler
@MainActor
func waitUntil(_ timeout: TimeInterval = 3, _ condition: @MainActor () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return condition()
}

/// Bekleyen görevlerin ilerlemesi için kısa bir an
@MainActor
func settle(_ rounds: Int = 40) async {
    for _ in 0..<rounds { await Task.yield() }
}


/// Telefonun kaynak durumu: testler `current` değerini değiştirip sistemin bildirimlerini tetikler
@MainActor
final class FakeSystem: SystemHealthProviding {
    var current = SystemSnapshot(availableMemoryMB: 1500, footprintMB: 200, thermal: .nominal, lowPowerMode: false, freeDiskMB: 5000)
    var onMemoryWarning: (() -> Void)?
    var onThermalChange: (() -> Void)?
    var onPowerModeChange: (() -> Void)?
    func snapshot() -> SystemSnapshot { return current }
}

/// Ses seviyesi ayarı: istekleri kaydeder; `apply` doluysa ses seviyesini onunla değiştirir (iOS'un izin vermediği durumu sınamak için boş bırakılır)
@MainActor
final class FakeVolume: VolumeControlling {
    private(set) var requests: [Float] = []
    var apply: ((Float) -> Void)?
    func requestOutputVolume(_ level: Float) {
        requests.append(level)
        apply?(level)
    }
}

/// Çalışmalar arası defter: testler `start` ile "önceki çalışma böyle bitti" der, yazılanları `saved*` alanlarından okur
@MainActor
final class FakeJournal: RunJournaling {
    var start = RunStart.fresh
    private(set) var beginCalls = 0
    private(set) var sessionOpen = false
    private(set) var openHistory: [Bool] = []
    private(set) var heartbeats = 0
    private(set) var pending: PendingWork?
    private(set) var nextNumber = 1
    private(set) var folder: String?
    private(set) var deliberate = false

    func beginRun() -> RunStart {
        beginCalls += 1
        return start
    }
    func setSessionOpen(_ open: Bool) {
        sessionOpen = open
        openHistory.append(open)
    }
    func heartbeat() { heartbeats += 1 }
    func savePending(_ work: PendingWork?) { pending = work }
    private(set) var passage: SavedPassage?
    func savePassage(_ passage: SavedPassage?) { self.passage = passage }
    func saveNextNumber(_ number: Int) { nextNumber = number }
    func saveFolder(_ name: String?) { folder = name }
    func markDeliberateClose() {
        deliberate = true
        sessionOpen = false
    }
    private(set) var awayHistory: [Bool] = []
    func setAway(_ away: Bool) { awayHistory.append(away) }
}

/// Kapanma sayacı ("Programı kapat" gerçekten çıkışı istedi mi)
final class ExitCounter {
    var count = 0
}
