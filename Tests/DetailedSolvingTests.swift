import XCTest
@testable import G526CameraDrive

/// Ayrıntılı çözüm (kullanıcı isteği 2026-11-25): 30 soruluk ALES sayısal denemesinde tek istekte 13 yanlış çıkmıştı. Windows programında
/// denenip işe yarayan iki değişiklik buraya taşındı: sistem komutuna eklenen çözüm kuralları ve sayfa taramasında en yüksek düşünme düzeyi.
/// Seçenek kapalıyken istek önceki sürümdekiyle aynıdır; açıkken kurallar her isteğe, yüksek düşünme düzeyi yalnız sayfa isteğine girer.
@MainActor
final class DetailedSolvingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FakeGeminiProtocol.reset()
    }

    // MARK: Yardımcılar

    private func json(_ object: [String: Any]) -> Data {
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private func ok(_ text: String) -> FakeGeminiProtocol.Reply {
        let candidate: [String: Any] = ["finishReason": "STOP", "content": ["parts": [["text": text]]]]
        return FakeGeminiProtocol.Reply(status: 200, body: json(["candidates": [candidate]]), error: nil)
    }

    private func refusal(_ status: Int, _ message: String) -> FakeGeminiProtocol.Reply {
        let error: [String: Any] = ["code": status, "message": message]
        return FakeGeminiProtocol.Reply(status: status, body: json(["error": error]), error: nil)
    }

    private func queue(_ replies: [FakeGeminiProtocol.Reply]) {
        FakeGeminiProtocol.lock.lock()
        FakeGeminiProtocol.replies = replies
        FakeGeminiProtocol.lock.unlock()
    }

    private func sentBodies() -> [Data] {
        FakeGeminiProtocol.lock.lock()
        defer { FakeGeminiProtocol.lock.unlock() }
        return FakeGeminiProtocol.bodies
    }

    private func sentURLs() -> [String] {
        FakeGeminiProtocol.lock.lock()
        defer { FakeGeminiProtocol.lock.unlock() }
        return FakeGeminiProtocol.urls.map { $0.absoluteString }
    }

    private func sent(_ index: Int) throws -> [String: Any] {
        let bodies = sentBodies()
        guard bodies.count > index else {
            XCTFail("Giden istek yok (\(index))")
            return [:]
        }
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: bodies[index]) as? [String: Any])
    }

    private func object(_ data: Data) throws -> [String: Any] {
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func systemTexts(_ body: [String: Any]) -> [String] {
        let parts = ((body["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        return parts.compactMap { $0["text"] as? String }
    }

    private func thinkingLevel(_ body: [String: Any]) -> String? {
        let config = body["generationConfig"] as? [String: Any]
        return (config?["thinkingConfig"] as? [String: Any])?["thinkingLevel"] as? String
    }

    /// `on`: iki seçenek birden (çözüm kuralları ve yüksek düşünme düzeyi); ayrı ayrı denemek için `rules` / `deep`
    private func service(on: Bool) -> GeminiAnswerService {
        return service(rules: on, deep: on)
    }

    private func service(rules: Bool, deep: Bool) -> GeminiAnswerService {
        let answering = GeminiAnswerService(profiles: testProfiles(count: 1), makeClient: fakeProfileClient)
        answering.solveRulesEnabled = { rules }
        answering.deepThinkingEnabled = { deep }
        return answering
    }

    // MARK: Kurallar

    func testTheRulesCoverTheFourSubjectAreasAndKeepTheAnswerFormat() {
        let rules = GeminiAnswerService.solveRules
        for word in ["GENEL:", "SAYISAL", "TÜRKÇE VE SÖZEL", "İNGİLİZCE", "ALAN BİLGİSİ", "Türk Dili ve Edebiyatı"] {
            XCTAssertTrue(rules.contains(word), "Kurallarda eksik bölüm: \(word)")
        }
        XCTAssertTrue(rules.contains("cevap biçimi yukarıda anlatıldığı gibidir"), "Kurallar cevap biçimini değiştirmez")
        XCTAssertTrue(rules.contains("şıklarda yoksa"), "Bulunan değer şıklarda yoksa çözüm baştan denetlenir")
        XCTAssertTrue(rules.contains("sağlamasını yap"))
        XCTAssertTrue(rules.contains("yalnız metinde söylenene dayan"), "Paragraf sorusunda metnin dışına çıkılmaz")
        XCTAssertTrue(rules.contains("Eser-yazar"), "Alan derslerinde benzer adlar karıştırılmaz")
        XCTAssertFalse(rules.contains("\\"), "Metinde kaçış işareti kalmamalı")
        XCTAssertEqual(GeminiAnswerService.deepLimit, 240, "Yüksek düşünme düzeyinde model başına bekleme")
    }

    // MARK: Kapalıyken eskisi gibi

    func testWithDetailedSolvingOffTheRequestsAreTheOldOnes() async throws {
        let plain = try GeminiAnswerService.requestBody(question: "bir soru", expectedNumber: 1)
        XCTAssertEqual(GeminiAnswerService.body(plain, forModel: "gemini-4-argon"), plain, "Seçenek kapalıyken gövdeye dokunulmaz (bayt bayt aynı)")

        queue([ok("Soru 1, Adana, Bir\nSoru 2, Bursa, İki")])
        let replies = try await service(on: false).answerPage(capture: FakeCamera.page(1, photos: 3), expectedNumber: 1)
        XCTAssertEqual(replies.map { $0.number }, [1, 2])
        let body = try sent(0)
        XCTAssertEqual(systemTexts(body), [GeminiAnswerService.pageSystemPrompt], "Sistem komutu önceki sürümdekiyle aynıdır")
        XCTAssertNil(thinkingLevel(body), "Düşünme düzeyi istenmez: modelin kendi ayarı kullanılır")
    }

    // MARK: Açıkken

    func testThePageRequestCarriesTheRulesAndAsksForTheHighestThinkingLevel() async throws {
        queue([ok("Soru 4, Denizli, Dört\nSoru 5, Erzurum, Beş")])
        let replies = try await service(on: true).answerPage(capture: FakeCamera.page(1, photos: 3), expectedNumber: 4)
        XCTAssertEqual(replies.map { $0.option }, ["Denizli", "Erzurum"], "Cevap biçimi ve çözümü değişmez")
        let body = try sent(0)
        XCTAssertEqual(systemTexts(body), [GeminiAnswerService.pageSystemPrompt, GeminiAnswerService.solveRules],
                       "Okuma komutu aynı kalır; çözüm kuralları ardına eklenir")
        XCTAssertEqual(thinkingLevel(body), "high", "Sayfadaki sorular en yüksek düşünme düzeyiyle çözülür")
        XCTAssertEqual((body["generationConfig"] as? [String: Any])?["mediaResolution"] as? String, "MEDIA_RESOLUTION_HIGH",
                       "Görüntü çözünürlüğü ayarı korunur")
        XCTAssertNotNil(body["contents"], "Görüntü ve soru metni korunur")
    }

    func testASpokenQuestionGetsTheRulesButKeepsItsShortWait() async throws {
        queue([ok("Soru 2, Bursa, Cevap")])
        let reply = try await service(on: true).answer(question: "ikinci soru", english: "", expectedNumber: 2, audio: nil, passage: nil)
        XCTAssertEqual(reply.option, "Bursa")
        let body = try sent(0)
        XCTAssertEqual(systemTexts(body), [GeminiAnswerService.systemPrompt, GeminiAnswerService.solveRules])
        XCTAssertNil(thinkingLevel(body), "Sesli soruda bekleme kısadır: yüksek düşünme düzeyi istenmez")
    }

    func testASingleCapturedQuestionGetsTheRulesToo() async throws {
        queue([ok("Soru 7, Ceyhan, Cevap")])
        let reply = try await service(on: true).answer(capture: CapturedQuestion(photo: Data([1, 2, 3])), expectedNumber: 7)
        XCTAssertEqual(reply.number, 7)
        let body = try sent(0)
        XCTAssertEqual(systemTexts(body), [GeminiAnswerService.captureSystemPrompt, GeminiAnswerService.solveRules])
        XCTAssertNil(thinkingLevel(body))
    }

    func testWithSourcesTheRulesComeBeforeTheSourceInstruction() async throws {
        let answering = service(on: true)
        answering.sourceStore = { _ in "fileSearchStores/depo" }
        queue([ok("Soru 3, Ceyhan, Cevap")])
        _ = try await answering.answer(question: "üçüncü soru", english: "", expectedNumber: 3, audio: nil, passage: nil)
        let body = try sent(0)
        XCTAssertEqual(systemTexts(body), [GeminiAnswerService.systemPrompt, GeminiAnswerService.solveRules, GeminiAnswerService.sourceInstruction],
                       "Sıra: okuma komutu, çözüm kuralları, kaynak talimatı")
        XCTAssertNotNil(body["tools"], "Kaynaklara göre cevaplama ayrıntılı çözümle birlikte çalışır")
    }

    // MARK: Düşünme düzeyini tanımayan model

    func testAModelThatRefusesTheThinkingLevelIsAskedAgainWithoutIt() async throws {
        let answering = service(on: true)
        queue([refusal(400, "Invalid value at 'generation_config.thinking_config': thinking level is not supported by this model"),
               ok("Soru 1, Adana, Bir")])
        let replies = try await answering.answerPage(capture: FakeCamera.page(1, photos: 3), expectedNumber: 1)
        XCTAssertEqual(replies.first?.option, "Adana", "Ayar reddedilse de cevap aynı modelden alınır")
        XCTAssertEqual(sentBodies().count, 2)
        XCTAssertEqual(thinkingLevel(try sent(0)), "high")
        XCTAssertNil(thinkingLevel(try sent(1)), "Aynı istek ayarsız yeniden gönderilir")
        XCTAssertEqual(systemTexts(try sent(1)), [GeminiAnswerService.pageSystemPrompt, GeminiAnswerService.solveRules], "Çözüm kuralları yine gider")
        let urls = sentURLs()
        XCTAssertEqual(urls.count, 2)
        XCTAssertEqual(urls.first, urls.last, "Yeniden deneme aynı modele gider; sıradaki modele geçilmez")

        queue([ok("Soru 2, Bursa, İki")])
        _ = try await answering.answerPage(capture: FakeCamera.page(2, photos: 3), expectedNumber: 2)
        XCTAssertEqual(sentBodies().count, 3)
        XCTAssertNil(thinkingLevel(try sent(2)), "Ayarı reddeden model aynı çalıştırmada her istekte yeniden denenmez")
    }

    func testOnlyAThinkingMessageCountsAsAThinkingRefusal() {
        XCTAssertTrue(GeminiAnswerService.thinkingRejection(GeminiError("Gemini isteği kabul etmedi (400): Unknown name \"thinkingLevel\"", .http, status: 400)))
        XCTAssertTrue(GeminiAnswerService.thinkingRejection(GeminiError("Gemini isteği kabul etmedi (400): Thinking level HIGH is not supported", .http, status: 400)))
        XCTAssertFalse(GeminiAnswerService.thinkingRejection(GeminiError("Gemini isteği kabul etmedi (400): File search is not supported", .http, status: 400)),
                       "Başka bir 400 düşünme ayarıyla ilgili sayılmaz")
        XCTAssertFalse(GeminiAnswerService.thinkingRejection(GeminiError("API anahtarı geçersiz (thinking)", .key, status: 400)), "Geçersiz anahtar ayarla ilgili değildir")
        XCTAssertFalse(GeminiAnswerService.thinkingRejection(GeminiError("thinking sunucu hatası", .http, status: 503)))
    }

    // MARK: Modele göre gövde

    func testTheBodyFollowsTheModelFamily() throws {
        let plain = try GeminiAnswerService.requestBody(question: "soru", expectedNumber: 1)

        let argon = try object(GeminiAnswerService.body(plain, forModel: "gemini-4-argon", solve: true, deep: true))
        XCTAssertEqual(thinkingLevel(argon), "high")
        XCTAssertEqual(systemTexts(argon), [GeminiAnswerService.systemPrompt, GeminiAnswerService.solveRules])

        let lite = try object(GeminiAnswerService.body(plain, forModel: "gemini-3.5-flash-lite", deep: true))
        XCTAssertEqual(thinkingLevel(lite), "high", "Varsayılanı en düşük düzey olan modelden de yüksek düzey istenir")
        XCTAssertEqual(systemTexts(lite), [GeminiAnswerService.systemPrompt], "Kurallar yalnız istenince eklenir")

        let old = try object(GeminiAnswerService.body(plain, forModel: "gemini-2.5-flash", solve: true, deep: true))
        XCTAssertNil(thinkingLevel(old), "Gemini 2.x düşünme düzeyi ayarını tanımaz: gönderilmez")
        XCTAssertEqual(systemTexts(old).count, 2, "Çözüm kuralları ona da gider")

        let rulesOnly = try object(GeminiAnswerService.body(plain, forModel: "gemini-4-argon", solve: true))
        XCTAssertNil(thinkingLevel(rulesOnly), "Yalnız kurallar istenirse düşünme düzeyine dokunulmaz")
        XCTAssertNil(rulesOnly["generationConfig"])

        let gemma = try object(GeminiAnswerService.body(plain, forModel: "gemma-4-31b-it"))
        XCTAssertEqual(thinkingLevel(gemma), "high", "Gemma eskisi gibi her zaman yüksek düzeyle sorulur")
    }

    // MARK: Ayar

    /// Kullanıcı bildirimi 2026-11-26: iki özellik tek seçenekken ve açık gelirken kamera taramalarında Gemini'den cevap gelmedi; kapatınca geldi.
    /// Artık ayrıdırlar: kurallar açık gelir (beklemeyi uzatmaz), yüksek düşünme düzeyi kapalı gelir
    func testTheRulesAreOnAndHighThinkingIsOffByDefault() {
        let defaults = UserDefaults(suiteName: "g526.testler.cozum.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.solveRules, "Çözüm kuralları varsayılan açıktır")
        XCTAssertFalse(settings.deepThinking, "Yüksek düşünme düzeyi varsayılan kapalıdır")
        settings.solveRules = false
        settings.deepThinking = true
        let again = AppSettings(defaults: defaults)
        XCTAssertFalse(again.solveRules, "Seçim hatırlanır")
        XCTAssertTrue(again.deepThinking)
    }

    func testWithOnlyTheRulesThePageIsAskedAtTheModelsOwnThinkingLevel() async throws {
        queue([ok("Soru 1, Adana, Bir")])
        let replies = try await service(rules: true, deep: false).answerPage(capture: FakeCamera.page(1, photos: 3), expectedNumber: 1)
        XCTAssertEqual(replies.first?.option, "Adana")
        let body = try sent(0)
        XCTAssertEqual(systemTexts(body), [GeminiAnswerService.pageSystemPrompt, GeminiAnswerService.solveRules], "Kurallar gider")
        XCTAssertNil(thinkingLevel(body), "Düşünme düzeyi istenmez: cevap eskisi kadar çabuk gelir")
    }

    /// Kullanıcı bildirimi 2026-11-26: yüksek düşünme düzeyiyle her model sırayla zaman aşımına düşüyor ve cevap hiç gelmiyordu. Artık ilk zaman
    /// aşımından sonra kalan modeller kendi düşünme düzeyleriyle ve olağan süreyle sorulur
    func testAfterOneTimeoutWithHighThinkingTheOtherModelsAreAskedTheUsualWay() async throws {
        let answering = GeminiAnswerService(profiles: testProfiles(count: 2), captureLimit: 0.2, makeClient: fakeProfileClient)
        answering.deepThinkingEnabled = { true }
        answering.deepWait = 0.4
        var stalled = FakeGeminiProtocol.Reply()
        stalled.stall = true
        queue([stalled, ok("Soru 1, Adana, Bir")])
        let replies = try await answering.answerPage(capture: FakeCamera.page(1, photos: 3), expectedNumber: 1)
        XCTAssertEqual(replies.first?.option, "Adana", "Cevap ikinci modelden gelir")
        XCTAssertEqual(sentBodies().count, 2)
        XCTAssertEqual(thinkingLevel(try sent(0)), "high", "İlk model yüksek düşünme düzeyiyle soruldu")
        XCTAssertNil(thinkingLevel(try sent(1)), "İlki süresinde cevap vermedi: sıradaki model kendi düşünme düzeyiyle sorulur")
        let urls = sentURLs()
        XCTAssertNotEqual(urls.first, urls.last, "Sıradaki modele geçildi")
    }

    func testWithOnlyHighThinkingTheSystemPromptIsTheOldOne() async throws {
        queue([ok("Soru 1, Adana, Bir")])
        _ = try await service(rules: false, deep: true).answerPage(capture: FakeCamera.page(1, photos: 3), expectedNumber: 1)
        let body = try sent(0)
        XCTAssertEqual(systemTexts(body), [GeminiAnswerService.pageSystemPrompt])
        XCTAssertEqual(thinkingLevel(body), "high")
    }
}
