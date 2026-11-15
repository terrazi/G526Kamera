import XCTest
import UIKit
@testable import G526CameraDrive

/// Sürüm 4: her soruda "kamera ile çekip göndermek ister misiniz?" akışı (sahte kamera, kestirme, internet ve Gemini ile)
@MainActor
final class CameraFlowTests: XCTestCase {
    typealias T = SessionViewModel.Timing

    /// Kameraya geçince internet gider, "Hücresele Geç" kestirmesi interneti getirir
    private func harness(shots: [Result<CapturedQuestion, CameraFailure>]? = nil,
                         replies: [Result<GeminiReply, Error>]? = nil,
                         internetBack: Bool = true) -> SessionHarness {
        let h = SessionHarness(cameraFlow: true)
        h.camera.results = shots ?? [.success(FakeCamera.shot())]
        h.answering.results = replies ?? [.success(FakeAnswering.reply(1))]
        h.trackEvents { name in
            if name == "Kameraya_Gec" { h.health.internet = false }
            if name == "Hücresele_Gec" && internetBack { h.health.internet = true }
            if name == "Hücresel_Ac" { h.health.internet = true }   // V3 internet onarımı
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

    private func jpegPhoto() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 60))
        return renderer.jpegData(withCompressionQuality: 0.8) { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 60))
        }
    }

    /// Ana ekrandaki "Son fotoğraf": çekim sonrası küçük resim ve bilgi saklanır; okunamayan fotoğraf (sahte veri) akışı bozmaz
    func testTheLastShotThumbnailAndInfoAreKeptForTheMainScreen() async {
        var shot = FakeCamera.shot(video: false)
        shot.photo = jpegPhoto()
        let h = harness(shots: [.success(shot)])
        _ = await h.startListening()
        XCTAssertNil(h.vm.lastShot, "Çekim yokken son fotoğraf yok")
        reply(h, "evet")
        let again = await waitUntil(45) { h.vm.answers.count == 1 && self.cameraQuestionOpen(h) }
        XCTAssertTrue(again)
        XCTAssertNotNil(h.vm.lastShot)
        XCTAssertTrue(h.vm.lastShotInfo.contains("KB"), h.vm.lastShotInfo)
    }

    func testTheLastShotIsNeitherKeptNorShownWhenTurnedOffInSettings() async {
        var shot = FakeCamera.shot(video: false)
        shot.photo = jpegPhoto()
        let h = harness(shots: [.success(shot)])
        h.cameraSettings.lastShotOff = true
        _ = await h.startListening()
        reply(h, "evet")
        let again = await waitUntil(45) { h.vm.answers.count == 1 && self.cameraQuestionOpen(h) }
        XCTAssertTrue(again, "Gönderim ayardan etkilenmez")
        XCTAssertNil(h.vm.lastShot, "Ayar açıkken küçük resim saklanmaz")
        XCTAssertEqual(h.vm.lastShotInfo, "")
    }

    func testClearLastShotRemovesAnExistingThumbnail() {
        let h = harness()
        h.vm.lastShot = UIImage()
        h.vm.lastShotInfo = "14:05:12 · fotoğraf 212 KB"
        h.vm.clearLastShot()
        XCTAssertNil(h.vm.lastShot)
        XCTAssertEqual(h.vm.lastShotInfo, "")
    }

    func testLastShotSettingIsRememberedAndOffByDefault() {
        let defaults = UserDefaults(suiteName: "g526.testler.\(UUID().uuidString)")!
        let first = CameraSettings(defaults: defaults)
        XCTAssertFalse(first.lastShotOff, "Varsayılan: son fotoğraf gösterilir")
        first.lastShotOff = true
        XCTAssertTrue(CameraSettings(defaults: defaults).lastShotOff, "Ayar kalıcıdır")
        XCTAssertTrue(CameraSettings.allKeys.contains("lastShotOff"))
    }

    func testAnUnreadablePhotoLeavesTheLastShotUntouchedAndTheFlowGoesOn() async {
        let h = harness()
        _ = await h.startListening()
        reply(h, "evet")
        let again = await waitUntil(45) { h.vm.answers.count == 1 && self.cameraQuestionOpen(h) }
        XCTAssertTrue(again, "Fotoğraf okunamasa da soru gönderilir")
        XCTAssertNil(h.vm.lastShot)
    }

    func testStartAsksTheCameraQuestionAfterTheReadyAnnouncement() async {
        let h = harness()
        let listening = await h.startListening()
        XCTAssertTrue(listening)
        XCTAssertEqual(h.speaker.spoken, [Say.readyCamera, Say.askCamera], "Önce hazırım, sonra kamera sorusu")
        XCTAssertEqual(h.vm.checkup.first(where: { $0.id == "kamera" })?.ok, true)
        XCTAssertEqual(h.vm.listenMode, .cameraChoice)
        XCTAssertEqual(h.camera.captures, 0)
        XCTAssertTrue(h.shortcuts.runs.isEmpty, "Sorulmadan hiçbir bağlantı değişmez")
    }

    func testYesRunsShortcutsCaptureAndSendInTheRightOrderThenAsksAgain() async {
        let shot = FakeCamera.shot()
        let h = harness(shots: [.success(shot)])
        _ = await h.startListening()
        reply(h, "evet")
        let again = await waitUntil(45) { h.vm.answers.count == 1 && self.cameraQuestionOpen(h) }
        XCTAssertTrue(again, "Cevap okunduktan sonra sıradaki soru için yine sorulur")
        XCTAssertEqual(h.events, ["kestirme:Kameraya_Gec", "çekim", "kestirme:Hücresele_Gec", "gönderim"],
                       "Önce hücresel kesilip kameraya geçilir, çekilir, sonra Wi-Fi bırakılıp hücresele dönülür, ondan sonra gönderilir")
        XCTAssertEqual(h.answering.captureCalls.count, 1)
        XCTAssertEqual(h.answering.captureCalls.first?.expectedNumber, 1)
        XCTAssertEqual(h.answering.captureCalls.first?.shot.photo, shot.photo)
        XCTAssertTrue(h.answering.calls.isEmpty, "Sesle soru gitmez")
        XCTAssertEqual(h.speaker.spoken.last, Say.askCamera)
        XCTAssertTrue(h.speaker.spoken.contains("Soru 1, Denizli, Örgütsel Davranış"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shot.video!.path), "Gönderilen çekimin video dosyası telefondan silinir")
        XCTAssertTrue(h.vm.pendingShots.isEmpty)
        XCTAssertEqual(h.vm.questions.last?.number, 1)
    }

    /// Kestirmeler (30 sn'lik beklemeler), kameraya bağlanma ve konumlandırma Gemini bekleyişinin önüne eklenir: V3'ün takılma gözcüsü
    /// sağlıklı çalışan kamera akışını "takıldı" sayıp iptal etmemeli
    func testTheStuckSupervisorGivesTheCameraFlowExtraTime() async {
        let h = harness()
        _ = await h.startListening()
        h.camera.hold = true
        reply(h, "evet")
        let capturing = await waitUntil(45) { h.camera.captures == 1 && h.vm.phase == .answering }
        XCTAssertTrue(capturing)
        let plain = T.stuckLimit(for: .answering) ?? 0
        XCTAssertGreaterThan(T.stuckLimit(for: .answering, camera: true) ?? 0, plain)
        h.scheduler.advance(by: plain + 60)
        XCTAssertEqual(h.vm.stuckTrips, 0, "Kamera akışı sürerken V3'ün sade sınırı uygulanmaz")
        XCTAssertEqual(h.vm.phase, .answering)
        XCTAssertEqual(h.camera.cancels, 0)
        h.camera.release()
        let done = await waitUntil(45) { h.vm.answers.count == 1 }
        XCTAssertTrue(done)
        XCTAssertEqual(h.vm.stuckTrips, 0)
    }

    /// Çekim sürerken arama gelir (V3 işi iptal eder): kamera kapanmalı, takılı kalmamalı; arama bitince kamera sorusu yeniden sorulmalı
    func testInterruptionDuringCaptureClosesTheCameraAndAsksAgainAfterwards() async {
        let h = harness()
        _ = await h.startListening()
        h.camera.hold = true
        reply(h, "evet")
        let capturing = await waitUntil(45) { h.camera.captures == 1 && h.vm.phase == .answering }
        XCTAssertTrue(capturing)
        h.route.interrupt(began: true)
        let closed = await waitUntil(45) { h.camera.cancels >= 1 && !h.vm.cameraBusy }
        XCTAssertTrue(closed, "İş iptal edilince kamera da kapanır ve akış takılı (meşgul) kalmaz")
        XCTAssertTrue(h.vm.pendingShots.isEmpty)
        h.route.interrupt(began: false)
        h.scheduler.advance(by: T.routeStable + 0.1)
        let asked = await waitUntil(45) { self.cameraQuestionOpen(h) }
        XCTAssertTrue(asked, "Kesintiden sonra kamera sorusu yeniden sorulur (sessizce sesle okumaya dönülmez)")
        XCTAssertFalse(h.shortcuts.runs.contains("Kamera_Onar"), "İptal edilen çekim için bağlantı onarımı çalışmaz")
    }

    func testNoLetsTheUserReadTheQuestionAsInVersionThree() async {
        let h = harness(shots: [], replies: [.success(FakeAnswering.reply(1)), .success(FakeAnswering.reply(2))])
        _ = await h.startListening()
        reply(h, "hayır")
        let voice = await waitUntil(45) { h.speaker.spoken.last == Say.cameraDeclined && h.vm.listenMode == .question && h.vm.phase == .listening }
        XCTAssertTrue(voice)
        h.ask("Birinci soru")
        let again = await waitUntil(45) { h.vm.answers.count == 1 && self.cameraQuestionOpen(h) }
        XCTAssertTrue(again, "Cevaptan sonra sıradaki soru için kamera yine sorulur")
        XCTAssertEqual(h.answering.calls.count, 1)
        XCTAssertEqual(h.camera.captures, 0)
        XCTAssertTrue(h.shortcuts.runs.isEmpty, "Hayır denince hiçbir bağlantı değişmez")
    }

    func testFailedCaptureReturnsToInternetThenFallsBackToTheVoiceFlow() async {
        let h = harness(shots: [.failure(.noPosition)], replies: [.success(FakeAnswering.reply(1))])
        _ = await h.startListening()
        reply(h, "evet")
        let voice = await waitUntil(45) { h.speaker.spoken.last == Say.cameraFailed(.noPosition) && h.vm.listenMode == .question && h.vm.phase == .listening }
        XCTAssertTrue(voice, "Neden söylenir ve soru sesle okunur")
        XCTAssertEqual(h.events, ["kestirme:Kameraya_Gec", "çekim", "kestirme:Hücresele_Gec"], "Çekim olmasa da internete dönülür")
        XCTAssertTrue(h.answering.captureCalls.isEmpty)
        XCTAssertTrue(h.vm.pendingShots.isEmpty)
        h.ask("Birinci soru")
        let done = await waitUntil(45) { h.vm.answers.count == 1 && self.cameraQuestionOpen(h) }
        XCTAssertTrue(done, "Sesle gidince de sıradaki soru için kamera yine sorulur")
    }

    func testCameraNotConnectedRunsTheRepairStepAndRetriesTheCapture() async {
        let h = harness(shots: [.failure(.notConnected), .success(FakeCamera.shot())])
        _ = await h.startListening()
        reply(h, "evet")
        let done = await waitUntil(45) { h.vm.answers.count == 1 }
        XCTAssertTrue(done)
        XCTAssertEqual(h.events, ["kestirme:Kameraya_Gec", "çekim", "kestirme:Kamera_Onar", "çekim", "kestirme:Hücresele_Gec", "gönderim"],
                       "Bağlanılamayınca Wi-Fi adımı (kamera bağlantısı onarımı) çalışır ve çekim yeniden denenir")
    }

    func testRepairIsGivenUpAfterTwoRepairsAndTheUserReadsTheQuestion() async {
        let h = harness(shots: [.failure(.notConnected), .failure(.notConnected), .failure(.noFrames)])
        _ = await h.startListening()
        reply(h, "evet")
        let voice = await waitUntil(45) { h.speaker.spoken.last == Say.cameraFailed(.noFrames) && h.vm.listenMode == .question && h.vm.phase == .listening }
        XCTAssertTrue(voice)
        XCTAssertEqual(h.events, ["kestirme:Kameraya_Gec", "çekim", "kestirme:Kamera_Onar", "çekim", "kestirme:Kamera_Onar", "çekim",
                                  "kestirme:Hücresele_Gec"])
    }

    func testRepairStepFallsBackToTheCameraShortcutWhenItsNameIsEmpty() async {
        let h = harness(shots: [.failure(.notConnected), .success(FakeCamera.shot())])
        h.settings.wifiShortcut = ""
        _ = await h.startListening()
        reply(h, "evet")
        let done = await waitUntil(45) { h.vm.answers.count == 1 }
        XCTAssertTrue(done)
        XCTAssertEqual(Array(h.events.prefix(4)), ["kestirme:Kameraya_Gec", "çekim", "kestirme:Kameraya_Gec", "çekim"])
    }

    func testFailedCameraShortcutNeverOpensTheCameraAndStillReturnsToInternet() async {
        let h = harness(shots: [.success(FakeCamera.shot())], internetBack: true)
        h.shortcuts.outcome = .failed("yok")
        _ = await h.startListening()
        reply(h, "evet")
        let done = await waitUntil(45) { h.camera.captures == 0 && h.shortcuts.runs.filter { $0 == "Hücresele_Gec" }.count == 2 }
        XCTAssertTrue(done)
        XCTAssertEqual(h.camera.captures, 0, "Kestirme çalışmadıysa kamera açılmaz")
        XCTAssertEqual(Array(h.shortcuts.runs.prefix(3)), ["Kameraya_Gec", "Kamera_Onar", "Kamera_Onar"])
    }

    func testInternetNotBackKeepsTheShotRunsRecoveryThenSendsIt() async {
        let shot = FakeCamera.shot()
        let h = harness(shots: [.success(shot)], internetBack: false)
        _ = await h.startListening()
        reply(h, "evet")
        let sent = await waitUntil(45) { h.vm.answers.count == 1 }
        XCTAssertTrue(sent, "Hücresel onarımı interneti getirince bekleyen çekim gönderilir")
        XCTAssertEqual(h.events.first, "kestirme:Kameraya_Gec")
        XCTAssertTrue(h.events.contains("kestirme:Hücresel_Ac"), "V3'ün internet onarımı çalışır")
        XCTAssertEqual(h.events.last, "gönderim")
        XCTAssertEqual(h.answering.captureCalls.count, 1)
        XCTAssertTrue(h.vm.pendingShots.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shot.video!.path))
    }

    func testNetworkErrorOnSendKeepsTheShotAndSendsItAgainAfterRecovery() async {
        let h = harness(shots: [.success(FakeCamera.shot())],
                        replies: [.failure(GeminiError("koptu", .network)), .failure(GeminiError("koptu", .network)),
                                  .success(FakeAnswering.reply(1))])
        _ = await h.startListening()
        reply(h, "evet")
        let sent = await waitUntil(45) { h.vm.answers.count == 1 }
        XCTAssertTrue(sent)
        XCTAssertEqual(h.answering.captureCalls.count, 3, "İki deneme (arada internet kestirmesi yeniden), sonra bekleyen çekim olarak üçüncü")
        XCTAssertEqual(h.shortcuts.runs.filter { $0 == "Hücresele_Gec" }.count, 2, "Ağ hatasından sonra internet kestirmesi yeniden çalışır")
        XCTAssertTrue(h.vm.pendingShots.isEmpty)
    }

    /// Gönderilemeyen çekim her onarımdan sonra sonsuza dek yeniden denenmez: bir kez yeniden denenir, yine olmazsa atılır ve söylenir
    func testAShotThatKeepsFailingIsRetriedOnceThenDroppedAndSaidSo() async {
        let shot = FakeCamera.shot()
        let errors: [Result<GeminiReply, Error>] = (0..<4).map { _ in .failure(GeminiError("koptu", .network)) }
        let h = harness(shots: [.success(shot)], replies: errors)
        _ = await h.startListening()
        reply(h, "evet")
        let settled = await waitUntil(45) { h.answering.captureCalls.count == 4 && self.cameraQuestionOpen(h) }
        XCTAssertTrue(settled, "İlk gönderim 2 deneme, bir kez de bekleyen çekim olarak 2 deneme: toplam 4")
        await settle()
        h.scheduler.advance(by: 30)
        await settle()
        XCTAssertEqual(h.answering.captureCalls.count, 4, "Yeniden deneme döngüye girmez")
        XCTAssertTrue(h.vm.pendingShots.isEmpty, "İki gönderimden sonra çekim atılır")
        XCTAssertFalse(FileManager.default.fileExists(atPath: shot.video!.path))
        XCTAssertTrue(h.vm.warnings.contains { $0.id == "kamera" && $0.text == Say.cameraPendingGivenUp }, "Kullanıcıya söylenir (ekranda ve kulaklıkta)")
    }

    /// Test bitince gönderilemeyen çekim bir sonraki oturuma sızmaz; kaç sorunun cevapsız kaldığı yazılır
    /// Bekleyen çekim yeniden gönderilirken arama gelirse bu bir başarısızlık sayılmaz: çekim atılmaz, arama bitince yeniden gönderilir
    func testInterruptionWhileResendingAPendingShotIsNotAFailure() async {
        let shot = FakeCamera.shot()
        let down = Result<GeminiReply, Error>.failure(GeminiError("koptu", .network))
        let h = harness(shots: [.success(shot)], replies: [down, down, down, .success(FakeAnswering.reply(1))])
        let previous = h.answering.onCall
        h.answering.onCall = { name in
            previous?(name)
            if h.answering.captureCalls.count == 3 { h.answering.hold = true }   // üçüncü çağrı: bekleyen çekimin yeniden gönderimi
        }
        _ = await h.startListening()
        reply(h, "evet")
        let held = await waitUntil(45) { h.answering.captureCalls.count == 3 && h.vm.phase == .answering }
        XCTAssertTrue(held, "Bekleyen çekim yeniden gönderilirken Gemini bekletilir")
        h.route.interrupt(began: true)
        await settle()
        h.answering.hold = false
        h.answering.release()
        await settle()
        XCTAssertEqual(h.vm.pendingShots.count, 1, "Kesinti yüzünden çekim atılmaz")
        XCTAssertTrue(FileManager.default.fileExists(atPath: shot.video!.path))
        h.route.interrupt(began: false)
        h.scheduler.advance(by: T.routeStable + 0.1)
        let sent = await waitUntil(45) { h.vm.answers.count == 1 }
        XCTAssertTrue(sent, "Arama bitince bekleyen çekim yeniden gönderilir")
        XCTAssertEqual(h.answering.captureCalls.count, 4)
        XCTAssertTrue(h.vm.pendingShots.isEmpty)
    }

    /// Kamera akışı sürerken test bitirilirse telefon kameranın Wi-Fi'sinde kalmaz: internet kestirmesi çalışır
    func testEndingTheTestDuringTheCameraFlowBringsTheInternetBack() async {
        let h = harness()
        _ = await h.startListening()
        h.camera.hold = true
        reply(h, "evet")
        let capturing = await waitUntil(45) { h.camera.captures == 1 && h.vm.phase == .answering }
        XCTAssertTrue(capturing)
        h.vm.endTest()
        let back = await waitUntil(45) { h.shortcuts.runs.filter { $0 == "Hücresele_Gec" }.count == 1 }
        XCTAssertTrue(back, "İnternet kestirmesi çalışır")
        XCTAssertEqual(h.vm.phase, .finished)
        XCTAssertTrue(h.vm.pendingShots.isEmpty)
        XCTAssertFalse(h.vm.cameraBusy)
    }

    func testEndingTheTestOutsideTheCameraFlowRunsNoShortcut() async {
        let h = harness()
        _ = await h.startListening()
        h.vm.endTest()
        await settle()
        XCTAssertTrue(h.shortcuts.runs.isEmpty)
    }

    // MARK: Sesli komutlar ve açılış (V3 düzenine uyum)

    /// Kamera sorusunun sözlüğü: "testi bitir", "bitir", "devam" gibi komutlar evet / hayır sayılmaz (yoksa kamera yanlışlıkla başlardı)
    func testCameraChoiceVocabularyDoesNotTreatCommandsAsYes() {
        XCTAssertEqual(SpokenReply.cameraChoice("evet"), .yes)
        XCTAssertEqual(SpokenReply.cameraChoice("Evet, kamera ile çekelim"), .yes)
        XCTAssertEqual(SpokenReply.cameraChoice("tamam"), .yes)
        XCTAssertEqual(SpokenReply.cameraChoice("hayır"), .no)
        XCTAssertEqual(SpokenReply.cameraChoice("hayır sesle okurum"), .no)
        XCTAssertEqual(SpokenReply.cameraChoice("kamera istemiyorum"), .no, "'kamera' sözü tek başına evet saymaz")
        XCTAssertEqual(SpokenReply.cameraChoice("çek"), .yes)
        XCTAssertNil(SpokenReply.cameraChoice("testi bitir"))
        XCTAssertNil(SpokenReply.cameraChoice("bitir"))
        XCTAssertNil(SpokenReply.cameraChoice("devam"))
        XCTAssertNil(SpokenReply.cameraChoice("cevapları tekrarla"))
        XCTAssertNil(SpokenReply.cameraChoice("evet hayır"), "Çelişen söz anlaşılmamış sayılır")
        XCTAssertNil(SpokenReply.cameraChoice(""))
    }

    /// "Testi bitir" kamera sorusu açıkken söylenirse kamera başlamaz: bitirme onayı istenir; vazgeçilirse kamera yeniden sorulur
    func testEndTestCommandAtTheCameraQuestionAsksToConfirmAndNeverStartsTheCamera() async {
        let h = harness()
        _ = await h.startListening()
        reply(h, "testi bitir")
        let asked = await waitUntil(45) { h.speaker.spoken.last == Say.confirmEnd && h.vm.listenMode == .confirmEnd && h.vm.phase == .listening }
        XCTAssertTrue(asked, "Önce bitirme onayı istenir")
        XCTAssertTrue(h.shortcuts.runs.isEmpty, "Kamera başlamaz: hiçbir bağlantı değişmez")
        XCTAssertEqual(h.camera.captures, 0)
        reply(h, "hayır")
        let back = await waitUntil(45) { self.cameraQuestionOpen(h) && h.speaker.spoken.last == Say.askCamera }
        XCTAssertTrue(back, "Bitirmekten vazgeçilince bu soru için kamera yeniden sorulur")
        XCTAssertTrue(h.speaker.spoken.contains(Say.endCancelledCamera), "Kamera sorusu hemen geleceği için 'soruyu okuyabilirsiniz' denmez")
        XCTAssertFalse(h.speaker.spoken.contains(Say.endCancelled))
        XCTAssertEqual(h.camera.captures, 0)
    }

    func testConfirmingTheEndAtTheCameraQuestionFinishesTheTestWithoutTheCamera() async {
        let h = harness()
        _ = await h.startListening()
        reply(h, "testi bitir")
        let asked = await waitUntil(45) { h.speaker.spoken.last == Say.confirmEnd && h.vm.listenMode == .confirmEnd }
        XCTAssertTrue(asked)
        reply(h, "evet")
        let done = await waitUntil(45) { h.vm.phase == .finished }
        XCTAssertTrue(done)
        XCTAssertTrue(h.shortcuts.runs.isEmpty)
        XCTAssertEqual(h.camera.captures, 0)
    }

    /// "Tekrarla" kamera sorusu açıkken de çalışır: son cevap okunur, kamera yeniden sorulur, yeni çekim olmaz
    func testRepeatLastAnswerCommandAtTheCameraQuestionReadsItAndAsksAgain() async {
        let h = harness()
        _ = await h.startListening()
        reply(h, "evet")
        let first = await waitUntil(45) { h.vm.answers.count == 1 && self.cameraQuestionOpen(h) }
        XCTAssertTrue(first)
        let spoken = h.vm.answers.last?.spoken ?? ""
        XCTAssertFalse(spoken.isEmpty)
        let before = h.speaker.spoken.filter { $0 == spoken }.count
        reply(h, "Tekrarla")
        let again = await waitUntil(45) {
            h.speaker.spoken.filter { $0 == spoken }.count == before + 1 && self.cameraQuestionOpen(h) && h.speaker.spoken.last == Say.askCamera
        }
        XCTAssertTrue(again, "Cevap yeniden okunur, sonra kamera yeniden sorulur")
        XCTAssertEqual(h.camera.captures, 1, "Yeni çekim olmaz")
        XCTAssertEqual(h.answering.captureCalls.count, 1, "Gemini'ye yeniden gidilmez")
    }

    /// Önceki kayıttan devam edilince de (ve yeni sınavda da) ilk soru için kamera sorulur; "soruyu okuyabilirsiniz" denmez
    func testContinuingAPreviousRecordAsksTheCameraQuestionForTheFirstQuestion() async {
        let h = harness()
        _ = await h.startListening()
        reply(h, "evet")
        let done = await waitUntil(45) { h.vm.answers.count == 1 && self.cameraQuestionOpen(h) }
        XCTAssertTrue(done)
        h.vm.endTest()
        _ = await h.startListening()
        XCTAssertEqual(h.vm.listenMode, .startChoice)
        reply(h, "Devam")
        let on = await waitUntil(45) { self.cameraQuestionOpen(h) && h.speaker.spoken.last == Say.askCamera }
        XCTAssertTrue(on, "Önceki kayıttan devam edilince de ilk soru için kamera sorulur")
        XCTAssertTrue(h.speaker.spoken.contains(Say.continuingPrevious(next: 2, camera: true)))
        XCTAssertFalse(h.speaker.spoken.contains(Say.continuingPrevious(next: 2)), "'Soruyu okuyabilirsiniz' denmez")
    }

    func testChoosingANewExamAlsoAsksTheCameraQuestion() async {
        let h = harness()
        _ = await h.startListening()
        reply(h, "evet")
        let done = await waitUntil(45) { h.vm.answers.count == 1 && self.cameraQuestionOpen(h) }
        XCTAssertTrue(done)
        h.vm.endTest()
        _ = await h.startListening()
        reply(h, "Yeni sınav")
        let on = await waitUntil(45) { self.cameraQuestionOpen(h) && h.speaker.spoken.last == Say.askCamera }
        XCTAssertTrue(on)
        XCTAssertTrue(h.speaker.spoken.contains(Say.startingNewCamera))
        XCTAssertFalse(h.speaker.spoken.contains(Say.startingNew))
    }

    // MARK: Zaman aşımı

    /// Çekilen soruya Gemini yanıt vermezse: çekim telefonda kalır ve bir kez yeniden gönderilir; yine yanıt yoksa atılır ve kamera yeniden sorulur
    func testShotThatTimesOutTwiceIsDroppedAndTheCameraIsAskedAgain() async {
        let shot = FakeCamera.shot()
        let h = harness(shots: [.success(shot)])
        h.settings.spokenProgress = true   // bekleme sınırı, cevap bekleme sayacına bağlıdır
        h.answering.hold = true
        _ = await h.startListening()
        reply(h, "evet")
        let sent = await waitUntil(45) { h.answering.captureCalls.count == 1 && h.vm.phase == .answering }
        XCTAssertTrue(sent)
        await settle()
        h.scheduler.advance(by: T.answerCap + T.cameraExtraWait + 1)
        let resent = await waitUntil(45) { h.speaker.spoken.contains(Say.geminiSlowCamera) && h.answering.captureCalls.count == 2 && h.vm.phase == .answering }
        XCTAssertTrue(resent, "İlk zaman aşımında çekim atılmaz, bir kez yeniden gönderilir")
        XCTAssertEqual(h.vm.pendingShots.count, 1)
        await settle()
        h.scheduler.advance(by: T.answerCap + T.cameraExtraWait + 1)
        let dropped = await waitUntil(45) { h.speaker.spoken.contains(Say.cameraSlowGivenUp) && self.cameraQuestionOpen(h) }
        XCTAssertTrue(dropped, "İkinci zaman aşımında çekim atılır, söylenir ve kamera yeniden sorulur")
        XCTAssertTrue(h.vm.pendingShots.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shot.video!.path))
        XCTAssertEqual(h.answering.captureCalls.count, 2, "Sonsuz yeniden gönderim yok")
        h.answering.hold = false
        h.answering.release()
        await settle()
    }

    // MARK: Derin denetim: kesinti, ağ, soruyu okuyarak cevap verme, ortak paragraf, üretim ayarları

    /// Üretimde açık olan V3 ayarları (testlerin geri kalanı sadeleştirmek için kapatır)
    private func productionHarness(shots: [Result<CapturedQuestion, CameraFailure>]? = nil,
                                   replies: [Result<GeminiReply, Error>]? = nil) -> SessionHarness {
        let h = harness(shots: shots, replies: replies)
        h.settings.spokenProgress = true
        h.settings.askMissingNumber = true
        h.settings.askNextQuestion = true
        h.settings.smartResume = true
        h.settings.instantDetection = true
        h.settings.readAnswersAtEnd = true
        return h
    }

    /// Kamera sorusu söylenirken kulaklık kopar ya da arama gelir: soru kaybolmaz, onarımdan sonra yeniden sorulur (düz sesle okumaya düşülmez)
    func testInterruptionWhileTheCameraQuestionIsBeingSpokenStillAsksItAfterwards() async {
        let h = harness()
        _ = await h.startListening()
        h.speaker.holdWhen = { $0 == Say.askCamera }
        reply(h, "evet")
        let held = await waitUntil(45) { h.vm.answers.count == 1 && h.speaker.allCalls.last?.text == Say.askCamera && h.vm.phase == .speaking }
        XCTAssertTrue(held, "Sıradaki soru için kamera sorusu söylenirken bekletilir")
        h.route.interrupt(began: true)
        h.speaker.holdWhen = nil
        await settle()
        XCTAssertTrue(h.isHardwarePause)
        h.route.interrupt(began: false)
        h.scheduler.advance(by: T.routeStable + 0.1)
        let asked = await waitUntil(45) { self.cameraQuestionOpen(h) && h.speaker.spoken.last == Say.askCamera }
        XCTAssertTrue(asked, "Kesintiden sonra kamera sorusu yeniden sorulur")
        XCTAssertEqual(h.vm.listenMode, .cameraChoice)
        XCTAssertEqual(h.camera.captures, 1, "Kendiliğinden yeni çekim olmaz")
    }

    /// Kamera sorusu açıkken (dinlerken) kesinti olursa "Anlayamadım" denmez; bağlantının onarıldığı söylenip soru yeniden sorulur
    func testInterruptionWhileListeningAtTheCameraQuestionAsksItAgainWithoutSayingNotUnderstood() async {
        let h = harness()
        _ = await h.startListening()
        h.route.interrupt(began: true)
        await settle()
        XCTAssertTrue(h.isHardwarePause)
        h.route.interrupt(began: false)
        h.scheduler.advance(by: T.routeStable + 0.1)
        let asked = await waitUntil(45) { self.cameraQuestionOpen(h) && h.speaker.spoken.last == Say.askCameraAfterRecovery }
        XCTAssertTrue(asked)
        XCTAssertFalse(h.speaker.spoken.contains(Say.askCameraAgain), "Kullanıcı yanlış anlaşılmadı: 'Anlayamadım' denmez")
    }

    /// Çekimden sonra internete dönülürken kesinti olursa telefon kameranın Wi-Fi'sinde kalır: onarımdan sonra bekleyen çekim gönderilmeden önce
    /// "internete geç" kestirmesi çalışır (30 sn boşuna beklenmez, kamera sorusu internetsiz sorulmaz)
    func testAnInterruptedReturnToTheInternetIsFinishedBeforeTheShotIsSent() async {
        let shot = FakeCamera.shot()
        let h = harness(shots: [.success(shot)])
        var returns = 0
        h.shortcuts.onRun = { [unowned h] name in
            if name == "Kameraya_Gec" { h.health.internet = false }
            if name == "Hücresele_Gec" {
                returns += 1
                if returns == 1 { h.route.interrupt(began: true) } else { h.health.internet = true }
            }
        }
        _ = await h.startListening()
        reply(h, "evet")
        let paused = await waitUntil(45) { h.isHardwarePause && !h.vm.cameraBusy }
        XCTAssertTrue(paused, "İnternete dönüş kestirmesi çalışırken arama geldi")
        XCTAssertEqual(h.vm.pendingShots.count, 1, "Çekilen soru telefonda kalır")
        XCTAssertFalse(h.health.internet, "Telefon hâlâ kameranın Wi-Fi'sinde")
        h.route.interrupt(began: false)
        h.scheduler.advance(by: T.routeStable + 0.1)
        let sent = await waitUntil(45) { h.vm.answers.count == 1 }
        XCTAssertTrue(sent, "Önce internete geçilir, sonra çekim gönderilir")
        XCTAssertEqual(h.shortcuts.runs.filter { $0 == "Hücresele_Gec" }.count, 2, "İnternet kestirmesi bir kez daha çalıştı")
        XCTAssertEqual(h.answering.captureCalls.count, 1)
        XCTAssertTrue(h.vm.pendingShots.isEmpty)
        XCTAssertTrue(h.health.internet)
    }

    /// İnternet zaten varsa (kesinti kamera akışının dışında oldu) hiçbir kestirme çalışmaz
    func testNoShortcutRunsAfterAnInterruptionWhenTheInternetIsFine() async {
        let h = harness()
        _ = await h.startListening()
        h.route.interrupt(began: true)
        await settle()
        h.route.interrupt(began: false)
        h.scheduler.advance(by: T.routeStable + 0.1)
        let asked = await waitUntil(45) { self.cameraQuestionOpen(h) }
        XCTAssertTrue(asked)
        XCTAssertTrue(h.shortcuts.runs.isEmpty)
    }

    /// V3 alışkanlığı: kullanıcı kamera sorusunu beklemeden soruyu okuyup "Cevapla" der. Soru sesle okunmuş sayılır ve metin kaybolmaz
    func testReadingTheQuestionAtTheCameraQuestionIsTakenAsAVoiceQuestion() async {
        let h = harness()
        _ = await h.startListening()
        h.ask("Soru 1. Aşağıdakilerden hangisi Türkiye'nin başkentidir A seçeneği Adana B seçeneği Bursa")
        let done = await waitUntil(45) { h.vm.answers.count == 1 && self.cameraQuestionOpen(h) }
        XCTAssertTrue(done, "Soru sesle gitti, cevap okundu, sıradaki soru için kamera sorulur")
        XCTAssertEqual(h.answering.calls.count, 1)
        XCTAssertTrue(h.answering.calls.first?.question.contains("başkentidir") ?? false, "Okunan metin Gemini'ye gider")
        XCTAssertTrue(h.answering.captureCalls.isEmpty)
        XCTAssertEqual(h.camera.captures, 0)
        XCTAssertTrue(h.shortcuts.runs.isEmpty)
        XCTAssertEqual(h.speaker.spoken.filter { $0 == Say.askCamera }.count, 2, "Aynı soru için yeniden sorulmaz")
    }

    /// Kısa, anlaşılmayan söz soru okuma sayılmaz: kamera sorusu yeniden sorulur
    func testAShortUnclearReplyIsNotTakenForAQuestion() async {
        let h = harness()
        _ = await h.startListening()
        h.listener.say("şey acaba nasıl")
        h.scheduler.advance(by: T.numberUnclear + 0.1)
        let again = await waitUntil(45) { h.speaker.spoken.last == Say.askCameraAgain && self.cameraQuestionOpen(h) }
        XCTAssertTrue(again)
        XCTAssertTrue(h.answering.calls.isEmpty)
    }

    /// Sesle okunmuş ortak paragraf, sonraki sorular kamerayla çekilince de Gemini'ye gider; cevaplanan soru paragrafın listesinden düşer
    func testAPassageReadAloudEarlierGoesWithTheNextCameraShot() async {
        let h = harness()
        _ = await h.startListening()
        h.vm.passage = PassageContext(text: "Ankara Türkiye'nin başkentidir.", english: "", audio: nil, all: [1, 2], remaining: [1, 2])
        reply(h, "evet")
        let done = await waitUntil(45) { h.vm.answers.count == 1 && self.cameraQuestionOpen(h) }
        XCTAssertTrue(done)
        let note = h.answering.captureCalls.first?.shot.passageNote ?? ""
        XCTAssertTrue(note.contains("Ankara Türkiye'nin başkentidir."), "Paragraf istekte: \(note)")
        XCTAssertTrue(note.contains("1 ve 2"), "Hangi sorulara ait olduğu da yazılır")
        XCTAssertEqual(h.vm.passage?.remaining, [2])
    }

    func testNoPassageNoteWithoutAPassage() async {
        let h = harness()
        _ = await h.startListening()
        reply(h, "evet")
        let done = await waitUntil(45) { h.vm.answers.count == 1 }
        XCTAssertTrue(done)
        XCTAssertEqual(h.answering.captureCalls.first?.shot.passageNote, "")
    }

    func testCapturePromptCarriesThePassageOnlyWhenThereIsOne() {
        let context = PassageContext(text: "Metin burada.", english: "", audio: nil, all: [5, 6, 7], remaining: [5, 6, 7])
        let note = QuestionComposer.cameraNote(passage: context)
        let with = GeminiAnswerService.captureText(expectedNumber: 5, hasVideo: true, extra: "", passage: note)
        XCTAssertTrue(with.contains("5, 6 ve 7"))
        XCTAssertTrue(with.contains("Metin burada."))
        XCTAssertEqual(GeminiAnswerService.captureText(expectedNumber: 5, hasVideo: true, extra: "", passage: ""),
                       GeminiAnswerService.captureText(expectedNumber: 5, hasVideo: true, extra: ""), "Paragraf yoksa istek değişmez")
        let done = PassageContext(text: "Metin", english: "", audio: nil, all: [5], remaining: [])
        XCTAssertEqual(QuestionComposer.cameraNote(passage: done), "", "Tüm sorular cevaplandıysa paragraf eklenmez")
    }

    /// Cevap duyulduktan sonra kamera sorusu açıkken kapanma olursa önceki cevap yeniden okunmaz: yarım iş kaydı silinmiştir
    func testThePreviousAnswerIsNotKeptAsUnfinishedWorkWhileTheCameraQuestionIsOpen() async {
        let h = harness()
        _ = await h.startListening()
        reply(h, "evet")
        let done = await waitUntil(45) { h.vm.answers.count == 1 && self.cameraQuestionOpen(h) }
        XCTAssertTrue(done)
        XCTAssertNil(h.journal.pending)
    }

    /// Kamera ve sesle okunan sorular karışık gidebilir: her cevap kendi numarasıyla kaydedilir, her soru için kamera sorulur
    func testCameraAndVoiceQuestionsCanBeMixedAndEachAnswerKeepsItsNumber() async {
        let h = harness(shots: [.success(FakeCamera.shot()), .success(FakeCamera.shot())],
                        replies: [.success(FakeAnswering.reply(1)), .success(FakeAnswering.reply(2)), .success(FakeAnswering.reply(3))])
        _ = await h.startListening()
        reply(h, "evet")
        let first = await waitUntil(45) { h.vm.answers.count == 1 && self.cameraQuestionOpen(h) }
        XCTAssertTrue(first)
        reply(h, "hayır")
        let voice = await waitUntil(45) { h.vm.listenMode == .question && h.vm.phase == .listening }
        XCTAssertTrue(voice)
        h.ask("Soru 2. bir soru metni")
        let second = await waitUntil(45) { h.vm.answers.count == 2 && self.cameraQuestionOpen(h) }
        XCTAssertTrue(second)
        reply(h, "evet")
        let third = await waitUntil(45) { h.vm.answers.count == 3 && self.cameraQuestionOpen(h) }
        XCTAssertTrue(third)
        XCTAssertEqual(h.vm.answers.map { $0.number }, [1, 2, 3])
        XCTAssertEqual(h.answering.captureCalls.map { $0.expectedNumber }, [1, 3])
        XCTAssertEqual(h.answering.calls.map { $0.expectedNumber }, [2])
        XCTAssertEqual(h.camera.captures, 2)
        XCTAssertEqual(h.speaker.spoken.filter { $0 == Say.askCamera }.count, 4, "Her soru sınırında bir kez sorulur")
    }

    /// Cevaplar okunduktan sonra "Devam" denince bu soru için kamera yeniden sorulur
    func testEndRequestReviewThenContinueAsksTheCameraQuestionAgain() async {
        let h = harness()
        _ = await h.startListening()
        reply(h, "evet")
        let first = await waitUntil(45) { h.vm.answers.count == 1 && self.cameraQuestionOpen(h) }
        XCTAssertTrue(first)
        reply(h, "testi bitir")
        let confirm = await waitUntil(45) { h.vm.listenMode == .confirmEnd && h.vm.phase == .listening }
        XCTAssertTrue(confirm)
        reply(h, "evet")
        let reading = await waitUntil(45) { h.vm.reviewing }
        XCTAssertTrue(reading)
        let playing = await waitUntil(45) { !h.player.played.isEmpty }
        XCTAssertTrue(playing)
        h.player.finish()
        let menu = await waitUntil(45) { h.vm.listenMode == .reviewMenu && h.vm.phase == .listening }
        XCTAssertTrue(menu)
        reply(h, "devam")
        let back = await waitUntil(45) { self.cameraQuestionOpen(h) && h.speaker.spoken.last == Say.askCamera }
        XCTAssertTrue(back, "Teste devam edilince kamera sorusu yeniden gelir")
        XCTAssertTrue(h.speaker.spoken.contains { $0.contains(Say.reviewBackToCamera) })
        XCTAssertFalse(h.speaker.spoken.contains { $0.contains(Say.reviewBackToQuestion) })
        XCTAssertEqual(h.camera.captures, 1)
    }

    // MARK: Üretim ayarlarıyla (ilerleme anonsu, numara sorma, akıllı devam, anında tespit açık)

    func testWithTheProductionDefaultsTheCameraFlowRunsInOrderAndNeverSaysTheVersionThreePrompt() async {
        let h = productionHarness()
        _ = await h.startListening()
        reply(h, "evet")
        let again = await waitUntil(45) { h.vm.answers.count == 1 && self.cameraQuestionOpen(h) }
        XCTAssertTrue(again)
        XCTAssertEqual(h.events, ["kestirme:Kameraya_Gec", "çekim", "kestirme:Hücresele_Gec", "gönderim"])
        XCTAssertFalse(h.speaker.spoken.contains(Say.nextQuestion), "Kamera açıkken 'Lütfen sonraki soruyu okuyun' denmez")
        XCTAssertEqual(h.speaker.spoken.last, Say.askCamera)
        XCTAssertTrue(h.vm.announced.contains(Say.cameraSending), "Gönderim anonsu (ilerleme) söylenir")
        XCTAssertFalse(h.speaker.spoken.contains(Say.cameraSending), "…ama cevap akışına karışmaz")
    }

    func testWithTheProductionDefaultsAMissingNumberIsStillAskedAfterReadingByVoice() async {
        let h = productionHarness(replies: [.success(FakeAnswering.reply(7))])
        _ = await h.startListening()
        reply(h, "hayır")
        let voice = await waitUntil(45) { h.vm.listenMode == .question && h.vm.phase == .listening }
        XCTAssertTrue(voice)
        h.ask("Aşağıdakilerden hangisi doğrudur A seçeneği Adana B seçeneği Bursa")
        let asked = await waitUntil(45) { h.vm.listenMode == .missingNumber && h.vm.phase == .listening }
        XCTAssertTrue(asked, "Numara okunmadıysa V3 gibi sorulur")
        XCTAssertEqual(h.speaker.spoken.last, Say.askNumber)
        reply(h, "yedi")
        let done = await waitUntil(45) { h.vm.answers.count == 1 && self.cameraQuestionOpen(h) }
        XCTAssertTrue(done)
        XCTAssertEqual(h.vm.answers.first?.number, 7)
    }

    /// Kamera cevabında numara görüntüden okunur: numara sorulmaz (kullanıcı kamera akışında hiçbir şey söylemez)
    func testWithTheProductionDefaultsACameraAnswerNeverAsksForANumber() async {
        let h = productionHarness(replies: [.success(GeminiReply(number: nil, option: "Denizli", text: "Örgütsel Davranış", spoken: "Denizli, Örgütsel Davranış", model: "fake"))])
        _ = await h.startListening()
        reply(h, "evet")
        let done = await waitUntil(45) { h.vm.answers.count == 1 && self.cameraQuestionOpen(h) }
        XCTAssertTrue(done)
        XCTAssertFalse(h.speaker.spoken.contains(Say.askNumber))
        XCTAssertEqual(h.vm.answers.first?.number, 1, "Görüntüden okunamayan numara sıradaki numara olur")
    }

    // MARK: Yeniden açılış

    func testRelaunchWithoutAPendingQuestionAsksTheCameraQuestionAndDoesNotAskToReadTheQuestion() async {
        let h = harness()
        h.journal.start = RunStart(exit: .unexpected(cause: "deneme"), pending: nil, nextNumber: 4, folder: nil, downSeconds: 10, loop: false)
        h.vm.launched()
        let asked = await waitUntil(45) { self.cameraQuestionOpen(h) && h.speaker.spoken.last == Say.askCamera }
        XCTAssertTrue(asked, "Kullanıcı telefona dokunamaz: kamera sorusu kendiliğinden sorulur")
        XCTAssertTrue(h.speaker.spoken.contains { $0.contains("beklenmedik biçimde kapanıp") })
        XCTAssertFalse(h.speaker.spoken.contains { $0.contains("baştan okuyun") }, "Kamera sorusu geleceği için 'soruyu baştan okuyun' denmez")
        XCTAssertEqual(h.vm.nextNumber, 4)
    }

    func testRelaunchAfterAnAnswerWasReceivedReadsItAgainThenAsksTheCameraQuestion() async {
        let h = harness()
        let pending = PendingWork(question: Say.cameraEntryText, english: "", spokenNumber: nil, number: 2, spoken: "Soru 2, Bursa, Yönetim")
        h.journal.start = RunStart(exit: .unexpected(cause: "deneme"), pending: pending, nextNumber: 3, folder: nil, downSeconds: 10, loop: false)
        h.vm.launched()
        let asked = await waitUntil(45) { self.cameraQuestionOpen(h) && h.speaker.spoken.last == Say.askCamera }
        XCTAssertTrue(asked)
        XCTAssertTrue(h.speaker.spoken.contains("Soru 2, Bursa, Yönetim"))
        XCTAssertTrue(h.answering.captureCalls.isEmpty, "Cevap zaten alınmıştı: çekim yeniden gönderilmez")
        XCTAssertTrue(h.answering.calls.isEmpty)
    }

    func testEndingTheTestDropsUnsentShotsAndSaysSo() async {
        let shot = FakeCamera.shot()
        let h = harness()
        _ = await h.startListening()
        h.vm.keepPending(shot)
        XCTAssertEqual(h.vm.pendingShots.count, 1)
        h.vm.endTest()
        XCTAssertTrue(h.vm.pendingShots.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shot.video!.path), "Gönderilmeyecek çekimin videosu telefonda bırakılmaz")
        XCTAssertTrue(h.vm.statusNote.contains("1 soru Gemini'ye gönderilemedi"))
    }

    func testBlockedShotIsNotKeptOnThePhone() async {
        let shot = FakeCamera.shot()
        let h = harness(shots: [.success(shot)], replies: [.failure(GeminiError("engellendi", .blocked))])
        _ = await h.startListening()
        reply(h, "evet")
        let failed = await waitUntil(45) { h.vm.warnings.contains { $0.id == "cevap" } }
        XCTAssertTrue(failed)
        await settle()
        XCTAssertTrue(h.vm.pendingShots.isEmpty, "Aynı sonucu verecek çekim telefonda tutulmaz")
        XCTAssertFalse(FileManager.default.fileExists(atPath: shot.video!.path))
        let asked = await waitUntil(45) { self.cameraQuestionOpen(h) }
        XCTAssertTrue(asked, "Hata söylendikten sonra kamera sorusu yeniden sorulur (sesle okumaya kayılmaz)")
    }

    func testUnansweredCameraQuestionIsRepeatedOnceThenTheVoiceFlowStartsWithoutTouchingTheNetwork() async {
        let h = harness()
        _ = await h.startListening()
        h.scheduler.advance(by: SilenceWatchdog.limit + 0.1)
        let reminded = await waitUntil(45) { h.speaker.spoken.last == Say.askCameraAgain && self.cameraQuestionOpen(h) }
        XCTAssertTrue(reminded)
        h.scheduler.advance(by: SilenceWatchdog.limit + 0.1)
        let voice = await waitUntil(45) { h.speaker.spoken.last == Say.cameraDefaultVoice && h.vm.listenMode == .question && h.vm.phase == .listening }
        XCTAssertTrue(voice, "Cevap gelmezse güvenli varsayılan: sesle okuma")
        XCTAssertTrue(h.shortcuts.runs.isEmpty)
        XCTAssertEqual(h.camera.captures, 0)
    }

    func testUnclearReplyIsAskedAgainRightAway() async {
        let h = harness()
        _ = await h.startListening()
        h.listener.say("bilmem ki")
        h.scheduler.advance(by: T.numberUnclear + 0.1)
        let again = await waitUntil(45) { h.speaker.spoken.last == Say.askCameraAgain && self.cameraQuestionOpen(h) }
        XCTAssertTrue(again, "Anlaşılmayınca program kendisi tekrar sorar; kullanıcı sessizlikte kalmaz")
        XCTAssertTrue(h.vm.warnings.contains { $0.id == "duyulan" && $0.text.contains("bilmem ki") })
    }

    func testCameraIsNotOfferedWithoutBothShortcutNames() async {
        let h = harness()
        h.settings.internetShortcut = ""
        let listening = await h.startListening()
        XCTAssertTrue(listening)
        XCTAssertEqual(h.speaker.spoken, [Say.readyCameraMissing], "Kestirmeler yazılmamışsa V3 gibi çalışır, ama eksik olduğu söylenir")
        XCTAssertEqual(h.vm.listenMode, .question)
        XCTAssertEqual(h.vm.checkup.first(where: { $0.id == "kamera" })?.ok, false)
    }

    func testTurningTheCameraQuestionOffGivesVersionThreeBehaviour() async {
        let h = harness()
        h.settings.askCamera = false
        _ = await h.startListening()
        XCTAssertEqual(h.speaker.spoken, [Say.ready])
        XCTAssertEqual(h.vm.listenMode, .question)
        XCTAssertNil(h.vm.checkup.first(where: { $0.id == "kamera" }), "Soru kapalıysa kamera maddesi görünmez")
    }
}

