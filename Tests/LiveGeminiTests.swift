import XCTest
import AVFoundation
import UIKit
@testable import G526CameraDrive

/// GERÇEK Gemini ile uçtan uca denemeler (diğer testlerin hepsi sahte sunucuyla çalışır; bunlar internetteki gerçek API'ye gider).
/// Gerçek kodla (GeminiAnswerService + GeminiClient + URLSession) şu dört isteği yollar: sesli soru, sesli soru + kamerayla çekilmiş paragraf,
/// çekilen soru (yalnız fotoğraf; fotoğraf + video), çekilen soru + çekilmiş paragraf. Sorular ve cevapları bellidir (İngilizce, uydurma
/// bilgiler), bu yüzden doğru cevap alınıp alınmadığı da denetlenir.
///
/// Anahtar ortam değişkeninden gelir (GEMINI_API_KEY; CI'da deponun gizli değişkeni). Yoksa her test atlanır: normal test koşusunu bozmaz.
/// Anahtar hiçbir yere yazılmaz (rapor satırlarında geçerse yıldızlanır).
/// Diğer ortam değişkenleri: LIVE_GEMINI_MODEL (varsayılan: 1. profilin modeli), LIVE_ASSETS_DIR (macOS `say` ile üretilmiş soru6.wav,
/// soru7.wav), LIVE_REPORT_FILE (sonuç satırlarının yazılacağı dosya).
@MainActor
final class LiveGeminiTests: XCTestCase {
    private var tempFiles: [URL] = []

    override func tearDown() {
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        tempFiles = []
        super.tearDown()
    }

    // MARK: Ortam

    private var env: [String: String] { return ProcessInfo.processInfo.environment }

    private func apiKey() throws -> String {
        let value = (env["GEMINI_API_KEY"] ?? "").trimmed
        if value.isEmpty { throw XCTSkip("GEMINI_API_KEY verilmedi: gerçek Gemini denemesi atlandı") }
        return value
    }

    private var model: String {
        let value = (env["LIVE_GEMINI_MODEL"] ?? "").trimmed
        return value.isEmpty ? GeminiProfiles.defaultModels[0] : value
    }

    /// Hem test günlüğüne hem (verildiyse) rapor dosyasına yazar; anahtar geçerse yıldızlar
    private func report(_ line: String) {
        var text = line
        let secret = (env["GEMINI_API_KEY"] ?? "").trimmed
        if !secret.isEmpty { text = text.replacingOccurrences(of: secret, with: "***") }
        print("CANLI-GEMINI " + text)
        guard let path = env["LIVE_REPORT_FILE"], !path.isEmpty else { return }
        let data = Data((text + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// İstekler arası kısa ara: ücretsiz katmanın dakikalık sınırına takılmamak için
    private func throttle() async {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
    }

    private func makeService(model name: String, key: String) -> GeminiAnswerService {
        let list = [GeminiProfileInfo(slot: 1, name: name, model: name, key: key, free: true)]
        return GeminiAnswerService(profiles: { list })
    }

    // MARK: Örnek içerik

    /// Beyaz sayfaya satır satır yazılmış görüntü (soru sayfası ya da paragraf gibi)
    private func page(_ lines: [String]) -> UIImage {
        let size = CGSize(width: 1280, height: 960)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 46), .foregroundColor: UIColor.black]
            var y: CGFloat = 80
            for line in lines {
                (line as NSString).draw(in: CGRect(x: 70, y: y, width: size.width - 140, height: 140), withAttributes: attributes)
                y += 110
            }
        }
    }

