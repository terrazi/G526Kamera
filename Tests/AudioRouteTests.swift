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
