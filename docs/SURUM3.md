# Sürüm 3 — Yalnız ses tasarımı

Kamera yok; giriş yaka mikrofonu, çıkış Bluetooth kulaklık. MVVM: `Models` (veri ve saf mantık), `Services` (dış dünya
arkasındaki protokoller ve gerçekleri), `ViewModels` (durum makinesi), `Views` (SwiftUI). Dış dünya `SessionDependencies` ile verilir;
gerçek kurulum `App/AppEnvironment`, testler sahtelerle (`Tests/Fakes`) kurar.

## Modüller ve dosyaları

| Modül | Ne yapar | Dosyalar |
|---|---|---|
| 1 Ayarlar ve açılış | başlama saati, API anahtarı, 3 kestirme adı; açılışta donanım denetimi ve "hazırım" anonsu | `AppSettings`, `StartScheduler`, `SessionViewModel+Checkup`, `HealthCheck`, `Permissions` |
| 2 Ses kalkanı | `.playAndRecord`, seçenekler yalnız `[.allowBluetooth, .allowBluetoothA2DP]`; yol değişince kontrol, kopunca anında sus ve duraklat | `AudioRouting`, `SessionViewModel+Recovery` (fail-safe) |
| 3 Dikte | çevrimdışı `SFSpeechRecognizer` (tr-TR, `requiresOnDeviceRecognition`), sürekli; "Cevapla"/"Gönder" son sözcükse mikrofon durur, tetikleyici kırpılır | `SpeechListener`, `Transcript`, `QuestionAudio` |
| 4 Kendini onarma | 30 sn sessizlik ya da düşen istek; `NWPathMonitor` + Kestirmeler: Wi-Fi → hücresel → sıfırlama; düzelince Google/Gemini'ye ping, anons, mikrofon | `SilenceWatchdog`, `NetworkWatcher`, `ShortcutRunner`, `RecoveryCoordinator`, `SessionViewModel+Recovery` |
| 5 Cevap | Gemini'ye soru (dikte metni + isteğe bağlı ses), tek satır cevap, kulaklıktan okuma ve `soru_N` olarak kaydetme, sonra yeni soruyu dinleme | `AnswerService`, `AnswerRecord`, `SpeechOutput`, `GeminiVoice`, `AnswerLibrary` |
| 6 Tekrar | test sonu çevrimdışı; dosyalar sırayla, aralarında `DispatchQueue.main.asyncAfter` ile ayarlanan boşluk | `ReplayController`, `Scheduling`, `SessionViewModel+Replay` |

## Kararlar ve varsayımlar

- **"Şık şehri":** şıklar A=Adana, B=Bursa, C=Ceyhan, D=Denizli, E=Erzurum kod sözcükleridir; cevap bu sözcükle söylenir.
- **Bir soru, bir istek:** her soru ayrı gönderilir, ayrı cevaplanır. Cevap hemen okunur (Modül 5) ve dosyaya kaydedilir; test sonunda
  hepsi Modül 6 ile yeniden çalınır. Ses: Gemini ses modeli (ayar açıksa), başarısız olursa telefonun sesi.
- **Dikte + ses:** dikte tetikleyici ve ekran metni için kalır; ayrıca soru sesi (16 kHz, tek kanal WAV, en çok 180 sn) dikteye ek
  olarak Gemini'ye gider ve asıl kaynak sayılır. Komuta, kullanıcının İngilizce telaffuzunun zayıf olduğu ve kelimeleri yanlış
  söyleyebileceği, bu yüzden empati kurup çok boyutlu düşünmesi gerektiği yazılıdır.
- **MP3 yok:** iOS MP3 kodlayamaz; kayıtlar `.m4a` (AAC), Gemini sesi gelirse `.wav`.
- **Tetikleyici:** yalnız metnin son sözcüğü "Cevapla"/"Gönder" ise ve 0,5 sn değişmeden kalırsa; "gönderi" ya da cümle ortasındaki "gönder" tetiklemez.
- **30 sn sessizlik:** okuyucu soruyu düşünüyor da olabilir. Önce dinleme sessizce yenilenir ve mikrofonun ses verip vermediğine bakılır;
  yalnız mikrofon donmuşsa (ya da yeniden açılamıyorsa) `Sistemi_Sifirla` çalışır.
- **Fail-safe:** çıkış Bluetooth kulaklık değilse ya da giriş harici mikrofon değilse (`AudioRouting.verdict`) ses anında durur, mikrofon
  kapanır; yol 1,5 sn sabit güvenli kalırsa devam edilir, 20 sn dönmezse sıfırlama kestirmesi çalışır. Hoparlör `overrideOutputAudioPort`
  ile de kullanılmaz.
- **Telefon yeniden başlatma / uygulamayı yeniden açma** yoktur (istenmedi).
- **Zamanlı başlatma:** iOS tam saatinde uyanmaya izin vermez; Kestirmeler otomasyonu `g526kamera://basla` açar. Yedek: uygulama
  açıkken zamanlayıcı, sessiz bildirim.

## Sınırlar (denenmedi)

Cihazda denenmedi: Lightning mikrofon + Bluetooth çıkışın aynı anda çalışması, çevrimdışı Türkçe dikte, Gemini ses modelinin
ücretsiz kotası ve gecikmesi, Kestirmelerin uygulamaya dönmesi, kilitli ekranda davranış. Arama ve mesaj engelleme uygulamadan
yapılamaz (Odak + Kestirme önerilir).
