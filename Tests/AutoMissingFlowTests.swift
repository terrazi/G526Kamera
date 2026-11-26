import XCTest
@testable import G526CameraDrive

/// Otomatik zamanlı başlatmada eksik sorular ve bölümler (kullanıcı kararları 2026-11-26):
/// - Okunamayan soru için kullanıcı ZORLANMAZ: sıradaki yeni soru istenir, eksikler yalnız hatırlatılır; kullanıcı istediği soruyu istediği sırayla
///   gösterebilir ve her cevap kendi numarasına kaydedilir. Sonradan okutulan eksik soru "tamamlandı" diye bildirilir.
/// - Sona gelindiğinde eksik varsa eksikler söylenir ve okutulmaları için süre verilir; sesli komut beklenmez ("kullanıcının mikrofondan talimatı
///   olmayacak"). Süre dolunca bölüm / sınav kendiliğinden tamamlanır.
/// - Bölümlü sınavda soru sayısı bölümlerden alınır (her bölüm 1'den numaralanır); bölüm bitince sormadan sonraki bölüme geçilir.
@MainActor
final class AutoMissingFlowTests: XCTestCase {
    private func series() -> Result<PageSeries, CameraFailure> {
        return .success(PageSeries(shot: FakeCamera.page(1, photos: 75), planned: 75, failure: nil, readable: true))
    }

    private func harness(scans: Int, pageReplies: [[Int]], count: Int = 0, sections: [Int] = []) -> SessionHarness {
        let h = SessionHarness(cameraFlow: true, pageSeries: true)
        h.cameraSettings.autoStart = true
        h.cameraSettings.autoQuestionCount = count
        for (index, questions) in sections.enumerated() {
            h.settings.setSection(index, on: true)
            h.settings.setSectionQuestions(index, questions)
        }
        h.camera.seriesResults = (0..<scans).map { _ in series() }
        var results: [Result<[GeminiReply], Error>] = []
        for numbers in pageReplies {
            let replies: [GeminiReply] = numbers.map { FakeAnswering.reply($0) }
            results.append(.success(replies))
        }
        h.answering.pageResults = results
        h.trackEvents { name in
            if name == "Kameraya_Gec" { h.health.internet = false }
            if name == "Hücresele_Gec" { h.health.internet = true }
            if name == "Hücresel_Ac" { h.health.internet = true }
        }
        return h
    }

    private func waiting(_ h: SessionHarness) -> Bool {
        return h.vm.listenMode == .cameraChoice && h.vm.phase == .listening
    }

    private func sight(_ numbers: Set<Int>) -> QuestionSight {
        return QuestionSight(frames: 3, numbers: numbers, looksLikeQuestion: true, chars: 240)
    }

    /// Kapının bir nabzı: kameraya bir kez bakılır
    private func tick(_ h: SessionHarness) async {
        h.scheduler.advance(by: AutoStart.tick + 0.1)
        await settle()
    }

    /// İlk tarama: başlangıç sorusu görülür, tarama yapılır, cevaplar okunur ve program yeniden bekler
    private func firstScan(_ h: SessionHarness, answers: Int) async {
        _ = await h.startListening()
        // Yavaş bir sınama makinesinde açılış 3 saniyeyi aşabiliyor (CI 26.11.2026: 9 sn sürdü; kapı kurulmadan atılan nabız boşa gitti ve tarama
        // hiç başlamadı). Nabız, program soruyu beklemeye geçince (kapı kurulunca) atılır
        let ready = await waitUntil(45) { self.waiting(h) }
        XCTAssertTrue(ready, "Program soruyu beklemeye geçmedi: \(h.speaker.spoken)")
        h.camera.sights = [sight([1])]
        h.scheduler.advance(by: AutoStart.tick + 0.1)
        let started = await waitUntil(10) { h.camera.seriesCalls.count == 1 }
        XCTAssertTrue(started, "İlk tarama başlamadı: \(h.speaker.spoken)")
        let read = await waitUntil(45) { h.vm.answers.count == answers && self.waiting(h) && h.camera.holding }
        XCTAssertTrue(read, "İlk taramanın cevapları okunmadı: \(h.speaker.spoken)")
    }