/// Sürüm 4: Gemini'ye giden çekim isteği
@MainActor
final class CaptureRequestTests: XCTestCase {
    private func parts(_ data: Data) throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let contents = object["contents"] as! [[String: Any]]
        return contents[0]["parts"] as! [[String: Any]]
    }

    func testPhotoAndVideoAreSentInlineWithTheFrameRate() throws {
        var shot = FakeCamera.shot(bytes: 100_000)
        shot.extraInstruction = "Şıklar küçük yazılmış"
        let body = try GeminiAnswerService.captureBody(shot, expectedNumber: 7)
        let p = try parts(body)
        XCTAssertEqual(p.count, 3)
        XCTAssertTrue((p[0]["text"] as! String).contains("Soru 7"))
        XCTAssertTrue((p[0]["text"] as! String).contains("Şıklar küçük yazılmış"))
        XCTAssertEqual((p[1]["inlineData"] as! [String: Any])["mimeType"] as? String, "image/jpeg")
        XCTAssertEqual((p[2]["inlineData"] as! [String: Any])["mimeType"] as? String, "video/mp4")
        XCTAssertEqual((p[2]["videoMetadata"] as! [String: Any])["fps"] as? Double, VideoRecorder.fps)
        let object = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        XCTAssertEqual((object["generationConfig"] as! [String: Any])["mediaResolution"] as? String, "MEDIA_RESOLUTION_HIGH")
    }

    func testOversizedVideoIsLeftOutAndOnlyThePhotoGoes() throws {
        let shot = FakeCamera.shot(bytes: CapturedQuestion.maxInlineVideoBytes + 1)
        let p = try parts(try GeminiAnswerService.captureBody(shot, expectedNumber: 1))
        XCTAssertEqual(p.count, 2, "Satır içi sınırı aşan video gönderilmez")
    }

    func testFrameRateCanBeLeftOutAndHighResolutionCanBeTurnedOff() throws {
        var shot = FakeCamera.shot()
        shot.highResolution = false
        let body = try GeminiAnswerService.captureBody(shot, expectedNumber: 1, fps: nil)
        XCTAssertNil(try parts(body)[2]["videoMetadata"])
        let object = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        XCTAssertNil(object["generationConfig"])
    }

    func testPromptTellsGeminiToIgnoreHalfVisibleNeighbours() {
        let prompt = GeminiAnswerService.captureSystemPrompt
        XCTAssertTrue(prompt.contains("YOK SAY"))
        XCTAssertTrue(prompt.contains("ortasındaki"))
        XCTAssertTrue(prompt.contains("Soru [numara], [şık sözcüğü], [doğru cevabın metni]"), "Cevap biçimi sesli soruyla aynı")
        let text = GeminiAnswerService.captureText(expectedNumber: 3, hasVideo: false, extra: "")
        XCTAssertTrue(text.contains("Soru 3"))
        XCTAssertFalse(text.contains("video"), "Video yoksa mesajda videodan söz edilmez")
    }
}

