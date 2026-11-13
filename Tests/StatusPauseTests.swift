import XCTest
@testable import G526CameraDrive

/// "Durum bilgisi ver", "duraklat" ve "devam et" komutları: söz listeleri, komut çakışması ve söylenen cümleler
final class StatusPauseTests: XCTestCase {
    // MARK: Söz listeleri

    private func hits(_ phrases: String, _ text: String) -> Int {
        return SpeechMatcher.occurrences(in: text, trigger: phrases)
    }

    private func statusHits(_ text: String) -> Int {
        return hits(GuidanceVocabulary.status, text) + GuidanceVocabulary.statusIntent.count(in: text)
    }

    func testManyWaysToAskForStatus() {
        for t in ["durum bilgisi ver", "Durum bilgisi ver", "durum bilgisini ver", "durum bilgisi verir misin", "durum bilgisi",
                  "durum bilgisini söyle", "durum bilgi ver", "sistem durumu", "sistemin durumunu söyle", "telefon durumu",
                  "telefonun durumu nedir", "performans nasıl", "performansı ne durumda", "performans durumu", "performans bilgisi ver"] {
            XCTAssertGreaterThan(statusHits(t), 0, t)
        }
    }

    func testOtherSpeechDoesNotAskForStatus() {
        for t in ["rapor ver", "durum nedir", "durum ver", "kaç sayfa çekildi", "şarj durumu nedir", "batarya kontrol", "hepsini gönder",
                  "bilgi ver", "tamam", "okey", "duraklat", "devam et", "son fotoğrafı sil", "yeniden çek", "özet ver"] {
            XCTAssertEqual(statusHits(t), 0, t)
        }
    }

    func testManyWaysToPause() {
        for t in ["duraklat", "Duraklat", "duraklatın", "duraklatalım", "duraklatır mısın", "her şeyi duraklat", "işlemleri duraklat",
                  "tüm işlemleri duraklat", "mola ver"] {
            XCTAssertGreaterThan(hits(GuidanceVocabulary.pause, t), 0, t)
        }
    }

    func testOtherSpeechDoesNotPause() {
        for t in ["devam et", "durdur", "kaydı durdur", "videoyu durdur", "durum bilgisi ver", "rapor ver", "bekle", "tamam", "kapat",
                  "hepsini gönder", "mola"] {
            XCTAssertEqual(hits(GuidanceVocabulary.pause, t), 0, t)
        }
    }

    func testManyWaysToResume() {
        for t in ["devam et", "Devam et", "devam edin", "devam edelim", "devam edebilirsin", "devam", "kaldığımız yerden devam et",
                  "kaldığın yerden devam", "tamam devam et"] {
            XCTAssertGreaterThan(hits(GuidanceVocabulary.resume, t), 0, t)
        }
    }

    func testOtherSpeechDoesNotResume() {
        for t in ["duraklat", "durdur", "kaydı durdur", "videoyu durdur", "durum bilgisi ver", "sürdür", "rapor ver", "tamam", "okey",
                  "hepsini gönder"] {
            XCTAssertEqual(hits(GuidanceVocabulary.resume, t), 0, t)
        }
    }

    // MARK: Komut çakışması

    func testStatusWinsOverReportAndBattery() {
        XCTAssertEqual(SpeechTrigger.resolve(["report", "status"]).ids, ["status"])
        XCTAssertEqual(SpeechTrigger.resolve(["battery", "report", "status"]).ids, ["status"])
        XCTAssertEqual(SpeechTrigger.resolve(["status"]).ids, ["status"])
    }

    func testOldCommandsKeepWorking() {
        XCTAssertEqual(SpeechTrigger.resolve(["report", "battery"]).ids, ["battery"])
        XCTAssertEqual(SpeechTrigger.resolve(["report"]).ids, ["report"])
        XCTAssertEqual(SpeechTrigger.resolve(["finish", "report"]).ids, ["finish", "report"])
        XCTAssertEqual(SpeechTrigger.resolve(["deleteLast", "finish", "report"]).ids, ["deleteLast"])
        XCTAssertEqual(SpeechTrigger.resolve(["retake", "deleteLast"]).ids, ["retake"])
        XCTAssertEqual(SpeechTrigger.resolve(["model", "pick.1", "model2"]).ids, ["model2"])
    }

