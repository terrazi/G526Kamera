import XCTest
@testable import G526CameraDrive

/// Sınav türleri (kullanıcı kararı 2026-11-17): görüntülü (kamera), sesli (mikrofon + kulaklık), hibrit (her soruda kamera mı sesle mi sorulur).
/// "Sesli sınav başlat", "hibrit sınav başlat", "görüntülü sınav başlat" komutlarıyla sınavın kalanı o türle sürer; denmezse tür aynı kalır.
@MainActor
final class ExamTypeTests: XCTestCase {
    typealias T = SessionViewModel.Timing

    // MARK: Komutlar

    func testTheExamTypeCommandsAreUnderstoodInTheWaysPeopleSayThem() {
        let voice = ["sesli sınav başlat", "Sesli sınav başlat.", "sesli sınava geç", "sesli sınavla devam et", "sınavı sesli yap", "sesli sınav",
                     "sesli moda geç", "lütfen sesli sınava geçelim", "sesle sınav başlat", "sınavın kalanını sesli yap"]
        for text in voice {
            XCTAssertEqual(VoiceCommand.parse(text), .camera(.examType(.voice)), text)
        }
        let hybrid = ["hibrit sınav başlat", "hibrit sınava geç", "hibrid sınav başlat", "karma sınav", "sınavı hibrit yap", "hibrit moda geç", "karışık sınav başlat"]
        for text in hybrid {
            XCTAssertEqual(VoiceCommand.parse(text), .camera(.examType(.hybrid)), text)
        }
        let camera = ["görüntülü sınav başlat", "görüntülü sınava geç", "görüntülü sınava devam", "kameralı sınav", "kameralı sınava geç", "sınavı görüntülü yap",
                      "kamera sınavı başlat", "görüntülü sınavla devam et"]
        for text in camera {
            XCTAssertEqual(VoiceCommand.parse(text), .camera(.examType(.camera)), text)
        }
    }

    func testTheExamTypeQuestionIsUnderstood() {
        for text in ["sınav türü ne", "sınav türü nedir", "hangi sınav türü", "sınav türünü söyle", "şu anki sınav türü ne"] {
            XCTAssertEqual(VoiceCommand.parse(text), .camera(.examTypeAsk), text)
        }
    }

    /// Soru metni, tek başına bir tür sözü ya da çelişen / olumsuz söz komut sayılmaz; eski komutlar aynı kalır
    func testQuestionTextAndOtherCommandsAreNotTakenForAnExamTypeCommand() {
        for text in ["sesli", "kameralı", "sınav başlat", "hibrit", "sesli ve kameralı sınav", "sesli sınav olmasın", "sesli sınava geçme",
                     "sınavda sesli soru okunur", "hibrit sınav nedir", "tipi nedir", "sınav nedir", "görüntülü sınav sistemi hangi yöntemi kullanır"] {
            let parsed = VoiceCommand.parse(text)
            if case .camera(.examType)? = parsed { XCTFail("Komut sayılmamalıydı: \(text)") }
            if case .camera(.examTypeAsk)? = parsed { XCTFail("Komut sayılmamalıydı: \(text)") }
        }
        XCTAssertEqual(VoiceCommand.parse("kamera sorusunu kapat"), .camera(.askQuestion(false)))
        XCTAssertEqual(VoiceCommand.parse("görüntü kalitesini yüksek yap"), .camera(.quality(high: true)))
        XCTAssertEqual(VoiceCommand.parse("testi bitir"), .endTest)
        XCTAssertEqual(VoiceCommand.parse("cevapları tekrarla"), .replayAnswers)
    }

    // MARK: Ayar