/// Sürüm 4 odak kipi: üzerinde çalışılan soru kadrajın ortasındaki bölümdür
final class GuidanceFocusTests: XCTestCase {
    private func col(_ x0: Double, _ x1: Double, y0: Double = 0.2, y1: Double = 0.8) -> ColumnBox {
        return ColumnBox(x0: x0, x1: x1, y0: y0, y1: y1, cells: 300, sharp: 1.0)
    }

    private func metrics(x0: Double, x1: Double, y0: Double = 0.2, y1: Double = 0.8, columns: [ColumnBox] = []) -> PageMetrics {
        var m = PageMetrics()
        m.hasPage = true
        m.hasText = true
        m.x0 = x0; m.x1 = x1; m.y0 = y0; m.y1 = y1
        m.cells = 600
        m.sharp = 1.0
        m.columns = columns
        return m
    }

    private func decide(_ m: PageMetrics, focus: Bool) -> GuidanceDecision {
        var c = GuidanceConfig()
        c.focusQuestion = focus
        return GuidanceAdvisor.decide(m, choice: nil, config: c, sharpFloor: 0.45)
    }

    func testTextRunningOffTheTopAndBottomIsFineBecauseNeighbouringQuestionsContinue() {
        let m = metrics(x0: 0.2, x1: 0.8, y0: GuidanceAnalyzer.skipTop + 0.005, y1: 0.995)
        XCTAssertNotEqual(decide(m, focus: false).advice, .ok, "V1 kipinde taşan yazı düzeltme ister")
        XCTAssertEqual(decide(m, focus: true).advice, .ok, "Odak kipinde üst ve alttan taşma sorun sayılmaz")
    }

