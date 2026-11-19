import XCTest
import AVFoundation
import CoreGraphics
@testable import G526CameraDrive

/// Otomatik zamanlı başlatmanın saf mantığı (kullanıcı kararı 2026-11-19): karede SORU bulma, saatlerin anı, cümleler, ayarlar
final class QuestionSpotterTests: XCTestCase {
    /// Satırlar üstten alta dizilir; `x`: satırın sol kenarı, `width`: genişliği (Vision ölçüsü 0–1, başlangıç sol alt)
    private func lines(_ texts: [String], x: Double = 0.1, width: Double = 0.8) -> [(text: String, box: CGRect)] {
        return texts.enumerated().map { index, text in
            (text: text, box: CGRect(x: x, y: 0.9 - Double(index) * 0.05, width: width, height: 0.04))
        }
    }

    func testANumberWithItsTextAndTwoOptionsIsAQuestion() {
        let sight = QuestionSpotter.sight(lines(["1. Aşağıdakilerden hangisi örgütsel davranışın konusudur?", "A) Güdüleme", "B) Muhasebe"]))
        XCTAssertEqual(sight.numbers, [1], "Numara, soru metni ve en az iki şık: soru")
        XCTAssertTrue(sight.looksLikeQuestion)
        XCTAssertEqual(sight.shows(1, orLater: false), 1)
    }

    func testTheNumberAloneOrAHeadingOrANumberedNoteIsNotAQuestion() {
        XCTAssertEqual(QuestionSpotter.sight(lines(["1"])).numbers, [], "Sayfa numarası soru değildir")
        XCTAssertEqual(QuestionSpotter.sight(lines(["1. Bölüm", "Sözel Yetenek Testi", "Bu testte 40 soru vardır."])).numbers, [], "Başlığın altında şık yoktur")
        XCTAssertEqual(QuestionSpotter.sight(lines(["1. Cevaplarınızı cevap kâğıdına işaretleyiniz.", "2. Süre 60 dakikadır."])).numbers, [],
                       "Açıklamalardaki numaralı maddelerin altında şık yoktur")
        XCTAssertEqual(QuestionSpotter.sight(lines(["1. Aşağıdakilerden hangisi doğrudur?", "A) Yalnız I"])).numbers, [], "Tek şık yetmez")
        XCTAssertFalse(QuestionSpotter.sight(lines(["1. Bölüm"])).looksLikeQuestion)
    }

    func testOptionsBelongToTheQuestionAboveThemAndAnotherQuestionDoesNotCount() {
        let texts = ["2. İlk sorunun devamı olan uzun bir soru metni", "A) bir", "B) iki", "C) üç", "D) dört", "E) beş",
                     "3. Sıradaki sorunun metni burada başlıyor"]
        let sight = QuestionSpotter.sight(lines(texts))
        XCTAssertEqual(sight.numbers, [2], "3. sorunun şıkları kadrajda yok: soru sayılmaz")
        XCTAssertNil(sight.shows(1, orLater: false), "1. soru beklenirken 2. soru tetiklemez")
        XCTAssertEqual(sight.shows(1, orLater: true), 2, "Sonraki taramalarda beklenen numara ya da daha ilerisi yeter")
        XCTAssertNil(sight.shows(3, orLater: true), "Cevaplanmış eski soru yeniden tetiklemez")
    }

    func testOptionsOnOneLineAndOptionsWithoutTheBracketAreCounted() {
        let oneLine = QuestionSpotter.sight(lines(["7. Sonuç aşağıdakilerden hangisidir sorusu", "A) 5   B) 6   C) 7   D) 8   E) 9"]))
        XCTAssertEqual(oneLine.numbers, [7])
        XCTAssertEqual(QuestionSpotter.optionLetters("A) 5   B) 6   C) 7"), ["A", "B", "C"])
        XCTAssertEqual(QuestionSpotter.optionLetters("E in which stage"), ["E"], "Yazı tanıma ayracı düşürmüş olabilir")
        XCTAssertEqual(QuestionSpotter.optionLetters("Bu bir cümledir"), [], "Sözcük başındaki harf şık değildir")
        XCTAssertEqual(QuestionSpotter.optionLetters("A study of the mind"), [], "Küçük harfli sözcükten önceki A şık değildir")
    }

