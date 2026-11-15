import XCTest
@testable import G526CameraDrive

/// Sürüm 4: ortak paragrafın kamerayla çekimi. Seste olduğu gibi: "Ortak paragraf" denir, program "kamera ile çekmek ister misiniz?" diye sorar,
/// evet denirse paragraf okunmaz (5 sn video + fotoğraf olarak çekilir), "hangi sorular için?" sorulur, numaralar söylenir ve görüntüler o
/// numaralı her soruyla birlikte (sesle okunan ya da kamerayla çekilen) Gemini'ye gider.
@MainActor
final class CameraPassageTests: XCTestCase {
    typealias T = SessionViewModel.Timing

    /// Kameraya geçince internet gider, "Hücresele Geç" kestirmesi interneti getirir
    private func harness(shots: [Result<CapturedQuestion, CameraFailure>], replies: [Result<GeminiReply, Error>] = []) -> SessionHarness {
        let h = SessionHarness(cameraFlow: true)
        h.camera.results = shots
        h.answering.results = replies
        h.trackEvents { name in
            if name == "Kameraya_Gec" { h.health.internet = false }
            if name == "Hücresele_Gec" { h.health.internet = true }
            if name == "Hücresel_Ac" { h.health.internet = true }
        }
        return h
    }

    private func reply(_ h: SessionHarness, _ text: String) {
        h.listener.say(text)
        h.scheduler.advance(by: T.numberConfirm + 0.1)
    }

    private func cameraQuestionOpen(_ h: SessionHarness) -> Bool {
        return h.vm.listenMode == .cameraChoice && h.vm.phase == .listening
    }

    /// Paragraf fotoğrafı soru fotoğrafından ayırt edilsin diye farklı baytlarla
    private func passageShot() -> CapturedQuestion {
        var shot = FakeCamera.shot()
        shot.photo = Data([9, 9, 9])
        return shot
    }

    /// Kamera sorusunda "ortak paragraf" der, "evet" der; çekim biter ve program "hangi sorular için" diye sorana kadar bekler
    private func takePassageByCamera(_ h: SessionHarness) async -> Bool {
        reply(h, "ortak paragraf")
        guard await waitUntil(45, { h.vm.listenMode == .passageCameraChoice && h.vm.phase == .listening }) else { return false }
        reply(h, "evet")
        return await waitUntil(45) { h.vm.listenMode == .passageTargets && h.vm.phase == .listening }
    }

    private func sayTargets(_ h: SessionHarness, _ text: String) {
        h.listener.say(text)
        h.scheduler.advance(by: T.triggerConfirm + 0.1)
    }

    // MARK: Soru ve akış

    /// Hata: kamera sorusuna doğrudan "Ortak paragraf" denince program bunu anlamıyor, "Anlayamadım" diyordu
    func testSayingOrtakParagrafAtTheCameraQuestionAsksWhetherToUseTheCamera() async {
        let h = harness(shots: [])
        _ = await h.startListening()
        reply(h, "ortak paragraf")
        let asked = await waitUntil(45) { h.speaker.spoken.last == Say.askPassageCamera && h.vm.listenMode == .passageCameraChoice && h.vm.phase == .listening }
        XCTAssertTrue(asked, "Kamera sorusunda 'ortak paragraf' denince kamerayla mı sesle mi sorulur: \(h.speaker.spoken)")
        XCTAssertFalse(h.speaker.spoken.contains(Say.askCameraAgain), "'Anlayamadım' denmez")
        XCTAssertEqual(h.camera.captures, 0)
        XCTAssertTrue(h.shortcuts.runs.isEmpty, "Sorulmadan hiçbir bağlantı değişmez")
    }

