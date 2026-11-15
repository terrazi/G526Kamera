# Sürüm 4: V1 kamera altyapısının taşınması

V1 (`pdf-toplu-gonderim` dalı) kamera uygulamasından V4'e (`surum-4`) neyin, nasıl alındığının kaydı. V1'in `Sources/` altındaki **62 dosyasının tamamı** aşağıda tek tek yer alır. Aynı kayıt kodda `Sources/Camera/PortManifest.swift` olarak durur ve `Tests/Camera/PortManifestTests.swift` ile `CameraSettingsTests.swift` bu kaydın V1'le birebir örtüştüğünü, taşınan türlerin derlemede var olduğunu ve V1'in her kamera ayarının ya alındığını ya da gerekçesiyle dışarıda bırakıldığını denetler.

## Dosya dosya durum

| V1 dosyası | Durum | V4'te / gerekçe |
|---|---|---|
| `CameraBattery.swift` | Aynen alındı | Sources/Camera/CameraBattery.swift (V1 ile satır satır aynı); türler: CameraBatteryLevel, CameraBattery, CameraBatteryMonitor, CameraLowBatteryWatcher |
| `CameraClient.swift` | Aynen alındı | Sources/Camera/CameraClient.swift (V1 ile satır satır aynı); türler: CameraState, CameraClient |
| `CameraProbe.swift` | Aynen alındı | Sources/Camera/CameraProbe.swift (V1 ile satır satır aynı); türler: CameraProbe |
| `CameraProtocol.swift` | Aynen alındı | Sources/Camera/CameraProtocol.swift (V1 ile satır satır aynı); türler: PPPP, CameraUID, CameraCommand |
| `CameraSession.swift` | Aynen alındı | Sources/Camera/CameraSession.swift (V1 ile satır satır aynı); türler: CameraSession |
| `CaptureEngine.swift` | Aynen alındı | Sources/Camera/CaptureEngine.swift (V1 ile satır satır aynı); türler: CaptureOptions, CapturedPhoto, CaptureError, CaptureEngine, MotionDetector |
| `CaptureLog.swift` | Aynen alındı | Sources/Camera/CaptureLog.swift (V1 ile satır satır aynı); türler: CaptureLog, DailyStats, DailyStatsStore |
| `DocumentGate.swift` | Aynen alındı | Sources/Camera/DocumentGate.swift (V1 ile satır satır aynı); türler: DocumentVerdict, DocumentGate |
| `Enhancer.swift` | Aynen alındı | Sources/Camera/Enhancer.swift (V1 ile satır satır aynı); türler: TimestampMode, EnhanceOptions, Enhancer |
| `FrameAnalysis.swift` | Aynen alındı | Sources/Camera/FrameAnalysis.swift (V1 ile satır satır aynı); türler: StoredFrame, FrameAnalysis, FrameStore |
| `FramePipeline.swift` | Aynen alındı | Sources/Camera/FramePipeline.swift (V1 ile satır satır aynı); türler: FramePipeline |
| `Guidance.swift` | Aynen alındı | Sources/Camera/Guidance.swift (V1 ile satır satır aynı); türler: ColumnBox, PageMetrics, GuidanceAnalyzer, ColumnChoice, GuidanceVocabulary, GuidanceAdvice, GuidanceTrend, GuidanceTrendTracker, GuidanceScene, GuidanceConfig, GuidanceDecision, GuidanceAdvisor, GuidanceEngine |
| `H264Decoder.swift` | Aynen alındı | Sources/Camera/H264Decoder.swift (V1 ile satır satır aynı); türler: H264Decoder |
| `ImageOrientation.swift` | Aynen alındı | Sources/Camera/ImageOrientation.swift (V1 ile satır satır aynı); türler: ImageOrientation |
| `PageEdges.swift` | Aynen alındı | Sources/Camera/PageEdges.swift (V1 ile satır satır aynı); türler: PageEdges, PageEdgeDetector, PageEdgeTracker |
| `PreviewLayout.swift` | Aynen alındı | Sources/Camera/PreviewLayout.swift (V1 ile satır satır aynı); türler: PreviewLayout |
| `StreamAssembly.swift` | Aynen alındı | Sources/Camera/StreamAssembly.swift (V1 ile satır satır aynı); türler: DrwAssembler, VideoFrame, VideoFrameParser |
| `UDPSocket.swift` | Aynen alındı | Sources/Camera/UDPSocket.swift (V1 ile satır satır aynı); türler: UDPAddress, UDPSocket, LocalNetwork |
| `VideoRenderer.swift` | Aynen alındı | Sources/Camera/VideoRenderer.swift (V1 ile satır satır aynı); türler: VideoRenderer, DisplayView, VideoLayerView |
| `VideoRecording.swift` | Uyarlandı | Sources/Camera/VideoRecording.swift: VideoRecorder korundu; VideoOutbox (belge klasörüne yükleme) ve VideoVocabulary (V1 sesli video komutları) alınmadı |
| `Settings.swift` | Uyarlandı | Sources/Camera/CameraSettings.swift: kamera ayarlarının tamamı V1 anahtar adları ve varsayılanlarıyla; belge/Gemini belge/sınav ayarları `CameraSettings.excluded` listesinde |
| `SettingsView.swift` | Uyarlandı | Sources/Views/CameraSettingsView.swift: V1'in Kamera, Video, Fotoğraf, Otomatik çekim, Sesli komut, Sesli konumlandırma, Pil ve kestirme bölümleri |
| `SpeechTrigger.swift` | Uyarlandı | Sources/Camera/SpeechMatcher.swift: yalnız SpeechMatcher ve SpeechIntent (komut eşleştirme); SFSpeechRecognizer dinleyicisi alınmadı, V3 dinleyicisi kullanılır |
| `SpokenReport.swift` | Uyarlandı | Sources/Camera/SpokenReport.swift: yalnız pil cümleleri (battery, phoneLow); belge / PDF / klasör raporları alınmadı |
| `App.swift` | V3'te var | Sources/App/App.swift: V3'te aynı işi yapan bileşen var |
| `AudioRoute.swift` | V3'te var | Sources/Services/AudioRouting.swift: V3'te aynı işi yapan bileşen var |
| `BatteryWatcher.swift` | V3'te var | Sources/Services/BatteryWatcher.swift: V3'te aynı işi yapan bileşen var |
| `BuildInfo.swift` | V3'te var | Sources/BuildInfo.swift: V3'te aynı işi yapan bileşen var |
| `GeminiProfiles.swift` | V3'te var | Sources/Models/GeminiProfiles.swift: V3'te aynı işi yapan bileşen var |
| `HelpRow.swift` | V3'te var | Sources/Views/HelpRow.swift: V3'te aynı işi yapan bileşen var |
| `Keychain.swift` | V3'te var | Sources/Support/Keychain.swift: V3'te aynı işi yapan bileşen var |
| `Logger.swift` | V3'te var | Sources/Support/Logger.swift: V3'te aynı işi yapan bileşen var |
| `ScreenDimmer.swift` | V3'te var | Sources/Services/ScreenDimmer.swift: V3'te aynı işi yapan bileşen var |
| `ScreenLock.swift` | V3'te var | Sources/Views/ScreenLock.swift: V3'te aynı işi yapan bileşen var |
| `SpeechVoice.swift` | V3'te var | Sources/Support/SpeechVoice.swift: V3'te aynı işi yapan bileşen var |
| `RoutePicker.swift` | V3'te var | Sources/Views/RoutePicker.swift: V3'te aynı işi yapan bileşen var |
| `GuidanceSpeaker.swift` | V3'te var | Sources/Services/SpeechOutput.swift: V3'te aynı işi yapan bileşen var |
| `BelgeKlasoru.swift` | Alınmadı | Belge klasörüne yükleme: V4 belge yüklemez (V3'ün kayıt klasörü kullanılır) |
| `FolderClient.swift` | Alınmadı | Belge klasörüne yükleme |
| `UploadQueue.swift` | Alınmadı | Fotoğrafları PDF yapıp klasöre yükleme: V4 toplu gönderim yapmaz |
| `PDFWrap.swift` | Alınmadı | PDF üretimi: soru fotoğrafı JPEG olarak Gemini'ye gider |
| `ExamGemini.swift` | Alınmadı | V1 sınav modu: V4 akışı V3 oturumudur |
| `ExamMode.swift` | Alınmadı | V1 sınav modu |
| `ExamPortsReal.swift` | Alınmadı | V1 sınav modu |
| `ExamText.swift` | Alınmadı | V1 sınav modu |
| `GeminiChat.swift` | Alınmadı | V1 belge sohbeti: V4 Gemini'yi V3 profil zinciriyle kullanır |
| `GeminiClient.swift` | Alınmadı | V1 belge sohbeti istemcisi: V3 Gemini.swift kullanılır |
| `GeminiDocs.swift` | Alınmadı | V1 belge sohbeti |
| `GeminiLast.swift` | Alınmadı | V1 son cevap kaydı: V3 cevap kütüphanesi var |
| `GeminiMemory.swift` | Alınmadı | V1 belge önbelleği |
| `GeminiText.swift` | Alınmadı | V1 belge sohbeti metinleri |
| `GeminiVideoQueue.swift` | Alınmadı | V1 video sırası: V4 her soruyu tek tek gönderir; bekleyenler PendingCaptures'ta |
| `ModelChoice.swift` | Alınmadı | V1 sesli model seçimi: V3 profil zinciri kendi geçer |
| `QuestionRecorder.swift` | Alınmadı | V1 soru kaydedici: V3 QuestionAudio / TranscriptAccumulator var |
| `SelfHeal.swift` | Alınmadı | V1 kendini onarma: V3 RecoveryCoordinator kullanılır |
| `StatusReport.swift` | Alınmadı | V1 durum raporu: V3'ün kendi durum bildirimi var |
| `NoticeQueue.swift` | Alınmadı | V1 haber kuyruğu: V3 speakNotice / warn kullanılır |
| `AppModel.swift` | Uyarlandı | `CameraCaptureController` (Sources/Camera) + `SessionViewModel+Camera`: kamera yaşam döngüsü, bağlantı izleme (8 sn görüntü gelmezse kopma), çekim, sesle konumlandırma, sayfa videosu, kamerayı kapatma, bağlantı onarımı |
| `ContentView.swift` | Uyarlandı | Ana ekrandaki kamera kartı: canlı önizleme, durum satırı, pil, çekim sırasında "Şimdi çek" düğmesi |
| `ConnectionAnnouncer.swift` | Uyarlandı | Kamera bağlandı / koptu cümleleri çekim akışının içinde (`CameraSay`, `Say.camera…`); "Kamera ve gönderim durumunu da söyle" ayarıyla açılıp kapanır |
| `GeminiVideo.swift` | Uyarlandı | `GeminiAnswerService.answer(capture:expectedNumber:)`: fotoğraf + video (inline, fps, yüksek medya çözünürlüğü) V3'ün profil zincirinden gider |
| `Health.swift` | Uyarlandı | `DiskGuard`: video öncesi boş yer denetimi (1500 MB altı uyarı, 400 MB altı çekim yok); diğer sınıflar V3 SystemHealth ile karşılanır |

Özet: Aynen alındı 19, Uyarlandı 5, V3'te var 13, BEKLİYOR 5, Alınmadı 20

## Kamera ayarları

V1'in kamera ayarlarının tamamı **aynı anahtar adları ve varsayılanlarla** `CameraSettings` içinde. V1 ya da V3 kurulu telefonda daha önce yazılmış değerler (kamera adı, parola, yön…) kendiliğinden gelir. Ayar ekranı bölümleri (`CameraSettings.Group`):

| Bölüm | Ayarlar |
|---|---|
| Kamera | uid, cameraIP, cameraPassword, streamQuality, guidanceFrame, imageOrientation |
| Video kaydı | pageVideoSeconds, examVideoMaxSeconds, videoToGemini, videoQuestion, videoHighRes |
| Fotoğraf | enhancement, multiFrame, documentOnly, deskew, timestampMode, upscale, jpegQuality, burstBefore, burstAfter |
| Otomatik çekim | motionEnabled, motionSensitivity |
| Sesle çekim (okey) | voiceEnabled, triggerWord, cooldown |
| Sesli konumlandırma | guidanceEnabled, guidanceVoice, videoGuidance, statusNotices, guidanceAutoCapture, guidanceSharpness, guidanceGlare, guidanceDescribe, guidancePageEdges, guidanceAutoPick |
| Pil ve ısınma | previewOff (ekran kısma V3'ün dimScreen ayarı) |
| Kamera kestirmesi | cameraShortcutName |

V1'e göre bilerek değişen varsayılanlar:

- `guidanceEnabled`: V1 kapalı, V4 **açık** (her kamera çekimi sesli konumlandırmayla başlar)
- `guidanceDescribe`: V1 açık, V4 **kapalı** (kullanıcı kararı: kadraj tarifi ve "soru bölünüyor" uyarıları verilmesin)

### V1'de olup V4'e alınmayan ayarlar

| Anahtar | Gerekçe |
|---|---|
| `dimScreen` | V3'te aynı işi `AppSettings.dimScreen` (v3.dimScreen) yapıyor |
| `speechVoiceID` | Okuma sesini V3'ün `phoneVoiceID` ayarı belirler |
| `speechRate` | Okuma hızını V3 konuşma çıkışı yönetir |
| `videoMaxSeconds` | Elle video çekimi V4 akışında yok; soru videosunun süresini `pageVideoSeconds` belirler |
| `examPageVideo` | V4'te soru her zaman sayfa videosuyla çekilir; kapatılacak bir eski yöntem yok |
| `videoSendMode` | V4 her soruyu tek tek, hemen gönderir; sıra bekletme kipi anlamsız |
| `finishWord` | Fotoğrafları toplu PDF yapma komutu: V4'te toplu gönderim yok |
| `sendMode` | Belge klasörüne tek tek / toplu yükleme: V4'te belge yükleme yok |
| `batchSize` | Toplu yükleme eşiği: V4'te belge yükleme yok |
| `batchIdle` | Toplu yükleme bekleme süresi: V4'te belge yükleme yok |
| `uploadFormat` | Klasöre PDF / JPEG yükleme biçimi: V4'te belge yükleme yok |
| `geminiEnabled` | V1'in belge sohbeti anahtarı; V4'te Gemini V3'ün profilleriyle çalışır |
| `geminiActive` | V1'in aktif Gemini profili; V3 profil zinciri kullanılıyor |
| `geminiProfiles` | V3'te `v3.geminiProfiles` olarak var |
| `geminiAutoFallback` | V3 zinciri yedeğe kendisi geçer |
| `geminiOverloadFallback` | V3 zinciri yedeğe kendisi geçer |
| `geminiChainFallback` | V3 zinciri yedeğe kendisi geçer |
| `geminiWaitLimit` | V3'ün kendi bekleme sınırları var |
| `geminiCapMonth` | V1 aylık kota sayacı; V3'te yok |
| `geminiCapPrev` | V1 aylık kota sayacı; V3'te yok |
| `geminiSessionTimeout` | V1 belge sohbeti oturumu; V4'te oturum yok |
| `geminiSession` | V1 belge sohbeti oturumu; V4'te oturum yok |
| `geminiThinking` | V1 düşünme düzeyi; V3 profil modeli belirler |
| `geminiPrivacyOK` | V1 gizlilik onayı; V4 yalnız kullanıcının başlattığı soruyu gönderir |
| `geminiDocCount` | V1 belge sayısı; V4'te belge yok |
| `geminiMemory` | V1 Files API belge önbelleği; V4'te belge seti yok |
| `geminiOptionCodes` | V1 şık kod sözcükleri; V3'ün cevap biçimi geçerli |
| `geminiBatchLast` | V1 toplu cevap sayacı; V4'te toplu cevap yok |
| `listenEnd` | V1 dinleyicisinin bitiş ayarı; V3 kendi dinleyicisini kullanır |
| `listenSilence` | V1 dinleyicisinin sessizlik ayarı; V3 kendi dinleyicisini kullanır |
| `audioLayout` | V1 ses yerleşimi; V3 ses yönlendirmesi sabit (kulaklık + Lightning mikrofon) |
| `examCancelWindow` | V1 sınav modu; V4 akışı V3 oturumudur |
| `examGap` | V1 sınav modu; V4 akışı V3 oturumudur |
| `examVideoFirst` | V1 sınav modu; V4 akışı V3 oturumudur |
| `examSelfCheck` | V1 sınav modu; V3'ün kendi açılış sınaması var |
| `examEnabled` | V1 sınav modu anahtarı; V4 her zaman sınav akışıdır |
| `connectionShortcutName` | V1 internet kestirmesi; V4'te bağlantı kestirmeleri yeniden düzenleniyor (Wi-Fi/hücresel) |
| `repairChecks` | V1 kendini onarma yoklaması; V3 `RecoveryCoordinator` kullanılıyor |
| `repairCheckSeconds` | V1 kendini onarma yoklaması; V3 `RecoveryCoordinator` kullanılıyor |
| `repairWaitSeconds` | V1 kendini onarma yoklaması; V3 `RecoveryCoordinator` kullanılıyor |
| `audioShortcutName` | V1 ses kestirmesi; V3'te `bluetoothShortcut` / `resetShortcut` var |

## Altyapı denetimi (V1 proje tanımına göre)

- `Info.plist`: V1'deki `NSLocalNetworkUsageDescription` (kameranın kendi Wi-Fi ağındaki UDP bağlantısı için yerel ağ izni) V4'te **eksikti, eklendi**.
- Mikrofon / konuşma tanıma izinleri V3'te var; `UIBackgroundModes: audio` V3'te var.
- Çıkış kimliği ve paket adı V3'le aynı (`com.huseyinozer.g526`): V1'de yazılan kamera ayarları aynı anahtarlarla okunur.
- Test fixture'ları (`RealFrameFixtures`) ve kamera testleri `Tests/Camera/` altına alındı; V1'in belge, sınav, Gemini belge sohbeti, kendini onarma ve sesli komut dinleyicisi testleri alınmadı (kodları da alınmadığı için).
- V1 `UITests` (ekran görüntüsü testi) alınmadı: V4'ün ekranları farklı.

## Taşınan testler

`ProtocolTests`, `CameraProbeTests`, `ImageOrientationTests`, `PageEdgesTests`, `PreviewLayoutTests`, `VideoRecorderTests`, `DocumentGateTests`, `RealFrameFixtures`, `TimestampTests`, `PowerSavingTests`, `GuidanceTests`, `AutoPickTests`, `GhostTests`, `BatteryTests` (V1 testlerinin V4'te var olan türlere uyarlanmış hâli; PDF, belge klasörü, sesli video komutu ve rapor cümleleri testleri kodlarıyla birlikte alınmadı). Yeni: `CameraSettingsTests` (ayar eksiksizliği, varsayılan eşitliği, kalıcılık, sınırlar, geçişler), `PortManifestTests` (dosya kaydının eksiksizliği).

## Bekleyen iş

Yok: V1'in 62 dosyasının hepsi ya alındı, uyarlandı, V3'te karşılığı var ya da gerekçesiyle alınmadı (`PortManifestTests.testNothingIsLeftPending` bekleyen kaydı kabul etmez).

## V4'te işlemeyen V1 kamera ayarları

Anahtarlar ve varsayılanlar V1'le birebir korunur (V1'e dönülürse aynı değerler çalışır; `CameraSettingsTests` anahtar eksiksizliğini denetler), ama V4 akışı şunları kullanmaz; ayar ekranında sönük ve açıklamalı görünür:

- Görüntü değişince çek (hareket tetiği) ve duyarlılık: kamera yalnız "evet" denince açılıp tek soru çeker.
- Sesli komutla çek, tetikleme sözcüğü, çekimler arası bekleme: kamera açıkken mikrofon soru okumaya ayrılmıştır; yardım eden biri için ekranda "Şimdi çek" düğmesi vardır.
- Uzun video sınırı (`examVideoMaxSeconds`): V1'in sürekli kaydı içindir; V4'te soru videosunun süresi `pageVideoSeconds`'tır.
- Konum uygunsa kendiliğinden çek, tam sığan bölümü kendiliğinden seç, video sırasında konum tarifi: çekim her zaman kendiliğinden yapılır, bölüm sorulmaz (kadrajın ortasındaki bölüm hedeflenir), video sırasında tarif verilmez.

"Sesle konumlandır" kapalıysa konumlandırma atlanır ve kamera bağlanır bağlanmaz çeker.

## Kamerayı dene

Ayarlar > Kamera > "Kamerayı dene" (`CameraTester`): sınavın adımlarını (Kameraya Geç kestirmesi, kameraya bağlanıp çekim, Hücresele Geç kestirmesi, internetin gelmesi) sınavdan önce yürütür; deneme çekimi gönderilmez ve silinir. iOS'un yerel ağ izni ilk kamera kullanımında sorulduğundan, kutunun sınavda çıkmaması için bir kez denenmelidir. Sınav sürerken çalışmaz.

## V4 akışı

Soru başına: "Bu soruyu kamera ile çekip göndermek ister misiniz?" Evet: (1) `Kameraya Geç` kestirmesi (hücresel kapanır, kameranın Wi-Fi'sine bağlanır); (2) kamera açılır, soru kadraja alınır, video + fotoğraf çekilir, kamera kapanır; (3) `Hücresele Geç` kestirmesi (Wi-Fi kapanır, hücresel açılır), internet gelene kadar beklenir; (4) çekim Gemini'ye gider, cevap V3'teki gibi okunur ve kaydedilir; (5) sıradaki soru için yine sorulur. Toplu gönderim ve yedek Wi-Fi interneti yoktur.

- Kameraya bağlanılamazsa `Kamera Bağlantısını Onar` kestirmesi (Ayarlar'daki Wi-Fi adımı; yazılmamışsa `Kameraya Geç` yeniden) en çok iki kez çalışır ve çekim yeniden denenir.
- İnternet gelmezse V3'ün internet onarımı çalışır (hücresel, sıfırlama); Wi-Fi artık internet onarım adımı değildir.
- Çekilen soru gönderilemezse (ağ hatası) telefonda bekler, bir sonraki soru sınırında bir kez yeniden denenir; en çok 3 çekim saklanır. Engellenen ya da çok büyük çekim saklanmaz.
- Soru numarasını Gemini görüntüden okur; okuyamazsa sıra numarası kullanılır (sesle sorulmaz). Kadrajdaki yarım görünen komşu sorular Gemini'ye yok sayılması söylenerek gönderilir.
- Çekilen fotoğraf ve video cevap klasörüne kaydedilmez; yalnız gönderilir, video gönderimden sonra silinir.
