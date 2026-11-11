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
}
