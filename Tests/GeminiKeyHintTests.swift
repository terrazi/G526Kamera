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

    func testKeyTestSaysAcceptedAndModelAvailable() {
        let r = GeminiProfiles.keyTestText(model: " gemini-3.8-flash ", result: .success(["a", "gemini-3.8-flash"]))
        XCTAssertTrue(r.ok)
        XCTAssertTrue(r.text.contains("gemini-3.8-flash"))
        XCTAssertTrue(r.text.hasPrefix("✓"))
        XCTAssertTrue(GeminiProfiles.keyTestText(model: "models/a", result: .success(["a"])).ok)
    }

    func testKeyTestAcceptedKeyButMissingModelIsNotOk() {
        let r = GeminiProfiles.keyTestText(model: "yok-model", result: .success(["a", "b"]))
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.text.contains("Anahtar kabul edildi"))
        XCTAssertTrue(r.text.contains("yok-model"))
    }

    func testKeyTestRejectedKeyShowsGoogleReason() {
        let r = GeminiProfiles.keyTestText(model: "m", result: .failure(GeminiError("API anahtarı geçersiz.", .key, status: 400)))
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.text, "✗ API anahtarı geçersiz.")
    }

    func testKeyTestWithEmptyModelStillAcceptsKey() {
        let r = GeminiProfiles.keyTestText(model: "  ", result: .success([]))
        XCTAssertTrue(r.ok)
    }
}
