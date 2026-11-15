# Sesli Kontrol (Sürüm 4) — Kurulum (iPhone 12 mini, Mac gerekmez)

Sistem sesle çalışır: **giriş** Lightning'e takılı kablosuz yaka mikrofonu, **çıkış** yalnız Bluetooth kulaklık.
Soruyu yüksek sesle okursunuz, bitince "Cevapla" ya da "Gönder" dersiniz; uygulama soruyu Gemini'ye sorar, cevabı kulaklıktan okur
ve cihazda kaydeder. Test bitince "Cevapları Tekrarla" kayıtları internetsiz, aralarında bekleyerek çalar.
Sürüm 4'te kamera da vardır (isteğe bağlı): her soruda "Bu soruyu kamera ile çekip göndermek ister misiniz?" diye sorulur; **evet** denirse
program kameraya geçer, video ve fotoğraf çeker, internete döner, soruyu Gemini'ye gönderir ve cevabı okur; **hayır** denirse Sürüm 3'teki gibi
soruyu sesle okursunuz. Kamera kullanılmayacaksa Ayarlar'dan kamera sorusu kapatılır.
Ayrıntılı işleyiş: `docs/PROSEDUR.md` (adım adım), `docs/SENARYOLAR.md` (olay olay), `docs/SURUM3.md` (V3 tabanı).

> Hiçbir özellik telefonda denenmedi; yalnız GitHub Actions'ta derlendi ve birim testlerden geçti.

## 1) Derleme (GitHub Actions)

1. Depoda `surum-4` dalına gönderilen her değişiklik kendiliğinden derlenir.
2. **Releases** sayfasında `surum-4` sürümünün altından `G526CameraDrive-unsigned.ipa` dosyasını indirin.
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
- **Kamera kutusu (ana ekran):** V1'deki gibi ana ekranda hep durur; kamera kapalıyken siyahtır. Üstünde kamera durumu (nokta ve yazı) ve pili, altında konumlandırma bildirimi görünür. **Canlı önizleme** anahtarı kapatılırsa kutu yerine tek satır kalır (pil tasarrufu); **Test sürerken ekranı kıs** anahtarı da burada. **Şimdi çek** yalnız kamera çekimi sürerken çalışır. Çekimden sonra **Son fotoğraf** küçük resmi gösterilir. Ayarlar > Kamera > Pil ve ısınma'dan **Canlı önizlemeyi kapat** ve **Son fotoğrafı ana ekranda gösterme** ile ikisi de kapatılabilir (kapalıyken küçük resim bellekte de tutulmaz; çekim ve gönderim aynen sürer).
- **Çekim klasörü (Ayarlar > Çekim klasörü):** Kamerayla çekilen her soru (fotoğraf + video) önce telefona yazılır: Dosyalar uygulamasında
  **Bu iPhone'da > Sesli Kontrol > Cekimler** (alt klasörler: Bekleyen, Gonderilen, Gonderilemeyen, Paragraf). İnternet gelene kadar
  orada bekler, gelince en eskisinden başlayarak sırayla Gemini'ye gider; cevabı gelince Gonderilen'e taşınır (cevap.txt ile). Uygulama
  kapansa ya da test bitse de kaybolmaz: bir sonraki testte klasörden geri yüklenip sırayla gönderilir (kamera sorusu kapalı olsa da;
  cevapları o testin numaralarıyla kaydedilir). **Hiçbir çekim kendiliğinden silinmez**; ayarlardaki "Gönderilenleri sil" ve "Tümünü
  sil (bekleyenler dahil)" düğmeleri onay sorar ve test sürerken çalışmaz. Ayarlar bölümü kaç çekim olduğunu ve kapladığı yeri gösterir.
  Telefonda yer azalırsa çekim klasöre yazılamayabilir; o çekim bellekte tutulur ama test biterse gönderilemez (ekranda yazılır).
- **Telefon sesi:** "Otomatik" en kaliteli kurulu Türkçe sesi seçer; isterseniz listeden başka ses seçin. Ana ekrandaki **Sesi dene**
  seçtiğiniz sesi kulaklıktan dinletir.
- **Uyarıları sesli söyle:** (açık gelir) ekrana yazılan her uyarı kulaklıktan da kısaca söylenir: internet koptu, mikrofon yok, onarım başarısız, şarj azaldı, yedek modelden cevap geldi… (hangi modelin cevapladığı söylenmez; yalnız cevap diğer modeller yanıt vermeyince ÜCRETLİ modelden gelirse “Ücretli modelden cevaplandı” denir. Sunucunun uzun, çoğu İngilizce hata metni ve açıklamalar yalnız ekranda yazar, hiç okunmaz). Yalnız Bluetooth kulaklıktan çalar (kulaklık yoksa hiçbir şey çalınmaz; ses telefondan çıkmaz). Soru okunurken ya da cevap beklenirken araya girmez: duraklama ve onarım anlarında hemen, aksi hâlde cevap duyulduktan sonra söylenir. Aynı cümle 5 dakika içinde tekrar etmez.
- **Test sürerken ekranı kıs:** (kapalı gelir) test sürerken parlaklığı en aza indirir, pil daha yavaş biter. Ekran açık kalır
  (Kestirmeler için gerekir). iOS parlaklık atamasını sessizce yok sayabildiği ve otomatik parlaklık değeri geri yükseltebildiği için
  üç şey birlikte yapılır: parlaklık düşürülür, ekranın üstüne dokunuşları geçiren koyu bir örtü konur (OLED'de siyah piksel yanmaz;
  parlaklık atanmasa bile ekran kararır) ve 5 saniyede bir parlaklık denetlenip gerekirse yeniden düşürülür. Kırmızı uyarı çıkınca ya da
  uygulamadan çıkınca/test bitince parlaklık ve örtü geri verilir. **Kırmızı uyarı sürdükçe ekran kısılmaz** (örn. düşük güç modu uyarısı
  kalıcıdır); ayarın altındaki yazı o an kısılıp kısılmadığını ve kısılmıyorsa nedenini (uyarı metniyle) söyler.