    func testCutNeighbouringColumnNeverAsksWhichOneAndTheCentreOneIsUsed() {
        let m = metrics(x0: 0.1, x1: 0.999, columns: [col(0.1, 0.45), col(0.55, 0.999)])
        XCTAssertEqual(decide(m, focus: false).advice, .chooseColumn, "V1 kipinde bölüm sorulur")
        let d = decide(m, focus: true)
        XCTAssertEqual(d.advice, .ok, "Ortaya yakın bölüm tam sığıyor: yandaki yarım sütun sorun değil, bölüm sorulmaz")
    }

    func testTheCentreColumnIsChosenEvenWhenItIsTheRightOne() {
        let m = metrics(x0: 0.001, x1: 0.9, columns: [col(0.001, 0.4), col(0.5, 0.9)])
        XCTAssertEqual(decide(m, focus: true).advice, .ok, "Ortaya yakın olan sağ sütun tam sığıyor; soldaki kesik olsa da")
    }

    func testTheTargetColumnCutAtTheSideStillGetsMoveAdvice() {
        let m = metrics(x0: 0.005, x1: 0.9, columns: [col(0.005, 0.52), col(0.6, 0.9)])
        XCTAssertEqual(decide(m, focus: true).advice, .moveLeft, "Hedef bölüm yandan taşıyorsa yön söylenir")
    }