    func testPassageByCameraAsksWhichQuestionsThenKeepsTheImagesForThem() async {
        let shot = passageShot()
        let h = harness(shots: [.success(shot)])
        _ = await h.startListening()
        let asked = await takePassageByCamera(h)
        XCTAssertTrue(asked, "Çekimden sonra hangi sorular için olduğu sorulur: \(h.speaker.spoken)")
        XCTAssertEqual(h.camera.subjects, [.passage], "Kamera paragraf için açıldı")
        XCTAssertEqual(h.events, ["kestirme:Kameraya_Gec", "çekim", "kestirme:Hücresele_Gec"], "Soruyla aynı bağlantı düzeni: kameraya geç, çek, internete dön")
        XCTAssertTrue(h.speaker.spoken.contains(Say.passageCameraConnecting), "Kameraya geçerken bilgi verilir")
        XCTAssertTrue(h.speaker.spoken.contains(Say.passageCaptured), "Çekim başarılı: 'video ve fotoğraf çekimi başarıyla yapıldı' denir")
        XCTAssertEqual(h.speaker.spoken.last, Say.passageTakenCamera, "İnternet gelince hangi sorular için olduğu sorulur")
        XCTAssertTrue(h.answering.captureCalls.isEmpty && h.answering.calls.isEmpty, "Paragraf tek başına Gemini'ye gitmez")
        XCTAssertNotNil(h.vm.passageDraft?.shot)

        sayTargets(h, "beş altı yedi Tamam")
        let kept = await waitUntil(45) { h.vm.passage?.all == [5, 6, 7] && self.cameraQuestionOpen(h) }
        XCTAssertTrue(kept, "Paragraf kaydedilir ve bu soru için kamera yeniden sorulur: \(h.speaker.spoken)")
        XCTAssertEqual(h.vm.passage?.viaCamera, true)
        XCTAssertNil(h.vm.passageDraft)
        XCTAssertTrue(h.speaker.spoken.contains(Say.passageReady([5, 6, 7], cameraNext: true)))
        XCTAssertEqual(h.speaker.spoken.last, Say.askCamera)
        XCTAssertTrue(FileManager.default.fileExists(atPath: shot.video!.path), "Paragrafın videosu soruları bitene kadar telefonda durur")
        XCTAssertEqual(h.vm.statusNote, "")
    }

    /// Hayır: paragraf V3'teki gibi sesle okunur
    func testDecliningTheCameraForThePassageReadsItAloudAsBefore() async {
        let h = harness(shots: [])
        _ = await h.startListening()
        reply(h, "ortak paragraf")
        _ = await waitUntil(45) { h.vm.listenMode == .passageCameraChoice && h.vm.phase == .listening }
        reply(h, "hayır")
        let reading = await waitUntil(45) { h.speaker.spoken.last == Say.passageCameraDeclined && h.vm.listenMode == .passage && h.vm.phase == .listening }
        XCTAssertTrue(reading)
        h.listener.say("Ali eve gitti. Sonra okula yürüdü Tamam")
        h.scheduler.advance(by: T.numberConfirm + 0.1)
        let targets = await waitUntil(45) { h.vm.listenMode == .passageTargets && h.vm.phase == .listening }
        XCTAssertTrue(targets)
        sayTargets(h, "beş altı Tamam")
        let kept = await waitUntil(45) { h.vm.passage?.all == [5, 6] && self.cameraQuestionOpen(h) }
        XCTAssertTrue(kept)
        XCTAssertEqual(h.vm.passage?.viaCamera, false)
        XCTAssertTrue(h.vm.passage?.text.contains("Ali eve gitti") ?? false)
        XCTAssertEqual(h.camera.captures, 0)
        XCTAssertTrue(h.shortcuts.runs.isEmpty, "Sesle okunan paragraf hiçbir bağlantıyı değiştirmez")
    }

    /// Kamera yapılandırılmamışsa V3'teki gibi doğrudan okutulur (ek soru yok)
    func testWithoutACameraSetupThePassageIsReadAloudDirectly() async {
        let h = SessionHarness()
        _ = await h.startListening()
        h.listener.say("ortak paragraf")
        h.scheduler.advance(by: T.numberConfirm + 0.1)
        let prompt = await waitUntil(45) { h.speaker.spoken.last == Say.passagePrompt && h.vm.listenMode == .passage }
        XCTAssertTrue(prompt)
        XCTAssertFalse(h.speaker.spoken.contains(Say.askPassageCamera))
    }

