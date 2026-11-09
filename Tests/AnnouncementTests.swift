import XCTest
@testable import G526CameraDrive

/// Görmeden kullanım: kamera ve gönderim durumları sesle bildirilir
final class AnnouncementTests: XCTestCase {
    private func run(_ a: inout ConnectionAnnouncer, from: Int, to: Int, live: Bool) -> [(Int, ConnectionAnnouncer.Message)] {
        var out: [(Int, ConnectionAnnouncer.Message)] = []
        for t in from...to {
            if let m = a.tick(now: Double(t), live: live) { out.append((t, m)) }
        }
        return out
    }

    func testReadyIsAnnouncedOnceWhenFirstLive() {
        var a = ConnectionAnnouncer()
        XCTAssertEqual(run(&a, from: 0, to: 4, live: false).count, 0)
        let ready = run(&a, from: 5, to: 30, live: true)
        XCTAssertEqual(ready.count, 1)
        XCTAssertEqual(ready.first?.1, .ready)
    }

    func testShortGlitchIsNotAnnounced() {
        var a = ConnectionAnnouncer()
        _ = run(&a, from: 0, to: 10, live: true)
        XCTAssertEqual(run(&a, from: 11, to: 15, live: false).count, 0)
        XCTAssertEqual(run(&a, from: 16, to: 40, live: true).count, 0)
    }

    func testLostThenRestored() {
        var a = ConnectionAnnouncer()
        _ = run(&a, from: 0, to: 10, live: true)
        let lost = run(&a, from: 11, to: 30, live: false)
        XCTAssertEqual(lost.map { $0.1 }, [.lost])
        XCTAssertEqual(lost.first?.0, 17)
        let back = run(&a, from: 31, to: 40, live: true)
        XCTAssertEqual(back.map { $0.1 }, [.restored])
        // yeniden kopunca tekrar haber verir
        XCTAssertEqual(run(&a, from: 41, to: 60, live: false).map { $0.1 }, [.lost])
    }

    func testNeverConnectedWarnsAndRemindsAtMostThreeTimes() {
        var a = ConnectionAnnouncer()
        let said = run(&a, from: 0, to: 600, live: false)
        XCTAssertEqual(said.map { $0.1 }, [.unreachable, .stillDown, .stillDown])
        XCTAssertEqual(said.first?.0, 25)
        XCTAssertGreaterThanOrEqual(said[1].0 - said[0].0, 60)
    }

    func testLongOutageRemindersAreLimited() {
        var a = ConnectionAnnouncer()
        _ = run(&a, from: 0, to: 10, live: true)
        let said = run(&a, from: 11, to: 900, live: false)
        XCTAssertEqual(said.first?.1, .lost)
        XCTAssertEqual(said.filter { $0.1 == .stillDown }.count, ConnectionAnnouncer.maxReminders)
    }

    func testResetStartsFresh() {
        var a = ConnectionAnnouncer()
        _ = run(&a, from: 0, to: 10, live: true)
        a.reset()
        XCTAssertEqual(run(&a, from: 11, to: 12, live: true).map { $0.1 }, [.ready])
    }

    func testMessagesAreSpeakableTurkish() {
        for m in [ConnectionAnnouncer.Message.ready, .lost, .restored, .unreachable, .stillDown] {
            XCTAssertFalse(m.text.isEmpty)
            XCTAssertTrue(m.text.hasSuffix("."))
        }
    }

    func testStartupTellsWhatIsMissing() {
        XCTAssertEqual(SpokenReport.startup(signedIn: true, waiting: 0), "Sesli konumlandırma açık.")
        let out = SpokenReport.startup(signedIn: false, waiting: 3)
        XCTAssertTrue(out.contains("giriş yok"))
        XCTAssertTrue(out.contains("3 sayfa"))
    }

    func testAnnouncementsAreShort() {
        // Dinleyiciyi yormamak için her bildirim kısa olmalı
        var all: [String] = [ConnectionAnnouncer.Message.ready, .lost, .restored, .unreachable, .stillDown].map { $0.text }
        all += [SpokenReport.startup(signedIn: false, waiting: 5), SpokenReport.autoSent(),
                SpokenReport.uploadFailed(signedIn: true, waiting: 3), SpokenReport.uploadFailed(signedIn: false, waiting: 3),
                SpokenReport.speechProblem("Mikrofon izni verilmedi") ?? ""]
        for t in all {
            XCTAssertLessThanOrEqual(t.split(separator: " ").count, 16, t)
        }
    }

