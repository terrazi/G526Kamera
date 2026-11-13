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

    private func record(width: Int, height: Int, seconds: Double, step: Double,
                        limit: TimeInterval = VideoRecorder.maxSeconds) -> (VideoRecorder.Output?, VideoRecorder.Failure?) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).mp4")
        let recorder = VideoRecorder()
        recorder.start(to: url, maxSeconds: limit)
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
        XCTAssertGreaterThan(full, 1_000_000)
        XCTAssertLessThanOrEqual(full, 1_500_000)
        XCTAssertEqual(VideoRecorder.bitrate(width: 640, height: 360), 250_000, "küçük çözünürlükte alt sınır")
        XCTAssertEqual(VideoRecorder.maxSeconds, 90, "üst sınır 90 sn; otomatik taramada her çekim 5 sn")
    }







    /// Duraklat / devam: aradaki süre videoya girmez, dosya aralıksız tek parça olur; süre sınırı yalnız yazılan saniyeleri sayar
    func testPauseAndResumeKeepsOneContinuousFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("duraklat-\(UUID().uuidString).mp4")
        let recorder = VideoRecorder()
        recorder.start(to: url, maxSeconds: 30)
        func feed(from: Double, to: Double, shade: UInt8) {
            var t = from
            while t < to {
                recorder.append(makeBuffer(width: 640, height: 360, shade: shade), time: 1000 + t)
                t += 0.1
            }
        }
        feed(from: 0, to: 4, shade: 60)
        recorder.pause()
        XCTAssertTrue(recorder.isPaused)
        // duraklamada gelen kareler yazılmaz
        feed(from: 4, to: 40, shade: 200)
        XCTAssertEqual(recorder.recordedSeconds, 4, accuracy: 0.6, "duraklamada süre ilerlemez")
        recorder.resume()
        XCTAssertFalse(recorder.isPaused)
        feed(from: 40, to: 44, shade: 120)
        let done = expectation(description: "video bitti")
        var output: VideoRecorder.Output?
        recorder.finish { result in
            if case .success(let o) = result { output = o }
            done.fulfill()
        }
        wait(for: [done], timeout: 60)
        guard let out = output else { return XCTFail("video üretilmedi") }
        XCTAssertEqual(out.seconds, 8, accuracy: 1.0, "4 sn + 4 sn, arada boşluk yok: \(out.seconds)")
        XCTAssertTrue(out.frames >= 14 && out.frames <= 17, "yaklaşık 2 kare/sn × 8 sn: \(out.frames)")
        XCTAssertEqual(AVURLAsset(url: out.url).duration.seconds, 8, accuracy: 1.0)
        try? FileManager.default.removeItem(at: out.url)
    }

    func testPauseCountsOnlyRecordedSecondsAgainstTheLimit() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("duraklat2-\(UUID().uuidString).mp4")
        let recorder = VideoRecorder()
        recorder.start(to: url, maxSeconds: 6)
        var t = 0.0
        func feed(_ seconds: Double) {
            let end = t + seconds
            while t < end {
                recorder.append(makeBuffer(width: 640, height: 360, shade: 90), time: 1000 + t)
                t += 0.1
            }
        }
        feed(3)
        recorder.pause()
        t += 100          // uzun duraklama
        recorder.resume()
        feed(10)          // 3 sn yazılmış, sınır 6: ancak 3 sn daha girer
        let done = expectation(description: "video bitti")
        var output: VideoRecorder.Output?
        recorder.finish { result in
            if case .success(let o) = result { output = o }
            done.fulfill()
        }
        wait(for: [done], timeout: 60)
        guard let out = output else { return XCTFail("video üretilmedi") }
        XCTAssertLessThanOrEqual(out.seconds, 6.0)
        XCTAssertGreaterThan(out.seconds, 5.0)
        try? FileManager.default.removeItem(at: out.url)
    }

    func testPauseBeforeAnyFrameAndWithoutRecordingIsHarmless() {
        let recorder = VideoRecorder()
        recorder.pause()          // kayıt yok
        recorder.resume()
        XCTAssertFalse(recorder.isPaused)
        XCTAssertEqual(recorder.recordedSeconds, 0)
    }

    func testRecordsPlayableH264Mp4AtCameraResolution() {
        let (output, failure) = record(width: 1920, height: 1080, seconds: 12, step: 0.1)
        XCTAssertNil(failure)
        guard let out = output else { return XCTFail("video üretilmedi") }
        XCTAssertGreaterThan(out.bytes, 0)
        XCTAssertLessThan(out.bytes, 3 * 1024 * 1024, "12 sn'lik video küçük kalmalı")
        XCTAssertTrue(out.frames >= 22 && out.frames <= 26, "yaklaşık 2 kare/sn (giriş 10 kare/sn): \(out.frames)")
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

    func testNeverRecordsMoreThanTheGivenLimit() {
        let (output, failure) = record(width: 640, height: 360, seconds: 45, step: 0.2, limit: 30)
        XCTAssertNil(failure)
        guard let out = output else { return XCTFail("video üretilmedi") }
        XCTAssertLessThanOrEqual(out.seconds, 30.0)
        XCTAssertLessThanOrEqual(out.frames, 61)
        XCTAssertLessThanOrEqual(AVURLAsset(url: out.url).duration.seconds, 30.5)
        try? FileManager.default.removeItem(at: out.url)
    }

    /// Elle başlatılan kayıtta varsayılan sınır 90 sn'dir: 40 sn'lik giriş kesilmeden yazılır
    func testDefaultLimitAllowsMoreThanThirtySeconds() {
        let (output, failure) = record(width: 640, height: 360, seconds: 40, step: 0.25)
        XCTAssertNil(failure)
        guard let out = output else { return XCTFail("video üretilmedi") }
        XCTAssertGreaterThan(out.seconds, 35)
        XCTAssertGreaterThan(out.frames, 70, "40 sn × 2 kare/sn ≈ 81 kare: \(out.frames)")
        try? FileManager.default.removeItem(at: out.url)
    }

    /// Her yarım saniyelik pencereden en net kare seçilir: pencerede tek kare parlak (200), diğerleri koyu (40); o kare puanı en yüksek.
    func testPicksSharpestFramePerHalfSecondWindow() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("net-\(UUID().uuidString).mp4")
        let recorder = VideoRecorder()
        recorder.start(to: url)
        // 6 pencere (3 sn), pencere başına 5 kare (10 kare/sn); en net kare pencerenin farklı sıralarında
        for window in 0..<6 {
            let best = window % 5
            for k in 0..<5 {
                let t = Double(window) * 0.5 + Double(k) * 0.1
                let isBest = k == best
                recorder.offer(makeBuffer(width: 320, height: 180, shade: isBest ? 200 : 40),
                               time: 3000 + t, sharpness: isBest ? 500 : Double(10 + k))
            }
        }
        let done = expectation(description: "video bitti")
        var output: VideoRecorder.Output?
        recorder.finish { result in
            if case .success(let o) = result { output = o }
            done.fulfill()
        }
        wait(for: [done], timeout: 60)
        guard let out = output else { return XCTFail("video üretilmedi") }
        defer { try? FileManager.default.removeItem(at: out.url) }
        XCTAssertEqual(out.frames, 6, "pencere başına tek kare")

        let asset = AVURLAsset(url: out.url)
        guard let track = asset.tracks(withMediaType: .video).first else { return XCTFail("video izi yok") }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(trackOutput)
        XCTAssertTrue(reader.startReading())
        var times: [Double] = []
        var lumas: [Int] = []
        while let sample = trackOutput.copyNextSampleBuffer() {
            times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
            guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            lumas.append(Int(base[90 * stride + 160]))
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        }
        XCTAssertEqual(times.count, 6)
        for (i, t) in times.enumerated() {
            XCTAssertEqual(t, Double(i) * 0.5, accuracy: 0.02, "kareler düzenli aralıklı")
        }
        for (i, y) in lumas.enumerated() {
            XCTAssertGreaterThan(y, 150, "\(i). pencerede en net (parlak) kare seçilmeliydi: parlaklık \(y)")
        }
    }

    func testEqualSharpnessKeepsFirstFrameOfWindow() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("esit-\(UUID().uuidString).mp4")
        let recorder = VideoRecorder()
        recorder.start(to: url)
        for k in 0..<10 {
            recorder.append(makeBuffer(width: 320, height: 180, shade: k == 0 ? 200 : 40), time: 4000 + Double(k) * 0.1)
        }
        let done = expectation(description: "video bitti")
        var output: VideoRecorder.Output?
        recorder.finish { result in
            if case .success(let o) = result { output = o }
            done.fulfill()
        }
        wait(for: [done], timeout: 60)
        guard let out = output else { return XCTFail("video üretilmedi") }
        defer { try? FileManager.default.removeItem(at: out.url) }
        XCTAssertEqual(out.frames, 2, "1 saniye = 2 pencere")
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


}
