import XCTest
@testable import G526CameraDrive

// MARK: - Sahte dış dünya

@MainActor
private final class FakePorts: ExamPorts {
    var spoken: [String] = []
    var preflightText = ""
    var pendingList: [String] = []
    var sentFiles: [ExamSentFile] = []
    var holds: [Bool] = []
    var guides: [Bool?] = []
    var guideResets = 0
    var flushCalls = 0
    /// İlk flush'ta gönderilemeyen sayfa sayısı (sonraki flush başarılı)
    var flushLeft = 0
    var released = 0
    var stopped = 0
    var removed: [String] = []
    var docsCalls = 0
    var prepareCalls = 0
    /// Gemini'ye giden istek metinleri
    var asks: [String] = []
    /// Sıradaki isteklerde fırlatılacak hatalar
    var failAsk: [Error] = []
    /// Sıradaki isteklere (hata yoksa) verilecek ham cevaplar
    var rawReplies: [String] = []
    /// Soru numaraları (tek bölüm)
    var questionNos: [Int] = [1, 2, 3, 4, 5]
    var unreadNos: Set<Int> = []
    var unsureNos: Set<Int> = []
    /// Her teyit isteğinde bildirilecek okunamayan sayfa sayıları (bitince 0)
    var unreadPages: [Int] = []
    var fileTime: Double = 1001
    /// İkinci çözümün cevabı: no → (şık, değer, durum); yoksa ilkiyle aynı
    var alt: [Int: (String, String, String)] = [:]
    /// Sıradaki ikinci çözüm isteklerinde fırlatılacak hatalar
    var failRecheck: [Error] = []
    var recheckCalls = 0
    /// klasöre yüklenen cevap anahtarları
    var keys: [(name: String, text: String)] = []
    var keyLink = "https://drive.example/anahtar"
    /// "Dinle": sırayla verilecek kayıtlar (nil = duyulmadı); bitince nil
    var listenResults: [Data?] = []
    var listenCalls = 0
    var listenStops = 0
    /// Gemini'ye doğrudan giden ses kayıtları
    var freeAudio: [Data] = []

    /// Açılış sınaması
    var checkOn = false
    var systemProblem = ""
    var systemChecks = 0
    func selfCheckOn() -> Bool { return checkOn }
    func checkSystem() async -> String {
        systemChecks += 1
        return systemProblem
    }

    /// Video aşaması
    var videoOn = false
    var videoPhaseValue: ExamVideoPhase = .idle
    var videoArms = 0
    var videoStops = 0
    var videoDiscards = 0
    var videoSends = 0
    var videoBegins = 0
    var videoSendError = ""

    func videoEnabled() -> Bool { return videoOn }
    func videoArm() {
        videoArms += 1
        videoPhaseValue = .waiting
    }
    func videoPhase() -> ExamVideoPhase { return videoPhaseValue }
    func videoBegin() {
        videoBegins += 1
        if videoPhaseValue == .found { videoPhaseValue = .recording }
    }
    func videoStop() {
        videoStops += 1
        if videoPhaseValue == .recording { videoPhaseValue = .finished }
    }
    func videoDiscard() {
        videoDiscards += 1
        videoPhaseValue = .idle
    }
    func videoSend() async -> String {
        videoSends += 1
        videoPhaseValue = .idle
        await Task.yield()
        return videoSendError
    }

    func listen() async -> Data? {
        listenCalls += 1
        await Task.yield()
        return listenResults.isEmpty ? nil : listenResults.removeFirst()
    }

    func stopListening() { listenStops += 1 }

    func preflight(needCamera: Bool) -> String { return preflightText }

    func say(_ text: String) async {
        spoken.append(text)
        await Task.yield()
    }

    func stopSpeaking() { stopped += 1 }
    func guide(_ on: Bool?) {
        guides.append(on)
        if on == nil { guideResets += 1 }
    }
    func hold(_ on: Bool) { holds.append(on) }
    func pending() -> [String] { return pendingList }

    func removePending(_ name: String) -> Bool {
        guard let i = pendingList.firstIndex(of: name) else { return false }
        pendingList.remove(at: i)
        removed.append(name)
        return true
    }

    func flush(aborted: () -> Bool) async -> Int {
        flushCalls += 1
        if flushLeft > 0 {
            let left = flushLeft
            flushLeft = 0
            return left
        }
        if !pendingList.isEmpty {
            sentFiles.append(ExamSentFile(id: "f\(sentFiles.count + 1)", name: "tarama\(sentFiles.count + 1).pdf", size: 5000,
                                          photos: pendingList.count, time: fileTime))
            pendingList = []
        }
        return 0
    }

    func canGuide() -> Bool { return true }
    func sendError() -> String { return "internet yok" }
    func sent(since: Double) -> [ExamSentFile] { return sentFiles.filter { $0.time >= since } }

    func docs(for files: [ExamSentFile]) async throws -> (docs: [GeminiDoc], notes: [String]) {
        docsCalls += 1
        let docs = files.map { GeminiDoc(name: $0.name, data: Data("%PDF-1.4".utf8)) }
        return (docs, [])
    }

    func prepare(_ docs: [GeminiDoc]) async throws -> [GeminiDoc] {
        prepareCalls += 1
        return docs
    }

    func codes() -> [(letter: String, word: String)] {
        return [(letter: "A", word: "Ankara"), (letter: "B", word: "Bursa"), (letter: "C", word: "Denizli"), (letter: "D", word: "Edirne")]
    }

    func release() async { released += 1 }

    func saveKey(_ name: String, _ text: String) async -> String {
        keys.append((name: name, text: text))
        return keyLink
    }

    // MARK: Sahte Gemini

    func ask(_ task: ExamTask, docs: [GeminiDoc]) async throws -> String {
        asks.append(task.prompt)
        if let a = task.audio { freeAudio.append(a) }
        let recheck = task.prompt.hasPrefix("Şu soruları SIFIRDAN")
        if recheck {
            recheckCalls += 1
            if !failRecheck.isEmpty { throw failRecheck.removeFirst() }
        } else if !failAsk.isEmpty {
            throw failAsk.removeFirst()
        }
        if !rawReplies.isEmpty { return rawReplies.removeFirst() }
        if task.prompt.hasPrefix("Belgelerdeki") {
            let pages = sentFiles.reduce(0) { $0 + $1.photos }
            let unread = unreadPages.isEmpty ? 0 : unreadPages.removeFirst()
            let obj: [String: Any] = [
                "belgeler": [["belge": "Belge 1", "sayfa": pages, "soru_sayisi": questionNos.count]],
                "sorular": questionNos.map { ["bolum": "", "no": $0] as [String: Any] },
                "okunamayan_sayfa": unread,
                "not": ""
            ]
            return json(obj)
        }
        var out: [[String: Any]] = []
        for line in task.prompt.components(separatedBy: "\n").dropFirst() {
            guard line.hasPrefix("no: "), let n = Int(line.dropFirst(4)) else { continue }
            if recheck, let a = alt[n] {
                out.append(["bolum": "", "no": n, "durum": a.2, "sik": a.0, "deger": a.1, "gerekce": ""])
            } else {
                out.append(FakePorts.answer(n, unread: unreadNos.contains(n), unsure: unsureNos.contains(n) && !recheck))
            }
        }
        return json(["cevaplar": out])
    }

    static func letter(_ n: Int) -> String { return ["A", "B", "C", "D"][n % 4] }

    static func answer(_ n: Int, unread: Bool = false, unsure: Bool = false) -> [String: Any] {
        if unread { return ["bolum": "", "no": n, "durum": "okunamadi", "sik": "", "deger": "", "gerekce": ""] }
        return ["bolum": "", "no": n, "durum": unsure ? "belirsiz" : "tamam", "sik": letter(n), "deger": "\(n * 10) metre",
                "gerekce": "Çünkü \(n) kere on"]
    }

    private func json(_ obj: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Soru n için beklenen okuma cümlesi
    static func line(_ n: Int) -> String {
        let word = ["Ankara", "Bursa", "Denizli", "Edirne"][n % 4]
        return "\(ExamMode.cap(ExamText.ordinal(n))) sorunun cevabı \(word), \(n * 10) metre."
    }
}

private final class Clock {
    var t: Double = 100
}

// MARK: - Sınav akışı

@MainActor
final class ExamModeTests: XCTestCase {
    private func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sinav-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    /// Okuma biter bitmez gelen sesli komutlar bekleme başlamadan yok sayılır; bekleme başlasın diye kısa süre tanır
    private func settle() async {
        try? await Task.sleep(nanoseconds: 80_000_000)
    }

