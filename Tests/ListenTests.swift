import XCTest
@testable import G526CameraDrive

/// "Dinle … tamam" serbest konuşma: bitirme sözcüğü, çağrı sözcüğü varsayılanı, ayarlar, düşünme modu, sesli görev isteği
final class ListenTests: XCTestCase {
    private let endWords = GeminiText.endWords

    func testTamamAsLastWordEndsTheRecording() {
        XCTAssertTrue(SpeechMatcher.endsWith("bugün hava nasıl tamam", words: endWords))
        XCTAssertTrue(SpeechMatcher.endsWith("Tamam.", words: endWords))
        XCTAssertTrue(SpeechMatcher.endsWith("on ikinci soruyu tekrar oku, Tamam", words: endWords))
        XCTAssertTrue(SpeechMatcher.endsWith("kaç soru var tamamdır", words: endWords))
    }

    func testTamamInTheMiddleOrSimilarWordsDoNotEnd() {
        XCTAssertFalse(SpeechMatcher.endsWith("tamam şimdi kaç soru var", words: endWords))
        XCTAssertFalse(SpeechMatcher.endsWith("sorunun tamamı", words: endWords))
        XCTAssertFalse(SpeechMatcher.endsWith("tamamen yanlış", words: endWords))
        XCTAssertFalse(SpeechMatcher.endsWith("", words: endWords))
        XCTAssertFalse(SpeechMatcher.endsWith("   ", words: endWords))
    }

    func testDinleIsADefaultCallWord() {
        let phrases = GeminiText.callPhrases("")
        XCTAssertTrue(phrases.hasPrefix("dinle, gemini"), phrases)
        XCTAssertGreaterThan(SpeechMatcher.occurrences(in: "dinle", trigger: phrases), 0)
        XCTAssertGreaterThan(SpeechMatcher.occurrences(in: "Dinle", trigger: phrases), 0)
        XCTAssertGreaterThan(SpeechMatcher.occurrences(in: "gemini", trigger: phrases), 0)
        XCTAssertEqual(GeminiText.defaultCallSetting, "dinle, gemini")
    }

    func testOwnCallWordDoesNotGetDinleAdded() {
        XCTAssertEqual(GeminiText.callWordList("dostum"), ["dostum"])
    }

    func testDinleWordIsStrippedFromTheQuestion() {
        let words = GeminiText.triggerList(for: GeminiText.defaultCallSetting)
        XCTAssertEqual(GeminiText.stripTrigger("Dinle, kaç soru var", words: words), "kaç soru var")
        XCTAssertEqual(GeminiText.stripTrigger("dinleme sorusu", words: words), "dinleme sorusu")
    }

    func testSavedCallWordMigration() {
        XCTAssertEqual(AppSettings.migratedCallWord(nil), "dinle, gemini")
        XCTAssertEqual(AppSettings.migratedCallWord("gemini"), "dinle, gemini", "eski varsayılan yükselir")
        XCTAssertEqual(AppSettings.migratedCallWord("  Gemini "), "dinle, gemini")
        XCTAssertEqual(AppSettings.migratedCallWord("dostum"), "dostum", "kullanıcının kendi sözcüğü korunur")
        XCTAssertEqual(AppSettings.migratedCallWord("dostum, gemini"), "dostum, gemini")
        XCTAssertEqual(AppSettings.migratedCallWord(""), "", "boş bırakılan ayar boş kalır (varsayılan sözcükler geçerli)")
    }

    func testThinkingSettingValidation() {
        XCTAssertEqual(AppSettings.validThinking(nil), "auto")
        XCTAssertEqual(AppSettings.validThinking("xx"), "auto")
        XCTAssertEqual(AppSettings.validThinking("high"), "high")
        XCTAssertEqual(AppSettings.validThinking("minimal"), "minimal")
    }

    func testThinkingLevelPerModel() {
        XCTAssertEqual(GeminiSupport.thinkingLevel(model: "gemma-4-31b-it", setting: "auto"), "high")
        XCTAssertEqual(GeminiSupport.thinkingLevel(model: "models/gemma-4-26b-a4b-it", setting: "auto"), "high")
        XCTAssertNil(GeminiSupport.thinkingLevel(model: "gemini-3.8-flash", setting: "auto"))
        XCTAssertEqual(GeminiSupport.thinkingLevel(model: "gemini-3.8-flash", setting: "high"), "high")
        XCTAssertEqual(GeminiSupport.thinkingLevel(model: "gemma-4-31b-it", setting: "minimal"), "minimal")
        XCTAssertNil(GeminiSupport.thinkingLevel(model: "gemini-2.5-flash", setting: "high"), "Gemini 2.x thinkingLevel almaz")
    }

