import Foundation

/// CS2 PPPP (LookCam / tcam ailesi) protokolünün paket kurucuları ve ayrıştırıcıları.
/// Bu bilgiler LookCam APK'sının yerel kodundan çıkarıldı ve gerçek kamerada doğrulandı.
enum PPPP {
    static let magic: UInt8 = 0xF1

    static let p2pReq: UInt8 = 0x20
    static let lanSearch: UInt8 = 0x30
    static let punch: UInt8 = 0x41
    static let p2pRdy: UInt8 = 0x42
    static let p2pRdyAck: UInt8 = 0x43
    static let drw: UInt8 = 0xD0
    static let drwAck: UInt8 = 0xD1
    static let alive: UInt8 = 0xE0
    static let aliveAck: UInt8 = 0xE1
    static let close: UInt8 = 0xF0

    static let devPort: UInt16 = 32100
    static let lanPort: UInt16 = 32108

    /// Kanal 0: canlı görüntü, kanal 1: JSON komutları
    static let chVideo: UInt8 = 0
    static let chCmd: UInt8 = 1

    static func packet(_ type: UInt8, _ payload: [UInt8] = []) -> [UInt8] {
        var p: [UInt8] = [magic, type, UInt8((payload.count >> 8) & 0xFF), UInt8(payload.count & 0xFF)]
        p.append(contentsOf: payload)
        return p
    }

    /// Komut zarfi: A0AFAFAF + 22 bayt başlık + JSON + F4F3F2F1
    static func mykjEncode(_ json: String, tzHours: Int, now: Date = Date()) -> [UInt8] {
        let body = Array(json.utf8)
        var b = [UInt8](repeating: 0, count: 26 + body.count + 4)
        b[0] = 0xA0; b[1] = 0xAF; b[2] = 0xAF; b[3] = 0xAF
        b[4] = 0
        b[5] = UInt8(truncatingIfNeeded: tzHours)
        let t = Int64(now.timeIntervalSince1970) + Int64(tzHours) * 3600
        let tu = UInt64(bitPattern: t)
        for i in 0..<8 { b[6 + i] = UInt8((tu >> UInt64(8 * i)) & 0xFF) }
        let n = UInt32(body.count)
        for i in 0..<4 { b[22 + i] = UInt8((n >> UInt32(8 * i)) & 0xFF) }
        for (i, c) in body.enumerated() { b[26 + i] = c }
        let end = 26 + body.count
        b[end] = 0xF4; b[end + 1] = 0xF3; b[end + 2] = 0xF2; b[end + 3] = 0xF1
        return b
    }

    /// Zarfın içindeki JSON metinlerini çıkarır. Tamamlanmamış zarf varsa kalan baytları döndürür.
    static func mykjExtract(from data: [UInt8]) -> (jsons: [String], rest: [UInt8]) {
        var out: [String] = []
        var i = 0
        let n = data.count
        while i + 26 <= n {
            if data[i] == 0xA0 && data[i + 1] == 0xAF && data[i + 2] == 0xAF && data[i + 3] == 0xAF {
                var len = 0
                for k in 0..<4 { len |= Int(data[i + 22 + k]) << (8 * k) }
                if len < 0 || len > 1_000_000 { i += 4; continue }
                let start = i + 26
                if start + len > n { break }
                out.append(String(decoding: data[start..<(start + len)], as: UTF8.self))
                i = start + len
                if i + 4 <= n && data[i] == 0xF4 && data[i + 1] == 0xF3 && data[i + 2] == 0xF2 && data[i + 3] == 0xF1 {
                    i += 4
                }
            } else {
                i += 1
            }
        }
        return (out, i < n ? Array(data[i...]) : [])
    }

    static func drwCommand(channel: UInt8, index: UInt16, json: String, tzHours: Int) -> [UInt8] {
        var inner: [UInt8] = [0xD1, channel, UInt8(index >> 8), UInt8(index & 0xFF)]
        inner.append(contentsOf: mykjEncode(json, tzHours: tzHours))
        return packet(drw, inner)
    }

    static func drwAcknowledge(channel: UInt8, index: UInt16) -> [UInt8] {
        let inner: [UInt8] = [0xD1, channel, 0x00, 0x01, UInt8(index >> 8), UInt8(index & 0xFF)]
        return packet(drwAck, inner)
    }

