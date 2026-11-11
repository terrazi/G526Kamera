import XCTest
@testable import G526CameraDrive

final class GeminiSupportTests: XCTestCase {
    private let pdf = Data("%PDF-1.4 deneme".utf8)

    private func parts(_ content: [String: Any]) -> [[String: Any]] {
        return (content["parts"] as? [[String: Any]]) ?? []
    }

    // MARK: İstek kurma

    func testDocumentsGoFirstInTheFirstUserTurn() throws {
        let docs = [GeminiDoc(name: "a.pdf", data: pdf), GeminiDoc(name: "b.pdf", data: pdf)]
        let history = [GeminiTurn(question: "önceki soru", answer: "önceki cevap")]
        let object = GeminiSupport.requestObject(questionText: "toplam nedir", audioWAV: nil, docs: docs, history: history)
        let contents = try XCTUnwrap(object["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.map { $0["role"] as? String ?? "" }, ["user", "model", "user"])

        let first = parts(contents[0])
        XCTAssertEqual(first.count, 5)
        XCTAssertEqual(first[0]["text"] as? String, "Belge 1: a.pdf")
        let inline = try XCTUnwrap(first[1]["inlineData"] as? [String: String])
        XCTAssertEqual(inline["mimeType"], "application/pdf")
        XCTAssertEqual(Data(base64Encoded: inline["data"] ?? ""), pdf)
        XCTAssertEqual(first[2]["text"] as? String, "Belge 2: b.pdf")
        XCTAssertEqual(first[4]["text"] as? String, "önceki soru")

        XCTAssertEqual(parts(contents[2]).count, 1)
        XCTAssertEqual(parts(contents[2])[0]["text"] as? String, "toplam nedir")
    }

    func testModelTurnIsJsonWithQuestionAndAnswer() throws {
        let history = [GeminiTurn(question: "kaç lira", answer: "Yüz lira.")]
        let object = GeminiSupport.requestObject(questionText: "peki", audioWAV: nil, docs: [], history: history)
        let contents = try XCTUnwrap(object["contents"] as? [[String: Any]])
        let text = try XCTUnwrap(parts(contents[1])[0]["text"] as? String)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(json["soru"] as? String, "kaç lira")
        XCTAssertEqual(json["cevap"] as? String, "Yüz lira.")
    }

    func testAudioQuestionComesAfterDocumentsAsWav() throws {
        let wav = GeminiSupport.wav(fromPCM16: Data(count: 3200))
        let object = GeminiSupport.requestObject(questionText: "", audioWAV: wav,
                                                 docs: [GeminiDoc(name: "a.pdf", data: pdf)], history: [])
        let contents = try XCTUnwrap(object["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.count, 1)
        let all = parts(contents[0])
        XCTAssertEqual(all.count, 4)
        XCTAssertNotNil(all[1]["inlineData"])
        let audio = try XCTUnwrap(all[2]["inlineData"] as? [String: String])
        XCTAssertEqual(audio["mimeType"], "audio/wav")
        XCTAssertEqual(Data(base64Encoded: audio["data"] ?? ""), wav)
        XCTAssertTrue((all[3]["text"] as? String ?? "").contains("çağrı sözcüğü"))
    }

    func testRequestWithoutDocumentsHasNoInlineData() throws {
        let object = GeminiSupport.requestObject(questionText: "merhaba", audioWAV: nil, docs: [], history: [])
        let contents = try XCTUnwrap(object["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.count, 1)
        XCTAssertNil(parts(contents[0])[0]["inlineData"])
    }

    func testRequestAsksForJsonAndHasSystemInstruction() throws {
        let object = GeminiSupport.requestObject(questionText: "x", audioWAV: nil, docs: [], history: [])
        let config = try XCTUnwrap(object["generationConfig"] as? [String: Any])
        XCTAssertEqual(config["responseMimeType"] as? String, "application/json")
        XCTAssertNotNil(config["responseSchema"])
        let system = try XCTUnwrap(object["systemInstruction"] as? [String: Any])
        let text = try XCTUnwrap(parts(system)[0]["text"] as? String)
        XCTAssertTrue(text.contains("Belge 1"))
        XCTAssertTrue(text.contains("Belgelerde bunu göremedim"))
    }

    func testBuiltBodyIsValidJsonWithoutEscapedSlashes() throws {
        let body = try GeminiSupport.buildRequest(questionText: "x", audioWAV: nil,
                                                  docs: [GeminiDoc(name: "a.pdf", data: pdf)], history: [])
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("application/pdf"))
        XCTAssertFalse(text.contains("\\/"))
    }

    func testWavHeader() {
        let pcm = Data(count: 3200)
        let wav = GeminiSupport.wav(fromPCM16: pcm)
        XCTAssertEqual(wav.count, 44 + 3200)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        let rate = wav[24..<28].enumerated().reduce(0) { $0 + Int($1.element) << (8 * $1.offset) }
        XCTAssertEqual(rate, 16000)
        let length = wav[40..<44].enumerated().reduce(0) { $0 + Int($1.element) << (8 * $1.offset) }
        XCTAssertEqual(length, 3200)
    }

    // MARK: Cevap ayrıştırma

    private func response(_ text: String, finish: String = "STOP") -> [String: Any] {
        return ["candidates": [["finishReason": finish, "content": ["parts": [["text": text]]]]],
                "usageMetadata": ["promptTokenCount": 10, "candidatesTokenCount": 5, "totalTokenCount": 15]]
    }

    func testParsesJsonAnswer() throws {
        let answer = try GeminiSupport.parseAnswer(response("{\"soru\": \"toplam\", \"cevap\": \"Yüz lira.\"}"))
        XCTAssertEqual(answer.question, "toplam")
        XCTAssertEqual(answer.answer, "Yüz lira.")
        XCTAssertEqual(answer.totalTokens, 15)
        XCTAssertEqual(answer.promptTokens, 10)
    }

    func testParsesFencedJsonAnswer() throws {
        let answer = try GeminiSupport.parseAnswer(response("```json\n{\"soru\": \"q\", \"cevap\": \"c\"}\n```"))
        XCTAssertEqual(answer.answer, "c")
        XCTAssertEqual(answer.question, "q")
    }

    func testPlainTextAnswerIsKept() throws {
        let answer = try GeminiSupport.parseAnswer(response("Düz yazı cevabı."))
        XCTAssertEqual(answer.answer, "Düz yazı cevabı.")
        XCTAssertEqual(answer.question, "")
    }

    func testThoughtPartsAreSkipped() throws {
        let object: [String: Any] = ["candidates": [["content": ["parts": [
            ["text": "düşünce", "thought": true],
            ["text": "{\"soru\":\"a\",\"cevap\":\"b\"}"]]]]]]
        XCTAssertEqual(try GeminiSupport.parseAnswer(object).answer, "b")
    }

    func testBlockedAndEmptyAnswersThrow() {
        let cases: [(Any, GeminiErrorKind)] = [
            (["promptFeedback": ["blockReason": "SAFETY"]], .blocked),
            (["candidates": [Any]()], .empty),
            (response("  "), .empty),
            (response("", finish: "SAFETY"), .blocked),
            ([1, 2], .error)
        ]
        for (object, kind) in cases {
            do {
                _ = try GeminiSupport.parseAnswer(object)
                XCTFail("hata beklenirdi: \(object)")
            } catch let e as GeminiError {
                XCTAssertEqual(e.kind, kind)
            } catch {
                XCTFail("beklenmeyen hata türü")
            }
        }
    }

    // MARK: Hata çevirisi

    private func describe(_ status: Int, _ message: String, reason: String = "") -> (GeminiErrorKind, String) {
        var err: [String: Any] = ["message": message]
        if !reason.isEmpty { err["details"] = [["reason": reason]] }
        return GeminiSupport.describeError(status: status, json: ["error": err], model: "m")
    }

    func testErrorMapping() {
        XCTAssertEqual(describe(400, "API key not valid. Please pass a valid API key.", reason: "API_KEY_INVALID").0, .key)
        XCTAssertEqual(describe(403, "denied").0, .key)
        XCTAssertEqual(describe(404, "not found").0, .model)
        XCTAssertEqual(describe(503, "x").0, .http)
        XCTAssertEqual(describe(413, "x").0, .tooBig)
        XCTAssertEqual(describe(400, "User location is not supported for the API use.").0, .key)
        let cap = describe(429, "Your project has exceeded its monthly spending cap.")
        XCTAssertEqual(cap.0, .cap)
        XCTAssertTrue(cap.1.contains("harcama sınırınız doldu"), cap.1)
        XCTAssertFalse(cap.1.contains("Ücretsiz"))
        let quota = describe(429, "Quota exceeded. Please retry in 31.2s.")
        XCTAssertEqual(quota.0, .quota)
        XCTAssertTrue(quota.1.contains("32 saniye"), quota.1)
    }

    // MARK: Belge seçimi

    func testBudgetDropsOldestDocuments() {
        let mb = 1024 * 1024
        let picked = GeminiSupport.selectDocs([(name: "yeni", size: 6 * mb), (name: "orta", size: 6 * mb), (name: "eski", size: 6 * mb)])
        XCTAssertEqual(picked.chosen, [0, 1])
        XCTAssertEqual(picked.skipped, ["eski"])
    }

    func testOversizedSingleDocumentIsSkipped() {
        let picked = GeminiSupport.selectDocs([(name: "dev", size: 20 * 1024 * 1024), (name: "küçük", size: 1000)])
        XCTAssertEqual(picked.chosen, [1])
        XCTAssertEqual(picked.skipped, ["dev"])
    }

    // MARK: Drive listesi

    func testDriveListingParsing() {
        let json: [String: Any] = ["files": [
            ["id": "a", "name": "x.pdf", "size": "1234", "createdTime": "2026-11-01T10:00:00Z"],
            ["name": "kimliksiz"],
            ["id": "b", "size": 99]
        ]]
        let files = DriveClient.parseListing(json)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0], DriveFileInfo(id: "a", name: "x.pdf", size: 1234, created: "2026-11-01T10:00:00Z"))
        XCTAssertEqual(files[1].size, 99)
        XCTAssertEqual(files[1].name, "belge.pdf")
        XCTAssertTrue(DriveClient.parseListing([:]).isEmpty)
    }
}

final class GeminiTextTests: XCTestCase {
    func testMarkdownIsRemoved() {
        XCTAssertEqual(GeminiText.cleanForSpeech("**Toplam** tutar %20 oldu"), "Toplam tutar yüzde 20 oldu")
        XCTAssertEqual(GeminiText.cleanForSpeech("12,5%"), "yüzde 12,5")
        XCTAssertEqual(GeminiText.cleanForSpeech("- birinci\n- ikinci"), "birinci\nikinci")
        XCTAssertEqual(GeminiText.cleanForSpeech("# Başlık\nmetin"), "Başlık\nmetin")
    }

    func testLinksAndEmojiAreRemoved() {
        XCTAssertEqual(GeminiText.cleanForSpeech("[site](https://x.com) ve https://a.b/c"), "site ve bağlantı")
        XCTAssertEqual(GeminiText.cleanForSpeech("Tamam 😀 bitti"), "Tamam bitti")
    }

    func testPlainTurkishTextIsUntouched() {
        let text = "Fatura tutarı bin iki yüz elli Türk lirası, son ödeme tarihi 15 Kasım."
        XCTAssertEqual(GeminiText.cleanForSpeech(text), text)
    }

    func testCallWordIsStripped() {
        let words = GeminiText.triggerList(for: GeminiText.defaultCallWord)
        XCTAssertEqual(GeminiText.stripTrigger("Gemini, son faturanın tutarı nedir", words: words), "son faturanın tutarı nedir")
        XCTAssertEqual(GeminiText.stripTrigger("Cemini son fatura", words: words), "son fatura")
        XCTAssertEqual(GeminiText.stripTrigger("Gemini", words: words), "")
        XCTAssertEqual(GeminiText.stripTrigger("bugün gemini", words: words), "bugün gemini")
    }

    func testDefaultCallWordsIncludeRecognitionVariants() {
        let list = GeminiText.callWordList("")
        XCTAssertEqual(list.first, "dinle", "boş çağrı sözcüğü: önce \"dinle\", sonra \"gemini\"")
        XCTAssertTrue(list.contains("gemini"))
        for v in ["cimini", "geminay", "ceminay", "cemini", "jemini"] { XCTAssertTrue(list.contains(v), v) }
        XCTAssertEqual(GeminiText.callWordList("  ;; "), list)
    }

    func testCustomCallWordReplacesTheDefault() {
        XCTAssertEqual(GeminiText.callWordList("dostum"), ["dostum"])
        XCTAssertEqual(GeminiText.callPhrases("Dostum, hey asistan"), "Dostum, hey asistan")
        // "gemini" listede kalırsa varyantları da gelir, yinelenenler atılır
        let both = GeminiText.callWordList("dostum; Gemini, dostum")
        XCTAssertEqual(Array(both.prefix(2)), ["dostum", "Gemini"])
        XCTAssertTrue(both.contains("jemini"))
        XCTAssertEqual(both.filter { GeminiText.fold($0) == "dostum" }.count, 1)
    }

    func testTooShortCallWordsAreDropped() {
        XCTAssertEqual(GeminiText.callWordList("ok, he, dostum"), ["dostum"])
        XCTAssertEqual(GeminiText.callWordList("ok"), GeminiText.callWordList(""))
    }

    func testCustomCallWordIsStrippedOnlyAsAWholeWord() {
        let words = GeminiText.triggerList(for: "dostum")
        XCTAssertEqual(GeminiText.stripTrigger("Dostum, son faturanın tutarı nedir", words: words), "son faturanın tutarı nedir")
        XCTAssertEqual(GeminiText.stripTrigger("DOSTUM kira ne kadar", words: words), "kira ne kadar")
        XCTAssertEqual(GeminiText.stripTrigger("dostumun faturası ne kadar", words: words), "dostumun faturası ne kadar")
        // "dostum" seçilince "gemini" artık çağrı sözcüğü değildir
        XCTAssertEqual(GeminiText.stripTrigger("Gemini kira ne kadar", words: words), "Gemini kira ne kadar")
    }

    func testCallWordMatchesWhatTheRecognizerHears() {
        let phrases = GeminiText.callPhrases("dostum")
        XCTAssertGreaterThan(SpeechMatcher.occurrences(in: "dostum son fatura ne kadar", trigger: phrases), 0)
        XCTAssertGreaterThan(SpeechMatcher.occurrences(in: "Dostum", trigger: phrases), 0)
        XCTAssertEqual(SpeechMatcher.occurrences(in: "gemini son fatura", trigger: phrases), 0)
        XCTAssertGreaterThan(SpeechMatcher.occurrences(in: "cemini son fatura", trigger: GeminiText.callPhrases("")), 0)
    }

    func testCallWordClashWithOtherCommandsIsReported() {
        XCTAssertEqual(GeminiText.clashes("okey", with: ["okey, tamam"]), ["okey"])
        XCTAssertEqual(GeminiText.clashes("dostum", with: ["okey", "hepsi tamamlandı"]), [])
        XCTAssertEqual(GeminiText.clashes("", with: ["okey"]), [])
    }
}

final class EndpointDetectorTests: XCTestCase {
    private let rate = 16000

    private func silence(_ seconds: Double) -> [Int16] {
        return [Int16](repeating: 0, count: Int(Double(rate) * seconds))
    }

    private func loud(_ seconds: Double) -> [Int16] {
        return [Int16](repeating: 3000, count: Int(Double(rate) * seconds))
    }

    /// Örnekleri 0,1 sn'lik parçalarla verir; ilk bitiş durumunu (yoksa son durumu) döndürür
    private func run(_ detector: inout EndpointDetector, _ samples: [Int16]) -> EndpointDetector.State {
        var state = EndpointDetector.State.wait
        let step = rate / 10
        var i = 0
        while i < samples.count {
            let end = min(i + step, samples.count)
            state = detector.feed(Array(samples[i..<end]))
            if state == .done || state == .noSpeech || state == .max { return state }
            i = end
        }
        return state
    }

    func testSilenceOnlyEndsWithNoSpeech() {
        var d = EndpointDetector()
        XCTAssertEqual(run(&d, silence(8)), .noSpeech)
    }

    /// Gerçek konuşma gibi: başta kısa sessizlik (eşik uyarlansın), sonra konuşma
    private func lead(_ speech: Double) -> [Int16] {
        return silence(0.5) + loud(speech)
    }

    /// 0,6 sn konuşma + 0,3 sn duraklama tekrarı (sürekli konuşan biri)
    private func bursts(_ seconds: Double) -> [Int16] {
        var out = silence(0.5)
        while Double(out.count) / Double(rate) < seconds {
            out += loud(0.6)
            out += silence(0.3)
        }
        return out
    }

    func testSpeechThenSilenceIsDone() {
        var d = EndpointDetector()
        XCTAssertEqual(run(&d, lead(1.0)), .speech)
        XCTAssertEqual(run(&d, silence(0.8)), .speech)
        XCTAssertEqual(run(&d, silence(1.0)), .done)
        XCTAssertTrue(d.started)
    }

    func testTooShortBlipDoesNotCountAsSpeech() {
        var d = EndpointDetector()
        XCTAssertEqual(run(&d, lead(0.1)), .wait)
        XCTAssertFalse(d.started)
        XCTAssertEqual(run(&d, silence(8)), .noSpeech)
    }

    func testEndlessSpeechStopsAtMaximum() {
        var d = EndpointDetector()
        XCTAssertEqual(run(&d, bursts(33)), .max)
        XCTAssertTrue(d.started)
    }

    func testSteadyBackgroundNoiseIsNotSpeech() {
        var d = EndpointDetector()
        let noise = [Int16](repeating: 400, count: rate * 3)
        XCTAssertEqual(run(&d, noise), .wait)
        XCTAssertFalse(d.started)
    }

    func testResultIsSticky() {
        var d = EndpointDetector()
        _ = run(&d, lead(1.0))
        _ = run(&d, silence(2.0))
        XCTAssertEqual(d.feed(loud(0.5)), .done)
    }

    func testUnlimitedWaitNeverGivesUpButStillCatchesTheQuestion() {
        var d = EndpointDetector(noSpeech: .infinity)
        XCTAssertEqual(run(&d, silence(60)), .wait)
        XCTAssertFalse(d.started)
        XCTAssertEqual(run(&d, lead(1.0)), .speech)
        XCTAssertEqual(run(&d, silence(2.0)), .done)
    }

    func testMaximumLengthCountsFromTheStartOfSpeech() {
        var d = EndpointDetector(noSpeech: .infinity)
        XCTAssertEqual(run(&d, silence(40)), .wait, "uzun bekleme konuşma süresinden sayılmamalı")
        XCTAssertEqual(run(&d, bursts(33)), .max)
        XCTAssertTrue(d.started)
    }

    func testScatteredShortSoundsDoNotAddUpToSpeech() {
        var d = EndpointDetector(noSpeech: .infinity)
        for _ in 0..<10 {
            _ = run(&d, silence(0.6))
            _ = run(&d, loud(0.1))
        }
        XCTAssertFalse(d.started, "kapı / tuş sesleri birikip konuşma sayılmamalı")
        XCTAssertEqual(run(&d, lead(1.0)), .speech)
        XCTAssertTrue(d.started)
    }
}

final class GeminiSessionTextTests: XCTestCase {
    func testReadyLine() {
        XCTAssertEqual(GeminiText.readyLine(count: 3, new: nil), "3 belge hazır. Sorunuzu bekliyorum.")
        XCTAssertEqual(GeminiText.readyLine(count: 3, new: 3), "3 belge hazır, hepsi yeni. Sorunuzu bekliyorum.")
        XCTAssertEqual(GeminiText.readyLine(count: 3, new: 1), "3 belge hazır, 1 tanesi yeni. Sorunuzu bekliyorum.")
        XCTAssertEqual(GeminiText.readyLine(count: 3, new: 0), "3 belge hazır. Sorunuzu bekliyorum.")
    }

    func testReadyLineMentionsPagesWhenTheyDifferFromDocuments() {
        XCTAssertEqual(GeminiText.readyLine(count: 2, new: nil, pages: 40), "2 belge, 40 sayfa hazır. Sorunuzu bekliyorum.")
        XCTAssertEqual(GeminiText.readyLine(count: 2, new: nil, pages: 2), "2 belge hazır. Sorunuzu bekliyorum.")
    }

    func testReadyLineAnnouncesWarnings() {
        let line = GeminiText.readyLine(count: 2, new: nil, warnings: ["3 belge boyut sınırı nedeniyle atlandı."])
        XCTAssertEqual(line, "2 belge hazır. Dikkat: 3 belge boyut sınırı nedeniyle atlandı. Sorunuzu bekliyorum.")
    }

    func testParsesCloseAndModelSwitchFlags() throws {
        func reply(_ json: String) -> [String: Any] {
            return ["candidates": [["content": ["parts": [["text": json]]]]]]
        }
        let close = try GeminiSupport.parseAnswer(reply("{\"soru\":\"yeter\",\"cevap\":\"Görüşürüz.\",\"kapat\":true}"))
        XCTAssertTrue(close.close)
        XCTAssertFalse(close.switchModel)
        let model = try GeminiSupport.parseAnswer(reply("{\"soru\":\"model değiştir\",\"cevap\":\"\",\"model_degistir\":true}"))
        XCTAssertTrue(model.switchModel)
        XCTAssertEqual(model.answer, "")
        let plain = try GeminiSupport.parseAnswer(reply("{\"soru\":\"a\",\"cevap\":\"b\"}"))
        XCTAssertFalse(plain.close)
        XCTAssertFalse(plain.switchModel)
    }

    func testServerErrorShowsTheServersOwnMessage() {
        let google = GeminiSupport.describeError(status: 503, json: GeminiSupport.errorObject(from: Data("{\"error\":{\"message\":\"The model is overloaded.\"}}".utf8)), model: "m").1
        XCTAssertEqual(google, "Gemini şu an yanıt vermiyor (503). Sunucunun mesajı: The model is overloaded. Biraz sonra yeniden deneyin.")
        let proxy = GeminiSupport.describeError(status: 503, json: GeminiSupport.errorObject(from: Data("<html><body><h1>503 Service Unavailable</h1><p>Proxy blocked</p></body></html>".utf8)), model: "m").1
        XCTAssertTrue(proxy.contains("Proxy blocked"), proxy)
        XCTAssertFalse(proxy.contains("<"), proxy)
        XCTAssertEqual(GeminiSupport.describeError(status: 503, json: GeminiSupport.errorObject(from: Data()), model: "m").1,
                       "Gemini şu an yanıt vermiyor (503). Biraz sonra yeniden deneyin.")
    }

    // MARK: Kota mesajı, yoğunluk, yedek model seçimi

    private func quotaDescribe(_ message: String, ids: [String] = []) -> String {
        let violations: [[String: Any]] = ids.map {
            ["quotaId": $0, "quotaMetric": "generativelanguage.googleapis.com/generate_content_free_tier_requests"]
        }
        let err: [String: Any] = ["message": message, "details": [["violations": violations]]]
        return GeminiSupport.describeError(status: 429, json: ["error": err], model: "m").1
    }

    func testQuotaMessageNamesTheDailyLimit() {
        let text = quotaDescribe("You exceeded your current quota. Quota exceeded for metric: generativelanguage.googleapis.com/generate_content_free_tier_requests, limit: 20, model: gemini-3.8-flash\nPlease retry in 41s.",
                                 ids: ["GenerateRequestsPerDayPerProjectPerModel-FreeTier"])
        XCTAssertTrue(text.contains("günlük kotası doldu"), text)
        XCTAssertTrue(text.contains("sınır: 20"), text)
        XCTAssertTrue(text.contains("10:00-11:00"), text)
        XCTAssertTrue(text.contains("Quota exceeded for metric"), text)
        XCTAssertFalse(text.contains("saniye"), text)
    }

    func testQuotaMessageNamesTheMinuteTokenLimit() {
        let text = quotaDescribe("Quota exceeded for metric: generativelanguage.googleapis.com/generate_content_free_tier_input_token_count, limit: 250000\nPlease retry in 20.4s.",
                                 ids: ["GenerateContentInputTokensPerMinutePerProjectPerModel-FreeTier"])
        XCTAssertTrue(text.contains("Dakikalık token sınırı"), text)
        XCTAssertTrue(text.contains("sınır: 250000"), text)
        XCTAssertTrue(text.contains("21 saniye"), text)
    }

    func testQuotaMessageNamesTheMinuteRequestLimit() {
        let text = quotaDescribe("Quota exceeded for metric: generativelanguage.googleapis.com/generate_content_free_tier_requests, limit: 5, model: gemini-3.8-flash\nPlease retry in 12s.",
                                 ids: ["GenerateRequestsPerMinutePerProjectPerModel-FreeTier"])
        XCTAssertTrue(text.contains("Dakikalık istek sınırı"), text)
        XCTAssertTrue(text.contains("sınır: 5"), text)
        XCTAssertTrue(text.contains("13 saniye"), text)
    }

    func testQuotaMessageWithoutDetailsStaysGeneric() {
        let text = quotaDescribe("Resource exhausted.")
        XCTAssertTrue(text.hasPrefix("Kota ya da hız sınırı aşıldı"), text)
        XCTAssertFalse(text.contains("Google:"), text)
    }

    func testOnlyBusyMessagesOn503CountAsOverload() {
        XCTAssertTrue(GeminiSupport.isOverload(GeminiError("Sunucunun mesajı: This model is currently experiencing high demand.", .http, status: 503)))
        XCTAssertTrue(GeminiSupport.isOverload(GeminiError("The model is overloaded.", .http, status: 503)))
        XCTAssertFalse(GeminiSupport.isOverload(GeminiError("Backend Error", .http, status: 503)))
        XCTAssertFalse(GeminiSupport.isOverload(GeminiError("high demand", .http, status: 500)))
        XCTAssertFalse(GeminiSupport.isOverload(GeminiError("", .http, status: 503)))
    }

    func testPickFallbackModelsPrefersNewestStableFlashThenLite() {
        let names = ["gemini-3.8-flash", "gemini-3.10-flash", "gemini-3.9-flash", "gemini-3.8-flash-lite", "gemini-3.9-flash-lite",
                     "gemini-3.9-flash-preview-05-20", "gemini-3.9-flash-image", "gemini-3.9-pro", "gemini-3.9-flash-live", "gemma-3-27b-it"]
        XCTAssertEqual(GeminiSupport.pickFallbackModels(names, current: "gemini-3.8-flash"), ["gemini-3.10-flash", "gemini-3.9-flash"])
        XCTAssertEqual(GeminiSupport.pickFallbackModels(names, current: "gemini-3.8-flash", limit: 4),
                       ["gemini-3.10-flash", "gemini-3.9-flash", "gemini-3.9-flash-lite", "gemini-3.8-flash-lite"])
        XCTAssertEqual(GeminiSupport.pickFallbackModels(["gemini-3.8-flash"], current: "gemini-3.8-flash"), [])
        XCTAssertEqual(GeminiSupport.pickFallbackModels(["gemini-2.5-flash", "gemini-3-flash"], current: "x"), ["gemini-3-flash", "gemini-2.5-flash"])
    }

    func testTruncatedJsonSalvagesAnswerInsteadOfReadingRawJson() throws {
        func response(_ text: String, finish: String) -> [String: Any] {
            return ["candidates": [["finishReason": finish, "content": ["parts": [["text": text]]]]]]
        }
        let cut = response("{\"soru\":\"ilk on\",\"cevap\":\"1) Adana. 2) \\\"Bursa\\\". 3) Cey", finish: "MAX_TOKENS")
        let answer = try GeminiSupport.parseAnswer(cut)
        XCTAssertTrue(answer.answer.hasPrefix("1) Adana. 2) \"Bursa\". 3) Cey"), answer.answer)
        XCTAssertTrue(answer.answer.hasSuffix(GeminiSupport.truncatedNote), answer.answer)
        XCTAssertFalse(answer.answer.contains("{"))
        XCTAssertEqual(answer.question, "ilk on")
        XCTAssertEqual(answer.lastQuestion, 0)
        let halfEscape = try GeminiSupport.parseAnswer(response("{\"soru\":\"x\",\"cevap\":\"ü \\u00", finish: "MAX_TOKENS"))
        XCTAssertTrue(halfEscape.answer.hasPrefix("ü"), halfEscape.answer)
        XCTAssertFalse(halfEscape.answer.contains("\\u"))
        XCTAssertThrowsError(try GeminiSupport.parseAnswer(response("{\"soru\":\"x\"", finish: "MAX_TOKENS")))
        XCTAssertEqual(try GeminiSupport.parseAnswer(response("Merhaba dünya", finish: "STOP")).answer, "Merhaba dünya")
    }

    func testEmptyAnswerFieldStaysEmptyInsteadOfShowingRawJson() throws {
        let object: [String: Any] = ["candidates": [["content": ["parts": [["text": "{\"soru\":\"\",\"cevap\":\"\"}"]]]]]]
        let a = try GeminiSupport.parseAnswer(object)
        XCTAssertEqual(a.answer, "")
        XCTAssertEqual(a.question, "")
    }

    func testModelListKeepsOnlyGenerateContentModels() {
        let json: [String: Any] = ["models": [
            ["name": "models/gemini-3.8-pro", "supportedGenerationMethods": ["generateContent", "countTokens"]],
            ["name": "models/embedding-001", "supportedGenerationMethods": ["embedContent"]],
            ["name": "models/gemini-3.8-flash", "supportedGenerationMethods": ["generateContent"]],
            ["name": "models/gemini-3.8-flash", "supportedGenerationMethods": ["generateContent"]]
        ]]
        XCTAssertEqual(GeminiSupport.parseModelList(json), ["gemini-3.8-flash", "gemini-3.8-pro"])
        XCTAssertEqual(GeminiSupport.parseModelList([:]), [])
    }
}

final class GeminiOcrTextTests: XCTestCase {
    func testOcrTextCleaning() {
        XCTAssertEqual(GeminiSupport.cleanOCRText("```\n1. A\n```"), "1. A")
        XCTAssertEqual(GeminiSupport.cleanOCRText("[yazı yok]"), "")
        XCTAssertEqual(GeminiSupport.cleanOCRText(" [YAZI YOK] "), "")
        XCTAssertEqual(GeminiSupport.cleanOCRText("5. Hangisi?\nA) ADANA"), "5. Hangisi?\nA) ADANA")
    }

    func testOcrPromptKeepsQuestionNumbersAndOptions() {
        let p = GeminiConfig.ocrPrompt
        for word in ["Soru numaralarını", "şık harflerini", "Tabloları", "tahmin etme", "[okunamadı]", "[yazı yok]"] {
            XCTAssertTrue(p.contains(word), word)
        }
    }

    func testClientTagIsShortAndComparable() {
        XCTAssertEqual(DriveClient.clientTag("123456789012-abcdefghijklmnop.apps.googleusercontent.com"), "123456...klmnop")
        XCTAssertEqual(DriveClient.clientTag("CID-123"), "CID-123")
        XCTAssertEqual(DriveClient.clientTag("  "), "(girilmemiş)")
    }

    func testDriveListSizeFollowsTheDocumentCountSetting() {
        XCTAssertEqual(DriveClient.listPageSize(3), 3)
        XCTAssertEqual(DriveClient.listPageSize(30), 30, "belge sayısı 30 olabilir; 10'da kesilmemeli")
        XCTAssertEqual(DriveClient.listPageSize(0), 1)
        XCTAssertEqual(DriveClient.listPageSize(500), 50)
    }

    func testPromptSpeaksOptionCodesInsteadOfLetters() {
        let prompt = GeminiConfig.systemPrompt
        XCTAssertTrue(prompt.contains("A = ADANA"))
        XCTAssertTrue(prompt.contains("D = DENİZLİ"))
        XCTAssertTrue(prompt.contains("Şık harfini (A, B, C…) SÖYLEME"))
        XCTAssertTrue(prompt.contains("Birinci sorunun cevabı DENİZLİ, altmış sekiz."))
        XCTAssertFalse(prompt.contains("@@"))
    }

    func testPromptWithoutCodesSpeaksTheLetterAndItsValue() {
        let prompt = GeminiSupport.systemPrompt(codesText: "")
        XCTAssertTrue(prompt.contains("ASLA tek başına"))
        XCTAssertTrue(prompt.contains("Birinci sorunun cevabı D, altmış sekiz."))
        XCTAssertFalse(prompt.contains("SÖYLEME"))
    }

    func testCustomCodesReplaceTheDefaults() {
        let prompt = GeminiSupport.systemPrompt(codesText: "A=ANKARA, B=BOLU")
        XCTAssertTrue(prompt.contains("A = ANKARA"))
        XCTAssertFalse(prompt.contains("ADANA"))
        XCTAssertEqual(GeminiSupport.parseOptionCodes("A=ANKARA, b=bolu; C-CEYHAN").map { $0.letter }, ["A", "B", "C"])
    }

    func testPromptHasBatchAndSpecificQuestionRules() {
        let prompt = GeminiConfig.systemPrompt
        XCTAssertTrue(prompt.contains("12. Kullanıcı soruları toplu cevaplatmak isterse"))
        XCTAssertTrue(prompt.contains("N+1"))
        XCTAssertTrue(prompt.contains("'son_soru' alanına"))
        XCTAssertTrue(prompt.contains("13. Kullanıcı belirli soruların cevabını isterse"))
        XCTAssertTrue(prompt.contains("AYNEN yeniden oku"))
        XCTAssertTrue(prompt.contains("'son_soru' alanına 0 yaz"))
    }

    func testBatchNoteIsAddedOnlyWhenThereIsAPersistedPosition() throws {
        let with = GeminiSupport.requestObject(questionText: "sıradaki on soru", audioWAV: nil, docs: [], history: [], batchLast: 20)
        let withParts = try XCTUnwrap(((with["contents"] as? [[String: Any]])?.last?["parts"]) as? [[String: Any]])
        XCTAssertTrue(withParts.contains { ($0["text"] as? String)?.contains("en son verilen soru numarası: 20.") == true })
        let without = GeminiSupport.requestObject(questionText: "x", audioWAV: nil, docs: [], history: [], batchLast: 0)
        let plain = try XCTUnwrap(((without["contents"] as? [[String: Any]])?.last?["parts"]) as? [[String: Any]])
        XCTAssertFalse(plain.contains { ($0["text"] as? String)?.contains("Uygulama notu") == true })
    }

    func testUnheardBatchInHistoryAddsTheNoGroupReachedNote() throws {
        let history = [GeminiTurn(question: "ilk on", answer: "Birinci sorunun cevabı BURSA, yetmiş.", batch: 10)]
        let object = GeminiSupport.requestObject(questionText: "sıradaki on soru", audioWAV: nil, docs: [], history: history, batchLast: 0)
        let contents = try XCTUnwrap(object["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents.last?["parts"] as? [[String: Any]])
        XCTAssertTrue(parts.contains { ($0["text"] as? String)?.contains("ulaşan grup yok") == true })
        // geçmişteki model cevabı bütün şema alanlarını (son_soru dahil) taşır
        let modelText = try XCTUnwrap(((contents[1]["parts"] as? [[String: Any]])?.first?["text"]) as? String)
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(modelText.utf8)) as? [String: Any])
        XCTAssertEqual(decoded["son_soru"] as? Int, 10)
        XCTAssertEqual(decoded["kapat"] as? Bool, false)
        XCTAssertEqual(decoded["model_degistir"] as? Bool, false)
        // toplu cevap yoksa not eklenmez
        let plain = GeminiSupport.requestObject(questionText: "x", audioWAV: nil, docs: [],
                                                history: [GeminiTurn(question: "a", answer: "b")], batchLast: 0)
        let plainParts = try XCTUnwrap(((plain["contents"] as? [[String: Any]])?.last?["parts"]) as? [[String: Any]])
        XCTAssertFalse(plainParts.contains { ($0["text"] as? String)?.contains("Uygulama notu") == true })
    }

    func testSchemaRequiresEveryFieldSoTheModelCannotSkipTheBatchNumber() {
        let required = (GeminiConfig.responseSchema["required"] as? [String]) ?? []
        XCTAssertEqual(Set(required), ["soru", "cevap", "kapat", "model_degistir", "son_soru"])
        XCTAssertTrue(GeminiConfig.systemPrompt.contains("N sıfırsa"))
    }

    func testLastQuestionAcceptsANumberWrittenAsText() throws {
        let inner = "{\"soru\":\"ilk on\",\"cevap\":\"x\",\"son_soru\":\"10\"}"
        let object: [String: Any] = ["candidates": [["finishReason": "STOP", "content": ["parts": [["text": inner]]]]]]
        XCTAssertEqual(try GeminiSupport.parseAnswer(object).lastQuestion, 10)
    }

    func testSpelledOutQuestionNumbersAreNotRepeatRequests() {
        for text in ["üçüncü soruyu tekrar anlat", "sekizinci soruyu bir daha oku", "beşinci soruyu yeniden oku", "iki soruyu tekrar oku"] {
            XCTAssertFalse(GeminiSupport.isRepeatRequest(text), text)
        }
        XCTAssertTrue(GeminiSupport.isRepeatRequest("sonuncu yanıtı tekrar et"))
        XCTAssertTrue(GeminiSupport.isRepeatRequest("son yanıtı tekrarla"))
    }

    func testLastQuestionIsParsedFromTheAnswer() throws {
        let inner = "{\"soru\":\"ilk on\",\"cevap\":\"x\",\"son_soru\":10}"
        let object: [String: Any] = ["candidates": [["finishReason": "STOP", "content": ["parts": [["text": inner]]]]]]
        XCTAssertEqual(try GeminiSupport.parseAnswer(object).lastQuestion, 10)
        let none: [String: Any] = ["candidates": [["finishReason": "STOP", "content": ["parts": [["text": "{\"soru\":\"a\",\"cevap\":\"x\"}"]]]]]]
        XCTAssertEqual(try GeminiSupport.parseAnswer(none).lastQuestion, 0)
    }

    func testRepeatRequestsAreRecognised() {
        for phrase in ["son yanıtı tekrarla", "Son cevabı tekrar et", "bir daha söyle", "yeniden oku", "tekrar", "baştan oku",
                       "tekrarlar mısın", "Tekrar eder misin", "cevabı tekrar dinleyebilir miyim", "SON YANITI TEKRARLA"] {
            XCTAssertTrue(GeminiSupport.isRepeatRequest(phrase), phrase)
        }
    }

    func testNewQuestionsAreNotMistakenForRepeats() {
        for phrase in ["ilk on soruyu cevapla", "ilk on soruyu tekrar cevapla", "sıradaki on soruyu cevapla", "on birden yirmiye kadar",
                       "toplam tutar nedir", "yeniden başla", "devam", "üçüncü sekizinci ve on beşinci soruların cevaplarını ver",
                       "3 ve 8. soruyu tekrar anlat", ""] {
            XCTAssertFalse(GeminiSupport.isRepeatRequest(phrase), phrase)
        }
    }

    func testFoldingTurkishLetters() {
        XCTAssertEqual(GeminiSupport.foldTR("ÇAĞRI İŞÇİ Öğüt Iğdır"), "cagri isci ogut igdir")
    }
}

final class GeminiProfilesTests: XCTestCase {
    private func info(_ slot: Int, _ name: String, key: String = "k", model: String = "m", free: Bool = false) -> GeminiProfileInfo {
        return GeminiProfileInfo(slot: slot, name: name, model: model, key: key, free: free)
    }

    func testUsableNeedsKeyAndModel() {
        let list = [info(1, "Flash"), info(2, "Pro", key: ""), info(3, "Ücretsiz", model: "")]
        XCTAssertEqual(GeminiProfiles.usable(list).map { $0.slot }, [1])
    }

    func testActiveFallsBackToTheFirstUsableProfile() {
        let list = [info(1, "Flash"), info(2, "Pro", key: ""), info(3, "Ücretsiz", free: true)]
        XCTAssertEqual(GeminiProfiles.active(list, active: 3).slot, 3)
        XCTAssertEqual(GeminiProfiles.active(list, active: 2).slot, 1, "seçili profil boşsa ilk dolu profil")
    }

    func testFallbackTargetIsTheFirstUsableFreeProfileAndOnlyFromPaid() {
        let list = [info(1, "Flash"), info(2, "Pro"), info(3, "Ücretsiz", free: true)]
        XCTAssertEqual(GeminiProfiles.fallbackTarget(list, from: list[1], auto: true)?.slot, 3)
        XCTAssertNil(GeminiProfiles.fallbackTarget(list, from: list[1], auto: false))
        XCTAssertNil(GeminiProfiles.fallbackTarget(list, from: list[2], auto: true), "ücretsizden yine ücretsize geçilmez")
        let noKey = [info(1, "Flash"), info(3, "Ücretsiz", key: "", free: true)]
        XCTAssertNil(GeminiProfiles.fallbackTarget(noKey, from: noKey[0], auto: true))
    }

    func testKeychainNamesKeepTheOldFirstName() {
        XCTAssertEqual(GeminiProfiles.keychainName(slot: 1), "geminiApiKey")
        XCTAssertEqual(GeminiProfiles.keychainName(slot: 2), "geminiApiKey2")
        XCTAssertEqual(GeminiProfiles.keychainName(slot: 3), "geminiApiKey3")
    }

    func testMonthKey() {
        var c = DateComponents()
        c.year = 2026; c.month = 11; c.day = 10; c.hour = 12
        let date = Calendar(identifier: .gregorian).date(from: c) ?? Date()
        XCTAssertEqual(GeminiProfiles.monthKey(date), "202611")
    }
}

// MARK: - Ağ istemcisi (sahte URLProtocol)

final class FakeGeminiProtocol: URLProtocol {
    struct Reply {
        var status: Int = 200
        var body: Data = Data()
        var error: Error?
        var headers: [String: String] = [:]
    }

    static let lock = NSLock()
    static var replies: [Reply] = []
    static var urls: [URL] = []
    static var headers: [[String: String]] = []
    static var bodies: [Data] = []
    static var methods: [String] = []

    static func reset() {
        lock.lock()
        replies = []
        urls = []
        headers = []
        bodies = []
        methods = []
        lock.unlock()
    }

    static func read(_ stream: InputStream) -> Data {
        var data = Data()
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { return true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { return request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream { body = FakeGeminiProtocol.read(stream) }
        let url = request.url!
        FakeGeminiProtocol.lock.lock()
        FakeGeminiProtocol.urls.append(url)
        FakeGeminiProtocol.headers.append(request.allHTTPHeaderFields ?? [:])
        FakeGeminiProtocol.bodies.append(body)
        FakeGeminiProtocol.methods.append(request.httpMethod ?? "")
        let reply = FakeGeminiProtocol.replies.isEmpty ? Reply(status: 500, body: Data(), error: nil)
                                                       : FakeGeminiProtocol.replies.removeFirst()
        FakeGeminiProtocol.lock.unlock()
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        var fields = ["Content-Type": "application/json"]
        for (k, v) in reply.headers { fields[k] = v }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: fields)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class SleepLog {
    var values: [TimeInterval] = []
}

final class GeminiClientTests: XCTestCase {
    private let pdf = Data("%PDF-1.4 deneme".utf8)
    private var sleeps = SleepLog()

    override func setUp() {
        super.setUp()
        FakeGeminiProtocol.reset()
        sleeps = SleepLog()
    }

    private func makeClient(key: String = " AIza-TEST \n", model: String = "", batch: Int = 0) -> GeminiClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeGeminiProtocol.self]
        let log = sleeps
        return GeminiClient(session: URLSession(configuration: config),
                            baseURL: "https://example.test/v1beta",
                            key: { key }, model: { model }, batchLast: { batch },
                            sleep: { seconds in log.values.append(seconds) })
    }

    private func okBody(answer: String = "Toplam yüz lira.", question: String = "toplam nedir") -> Data {
        let inner = (try? JSONSerialization.data(withJSONObject: ["soru": question, "cevap": answer])) ?? Data()
        let object: [String: Any] = [
            "candidates": [["finishReason": "STOP", "content": ["parts": [["text": String(decoding: inner, as: UTF8.self)]]]]],
            "usageMetadata": ["promptTokenCount": 1000, "candidatesTokenCount": 40, "totalTokenCount": 1040]
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private func headerValue(_ name: String, _ index: Int = 0) -> String? {
        let dict = FakeGeminiProtocol.headers[index]
        return dict.first(where: { $0.key.lowercased() == name.lowercased() })?.value
    }

    private func errorBody(_ message: String, reason: String = "") -> Data {
        var err: [String: Any] = ["message": message]
        if !reason.isEmpty { err["details"] = [["reason": reason]] }
        return (try? JSONSerialization.data(withJSONObject: ["error": err])) ?? Data()
    }

    private func queue(_ replies: FakeGeminiProtocol.Reply...) {
        FakeGeminiProtocol.lock.lock()
        FakeGeminiProtocol.replies = replies
        FakeGeminiProtocol.lock.unlock()
    }

    private func failure(_ body: () async throws -> Void) async -> GeminiError? {
        do {
            try await body()
            return nil
        } catch let e as GeminiError {
            return e
        } catch {
            return GeminiError("başka hata: \(error)")
        }
    }

    func testSuccessfulQuestion() async throws {
        queue(.init(status: 200, body: okBody(), error: nil))
        let client = makeClient()
        let answer = try await client.ask(questionText: "toplam tutar nedir", audioWAV: nil,
                                          docs: [GeminiDoc(name: "a.pdf", data: pdf)], history: [])
        XCTAssertEqual(answer.answer, "Toplam yüz lira.")
        XCTAssertEqual(answer.question, "toplam nedir")
        XCTAssertEqual(answer.totalTokens, 1040)
        XCTAssertEqual(FakeGeminiProtocol.urls.count, 1)
        XCTAssertEqual(FakeGeminiProtocol.urls[0].absoluteString, "https://example.test/v1beta/models/gemini-3.8-flash:generateContent")
        XCTAssertEqual(headerValue("x-goog-api-key"), "AIza-TEST")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: FakeGeminiProtocol.bodies[0]) as? [String: Any])
        let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
        let first = try XCTUnwrap(contents[0]["parts"] as? [[String: Any]])
        let inline = try XCTUnwrap(first[1]["inlineData"] as? [String: String])
        XCTAssertEqual(inline["data"], pdf.base64EncodedString())
    }

    private func jsonBody(_ index: Int) throws -> [String: Any] {
        return try XCTUnwrap(JSONSerialization.jsonObject(with: FakeGeminiProtocol.bodies[index]) as? [String: Any])
    }

    private func remoteDoc(_ name: String) -> GeminiDoc {
        var doc = GeminiDoc(name: name, data: pdf)
        doc.uri = "https://example.test/v1beta/files/\(name)"
        doc.remote = "files/\(name)"
        return doc
    }

    func testFileUploadUsesTheResumableProtocol() async throws {
        let startReply = FakeGeminiProtocol.Reply(status: 200, body: Data("{}".utf8), error: nil,
                                                  headers: ["x-goog-upload-url": "https://example.test/upload/session-1"])
        let doneBody = Data("{\"file\":{\"name\":\"files/abc\",\"uri\":\"https://example.test/v1beta/files/abc\",\"state\":\"ACTIVE\"}}".utf8)
        queue(startReply, .init(status: 200, body: doneBody, error: nil))
        let file = try await makeClient().uploadFile(name: "Belge.pdf", data: pdf)
        XCTAssertEqual(file, RemoteFile(name: "files/abc", uri: "https://example.test/v1beta/files/abc", state: "ACTIVE"))
        XCTAssertEqual(FakeGeminiProtocol.urls.map { $0.absoluteString },
                       ["https://example.test/upload/v1beta/files", "https://example.test/upload/session-1"])
        XCTAssertEqual(headerValue("X-Goog-Upload-Protocol", 0), "resumable")
        XCTAssertEqual(headerValue("X-Goog-Upload-Command", 0), "start")
        XCTAssertEqual(headerValue("X-Goog-Upload-Header-Content-Length", 0), String(pdf.count))
        XCTAssertEqual(headerValue("X-Goog-Upload-Command", 1), "upload, finalize")
        XCTAssertEqual(headerValue("X-Goog-Upload-Offset", 1), "0")
        XCTAssertEqual(FakeGeminiProtocol.bodies[1], pdf)
    }

    func testFileUploadWithoutUploadUrlFails() async {
        queue(.init(status: 200, body: Data("{}".utf8), error: nil))
        let e = await failure { _ = try await makeClient().uploadFile(name: "a.pdf", data: pdf) }
        XCTAssertNotNil(e)
    }

    func testMissingFileGivesNilInsteadOfAnError() async throws {
        queue(.init(status: 404, body: errorBody("File not found"), error: nil))
        let file = try await makeClient().getFile(name: "files/yok")
        XCTAssertNil(file)
    }

    func testCacheIsCreatedWithTheSystemPromptAndFileUris() async throws {
        queue(.init(status: 200, body: Data("{\"name\":\"cachedContents/c1\"}".utf8), error: nil))
        let name = try await makeClient().createCache(docs: [remoteDoc("a.pdf"), remoteDoc("b.pdf")])
        XCTAssertEqual(name, "cachedContents/c1")
        XCTAssertEqual(FakeGeminiProtocol.urls[0].absoluteString, "https://example.test/v1beta/cachedContents")
        let body = try jsonBody(0)
        XCTAssertEqual(body["model"] as? String, "models/gemini-3.8-flash")
        XCTAssertEqual(body["ttl"] as? String, "1800s")
        XCTAssertNotNil(body["systemInstruction"])
        let text = String(decoding: FakeGeminiProtocol.bodies[0], as: UTF8.self)
        XCTAssertTrue(text.contains("files/a.pdf") && text.contains("files/b.pdf"))
        XCTAssertFalse(text.contains("inlineData"), "önbelleğe PDF baytı değil dosya adresi konur")
    }

    func testCacheLifeIsExtendedAndDeleted() async throws {
        queue(.init(status: 200, body: Data("{}".utf8), error: nil), .init(status: 200, body: Data("{}".utf8), error: nil))
        let client = makeClient()
        try await client.touchCache("cachedContents/c1")
        await client.deleteCache("cachedContents/c1")
        XCTAssertEqual(FakeGeminiProtocol.methods, ["PATCH", "DELETE"])
        XCTAssertEqual(FakeGeminiProtocol.urls[0].absoluteString, "https://example.test/v1beta/cachedContents/c1?updateMask=ttl")
        XCTAssertEqual(FakeGeminiProtocol.urls[1].absoluteString, "https://example.test/v1beta/cachedContents/c1")
    }

    func testQuestionWithCachedContentCarriesNoSystemInstructionOrDocuments() async throws {
        queue(.init(status: 200, body: okBody(), error: nil))
        let answer = try await makeClient().ask(questionText: "toplam nedir", audioWAV: nil, docs: [remoteDoc("a.pdf")],
                                                history: [], cached: "cachedContents/c1")
        XCTAssertEqual(answer.answer, "Toplam yüz lira.")
        let body = try jsonBody(0)
        XCTAssertEqual(body["cachedContent"] as? String, "cachedContents/c1")
        XCTAssertNil(body["systemInstruction"], "önbellekli istekte sistem yönergesi gönderilemez")
        XCTAssertFalse(String(decoding: FakeGeminiProtocol.bodies[0], as: UTF8.self).contains("files/a.pdf"))
    }

    func testQuestionWithFileUrisButNoCacheReferencesTheFiles() async throws {
        queue(.init(status: 200, body: okBody(), error: nil))
        _ = try await makeClient().ask(questionText: "x", audioWAV: nil, docs: [remoteDoc("a.pdf")], history: [])
        let body = try jsonBody(0)
        XCTAssertNotNil(body["systemInstruction"])
        let text = String(decoding: FakeGeminiProtocol.bodies[0], as: UTF8.self)
        XCTAssertTrue(text.contains("fileData") && text.contains("files/a.pdf"))
        XCTAssertFalse(text.contains("inlineData"))
    }

    func testPersistedBatchPositionIsSentAsAnAppNote() async throws {
        queue(.init(status: 200, body: okBody(), error: nil))
        _ = try await makeClient(batch: 30).ask(questionText: "sıradaki on soruyu cevapla", audioWAV: nil, docs: [], history: [])
        XCTAssertTrue(String(decoding: FakeGeminiProtocol.bodies[0], as: UTF8.self).contains("en son verilen soru numarası: 30."))
    }

    func testTranscribeSendsOnlyTheAudioAndReturnsTheText() async throws {
        let inner = "{\"soru\":\"son cevabı tekrar et\"}"
        let object: [String: Any] = ["candidates": [["finishReason": "STOP", "content": ["parts": [["text": inner]]]]]]
        queue(.init(status: 200, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), error: nil))
        let text = try await makeClient().transcribe(audioWAV: Data("RIFFxxxx".utf8))
        XCTAssertEqual(text, "son cevabı tekrar et")
        let sent = String(decoding: FakeGeminiProtocol.bodies[0], as: UTF8.self)
        XCTAssertTrue(sent.contains("Bu sesi yazıya dök."))
        XCTAssertTrue(sent.contains("audio/wav"))
        XCTAssertFalse(sent.contains("application/pdf"), "yazıya dökmede belge gönderilmez")
        XCTAssertTrue(sent.contains("\"maxOutputTokens\":256"))
    }

    func testChosenModelIsUsed() async throws {
        queue(.init(status: 200, body: okBody(), error: nil))
        _ = try await makeClient(model: "gemini-test-model").ask(questionText: "x", audioWAV: nil, docs: [], history: [])
        XCTAssertTrue(FakeGeminiProtocol.urls[0].absoluteString.hasSuffix("/models/gemini-test-model:generateContent"))
    }

    func testOcrImageReturnsPlainTextAndSendsThePicture() async throws {
        let object: [String: Any] = ["candidates": [["finishReason": "STOP",
                                                      "content": ["parts": [["text": "5. Soru\nA) ADANA\nB) ANKARA"]]]]]]
        queue(.init(status: 200, body: try JSONSerialization.data(withJSONObject: object), error: nil))
        let text = try await makeClient().ocrImage(Data([0xFF, 0xD8, 0xFF, 0xE0]))
        XCTAssertEqual(text, "5. Soru\nA) ADANA\nB) ANKARA")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: FakeGeminiProtocol.bodies[0]) as? [String: Any])
        let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents[0]["parts"] as? [[String: Any]])
        let inline = try XCTUnwrap(parts[0]["inlineData"] as? [String: String])
        XCTAssertEqual(inline["mimeType"], "image/jpeg")
        XCTAssertEqual(inline["data"], Data([0xFF, 0xD8, 0xFF, 0xE0]).base64EncodedString())
        XCTAssertEqual(parts[1]["text"] as? String, GeminiConfig.ocrPrompt)
        let config = try XCTUnwrap(body["generationConfig"] as? [String: Any])
        XCTAssertEqual(config["temperature"] as? Double, 0.0)
        XCTAssertNil(config["responseMimeType"], "OCR düz metin ister, JSON değil")
    }

