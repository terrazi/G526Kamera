# Sesli Kontrol (Sürüm 3) — Kurulum (iPhone 12 mini, Mac gerekmez)

Kamera yok. Sistem yalnız ses ile çalışır: **giriş** Lightning'e takılı kablosuz yaka mikrofonu, **çıkış** yalnız Bluetooth kulaklık.
Soruyu yüksek sesle okursunuz, bitince "Cevapla" ya da "Gönder" dersiniz; uygulama soruyu Gemini'ye sorar, cevabı kulaklıktan okur
ve cihazda kaydeder. Test bitince "Cevapları Tekrarla" kayıtları internetsiz, aralarında bekleyerek çalar.
Ayrıntılı işleyiş: `docs/SURUM3.md`.

> Hiçbir özellik telefonda denenmedi; yalnız GitHub Actions'ta derlendi ve birim testlerden geçti.

## 1) Derleme (GitHub Actions)

1. Depoda `surum-3` dalına gönderilen her değişiklik kendiliğinden derlenir.
2. **Releases** sayfasında `surum-3` sürümünün altından `G526CameraDrive-unsigned.ipa` dosyasını indirin.
3. Derleme hata verirse aynı çalışmadaki `G526CameraDrive-Build-Log` dosyasına bakın.

## 2) iPhone'a yükleme (Sideloadly, Windows)

1. Sideloadly'de `.ipa` dosyasını sürükleyin, Apple ID'nizi yazın, **Start**.
2. iPhone: **Ayarlar > Genel > VPN ve Cihaz Yönetimi** → geliştirici profiline **Güven**.
3. iOS 16 ve üstünde: **Ayarlar > Gizlilik ve Güvenlik > Geliştirici Modu** açık olmalı.
4. Ücretsiz Apple ID ile uygulama **7 gün** sonra süresi dolar; aynı ayarlarla yeniden yükleyin.
5. İlk açılışta **Mikrofon** ve **Konuşma Tanıma** izinlerini verin.

## 3) Telefonda bir kerelik hazırlık

1. **Çevrimdışı Türkçe dikte:** Ayarlar > Genel > Klavye > Dikte etkin, Klavyeler'e Türkçe eklenmiş olsun; internetteyken bir kez
   dikte kullanın ki Türkçe model inip telefona yüklensin. Yüklü değilse uygulama başlamaz ve nedenini söyler.
2. **Bluetooth kulaklık** bağlı, **yaka mikrofonunun alıcısı** Lightning'e takılı olsun.
3. Alıcı sesi kapabilir (çıkış alıcıya gider). Ana ekrandaki **ses çıkışı düğmesinden Bluetooth kulaklığı seçin**; yoksa uygulama
   susar ve sebebi kırmızı kutuda yazar. Ses telefon hoparlöründen asla çıkmaz.
4. Ana ekranın altındaki **Mikrofon** listesinden yaka mikrofonunu (Lightning alıcısı) seçin. Liste yalnız harici mikrofonları
   gösterir; alıcı görünmüyorsa **Yenile**'ye basın. Seçiminiz hatırlanır.
5. **Kayıt klasörü:** Dosyalar uygulamasında **Bu iPhone** altında "Sesli Kontrol Cevaplar" adlı yeni bir klasör açın. Sonra
   Ayarlar > **Kayıt klasörü** > **Klasör seç** ile onu seçip **Deneme dosyası yaz**'a basın; Dosyalar'da `deneme.txt`'yi görmelisiniz.
   Cevap sesleri bu klasöre yazılır ve uygulama silinse de kalır. Seçmezseniz cevaplar uygulamanın kendi klasörüne gider (uygulama
   silinirse onlar da gider) ve ana ekranda kırmızı uyarı çıkar.

## 4) Ayarlar (ana ekranda sağ üst)

- **Başlama saati:** açıp saati seçin. Asıl yol aşağıdaki otomasyondur (5. bölüm).
- **Gemini modelleri ve API anahtarları (4 yedekli profil):** her profilin kendi adı, modeli ve anahtarı vardır. Anahtarı
  **Yapıştır** ile girin (açık görünür, doğru yapıştığını gözle kontrol edin), **Anahtarı dene** ile sınayın. Soru önce 1. profile
  gider; kota dolarsa, sunucu hata verirse, 40 sn cevap gelmezse ya da anahtar/model sorunluysa kendiliğinden 2., 3., 4. profile geçilir
  (cevabın hangi profilden geldiği kırmızı kutuda yazılır). Anahtarı boş profil atlanır. "Ücretsiz anahtar / Ücretli anahtar"
  kutusunu anahtarınıza göre işaretleyin. Ayarlardaki **Açıklama** bağlantıları ayrıntıyı açar.