    func testNoTextIsStillReportedInFocusMode() {
        var m = metrics(x0: 0.2, x1: 0.8)
        m.hasText = false
        XCTAssertEqual(decide(m, focus: true).advice, .blurry)
        m.hasPage = false
        XCTAssertEqual(decide(m, focus: true).advice, .noText)
    }

    func testBlurAndGlareChecksRemainInFocusMode() {
        var m = metrics(x0: 0.2, x1: 0.8)
        m.sharp = 0.1
        XCTAssertEqual(decide(m, focus: true).advice, .blurry)
    }

    func testVerticalRecentringIsNotAskedInFocusMode() {
        // Küçük yazı bloğu üstte: V1 "yaklaşın" derken önce aşağı kaydırma isteyebilir; odak kipinde yalnız yaklaşma / yatay yön söylenir
        let m = metrics(x0: 0.4, x1: 0.6, y0: 0.1, y1: 0.3)
        let advice = decide(m, focus: true).advice
        XCTAssertFalse(advice == .moveUp || advice == .moveDown)
    }
}

@MainActor
final class CameraSupportTests: XCTestCase {
    func testDiskGuardLevels() {
        XCTAssertEqual(DiskGuard.level(freeMB: -1), .ok, "Ölçülemeyen boş yer sorun sayılmaz")
        XCTAssertEqual(DiskGuard.level(freeMB: 100), .critical)
        XCTAssertEqual(DiskGuard.level(freeMB: 1000), .low)
        XCTAssertEqual(DiskGuard.level(freeMB: 5000), .ok)
    }

