import XCTest
@testable import G526CameraDrive

/// Derin inceleme turu: duyulmayan cevabın yeniden okunurken ses dosyasının kaybolmaması, ortak paragrafın beklenmedik kapanmadan sağ çıkması,
/// çok uzun paragraf sesinin eksik başının Gemini'ye bildirilmesi.
@MainActor
final class DeepReviewTests: XCTestCase {
    private typealias Timing = SessionViewModel.Timing

    private func harness() -> SessionHarness {
        let h = SessionHarness()
        h.settings.askMissingNumber = false
        h.settings.spokenProgress = false
        h.settings.smartResume = false
        return h
    }

    private func say(_ h: SessionHarness, _ text: String) {
        h.listener.say(text)
        h.scheduler.advance(by: Timing.triggerConfirm + 0.1)
    }

    private func savePassage(_ h: SessionHarness, targets: String = "beş yedi") async {
        say(h, "Ortak paragraf Ali eve gitti. Sonra okula yürüdü Tamamlandı")
        let asked = await waitUntil { h.vm.phase == .listening && h.vm.listenMode == .passageTargets }
        XCTAssertTrue(asked)
        say(h, targets + " Cevapla")
        let saved = await waitUntil { h.vm.phase == .listening && h.vm.listenMode == .question && h.vm.passage != nil }
        XCTAssertTrue(saved)
    }

    private func hasWarning(_ h: SessionHarness, _ id: String) -> Bool {
        return h.vm.warnings.contains { $0.id == id }
    }

    private func recordingNames(_ h: SessionHarness) -> [String] {
        guard let folder = h.vm.sessionFolder else { return [] }
        return h.vm.deps.library.answerFiles(in: folder).map { $0.lastPathComponent }
    }

    // MARK: Duyulmayan cevap yeniden okunurken ses dosyası

    func testUnheardAnswerIsSavedAsFileWhenTheFirstReadingLeftNone() async {
        let h = harness()
        h.answering.results = [.success(FakeAnswering.reply(1))]
        h.speaker.script = [nil, SpeakError.routeUnsafe, nil]   // anons tamam, cevap okunurken yol güvensiz (dosya yok), sonra tamam
        _ = await h.startListening()
        h.ask("Bir soru")
        let paused = await waitUntil { h.isHardwarePause }
        XCTAssertTrue(paused)
        XCTAssertEqual(recordingNames(h), [], "Okuma yarıda kesildi: dosya yazılmadı")

        h.route.change(to: FakeRoute.good)
        h.scheduler.advance(by: Timing.routeStable + 0.1)
        let listening = await waitUntil { h.vm.phase == .listening }
        XCTAssertTrue(listening)
        let answer = FakeAnswering.reply(1).spoken
        let saves = h.speaker.calls.filter { $0.text == answer }.map { $0.saveAs?.lastPathComponent }
        XCTAssertEqual(saves, ["soru_1", "soru_1"], "Yeniden okuma da soru_1 dosyasını yazar: test sonu tekrarı bu cevabı atlamasın")
        XCTAssertEqual(recordingNames(h), ["soru_1.m4a"])
        XCTAssertFalse(hasWarning(h, "kayit"))
        XCTAssertNil(h.vm.unheard)
    }

    func testUnheardAnswerDoesNotOverwriteAFileThatSurvived() async {
        let h = harness()
        h.answering.results = [.success(FakeAnswering.reply(1))]
        h.speaker.script = [nil, SpeakError.routeUnsafe, nil]
        _ = await h.startListening()
        h.ask("Bir soru")
        let paused = await waitUntil { h.isHardwarePause }
        XCTAssertTrue(paused)
        // Kesinti çalma sırasında olduysa dosya tamdır ve durur
        if let folder = h.vm.sessionFolder {
            try? Data([7]).write(to: folder.appendingPathComponent("soru_1.m4a"))
        }
        h.route.change(to: FakeRoute.good)
        h.scheduler.advance(by: Timing.routeStable + 0.1)
        let listening = await waitUntil { h.vm.phase == .listening }
        XCTAssertTrue(listening)
        let answer = FakeAnswering.reply(1).spoken
        let saves = h.speaker.calls.filter { $0.text == answer }.map { $0.saveAs?.lastPathComponent }
        XCTAssertEqual(saves, ["soru_1", nil], "Var olan dosyanın üzerine yazılmaz")
    }

