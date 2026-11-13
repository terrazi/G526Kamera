import Foundation
import AVFoundation

/// Okunan sorunun sesini bellekte tutar; Gemini'ye dikte metniyle birlikte gönderilir (ses asıl kaynaktır, İngilizce kelimeleri
/// Türkçe dikteden çok daha iyi çözer). Gemini'nin en rahat okuduğu biçim: 16 kHz, tek kanal, 16 bit WAV.
protocol QuestionRecording: AnyObject {
    /// Bellekteki sesi siler (yeni soru başlıyor)
    func reset()
    /// Kayıt WAV olarak; hiç ses yoksa nil
    func wavData() -> Data?
    var duration: TimeInterval { get }
}

/// İş parçacığı güvenli ses biriktirici. Mikrofon tamponlarını ses iş parçacığında alır, 16 kHz / tek kanal / Int16'ya çevirir.
final class PCMRecorder: QuestionRecording, @unchecked Sendable {
    static let sampleRate: Double = 16_000
    /// En çok tutulan süre: dolunca en eski ses atılır (bellek ve istek boyutu sınırı; 180 sn ≈ 5,8 MB)
    static let maxSeconds: Double = 180

    private let lock = NSLock()
    private var samples: [Int16] = []
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: PCMRecorder.sampleRate, channels: 1, interleaved: true)

    var duration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Double(samples.count) / PCMRecorder.sampleRate
    }

    func reset() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func wavData() -> Data? {
        lock.lock()
        let copy = samples
        lock.unlock()
        guard !copy.isEmpty else { return nil }
        return PCMRecorder.wav(samples: copy, sampleRate: Int(PCMRecorder.sampleRate))
    }

    /// Mikrofon tamponunu (her biçimde) ekler
    func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, let target = target else { return }
        lock.lock()
        defer { lock.unlock() }
        if converter == nil || converterInput != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converterInput = buffer.format
        }
        guard let converter = converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0, let channel = output.int16ChannelData?[0] else { return }
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        trim()
    }

    /// Test ve kayıt için: hazır örneklerden ekleme
    func append(samples more: [Int16]) {
        lock.lock()
        samples.append(contentsOf: more)
        trim()
        lock.unlock()
    }

    /// En çok `maxSeconds` tutulur; her tamponda değil, 10 sn fazlalık birikince bir kerede kırpılır (kopyalama azalır)
    private func trim() {
        let limit = Int(PCMRecorder.maxSeconds * PCMRecorder.sampleRate)
        let slack = Int(10 * PCMRecorder.sampleRate)
        if samples.count > limit + slack { samples.removeFirst(samples.count - limit) }
    }

    // MARK: WAV

    /// 16 bit tek kanal PCM → 44 baytlık başlıklı WAV
    static func wav(samples: [Int16], sampleRate: Int) -> Data {
        let dataSize = samples.count * 2
        var data = Data()
        func put32(_ value: Int) { var v = UInt32(value).littleEndian; data.append(Data(bytes: &v, count: 4)) }
        func put16(_ value: Int) { var v = UInt16(value).littleEndian; data.append(Data(bytes: &v, count: 2)) }
        data.append(contentsOf: Array("RIFF".utf8))
        put32(36 + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        put32(16)
        put16(1)               // PCM
        put16(1)               // tek kanal
        put32(sampleRate)
        put32(sampleRate * 2)  // bayt/sn
        put16(2)               // blok hizası
        put16(16)              // bit
        data.append(contentsOf: Array("data".utf8))
        put32(dataSize)
        for sample in samples {
            var v = sample.littleEndian
            data.append(Data(bytes: &v, count: 2))
        }
        return data
    }
}