    func testDecodeClockIsInfiniteUntilAFrameArrives() {
        let clock = DecodeClock()
        XCTAssertEqual(clock.age(), .infinity)
        clock.mark()
        XCTAssertLessThan(clock.age(), 1)
        clock.clear()
        XCTAssertEqual(clock.age(), .infinity)
    }

    func testCapturedQuestionIdentityAndVideoLimit() {
        let a = FakeCamera.shot()
        var b = a
        XCTAssertEqual(a, b)
        b.id = UUID()
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.canSendVideo)
        XCTAssertFalse(FakeCamera.shot(bytes: CapturedQuestion.maxInlineVideoBytes + 1).canSendVideo)
        XCTAssertFalse(FakeCamera.shot(video: false).canSendVideo)
    }

    func testCameraFailureMessagesAreNeverEmpty() {
        let all: [CameraFailure] = [.notConnected, .noFrames, .noPosition, .lowDisk, .captureFailed("x"), .captureFailed(""), .cancelled, .unavailable]
        all.forEach { XCTAssertFalse($0.message.isEmpty) }
    }
}

/// Ayarlar > Kamera > "Kamerayı dene": sınavın adımlarını (kestirme, çekim, internete dönüş) sınavdan önce yürütür
@MainActor
final class CameraTesterTests: XCTestCase {
    private struct Rig {
        let tester: CameraTester
        let camera: FakeCamera
        let shortcuts: FakeShortcuts
        let health: FakeHealth
        let cameraSettings: CameraSettings
    }

