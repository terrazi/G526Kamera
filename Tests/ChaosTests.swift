import XCTest
@testable import G526CameraDrive

/// Kaos testi: rastgele (ama tohumlu, yani yeniden üretilebilir) olay dizileriyle oturumu hırpalar.
/// Kulaklık/mikrofon kopması, arama, internet gidip gelmesi, tanıma hatası, kestirme başarısızlığı, Gemini hatası ve takılması,
/// okuma hatası, elle duraklatma… hepsi karışık sırayla gelir. Her adımdan sonra durum değişmezleri denetlenir; dizinin sonunda
/// her şey düzeltilir ve oturumun kendi kendine dinlemeye döndüğü (kilitlenmediği) doğrulanır.
@MainActor
final class ChaosTests: XCTestCase {
    /// Tohumdan yeniden üretilebilir rastgele sayı üreteci (SplitMix64)
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

    /// Olay havuzu: sık görülenler birden çok kez yazılarak ağırlıklandırılır
    private static let pool: [Int] = [0, 0, 0, 1, 2, 3, 3, 4, 5, 5, 5, 6, 7, 7, 8, 9, 9, 10, 11, 12, 13, 14, 14, 15, 16,
                                      17, 17, 17, 17, 18, 19, 20, 21, 22, 22, 23, 24, 25, 26, 26]

    private func apply(_ code: Int, _ h: SessionHarness, _ rng: inout SeededGenerator) -> String {
        switch code {
        case 0:
            h.answering.results.append(.success(FakeAnswering.reply(Int.random(in: 1...40, using: &rng))))
            h.ask("Rastgele soru metni")
            return "soru (cevap gelir)"
        case 1:
            h.answering.results.append(.failure(GeminiError("ağ koptu", .network)))
            h.ask("Rastgele soru metni")
            return "soru (ağ hatası)"
        case 2:
            h.answering.results.append(.failure(GeminiError("kota doldu", .quota)))
            h.ask("Rastgele soru metni")
            return "soru (kota hatası)"
        case 3: h.route.change(to: FakeRoute.noHeadphones); return "kulaklık gitti"
        case 4: h.route.change(to: FakeRoute.noMic); return "mikrofon gitti"
        case 5: h.route.change(to: FakeRoute.good); return "yol düzeldi"
        case 6: h.route.interrupt(began: true); return "arama başladı"
        case 7: h.route.interrupt(began: false); return "arama bitti"
        case 8: h.network.set(online: false); h.health.internet = false; return "internet gitti"
        case 9: h.network.set(online: true); h.health.internet = true; return "internet geldi"
        case 10: h.listener.onEvent?(.failure("tanıma görevi hata verdi")); return "tanıma hatası"
        case 11: h.listener.onEvent?(.recognizerDown(message: "tanıyıcı düştü", permanent: false)); return "tanıyıcı düştü"
        case 12: h.listener.onEvent?(.engineStopped); return "ses motoru durdu"
        case 13: h.listener.secondsSinceAudio = 6; return "mikrofon tamponu durdu"
        case 14: h.listener.secondsSinceAudio = 0.2; return "mikrofon tamponu geldi"
        case 15:
            let outcomes: [ShortcutOutcome] = [.success, .failed("kestirme hatası"), .timedOut, .cancelled]
            let pick = outcomes[Int.random(in: 0..<outcomes.count, using: &rng)]
            h.shortcuts.outcome = pick
            return "kestirme sonucu: \(pick)"
        case 16: h.route.onMediaServicesReset?(); return "ses servisi sıfırlandı"
        case 17:
            let steps: [TimeInterval] = [0.5, 3, 12, 40, 90]
            let step = steps[Int.random(in: 0..<steps.count, using: &rng)]
            h.scheduler.advance(by: step)
            return "\(step) sn geçti"
        case 18: h.speaker.script = [SpeakError.failed("okuma hatası")]; return "okuma hatası"
        case 19: h.speaker.hold = true; return "okuma takıldı"
        case 20: h.battery.set(12); return "şarj azaldı"
        case 21: h.vm.pauseByUser(); return "elle duraklat"
        case 22: h.vm.resumeByUser(); return "elle devam"
        case 23: h.health.quickResults = [false, false]; return "internet nabzı kaçtı"
        case 24: h.answering.hold = true; return "Gemini takıldı"
        case 25: h.answering.hold = false; h.answering.release(); return "Gemini yanıt verdi"
        default: h.speaker.hold = false; h.speaker.release(); return "okuma devam etti"
        }
    }