    /// Aynı sayfadan, kameranın kaydettiği gibi 2 kare/sn H.264 MP4 (gerçek AVAssetWriter)
    private func makeVideo(from image: UIImage, seconds: Int = 3) async throws -> URL {
        let cg = try XCTUnwrap(image.cgImage)
        let width = cg.width
        let height = cg.height
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("canli-\(UUID().uuidString).mp4")
        tempFiles.append(url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting(), "Video yazımı başlamadı: \(writer.error?.localizedDescription ?? "")")
        writer.startSession(atSourceTime: .zero)
        let timescale = Int32(VideoRecorder.fps)
        for index in 0..<(Int(VideoRecorder.fps) * seconds) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
            let pool = try XCTUnwrap(adaptor.pixelBufferPool)
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            context?.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            let appended = adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: timescale))
            XCTAssertTrue(appended, "Kare yazılamadı: \(writer.error?.localizedDescription ?? "")")
        }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        XCTAssertEqual(writer.status, .completed, "Video tamamlanmadı: \(writer.error?.localizedDescription ?? "")")
        return url
    }

    private func shot(lines: [String], withVideo: Bool) async throws -> CapturedQuestion {
        let image = page(lines)
        var captured = CapturedQuestion(photo: try XCTUnwrap(image.jpegData(compressionQuality: 0.85)))
        if withVideo {
            let url = try await makeVideo(from: image)
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            XCTAssertGreaterThan(size, 1_000, "Üretilen video boş")
            captured.video = url
            captured.videoBytes = size
            captured.videoSeconds = 3
        }
        return captured
    }

    private func speech(_ name: String) throws -> Data {
        guard let dir = env["LIVE_ASSETS_DIR"], !dir.isEmpty else { throw XCTSkip("LIVE_ASSETS_DIR yok: konuşma kaydı hazırlanmamış") }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(name)) else {
            throw XCTSkip("\(name) bulunamadı (macOS 'say' çalışmadı mı?)")
        }
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF", "\(name) WAV değil")
        XCTAssertGreaterThan(data.count, 20_000, "\(name) çok kısa")
        return data
    }

    private let questionFour = ["4. Which of the following is a country?", "A) Cat", "B) France", "C) Table", "D) Blue", "E) Apple"]
    private let kelmoPassage = ["Reading passage (questions 5 and 6)", "The village of Kelmo has one bakery.",
                                "The baker, Mr. Tarn, opens the shop at five in the morning."]
    private let questionFive = ["5. At what time does Mr. Tarn open the bakery?", "A) At three", "B) At four", "C) At six", "D) At five", "E) At seven"]
    private let bicycleStory = ["Story", "The red bicycle in the garden belongs to Anna's grandfather."]

    // MARK: Çağrı ve denetim yardımcıları

    /// Gerçek çağrı: süreyi ve hatayı rapora yazar; kota dolduysa test atlanır (kod hatası değildir)
    private func ask(_ label: String, _ work: () async throws -> GeminiReply) async throws -> GeminiReply {
        let started = Date()
        do {
            let reply = try await work()
            report("[\(label)] süre=\(String(format: "%.1f", Date().timeIntervalSince(started))) sn")
            return reply
        } catch let error as GeminiError {
            report("[\(label)] HATA tür=\(error.kind.rawValue) durum=\(error.status): \(error.message)")
            if error.kind == .quota { throw XCTSkip("Kota doldu (\(label)): \(error.message)") }
            throw error
        }
    }

    private func normalized(_ text: String) -> String {
        return text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "tr_TR"))
    }

    private func check(_ label: String, _ reply: GeminiReply, number: Int, option: String, file: StaticString = #filePath, line: UInt = #line) {
        let same = reply.number == number && normalized(reply.option) == normalized(option)
        report("[\(label)] model=\(reply.model) cevap=\"\(reply.spoken)\" beklenen=Soru \(number), \(option) → \(same ? "TAMAM" : "FARKLI")")
        XCTAssertEqual(reply.number, number, "\(label): soru numarası", file: file, line: line)
        XCTAssertEqual(normalized(reply.option), normalized(option), "\(label): şık sözcüğü (cevap: \(reply.spoken))", file: file, line: line)
        XCTAssertFalse(reply.spoken.isEmpty, "\(label): okunacak cümle boş", file: file, line: line)
    }

    /// Çekilen soru için İLK istek, kare hızı olmadan yeniden deneme (geri dönüş) OLMADAN: model videoMetadata.fps ve
    /// mediaResolution ayarlarını gerçekten kabul ediyor mu
    private func rawCapture(_ shot: CapturedQuestion, number: Int, model name: String, key: String) async throws -> GeminiReply {
        let body = try GeminiAnswerService.captureBody(shot, expectedNumber: number)
        let client = GeminiClient(key: { key }, model: { name })
        let object = try await client.generate(model: name, key: key, body: GeminiAnswerService.body(body, forModel: name),
                                               serverRetries: 1, timeout: 120)
        let parsed = AnswerParser.parse(try GeminiAnswerService.replyText(from: object))
        return GeminiReply(number: parsed.number, option: parsed.option, text: parsed.text, spoken: parsed.spoken, model: name)
    }

    // MARK: 1. Sesli soru (gerçek konuşma kaydı)

    func testLiveVoiceQuestionWithRealSpeech() async throws {
        let key = try apiKey()
        let wav = try speech("soru6.wav")
        await throttle()
        let service = makeService(model: model, key: key)
        let reply = try await ask("SES") {
            try await service.answer(question: "soru altı", english: "", expectedNumber: 6, audio: wav, passage: nil)
        }
        report("[SES] ses=\(wav.count) bayt")
        check("SES", reply, number: 6, option: "Erzurum")
    }

    // MARK: 2. Sesli soru + kamerayla çekilmiş paragraf (fotoğraf + video)

    func testLiveVoiceQuestionWithACameraPassage() async throws {
        let key = try apiKey()
        let wav = try speech("soru7.wav")
        let passageShot = try await shot(lines: bicycleStory, withVideo: true)
        let context = PassageContext(text: "", english: "", audio: nil, all: [7], remaining: [7], shot: passageShot)
        let question = QuestionComposer.withCameraPassage(question: "soru yedi", passage: context)
        await throttle()
        let service = makeService(model: model, key: key)
        let reply = try await ask("SES+PARAGRAF") {
            try await service.answer(question: question, english: "", expectedNumber: 7, audio: wav, passage: PassageMedia(passageShot))
        }
        report("[SES+PARAGRAF] ses=\(wav.count) bayt, paragraf fotoğrafı=\(passageShot.photo.count) bayt, videosu=\(passageShot.videoBytes) bayt")
        check("SES+PARAGRAF", reply, number: 7, option: "Ceyhan")
    }

    // MARK: 3. Çekilen soru: yalnız fotoğraf

    func testLiveCapturedQuestionPhotoOnly() async throws {
        let key = try apiKey()
        let captured = try await shot(lines: questionFour, withVideo: false)
        await throttle()
        let service = makeService(model: model, key: key)
        let reply = try await ask("FOTO") { try await service.answer(capture: captured, expectedNumber: 4) }
        report("[FOTO] fotoğraf=\(captured.photo.count) bayt")
        check("FOTO", reply, number: 4, option: "Bursa")
    }

    // MARK: 4. Çekilen soru: fotoğraf + video (kare hızı ve yüksek çözünürlük ayarlarıyla)

    func testLiveCapturedQuestionPhotoAndVideoIsAcceptedWithFrameRateAndHighResolution() async throws {
        let key = try apiKey()
        let captured = try await shot(lines: questionFour, withVideo: true)
        XCTAssertTrue(captured.canSendVideo)
        XCTAssertTrue(captured.highResolution)
        report("[FOTO+VIDEO] fotoğraf=\(captured.photo.count) bayt, video=\(captured.videoBytes) bayt, fps=\(VideoRecorder.fps), mediaResolution=HIGH")
        await throttle()
        // Önce geri dönüşsüz tek istek: ayarlar gerçekten kabul ediliyor mu (400 gelirse uygulama ayarsız yeniden dener; burada sorun olarak görünür)
        let first = try await ask("FOTO+VIDEO ilk istek") { try await rawCapture(captured, number: 4, model: model, key: key) }
        check("FOTO+VIDEO ilk istek", first, number: 4, option: "Bursa")
        await throttle()
        // Sonra uygulamanın gerçek yolu
        let service = makeService(model: model, key: key)
        let reply = try await ask("FOTO+VIDEO") { try await service.answer(capture: captured, expectedNumber: 4) }
        check("FOTO+VIDEO", reply, number: 4, option: "Bursa")
    }

    // MARK: 5. Çekilen soru + çekilmiş paragraf (iki fotoğraf + iki video)

    func testLiveCapturedQuestionWithACameraPassage() async throws {
        let key = try apiKey()
        let passageShot = try await shot(lines: kelmoPassage, withVideo: true)
        var captured = try await shot(lines: questionFive, withVideo: true)
        let context = PassageContext(text: "", english: "", audio: nil, all: [5, 6], remaining: [5, 6], shot: passageShot)
        captured.passageNote = QuestionComposer.cameraNote(passage: context)
        captured.passageMedia = PassageMedia(passageShot)
        XCTAssertTrue(captured.canSendVideo)
        XCTAssertTrue(captured.canSendPassageVideo)
        report("[FOTO+PARAGRAF] soru: foto=\(captured.photo.count) video=\(captured.videoBytes) bayt; paragraf: foto=\(passageShot.photo.count) video=\(passageShot.videoBytes) bayt")
        await throttle()
        let first = try await ask("FOTO+PARAGRAF ilk istek") { try await rawCapture(captured, number: 5, model: model, key: key) }
        check("FOTO+PARAGRAF ilk istek", first, number: 5, option: "Denizli")
        await throttle()
        let service = makeService(model: model, key: key)
        let reply = try await ask("FOTO+PARAGRAF") { try await service.answer(capture: captured, expectedNumber: 5) }
        check("FOTO+PARAGRAF", reply, number: 5, option: "Denizli")
    }

    // MARK: 6. Varsayılan üç modelin hepsi video isteğini kabul ediyor mu (model adları gerçekten var mı)

    func testLiveEveryDefaultModelAcceptsAPhotoAndVideoRequest() async throws {
        let key = try apiKey()
        let captured = try await shot(lines: questionFour, withVideo: true)
        var models: [String] = []
        for name in GeminiProfiles.defaultModels where !models.contains(name) { models.append(name) }
        var failures: [String] = []
        var skipped: [String] = []
        for name in models {
            await throttle()
            let started = Date()
            do {
                let reply = try await rawCapture(captured, number: 4, model: name, key: key)
                let right = reply.number == 4 && normalized(reply.option) == normalized("Bursa")
                report("[MODEL \(name)] kabul edildi, süre=\(String(format: "%.1f", Date().timeIntervalSince(started))) sn, cevap=\"\(reply.spoken)\" → \(right ? "TAMAM" : "FARKLI")")
                if !right { failures.append("\(name): beklenmeyen cevap \"\(reply.spoken)\"") }
            } catch let error as GeminiError {
                report("[MODEL \(name)] HATA tür=\(error.kind.rawValue) durum=\(error.status): \(error.message)")
                if error.kind == .quota { skipped.append(name) } else { failures.append("\(name): \(error.message)") }
            }
        }
        if !skipped.isEmpty { report("[MODEL] kotası dolduğu için denenemeyen: \(skipped.joined(separator: ", "))") }
        XCTAssertTrue(failures.isEmpty, "Modeller: " + failures.joined(separator: " | "))
    }
}