    func testTheTypeStartsAsVisualAndAnOldSettingWithoutTheCameraQuestionStartsAsVoice() {
        let fresh = AppSettings(defaults: UserDefaults(suiteName: "g526.tur.\(UUID().uuidString)")!)
        XCTAssertEqual(fresh.examType, .camera, "Varsayılan: görüntülü sınav")
        XCTAssertEqual(fresh.examTypeDefault, .camera)
        XCTAssertTrue(fresh.askCamera)
        let old = UserDefaults(suiteName: "g526.tur.\(UUID().uuidString)")!
        old.set(false, forKey: "v3.askCamera")
        XCTAssertEqual(AppSettings(defaults: old).examType, .voice, "Kamera sorusu kapalı kalmış bir kurulum sesli sınavla başlar")
        let oldOn = UserDefaults(suiteName: "g526.tur.\(UUID().uuidString)")!
        oldOn.set(true, forKey: "v3.askCamera")
        XCTAssertEqual(AppSettings(defaults: oldOn).examType, .camera)
    }

    func testTheTypeAndTheStartingTypeAreKeptSeparatelyAcrossRestarts() {
        let defaults = UserDefaults(suiteName: "g526.tur.\(UUID().uuidString)")!
        let first = AppSettings(defaults: defaults)
        first.examTypeDefault = .hybrid
        first.examType = .voice
        let second = AppSettings(defaults: defaults)
        XCTAssertEqual(second.examTypeDefault, .hybrid)
        XCTAssertEqual(second.examType, .voice, "Kapanıp açılsa da sınavın şu anki türü korunur")
    }