    /// Okunmakta olan cevapların hepsi çalınır
    private func finishReading(_ h: SessionHarness, files: Int) async {
        let reading = await waitUntil(45) { h.vm.reviewing }
        XCTAssertTrue(reading, "Cevaplar okunmaya başlamadı: \(h.speaker.spoken)")
        for index in 0..<files {
            h.player.finish()
            if index < files - 1 { h.scheduler.advance(by: 3.1) }
        }
    }

    // MARK: Zorlama yok, yalnız hatırlatma

    func testASkippedQuestionIsOnlyRemindedAndTheNextNewQuestionIsAsked() async {
        let h = harness(scans: 1, pageReplies: [[1, 2, 4]])
        await firstScan(h, answers: 3)
        XCTAssertEqual(h.vm.autoAsked, 5, "3. soru eksik kalsa da sıradaki yeni soru (5) istenir")
        XCTAssertEqual(h.vm.autoMissing, [3])
        XCTAssertEqual(h.speaker.spoken.last, Say.autoGap(seconds: 15, next: 5, missing: [3]), "\(h.speaker.spoken)")
        XCTAssertFalse(h.speaker.spoken.contains { $0.contains("yeniden tarayın") }, "Eksik soru için yeniden tarama istenmez: \(h.speaker.spoken)")
        XCTAssertFalse(h.vm.autoClosing, "Soru sayısı belirtilmedi: son aşama yok")
    }

    func testAMissingQuestionShownLaterIsRecordedAndReportedAsCompleted() async {
        let h = harness(scans: 2, pageReplies: [[1, 2, 4], [3]])
        await firstScan(h, answers: 3)
        // Boşluk doldu; kullanıcı eksik kalan 3. soruyu gösterir (istenen 5. soruydu): tarama yine başlar
        h.clock.offset += Double(AutoStart.gapSeconds - AutoStart.questionCountdown) + 1
        h.camera.sights = [sight([3])]
        h.scheduler.advance(by: AutoStart.tick + 0.1)
        let second = await waitUntil(10) { h.camera.seriesCalls.count == 2 }
        XCTAssertTrue(second, "Eksik soru görülünce tarama başlamadı: \(h.speaker.spoken)")
        let read = await waitUntil(45) { h.vm.answers.count == 4 && self.waiting(h) && h.camera.holding }
        XCTAssertTrue(read, "\(h.speaker.spoken)")
        XCTAssertEqual(h.vm.answers.map { $0.number }, [1, 2, 3, 4], "Cevap kendi numarasına kaydedilir")
        XCTAssertTrue(h.speaker.spoken.contains(Say.autoSeen(number: 3)), "\(h.speaker.spoken)")
        XCTAssertTrue(h.speaker.spoken.contains(Say.autoCompleted([3], remaining: [])), "Eksik sorunun tamamlandığı söylenir: \(h.speaker.spoken)")
        XCTAssertEqual(h.speaker.spoken.last, Say.autoGap(seconds: 15, next: 5), "Eksik kalmadı: hatırlatma yok, sıradaki yeni soru istenir")
        XCTAssertEqual(h.vm.autoMissing, [])
    }

    // MARK: Son aşama

