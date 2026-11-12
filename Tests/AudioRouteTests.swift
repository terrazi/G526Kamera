import XCTest
import AVFoundation
@testable import G526CameraDrive

final class AudioRouteTests: XCTestCase {
    func testHintWhenSoundGoesToMicReceiver() {
        let hint = AudioRoute.outputHint([.usbAudio])
        XCTAssertTrue(hint.contains("kulaklığa gitmiyor"), hint)
        XCTAssertTrue(hint.contains("ses çıkışı düğmesi"), hint)
    }

    func testNoHintWhenBluetoothHeadphonesAreTheOutput() {
        XCTAssertEqual(AudioRoute.outputHint([.bluetoothA2DP]), "")
        XCTAssertEqual(AudioRoute.outputHint([.bluetoothLE]), "")
    }

    func testHintWhenOnlyPhoneSpeakerIsUsed() {
        XCTAssertTrue(AudioRoute.outputHint([.builtInSpeaker]).contains("hoparlör"))
    }

    /// Ses düzeni (T): 0 varsayılan (Bluetooth yalnız çıkış), 1 kulaklığın kendi mikrofonu (konuşma profili açık)
    func testAudioLayoutOptions() {
        XCTAssertEqual(AudioRoute.categoryOptions(layout: 0), AudioRoute.categoryOptions)
        XCTAssertFalse(AudioRoute.categoryOptions(layout: 0).contains(.allowBluetooth))
        XCTAssertTrue(AudioRoute.categoryOptions(layout: 1).contains(.allowBluetooth))
        XCTAssertTrue(AudioRoute.categoryOptions(layout: 1).contains(.allowBluetoothA2DP))
        XCTAssertEqual(AudioRoute.categoryOptions(layout: 7), AudioRoute.categoryOptions, "bilinmeyen düzen varsayılana düşer")
    }

    func testOutputNameForSettingsStatusRow() {
        XCTAssertEqual(AudioRoute.outputName([.bluetoothA2DP]), "kulaklık")
        XCTAssertEqual(AudioRoute.outputName([.headphones]), "kulaklık")
        XCTAssertEqual(AudioRoute.outputName([.builtInSpeaker]), "telefon hoparlörü")
        XCTAssertTrue(AudioRoute.outputName([.usbAudio]).contains("kulaklık değil"))
        XCTAssertEqual(AudioRoute.outputName([]), "çıkış yok")
    }

    func testRouteWarningOnlyForReceiver() {
        XCTAssertFalse(AudioRoute.routeWarning([.usbAudio]).isEmpty)
        XCTAssertEqual(AudioRoute.routeWarning([.bluetoothA2DP]), "")
        XCTAssertEqual(AudioRoute.routeWarning([.builtInSpeaker]), "", "hoparlör bilerek seçilmiş olabilir: sınavı engellemez")
    }

    func testNoHintWithoutOutputs() {
        XCTAssertEqual(AudioRoute.outputHint([]), "")
    }

    func testReceiverWinsOverSpeakerWhenBothListed() {
        XCTAssertTrue(AudioRoute.outputHint([.builtInSpeaker, .usbAudio]).contains("mikrofon alıcısına"))
    }

    func testRestartDelayGrowsOnlyWhenRestartsPileUp() {
        XCTAssertEqual(SpeechTrigger.restartDelay(base: 0.4, recentRestarts: 1), 0.4)
        XCTAssertEqual(SpeechTrigger.restartDelay(base: 0.4, recentRestarts: 3), 0.4)
        XCTAssertEqual(SpeechTrigger.restartDelay(base: 0.4, recentRestarts: 4), 1.5, accuracy: 0.001)
        XCTAssertEqual(SpeechTrigger.restartDelay(base: 0.4, recentRestarts: 6), 4.5, accuracy: 0.001)
        XCTAssertEqual(SpeechTrigger.restartDelay(base: 0.4, recentRestarts: 8), 7.5, accuracy: 0.001)
        XCTAssertEqual(SpeechTrigger.restartDelay(base: 0.4, recentRestarts: 50), 30, accuracy: 0.001, "üst sınır 30 sn")
        XCTAssertEqual(SpeechTrigger.restartDelay(base: 10, recentRestarts: 5), 10, "istenen bekleme kısaltılmaz")
    }
}
