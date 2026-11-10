import XCTest
@testable import G526CameraDrive

final class SpeechVoiceTests: XCTestCase {
    private let compact = VoiceInfo(id: "tr.compact.yelda", name: "Yelda", language: "tr-TR", rank: 0)
    private let enhanced = VoiceInfo(id: "tr.enhanced.yelda", name: "Yelda", language: "tr-TR", rank: 1)
    private let premium = VoiceInfo(id: "tr.premium.x", name: "Zeynep", language: "tr-TR", rank: 2)
    private let english = VoiceInfo(id: "en.premium.sam", name: "Samantha", language: "en-US", rank: 2)

    func testQualityRawValuesMapToRanks() {
        XCTAssertEqual(SpeechVoiceChooser.rank(forQualityRawValue: 1), 0)
        XCTAssertEqual(SpeechVoiceChooser.rank(forQualityRawValue: 2), 1)
        XCTAssertEqual(SpeechVoiceChooser.rank(forQualityRawValue: 3), 2)
        XCTAssertEqual(SpeechVoiceChooser.rank(forQualityRawValue: 0), 0)
        XCTAssertEqual(SpeechVoiceChooser.rank(forQualityRawValue: 9), 2)
    }

    func testAutomaticPicksBestTurkishVoice() {
        XCTAssertEqual(SpeechVoiceChooser.best(from: [compact, enhanced, english], preferredID: "")?.id, enhanced.id)
        XCTAssertEqual(SpeechVoiceChooser.best(from: [enhanced, premium, compact], preferredID: "")?.id, premium.id)
    }

    func testOtherLanguagesAreNeverChosen() {
        XCTAssertNil(SpeechVoiceChooser.best(from: [english], preferredID: ""))
        XCTAssertNil(SpeechVoiceChooser.best(from: [english], preferredID: english.id))
        XCTAssertNil(SpeechVoiceChooser.best(from: [], preferredID: ""))
    }

    func testChosenVoiceWinsWhenInstalled() {
        XCTAssertEqual(SpeechVoiceChooser.best(from: [compact, premium], preferredID: compact.id)?.id, compact.id)
    }

    func testMissingChosenVoiceFallsBackToBest() {
        XCTAssertEqual(SpeechVoiceChooser.best(from: [compact, enhanced], preferredID: "silinmis.ses")?.id, enhanced.id)
    }

    func testSameQualitySortedByName() {
        let a = VoiceInfo(id: "a", name: "Ayşe", language: "tr-TR", rank: 1)
        let b = VoiceInfo(id: "b", name: "Burak", language: "tr-TR", rank: 1)
        XCTAssertEqual(SpeechVoiceChooser.sortedTurkish([b, a]).map { $0.id }, ["a", "b"])
    }

    func testTitlesShowQualityInTurkish() {
        XCTAssertEqual(compact.title, "Yelda · Standart")
        XCTAssertEqual(enhanced.title, "Yelda · Gelişmiş")
        XCTAssertEqual(premium.title, "Zeynep · Premium")
    }

    func testInstalledVoicesCallDoesNotCrash() {
        // Simülatörde Türkçe ses olmayabilir; yalnız çağrının çökmediğini ve sonucun tutarlı olduğunu denetler
        let all = SpeechVoiceChooser.installed()
        for v in all { XCTAssertTrue((0...2).contains(v.rank)) }
        _ = SpeechVoiceChooser.currentDescription(preferredID: "")
    }
}
