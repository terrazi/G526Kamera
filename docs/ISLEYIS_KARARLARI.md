# Deneme sınavı modu: işleyiş kararları

Kullanıcının onayladığı maddeler. Revizyonda kod bu listeye göre düzeltilir.
Durum: [ONAYLI] kullanıcı onayladı · [TASLAK] önerildi, onay bekliyor

## Genel iskelet (kullanıcının tarifi)
1. [TASLAK] Açılışta sına: ses çıkışı, mikrofon, internet, Gemini
2. [TASLAK] Sorun yoksa kamera kaydı (video) başlar
3. [TASLAK] Fotoğraf çekimine başlanacağını söyler; kamerayı sesle konumlandırır
4. [TASLAK] Fotoğraflar çekilince Drive'a gönderilir
5. [TASLAK] Video + PDF Gemini'ye gider; soruları tane tane çözmesi istenir; soru sayısına ve dosyalara göre gruplara bölünür, bir grubun cevabı gelince sonraki grup
6. [TASLAK] Bitince tüm cevaplar istenir
7. [TASLAK] Cevaplar kontrol edilir, işlem tamamlanır

## Onaylı maddeler
A. [ONAYLI] Program açılınca ilk sınama yapılır: ses çıkışı, mikrofon, internet, Gemini. Hepsi çalışmadan ilerlenmez; sorun varsa nedeni söylenir/ekrana yazılır.
B. [ONAYLI] Sınama tamamsa "Her şey tamam, istediğiniz zaman deneme sınavına başlayabiliriz" denir ve program BEKLER. Video kaydı ve sınav kendiliğinden başlamaz.
C. [ONAYLI] Kullanıcı "sınavı başlat" deyince tek bir video aşaması: kağıttaki yazılar görünür görünmez "Kaydı başlatayım mı?" diye sorulur; "evet" ile 30 saniyelik kayıt başlar; kullanıcı 30 saniye içinde iptal etmezse video telefondaki sınav klasörüne kaydedilir (Drive'a GİTMEZ). Bu aşama burada biter (tek video, "videoya devam edeyim mi" döngüsü yok).
D. [ONAYLI] Video Gemini'ye şimdilik EKLENMEZ. Gemini'ye veriler (PDF'ler vb.) daha sonraki aşamada gönderilecek (ayrıntısı o adımda konuşulacak).

E. [ONAYLI] Gemini ile konuşma ilkesi: dosyalar Gemini'ye her seferinde yeniden gönderilmez. Dosyalar bir kez yüklenir, işleri toplu olarak yaptırılır, iş bitince konu kapatılır (Gemini'ye yüklenen dosyalar silinir).
   [TASLAK] Uygulama: tüm sorular mümkünse tek çağrıda istenir; cevap kesilirse ya da eksik kalırsa kalan sorular için, aynı yüklü dosyalarla (yeniden göndermeden) tamamlama çağrısı yapılır. Cevaplar tane tane sesli okunur. Kontrol sonda tek çağrı.
G. [ONAYLI] Sınav boyutu (soru/sayfa sayısı) her sınavda değişir; kullanıcı ayar yapmaz.
   [TASLAK] Program kendisi karar verir: varsayılan tek çağrı; soru sayısı/sayfa/dosya boyutu tahmini cevap ya da istek sınırının ~%70'ini aşarsa kendiliğinden parçalara böler.
H. [ONAYLI] Aynı sayfa/soru kalite için birkaç kez çekilebilir (Gemini daha iyi değerlendirsin diye).
   [TASLAK] Nasıl işlenecek: karar bekliyor (tüm çekimler mi, her sayfanın en net çekimi mi).
I. [ONAYLI] Dosya düzeni: çekilen fotoğraflar, PDF'ler ve video telefondaki sınav klasörüne kaydedilir; Gemini'ye hep o klasörden yüklenir (Drive'dan indirme yok). Gemini'ye yükleme, çekimler tamamen bitince yapılır.
J. [ONAYLI] Sınav modunda Drive'a hiç dokunulmaz, Drive yedeği de yapılmaz; yedek, telefondaki kayıtların kendisidir (kullanıcı kararı). Drive özelliği normal tarama/kayıt modlarında olduğu gibi kalır.
K. [ONAYLI] Sınav dosyaları programın klasörünün DIŞINDA, "G526 Belgeler" adlı ayrı bir klasörde tutulur (program silinse de silinmesin). PDF ve video orada KALIR, kullanıcı silene kadar saklanır.
   Alt klasör YOK: sınavla ilgili tüm dosyalar (PDF'ler, video) doğrudan "G526 Belgeler" klasörüne atılır.
   Dosya adı: oluşturulma anı, yıl-ay-gün-saat-dakika-saniye (yyyyaaggssddss), örnek 20261112091245.pdf / .mp4 (kullanıcı onayladı: yıl ay gün sırası). Adla sıralayınca kronolojik olur. Aynı saniyede iki dosya olursa sonuna -2, -3 eklenir.
   [TASLAK] Uygulama: iOS bir programa kendi klasörü dışında yazma izni ancak kullanıcı klasörü seçerse verir. Kullanıcı bir kez "Klasör seç" der (seçici ekranında "Yeni Klasör" ile "G526 Belgeler" açılır/seçilir); program bağlantıyı hatırlar. Klasör seçili değilse ya da erişilemiyorsa açılış sınaması bunu bildirir (A maddesine "belge klasörü hazır mı" eklenir). Video önce geçici yere yazılır, bitince klasöre taşınır. Gemini'ye yükleme bu klasörden yapılır.
   [VARSAYILAN] Ham fotoğraflar PDF oluşturulunca silinir; PDF ve video kalır.
   [KAPANDI] Windows programı kullanılmıyor; Drive'ın kalkması onu etkilemez.
L. [ONAYLI] Fotoğraf taraması: video bitince program "Şimdi fotoğraf taraması" der; kullanıcı sayfaları kameraya gösterirken sesle konumlandırmaya yardım eder (yukarı, aşağı, yaklaştır, sabit tut); sayfa net okunduğunda otomatik çeker ve "çekildi, sıradaki sayfa" der; kullanıcı "tarama tamamlandı" deyince fotoğraflar PDF'e dönüştürülüp "G526 Belgeler" klasörüne kaydedilir.
   [VARSAYILAN] Tekrar çekimler (H): B seçeneği — her sayfanın en net çekimi Gemini'ye gider, diğerleri telefonda yedek kalır; Gemini bir yeri okuyamazsa yedek çekim sonradan gönderilir. (Kullanıcı A/B sorusuna açıkça cevap vermedi; itiraz ederse A'ya çevrilir.)
M. [ONAYLI] PDF birleştirme ve yükleme: "tarama tamamlandı" sonrası program görselleri dosya sınırına göre birleştirir; mümkün olduğunca EŞİT sayıda görsel içeren parçalar (PDF'ler) oluşturur; parçaları gönderim sınırı durumuna göre Gemini'ye yükler.
   [TASLAK] Parça sayısı = toplam sayfa / parça sınırı yukarı yuvarlanır (sınır: parça başına en çok ~20 sayfa ve ~15 MB, hangisi önce dolarsa); sonra sayfalar parçalara eşit paylaştırılır (örnek: 70 sayfa → 4 parça: 18+18+17+17). Sayfa sırası korunur. Boyut için önce bölme, gerekirse görseli küçültme (okunabilirlik önce gelir). PDF sayfa sayfa diske yazılarak üretilir (tüm görseller belleğe alınmaz). Parça adları zaman damgalıdır (K maddesi).
   [TASLAK] Yükleme: parçalar Gemini'ye sırayla, tek tek yüklenir; kota/sınır hatasında (429 vb.) bekleyip kaldığı parçadan devam eder, yüklenmiş parça yeniden gönderilmez. Tüm parçalar yüklenmeden soru çağrısı yapılmaz. Gemini tüm parçaları tek çağrıda birlikte görür (iki sayfaya yayılan soru sorun olmaz).
N. [ONAYLI] Programdaki TÜM Drive tanımları kaldırılır; Drive ile iş kalmaz (kullanıcı kararı; yalnız sınav modu değil, bütün program).
   Kalkacaklar: Google hesabıyla Drive bağlantısı ve ayar ekranları, Drive'a yükleme kuyrukları (fotoğraf ve video), Drive'dan indirip Gemini'ye verme, Drive'la ilgili sesli komut/mesajlar ve testler.
   [VARSAYILAN] Normal tarama ve video modları da dosyalarını "G526 Belgeler" klasörüne kaydeder (K maddesi). Bunların yerine gelen yerel kaydetme tek bir yerden yönetilir.
   [KAPANDI] Windows programı kullanılmıyor (kullanıcı); Windows tarafı için ayrı bir yol gerekmez.
   [UYGULAMA NOTU] Bu, koda dokunan büyük bir değişikliktir (Drive geçen 20 kaynak dosya, 27 test dosyası); revizyonda adım adım yapılacak, her adım CI'da derlenip sınanacak.
O. [ONAYLI] Ayarlar 4 başlıkta toplanır: 1) Kamera ayarları, 2) Ses ayarları, 3) Gemini ayarları, 4) Dosya ve diğer ayarlar (kullanıcı önerdi).
   [TASLAK] Dağılım: Kamera = kamera bağlantısı/UID, çekim, hareket, sesli konumlandırma kılavuzu, güç tasarrufu. Ses = ses çıkışı seçici, "Sesi dene", dinleme ve komut sesi, okuma sesi, mikrofon sağlığı. Gemini = anahtar/model/profiller, düşünme düzeyi, deneme sınavı seçenekleri (açılışta sına, grup/iptal süreleri). Dosya ve diğer = "G526 Belgeler" klasörünü seç, internet kendini onarma kestirmesi, Tanı/günlük, Sağlık raporu, sürüm bilgisi.
   [TASLAK] Ayarlar ilk ekranı 4 satır + her satırda kısa durum ("Kamera: bağlı", "Ses: kulaklık", "Gemini: anahtar var", "Klasör: seçildi"); her başlıkta üstte yalnız birkaç temel ayar, geri kalanı "Gelişmiş" altında.
