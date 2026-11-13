import Foundation
import AVFoundation
import Speech
import UIKit

struct PermissionResult: Equatable {
    var microphone: Bool
    var speech: Bool
    /// Türkçe çevrimdışı dikte telefonda var mı
    var onDeviceSpeech: Bool
    /// İngilizce çevrimdışı dikte (yardımcı tanıyıcı) telefonda var mı; yoksa oturum yine başlar
    var englishOnDevice: Bool = true
}

@MainActor
protocol PermissionProviding: AnyObject {
    func request() async -> PermissionResult
}

@MainActor
final class SystemPermissions: PermissionProviding {
    func request() async -> PermissionResult {
        let mic = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
        }
        let speech = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        return PermissionResult(microphone: mic, speech: speech, onDeviceSpeech: OnDeviceSpeechListener.onDeviceAvailable,
                                  englishOnDevice: OnDeviceSpeechListener.englishAvailable)
    }
}

/// Oturum sürerken ekranın kararmasını (ve kilitlenmesini) engeller: kilitliyken Kestirmeler açılamaz
@MainActor
protocol ScreenKeeping: AnyObject {
    func keepAwake(_ on: Bool)
}

@MainActor
final class SystemScreen: ScreenKeeping {
    func keepAwake(_ on: Bool) {
        UIApplication.shared.isIdleTimerDisabled = on
    }
}