    /// Her şeyi düzeltir (kulaklık, mikrofon, internet, kestirme, Gemini, okuma, arama) ve oturumun kendiliğinden dinlemeye dönmesini bekler
    private func healEverything(_ h: SessionHarness) async {
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
            h.scheduler.advance(by: 15)
            await settle()
            if h.vm.phase == .paused(.manual) { h.vm.resumeByUser() }
            if h.vm.phase == .listening && h.listener.isRunning { break }
        }
        // Dinleme göründükten sonra da biraz zaman geçirilir: gecikmeli bir görev yeniden bozmasın
        for _ in 0..<6 {
            h.scheduler.advance(by: 20)
            await settle()
        }
    }

    private func runSequence(seed: UInt64) async -> [String] {
        var problems: [String] = []
        var rng = SeededGenerator(seed: seed)
        let h = SessionHarness()
        h.settings.instantDetection = seed % 2 == 0
        h.answering.results = [.success(FakeAnswering.reply(1))]
        guard await h.startListening() else { return ["oturum açılışta dinlemeye geçemedi"] }

        var log: [String] = []
        let count = Int.random(in: 8...16, using: &rng)
        for step in 0..<count {
            let code = ChaosTests.pool[Int.random(in: 0..<ChaosTests.pool.count, using: &rng)]
            let name = apply(code, h, &rng)
            log.append("\(step + 1). \(name)")
            await settle()
            // Değişmez 1: dinleme aşamasındaysa dinleyici gerçekten çalışıyor olmalı (yoksa kullanıcı konuşur, kimse duymaz)
            if h.vm.phase == .listening, !h.listener.isRunning {
                problems.append("adım \(step + 1): aşama 'dinliyor' ama dinleyici kapalı")
            }
            // Değişmez 2: oturum kendiliğinden kapanmaz (kalıcı hata üretilmedi)
            if h.vm.phase == .idle || h.vm.phase == .finished {
                problems.append("adım \(step + 1): oturum kendiliğinden kapandı (\(h.vm.phase))")
                break
            }
        }

        await healEverything(h)
        // Canlılık: her şey düzelince oturum kendi kendine dinlemeye dönmeli
        if h.vm.phase != .listening {
            problems.append("her şey düzeldiği hâlde aşama '\(h.vm.phase)' (dinlemeye dönmedi)")
        }
        if h.vm.phase == .listening, !h.listener.isRunning {
            problems.append("düzeldikten sonra aşama 'dinliyor' ama dinleyici kapalı")
        }
        if h.vm.phase == .listening, h.vm.questions.contains(where: { $0.state == .sending }) {
            problems.append("dinlerken 'gönderiliyor' işaretiyle takılı kalmış soru var")
        }
        // Döngü bekçileri: sınırsız kestirme çalıştırma ya da anons yağmuru olmamalı
        if h.shortcuts.runs.count > 60 { problems.append("kestirme \(h.shortcuts.runs.count) kez çalıştı") }
        if h.speaker.allCalls.count > 150 { problems.append("\(h.speaker.allCalls.count) konuşma isteği (anons yağmuru)") }
        if !problems.isEmpty { problems.append("olaylar: " + log.joined(separator: " | ")) }
        return problems
    }

    func testRandomOutagesNeverDeadlockTheSession() async {
        var failed = 0
        for seed in 1...160 {
            let problems = await runSequence(seed: UInt64(seed))
            if !problems.isEmpty {
                failed += 1
                XCTFail("tohum \(seed): " + problems.joined(separator: "; "))
                if failed >= 6 { break }   // günlük şişmesin
            }
        }
    }
}