P. [ONAYLI] Cevap okuma biçimi (kullanıcı belirledi): "11. sorunun cevabı Ceyhan. <şıkta yazan cevap metni>." Yani önce kaçıncı soru olduğu net söylenir, sonra şıkkın KOD ADI (harf değil, kod kelime: C şıkkı için "Ceyhan"), sonra o şıkta yazan cevap metni. Harfin kendisi ("Şık C") söylenmez; sebep: be/de/e/ce harfleri kulaklıkta karışır. Cevaplar arasında 2 saniye bekleyip kendiliğinden sonraki soruya geçer. Komutlar: dur, tekrar, devam.
   [ONAYLI] Şık kod adları (kullanıcı onayladı; Ses ayarlarında düzenlenebilir): A=Adana, B=Bursa, C=Ceyhan, D=Denizli, E=Erzurum. 4 şıklı sorularda D'ye kadar okunur.
   [VARSAYILAN] Bölüm varsa başta söylenir ("Türkçe, soru 5"). Bekleme süresi Ses ayarlarında değiştirilebilir (varsayılan 2 sn). Şık metni yoksa ("klasik" soru ya da okunamadıysa) kod adı okunur ve "şık metni okunamadı" denir; şıksız sorularda cevap metni okunur.
   [VARSAYILAN] Cevap listesi "G526 Belgeler" klasörüne düz metin (.txt) olarak kaydedilir (zaman damgalı adla). İtiraz edilirse PDF yapılır.