    func testAtTheEndTheMissingQuestionsAreAnnouncedAndTheExamCompletesByItselfWhenTheTimeIsUp() async {
        let h = harness(scans: 1, pageReplies: [[1, 2, 4]], count: 4)
        await firstScan(h, answers: 3)
        XCTAssertEqual(h.speaker.spoken.last, Say.autoClosing(missing: [3], seconds: 120, section: false), "\(h.speaker.spoken)")
        XCTAssertNotNil(h.vm.auto.closingUntil, "Eksikler için süre başladı")
        XCTAssertTrue(h.camera.holding, "Kamera açık bekler")
        // Süre dolmadan tarama kendiliğinden başlamaz (eskiden 45 sn sonra başlardı); cevaplanmış bir soru görülmesi de başlatmaz
        h.clock.offset += 60
        h.camera.sights = [sight([2])]
        await tick(h)
        await tick(h)
        XCTAssertEqual(h.camera.seriesCalls.count, 1, "Son aşamada yalnız cevapsız bir soru taramayı başlatır")
        XCTAssertTrue(waiting(h))
        // Süre doldu: sesli komut beklenmeden sınav tamamlanır
        h.clock.offset += 61
        h.scheduler.advance(by: AutoStart.tick + 0.1)
        await finishReading(h, files: 3)
        XCTAssertTrue(h.speaker.spoken.contains(Say.autoWindowOver(section: false)), "\(h.speaker.spoken)")
        let ended = await waitUntil(45) { h.vm.phase == .finished }
        XCTAssertTrue(ended, "\(h.speaker.spoken)")
        XCTAssertTrue(h.speaker.spoken.contains { $0.hasSuffix(Say.testCompleted(3, missing: [3])) }, "Sonda eksik soru söylenir: \(h.speaker.spoken)")
        XCTAssertFalse(h.settings.finishedExamFolder.isEmpty, "Sınav tamamlandı: bir sonraki \"Başlat\" yeni sınav açar")
        XCTAssertEqual(h.camera.seriesCalls.count, 1)
    }

    func testAMissingQuestionShownInTheClosingStageCompletesTheExam() async {
        let h = harness(scans: 2, pageReplies: [[1, 2, 4], [3]], count: 4)
        await firstScan(h, answers: 3)
        XCTAssertEqual(h.speaker.spoken.last, Say.autoClosing(missing: [3], seconds: 120, section: false), "\(h.speaker.spoken)")
        h.camera.sights = [sight([3])]
        h.scheduler.advance(by: AutoStart.tick + 0.1)
        let second = await waitUntil(10) { h.camera.seriesCalls.count == 2 }
        XCTAssertTrue(second, "Eksik soru gösterilince tarama başlamadı: \(h.speaker.spoken)")
        // Eksik kalmadı: süre beklenmez, cevaplar baştan okunur ve sınav kapanır
        await finishReading(h, files: 4)
        XCTAssertTrue(h.speaker.spoken.contains(Say.autoCompleted([3], remaining: [])), "\(h.speaker.spoken)")
        XCTAssertFalse(h.speaker.spoken.contains(Say.autoWindowOver(section: false)))
        let ended = await waitUntil(45) { h.vm.phase == .finished }
        XCTAssertTrue(ended, "\(h.speaker.spoken)")
        XCTAssertEqual(h.vm.answers.map { $0.number }, [1, 2, 3, 4])
        XCTAssertTrue(h.speaker.spoken.contains { $0.hasSuffix(Say.testCompleted(4)) }, "\(h.speaker.spoken)")
    }

    // MARK: Bölümler

