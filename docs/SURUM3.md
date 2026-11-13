# Sesli Kontrol (Sürüm 3) — Yalnız ses tasarımı

Kamera yok; giriş yaka mikrofonu, çıkış Bluetooth kulaklık. MVVM: `Models` (veri ve saf mantık), `Services` (dış dünya
arkasındaki protokoller ve gerçekleri), `ViewModels` (durum makinesi), `Views` (SwiftUI). Dış dünya `SessionDependencies` ile verilir;
gerçek kurulum `App/AppEnvironment`, testler sahtelerle (`Tests/Fakes`) kurar.

## Modüller ve dosyaları

| Modül | Ne yapar | Dosyalar |
|---|---|---|
| 1 Ayarlar ve açılış | başlama saati, 4 Gemini profili ve anahtarı, kayıt klasörü, 4 kestirme adı; açılışta donanım denetimi (kayıt klasörü, anahtarlar dahil) ve "hazırım" anonsu | `AppSettings`, `GeminiProfiles`, `FolderStore`, `StartScheduler`, `SessionViewModel+Checkup`, `HealthCheck`, `Permissions` |
| 2 Ses kalkanı | `.playAndRecord`, seçenek yalnız `[.allowBluetoothA2DP]` (HFP yok: kulaklık seçilince sesi iPhone'a düşürüyordu); yol değişince kontrol, kopunca anında sus ve duraklat | `AudioRouting`, `SessionViewModel+Recovery` (fail-safe) |
| 3 Dikte | çevrimdışı `SFSpeechRecognizer` (tr-TR, `requiresOnDeviceRecognition`), sürekli; "Cevapla"/"Gönder" son sözcükse mikrofon durur, tetikleyici kırpılır | `SpeechListener`, `Transcript`, `QuestionAudio` |
| 4 Kendini onarma | 30 sn sessizlik ya da düşen istek; `NWPathMonitor` + Kestirmeler: internet için Wi-Fi → hücresel → sıfırlama, donanım için Bluetooth yenileme → sıfırlama; düzelince Google/Gemini'ye ping ya da ses yolu denetimi, anons, mikrofon | `SilenceWatchdog`, `NetworkWatcher`, `ShortcutRunner`, `RecoveryCoordinator`, `SessionViewModel+Recovery` |
| 5 Cevap | Gemini'ye soru (dikte metni + isteğe bağlı ses), tek satır cevap, kulaklıktan okuma ve `soru_N` olarak kaydetme, sonra yeni soruyu dinleme | `AnswerService`, `AnswerRecord`, `SpeechOutput`, `GeminiVoice`, `AnswerLibrary` |
| 6 Tekrar | test sonu çevrimdışı; dosyalar sırayla, aralarında `DispatchQueue.main.asyncAfter` ile ayarlanan boşluk | `ReplayController`, `Scheduling`, `SessionViewModel+Replay` |

## Kararlar ve varsayımlar

- **"Şık şehri":** şıklar A=Adana, B=Bursa, C=Ceyhan, D=Denizli, E=Erzurum kod sözcükleridir; cevap bu sözcükle söylenir.
- **4 yedekli Gemini profili:** her profilin adı, modeli, anahtarı ve "ücretsiz/ücretli anahtar" işareti vardır (ilk sürümdeki düzen).
  Anahtarlar Keychain'de (`geminiKeyV3`, `geminiKeyV3_2…4`), adlar ve modeller UserDefaults'ta saklanır; tek anahtarlı sürümün anahtarı
  1. profile gelir. `GeminiAnswerService` soruyu 1→2→3→4 sırasıyla kendi anahtarlarıyla sorar: kota, sunucu hatası, 40 sn zaman aşımı,
  boş cevap, anahtar ya da model hatasında sıradakine geçer; hata veren profil bir süre sona bırakılır (kota 5 dk, günlük kota 1 saat,
  anahtar/model 15 dk, diğer 2 dk). İçerik engeli, çok büyük istek, harcama sınırı ve internetin hiç olmaması zinciri durdurur.
  Son profile zaman aşımı konmaz. Cevap yedekten geldiyse sebep kırmızı kutuda yazılır. Gemini sesi de aynı anahtarları sırayla dener.
  Açılışta ilk sağlam anahtar bulunana kadar profiller yoklanır; öncekilerin sorunu kırmızı kutuda yazılır.
- **Kayıt klasörü:** kullanıcı Dosyalar uygulamasından bir klasör seçer; `UIDocumentPickerViewController` + güvenlik kapsamlı yer imi
  (bookmark) ile hatırlanır ve oturum boyunca erişim açık tutulur. Cevaplar (`soru_N`, `cevaplar.txt`) gün klasörleriyle buraya yazılır,
  uygulama silinse de kalır. Seçilmemişse ya da erişilemiyorsa uygulamanın kendi klasörü kullanılır, kırmızı uyarı çıkar ve açılış
  kontrolünde ✗ görünür (test yine başlar). Oturum sürerken klasör değiştirilemez.
- **Mikrofon seçimi:** ana ekranda yalnız harici girişler (Lightning/USB, kulaklık mikrofonu, hat girişi) listelenir;
  `AVAudioSession.setPreferredInput` ile seçilir, seçim saklanır ve açılış / yol değişiminde yeniden uygulanır. Sistemin ses yolu seçicisi
  yalnız çıkış içindir, bu yüzden giriş listesi uygulamadadır.
- **Bluetooth yenileme adımı:** donanım sorununda önce hafif `Bluetooth_Yenile` kestirmesi, olmazsa `Sistemi_Sifirla`. Donanım doğrulaması
  yalnız ses yolunun güvenli görünmesine bakar; bu yüzden mikrofon sessiz kaldığı için zorla başlatılan onarımda (`force`) yalnız sıfırlama
  çalışır, yoksa yol sağlam göründüğü için Bluetooth adımı sorunu çözmüş gibi görünürdü.
- **Ana ekran soru listesi:** tek liste, "Yüklenen sorular". Okunmakta olan soru canlı görünür; "Cevapla" denince `QuestionEntry` olarak
  listeye girer ve yanındaki işaret durumu gösterir: saat = okunuyor, "Cevapla" bekleniyor (canlı satır), mektup = Gemini'ye gitti,
  cevap bekleniyor, gülen yüz = cevaplandı (cevap ve model), kırmızı çarpı = gitmedi (neden). Uçak modu kestirmesiyle karışmasın diye
  uçak yerine mektup seçildi.
  Yeni soru en üsttedir. Cevabı gelmeden iş kesilirse (duraklatma, test bitişi) satır "gitmedi" olur; soru yeniden okunur.
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
- **Ses kesintisi (arama, alarm, Siri):** `AVAudioSession.interruptionNotification` ile her şey susar ve durur; bu durumda
  sıfırlama kestirmesi çalışmaz (aramayı keserdi). Kesinti bitince ses oturumu yeniden açılır, yol 1,5 sn sabit güvenliyse "yeniden hazır"
  anonsuyla devam edilir. Bitiş bildirimi gelmezse 15 sn'de bir ses oturumunun yeniden açılıp açılamadığına bakılır.
- **Sonsuz sıfırlama döngüsü yok:** donanım onarımı arada tek kelime tanınmadan 3 kez yapılıp mikrofon yine çalışmıyorsa durulur,
  uyarı çıkar, 5 dk sonra bir kez daha denenir. Başarısız donanım onarımından sonra yeniden deneme 60 sn aralıklıdır.
- **Duyulmayan cevap kaybolmaz:** cevap kaydedilir; okunurken kulaklık koparsa, kulaklık dönünce o cevap (soru yeniden okutulmadan)
  tekrar okunur. Açılış anonsu yarıda kesilirse açılış kontrolü baştan yapılır.
- **Gemini sesi çalışmazsa** (kota, model) 5 dk boyunca denenmez; cevaplar hemen telefonun sesiyle okunur. Her model için bekleme 8 sn.
- **İngilizce sorular:** Türkçe tanıyıcı (tr-TR) İngilizce cümleleri anlamsız yazar. `OnDeviceSpeechListener` aynı mikrofon tamponlarını
  ikinci bir çevrimdışı tanıyıcıya (en-US) da verir; olaylar `englishPartial` / `englishTaskEnded` (tetikleyici aramasına GİRMEZ,
  yalnız `englishAccumulator`'a yazılır). Soru gönderilirken Gemini'ye ses kaydı + Türkçe metin + İngilizce metin gider; komut ikisini
  nasıl yorumlayacağını söyler. İngilizce görev hata verirse sessizce vazgeçilir (Türkçe dinleme etkilenmez). Ayar: "İngilizce dikteyi
  de çalıştır" (açık). Maliyet: iki tanıyıcı → daha çok ısı ve pil.
- **Okunamayan duyuru** oturumu durdurmaz; sebep ekranda yazılır, dinleme sürer.
- **İlk sürümden alınan araçlar** (kamera, PDF, video ve sesli komut sistemi alınmadı): dokunmatik ekran kilidi (`ScreenLock`, ayrı
  UIWindow, 3 sn basılı tutunca açılır, test bitince kendiliğinden kalkar), "Testi Bitir" onayı, elle Duraklat / Devam et
  (`PauseReason.manual`; mikrofon kapanır, uçuştaki soru "gitmedi" olur, okunurken kesilen cevap `unheard` kalır ve devam edince
  yeniden okunur; devam ederken ses yolu yeniden denetlenir, güvensizse donanım beklemesine girilir), "Sesi dene" (yalnız Bluetooth
  çıkışta çalar, KURAL 1), düşük şarj uyarısı (`LowBatteryWatcher`: %20/10/5, şarjda ya da %25 üstünde sıfırlanır; yalnız kırmızı kutu,
  sesli değil), Tanı ve günlük ekranı (`AppLog`, `DeviceInfo`), modelleri listeleme / model seçme (`GeminiClient.listModels`), Gemma
  için `thinkingLevel: high` (`GeminiAnswerService.body(_:forModel:)`), telefon sesi seçimi (`SpeechVoiceChooser`), ekranı kısma
  (`ScreenDimmer`; ayar varsayılan kapalı, kırmızı uyarıda/uygulama pasifken parlaklık geri verilir, çökme olursa açılışta geri verilir).
- **Bilerek alınmayanlar:** ayarlardaki sesli "dene" düğmeleri (telefon hoparlöründen ses çıkardı, KURAL 1'e aykırı), sesli komut
  sözlüğü, harcama sınırı ile profil değiştirme, durum raporu/sağlık izleyicisi (bu sürümde karşılığı yok).
- **Telefon yeniden başlatma / uygulamayı yeniden açma** yoktur (istenmedi).
- **Zamanlı başlatma:** iOS tam saatinde uyanmaya izin vermez; Kestirmeler otomasyonu `seslikontrol://basla` açar. Yedek: uygulama
  açıkken zamanlayıcı, sessiz bildirim.

## Sınırlar (denenmedi)

Cihazda denenmedi: Lightning mikrofon + Bluetooth çıkışın aynı anda çalışması, çevrimdışı Türkçe dikte, Gemini ses modelinin
ücretsiz kotası ve gecikmesi, Kestirmelerin uygulamaya dönmesi, kilitli ekranda davranış, kayıt klasörü seçicisi, ekran kilidi
penceresi ve ekran kısma, Duraklat/Devam et ve Sesi dene'nin gerçek kulaklıkla davranışı, `AQ.` ile başlayan anahtarların kabulü. Arama ve mesaj engelleme uygulamadan
yapılamaz (Odak + Kestirme önerilir).