    func testPauseAndResumeTogetherDoNothing() {
        XCTAssertEqual(SpeechTrigger.resolve(["pause", "resume"]).ids, [])
        XCTAssertEqual(SpeechTrigger.resolve(["pause"]).ids, ["pause"])
        XCTAssertEqual(SpeechTrigger.resolve(["resume"]).ids, ["resume"])
        XCTAssertEqual(SpeechTrigger.resolve(["resume", "finish"]).ids, ["resume", "finish"])
    }

    func testChoiceWordsStillPassThrough() {
        let r = SpeechTrigger.resolve(["choice.left"])
        XCTAssertEqual(r.choiceIDs, ["choice.left"])
        XCTAssertEqual(r.ids, ["choice.left"])
        let two = SpeechTrigger.resolve(["choice.left", "choice.right"])
        XCTAssertEqual(two.choiceIDs.count, 2)
        XCTAssertEqual(two.ids, [])
        XCTAssertEqual(SpeechTrigger.resolve(["status", "choice.left"]).ids, ["status", "choice.left"])
    }

    // MARK: Duraklatılmış cümlesi

    func testPausedStatusIsExactlyTheRequestedSentence() {
        XCTAssertEqual(StatusReport.pausedNotice,
                       "İşlemler duraklatıldı. Kaldığınız yerden devam etmek için lütfen devam et komutunu verin.")
        let w = StatusReport.Work(camera: .live, internetDown: false, examLine: "Sınav taraması sürüyor, 3 sayfa tarandı.")
        XCTAssertEqual(StatusReport.make(work: w, phone: StatusReport.Phone(), paused: true), StatusReport.pausedNotice)
        XCTAssertTrue(StatusReport.pausing.contains("devam et"))
        XCTAssertEqual(StatusReport.resuming, "Devam ediyorum.")
    }

    // MARK: Telefon cümlesi

    private func phone(_ edit: (inout StatusReport.Phone) -> Void = { _ in }) -> String {
        var p = StatusReport.Phone(thermal: 0, memoryMB: 640, freeMB: 12_400, battery: 74, charging: false, lowPower: false,
                                   stalls: 0, lightMode: false)
        edit(&p)
        return StatusReport.phone(p)
    }

    func testHealthyPhoneSentence() {
        XCTAssertEqual(phone(), "Telefon iyi durumda: ısı normal, bellek rahat (640 megabayt), ekran takılmıyor, pil yüzde 74, boş yer 12 gigabayt.")
    }

    func testPhoneProblemsAreFlaggedUpFront() {
        XCTAssertTrue(phone { $0.thermal = 2 }.hasPrefix("Telefonda dikkat edilecek durum var: ısı ciddi yüksek"))
        XCTAssertTrue(phone { $0.thermal = 3 }.contains("ısı kritik"))
        XCTAssertTrue(phone { $0.memoryMB = 1200 }.contains("bellek yüksek (1200 megabayt)"))
        XCTAssertTrue(phone { $0.memoryMB = 1200 }.hasPrefix("Telefonda dikkat"))
        XCTAssertTrue(phone { $0.memoryMB = 1600 }.contains("bellek kritik (1600 megabayt)"))
        XCTAssertTrue(phone { $0.stalls = 3 }.hasPrefix("Telefonda dikkat"))
        XCTAssertTrue(phone { $0.stalls = 3 }.contains("ekran son dakikada 3 kez takıldı"))
        XCTAssertTrue(phone { $0.battery = 15 }.contains("pil yüzde 15, düşük"))
        XCTAssertTrue(phone { $0.battery = 15 }.hasPrefix("Telefonda dikkat"))
        XCTAssertTrue(phone { $0.freeMB = 900 }.contains("boş yer az (900 megabayt)"))
        XCTAssertTrue(phone { $0.freeMB = 300 }.contains("boş yer çok az (300 megabayt)"))
        XCTAssertTrue(phone { $0.freeMB = 300 }.hasPrefix("Telefonda dikkat"))
        XCTAssertTrue(phone { $0.lightMode = true }.contains("yük azaltıldı, canlı önizleme kapalı"))
        XCTAssertTrue(phone { $0.lightMode = true }.hasPrefix("Telefonda dikkat"))
    }