    func testSpeechProblemsAreSpokenOnlyWhenUserMustAct() {
        XCTAssertNotNil(SpokenReport.speechProblem("Mikrofon izni verilmedi (Ayarlar > G526 Kamera)"))
        XCTAssertNotNil(SpokenReport.speechProblem("Konuşma tanıma izni verilmedi (Ayarlar > G526 Kamera)"))
        XCTAssertNotNil(SpokenReport.speechProblem("Türkçe konuşma tanıma bu cihazda yok"))
        XCTAssertEqual(SpokenReport.speechProblem("Mikrofon izni verilmedi (Ayarlar > G526 Kamera)"),
                       SpokenReport.speechProblem("Konuşma tanıma izni verilmedi (Ayarlar > G526 Kamera)"))
        for s in ["Dinleniyor — “okey” deyin", "İzinler isteniyor…", "Ses kesildi (arama / başka uygulama)",
                  "Mikrofon açılamadı, tekrar deneniyor…", "Konuşma tanıma şu an kullanılamıyor, tekrar deneniyor…"] {
            XCTAssertNil(SpokenReport.speechProblem(s), s)
        }
    }

    func testBackgroundUploadSentences() {
        XCTAssertEqual(SpokenReport.autoSent(), "Dosya gönderildi.")
        XCTAssertTrue(SpokenReport.uploadFailed(signedIn: true, waiting: 2).contains("yeniden denenecek"))
        let out = SpokenReport.uploadFailed(signedIn: false, waiting: 2)
        XCTAssertTrue(out.contains("giriş yok"))
        XCTAssertTrue(out.contains("2 sayfa"))
    }

    // MARK: - NoticeQueue: dinleyiciyi yormama kuralları

    func testNoticeWaitsForQuietAfterOtherSpeech() {
        var q = NoticeQueue()
        q.add("Dosya gönderildi.", .status, group: "g", now: 100)
        XCTAssertNil(q.next(now: 100.5, speaking: false, lastSpeechAt: 100))      // az önce konuşuldu
        XCTAssertNil(q.next(now: 103, speaking: true, lastSpeechAt: 100))         // şu an konuşuyor
        XCTAssertEqual(q.next(now: 103, speaking: false, lastSpeechAt: 100), "Dosya gönderildi.")
        XCTAssertNil(q.next(now: 104, speaking: false, lastSpeechAt: 100))        // bir kez söylenir
    }

    func testStaleStatusIsDroppedButAlertSurvives() {
        var q = NoticeQueue()
        q.add("iyi haber", .status, group: "a", now: 0)
        q.add("uyarı", .alert, group: "b", now: 0)
        // konuşma 12 sn boyunca sürüyor: iyi haber bayatlar, uyarı kalır
        XCTAssertNil(q.next(now: 12, speaking: true, lastSpeechAt: 11))
        XCTAssertEqual(q.next(now: 14, speaking: false, lastSpeechAt: 11), "uyarı")
        XCTAssertNil(q.next(now: 30, speaking: false, lastSpeechAt: 14))
        XCTAssertTrue(q.isEmpty)
    }

    func testAlertGoesBeforeStatusAndStatusIsRateLimited() {
        var q = NoticeQueue()
        q.add("iyi", .status, group: "a", now: 0)
        q.add("kötü", .alert, group: "b", now: 0)
        XCTAssertEqual(q.next(now: 5, speaking: false, lastSpeechAt: 0), "kötü")
        XCTAssertNil(q.next(now: 6, speaking: false, lastSpeechAt: 5))            // az önce konuşuldu
        XCTAssertEqual(q.next(now: 7.5, speaking: false, lastSpeechAt: 5), "iyi")
        q.add("iyi 2", .status, group: "c", now: 8)
        XCTAssertNil(q.next(now: 14, speaking: false, lastSpeechAt: 7.5))         // son iyi haberden 8 sn geçmedi
        XCTAssertEqual(q.next(now: 16, speaking: false, lastSpeechAt: 7.5), "iyi 2")
    }

    func testSameGroupReplacesAndSameTextIsNotRepeated() {
        var q = NoticeQueue()
        q.add("Kamera bağlantısı koptu.", .alert, group: "kamera", now: 0)
        q.add("Kamera geri geldi.", .status, group: "kamera", now: 3)             // kopma söylenmeden düzeldi
        XCTAssertEqual(q.next(now: 6, speaking: false, lastSpeechAt: 0), "Kamera geri geldi.")
        XCTAssertNil(q.next(now: 7, speaking: false, lastSpeechAt: 6))
        q.add("Kamera geri geldi.", .status, group: "kamera", now: 10)            // 30 sn içinde aynı cümle yok
        XCTAssertNil(q.next(now: 20, speaking: false, lastSpeechAt: 6))
        q.add("Kamera geri geldi.", .status, group: "kamera", now: 50)
        XCTAssertEqual(q.next(now: 52, speaking: false, lastSpeechAt: 6), "Kamera geri geldi.")
    }

    func testAlertIsNotStarvedByContinuousGuidance() {
        var q = NoticeQueue()
        q.add("uyarı", .alert, group: "a", now: 0)
        // konumlandırma her 1 sn'de bir konuşuyor: sessizlik hiç olmaz
        for t in 1..<15 { XCTAssertNil(q.next(now: Double(t), speaking: false, lastSpeechAt: Double(t) - 0.5)) }
        XCTAssertEqual(q.next(now: 15.5, speaking: false, lastSpeechAt: 15), "uyarı")
    }
}