    func testThinkingConfigIsPutIntoTheRequest() throws {
        let plain = GeminiSupport.requestObject(questionText: "x", audioWAV: nil, docs: [], history: [])
        let withThinking = GeminiSupport.applyThinking(plain, level: "high")
        let config = withThinking["generationConfig"] as? [String: Any]
        XCTAssertEqual((config?["thinkingConfig"] as? [String: String])?["thinkingLevel"], "high")
        XCTAssertEqual(config?["temperature"] as? Double, 0.3, "öteki ayarlar kalır")
        let untouched = GeminiSupport.applyThinking(plain, level: nil)
        XCTAssertNil((untouched["generationConfig"] as? [String: Any])?["thinkingConfig"])

        let data = try GeminiSupport.buildRequest(questionText: "x", audioWAV: nil, docs: [], history: [], thinking: "high")
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let cfg = obj?["generationConfig"] as? [String: Any]
        XCTAssertEqual((cfg?["thinkingConfig"] as? [String: String])?["thinkingLevel"], "high")
    }

    func testAudioInstructionTellsGeminiToIgnoreTrailingTamam() {
        XCTAssertTrue(GeminiConfig.audioInstruction.contains("'tamam'"))
        XCTAssertTrue(GeminiConfig.audioInstruction.contains("çağrı sözcüğü"))
    }

    func testExamTaskCarriesAudioBeforeThePrompt() {
        let wav = GeminiSupport.wav(fromPCM16: Data(count: 3200))
        let task = ExamTask(prompt: ExamPrompts.freePrompt(record: ""), schema: ExamPrompts.freeSchema, maxTokens: 2048, audio: wav)
        let obj = GeminiSupport.taskRequestObject(task, docs: [])
        let contents = obj["contents"] as? [[String: Any]]
        let parts = contents?.last?["parts"] as? [[String: Any]]
        XCTAssertEqual(parts?.count, 2)
        let inline = parts?.first?["inlineData"] as? [String: Any]
        XCTAssertEqual(inline?["mimeType"] as? String, "audio/wav")
        XCTAssertEqual(inline?["data"] as? String, wav.base64EncodedString())
        XCTAssertEqual(parts?.last?["text"] as? String, task.prompt)
    }

    func testExamTaskWithoutAudioIsUnchanged() {
        let task = ExamTask(prompt: "p", schema: ExamPrompts.freeSchema)
        let obj = GeminiSupport.taskRequestObject(task, docs: [])
        let parts = (obj["contents"] as? [[String: Any]])?.last?["parts"] as? [[String: Any]]
        XCTAssertEqual(parts?.count, 1)
        XCTAssertEqual(parts?.first?["text"] as? String, "p")
    }

    func testFreePromptMentionsRecordAndTamam() {
        let text = ExamPrompts.freePrompt(record: "Soru 1: B. Soru 2: C.")
        XCTAssertTrue(text.contains("Soru 1: B. Soru 2: C."))
        XCTAssertTrue(text.contains("'tamam'"))
        for word in ["tekrar", "hepsi", "devam", "bitir", "cevap", "anlasilmadi"] {
            XCTAssertTrue(text.contains(word), word)
        }
        XCTAssertTrue(ExamPrompts.freePrompt(record: "").contains("(henüz yok)"))
    }
}

final class FreeProfileDefaultTests: XCTestCase {
    func testOnlyTheLastProfileIsPaidByDefault() {
        let list = GeminiProfiles.defaults()
        XCTAssertEqual(list.count, GeminiProfiles.slotCount)
        XCTAssertEqual(list.map { $0.free }, [true, true, true, true, true, false])
        XCTAssertEqual(list[5].name, "Ücretli Gemini 3.1 Flash-Lite")
        XCTAssertEqual(list[5].model, "gemini-3.1-flash-lite", "ücretli profil ucuz Flash-Lite")
    }
}