- **Kayıt klasörü:** 3. bölümdeki 5. adım.
- **Soruyu ses olarak da gönder:** açıkken soru, dikte metnine ek olarak ses kaydı olarak da Gemini'ye gider (İngilizce kelimeleri
  sesten daha iyi çözer). Ses Google'a gider.
- **İngilizce dikteyi de çalıştır:** (açık gelir) Türkçe tanıyıcı İngilizce cümleleri anlamsız Türkçe sözcüklerle yazar. Açıkken telefon
  aynı sesi bir de İngilizce tanıyıcıdan geçirir; ana ekranda soru okunurken "İngilizce:" satırı görünür ve Gemini'ye ses kaydıyla
  birlikte **iki metin** gider (Türkçe ve İngilizce). "Cevapla" yine yalnız Türkçe metinde aranır. İki tanıyıcı birlikte çalıştığı için
  telefon biraz daha ısınır, pil biraz daha çok gider; yalnız Türkçe soru okuyacaksanız kapatın. Telefonda çevrimdışı İngilizce
  dikte yüklü olmalı (yoksa ana ekranda kırmızı uyarı çıkar, test yine başlar ve İngilizce sorular yalnız ses kaydından çözülür).
- **Cevabı Gemini sesiyle oku:** açıkken cevap Gemini'nin ses modeliyle üretilip kaydedilir; olmazsa telefonun sesi kullanılır.
- **Modelleri listele / Model seç:** her profilde anahtar girilince anahtarın görebildiği modelleri listeler, listeden seçilen model o
  profile yazılır (model adını elle yazmak gerekmez). Gemma modellerinde "düşünme" otomatik açılır (soru çözümünde doğruluk için).
- **Telefon sesi:** "Otomatik" en kaliteli kurulu Türkçe sesi seçer; isterseniz listeden başka ses seçin. Ana ekrandaki **Sesi dene**
  seçtiğiniz sesi kulaklıktan dinletir.
- **Uyarıları sesli söyle:** (açık gelir) ekrana yazılan her uyarı kulaklıktan da kısaca söylenir: internet koptu, mikrofon yok, onarım başarısız, şarj azaldı, yedek modelden cevap geldi… Yalnız Bluetooth kulaklıktan çalar (kulaklık yoksa hiçbir şey çalınmaz; ses telefondan çıkmaz). Soru okunurken ya da cevap beklenirken araya girmez: duraklama ve onarım anlarında hemen, aksi hâlde cevap duyulduktan sonra söylenir. Aynı cümle 5 dakika içinde tekrar etmez.
- **Test sürerken ekranı kıs:** (kapalı gelir) test sürerken parlaklığı en aza indirir, pil daha yavaş biter. Ekran açık kalır
  (Kestirmeler için gerekir). Kırmızı uyarı çıkınca ya da uygulamadan çıkınca/test bitince parlaklık geri verilir.
- **Anında tespit (nabız):** (açık gelir) Dinlerken mikrofonun ses verip vermediğine yarım saniyede bir, internete 5 saniyede bir (ağ yolu değişince hemen) bakılır. Mikrofon bir saniyeden uzun ses vermezse dinleme hemen yeniden kurulur ve yarım metin korunur; art arda 3 kez işe yaramazsa Kestirmeler çalışır. iOS'un ses servisi çökerse ve ses motoru kendiliğinden durursa bildirim gelir gelmez aynı onarım başlar. İnternet için art arda iki nabız yoksa onarım başlar; bağlantı yokken her 2 saniyede bir bakıldığından internet dönünce 60 saniyelik yeniden deneme beklenmeden devam edilir. Kulaklık yoldan çıkınca çıkış kestirmesi 1 saniye sonra çalışır. Kısa kesintiden sonra uzun anons yerine yalnız "Hazır. Son soruyu tekrar oku." denir. Ana ekranda "Canlı: Kulaklık ✓ · Mikrofon ✓ · İnternet ✓" satırı görünür; Tanı ve günlük'te "[tespit]" satırları neyin ne zaman yakalandığını gösterir. Sorun çıkarsa Ayarlar'dan kapatılabilir.
- **Tanı ve günlük:** ayarların en altında; cihaz özeti (şarj, ısı, boş yer) ve olay günlüğü. Bir sorun olursa **Günlüğü kopyala** ile
  yapıştırıp bana gönderin; nedeni Mac olmadan okunur.
