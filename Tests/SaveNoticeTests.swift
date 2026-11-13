import XCTest
@testable import G526CameraDrive

/// Kırmızı uyarı kutusundaki "klasöre kaydedilemiyor" yazısı: yalnız o anki durumdan türetilir, sorun giderilince kalkar
@MainActor
final class SaveNoticeTests: XCTestCase {
    private func text(photos: Int = 0, videos: Int = 0, chosen: Bool = true, photoError: String = "", videoError: String = "") -> String {
        return AppModel.saveProblemText(photos: photos, videos: videos, folderChosen: chosen, photoError: photoError, videoError: videoError)
    }

    func testNothingWaitingMeansNoWarning() {
        XCTAssertEqual(text(), "")
        XCTAssertEqual(text(chosen: false), "", "bekleyen yoksa klasör seçilmemiş olsa da uyarı yok")
        XCTAssertEqual(text(photoError: "hata", videoError: "hata"), "", "bekleyen yoksa eski hata uyarı olmaz")
    }

    func testWaitingFilesWithoutFolderWarnWithWhatWaits() {
        let t = text(photos: 3, videos: 1, chosen: false)
        XCTAssertTrue(t.hasPrefix("Belge klasörü seçilmemiş: 3 fotoğraf ve 1 video telefonda bekliyor."), t)
        XCTAssertTrue(text(videos: 2, chosen: false).contains("2 video telefonda bekliyor"))
        XCTAssertTrue(text(photos: 1, chosen: false).contains("1 fotoğraf telefonda bekliyor"))
    }

    func testFolderChosenAndNoErrorIsQuiet() {
        // Toplu gönderimde fotoğrafların bekleyişi normaldir: klasör seçili ve hata yoksa uyarı yok
        XCTAssertEqual(text(photos: 5), "")
        XCTAssertEqual(text(videos: 1), "")
    }

    func testWriteErrorWarnsWhileFilesWait() {
        let t = text(photos: 2, photoError: "Klasöre yazılamadı.")
        XCTAssertEqual(t, "Klasöre kaydedilemedi: Klasöre yazılamadı. 2 fotoğraf telefonda bekliyor, yeniden denenecek.")
        let v = text(videos: 1, videoError: "disk dolu")
        XCTAssertEqual(v, "Klasöre kaydedilemedi: disk dolu. 1 video telefonda bekliyor, yeniden denenecek.")
    }

    func testErrorOfOtherKindDoesNotWarnAboutFilesThatAreNotWaiting() {
        // Fotoğraf hatası var ama bekleyen yalnız video: fotoğraf hatası videonun uyarısı olmaz
        XCTAssertEqual(text(videos: 1, photoError: "foto hatası"), "")
    }

    func testWarningGoesAwayOnceFixed() {
        XCTAssertFalse(text(photos: 2, chosen: false).isEmpty)
        // Klasör seçildi
        XCTAssertEqual(text(photos: 2, chosen: true), "")
        // Hata sürerken bekleyen sayı bitti (kaydedildi)
        XCTAssertEqual(text(photos: 0, photoError: "hata"), "")
    }
}
