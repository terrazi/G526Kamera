import XCTest
@testable import G526CameraDrive

/// Olumsuz durum incelemesinden çıkan senaryolar (docs/SENARYOLAR.md): cevap kaybı, kayıt yazılamaması, kesinti sırasında bekleyen soru,
/// Gemini'nin biçim sapmaları, tetikleyici varyantları ve art arda oturumlar.
@MainActor
final class ScenarioReviewTests: XCTestCase {
    private typealias T = SessionViewModel.Timing

    private func hasWarning(_ h: SessionHarness, _ id: String) -> Bool {
        return h.vm.warnings.contains { $0.id == id }
    }

    private func warningText(_ h: SessionHarness, _ id: String) -> String {
        return h.vm.warnings.first(where: { $0.id == id })?.text ?? ""
    }

    // MARK: Cevap okunamazsa kaybolmaz

    func testAnswerThatCannotBeSpokenIsReadAgainOnceBeforeMovingOn() async {
        let h = SessionHarness()
        h.answering.results = [.success(FakeAnswering.reply(1))]
        _ = await h.startListening()
        let before = h.speaker.calls.count   // açılıştaki "Ben hazırım" anonsu da sayılır
        h.speaker.script = [SpeakError.failed("Ses çalınamadı.")]   // ilk okuma olmaz, ikincisi olur
        h.ask("Birinci soru")
        let done = await waitUntil { h.vm.phase == .listening && h.speaker.calls.count >= before + 2 }
        XCTAssertTrue(done, "Okuma olmayınca cevap bir kez daha okunur, sonra dinlemeye dönülür")
        let mine = Array(h.speaker.calls.dropFirst(before))
        XCTAssertEqual(mine.count, 2)
        XCTAssertEqual(mine.first?.text, mine.last?.text, "Aynı cevap yeniden okunur")
        XCTAssertNotNil(mine.first?.saveAs)
        XCTAssertNil(mine.last?.saveAs, "Yeniden okuma dosya yazmadan, canlı sesle yapılır")
        XCTAssertNil(h.vm.unheard, "Cevap duyuldu")
        XCTAssertFalse(hasWarning(h, "ses"), "İkinci okuma olunca ses uyarısı silinir")
        XCTAssertFalse(hasWarning(h, "cevap"))
    }

    func testAnswerThatCannotBeSpokenTwiceStaysInTheRedBox() async {
        let h = SessionHarness()
        h.answering.results = [.success(FakeAnswering.reply(7, option: "Bursa", text: "Yönetim"))]
        _ = await h.startListening()
        let before = h.speaker.calls.count
        h.speaker.script = [SpeakError.failed("Ses çalınamadı."), SpeakError.failed("Ses okunamadı.")]
        h.ask("Yedinci soru")
        let done = await waitUntil { h.vm.phase == .listening && h.speaker.calls.count >= before + 2 }
        XCTAssertTrue(done, "İki okuma da olmasa bile oturum takılmaz, dinlemeye döner")
        XCTAssertTrue(warningText(h, "cevap").contains("Soru 7, Bursa, Yönetim"), "Duyulamayan cevap kırmızı kutuda yazılı kalır: \(warningText(h, "cevap"))")
        XCTAssertEqual(h.vm.answers.map { $0.number }, [7], "Cevap listede de kayıtlıdır")
    }

    func testSecondReadingOnAnUnsafeRoutePausesInsteadOfPlaying() async {
        let h = SessionHarness()
        h.answering.results = [.success(FakeAnswering.reply(1))]
        _ = await h.startListening()
        h.speaker.script = [SpeakError.failed("Ses çalınamadı."), SpeakError.routeUnsafe]
        h.ask("Soru")
        let paused = await waitUntil { h.isHardwarePause }
        XCTAssertTrue(paused, "İkinci denemede ses yolu güvensizse (KURAL 1) donanım beklemesine geçilir")
    }

    // MARK: Kayıt yazılamazsa kırmızı kutuda görünür

    func testRecordingThatWasNotWrittenIsReportedAndClearedWhenItWorksAgain() async {
        let h = SessionHarness()
        h.answering.results = [.success(FakeAnswering.reply(1)), .success(FakeAnswering.reply(2))]
        _ = await h.startListening()
        h.speaker.writeFiles = false   // dosya yazılamıyor (yer doldu / klasör erişimi gitti)
        h.ask("Birinci soru")
        var ok = await waitUntil { h.vm.answers.count == 1 && h.vm.phase == .listening }
        XCTAssertTrue(ok)
        XCTAssertTrue(hasWarning(h, "kayit"), "Ses kaydı yazılamadı: kırmızı kutuda")
        XCTAssertTrue(warningText(h, "kayit").contains("Soru 1"))
        XCTAssertTrue(h.vm.announced.contains(Say.recordingFailed(1)), "Kulaklıktan da söylenir")

        h.speaker.writeFiles = true
        h.ask("İkinci soru")
        ok = await waitUntil { h.vm.answers.count == 2 && h.vm.phase == .listening }
        XCTAssertTrue(ok)
        XCTAssertFalse(hasWarning(h, "kayit"), "Kayıt yeniden yazılabilince uyarı silinir")
    }