    func testMissingKeyIsRejectedWithoutRequest() async {
        let error = await failure { _ = try await self.makeClient(key: "  ").ask(questionText: "x", audioWAV: nil, docs: [], history: []) }
        XCTAssertEqual(error?.kind, .key)
        XCTAssertTrue(FakeGeminiProtocol.urls.isEmpty)
    }

    func testEmptyQuestionIsRejected() async {
        let error = await failure { _ = try await self.makeClient().ask(questionText: " ", audioWAV: nil, docs: [], history: []) }
        XCTAssertNotNil(error)
        XCTAssertTrue(FakeGeminiProtocol.urls.isEmpty)
    }

    func testInvalidKeyResponse() async {
        queue(.init(status: 400, body: errorBody("API key not valid. Please pass a valid API key.", reason: "API_KEY_INVALID"), error: nil))
        let error = await failure { _ = try await self.makeClient().ask(questionText: "x", audioWAV: nil, docs: [], history: []) }
        XCTAssertEqual(error?.kind, .key)
        XCTAssertEqual(error?.status, 400)
    }

    func testServerErrorIsRetriedOnce() async throws {
        queue(.init(status: 503, body: errorBody("overloaded"), error: nil),
              .init(status: 200, body: okBody(), error: nil))
        let answer = try await makeClient().ask(questionText: "tekrar", audioWAV: nil, docs: [], history: [])
        XCTAssertFalse(answer.answer.isEmpty)
        XCTAssertEqual(sleeps.values, [1.5])
        XCTAssertEqual(FakeGeminiProtocol.urls.count, 2)
    }

