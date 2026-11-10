# G526 Kamera — Kurulum (iPhone 12 mini, Mac gerekmez)

Bu uygulama G526 (LookCam / MYKJ) Wi-Fi kameranızdan canlı görüntü alır, "Okey" deyince
(veya görüntü değişince) en net kareyi seçer, iyileştirir ve Google Drive'a yükler.

> **Önemli:** Kamera UID'si kodun içinde değildir. Uygulamada **Ayarlar > Kamera UID** alanına
> bir kez yazarsınız, yalnızca telefonda saklanır. Bu depoyu herkese açık (public) yapmayın.

## 1) Derleme (GitHub Actions)

1. Bu klasörün içeriğini (zip'i açın) GitHub'daki **özel (private)** deponuza yükleyin.
2. Depoda **Actions** sekmesi → son çalışma → **Artifacts** bölümünden
   `G526CameraDrive-iPhone-IPA` dosyasını indirin, zip'ten `G526CameraDrive-unsigned.ipa` çıkar.
3. Derleme hata verirse aynı çalışmadaki `G526CameraDrive-Build-Log` dosyasını bana gönderin.

## 2) iPhone'a yükleme (Sideloadly, Windows)

1. Sideloadly'de `.ipa` dosyasını sürükleyin, Apple ID'nizi yazın, **Start**.
2. iPhone: **Ayarlar > Genel > VPN ve Cihaz Yönetimi** → geliştirici profiline **Güven**.
3. iOS 16 ve üstünde: **Ayarlar > Gizlilik ve Güvenlik > Geliştirici Modu** açık olmalı.
4. Ücretsiz Apple ID ile uygulama **7 gün** sonra süresi dolar; Sideloadly ile aynı ayarlarla
   yeniden yükleyin (ayarlarınız ve bekleyen fotoğraflar korunur).

## 3) Google Drive hazırlığı (bir kez, bilgisayarda)

Menü adları zamanla değişebilir; mantık aynıdır.

1. <https://console.cloud.google.com> → yeni proje (örn. "G526").
2. **API'ler ve Hizmetler > Kitaplık** → **Google Drive API** → **Etkinleştir**.
3. **Google Auth Platform** (eski adıyla *OAuth izin ekranı*):
   - Uygulama adı: G526 Kamera, destek e-postası: kendi adresiniz.
   - Hedef kitle: **Harici**.
   - Veri erişimi (kapsamlar): `.../auth/drive.file` ve `email`.
   - **Yayınlama durumu: "Üretimde / In production"** yapın. *Test* modunda bırakırsanız
     Google giriş jetonunu 7 günde geçersiz kılar ve uygulama Drive'a yüklemeyi bırakır.
     (`drive.file` hassas olmayan bir kapsamdır, doğrulama istenmez.)
4. **Kimlik Bilgileri / İstemciler > Oluştur > OAuth istemci kimliği** →
   Uygulama türü: **"TV'ler ve Sınırlı Giriş Cihazları" (TVs and Limited Input devices)**.
   Oluşunca **İstemci Kimliği** ve **İstemci Sırrı** görünür.
5. İkisini telefona taşıyın (kendinize e-posta / not). Depoya veya herkese açık yere koymayın.

Uygulama yalnızca kendi oluşturduğu klasöre ve dosyalara erişir (`drive.file`); Drive'ınızın
geri kalanını göremez. Google parolanızı uygulamaya hiç yazmazsınız.

## 4) Uygulamada ayar

1. Telefonu **kameranın Wi-Fi ağına** bağlayın.
2. Uygulamayı açın. İzinleri verin: **Yerel Ağ**, **Mikrofon**, **Konuşma Tanıma**.
3. Sağ üst **dişli > Kamera**: UID'yi yazın (örn. `G123456ABCDE`). Parola varsayılan `123456`.
   IP'yi boş bırakın (kendiliğinden bulunur). Birkaç saniyede "Canlı" görünür.
4. **Dişli > Google Drive > Google hesabı ve bağlantı**: İstemci Kimliği ve Sırrını yapıştırın →
   **Google ile giriş yap** → ekranda kod çıkar → **Kodu kopyala ve Google sayfasını aç** →
   açılan sayfada kodu yapıştırıp hesabınızı seçin, izin verin. Sonra **Bağlantıyı sına**.
5. Kameranın Wi-Fi'sinde internet yoktur; iPhone Drive için **hücresel veriyi** kullanır.
   **Ayarlar > Hücresel > G526 Kamera** açık olsun. Kamera Wi-Fi'sinde "internet yok"
   uyarısı normaldir.

## 5) Kullanım

- Uygulama **açık ve ekran uyanık** olmalı (arka planda iOS ağı ve mikrofonu keser).
  Uygulama bu sırada ekranın kararmasını kendisi engeller.
- Belgeyi kameranın altına koyun, **"Okey"** deyin → fotoğraf Drive'daki "G526 Belgeler"
  klasörüne `Belge_2026-11-08_20-48-11.jpg` adıyla yüklenir. Telefonda kopya,
  **Dosyalar > G526 Kamera > Belgeler** içinde de durur (Ayarlar'dan kapatılabilir).
- **Görüntü değişince çek:** yeni belge konup görüntü durulunca bir kez çeker; belgeyi alıp
  masa boşalınca çekmez.
- İnternet yoksa fotoğraflar kuyrukta bekler, internet gelince sırayla yüklenir.

### Okunaklı belge için

- Kameradan canlı akışta en yüksek çözünürlük **1920×1080**'dir (kamerada SD kart yok;
  "4K" etiketi canlı akışta kullanılamıyor). Tam A4 sayfa yaklaşık 130 dpi olur; küçük
  yazılar için sayfanın yazılı bölgesine yaklaşın.
- İyileştirme **Hafif**, JPEG kalitesi **%92+**, **Birkaç net kareyi birleştir** açık.
- Kamera üstündeki saat yazısı sağ üst köşeye basılır; belgeyi oraya taşırmayın veya
  **Üstteki saat yazısını kes** seçeneğini açın.
- Işık bol ve titreşimsiz olsun; gölge düşürmeyin.

## 6) Gemini ile belgelerle sesli sohbet

Drive'a gönderdiğiniz son PDF'ler hakkında sesle soru sorarsınız; cevap iPhone'un en kaliteli Türkçe sesiyle okunur.

1. **aistudio.google.com** adresinden bir API anahtarı alın (Get API key). Faturalandırma bağlı (ücretli) bir
   projenin anahtarı önerilir: ücretsiz anahtarda Google gönderdiğiniz içeriği ürünlerini geliştirmek için
   kullanabilir ve günlük istek sınırı düşüktür. Anahtarı sohbete/koda yazmayın.
2. **Dişli > Gemini ile belge sohbeti**: anahtarı yapıştırın, "Ses kaydımın ve PDF'lerimin Google'a gönderilmesini
   onaylıyorum" kutusunu işaretleyin, **Gemini'ye sesle soru sor**'u açın. Model boşsa `gemini-3.8-flash` kullanılır.
3. **Dişli > Google Drive > dosya türü: PDF** olmalı (Gemini yalnız Drive'daki PDF'leri okur).
4. Çağrı sözcüğünü değiştirmek için **Çağrı sözcüğü** kutusuna istediğinizi yazın (ör. `dostum`; virgülle birden çok:
   `dostum, gemini`). En az 3 harf olsun, gündelik konuşmada sık geçmesin, fotoğraf çekme/gönder sözcüklerinden farklı
   olsun. Kutu boşsa "gemini" kullanılır.
5. Kullanım: **çağrı sözcüğünü** ("Gemini" ya da seçtiğiniz) deyin, kısa "tık" sesinden sonra sorunuzu söyleyin
   (susunca gönderilir), ya da ana ekrandaki **Gemini'ye sor** düğmesine basın. Örnek: "Son faturanın tutarı ne kadar?", "Bu sözleşmede ödeme vadesi kaç gün?"
   Sohbet son 6 soruyu hatırlar; **Yeni sohbet** sıfırlar.
6. Soru sürerken sürekli dinleyen "Okey" komutu kısa süre durur, cevap bitince yeniden başlar.
7. Her soruda ses kaydınız ve seçilen PDF'ler (en çok ~14 MB) hücresel veriyle Google'a gider.

## Sorun giderme

- **Kamera bulunamadı:** telefon kameranın ağında mı? Ayarlar > G526 Kamera > **Yerel Ağ** açık mı?
  UID doğru mu?
- **Okey duyulmuyor:** Ayarlar > Gizlilik > Mikrofon / Konuşma Tanıma izinleri; ana ekranda
  "Duyulan:" satırında ne anladığı görünür. Tetikleme sözcüğünü değiştirebilirsiniz.
- **Drive'a yüklenmiyor:** Ayarlar > Google Drive'da durumu görün; İstemci türü "TV ve Sınırlı
  Giriş Cihazları" olmalı; yayınlama durumu *Üretimde* olmalı.
- **Gemini cevap vermiyor:** cevap kutusundaki turuncu mesaj nedeni söyler (anahtar geçersiz, kota doldu, Drive'da
  PDF yok…). "Gemini" deyince tepki yoksa düğmeyi deneyin; ana ekranda "Duyulan:" satırı "Cemini" gibi yazıyorsa
  komut yine yakalanır.
- Hâlâ olmuyorsa **Ayarlar > Tanı ve günlük > Günlüğü kopyala** ile kopyalayıp bana gönderin.