    func testRetryAfterFailedReadingWarnsWhenTheRecordingIsMissing() async {
        let h = harness()
        h.answering.results = [.success(FakeAnswering.reply(1))]
        _ = await h.startListening()
        h.speaker.script = [SpeakError.failed("Ses çalınamadı.")]   // ilk okuma olmaz (dosya yok), yeniden okuma dosyasız yapılır
        h.ask("Birinci soru")
        let done = await waitUntil { h.vm.phase == .listening && h.vm.unheard == nil && !h.vm.answers.isEmpty }
        XCTAssertTrue(done)
        XCTAssertTrue(hasWarning(h, "kayit"), "Yeniden okuma dosya yazmaz: eksik kayıt kırmızı kutuda görünür")
    }

    // MARK: Ortak paragraf beklenmedik kapanmadan sağ çıkar

    func testPassageIsKeptInTheJournalAndDroppedWhenAllAreAnswered() async {
        let h = harness()
        _ = await h.startListening()
        await savePassage(h)
        XCTAssertEqual(h.journal.passage?.remaining, [5, 7])
        XCTAssertEqual(h.journal.passage?.text, "Ali eve gitti. Sonra okula yürüdü")

        h.answering.results = [.success(FakeAnswering.reply(5)), .success(FakeAnswering.reply(7))]
        h.ask("Soru 5 ilk soru")
        var back = await waitUntil { h.speaker.spoken.last == FakeAnswering.reply(5).spoken && h.vm.phase == .listening }
        XCTAssertTrue(back)
        XCTAssertEqual(h.journal.passage?.remaining, [7], "Cevaplanan soru defterdeki paragraftan da düşer")
        h.ask("Soru 7 son soru")
        back = await waitUntil { h.speaker.spoken.last == FakeAnswering.reply(7).spoken && h.vm.phase == .listening }
        XCTAssertTrue(back)
        XCTAssertNil(h.journal.passage, "Hepsi cevaplanınca paragraf defterden silinir")
    }

    func testEndingTheTestClearsThePassageFromTheJournal() async {
        let h = harness()
        _ = await h.startListening()
        await savePassage(h)
        XCTAssertNotNil(h.journal.passage)
        h.vm.endTest()
        let ended = await waitUntil { h.vm.phase == .finished || h.vm.phase == .idle }
        XCTAssertTrue(ended)
        XCTAssertNil(h.journal.passage)
    }

    func testRelaunchRestoresThePassageAsTextAndSaysSo() async {
        let h = harness()
        var run = RunStart(exit: .unexpected(cause: "deneme"), pending: nil, nextNumber: 5, folder: nil, downSeconds: 10, loop: false)
        run.passage = SavedPassage(text: "Ali eve gitti. Sonra okula yürüdü", english: "", all: [5, 6, 7], remaining: [5, 7])
        h.journal.start = run
        h.vm.launched()
        let listening = await waitUntil { h.vm.phase == .listening }
        XCTAssertTrue(listening)
        XCTAssertEqual(h.vm.passage?.remaining, [5, 7])
        XCTAssertEqual(h.vm.passage?.all, [5, 6, 7])
        XCTAssertNil(h.vm.passage?.audio, "Ses kaydı kapanmayla kayboldu; yalnız metin geri gelir")
        XCTAssertTrue(h.speaker.spoken.contains { $0.contains(Say.resumedPassage([5, 7])) }, "Kullanıcıya paragrafın korunduğu söylenir: \(h.speaker.spoken)")
        XCTAssertEqual(h.journal.passage?.remaining, [5, 7], "Defterde durur: yeniden kapanırsa yine geri gelir")

        h.answering.results = [.success(FakeAnswering.reply(5))]
        h.ask("Soru 5 ilk soru")
        let sent = await waitUntil { h.answering.calls.count == 1 }
        XCTAssertTrue(sent)
        XCTAssertTrue(h.answering.calls[0].question.contains("Ali eve gitti. Sonra okula yürüdü"), "Sonraki soru paragrafla gider")
    }