- **Kestirmeler:** dört kestirmenin adı (aşağıda) ve isteğe bağlı beşincisi **Çıkışı kulaklığa al**. Boş bırakılan adım atlanır.
- **Cevaplar arası boşluk:** 0-10 saniye (varsayılan 3), test sonundaki tekrar için.

## 5) iOS Kestirmeler (sınavdan önce, bir kez)

Uygulama ilk açıldığında Ayarlar'daki alanlara şu adları kendiliğinden yazar: **Wifi**, **Hücresel Veri**, **Bluetooth**, **Sistemi Sıfırla** ve **Çıkışı kulaklığa al** alanına **Kulaklık Düzeltme**. Kestirmeler uygulamasındaki kestirmelerin adı bunlarla birebir aynı olmalıdır. Başka ad kullanmak için alanı silip yenisini yazın (ya da boş bırakın); bir daha geri yazılmaz.

Kestirmeler uygulamasında dört kestirme yapıp adlarını Ayarlar'a yazın (örnek adlar):

1. `WiFi_Ac` — Wi-Fi'yi aç (gerekirse kapat, 2 sn bekle, aç).
2. `Hücresel_Ac` — hücresel veriyi aç.
3. `Bluetooth_Yenile` — Bluetooth'u kapat, 2 sn bekle, aç (kulaklık ya da mikrofon yolunu hafifçe yeniler).
4. `Sistemi_Sifirla` — uçak modunu aç (**Uçak Modunu Ayarla: Aç**), 3 sn bekle, kapat (**Uçak Modunu Ayarla: Kapat**); ağ ve Bluetooth yeniden kurulur.