    func testTheNumberPatternRejectsDecimalsAndLongNumbers() {
        XCTAssertEqual(QuestionSpotter.numbered("12. Aşağıdakilerden hangisi")?.number, 12)
        XCTAssertEqual(QuestionSpotter.numbered("3) Hangisi doğrudur")?.number, 3)
        XCTAssertEqual(QuestionSpotter.numbered("4.Aşağıdaki")?.number, 4, "Boşluksuz yazılmış numara")
        XCTAssertEqual(QuestionSpotter.numbered("5. 2x + 3 = 7 ise x kaçtır")?.number, 5, "Rakamla başlayan soru metni")
        XCTAssertNil(QuestionSpotter.numbered("1.5 kilogram"), "Ondalık sayı numara değildir")
        XCTAssertNil(QuestionSpotter.numbered("2024. yılında"), "Yıl numara değildir")
        XCTAssertNil(QuestionSpotter.numbered("Soru 1. kısım"))
    }

    func testTwoColumnsAreReadSeparately() {
        // Sol sütunda 1. soru ve şıkları, sağ sütunda 5. sorunun yalnız metni: sağ sütun sol sütunun şıklarını almaz
        let left = lines(["1. Sol sütundaki ilk sorunun metni", "A) bir", "B) iki", "C) üç"], x: 0.05, width: 0.35)
        let right = lines(["5. Sağ sütundaki sorunun metni burada", "devam eden ikinci satırı", "ve üçüncü satırı"], x: 0.6, width: 0.35)
        let sight = QuestionSpotter.sight(left + right)
        XCTAssertEqual(sight.numbers, [1])
    }

    func testAQuestionShapeWithoutAReadableNumberIsStillNoticed() {
        let sight = QuestionSpotter.sight(lines(["l. Aşağıdakilerden hangisi örgütsel davranışın konusudur?", "A) Güdüleme", "B) Muhasebe", "C) Finans"]))
        XCTAssertEqual(sight.numbers, [], "\"1.\" yerine \"l.\" okunmuş: numara yok")
        XCTAssertTrue(sight.looksLikeQuestion, "Soru yapısı görünüyor: 20 sn sonra yine de başlanır")
        XCTAssertEqual(QuestionSight(frames: 3, numbers: [1, 2], looksLikeQuestion: true, chars: 240).summary, "3 kare, 240 harf, soru 1,2, soru yapısı var")
    }
}