    func testMinorPhoneFactsDoNotRaiseAlarm() {
        XCTAssertTrue(phone { $0.thermal = 1 }.hasPrefix("Telefon iyi durumda"))
        XCTAssertTrue(phone { $0.thermal = 1 }.contains("ısı hafif yüksek"))
        XCTAssertTrue(phone { $0.stalls = 1 }.hasPrefix("Telefon iyi durumda"))
        XCTAssertTrue(phone { $0.stalls = 1 }.contains("ekran son dakikada 1 kez takıldı"))
        XCTAssertTrue(phone { $0.lowPower = true }.contains("düşük güç modu açık"))
        XCTAssertTrue(phone { $0.lowPower = true }.hasPrefix("Telefon iyi durumda"))
        let charging = phone { $0.battery = 15; $0.charging = true }
        XCTAssertTrue(charging.contains("pil yüzde 15, şarjda"))
        XCTAssertTrue(charging.hasPrefix("Telefon iyi durumda"))
    }

    func testUnknownMeasurementsAreLeftOut() {
        let s = phone { $0.memoryMB = -1; $0.freeMB = -1; $0.battery = nil }
        XCTAssertFalse(s.contains("bellek"))
        XCTAssertFalse(s.contains("boş yer"))
        XCTAssertTrue(s.contains("pil bilgisi okunamıyor"))
        XCTAssertTrue(s.hasSuffix("."))
    }

    func testSpaceWording() {
        XCTAssertEqual(StatusReport.space(500), "500 megabayt")
        XCTAssertEqual(StatusReport.space(999), "999 megabayt")
        XCTAssertEqual(StatusReport.space(1000), "1,0 gigabayt")
        XCTAssertEqual(StatusReport.space(4500), "4,5 gigabayt")
        XCTAssertEqual(StatusReport.space(12_400), "12 gigabayt")
    }

    // MARK: Ne yapılıyor

    private func work(_ edit: (inout StatusReport.Work) -> Void = { _ in }) -> StatusReport.Work {
        var w = StatusReport.Work()
        edit(&w)
        return w
    }

    func testIdleActivity() {
        XCTAssertEqual(StatusReport.activity(work()), "Boştayım, komut bekliyorum.")
        XCTAssertTrue(StatusReport.activity(work { $0.guided = true }).contains("sesli konumlandırma açık"))
    }

    func testBusyActivities() {
        XCTAssertEqual(StatusReport.activity(work { $0.recording = true }), "Video kaydediliyor.")
        XCTAssertTrue(StatusReport.activity(work { $0.pageVideoPages = 3 }).contains("3 sayfa kaydedildi"))
        XCTAssertTrue(StatusReport.activity(work { $0.pageVideoPages = 0 }).contains("ilk sayfayı bekliyorum"))
        XCTAssertEqual(StatusReport.activity(work { $0.capturing = true }), "Fotoğraf işleniyor.")
        XCTAssertEqual(StatusReport.activity(work { $0.gemini = true }), "Gemini ile konuşma sürüyor.")
        XCTAssertEqual(StatusReport.activity(work { $0.sendingVideos = true }), "Videolar Gemini'ye gönderiliyor.")
        XCTAssertEqual(StatusReport.activity(work { $0.saving = true; $0.waitingPages = 1 }), "Sayfa klasöre kaydediliyor.")
        XCTAssertEqual(StatusReport.activity(work { $0.saving = true; $0.waitingPages = 4 }),
                       "Sayfalar klasöre kaydediliyor, 4 sayfa bekliyor.")
        XCTAssertEqual(StatusReport.activity(work { $0.queuedVideos = 2 }), "Sırada 2 video var.")
    }

