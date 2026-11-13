import XCTest
@testable import G526CameraDrive

final class GeminiKeyHintTests: XCTestCase {
    private let good = "AIza" + String(repeating: "x", count: 31) + "Q7dZ"   // 39 karakter

    func testHintShowsOnlyEndsAndLength() {
        XCTAssertEqual(GeminiProfiles.keyHint(good), "AIza…Q7dZ, 39 karakter")
        XCTAssertEqual(GeminiProfiles.keyHint("  "), "anahtar boş")
        XCTAssertEqual(GeminiProfiles.keyHint("abc"), "3 karakter")
        XCTAssertFalse(GeminiProfiles.keyHint(good).contains("xxxx"))
    }

    func testWellFormedKeyHasNoProblem() {
        XCTAssertNil(GeminiProfiles.keyShapeProblem(good))
        XCTAssertNil(GeminiProfiles.keyShapeProblem(""))
        XCTAssertNil(GeminiProfiles.keyShapeProblem("  \(good)\n"), "baştaki/sondaki boşluk zaten kırpılır")
    }

    func testPastedMistakesAreNamed() {
        XCTAssertNotNil(GeminiProfiles.keyShapeProblem("AIza" + String(repeating: "x", count: 15) + " " + String(repeating: "y", count: 19)))
        XCTAssertNotNil(GeminiProfiles.keyShapeProblem("\"\(good)\""))
        XCTAssertNotNil(GeminiProfiles.keyShapeProblem("sk-" + String(repeating: "x", count: 36)))
        XCTAssertNotNil(GeminiProfiles.keyShapeProblem(String(good.dropLast(3))))
        XCTAssertTrue(GeminiProfiles.keyShapeProblem(String(good.dropLast(3)))?.contains("36") == true)
    }

    func testFailureLineNamesModelAndKeyOnlyForKeyErrors() {
        let p = GeminiProfileInfo(slot: 6, name: "Ücretli", model: "m", key: good, free: false)
        let keyLine = GeminiVideo.failureLine(profile: p, error: GeminiError("API anahtarı geçersiz.", .key))
        XCTAssertTrue(keyLine.hasPrefix("Ücretli: API anahtarı geçersiz."))
        XCTAssertTrue(keyLine.contains("AIza…Q7dZ, 39 karakter"))
        let quotaLine = GeminiVideo.failureLine(profile: p, error: GeminiError("Kota doldu.", .quota))
        XCTAssertEqual(quotaLine, "Ücretli: Kota doldu.")
    }

    func testCombinedErrorListsEveryTriedModelAndKeepsLastKind() {
        let last = GeminiError("son", .key, status: 400)
        let merged = GeminiVideo.combined(last, trail: ["A: kota doldu.", "B: anahtar geçersiz."])
        XCTAssertEqual(merged.message, "A: kota doldu. B: anahtar geçersiz.")
        XCTAssertEqual(merged.kind, .key)
        XCTAssertEqual(merged.status, 400)
        XCTAssertEqual(GeminiVideo.combined(last, trail: []).message, "son")
    }

    func testClipboardKeyIsExtractedFromSurroundingText() {
        XCTAssertEqual(GeminiProfiles.cleanedKey(fromClipboard: "  \(good)\n"), good)
        XCTAssertEqual(GeminiProfiles.cleanedKey(fromClipboard: "API key: \(good) (ücretsiz)"), good)
        XCTAssertEqual(GeminiProfiles.cleanedKey(fromClipboard: "\"\(good)\""), good)
    }

    func testClipboardNonStandardKeyIsTrimmedButKept() {
        XCTAssertEqual(GeminiProfiles.cleanedKey(fromClipboard: " “abc-123” \n"), "abc-123")
    }

    func testEmptyClipboardGivesNothing() {
        XCTAssertNil(GeminiProfiles.cleanedKey(fromClipboard: nil))
        XCTAssertNil(GeminiProfiles.cleanedKey(fromClipboard: " \n\t"))
        XCTAssertNil(GeminiProfiles.cleanedKey(fromClipboard: "\"\""))
    }

    func testKeyKindLabelFollowsTheSwitch() {
        XCTAssertEqual(GeminiProfiles.keyKindLabel(free: true), "Ücretsiz anahtar")
        XCTAssertEqual(GeminiProfiles.keyKindLabel(free: false), "Ücretli anahtar")
    }

    func testNewAQKeyIsNotFlaggedAsWrong() {
        let aq = "AQ.Ab8RN6" + String(repeating: "k", count: 40)
        XCTAssertNil(GeminiProfiles.keyShapeProblem(aq))
        XCTAssertNotNil(GeminiProfiles.keyShapeProblem("AQ.abc"), "çok kısa AQ. anahtarı eksik yapışmıştır")
        XCTAssertTrue(GeminiProfiles.keyShapeProblem("sk-abc")?.contains("AQ.") == true, "uyarı iki biçimi de anlatır")
    }