- **Anında tespit (nabız):** (açık gelir) Dinlerken mikrofonun ses verip vermediğine yarım saniyede bir, internete 5 saniyede bir (ağ yolu değişince hemen) bakılır. Mikrofon bir saniyeden uzun ses vermezse dinleme hemen yeniden kurulur ve yarım metin korunur; art arda 3 kez işe yaramazsa ses oturumu ve dinleme baştan kurulur (kulaklık sağlamsa Kestirme hiç çalışmaz; yalnız kulaklık yoldan çıkmışsa çalışır). iOS'un ses servisi çökerse ve ses motoru kendiliğinden durursa bildirim gelir gelmez aynı onarım başlar. İnternet için art arda iki nabız yoksa onarım başlar; bağlantı yokken her 2 saniyede bir bakıldığından internet dönünce 60 saniyelik yeniden deneme beklenmeden devam edilir. Kulaklık yoldan çıkınca çıkış kestirmesi 1 saniye sonra çalışır. Kısa kesintiden sonra uzun anons yerine yalnız "Hazır. Son soruyu tekrar oku." denir. Ana ekranda "Canlı: Kulaklık ✓ · Mikrofon ✓ · İnternet ✓" satırı görünür; Tanı ve günlük'te "[tespit]" satırları neyin ne zaman yakalandığını gösterir. Sorun çıkarsa Ayarlar'dan kapatılabilir.
- **Cevaptan sonra sonraki soruyu iste:** (açık gelir) Cevap kulaklıktan okunup bitince program kendisi "Lütfen sonraki soruyu okuyun" der, ondan sonra dinlemeye geçer; "Cevapla" deyip numara sorulmasına kadar ne yapacağınızı düşünmeniz gerekmez. Bu cümle kayda yazılmaz (soru_N dosyasında yalnız cevap vardır). Cevap alınamadıysa söylenmez (zaten "Soruyu yeniden okuyun" denir). Ayarlardan kapatılabilir.

## Sesli komutlar

Mikrofon açıkken, soruyu okumadan **tek başına** söylenen komutlar tanınır (cümle içinde geçen "testi bitirmek için…" komut sayılmaz, soru olarak gider):

