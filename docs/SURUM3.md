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
- **Bluetooth yenileme adımı:** donanım sorununda önce hafif `Bluetooth` kestirmesi, olmazsa `Sistemi Sıfırla`. Donanım doğrulaması
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
  yalnız mikrofon donmuşsa (ya da yeniden açılamıyorsa) `Sistemi Sıfırla` çalışır.
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
- **Çıkışı kulaklığa al kestirmesi (isteğe bağlı, `outputShortcut`)**: "Oynatma Hedefini Ayarla → Bluetooth kulaklık" kestirmesi. Açılışta `settledRoute` sonrası kulaklık yolda değilse; test sürerken kulaklık yoldan çıkınca `outputQuickDelay` (3 sn) sonra (`scheduleQuickOutputFix`, 20 sn'lik beklemeyi beklemez); ve süre dolunca `hardwareGraceExpired` içinde Bluetooth yenileme/sıfırlamadan **önce** çalışır (`switchOutputToHeadphones`). Hızlı deneme sürerken süre dolumu onu bekler, iki kestirme iç içe çalışmaz. Hak: yol düzelmeden art arda `maxOutputTries`=6; yol dönünce (`hardwareReturned`) sıfırlanır. Ana ekrandaki elle "Bluetooth ayarlarını aç" düğmesi kaldırıldı (iOS'ta açılmadı, üstelik sınavda elle yapılamaz). Yol düzelirse Bluetooth'a dokunulmaz. iOS bir uygulamanın Bluetooth ayarlarında bağlantı kesip kurmasına izin vermez; bu yüzden yol yalnız Kestirmeler üzerinden.
- **Uyarılar sesli de verilir** (`SessionViewModel+Voice`): `warn()` ile ekrana yazılan her uyarı ("start", "cevap", "ses" hariç; onlar zaten başka yerde söyleniyor ya da söylenemez) `announce` ile kuyruğa girer. Sessiz anlarda (duraklatma, onarım, test bitti, boşta) hemen, diğer zamanlarda sıradaki anons ya da cevap duyulduktan sonra söylenir; kulaklık yoksa KURAL 1 gereği hiçbir şey çalınmaz ve kuyruk atılır. Aynı cümle 5 dk içinde tekrarlanmaz, 3 dk'dan eski haber söylenmez, arama/Siri kesintisinde susar. Ayar: "Uyarıları sesli söyle" (açık).
- **Soru numarası okunana göre verilir** (`SpokenNumber`): numara dikte metninin başından ("soru 7", "7. soru", "yedinci soru", "soru yirmi beş")
  uygulamanın kendisi tarafından çözülür; öncelik okunan numara > Gemini'nin metinden/sesten duyduğu > sıradaki. Cevap cümlesi,
  dosya adı (`soru_N`), liste ve `cevaplar.txt` hep kaydedilen numarayı taşır; Gemini yanlış numara yazsa da düzeltilir. "Bir soru" gibi
  belirsiz söyleyişler numara sayılmaz, metnin ortasındaki sayılara bakılmaz (yalnız ilk beş sözcükteki "soru" bakılır).
