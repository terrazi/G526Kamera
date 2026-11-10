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
    /// Drive'a yüklenen cevap anahtarları
    var keys: [(name: String, text: String)] = []
    var keyLink = "https://drive.example/anahtar"

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
        XCTAssertTrue(p.spoken.contains("3 sayfa Drive'a gönderiliyor."))
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
        let asked = await until { p.spoken.contains(where: { $0.contains("5 saniye içinde Drive'a gönderilecek") }) }
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
        XCTAssertTrue(p.spoken.contains(where: { $0.hasPrefix("Deneme sınavı modu açıldı. 2 sayfa Drive'a gönderiliyor") }), "\(p.spoken)")
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
        XCTAssertTrue(p.spoken.contains("Tüm sayfalar Drive'a gönderildi."))
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
        XCTAssertTrue(p.keys.isEmpty, "sınav sürerken Drive'a yüklenmez")

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
}