    func testTranscriptFileThatCannotBeWrittenIsReported() async {
        let h = SessionHarness()
        h.answering.results = [.success(FakeAnswering.reply(1))]
        _ = await h.startListening()
        // cevaplar.txt adında bir KLASÖR açılır: dosyaya yazma imkânsız olur (yer dolması gibi)
        let blocker = h.vm.sessionFolder!.appendingPathComponent(AnswerLibrary.transcriptName)
        try? FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        h.ask("Birinci soru")
        let ok = await waitUntil { h.vm.answers.count == 1 && h.vm.phase == .listening }
        XCTAssertTrue(ok, "Yazı dosyası yazılamasa da cevap okunur ve oturum sürer")
        XCTAssertEqual(warningText(h, "yazi"), Say.transcriptFailed)
        XCTAssertEqual(h.speaker.spoken.last, "Soru 1, Denizli, Örgütsel Davranış", "Cevap yine de okundu")
    }

    // MARK: Kesinti sırasında Gemini bekleyen soru

    func testCallWhileWaitingForGeminiNeverLeavesAStuckQuestion() async {
        let h = SessionHarness()
        h.answering.hold = true
        h.answering.results = [.success(FakeAnswering.reply(1))]
        _ = await h.startListening()
        h.ask("Birinci soru")
        let waiting = await waitUntil { h.vm.phase == .answering }
        XCTAssertTrue(waiting)

        h.route.interrupt(began: true)   // telefon çaldı
        await settle()
        XCTAssertTrue(h.shortcuts.runs.isEmpty, "Kesintide kestirme çalışmaz")
        h.route.interrupt(began: false)
        h.answering.hold = false
        h.answering.release()
        h.scheduler.advance(by: T.routeStable + 0.1)
        let back = await waitUntil { h.vm.phase == .listening }
        XCTAssertTrue(back, "Arama bitince dinlemeye dönülür")
        XCTAssertFalse(h.vm.questions.contains { $0.state == .sending }, "Gönderiliyor işaretiyle takılı kalan soru yok")
        XCTAssertTrue(h.shortcuts.runs.isEmpty)
    }

    func testGeminiThatNeverAnswersIsReleasedByTheUserPause() async {
        let h = SessionHarness()
        h.answering.hold = true
        _ = await h.startListening()
        h.ask("Takılacak soru")
        let waiting = await waitUntil { h.vm.phase == .answering }
        XCTAssertTrue(waiting)
        h.vm.pauseByUser()
        XCTAssertEqual(h.vm.phase, .paused(.manual))
        h.answering.hold = false
        h.answering.results = [.success(FakeAnswering.reply(1))]
        h.answering.release()
        await settle()
        XCTAssertEqual(h.vm.phase, .paused(.manual), "Geç gelen cevap duraklatılmış oturumu bozmaz")
        h.vm.resumeByUser()
        let back = await waitUntil { h.vm.phase == .listening }
        XCTAssertTrue(back)
        XCTAssertFalse(h.vm.questions.contains { $0.state == .sending })
    }

    func testSecondTriggerWhileWaitingForGeminiIsIgnored() async {
        let h = SessionHarness()
        h.answering.hold = true
        _ = await h.startListening()
        h.ask("Birinci soru")
        _ = await waitUntil { h.vm.phase == .answering }
        h.listener.say("Başka bir şey Cevapla")
        h.scheduler.advance(by: T.triggerConfirm + 0.1)
        await settle()
        XCTAssertEqual(h.answering.calls.count, 1, "Cevap beklenirken ikinci soru gitmez")
        h.answering.hold = false
        h.answering.release()
    }

    // MARK: Onarım görevi iptal edilirse oturum takılmaz

    func testRecoveryTaskCancelledBeforeItStartsNeverLeavesTheSessionStuck() async {
        let h = SessionHarness()
        _ = await h.startListening()
        // Dinlerken bir onarım görevi kuyruğa alınır; başlamadan yol gider ve iş iptal edilir
        h.vm.work = Task { [weak vm = h.vm] in await vm?.runRecovery(.hardware, force: true) }
        h.route.change(to: FakeRoute.noHeadphones)
        await settle()
        XCTAssertTrue(h.isHardwarePause, "İptal edilmiş görev aşamayı 'onarılıyor' yapıp takmaz: \(h.vm.phase)")
        h.route.change(to: FakeRoute.good)
        h.scheduler.advance(by: T.routeStable + 0.1)
        let back = await waitUntil { h.vm.phase == .listening }
        XCTAssertTrue(back, "Kulaklık dönünce oturum kendiliğinden devam eder")
    }