- **Giriş yolda listelenmiyorsa** (iOS çıkışı Bluetooth'a alınca girişi hemen göstermez) `AudioSessionGuard.snapshot()` tercih edilen harici
  mikrofonu giriş sayar; motor başlayınca gerçek yol okunur, başka giriş (telefonun mikrofonu) görünürse güvenli sayılmaz. Açılış kontrolü,
  Sesi dene, devam et ve onarım yol oturana kadar en çok ~1,6 sn bekler (`settledRoute`). Kulaklık sağlam + alıcı takılı + giriş boşsa
  süre dolunca Kestirme **çalışmaz** (`hardwareGraceExpired`): mikrofon yeniden seçilir, kırmızı kutuda nedeni yazar.
- **İlk açılışta yol oturmuyorsa** ("Testi bitir + yeniden başlat" düzeltiyordu) `settledRoute` üçüncü bakışta ses oturumunu yeniden etkinleştirir (`configure()`); elle yeniden başlatmak gerekmez.
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

## Anında tespit (nabız) — `SessionViewModel+Sentinel.swift`

iOS bildirimleri kopmayı geç ya da hiç bildirmeyebilir (ses servisi çökünce önceden bildirim yok; Wi-Fi "bağlı" ama ölü; motor sessizce durur).
Bu yüzden kopma ölçülerek yakalanır. Ayar: `AppSettings.instantDetection` (varsayılan açık; testlerde `SessionHarness` kapatır).

- **Döngü:** `sentinelTick` (0,5 sn), `start()` ile kurulur, oturum bitince kendiliğinden durur.
- **Mikrofon:** dinlerken `secondsSinceAudio` (son ses tamponu) `micStallLimit` (1,2 sn) aşılırsa ya da dinleyici durduysa `healMic`: eldeki metin `commitCurrent` ile korunur,
  ses oturumu yeniden etkinleştirilir, yol güvenliyse dinleme yeniden başlar. Art arda `maxMicHeals`=3 onarım işe yaramazsa `runRecovery(.hardware, force: true)`.
  Dinleme başlayınca `micWarmupTicks` kadar nabız beklenir. `SpeechEvent.engineStopped` (AVAudioEngineConfigurationChange) aynı onarımı bildirim gelir gelmez başlatır.
- **Ses servisi:** `mediaServicesWereLost/Reset` → `onMediaServicesReset` → `mediaServicesReset`: duraklat, `mediaHealDelay` (0,3 sn) sonra `configure()`; servis dönmediyse
  1 sn arayla 5 kez denenir; yol güvenliyse `routeStable` sonra devam.
- **İnternet:** `netBeat` (`InternetProbe.quick`, 3 sn sınır, iki adres paralel). Her `netBeatEvery`=10 nabızda (5 sn) ve `NWPathMonitor` her yol değişiminde (`onPathChange`). Art arda
  `netFailLimit`=2 yoklama başarısızsa (ikincisi ~1 sn sonra) `runRecovery(.network)`. `.paused(.noConnection)` iken her 2 sn'de yoklanır; başarılıysa `reconnectIfHealthy`.
  `InternetProbe.check` üç adresi artık paralel dener (en kötü durumda 20 sn yerine 10 sn).
- **Donanım dönüşü:** `.paused(.hardware)` iken yol güvenli hâle geldiyse (bildirim gelmese de) `routeStable` sonra devam (`watchReturns`).
- **Gecikmeler kısaltıldı:** `outputQuickDelay` 3→1 sn, `routeStable` 1,5→1 sn, `offlineDebounce` 3→1 sn (onarım önce bağlantıyı sınar, sağlamsa Kestirme çalıştırmaz).
- **Kısa kesinti:** `briefOutage` (8 sn) altındaysa `Say.recoveredShort`.
- **Ekran/günlük:** `liveStatus` ("Canlı: Kulaklık ✓ · Mikrofon ✓ · İnternet ✓"), günlükte `[tespit]` satırları.
- **Bilinen sınır:** çıkış (kulaklık) için kopma yalnız iOS yol bildirimiyle ve `watchReturns` ile görülür; Bluetooth bağlantısı sessizce ölüp iOS yolu değiştirmezse ölçülemez.

## Konuşma tanıma düşerse (anında tespit sonrası saha hatası)

Sahada "Hazır. Son soruyu tekrar oku." anonsu durmadan tekrarlandı, "Konuşma tanıma üst üste hata verdi" ve "Kulaklık ya da mikrofon sorunu var" çıktı,
oysa kulaklık ve mikrofon sağlamdı. Zincir: tanıma görevi hemen düşüyor → uygulama bunu donanım sanıp Bluetooth/uçak modu Kestirmelerini çalıştırıyor → "hazır"
diyor → tanıma yine düşüyor. Susturmak bunu gizlerdi; çözüm tanımayı gerçekten onarmak ve ne olduğunu söylemektir.

**Apple'ın hata kodları** (SFSpeechRecognitionTask hata tablosu): `kLSRErrorDomain` 201 Siri/Dikte kapalı, 102 çevrimdışı model yüklü değil (kalıcı: yeniden denemek
işe yaramaz, kullanıcıya ne yapacağı söylenir ve oturum kapanır); 300 tanıyıcı başlatılamadı, 301 iptal; `kAFAssistantErrorDomain` 1100 önceki görev sürerken yenisi
başlatıldı, 1101/1107 konuşma sürecine bağlantı kesildi, 1110 konuşma tanınmadı, 203 genel hata (geçici: yeniden kurulur). Her hatanın kodu günlüğe yazılır
(`[mikrofon] tanıma görevi hata verdi (hemen, üst üste N): alan kod: açıklama`).

