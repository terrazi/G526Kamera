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

    func advance(by seconds: TimeInterval) {
        let target = now + seconds
        while let next = items.values.filter({ $0.due <= target }).min(by: { ($0.due, $0.id) < ($1.due, $1.id) }) {
            items[next.id] = nil
            now = max(now, next.due)
            next.action()
        }
        now = target
    }
}

@MainActor
final class FakeRoute: AudioRouteProviding {
    static let good = RouteSnapshot(outputs: [.bluetoothA2DP], inputs: [.usbAudio])
    static let noHeadphones = RouteSnapshot(outputs: [.builtInSpeaker], inputs: [.usbAudio])
    static let noMic = RouteSnapshot(outputs: [.bluetoothA2DP], inputs: [.builtInMic])

    var onChange: (@MainActor (RouteSnapshot) -> Void)?
    var onInterruption: (@MainActor (Bool) -> Void)?
    var current = FakeRoute.good
    var configureError: Error?
    private(set) var configureCalls = 0
    private(set) var preferCalls = 0

    func configure() throws {
        configureCalls += 1
        if let error = configureError { throw error }
    }

    func snapshot() -> RouteSnapshot { return current }
    func preferExternalInput() { preferCalls += 1 }

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
    private(set) var isRunning = false
    var secondsSinceAudio: TimeInterval? = 0.2
    private(set) var startCalls = 0
    private(set) var pauseCalls = 0
    /// Sırayla fırlatılacak başlatma hataları (boşsa başarılı)
    var startErrors: [Error] = []

    func start() throws {
        startCalls += 1
        if !startErrors.isEmpty { throw startErrors.removeFirst() }
        isRunning = true
    }

    func pause() {
        pauseCalls += 1
        isRunning = false
    }

    /// Kullanıcı konuştu: dikte kısmi metni
    func say(_ text: String) { onEvent?(.partial(text)) }
}

final class FakeRecorder: QuestionRecording {
    var data: Data? = Data([1, 2, 3, 4])
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

    private(set) var calls: [Call] = []
    private(set) var stopCalls = 0
    /// Çağrı sırasına göre sonuç: nil = başarılı, hata = fırlatır (liste bitince başarılı)
    var script: [Error?] = []
    /// Başarılı kayıtlı çağrıda dosya gerçekten oluşturulsun mu
    var writeFiles = true
    /// true iken konuşma `release()` ya da `stop()` gelene kadar sürer
    var hold = false
    private var continuation: CheckedContinuation<Void, Never>?

    var spoken: [String] { return calls.map { $0.text } }

    @discardableResult
    func speak(_ text: String, saveAs fileBase: URL?) async throws -> URL? {
        calls.append(Call(text: text, saveAs: fileBase))
        if hold { await withCheckedContinuation { continuation = $0 } }
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
    var onChange: (@MainActor (Bool) -> Void)?
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

    func gemini(key: String) async -> GeminiHealth {
        geminiCalls += 1
        geminiKeysAsked.append(key)
        return geminiResults[key] ?? geminiResult
    }
}

@MainActor
final class FakeShortcuts: ShortcutRunning {
    private(set) var runs: [String] = []
    private(set) var callbacks: [URL] = []
    var outcome: ShortcutOutcome = .success
    /// Kestirme "çalışınca" dünyada olacak değişiklik (ör. interneti geri getirmek)
    var onRun: ((String) -> Void)?

    func run(name: String) async -> ShortcutOutcome {
        runs.append(name)
        onRun?(name)
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
        let expectedNumber: Int
        let audio: Data?
    }

    private(set) var calls: [Call] = []
    var results: [Result<GeminiReply, Error>] = []

    static func reply(_ number: Int, option: String = "Denizli", text: String = "Örgütsel Davranış") -> GeminiReply {
        return GeminiReply(number: number, option: option, text: text, spoken: "Soru \(number), \(option), \(text)", model: "fake")
    }

    func answer(question: String, expectedNumber: Int, audio: Data?) async throws -> GeminiReply {
        calls.append(Call(question: question, expectedNumber: expectedNumber, audio: audio))
        guard !results.isEmpty else { throw GeminiError("Cevap hazırlanmadı.", .error) }
        return try results.removeFirst().get()
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