final class AutoStartPlanTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        return c
    }

    private func date(_ hour: Int, _ minute: Int, day: Int = 19) -> Date {
        return calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    func testAComingHourIsTodayAPassedHourIsNowAndAnOldHourIsTomorrow() {
        XCTAssertEqual(AutoStart.moment(minutes: 9 * 60 + 30, now: date(9, 20), calendar: calendar), date(9, 30), "Henüz gelmedi: bugün")
        XCTAssertEqual(AutoStart.moment(minutes: 9 * 60 + 30, now: date(9, 40), calendar: calendar), date(9, 30), "Az önce geçti: saati gelmiş sayılır")
        XCTAssertEqual(AutoStart.moment(minutes: 8 * 60, now: date(23, 0), calendar: calendar), date(8, 0, day: 20), "Akşamdan basıldı: yarın sabah")
        XCTAssertEqual(AutoStart.moment(minutes: 23 * 60 + 50, now: date(0, 10, day: 20), calendar: calendar), date(23, 50), "Gece yarısını yeni geçti: dünkü saat")
        XCTAssertEqual(AutoStart.clockText(date(9, 5), calendar: calendar), "9:05")
    }

    func testTheSentencesNameTheQuestionAndTheCountdownWordsReachFifteen() {
        XCTAssertEqual(Say.autoShow(number: 1), "Kameranın başlaması için lütfen 1. soruyu okutunuz.")
        XCTAssertEqual(Say.autoShow(number: nil), "Kameranın başlaması için lütfen sıradaki soruyu okutunuz.")
        XCTAssertEqual(Say.autoSeen(number: 1), "1. soru görüldü.")
        XCTAssertEqual(Say.autoDeadline(number: 1, seconds: 15), "1. soru okutulmadı. Kayıt 15 saniye sonra kendiliğinden başlayacak.")
        XCTAssertEqual(Say.autoUnread(number: 9), "9. soru okunamadı, yine de başlıyorum.")
        XCTAssertEqual(Say.autoLost(number: 1), "1. soru görünmüyor. Lütfen yeniden okutunuz.")
        XCTAssertEqual(Say.autoWaiting(clock: "9:30"), "Kamera açılış saati 9:30.", "Program sesli komut istemez")
        XCTAssertEqual(Say.autoGap(seconds: 15, next: 9), "Yeni iki sayfalık tarama 15 saniye sonra başlayacak. Sıradaki soru 9.")
        XCTAssertEqual(AutoStart.gapSeconds, 15)
        XCTAssertEqual((1...15).reversed().map { Say.countWord($0) }.prefix(6).joined(separator: " "), "On beş On dört On üç On iki On bir On")
        XCTAssertEqual(Say.countWord(1), "Bir")
        XCTAssertEqual(AutoStart.questionCountdown, 5)
        XCTAssertEqual(AutoStart.deadlineCountdown, 15)
        XCTAssertEqual(AutoStart.Trigger.question(1).logName, "1. soru görüldü")
    }

    func testTheNextWantedQuestionIsTheSmallestUnansweredAndTheExamEndsWhenNoneIsLeft() {
        XCTAssertEqual(AutoStart.nextMissing(first: 1, answered: []), 1)
        XCTAssertEqual(AutoStart.nextMissing(first: 1, answered: [1, 2, 3]), 4)
        XCTAssertEqual(AutoStart.nextMissing(first: 1, answered: [1, 2, 4, 5]), 3, "Arada cevapsız kalan soru istenir")
        XCTAssertEqual(AutoStart.nextMissing(first: 41, answered: [41, 42]), 43)
        XCTAssertFalse(AutoStart.examComplete(count: 0, nextMissing: 999), "Soru sayısı belirtilmediyse sınav kendiliğinden bitmez")
        XCTAssertFalse(AutoStart.examComplete(count: 40, nextMissing: 40), "Soruların tamamı taranmadan program işine devam eder")
        XCTAssertTrue(AutoStart.examComplete(count: 40, nextMissing: 41))
        XCTAssertEqual(AutoStart.accepted([1, 2], ask: 1, answered: []), 1)
        XCTAssertNil(AutoStart.accepted([2, 3], ask: 1, answered: []), "İlk taramayı yalnız başlangıç sorusu başlatır")
        XCTAssertEqual(AutoStart.accepted([5, 6, 9], ask: 9, answered: Set(1...8)), 9)
        XCTAssertNil(AutoStart.accepted([5, 6], ask: 9, answered: Set(1...8)), "Cevaplanmış eski sayfa yeniden taranmaz")
        XCTAssertEqual(AutoStart.accepted([10, 11], ask: 9, answered: Set(1...8)), 10, "İstenen numaranın ilerisindeki cevapsız soru da başlatır")
        XCTAssertEqual(AutoStart.finalGap, 2, "Sınav sonunda cevaplar arasında 2 sn boşluk")
    }

    func testTheSettingsStartOnAndPersist() {
        let defaults = UserDefaults(suiteName: "g526.testler.otomatik.\(UUID().uuidString)")!
        let fresh = CameraSettings(defaults: defaults)
        XCTAssertTrue(fresh.autoStart, "Otomatik zamanlı başlatma varsayılan açık")
        XCTAssertFalse(fresh.autoOpenEnabled)
        XCTAssertFalse(fresh.autoLatestEnabled)
        XCTAssertEqual(fresh.autoFirstNumber, 1)
        XCTAssertEqual(fresh.autoQuestionCount, 0, "Soru sayısı belirtilmedi")
        fresh.autoQuestionCount = 40
        fresh.autoStart = false
        fresh.autoOpenEnabled = true
        fresh.autoOpenMinutes = 9 * 60 + 30
        fresh.autoLatestEnabled = true
        fresh.autoLatestMinutes = 9 * 60 + 35
        fresh.autoFirstNumber = 41
        let again = CameraSettings(defaults: defaults)
        XCTAssertFalse(again.autoStart)
        XCTAssertTrue(again.autoOpenEnabled)
        XCTAssertEqual(again.autoOpenMinutes, 570)
        XCTAssertTrue(again.autoLatestEnabled)
        XCTAssertEqual(again.autoLatestMinutes, 575)
        XCTAssertEqual(again.autoFirstNumber, 41)
        XCTAssertEqual(again.autoQuestionCount, 40)
        XCTAssertEqual(CameraSettings.minutes(of: CameraSettings.date(minutes: 575)), 575, "Saat seçici dakikayı aynen geri verir")
        defaults.set(999, forKey: "autoQuestionCount")
        XCTAssertEqual(CameraSettings(defaults: defaults).autoQuestionCount, 300, "Üst sınır")
        XCTAssertTrue(AppSettings(defaults: defaults).headsetMic, "Kulaklık mikrofonu varsayılan açık")
        XCTAssertTrue(AppSettings(defaults: defaults).cameraOnlyExam, "Sesli ve hibrit sınav kaldırıldı: yalnız görüntülü")
        XCTAssertEqual(Say.examTypeCameraOnly, "Bu sürümde yalnız görüntülü sınav var.")
    }

    func testTheHeadsetMicrophoneModeNeedsOnlyTheHeadsetAndUsesTheCallProfile() {
        AudioRouting.headsetMicMode = true
        defer { AudioRouting.headsetMicMode = false }
        let both = AudioRouting.verdict(RouteSnapshot(outputs: [.bluetoothHFP], inputs: [.bluetoothHFP]))
        XCTAssertTrue(both.isSafe, "Çıkış da giriş de kulaklık")
        XCTAssertTrue(AudioRouting.verdict(RouteSnapshot(outputs: [.bluetoothHFP], inputs: [])).isSafe, "Mikrofon zorunlu değil")
        let phone = AudioRouting.verdict(RouteSnapshot(outputs: [.builtInReceiver], inputs: [.builtInMic]))
        XCTAssertFalse(phone.headphonesOK, "Kulaklık yoksa ses telefona düşer: güvenli değil")
        XCTAssertFalse(phone.isSafe)
        XCTAssertEqual(AudioSessionGuard.options, [.allowBluetooth], "Kulaklık mikrofonu görüşme profiliyle açılır")
        XCTAssertFalse(AudioSessionGuard.options.contains(.defaultToSpeaker), "Telefonun hoparlörü hiçbir kipte kullanılmaz")
        AudioRouting.headsetMicMode = false
        XCTAssertFalse(AudioRouting.verdict(RouteSnapshot(outputs: [.bluetoothA2DP], inputs: [])).isSafe, "Eski düzende yaka mikrofonu aranır")
    }

    func testTheDeviceShortcutRunsThreeTimesBeforeTheResetAndRetriesStopAfterThreeHours() {
        XCTAssertEqual(RecoveryCoordinator.expanded([.cellular, .reset], deviceTries: 3), [.cellular, .cellular, .cellular, .reset])
        XCTAssertEqual(RecoveryCoordinator.expanded([.bluetooth, .reset], deviceTries: 1), [.bluetooth, .reset], "Eski düzen")
        XCTAssertEqual(RecoveryCoordinator.expanded([.reset], deviceTries: 3), [.reset])
        XCTAssertEqual(RecoveryCoordinator.Config().deviceTries, 1)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(SessionViewModel.outageTooLong(since: nil, now: start))
        XCTAssertFalse(SessionViewModel.outageTooLong(since: start, now: start.addingTimeInterval(3 * 3600 - 1)))
        XCTAssertTrue(SessionViewModel.outageTooLong(since: start, now: start.addingTimeInterval(3 * 3600)), "3 saat dolunca denemeler durur")
        XCTAssertEqual(SessionViewModel.retryGap(rounds: 1), 30, "Tur sonuçsuzsa 30 sn beklenir")
        XCTAssertEqual(SessionViewModel.retryGap(rounds: 5), 30)
        XCTAssertEqual(SessionViewModel.retryGap(rounds: 6), 60, "5 denemeden sonra bekleme 60 sn olur")
    }

    func testThePaidKeyTakesTheFirstThreeSlotsAndAFreeKeyTheFourth() {
        XCTAssertEqual(GeminiProfiles.defaultModels, ["gemini-4-argon", "gemini-3.8-flash", "gemini-3.7-flash", "gemini-3.5-flash-lite"])
        XCTAssertEqual(GeminiProfiles.defaultFree, [false, false, false, true], "Ücretli modeller en iyisinden başlayarak önde, dördüncü ücretsiz")
        let old = [GeminiProfile(name: "Ücretli", model: "gemini-3.1-flash-lite", free: false), GeminiProfile(name: "A", model: "gemini-3.6-flash", free: true),
                   GeminiProfile(name: "B", model: "gemini-3.5-flash-lite", free: true), GeminiProfile(name: "C", model: "gemini-3.1-flash-lite", free: true)]
        let lineup = GeminiProfiles.paidLineup(profiles: old, keys: ["PAID", "", "FREE-2", "FREE-3"])
        XCTAssertEqual(lineup?.keys, ["PAID", "PAID", "PAID", "FREE-2"], "Ücretli anahtar ilk üç yuvaya, ilk dolu ücretsiz anahtar dördüncüye")
        XCTAssertEqual(lineup?.profiles, GeminiProfiles.defaults())
        XCTAssertNil(GeminiProfiles.paidLineup(profiles: old, keys: ["", "F1", "F2", "F3"]), "Ücretli anahtar yoksa dokunulmaz")
        XCTAssertEqual(GeminiProfiles.paidLineup(profiles: old, keys: ["PAID", "", "", ""])?.keys, ["PAID", "PAID", "PAID", ""])
    }
}

