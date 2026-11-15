import XCTest
@testable import G526CameraDrive

/// Gemini'ye giden dört istek türü, gerçek `GeminiAnswerService` + `GeminiClient` + `URLSession` üzerinden (yalnız ağın ucu sahte):
/// telde giden adres, başlık ve gövde Google'ın belgelerindeki biçimle (inlineData/mimeType, videoMetadata.fps, systemInstruction,
/// generationConfig.mediaResolution) karşılaştırılır; görüntü ve ses baytları base64'ten geri çözülüp aynı mı diye bakılır.
/// Gerçek Gemini'ye bağlanılmaz (anahtar ve ağ yok): cihazda ve gerçek anahtarla ayrıca denenmelidir.
@MainActor
final class GeminiWireTests: XCTestCase {
    private var tempFiles: [URL] = []

    override func setUp() {
        super.setUp()
        FakeGeminiProtocol.reset()
    }

    override func tearDown() {
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        tempFiles = []
        super.tearDown()
    }

    // MARK: Yardımcılar

    private func queue(_ replies: FakeGeminiProtocol.Reply...) {
        FakeGeminiProtocol.lock.lock()
        FakeGeminiProtocol.replies = replies
        FakeGeminiProtocol.lock.unlock()
    }

    private func json(_ object: [String: Any]) -> Data {
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// Gemini 3 biçiminde bir cevap: düşünce parçası, imza alanı ve kullanım bilgisi de gelir
    private func ok(_ text: String) -> FakeGeminiProtocol.Reply {
        let object: [String: Any] = [
            "candidates": [["content": ["role": "model", "parts": [
                ["text": "Soruyu inceliyorum", "thought": true],
                ["text": text, "thoughtSignature": "c2lnbmF0dXJl"]
            ]], "finishReason": "STOP", "index": 0]],
            "usageMetadata": ["promptTokenCount": 1200, "candidatesTokenCount": 14, "totalTokenCount": 1500],
            "modelVersion": "gemini-test", "responseId": "abc"
        ]
        return FakeGeminiProtocol.Reply(status: 200, body: json(object), error: nil)
    }

    private func failure(_ status: Int, _ message: String, reason: String = "") -> FakeGeminiProtocol.Reply {
        var error: [String: Any] = ["code": status, "message": message]
        if !reason.isEmpty { error["details"] = [["@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": reason]] }
        return FakeGeminiProtocol.Reply(status: status, body: json(["error": error]), error: nil)
    }

    private func service() -> GeminiAnswerService {
        return GeminiAnswerService(profiles: testProfiles(count: 1), makeClient: fakeProfileClient)
    }

    private func sentBody(_ index: Int = 0) throws -> [String: Any] {
        FakeGeminiProtocol.lock.lock()
        let bodies = FakeGeminiProtocol.bodies
        FakeGeminiProtocol.lock.unlock()
        XCTAssertGreaterThan(bodies.count, index, "Giden istek yok")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: bodies[index]) as? [String: Any])
    }

    private func parts(_ body: [String: Any]) throws -> [[String: Any]] {
        let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.count, 1)
        XCTAssertEqual(contents[0]["role"] as? String, "user")
        return try XCTUnwrap(contents[0]["parts"] as? [[String: Any]])
    }

    private func kinds(_ list: [[String: Any]]) -> [String] {
        return list.map { part in
            if part["text"] != nil { return "metin" }
            return (part["inlineData"] as? [String: Any])?["mimeType"] as? String ?? "?"
        }
    }

    private func decoded(_ part: [String: Any]) throws -> Data {
        let inline = try XCTUnwrap(part["inlineData"] as? [String: Any])
        return try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(inline["data"] as? String)), "base64 çözülemedi")
    }

    private func shot(photo: UInt8, video: [UInt8], bytes: Int = 200_000) throws -> CapturedQuestion {
        var s = FakeCamera.shot(bytes: bytes)
        s.photo = Data(repeating: photo, count: 3_000)
        try Data(video).write(to: try XCTUnwrap(s.video))
        tempFiles.append(try XCTUnwrap(s.video))
        return s
    }

    private func assertCommonRequest(file: StaticString = #filePath, line: UInt = #line) throws {
        FakeGeminiProtocol.lock.lock()
        let urls = FakeGeminiProtocol.urls
        let headers = FakeGeminiProtocol.headers
        let methods = FakeGeminiProtocol.methods
        FakeGeminiProtocol.lock.unlock()
        XCTAssertFalse(urls.isEmpty, file: file, line: line)
        let address = urls[0].absoluteString
        XCTAssertTrue(address.contains("/models/") && address.hasSuffix(":generateContent"), address, file: file, line: line)
        XCTAssertFalse(address.contains("key="), "Anahtar adreste değil başlıkta gider", file: file, line: line)
        XCTAssertEqual(methods[0], "POST", file: file, line: line)
        XCTAssertEqual(headers[0].first(where: { $0.key.lowercased() == "x-goog-api-key" })?.value, "AIza-TEST", file: file, line: line)
        XCTAssertEqual(headers[0].first(where: { $0.key.lowercased() == "content-type" })?.value, "application/json", file: file, line: line)
    }

    // MARK: 1. Sesli soru

    func testAVoiceQuestionTravelsWithItsAudioAndTheAnswerComesBackParsed() async throws {
        queue(ok("Soru 3, Denizli, Örgütsel Davranış"))
        let audio = PCMRecorder.wav(samples: (0..<1600).map { Int16($0 % 200) }, sampleRate: 16_000)
        let reply = try await service().answer(question: "üçüncü soru dikte", english: "third question", expectedNumber: 3, audio: audio, passage: nil)
        XCTAssertEqual(reply.number, 3)
        XCTAssertEqual(reply.option, "Denizli")
        XCTAssertEqual(reply.spoken, "Soru 3, Denizli, Örgütsel Davranış", "Düşünce parçası okunmaz, imza alanı sorun çıkarmaz")
        try assertCommonRequest()
        let body = try sentBody()
        let list = try parts(body)
        XCTAssertEqual(kinds(list), ["metin", "audio/wav"])
        XCTAssertEqual(try decoded(list[1]), audio, "Ses kaydı baytı baytına aynı gider")
        XCTAssertEqual(decodedPrefix(try decoded(list[1])), "RIFF")
        let text = try XCTUnwrap(list[0]["text"] as? String)
        XCTAssertTrue(text.contains("Soru 3") && text.contains("üçüncü soru dikte") && text.contains("third question"))
        let system = try XCTUnwrap((body["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]])
        XCTAssertEqual(system.first?["text"] as? String, GeminiAnswerService.systemPrompt)
        XCTAssertNil(body["generationConfig"], "Sesli soruda ek ayar yok")
    }

    private func decodedPrefix(_ data: Data) -> String {
        return String(decoding: data.prefix(4), as: UTF8.self)
    }

    // MARK: 2. Sesli soru + kamerayla çekilmiş ortak paragraf

    func testAVoiceQuestionCarriesTheCameraPassageImagesAfterTheAudio() async throws {
        queue(ok("Soru 5, Bursa, Rekabet"))
        let audio = PCMRecorder.wav(samples: [1, 2, 3, 4], sampleRate: 16_000)
        let passageShot = try shot(photo: 7, video: [7, 7, 7])
        let reply = try await service().answer(question: "Soru 5. beşinci", english: "", expectedNumber: 5, audio: audio,
                                               passage: PassageMedia(passageShot))
        XCTAssertEqual(reply.number, 5)
        try assertCommonRequest()
        let list = try parts(try sentBody())
        XCTAssertEqual(kinds(list), ["metin", "audio/wav", "image/jpeg", "video/mp4"])
        XCTAssertEqual(try decoded(list[2]), Data(repeating: 7, count: 3_000), "Paragraf fotoğrafı aynı gider")
        XCTAssertEqual(try decoded(list[3]), Data([7, 7, 7]), "Paragraf videosu dosyadan okunup aynı gider")
        XCTAssertEqual((list[3]["videoMetadata"] as? [String: Any])?["fps"] as? Double, VideoRecorder.fps)
    }

    // MARK: 3. Kamerayla çekilen soru

    func testACapturedQuestionGoesOutAsPhotoVideoAndThenTheText() async throws {
        queue(ok("Soru 7, Ceyhan, Pazarlama karması"))
        var question = try shot(photo: 9, video: [9, 9])
        question.extraInstruction = "Şıklar küçük yazılmış"
        let reply = try await service().answer(capture: question, expectedNumber: 7)
        XCTAssertEqual(reply.number, 7)
        XCTAssertEqual(reply.option, "Ceyhan")
        try assertCommonRequest()
        let body = try sentBody()
        let list = try parts(body)
        XCTAssertEqual(kinds(list), ["image/jpeg", "video/mp4", "metin"], "Google'ın önerisi: metin görüntüden sonra")
        XCTAssertEqual(try decoded(list[0]), Data(repeating: 9, count: 3_000))
        XCTAssertEqual(try decoded(list[1]), Data([9, 9]))
        XCTAssertEqual((list[1]["videoMetadata"] as? [String: Any])?["fps"] as? Double, VideoRecorder.fps, "videoMetadata parçanın kendisinde")
        XCTAssertNil((list[1]["inlineData"] as? [String: Any])?["videoMetadata"], "inlineData içine konmaz (Blob'un alanı değil)")
        let text = try XCTUnwrap(list[2]["text"] as? String)
        XCTAssertTrue(text.contains("Soru 7") && text.contains("Şıklar küçük yazılmış"))
        XCTAssertEqual((body["generationConfig"] as? [String: Any])?["mediaResolution"] as? String, "MEDIA_RESOLUTION_HIGH")
        let system = try XCTUnwrap((body["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]])
        XCTAssertEqual(system.first?["text"] as? String, GeminiAnswerService.captureSystemPrompt)
    }

    // MARK: 4. Kamerayla çekilen soru + kamerayla çekilmiş ortak paragraf

    func testACapturedQuestionWithACameraPassageSendsThePassageFirst() async throws {
        queue(ok("Soru 6, Adana, Yazar"))
        var question = try shot(photo: 9, video: [9])
        let passageShot = try shot(photo: 7, video: [7])
        question.passageMedia = PassageMedia(passageShot)
        question.passageNote = QuestionComposer.cameraNote(
            passage: PassageContext(text: "", english: "", audio: nil, all: [6, 7], remaining: [6, 7], shot: passageShot))
        _ = try await service().answer(capture: question, expectedNumber: 6)
        let list = try parts(try sentBody())
        XCTAssertEqual(kinds(list), ["image/jpeg", "video/mp4", "image/jpeg", "video/mp4", "metin"])
        XCTAssertEqual(try decoded(list[0]), Data(repeating: 7, count: 3_000), "Önce paragrafın görüntüleri")
        XCTAssertEqual(try decoded(list[2]), Data(repeating: 9, count: 3_000), "Sonra sorunun görüntüleri")
        let text = try XCTUnwrap(list[4]["text"] as? String)
        XCTAssertTrue(text.contains("ORTAK PARAGRAFA") && text.contains("6 ve 7"), "Not hangi görüntünün neye ait olduğunu söyler")
    }

    // MARK: İstek boyutu (Google: tek istek en çok 20 MB)

    /// En büyük izinli çekim (sorunun videosu + paragrafın videosu + fotoğraflar 14 MB) base64 ile 20 MB'ı aşmaz
    func testTheLargestAllowedCaptureStaysUnderTheTwentyMegabyteRequestLimit() throws {
        var question = FakeCamera.shot(bytes: 6_000_000)
        question.photo = Data(count: 50_000)
        try Data(count: 6_000_000).write(to: try XCTUnwrap(question.video))
        tempFiles.append(try XCTUnwrap(question.video))
        var passage = FakeCamera.shot(bytes: 7_900_000)
        passage.photo = Data(count: 50_000)
        try Data(count: 7_900_000).write(to: try XCTUnwrap(passage.video))
        tempFiles.append(try XCTUnwrap(passage.video))
        question.passageMedia = PassageMedia(passage)
        XCTAssertTrue(question.canSendVideo && question.canSendPassageVideo, "Sınırda ikisi de sığar")
        let body = try GeminiAnswerService.captureBody(question, expectedNumber: 1)
        XCTAssertGreaterThan(body.count, 18_000_000, "İki video gerçekten gömüldü")
        XCTAssertLessThan(body.count, 20_000_000, "base64 şişmesiyle bile 20 MB'ın altında")
    }

    func testTheLongestRecordedQuestionAudioStaysUnderTheLimitToo() throws {
        let longest = PCMRecorder.wav(samples: [Int16](repeating: 3, count: Int(PCMRecorder.maxSeconds * PCMRecorder.sampleRate)), sampleRate: 16_000)
        let body = try GeminiAnswerService.requestBody(question: "soru", expectedNumber: 1, audio: longest)
        XCTAssertLessThan(body.count, 20_000_000)
        let joinedMax = Data(count: AudioJoin.maxBytes)
        let bodyMax = try GeminiAnswerService.requestBody(question: "soru", expectedNumber: 1, audio: joinedMax)
        XCTAssertLessThan(bodyMax.count, 20_000_000, "Paragraf + soru birleşik ses kaydının en büyüğü")
    }

    // MARK: Kare hızı reddedilirse yeniden deneme (400)

    func testAFrameRateRejectionIsRetriedOnceWithoutTheFrameRate() async throws {
        queue(failure(400, "Invalid JSON payload received. Unknown name \"fps\" at 'contents[0].parts[1].video_metadata'"),
              ok("Soru 2, Erzurum, Motivasyon"))
        let question = try shot(photo: 9, video: [9])
        let reply = try await service().answer(capture: question, expectedNumber: 2)
        XCTAssertEqual(reply.number, 2)
        XCTAssertEqual(FakeGeminiProtocol.bodies.count, 2)
        XCTAssertTrue(try parts(try sentBody(0)).contains { $0["videoMetadata"] != nil })
        XCTAssertFalse(try parts(try sentBody(1)).contains { $0["videoMetadata"] != nil }, "İkinci istekte kare hızı yok")
        XCTAssertTrue(try parts(try sentBody(1)).contains { ($0["inlineData"] as? [String: Any])?["mimeType"] as? String == "video/mp4" },
                      "Video yine gider")
    }

    /// Yalnız PARAGRAFIN videosu giderken de (sorunun videosu yok ya da sığmadı) kare hızı reddi ayarsız yeniden denenir
    func testAFrameRateRejectionIsRetriedWhenOnlyThePassageVideoCarriesIt() async throws {
        queue(failure(400, "Invalid argument: video_metadata.fps"), ok("Soru 4, Bursa, Finans"))
        var question = try shot(photo: 9, video: [9])
        question.video = nil
        question.videoBytes = 0
        let passageShot = try shot(photo: 7, video: [7])
        question.passageMedia = PassageMedia(passageShot)
        XCTAssertFalse(question.canSendVideo)
        XCTAssertTrue(question.canSendPassageVideo)
        let reply = try await service().answer(capture: question, expectedNumber: 4)
        XCTAssertEqual(reply.number, 4)
        XCTAssertEqual(FakeGeminiProtocol.bodies.count, 2)
        XCTAssertTrue(try parts(try sentBody(0)).contains { $0["videoMetadata"] != nil })
        XCTAssertFalse(try parts(try sentBody(1)).contains { $0["videoMetadata"] != nil })
    }

    /// Geçersiz anahtar da 400 ile döner: büyük yükleme boşuna ikinci kez yapılmamalı
    func testAnInvalidKeyIsNotRetriedLikeAFrameRateRejection() async throws {
        queue(failure(400, "API key not valid. Please pass a valid API key.", reason: "API_KEY_INVALID"), ok("Soru 1, Adana, X"))
        let question = try shot(photo: 9, video: [9])
        do {
            _ = try await service().answer(capture: question, expectedNumber: 1)
            XCTFail("Hata beklenirdi")
        } catch let error as GeminiError {
            XCTAssertEqual(error.kind, .key)
        }
        XCTAssertEqual(FakeGeminiProtocol.bodies.count, 1, "Anahtar hatasında istek yinelenmez")
    }

    func testARequestWithoutAnyVideoIsNotRetriedOnA400() async throws {
        queue(failure(400, "Invalid argument"), ok("Soru 1, Adana, X"))
        var question = try shot(photo: 9, video: [9])
        question.video = nil
        question.videoBytes = 0
        do {
            _ = try await service().answer(capture: question, expectedNumber: 1)
            XCTFail("Hata beklenirdi")
        } catch let error as GeminiError {
            XCTAssertEqual(error.status, 400)
        }
        XCTAssertEqual(FakeGeminiProtocol.bodies.count, 1, "Kare hızı olmayan istek ayarsız yeniden denenmez")
    }

    // MARK: Cevap biçimleri

    func testRealisticReplyShapesAreParsedAndSpokenWithTheirNumber() {
        let cases: [(raw: String, number: Int?, option: String, spoken: String)] = [
            ("Soru 12, Denizli, Örgütsel Davranış.", 12, "Denizli", "Soru 12, Denizli, Örgütsel Davranış."),
            ("5. soru, Denizli, Örgütsel Davranış", 5, "Denizli", "Soru 5, Denizli, Örgütsel Davranış"),
            ("5. Soru: Bursa - Eğitim, öğretim ve bilgi", 5, "Bursa", "Soru 5, Bursa, Eğitim, öğretim ve bilgi"),
            ("12) soru Ceyhan", 12, "Ceyhan", "Soru 12, Ceyhan"),
            ("**Soru 8**, Erzurum, Kalite\n\nAçıklama: çünkü …", 8, "Erzurum", "Soru 8, Erzurum, Kalite"),
            ("Soru 3, Sorumluluk, kurumsal", 3, "Sorumluluk", "Soru 3, Sorumluluk, kurumsal")
        ]
        for item in cases {
            let parsed = AnswerParser.parse(item.raw)
            XCTAssertEqual(parsed.number, item.number, item.raw)
            XCTAssertEqual(parsed.option, item.option, item.raw)
            XCTAssertEqual(parsed.spoken, item.spoken, item.raw)
        }
    }
}
