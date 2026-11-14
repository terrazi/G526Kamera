# Olumsuz durum senaryoları ve önlemleri (Sürüm 3)

Her satır: ne olabilir → uygulama ne yapar → hangi testle sınandı. **Cihazda doğrulanamayanlar** ve **açık kalan** maddeler ayrıca işaretlidir;
test yeşil olması, sahada aynen böyle çalıştığının kanıtı değildir (testler sahte kulaklık/mikrofon/ağ ile çalışır, gerçek Bluetooth ve iOS ses servisi yoktur).

Durum: ✅ önlem var ve testli · 🛠 bu incelemede bulundu ve düzeltildi · ⚠️ açık (karar/cihaz denemesi gerekiyor) · 📱 yalnız cihazda doğrulanabilir

## 1. Kulaklık ve mikrofon

| Ne olabilir | Önlem | Durum |
|---|---|---|
| Kulaklık koptu (okurken, dinlerken, Gemini beklerken) | Ses anında susar, mikrofon kapanır, iş durur; hiçbir şey telefon hoparlöründen çalınmaz (KURAL 1). Yol dönünce 1 sn sabit kalırsa devam; 20 sn dönmezse "çıkışı kulaklığa al" → Bluetooth → sıfırlama kestirmesi. Duyulamayan cevap devamda yeniden okunur | ✅ 📱 (iOS bildirimi gelmeden önceki kısa pencere ölçülemez) |
| Yaka mikrofonu çıktı / ses telefonun kendi mikrofonuna düştü (kulaklık sağlam) | Aynı duraklama; **hiçbir Kestirme çalışmaz** (Lightning mikrofon için Kestirme yok, Bluetooth/uçak modu çalışan kulaklığı koparırdı). Mikrofon yeniden seçilir, kırmızı kutuda neden yazar (alıcı hiç görünmüyorsa "Yaka mikrofonu görünmüyor…", takılı ama girişte yoksa "alıcı yola girmiyor…"), her 20 sn bakılır, mikrofon dönünce 1 sn sabit kalırsa kendiliğinden devam edilir | ✅ |
| Çıkış kulaklıktan telefona düştü ama kulaklık bağlı | "Çıkışı kulaklığa al" kestirmesi 1 sn içinde, bir oturumda en çok 6 kez | ✅ |
| Mikrofon donuyor (tampon gelmiyor), kulaklık sağlam | Nöbetçi 0,5 sn'de yakalar, dinlemeyi yeniden kurar, yarım metin korunur; art arda olursa ses oturumu ve dinleme baştan kurulur (Kestirme çalışmaz); 3 kez işe yaramazsa uyarı + dakikada bir deneme | ✅ |
| iOS ses servisi çöktü/sıfırlandı | Her şey durur, ses oturumu hemen yeniden kurulur, 5 kez denenir | ✅ |
| Onarım işe yaramıyor, döngü | 3 onarımdan sonra 60 sn bekleme + bir deneme; ne olduğu söylenir; sayaç tek kelime tanınınca sıfırlanır | ✅ |
| Arama / alarm / Siri | Duraklar, Kestirme çalıştırılmaz, bitince devam; bitiş bildirimi gelmezse 15 sn'de yoklar | ✅ |
| **Arama onarımın ortasında gelir** (uçak modu kestirmesi aramayı keserdi) | Onarım bırakılır, kesinti duraklamasına geçilir | 🛠 |
| Kulaklık ses seviyesi 0 / kulaklık uykuda ama bağlı görünür | Uygulama ses seviyesini okumuyor; "Ses testi" düğmesi var | ⚠️ 📱 |

## 2. İnternet ve Gemini

