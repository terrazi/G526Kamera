import XCTest
import PDFKit
import UIKit
import Vision
@testable import G526CameraDrive

final class OcrTests: XCTestCase {
    private let turkishLines = [
        "ÖRNEK BELGE – TEST SAHNESİ",
        "Madde 1 – Çığlık, şişe, ağaç, öğrenci, ıslık, güneş, ördek, İstanbul.",
        "Madde 2 – Çeşitli Türkçe harfler: ç Ç ğ Ğ ı İ ö Ö ş Ş ü Ü.",
        "Madde 3 – Teslim tarihi 15.03.2027, tutar 1.250,00 TL."
    ]

    private func makeJPEG(width: Int = 1600, height: Int = 700) -> URL {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let image = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            for (i, line) in turkishLines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 40, y: 40 + i * 90),
                                        withAttributes: [.font: UIFont.systemFont(ofSize: 40), .foregroundColor: UIColor.black])
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-\(UUID().uuidString).jpg")
        try? image.jpegData(compressionQuality: 0.9)!.write(to: url)
        return url
    }

    private func solidJPEG() -> URL {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200), format: format).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("s-\(UUID().uuidString).jpg")
        try? image.jpegData(compressionQuality: 0.9)!.write(to: url)
        return url
    }

    /// OCR metni PDF'in sonuna ayrı sayfalar olarak eklenir; Apple'ın PDF okuyucusu Türkçe harfleri doğru çıkarır.
    func testPDFTextPagesAreReadableByPDFKit() throws {
        let a = solidJPEG(), b = solidJPEG()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let handle = try FileHandle(forWritingTo: out)
        let turkish = "Pijamalı hasta yağız şoföre çabucak güvendi. ĞÜŞİÖÇ ğüşiöç ı İ € (parantez) \\ ters\nikinci satır"
        try PDFWrap.write(jpegs: [a, b], title: "T", texts: [turkish, ""], to: handle)
        try handle.close()

        let document = try XCTUnwrap(PDFDocument(url: out))
        XCTAssertEqual(document.pageCount, 3, "2 resim + 1 metin sayfası")
        let text = document.page(at: 2)?.string ?? ""
        for word in ["Sayfa 1", "Pijamalı", "yağız", "şoföre", "çabucak", "güvendi", "ĞÜŞİÖÇ", "ğüşiöç", "(parantez)", "ikinci satır"] {
            XCTAssertTrue(text.contains(word), "PDF'te '\(word)' yok: \(text.prefix(200))")
        }
        XCTAssertFalse((document.page(at: 0)?.string ?? "").contains("Sayfa"), "resim sayfasında metin olmamalı")
    }

    func testPDFWithoutTextsKeepsOldBehaviour() throws {
        let a = solidJPEG()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let handle = try FileHandle(forWritingTo: out)
        try PDFWrap.write(jpegs: [a], title: "T", to: handle)
        try handle.close()
        XCTAssertEqual(PDFDocument(url: out)?.pageCount, 1)
    }

    func testLongTextSplitsAcrossPages() throws {
        let a = solidJPEG()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let handle = try FileHandle(forWritingTo: out)
        let long = (0..<1500).map { "kelime\($0)" }.joined(separator: " ")
        try PDFWrap.write(jpegs: [a], title: "T", texts: [long], to: handle)
        try handle.close()
        let document = try XCTUnwrap(PDFDocument(url: out))
        XCTAssertGreaterThan(document.pageCount, 2)
        let all = (1..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: " ")
        XCTAssertTrue(all.contains("kelime0 ") && all.contains("kelime1499"))
    }

    /// Gerçek Vision motoru: bu cihazda hangi diller var, Türkçe metin nasıl okunuyor (sonuç günlüğe ve ek dosyaya yazılır).
    func testVisionReadsTurkishSample() async throws {
        let url = makeJPEG()
        let probe = VNRecognizeTextRequest()
        probe.recognitionLevel = .accurate
        let info = OcrRecognizer.chooseLanguages(probe)
        var report = "Desteklenen diller: \(info.supported.joined(separator: ", "))\nSeçilen: \(info.chosen.joined(separator: ", "))\n\nOrijinal:\n\(turkishLines.joined(separator: "\n"))\n"
        var configs: [(String, [String]?)] = [("varsayılan seçim", nil), ("yalnız en-US", ["en-US"])]
        if info.supported.contains("tr-TR") { configs.append(("tr-TR + en-US", ["tr-TR", "en-US"])) }
        var firstText = ""
        for (name, langs) in configs {
            let started = Date()
            let result = await OcrRecognizer.recognize(url: url, timeout: 60, languages: langs)
            let secs = Date().timeIntervalSince(started)
            switch result {
            case .success(let text):
                if firstText.isEmpty { firstText = text }
                report += "\n--- \(name) (\(String(format: "%.2f", secs)) sn) ---\n\(text)\n"
            case .failure(let error):
                report += "\n--- \(name): HATA \(error) ---\n"
            }
        }
        print("OCR_RAPORU_BASLA\n\(report)\nOCR_RAPORU_BITIS")
        let attachment = XCTAttachment(string: report)
        attachment.name = "vision-turkce-ocr.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertFalse(firstText.isEmpty, "Vision hiç metin okuyamadı")
        XCTAssertTrue(firstText.uppercased().contains("BELGE") || firstText.contains("Madde"), "temel sözcükler okunamadı")
    }

    /// OcrCenter: iş kabul edilir, metin dosyası yazılır, kapalıyken iş alınmaz.
    @MainActor
    func testOcrCenterWritesSidecarAndHonoursSetting() async throws {
        let settings = AppSettings.shared
        let old = settings.ocrEnabled
        defer { settings.ocrEnabled = old; OcrCenter.shared.reset() }
        let url = makeJPEG()

        settings.ocrEnabled = false
        OcrCenter.shared.submit(url)
        XCTAssertFalse(OcrCenter.shared.isPending(url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: OcrCenter.sidecar(url).path))

        settings.ocrEnabled = true
        OcrCenter.shared.reset()
        OcrCenter.shared.submit(url)
        await OcrCenter.shared.waitFor([url], timeout: 60)
        XCTAssertFalse(OcrCenter.shared.isPending(url))
        let text = OcrCenter.readText(url)
        XCTAssertFalse(text.isEmpty, "metin dosyası yazılmadı (durum: \(OcrCenter.shared.status))")
    }
}
