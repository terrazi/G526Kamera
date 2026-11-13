import XCTest
@testable import G526CameraDrive

/// FakeGeminiProtocol (GeminiSupportTests.swift) üzerinden çalışan, ağsız Gemini istemcisi
func fakeGeminiClient(_ model: String) -> GeminiClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FakeGeminiProtocol.self]
    return GeminiClient(session: URLSession(configuration: config), baseURL: "https://example.test/v1beta",
                        key: { "AIza-TEST" }, model: { model }, sleep: { _ in })
}

/// Sınama için profiller (varsayılan ad ve modeller), hepsi aynı anahtarla; boş anahtarda kullanılabilir profil yoktur
func testProfiles(_ key: String = "AIza-TEST", count: Int = 3) -> () -> [GeminiProfileInfo] {
    return {
        (1...count).map {
            GeminiProfileInfo(slot: $0, name: GeminiProfiles.defaultNames[$0 - 1], model: GeminiProfiles.defaultModels[$0 - 1],
                              key: key.trimmed, free: GeminiProfiles.defaultFree[$0 - 1])
        }
    }
}

func fakeProfileClient(_ profile: GeminiProfileInfo) -> GeminiClient {
    return fakeGeminiClient(profile.model)
}

private func queueReplies(_ replies: [FakeGeminiProtocol.Reply]) {
    FakeGeminiProtocol.lock.lock()
    FakeGeminiProtocol.replies = replies
    FakeGeminiProtocol.lock.unlock()
}

private func json(_ object: [String: Any]) -> Data {
    return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}

private func textReply(_ text: String) -> FakeGeminiProtocol.Reply {
    let body = json(["candidates": [["finishReason": "STOP", "content": ["parts": [["text": text]]]]]])
    return FakeGeminiProtocol.Reply(status: 200, body: body, error: nil)
}

private func audioReply(_ bytes: Data) -> FakeGeminiProtocol.Reply {
    let body = json(["candidates": [["content": ["parts": [["inlineData": ["mimeType": "audio/L16;rate=24000",
                                                                            "data": bytes.base64EncodedString()]]]]]]])
    return FakeGeminiProtocol.Reply(status: 200, body: body, error: nil)
}

private func errorReply(_ status: Int, _ message: String = "hata") -> FakeGeminiProtocol.Reply {
    return FakeGeminiProtocol.Reply(status: status, body: json(["error": ["message": message]]), error: nil)
}

