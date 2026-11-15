import XCTest
@testable import G526CameraDrive

/// Sürüm 4 kaos testi: kameralı akış (kamera sorusu, kamerayla soru ve ortak paragraf, iptal ve tekrar komutları) rastgele ama tohumlu olay
/// dizileriyle kulaklık/mikrofon/internet/kestirme/Gemini kesintileriyle karışık hırpalanır. Her adımda durum değişmezleri denetlenir; dizinin
/// sonunda her şey düzeltilir ve (1) oturumun kendiliğinden dinlemeye döndüğü, (2) kameranın meşgul kalmadığı, (3) test bitince hiçbir video
/// dosyasının telefonda sahipsiz kalmadığı doğrulanır.
@MainActor
final class CameraChaosTests: XCTestCase {
    typealias T = SessionViewModel.Timing

    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// Olaylar arasında paylaşılan durum: kestirme interneti geri getiriyor mu, çekilen sahte videoların dosyaları
    private final class Box {
        var internetBack = true
        var videos: [URL] = []
    }

    static let realisticSeeds = 150
    static let burstSeeds = 250

    /// Olay havuzu: kameralı akış olayları ağırlıklıdır
    private static let pool: [Int] = [
        0, 0, 0, 0, 1, 1, 2, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10,
        11, 11, 11, 12, 13, 14, 14, 15, 16, 16,
        17, 18, 18, 19, 20, 20, 21, 22, 22, 23, 24, 25, 25, 37, 38, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36
    ]

    private func pass(_ h: SessionHarness, _ seconds: TimeInterval, burst: Bool) async {
        if burst {
            h.scheduler.advance(by: seconds)
            return
        }
        var left = seconds
        while left > 0 {
            let step = min(0.5, left)
            h.scheduler.advance(by: step)
            left -= step
            await settle(8)
        }
    }

    private func newShot(_ box: Box) -> CapturedQuestion {
        let shot = FakeCamera.shot()
        if let video = shot.video { box.videos.append(video) }
        return shot
    }

    private func say(_ h: SessionHarness, _ text: String, after: TimeInterval) {
        h.listener.say(text)
        h.scheduler.advance(by: after + 0.1)
    }

