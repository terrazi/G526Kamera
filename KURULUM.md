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

**Önemli — Drive klasörü paylaşımı (iPhone + Windows birlikte kullanılacaksa):** `drive.file` izni "istemci kimliği"
başınadır. İki program da **aynı İstemci Kimliği ve Sırrını** kullanırsa aynı "G526 Belgeler" klasörünü görür ve Gemini
iPhone'dan da Windows'tan da yüklenen PDF'leri okur. Farklı kimlik girerseniz her biri kendi klasörünü açar ve birbirinin
dosyasını göremez. Klasörü Drive'da **elle açmayın**, dosyaları da **elle atmayın**: uygulamanın oluşturmadığı klasör ve
dosyalar görünmez. Emin olmak için iki programda da **Bağlantıyı sına** deyin: klasör adı, kimlik parmak izi (iki yerde
aynı olmalı), aynı adlı klasör sayısı ve bulunan PDF sayısı yazılır.

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

1. **aistudio.google.com** adresinden API anahtarı alın (Get API key). Faturalandırma bağlı (ücretli) bir
   projenin anahtarı önerilir: ücretsiz anahtarda Google gönderdiğiniz içeriği ürünlerini geliştirmek için
   kullanabilir ve günlük istek sınırı düşüktür. Anahtarı sohbete/koda yazmayın, yalnız uygulamanın ayarlarına yapıştırın.
2. **Dişli > Gemini modelleri**: her model profili için (1. Flash, 2. Pro, 3. ücretsiz gibi) ad, model adı ve kendi
   API anahtarını yazın. Ücretli/ücretsiz olmak modelin değil anahtarın özelliğidir: faturalandırma bağlı projenin
   anahtarı ücretli, bağlı olmayan ücretsizdir; **Ücretsiz anahtar** kutusunu buna göre işaretleyin. **Kullanılan model**
   listesinden hangisiyle çalışılacağını seçin. Doğru model adını bilmiyorsanız **Modelleri listele** düğmesi anahtarın
   görebildiği modelleri yazar. Birinci profilde model boşsa `gemini-3.8-flash` kullanılır.
3. **Dişli > Gemini ile belge sohbeti**: "Ses kaydımın ve PDF'lerimin Google'a gönderilmesini onaylıyorum" kutusunu
   işaretleyin, **Gemini'ye sesle soru sor**'u açın.
4. **Dişli > Google Drive > dosya türü: PDF** olmalı (Gemini yalnız Drive'daki PDF'leri okur).
5. Çağrı sözcüğünü değiştirmek için **Çağrı sözcüğü** kutusuna istediğinizi yazın (ör. `hey dostum`; virgülle birden
   çok: `dostum, gemini`). En az 3 harf olsun, gündelik konuşmada sık geçmesin, fotoğraf çekme/gönder sözcüklerinden
   farklı olsun. Kutu boşsa "gemini" kullanılır.
6. Kullanım: **çağrı sözcüğünü** deyin. Program Drive klasöründeki PDF'leri okuyup "3 belge hazır, sorunuzu bekliyorum"
   der (atlanan belge varsa onu da söyler). Sorunuzu söyleyin (susunca gönderilir), ör. "Beşinci soruyu cevapla": cevap
   "Beşinci sorunun cevabı, C, CEYHAN şıkkıdır. Sonraki sorunuzu bekliyorum." diye okunur ve mikrofon kendiliğinden yeniden
   açılır. Her soruda klasör yeniden taranır, yeni PDF'ler de değerlendirilir. Ana ekrandaki **Gemini'ye sor** düğmesi de
   aynı işi yapar. Sohbet son 6 soruyu hatırlar; **Yeni sohbet** sıfırlar.
7. **Oturum süresi:** "Oturum sessizlik süresi" kutusu 0 ise (varsayılan) oturum siz kapatana kadar açık kalır ve her an
   soru bekler. Bir süre (saniye) yazarsanız o kadar sessiz kalınca oturum kapanır. Oturumu "oturumu kapat" diyerek,
   Durdur düğmesiyle kapatırsınız. Oturum açıkken mikrofon sürekli açıktır: duyulan her konuşma
   Gemini'ye gider ve ücretlendirilir; "okey" gibi diğer sesli komutlar bu sürede çalışmaz.