/// Otomatik zamanlı başlatmanın akışı: saat, soru, en geç başlama ve sesli komut tetikleri (hangisi önce gelirse; ötekiler iptal olur)
@MainActor
final class AutoStartFlowTests: XCTestCase {
    typealias T = SessionViewModel.Timing

    private func series() -> Result<PageSeries, CameraFailure> {
        return .success(PageSeries(shot: FakeCamera.page(1, photos: 75), planned: 75, failure: nil, readable: true))
    }

    private func harness(seriesResults: [Result<PageSeries, CameraFailure>], pageReplies: [Result<[GeminiReply], Error>]) -> SessionHarness {
        let h = SessionHarness(cameraFlow: true, pageSeries: true)
        h.cameraSettings.autoStart = true
        h.camera.seriesResults = seriesResults
        h.answering.pageResults = pageReplies
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

    /// Sınama saatinin (düzenekteki donuk "şimdi") `seconds` sn sonrasının gün içi dakikası
    private func minutes(after seconds: TimeInterval) -> Int {
        return CameraSettings.minutes(of: Date(timeIntervalSince1970: 1_800_000_000 + seconds))
    }

    private let questionOne = QuestionSight(frames: 3, numbers: [1], looksLikeQuestion: true, chars: 240)
    private let nothing = QuestionSight(frames: 3, numbers: [], looksLikeQuestion: false, chars: 0)

    func testWithoutAnOpeningHourTheCameraOpensAtOnceAndQuestionOneStartsTheScanAfterCountingFromFive() async {
        let h = harness(seriesResults: [series(), series()],
                        pageReplies: [.success([FakeAnswering.reply(1), FakeAnswering.reply(2)]), .success([FakeAnswering.reply(3)])])
        _ = await h.startListening()
        XCTAssertTrue(h.camera.holding, "Açılış saati yok: kamera hemen açılır")
        XCTAssertEqual(Array(h.speaker.spoken.suffix(2)), [Say.seriesConnecting, Say.autoShow(number: 1)], "\(h.speaker.spoken)")
        XCTAssertTrue(waiting(h), "\"Başla\" da dinlenir")
        XCTAssertEqual(h.camera.seriesCalls.count, 0, "Soru görülmeden süre başlamaz")
        h.camera.sights = [questionOne]
        h.scheduler.advance(by: AutoStart.tick + 0.1)
        let started = await waitUntil(10) { h.camera.seriesCalls.count == 1 }
        XCTAssertTrue(started, "\(h.speaker.spoken)")
        let spoken = h.speaker.spoken
        guard let seen = spoken.firstIndex(of: Say.autoSeen(number: 1)), let go = spoken.firstIndex(of: Say.seriesGo) else {
            return XCTFail("\(spoken)")
        }
        XCTAssertEqual(Array(spoken[(seen + 1)..<go]), (1...5).reversed().map { Say.countWord($0) }, "Soru görülünce beşten bire sayılır, sonra \"Başladı.\"")
        XCTAssertEqual(h.camera.seriesHeldAtStart, [true], "Tarama açık bekleyen bağlantıyla hemen başlar")
        // Cevaplar okununca kamera kendiliğinden yeniden açılır ve sıradaki soru istenir
        let next = await waitUntil(45) { h.vm.answers.count == 2 && self.waiting(h) && h.camera.holding }
        XCTAssertTrue(next, "\(h.speaker.spoken)")
        XCTAssertEqual(h.speaker.spoken.last, Say.autoGap(seconds: 15, next: 3), "İki tarama arasında 15 sn boşluk duyurulur; sıradaki 3. soru")
        XCTAssertEqual(h.vm.auto.rounds, 1)
        // Boşluğun son 5 saniyesi gelmeden tarama başlamaz; gelince beşten sayılıp başlanır (soru görülmesi beklenmez)
        h.scheduler.advance(by: 3)
        await settle()
        XCTAssertEqual(h.camera.seriesCalls.count, 1, "Boşluk dolmadı")
        h.clock.offset += Double(AutoStart.gapSeconds - AutoStart.questionCountdown) + 1
        h.scheduler.advance(by: AutoStart.tick + 0.1)
        let second = await waitUntil(10) { h.camera.seriesCalls.count == 2 }
        XCTAssertTrue(second, "\(h.speaker.spoken)")
        let after = Array(h.speaker.spoken.drop(while: { $0 != Say.autoGap(seconds: 15, next: 3) }).dropFirst().prefix(6))
        XCTAssertEqual(after, (1...5).reversed().map { Say.countWord($0) } + [Say.seriesGo], "Son 5 saniyede beşten bire sayılır, sonra \"Başladı.\"")
    }

    func testBeforeTheOpeningHourTheCameraStaysClosedAndOpensWhenTheHourComes() async {
        let h = harness(seriesResults: [], pageReplies: [])
        h.cameraSettings.autoOpenEnabled = true
        h.cameraSettings.autoOpenMinutes = minutes(after: 600)
        _ = await h.startListening()
        XCTAssertFalse(h.camera.holding, "Saat gelmeden kameraya bağlanılmaz")
        XCTAssertTrue(h.health.internet, "Kamera kapalı: internet açık")
        XCTAssertTrue(h.speaker.spoken.last?.hasPrefix("Kamera açılış saati") ?? false, "\(h.speaker.spoken)")
        XCTAssertTrue(waiting(h))
        h.scheduler.advance(by: 5)
        await settle()
        XCTAssertFalse(h.camera.holding, "Saat gelmedi")
        XCTAssertEqual(h.events, [])
        h.clock.offset = 601
        h.scheduler.advance(by: AutoStart.tick + 0.1)
        let opened = await waitUntil(10) { h.camera.holding && self.waiting(h) }
        XCTAssertTrue(opened, "\(h.speaker.spoken)")
        XCTAssertEqual(Array(h.speaker.spoken.suffix(2)), [Say.seriesConnecting, Say.autoShow(number: 1)])
        XCTAssertEqual(h.camera.seriesCalls.count, 0, "Kamera açıldı ama soru görülmeden süre başlamaz")
    }

    func testWhenTheLatestHourComesTheScanStartsByItselfAfterCountingFromFifteen() async {
        let h = harness(seriesResults: [series()], pageReplies: [.success([FakeAnswering.reply(1)])])
        h.cameraSettings.autoLatestEnabled = true
        h.cameraSettings.autoLatestMinutes = minutes(after: 600)
        _ = await h.startListening()
        XCTAssertTrue(h.camera.holding)
        h.scheduler.advance(by: 3)
        await settle()
        XCTAssertEqual(h.camera.seriesCalls.count, 0, "En geç başlama saati gelmedi")
        h.clock.offset = 601
        h.scheduler.advance(by: AutoStart.tick + 0.1)
        let started = await waitUntil(10) { h.camera.seriesCalls.count == 1 }
        XCTAssertTrue(started, "\(h.speaker.spoken)")
        let spoken = h.speaker.spoken
        guard let notice = spoken.firstIndex(of: Say.autoDeadline(number: 1, seconds: 15)), let go = spoken.firstIndex(of: Say.seriesGo) else {
            return XCTFail("\(spoken)")
        }
        XCTAssertEqual(Array(spoken[(notice + 1)..<go]), (1...15).reversed().map { Say.countWord($0) }, "On beşten bire sayılır, sonra \"Başladı.\"")
    }

    func testTheSpokenStartBeforeTheHoursCancelsTheTimers() async {
        let h = harness(seriesResults: [series()], pageReplies: [.success([FakeAnswering.reply(1)])])
        h.cameraSettings.autoOpenEnabled = true
        h.cameraSettings.autoOpenMinutes = minutes(after: 600)
        h.cameraSettings.autoLatestEnabled = true
        h.cameraSettings.autoLatestMinutes = minutes(after: 900)
        _ = await h.startListening()
        XCTAssertFalse(h.camera.holding)
        h.listener.say("başla")
        h.scheduler.advance(by: T.numberConfirm + 0.1)
        let started = await waitUntil(10) { h.camera.seriesCalls.count == 1 }
        XCTAssertTrue(started, "\(h.speaker.spoken)")
        XCTAssertFalse(h.speaker.spoken.contains(Say.autoShow(number: 1)), "Sesli komut önce geldi: soru beklenmez")
        XCTAssertFalse(h.speaker.spoken.contains(Say.autoDeadline(number: 1, seconds: 15)), "Sayaçlar iptal oldu")
        XCTAssertTrue(h.speaker.spoken.contains(Say.seriesGetReady), "Sesle başlatmada kamera açılır, \"Hazır olun\" ve geri sayımla başlanır")
        XCTAssertEqual(h.vm.auto.rounds, 1)
    }

    func testIfTheQuestionLeavesTheFrameDuringTheCountdownTheScanDoesNotStart() async {
        let h = harness(seriesResults: [series()], pageReplies: [])
        _ = await h.startListening()
        h.camera.sights = [questionOne, nothing, nothing, nothing]
        h.scheduler.advance(by: AutoStart.tick + 0.1)
        let back = await waitUntil(10) { h.speaker.spoken.contains(Say.autoLost(number: 1)) && self.waiting(h) }
        XCTAssertTrue(back, "\(h.speaker.spoken)")
        XCTAssertEqual(h.camera.seriesCalls.count, 0, "Soru kayboldu: süre başlamadı")
        XCTAssertTrue(h.camera.holding, "Kamera açık, soru yeniden beklenir")
    }

    func testAQuestionWhoseNumberCannotBeReadStartsTheScanAfterTwentySeconds() async {
        let h = harness(seriesResults: [series()], pageReplies: [.success([FakeAnswering.reply(1)])])
        _ = await h.startListening()
        let unread = QuestionSight(frames: 3, numbers: [], looksLikeQuestion: true, chars: 240)
        h.camera.sights = [unread, unread]
        h.scheduler.advance(by: AutoStart.tick + 0.1)
        await settle()
        XCTAssertEqual(h.camera.seriesCalls.count, 0)
        XCTAssertNotNil(h.vm.auto.unreadSince, "Soru yapısı görüldü: süre tutulur")
        h.clock.offset = AutoStart.unreadSeconds + 1
        h.scheduler.advance(by: AutoStart.tick + 0.1)
        let started = await waitUntil(10) { h.camera.seriesCalls.count == 1 }
        XCTAssertTrue(started, "\(h.speaker.spoken)")
        XCTAssertTrue(h.speaker.spoken.contains(Say.autoUnread(number: 1)))
    }

    func testWhenTheCameraDoesNotAnswerTheDeviceShortcutRunsThreeTimesThenTheResetAndTheNextRoundConnects() async {
        let h = harness(seriesResults: [], pageReplies: [])
        // Birinci tur: üç deneme ve sıfırlamadan sonraki deneme sonuçsuz; ikinci turun ilk denemesinde kamera bağlanır
        h.camera.holdResults = Array(repeating: .failure(.notConnected), count: 4) + [.success(())]
        h.vm.start()
        let ready = await waitUntil(20) { self.waiting(h) && h.camera.holding }
        XCTAssertTrue(ready, "\(h.speaker.spoken)")
        XCTAssertEqual(h.camera.holdOpens, 5, "Vazgeçilmez: tur sonuçsuzsa beklenip yeniden denenir")
        let runs = h.shortcuts.runs
        XCTAssertEqual(runs.filter { $0 == "Kamera_Onar" }.count, 2, "Aygıtın kestirmesi: ilk deneme + iki onarım = üç deneme")
        XCTAssertEqual(runs.filter { $0 == "Sistemi_Sifirla" }.count, 1, "Üç denemede açılmadı: uçak modu kestirmesi")
        if let reset = runs.firstIndex(of: "Sistemi_Sifirla"), let repair = runs.lastIndex(of: "Kamera_Onar") {
            XCTAssertGreaterThan(reset, repair, "Sıfırlama üç denemeden sonra çalışır")
        } else {
            XCTFail("\(runs)")
        }
        XCTAssertTrue(h.sleepLog.entries.contains { $0.seconds == T.quickRetry }, "Turlar arasında 30 sn beklenir")
        XCTAssertEqual(h.speaker.spoken.last, Say.autoShow(number: 1), "Kamera bağlanınca akış kaldığı yerden sürer")
        XCTAssertEqual(T.cameraPersistResetAfter, 3)
        XCTAssertEqual(T.outageLimit, 3 * 3600, "Denemeler en çok 3 saat sürer")
    }

    func testEmptyScansAreCountedAndTheLimitDependsOnWhetherTheQuestionCountIsSet() async {
        let h = harness(seriesResults: [], pageReplies: [])
        XCTAssertEqual(h.vm.auto.emptyScans, 0)
        h.vm.noteEmptyScan()
        h.vm.noteEmptyScan()
        XCTAssertEqual(h.vm.auto.emptyScans, 2, "Gemini'nin soru bulamadığı taramalar sayılır")
        XCTAssertEqual(AutoStart.emptyScanLimit(count: 0), 10, "Soru sayısı girilmemişse art arda 10 boş taramada sınav kapanır")
        XCTAssertEqual(AutoStart.emptyScanLimit(count: 40), 20, "Soru sayısı girilmişse 20 boş taramada")
        // Kapanan sınav yarıda kaldığı yerden sürer; yeni sınav yalnız düğmeyle ya da önceki sınav tamamlandıysa açılır
        XCTAssertFalse(AutoStart.startsNewExam(force: false, finished: "", previous: "20261119080000"), "\"Başlat\" yeni sınav açmaz")
        XCTAssertFalse(AutoStart.startsNewExam(force: false, finished: "20261118230000", previous: "20261119080000"), "Tamamlanan başka bir sınavdı")
        XCTAssertTrue(AutoStart.startsNewExam(force: false, finished: "20261119080000", previous: "20261119080000"), "Önceki sınav tamamlanmıştı")
        XCTAssertTrue(AutoStart.startsNewExam(force: true, finished: "", previous: "20261119080000"), "\"Yeni sınav başlat\" düğmesi")
        XCTAssertFalse(AutoStart.startsNewExam(force: false, finished: "x", previous: nil))
        XCTAssertEqual(Say.autoResumeReport(answered: 8, total: 40, last: 8),
                       "Önceki sınav yarıda kalmış. 40 sorudan 8 soru cevaplandı; son cevaplanan 8. soru. Kaldığı yerden devam ediyorum.")
        XCTAssertEqual(Say.autoResumeReport(answered: 3, total: 0, last: nil), "Önceki sınav yarıda kalmış. 3 soru cevaplandı. Kaldığı yerden devam ediyorum.")
        XCTAssertFalse(h.vm.autoSequential, "Cevap yokken ilk tetik aranır (saat, soru görme, sesli komut)")
        XCTAssertEqual(Say.autoEmptyStop(scans: 2), "Art arda 2 taramada soru bulunamadı. Sınav kapatılıyor.")
        // Program sesli komut istemez: çekim olmazsa "soruyu okuyun" denmez, tarama yeniden denenir
        XCTAssertTrue(Say.cameraFailed(.noFrames).hasSuffix(Say.readInstead))
        XCTAssertFalse((Say.cameraFailed(.noFrames).replacingOccurrences(of: Say.readInstead, with: "") + " " + Say.autoRetry).contains("Cevapla"))
    }
}