    private func apply(_ code: Int, _ h: SessionHarness, _ box: Box, _ rng: inout SeededGenerator, burst: Bool) async -> String {
        switch code {
        case 0: say(h, "evet", after: T.numberConfirm); return "evet"
        case 1: say(h, "hayır", after: T.numberConfirm); return "hayır"
        case 2: say(h, "ortak paragraf", after: T.numberConfirm); return "ortak paragraf"
        case 3: say(h, "Ortak paragraf Ali eve gitti. Sonra okula yürüdü Tamamlandı", after: T.triggerConfirm); return "paragraf okundu"
        case 4: say(h, "beş altı yedi Tamam", after: T.triggerConfirm); return "paragrafın soru numaraları"
        case 5:
            h.answering.results.append(.success(FakeAnswering.reply(Int.random(in: 1...40, using: &rng))))
            h.ask("Rastgele soru metni")
            return "sesle soru"
        case 6: say(h, "paragrafı iptal et", after: T.numberConfirm); return "paragrafı iptal et"
        case 7: say(h, "soruyu iptal et", after: T.numberConfirm); return "soruyu iptal et"
        case 8: say(h, "cevapları tekrarla", after: T.numberConfirm); return "cevapları tekrarla"
        case 9: say(h, "beşinci sorunun cevabını tekrarla", after: T.numberConfirm); return "5. sorunun cevabını tekrarla"
        case 10: say(h, "kamerayla", after: T.numberConfirm); return "kamerayla"
        case 11:
            h.camera.results.append(.success(newShot(box)))
            h.answering.results.append(.success(FakeAnswering.reply(Int.random(in: 1...40, using: &rng))))
            return "kamera çekimi hazır"
        case 12: h.camera.results.append(.failure(.noPosition)); return "kamera çekimi başarısız"
        case 13: h.camera.hold = true; return "kamera çekimi takıldı"
        case 14: h.camera.release(); return "kamera çekimi sürdü"
        case 15: box.internetBack = false; return "kestirme interneti getirmiyor"
        case 16: box.internetBack = true; return "kestirme interneti getiriyor"
        case 17: h.route.change(to: FakeRoute.noHeadphones); return "kulaklık gitti"
        case 18: h.route.change(to: FakeRoute.good); return "yol düzeldi"
        case 19: h.route.interrupt(began: true); return "arama başladı"
        case 20: h.route.interrupt(began: false); return "arama bitti"
        case 21: h.network.set(online: false); h.health.internet = false; return "internet gitti"
        case 22: h.network.set(online: true); h.health.internet = true; return "internet geldi"
        case 23: h.listener.onEvent?(.failure("tanıma görevi hata verdi")); return "tanıma hatası"
        case 24:
            let outcomes: [ShortcutOutcome] = [.success, .failed("kestirme hatası"), .timedOut, .cancelled]
            let pick = outcomes[Int.random(in: 0..<outcomes.count, using: &rng)]
            h.shortcuts.outcome = pick
            return "kestirme sonucu: \(pick)"
        case 25:
            let steps: [TimeInterval] = [0.5, 3, 12, 40, 90]
            let step = steps[Int.random(in: 0..<steps.count, using: &rng)]
            await pass(h, step, burst: burst)
            return "\(step) sn geçti"
        case 26: h.answering.hold = true; return "Gemini takıldı"
        case 27: h.answering.hold = false; h.answering.release(); return "Gemini yanıt verdi"
        case 28: h.speaker.script = [SpeakError.failed("okuma hatası")]; return "okuma hatası"
        case 29: h.speaker.hold = true; return "okuma takıldı"
        case 30: h.speaker.hold = false; h.speaker.release(); return "okuma devam etti"
        case 31: h.vm.pauseByUser(); return "elle duraklat"
        case 32: h.vm.resumeByUser(); return "elle devam"
        case 33: h.listener.secondsSinceAudio = 6; return "mikrofon tamponu durdu"
        case 34: h.listener.secondsSinceAudio = 0.2; return "mikrofon tamponu geldi"
        case 35:
            h.answering.results.append(.failure(GeminiError("ağ koptu", .network)))
            return "sıradaki Gemini isteği ağ hatası verecek"
        case 37: say(h, "anlamadım", after: T.numberConfirm); return "anlamadım"
        case 38: say(h, "bir daha söyle", after: T.numberConfirm); return "bir daha söyle"
        default:
            h.listener.say("Soru 3 Ali eve gitti. Sonra okula yürüdü ve arkadaşlarıyla buluştu")
            return "yarım okuma"
        }
    }

    private func healEverything(_ h: SessionHarness, _ box: Box, burst: Bool) async {
        box.internetBack = true
        h.camera.hold = false
        h.camera.release()
        h.speaker.hold = false
        h.speaker.script = []
        h.speaker.release()
        h.answering.hold = false
        h.answering.release()
        h.route.configureError = nil
        h.route.change(to: FakeRoute.good)
        h.route.interrupt(began: false)
        h.network.set(online: true)
        h.health.internet = true
        h.health.geminiResult = .ok
        h.health.quickResults = []
        h.shortcuts.outcome = .success
        h.listener.secondsSinceAudio = 0.2
        h.listener.recognitionStreak = 0
        h.listener.startErrors = []
        h.battery.set(80, charging: true)
        if h.vm.phase == .paused(.manual) { h.vm.resumeByUser() }
        for _ in 0..<60 {
            await pass(h, 15, burst: burst)
            await settle()
            if h.vm.phase == .paused(.manual) { h.vm.resumeByUser() }
            if h.vm.phase == .listening && h.listener.isRunning { break }
        }
        for _ in 0..<6 {
            await pass(h, 20, burst: burst)
            await settle()
        }
    }

