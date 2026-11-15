import XCTest
@testable import G526CameraDrive

final class ProtocolTests: XCTestCase {
    func testPacketHeader() {
        let p = PPPP.packet(PPPP.alive)
        XCTAssertEqual(p, [0xF1, 0xE0, 0x00, 0x00])

        let q = PPPP.packet(PPPP.drwAck, [1, 2, 3])
        XCTAssertEqual(q, [0xF1, 0xD1, 0x00, 0x03, 1, 2, 3])
    }

    func testDrwAcknowledge() {
        let a = PPPP.drwAcknowledge(channel: 0, index: 0x1234)
        XCTAssertEqual(a, [0xF1, 0xD1, 0x00, 0x06, 0xD1, 0x00, 0x00, 0x01, 0x12, 0x34])
    }

    func testDrwSetup() {
        XCTAssertEqual(PPPP.drwSetup(), [0xF1, 0xD1, 0x00, 0x06, 0xD1, 0x07, 0x00, 0x01, 0xAA, 0xAA])
    }

    func testCommandEnvelopeRoundTrip() {
        let json = CameraCommand.login(password: "123456")
        XCTAssertEqual(json, "{\"pwd\":\"123456\",\"cmd\":\"LoginDev\"}")

        let bytes = PPPP.mykjEncode(json, tzHours: 3, now: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(Array(bytes.prefix(4)), [0xA0, 0xAF, 0xAF, 0xAF])
        XCTAssertEqual(Array(bytes.suffix(4)), [0xF4, 0xF3, 0xF2, 0xF1])
        XCTAssertEqual(bytes[5], 3)
        XCTAssertEqual(Int(bytes[22]), json.utf8.count)

        let extracted = PPPP.mykjExtract(from: bytes)
        XCTAssertEqual(extracted.jsons, [json])
        XCTAssertTrue(extracted.rest.isEmpty)
    }

    func testEnvelopeSplitAcrossPackets() {
        let json = CameraCommand.deviceInfo()
        let bytes = PPPP.mykjEncode(json, tzHours: 0)
        let cut = bytes.count / 2
        let first = PPPP.mykjExtract(from: Array(bytes[0..<cut]))
        XCTAssertTrue(first.jsons.isEmpty)
        let second = PPPP.mykjExtract(from: first.rest + Array(bytes[cut...]))
        XCTAssertEqual(second.jsons, [json])
    }

    func testOpenVideoFieldOrder() {
        let json = CameraCommand.openVideo(state: 1, password: "123456", stream: 1, userID: 7)
        XCTAssertEqual(json, "{\"state\":1,\"pwd\":\"123456\",\"stream\":1,\"userid\":7,\"cmd\":\"OpenVideo\"}")
    }

    func testUIDParsing() {
        let short = CameraUID("G123456ABCDE")
        XCTAssertEqual(short?.prefix, "GHBB")
        XCTAssertEqual(short?.serial, 123456)
        XCTAssertEqual(short?.suffix, "ABCDE")
        XCTAssertEqual(short?.display, "GHBB-123456-ABCDE")

        let long = CameraUID("ghbb-123456-abcde")
        XCTAssertEqual(long, short)

        XCTAssertNil(CameraUID(""))
        XCTAssertNil(CameraUID("abc"))
    }

    func testUIDPayloadSizes() {
        guard let uid = CameraUID("G123456ABCDE") else { return XCTFail("UID okunamadı") }
        let device = uid.devicePayload
        XCTAssertEqual(device.count, 20)
        XCTAssertEqual(Array(device.prefix(4)), Array("GHBB".utf8))
        XCTAssertEqual(Array(device[12..<17]), Array("ABCDE".utf8))

        let request = uid.p2pRequestPayload(localPort: 40000, localIPv4: [192, 168, 1, 5])
        XCTAssertEqual(request.count, 36)
        XCTAssertEqual(request[20], UInt8(40000 & 0xFF))
        XCTAssertEqual(request[21], UInt8(40000 >> 8))
        XCTAssertEqual(Array(request[22..<26]), [192, 168, 1, 5])
    }
}

final class AssemblyTests: XCTestCase {
    func testInOrderAndDuplicates() {
        let a = DrwAssembler()
        XCTAssertEqual(a.push(index: 10, body: [1], now: 0).data, [1])
        XCTAssertEqual(a.push(index: 11, body: [2], now: 0).data, [2])
        XCTAssertTrue(a.push(index: 11, body: [2], now: 0.1).data.isEmpty)
        XCTAssertEqual(a.duplicates, 1)
    }

    func testReordering() {
        let a = DrwAssembler()
        _ = a.push(index: 10, body: [1], now: 0)
        let held = a.push(index: 12, body: [3], now: 0.01)
        XCTAssertTrue(held.data.isEmpty)
        let filled = a.push(index: 11, body: [2], now: 0.02)
        XCTAssertEqual(filled.data, [2, 3])
        XCTAssertFalse(filled.gapSkipped)
    }

