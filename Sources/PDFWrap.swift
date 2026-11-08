import Foundation

/// JPEG dosyalarını çözmeden ve yeniden sıkıştırmadan çok sayfalı PDF'e sarar.
/// JPEG baytları PDF'in içine olduğu gibi (DCTDecode) konur: kalite kaybı yoktur, işlemci neredeyse
/// kullanılmaz, her seferinde yalnızca tek bir JPEG belleğe eşlenir (telefonu yormaz). Çıktı doğrudan
/// dosyaya akıtılır.
enum PDFWrap {
    enum WrapError: LocalizedError {
        case notJPEG
        case unsupported(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .notJPEG: return "Dosya geçerli bir JPEG değil."
            case .unsupported(let m): return "Desteklenmeyen JPEG: \(m)"
            case .empty: return "PDF için fotoğraf yok."
            }
        }
    }

    struct JPEGInfo {
        let width: Int
        let height: Int
        let components: Int
    }

    /// Sayfa boyutu = piksel / DPI inç (yalnızca sayfanın kâğıt boyutunu belirler).
    static let dpi = 150.0

    /// JPEG başlığından genişlik, yükseklik ve bileşen sayısını okur.
    static func jpegInfo(_ data: Data) throws -> JPEGInfo {
        return try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> JPEGInfo in
            let n = raw.count
            guard n >= 4, raw[0] == 0xFF, raw[1] == 0xD8 else { throw WrapError.notJPEG }
            var i = 2
            while i + 4 <= n {
                if raw[i] != 0xFF { i += 1; continue }
                let marker = Int(raw[i + 1])
                if marker == 0xFF { i += 1; continue }
                if marker == 0x01 || marker == 0xD8 || (marker >= 0xD0 && marker <= 0xD7) { i += 2; continue }
                if marker == 0xD9 { break }
                let length = (Int(raw[i + 2]) << 8) | Int(raw[i + 3])
                let isFrame = marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC
                if isFrame {
                    guard i + 10 <= n else { break }
                    let precision = Int(raw[i + 4])
                    let height = (Int(raw[i + 5]) << 8) | Int(raw[i + 6])
                    let width = (Int(raw[i + 7]) << 8) | Int(raw[i + 8])
                    let comps = Int(raw[i + 9])
                    guard precision == 8, width > 0, height > 0, comps == 1 || comps == 3 else {
                        throw WrapError.unsupported("kesinlik \(precision), bileşen \(comps)")
                    }
                    return JPEGInfo(width: width, height: height, components: comps)
                }
                i += 2 + length
            }
            throw WrapError.notJPEG
        }
    }

    /// Dosyanın PDF'e sarılabilir bir JPEG olup olmadığını (yalnızca başlığa bakarak) söyler.
    static func isWrappable(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        return (try? jpegInfo(data)) != nil
    }

    private static func ascii(_ s: String) -> Data {
        return Data(s.utf8)
    }

    private static func fixed2(_ v: Double) -> String {
        return String(format: "%.2f", v)
    }

    /// Her JPEG'i kendi sayfasına koyarak PDF'i `handle`'a yazar. Konum ofsetleri PDF'in başından sayılır.
    static func write(jpegs: [URL], title: String, to handle: FileHandle) throws {
        guard !jpegs.isEmpty else { throw WrapError.empty }
        var safeTitle = ""
        for scalar in title.unicodeScalars {
            let v = scalar.value
            if v < 32 || v >= 127 || v == 0x28 || v == 0x29 || v == 0x5C { continue }   // ( ) \ ve ASCII dışı atlanır
            safeTitle.unicodeScalars.append(scalar)
            if safeTitle.count >= 80 { break }
        }

        let count = jpegs.count
        let pageNumbers = (0..<count).map { 3 + 3 * $0 }     // her sayfa: sayfa, resim, içerik nesneleri
        let infoNumber = 3 + 3 * count
        var written = 0
        var offsets: [Int: Int] = [:]

        func put(_ data: Data) throws {
            try handle.write(contentsOf: data)
            written += data.count
        }
        func object(_ num: Int, _ body: Data) throws {
            offsets[num] = written
            try put(ascii("\(num) 0 obj\n"))
            try put(body)
            try put(ascii("\nendobj\n"))
        }

        try put(Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34, 0x0A, 0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]))
        try object(1, ascii("<< /Type /Catalog /Pages 2 0 R >>"))
        let kids = pageNumbers.map { "\($0) 0 R" }.joined(separator: " ")
        try object(2, ascii("<< /Type /Pages /Kids [\(kids)] /Count \(count) >>"))

        for (index, url) in jpegs.enumerated() {
            let base = pageNumbers[index]
            let jpeg = try Data(contentsOf: url, options: .mappedIfSafe)
            let info = try jpegInfo(jpeg)
            let pw = fixed2(Double(info.width) * 72.0 / dpi)
            let ph = fixed2(Double(info.height) * 72.0 / dpi)
            let colorSpace = info.components == 3 ? "/DeviceRGB" : "/DeviceGray"
            let content = ascii("q \(pw) 0 0 \(ph) 0 0 cm /Im0 Do Q")

            try object(base, ascii("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(pw) \(ph)] "
                + "/Resources << /XObject << /Im0 \(base + 1) 0 R >> >> /Contents \(base + 2) 0 R >>"))

            offsets[base + 1] = written
            try put(ascii("\(base + 1) 0 obj\n"))
            try put(ascii("<< /Type /XObject /Subtype /Image /Width \(info.width) /Height \(info.height) /ColorSpace \(colorSpace) "
                + "/BitsPerComponent 8 /Filter /DCTDecode /Length \(jpeg.count) >>\nstream\n"))
            try put(jpeg)
            try put(ascii("\nendstream\nendobj\n"))

            var stream = ascii("<< /Length \(content.count) >>\nstream\n")
            stream.append(content)
            stream.append(ascii("\nendstream"))
            try object(base + 2, stream)
        }

        let titlePart = safeTitle.isEmpty ? "" : " /Title (\(safeTitle))"
        try object(infoNumber, ascii("<< /Producer (G526 Kamera)\(titlePart) >>"))

        let xrefOffset = written
        let total = infoNumber + 1
        var xref = "xref\n0 \(total)\n0000000000 65535 f \n"
        for num in 1..<total {
            xref += String(format: "%010d 00000 n \n", offsets[num] ?? 0)
        }
        xref += "trailer\n<< /Size \(total) /Root 1 0 R /Info \(infoNumber) 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        try put(ascii(xref))
    }
}