    func testRelaunchWithoutPassageSaysNothingAboutIt() async {
        let h = harness()
        h.journal.start = RunStart(exit: .unexpected(cause: "deneme"), pending: nil, nextNumber: 2, folder: nil, downSeconds: 10, loop: false)
        h.vm.launched()
        let listening = await waitUntil { h.vm.phase == .listening }
        XCTAssertTrue(listening)
        XCTAssertNil(h.vm.passage)
        XCTAssertFalse(h.speaker.spoken.contains { $0.contains("Ortak paragraf yazı olarak korundu") })
    }

    func testSavedPassageSurvivesAJournalRoundTrip() {
        let suite = "g526.deepreview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let journal = RunJournal(defaults: defaults, previousLog: [], clipboard: ClipboardFlag(defaults: defaults, write: { _ in }, changeCount: { 0 }))
        let saved = SavedPassage(text: "Paragraf", english: "Paragraph", all: [1, 2], remaining: [2])
        journal.savePassage(saved)
        XCTAssertEqual(journal.beginRun().passage, saved)
        journal.savePassage(nil)
        XCTAssertNil(journal.beginRun().passage)
    }

    // MARK: Çok uzun paragraf sesi

    func testTruncatedPassageAudioIsReportedToGemini() async {
        let h = harness()
        h.recorder.data = PCMRecorder.wav(samples: [1, 2, 3], sampleRate: 16_000)
        h.recorder.truncated = true
        _ = await h.startListening()
        await savePassage(h, targets: "yedi")
        XCTAssertEqual(h.vm.passage?.audioTruncated, true)
        h.recorder.truncated = false
        h.recorder.data = PCMRecorder.wav(samples: [9, 8], sampleRate: 16_000)
        h.answering.results = [.success(FakeAnswering.reply(7))]
        h.ask("Soru 7 bir soru")
        let sent = await waitUntil { h.answering.calls.count == 1 }
        XCTAssertTrue(sent)
        XCTAssertTrue(h.answering.calls[0].question.contains("ilk bölümü yok"), "Gemini paragraf sesinin başının eksik olduğunu bilir")
    }

    func testIntactPassageAudioHasNoTruncationNote() async {
        let h = harness()
        h.recorder.data = PCMRecorder.wav(samples: [1, 2, 3], sampleRate: 16_000)
        _ = await h.startListening()
        await savePassage(h, targets: "yedi")
        h.recorder.data = PCMRecorder.wav(samples: [9, 8], sampleRate: 16_000)
        h.answering.results = [.success(FakeAnswering.reply(7))]
        h.ask("Soru 7 bir soru")
        let sent = await waitUntil { h.answering.calls.count == 1 }
        XCTAssertTrue(sent)
        XCTAssertFalse(h.answering.calls[0].question.contains("ilk bölümü yok"))
    }

    func testRecorderMarksTruncationOnlyAfterDroppingAudioAndClearsItOnReset() {
        let recorder = PCMRecorder()
        XCTAssertFalse(recorder.truncated)
        let second = [Int16](repeating: 1, count: Int(PCMRecorder.sampleRate))
        for _ in 0..<Int(PCMRecorder.maxSeconds) { recorder.append(samples: second) }
        XCTAssertFalse(recorder.truncated, "Sınıra gelindi ama henüz bir şey atılmadı")
        for _ in 0..<12 { recorder.append(samples: second) }
        XCTAssertTrue(recorder.truncated, "Sınırın 10 sn fazlası dolunca en eski ses atılır")
        XCTAssertLessThanOrEqual(recorder.duration, PCMRecorder.maxSeconds + 1)
        recorder.reset()
        XCTAssertFalse(recorder.truncated)
    }
}
