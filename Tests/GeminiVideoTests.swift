import XCTest
@testable import G526CameraDrive

final class GeminiVideoTests: XCTestCase {
    private func profile(_ slot: Int, key: String = "K", model: String = "m") -> GeminiProfileInfo {
        return GeminiProfileInfo(slot: slot, name: "Model \(slot)", model: model, key: key, free: true)
    }

    func testRequestHasVideoInlineDataThenQuestionAndOptionalHighResolution() throws {
        let video = Data([1, 2, 3])
        let normal = GeminiVideo.requestObject(video: video, question: "Soru?", highResolution: false)
        let contents = try XCTUnwrap(normal["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents[0]["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 2)
        let inline = try XCTUnwrap(parts[0]["inlineData"] as? [String: Any])
        XCTAssertEqual(inline["mimeType"] as? String, "video/mp4")
        XCTAssertEqual(inline["data"] as? String, video.base64EncodedString())
        XCTAssertEqual(parts[1]["text"] as? String, "Soru?")
        let config = try XCTUnwrap(normal["generationConfig"] as? [String: Any])
        XCTAssertNil(config["mediaResolution"], "varsayılan çözünürlükte ayar gönderilmez")
        XCTAssertNil(config["responseSchema"], "düz metin cevap istenir (belge sohbetinin JSON şeması yok)")

        let high = GeminiVideo.requestObject(video: video, question: "Soru?", highResolution: true)
        let highConfig = try XCTUnwrap(high["generationConfig"] as? [String: Any])
        XCTAssertEqual(highConfig["mediaResolution"] as? String, "MEDIA_RESOLUTION_HIGH")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: high))
    }

    func testBigVideoRequestPointsToUploadedFileInsteadOfInlineData() throws {
        let object = GeminiVideo.requestObject(fileURI: "https://example.test/files/abc", question: "Soru?", highResolution: true)
        let contents = try XCTUnwrap(object["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents[0]["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 2)
        XCTAssertNil(parts[0]["inlineData"], "büyük video istek içinde gitmez")
        let file = try XCTUnwrap(parts[0]["fileData"] as? [String: Any])
        XCTAssertEqual(file["mimeType"] as? String, "video/mp4")
        XCTAssertEqual(file["fileUri"] as? String, "https://example.test/files/abc")
        XCTAssertEqual(parts[1]["text"] as? String, "Soru?")
        let config = try XCTUnwrap(object["generationConfig"] as? [String: Any])
        XCTAssertEqual(config["mediaResolution"] as? String, "MEDIA_RESOLUTION_HIGH")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: object))
    }

    func testUploadDecisionAndLimits() {
        XCTAssertFalse(GeminiVideo.usesFilesAPI(bytes: GeminiVideo.inlineMaxBytes), "sınırda hâlâ doğrudan istek")
        XCTAssertTrue(GeminiVideo.usesFilesAPI(bytes: GeminiVideo.inlineMaxBytes + 1))
        XCTAssertTrue(GeminiVideo.usesFilesAPI(bytes: 40 * 1024 * 1024), "3 dk'lık kayıt ≈ 25–40 MB yüklenir")
        XCTAssertLessThan(GeminiVideo.inlineMaxBytes * 4 / 3, 20 * 1024 * 1024, "base64 sonrası istek 20 MB altında")
        XCTAssertGreaterThan(GeminiVideo.maxBytes, 40 * 1024 * 1024)
        XCTAssertEqual(GeminiVideo.uploadTimeout(bytes: 1_000_000), 300, "küçük dosyada en az 300 sn")
        XCTAssertGreaterThan(GeminiVideo.uploadTimeout(bytes: 40 * 1024 * 1024), 600, "büyük dosyada süre uzar")
    }

    func testCandidatesStartWithActiveThenRotateAndSkipEmptyKeys() {
        let list = [profile(1), profile(2, key: ""), profile(3), profile(4), profile(5), profile(6)]
        XCTAssertEqual(GeminiVideo.candidates(profiles: list, active: 3, chain: true).map { $0.slot }, [3, 4, 5, 6, 1])
        XCTAssertEqual(GeminiVideo.candidates(profiles: list, active: 3, chain: false).map { $0.slot }, [3])
        XCTAssertEqual(GeminiVideo.candidates(profiles: list, active: 1, chain: true).map { $0.slot }, [1, 3, 4, 5, 6])
    }

    func testNoUsableProfileGivesNoCandidates() {
        let list = [profile(1, key: ""), profile(2, key: "")]
        XCTAssertTrue(GeminiVideo.candidates(profiles: list, active: 1, chain: true).isEmpty)
    }

    func testTooBigVideoIsRefusedBeforeAnyRequest() async {
        let big = Data(count: GeminiVideo.maxBytes + 1)
        do {
            _ = try await GeminiVideo.analyze(videoData: big, question: "x", highResolution: false,
                                              profiles: [profile(1)], active: 1, chain: false, waitLimit: 0, notify: { _ in })
            XCTFail("hata bekleniyordu")
        } catch let e as GeminiError {
            XCTAssertEqual(e.kind, .tooBig)
        } catch {
            XCTFail("beklenmeyen hata \(error)")
        }
    }

    func testMissingKeyIsReportedWithoutRequest() async {
        do {
            _ = try await GeminiVideo.analyze(videoData: Data([1]), question: "x", highResolution: false,
                                              profiles: [profile(1, key: "")], active: 1, chain: true, waitLimit: 0, notify: { _ in })
            XCTFail("hata bekleniyordu")
        } catch let e as GeminiError {
            XCTAssertEqual(e.kind, .key)
        } catch {
            XCTFail("beklenmeyen hata \(error)")
        }
    }
}