    func testWaitingPagesExplainWhy() {
        XCTAssertEqual(StatusReport.activity(work { $0.waitingPages = 4 }), "4 sayfa gönderilmeyi bekliyor.")
        XCTAssertTrue(StatusReport.activity(work { $0.waitingPages = 4; $0.folderReady = false }).contains("Belge klasörü seçilmemiş."))
        XCTAssertTrue(StatusReport.activity(work { $0.waitingPages = 4; $0.uploadError = true }).contains("Son gönderim başarısız oldu"))
    }

    func testExamLineReplacesTheIdleSentence() {
        let line = "Deneme sınavı modu açık, sınav başlamadı."
        XCTAssertEqual(StatusReport.activity(work { $0.examLine = line }), line)
        let busy = StatusReport.activity(work { $0.examLine = line; $0.recording = true })
        XCTAssertEqual(busy, line + " Video kaydediliyor.")
    }

    func testLinkSentences() {
        XCTAssertEqual(StatusReport.link(work()), "Kamera bağlı.")
        XCTAssertEqual(StatusReport.link(work { $0.camera = .off }), "Kamera bağlı değil.")
        XCTAssertEqual(StatusReport.link(work { $0.camera = .connecting }), "Kameraya bağlanılıyor.")
        XCTAssertEqual(StatusReport.link(work { $0.camera = .reconnecting }), "Kamera yeniden bağlanıyor.")
        XCTAssertTrue(StatusReport.link(work { $0.camera = .noPicture }).contains("görüntü gelmiyor"))
        XCTAssertEqual(StatusReport.link(work { $0.internetDown = true }), "Kamera bağlı. İnternet yok.")
    }

    func testFullSentenceOrderIsActivityThenLinksThenPhone() {
        let text = StatusReport.make(work: work { $0.recording = true }, phone: StatusReport.Phone(thermal: 0, memoryMB: 640, freeMB: -1,
                                                                                                   battery: 74, charging: false,
                                                                                                   lowPower: false, stalls: 0, lightMode: false),
                                     paused: false)
        XCTAssertEqual(text, "Video kaydediliyor. Kamera bağlı. Telefon iyi durumda: ısı normal, bellek rahat (640 megabayt), ekran takılmıyor, pil yüzde 74.")
    }

    func testSystemPartLeavesOutTheActivity() {
        let text = StatusReport.system(work: work { $0.recording = true; $0.internetDown = true }, phone: StatusReport.Phone())
        XCTAssertTrue(text.hasPrefix("Kamera bağlı. İnternet yok. Telefon"))
        XCTAssertFalse(text.contains("Video"))
    }

    func testStatusSentenceStaysShort() {
        let text = StatusReport.make(work: work { $0.waitingPages = 3 }, phone: StatusReport.Phone(thermal: 0, memoryMB: 640, freeMB: 12_400,
                                                                                                   battery: 74, charging: false,
                                                                                                   lowPower: false, stalls: 0, lightMode: false),
                                     paused: false)
        XCTAssertLessThan(text.split(separator: " ").count, 40, text)
    }

    // MARK: Sınav komutlarıyla karışmaz

    func testStatusSentenceIsNotAnExamCommand() {
        let all: Set<String> = ["start", "scan_done", "end", "undo", "close", "continue", "pause", "more", "new", "cancel", "yes", "no", "skip", "del"]
        for t in ["durum bilgisi ver", "durum bilgisini söyle", "telefonun durumu", "performans nasıl", "sistem durumu"] {
            XCTAssertNil(ExamText.match(t, all), t)
        }
    }
}
