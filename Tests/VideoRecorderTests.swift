import XCTest
import AVFoundation
import CoreMedia
import CoreVideo
@testable import G526CameraDrive

final class VideoRecorderTests: XCTestCase {
    private func makeBuffer(width: Int, height: Int, shade: UInt8) -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            attrs as CFDictionary, &created)
        let buffer = created!
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
            let count = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane)
            memset(base, plane == 0 ? Int32(shade) : 128, count)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func record(width: Int, height: Int, seconds: Double, step: Double) -> (VideoRecorder.Output?, VideoRecorder.Failure?) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).mp4")
        let recorder = VideoRecorder()
        recorder.start(to: url)
        XCTAssertTrue(recorder.isRecording)
        var t = 0.0
        var i = 0
        while t <= seconds {
            recorder.append(makeBuffer(width: width, height: height, shade: UInt8(40 + (i % 150))), time: 1000 + t)
            t += step
            i += 1
        }
        let done = expectation(description: "video bitti")
        var output: VideoRecorder.Output?
        var failure: VideoRecorder.Failure?
        recorder.finish { result in
            switch result {
            case .success(let o): output = o
            case .failure(let f): failure = f
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 90)
        XCTAssertFalse(recorder.isRecording)
        return (output, failure)
    }

    func testBitrateScalesWithResolutionAndStaysSmall() {
        let full = VideoRecorder.bitrate(width: 1920, height: 1080)
        XCTAssertGreaterThan(full, 800_000)
        XCTAssertLessThanOrEqual(full, 1_200_000)
        XCTAssertEqual(VideoRecorder.bitrate(width: 640, height: 360), 250_000, "küçük çözünürlükte alt sınır")
        XCTAssertEqual(VideoRecorder.maxSeconds, 30)
    }

    func testRecordsPlayableH264Mp4AtCameraResolution() {
        let (output, failure) = record(width: 1920, height: 1080, seconds: 12, step: 0.1)
        XCTAssertNil(failure)
        guard let out = output else { return XCTFail("video üretilmedi") }
        XCTAssertGreaterThan(out.bytes, 0)
        XCTAssertLessThan(out.bytes, 3 * 1024 * 1024, "12 sn'lik video küçük kalmalı")
        XCTAssertTrue(out.frames >= 55 && out.frames <= 65, "5 kare/sn: \(out.frames)")
        let asset = AVURLAsset(url: out.url)
        XCTAssertEqual(asset.duration.seconds, 12, accuracy: 1.0)
        guard let track = asset.tracks(withMediaType: .video).first else { return XCTFail("video izi yok") }
        XCTAssertEqual(Int(track.naturalSize.width), 1920)
        XCTAssertEqual(Int(track.naturalSize.height), 1080)
        let formats = track.formatDescriptions as? [CMFormatDescription] ?? []
        XCTAssertEqual(formats.first.map { CMFormatDescriptionGetMediaSubType($0) }, kCMVideoCodecType_H264)
        XCTAssertEqual(asset.tracks(withMediaType: .audio).count, 0)
        try? FileManager.default.removeItem(at: out.url)
    }

    func testNeverRecordsMoreThanThirtySeconds() {
        let (output, failure) = record(width: 640, height: 360, seconds: 45, step: 0.2)
        XCTAssertNil(failure)
        guard let out = output else { return XCTFail("video üretilmedi") }
        XCTAssertLessThanOrEqual(out.seconds, 30.0)
        XCTAssertLessThanOrEqual(out.frames, 151)
        XCTAssertLessThanOrEqual(AVURLAsset(url: out.url).duration.seconds, 30.5)
        try? FileManager.default.removeItem(at: out.url)
    }

    func testNoFramesGivesNoFramesFailureAndNoFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bos-\(UUID().uuidString).mp4")
        let recorder = VideoRecorder()
        recorder.start(to: url)
        let done = expectation(description: "bitti")
        var failure: VideoRecorder.Failure?
        recorder.finish { result in
            if case .failure(let f) = result { failure = f }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        guard case .noFrames? = failure else { return XCTFail("noFrames bekleniyordu") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testVoiceCommandsMatchStartAndStopButNotFinishPhrases() {
        XCTAssertGreaterThan(SpeechMatcher.occurrences(in: "video kaydını aç", trigger: VideoVocabulary.start), 0)
        XCTAssertGreaterThan(SpeechMatcher.occurrences(in: "Video kaydı başlat", trigger: VideoVocabulary.start), 0)
        XCTAssertGreaterThan(SpeechMatcher.occurrences(in: "kapat", trigger: VideoVocabulary.stop), 0)
        XCTAssertGreaterThan(SpeechMatcher.occurrences(in: "kaydı kapat", trigger: VideoVocabulary.stop), 0)
        XCTAssertEqual(SpeechMatcher.occurrences(in: "hepsini gönder", trigger: VideoVocabulary.start), 0)
        XCTAssertEqual(SpeechMatcher.occurrences(in: "hepsini gönder", trigger: VideoVocabulary.stop), 0)
        XCTAssertFalse(VideoVocabulary.stop.contains("bitir"), "\"bitir\" PDF gönderme komutuyla karışır")
        XCTAssertFalse(VideoVocabulary.start.contains("bitir"))
    }
}
