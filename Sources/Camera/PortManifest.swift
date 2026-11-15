import Foundation

/// V1'in kamera altyapısının V4'e taşınma kaydı. V1'deki HER kaynak dosya burada tam bir durumla yer alır; hiçbiri sessizce atlanmamıştır.
/// `types` listesi taşınan türlere derleme zamanında başvurur: tür kaybolursa derleme kırılır. Testler (`PortManifestTests`) kaydın V1 dosya
/// listesiyle birebir örtüştüğünü, her dışarıda kalanın gerekçesi olduğunu ve bekleyenlerin neler olduğunu denetler. Okunur biçimi: docs/SURUM4_TASIMA.md.
enum PortStatus: String {
    /// V1'deki dosya V4'e satır satır aynı alındı
    case copied
    /// V4'e uyarlanarak alındı (yalnız gereken bölümler / V3 ile birleştirildi)
    case adapted
    /// V3'te aynı işi yapan bileşen zaten var
    case v3Equivalent
    /// Alınacak, henüz yapılmadı (sürüm bitmeden boş olmalı)
    case pending
    /// Bilerek alınmadı (gerekçesiyle)
    case excluded
}

struct PortEntry {
    let v1: String
    let status: PortStatus
    let note: String
    let types: [Any.Type]
}

enum PortManifest {
    /// V1 `Sources/` altındaki dosyalar (taşıma sırasında V1 kaynağından mekanik olarak çıkarıldı)
    static let v1Files: [String] = [
        "App.swift",
        "AppModel.swift",
        "AudioRoute.swift",
        "BatteryWatcher.swift",
        "BelgeKlasoru.swift",
        "BuildInfo.swift",
        "CameraBattery.swift",
        "CameraClient.swift",
        "CameraProbe.swift",
        "CameraProtocol.swift",
        "CameraSession.swift",
        "CaptureEngine.swift",
        "CaptureLog.swift",
        "ConnectionAnnouncer.swift",
        "ContentView.swift",
        "DocumentGate.swift",
        "Enhancer.swift",
        "ExamGemini.swift",
        "ExamMode.swift",
        "ExamPortsReal.swift",
        "ExamText.swift",
        "FolderClient.swift",
        "FrameAnalysis.swift",
        "FramePipeline.swift",
        "GeminiChat.swift",
        "GeminiClient.swift",
        "GeminiDocs.swift",
        "GeminiLast.swift",
        "GeminiMemory.swift",
        "GeminiProfiles.swift",
        "GeminiText.swift",
        "GeminiVideo.swift",
        "GeminiVideoQueue.swift",
        "Guidance.swift",
        "GuidanceSpeaker.swift",
        "H264Decoder.swift",
        "Health.swift",
        "HelpRow.swift",
        "ImageOrientation.swift",
        "Keychain.swift",
        "Logger.swift",
        "ModelChoice.swift",
        "NoticeQueue.swift",
        "PDFWrap.swift",
        "PageEdges.swift",
        "PreviewLayout.swift",
        "QuestionRecorder.swift",
        "RoutePicker.swift",
        "ScreenDimmer.swift",
        "ScreenLock.swift",
        "SelfHeal.swift",
        "Settings.swift",
        "SettingsView.swift",
        "SpeechTrigger.swift",
        "SpeechVoice.swift",
        "SpokenReport.swift",
        "StatusReport.swift",
        "StreamAssembly.swift",
        "UDPSocket.swift",
        "UploadQueue.swift",
        "VideoRecording.swift",
        "VideoRenderer.swift"
    ]