    func testTheOldCameraQuestionSettingStillMapsToTheTypes() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "g526.tur.\(UUID().uuidString)")!)
        settings.askCamera = false
        XCTAssertEqual(settings.examType, .voice)
        XCTAssertEqual(settings.examTypeDefault, .voice, "Eski ayar kalıcıdır")
        settings.askCamera = true
        XCTAssertEqual(settings.examType, .hybrid, "Kamera sorusunu açmak sesli sınavdan hibrite geçirir")
        settings.examType = .camera
        settings.askCamera = true
        XCTAssertEqual(settings.examType, .camera, "Zaten kamera kullanan tür değişmez")
        XCTAssertEqual(ExamType.allCases.count, 3)
        XCTAssertTrue(ExamType.camera.usesCamera && ExamType.hybrid.usesCamera && !ExamType.voice.usesCamera)
    }

    // MARK: Akış

    private func say(_ h: SessionHarness, _ text: String) {
        h.listener.say(text)
        h.scheduler.advance(by: T.numberConfirm + 0.1)
    }

    private func cameraQuestionOpen(_ h: SessionHarness) -> Bool {
        return h.vm.listenMode == .cameraChoice && h.vm.phase == .listening
    }

    /// Komutu söyler; program tam bir cümle söyleyip beklenen kipte dinlemeye dönene kadar bekler ve söylediği cümleyi verir
    private func command(_ h: SessionHarness, _ text: String, mode: ListenMode = .question) async -> String? {
        let before = h.speaker.spoken.count
        say(h, text)
        let done = await waitUntil(45) { h.speaker.spoken.count == before + 1 && h.vm.phase == .listening && h.vm.listenMode == mode }
        XCTAssertTrue(done, "'\(text)' sonrası program bir cümle söyleyip dinlemeye dönmedi: \(h.speaker.spoken)")
        return h.speaker.spoken.last
    }

    private func harness(_ type: ExamType, cameraFlow: Bool = true, pageSeries: Bool = false) -> SessionHarness {
        let h = SessionHarness(cameraFlow: cameraFlow, archive: true, pageSeries: pageSeries)
        h.camera.results = [.success(FakeCamera.shot())]
        h.answering.results = [.success(FakeAnswering.reply(1))]
        h.trackEvents { name in
            if name == "Kameraya_Gec" { h.health.internet = false }
            if name == "Hücresele_Gec" { h.health.internet = true }
            if name == "Hücresel_Ac" { h.health.internet = true }
        }
        h.settings.examType = type
        h.settings.examTypeDefault = type
        return h
    }

    func testTheVisualExamAsksNoYesOrNoQuestionAndStaysOnTheCameraWhenTheUserSaysNo() async {
        let h = harness(.camera)
        _ = await h.startListening()
        XCTAssertEqual(h.speaker.spoken, [Say.readyCamera, Say.askCameraOnly], "Görüntülü sınav: kamera hazır, \"evet / hayır\" sorulmaz")
        XCTAssertTrue(Say.askCameraOnly.contains("sesli sınav başlat"))
        let said = await command(h, "hayır", mode: .cameraChoice)
        XCTAssertEqual(said, Say.cameraOnlyStays, "Hayır sesle okumaya geçirmez; nasıl geçileceği söylenir")
        XCTAssertEqual(h.camera.captures, 0)
        say(h, "başla")
        let done = await waitUntil(45) { h.vm.answers.count == 1 && self.cameraQuestionOpen(h) }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        XCTAssertEqual(h.camera.captures, 1, "Başla denince kamera çekti")
        XCTAssertEqual(h.speaker.spoken.last, Say.askCameraOnly, "Sıradaki soru için yine kamera hazır denir")
    }

    /// Görüntülü sınav sürerken "sesli sınav başlat": kalan sorular sesle okunur; komut verilmezse görüntülü sürerdi
    func testSayingVoiceExamAtTheCameraQuestionContinuesTheRestOfTheExamByVoice() async {
        let h = harness(.camera)
        _ = await h.startListening()
        let said = await command(h, "sesli sınav başlat", mode: .question)
        XCTAssertEqual(said, Say.examTypeChanged(.voice, configured: true, leavingChoice: true, releasing: false, keepsQuestion: false))
        XCTAssertEqual(h.settings.examType, .voice)
        XCTAssertEqual(h.settings.examTypeDefault, .camera, "Yalnız bu sınav sesli olur; sonraki sınav ayardaki türle başlar")
        XCTAssertEqual(h.camera.captures, 0)
        XCTAssertTrue(h.shortcuts.runs.isEmpty, "Hiçbir bağlantı değişmez")
        let before = h.speaker.spoken.count   // başlangıçtaki kamera sorusu geçmişte kalır; komuttan sonrası denetlenir
        h.ask("Soru 1. A seçeneği Adana")
        let answered = await waitUntil(45) { h.vm.answers.count == 1 && h.vm.listenMode == .question && h.vm.phase == .listening }
        XCTAssertTrue(answered, "\(h.speaker.spoken)")
        XCTAssertEqual(h.answering.calls.count, 1, "Soru sesle gitti")
        XCTAssertFalse(h.speaker.spoken.dropFirst(before).contains(Say.askCameraOnly), "Cevaptan sonra kamera sorulmaz: sınavın kalanı sesli")
        XCTAssertEqual(h.camera.captures, 0)
    }

    func testSayingHybridExamAtTheVisualQuestionKeepsTheQuestionAndAsksYesOrNoFromNowOn() async {
        let h = harness(.camera)
        _ = await h.startListening()
        let said = await command(h, "hibrit sınav başlat", mode: .cameraChoice)
        XCTAssertEqual(said, Say.examTypeChanged(.hybrid, configured: true, leavingChoice: false, releasing: false, keepsQuestion: false))
        XCTAssertEqual(h.settings.examType, .hybrid)
        // Hibritte "hayır" sesle okumaya geçirir
        say(h, "hayır")
        let voice = await waitUntil(45) { h.vm.listenMode == .question && h.vm.phase == .listening }
        XCTAssertTrue(voice, "\(h.speaker.spoken)")
        XCTAssertEqual(h.speaker.spoken.last, Say.cameraDeclined)
    }

    /// Sesli sınavda soru metni yokken "görüntülü sınav başlat": kamera hemen sorulur
    func testSayingVisualExamDuringAVoiceExamAsksTheCameraAtOnce() async {
        let h = harness(.voice)
        _ = await h.startListening()
        XCTAssertEqual(h.speaker.spoken, [Say.ready], "Sesli sınavda kamera sorulmaz")
        let before = h.speaker.spoken.count
        say(h, "görüntülü sınav başlat")
        let asked = await waitUntil(45) { self.cameraQuestionOpen(h) && h.speaker.spoken.count == before + 2 }
        XCTAssertTrue(asked, "\(h.speaker.spoken)")
        XCTAssertEqual(h.speaker.spoken.suffix(2), [Say.examTypeChanged(.camera, configured: true, leavingChoice: false, releasing: false, keepsQuestion: false),
                                                    Say.askCameraOnly])
        XCTAssertEqual(h.settings.examType, .camera)
    }

    func testHybridDuringAVoiceExamAlsoAsksTheCameraAtOnce() async {
        let h = harness(.voice)
        _ = await h.startListening()
        let before = h.speaker.spoken.count
        say(h, "hibrit sınav başlat")
        let asked = await waitUntil(45) { self.cameraQuestionOpen(h) && h.speaker.spoken.count == before + 2 }
        XCTAssertTrue(asked, "\(h.speaker.spoken)")
        XCTAssertEqual(h.speaker.spoken.last, Say.askCamera)
    }

    func testTheAlreadyCurrentTypeIsJustReportedAndTheQuestionStaysOpen() async {
        let h = harness(.voice, cameraFlow: false)
        _ = await h.startListening()
        var said = await command(h, "sesli sınav başlat")
        XCTAssertEqual(said, Say.examTypeAlready(.voice))
        said = await command(h, "sınav türü ne")
        XCTAssertEqual(said, Say.examTypeAnswer(.voice))
        XCTAssertEqual(h.settings.examType, .voice)
    }

    func testTheCurrentTypeCanBeAskedInEveryType() async {
        for type in ExamType.allCases {
            let h = harness(type)
            _ = await h.startListening()
            let mode: ListenMode = type == .voice ? .question : .cameraChoice
            let said = await command(h, "sınav türü ne", mode: mode)
            XCTAssertEqual(said, Say.examTypeAnswer(type))
        }
    }

    /// Toplu çekimde kamera hazır beklerken (telefon kameranın Wi-Fi'sinde, internet kapalı) sesliye geçilirse kamera kapanır ve internete dönülür
    func testSwitchingToVoiceWhileTheSeriesCameraWaitsClosesItAndReturnsToTheInternet() async {
        let h = harness(.camera, pageSeries: true)
        _ = await h.startListening()
        XCTAssertTrue(h.camera.holding, "Kamera hazır bekliyor")
        XCTAssertFalse(h.health.internet)
        say(h, "sesli sınav başlat")
        let voice = await waitUntil(45) { h.vm.listenMode == .question && h.vm.phase == .listening && !h.camera.holding }
        XCTAssertTrue(voice, "\(h.speaker.spoken) \(h.events)")
        XCTAssertEqual(h.speaker.spoken.last, Say.examTypeChanged(.voice, configured: true, leavingChoice: true, releasing: true, keepsQuestion: false))
        XCTAssertTrue(h.health.internet, "İnternete dönüldü")
        XCTAssertTrue(h.events.contains("kestirme:Hücresele_Gec"), "\(h.events)")
        XCTAssertEqual(h.settings.examType, .voice)
    }

    /// Eski "kamera sorusunu kapat" komutu da sınav türü kuralına uyar: yalnız bu sınav sesli olur, sonraki sınav Ayarlar'daki tiple başlar
    func testTheOldCameraQuestionCommandOnlyChangesThisExam() async {
        let h = harness(.hybrid)
        _ = await h.startListening()
        XCTAssertEqual(h.vm.listenMode, .cameraChoice)
        let before = h.speaker.spoken.count
        say(h, "kamera sorusunu kapat")
        let left = await waitUntil(45) { h.speaker.spoken.count == before + 1 && h.vm.listenMode == .question && h.vm.phase == .listening }
        XCTAssertTrue(left, "\(h.speaker.spoken)")
        XCTAssertEqual(h.settings.examType, .voice)
        XCTAssertEqual(h.settings.examTypeDefault, .hybrid, "Sonraki sınav yine Ayarlar'daki tiple başlar")
    }

    func testTurningTheCameraQuestionOffWhileTheSeriesCameraWaitsAlsoReturnsToTheInternet() async {
        let h = harness(.camera, pageSeries: true)
        _ = await h.startListening()
        XCTAssertTrue(h.camera.holding)
        say(h, "kamera sorusunu kapat")
        let voice = await waitUntil(45) { h.vm.listenMode == .question && h.vm.phase == .listening && !h.camera.holding }
        XCTAssertTrue(voice, "\(h.speaker.spoken) \(h.events)")
        XCTAssertEqual(h.speaker.spoken.last, Say.cameraAskChanged(on: false, configured: true, leavingChoice: true) + " Kameradan çıkılıyor, internete geçiliyor.")
        XCTAssertTrue(h.health.internet, "İnternete dönüldü")
        XCTAssertEqual(h.settings.examType, .voice)
        XCTAssertEqual(h.settings.examTypeDefault, .camera)
    }

    // MARK: Yeni sınav

    /// Bir sınav yapılıp bitirilir; sınav sırasında tür sesle değiştirilmiştir. Yeni oturumda "önceki kayıt mı, yeni sınav mı" sorulur.
    private func previousExamChangedToVoice(_ h: SessionHarness) async {
        _ = await h.startListening()
        say(h, "evet")
        let done = await waitUntil(45) { h.vm.answers.count == 1 && self.cameraQuestionOpen(h) }
        XCTAssertTrue(done, "\(h.speaker.spoken)")
        h.vm.endTest()
        h.settings.examType = .voice   // sınav sırasında "sesli sınav başlat" denmişti
        _ = await h.startListening()
        XCTAssertEqual(h.vm.listenMode, .startChoice, "\(h.speaker.spoken)")
    }

    func testANewExamStartsWithTheTypeOfTheSettingEvenIfThePreviousExamWasSwitchedByVoice() async {
        let h = harness(.hybrid)
        await previousExamChangedToVoice(h)
        XCTAssertEqual(h.settings.examType, .voice, "Başlangıç sorusu beklenirken önceki sınavın türü durur")
        say(h, "yeni sınav")
        let asked = await waitUntil(45) { self.cameraQuestionOpen(h) }
        XCTAssertTrue(asked, "\(h.speaker.spoken)")
        XCTAssertEqual(h.settings.examType, .hybrid, "Yeni sınav ayardaki başlangıç türüne döner")
    }

    func testContinuingThePreviousRecordKeepsTheTypeOfTheExam() async {
        let h = harness(.hybrid)
        await previousExamChangedToVoice(h)
        let before = h.speaker.spoken.count   // ilk sınavdaki kamera sorusu geçmişte kalır; "Devam"dan sonrası denetlenir
        say(h, "Devam")
        let on = await waitUntil(45) { h.vm.listenMode == .question && h.vm.phase == .listening }
        XCTAssertTrue(on, "\(h.speaker.spoken)")
        XCTAssertEqual(h.settings.examType, .voice, "Kaldığı yerden devam: tür de aynı kalır")
        XCTAssertFalse(h.speaker.spoken.dropFirst(before).contains(Say.askCamera), "Sesli sınav sürüyor: kamera sorulmaz")
    }

    func testAnExamTypeChosenAtTheStartQuestionSurvivesTheNewExamChoice() async {
        let h = harness(.hybrid)
        await previousExamChangedToVoice(h)
        h.settings.examType = .hybrid
        let said = await command(h, "sesli sınav başlat", mode: .startChoice)
        XCTAssertEqual(said, Say.examTypeChanged(.voice, configured: true, leavingChoice: false, releasing: false, keepsQuestion: false))
        let before = h.speaker.spoken.count   // ilk sınavdaki kamera sorusu geçmişte kalır; "yeni sınav"dan sonrası denetlenir
        say(h, "yeni sınav")
        let on = await waitUntil(45) { h.vm.listenMode == .question && h.vm.phase == .listening }
        XCTAssertTrue(on, "\(h.speaker.spoken)")
        XCTAssertEqual(h.settings.examType, .voice, "Başlangıç sorusunda sesle seçilen tür \"yeni sınav\" ile bozulmaz")
        XCTAssertFalse(h.speaker.spoken.dropFirst(before).contains(Say.askCamera))
    }
}