8. **Model değiştirme:** "model değiştir" deyin (oturum açıkken de olur). Program "Model seçimi yapınız. 1. model: Flash,
   ücretli. 2. model: Pro, ücretli. 3. model: Ücretsiz, ücretsiz. Hangisini istiyorsunuz?" der; "ikinci model", "2 model" ya
   da profil adını ("pro") söyleyin. 35 saniye içinde seçmezseniz "Model değişmedi" der.
9. **Harcama sınırı:** AI Studio'da Spend sayfasından aylık sınır koyun (ör. 20 dolar). Ücretli profilde sınır dolunca
   program "Aylık harcama sınırı doldu. <ad> modeline geçtim" der, aynı soruyu "ücretsiz" işaretli profille yineler ve
   yeni ayda eski profile döner. Google harcamayı yaklaşık 10 dakika gecikmeyle saydığı için sınır biraz aşılabilir.
   Dikkat: ücretsiz anahtarda Google içeriğinizi ürünlerini geliştirmek için kullanabilir; gizli belgeleriniz varsa
   **Harcama sınırı dolunca ücretsiz modele geç** kutusunu kapatın.
10. Ses kaydınız Google'a her soruda gider. PDF'ler küçük setlerde (8 sayfadan az) her soruda doğrudan (en çok ~14 MB) gider; büyük
    setlerde **Gemini hafızası** devreye girer (madde 15).
11. **Belge sayısı:** "Gönderilecek son belge sayısı" 1-500 arasıdır; Gemini'ye en çok **500 sayfa** verilir (en yeni belgelerden başlanır,
    sığmayan eski belgeler atlanır ve bu sesle söylenir). Tek tek göndermede her sayfa ayrı PDF'tir; taradığınız
    sayfa sayısı kadar yapın, yoksa Gemini yalnız en yeni birkaç sayfayı görür. Toplu göndermede bir PDF birçok sayfa içerir.
12. **Bekleyen fotoğraflar:** Gemini'ye her sorudan önce, Drive'a henüz gitmemiş (toplu modda biriken) fotoğraflar kendiliğinden
    gönderilir ve yüklenmeleri en çok 90 sn beklenir. Yine de yüklenemeyenler olursa (internet yok) program bunu sesle söyler:
    "N fotoğraf henüz Drive'a yüklenmedi, Gemini onları göremez."
13. **Geçici hatalar:** oturum sırasında internet kopması ya da Gemini'nin geçici hatası oturumu kapatmaz; hata söylenir ve
    "Sorunuzu yeniden söyleyebilirsiniz" denir. Üst üste 3. hatada, ya da anahtar/model/kota/harcama sınırı hatasında oturum kapanır.
14. **Şık cevapları:** şık harfi yerine **kod sözcüğü** okunur ve ardından şıkkın metni/değeri gelir: "Birinci sorunun cevabı
    DENİZLİ, altmış sekiz." Kodlar Dişli > Gemini > **Şık kodları** kutusundadır (varsayılan A=ADANA, B=BURSA, C=CEYHAN,
    D=DENİZLİ, E=EDİRNE); kutuyu boşaltırsanız harfin kendisi okunur.
    Aynı numaralı soru birden çok belgede varsa program tahmin etmez, "hangisi?" diye sorar.
15. **Gemini hafızası** (Dişli > Gemini > "Büyük belge setlerini Gemini'nin hafızasına al", varsayılan açık): 8 sayfadan büyük setlerde
    PDF'ler Gemini'ye **bir kez** yüklenir (48 saat saklanır; uygulama kapanıp açılsa da yeniden yüklenmez) ve oturumda belgeler Gemini'nin
    önbelleğinde durur: her soruda 500 sayfa yeniden gönderilmez. Önbellek oturum boyunca saat başı küçük bir saklama ücreti işler,
    oturum bitince silinir (uygulama aniden kapanırsa 30 dakika sonra kendiliğinden silinir). İlk büyük yüklemede (500 sayfa) hazırlık
    birkaç dakika sürebilir; durum ekranda yazılır. Bir sorun olursa belgeler eski yöntemle doğrudan gönderilir.