private func dictionary(_ data: Data) throws -> [String: Any] {
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

// MARK: - Modül 5: Gemini'ye soru

@MainActor
final class GeminiAnswerServiceTests: XCTestCase {
    func testSystemPromptCarriesTheRequiredFramingAndEmpathyInstruction() {
        let prompt = GeminiAnswerService.systemPrompt
        XCTAssertTrue(prompt.contains("Sen bir sınav okuyucu asistansın. Gelen test sorularını çöz"))
        XCTAssertTrue(prompt.contains("Soru [numara], [şık sözcüğü], [doğru cevabın metni]"))
        XCTAssertTrue(prompt.contains("A=Adana, B=Bursa, C=Ceyhan, D=Denizli, E=Erzurum"))
        XCTAssertTrue(prompt.contains("yanlış telaffuz"), "Kullanıcının zayıf İngilizce telaffuzu bildirilir")
        XCTAssertTrue(prompt.contains("empati"))
        XCTAssertTrue(prompt.contains("Çok boyutlu düşün"))
        XCTAssertTrue(prompt.contains("SES KAYDI"))
    }

    func testRequestBodyWithoutAudioHasOneTextPart() throws {
        FakeGeminiProtocol.reset()
        let body = try dictionary(try GeminiAnswerService.requestBody(question: "bir soru", expectedNumber: 4))
        let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents[0]["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 1)
        let text = try XCTUnwrap(parts[0]["text"] as? String)
        XCTAssertTrue(text.contains("Soru 4"))
        XCTAssertTrue(text.contains("bir soru"))
        let system = try XCTUnwrap(body["systemInstruction"] as? [String: Any])
        XCTAssertNotNil(system["parts"])
    }

    func testRequestBodyWithAudioAddsInlineWav() throws {
        let audio = Data([9, 8, 7, 6])
        let body = try dictionary(try GeminiAnswerService.requestBody(question: "bir soru", expectedNumber: 2, audio: audio))
        let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents[0]["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 2)
        let inline = try XCTUnwrap(parts[1]["inlineData"] as? [String: Any])
        XCTAssertEqual(inline["mimeType"] as? String, "audio/wav")
        XCTAssertEqual(inline["data"] as? String, audio.base64EncodedString())
        XCTAssertTrue((parts[0]["text"] as? String)?.contains("ses kaydı") ?? false)
    }

    func testReplyTextSkipsThoughtsAndJoinsParts() throws {
        let object: [String: Any] = ["candidates": [["content": ["parts": [["text": "düşünüyorum", "thought": true],
                                                                        ["text": "Soru 1, "], ["text": "Adana, A"]]]]]]
        XCTAssertEqual(try GeminiAnswerService.replyText(from: object), "Soru 1, Adana, A")
    }

    func testReplyTextErrors() {
        XCTAssertThrowsError(try GeminiAnswerService.replyText(from: ["promptFeedback": ["blockReason": "SAFETY"]])) {
            XCTAssertEqual(($0 as? GeminiError)?.kind, .blocked)
        }
        XCTAssertThrowsError(try GeminiAnswerService.replyText(from: ["candidates": []])) {
            XCTAssertEqual(($0 as? GeminiError)?.kind, .empty)
        }
        XCTAssertThrowsError(try GeminiAnswerService.replyText(from: ["candidates": [["content": ["parts": [["text": "  "]]]]]])) {
            XCTAssertEqual(($0 as? GeminiError)?.kind, .empty)
        }
    }

    func testAnswerParsesTheReplyAndUsesFirstModel() async throws {
        FakeGeminiProtocol.reset()
        queueReplies([textReply("**Soru 2, Denizli, Örgütsel Davranış**")])
        let service = GeminiAnswerService(profiles: testProfiles(" AIza-TEST "), makeClient: fakeProfileClient)
        let reply = try await service.answer(question: "bir soru", expectedNumber: 2, audio: nil)
        XCTAssertEqual(reply.number, 2)
        XCTAssertEqual(reply.option, "Denizli")
        XCTAssertEqual(reply.text, "Örgütsel Davranış")
        XCTAssertEqual(reply.spoken, "Soru 2, Denizli, Örgütsel Davranış")
        XCTAssertEqual(reply.model, GeminiProfiles.defaultModels[0])
        XCTAssertEqual(FakeGeminiProtocol.urls.count, 1)
        XCTAssertTrue(FakeGeminiProtocol.urls[0].absoluteString.contains(GeminiProfiles.defaultModels[0]))
    }

    func testAudioReachesTheRequestBody() async throws {
        FakeGeminiProtocol.reset()
        queueReplies([textReply("Soru 1, Adana, A")])
        let service = GeminiAnswerService(profiles: testProfiles("AIza-TEST"), makeClient: fakeProfileClient)
        _ = try await service.answer(question: "x", expectedNumber: 1, audio: Data([1, 2, 3]))
        let body = try dictionary(FakeGeminiProtocol.bodies[0])
        let parts = try XCTUnwrap((body["contents"] as? [[String: Any]])?[0]["parts"] as? [[String: Any]])
        XCTAssertNotNil(parts.last?["inlineData"])
    }

    func testModelNotFoundFallsBackToNextModel() async throws {
        FakeGeminiProtocol.reset()
        queueReplies([errorReply(404, "model yok"), textReply("Soru 5, Bursa, Pazarlama")])
        let service = GeminiAnswerService(profiles: testProfiles("AIza-TEST"), makeClient: fakeProfileClient)
        let reply = try await service.answer(question: "x", expectedNumber: 5, audio: nil)
        XCTAssertEqual(reply.model, GeminiProfiles.defaultModels[1])
        XCTAssertEqual(FakeGeminiProtocol.urls.count, 2)
        XCTAssertTrue(FakeGeminiProtocol.urls[1].absoluteString.contains(GeminiProfiles.defaultModels[1]))
    }

    func testEveryModelFailingMergesTheTrail() async {
        FakeGeminiProtocol.reset()
        queueReplies([errorReply(404), errorReply(404), errorReply(404)])
        let service = GeminiAnswerService(profiles: testProfiles("AIza-TEST"), makeClient: fakeProfileClient)
        do {
            _ = try await service.answer(question: "x", expectedNumber: 1, audio: nil)
            XCTFail("Hata bekleniyordu")
        } catch let error as GeminiError {
            XCTAssertEqual(error.kind, .model)
            GeminiProfiles.defaultModels.forEach { XCTAssertTrue(error.message.contains($0), $0) }
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(FakeGeminiProtocol.urls.count, 3)
    }

    func testBlockedContentDoesNotTryOtherModels() async {
        FakeGeminiProtocol.reset()
        let blocked = FakeGeminiProtocol.Reply(status: 200, body: json(["promptFeedback": ["blockReason": "SAFETY"]]), error: nil)
        queueReplies([blocked, textReply("Soru 1, Adana, A")])
        let service = GeminiAnswerService(profiles: testProfiles("AIza-TEST"), makeClient: fakeProfileClient)
        do {
            _ = try await service.answer(question: "x", expectedNumber: 1, audio: nil)
            XCTFail("Hata bekleniyordu")
        } catch let error as GeminiError {
            XCTAssertEqual(error.kind, .blocked)
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(FakeGeminiProtocol.urls.count, 1)
    }

    func testMissingKeyFailsBeforeAnyRequest() async {
        FakeGeminiProtocol.reset()
        let service = GeminiAnswerService(profiles: testProfiles("  "), makeClient: fakeProfileClient)
        do {
            _ = try await service.answer(question: "x", expectedNumber: 1, audio: nil)
            XCTFail("Hata bekleniyordu")
        } catch let error as GeminiError {
            XCTAssertEqual(error.kind, .key)
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertTrue(FakeGeminiProtocol.urls.isEmpty)
    }

    func testFallbackRules() {
        XCTAssertFalse(GeminiAnswerService.fallbackWorthy(GeminiError("x", .blocked)))
        XCTAssertFalse(GeminiAnswerService.fallbackWorthy(GeminiError("x", .cap)))
        XCTAssertFalse(GeminiAnswerService.fallbackWorthy(GeminiError("x", .tooBig)))
        XCTAssertFalse(GeminiAnswerService.fallbackWorthy(GeminiError("x", .network)), "İnternet yoksa başka model de çalışmaz")
        var slow = GeminiError("x", .network)
        slow.timedOut = true
        XCTAssertTrue(GeminiAnswerService.fallbackWorthy(slow), "Cevap gecikirse sıradaki model denenir")
        XCTAssertTrue(GeminiAnswerService.fallbackWorthy(GeminiError("x", .quota)))
        XCTAssertTrue(GeminiAnswerService.fallbackWorthy(GeminiError("x", .empty)))
        XCTAssertTrue(GeminiAnswerService.fallbackWorthy(GeminiError("x", .error, status: 503)))
    }
}

// MARK: - Gemini sesi (TTS)

@MainActor
final class GeminiVoiceTests: XCTestCase {
    func testRequestBodyAsksForAudioWithTheConfiguredVoice() throws {
        let body = try dictionary(try GeminiVoice.requestBody(text: "Soru 1, Adana, A"))
        let config = try XCTUnwrap(body["generationConfig"] as? [String: Any])
        XCTAssertEqual(config["responseModalities"] as? [String], ["AUDIO"])
        let voice = (((config["speechConfig"] as? [String: Any])?["voiceConfig"]) as? [String: Any])?["voice"] as? String
        XCTAssertEqual(voice, GeminiVoice.voiceName)
        let parts = try XCTUnwrap((body["contents"] as? [[String: Any]])?[0]["parts"] as? [[String: Any]])
        XCTAssertEqual(parts[0]["text"] as? String, "Soru 1, Adana, A")
    }

    func testAudioBytesAreDecodedFromInlineData() throws {
        let bytes = Data([1, 2, 3, 4])
        let camel: [String: Any] = ["candidates": [["content": ["parts": [["inlineData": ["data": bytes.base64EncodedString()]]]]]]]
        let snake: [String: Any] = ["candidates": [["content": ["parts": [["text": "x"], ["inline_data": ["data": bytes.base64EncodedString()]]]]]]]
        XCTAssertEqual(try GeminiVoice.audioBytes(from: camel), bytes)
        XCTAssertEqual(try GeminiVoice.audioBytes(from: snake), bytes)
    }

    func testMissingAudioIsAnEmptyError() {
        XCTAssertThrowsError(try GeminiVoice.audioBytes(from: ["candidates": [["content": ["parts": [["text": "yalnız metin"]]]]]])) {
            XCTAssertEqual(($0 as? GeminiError)?.kind, .empty)
        }
        XCTAssertThrowsError(try GeminiVoice.audioBytes(from: "çöp"))
    }

    func testWavPassesThroughAndRawPCMGetsAHeader() {
        let wav = PCMRecorder.wav(samples: [1, 2, 3], sampleRate: 16_000)
        XCTAssertEqual(GeminiVoice.wavFile(from: wav), wav)

        let raw = Data([1, 0, 2, 0, 3, 0])
        let wrapped = GeminiVoice.wavFile(from: raw)
        XCTAssertEqual(wrapped.count, 44 + 6)
        XCTAssertEqual(String(decoding: wrapped.prefix(4), as: UTF8.self), "RIFF")
        let rate = UInt32(wrapped[24]) | (UInt32(wrapped[25]) << 8) | (UInt32(wrapped[26]) << 16)
        XCTAssertEqual(rate, 24_000)
        XCTAssertEqual(Array(wrapped.suffix(6)), [1, 0, 2, 0, 3, 0])
    }

    func testSynthesizeWritesAWavFileNextToTheBase() async throws {
        FakeGeminiProtocol.reset()
        queueReplies([audioReply(Data([1, 0, 2, 0]))])
        let voice = GeminiVoice(key: { "AIza-TEST" }, makeClient: fakeGeminiClient)
        let base = makeTempFolder().appendingPathComponent("soru_1")
        let url = try await voice.synthesize("Soru 1, Adana, A", to: base)
        XCTAssertEqual(url.lastPathComponent, "soru_1.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(FakeGeminiProtocol.urls.count, 1)
        XCTAssertTrue(FakeGeminiProtocol.urls[0].absoluteString.contains(GeminiVoice.models[0]))
        let sent = String(decoding: FakeGeminiProtocol.bodies[0], as: UTF8.self)
        XCTAssertTrue(sent.contains("AUDIO"))
    }

    func testSecondModelIsTriedWhenTheFirstFails() async throws {
        FakeGeminiProtocol.reset()
        queueReplies([errorReply(404), audioReply(Data([1, 0]))])
        let voice = GeminiVoice(key: { "AIza-TEST" }, makeClient: fakeGeminiClient)
        let url = try await voice.synthesize("x", to: makeTempFolder().appendingPathComponent("soru_2"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FakeGeminiProtocol.urls[1].absoluteString.contains(GeminiVoice.models[1]))
    }

    func testFailureThrowsSoTheNextEngineCanTakeOver() async {
        FakeGeminiProtocol.reset()
        queueReplies([errorReply(503), errorReply(503)])
        let voice = GeminiVoice(key: { "AIza-TEST" }, makeClient: fakeGeminiClient)
        let base = makeTempFolder().appendingPathComponent("soru_3")
        do {
            _ = try await voice.synthesize("x", to: base)
            XCTFail("Hata bekleniyordu")
        } catch {
            XCTAssertTrue(error is GeminiError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathExtension("wav").path))
        XCTAssertEqual(FakeGeminiProtocol.urls.count, 2, "Sunucu hatasında yeniden deneme yok, hemen sıradaki modele geçilir")
    }

    func testMissingKeyThrowsWithoutRequest() async {
        FakeGeminiProtocol.reset()
        let voice = GeminiVoice(key: { "" }, makeClient: fakeGeminiClient)
        do {
            _ = try await voice.synthesize("x", to: makeTempFolder().appendingPathComponent("soru_4"))
            XCTFail("Hata bekleniyordu")
        } catch let error as GeminiError {
            XCTAssertEqual(error.kind, .key)
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertTrue(FakeGeminiProtocol.urls.isEmpty)
    }
}

// MARK: - KURAL 1: kulaklık konuşmacısı

@MainActor
final class FakeEngine: SpeechSynthesizing {
    var fail = false
    var hold = false
    let ext: String
    private(set) var calls: [(text: String, base: URL)] = []
    private(set) var cancelCalls = 0
    private var continuation: CheckedContinuation<Void, Never>?

    init(ext: String = "m4a") { self.ext = ext }

    func synthesize(_ text: String, to base: URL) async throws -> URL {
        calls.append((text, base))
        if hold { await withCheckedContinuation { continuation = $0 } }
        if fail { throw GeminiError("motor çalışmadı", .error) }
        let url = base.appendingPathExtension(ext)
        try Data([1, 2, 3]).write(to: url)
        return url
    }

    func cancel() {
        cancelCalls += 1
        release()
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class HeadphoneSpeakerTests: XCTestCase {
    private func speaker(safe: @escaping () -> Bool, engines: @escaping HeadphoneSpeaker.EngineChooser) -> HeadphoneSpeaker {
        return HeadphoneSpeaker(isRouteSafe: safe, engines: engines, voice: { nil })
    }

    func testNothingIsPlayedWhenRouteIsNotSafeButSavedAnswerStays() async {
        let engine = FakeEngine()
        let s = speaker(safe: { false }, engines: { _ in [engine] })
        let base = makeTempFolder().appendingPathComponent("soru_1")
        do {
            _ = try await s.speak("Soru 1, Adana, A", saveAs: base)
            XCTFail("Çalınmamalıydı")
        } catch {
            XCTAssertEqual(error as? SpeakError, .routeUnsafe)
        }
        XCTAssertEqual(engine.calls.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathExtension("m4a").path),
                      "Kayıt dosyada kalır; tekrar modunda kulaklıkla çalınır")
    }

    func testTemporaryAnnouncementIsDeletedWhenRouteIsNotSafe() async {
        let engine = FakeEngine()
        let s = speaker(safe: { false }, engines: { _ in [engine] })
        do {
            _ = try await s.speak("Ben hazırım", saveAs: nil)
            XCTFail("Çalınmamalıydı")
        } catch {
            XCTAssertEqual(error as? SpeakError, .routeUnsafe)
        }
        let temp = engine.calls[0].base.appendingPathExtension("m4a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
    }

    func testNextEngineTakesOverWhenFirstFails() async {
        let broken = FakeEngine()
        broken.fail = true
        let working = FakeEngine()
        let s = speaker(safe: { false }, engines: { _ in [broken, working] })
        _ = try? await s.speak("x", saveAs: makeTempFolder().appendingPathComponent("soru_2"))
        XCTAssertEqual(broken.calls.count, 1)
        XCTAssertEqual(working.calls.count, 1)
    }

    func testWorkingFirstEngineSkipsTheRest() async {
        let first = FakeEngine()
        let second = FakeEngine()
        let s = speaker(safe: { false }, engines: { _ in [first, second] })
        _ = try? await s.speak("x", saveAs: makeTempFolder().appendingPathComponent("soru_3"))
        XCTAssertEqual(first.calls.count, 1)
        XCTAssertTrue(second.calls.isEmpty)
    }

    func testEveryEngineFailingStillNeverSpeaksOnUnsafeRoute() async {
        let broken = FakeEngine()
        broken.fail = true
        let s = speaker(safe: { false }, engines: { _ in [broken] })
        do {
            _ = try await s.speak("x", saveAs: nil)
            XCTFail("Çalınmamalıydı")
        } catch {
            XCTAssertEqual(error as? SpeakError, .routeUnsafe, "Canlı konuşmaya da düşülmez")
        }
    }

    func testChooserKnowsWhetherTheAnswerIsBeingSaved() async {
        var asked: [Bool] = []
        let s = speaker(safe: { false }, engines: { saving in
            asked.append(saving)
            return [FakeEngine()]
        })
        _ = try? await s.speak("a", saveAs: nil)
        _ = try? await s.speak("b", saveAs: makeTempFolder().appendingPathComponent("soru_4"))
        XCTAssertEqual(asked, [false, true])
    }

    func testStopDuringSynthesisThrowsStoppedAndLeavesNoFile() async {
        let engine = FakeEngine()
        engine.hold = true
        let s = speaker(safe: { true }, engines: { _ in [engine] })
        let base = makeTempFolder().appendingPathComponent("soru_5")
        let task = Task { () -> Error? in
            do {
                _ = try await s.speak("x", saveAs: base)
                return nil
            } catch {
                return error
            }
        }
        let started = await waitUntil { engine.calls.count == 1 }
        XCTAssertTrue(started)
        s.stop()
        let error = await task.value
        XCTAssertEqual(error as? SpeakError, .stopped)
        XCTAssertGreaterThanOrEqual(engine.cancelCalls, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathExtension("m4a").path))
    }
}

// MARK: - 4 yedekli Gemini profili

@MainActor
final class GeminiProfileChainTests: XCTestCase {
    /// Verilen anahtarlarla varsayılan ad ve modellerden profil listesi (boş anahtar = boş profil)
    private func profiles(_ keys: [String]) -> () -> [GeminiProfileInfo] {
        return {
            keys.enumerated().map { i, key in
                GeminiProfileInfo(slot: i + 1, name: GeminiProfiles.defaultNames[i], model: GeminiProfiles.defaultModels[i],
                                  key: key, free: GeminiProfiles.defaultFree[i])
            }
        }
    }

    private func sentKey(_ index: Int) -> String? {
        return FakeGeminiProtocol.headers[index].first(where: { $0.key.lowercased() == "x-goog-api-key" })?.value
    }

    func testEachProfileAsksWithItsOwnKeyAndModel() async throws {
        FakeGeminiProtocol.reset()
        queueReplies([errorReply(429, "quota"), textReply("Soru 3, Ceyhan, Maliyet")])
        let service = GeminiAnswerService(profiles: profiles(["K1", "K2", "K3"]), makeClient: fakeProfileClient)
        let reply = try await service.answer(question: "x", expectedNumber: 3, audio: nil)
        XCTAssertEqual(reply.model, GeminiProfiles.defaultModels[1])
        XCTAssertEqual(FakeGeminiProtocol.urls.count, 2)
        XCTAssertEqual(sentKey(0), "K1", "İlk soru 1. profilin kendi anahtarıyla gider")
        XCTAssertEqual(sentKey(1), "K2", "Kotası dolunca 2. profilin kendi anahtarına geçilir")
        XCTAssertTrue(FakeGeminiProtocol.urls[1].absoluteString.contains(GeminiProfiles.defaultModels[1]))
    }

    func testBlankProfilesAreSkipped() async throws {
        FakeGeminiProtocol.reset()
        queueReplies([textReply("Soru 1, Adana, A")])
        let service = GeminiAnswerService(profiles: profiles(["", "K2", "K3"]), makeClient: fakeProfileClient)
        let reply = try await service.answer(question: "x", expectedNumber: 1, audio: nil)
        XCTAssertEqual(reply.model, GeminiProfiles.defaultModels[1])
        XCTAssertEqual(FakeGeminiProtocol.urls.count, 1)
        XCTAssertEqual(sentKey(0), "K2", "Anahtarı boş profil atlanır")
    }

    func testNoteNamesTheProfileThatAnsweredAndWhyTheOthersFailed() async throws {
        FakeGeminiProtocol.reset()
        queueReplies([errorReply(503, "yoğun"), errorReply(404), textReply("Soru 1, Adana, A")])
        let service = GeminiAnswerService(profiles: profiles(["K1", "K2", "K3"]), makeClient: fakeProfileClient)
        let reply = try await service.answer(question: "x", expectedNumber: 1, audio: nil)
        XCTAssertTrue(reply.note.contains("Cevap \(GeminiProfiles.defaultNames[2]) modelinden geldi"), reply.note)
        XCTAssertTrue(reply.note.contains(GeminiProfiles.defaultNames[0]), reply.note)
        XCTAssertTrue(reply.note.contains(GeminiProfiles.defaultNames[1]), reply.note)
    }

    func testFirstProfileAnsweringLeavesNoNote() async throws {
        FakeGeminiProtocol.reset()
        queueReplies([textReply("Soru 1, Adana, A")])
        let service = GeminiAnswerService(profiles: profiles(["K1", "K2", "K3"]), makeClient: fakeProfileClient)
        let reply = try await service.answer(question: "x", expectedNumber: 1, audio: nil)
        XCTAssertEqual(reply.note, "")
    }

    func testBadKeyMovesToTheNextProfile() async throws {
        FakeGeminiProtocol.reset()
        queueReplies([errorReply(403, "izin yok"), textReply("Soru 1, Adana, A")])
        let service = GeminiAnswerService(profiles: profiles(["K1", "K2", "K3"]), makeClient: fakeProfileClient)
        let reply = try await service.answer(question: "x", expectedNumber: 1, audio: nil)
        XCTAssertEqual(reply.model, GeminiProfiles.defaultModels[1])
        XCTAssertEqual(sentKey(1), "K2")
    }

    func testAProfileThatFailedRestsAndGoesLastUntilTheRestEnds() async throws {
        FakeGeminiProtocol.reset()
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let service = GeminiAnswerService(profiles: profiles(["K1", "K2", "K3"]), now: { clock }, makeClient: fakeProfileClient)
        queueReplies([errorReply(429, "quota"), textReply("Soru 1, Adana, A")])
        _ = try await service.answer(question: "x", expectedNumber: 1, audio: nil)
        XCTAssertEqual(FakeGeminiProtocol.urls.count, 2)

        // Hemen ardından: kotası dolan 1. profil boşuna beklenmez, doğrudan 2. profil sorulur
        queueReplies([textReply("Soru 2, Bursa, B")])
        let again = try await service.answer(question: "y", expectedNumber: 2, audio: nil)
        XCTAssertEqual(again.model, GeminiProfiles.defaultModels[1])
        XCTAssertEqual(FakeGeminiProtocol.urls.count, 3, "Dinlenen profil bu soruda denenmedi")
        XCTAssertEqual(sentKey(2), "K2")

        // Dinlenme süresi dolunca 1. profil yeniden başa geçer
        clock = clock.addingTimeInterval(4000)
        queueReplies([textReply("Soru 3, Ceyhan, C")])
        let later = try await service.answer(question: "z", expectedNumber: 3, audio: nil)
        XCTAssertEqual(later.model, GeminiProfiles.defaultModels[0])
        XCTAssertEqual(sentKey(3), "K1")
    }

    func testEveryProfileFailingKeepsEachProfilesReason() async {
        FakeGeminiProtocol.reset()
        queueReplies([errorReply(429, "quota"), errorReply(403, "izin yok"), errorReply(404)])
        let service = GeminiAnswerService(profiles: profiles(["K1", "K2", "K3"]), makeClient: fakeProfileClient)
        do {
            _ = try await service.answer(question: "x", expectedNumber: 1, audio: nil)
            XCTFail("Hata bekleniyordu")
        } catch let error as GeminiError {
            GeminiProfiles.defaultNames.prefix(3).forEach { XCTAssertTrue(error.message.contains($0), $0) }
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(FakeGeminiProtocol.urls.count, 3)
    }

    func testBlockedContentStopsTheChainEvenWithManyProfiles() async {
        FakeGeminiProtocol.reset()
        let blocked = FakeGeminiProtocol.Reply(status: 200, body: json(["promptFeedback": ["blockReason": "SAFETY"]]), error: nil)
        queueReplies([blocked, textReply("Soru 1, Adana, A")])
        let service = GeminiAnswerService(profiles: profiles(["K1", "K2", "K3"]), makeClient: fakeProfileClient)
        do {
            _ = try await service.answer(question: "x", expectedNumber: 1, audio: nil)
            XCTFail("Hata bekleniyordu")
        } catch let error as GeminiError {
            XCTAssertEqual(error.kind, .blocked)
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(FakeGeminiProtocol.urls.count, 1)
    }

    func testVoiceTriesTheSecondKeyWhenTheFirstIsRejected() async throws {
        FakeGeminiProtocol.reset()
        queueReplies([errorReply(403, "izin yok"), audioReply(Data([1, 0, 2, 0]))])
        let voice = GeminiVoice(keys: { ["K1", "", "K2", "K1"] }, makeClient: fakeGeminiClient)
        let base = makeTempFolder().appendingPathComponent("soru_1")
        let url = try await voice.synthesize("Soru 1, Adana, A", to: base)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(FakeGeminiProtocol.urls.count, 2)
        XCTAssertEqual(sentKey(0), "K1")
        XCTAssertEqual(sentKey(1), "K2", "Boş ve yinelenen anahtarlar atlanır, sıradaki anahtar denenir")
    }
}
