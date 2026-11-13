# G526 Ses (Sürüm 3) — Kurulum (iPhone 12 mini, Mac gerekmez)

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

## 4) Ayarlar (ana ekranda sağ üst)

- **Başlama saati:** açıp saati seçin. Asıl yol aşağıdaki otomasyondur (5. bölüm).
- **Gemini API anahtarı:** yapıştırın, **Anahtarı dene** ile sınayın. Eski sürümün anahtarı taşınmaz, yeniden girin.
- **Soruyu ses olarak da gönder:** açıkken soru, dikte metnine ek olarak ses kaydı olarak da Gemini'ye gider (İngilizce kelimeleri
  sesten daha iyi çözer). Ses Google'a gider.
- **Cevabı Gemini sesiyle oku:** açıkken cevap Gemini'nin ses modeliyle üretilip kaydedilir; olmazsa telefonun sesi kullanılır.
- **Kestirmeler:** üç kestirmenin adı (aşağıda). Boş bırakılan adım atlanır.
- **Cevaplar arası boşluk:** 0-10 saniye (varsayılan 3), test sonundaki tekrar için.

## 5) iOS Kestirmeler (sınavdan önce, bir kez)

Kestirmeler uygulamasında üç kestirme yapıp adlarını Ayarlar'a yazın (örnek adlar):

1. `WiFi_Ac` — Wi-Fi'yi aç (gerekirse kapat, 2 sn bekle, aç).
2. `Hücresel_Ac` — hücresel veriyi aç.
3. `Sistemi_Sifirla` — uçak modunu aç, 3 sn bekle, kapat (ağ ve Bluetooth yeniden kurulur).

Bağlantı kopunca uygulama sırayla bunları çalıştırır, her birinden sonra internet ve Gemini'ye ulaşıp ulaşamadığını sınar, düzelince
"Bağlantı sorunu giderildi…" der ve mikrofonu yeniden açar; **son soruyu baştan okursunuz**. Mikrofon/kulaklık koptuysa yalnız
`Sistemi_Sifirla` çalışır. Kestirmeler uygulaması öne gelip geri döner; bunun için **ekran açık ve kilitsiz** olmalıdır (oturum
boyunca ekran kararmaz).

**Zamanlı başlatma:** Kestirmeler > Otomasyon > Günün Saati > sınav saati > eylem **URL'yi Aç**: `g526kamera://basla` > **Hemen
Çalıştır**. iOS uygulamanın kendi kendine uyanmasına izin vermez; bu yüzden otomasyon uygulamayı açıp başlatır. Telefon o saatte
açık ve kilitsiz olmalı. Yedek: uygulama açıksa saat gelince kendisi başlar; ayrıca sessiz bir bildirim çıkar, dokunun.

İsteğe bağlı: sınav süresince **Odak** (Rahatsız Etme) açan otomasyon. Uygulama aramaları/mesajları engelleyemez.

## 6) Sınav günü

1. Başlayınca uygulama donanımı denetler: izinler, çevrimdışı dikte, kulaklık, mikrofon, internet, Gemini. Sorun yoksa kulaklıktan
   "Ben hazırım, sistem kontrol edildi ve problem yok, şimdi ilk soruyu okumanı bekliyorum." der.
2. Soruyu, şıklarıyla birlikte okuyun, sonunda **"Cevapla"** (ya da "Gönder") deyin. Her soru ayrı gönderilir; cevap
   "Soru 1, Denizli, Örgütsel Davranış" biçiminde kulaklıktan okunur (Adana=A, Bursa=B, Ceyhan=C, Denizli=D, Erzurum=E).
3. Cevaplar Dosyalar uygulamasında **Bu iPhone > G526 Ses > gün klasörü** altında `soru_1`, `soru_2`… olarak kalır (`cevaplar.txt` de yazılır).
4. Bitince **Testi Bitir**, sonra **Cevapları Tekrarla**: sistem internetsiz çalışır, kayıtlar sırayla çalınır, aralarında ayardaki süre kadar bekler.

## Sorun giderme

- **"Duraklatıldı: kulaklık ya da mikrofon bağlantısı yok":** kulaklık ve alıcı bağlı mı, çıkış düğmesinde kulaklık seçili mi? Geri gelince kendiliğinden devam eder; 20 sn dönmezse `Sistemi_Sifirla` çalışır.
- **Kırmızı kutuda "çevrimdışı dikte yüklü değil":** 3. bölümdeki 1. adım.
- **Kestirme açılıyor ama uygulamaya dönmüyor:** Ayarlar'daki **Dene** düğmesiyle her kestirmeyi tek tek sınayın; adın birebir aynı olması gerekir.
- **Gemini cevap vermiyor:** kırmızı kutu nedeni söyler (anahtar geçersiz, kota doldu…). Model zinciri kendiliğinden sıradaki modele geçer.
- **Kaydedilen dosyalar `.m4a`/`.wav`:** iOS MP3 yazamaz; cevaplar bu biçimlerde saklanır.