16. **Toplu cevap (10'arlı gruplar):** "ilk on soruyu cevapla" deyince Gemini belgelerdeki numaralı soruları 1-10 arası okur; "sıradaki on
    soruyu cevapla" (ya da "sonraki on soru", "devam") dediğinizde 11-20'ye geçer. Kaldığı yer telefonda **kalıcı** saklanır ve yalnızca cevap
    size **sonuna kadar okununca** ilerler: cevabı kestiyseniz, internet koptuysa ya da cevap gelmediyse aynı grup yeniden verilir. Oturum
    kapansa, "Yeni sohbet" dense ya da uygulama yeniden açılsa da kaldığı yerden devam eder. Baştan başlamak için "ilk on soruyu cevapla"
    deyin (ayarlardaki **Sıfırla** düğmesi de sırayı sıfırlar).
17. **Belirli sorular:** "üçüncü, sekizinci ve on beşinci soruların cevabını ver" deyin. Bu ayrımı Gemini yapar: cevabını bu sohbette zaten
    verdiği soruları sohbet geçmişinden aynen yeniden okur (son 12 soru-cevap turu hatırlanır), vermediklerini belgelerden hazırlar. Bu
    istek toplu sırayı değiştirmez ve normal bir Gemini sorusu olarak ücretlendirilir.
18. **Son yanıtı tekrarla:** "son yanıtı tekrarla", "bir daha söyle", "yeniden oku" derseniz son cevap Gemini'ye gitmeden uygulamanın kendi
    hafızasından (telefona yazılır) yeniden okunur: ücret yazılmaz. 5 saniyeden kısa sesli sorular önce belgesiz, birkaç yüz jetonluk küçük
    bir istekle yazıya dökülüp bu isteğe bakılır (çok az ücret; internet gerekir). Yarım kalmış bir toplu cevabı tekrarlatıp sonuna kadar
    dinlerseniz kaldığı yer de o cevaba göre ilerler.

### Akıllı OCR (Gemini ile)

Cihazın kendi OCR'ı bozuk ya da silik yazıda zayıf kalır. **Dişli > Metni oku (OCR)** açıkken **OCR'ı Gemini ile yap**
kutusu açıksa her sayfanın fotoğrafını Gemini okur ve metni PDF'in sonuna ekler (soru numaraları, şık harfleri, tablolar
korunur). Şartlar: Gemini API anahtarı girilmiş ve "Google'a gönderilmesini onaylıyorum" kutusu işaretli olmalı; aksi
hâlde cihazın kendi OCR'ı çalışır. Dikkat: sayfa fotoğrafları Google'a gider ve sayfa başına küçük bir ücret çıkar
(tahminen yarım cent mertebesinde). Art arda 3 hata olursa OCR o oturumda kendini kapatır; fotoğraf çekme
ve Drive'a gönderme etkilenmez. Not: Gemini sohbeti PDF'in sayfa görüntülerini zaten kendisi okur; OCR metni PDF'in
sonundaki metin sayfalarını ve Drive'daki aranabilir metni iyileştirir.

## Sorun giderme

- **Kamera bulunamadı:** telefon kameranın ağında mı? Ayarlar > G526 Kamera > **Yerel Ağ** açık mı?
  UID doğru mu?
- **Okey duyulmuyor:** Ayarlar > Gizlilik > Mikrofon / Konuşma Tanıma izinleri; ana ekranda
  "Duyulan:" satırında ne anladığı görünür. Tetikleme sözcüğünü değiştirebilirsiniz.
- **Gemini "Drive klasöründe PDF bulunamadı" diyor:** iki programda da aynı İstemci Kimliği/Sırrı girili mi? Klasörü elle
  açmadınız, dosyaları elle atmadınız değil mi? **Bağlantıyı sına** hangi klasörü, kaç aynı adlı klasörü ve kaç PDF'i
  gördüğünü yazar; "AYNI kimlik" uyarısı çıkıyorsa kimlikleri eşitleyin.
- **Drive'a yüklenmiyor:** Ayarlar > Google Drive'da durumu görün; İstemci türü "TV ve Sınırlı
  Giriş Cihazları" olmalı; yayınlama durumu *Üretimde* olmalı.
- **Gemini cevap vermiyor:** cevap kutusundaki turuncu mesaj nedeni söyler (anahtar geçersiz, kota doldu, Drive'da
  PDF yok…). "Gemini" deyince tepki yoksa düğmeyi deneyin; ana ekranda "Duyulan:" satırı "Cemini" gibi yazıyorsa
  komut yine yakalanır.
- Hâlâ olmuyorsa **Ayarlar > Tanı ve günlük > Günlüğü kopyala** ile kopyalayıp bana gönderin.