| Ne olabilir | Önlem | Durum |
|---|---|---|
| İnternet koptu | Nabız (5 sn'de bir yoklama, 2 başarısız yoklama) yaklaşık 6–10 sn'de yakalar; Wi-Fi → Hücresel → Sistem Sıfırla; her adımdan sonra doğrulama; düzelince "hazır" | ✅ |
| Hızlı yoklama boşuna alarm verir | Önce tam sınama (internet + Gemini); sağlamsa hiçbir şey durmaz, anons yok, yarım soru silinmez; susturma yok, nabız daha uzun yoklamaya geçer | ✅ |
| Soru giderken bağlantı düştü | Soru "gitmedi" işaretlenir, bağlantı onarılır, "Bağlantı yeniden onarıldı. Sorunuz yarım kaldıysa son soruyu tekrar okuyunuz" denir (akıllı devam kapalıysa eski cümle) | ✅ (otomatik yeniden gönderim bekliyor, bkz. §7) |
| Kota / anahtar reddi / sunucu hatası / boş yanıt | 4 profil sırayla; arızalı profil dinlenir, cevap yedekten gelirse sebebi kırmızı kutuda | ✅ |
| İçerik engeli, harcama sınırı, çok büyük istek | Başka modele geçilmez; ne olduğu söylenir, dinlemeye dönülür | ✅ |
| **Gemini takıldı** (bağlantı var, cevap gelmiyor) | "Cevapla"dan sonra "soru gönderildi, cevap bekleniyor"; 30 sn'de bir "Cevap bekleniyor"; **180 sn'de bekleme bırakılır** (istek iptal, soru "gitmedi", "soruyu tekrar okuyun", dinlemeye dönülür; onarım başlatmaz). Ayar kapalıysa eski davranış (en kötü ~8–10 dk sessizlik) | ✅ |
| Yavaş hatta büyük ses kaydı zaman aşımına uğrar | Zaman aşımı → sıradaki profil (aynı büyük kayıtla) → hepsi dolarsa "soruyu yeniden oku" | ⚠️ açık |
| Gemini beklenirken arama gelir / elle duraklatılır / ikinci "Cevapla" | Soru "gitmedi" olur ya da yok sayılır; geç gelen cevap duraklatılmış oturumu bozmaz | ✅ |

## 3. Konuşma tanıma

| Ne olabilir | Önlem | Durum |
|---|---|---|
| Dikte kapalı / Türkçe çevrimdışı model yok / izin yok | Oturum kapanır, ne yapılacağı söylenir (yeniden denemek işe yaramaz) | ✅ |
| Tanıma görevi hemen düşüyor | Dinleyici içinde kademeli onarım (İngilizceyi bırak → tanıyıcıları yenile → motoru yeniden kur), sonra uygulama tarafı: Kestirme çalışmaz, ne olduğu söylenir, dinleme kanıtlanınca "hazır" | ✅ 📱 (ilk düşmenin kök nedeni cihaz günlüğü olmadan bilinemez) |
| 30 sn sessizlik | Dinleme sessizce yenilenir, mikrofon ve bağlantı denetlenir; yalnız gerçek arıza varsa onarım | ✅ |
| Tetikleyici varyantları ("CEVAPLA.", "gonder", "“Cevapla” …") | Büyük/küçük harf, noktalama, ö/o yok sayılır; soru metnine tetikleyici karışmaz | ✅ |
| Soru ortasında "gönder…" gibi sözcük | Yalnız SON sözcük tetikler | ✅ |
| Tanıyıcı "cevap la" diye böler | Tetiklemez (bilinen sınır; cihazda görülürse sözcük listesine eklenir) | 📱 |

## 4. Cevap, okuma ve kayıt

| Ne olabilir | Önlem | Durum |
|---|---|---|
| **Cevap okunamadı** (ses çalınamadı / okunamadı) | Eskiden sessizce düşüyordu. Şimdi 1 sn sonra bir kez kayıtsız yeniden okunur; olmazsa metni kırmızı kutuda kalır; ses yolu güvensizse KURAL 1 gereği duraklar | 🛠 |
| **Ses dosyası klasöre yazılamadı** (yer doldu, klasör erişimi gitti) | Eskiden fark edilmiyordu. Kırmızı kutu + kulaklıktan söylenir; sonraki başarılı kayıtta silinir | 🛠 |
| **cevaplar.txt yazılamadı** | Aynı şekilde bildirilir; dosya açılamazsa üzerine yazılmaz (eski satırlar kaybolmasın) | 🛠 |
| Aynı soru yeniden okunup yeniden cevaplandı | `soru_N` ses dosyası ve `cevaplar.txt` satırı yenisiyle değişir (çelişen çift satır kalmaz) | 🛠 |
| Cevap duyulamadı (kulaklık koptu, arama geldi), dönünce yeniden okundu | Yeniden okuma `soru_N` dosyasını da yazar (yoksa); test sonu tekrarı bu cevabı atlamaz. Yeniden okuma kayıtsız yapılırsa (ses hatası sonrası ikinci deneme) eksik kayıt kırmızı kutuda görünür | 🛠 |
| Tekrar sırasında bir ses dosyası bozuk | Atlanır, bitişte sayısı yazılır; üst üste iki dosya çalınamazsa tekrar durur | 🛠 |
| Gemini "Soru: 3, …" / "Soru No 3 - …" / ```` ``` ```` çitli / başlıklı yazar | Numara ve şık çözülür; çözülemezse ham satır numarayla okunur | 🛠 |
| Soru numarası okunmadı / çakıştı | Program "Lütfen okuduğunuz sorunun numarasını söyleyin" der; söylenen numara sorunun başına yazılıp gönderilir ("sıradaki" = sıradaki numara). Söylenmezse 2 hatırlatma, sonra sıradaki numarayla gider. Sıra: okunan → söylenen → Gemini'nin duyduğu → sıradaki; aynı numaralı eski dosya silinir | ✅ |
| Birkaç soru aynı paragrafa dayanıyor | "Ortak paragraf … Tamamlandı" → "Paragraf metnini aldım, hangi sorular için?" → numaralar + "Cevapla". Paragraf (ve sesi) ait olduğu her soruyla gider; hepsi cevaplanınca bırakılır | ✅ |
| Okurken kesinti oldu (uzun soru/paragraf) | Onarımdan sonra numara ve en son cümle söylenir, kullanıcı devam eder, metinler birleşir. Uygulama tümüyle kapanırsa yarım metin ve paragrafın ses kaydı kaybolur; paragrafın metni defterde durur ve yeniden açılışta geri yüklenir ("Ortak paragraf yazı olarak korundu…") | ✅ (⚠️ yarım metin ve paragraf sesi kapanmada kaybolur) |
| Paragraf çok uzun okundu (ses kaydı 180 sn'yi aştı, başı atıldı) | Gemini'ye paragraf sesinin başının eksik olduğu, tam metnin dikte metninde olduğu söylenir | 🛠 |
| Numara/paragraf numarası beklerken kesinti | Bekleyen soru ya da paragraf korunur; onarımdan sonra aynı şey yeniden sorulur | ✅ |
| Okurken kulaklık koptu | Cevap kayıtlıdır, dönünce yeniden okunur | ✅ |

## 5. Telefon ve uygulama

| Ne olabilir | Önlem | Durum |
|---|---|---|
| Ekran kilitlenir (Kestirmeler açılamazdı) | Oturum boyunca ekran açık tutulur | ✅ |
| Arka plana geçer | Arka planda ses modu; öne gelince duraklatılmışsa yeniden bakılır | ✅ 📱 |
| Şarj azalır | Kademeli sesli + kırmızı kutu uyarısı | ✅ |
| Art arda oturum (bitir → yeniden başlat) | Temiz başlar, eski cevaplar karışmaz | ✅ |
| Kestirme adı boş | Çalıştırılmaz, söylenir | ✅ |
| Kestirme adı yanlış / Kestirmeler hata penceresi açık kalır | Uygulama bunu göremez (30 sn zaman aşımı); Kestirmeler öndeyken uygulama arka planda kalır | ⚠️ 📱 (kurulum rehberindeki "Dene" adımı şart) |
| Telefon ısınır | Ciddi/kritik ısıda kırmızı kutu + kulaklıktan uyarı, yardımcı İngilizce tanıma kapatılır; soğuyunca uyarı silinir, tanıma geri açılır | ✅ (gerçek ısı 📱) |
| **Bellek dolar** (iOS uygulamayı kapatmadan önce uyarır) | iOS bellek uyarısında ya da kalan bellek 250 MB altına inince yardımcı İngilizce tanıyıcı bırakılır (en ağır parça), söylenir; 400 MB'a çıkınca geri açılır; dakikada bir günlüğe bellek yazılır | ✅ (uyarıya tepki testli; gerçek bellek baskısı 📱) |
| Düşük Güç Modu | Açılışta ve açılıp kapanınca uyarılır | ✅ |
| Boş yer azalır (<200 MB) | Açılışta ve dakikada bir uyarılır (ses kayıtları yazılamayabilir) | ✅ |
| **iOS uygulamayı kapatır / çöker / kaydırılıp kapatılır** | Önlenemez ama telafi edilir: günlük diske yazılır; açılışta önceki çalışma taranır, oturum açıkken kapandıysa **oturum kendiliğinden yeniden başlar**, olanlar ve olası neden söylenir, Gemini'ye gitmiş soru yeniden sorulur / cevabı yeniden okunur, klasör ve numara kaldığı yerden sürer. Yeniden açılışı yalnız Kestirmeler otomasyonu yapabilir (KURULUM.md 5); kaydırıp kapatınca otomatik yeniden açılma evde denendi ve çalıştığı bildirildi (2026-11-14); iOS tetikleyiciyi zorla kapatmadan sonra çalıştırmayı belgelemediği için her sürümde garanti edilmez; elle açınca oturum her hâlde sürer | ✅ kod ve testler; ✅ 📱 otomasyon evde denendi (tek cihaz, tek deneme) |
| Arka arkaya kapanma (çökme döngüsü) | 2 dk içinde 3 beklenmedik kapanmada otomatik başlatma durur, ekranda yazar | ✅ |
| Bilerek kapatma | Kapanma yalnız "Programı kapat" düğmesiyle serbest: 3 sn basılı tutulur; oturum biter, "kullanıcı kapattı" işlenir, panoya `SESLIKONTROL-KAPALI` yazılır (otomasyon yeniden açmaz). Oturum yokken ve "Testi Bitir"den sonra da pano işaretsizdir: başka yolla kapanırsa otomasyon uygulamayı yeniden açar (yeni oturum başlatmaz). İşaret her açılışta silinir | ✅ kod ve testler; 📱 otomasyon |
| Bir aşama sonsuza dek takılır (kontrol, Gemini, okuma, onarım) | Gözcü: kontrol 4 dk, Gemini 11 dk, okuma 3 dk, onarım 6 dk hiç değişmezse iş iptal edilip oturum yeniden kurulur. Dinleme ve duraklatmalar sınırsız bekleyebilir | ✅ |
| Ana iş parçacığı takılır / uygulama askıya alınır | Nabız 3 sn'den geç gelirse günlüğe "gecikti" yazılır (sonradan teşhis) | ✅ |

## 6. Durum makinesi taraması (kaos testi)

`Tests/ChaosTests.swift`: tohumlu rastgele 8–16 olaylık diziler (kulaklık/mikrofon kopma ve dönüşü, arama, internet, tanıma hatası, ses motoru,
mikrofon tamponu, Kestirme sonuçları, Gemini hata/takılma, okuma hatası/takılma, elle duraklatma, şarj, ağ yolu, uygulamanın öne gelmesi).
Her adımda "dinliyor aşamasında dinleyici çalışıyor" değişmezi; dizi sonunda her şey düzeltilip **oturumun kendiliğinden dinlemeye dönmesi**,
Kestirme ve anons sayılarının sınırlı kalması aranır. İki zaman kipi vardır: gerçek zamana yakın (yarım saniyelik adım) ve hamle (zaman tek seferde geçer).

Okuma komutları açık (numara sorma, ilerleme anonsu, akıllı devam) ek iki tarama daha vardır; havuza numara söyleme, "ortak paragraf … Tamamlandı",
paragrafın soru numaraları, "sıradaki" ve yarım okuma olayları eklenir; "numara bekleniyor ama bekleyen soru yok" gibi değişmezler de aranır.

Sistem olayları (bellek uyarısı, ısı, düşük güç, boş yer) havuza eklendi. Geniş tarama (1500 gerçekçi + 2500 hamle tohumu, 29 olay) **0 hata** verdi;
kalıcı sayı 300 + 500'dür.

**Bulunan ve düzeltilen takılma:** kuyruğa alınmış ama başlamadan iptal edilen bir onarım görevi, çalışınca aşamayı "onarılıyor" yapıp iptal
olduğunu görünce çıkıyor, oturum kalıcı olarak "onarılıyor"da kalıyordu (kulaklık ve mikrofon düzelse de dinlemeye dönülmezdi). Mikrofon donması,
yol bildirimi ve onarım sınırı aynı anda üst üste gelince tetikleniyordu. Gerçek hayatta pencere dardır ama sonucu sessiz ve kalıcıdır.

## 7. Bekleyen kararlar ve öneriler

1. ~~Gemini'nin takılması~~ **Yapıldı:** 180 sn sınır, 30 sn'de bir "cevap bekleniyor", "soru gönderildi" anonsu. Ayrıntı: §2.
2. **Zaman aşımında ses kaydı:** ilk profil zaman aşımına uğrarsa sıradaki profile yalnız metinle (kayıtsız) gitmek; doğruluğu biraz düşürür, ama yavaş hatta cevabı kurtarır. Karar sizin.
3. **Kestirmeler "Kapatıldı" otomasyonu:** gerçek telefonda denenmeli (kaydırıp kapatınca açılıyor mu, kilitliyken ne oluyor; Testi Bitir sonrası kaydırıp kapatınca da açılıyor mu; Kestirmeler'e bilerek geçerken pano işareti sayesinde geri çekmiyor mu).
4. **Cihaz günlüğü:** ilk beklenmedik kapanmadan sonra "Tanı ve günlük"ten günlük istenmeli; neden tahmini günlüğün ipucuna dayanır, kesin değildir.
5. **Ses seviyesi:** açılışta çıkış sesi çok düşükse (<%10) kullanıcıya söylemek.