    func testTwoServerErrorsAreStillRetriedWithGrowingWait() async throws {
        queue(.init(status: 503, body: errorBody("x"), error: nil), .init(status: 503, body: errorBody("x"), error: nil),
              .init(status: 200, body: okBody(), error: nil))
        let answer = try await makeClient().ask(questionText: "x", audioWAV: nil, docs: [], history: [])
        XCTAssertFalse(answer.answer.isEmpty)
        XCTAssertEqual(sleeps.values, [1.5, 4.0])
    }

    func testPersistentServerErrorFailsAfterThreeRetries() async {
        let bad = FakeGeminiProtocol.Reply(status: 503, body: errorBody("x"), error: nil)
        queue(bad, bad, bad, bad)
        let error = await failure { _ = try await self.makeClient().ask(questionText: "x", audioWAV: nil, docs: [], history: []) }
        XCTAssertEqual(error?.kind, .http)
        XCTAssertEqual(error?.status, 503)
        XCTAssertEqual(sleeps.values, [1.5, 4.0, 8.0])
        XCTAssertEqual(FakeGeminiProtocol.urls.count, 4)
    }

    func testBackupModelRequestUsesItsOwnUrlAndIsNotRetried() async {
        let bad = FakeGeminiProtocol.Reply(status: 503, body: errorBody("This model is currently experiencing high demand."), error: nil)
        queue(bad, bad)
        let error = await failure {
            _ = try await self.makeClient(model: "gemini-3.8-flash").ask(questionText: "x", audioWAV: nil, docs: [], history: [],
                                                                         cached: "", model: "gemini-3.7-flash", serverRetries: 0)
        }
        XCTAssertEqual(error?.status, 503)
        XCTAssertEqual(FakeGeminiProtocol.urls.count, 1)
        XCTAssertTrue(FakeGeminiProtocol.urls[0].absoluteString.contains("/models/gemini-3.7-flash:generateContent"),
                      FakeGeminiProtocol.urls[0].absoluteString)
        XCTAssertTrue(sleeps.values.isEmpty, "\(sleeps.values)")
    }