    /// Oturum açıldıktan sonra kameraya gönderilen ilk onay.
    static func drwSetup() -> [UInt8] {
        return packet(drwAck, [0xD1, 0x07, 0x00, 0x01, 0xAA, 0xAA])
    }
}

/// Kamera kimliği (UID). "G123456ABCDE" veya "GHBB-123456-ABCDE" biçimini kabul eder.
struct CameraUID: Equatable {
    let prefix: String
    let serial: UInt64
    let suffix: String

    private static let prefixMap: [Character: String] = [
        "9": "AHCC", "B": "BHCC", "C": "CHCC", "F": "FHBB", "G": "GHBB",
        "H": "HHBB", "I": "IHBB", "J": "JHBB", "K": "KHBB", "T": "THBB", "X": "XHBB"
    ]

    init?(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if t.contains("-") {
            let parts = t.split(separator: "-").map(String.init)
            guard parts.count == 3, let s = UInt64(parts[1]) else { return nil }
            prefix = parts[0]
            serial = s
            suffix = parts[2]
            return
        }
        guard t.count >= 8, let first = t.first, let p = CameraUID.prefixMap[first] else { return nil }
        let digits = String(t.dropFirst().prefix(6))
        guard let s = UInt64(digits) else { return nil }
        prefix = p
        serial = s
        suffix = String(t.dropFirst(7))
    }

    var display: String {
        return "\(prefix)-\(String(format: "%06llu", serial))-\(suffix)"
    }

    /// PUNCH / RDY paketlerinin yükü (20 bayt)
    var devicePayload: [UInt8] {
        var b = [UInt8](repeating: 0, count: 20)
        for (i, c) in prefix.utf8.prefix(4).enumerated() { b[i] = c }
        for i in 0..<8 { b[4 + i] = UInt8((serial >> UInt64(8 * (7 - i))) & 0xFF) }
        for (i, c) in suffix.utf8.prefix(8).enumerated() { b[12 + i] = c }
        return b
    }

    /// P2P_REQ yükü (36 bayt)
    func p2pRequestPayload(localPort: UInt16, localIPv4: [UInt8]?) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 36)
        for (i, c) in prefix.utf8.prefix(7).enumerated() { b[i] = c }
        let s32 = UInt32(truncatingIfNeeded: serial)
        for i in 0..<4 { b[8 + i] = UInt8((s32 >> UInt32(8 * (3 - i))) & 0xFF) }
        for (i, c) in suffix.utf8.prefix(7).enumerated() { b[12 + i] = c }
        b[19] = 0x02
        b[20] = UInt8(localPort & 0xFF)
        b[21] = UInt8(localPort >> 8)
        if let ip = localIPv4, ip.count == 4 {
            for i in 0..<4 { b[22 + i] = ip[i] }
        }
        return b
    }
}

/// Kameraya gönderilen JSON komutları. Alan sırası LookCam ile aynı tutuldu.
enum CameraCommand {
    static func object(_ pairs: [(String, Any)]) -> String {
        let parts = pairs.map { (key, value) -> String in
            if let s = value as? String {
                return "\"\(key)\":\"\(escape(s))\""
            }
            return "\"\(key)\":\(value)"
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    static func login(password: String) -> String {
        return object([("pwd", password), ("cmd", "LoginDev")])
    }

    static func appoint(password: String, tzHours: Int, now: Date = Date()) -> String {
        // Kamera "time" alanını yerel saat gibi gösteriyor (gerçek testte doğrulandı).
        let local = Int(now.timeIntervalSince1970) + tzHours * 3600
        return object([("state", 3), ("pwd", password), ("zone", tzHours),
                       ("zone_s", tzHours * 3600), ("time", local), ("cmd", "AppointDev")])
    }

    static func deviceInfo() -> String { return object([("cmd", "GetDevInfo")]) }

    /// state: 0 kapat, 1 ana akış (1920x1080), 2 alt akış (640x360)
    static func openVideo(state: Int, password: String, stream: Int, userID: Int) -> String {
        return object([("state", state), ("pwd", password), ("stream", stream),
                       ("userid", userID), ("cmd", "OpenVideo")])
    }
}