    private func make(_ ports: FakePorts, group: Int = 10, cancel: Int = 0, gap: Int = 0, dir: URL? = nil,
                      uptime: (() -> Double)? = nil, guardSeconds: Double = 0) -> ExamMode {
        let up: () -> Double = uptime ?? { ProcessInfo.processInfo.systemUptime }
        let e = ExamMode(ports: ports, settings: { ExamSettings(group: group, fetch: 20, cancelWindow: cancel, gap: gap) },
                         directory: dir ?? tmpDir(), now: { 1000 }, uptime: up)
        e.echoGuard = guardSeconds
        return e
    }

    private func until(_ timeout: Double = 8, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return cond()
    }

    private func scanPages(_ exam: ExamMode, _ p: FakePorts, _ names: [String]) async {
        let ok = await until { exam.status == "Tarama: 0 sayfa" }
        XCTAssertTrue(ok, "tarama beklemesi başlamadı")
        p.pendingList = names
        for n in names { exam.notePhoto(n) }
    }

    private func finish(_ exam: ExamMode) async {
        exam.command("end", source: "ui")
        let done = await exam.waitDone(timeout: 8)
        XCTAssertTrue(done, "sınav kapanmadı")
    }

    // MARK: "Dinle": her an Gemini ile serbest konuşma