    private func runSequence(seed: UInt64, burst: Bool) async -> [String] {
        var problems: [String] = []
        var rng = SeededGenerator(seed: seed)
        let box = Box()
        let h = SessionHarness(cameraFlow: true)
        h.settings.instantDetection = seed % 2 == 0
        h.settings.askMissingNumber = true
        h.settings.spokenProgress = true
        h.settings.smartResume = true
        h.trackEvents { name in
            if name == "Kameraya_Gec" { h.health.internet = false }
            if name == "Hücresele_Gec", box.internetBack { h.health.internet = true }
            if name == "Hücresel_Ac" { h.health.internet = true }
        }
        h.answering.results = [.success(FakeAnswering.reply(1))]
        // Açılış beklemesi uzun tutulur: koşucuda disk ya da ana iş parçacığı birkaç saniye takılabilir (kilitlenme sınaması bunu aramaz)
        h.vm.start()
        guard await waitUntil(30, { h.vm.phase == .listening }) else { return ["oturum açılışta dinlemeye geçemedi (30 sn)"] }

        var log: [String] = []
        let count = Int.random(in: 8...16, using: &rng)
        for step in 0..<count {
            let code = CameraChaosTests.pool[Int.random(in: 0..<CameraChaosTests.pool.count, using: &rng)]
            let name = await apply(code, h, box, &rng, burst: burst)
            log.append("\(step + 1). \(name)")
            await settle()
            if h.vm.phase == .listening, !h.listener.isRunning {
                problems.append("adım \(step + 1): aşama 'dinliyor' ama dinleyici kapalı")
            }
            if h.vm.phase == .idle || h.vm.phase == .finished {
                problems.append("adım \(step + 1): oturum kendiliğinden kapandı (\(h.vm.phase))")
                break
            }
            if h.vm.phase == .listening, h.vm.listenMode == .missingNumber, h.vm.heldQuestion == nil {
                problems.append("adım \(step + 1): numara bekleniyor ama bekleyen soru yok")
            }
            if h.vm.phase == .listening, h.vm.listenMode == .passageTargets, h.vm.passageDraft == nil {
                problems.append("adım \(step + 1): paragrafın soru numaraları bekleniyor ama bekleyen paragraf yok")
            }
        }

        await healEverything(h, box, burst: burst)
        if h.vm.phase != .listening {
            problems.append("her şey düzeldiği hâlde aşama '\(h.vm.phase)' (dinlemeye dönmedi)")
        }
        if h.vm.phase == .listening, !h.listener.isRunning {
            problems.append("düzeldikten sonra aşama 'dinliyor' ama dinleyici kapalı")
        }
        if h.vm.phase == .listening, h.vm.questions.contains(where: { $0.state == .sending }) {
            problems.append("dinlerken 'gönderiliyor' işaretiyle takılı kalmış soru var")
        }
        if h.vm.cameraBusy { problems.append("her şey düzeldiği hâlde kamera akışı meşgul görünüyor (takılı kaldı)") }
        if h.vm.phase == .listening, h.vm.passageDraft != nil, h.vm.listenMode != .passageTargets {
            problems.append("dinlerken sahipsiz paragraf taslağı var (kip: \(h.vm.listenMode))")
        }
        if h.shortcuts.runs.count > 120 { problems.append("kestirme \(h.shortcuts.runs.count) kez çalıştı") }
        if h.speaker.allCalls.count > 250 { problems.append("\(h.speaker.allCalls.count) konuşma isteği (anons yağmuru)") }

        // Dosya sızıntısı: oturum bitince çekilmiş hiçbir video telefonda kalmamalı (kameraya hiç verilmemiş olanlar sayılmaz)
        for result in h.camera.results { if case .success(let shot) = result { shot.discard() } }
        h.camera.results = []
        h.vm.endTest()
        await settle()
        let leaked = box.videos.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !leaked.isEmpty { problems.append("test bitti ama \(leaked.count) video dosyası telefonda sahipsiz kaldı") }
        box.videos.forEach { try? FileManager.default.removeItem(at: $0) }

        if !problems.isEmpty { problems.append("olaylar: " + log.joined(separator: " | ")) }
        return problems
    }

    func testCameraFlowRandomOutagesNeverDeadlockOrLeak() async {
        var failed = 0
        for seed in 1...CameraChaosTests.realisticSeeds {
            let problems = await runSequence(seed: UInt64(seed), burst: false)
            if !problems.isEmpty {
                failed += 1
                XCTFail("tohum \(seed): " + problems.joined(separator: "; "))
                if failed >= 6 { break }
            }
        }
    }

    func testCameraFlowRandomOutagesWithBurstedTimeNeverDeadlockOrLeak() async {
        var failed = 0
        for seed in 1...CameraChaosTests.burstSeeds {
            let problems = await runSequence(seed: UInt64(seed), burst: true)
            if !problems.isEmpty {
                failed += 1
                XCTFail("tohum \(seed) (hamle): " + problems.joined(separator: "; "))
                if failed >= 6 { break }
            }
        }
    }
}