    static let entries: [PortEntry] = [
        PortEntry(v1: "CameraBattery.swift", status: .copied, note: "", types: [CameraBatteryLevel.self, CameraBattery.self, CameraBatteryMonitor.self, CameraLowBatteryWatcher.self]),
        PortEntry(v1: "CameraClient.swift", status: .copied, note: "", types: [CameraState.self, CameraClient.self]),
        PortEntry(v1: "CameraProbe.swift", status: .copied, note: "", types: [CameraProbe.self]),
        PortEntry(v1: "CameraProtocol.swift", status: .copied, note: "", types: [PPPP.self, CameraUID.self, CameraCommand.self]),
        PortEntry(v1: "CameraSession.swift", status: .copied, note: "", types: [CameraSession.self]),
        PortEntry(v1: "CaptureEngine.swift", status: .copied, note: "", types: [CaptureOptions.self, CapturedPhoto.self, CaptureError.self, CaptureEngine.self, MotionDetector.self]),
        PortEntry(v1: "CaptureLog.swift", status: .copied, note: "", types: [CaptureLog.self, DailyStats.self, DailyStatsStore.self]),
        PortEntry(v1: "DocumentGate.swift", status: .copied, note: "", types: [DocumentVerdict.self, DocumentGate.self]),
        PortEntry(v1: "Enhancer.swift", status: .copied, note: "", types: [TimestampMode.self, EnhanceOptions.self, Enhancer.self]),
        PortEntry(v1: "FrameAnalysis.swift", status: .copied, note: "", types: [StoredFrame.self, FrameAnalysis.self, FrameStore.self]),
        PortEntry(v1: "FramePipeline.swift", status: .copied, note: "", types: [FramePipeline.self]),
        PortEntry(v1: "Guidance.swift", status: .copied, note: "", types: [ColumnBox.self, PageMetrics.self, GuidanceAnalyzer.self, ColumnChoice.self, GuidanceVocabulary.self, GuidanceAdvice.self, GuidanceTrend.self, GuidanceTrendTracker.self, GuidanceScene.self, GuidanceConfig.self, GuidanceDecision.self, GuidanceAdvisor.self, GuidanceEngine.self]),
        PortEntry(v1: "H264Decoder.swift", status: .copied, note: "", types: [H264Decoder.self]),
        PortEntry(v1: "ImageOrientation.swift", status: .copied, note: "", types: [ImageOrientation.self]),
        PortEntry(v1: "PageEdges.swift", status: .copied, note: "", types: [PageEdges.self, PageEdgeDetector.self, PageEdgeTracker.self]),
        PortEntry(v1: "PreviewLayout.swift", status: .copied, note: "", types: [PreviewLayout.self]),
        PortEntry(v1: "StreamAssembly.swift", status: .copied, note: "", types: [DrwAssembler.self, VideoFrame.self, VideoFrameParser.self]),
        PortEntry(v1: "UDPSocket.swift", status: .copied, note: "", types: [UDPAddress.self, UDPSocket.self, LocalNetwork.self]),
        PortEntry(v1: "VideoRenderer.swift", status: .copied, note: "", types: [VideoRenderer.self, DisplayView.self, VideoLayerView.self]),
        PortEntry(v1: "VideoRecording.swift", status: .adapted, note: "Sources/Camera/VideoRecording.swift: VideoRecorder korundu; VideoOutbox (belge klasörüne yükleme) ve VideoVocabulary (V1 sesli video komutları) alınmadı", types: [VideoRecorder.self]),
        PortEntry(v1: "Settings.swift", status: .adapted, note: "Sources/Camera/CameraSettings.swift: kamera ayarlarının tamamı V1 anahtar adları ve varsayılanlarıyla; belge/Gemini belge/sınav ayarları `CameraSettings.excluded` listesinde", types: [CameraSettings.self]),
        PortEntry(v1: "SettingsView.swift", status: .adapted, note: "Sources/Views/CameraSettingsView.swift: V1'in Kamera, Video, Fotoğraf, Otomatik çekim, Sesli komut, Sesli konumlandırma, Pil ve kestirme bölümleri", types: [CameraSettingsSections.self]),
        PortEntry(v1: "SpeechTrigger.swift", status: .adapted, note: "Sources/Camera/SpeechMatcher.swift: yalnız SpeechMatcher ve SpeechIntent (komut eşleştirme); SFSpeechRecognizer dinleyicisi alınmadı, V3 dinleyicisi kullanılır", types: [SpeechMatcher.self, SpeechIntent.self]),
        PortEntry(v1: "SpokenReport.swift", status: .adapted, note: "Sources/Camera/SpokenReport.swift: yalnız pil cümleleri (battery, phoneLow); belge / PDF / klasör raporları alınmadı", types: [SpokenReport.self]),
        PortEntry(v1: "App.swift", status: .v3Equivalent, note: "Sources/App/App.swift: V3'te aynı işi yapan bileşen var", types: []),
        PortEntry(v1: "AudioRoute.swift", status: .v3Equivalent, note: "Sources/Services/AudioRouting.swift: V3'te aynı işi yapan bileşen var", types: []),
        PortEntry(v1: "BatteryWatcher.swift", status: .v3Equivalent, note: "Sources/Services/BatteryWatcher.swift: V3'te aynı işi yapan bileşen var", types: []),
        PortEntry(v1: "BuildInfo.swift", status: .v3Equivalent, note: "Sources/BuildInfo.swift: V3'te aynı işi yapan bileşen var", types: []),
        PortEntry(v1: "GeminiProfiles.swift", status: .v3Equivalent, note: "Sources/Models/GeminiProfiles.swift: V3'te aynı işi yapan bileşen var", types: []),
        PortEntry(v1: "HelpRow.swift", status: .v3Equivalent, note: "Sources/Views/HelpRow.swift: V3'te aynı işi yapan bileşen var", types: []),
        PortEntry(v1: "Keychain.swift", status: .v3Equivalent, note: "Sources/Support/Keychain.swift: V3'te aynı işi yapan bileşen var", types: []),
        PortEntry(v1: "Logger.swift", status: .v3Equivalent, note: "Sources/Support/Logger.swift: V3'te aynı işi yapan bileşen var", types: []),
        PortEntry(v1: "ScreenDimmer.swift", status: .v3Equivalent, note: "Sources/Services/ScreenDimmer.swift: V3'te aynı işi yapan bileşen var", types: []),
        PortEntry(v1: "ScreenLock.swift", status: .v3Equivalent, note: "Sources/Views/ScreenLock.swift: V3'te aynı işi yapan bileşen var", types: []),
        PortEntry(v1: "SpeechVoice.swift", status: .v3Equivalent, note: "Sources/Support/SpeechVoice.swift: V3'te aynı işi yapan bileşen var", types: []),
        PortEntry(v1: "RoutePicker.swift", status: .v3Equivalent, note: "Sources/Views/RoutePicker.swift: V3'te aynı işi yapan bileşen var", types: []),
        PortEntry(v1: "GuidanceSpeaker.swift", status: .v3Equivalent, note: "Sources/Services/SpeechOutput.swift: V3'te aynı işi yapan bileşen var", types: []),
        PortEntry(v1: "BelgeKlasoru.swift", status: .excluded, note: "Belge klasörüne yükleme: V4 belge yüklemez (V3'ün kayıt klasörü kullanılır)", types: []),
        PortEntry(v1: "FolderClient.swift", status: .excluded, note: "Belge klasörüne yükleme", types: []),
        PortEntry(v1: "UploadQueue.swift", status: .excluded, note: "Fotoğrafları PDF yapıp klasöre yükleme: V4 toplu gönderim yapmaz", types: []),
        PortEntry(v1: "PDFWrap.swift", status: .excluded, note: "PDF üretimi: soru fotoğrafı JPEG olarak Gemini'ye gider", types: []),
        PortEntry(v1: "ExamGemini.swift", status: .excluded, note: "V1 sınav modu: V4 akışı V3 oturumudur", types: []),
        PortEntry(v1: "ExamMode.swift", status: .excluded, note: "V1 sınav modu", types: []),
        PortEntry(v1: "ExamPortsReal.swift", status: .excluded, note: "V1 sınav modu", types: []),
        PortEntry(v1: "ExamText.swift", status: .excluded, note: "V1 sınav modu", types: []),
        PortEntry(v1: "GeminiChat.swift", status: .excluded, note: "V1 belge sohbeti: V4 Gemini'yi V3 profil zinciriyle kullanır", types: []),
        PortEntry(v1: "GeminiClient.swift", status: .excluded, note: "V1 belge sohbeti istemcisi: V3 Gemini.swift kullanılır", types: []),
        PortEntry(v1: "GeminiDocs.swift", status: .excluded, note: "V1 belge sohbeti", types: []),
        PortEntry(v1: "GeminiLast.swift", status: .excluded, note: "V1 son cevap kaydı: V3 cevap kütüphanesi var", types: []),
        PortEntry(v1: "GeminiMemory.swift", status: .excluded, note: "V1 belge önbelleği", types: []),
        PortEntry(v1: "GeminiText.swift", status: .excluded, note: "V1 belge sohbeti metinleri", types: []),
        PortEntry(v1: "GeminiVideoQueue.swift", status: .excluded, note: "V1 video sırası: V4 her soruyu tek tek gönderir; bekleyenler PendingCaptures'ta", types: []),
        PortEntry(v1: "ModelChoice.swift", status: .excluded, note: "V1 sesli model seçimi: V3 profil zinciri kendi geçer", types: []),
        PortEntry(v1: "QuestionRecorder.swift", status: .excluded, note: "V1 soru kaydedici: V3 QuestionAudio / TranscriptAccumulator var", types: []),
        PortEntry(v1: "SelfHeal.swift", status: .excluded, note: "V1 kendini onarma: V3 RecoveryCoordinator kullanılır", types: []),
        PortEntry(v1: "StatusReport.swift", status: .excluded, note: "V1 durum raporu: V3'ün kendi durum bildirimi var", types: []),
        PortEntry(v1: "NoticeQueue.swift", status: .excluded, note: "V1 haber kuyruğu: V3 speakNotice / warn kullanılır", types: []),
        PortEntry(v1: "AppModel.swift", status: .adapted, note: "CameraCaptureController (kamera yaşam döngüsü, konumlandırma, fotoğraf + sayfa videosu, kapatma) ve SessionViewModel+Camera (kestirmeler, internete dönüş, gönderim); V1'in elle çekim, sınav, Gemini sohbeti, yükleme kuyruğu, duraklatma ve sağlık izleme parçaları V4'te yoktur", types: [CameraCaptureController.self, CapturedQuestion.self]),
        PortEntry(v1: "ContentView.swift", status: .adapted, note: "Kamera önizleme kartı yalnız çekim sürerken ana ekranda görünür (canlı görüntü, durum, pil, Şimdi çek düğmesi)", types: [ContentView.self]),
        PortEntry(v1: "ConnectionAnnouncer.swift", status: .adapted, note: "Kamera yalnız çekim sırasında açıktır: bağlandı (Kamera hazır), koptu (8 sn görüntü yoksa vazgeçilir, söylenir) ve bağlanılamadı (onarım adımı) CameraCaptureController ve SessionViewModel+Camera içindedir", types: [CameraCaptureController.self]),
        PortEntry(v1: "GeminiVideo.swift", status: .adapted, note: "Fotoğraf + video satır içi (≤ 14 MB; fps, mediaResolution) V3 Gemini profil zincirine gider; Files API yüklemesi ve toplu cevap biçimi V4'te yoktur (soru başına tek satır cevap)", types: [GeminiAnswerService.self]),
        PortEntry(v1: "Health.swift", status: .adapted, note: "DiskGuard: çekimden önce boş yer denetimi (diğer sınıflar V3 SystemHealth ile karşılanır)", types: [DiskGuard.self])
    ]
}
