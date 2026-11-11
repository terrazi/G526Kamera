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
