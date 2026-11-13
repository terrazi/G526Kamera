import XCTest
import AVFoundation
@testable import G526CameraDrive

/// KURAL 1: ses yalnız Bluetooth kulaklığa gider, giriş yalnız harici yaka mikrofonundan gelir
@MainActor
final class AudioRoutingTests: XCTestCase {
    private func verdict(out: [AVAudioSession.Port], in inputs: [AVAudioSession.Port]) -> RouteVerdict {
        return AudioRouting.verdict(RouteSnapshot(outputs: out, inputs: inputs))
    }

    func testBluetoothHeadphonesWithLightningMicIsSafe() {
        for port in [AVAudioSession.Port.bluetoothA2DP, .bluetoothHFP, .bluetoothLE] {
            let v = verdict(out: [port], in: [.usbAudio])
            XCTAssertTrue(v.isSafe, "\(port)")
            XCTAssertEqual(v.hint, "")
            XCTAssertEqual(v.summary, "")
        }
    }

    func testEveryExternalMicPortIsAccepted() {
        for port in [AVAudioSession.Port.usbAudio, .headsetMic, .lineIn] {
            XCTAssertTrue(verdict(out: [.bluetoothA2DP], in: [port]).micOK, "\(port)")
        }
    }

    func testPhoneSpeakerIsNeverSafe() {
        let v = verdict(out: [.builtInSpeaker], in: [.usbAudio])
        XCTAssertFalse(v.headphonesOK)
        XCTAssertFalse(v.isSafe)
        XCTAssertTrue(v.hint.contains("telefondan ses verilmez"))
        XCTAssertEqual(v.summary, "Bluetooth kulaklık yok")
    }

    func testReceiverAndWiredHeadphonesAreNotSafe() {
        XCTAssertFalse(verdict(out: [.builtInReceiver], in: [.usbAudio]).headphonesOK)
        XCTAssertFalse(verdict(out: [.headphones], in: [.usbAudio]).headphonesOK)
        XCTAssertFalse(verdict(out: [.airPlay], in: [.usbAudio]).headphonesOK)
    }

    func testSpeakerMixedWithBluetoothIsNotSafe() {
        XCTAssertFalse(verdict(out: [.bluetoothA2DP, .builtInSpeaker], in: [.usbAudio]).headphonesOK,
                       "Hoparlör çıkışlardan biriyse ses dışarı sızar")
    }

    func testNoOutputAtAllIsNotSafe() {
        let v = verdict(out: [], in: [.usbAudio])
        XCTAssertFalse(v.headphonesOK)
        XCTAssertEqual(v.hint, "Bluetooth kulaklık bulunamadı.")
    }

    func testLightningReceiverStealingOutputGivesPickerHint() {
        let v = verdict(out: [.usbAudio], in: [.usbAudio])
        XCTAssertFalse(v.headphonesOK)
        XCTAssertTrue(v.hint.contains("Lightning"))
        XCTAssertTrue(v.hint.contains("Bluetooth kulaklığı seçin"))
    }

    func testPhoneMicrophoneAndBluetoothMicAreNotAccepted() {
        XCTAssertFalse(verdict(out: [.bluetoothA2DP], in: [.builtInMic]).micOK)
        XCTAssertFalse(verdict(out: [.bluetoothHFP], in: [.bluetoothHFP]).micOK)
        XCTAssertFalse(verdict(out: [.bluetoothA2DP], in: []).micOK)
        XCTAssertEqual(verdict(out: [.bluetoothA2DP], in: [.builtInMic]).summary, "yaka mikrofonu yok")
    }

    func testSummaryNamesBothMissingParts() {
        XCTAssertEqual(verdict(out: [.builtInSpeaker], in: [.builtInMic]).summary, "Bluetooth kulaklık yok, yaka mikrofonu yok")
    }

    // MARK: Modül 2: oturum ayarları

    func testSessionCategoryAndOptionsNeverIncludeSpeaker() {
        XCTAssertEqual(AudioSessionGuard.category, .playAndRecord)
        XCTAssertEqual(AudioSessionGuard.options, [.allowBluetoothA2DP])
        XCTAssertFalse(AudioSessionGuard.options.contains(.allowBluetooth),
                       "HFP kulaklığın mikrofonunu girişe alır ve Lightning mikrofonla çakışır; sesi iPhone'a düşürür")
        XCTAssertFalse(AudioSessionGuard.options.contains(.defaultToSpeaker))
    }
}