F. [TASLAK] Telefon yükü ilkeleri (ısınma/kasılma): dosyalar RAM'de değil diskte tutulur (çekilen fotoğraf hemen diske yazılıp bellekten bırakılır); yükleme (Drive ve Gemini) dosyadan akıtılarak yapılır, tüm dosya belleğe okunmaz; dosyalar Gemini'ye bir kez yüklenir, sonraki çağrılarda yalnız adres gider; dosya telefondaki yerel kopyadan gider (Drive'dan tekrar indirilmez); gönderme sırasında kamera önizleme/analiz kapalı; aynı anda tek ağır iş; sonuçlar Sağlık raporuyla ölçülür.

## Varsayılan ayrıntılar (kullanıcı itiraz etmedikçe)
- Kayıt sırasında "durdur/yeter" derse kayıt o an biter ve gönderilir; "iptal/sil" derse silinir, gönderilmez.
- "Kaydı başlatayım mı?" sorusuna "hayır" derse program bekler; kullanıcı "kaydı başlat" deyince başlar.

## Koddaki mevcut durumdan farklar (revizyonda düzeltilecek)
- Sınama şu an sınav başlarken yapılıyor; açılışta yapılacak ve sonucu hatırlanacak.
- Video şu an "evet" sorulmadan, evrak görününce kendiliğinden başlıyor; evet sorulacak.
- Videodan sonra "Videoya devam edeyim mi?" döngüsü var; kalkacak.
- Sınav videosu şu an Gemini isteklerine ekleniyor (son sürümde eklendi); kaldırılacak (D maddesi).

## Gereksiz kalanlar taraması (2026-11-12)
Kesin kalkacak (karar var):
- Google Drive: GoogleAuth, DriveClient, DriveSetupView, "Google Drive" ayar bölümü (klasör adı, istemci kimliği/sırrı), ana ekrandaki Drive satırı, Drive yükleme/indirme, bağlantı sınama, "Windows programında aynı kimlik" yazıları.
- "Telefonda da kopya sakla" (keepLocalCopies) ve Documents/Belgeler, Documents/Videolar alt klasörleri: tek klasör "G526 Belgeler" bunların yerini alır.
- Sınav videosunu Gemini'ye ekleme (ExamTask video, ExamAsker.videoProvider, AppModel sınav video kopyası).
- Sınav ayarları "Gruptaki soru sayısı" (examGroup) ve "Bir seferde alınacak PDF" (examFetch): Gemini bölme işini program kendi karar verir (G).
Sorulacak (kullanıcı kararı bekliyor):
- "Video bitince Gemini'ye de sor" (videoToGemini/videoQuestion/videoHighRes): sınav dışı video için; video Gemini'ye gitmeyecekse gereksiz.
- Gönderme modu tek tek/toplu, "kaç fotoğrafta bir", "bekleme sn", dosya türü PDF/JPEG: yeni düzende PDF parçaları komutla yapılır.
- OCR (metni oku, PDF sonuna ekle; "OCR'ı Gemini ile yap"): telefonu ısıtır, Gemini sayfayı kendisi okuyor.
- "Büyük belge setlerini Gemini'nin hafızasına al" (geminiMemory) ve "Gemini'ye verilecek belge sayısı" (geminiDocCount): dosyalar bir kez Files API'ye yüklenecek.
- "Sınav önce video çeksin" (examVideoFirst) ve "Sınav başlarken ses/internet/Gemini'yi sına" (examSelfCheck): yeni düzende ilk sınama hep var, video aşaması her zaman soruluyor.
- Fotoğraf iyileştirme ayarları (deskew, upscale, tarih yazısı, birkaç kareyi birleştir, çekim öncesi/sonrası): sınav taramasında sadeleştirilebilir.

Q. [İSTEK] Görüntü yönü: kamera dik (portre) tutulabilsin; ayarlarda "Görüntü yönü: Normal / 90° sağa / 90° sola / 180°". Önizleme, fotoğraf, PDF ve video bu yöne göre kaydedilir; sesli yönlendirme (sağa/sola/yukarı/aşağı) yöne göre uyarlanır. Kodda şu an görüntü döndürme yok ("ters takılı" ayarı yalnız sesli yönleri çevirir). Karar: Drive kaldırma sürümünden sonraki sürümde yapılacak.

A'. [İSTEK] Açılıştaki ses sınaması: program "Beni duyabiliyor musunuz? Lütfen teyit edin." diye sorar; kullanıcı "evet" (ya da tamam) deyince iki taraflı ses sınaması (program konuştu + kullanıcıyı duydu) tamamlanmış sayılır. Şimdi bu sınama yalnız "deneme sınavı modu" denince yapılıyor ("tamam deyin" metniyle); 2. adımda programın açılışına taşınacak ve metin bu olacak.