    func testWithSectionsTheSectionCountEndsTheSectionAndTheNextOneStartsWithoutAsking() async {
        // Video kaydındaki sayı (100) bölümlü sınavda kullanılmaz: her bölüm kendi sayısıyla (2) biter
        let h = harness(scans: 2, pageReplies: [[1, 2], [1, 2]], count: 100, sections: [2, 2])
        _ = await h.startListening()
        let ready = await waitUntil(45) { self.waiting(h) }
        XCTAssertTrue(ready, "Program soruyu beklemeye geçmedi: \(h.speaker.spoken)")
        XCTAssertEqual(h.vm.sectionIndex, 1)
        XCTAssertEqual(h.vm.autoQuestionTotal, 2, "Soru sayısı bölümden alınır")
        h.camera.sights = [sight([1])]
        h.scheduler.advance(by: AutoStart.tick + 0.1)
        let started = await waitUntil(10) { h.camera.seriesCalls.count == 1 }
        XCTAssertTrue(started, "\(h.speaker.spoken)")
        // 1. bölümün iki sorusu cevaplandı: bölümün cevapları okunur, sonra sormadan 2. bölüme geçilir
        await finishReading(h, files: 2)
        let next = await waitUntil(45) { h.vm.sectionIndex == 2 && self.waiting(h) && h.camera.holding }
        XCTAssertTrue(next, "2. bölüm başlamadı: \(h.speaker.spoken)")
        XCTAssertTrue(h.speaker.spoken.contains(Say.reviewStartSection(2)), "\(h.speaker.spoken)")
        let moved = Say.reviewReport(count: 2, failed: 0) + " " + Say.sectionCompleted(1, answers: 2, missing: []) + " " + Say.sectionStart(2, questions: 2)
        XCTAssertTrue(h.speaker.spoken.contains(moved), "\(h.speaker.spoken)")
        XCTAssertFalse(h.speaker.spoken.contains { $0.contains("Yeni bir bölüm ile devam") }, "Mikrofondan cevap beklenmez: \(h.speaker.spoken)")
        XCTAssertEqual(h.speaker.spoken.last, Say.autoShow(number: 1), "Yeni bölümün ilk sorusu istenir")
        XCTAssertEqual(h.vm.sessionFolder?.lastPathComponent, "bolum_2")
        XCTAssertTrue(h.vm.answers.isEmpty, "Numara her bölümde 1'den başlar")
        XCTAssertEqual(h.vm.auto.rounds, 0, "Yeni bölümün ilk taraması sınavın başındaki gibi soru görülünce başlar")
        XCTAssertTrue(h.settings.finishedExamFolder.isEmpty, "Sınav sürüyor: tamamlandı diye işaretlenmez")
        XCTAssertNotEqual(h.vm.phase, .finished)

        // 2. bölüm sonuncu: tamamlanınca sınav kapanır
        h.camera.sights = [sight([1])]
        h.scheduler.advance(by: AutoStart.tick + 0.1)
        let second = await waitUntil(10) { h.camera.seriesCalls.count == 2 }
        XCTAssertTrue(second, "\(h.speaker.spoken)")
        await finishReading(h, files: 2)
        let ended = await waitUntil(45) { h.vm.phase == .finished }
        XCTAssertTrue(ended, "\(h.speaker.spoken)")
        XCTAssertTrue(h.speaker.spoken.contains { $0.hasSuffix(Say.testCompletedSections([2, 2], current: 2, missing: [])) }, "\(h.speaker.spoken)")
        XCTAssertFalse(h.settings.finishedExamFolder.isEmpty, "Son bölüm de bitti: sınav tamamlandı")
    }

    func testWithoutSectionsTheCountInTheVideoSettingsIsUsed() async {
        let h = harness(scans: 1, pageReplies: [[1, 2]], count: 2)
        _ = await h.startListening()
        let ready = await waitUntil(45) { self.waiting(h) }
        XCTAssertTrue(ready, "Program soruyu beklemeye geçmedi: \(h.speaker.spoken)")
        XCTAssertEqual(h.vm.autoQuestionTotal, 2)
        h.camera.sights = [sight([1])]
        h.scheduler.advance(by: AutoStart.tick + 0.1)
        let started = await waitUntil(10) { h.camera.seriesCalls.count == 1 }
        XCTAssertTrue(started, "\(h.speaker.spoken)")
        await finishReading(h, files: 2)
        let ended = await waitUntil(45) { h.vm.phase == .finished }
        XCTAssertTrue(ended, "Bütün sorular cevaplanınca sınav eskisi gibi kendiliğinden kapanır: \(h.speaker.spoken)")
        XCTAssertFalse(h.speaker.spoken.contains { $0.hasPrefix("Eksik") }, "\(h.speaker.spoken)")
    }
}
