import XCTest
@testable import G526CameraDrive

@MainActor
final class GeminiVideoQueueTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("kuyruk-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func queue() -> GeminiVideoQueue {
        return GeminiVideoQueue(directory: root.appendingPathComponent("kuyruk", isDirectory: true))
    }

    func testStartsEmpty() {
        let q = queue()
        XCTAssertEqual(q.count, 0)
        XCTAssertTrue(q.files.isEmpty)
    }

    func testAddKeepsOriginalAndListsOldestFirst() {
        let q = queue()
        let names = ["Video_2026-11-12_15-00-00.mp4", "Video_2026-11-12_15-10-00.mp4", "Video_2026-11-12_14-50-00.mp4"]
        for name in names {
            let source = root.appendingPathComponent(name)
            FileManager.default.createFile(atPath: source.path, contents: Data([1]))
            XCTAssertTrue(q.add(source))
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "özgün dosya yerinde kalır (klasöre kaydetmek için)")
        }
        XCTAssertEqual(q.count, 3)
        XCTAssertEqual(q.files.map { $0.lastPathComponent }, names.sorted(), "eskiden yeniye (adı tarihli)")
    }

    func testQueuedCopyHasSameContentAndSurvivesOriginalRemoval() throws {
        let q = queue()
        let source = root.appendingPathComponent("Video_2026-11-12_15-00-00.mp4")
        FileManager.default.createFile(atPath: source.path, contents: Data([1, 2, 3, 4]))
        XCTAssertTrue(q.add(source))
        try FileManager.default.removeItem(at: source)      // klasöre kaydedilince özgün dosya silinir
        let queued = try XCTUnwrap(q.files.first)
        XCTAssertEqual(try Data(contentsOf: queued), Data([1, 2, 3, 4]), "kuyruktaki kopya özgün silinse de durur")
    }

    func testRemoveTakesVideoOutOfTheQueueAndAddingSameNameReplaces() {
        let q = queue()
        let source = root.appendingPathComponent("Video_2026-11-12_15-00-00.mp4")
        FileManager.default.createFile(atPath: source.path, contents: Data([9]))
        XCTAssertTrue(q.add(source))
        XCTAssertTrue(q.add(source), "aynı ad yeniden eklenebilir")
        XCTAssertEqual(q.count, 1, "aynı adlı kayıt yenisiyle değişir, çift olmaz")
        q.remove(q.files[0])
        XCTAssertEqual(q.count, 0)
    }

    func testIgnoresNonMp4Files() {
        let q = queue()
        FileManager.default.createFile(atPath: q.directory.appendingPathComponent("not.txt").path, contents: Data([1]))
        XCTAssertEqual(q.count, 0)
    }

    func testQueueSurvivesNewInstanceOnSameFolder() {
        let first = queue()
        let source = root.appendingPathComponent("Video_2026-11-12_15-00-00.mp4")
        FileManager.default.createFile(atPath: source.path, contents: Data([5]))
        XCTAssertTrue(first.add(source))
        let second = queue()
        XCTAssertEqual(second.count, 1, "uygulama kapanıp açılınca sıra korunur")
    }

    // MARK: Sesli komut, ayar ve talimat

    func testSendVideosPhrasesMatchOnlyTheirOwnCommand() {
        for said in ["videoları gönder", "Videoları gönder", "videoları sırayla gönder", "videoları analiz et"] {
            XCTAssertGreaterThan(SpeechMatcher.occurrences(in: said, trigger: VideoVocabulary.send), 0, said)
            XCTAssertEqual(SpeechMatcher.occurrences(in: said, trigger: VideoVocabulary.start), 0, said)
            XCTAssertEqual(SpeechMatcher.occurrences(in: said, trigger: VideoVocabulary.stop), 0, said)
        }
        XCTAssertEqual(SpeechMatcher.occurrences(in: "hepsini gönder", trigger: VideoVocabulary.send), 0, "PDF gönderme komutuyla karışmaz")
        XCTAssertEqual(SpeechMatcher.occurrences(in: "kapat", trigger: VideoVocabulary.send), 0)
        XCTAssertEqual(SpeechMatcher.occurrences(in: "video kaydını aç", trigger: VideoVocabulary.send), 0)
        XCTAssertFalse(VideoVocabulary.send.lowercased().contains("gemini"), "Gemini çağrı komutuyla karışmasın")
    }

    func testSendModeDefaultsToQueueAndPersists() {
        UserDefaults.standard.removeObject(forKey: "videoSendMode")
        let s = AppSettings()
        XCTAssertEqual(s.videoSendMode, 1, "varsayılan: videoları gönder deyince sırayla")
        s.videoSendMode = 0
        XCTAssertEqual(AppSettings().videoSendMode, 0)
        UserDefaults.standard.removeObject(forKey: "videoSendMode")
    }

    func testDefaultInstructionKeepsReadingFreeAndAddsAnswerOrder() {
        let q = GeminiVideo.defaultInstruction(optionCodes: GeminiConfig.defaultOptionCodes)
        XCTAssertTrue(q.hasPrefix("Videodaki yazıları oku ve analiz et. Soruları çöz ve cevaplarını ver."),
                      "okuma işi kullanıcının sade cümlesidir")
        XCTAssertFalse(q.contains("uydurma"), "Gemini'nin okuma işine ek kural konmaz")
        XCTAssertFalse(q.contains("okunamadı"))
        // Cevap düzeni: soru numarası, şehir adıyla kodlanmış şık, cevap metni; sıralı
        XCTAssertTrue(q.contains("soru numarası, sonra şık, ardından cevap metni"))
        XCTAssertTrue(q.contains("A = ADANA, B = BURSA, C = CEYHAN, D = DENİZLİ, E = ERZURUM"))
        XCTAssertTrue(q.contains("Birinci sorunun cevabı DENİZLİ, altmış sekiz."))
        XCTAssertTrue(q.contains("soru numarasına göre sıralı"))
        XCTAssertTrue(GeminiVideo.system.contains("sesli"), "yalnız çıktı biçimi: sesle okunacak")
        XCTAssertFalse(GeminiVideo.system.contains("uydurma"))
        let object = GeminiVideo.requestObject(video: Data([1]), question: q, highResolution: true)
        let config = object["generationConfig"] as? [String: Any]
        XCTAssertGreaterThanOrEqual(config?["maxOutputTokens"] as? Int ?? 0, 8192, "çok soru: uzun cevap")
    }

    func testAnswerFormatFollowsEditedOptionCodes() {
        let q = GeminiVideo.defaultInstruction(optionCodes: "A=ANKARA, B=BOLU")
        XCTAssertTrue(q.contains("A = ANKARA, B = BOLU"))
        XCTAssertFalse(q.contains("ADANA"), "kodlar ayarlardan gelir, sabit değildir")
        XCTAssertTrue(q.contains("Birinci sorunun cevabı ANKARA, altmış sekiz."), "D yoksa ilk kod örnekte kullanılır")
    }

    func testAnswerFormatWithoutCodesUsesLetters() {
        let q = GeminiVideo.defaultInstruction(optionCodes: "")
        XCTAssertTrue(q.contains("Şık harfini söyle"))
        XCTAssertTrue(q.contains("Birinci sorunun cevabı D, altmış sekiz."))
        XCTAssertTrue(q.contains("sıralı"))
    }
}