| Söyleyin | Ne olur |
|---|---|
| "Testi bitir" / "Sınavı bitir" / "sınav bitti" / "sınavı sonlandır" | Program "Testi bitirmek istiyor musunuz?" diye sorar. **Evet** (ya da komutu yeniden söylemek) kaydedilen cevapları numara sırasıyla baştan sona okutur, sonra "N sorunun cevabı okundu" der ve sorar: **Devam** (teste devam), **Tekrar** (cevapları yeniden oku), **Bitir** (testi tamamla). Söz gelmezse bitirme isteğiyle gelindiği için test tamamlanır. Ayarlar > "Testi bitirince cevapları oku" kapatılırsa onaydan sonra test doğrudan tamamlanır. **Hayır / vazgeç** ya da hiç cevap vermemek testi sürdürür. Yanlış tanımada test kapanmaz. |
| "Cevapları tekrarla" / "Tüm cevapları oku" | Test sürerken (soru beklerken, bitirme onayında, eksik numara ve paragraf numaraları beklenirken) bütün cevaplar baştan okunur; sonra "N sorunun cevabı okundu" der ve **Devam / Tekrar / Bitir** diye sorar. Söz gelmezse teste devam edilir. |
| "Son cevabı tekrarla" / "Tekrarla" | Son cevap yeniden okunur, Gemini'ye gitmez. (Bitirme onayında, numara ve paragraf numarası beklerken, başlangıç sorusunda "Tekrarla" programın son sözünü tekrarlar.) |
| "Beşinci sorunun cevabını tekrarla" / "5. sorunun cevabını oku" | Yalnız o sorunun cevabı okunur; cevap yoksa "… için cevap yok" denir. |
| **"Yardım" / "Ne duydun" / "Son cümleyi sil" / "Durum" / "Cevapsız soruları söyle"** | Her kipte söylenebilen bilgi ve düzeltme komutları; her biri yaptığını ya da yapamadığını kısaca söyler. Yardım komutları sayar; Ne duydun o ana kadar anlaşılan soru metnini okur; Son cümleyi sil soru metninin son sözünü siler (ses kaydı silinmez); Durum cevap sayısı, sıradaki numara, kulaklık, internet ve pili söyler; Cevapsız soruları söyle atlanan numaraları sayar. Soru okurken tek sözcük yerine iki sözcük söyleyin ("yardım et", "durum nedir"). |
| "Soruyu iptal et" | Okunmakta olan soru (metin ve ses kaydı) silinir, Gemini'ye gitmez; baştan okursunuz. Numara beklenirken söylenirse bekleyen soru da bırakılır. Kamera sorusu açıkken silinecek bir şey yoktur. |
| "Paragrafı iptal et" | Okunmakta ya da hangi sorulara ait olduğu beklenen ortak paragraf bırakılır; hiçbiri yoksa kayıtlı ortak paragraf silinir. |
| **"Anlamadım" / "Duyamadım" / "Bir daha söyle" / "Yeniden söyle" / "Tekrar söyle" / "Ne dedin"** (ve benzerleri) | Programın söylediğini duymadıysanız ya da anlamadıysanız her aşamada (soru, onay, menü, numara, paragraf, başlangıç, kamera sorusu) söylenir: program **son sözünü** (en çok son iki anons; örneğin cevap + kamera sorusu) aynen yeniden söyler ve aynı yerde dinlemeye devam eder. Cevap sayılmaz, hiçbir şey değişmez. Program sizi anlamazsa o da "Anlayamadım…" der ve sorusunu yeniden sorar. |
| **Raporlar:** "İnternet raporu" / "İnternet var mı", "Mikrofon raporu", "Kulaklık raporu", "Ses raporu", "Kamera raporu" (görüntü ayarları ve son okunan kamera pili), "Şarj durumu" / "Pil kaç", "Isınma durumu" / "Telefon ısındı mı", "Bellek durumu" / "RAM kaç", "Genel rapor" | Her biri kısa bir cümleyle durumu söyler ve soruyu/kipi bozmaz, Gemini'ye gitmez. İnternet raporu gerçekten yoklar (ağ türü, internet, Gemini). Genel rapor internet, kulaklık, mikrofon, ses, şarj, ısınma ve belleği tek seferde sayar. Bilinmeyen bilgi söylenmez. Yalnız komut sözcüklerinden oluşan söz rapor sayılır: soru başlığı ("Bellek nedir") rapor değildir. |
| **Ses seviyesi:** "Sesi aç", "Sesi kıs", "Sesi yüzde 60 yap", "Sesi artır" | Telefonun ses düzeyini değiştirir; sonuç ses seviyesi yeniden okunarak doğrulanır ("Ses açıldı. Ses seviyesi yüzde N." / "Ses zaten en yüksek düzeyde."). iOS uygulamaya ses ayarı izni vermezse "değiştirilemedi, ses tuşlarını kullanın" der. Cevaplar duyulsun diye en az yüzde 15'e iner. **Cihazda doğrulanmadı.** |
| **Kamera ayarları:** "Kamera sorusunu kapat / aç" (ya da "Kamera sorusu olmasın"), "Görüntü kalitesini yüksek / düşük yap", "Videoyu gönder / gönderme", "Video süresi 8 saniye", "Kadrajı dikey / yatay yap", "Yönü sağa çevir / ters çevir", "Konumlandırma sesini kapat / aç", "İyileştirmeyi iki yap", "Önizlemeyi kapat / aç" | Ayarı değiştirir ve ne yaptığını söyler (zaten öyleyse "zaten" der). Kamera çalışırken "değiştirilemez" der; yatay kadrajda dik çevirme gibi uyumsuz istekleri nedeniyle reddeder. Kamera sorusu sorulurken "kamera sorusunu kapat" denirse soru sesle okunur. |
| "Cevapla" / "Gönder" | Okuduğunuz soruyu Gemini'ye gönderir (komutlarla birlikte söylenirse komut soru olarak gitmez). |
| "Ortak paragraf" (duraklayın) … "Tamam" | Program kulaklıktan "Lütfen ortak paragrafı okuyun, bitince Tamam deyin" der; paragrafı okuyup "Tamam" dersiniz. Sonra hangi sorulara ait olduğunu söyleyip yine "Tamam" dersiniz. |

**Evet / hayır sorularında güvenli kural:** "evet" yalnız açık söylenirse ("evet", "olur", "çekelim", "çekmek istiyorum", "bitirmek istiyorum"…) anlaşılır. Olumsuz söz ("çekmiyorum", "çekmem", "kamera olmasın", "bitirmeyelim", "bitirmek istemiyorum", "devam etmeyelim") hiçbir zaman evet sayılmaz, kamerayı açmaz, testi bitirmez; anlaşılmayan cevap yeniden sorulur. "Testi bitirme", "cevapları tekrarlama" gibi olumsuz sözler komut da değildir.

Ekrandaki "Okunuyor: sorunuz bitince Cevapla deyin" notu, okunan metin varken görünür; program bir şey beklemiyor, yalnız dinliyor demektir.

## Önceki kaydı hatırlama

Uygulama kapanıp açıldığında ya da "Testi bitir"den sonra yeniden başlatıldığında, önceki klasörde cevap varsa program **"Önceki kayıtta N cevap var, sıradaki soru M. Devam mı, yeni sınav mı?"** diye sorar:

- **"Devam"** (ya da "önceki kayıttan devam", "kaldığı yerden"): aynı klasör, numaralama kaldığı yerden sürer; önceki cevaplar yüklenir ("Son cevabı tekrarla" onlardan okur).
- **"Yeni"** (ya da "yeni sınav", "baştan"): yeni klasör açılır, numara 1'den başlar; eski cevapların üzerine yazılmaz.
- Cevap vermezseniz bir kez hatırlatılır; yine olmazsa önceki kayıt 12 saatten **yeniyse devam**, eskiyse yeni sınav sayılır.
- Beklenmedik kapanmadan sonra (çökme, iOS kapattı) soru sorulmaz: kaldığı yerden otomatik sürer. Önceki kayıtta hiç cevap yoksa da soru sorulmaz.
- **Soru numarası okunmadıysa sor:** (açık gelir) Soruyu okuyup "Cevapla" dediniz ama numara söylemediyseniz program "Lütfen okuduğunuz sorunun numarasını söyleyin" der. "Yedi" ya da "soru yedi" demeniz yeter; numara sorunun başına yazılıp Gemini'ye öyle gider. Bilmiyorsanız "sıradaki" deyin, sıradaki numara verilir. Hiç söylemezseniz iki kez hatırlatılır, sonra sıradaki numarayla gönderilir (soru kaybolmaz). Kapalıyken numara sorulmaz, sıradaki numara verilir.
- **Gemini beklerken bilgi ver:** (açık gelir) "Cevapla" deyince kulaklıktan "Soru başarıyla alınıp Gemini'ye gönderildi, cevap bekleniyor" denir; cevap uzarsa 30 saniyede bir "Cevap bekleniyor" denir. Gemini **3 dakikada** cevap vermezse bekleme bırakılır, "soruyu tekrar okuyun" denir ve dinlemeye dönülür. Kapalıyken bu anonslar ve 3 dakikalık sınır yoktur.
- **Kesintiden sonra akıllı devam:** (açık gelir) Soru Gemini'ye gittikten sonra bağlantı koptu ve onarıldıysa "Bağlantı yeniden onarıldı. Sorunuz yarım kaldıysa son soruyu tekrar okuyunuz" denir. Okurken kesilirse program soru numarasını ve en son okuduğunuz cümleyi söyler ("En son üçüncü soruda şu cümleyi okudunuz: … Buradan devam edebilirsiniz"); devam ettiğiniz metin öncekiyle birleştirilir. Uygulama tümüyle kapanıp yeniden açılırsa yarım metin ve ortak paragraf korunamaz (soru baştan okunur). Kapalıyken eski davranış: "Lütfen en son kaldığın soruyu tekrar oku" ve yarım metin silinir.
- **Tanı ve günlük:** ayarların en altında; cihaz özeti (şarj, ısı, boş yer) ve olay günlüğü. Bir sorun olursa **Günlüğü kopyala** ile
  yapıştırıp bana gönderin; nedeni Mac olmadan okunur. Kopya dosyadan alınır: uygulama kapanıp yeniden açıldıysa **kapanan çalışmanın son
  satırları da** gelir (kalan bellek, ısı, takılma gecikmeleri, son olaylar); neden orada aranır.
- **Kestirmeler:** dört kestirmenin adı (aşağıda) ve isteğe bağlı beşincisi **Çıkışı kulaklığa al**. Boş bırakılan adım atlanır.
- **Cevaplar arası boşluk:** 0-10 saniye (varsayılan 3), test sonundaki tekrar için.
  Kulaklık çalışırken program "Duraklatıldı" diyorsa: günlükteki `[ses yolu] … Güvenli değil` satırını ve ondan sonraki "ham çıkış / ham giriş;
  kulaklık tamam|SORUNLU, mikrofon tamam|SORUNLU; bağlı girişler" satırını gönderin; hangi tarafın (kulaklık mı, mikrofon mu) neden güvenli
  sayılmadığını kesin gösterir. Kestirmeden sonraki `[çıkış] kestirmeden sonra:` satırı da aynı ayrıntıyı verir.

## 5) iOS Kestirmeler (sınavdan önce, bir kez)

Uygulama ilk açıldığında Ayarlar'daki alanlara şu adları kendiliğinden yazar: **Wifi**, **Hücresel Veri**, **Bluetooth**, **Sistemi Sıfırla** ve **Çıkışı kulaklığa al** alanına **Kulaklık Düzeltme**. Kestirmeler uygulamasındaki kestirmelerin adı bunlarla birebir aynı olmalıdır. Başka ad kullanmak için alanı silip yenisini yazın (ya da boş bırakın); bir daha geri yazılmaz.

Kestirmeler uygulamasında beş kestirme yapın; adları yukarıdakilerle birebir aynı olsun (adım adım, hiç bilmeyen biri için anlatım: **Kestirmeler_Kurulum_Rehberi** PDF/Word dosyası):

1. `Wifi` — Wi-Fi'yi kapat, 2 sn bekle, aç. (Sürüm 4'te bu adım **Kamera Bağlantısını Onar** adını alır; aşağıdaki Sürüm 4 bölümüne bakın.)
2. `Hücresel Veri` — hücresel veriyi aç.
3. `Bluetooth` — Bluetooth'u kapat, 2 sn bekle, aç (kulaklık ya da mikrofon yolunu hafifçe yeniler).
4. `Sistemi Sıfırla` — uçak modunu aç (**Uçak Modunu Ayarla: Aç**), 3 sn bekle, kapat (**Uçak Modunu Ayarla: Kapat**); ağ ve Bluetooth yeniden kurulur.
5. `Kulaklık Düzeltme` — tek eylem: **Oynatma Hedefini Ayarla** (hedef: Bluetooth kulaklık; kulaklık bağlıyken seçilir).