İnternet kopunca uygulama sırayla 1, 2, 4'ü çalıştırır; kulaklık ya da mikrofon koptuysa önce 3'ü, işe yaramazsa 4'ü çalıştırır. Her
adımdan sonra durumu sınar (internet için internete ve Gemini'ye ulaşmayı, donanım için ses yolunu), düzelince "Bağlantı sorunu
giderildi…" der ve mikrofonu yeniden açar; **son soruyu baştan okursunuz**. Mikrofon sessiz kaldığı için onarım gerekirse yalnız
`Sistemi_Sifirla` çalışır (ses yolu sağlam görünürken Bluetooth yenilemesi sorunu çözmüş gibi görünürdü). Kestirmeler uygulaması öne gelip geri döner; bunun için **ekran açık ve kilitsiz** olmalıdır (oturum
boyunca ekran kararmaz).

**Zamanlı başlatma:** Kestirmeler > Otomasyon > Günün Saati > sınav saati > eylem **URL'yi Aç**: `seslikontrol://basla` > **Hemen
Çalıştır**. iOS uygulamanın kendi kendine uyanmasına izin vermez; bu yüzden otomasyon uygulamayı açıp başlatır. Telefon o saatte
açık ve kilitsiz olmalı. Yedek: uygulama açıksa saat gelince kendisi başlar; ayrıca sessiz bir bildirim çıkar, dokunun.

İsteğe bağlı: sınav süresince **Odak** (Rahatsız Etme) açan otomasyon. Uygulama aramaları/mesajları engelleyemez.

## 6) Sınav günü

1. Başlayınca uygulama donanımı denetler: izinler, çevrimdışı dikte, kulaklık, mikrofon, internet, Gemini. Sorun yoksa kulaklıktan
   "Ben hazırım, sistem kontrol edildi ve problem yok, şimdi ilk soruyu okumanı bekliyorum." der.
2. Soruyu, şıklarıyla birlikte okuyun, sonunda **"Cevapla"** (ya da "Gönder") deyin. Her soru ayrı gönderilir; cevap
   "Soru 1, Denizli, Örgütsel Davranış" biçiminde kulaklıktan okunur (Adana=A, Bursa=B, Ceyhan=C, Denizli=D, Erzurum=E).
   Ana ekranda **Yüklenen sorular** tek listede görünür; her sorunun yanında bir işaret vardır: **saat** = okunuyor, "Cevapla"
   demenizi bekliyor; **mektup** = Gemini'ye gitti, cevap bekleniyor; **gülen yüz** = cevaplandı (cevap ve model altında yazar);
   **kırmızı çarpı** = gitmedi (nedeni kırmızıyla yazar, soruyu yeniden okuyun).
   **Soru numarası:** soruları karışık okuyabilirsiniz. Her sorunun başında numarayı söyleyin ("soru yedi", "7. soru", "yedinci soru",
   "soru numarası on iki"); cevap ve kayıt **söylediğiniz numarayla** yapılır (`soru_7`), sıraya bakılmaz. Aynı numarayı yeniden
   okursanız eski cevabın yerine yenisi yazılır. Numara hiç söylenmezse sıradaki numara verilir ve soru listesinde turuncu bir not çıkar.
3. Cevaplar, seçtiğiniz **kayıt klasöründe gün klasörü** altında `soru_1`, `soru_2`… olarak kalır (`cevaplar.txt` de yazılır).
4. Bitince **Testi Bitir** (yanlışlıkla basılmasın diye bir onay sorar), sonra **Cevapları Tekrarla**: sistem internetsiz çalışır,
   kayıtlar sırayla çalınır, aralarında ayardaki süre kadar bekler.

**Sınavda işe yarayan düğmeler (ana ekran)**

- **Sesi dene** (test başlamadan): ses yolunu denetler, kulaklıktan kısa bir cümle çalar, mikrofonun görünüp görünmediğini yazar.
  Kulaklık bağlı değilse hiçbir şey çalmaz (ses telefon hoparlöründen çıkmaz).
- **Duraklat / Devam et:** görevliyle konuşmanız gerekirse mikrofon kapanır, konuşulanlar yazıya çevrilmez, hiçbir şey gönderilmez.
  Gemini'ye gitmekte olan soru gitmedi sayılır (soruyu yeniden okursunuz); okunurken kesilen cevap kayıtlıdır ve devam edince yeniden okunur.
- **Ekranı kilitle:** ekrana yanlışlıkla dokunmak (ör. **Testi Bitir**) bir şey yaptırmasın diye dokunmatik ekranı kilitler. Program
  çalışmaya devam eder. Kilidi açmak için ekrandaki düğmeye **3 saniye basılı tutun**; test bitince kilit kendiliğinden kalkar.
  Sınır: yan tuş, ses tuşları ve ekran kenarından kaydırma iOS'un işidir, uygulama engelleyemez; tam kilit için iPhone'un
  **Kılavuzlu Erişim** özelliğini açın.
- **Şarj uyarısı:** telefon şarjı %20, %10 ve %5'e düşünce (şarjda değilse) kırmızı kutuda bir kez yazar; sesli söylemez, soru
  okunurken araya girmesin diye. Şarja takınca kalkar.

## Sorun giderme

- **"Duraklatıldı: kulaklık, mikrofon ya da ses kesintisi":** kulaklık ve alıcı bağlı mı, çıkış düğmesinde kulaklık, mikrofon listesinde alıcı seçili mi? Geri gelince kendiliğinden devam eder; 20 sn dönmezse `Bluetooth_Yenile`, o da işe yaramazsa `Sistemi_Sifirla` çalışır.
- **"Ses şu an telefona gidiyor" / Sesi dene çalmıyor:** ana ekranın altındaki "Şu an: Çıkış: …" satırı sesin nereye gittiğini yazar. Çıkış telefon ise "Ses çıkışı" düğmesinden Bluetooth kulaklığı seçin. Kulaklık yalnız müzik (A2DP) olarak bağlanır; telefon (mikrofonlu) profili kapalıdır, çünkü mikrofon her zaman Lightning alıcıdan gelir.
- **"Giriş: yok" ama mikrofon alıcısı takılı:** kulaklık seçildikten sonra iOS ses yolunu yeniden kurar; uygulama kontrolü bir buçuk saniye kadar bekleyip mikrofonu yeniden seçerek tekrarlar. Ana ekrandaki "Şu an" satırı alıcının adını ve "takılı ama ses yoluna girmedi" bilgisini yazar. Hâlâ girmiyorsa alttaki mikrofon listesinden alıcıya bir kez dokunun.
- **Kulaklık düştü, yeniden bağlanmıyor:** Ayarlar > Bluetooth'ta kulaklığa dokunmak elle yapılır ve sınavda mümkün değildir; uygulama da Ayarlar'a girip dokunamaz (iOS izin vermez). Bu yüzden tek otomatik yol Kestirmeler'dir: aşağıdaki **Çıkışı kulaklığa al** kestirmesini kurun. Kulaklık yoldan çıkınca uygulama bunu ~3 sn sonra kendisi çalıştırır; düzelmezse 20 sn dolunca bir kez daha, o da olmazsa `Bluetooth_Yenile` ve `Sistemi_Sifirla`. Ana ekranda kulaklık yolda değilken hangi adımın bekleyeceği yazar.
- **Ses iPhone'a düşüyor / "Bluetooth music" kendiliğinden seçilmiyor:** Kestirmeler'de tek eylemli bir kestirme yapın (ör. adı `Kulakliga_Al`): **Oynatma Hedefini Ayarla** eylemini ekleyin ve hedef olarak Bluetooth kulaklığınızı seçin. Adını Ayarlar > Kestirmeler > **Çıkışı kulaklığa al** alanına yazıp **Dene** ile sınayın. Uygulama bunu, açılışta kulaklık yolda değilse ve test sürerken kulaklık yoldan çıkınca ~3 sn sonra ve 20 sn dolunca **Bluetooth'u kapatıp açmadan önce** çalıştırır; art arda 6 denemede yol düzelmezse eski sıraya geçer, yol düzelince hak yenilenir. Kestirme herhangi bir eylem dizisi olabilir: uygulama onu çalıştırır, sonra ses yolunun düzelip düzelmediğine bakar. Güçlendirme önerileri (hiçbiri cihazda denenmedi):
  - Eylemi iki kez koyun: **Oynatma Hedefini Ayarla** → **Bekle 3 sn** → **Oynatma Hedefini Ayarla** (aynı hedef). İlki bağlanmayı başlatır, ikincisi bağlanınca çıkışı seçer.
  - Uygulamadan bağımsız yedek: Kestirmeler > Otomasyon > Kişisel > **Bluetooth** > kulaklık > **Bağlantı Kesildi** > **Hemen Çalıştır** > aynı kestirme.
  - Ayarlar'daki "Bluetooth Music" satırına dokunmayı yaptırmak için **Anahtarla Denetim** kullanılabilir (Ayarlar > Erişilebilirlik > Anahtarla Denetim > Tarifler: tam ekran özel hareketle o satıra dokunuşu kaydedip **Başlatma Tarifi** yapın; kestirme sırası: **URL'yi Aç** `App-Prefs:Bluetooth` > **Anahtarla Denetim'i Ayarla: Aç** > bekle > **Anahtarla Denetim'i Ayarla: Kapat**). Zayıf yanları: dokunuş ekran koordinatına bağlıdır (aygıt listesi değişirse yanlış yere dokunur), Başlatma Tarifi'nin açılır açılmaz kendiliğinden çalışıp çalışmadığı bildirilen kullanıcı deneyimlerine göre değişiyor (bir tıklama isteyebilir) ve `App-Prefs` bağlantısı iOS sürümüne göre açılmayabilir. Önce elle deneyip çalıştığını görün, sonra kestirmeye alın.