    func testFallbackModelsComeFromTheAccountsOwnModelList() async throws {
        func entry(_ name: String) -> [String: Any] { return ["name": "models/" + name, "supportedGenerationMethods": ["generateContent"]] }
        let list: [String: Any] = ["models": [entry("gemini-3.8-flash"), entry("gemini-3.7-flash"), entry("gemini-3.8-flash-lite"),
                                              entry("gemini-3.8-flash-image"), entry("gemini-3.8-pro")]]
        queue(.init(status: 200, body: try JSONSerialization.data(withJSONObject: list), error: nil))
        let names = await makeClient(model: "gemini-3.8-flash").fallbackModels()
        XCTAssertEqual(names, ["gemini-3.7-flash", "gemini-3.8-flash-lite"])

        FakeGeminiProtocol.reset()
        queue(.init(status: 500, body: Data(), error: nil))
        let none = await makeClient(model: "gemini-3.8-flash").fallbackModels()
        XCTAssertEqual(none, [])
    }

    func testQuotaErrorMentionsWait() async {
        queue(.init(status: 429, body: errorBody("Quota exceeded, retry in 5s"), error: nil))
        let error = await failure { _ = try await self.makeClient().ask(questionText: "x", audioWAV: nil, docs: [], history: []) }
        XCTAssertEqual(error?.kind, .quota)
        XCTAssertTrue(error?.message.contains("6 saniye") ?? false, error?.message ?? "")
        XCTAssertEqual(FakeGeminiProtocol.urls.count, 1)
    }