İnternet kopunca uygulama sırayla 2, 4'ü çalıştırır (Sürüm 4; Sürüm 3'te önce 1); kulaklık yoldan çıkınca önce 5'i, kulaklık ya da mikrofon koptuysa 3'ü, işe yaramazsa 4'ü çalıştırır. Konuşma tanıma düşerse hiçbirini çalıştırmaz (aşağıdaki "Konuşma tanıma düşerse" bölümü). Her
adımdan sonra durumu sınar (internet için internete ve Gemini'ye ulaşmayı, donanım için ses yolunu), düzelince "Bağlantı sorunu
giderildi…" der ve mikrofonu yeniden açar; **son soruyu baştan okursunuz**. Mikrofon sessiz kaldığı için onarım gerekirse yalnız
`Sistemi Sıfırla` çalışır (ses yolu sağlam görünürken Bluetooth yenilemesi sorunu çözmüş gibi görünürdü). Kestirmeler uygulaması öne gelip geri döner; bunun için **ekran açık ve kilitsiz** olmalıdır (oturum
boyunca ekran kararmaz).

### Sürüm 4: kamera için üç kestirme

Kamera ile çekim için Kestirmeler'de üç kestirme daha yapın; adları Ayarlar'daki alanlarla birebir aynı olsun (ilk açılışta kendiliğinden yazılır):

1. `Kameraya Geç` — hücresel veriyi kapat, Wi-Fi'yi aç. Telefon kameranın ağına kendiliğinden bağlanır: kamerayı bir kez elle bağlayıp **Otomatik Bağlan**'ı açık bırakın (Kestirmeler belirli bir ağa bağlanma eylemi sunmaz).
2. `Hücresele Geç` — Wi-Fi'yi kapat, hücresel veriyi aç.
3. `Kamera Bağlantısını Onar` — Wi-Fi'yi kapat, 2 sn bekle, aç (telefon kameranın ağına yeniden bağlanır; kamera bağlanamayınca çalışır).

**Sınavdan önce bir kez Ayarlar > Kamera > “Kamerayı dene” düğmesine basın:** kamera ilk kez açılırken iOS “yerel ağ” izni sorar (“İzin ver”e basın); sınavda bu kutu çıkarsa kulaklıktan yönetilen akış kilitlenir. Deneme, sınavın adımlarını sırayla yürütür ve her adımın sonucunu yazar.

Bu sürümde Wi-Fi artık internet onarımı için kullanılmaz (internet yalnız hücreseldir): internet kopunca sırayla hücresel ve sistem sıfırlama çalışır. Kestirmelerin Wi-Fi ve hücreseli sorunsuz (onay sormadan) değiştirip değiştirmediği ve kameranın ağına kendiliğinden bağlanıp bağlanmadığı cihazda denenmedi: Ayarlar'daki **Dene** düğmesiyle üçünü de sınayın.


**Zamanlı başlatma:** Kestirmeler > Otomasyon > Günün Saati > sınav saati > eylem **URL'yi Aç**: `seslikontrol://basla` > **Hemen
Çalıştır**. iOS uygulamanın kendi kendine uyanmasına izin vermez; bu yüzden otomasyon uygulamayı açıp başlatır. Telefon o saatte
açık ve kilitsiz olmalı. Yedek: uygulama açıksa saat gelince kendisi başlar; ayrıca sessiz bir bildirim çıkar, dokunun.

İsteğe bağlı: sınav süresince **Odak** (Rahatsız Etme) açan otomasyon. Uygulama aramaları/mesajları engelleyemez.

**Kapanırsa kendiliğinden yeniden açılma (önerilir, bir kez kurulur):** iOS hiçbir uygulamaya kendini yeniden açma izni vermez; bunu
yalnız Kestirmeler yapabilir. Uygulama kapanınca (iOS belleği boşaltmak için kapatırsa, çökerse, yanlışlıkla kaydırıp kapatılırsa)
yeniden açılması için:
1. Kestirmeler > **Otomasyon** > **+** > **Uygulama** > **Seç** > "Sesli Kontrol" > yalnız **Kapatıldı** işaretli kalsın (Açıldı kapalı) > **İleri**.
2. **Yeni Boş Otomasyon** > eylem ekle: **Panoyu Al**.
3. Eylem ekle: **Eğer** > "Pano" **içerir** > `SESLIKONTROL-` (büyük harf, sonunda tire; devamı yok).
4. "Eğer"in içine: **Bu Kestirmeyi Durdur**. ("Aksi hâlde" bölümüne dokunmayın.)
5. "Aksi hâlde" bölümüne: **URL'yi Aç** > `seslikontrol://yeniden`.
6. **İleri** > **Çalıştırmadan Önce Sor: KAPALI** > **Bitti**.

Nasıl çalışır: uygulama açılınca önceki kapanışın nedenini kendi günlüğünden okur. Oturum sürerken kapandıysa **kendiliğinden yeniden
başlar** (telefona dokunmanız gerekmez), kulaklıktan ne olduğunu söyler ("Program beklenmedik biçimde kapanıp yeniden açıldı. Olası
neden: …"), Gemini'ye gitmiş ama cevabı duyulmamış son soruyu yeniden sorar ya da cevabı yeniden okur. Soruyu söylerken kapanmışsa
son soruyu baştan okumanızı ister. Cevap klasörü ve soru numarası kaldığı yerden sürer.

**Pano işareti (otomasyonun "açma" işareti):** Apple'a göre "Kapatıldı" tetikleyicisi uygulamadan başka uygulamaya geçildiğinde de çalışır,
yalnız kaydırıp kapatınca değil. **Kapanma yalnız "Programı kapat" düğmesiyle serbesttir**: uygulama panoya `SESLIKONTROL-` ile başlayan
bir işareti yalnız iki anda yazar: **"Programı kapat"** ile kapatırken (`SESLIKONTROL-KAPALI`) ve **Kestirmeler'i bilerek açarken**
(`SESLIKONTROL-ONARIM`; onarım ve "Dene" sırasında otomasyon uygulamayı geri çekip onarımı bozmasın). **Başka her durumda panoda işaret
yoktur**: oturum sürerken de, oturum yokken de, **"Testi Bitir"den sonra da** uygulama kapanırsa ya da ekrandan çıkılırsa otomasyon
uygulamayı geri açar. İşaret her açılışta silinir (düğmeyle kapattıktan sonra elle açınca kural yeniden geçerli olur). Yalnız kendi
yazdığı işaret silinir; arada başka bir şey kopyaladıysanız panonuza dokunulmaz (silmek için panoyu okumak da gerekmez, iOS'un
"yapıştırmaya izin ver" sorusu çıkmaz).

**Bilerek kapatmak:** ana ekranın altındaki kırmızı **Programı kapat** düğmesine dokunun; çıkan büyük yuvarlak düğmeye (kilit açma düğmesiyle aynı görünümde) **3 saniye basılı tutun**; halka dolunca program kapanır. Vazgeçmek için **Vazgeç**'e ya da örtünün dışına dokunun. Bu kapanış "bilerek" sayılır:
oturum biter, uygulama panoya `SESLIKONTROL-KAPALI` yazar, otomasyon bunu görüp uygulamayı yeniden açmaz. Bu düğme dışındaki her
kapanış otomasyonla geri açılır; oturum sürerken kapandıysa oturum kaldığı yerden sürer ("beklenmedik" sayılır), "Testi Bitir"den sonra ya da
oturum yokken kapandıysa uygulama yalnız açılır, yeni oturum **başlatmaz**. Bunun bedeli: otomasyon kuruluyken uygulamadan başka uygulamaya
geçemezsiniz (ana ekrana çıkmak da uygulamayı geri getirir). Başka bir uygulamayı (Kestirmeler'de otomasyon düzenlemek gibi) kullanmak
için önce "Programı kapat" ile kapatın; kapalıyken istediğiniz uygulamayı açabilirsiniz.

Sınırlar (dürüstçe): (0) 2026-11-14 evde denemede ilk bakışta oturum sürerken yukarı kaydırıp kapatınca uygulama açılmamış görünmüştü; sonradan
kullanıcı ikisinin de (yeniden açılma ve ekran kısma) çalıştığını bildirdi. Yine de iOS "Kapatıldı" tetikleyicisini zorla kapatmadan sonra
çalıştırmayı belgelemiyor (kamuya açık bildirimlere göre uygulamadan çıkınca/ekran kilitlenince/Denetim Merkezi açılınca da çalışır), bu yüzden
her iOS sürümünde aynı olacağı garanti edilmez. Açılışta günlüğe "[açılış] pano işareti: …" satırı yazılır: otomasyon bir gün açmazsa işaretin
engel olup olmadığı orada görünür. (1) Bu otomasyon telefonda denenmeden güvenilmemeli. Evde dört deneme: Başlat'tan sonra uygulamayı yukarı kaydırıp
kapatın (birkaç saniyede yeniden açılmalı); "Programı kapat" ile kapatın (açılmamalı); Başlat > Testi Bitir > uygulamayı yukarı kaydırıp
kapatın (yeniden açılmalı, yeni oturum başlatmamalı); Ayarlar'dan bir kestirmeyi "Dene" ile çalıştırın (kestirme çalışıp uygulamaya dönmeli). (2) Oturum sürerken başka uygulamaya
geçerseniz otomasyon Sesli Kontrol'ü öne geri getirir (sınav okuyucusu için çoğu zaman istenen budur). (3) Telefon kilitliyken iOS başka
uygulama açtırmayabilir; yeniden açılma kilit açılana kadar bekleyebilir. (4) Kısa sürede (2 dk içinde) üç kez beklenmedik kapanırsa açılış
döngüsüne girmemek için otomatik başlatma durur ve ekranda yazar. (5) Panonuz bir süre `SESLIKONTROL-…` içerebilir.

## 6) Sınav günü

1. Başlayınca uygulama donanımı denetler: izinler, çevrimdışı dikte, kulaklık, mikrofon, internet, Gemini. Sorun yoksa kulaklıktan
   "Ben hazırım, sistem kontrol edildi ve problem yok, şimdi ilk soruyu okumanı bekliyorum." der. (Sürüm 4'te kamera sorusu açıkken kamera adı ya da
   kestirme adları eksikse "Kamera ayarları eksik olduğu için sorular sesle okunacak" der; kamerayı hiç kullanmayacaksanız Ayarlar'dan kamera
   sorusunu kapatın.)
2. Soruyu, şıklarıyla birlikte okuyun, sonunda **"Cevapla"** (ya da "Gönder") deyin. Her soru ayrı gönderilir; cevap
   "Soru 1, Denizli, Örgütsel Davranış" biçiminde kulaklıktan okunur (Adana=A, Bursa=B, Ceyhan=C, Denizli=D, Erzurum=E).
   Ana ekranda **Yüklenen sorular** tek listede görünür; her sorunun yanında bir işaret vardır: **saat** = okunuyor, "Cevapla"
   demenizi bekliyor; **mektup** = Gemini'ye gitti, cevap bekleniyor; **gülen yüz** = cevaplandı (cevap ve model altında yazar);
   **kırmızı çarpı** = gitmedi (nedeni kırmızıyla yazar, soruyu yeniden okuyun).
   **Soru numarası:** soruları karışık okuyabilirsiniz. Her sorunun başında numarayı söyleyin ("soru yedi", "7. soru", "yedinci soru",
   "soru numarası on iki"); cevap ve kayıt **söylediğiniz numarayla** yapılır (`soru_7`), sıraya bakılmaz. Aynı numarayı yeniden
   okursanız eski cevabın yerine yenisi yazılır. Numara hiç söylenmezse sıradaki numara verilir ve soru listesinde turuncu bir not çıkar.
   **Gönderildi bilgisi:** "Cevapla" dedikten sonra kulaklıktan "Soru başarıyla alınıp Gemini'ye gönderildi, cevap bekleniyor" duyarsınız;
   bu cümleyi duymadıysanız soru gitmemiştir. Numara söylememişseniz önce "Lütfen okuduğunuz sorunun numarasını söyleyin" denir.
   **Ortak paragraf:** birkaç soru aynı paragrafa dayanıyorsa önce **"Ortak paragraf"** deyip duraklayın; program "Lütfen ortak paragrafı okuyun, bitince Tamam deyin" der. Paragrafı okuyup bitirince **"Tamam"** deyin ("Tamamlandı" da kabul edilir).
   Program "Paragraf metnini aldım" der ve hangi sorulara ait olduğunu sorar: numaraları söyleyip **"Tamam"** deyin ("beş altı yedi", "5, 6, 7",
   "5. soru, 6. soru, 7. soru", "beşinci soru, altıncı soru", "beşten yediye kadar"; eskisi gibi "Cevapla" da kabul edilir). Sonra soruları sırayla okuyun: paragraf, ait olduğu her soruyla birlikte Gemini'ye gider (varsa sesiyle);
   hepsi cevaplanınca paragraf bırakılır. Paragraf okurken bağlantı kesilirse program son cümleyi söyler, oradan devam edersiniz ve
   "Tamam" demeniz yeter. Uygulama tümüyle kapanıp kendiliğinden açılırsa paragrafın **metni** korunur ("Ortak paragraf yazı olarak korundu…" denir) ve sonraki sorular onunla gider; paragrafın ses kaydı kaybolur, yarım okunan metin de kaybolur (gerekirse son soruyu baştan okuyun).
3. Cevaplar, seçtiğiniz **kayıt klasöründe gün klasörü** altında `soru_1`, `soru_2`… olarak kalır (`cevaplar.txt` de yazılır). Bir soruyu yeniden
   okuyup yeniden cevaplatırsanız hem ses dosyası hem `cevaplar.txt` satırı yenisiyle değişir. Cevap kulaklıktan duyulamayıp sonradan yeniden
   okunursa ses dosyası o sırada yazılır.
4. Bitince **Testi Bitir** (yanlışlıkla basılmasın diye bir onay sorar), sonra **Cevapları Tekrarla**: sistem internetsiz çalışır,
   kayıtlar sırayla çalınır, aralarında ayardaki süre kadar bekler. Tek bir bozuk dosya atlanır (bitişte kaç dosyanın çalınamadığı yazılır);
   üst üste iki dosya çalınamazsa tekrar durur.

**Sınavda işe yarayan düğmeler (ana ekran)**

- **Sesi dene** (test başlamadan): ses yolunu denetler, kulaklıktan kısa bir cümle çalar, mikrofonun görünüp görünmediğini yazar.
  Kulaklık bağlı değilse hiçbir şey çalmaz (ses telefon hoparlöründen çıkmaz).
- **Duraklat / Devam et:** görevliyle konuşmanız gerekirse mikrofon kapanır, konuşulanlar yazıya çevrilmez, hiçbir şey gönderilmez.
  Gemini'ye gitmekte olan soru gitmedi sayılır (soruyu yeniden okursunuz); okunurken kesilen cevap kayıtlıdır ve devam edince yeniden okunur.
- **Ekranı kilitle** (test başlamadan da, test sürerken de görünür): ekrana yanlışlıkla dokunmak (ör. **Testi Bitir**) bir şey yaptırmasın
  diye dokunmatik ekranı kilitler. Program çalışmaya devam eder. Test başlamadan kilitlerseniz kilit test başlayınca da sürer. Kilidi
  açmak için çıkan büyük yuvarlak düğmeye **3 saniye basılı tutun** (halka dolar); test bitince kilit kendiliğinden kalkar.
  Sınır: yan tuş, ses tuşları ve ekran kenarından kaydırma iOS'un işidir, uygulama engelleyemez; tam kilit için iPhone'un
  **Kılavuzlu Erişim** özelliğini açın.
- **Şarj uyarısı:** telefon şarjı %20, %10 ve %5'e düşünce (şarjda değilse) kırmızı kutuda bir kez yazar; sesli söylemez, soru
  okunurken araya girmesin diye. Şarja takınca kalkar.

## Sorun giderme

- **"Konuşma tanıma durdu, yeniden kuruluyor":** kulaklık ve mikrofon sağlam, yalnız iOS'un konuşma tanıması düştü. Hiçbir Kestirme çalışmaz; uygulama tanıyıcıyı ve ses oturumunu yeniden kurar, dinlemenin gerçekten çalıştığını gördükten sonra "Hazır" der (birkaç saniye). Kurulamazsa nedenini söyler ve her 15 sn'de yeniden dener. "Konuşma tanıma kapalı" derse iPhone Ayarlar > Genel > Klavye > Dikteyi Etkinleştir'i açın; çevrimdışı Türkçe dikte yoksa Ayarlar > Genel > Klavye > Dikte bölümünden Türkçe'yi ekleyip internetteyken indirin. Sürerse Ayarlar > Tanı ve günlük kaydındaki `[mikrofon]` satırlarını (hata kodları) gönderin.
- **"Duraklatıldı: kulaklık, mikrofon ya da ses kesintisi":** kulaklık ve alıcı bağlı mı, çıkış düğmesinde kulaklık, mikrofon listesinde alıcı seçili mi? Geri gelince kendiliğinden devam eder; 20 sn dönmezse `Bluetooth`, o da işe yaramazsa `Sistemi Sıfırla` çalışır.
- **"Ses şu an telefona gidiyor" / Sesi dene çalmıyor:** ana ekranın altındaki "Şu an: Çıkış: …" satırı sesin nereye gittiğini yazar. Çıkış telefon ise "Ses çıkışı" düğmesinden Bluetooth kulaklığı seçin. Kulaklık yalnız müzik (A2DP) olarak bağlanır; telefon (mikrofonlu) profili kapalıdır, çünkü mikrofon her zaman Lightning alıcıdan gelir.
- **"Giriş: yok" ama mikrofon alıcısı takılı:** kulaklık seçildikten sonra iOS ses yolunu yeniden kurar; uygulama kontrolü bir buçuk saniye kadar bekleyip mikrofonu yeniden seçerek tekrarlar. Ana ekrandaki "Şu an" satırı alıcının adını ve "takılı ama ses yoluna girmedi" bilgisini yazar. Hâlâ girmiyorsa alttaki mikrofon listesinden alıcıya bir kez dokunun.
- **Kulaklık düştü, yeniden bağlanmıyor:** Ayarlar > Bluetooth'ta kulaklığa dokunmak elle yapılır ve sınavda mümkün değildir; uygulama da Ayarlar'a girip dokunamaz (iOS izin vermez). Bu yüzden tek otomatik yol Kestirmeler'dir: aşağıdaki **Çıkışı kulaklığa al** kestirmesini kurun. Kulaklık yoldan çıkınca uygulama bunu ~3 sn sonra kendisi çalıştırır; düzelmezse 20 sn dolunca bir kez daha, o da olmazsa `Bluetooth` ve `Sistemi Sıfırla`. Ana ekranda kulaklık yolda değilken hangi adımın bekleyeceği yazar.
- **Ses iPhone'a düşüyor / "Bluetooth music" kendiliğinden seçilmiyor:** Kestirmeler'de tek eylemli bir kestirme yapın (ör. adı `Kulaklık Düzeltme`): **Oynatma Hedefini Ayarla** eylemini ekleyin ve hedef olarak Bluetooth kulaklığınızı seçin. Adını Ayarlar > Kestirmeler > **Çıkışı kulaklığa al** alanına yazıp **Dene** ile sınayın. Uygulama bunu, açılışta kulaklık yolda değilse ve test sürerken kulaklık yoldan çıkınca ~3 sn sonra ve 20 sn dolunca **Bluetooth'u kapatıp açmadan önce** çalıştırır; art arda 6 denemede yol düzelmezse eski sıraya geçer, yol düzelince hak yenilenir. Kestirme herhangi bir eylem dizisi olabilir: uygulama onu çalıştırır, sonra ses yolunun düzelip düzelmediğine bakar. Güçlendirme önerileri (hiçbiri cihazda denenmedi):
  - Eylemi iki kez koyun: **Oynatma Hedefini Ayarla** → **Bekle 3 sn** → **Oynatma Hedefini Ayarla** (aynı hedef). İlki bağlanmayı başlatır, ikincisi bağlanınca çıkışı seçer.
  - Uygulamadan bağımsız yedek: Kestirmeler > Otomasyon > Kişisel > **Bluetooth** > kulaklık > **Bağlantı Kesildi** > **Hemen Çalıştır** > aynı kestirme.
  - Ayarlar'daki "Bluetooth Music" satırına dokunmayı yaptırmak için **Anahtarla Denetim** kullanılabilir (Ayarlar > Erişilebilirlik > Anahtarla Denetim > Tarifler: tam ekran özel hareketle o satıra dokunuşu kaydedip **Başlatma Tarifi** yapın; kestirme sırası: **URL'yi Aç** `App-Prefs:Bluetooth` > **Anahtarla Denetim'i Ayarla: Aç** > bekle > **Anahtarla Denetim'i Ayarla: Kapat**). Zayıf yanları: dokunuş ekran koordinatına bağlıdır (aygıt listesi değişirse yanlış yere dokunur), Başlatma Tarifi'nin açılır açılmaz kendiliğinden çalışıp çalışmadığı bildirilen kullanıcı deneyimlerine göre değişiyor (bir tıklama isteyebilir) ve `App-Prefs` bağlantısı iOS sürümüne göre açılmayabilir. Önce elle deneyip çalıştığını görün, sonra kestirmeye alın.
- **"Kestirme ikide bir çalışıyor":** kulaklık sağlamken yalnız mikrofon girişi yola girmemişse (alıcı takılı) Kestirme **çalıştırılmaz**; Bluetooth/uçak modunu kapatıp açmak kulaklığı da koparırdı. Bunun yerine mikrofon yeniden seçilir, kırmızı kutuda nedeni yazar ve yol oturunca kendiliğinden devam edilir. Alıcı hiç görünmüyorsa (yaka mikrofonunu çıkardınız) da Kestirme çalışmaz: Lightning mikrofon için Kestirme yoktur ve Bluetooth/uçak modu mikrofonu getirmez, kulaklığı koparır. Program "Yaka mikrofonu görünmüyor…" der, bekler ve mikrofon takılınca kendiliğinden devam eder. Kestirmeler yalnız **kulaklık yolda değilse** (Bluetooth sorunu) ve **internet kopmuşsa** çalışır.
- **Mikrofon listesi boş:** alıcıyı çıkarıp takın, **Yenile**'ye basın.
- **Kırmızı kutuda "çevrimdışı dikte yüklü değil":** 3. bölümdeki 1. adım.
- **Kestirme açılıyor ama uygulamaya dönmüyor:** Ayarlar'daki **Dene** düğmesiyle her kestirmeyi tek tek sınayın; adın birebir aynı olması gerekir.
- **Gemini cevap vermiyor:** kırmızı kutu nedeni söyler (anahtar geçersiz, kota doldu…). Model zinciri kendiliğinden sıradaki modele geçer.
- **Kaydedilen dosyalar `.m4a`/`.wav`:** iOS MP3 yazamaz; cevaplar bu biçimlerde saklanır.
