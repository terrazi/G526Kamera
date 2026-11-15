import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// Annex-B H.264 karelerini VideoToolbox ile çözer. Kare kaybından sonra ilk anahtar kareye
/// (IDR) kadar bekler, böylece bozuk görüntü üretmez.
final class H264Decoder {
    /// Çözülen kare (CVPixelBuffer NV12) ve çözülme zamanı (sistem açılışından beri saniye)
    var onDecoded: ((CVPixelBuffer, TimeInterval) -> Void)?
    var onResolution: ((Int, Int) -> Void)?

    private let queue = DispatchQueue(label: "g526.decoder", qos: .userInitiated)
    private let lock = NSLock()
    private var inflight = 0
    private var overloaded = false

    // Yalnızca `queue` üzerinde kullanılır
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var sps: [UInt8] = []
    private var pps: [UInt8] = []
    private var needKeyFrame = true
    private var counter: Int64 = 0

    private(set) var decodedFrames = 0

    func reset() {
        queue.async {
            self.teardown()
            self.sps = []
            self.pps = []
            self.needKeyFrame = true
        }
    }

    func submit(_ frame: VideoFrame) {
        lock.lock()
        if inflight >= 6 {
            overloaded = true
            lock.unlock()
            return
        }
        inflight += 1
        lock.unlock()

        queue.async {
            self.decode(frame)
            self.lock.lock()
            self.inflight -= 1
            self.lock.unlock()
        }
    }

    // MARK: - Çözme

    private func decode(_ frame: VideoFrame) {
        lock.lock()
        if overloaded {
            overloaded = false
            needKeyFrame = true
        }
        lock.unlock()
        if frame.lossBefore { needKeyFrame = true }

        let nals = H264Decoder.splitAnnexB(frame.payload)
        var hasIDR = false
        var slices: [ArraySlice<UInt8>] = []
        for nal in nals {
            guard let first = nal.first else { continue }
            switch first & 0x1F {
            case 7:
                let bytes = Array(nal)
                if bytes != sps {
                    sps = bytes
                    teardown()
                }
            case 8:
                let bytes = Array(nal)
                if bytes != pps {
                    pps = bytes
                    teardown()
                }
            case 5:
                hasIDR = true
                slices.append(nal)
            case 1:
                slices.append(nal)
            default:
                break
            }
        }
        if slices.isEmpty { return }
        if needKeyFrame {
            if !hasIDR { return }
        }
        if session == nil {
            guard !sps.isEmpty, !pps.isEmpty, createSession() else { return }
        }
        if hasIDR { needKeyFrame = false }

        // Annex-B -> AVCC (4 baytlık uzunluk öneki)
        var avcc = [UInt8]()
        avcc.reserveCapacity(frame.payload.count + 16)
        for nal in slices {
            let n = UInt32(nal.count)
            avcc.append(UInt8((n >> 24) & 0xFF))
            avcc.append(UInt8((n >> 16) & 0xFF))
            avcc.append(UInt8((n >> 8) & 0xFF))
            avcc.append(UInt8(n & 0xFF))
            avcc.append(contentsOf: nal)
        }
        decodeSample(avcc)
    }

    private func decodeSample(_ avcc: [UInt8]) {
        guard let session = session, let format = format else { return }

        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block)
        guard status == kCMBlockBufferNoErr, let blockBuffer = block else { return }
        status = avcc.withUnsafeBytes { raw -> OSStatus in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard status == kCMBlockBufferNoErr else { return }

        counter += 1
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: counter, timescale: 10),
                                        decodeTimeStamp: .invalid)
        var sampleSize = avcc.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample)
        guard status == noErr, let sampleBuffer = sample else { return }

        var infoFlags = VTDecodeInfoFlags()
        let result = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: &infoFlags
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard let self = self else { return }
            if status == noErr, let pixelBuffer = imageBuffer {
                self.decodedFrames += 1
                self.onDecoded?(pixelBuffer, ProcessInfo.processInfo.systemUptime)
            } else {
                self.needKeyFrame = true
            }
        }
        if result != noErr {
            tlog("[çözücü] hata \(result), anahtar kare bekleniyor")
            needKeyFrame = true
            if result == kVTInvalidSessionErr {
                teardown()
            }
        }
    }

    private func createSession() -> Bool {
        var newFormat: CMVideoFormatDescription?
        let spsCopy = sps
        let ppsCopy = pps
        let formatStatus: OSStatus = spsCopy.withUnsafeBufferPointer { (s: UnsafeBufferPointer<UInt8>) -> OSStatus in
            return ppsCopy.withUnsafeBufferPointer { (p: UnsafeBufferPointer<UInt8>) -> OSStatus in
                let pointers: [UnsafePointer<UInt8>] = [s.baseAddress!, p.baseAddress!]
                let sizes: [Int] = [spsCopy.count, ppsCopy.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &newFormat)
            }
        }
        guard formatStatus == noErr, let fmt = newFormat else {
            tlog("[çözücü] format oluşturulamadı: \(formatStatus)")
            return false
        }

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: fmt, decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
            decompressionSessionOut: &newSession)
        guard status == noErr, let created = newSession else {
            tlog("[çözücü] oturum oluşturulamadı: \(status)")
            return false
        }
        format = fmt
        session = created
        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        tlog("[çözücü] hazır: \(dims.width)x\(dims.height)")
        onResolution?(Int(dims.width), Int(dims.height))
        return true
    }

    private func teardown() {
        if let s = session {
            VTDecompressionSessionInvalidate(s)
        }
        session = nil
        format = nil
    }

    // MARK: - Yardımcı

    /// Annex-B baytlarını NAL birimlerine böler (başlangıç kodları atılır).
    static func splitAnnexB(_ data: [UInt8]) -> [ArraySlice<UInt8>] {
        var starts: [(code: Int, nal: Int)] = []
        var i = 0
        let n = data.count
        while i + 3 <= n {
            if data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
                starts.append((i, i + 3))
                i += 3
            } else {
                i += 1
            }
        }
        var result: [ArraySlice<UInt8>] = []
        for (k, s) in starts.enumerated() {
            var end = (k + 1 < starts.count) ? starts[k + 1].code : n
            while end > s.nal && data[end - 1] == 0 { end -= 1 }
            if end > s.nal { result.append(data[s.nal..<end]) }
        }
        return result
    }
}