    func testWrapAround() {
        let a = DrwAssembler()
        _ = a.push(index: 0xFFFF, body: [1], now: 0)
        XCTAssertEqual(a.push(index: 0, body: [2], now: 0).data, [2])
    }

    func testGapIsSkippedAfterWaiting() {
        let a = DrwAssembler()
        _ = a.push(index: 0, body: [0], now: 0)
        _ = a.push(index: 5, body: [5], now: 0.0)
        let out = a.push(index: 6, body: [6], now: 0.5)
        XCTAssertTrue(out.gapSkipped)
        XCTAssertEqual(out.data, [5, 6])
        XCTAssertEqual(a.lostPackets, 4)
    }

    private func makeFrame(payload: [UInt8]) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: VideoFrameParser.headerSize)
        header[0] = 0x01; header[1] = 0xAF; header[2] = 0xAF; header[3] = 0xAF
        let n = UInt32(payload.count)
        for k in 0..<4 { header[VideoFrameParser.lengthOffset + k] = UInt8((n >> UInt32(8 * k)) & 0xFF) }
        return header + payload + [0xF4, 0xF3, 0xF2, 0xF1]
    }

    func testFrameParserSplitAcrossChunks() {
        let payload = (0..<300).map { UInt8($0 % 251) }
        let stream = makeFrame(payload: payload) + makeFrame(payload: [9, 8, 7])
        let parser = VideoFrameParser()
        var frames: [VideoFrame] = []
        var pos = 0
        while pos < stream.count {
            let end = min(pos + 37, stream.count)
            frames += parser.append(Array(stream[pos..<end]), gapBefore: false)
            pos = end
        }
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].payload, payload)
        XCTAssertEqual(frames[1].payload, [9, 8, 7])
        XCTAssertFalse(frames[0].lossBefore)
    }

    func testFrameParserResyncsAfterGap() {
        let parser = VideoFrameParser()
        let good = makeFrame(payload: [1, 2, 3, 4])
        _ = parser.append(Array(good.prefix(50)), gapBefore: false)
        let frames = parser.append(good, gapBefore: true)
        XCTAssertEqual(frames.count, 1)
        XCTAssertTrue(frames[0].lossBefore)
    }

    func testAnnexBSplit() {
        let data: [UInt8] = [0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 4, 5, 6]
        let nals = H264Decoder.splitAnnexB(data)
        XCTAssertEqual(nals.count, 3)
        XCTAssertEqual(Array(nals[0]), [0x67, 1, 2])
        XCTAssertEqual(Array(nals[1]), [0x68, 3])
        XCTAssertEqual(Array(nals[2]), [0x65, 4, 5, 6])
    }
}

final class SpeechAndMotionTests: XCTestCase {
    func testTriggerMatching() {
        XCTAssertEqual(SpeechMatcher.occurrences(in: "Okey", trigger: "okey"), 1)
        XCTAssertEqual(SpeechMatcher.occurrences(in: "tamam okay çek", trigger: "okey"), 1)
        XCTAssertEqual(SpeechMatcher.occurrences(in: "OK", trigger: "okey"), 1)
        XCTAssertEqual(SpeechMatcher.occurrences(in: "okey okey", trigger: "okey"), 2)
        XCTAssertEqual(SpeechMatcher.occurrences(in: "merhaba nasılsın", trigger: "okey"), 0)
        XCTAssertEqual(SpeechMatcher.occurrences(in: "", trigger: "okey"), 0)
    }

    func testCustomTriggerAndTurkishLetters() {
        XCTAssertEqual(SpeechMatcher.occurrences(in: "ÇEK", trigger: "çek"), 1)
        XCTAssertEqual(SpeechMatcher.occurrences(in: "şimdi çek", trigger: "çek, tamam"), 1)
        XCTAssertEqual(SpeechMatcher.occurrences(in: "tamam kamera", trigger: "tamam kamera"), 1)
        XCTAssertEqual(SpeechMatcher.occurrences(in: "tamam", trigger: "tamam kamera"), 0)
    }

    func testWordNormalization() {
        XCTAssertEqual(SpeechMatcher.words("Işık, ÖĞÜT!"), ["isik", "ogut"])
    }

    func testMotionTriggersOnceAndIgnoresRemoval() {
        let desk = [UInt8](repeating: 40, count: FrameAnalysis.signatureColumns * FrameAnalysis.signatureRows)
        let paper = [UInt8](repeating: 200, count: desk.count)
        let detector = MotionDetector()
        detector.enabled = true
        detector.sensitivity = 1

        var t = 0.0
        var triggers = 0
        func feed(_ sig: [UInt8], seconds: Double) {
            let end = t + seconds
            while t < end {
                if detector.process(signature: sig, time: t, busy: false) { triggers += 1 }
                t += 0.1
            }
        }

        feed(desk, seconds: 2)
        XCTAssertEqual(triggers, 0)
        feed(paper, seconds: 3)
        XCTAssertEqual(triggers, 1)
        feed(desk, seconds: 3)
        XCTAssertEqual(triggers, 1, "Masa boşalınca çekmemeli")
        feed(paper, seconds: 3)
        XCTAssertEqual(triggers, 2)
    }
}
