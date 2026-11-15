import Foundation

/// DRW paketlerini numarasına göre sıralar, tekrarları eler, kayıp boşlukları atlar.
final class DrwAssembler {
    struct Output {
        var data: [UInt8] = []
        /// Kayıp paket yüzünden bir boşluk atlandı; akış bu noktada kesintili.
        var gapSkipped = false
    }

    private var expected: UInt16?
    private var pending: [UInt16: [UInt8]] = [:]
    private var pendingSince: TimeInterval?

    private(set) var duplicates = 0
    private(set) var lostPackets = 0
    private(set) var delivered = 0

    private let maxPending = 48
    private let maxAhead = 400
    private let maxWait: TimeInterval = 0.3

    func reset() {
        expected = nil
        pending.removeAll()
        pendingSince = nil
    }

    func push(index: UInt16, body: [UInt8], now: TimeInterval) -> Output {
        var out = Output()
        guard let exp = expected else {
            expected = index &+ 1
            out.data = body
            delivered += 1
            return out
        }

        let diff = Int(Int16(bitPattern: index &- exp))
        if diff < 0 {
            duplicates += 1
            return out
        }
        if diff == 0 {
            out.data.append(contentsOf: body)
            delivered += 1
            expected = exp &+ 1
            drain(&out)
            if pending.isEmpty { pendingSince = nil }
            return out
        }

        if pending[index] != nil {
            duplicates += 1
        } else {
            pending[index] = body
            if pendingSince == nil { pendingSince = now }
        }
        let waited = now - (pendingSince ?? now)
        if pending.count > maxPending || diff > maxAhead || waited > maxWait {
            skipGap(&out)
        }
        return out
    }

    private func drain(_ out: inout Output) {
        while let exp = expected, let body = pending.removeValue(forKey: exp) {
            out.data.append(contentsOf: body)
            delivered += 1
            expected = exp &+ 1
        }
    }

    private func skipGap(_ out: inout Output) {
        guard let exp = expected, !pending.isEmpty else { return }
        var bestKey: UInt16?
        var bestDiff = Int.max
        for key in pending.keys {
            let d = Int(Int16(bitPattern: key &- exp))
            if d > 0 && d < bestDiff {
                bestDiff = d
                bestKey = key
            }
        }
        guard let target = bestKey else {
            pending.removeAll()
            pendingSince = nil
            return
        }
        lostPackets += bestDiff
        expected = target
        out.gapSkipped = true
        drain(&out)
        pendingSince = pending.isEmpty ? nil : pendingSince
    }
}

/// Bir görüntü karesi: 83 baytlık başlık + Annex-B H.264 yükü.
struct VideoFrame {
    let header: [UInt8]
    let payload: [UInt8]
    /// Bu kareden hemen önce paket kaybı oldu (referans kareler eksik olabilir).
    let lossBefore: Bool
}

/// 01AFAFAF + 83 bayt başlık (uzunluk: ofset 79, u32 LE) + yük + F4F3F2F1 çerçevelerini ayıklar.
final class VideoFrameParser {
    static let headerSize = 83
    static let lengthOffset = 79
    private static let maxPayload = 12 * 1024 * 1024

    private var buffer: [UInt8] = []
    private var lossPending = false

    private(set) var framesParsed = 0
    private(set) var resyncs = 0

    func reset() {
        buffer.removeAll()
        lossPending = false
    }

    func append(_ bytes: [UInt8], gapBefore: Bool) -> [VideoFrame] {
        if gapBefore {
            if !buffer.isEmpty { resyncs += 1 }
            buffer.removeAll()
            lossPending = true
        }
        buffer.append(contentsOf: bytes)

        var frames: [VideoFrame] = []
        var pos = 0
        let total = buffer.count

        while true {
            guard let m = findMarker(from: pos, end: total) else {
                // Son 3 baytı sakla (işaret iki pakete bölünmüş olabilir)
                pos = max(pos, total - 3)
                break
            }
            if m > pos { resyncs += 1 }
            pos = m
            if total - pos < VideoFrameParser.headerSize { break }

            var plen = 0
            for k in 0..<4 { plen |= Int(buffer[pos + VideoFrameParser.lengthOffset + k]) << (8 * k) }
            if plen <= 0 || plen > VideoFrameParser.maxPayload {
                pos += 4
                continue
            }
            let frameEnd = pos + VideoFrameParser.headerSize + plen
            if total < frameEnd + 4 { break }

            if buffer[frameEnd] == 0xF4 && buffer[frameEnd + 1] == 0xF3
                && buffer[frameEnd + 2] == 0xF2 && buffer[frameEnd + 3] == 0xF1 {
                let header = Array(buffer[pos..<(pos + VideoFrameParser.headerSize)])
                let payload = Array(buffer[(pos + VideoFrameParser.headerSize)..<frameEnd])
                frames.append(VideoFrame(header: header, payload: payload, lossBefore: lossPending))
                lossPending = false
                framesParsed += 1
                pos = frameEnd + 4
            } else {
                resyncs += 1
                lossPending = true
                pos += 4
            }
        }

        if pos > 0 {
            buffer.removeFirst(min(pos, buffer.count))
        }
        return frames
    }

    private func findMarker(from start: Int, end: Int) -> Int? {
        if end - start < 4 { return nil }
        var i = start
        let last = end - 4
        while i <= last {
            if buffer[i] == 0x01 && buffer[i + 1] == 0xAF && buffer[i + 2] == 0xAF && buffer[i + 3] == 0xAF {
                return i
            }
            i += 1
        }
        return nil
    }
}
