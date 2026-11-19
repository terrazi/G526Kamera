import XCTest
@testable import G526CameraDrive

/// Program yalnız otomatik görüntülü sınavı bilir (kullanıcı kararı 2026-11-19): sesli ve hibrit sınav, yaka mikrofonu kaldırıldı. Gemini'nin
/// cevap vermemesi telefonun bağlantı sorunu sayılmaz (günlük 19.11.2026: kota + yoğunluk "internet yok" diye onarımı başlatmıştı).
@MainActor
final class CameraOnlyTests: XCTestCase {
    typealias T = SessionViewModel.Timing

    func testTheExamTypeIsAlwaysCameraAndIsNotStored() {
        let defaults = UserDefaults(suiteName: "g526.testler.\(UUID().uuidString)")!
        defaults.set("voice", forKey: "v4.examType")          // eski sürümden kalan kayıt
        defaults.set("hybrid", forKey: "v4.examTypeDefault")
        defaults.set(false, forKey: "v3.askCamera")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.examType, .camera, "Eski kayıt okunmaz: tür hep görüntülü")
        XCTAssertTrue(settings.askCamera)
        // Sınav türü ve kamera sorusu komutları kaldırıldı: bu sözler artık bir kamera / sınav ayarı komutu değildir
        for phrase in ["sesli sınav başlat", "hibrit sınav başlat", "görüntülü sınav başlat", "kamera sorusunu kapat", "kamera sorusunu aç"] {
            if case .camera(_)? = VoiceCommand.parse(phrase) { XCTFail("\"\(phrase)\" hâlâ bir ayar komutu sayılıyor") }
        }
    }

    /// Görüntülü sınavda soru sesle okunup "Cevapla" dense de Gemini'ye gönderilmez; komutlar çalışmaya devam eder
    func testInTheCameraExamASpokenQuestionIsNeverSentButCommandsStillWork() async {
        let h = SessionHarness()
        h.settings.examType = .camera   // uygulamadaki tek tür (kamera yapılandırılmamış: tarama yok, program komut dinler)
        _ = await h.startListening()
        XCTAssertEqual(h.speaker.spoken.first, Say.readyCameraMissingScan, "Sesle okuma önerilmez: \(h.speaker.spoken)")
        XCTAssertFalse(h.speaker.spoken.contains { $0.contains("okuyun") || $0.contains("Cevapla") }, "\(h.speaker.spoken)")
        // Komutlar verilebilir
        let before = h.speaker.spoken.count
        h.listener.say("durum")
        h.scheduler.advance(by: T.numberConfirm + 0.1)
        let told = await waitUntil(20) { h.speaker.spoken.count > before && h.vm.phase == .listening }
        XCTAssertTrue(told, "Komut çalışır: \(h.speaker.spoken)")
        // Sesle okunan soru gönderilmez
        h.answering.results = [.success(FakeAnswering.reply(1))]
        h.ask("Soru 1. Türkiye'nin başkenti neresidir. A seçeneği Adana")
        await settle()
        h.scheduler.advance(by: T.questionIdle + 1)
        await settle()
        XCTAssertTrue(h.answering.calls.isEmpty, "Sesle okunan soru gönderilmez")
        XCTAssertEqual(h.vm.answers.count, 0)
        XCTAssertEqual(h.vm.phase, .listening)
        XCTAssertFalse(h.speaker.spoken.contains(Say.noTriggerHeard), "\"Cevapla demediniz\" hatırlatması da söylenmez")
    }

    // MARK: Gemini cevap vermiyor ≠ internet yok

    func testAGeminiAnswerDecidesTheErrorKindEvenWhenTheLastErrorIsATimeout() {
        var timeout = GeminiError("İnternete ulaşılamadı: The request timed out.", .network)
        timeout.timedOut = true
        let quota = GeminiError("Bu modelin günlük kotası doldu", .quota, status: 429)
        XCTAssertEqual(GeminiAnswerService.decisive(last: timeout, served: quota).kind, .quota, "Gemini cevap verdi: internet çalışıyor")
        XCTAssertEqual(GeminiAnswerService.decisive(last: timeout, served: nil).kind, .network, "Hiç cevap gelmediyse bağlantı hatasıdır")
        XCTAssertEqual(GeminiAnswerService.decisive(last: quota, served: quota).kind, .quota)
    }

    func testAFreeTierQuotaIsNamedSoThePaidSlotDoesNotMislead() {
        let message = "You exceeded your current quota. Quota exceeded for metric: generativelanguage.googleapis.com/generate_content_free_tier_requests, limit: 0, model: gemini-4-argon"
        let err: [String: Any] = ["message": message, "details": [["violations": [["quotaId": "GenerateRequestsPerDayPerProjectPerModel-FreeTier",
                                                                                 "quotaMetric": "generativelanguage.googleapis.com/generate_content_free_tier_requests"]]]]]
        let text = GeminiSupport.describeError(status: 429, json: ["error": err], model: "gemini-4-argon").1
        XCTAssertTrue(text.contains(GeminiSupport.freeTierHint), text)
        XCTAssertTrue(text.contains("sınır: 0"), text)
        let paid = GeminiSupport.describeError(status: 429, json: ["error": ["message": "Quota exceeded for metric: x_requests, limit: 5\nPlease retry in 12s."]], model: "m").1
        XCTAssertFalse(paid.contains(GeminiSupport.freeTierHint), "Ücretsiz katman yazmıyorsa söylenmez: \(paid)")
    }

    /// İnternet var, Gemini yoklamaya cevap vermiyor (yoğunluk, zaman aşımı): telefonun bağlantısı sağlamdır, hiçbir Kestirme çalışmaz
    func testWithTheInternetUpASilentGeminiNeverRunsTheShortcuts() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.health.geminiResult = .unreachable("zaman aşımı")
        await h.vm.runRecovery(.network)
        XCTAssertTrue(h.shortcuts.runs.isEmpty, "\(h.shortcuts.runs)")
        XCTAssertEqual(h.vm.phase, .listening, "Hiçbir şey durdurulmadı")
        // İnternet gerçekten yoksa onarım yine çalışır
        h.health.internet = false
        h.shortcuts.onRun = { _ in h.health.internet = true }
        await h.vm.runRecovery(.network)
        let back = await waitUntil(45) { h.vm.phase == .listening && !h.shortcuts.runs.isEmpty }
        XCTAssertTrue(back, "\(h.shortcuts.runs)")
        XCTAssertEqual(h.shortcuts.runs.first, "Hücresel_Ac")
    }
}