**Dinleyici kendi içinde, bir saniyeden kısa sürede kademeli onarır** (üst üste çabuk biten görev sayısına göre; bir görev 3 sn yaşar ya da metin gelirse sayaç sıfırlanır):
1. hata: yardımcı İngilizce tanıyıcı bırakılır (Türkçe öncelikli; iki çevrimdışı tanıyıcının çakışması bilinen bir olasılık) ve görev yenilenir;
2. hata: tanıyıcı nesneleri yeniden yaratılır; 3-4. hata: ses motoru ve dinleme kancası baştan kurulur (giriş biçimi değişmiş olabilir);
5. hata: basamaklar tükendi, dinleme durur ve `recognizerDown` olayı gelir.

**Uygulama tarafı** (`repairRecognizer`): ses yolu sağlamsa Kestirme çalışmaz (kulaklığı koparırdı). Kulaklıktan "Konuşma tanıma durdu, yeniden kuruluyor. Kulaklık ve
mikrofon sağlam." denir (sessizlik kesinti sanılmasın), ses oturumu baştan kurulur ve dinleme **kanıtlanır**: mikrofon tamponları geliyor ve tanıyıcı yaklaşık 2,5 sn
görevleri hemen düşürmüyorsa "Hazır. Son soruyu tekrar oku." söylenir; kanıtlanamazsa "hazır" denmez. 3 turda kanıtlanamazsa gerçek durum söylenir ("Konuşma tanıma açılamıyor.
On beş saniyede bir yeniden deniyorum…"), ekranda kırmızı kutu kalır ve her 15 sn'de sessizce yeniden denenir; düzelince "Hazır" denir. Ses yolu bozuksa eski donanım onarımı çalışır.

**Sınır beklemesi** (art arda 3 donanım onarımı işe yaramayınca): bekleme 5 dk değil 60 sn'dir ve ne olduğu söylenir; bu sürede nabız ya da yol bildirimi beklemeyi bozmaz
(`holdForRetry`), süre dolunca bir kez daha denenir, ses yolu gerçekten değişirse bekleme biter.

**İnternet nabzı boşuna alarm verebilir:** mikrofon açıkken `runRecovery(.network)` önce internet + Gemini'yi sessizce sınar; sağlamsa hiçbir şey durdurulmaz, anons yapılmaz,
yarım okunan soru silinmez (`[onarım] internet alarmı yanlıştı`). Susturma yoktur: ilk yanlış alarmdan sonra nabız, bu oturumda hızlı yoklama yerine daha uzun sınırlı tam internet
yoklamasıyla (`internetReachable`, 10 sn) bakar; gerçek kopma yine yakalanır (yaklaşık 25 sn). Hızlı yoklama üç adrese aynı anda 5 sn sınırla gider; başarısızlık nedeni günlüğe
yazılır (`[tespit] yoklama başarısız: …`).

Bunların hiçbiri cihazda denenmedi; ilk hatanın kök nedeni günlük olmadan bilinemez. Tekrarlarsa Ayarlar > Tanı ve günlük kaydındaki `[mikrofon]` satırları nedeni gösterir.
