import XCTest
@testable import G526CameraDrive

final class GeminiKeyTests: XCTestCase {
    private let good = "AIza" + String(repeating: "x", count: 31) + "Q7dZ"   // 39 karakter

    func testHintShowsOnlyEndsAndLength() {
        XCTAssertEqual(GeminiKey.keyHint(good), "AIza…Q7dZ, 39 karakter")
        XCTAssertEqual(GeminiKey.keyHint("  "), "anahtar boş")
        XCTAssertEqual(GeminiKey.keyHint("abc"), "3 karakter")
        XCTAssertFalse(GeminiKey.keyHint(good).contains("xxxx"))
    }

    func testWellFormedKeyHasNoProblem() {
        XCTAssertNil(GeminiKey.keyShapeProblem(good))
        XCTAssertNil(GeminiKey.keyShapeProblem(""))
        XCTAssertNil(GeminiKey.keyShapeProblem("  \(good)\n"), "baştaki/sondaki boşluk zaten kırpılır")
    }

    func testPastedMistakesAreNamed() {
        XCTAssertNotNil(GeminiKey.keyShapeProblem("AIza" + String(repeating: "x", count: 15) + " " + String(repeating: "y", count: 19)))
        XCTAssertNotNil(GeminiKey.keyShapeProblem("\"\(good)\""))
        XCTAssertNotNil(GeminiKey.keyShapeProblem("sk-" + String(repeating: "x", count: 36)))
        XCTAssertNotNil(GeminiKey.keyShapeProblem(String(good.dropLast(3))))
        XCTAssertTrue(GeminiKey.keyShapeProblem(String(good.dropLast(3)))?.contains("36") == true)
    }





    func testClipboardKeyIsExtractedFromSurroundingText() {
        XCTAssertEqual(GeminiKey.cleanedKey(fromClipboard: "  \(good)\n"), good)
        XCTAssertEqual(GeminiKey.cleanedKey(fromClipboard: "API key: \(good) (ücretsiz)"), good)
        XCTAssertEqual(GeminiKey.cleanedKey(fromClipboard: "\"\(good)\""), good)
    }

    func testClipboardNonStandardKeyIsTrimmedButKept() {
        XCTAssertEqual(GeminiKey.cleanedKey(fromClipboard: " “abc-123” \n"), "abc-123")
    }

    func testEmptyClipboardGivesNothing() {
        XCTAssertNil(GeminiKey.cleanedKey(fromClipboard: nil))
        XCTAssertNil(GeminiKey.cleanedKey(fromClipboard: " \n\t"))
        XCTAssertNil(GeminiKey.cleanedKey(fromClipboard: "\"\""))
    }

    func testNewAQKeyIsNotFlaggedAsWrong() {
        let aq = "AQ.Ab8RN6" + String(repeating: "k", count: 40)
        XCTAssertNil(GeminiKey.keyShapeProblem(aq))
        XCTAssertNotNil(GeminiKey.keyShapeProblem("AQ.abc"), "çok kısa AQ. anahtarı eksik yapışmıştır")
        XCTAssertTrue(GeminiKey.keyShapeProblem("sk-abc")?.contains("AQ.") == true, "uyarı iki biçimi de anlatır")
    }

    func testClipboardAQKeyIsExtractedAndTrailingDotDropped() {
        let aq = "AQ.Ab8RN6" + String(repeating: "k", count: 40)
        XCTAssertEqual(GeminiKey.cleanedKey(fromClipboard: "Anahtarım: \(aq). Kullan"), aq)
        XCTAssertEqual(GeminiKey.cleanedKey(fromClipboard: "\(aq)\n"), aq)
    }


    private let aq = "AQ.Ab8RN6" + String(repeating: "k", count: 40)

    func testProbeWorkingKeyIsOk() {
        let r = GeminiKey.keyProbeText(model: "m", key: good, header: KeyProbe(status: 200, message: ""), query: nil)
        XCTAssertTrue(r.ok)
        XCTAssertTrue(r.text.hasPrefix("✓ Anahtar ve model çalışıyor"))
    }

    func testProbeQuotaOrOverloadMeansKeyWasAccepted() {
        let quota = GeminiKey.keyProbeText(model: "m", key: good, header: KeyProbe(status: 429, message: "Resource exhausted"), query: nil)
        XCTAssertTrue(quota.ok)
        XCTAssertTrue(quota.text.contains("Anahtar kabul edildi") && quota.text.contains("kota"))
        let busy = GeminiKey.keyProbeText(model: "m", key: good, header: KeyProbe(status: 503, message: "overloaded"), query: nil)
        XCTAssertTrue(busy.ok)
        XCTAssertTrue(busy.text.contains("Anahtar kabul edildi"))
    }

    func testProbeUnknownModelIsKeyOkButNotOk() {
        let r = GeminiKey.keyProbeText(model: "yok-model", key: good, header: KeyProbe(status: 404, message: "not found"), query: nil)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.text.contains("Anahtar kabul edildi") && r.text.contains("yok-model"))
    }

    func testProbeRejectedKeyShowsGoogleAnswerFromBothWays() {
        let header = KeyProbe(status: 400, message: "API key not valid. Please pass a valid API key.")
        let query = KeyProbe(status: 401, message: "Request had invalid authentication credentials.")
        let r = GeminiKey.keyProbeText(model: "m", key: good, header: header, query: query)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.text.contains("Başlıkla: HTTP 400") && r.text.contains("Adreste: HTTP 401"))
        XCTAssertTrue(r.text.contains("API key not valid"))
        XCTAssertFalse(r.text.contains("Cloud Console"), "AIza anahtarına AQ notu eklenmez")
    }

    func testProbeAQKeyRejectedGetsFormatNote() {
        let header = KeyProbe(status: 400, message: "API key not valid.")
        let r = GeminiKey.keyProbeText(model: "m", key: aq, header: header, query: KeyProbe(status: 400, message: "API key not valid."))
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.text.contains("Cloud Console"))
    }

    func testProbeWorksOnlyViaQueryIsReported() {
        let header = KeyProbe(status: 401, message: "ACCESS_TOKEN_TYPE_UNSUPPORTED")
        let r = GeminiKey.keyProbeText(model: "m", key: aq, header: header, query: KeyProbe(status: 200, message: ""))
        XCTAssertTrue(r.ok)
        XCTAssertTrue(r.text.contains("adreste"))
    }

    func testProbeNetworkFailureIsNotCalledKeyFailure() {
        let r = GeminiKey.keyProbeText(model: "m", key: good, header: KeyProbe(status: 0, message: "çevrimdışı"), query: nil)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.text.contains("İnternete ulaşılamadı"))
        XCTAssertFalse(GeminiKey.isKeyRejection(KeyProbe(status: 0, message: "")))
    }

    func testOtherBadRequestIsNotBlamedOnTheKey() {
        let probe = KeyProbe(status: 400, message: "Invalid JSON payload received.")
        XCTAssertFalse(GeminiKey.isKeyRejection(probe))
        let r = GeminiKey.keyProbeText(model: "m", key: good, header: probe, query: nil)
        XCTAssertTrue(r.text.contains("Google isteği kabul etmedi"))
        XCTAssertTrue(GeminiKey.isKeyRejection(KeyProbe(status: 403, message: "")))
        XCTAssertTrue(GeminiKey.isKeyRejection(KeyProbe(status: 400, message: "API key expired.")))
    }


}