    private func rig(sessionActive: Bool = false, cameraShortcut: String = "Kameraya_Gec") -> Rig {
        let defaults = UserDefaults(suiteName: "g526.testler.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        let cameraSettings = CameraSettings(defaults: defaults)
        cameraSettings.cameraShortcutName = cameraShortcut
        settings.internetShortcut = "Hücresele_Gec"
        let camera = FakeCamera()
        let shortcuts = FakeShortcuts()
        let health = FakeHealth()
        let tester = CameraTester(camera: camera, shortcuts: shortcuts, health: health, settings: settings, cameraSettings: cameraSettings,
                                  sessionActive: { sessionActive }, sleep: { _ in })
        return Rig(tester: tester, camera: camera, shortcuts: shortcuts, health: health, cameraSettings: cameraSettings)
    }

    func testRunsTheExamStepsInOrderAndDeletesTheTestShot() async {
        let r = rig()
        let shot = FakeCamera.shot()
        r.camera.results = [.success(shot)]
        await r.tester.run()
        XCTAssertEqual(r.shortcuts.runs, ["Kameraya_Gec", "Hücresele_Gec"], "Önce kameraya geçilir, çekimden sonra internete dönülür")
        XCTAssertEqual(r.camera.captures, 1)
        XCTAssertTrue(r.tester.lines.contains { $0.hasPrefix("✓ Kamera çalıştı") })
        XCTAssertEqual(r.tester.lines.last, "✓ İnternet geldi. Sınama tamam.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: shot.video!.path), "Deneme çekimi telefonda bırakılmaz")
        XCTAssertFalse(r.tester.running)
    }

    func testTheTestShotPhotoIsKeptForThePreviewAndClearedByTheNextRun() async {
        let r = rig()
        let shot = FakeCamera.shot()
        let photo = shot.photo
        r.camera.results = [.success(shot), .failure(.notConnected)]
        await r.tester.run()
        XCTAssertEqual(r.tester.lastPhoto, photo, "Başarılı denemenin fotoğrafı ekranda küçük resim için tutulur")
        await r.tester.run()
        XCTAssertNil(r.tester.lastPhoto, "Sonraki deneme başarısızsa eski resim kalmaz")
    }

    func testTheCameraBatteryLineAppearsOnlyWhenItWasRead() async {
        let r = rig()
        r.camera.results = [.success(FakeCamera.shot(video: false))]
        await r.tester.run()
        XCTAssertFalse(r.tester.lines.contains { $0.hasPrefix("🔋") }, "Pil okunmadıysa satır yazılmaz")
        r.camera.lastBattery = .level(3)
        r.camera.results = [.success(FakeCamera.shot(video: false))]
        await r.tester.run()
        XCTAssertTrue(r.tester.lines.contains("🔋 Kamera pili ≈ %60–80 (son görüntü karesinden okundu)."), "\(r.tester.lines)")
    }

    func testACameraFailureIsReportedAndThePhoneStillReturnsToTheInternet() async {
        let r = rig()
        r.camera.results = [.failure(.notConnected)]
        await r.tester.run()
        XCTAssertTrue(r.tester.lines.contains { $0.hasPrefix("✗ Kameraya bağlanılamadı.") && $0.contains("Yerel Ağ") },
                      "Bağlanılamayınca olası neden (yerel ağ izni, kamera ağı) yazılır")
        XCTAssertEqual(r.shortcuts.runs.last, "Hücresele_Gec", "Telefon kameranın ağında kalmaz")
        XCTAssertEqual(r.tester.lines.last, "✓ İnternet geldi. Sınama tamam.")
    }

    func testReportsWhenTheInternetNeverComesBack() async {
        let r = rig()
        r.camera.results = [.success(FakeCamera.shot(video: false))]
        r.health.internet = false
        await r.tester.run()
        XCTAssertEqual(r.health.internetCalls, CameraTester.internetPolls)
        XCTAssertTrue(r.tester.lines.last?.hasPrefix("✗ İnternet gelmedi") ?? false)
    }

    func testRefusesWhileAnExamIsRunning() async {
        let r = rig(sessionActive: true)
        await r.tester.run()
        XCTAssertTrue(r.shortcuts.runs.isEmpty)
        XCTAssertEqual(r.camera.captures, 0)
        XCTAssertTrue(r.tester.lines.first?.contains("Sınav sürerken") ?? false)
    }

    func testAsksForTheMissingShortcutNameFirst() async {
        let r = rig(cameraShortcut: "")
        await r.tester.run()
        XCTAssertTrue(r.shortcuts.runs.isEmpty)
        XCTAssertTrue(r.tester.lines.first?.contains("“Kameraya geç” kestirmesinin adı") ?? false)
    }

    func testStopCancelsTheCameraButStillReturnsToTheInternet() async {
        let r = rig()
        r.camera.hold = true
        let task = Task { await r.tester.run() }
        let capturing = await waitUntil(45) { r.camera.captures == 1 }
        XCTAssertTrue(capturing)
        XCTAssertTrue(r.tester.running)
        r.tester.stop()
        await task.value
        XCTAssertEqual(r.camera.cancels, 1)
        XCTAssertEqual(r.shortcuts.runs.last, "Hücresele_Gec", "Durdurulunca da telefon kameranın ağında bırakılmaz")
        XCTAssertFalse(r.tester.running)
    }
}

@MainActor
final class LeftoverVideoTests: XCTestCase {
    func testLeftoverVideosAreRemovedAtLaunchAndOtherFilesAreKept() throws {
        let url = CameraCaptureController.newVideoURL()
        try Data([1]).write(to: url)
        let other = CameraCaptureController.videoFolder.appendingPathComponent("baska-dosya.txt")
        try Data([1]).write(to: other)
        CameraCaptureController.purgeLeftoverVideos()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Önceki çalışmadan kalan video silinir")
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path), "Video olmayan dosyaya dokunulmaz")
        try? FileManager.default.removeItem(at: other)
    }
}