- **"Kestirme ikide bir çalışıyor":** kulaklık sağlamken yalnız mikrofon girişi yola girmemişse (alıcı takılı) Kestirme **çalıştırılmaz**; Bluetooth/uçak modunu kapatıp açmak kulaklığı da koparırdı. Bunun yerine mikrofon yeniden seçilir, kırmızı kutuda nedeni yazar ve yol oturunca kendiliğinden devam edilir. Kestirme yalnız kulaklık yolda değilse ya da alıcı hiç görünmüyorsa çalışır.
- **Mikrofon listesi boş:** alıcıyı çıkarıp takın, **Yenile**'ye basın.
- **Kırmızı kutuda "çevrimdışı dikte yüklü değil":** 3. bölümdeki 1. adım.
- **Kestirme açılıyor ama uygulamaya dönmüyor:** Ayarlar'daki **Dene** düğmesiyle her kestirmeyi tek tek sınayın; adın birebir aynı olması gerekir.
- **Gemini cevap vermiyor:** kırmızı kutu nedeni söyler (anahtar geçersiz, kota doldu…). Model zinciri kendiliğinden sıradaki modele geçer.
- **Kaydedilen dosyalar `.m4a`/`.wav`:** iOS MP3 yazamaz; cevaplar bu biçimlerde saklanır.