    func testClipboardAQKeyIsExtractedAndTrailingDotDropped() {
        let aq = "AQ.Ab8RN6" + String(repeating: "k", count: 40)
        XCTAssertEqual(GeminiProfiles.cleanedKey(fromClipboard: "Anahtarım: \(aq). Kullan"), aq)
        XCTAssertEqual(GeminiProfiles.cleanedKey(fromClipboard: "\(aq)\n"), aq)
    }


    private let aq = "AQ.Ab8RN6" + String(repeating: "k", count: 40)

    func testProbeWorkingKeyIsOk() {
        let r = GeminiProfiles.keyProbeText(model: "m", key: good, header: KeyProbe(status: 200, message: ""), query: nil)
        XCTAssertTrue(r.ok)
        XCTAssertTrue(r.text.hasPrefix("✓ Anahtar ve model çalışıyor"))
    }

    func testProbeQuotaOrOverloadMeansKeyWasAccepted() {
        let quota = GeminiProfiles.keyProbeText(model: "m", key: good, header: KeyProbe(status: 429, message: "Resource exhausted"), query: nil)
        XCTAssertTrue(quota.ok)
        XCTAssertTrue(quota.text.contains("Anahtar kabul edildi") && quota.text.contains("kota"))
        let busy = GeminiProfiles.keyProbeText(model: "m", key: good, header: KeyProbe(status: 503, message: "overloaded"), query: nil)
        XCTAssertTrue(busy.ok)
        XCTAssertTrue(busy.text.contains("Anahtar kabul edildi"))
    }

    func testProbeUnknownModelIsKeyOkButNotOk() {
        let r = GeminiProfiles.keyProbeText(model: "yok-model", key: good, header: KeyProbe(status: 404, message: "not found"), query: nil)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.text.contains("Anahtar kabul edildi") && r.text.contains("yok-model"))
    }

    func testProbeRejectedKeyShowsGoogleAnswerFromBothWays() {
        let header = KeyProbe(status: 400, message: "API key not valid. Please pass a valid API key.")
        let query = KeyProbe(status: 401, message: "Request had invalid authentication credentials.")
        let r = GeminiProfiles.keyProbeText(model: "m", key: good, header: header, query: query)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.text.contains("Başlıkla: HTTP 400") && r.text.contains("Adreste: HTTP 401"))
        XCTAssertTrue(r.text.contains("API key not valid"))
        XCTAssertFalse(r.text.contains("Cloud Console"), "AIza anahtarına AQ notu eklenmez")
    }

    func testProbeAQKeyRejectedGetsFormatNote() {
        let header = KeyProbe(status: 400, message: "API key not valid.")
        let r = GeminiProfiles.keyProbeText(model: "m", key: aq, header: header, query: KeyProbe(status: 400, message: "API key not valid."))
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.text.contains("Cloud Console"))
    }

    func testProbeWorksOnlyViaQueryIsReported() {
        let header = KeyProbe(status: 401, message: "ACCESS_TOKEN_TYPE_UNSUPPORTED")
        let r = GeminiProfiles.keyProbeText(model: "m", key: aq, header: header, query: KeyProbe(status: 200, message: ""))
        XCTAssertTrue(r.ok)
        XCTAssertTrue(r.text.contains("adreste"))
    }

    func testProbeNetworkFailureIsNotCalledKeyFailure() {
        let r = GeminiProfiles.keyProbeText(model: "m", key: good, header: KeyProbe(status: 0, message: "çevrimdışı"), query: nil)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.text.contains("İnternete ulaşılamadı"))
        XCTAssertFalse(GeminiProfiles.isKeyRejection(KeyProbe(status: 0, message: "")))
    }

    func testOtherBadRequestIsNotBlamedOnTheKey() {
        let probe = KeyProbe(status: 400, message: "Invalid JSON payload received.")
        XCTAssertFalse(GeminiProfiles.isKeyRejection(probe))
        let r = GeminiProfiles.keyProbeText(model: "m", key: good, header: probe, query: nil)
        XCTAssertTrue(r.text.contains("Google isteği kabul etmedi"))
        XCTAssertTrue(GeminiProfiles.isKeyRejection(KeyProbe(status: 403, message: "")))
        XCTAssertTrue(GeminiProfiles.isKeyRejection(KeyProbe(status: 400, message: "API key expired.")))
    }

    func testFailureLineGetsFormatNoteOnlyForAQKeys() {
        let err = GeminiError("API anahtarı geçersiz.", .key, status: 400)
        let aqLine = GeminiVideo.failureLine(profile: GeminiProfileInfo(slot: 6, name: "Ücretli", model: "m", key: aq, free: false), error: err)
        XCTAssertTrue(aqLine.contains("Cloud Console"))
        let line = GeminiVideo.failureLine(profile: GeminiProfileInfo(slot: 1, name: "Bir", model: "m", key: good, free: true), error: err)
        XCTAssertFalse(line.contains("Cloud Console"))
    }
}