    func testUnknownModel() async {
        queue(.init(status: 404, body: errorBody("not found"), error: nil))
        let error = await failure { _ = try await self.makeClient(model: "yok-model").ask(questionText: "x", audioWAV: nil, docs: [], history: []) }
        XCTAssertEqual(error?.kind, .model)
        XCTAssertTrue(error?.message.contains("yok-model") ?? false)
    }

    func testNetworkErrorIsRetriedThenReported() async throws {
        queue(.init(status: 0, body: Data(), error: URLError(.notConnectedToInternet)),
              .init(status: 200, body: okBody(), error: nil))
        let answer = try await makeClient().ask(questionText: "x", audioWAV: nil, docs: [], history: [])
        XCTAssertFalse(answer.answer.isEmpty)
        XCTAssertEqual(sleeps.values, [1.5])

        FakeGeminiProtocol.reset()
        queue(.init(status: 0, body: Data(), error: URLError(.notConnectedToInternet)),
              .init(status: 0, body: Data(), error: URLError(.notConnectedToInternet)))
        let error = await failure { _ = try await self.makeClient().ask(questionText: "x", audioWAV: nil, docs: [], history: []) }
        XCTAssertEqual(error?.kind, .network)
    }

    func testBlockedAnswerFromServer() async {
        let body = (try? JSONSerialization.data(withJSONObject: ["promptFeedback": ["blockReason": "SAFETY"]])) ?? Data()
        queue(.init(status: 200, body: body, error: nil))
        let error = await failure { _ = try await self.makeClient().ask(questionText: "x", audioWAV: nil, docs: [], history: []) }
        XCTAssertEqual(error?.kind, .blocked)
    }
}