    func testCallStartingDuringRecoveryStopsTheRecoveryWithoutRunningShortcuts() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.health.internet = false
        h.shortcuts.outcome = .success
        // Kestirme çalışırken (aşama: onarılıyor) telefon çalar
        h.shortcuts.onRun = { [weak h] _ in h?.route.interrupt(began: true) }
        h.network.set(online: false)
        h.scheduler.advance(by: T.offlineDebounce + 0.1)
        let calledInRecovery = await waitUntil { h.vm.interruptionActive }
        XCTAssertTrue(calledInRecovery, "Onarım sürerken gelen arama kesinti olarak işlenir")
        let runsAtCall = h.shortcuts.runs.count
        await settle()
        XCTAssertEqual(h.shortcuts.runs.count, runsAtCall, "Arama sürerken başka kestirme çalıştırılmaz (uçak modu aramayı keserdi)")
        XCTAssertTrue(h.isHardwarePause)
        h.route.interrupt(began: false)
        h.health.internet = true
        h.network.set(online: true)
        h.scheduler.advance(by: T.routeStable + 0.1)
        let back = await waitUntil { h.vm.phase == .listening }
        XCTAssertTrue(back, "Arama bitince oturum devam eder")
    }

    // MARK: Art arda oturumlar

    func testEndingAndStartingAgainStartsClean() async {
        let h = SessionHarness()
        h.answering.results = [.success(FakeAnswering.reply(1)), .success(FakeAnswering.reply(1))]
        _ = await h.startListening()
        h.ask("Birinci oturum sorusu")
        _ = await waitUntil { h.vm.answers.count == 1 && h.vm.phase == .listening }
        h.vm.endTest()
        await settle()
        XCTAssertNotEqual(h.vm.phase, .listening)
        let again = await h.startListening()
        XCTAssertTrue(again, "İkinci oturum sorunsuz açılır")
        XCTAssertTrue(h.vm.answers.isEmpty, "Önceki oturumun cevapları yeni oturuma karışmaz")
        h.ask("İkinci oturum sorusu")
        let ok = await waitUntil { h.vm.answers.count == 1 && h.vm.phase == .listening }
        XCTAssertTrue(ok)
    }

    // MARK: Gemini cevabının biçim sapmaları

    func testParserHandlesTheFormatsGeminiActuallyUses() {
        let cases: [(raw: String, number: Int?, option: String)] = [
            ("Soru 3, Bursa, Yönetim", 3, "Bursa"),
            ("Soru: 3, Bursa, Yönetim", 3, "Bursa"),
            ("Soru No: 3 - Bursa - Yönetim", 3, "Bursa"),
            ("SORU 12 – Erzurum, Pazarlama", 12, "Erzurum"),
            ("**Soru 4**, Denizli, Finans", 4, "Denizli"),
            ("4) Ceyhan, Muhasebe", 4, "Ceyhan"),
            ("```\nSoru 5, Adana, Maliye\n```", 5, "Adana"),
            ("\n\nSoru 6, Bursa, Halkla İlişkiler\nAçıklama: şundan dolayı", 6, "Bursa"),
            ("Soru 7, D şıkkı, Denizli", 7, "D şıkkı")
        ]
        for item in cases {
            let parsed = AnswerParser.parse(item.raw)
            XCTAssertEqual(parsed.number, item.number, "Numara: \(item.raw)")
            XCTAssertEqual(parsed.option, item.option, "Şık: \(item.raw)")
            XCTAssertFalse(parsed.spoken.isEmpty, "Okunacak cümle boş olmamalı: \(item.raw)")
            XCTAssertFalse(parsed.spoken.contains("*"), "İşaretler okunmaz: \(item.raw)")
        }
    }

    func testUnparseableReplyIsStillSpokenWithTheNumberInFront() {
        let parsed = AnswerParser.parse("Bu soruyu çözemem")
        XCTAssertNil(parsed.number)
        XCTAssertEqual(AnswerParser.spokenLine(number: 9, option: parsed.option, text: parsed.text, fallback: parsed.spoken).hasPrefix("Soru 9"), true)
    }

    // MARK: Tetikleyici varyantları

    func testTriggerWordVariantsTheRecognizerProduces() {
        let fires = ["Soru üç. A Adana. Cevapla", "soru üç cevapla.", "SORU ÜÇ CEVAPLA", "Soru üç, gönder!", "soru üç GÖNDER", "soru üç gonder", "soru üç “Cevapla”", "soru üç Cevapla …"]
        for text in fires {
            let match = TriggerDetector.match(in: text)
            XCTAssertNotNil(match, "Tetiklemeli: \(text)")
            XCTAssertFalse(match?.question.lowercased().contains("cevapla") ?? true, "Tetikleyici sözcük soruya karışmaz: \(text)")
        }
        let silent = ["Soru üç. Cevapla sözcüğünün anlamı nedir", "Cevaplayın", "Gönderilen mektup", "", "   ", "Cevap"]
        for text in silent {
            XCTAssertNil(TriggerDetector.match(in: text), "Tetiklememeli: \(text)")
        }
    }
}