    private func freeReply(_ islem: String, say: String = "", nums: [Int] = []) -> String {
        let obj: [String: Any] = ["anlasilan": "kullanıcı bir şey söyledi", "islem": islem, "numaralar": nums, "cevap": say]
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func reviewed(_ p: FakePorts, group: Int = 10) async -> ExamMode {
        p.questionNos = [1, 2, 3]
        let exam = make(p, group: group)
        XCTAssertTrue(exam.start())
        await scanPages(exam, p, ["a.jpg", "b.jpg"])
        exam.command("scan_done")
        let reached = await until { exam.status == "Soru numarası bekleniyor" }
        XCTAssertTrue(reached, "gözden geçirmeye ulaşılamadı: \(p.spoken)")
        await settle()
        return exam
    }

    func testDinleIsIgnoredWhenNoExamIsRunning() {
        let p = FakePorts()
        let exam = make(p)
        XCTAssertFalse(exam.listenRequest(source: "ui"))
        XCTAssertEqual(p.listenCalls, 0)
    }

    func testDinleSaysListeningRecordsAndSendsTheAudioStraightToGemini() async {
        let p = FakePorts()
        let exam = await reviewed(p)
        let before = p.asks.count
        p.listenResults = [Data(count: 64)]
        p.rawReplies = [freeReply("cevap", say: "Bunun nedeni şudur.")]
        XCTAssertTrue(exam.listenRequest(source: "ui"))
        let spoke = await until { p.spoken.contains("Bunun nedeni şudur.") }
        XCTAssertTrue(spoke, "\(p.spoken.suffix(5))")
        let i = p.spoken.lastIndex(of: "Dinliyorum.") ?? -1
        let j = p.spoken.lastIndex(of: "Bunun nedeni şudur.") ?? -1
        XCTAssertTrue(i >= 0 && j > i, "önce Dinliyorum, sonra cevap: \(p.spoken.suffix(5))")
        XCTAssertEqual(p.listenCalls, 1)
        XCTAssertEqual(p.freeAudio.count, 1)
        XCTAssertEqual(p.freeAudio.first?.count, 64, "ses dosyası olduğu gibi gider (yazıya çevrilmez)")
        XCTAssertEqual(p.asks.count, before + 1)
        XCTAssertTrue(p.asks.last?.hasPrefix("Ekteki ses kaydı") ?? false)
        XCTAssertTrue(p.asks.last?.contains("metre") ?? false, "kayıtlı cevaplar bağlam olarak gider")
        XCTAssertTrue(p.asks.last?.contains("'tamam'") ?? false, "sondaki tamam yok sayılsın")
        await finish(exam)
    }

    func testDinleRepeatsSavedAnswersFromRecord() async {
        let p = FakePorts()
        let exam = await reviewed(p)
        p.listenResults = [Data(count: 64)]
        p.rawReplies = [freeReply("tekrar", nums: [3])]
        let before = p.spoken.filter { $0 == FakePorts.line(3) }.count
        XCTAssertTrue(exam.listenRequest(source: "ui"))
        let spoke = await until { p.spoken.filter { $0 == FakePorts.line(3) }.count > before }
        XCTAssertTrue(spoke, "\(p.spoken.suffix(5))")
        await finish(exam)
    }

    func testDinleCanReadAllAnswers() async {
        let p = FakePorts()
        let exam = await reviewed(p)
        p.listenResults = [Data(count: 64)]
        p.rawReplies = [freeReply("hepsi")]
        let before = p.spoken.filter { $0 == FakePorts.line(2) }.count
        XCTAssertTrue(exam.listenRequest(source: "ui"))
        let spoke = await until { p.spoken.filter { $0 == FakePorts.line(2) }.count > before }
        XCTAssertTrue(spoke, "\(p.spoken.suffix(6))")
        await finish(exam)
    }

    func testDinleNotHeardSaysSoAndAsksNothing() async {
        let p = FakePorts()
        let exam = await reviewed(p)
        let before = p.asks.count
        p.listenResults = [nil]
        XCTAssertTrue(exam.listenRequest(source: "ui"))
        let spoke = await until { p.spoken.contains("Sizi duyamadım. Tekrar denemek için dinle deyin.") }
        XCTAssertTrue(spoke, "\(p.spoken.suffix(4))")
        XCTAssertEqual(p.asks.count, before)
        await finish(exam)
    }

    func testDinleGeminiErrorIsSpokenAndTheExamGoesOn() async {
        let p = FakePorts()
        let exam = await reviewed(p)
        p.listenResults = [Data(count: 64)]
        p.failAsk = [GeminiError("Gemini şu an yanıt vermiyor.", .network)]
        XCTAssertTrue(exam.listenRequest(source: "ui"))
        let spoke = await until { p.spoken.contains("Gemini şu an yanıt vermiyor. Tekrar denemek için dinle deyin.") }
        XCTAssertTrue(spoke, "\(p.spoken.suffix(4))")
        XCTAssertTrue(exam.active)
        await finish(exam)
    }

    func testDinleCanEndTheExam() async {
        let p = FakePorts()
        let exam = await reviewed(p)
        p.listenResults = [Data(count: 64)]
        p.rawReplies = [freeReply("bitir")]
        XCTAssertTrue(exam.listenRequest(source: "ui"))
        let done = await exam.waitDone(timeout: 8)
        XCTAssertTrue(done, "sınav kapanmadı: \(p.spoken.suffix(4))")
        XCTAssertEqual(p.spoken.last, "Deneme sınavı tamamlandı.")
    }

    func testDinleWorksAlreadyDuringScanning() async {
        let p = FakePorts()
        let exam = make(p)
        XCTAssertTrue(exam.start())
        let scanning = await until { exam.status == "Tarama: 0 sayfa" }
        XCTAssertTrue(scanning)
        p.listenResults = [Data(count: 64)]
        p.rawReplies = [freeReply("cevap", say: "Henüz sınav sayfası taranmadı.")]
        XCTAssertTrue(exam.listenRequest(source: "ui"))
        let spoke = await until { p.spoken.contains("Henüz sınav sayfası taranmadı.") }
        XCTAssertTrue(spoke, "\(p.spoken.suffix(4))")
        XCTAssertEqual(p.freeAudio.count, 1)
        await finish(exam)
    }

    func testEndingTheExamStopsTheRecording() async {
        let p = FakePorts()
        let exam = await reviewed(p)
        let before = p.listenStops
        exam.command("end", source: "ui")
        _ = await exam.waitDone(timeout: 8)
        XCTAssertGreaterThan(p.listenStops, before)
    }

    // MARK: Mutlu yol

    func testHappyPathReadsGroupsTwiceThenReviewsFromRecord() async {
        let p = FakePorts()
        p.questionNos = Array(1...5)
        let exam = make(p, group: 2)
        XCTAssertTrue(exam.start())
        await scanPages(exam, p, ["a.jpg", "b.jpg", "c.jpg"])
        XCTAssertTrue(exam.command("scan_done"))
        let reached = await until { exam.status == "Soru numarası bekleniyor" }
        XCTAssertTrue(reached, "gözden geçirmeye ulaşılamadı: \(p.spoken)")

        XCTAssertTrue(p.spoken.contains("Soru sayfalarını sırayla tarayın. Bitince tarama tamamlandı deyin.") ||
                      p.spoken.first?.hasPrefix("Deneme sınavı modu açık.") == true)
        XCTAssertTrue(p.spoken.contains("Gemini belgeleri okuyabildi: 1 belge, 3 sayfa, 5 soru görüyorum."), "\(p.spoken)")
        XCTAssertTrue(p.spoken.contains("3 sayfa klasöre kaydediliyor."))
        XCTAssertEqual(p.flushCalls, 1)
        XCTAssertEqual(p.holds.first, true)
        XCTAssertEqual(p.holds.contains(false), true)

        // her soru iki kez okunur (grup bir kez daha okunur)
        for n in 1...5 {
            XCTAssertEqual(p.spoken.filter { $0 == FakePorts.line(n) }.count, 2, "soru \(n): \(p.spoken)")
        }
        XCTAssertEqual(p.spoken.filter { $0 == "Bu 2 cevabı bir kez daha okuyorum." }.count, 2)
        XCTAssertEqual(p.spoken.filter { $0 == "Bu cevabı bir kez daha okuyorum." }.count, 1)
        XCTAssertEqual(p.spoken.filter { $0 == "Sonraki sorulara geçiyorum." }.count, 2)
        XCTAssertTrue(p.spoken.contains(where: { $0.hasPrefix("Gönderilen 5 sorunun tamamı cevaplandı.") }))
        // yalnız teyit + tek cevap isteği (5 soru tek seferde alındı)
        XCTAssertEqual(p.asks.count, 2)
        XCTAssertEqual(exam.info.questions, 5)
        XCTAssertEqual(exam.info.answered, 5)

        // kayıttan tekrar: Gemini'ye gitmez
        let before = p.spoken.count
        XCTAssertTrue(exam.hear("üçüncü soru"))
        let again = await until { p.spoken.last == "Başka soru var mı?" && p.spoken.count > before }
        XCTAssertTrue(again, "\(p.spoken.suffix(4))")
        XCTAssertTrue(p.spoken.suffix(3).contains(FakePorts.line(3)))
        XCTAssertEqual(p.asks.count, 2)
        await settle()

        // gerekçe istenince
        let before2 = p.spoken.count
        XCTAssertTrue(exam.hear("beşinci soru neden"))
        let why = await until { p.spoken.count > before2 + 1 && p.spoken.last == "Başka soru var mı?" }
        XCTAssertTrue(why)
        await settle()
        XCTAssertTrue(p.spoken.contains(where: { $0.hasPrefix(FakePorts.line(5)) && $0.contains("Gerekçe: Çünkü 5 kere on") }), "\(p.spoken.suffix(4))")

        // tüm cevapları oku
        let before3 = p.spoken.count
        XCTAssertTrue(exam.hear("tüm cevapları oku"))
        let all = await until { p.spoken.count >= before3 + 6 && p.spoken.last == "Başka soru var mı?" }
        XCTAssertTrue(all, "\(p.spoken.suffix(8))")
        XCTAssertEqual(p.asks.count, 2)
        await settle()

        // kapanış
        XCTAssertTrue(exam.hear("sınav tamamlandı"))
        let done = await exam.waitDone(timeout: 8)
        XCTAssertTrue(done)
        XCTAssertEqual(p.spoken.last, "Deneme sınavı tamamlandı.")
        XCTAssertEqual(p.holds.last, false)
        XCTAssertEqual(p.guideResets, 1)
        XCTAssertEqual(p.released, 1)
        XCTAssertNil(exam.savedSummary())
        XCTAssertEqual(exam.lastAnswers()?.answers.count, 5)
    }

    func testTwentyFiveQuestionsAreSpokenInGroupsOfTenWithPrefetch() async {
        let p = FakePorts()
        p.questionNos = Array(1...25)
        let exam = make(p)
        XCTAssertTrue(exam.start())
        await scanPages(exam, p, ["a.jpg"])
        // 1 sayfa taradık ama Gemini 1 sayfa görüyor: sorun yok
        exam.command("scan_done")
        let reached = await until(15) { exam.status == "Soru numarası bekleniyor" }
        XCTAssertTrue(reached, "\(p.spoken.suffix(5))")
        XCTAssertEqual(p.spoken.filter { $0 == "Bu 10 cevabı bir kez daha okuyorum." }.count, 2)
        XCTAssertEqual(p.spoken.filter { $0 == "Bu 5 cevabı bir kez daha okuyorum." }.count, 1)
        XCTAssertEqual(p.spoken.filter { $0 == "Sonraki sorulara geçiyorum." }.count, 2)
        // teyit + ilk 20 soru + arka planda kalan 5 soru
        XCTAssertEqual(p.asks.count, 3, "\(p.asks.map { $0.prefix(20) })")
        XCTAssertTrue(p.asks[1].contains("no: 20"))
        XCTAssertTrue(p.asks[2].contains("no: 21"))
        XCTAssertFalse(p.asks[2].contains("no: 20\n"))
        await finish(exam)
    }

    func testUnreadQuestionIsReportedNotGuessed() async {
        let p = FakePorts()
        p.questionNos = [1, 2, 3]
        p.unreadNos = [2]
        let exam = make(p)
        XCTAssertTrue(exam.start())
        await scanPages(exam, p, ["a.jpg", "b.jpg"])
        exam.command("scan_done")
        let reached = await until { exam.status == "Soru numarası bekleniyor" }
        XCTAssertTrue(reached)
        XCTAssertTrue(p.spoken.contains("İkinci soru okunamadı."), "\(p.spoken)")
        XCTAssertTrue(p.spoken.contains(where: { $0.contains("1 soru okunamadı ya da alınamadı: 2.") }))
        XCTAssertFalse(p.spoken.contains(where: { $0.hasPrefix("İkinci sorunun cevabı") }))
        await finish(exam)
    }

    func testUnsureAnswerSaysSo() async {
        let p = FakePorts()
        p.questionNos = [1]
        p.unsureNos = [1]
        let exam = make(p)
        XCTAssertTrue(exam.start())
        await scanPages(exam, p, ["a.jpg"])
        exam.command("scan_done")
        let reached = await until { exam.status == "Soru numarası bekleniyor" }
        XCTAssertTrue(reached)
        XCTAssertTrue(p.spoken.contains(FakePorts.line(1) + " Emin değilim. İkinci çözümde de aynı çıktı."), "\(p.spoken)")
        await finish(exam)
    }

    // MARK: Tarama, iptal, geri alma

    func testCancelWindowReturnsToScanning() async {
        let p = FakePorts()
        let exam = make(p, cancel: 5)
        XCTAssertTrue(exam.start())
        await scanPages(exam, p, ["a.jpg", "b.jpg"])
        exam.command("scan_done")
        let asked = await until { p.spoken.contains(where: { $0.contains("5 saniye içinde klasöre kaydedilecek") }) }
        XCTAssertTrue(asked, "\(p.spoken)")
        XCTAssertTrue(exam.command("cancel"))
        let back = await until { p.spoken.contains("Gönderim iptal edildi. Taramaya devam edebilirsiniz.") }
        XCTAssertTrue(back)
        XCTAssertEqual(p.flushCalls, 0)
        let scanning = await until { exam.stage == "scan" && exam.status == "Tarama: 2 sayfa" }
        XCTAssertTrue(scanning)
        await finish(exam)
        XCTAssertTrue(p.spoken.last?.contains("Taranan 2 sayfa") == true, "\(p.spoken.last ?? "")")
        XCTAssertEqual(p.flushCalls, 0)
    }

    func testUndoRemovesLastPendingPage() async {
        let p = FakePorts()
        let exam = make(p)
        XCTAssertTrue(exam.start())
        await scanPages(exam, p, ["a.jpg", "b.jpg"])
        exam.command("undo")
        let said = await until { p.spoken.contains("Son sayfa silindi. 1 sayfa kaldı.") }
        XCTAssertTrue(said, "\(p.spoken)")
        XCTAssertEqual(p.removed, ["b.jpg"])
        XCTAssertEqual(p.pendingList, ["a.jpg"])
        await finish(exam)
    }

    func testScanDoneWithoutPagesAsksToScan() async {
        let p = FakePorts()
        let exam = make(p)
        XCTAssertTrue(exam.start())
        let ok = await until { exam.status == "Tarama: 0 sayfa" }
        XCTAssertTrue(ok)
        exam.command("scan_done")
        let said = await until { p.spoken.contains("Henüz tarama yapılmadı. Soru sayfalarını tarayın.") }
        XCTAssertTrue(said, "\(p.spoken)")
        XCTAssertEqual(p.flushCalls, 0)
        await finish(exam)
    }

    func testClosingWhileScanningKeepsPhotosForNormalUpload() async {
        let p = FakePorts()
        let exam = make(p)
        XCTAssertTrue(exam.start())
        await scanPages(exam, p, ["a.jpg"])
        await finish(exam)
        XCTAssertTrue(p.spoken.last?.hasPrefix("Deneme sınavı kapatıldı. Taranan 1 sayfa") == true, "\(p.spoken.last ?? "")")
        XCTAssertEqual(p.holds.last, false)
        XCTAssertEqual(p.released, 1)
        XCTAssertEqual(exam.stage, "idle")
    }

    func testEchoGuardIgnoresVoiceRightAfterOwnSpeech() async {
        let clock = Clock()
        let p = FakePorts()
        let exam = make(p, uptime: { clock.t }, guardSeconds: 1.0)
        XCTAssertTrue(exam.start())
        await scanPages(exam, p, ["a.jpg"])
        XCTAssertFalse(exam.command("scan_done", source: "voice"), "kendi sesimizin yankısı komut sayılmamalı")
        XCTAssertFalse(exam.hear("tarama tamamlandı"))
        clock.t += 5
        XCTAssertTrue(exam.command("scan_done", source: "voice"))
        await finish(exam)
    }

    // MARK: Dışarıdan komutlar

    func testStartIsRefusedWhenPreflightFails() async {
        let p = FakePorts()
        p.preflightText = "Kamera görüntüsü yok. Kameraya bağlanınca tekrar söyleyin."
        let exam = make(p)
        XCTAssertFalse(exam.command("start"))
        let said = await until { p.spoken.contains("Kamera görüntüsü yok. Kameraya bağlanınca tekrar söyleyin.") }
        XCTAssertTrue(said)
        XCTAssertFalse(exam.active)
        XCTAssertEqual(exam.status, "Kamera görüntüsü yok. Kameraya bağlanınca tekrar söyleyin.", "ses çıkmasa da neden ekranda görünmeli")
    }

    func testEndOutsideTheModeIsAnswered() async {
        let p = FakePorts()
        let exam = make(p)
        XCTAssertTrue(exam.command("end"))
        let said = await until { p.spoken.contains("Açık bir deneme sınavı yok.") }
        XCTAssertTrue(said)
        XCTAssertFalse(exam.active)
    }

    func testFreeBittiWithoutScannedPagesIsIgnored() {
        let p = FakePorts()
        let exam = make(p)
        XCTAssertFalse(exam.hear("bitti"))
        XCTAssertFalse(exam.hear("son sayfayı sil"))
        XCTAssertFalse(exam.hear("tarama tamamlandı"))
        XCTAssertFalse(exam.wouldAdopt("tarama tamamlandı"))
    }

    func testStartByVoiceMeaning() async {
        let p = FakePorts()
        let exam = make(p)
        XCTAssertTrue(exam.hear("deneme sınavı modu"))
        XCTAssertTrue(exam.active)
        let ok = await until { exam.status == "Tarama: 0 sayfa" }
        XCTAssertTrue(ok)
        XCTAssertTrue(p.spoken.first?.hasPrefix("Deneme sınavı modu açık.") == true, "\(p.spoken)")
        await finish(exam)
    }

    func testScanDoneOutsideModeAdoptsRecentScans() async {
        let p = FakePorts()
        p.pendingList = ["a.jpg", "b.jpg"]
        p.questionNos = [1, 2]
        let exam = make(p)
        XCTAssertFalse(exam.wouldAdopt("tamamlandı"), "'tara' sözcüğü yoksa sınava alınmaz")
        XCTAssertTrue(exam.wouldAdopt("tarama tamamlandı"))
        XCTAssertTrue(exam.hear("tarama tamamlandı"))
        let reached = await until { exam.status == "Soru numarası bekleniyor" }
        XCTAssertTrue(reached, "\(p.spoken)")
        XCTAssertTrue(p.spoken.contains(where: { $0.hasPrefix("Deneme sınavı modu açıldı. 2 sayfa klasöre kaydediliyor") }), "\(p.spoken)")
        XCTAssertEqual(p.flushCalls, 1)
        XCTAssertEqual(p.docsCalls, 1)
        await finish(exam)
    }

    func testAlreadySentPdfsInLastThirtyMinutesAreAdopted() async {
        let p = FakePorts()
        p.sentFiles = [ExamSentFile(id: "f1", name: "eski.pdf", size: 4000, photos: 3, time: 900)]
        p.questionNos = [1, 2]
        let exam = make(p)
        XCTAssertTrue(exam.wouldAdopt("taramalar tamamlandı"))
        XCTAssertTrue(exam.hear("taramalar tamamlandı"))
        let reached = await until { exam.status == "Soru numarası bekleniyor" }
        XCTAssertTrue(reached, "\(p.spoken)")
        XCTAssertTrue(p.spoken.contains(where: { $0.contains("1 PDF sınava alınıyor.") }), "\(p.spoken)")
        await finish(exam)
    }

    // MARK: Telafi

    func testBadJSONIsRetriedOnceWithoutBlocking() async {
        let p = FakePorts()
        p.questionNos = [1, 2]
        p.rawReplies = ["bu json değil"]
        let exam = make(p)
        XCTAssertTrue(exam.start())
        await scanPages(exam, p, ["a.jpg", "b.jpg"])
        exam.command("scan_done")
        let reached = await until { exam.status == "Soru numarası bekleniyor" }
        XCTAssertTrue(reached, "\(p.spoken)")
        XCTAssertEqual(p.asks.count, 3)           // bozuk + düzgün teyit + cevaplar
        XCTAssertFalse(p.spoken.contains(where: { $0.contains("Sorun giderilince devam deyin") }))
        await finish(exam)
    }

    func testGeminiErrorIsSpokenAndRetriedOnContinue() async {
        let p = FakePorts()
        p.questionNos = [1]
        p.failAsk = [GeminiError("Gemini kotası doldu.", .quota, status: 429)]
        let exam = make(p)
        XCTAssertTrue(exam.start())
        await scanPages(exam, p, ["a.jpg"])
        exam.command("scan_done")
        let blocked = await until { p.spoken.contains(where: { $0.hasPrefix("Gemini kotası doldu.") && $0.contains("Sorun giderilince devam deyin") }) }
        XCTAssertTrue(blocked, "\(p.spoken)")
        XCTAssertTrue(exam.command("continue"))
        let reached = await until { exam.status == "Soru numarası bekleniyor" }
        XCTAssertTrue(reached, "\(p.spoken)")
        XCTAssertTrue(p.spoken.contains(FakePorts.line(1)))
        await finish(exam)
    }

    func testUploadFailureWaitsAndRetries() async {
        let p = FakePorts()
        p.questionNos = [1]
        p.flushLeft = 1
        let exam = make(p)
        XCTAssertTrue(exam.start())
        await scanPages(exam, p, ["a.jpg"])
        exam.command("scan_done")
        let told = await until { p.spoken.contains(where: { $0.hasPrefix("1 sayfa gönderilemedi (internet yok).") }) }
        XCTAssertTrue(told, "\(p.spoken)")
        // "tarama tamamlandı" hemen yeniden dener
        XCTAssertTrue(exam.command("scan_done"))
        let reached = await until { exam.status == "Soru numarası bekleniyor" }
        XCTAssertTrue(reached, "\(p.spoken)")
        XCTAssertEqual(p.flushCalls, 2)
        XCTAssertTrue(p.spoken.contains("Tüm sayfalar klasöre kaydedildi."))
        await finish(exam)
    }

    func testMissingPagesAreReportedAndExtraScanLoopRuns() async {
        let p = FakePorts()
        p.questionNos = [1, 2]
        p.unreadPages = [1]                      // ilk teyitte 1 sayfa okunamadı
        let exam = make(p)
        XCTAssertTrue(exam.start())
        await scanPages(exam, p, ["a.jpg", "b.jpg"])
        exam.command("scan_done")
        let issue = await until { p.spoken.contains(where: { $0.contains("1 sayfa okunamadı.") && $0.contains("taramaya devam deyin") }) }
        XCTAssertTrue(issue, "\(p.spoken)")
        XCTAssertTrue(exam.command("more"))
        let extra = await until { p.spoken.contains(where: { $0.hasPrefix("Eksik ya da okunamayan sayfaları tarayın.") }) }
        XCTAssertTrue(extra, "\(p.spoken)")
        let scanning = await until { exam.status.hasPrefix("Tarama:") }
        XCTAssertTrue(scanning)
        // ek sayfa taranır ve gönderilir
        p.pendingList = ["c.jpg"]
        exam.notePhoto("c.jpg")
        exam.command("scan_done")
        let reached = await until { exam.status == "Soru numarası bekleniyor" }
        XCTAssertTrue(reached, "\(p.spoken)")
        XCTAssertEqual(p.docsCalls, 2, "ek taramadan sonra belgeler yeniden hazırlanmalı")
        XCTAssertTrue(p.spoken.contains(FakePorts.line(1)))
        await finish(exam)
    }

    func testNoQuestionsFoundOffersExtraScan() async {
        let p = FakePorts()
        p.questionNos = []
        let exam = make(p)
        XCTAssertTrue(exam.start())
        await scanPages(exam, p, ["a.jpg"])
        exam.command("scan_done")
        let said = await until { p.spoken.contains(where: { $0.contains("Belgelerde soru bulamadım.") }) }
        XCTAssertTrue(said, "\(p.spoken)")
        XCTAssertTrue(exam.command("more"))
        let scanning = await until { p.spoken.contains(where: { $0.hasPrefix("Eksik ya da okunamayan sayfaları tarayın.") }) }
        XCTAssertTrue(scanning)
        await finish(exam)
    }

    func testInterruptedExamResumesFromSavedAnswerStage() async {
        let dir = tmpDir()
        var s = ExamState()
        s.id = "x"
        s.stage = "answer"
        s.announced = true
        s.scanned = 2
        s.sent = [ExamSentFile(id: "f1", name: "a.pdf", size: 4000, photos: 2, time: 1001)]
        s.questions = [ExamQuestion(bolum: "", no: 1), ExamQuestion(bolum: "", no: 2)]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertNoThrow(try JSONEncoder().encode(s).write(to: dir.appendingPathComponent("sinav.json")))

        let p = FakePorts()
        let exam = make(p, dir: dir)
        XCTAssertNotNil(exam.savedSummary())
        XCTAssertTrue(exam.info.saved)
        XCTAssertTrue(exam.start())
        let asked = await until { p.spoken.contains(where: { $0.hasPrefix("Yarım kalan bir deneme sınavı var: 2 sayfa, 2 soru, 0 cevap.") }) }
        XCTAssertTrue(asked, "\(p.spoken)")
        XCTAssertTrue(exam.command("continue"))
        let reached = await until { exam.status == "Soru numarası bekleniyor" }
        XCTAssertTrue(reached, "\(p.spoken)")
        XCTAssertEqual(p.asks.count, 1, "teyit yeniden yapılmaz, yalnız cevaplar istenir")
        XCTAssertTrue(p.spoken.contains(FakePorts.line(2)))
        XCTAssertEqual(p.docsCalls, 1)
        await finish(exam)
    }

    func testResumeNewDiscardsOldExam() async {
        let dir = tmpDir()
        var s = ExamState()
        s.id = "x"
        s.stage = "answer"
        s.scanned = 4
        s.questions = [ExamQuestion(bolum: "", no: 1)]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertNoThrow(try JSONEncoder().encode(s).write(to: dir.appendingPathComponent("sinav.json")))
        let p = FakePorts()
        let exam = make(p, dir: dir)
        XCTAssertTrue(exam.start())
        let asked = await until { p.spoken.contains(where: { $0.hasPrefix("Yarım kalan bir deneme sınavı var") }) }
        XCTAssertTrue(asked)
        XCTAssertTrue(exam.command("new"))
        let scanning = await until { exam.status == "Tarama: 0 sayfa" }
        XCTAssertTrue(scanning, "\(p.spoken)")
        XCTAssertEqual(exam.info.questions, 0)
        await finish(exam)
    }

    // MARK: İkinci çözüm ("emin değilim")

    func testUnsureQuestionsAreSolvedAgainAndBothAnswersAreSpoken() async {
        let p = FakePorts()
        p.questionNos = Array(1...12)
        p.unsureNos = [3, 7, 11]
        p.alt[3] = ("B", "99", "tamam")             // farklı çıkar
        p.alt[11] = ("", "", "okunamadi")           // ikinci çözüm okunamadı
        // 7: ikinci çözüm ilkiyle aynı
        let exam = make(p)
        XCTAssertTrue(exam.start())
        await scanPages(exam, p, ["a.jpg", "b.jpg", "c.jpg"])
        exam.command("scan_done")
        let reached = await until(15) { exam.status == "Soru numarası bekleniyor" }
        XCTAssertTrue(reached, "\(p.spoken.suffix(4))")
        XCTAssertEqual(p.recheckCalls, 1, "ikinci çözüm yalnız emin olunmayan sorular için, tek istekle yapılır")
        let recheckPrompt = p.asks.first(where: { $0.hasPrefix("Şu soruları SIFIRDAN") }) ?? ""
        XCTAssertTrue(recheckPrompt.contains("no: 3") && recheckPrompt.contains("no: 7") && recheckPrompt.contains("no: 11"))
        XCTAssertFalse(recheckPrompt.contains("no: 4"))
        let l3 = "Üçüncü sorunun cevabı Edirne, 30 metre. Emin değilim. İkinci çözümde cevap Bursa, 99 çıktı."
        XCTAssertEqual(p.spoken.filter { $0 == l3 }.count, 2, "\(p.spoken.filter { $0.contains("Üçüncü") })")
        let l7 = "Yedinci sorunun cevabı Edirne, 70 metre. Emin değilim. İkinci çözümde de aynı çıktı."
        XCTAssertEqual(p.spoken.filter { $0 == l7 }.count, 2, "\(p.spoken.filter { $0.contains("Yedinci") })")
        let l11 = "On birinci sorunun cevabı Edirne, 110 metre. Emin değilim."
        XCTAssertEqual(p.spoken.filter { $0 == l11 }.count, 2, "\(p.spoken.filter { $0.contains("On birinci") })")
        let before = p.asks.count
        await settle()
        XCTAssertTrue(exam.hear("üçüncü soru"))
        let again = await until { p.spoken.filter { $0 == l3 }.count == 3 }
        XCTAssertTrue(again)
        XCTAssertEqual(p.asks.count, before, "kayıttan tekrar Gemini'ye gitmez")
        await finish(exam)
    }

    func testSecondSolveFailureDoesNotStopTheExam() async {
        let p = FakePorts()
        p.questionNos = [1, 2]
        p.unsureNos = [2]
        p.failRecheck = [GeminiError("Kota doldu.", .quota, status: 429)]
        let exam = make(p)
        XCTAssertTrue(exam.start())
        await scanPages(exam, p, ["a.jpg", "b.jpg"])
        exam.command("scan_done")
        let reached = await until { exam.status == "Soru numarası bekleniyor" }
        XCTAssertTrue(reached, "\(p.spoken)")
        XCTAssertTrue(p.spoken.contains("İkinci sorunun cevabı Denizli, 20 metre. Emin değilim."), "\(p.spoken.filter { $0.contains("İkinci") })")
        XCTAssertFalse(p.spoken.contains(where: { $0.contains("Sorun giderilince") }))
        XCTAssertEqual(p.recheckCalls, 1, "başarısız ikinci çözüm bir kez denenir, sonra vazgeçilir")
        await finish(exam)
    }

    // MARK: Açılış sınaması

    func testSelfCheckPassesThenStartsExam() async {
        let p = FakePorts()
        p.checkOn = true
        let exam = make(p)
        XCTAssertTrue(exam.start())
        let asked = await until { self.spoke(p, "Beni duyabiliyor musunuz") }
        XCTAssertTrue(asked, "\(p.spoken)")
        await say(exam, "tamam")
        let ready = await until { exam.status == "Tarama: 0 sayfa" }
        XCTAssertTrue(ready, "\(p.spoken) / \(exam.status)")
        XCTAssertTrue(spoke(p, "Ses, internet ve Gemini hazır."))
        XCTAssertEqual(p.systemChecks, 1)
        await finish(exam)
    }

    func testSelfCheckAsksAgainAndAcceptsSecondReply() async {
        let p = FakePorts()
        p.checkOn = true
        let exam = make(p)
        exam.checkTimeouts = (0.3, 5)
        XCTAssertTrue(exam.start())
        let again = await until { self.spoke(p, "Sizi duyamadım") }
        XCTAssertTrue(again, "\(p.spoken)")
        await say(exam, "tamam")
        let ready = await until { exam.status == "Tarama: 0 sayfa" }
        XCTAssertTrue(ready, "\(p.spoken) / \(exam.status)")
        await finish(exam)
    }

    func testSelfCheckWithoutReplyStopsAndSavesNothing() async {
        let p = FakePorts()
        p.checkOn = true
        let exam = make(p)
        exam.checkTimeouts = (0.2, 0.2)
        XCTAssertTrue(exam.start())
        let done = await exam.waitDone(timeout: 8)
        XCTAssertTrue(done)
        XCTAssertTrue(exam.status.contains("Ses sınaması başarısız"), exam.status)
        XCTAssertTrue(spoke(p, "Ses sınaması başarısız"))
        XCTAssertFalse(spoke(p, "hazır."))
        XCTAssertNil(exam.savedSummary(), "yarım kalan boş sınav kaydedilmemeli")
        XCTAssertFalse(spoke(p, "Deneme sınavı kapatıldı"), "sorun zaten okundu")
    }

    func testSelfCheckReportsInternetOrGeminiProblem() async {
        let p = FakePorts()
        p.checkOn = true
        p.systemProblem = "İnternet yok. Hücresel veriyi kontrol edin."
        let exam = make(p)
        XCTAssertTrue(exam.start())
        _ = await until { self.spoke(p, "Beni duyabiliyor musunuz") }
        await say(exam, "tamam")
        let done = await exam.waitDone(timeout: 8)
        XCTAssertTrue(done)
        XCTAssertEqual(exam.status, "İnternet yok. Hücresel veriyi kontrol edin.")
        XCTAssertTrue(spoke(p, "İnternet yok."))
        XCTAssertFalse(spoke(p, "hazır."))
        XCTAssertNil(exam.savedSummary())
    }

    func testEndingDuringSelfCheckSavesNothing() async {
        let p = FakePorts()
        p.checkOn = true
        let exam = make(p)
        XCTAssertTrue(exam.start())
        _ = await until { self.spoke(p, "Beni duyabiliyor musunuz") }
        await finish(exam)
        XCTAssertNil(exam.savedSummary())
        XCTAssertTrue(spoke(p, "Deneme sınavı kapatıldı."))
    }

    func testSelfCheckIsSkippedWhenResuming() async {
        let p = FakePorts()
        let dir = tmpDir()
        let first = make(p, dir: dir)
        XCTAssertTrue(first.start())
        _ = await until { first.status == "Tarama: 0 sayfa" }
        p.pendingList = ["a.jpg"]
        await finish(first)
        p.checkOn = true
        p.spoken.removeAll()
        let again = make(p, dir: dir)
        XCTAssertTrue(again.start())
        let asked = await until { self.spoke(p, "Yarım kalan bir deneme sınavı var") }
        XCTAssertTrue(asked, "\(p.spoken)")
        XCTAssertFalse(spoke(p, "Beni duyabiliyor musunuz"), "devam eden sınavda yeniden sınanmaz")
        await finish(again)
    }

    // MARK: Program açılınca sınama (A, B)

    func testStartupCheckAsksThenSaysAllGoodAndWaits() async {
        let p = FakePorts()
        p.checkOn = true
        let exam = make(p)
        XCTAssertTrue(exam.startupCheck())
        let asked = await until { self.spoke(p, "Beni duyabiliyor musunuz? Lütfen teyit edin.") }
        XCTAssertTrue(asked, "\(p.spoken)")
        await say(exam, "evet")
        let ready = await until { exam.startupReady }
        XCTAssertTrue(ready, "\(p.spoken) / \(exam.status)")
        XCTAssertTrue(spoke(p, "Her şey tamam, istediğiniz zaman deneme sınavına başlayabiliriz."))
        let closed = await exam.waitDone(timeout: 8)
        XCTAssertTrue(closed, "sınama bitince program beklemeye geçmeli")
        XCTAssertEqual(exam.stage, "idle")
        XCTAssertFalse(p.videoArms > 0, "sınav kendiliğinden başlamaz: video kaydı hazırlanmaz")
        XCTAssertNil(exam.savedSummary(), "sınama sınav kaydı oluşturmaz")
        XCTAssertEqual(p.systemChecks, 1)
    }

    func testStartupCheckIsRememberedSoExamStartDoesNotCheckAgain() async {
        let p = FakePorts()
        p.checkOn = true
        let exam = make(p)
        XCTAssertTrue(exam.startupCheck())
        _ = await until { self.spoke(p, "Beni duyabiliyor musunuz") }
        await say(exam, "tamam")
        _ = await until { exam.startupReady }
        _ = await exam.waitDone(timeout: 8)
        p.spoken.removeAll()
        XCTAssertTrue(exam.start())
        let scanning = await until { exam.status == "Tarama: 0 sayfa" }
        XCTAssertTrue(scanning, "\(p.spoken) / \(exam.status)")
        XCTAssertFalse(spoke(p, "Beni duyabiliyor musunuz"), "açılışta geçen sınama sınav başında yinelenmez")
        XCTAssertEqual(p.systemChecks, 1)
        await finish(exam)
    }

    func testStartupCheckProblemIsReadAndExamStartChecksAgain() async {
        let p = FakePorts()
        p.checkOn = true
        p.systemProblem = "İnternet yok. Hücresel veriyi kontrol edin."
        let exam = make(p)
        XCTAssertTrue(exam.startupCheck())
        _ = await until { self.spoke(p, "Beni duyabiliyor musunuz") }
        await say(exam, "tamam")
        let closed = await exam.waitDone(timeout: 8)
        XCTAssertTrue(closed)
        XCTAssertFalse(exam.startupReady)
        XCTAssertEqual(exam.status, "İnternet yok. Hücresel veriyi kontrol edin.")
        XCTAssertTrue(spoke(p, "İnternet yok."))
        XCTAssertFalse(spoke(p, "Her şey tamam"))
        // Sorun giderildi: sınav başlarken sınama yeniden yapılır
        p.systemProblem = ""
        p.spoken.removeAll()
        XCTAssertTrue(exam.start())
        let again = await until { self.spoke(p, "Beni duyabiliyor musunuz") }
        XCTAssertTrue(again, "sorunlu açılış sınaması sınav başında yinelenmeli: \(p.spoken)")
        await say(exam, "tamam")
        let scanning = await until { exam.status == "Tarama: 0 sayfa" }
        XCTAssertTrue(scanning, "\(p.spoken) / \(exam.status)")
        XCTAssertEqual(p.systemChecks, 2)
        await finish(exam)
    }

    func testStartupCheckRunsOnlyOncePerLaunchAndNotWhenOff() async {
        let off = FakePorts()
        off.checkOn = false
        XCTAssertFalse(make(off).startupCheck(), "ayar kapalıysa açılış sınaması yapılmaz")
        let p = FakePorts()
        p.checkOn = true
        let exam = make(p)
        XCTAssertTrue(exam.startupCheck())
        _ = await until { self.spoke(p, "Beni duyabiliyor musunuz") }
        await say(exam, "tamam")
        _ = await exam.waitDone(timeout: 8)
        XCTAssertFalse(exam.startupCheck(), "bir açılışta bir kez")
        XCTAssertTrue(exam.startupFinished)
    }

    func testPreflightProblemDelaysStartupCheckWithoutCountingItAsDone() async {
        let p = FakePorts()
        p.checkOn = true
        p.preflightText = "Sesli komut kapalı."
        let exam = make(p)
        XCTAssertFalse(exam.startupCheck())
        XCTAssertFalse(exam.startupFinished, "başlamayan sınama yapıldı sayılmaz; yeniden denenebilir")
        p.preflightText = ""
        XCTAssertTrue(exam.startupCheck())
        await finish(exam)
    }

    func testStartDuringStartupCheckWaitsForIt() async {
        let p = FakePorts()
        p.checkOn = true
        let exam = make(p)
        XCTAssertTrue(exam.startupCheck())
        _ = await until { self.spoke(p, "Beni duyabiliyor musunuz") }
        XCTAssertFalse(exam.start())
        let told = await until { self.spoke(p, "Önce hazırlık sınamasını tamamlayalım.") }
        XCTAssertTrue(told, "\(p.spoken)")
        await finish(exam)
    }

    // MARK: Cevap anahtarı

    func testAnswerKeyIsListedAndUploadedWhenTheExamEnds() async {
        let p = FakePorts()
        p.questionNos = [1, 2, 3, 4]
        p.unsureNos = [2]
        p.alt[2] = ("C", "29", "tamam")
        p.unreadNos = [3]
        let exam = make(p)
        XCTAssertTrue(exam.start())
        await scanPages(exam, p, ["a.jpg", "b.jpg"])
        exam.command("scan_done")
        let reached = await until { exam.status == "Soru numarası bekleniyor" }
        XCTAssertTrue(reached, "\(p.spoken)")
        let rows = exam.key
        XCTAssertEqual(rows.map { $0.no }, [1, 2, 3, 4])
        XCTAssertEqual(rows[0].sik, "B")
        XCTAssertEqual(rows[0].word, "Bursa")
        XCTAssertEqual(rows[0].deger, "10 metre")
        XCTAssertEqual(rows[1].durum, ExamStatus.unsure)
        XCTAssertEqual(rows[1].altSik, "C")
        XCTAssertEqual(rows[1].altWord, "Denizli")
        XCTAssertEqual(rows[2].durum, ExamStatus.unread)
        let text = exam.answerKeyText()
        XCTAssertTrue(text.hasPrefix("Deneme sınavı cevap anahtarı\n"), text)
        XCTAssertTrue(text.contains("Soru sayısı: 4 (okunamayan ya da alınamayan: 1)"), text)
        XCTAssertTrue(text.contains("1. soru: B - Bursa, 10 metre"), text)
        XCTAssertTrue(text.contains("2. soru: C - Denizli, 20 metre (emin değil; ikinci çözüm: C - Denizli, 29)"), text)
        XCTAssertTrue(text.contains("3. soru: okunamadı"), text)
        XCTAssertTrue(p.keys.isEmpty, "sınav sürerken klasöre yüklenmez")

        exam.command("end", source: "ui")
        let done = await exam.waitDone(timeout: 8)
        XCTAssertTrue(done)
        XCTAssertEqual(p.spoken.last, "Deneme sınavı tamamlandı.")
        _ = await exam.keyTask?.value
        XCTAssertEqual(p.keys.count, 1)
        XCTAssertTrue(p.keys.first?.name.hasPrefix("Cevap_Anahtari_") == true)
        XCTAssertTrue(p.keys.first?.name.hasSuffix(".txt") == true)
        XCTAssertEqual(p.keys.first?.text, text)
        XCTAssertEqual(exam.keyLink, "https://drive.example/anahtar")
        XCTAssertEqual(exam.key.count, 4, "sınav bittikten sonra da anahtar görünür")
    }

    func testUnfinishedExamDoesNotUploadAKey() async {
        let p = FakePorts()
        let exam = make(p)
        XCTAssertTrue(exam.start())
        await scanPages(exam, p, ["a.jpg"])
        await finish(exam)
        XCTAssertNil(exam.keyTask)
        XCTAssertTrue(p.keys.isEmpty)
        XCTAssertTrue(exam.key.isEmpty)
        XCTAssertEqual(exam.answerKeyText(), "")
    }

    // MARK: Yardımcılar

    func testNormalizeAndFormattingHelpers() {
        XCTAssertEqual(ExamMode.cap("istanbul"), "İstanbul")
        XCTAssertEqual(ExamMode.cap("ısparta"), "Isparta")
        XCTAssertEqual(ExamMode.cap("ankara"), "Ankara")
        XCTAssertEqual(ExamMode.cap(""), "")
        XCTAssertEqual(ExamMode.qkey(" Test 2 ", 7), "Test 2|7")

        let a = ExamMode.normalize(["no": 3, "durum": "Belirsiz", "sik": "b", "deger": "x", "gerekce": " y "])
        XCTAssertEqual(a?.durum, ExamStatus.unsure)
        XCTAssertEqual(a?.sik, "B")
        XCTAssertEqual(a?.gerekce, "y")
        // şık da değer de boşsa "tamam" denmiş olsa bile okunamadı sayılır (tahmin uydurulmaz)
        let b = ExamMode.normalize(["no": 4, "durum": "tamam", "sik": "", "deger": ""])
        XCTAssertEqual(b?.durum, ExamStatus.unread)
        let c = ExamMode.normalize(["no": "5", "durum": "okunamadi", "sik": "C", "deger": "kalmalı"])
        XCTAssertEqual(c?.no, 5)
        XCTAssertEqual(c?.sik, "")
        XCTAssertEqual(c?.deger, "")
        XCTAssertNil(ExamMode.normalize(["durum": "tamam"]))
    }

    func testLoadsStripsCodeFence() {
        XCTAssertNotNil(ExamMode.loads("```json\n{\"a\": 1}\n```"))
        XCTAssertNotNil(ExamMode.loads("  {\"a\": 1}  "))
        XCTAssertNil(ExamMode.loads("[1, 2]"))
        XCTAssertNil(ExamMode.loads("merhaba"))
    }

    func testStateFileRoundTripsAndToleratesMissingFields() throws {
        var s = ExamState()
        s.id = "abc"
        s.stage = "answer"
        s.answers["|1"] = ExamAnswer(bolum: "", no: 1, durum: "tamam", sik: "A", deger: "x", gerekce: "g")
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(ExamState.self, from: data)
        XCTAssertEqual(back.id, "abc")
        XCTAssertEqual(back.answers["|1"]?.sik, "A")
        // ikinci çözüm alanları olmayan eski kayıt okunur
        let legacy = "{\"v\":1,\"id\":\"z\",\"answers\":{\"|1\":{\"bolum\":\"\",\"no\":1,\"durum\":\"tamam\",\"sik\":\"A\",\"deger\":\"x\",\"gerekce\":\"g\"}}}"
        let legacyState = try JSONDecoder().decode(ExamState.self, from: Data(legacy.utf8))
        XCTAssertEqual(legacyState.answers["|1"]?.sik, "A")
        XCTAssertNil(legacyState.answers["|1"]?.alt)
        var withAlt = ExamState()
        withAlt.answers["|2"] = ExamAnswer(bolum: "", no: 2, durum: "belirsiz", sik: "B", deger: "", gerekce: "",
                                           alt: ExamAlt(sik: "C", deger: "5", durum: "tamam"), altTried: true)
        let altBack = try JSONDecoder().decode(ExamState.self, from: try JSONEncoder().encode(withAlt))
        XCTAssertEqual(altBack.answers["|2"]?.alt, ExamAlt(sik: "C", deger: "5", durum: "tamam"))
        XCTAssertEqual(altBack.answers["|2"]?.altTried, true)
        let old = try JSONDecoder().decode(ExamState.self, from: Data("{\"v\":1,\"id\":\"z\"}".utf8))
        XCTAssertEqual(old.id, "z")
        XCTAssertEqual(old.stage, "scan")
        XCTAssertTrue(old.photos.isEmpty)
    }

    // MARK: Video aşaması (sınavın ilk aşaması)

    /// Konuşulan sözü, komut kabul edilene kadar yineleyerek söyler (bekleme penceresi dışında söz yok sayılır)
    private func say(_ exam: ExamMode, _ text: String) async {
        let end = Date().addingTimeInterval(8)
        while Date() < end {
            if exam.hear(text) { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("söz kabul edilmedi: \(text)")
    }

    private func spoke(_ p: FakePorts, _ part: String) -> Bool {
        return p.spoken.contains { $0.contains(part) }
    }

    private func videoExam(_ p: FakePorts) async -> ExamMode {
        p.videoOn = true
        let exam = make(p)
        XCTAssertTrue(exam.start())
        let waiting = await until { exam.status == "Video: evrak bekleniyor" }
        XCTAssertTrue(waiting, "video beklemesi başlamadı: \(p.spoken) / \(exam.status)")
        return exam
    }

    func testStartsWithVideoStageAndSendsAfterStop() async {
        let p = FakePorts()
        let exam = await videoExam(p)
        XCTAssertEqual(p.videoArms, 1)
        XCTAssertTrue(spoke(p, "Önce video çekeceğiz"))
        XCTAssertFalse(p.guides.contains(true), "video aşamasında konumlandırma açılmamalı")
        // Evrak görününce kayıt başlar
        p.videoPhaseValue = .recording
        let rec = await until { exam.status == "Video kaydediliyor" }
        XCTAssertTrue(rec)
        await say(exam, "durdur")
        let ask = await until { exam.status == "Video: devam edilsin mi?" }
        XCTAssertTrue(ask, "devam sorusuna gelinmedi: \(p.spoken)")
        XCTAssertEqual(p.videoStops, 1)
        XCTAssertEqual(p.videoSends, 1)
        XCTAssertTrue(spoke(p, "Video klasöre kaydedildi."))
        XCTAssertTrue(spoke(p, "Videoya devam edeyim mi?"))
        // Hayır: fotoğraf taramasına hazırlanır
        await say(exam, "hayır")
        let scanning = await until { exam.status == "Tarama: 0 sayfa" }
        XCTAssertTrue(scanning, "taramaya geçilmedi: \(exam.status)")
        XCTAssertTrue(spoke(p, "Şimdi fotoğraf taraması"))
        XCTAssertFalse(spoke(p, "Deneme sınavı modu açık. Soru sayfalarını"), "tarama aşaması açılışı yinelenmemeli")
        await finish(exam)
    }

    /// Evrak göründü: kayıt kendiliğinden başlamaz; "Kaydı başlatayım mı?" sorulur, evet denince başlar
    func testFoundDocumentAsksBeforeRecordingAndYesStartsIt() async {
        let p = FakePorts()
        let exam = await videoExam(p)
        p.videoPhaseValue = .found
        let asked = await until { self.spoke(p, "Kaydı başlatayım mı?") }
        XCTAssertTrue(asked, "\(p.spoken)")
        XCTAssertEqual(p.videoBegins, 0, "evet denmeden kayıt başlamaz")
        await say(exam, "evet")
        let began = await until { p.videoBegins == 1 }
        XCTAssertTrue(began)
        let rec = await until { exam.status == "Video kaydediliyor" }
        XCTAssertTrue(rec, exam.status)
        await finish(exam)
    }

    func testNoThenStartRecordingWaitsForTheStartCommand() async {
        let p = FakePorts()
        let exam = await videoExam(p)
        p.videoPhaseValue = .found
        _ = await until { self.spoke(p, "Kaydı başlatayım mı?") }
        await say(exam, "hayır")
        let waiting = await until { self.spoke(p, "Hazır olunca kaydı başlat deyin") }
        XCTAssertTrue(waiting, "\(p.spoken)")
        XCTAssertEqual(p.videoBegins, 0)
        await say(exam, "kaydı başlat")
        let began = await until { p.videoBegins == 1 }
        XCTAssertTrue(began, "\(p.spoken)")
        await finish(exam)
    }

    func testNoThenSkipGoesToPhotoScanningWithoutRecording() async {
        let p = FakePorts()
        let exam = await videoExam(p)
        p.videoPhaseValue = .found
        _ = await until { self.spoke(p, "Kaydı başlatayım mı?") }
        await say(exam, "hayır")
        _ = await until { self.spoke(p, "Hazır olunca kaydı başlat deyin") }
        await say(exam, "atla")
        let scanning = await until { exam.status == "Tarama: 0 sayfa" }
        XCTAssertTrue(scanning, "\(p.spoken) / \(exam.status)")
        XCTAssertEqual(p.videoBegins, 0)
        XCTAssertEqual(p.videoSends, 0)
        await finish(exam)
    }

    func testYesStartsSecondVideoThenAsksAgain() async {
        let p = FakePorts()
        let exam = await videoExam(p)
        p.videoPhaseValue = .recording
        // 30 sn doldu: kayıt kendiliğinden biter
        p.videoPhaseValue = .finished
        let ask = await until { exam.status == "Video: devam edilsin mi?" }
        XCTAssertTrue(ask)
        XCTAssertEqual(p.videoSends, 1)
        XCTAssertEqual(p.videoStops, 0, "süre dolunca durdur çağrılmaz")
        await say(exam, "evet")
        let again = await until { p.videoArms == 2 }
        XCTAssertTrue(again, "ikinci video için hazırlanılmadı")
        XCTAssertTrue(spoke(p, "Yeni video için evrakı kadraja alın"))
        p.videoPhaseValue = .recording
        p.videoPhaseValue = .finished
        let ask2 = await until { p.videoSends == 2 && p.spoken.filter { $0.contains("Videoya devam edeyim mi?") }.count == 2 }
        XCTAssertTrue(ask2, "ikinci videodan sonra yine sorulmadı: \(p.spoken)")
        await say(exam, "hayır")
        let scanning = await until { exam.status == "Tarama: 0 sayfa" }
        XCTAssertTrue(scanning)
        await finish(exam)
    }

    func testDeleteDiscardsWithoutSendingAndStillAsks() async {
        let p = FakePorts()
        let exam = await videoExam(p)
        p.videoPhaseValue = .recording
        let rec = await until { exam.status == "Video kaydediliyor" }
        XCTAssertTrue(rec)
        let before = p.videoDiscards
        await say(exam, "sil")
        let ask = await until { exam.status == "Video: devam edilsin mi?" }
        XCTAssertTrue(ask)
        XCTAssertEqual(p.videoSends, 0, "silinen video gönderilmemeli")
        XCTAssertGreaterThan(p.videoDiscards, before)
        XCTAssertTrue(spoke(p, "Video silindi, gönderilmedi."))
        XCTAssertFalse(spoke(p, "Video klasöre kaydedildi."))
        await say(exam, "hayır")
        let scanning = await until { exam.status == "Tarama: 0 sayfa" }
        XCTAssertTrue(scanning)
        await finish(exam)
    }

    func testSkipGoesStraightToPhotoScanning() async {
        let p = FakePorts()
        let exam = await videoExam(p)
        await say(exam, "atla")
        let scanning = await until { exam.status == "Tarama: 0 sayfa" }
        XCTAssertTrue(scanning)
        XCTAssertEqual(p.videoSends, 0)
        XCTAssertGreaterThan(p.videoDiscards, 0)
        XCTAssertFalse(spoke(p, "Videoya devam edeyim mi?"))
        await finish(exam)
    }

    func testStopBeforeRecordingStartsDoesNotEndVideoStage() async {
        let p = FakePorts()
        let exam = await videoExam(p)
        await say(exam, "durdur")
        let told = await until { self.spoke(p, "Kayıt henüz başlamadı") }
        XCTAssertTrue(told, "kayıt başlamadan durdurulunca açıklama yapılmadı")
        XCTAssertEqual(p.videoSends, 0)
        XCTAssertEqual(exam.status, "Video: evrak bekleniyor")
        await finish(exam)
    }

    func testSendFailureKeepsFileAndStillAsks() async {
        let p = FakePorts()
        p.videoSendError = "internet yok"
        let exam = await videoExam(p)
        p.videoPhaseValue = .recording
        p.videoPhaseValue = .finished
        let ask = await until { exam.status == "Video: devam edilsin mi?" }
        XCTAssertTrue(ask)
        XCTAssertTrue(spoke(p, "Video gönderilemedi. Telefonda saklandı"))
        XCTAssertFalse(spoke(p, "Video klasöre kaydedildi."))
        await say(exam, "hayır")
        let scanning = await until { exam.status == "Tarama: 0 sayfa" }
        XCTAssertTrue(scanning)
        await finish(exam)
    }

    func testRecordingFailureIsReportedAndAsks() async {
        let p = FakePorts()
        let exam = await videoExam(p)
        p.videoPhaseValue = .failed("kameradan görüntü gelmedi")
        let ask = await until { exam.status == "Video: devam edilsin mi?" }
        XCTAssertTrue(ask)
        XCTAssertTrue(spoke(p, "Video kaydedilemedi: kameradan görüntü gelmedi"))
        XCTAssertEqual(p.videoSends, 0)
        await say(exam, "hayır")
        let scanning = await until { exam.status == "Tarama: 0 sayfa" }
        XCTAssertTrue(scanning)
        await finish(exam)
    }

    func testEndingExamDuringVideoDiscardsRecording() async {
        let p = FakePorts()
        let exam = await videoExam(p)
        p.videoPhaseValue = .recording
        let before = p.videoDiscards
        await finish(exam)
        XCTAssertGreaterThan(p.videoDiscards, before, "sınav kapanınca kayıt silinmeli")
        XCTAssertEqual(p.videoSends, 0)
    }

    func testSpokenExamEndWordsDuringVideoEndExamNotRecording() async {
        let p = FakePorts()
        let exam = await videoExam(p)
        p.videoPhaseValue = .recording
        await say(exam, "sınavı kapat")
        let done = await exam.waitDone(timeout: 8)
        XCTAssertTrue(done, "sınav kapanmadı")
        XCTAssertEqual(p.videoSends, 0)
        XCTAssertEqual(p.videoStops, 0, "\"sınavı kapat\" videoyu durdurmak değil sınavı kapatmaktır")
    }

    func testWithoutVideoSettingExamStartsWithPhotoScanning() async {
        let p = FakePorts()
        p.videoOn = false
        let exam = make(p)
        XCTAssertTrue(exam.start())
        let scanning = await until { exam.status == "Tarama: 0 sayfa" }
        XCTAssertTrue(scanning)
        XCTAssertEqual(p.videoArms, 0)
        XCTAssertTrue(spoke(p, "Deneme sınavı modu açık. Soru sayfalarını"))
        await finish(exam)
    }
}