    /// Kamerayla soru çekilince paragrafın görüntüleri de gider; cevaplanan numara paragrafın listesinden düşer
    func testACameraQuestionGoesWithTheCameraPassageAndTheAnsweredNumberLeavesTheList() async {
        let p = passageShot()
        let q = FakeCamera.shot()
        let h = harness(shots: [.success(p), .success(q)], replies: [.success(FakeAnswering.reply(5))])
        h.settings.spokenProgress = true
        _ = await h.startListening()
        _ = await takePassageByCamera(h)
        sayTargets(h, "beş altı yedi Tamam")
        _ = await waitUntil(45) { h.vm.passage?.all == [5, 6, 7] && self.cameraQuestionOpen(h) }
        reply(h, "evet")
        let done = await waitUntil(45) { h.vm.answers.count == 1 && self.cameraQuestionOpen(h) }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        let call = h.answering.captureCalls.first
        XCTAssertEqual(call?.shot.passageMedia?.photo, p.photo, "Paragrafın fotoğrafı istekte")
        XCTAssertEqual(call?.shot.passageMedia?.video, p.video, "Paragrafın videosu istekte")
        XCTAssertTrue(call?.shot.passageNote.contains("ORTAK PARAGRAFA") ?? false, "Hangi görüntünün neye ait olduğu söylenir: \(call?.shot.passageNote ?? "")")
        XCTAssertTrue(call?.shot.passageNote.contains("5, 6 ve 7") ?? false)
        XCTAssertEqual(h.camera.subjects, [.passage, .question])
        XCTAssertEqual(h.vm.passage?.remaining, [6, 7])
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.video!.path), "Paragraf sürdüğü için videosu durur")
        XCTAssertFalse(FileManager.default.fileExists(atPath: q.video!.path), "Gönderilen sorunun videosu silinir")
        XCTAssertTrue(h.speaker.spoken.contains(Say.cameraCaptured), "Soru için de 'çekim başarıyla yapıldı' denir")
        XCTAssertTrue(h.vm.announced.contains(Say.cameraSendingWithPassage), "Gönderirken paragrafın da gittiği söylenir")
    }

    /// Sesle okunan soru da kamerayla çekilmiş paragrafın görüntüleriyle gider
    func testAVoiceQuestionGoesWithTheCameraPassageImages() async {
        let p = passageShot()
        let h = harness(shots: [.success(p)], replies: [.success(FakeAnswering.reply(5))])
        _ = await h.startListening()
        _ = await takePassageByCamera(h)
        sayTargets(h, "beş altı yedi Tamam")
        _ = await waitUntil(45) { h.vm.passage?.all == [5, 6, 7] && self.cameraQuestionOpen(h) }
        reply(h, "hayır")
        _ = await waitUntil(45) { h.speaker.spoken.last == Say.cameraDeclined && h.vm.listenMode == .question && h.vm.phase == .listening }
        h.ask("Soru 5 Aşağıdakilerden hangisi Türkiye'nin başkentidir")
        let done = await waitUntil(45) { h.vm.answers.count == 1 }
        XCTAssertTrue(done)
        let call = h.answering.calls.first
        XCTAssertEqual(call?.passage?.photo, p.photo, "Paragrafın fotoğrafı sesle okunan soruyla gider")
        XCTAssertEqual(call?.passage?.video, p.video)
        XCTAssertTrue(call?.question.contains("Ortak paragraf (5, 6 ve 7 numaralı") ?? false, call?.question ?? "")
        XCTAssertTrue(call?.question.contains("görüntü olarak") ?? false, "Paragraf yazı olarak değil görüntü olarak verildiği söylenir")
        XCTAssertTrue(call?.question.contains("başkentidir") ?? false, "Soru metni de gider")
        XCTAssertEqual(h.vm.passage?.remaining, [6, 7])
    }

    /// Paragraf bu soruya ait değilse (numara listede yok) görüntüler gitmez
    func testAVoiceQuestionOutsideThePassageListGoesWithoutImages() async {
        let h = harness(shots: [.success(passageShot())], replies: [.success(FakeAnswering.reply(9))])
        _ = await h.startListening()
        _ = await takePassageByCamera(h)
        sayTargets(h, "beş altı Tamam")
        _ = await waitUntil(45) { h.vm.passage?.all == [5, 6] && self.cameraQuestionOpen(h) }
        reply(h, "hayır")
        _ = await waitUntil(45) { h.speaker.spoken.last == Say.cameraDeclined && h.vm.phase == .listening }
        h.ask("Soru 9 Başka bir soru")
        let done = await waitUntil(45) { h.vm.answers.count == 1 }
        XCTAssertTrue(done)
        XCTAssertNil(h.answering.calls.first?.passage)
        XCTAssertEqual(h.vm.passage?.remaining, [5, 6])
    }

    // MARK: Hatalar ve kesintiler

    func testAFailedPassageShotFallsBackToReadingItAloud() async {
        let h = harness(shots: [.failure(.noPosition)])
        _ = await h.startListening()
        reply(h, "ortak paragraf")
        _ = await waitUntil(45) { h.vm.listenMode == .passageCameraChoice && h.vm.phase == .listening }
        reply(h, "evet")
        let voice = await waitUntil(45) { h.speaker.spoken.last == Say.passageCameraFailed(.noPosition) && h.vm.listenMode == .passage && h.vm.phase == .listening }
        XCTAssertTrue(voice, "Neden söylenir ve paragraf sesle okutulur: \(h.speaker.spoken)")
        XCTAssertEqual(h.events, ["kestirme:Kameraya_Gec", "çekim", "kestirme:Hücresele_Gec"], "Çekim olmasa da internete dönülür")
        XCTAssertNil(h.vm.passageDraft)
        XCTAssertNil(h.vm.passage)
    }

    func testAnUnansweredPassageCameraQuestionIsRepeatedOnceThenThePassageIsReadAloud() async {
        let h = harness(shots: [])
        _ = await h.startListening()
        reply(h, "ortak paragraf")
        _ = await waitUntil(45) { h.vm.listenMode == .passageCameraChoice && h.vm.phase == .listening }
        h.scheduler.advance(by: SilenceWatchdog.limit + 0.1)
        let reminded = await waitUntil(45) { h.speaker.spoken.last == Say.askPassageCameraAgain && h.vm.listenMode == .passageCameraChoice && h.vm.phase == .listening }
        XCTAssertTrue(reminded)
        h.scheduler.advance(by: SilenceWatchdog.limit + 0.1)
        let voice = await waitUntil(45) { h.speaker.spoken.last == Say.passageCameraDefaultVoice && h.vm.listenMode == .passage && h.vm.phase == .listening }
        XCTAssertTrue(voice, "Cevap gelmezse güvenli varsayılan: sesle okuma")
        XCTAssertTrue(h.shortcuts.runs.isEmpty)
        XCTAssertEqual(h.camera.captures, 0)
    }

    func testAnUnclearReplyToThePassageCameraQuestionIsAskedAgainRightAway() async {
        let h = harness(shots: [])
        _ = await h.startListening()
        reply(h, "ortak paragraf")
        _ = await waitUntil(45) { h.vm.listenMode == .passageCameraChoice && h.vm.phase == .listening }
        h.listener.say("bilmem ki")
        h.scheduler.advance(by: T.numberUnclear + 0.1)
        let again = await waitUntil(45) { h.speaker.spoken.last == Say.askPassageCameraAgain && h.vm.listenMode == .passageCameraChoice }
        XCTAssertTrue(again)
    }

    /// Kamera sorusu açıkken kesinti: "Anlayamadım" denmez, bağlantının onarıldığı söylenip aynı soru yeniden sorulur
    func testInterruptionAtThePassageCameraQuestionAsksItAgainAfterRepair() async {
        let h = harness(shots: [])
        _ = await h.startListening()
        reply(h, "ortak paragraf")
        _ = await waitUntil(45) { h.vm.listenMode == .passageCameraChoice && h.vm.phase == .listening }
        h.route.interrupt(began: true)
        await settle()
        XCTAssertTrue(h.isHardwarePause)
        h.route.interrupt(began: false)
        h.scheduler.advance(by: T.routeStable + 0.1)
        let asked = await waitUntil(45) { h.speaker.spoken.last == Say.askPassageCameraAfterRecovery && h.vm.listenMode == .passageCameraChoice && h.vm.phase == .listening }
        XCTAssertTrue(asked, "\(h.speaker.spoken)")
        XCTAssertFalse(h.speaker.spoken.contains(Say.askPassageCameraAgain))
    }

    /// Çekimden sonra internete dönüş sırasında kesinti: görüntüler kaybolmaz, onarımdan sonra hangi sorular için olduğu sorulur; telefon
    /// kameranın Wi-Fi'sinde kaldıysa sonraki kamera sorusundan önce internete geçilir
    func testAnInterruptionRightAfterThePassageShotKeepsTheImagesAndAsksTheNumbersAfterRepair() async {
        let p = passageShot()
        let h = harness(shots: [.success(p)])
        var returns = 0
        h.shortcuts.onRun = { [unowned h] name in
            if name == "Kameraya_Gec" { h.health.internet = false }
            if name == "Hücresele_Gec" {
                returns += 1
                if returns == 1 { h.route.interrupt(began: true) } else { h.health.internet = true }
            }
        }
        _ = await h.startListening()
        reply(h, "ortak paragraf")
        _ = await waitUntil(45) { h.vm.listenMode == .passageCameraChoice && h.vm.phase == .listening }
        reply(h, "evet")
        let paused = await waitUntil(45) { h.isHardwarePause && !h.vm.cameraBusy }
        XCTAssertTrue(paused, "İnternete dönüş kestirmesi çalışırken arama geldi")
        XCTAssertNotNil(h.vm.passageDraft?.shot, "Çekilen paragraf kaybolmadı")
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.video!.path))
        h.route.interrupt(began: false)
        h.scheduler.advance(by: T.routeStable + 0.1)
        let asked = await waitUntil(45) { h.speaker.spoken.last == Say.recoveredAskTargetsCamera && h.vm.listenMode == .passageTargets && h.vm.phase == .listening }
        XCTAssertTrue(asked, "Onarımdan sonra hangi sorular için olduğu sorulur: \(h.speaker.spoken)")
        XCTAssertNotNil(h.vm.passageDraft?.shot)
        XCTAssertFalse(h.health.internet, "Telefon hâlâ kameranın Wi-Fi'sinde")

        sayTargets(h, "beş altı yedi Tamam")
        let next = await waitUntil(45) { h.vm.passage?.all == [5, 6, 7] && self.cameraQuestionOpen(h) }
        XCTAssertTrue(next, "\(h.speaker.spoken)")
        XCTAssertEqual(h.shortcuts.runs.filter { $0 == "Hücresele_Gec" }.count, 2, "Kamera sorusundan önce internete geçildi")
        XCTAssertTrue(h.health.internet)
        XCTAssertEqual(h.vm.passage?.viaCamera, true)
    }

    // MARK: Görüntü dosyaları

    /// Yeni bir paragraf eskisinin yerine geçer: eski paragrafın video dosyası silinir
    func testANewPassageReplacesTheOldOneAndDeletesItsVideo() async {
        let p1 = passageShot()
        let p2 = passageShot()
        let h = harness(shots: [.success(p1), .success(p2)])
        _ = await h.startListening()
        _ = await takePassageByCamera(h)
        sayTargets(h, "beş altı Tamam")
        _ = await waitUntil(45) { h.vm.passage?.all == [5, 6] && self.cameraQuestionOpen(h) }
        let second = await takePassageByCamera(h)
        XCTAssertTrue(second, "Kamera sorusunda yeniden 'ortak paragraf' denebilir: \(h.speaker.spoken)")
        sayTargets(h, "yedi sekiz Tamam")
        let kept = await waitUntil(45) { h.vm.passage?.all == [7, 8] && self.cameraQuestionOpen(h) }
        XCTAssertTrue(kept)
        XCTAssertFalse(FileManager.default.fileExists(atPath: p1.video!.path), "Eski paragrafın videosu silinir")
        XCTAssertTrue(FileManager.default.fileExists(atPath: p2.video!.path))
    }

    /// Paragraf bitince (tüm soruları cevaplanınca) videosu silinir
    func testThePassageVideoIsDeletedWhenItsLastQuestionIsAnswered() async {
        let p = passageShot()
        let h = harness(shots: [.success(p), .success(FakeCamera.shot()), .success(FakeCamera.shot())],
                        replies: [.success(FakeAnswering.reply(5)), .success(FakeAnswering.reply(6))])
        _ = await h.startListening()
        _ = await takePassageByCamera(h)
        sayTargets(h, "beş altı Tamam")
        _ = await waitUntil(45) { h.vm.passage?.all == [5, 6] && self.cameraQuestionOpen(h) }
        reply(h, "evet")
        _ = await waitUntil(45) { h.vm.answers.count == 1 && self.cameraQuestionOpen(h) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.video!.path))
        reply(h, "evet")
        let done = await waitUntil(45) { h.vm.answers.count == 2 && self.cameraQuestionOpen(h) }
        XCTAssertTrue(done)
        XCTAssertNil(h.vm.passage, "Tüm soruları cevaplandı: paragraf bırakılır")
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.video!.path), "Paragrafın videosu silinir")
        XCTAssertNil(h.journal.passage)
    }

    /// Hangi sorular için olduğu sorulurken test biterse taslağın videosu silinir
    func testEndingTheTestWhileTheNumbersAreAskedDeletesTheDraftVideo() async {
        let p = passageShot()
        let h = harness(shots: [.success(p)])
        _ = await h.startListening()
        let asked = await takePassageByCamera(h)
        XCTAssertTrue(asked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.video!.path))
        h.vm.endTest()
        XCTAssertNil(h.vm.passageDraft)
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.video!.path), "Sahipsiz video dosyası kalmaz")
    }

    // MARK: Yeniden açılış

    func testRelaunchRestoresACameraPassageAsAPhotoAndAttachesItToTheNextVoiceQuestion() async {
        let h = harness(shots: [], replies: [.success(FakeAnswering.reply(5))])
        var run = RunStart(exit: .unexpected(cause: "deneme"), pending: nil, nextNumber: 5, folder: nil, downSeconds: 10, loop: false)
        run.passage = SavedPassage(text: "", english: "", all: [5, 6], remaining: [5, 6], photo: Data([7, 7]))
        h.journal.start = run
        h.vm.launched()
        let listening = await waitUntil { h.vm.phase == .listening }
        XCTAssertTrue(listening)
        XCTAssertEqual(h.vm.passage?.shot?.photo, Data([7, 7]), "Fotoğraf geri geldi")
        XCTAssertNil(h.vm.passage?.shot?.video, "Video kapanmada kayboldu")
        XCTAssertTrue(h.speaker.spoken.contains { $0.contains(Say.resumedPassage([5, 6], photo: true)) }, "Kullanıcıya söylenir: \(h.speaker.spoken)")
        XCTAssertNotNil(h.journal.passage?.photo, "Defterde durur: yeniden kapanırsa yine geri gelir")
        reply(h, "hayır")
        _ = await waitUntil(45) { h.speaker.spoken.last == Say.cameraDeclined && h.vm.phase == .listening }
        h.ask("Soru 5 ilk soru")
        let sent = await waitUntil(45) { h.answering.calls.count == 1 }
        XCTAssertTrue(sent)
        XCTAssertEqual(h.answering.calls.first?.passage?.photo, Data([7, 7]))
        XCTAssertNil(h.answering.calls.first?.passage?.video)
    }

    /// Paragraf görüntüsüyle giden soru kapanma yüzünden yeniden sorulurken fotoğraf yine eklenir
    func testAQuestionSentWithPassageImagesIsResentWithThePhotoAfterARelaunch() async {
        let h = harness(shots: [], replies: [.success(FakeAnswering.reply(5))])
        var run = RunStart(exit: .unexpected(cause: "deneme"), pending: nil, nextNumber: 5, folder: nil, downSeconds: 10, loop: false)
        run.pending = PendingWork(question: "Ortak paragraf (5 ve 6 numaralı sorular için ortaktır)\n\nŞimdi sorulan soru:\nSoru 5", english: "",
                                  spokenNumber: 5, number: nil, spoken: nil, withPassagePhoto: true)
        run.passage = SavedPassage(text: "", english: "", all: [5, 6], remaining: [5, 6], photo: Data([7, 7]))
        h.journal.start = run
        h.vm.launched()
        let sent = await waitUntil(45) { h.answering.calls.count == 1 }
        XCTAssertTrue(sent)
        XCTAssertEqual(h.answering.calls.first?.passage?.photo, Data([7, 7]), "Soru yine paragraf fotoğrafıyla gider")
    }

    func testTheJournalKeepsThePassagePhotoInItsOwnFile() {
        let suite = "g526.paragraf.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let journal = RunJournal(defaults: defaults, previousLog: [], clipboard: ClipboardFlag(defaults: defaults, write: { _ in }, changeCount: { 0 }))
        let photo = Data(repeating: 7, count: 500_000)
        journal.savePassage(SavedPassage(text: "", english: "", all: [5, 6], remaining: [6], photo: photo))
        XCTAssertLessThan(defaults.data(forKey: "journal.passage")?.count ?? Int.max, 1_000, "Fotoğraf ayarlara yazılmaz, ayrı dosyada durur")
        let start = journal.beginRun()
        XCTAssertEqual(start.passage?.photo, photo)
        XCTAssertEqual(start.passage?.remaining, [6])
        journal.savePassage(nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: RunJournal.passagePhotoURL.path), "Paragraf bırakılınca fotoğraf dosyası da silinir")
        XCTAssertNil(journal.beginRun().passage)
    }

    func testAPassageWithoutAPhotoDoesNotPickUpAStalePhotoFile() throws {
        let suite = "g526.paragraf.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let journal = RunJournal(defaults: defaults, previousLog: [], clipboard: ClipboardFlag(defaults: defaults, write: { _ in }, changeCount: { 0 }))
        try FileManager.default.createDirectory(at: RunJournal.passagePhotoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: RunJournal.passagePhotoURL)
        journal.savePassage(SavedPassage(text: "Yazı", english: "", all: [1], remaining: [1]))
        XCTAssertNil(journal.beginRun().passage?.photo, "Yazı olarak kaydedilen paragrafa eski fotoğraf bağlanmaz")
        XCTAssertFalse(FileManager.default.fileExists(atPath: RunJournal.passagePhotoURL.path), "Eski fotoğraf dosyası temizlenir")
        journal.savePassage(nil)
    }

    // MARK: Gemini isteği

    private func parts(_ data: Data) throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let contents = object?["contents"] as? [[String: Any]]
        return (contents?.first?["parts"] as? [[String: Any]]) ?? []
    }

    private func kinds(_ parts: [[String: Any]]) -> [String] {
        return parts.map { part in
            if part["text"] != nil { return "metin" }
            let mime = (part["inlineData"] as? [String: Any])?["mimeType"] as? String ?? "?"
            return mime
        }
    }

    private func media(photo: Int = 3, videoBytes: Int) -> PassageMedia {
        var shot = FakeCamera.shot(bytes: videoBytes)
        shot.photo = Data(count: photo)
        return PassageMedia(shot)
    }

    func testCameraRequestPutsThePassageImagesBeforeTheQuestionImages() throws {
        var shot = FakeCamera.shot(bytes: 5_000_000)
        shot.passageMedia = media(videoBytes: 5_000_000)
        shot.passageNote = QuestionComposer.cameraNote(passage: PassageContext(text: "", english: "", audio: nil, all: [5], remaining: [5], shot: FakeCamera.shot()))
        let list = try parts(try GeminiAnswerService.captureBody(shot, expectedNumber: 5))
        XCTAssertEqual(kinds(list), ["image/jpeg", "video/mp4", "image/jpeg", "video/mp4", "metin"],
                       "Paragraf fotoğrafı + videosu, sonra soru fotoğrafı + videosu; metin en sonda")
        let text = list.last?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("ORTAK PARAGRAFA"), text)
    }

    func testCameraRequestWithoutAPassageIsUnchanged() throws {
        let shot = FakeCamera.shot(bytes: 5_000_000)
        let list = try parts(try GeminiAnswerService.captureBody(shot, expectedNumber: 5))
        XCTAssertEqual(kinds(list), ["image/jpeg", "video/mp4", "metin"])
    }

    /// İstek 20 MB'ı aşmasın: önce sorunun görüntüleri, sığmazsa paragrafın videosu atılır (fotoğrafı kalır)
    func testThePassageVideoIsDroppedFirstWhenTheRequestWouldBeTooBig() throws {
        var shot = FakeCamera.shot(bytes: 6_000_000)
        shot.passageMedia = media(videoBytes: 9_000_000)
        XCTAssertTrue(shot.canSendVideo, "Sorunun videosu önceliklidir")
        XCTAssertFalse(shot.canSendPassageVideo, "6 + 9 MB sınırı aşar: paragrafın videosu gitmez")
        let list = try parts(try GeminiAnswerService.captureBody(shot, expectedNumber: 5))
        XCTAssertEqual(kinds(list), ["image/jpeg", "image/jpeg", "video/mp4", "metin"],
                       "Paragraf yalnız fotoğrafla, soru fotoğraf + videoyla gider")
    }

    func testBothVideosGoWhenTheyFit() {
        var shot = FakeCamera.shot(bytes: 6_000_000)
        shot.passageMedia = media(videoBytes: 6_000_000)
        XCTAssertTrue(shot.canSendVideo)
        XCTAssertTrue(shot.canSendPassageVideo)
    }

    func testAVoiceRequestCarriesThePassageImagesAfterTheAudio() throws {
        let withPassage = try parts(try GeminiAnswerService.requestBody(question: "Soru", expectedNumber: 5, audio: Data([1, 2]), passage: media(videoBytes: 1_000)))
        XCTAssertEqual(kinds(withPassage), ["metin", "audio/wav", "image/jpeg", "video/mp4"])
        let plain = try parts(try GeminiAnswerService.requestBody(question: "Soru", expectedNumber: 5, audio: Data([1, 2])))
        XCTAssertEqual(kinds(plain), ["metin", "audio/wav"], "Paragraf yoksa istek değişmez")
    }

    func testAVoiceRequestDropsThePassageVideoWhenTheAudioLeavesNoRoom() throws {
        let big = Data(count: 9_000_000)
        let list = try parts(try GeminiAnswerService.requestBody(question: "Soru", expectedNumber: 5, audio: big, passage: media(videoBytes: 6_000_000)))
        XCTAssertEqual(kinds(list), ["metin", "audio/wav", "image/jpeg"], "9 + 6 MB sınırı aşar: paragraf yalnız fotoğrafla gider")
    }

    func testThePassageNoteMentionsTheImagesOnlyForACameraPassage() {
        let camera = PassageContext(text: "", english: "", audio: nil, all: [5, 6], remaining: [5, 6], shot: FakeCamera.shot())
        XCTAssertTrue(QuestionComposer.cameraNote(passage: camera).contains("ORTAK PARAGRAFA"))
        XCTAssertTrue(QuestionComposer.withCameraPassage(question: "Soru 5", passage: camera).contains("görüntü olarak"))
        XCTAssertTrue(QuestionComposer.withCameraPassage(question: "Soru 5", passage: camera).hasSuffix("Şimdi sorulan soru:\nSoru 5"))
        let done = PassageContext(text: "", english: "", audio: nil, all: [5], remaining: [], shot: FakeCamera.shot())
        XCTAssertEqual(QuestionComposer.cameraNote(passage: done), "", "Tüm sorular cevaplandıysa paragraf eklenmez")
        let voice = PassageContext(text: "Metin burada.", english: "", audio: nil, all: [5], remaining: [5])
        XCTAssertTrue(QuestionComposer.cameraNote(passage: voice).contains("Metin burada."), "Sesle okunan paragraf yazı olarak gider")
    }

    // MARK: Anonslar

    func testEveryCaptureStageTellsTheUserWhatHappened() {
        XCTAssertTrue(Say.cameraCaptured.contains("video ve fotoğraf çekimi başarıyla yapıldı"))
        XCTAssertTrue(Say.passageCaptured.contains("video ve fotoğraf çekimi başarıyla yapıldı"))
        XCTAssertTrue(Say.cameraSending.contains("İnternet geldi"))
        XCTAssertTrue(Say.passageTakenCamera.contains("Bu paragraf hangi sorular için"))
        XCTAssertEqual(CameraSay.readyLine(.passage), "Kamera hazır. Ortak paragrafı kadraja alın.")
        XCTAssertEqual(CameraSay.readyLine(.question), "Kamera hazır. Soruyu kadraja alın.")
    }
}
