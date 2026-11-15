import Foundation
import Darwin

struct UDPAddress: Equatable {
    var ip: String
    var port: UInt16
}

/// Basit BSD UDP soketi.
/// NWConnection kullanılmaz: kamera cevapları 32100 yerine rastgele bir porttan gönderiyor
/// ve bağlı (connected) UDP akışı bunları düşürürdü. Bu soket her kaynaktan paket kabul eder.
final class UDPSocket {
    private var fd: Int32 = -1
    private(set) var localPort: UInt16 = 0

    init?() {
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        if s < 0 { return nil }
        fd = s

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        var rcvBuf: Int32 = 1 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvBuf, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = 0
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindResult != 0 {
            Darwin.close(fd)
            fd = -1
            return nil
        }

        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        if nameResult == 0 {
            localPort = UInt16(bigEndian: bound.sin_port)
        }
    }

    deinit {
        close()
    }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    @discardableResult
    func send(_ bytes: [UInt8], to address: UDPAddress) -> Bool {
        if fd < 0 { return false }
        var dst = sockaddr_in()
        dst.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dst.sin_family = sa_family_t(AF_INET)
        dst.sin_port = address.port.bigEndian
        if inet_pton(AF_INET, address.ip, &dst.sin_addr) != 1 { return false }
        let sent = bytes.withUnsafeBytes { raw -> Int in
            withUnsafePointer(to: &dst) { ptr -> Int in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent == bytes.count
    }

    /// Zaman aşımı (100 ms) dolarsa nil döner.
    func receive(buffer: inout [UInt8]) -> (count: Int, from: UDPAddress)? {
        if fd < 0 { return nil }
        var src = sockaddr_in()
        var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let capacity = buffer.count
        let n = buffer.withUnsafeMutableBytes { raw -> Int in
            withUnsafeMutablePointer(to: &src) { sp -> Int in
                sp.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, raw.baseAddress, capacity, 0, $0, &srcLen)
                }
            }
        }
        if n <= 0 { return nil }
        var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var addrCopy = src.sin_addr
        inet_ntop(AF_INET, &addrCopy, &ipBuf, socklen_t(INET_ADDRSTRLEN))
        let ip = String(cString: ipBuf)
        return (n, UDPAddress(ip: ip, port: UInt16(bigEndian: src.sin_port)))
    }
}

/// Telefonun Wi-Fi (en0) IPv4 adresi ve alt ağ maskesi.
enum LocalNetwork {
    static func wifi() -> (ip: UInt32, mask: UInt32)? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
        defer { freeifaddrs(ifap) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = cursor {
            let ifa = cur.pointee
            if let sa = ifa.ifa_addr,
               sa.pointee.sa_family == sa_family_t(AF_INET),
               String(cString: ifa.ifa_name) == "en0" {
                let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
                }
                var mask: UInt32 = 0xFFFF_FF00
                if let nm = ifa.ifa_netmask {
                    mask = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
                    }
                }
                return (ip, mask)
            }
            cursor = ifa.ifa_next
        }
        return nil
    }

    static func string(_ v: UInt32) -> String {
        return "\((v >> 24) & 0xFF).\((v >> 16) & 0xFF).\((v >> 8) & 0xFF).\(v & 0xFF)"
    }

    static func bytes(_ v: UInt32) -> [UInt8] {
        return [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    static func parse(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".").compactMap { UInt32($0) }
        if parts.count != 4 || parts.contains(where: { $0 > 255 }) { return nil }
        return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
    }
}
