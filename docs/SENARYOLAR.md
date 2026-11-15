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
| Cevap okunup bitti | Program kendisi "Lütfen sonraki soruyu okuyun" der (kayda yazılmaz), sonra dinler; yarıda kesilirse (kulaklık koptu) onarımdan sonra "Hazır. Son soruyu tekrar oku." denir. Ayardan kapatılabilir | ✅ |
| "Testi bitir" / "Sınavı bitir" denildi | Program "Testi bitirmek istiyor musunuz?" diye sorar; evet cevapları sırayla okutur, "N sorunun cevabı okundu. Başka cevap yok" der ve Devam / Tekrar / Bitir sorar; hayır ya da cevapsızlık sürdürür; Gemini'ye gitmez | ✅ |
| Soru numarası ya da paragraf numaraları beklenirken "Testi bitir" denildi | Program "Okuduğunuz soru henüz gönderilmedi (ya da: ortak paragraf henüz kaydedilmedi); bitirirseniz gönderilmeyecek" diye uyarıp onay ister; hayır / anlaşılmayan söz / cevapsızlıkta numara (paragraf numarası) yeniden sorulur, soru ve paragraf taslağı kaybolmaz; evet cevapları okutur, menüde Devam yine bekleyen numaraya döner | ✅ kod ve testler (`EndWhileWaitingTests`) |
| "Kamera sorusu olmasın" / "Her soruda kamera sorusu olmasın" denildi | Kamera sorusu kapanır, "Kamera sorusu kapatıldı" denir; "kamera olmasın" tek başına komut sayılmaz | ✅ kod ve testler |
| "Cevapları tekrarla" denildi (soru, onay, numara, paragraf numarası beklerken) | Test sürerken cevaplar okunur, kaç sorunun cevabı okunduğu söylenir, Devam / Tekrar / Bitir sorulur; Devam kalınan yere döner | ✅ |
| Menüde söz gelmedi / anlaşılmadı | Bir kez hatırlatılır; sonra bitirme isteğiyle gelindiyse test tamamlanır, değilse teste devam edilir | ✅ |
| Cevaplar okunurken kulaklık koptu ya da arama geldi | Okuma durur, test duraklar; düzelince menü yeniden sorulur | ✅ |
| Sınavda bölümler var ("bölümü tamamla") | Onay → bölümün cevapları okunur → "Yeni bir bölüm ile devam etmek ister misiniz, yoksa testi tamamlayalım mı?"; evet → sonraki bölüm (ayrı `bolum_N` klasörü, numara 1'den); hayır → test biter; cevap gelmezse bir hatırlatma, sonra yeni bölüm. Bölüm sayısından büyük numara kabul edilmez. Cihazda denenmedi | 🛠 |
| Tanıyıcı "beş"i "500 Euro" / "570" yazdı (cihaz günlüğü 22:09) | 100’ün üstündeki sayı soru numarası sayılmaz (hiçbir sınavda 100’den fazla soru yoktur): en iyi okuma buysa tanıyıcının alternatif okumasına ("beş") bakılır, yoksa "Soru numarasını duyamadım…" diye yeniden sorulur; 570 kaydedilmez. Cihazda denenmedi | 🛠 |
| Tanıyıcı "beş" yerine "peş", "yedi" yerine "yeti" yazdı | Yakın sesli yazım olarak anlaşılır (numara, komut, evet/hayır) | ✅ |
| Paragrafın soru numaraları ya da eksik soru numarası anlaşılmıyor | Ekranda "Duyulan: …" yazar; numara olmayan kısa söz 4 sn sonra yeniden sorulur; paragraf numaraları 2 yeniden sormadan sonra paragraf sıradaki soruya bağlanır ve söylenir (sonsuz tekrar yok) | ✅ |
| Soru içinde "testi bitirmek için…" geçti | Komut sayılmaz, normal soru olarak Gemini'ye gider | ✅ |
| "Son cevabı tekrarla" | Son cevap yeniden okunur; cevap yoksa "Tekrarlanacak cevap yok" | ✅ |
| Program kapanıp açıldı / Testi bitirip yeniden başlatıldı, önceki klasörde cevap var | "Devam mı, yeni sınav mı?" diye sorar; devam aynı klasör ve numaradan sürer, yeni yeni klasör ve numara 1; cevapsızsa bir hatırlatma, sonra 12 saatten yeniyse devam | ✅ |
| Önceki klasörde cevap yok / ilk açılış | Soru sorulmaz, "Hazır" denir | ✅ |
| Mikrofon donuyor (tampon gelmiyor), kulaklık sağlam | Nöbetçi 0,5 sn'de yakalar, dinlemeyi yeniden kurar, yarım metin korunur; art arda olursa ses oturumu ve dinleme baştan kurulur (Kestirme çalışmaz); 3 kez işe yaramazsa uyarı + dakikada bir deneme | ✅ |
| iOS ses servisi çöktü/sıfırlandı | Her şey durur, ses oturumu hemen yeniden kurulur, 5 kez denenir | ✅ |
| Onarım işe yaramıyor, döngü | 3 onarımdan sonra 60 sn bekleme + bir deneme; ne olduğu söylenir; sayaç tek kelime tanınınca sıfırlanır | ✅ |
| Arama / alarm / Siri | Duraklar, Kestirme çalıştırılmaz, bitince devam; bitiş bildirimi gelmezse 15 sn'de yoklar | ✅ |
| **Arama onarımın ortasında gelir** (uçak modu kestirmesi aramayı keserdi) | Onarım bırakılır, kesinti duraklamasına geçilir | 🛠 |
| Kulaklık ses seviyesi 0 / kulaklık uykuda ama bağlı görünür | Uygulama ses seviyesini okumuyor; "Ses testi" düğmesi var | ⚠️ 📱 |

## 2. İnternet ve Gemini

| Ne olabilir | Önlem | Durum |
|---|---|---|
| İnternet koptu | Nabız (5 sn'de bir yoklama, 2 başarısız yoklama) yaklaşık 6–10 sn'de yakalar; Hücresel → Sistem Sıfırla (Sürüm 4: Wi-Fi internet için kullanılmaz); her adımdan sonra doğrulama; düzelince "hazır" | ✅ |
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
| Tanıyıcı "cevap la" diye böler | İki sözcük de tetikleyici sayılır (metnin sonundaysa) | ✅ |
| Soru okunmadan / duyulmadan yalnız "Cevapla" denildi | Program "Soruyu duymadım. Lütfen soruyu okuyup Cevapla deyin" der (sessiz kalmaz), dinlemeye döner | ✅ |

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
| Birkaç soru aynı paragrafa dayanıyor | "Ortak paragraf" (duraklama) → "Lütfen ortak paragrafı okuyun, bitince Tamam deyin" → paragraf + "Tamam" → "Paragraf metnini aldım, hangi sorular için?" → numaralar + "Tamam". Paragraf (ve sesi) ait olduğu her soruyla gider; hepsi cevaplanınca bırakılır | ✅ |
| Okurken kesinti oldu (uzun soru/paragraf) | Onarımdan sonra numara ve en son cümle söylenir, kullanıcı devam eder, metinler birleşir. Uygulama tümüyle kapanırsa yarım metin ve paragrafın ses kaydı kaybolur; paragrafın metni defterde durur ve yeniden açılışta geri yüklenir ("Ortak paragraf yazı olarak korundu…") | ✅ (⚠️ yarım metin ve paragraf sesi kapanmada kaybolur) |
| Paragraf çok uzun okundu (ses kaydı 180 sn'yi aştı, başı atıldı) | Gemini'ye paragraf sesinin başının eksik olduğu, tam metnin dikte metninde olduğu söylenir | 🛠 |
| Numara/paragraf numarası beklerken kesinti | Bekleyen soru ya da paragraf korunur; onarımdan sonra aynı şey yeniden sorulur | ✅ |
| Okurken kulaklık koptu | Cevap kayıtlıdır, dönünce yeniden okunur | ✅ |

## 5. Telefon ve uygulama

| Ne olabilir | Önlem | Durum |
|---|---|---|
| Ekran kilitlenir (Kestirmeler açılamazdı) | Oturum boyunca ekran açık tutulur | ✅ |
| Ekrana yanlışlıkla dokunulur | "Ekranı kilitle" test başlamadan da vardır; hazır durumdayken kilitlenen ekran test başlayınca da kilitli kalır, test bitince kendiliğinden açılır. Kilit penceresindeki büyük yuvarlak düğmeye 3 sn basılınca açılır. "Programı kapat" normal kırmızı düğmedir; dokununca çıkan büyük yuvarlak düğmeye 3 sn basılı tutulunca program kapanır (halka dolar; Vazgeç ya da dışa dokunmak örtüyü kaldırır). Düğme renkleri: Başlat yeşil, Duraklat kahverengi, Ekranı kilitle mavi, Testi Bitir turuncu, Programı kapat kırmızı | ✅ kod; 📱 kilit penceresi ve düğmelerin görünümü |
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
| Komut anlaşılmadı ("testi bit") | 2,5 sn sonra "Komutu anlayamadım" der, o sözü metinden atar, tekrar ister; ikinci kez olursa komutları sayar | ✅ kod ve testler; 📱 cihazda görülmedi |
| Eski yanlış komut metinde kaldı, doğrusu söylendi | Komut yalnız son sözden aranır (1 sn sessizlik söz sınırı); "testi bit testi bitir" → testi bitir | ✅ kod ve testler |
| Soru okundu ama "Cevapla" duyulmadı | 20 sn sonra "Cevapla komutunu duyamadım…" (soruda en çok 2 kez, metin korunur) | ✅ kod ve testler |
| Paragraf numaraları söylendi, "Tamam" duyulmadı | 4 sn sonra numaraları okuyup onay ister; yine denmezse kabul eder | ✅ kod ve testler |
| Paragraf numaraları beklerken sessizlik | "Numaraları anlayamadım…" (sınırlı), sonra sıradaki soruya bağlanır | ✅ kod ve testler |

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

## 6b. Sürüm 4: kamera ile çekim

| Ne olabilir | Önlem | Durum |
|---|---|---|
| Kullanıcı "hayır" der ya da cevap vermez | Hayır: V3 gibi sesle okuma. Cevap gelmezse "Cevap vermediniz, ikinci defa soruyorum", sonra "üçüncü defa soruyorum" denir; üçüncüde de cevap yoksa kameraya kendiliğinden geçilir (anlaşılmayan söz de sayılır, "Anlayamadım" denir) | ✅ |
| Kamera "evet" denince çekilecek şey soru mu paragraf mı belli değil | "Soru mu, ortak paragraf mı çekeceksiniz? Birinci seçenek soru, ikinci seçenek paragraf" diye sorulur; bir / birinci / 1 / soru → soru, iki / ikinci / 2 / paragraf → ortak paragraf (çekim ve gönderim ona göre). Cevap gelmezse "ikinci", "üçüncü defa soruyorum", üçüncüde de gelmezse soru olarak çekilir; anlaşılmazsa "Anlayamadım"; "soru mu paragraf mı" ya da "bir iki" gibi seçim sayılmayan sözler yeniden sorulur; kesinti sonrası soru yeniden sorulur; Ayarlar'dan kapatılabilir (kapalıyken her çekim soru). Cihazda sesle tanınma denenmedi | 🛠 |
| Telefonda `Kamera Bağlantısını Onar` kestirmesi yok ("kestirmesi bulunamadı", cihaz günlüğü 22:10) | Yok olan kestirme bir kez denenir, günlüğe nedeni yazılır; ikinci denemede kameraya geçiş kestirmesi yeniden çalışır ve çekim yeniden denenir. Kestirme Ayarlar'daki adla Kestirmeler'de oluşturulmalıdır (KURULUM.md). Cihazda denenmedi | 🛠 |
| Kestirmeler kestirmeyi geri çevirir ("Çalma Hedefi aygıt bulunamadı", cihaz günlüğü 21:12) | Aynı kestirme 2,5 sn arayla en çok 2 kez yeniden çalışır; "kestirme bulunamadı" gibi kalıcı hatalarda beklenmez. Cihazda yeniden deneme sonucu denenmedi | 🛠 |
| Mikrofon eksik, program duraklatıldı (cihaz günlüğü: 10 dk sessizlik) | Yönlendirme bir kez söylenip susmaz; yaklaşık dakikada bir yeniden söylenir (`repeatPausedGuidance`); mikrofon gelince kendiliğinden devam edilir | ✅ |
| Kameraya bağlanılamaz / görüntü gelmez | `Kamera Bağlantısını Onar` ile en çok iki yeniden deneme; olmazsa nedeni söylenir ve sesle okumaya dönülür | ✅ |
| Çekim sırasında görüntü kesilir | 8 sn görüntü gelmezse "Kamera görüntüsü kesildi" denir, onarım ve yeniden deneme | ✅ |
| Soru 30 sn içinde konumlanmaz | Yine de çekilir (odak kipi: ortadaki soru hedeflenir); yardım eden için "Şimdi çek" düğmesi | ✅ |
| Boş yer az | 1500 MB altı uyarı; 400 MB altı çekim yapılmaz, sesle okumaya dönülür | ✅ |
| Çekimden sonra internet gelmez | V3 internet onarımı (hücresel, sıfırlama); çekim telefonda saklanır, gelince gönderilir | ✅ |
| Gönderim ağ hatası verir | İnternet kestirmesi yeniden çalışır, bir kez daha denenir; olmazsa çekim telefondaki klasörde (Bekleyen) bekler; sayı sınırı yoktur. Bir sonraki soru sınırında bir kez daha gönderilir; yine olmazsa ATILMAZ: klasörde durur, söylenir ve kamera sorusu yeniden sorulur; bir sonraki başarılı cevaptan sonra en eskisinden başlayarak sırayla yeniden gönderilir. Arama / kulaklık kesintisi bu hakkı tüketmez | ✅ |
| Kamera akışı sürerken test bitirilir | Kamera kapanır, `Hücresele Geç` kestirmesi çalışır (telefon kameranın Wi-Fi'sinde, hücresel kapalı kalmaz) | ✅ |
| Kamera sorusu açıkken "Testi bitir" / "Tekrarla" denir | Komut çalışır: bitirme onayı istenir (kamera başlamaz), "hayır"da kamera sorusu yeniden gelir; "Tekrarla" son cevabı okur ve yeniden sorar. "bitir", "devam" evet sayılmaz | ✅ |
| "Devam" / "Yeni sınav" seçildi ya da kesintiden dönüldü | İlk soru için kamera sorulur; "Soruyu okuyabilirsiniz" denmez (metinler kamera sorusuna göre değişir) | ✅ |
| Çekilen soruya Gemini yanıt vermez | 3 dk sonra söylenir, çekim bir kez daha gönderilir; yine yanıt yoksa çekim ATILMAZ (klasörde durur, sonra sırayla yeniden gönderilir), söylenir ve kamera sorusu yeniden sorulur | ✅ |
| Çekilen her soru | Gönderilmeden önce telefondaki klasöre yazılır (Dosyalar > Bu iPhone'da > Sesli Kontrol > Cekimler > Bekleyen: foto.jpg, video.mp4, bilgi.json). Gönderilince Gönderilen'e taşınır (cevap.txt ile); Gemini'nin kabul etmediği çekim Gonderilemeyen'e (neden.txt ile). **Kullanıcı Ayarlar'dan silene kadar hiçbir çekim silinmez** | ✅ |
| Uygulama kapanır / test biter, gönderilmemiş çekim var | Klasörde kalır; bir sonraki testte (internet varsa, kamera sorusu kapalı olsa da) en eskisinden başlayarak sırayla gönderilir. Cevapları o testin numaralarıyla kaydedilir | ✅ |
| İnternet yokken bekleyen çekim | Oturum takılmaz: söylenir, soru okunmaya geçilir; çekim klasörde durur | ✅ |
| Bekleyen çekim, internet çalışırken 3 kez gönderilemedi (Gemini hep hata veriyor) | O test için beklemeye alınır (söylenir), her soruda yeniden denenip sınav yavaşlamaz; çekim klasörde durur, silinmez, sonraki testte yeniden denenir | ✅ |
| Çekim tam kulaklık/arama kesintisi anında bitti | Fotoğraf ve video klasöre yazılır; onarımdan sonra gönderilir (kaybolmaz) | ✅ |
| Gemini kare hızı ayarını reddetti (400) | İstek ayarsız bir kez yeniden gönderilir (paragrafın videosu taşıyorsa da). Geçersiz anahtar gibi başka 400'lerde yinelenmez: aynı büyük yükleme boşuna ikinci kez yapılmaz | ✅ |
| Gemini "5. soru, Denizli, …" gibi biçim dışı cevap verdi | Numara ve şık çözülür; okunan cümle yine "Soru 5, Denizli, …" olur | ✅ |
| Çekim isteği | Görüntüler ve video önce, metin istemi en sonda gider (Google'ın video/görüntü önerisi); paragraf görüntüleri sorununkilerden önce | ✅ |
| Çekim klasörüne yazılamaz (yer yok) | Çekim bellekte ve eski yerinde tutulur; test biterse gönderilemeyen bu çekimler için ayrıca uyarı yazılır (kaybolurlar) | ✅ |
| Kamera sorusu söylenirken ya da açıkken kulaklık kopar / arama gelir | Soru kaybolmaz: onarımdan sonra "Bağlantı yeniden onarıldı" denip kamera yeniden sorulur (düz sesle okumaya düşülmez) | ✅ |
| Çekimden sonra internete dönüş sırasında kesinti oldu (telefon kameranın Wi-Fi'sinde kaldı) | Onarımdan sonra, internet yoksa `Hücresele Geç` kestirmesi çalışır; ancak sonra bekleyen çekim gönderilir ya da kamera sorulur. İnternet varsa hiçbir kestirme çalışmaz. Test bu durumda bitirilirse de kestirme çalışır | ✅ |
| Kamera sorusunu beklemeden soru okunup "Cevapla" denir (V3 alışkanlığı) | 9+ sözcük soru okuma sayılır: sesle okuma seçilmiş olur, metin kaybolmaz, Gemini'ye gider; kamera aynı soru için yeniden sorulmaz | ✅ |
| Ortak paragraf sesle kaydedilmişti, sonraki soru kamerayla çekildi | Paragraf (ve hangi numaralara ait olduğu) çekimle birlikte Gemini'ye gider; cevaplanan soru listeden düşer | ✅ |
| Kamera sorusunda "Ortak paragraf" denir | Program "Paragrafı kamera ile çekmek ister misiniz?" diye sorar (önceden "Anlayamadım" derdi). Hayır: V3'teki gibi paragraf sesle okunur, Tamam denir, numaralar sorulur. Cevap gelmezse bir kez daha sorulur, yine gelmezse güvenli varsayılan (sesle okuma) | ✅ |
| Ortak paragraf kamerayla çekilir | Paragraf okunmaz: aynı kamera akışıyla (kameraya geç → çek → internete dön) 5 sn video + fotoğraf alınır; "Paragraf için video ve fotoğraf çekimi başarıyla yapıldı" denir; internet gelince "Bu paragraf hangi sorular için?" sorulur, numaralar söylenip Tamam denir. Paragraf tek başına Gemini'ye gitmez | ✅ |
| Kamerayla çekilmiş paragraf varken soru gelir (sesle okunan ya da kamerayla çekilen) | Paragrafın fotoğrafı ve videosu o numaralı her soruyla gider (önce paragraf, sonra soru; mesajdaki not sırayı söyler); soru yazı olarak "paragraf görüntü olarak veriliyor" der. Cevaplanan soru listeden düşer; hepsi cevaplanınca paragrafın video dosyası silinir | ✅ |
| Paragraf + soru görüntüleri 14 MB'ı aşıyor | Önce sorunun videosu önceliklidir; sığmazsa paragrafın videosu atılır, fotoğrafı yine gider (istek reddedilmesin) | ✅ |
| Paragraf çekilemedi | Neden söylenir, internet geri getirilir ve paragraf V3'teki gibi sesle okutulur | ✅ |
| Paragraf çekildikten sonra (numaralar sorulurken) kesinti olur | Görüntüler kaybolmaz: onarımdan sonra "Paragrafın video ve fotoğrafı alındı. Hangi sorulara ait olduğunu söyleyip Tamam deyin" denir | ✅ |
| Program, kamerayla çekilmiş paragraf varken kapanıp açılır | Yalnız paragrafın FOTOĞRAFI geri gelir ("Ortak paragraf fotoğraf olarak korundu…"); videosu telefonun önbelleğinde durduğu için kapanmada silinir. Sonraki sorular fotoğrafla gider | ✅ (⚠️ video kaybolur) |
| Kullanıcı soruyu yanlış okudu: "Soruyu iptal et" | Okunan metin ve ses kaydı silinir, "Okunan soru silindi" denir, soru baştan okunur (kamera sorusu açıksa "silinecek soru yok" der ve kamera yeniden sorulur). Soru olarak Gemini'ye gitmez | ✅ |
| Kullanıcı paragrafı yanlış okudu ya da çekti: "Paragrafı iptal et" | Okunan / numaraları beklenen paragraf (ve kamerayla çekilmişse görüntü dosyası) bırakılır; okunmaya hiç başlanmamışsa kayıtlı ortak paragraf silinir; hiçbiri yoksa "Silinecek ortak paragraf yok" der. Sonra bu soru için kamera yeniden sorulur. Paragraf okunurken, numaralar beklenirken ve "Paragrafı kamera ile çekmek ister misiniz?" sorusunda çalışır | ✅ |
| Eski bir cevap yeniden dinlenmek istendi: "N. sorunun cevabını tekrarla" | Yalnız o cevap okunur; kayıt yoksa "N numaralı soru için kayıtlı cevap yok" der. Soru dinlenirken ve kamera sorusu açıkken çalışır, ardından kamera sorusu yeniden gelir | ✅ |
| Kamera sorusuna doğal söyleyişle yanıt ("çekelim", "olur", "sesle okuyayım", "istemiyorum") | Evet/hayır olarak anlaşılır; "soruyu iptal et" gibi komutlar yanıt sayılmaz (komut çalışır) | ✅ |
| Kameralı akışta rastgele kesintiler (kulaklık, arama, internet, kestirme, Gemini, okuma, kamera takılması, elle duraklatma…) | `CameraChaosTests`: 150 gerçek zamanlı + 250 hamle tohum; değişmezler: dinleyici açık, kamera meşgul kalmaz, sahipsiz paragraf/numara beklemesi yok, test bitince çekilmiş hiçbir video dosyası kalmaz, anons/kestirme sayısı sınırlı | ✅ |
| Kamera sorusuna olumsuz söz: "çekmiyorum", "çekmem", "kamerayı kullanmayalım", "kamera olmasın", "gerekmez" | HAYIR sayılır, kamera açılmaz, hücresel kesilmez. (Eskiden bulanık eşleşme yüzünden "çekmiyorum" EVET sayılıyordu.) Evet yalnız tam eşleşmeyle; bulanık eşleşme yalnız hayır yönünde | ✅ |
| Kamera sorusuna "çekmek istiyorum", "çekmeyi isterim", "kamerayı kullan" | EVET sayılır (eskiden "çekmek" hayır sözüne benzediği için anlaşılmıyordu) | ✅ |
| Testi bitirme onayına "bitirmek istiyorum" / "sonlandırmak istiyorum" | EVET (eskiden "bitirme"ye benzediği için HAYIR sayılıyordu); "bitirmiyorum", "bitirmeyelim", "bitirmek istemiyorum" hayır | ✅ |
| Menüde "bitirme, devam edelim" | Devam sayılır (olumsuz "bitirme" bitirme isteği değildir) | ✅ |
| Kullanıcı programı duymadı/anlamadı: "anlamadım", "duyamadım", "bir daha söyle", "yeniden söyle", "tekrar söyle", "ne dedin"… (her aşamada: soru, onay, menü, numara, paragraf, başlangıç, kamera sorusu) | Program son sözünü (cevap + kamera sorusu gibi son iki anons) aynen yeniden söyler, aynı kipte dinler; cevap sayılmaz, hiçbir durum bozulmaz | ✅ |
| Program kullanıcıyı anlamadı | "Anlayamadım…" der ve sorusunu yeniden sorar (menü, onay, kamera, numara, paragraf numarası, komut) | ✅ |
| Menüde "Tekrar" ile "tekrar söyle" | "Tekrar" cevapları yeniden oynatır; "tekrar söyle" / "anlamadım" menüyü yeniden söyler | ✅ |
| Menüde "bitirmek istemiyorum", "devam etmeyelim", "tekrar etme"; başlangıçta "devam etmeyelim", "yeni başlamayalım" | Hiçbir seçenek seçilmez: "Anlayamadım" denip yeniden sorulur (eskiden "bitirmek istemiyorum" testi bitirirdi) | ✅ |
| Komut gibi duyulan olumsuz söz: "testi bitirme", "sınavı bitirmem", "cevapları tekrarlamayın", "son cevabı okuma" | Komut sayılmaz (eskiden yakın sesli eşleşmeyle "testi bitirme" bitirme komutu sayılırdı) | ✅ |
| Numara beklenirken (söylenmediği için) "soruyu iptal et" | Bekleyen soru bırakılır, "Okunan soru silindi" denir, boşuna sıradaki numarayla Gemini'ye gitmez | ✅ |
| "Soruyu iptal et" bozuk okunur ("soruyu iptalet") | Soru metnine karışıp sessizce birikmez: "Komutu anlayamadım, lütfen bir kez daha söyleyin" denir, söz atılır (yalnız iptal fiili + soru/paragraf sözcüğü birlikteyse; tek başına "iptal et" soru metni olabilir) | ✅ |
| "Yardım" / "komutlar neler" | Komutlar sayılır; kamera sorusundayken kamera sorusu yeniden sorulur, evet/hayır ve menüde sorunun kendisi yeniden söylenir; durum bozulmaz | ✅ |
| "Ne duydun" | Soru metni okunur ("Duyduğum: …"), okuma kaldığı yerden sürer; metin yoksa "Henüz bir şey duymadım", soru dinlenmiyorsa "Şu anda dinlenen bir soru metni yok" | ✅ |
| "Son cümleyi sil" (soru okunurken) | Son söz silinir ve silinen (ilk 8 sözcük) söylenir, önceki metin korunur; silinecek bir şey yoksa "Silinecek cümle yok"; "…son cümleyi sil, Cevapla" soru gibi gitmez | ✅ (ses kaydı silinmez) |
| "Durum" / "kaç soru cevaplandı" | Cevap sayısı, sıradaki numara; kulaklık, internet ve pil yalnız biliniyorsa söylenir | ✅ |
| "Cevapsız soruları söyle" | Atlanan numaralar sayılır; yoksa "Cevapsız soru yok", cevap yoksa "Henüz cevaplanan soru yok" | ✅ |
| "Soruyu iptal et" ama okunmuş soru yok | "Silinecek soru yok" denir ("Okunan soru silindi" yanlış olurdu) | ✅ |
| Her aşamada bilgi | Soru ve paragraf için: "Kameraya geçiliyor", "Kamera hazır… kadraja alın", "Çekim başarıyla yapıldı, internete geçiliyor", "İnternet geldi, Gemini'ye gönderiliyor", cevap okunur | ✅ |
| Program kapanıp açıldı (kamera sorusu açıkken) | Önceki cevap yeniden okunmaz (yarım iş kaydı kamera sorusundan önce silinir); "Sistem hazır" denip kamera sorulur | ✅ |
| Kestirmeler Wi-Fi / hücreseli değiştirmez ya da onay sorar | Cihazda denenmedi: Ayarlar > Kamera > **Kamerayı dene** ile sınanmalı | ⚠️ 📱 |
| Komşu sorular kadrajda yarım görünür | Gemini'ye yok sayması söylenir; numara görüntüden okunur, okunamazsa sıra numarası | ✅ (cihazda denenmedi) |

## 7. Bekleyen kararlar ve öneriler

1. ~~Gemini'nin takılması~~ **Yapıldı:** 180 sn sınır, 30 sn'de bir "cevap bekleniyor", "soru gönderildi" anonsu. Ayrıntı: §2.
2. **Zaman aşımında ses kaydı:** ilk profil zaman aşımına uğrarsa sıradaki profile yalnız metinle (kayıtsız) gitmek; doğruluğu biraz düşürür, ama yavaş hatta cevabı kurtarır. Karar sizin.
3. **Kestirmeler "Kapatıldı" otomasyonu:** gerçek telefonda denenmeli (kaydırıp kapatınca açılıyor mu, kilitliyken ne oluyor; Testi Bitir sonrası kaydırıp kapatınca da açılıyor mu; Kestirmeler'e bilerek geçerken pano işareti sayesinde geri çekmiyor mu).
4. **Cihaz günlüğü:** ilk beklenmedik kapanmadan sonra "Tanı ve günlük"ten günlük istenmeli; neden tahmini günlüğün ipucuna dayanır, kesin değildir.
5. ~~Ses seviyesi~~ **Yapıldı (Tur 6):** açılışta ve dakikada bir çıkış sesi <%10 ise söylenir (`Say.lowVolume`); sesle "sesi aç" ile artırılabilir (cihazda doğrulanmadı).

## 8. Tur 6: sesli rapor ve ayar komutları, sınav boşlukları

| Senaryo | Program ne yapar | Test |
|---|---|---|
| Sınavda ses çok kısık (<%10) | Söyler (kulaklıktan duyulacak kadar sesle); oturum engellenmez; ses yükselince uyarı kalkar | `testLowVolumeAtStartWarnsButDoesNotBlockTheSession`, `testLowVolumeWarningClearsWhenTheVolumeRises` |
| Sesi okuyamıyor (simülatör, izin yok) | Yanlış alarm vermez; "okunamadı" der | `testUnknownVolumeGivesNoWarning`, `testVolumeUnreadableIsSaidSo` |
| "Sesi aç" ama iOS değiştirmedi | Ses yeniden okunur; aynıysa "değiştirilemedi, ses tuşlarını kullanın" | `testVolumeNotChangedByIOSIsSaidSo` |
| Soru okunurken "internet raporu" (tek başına) | Rapor söylenir, okunan soru metni ve kip bozulmaz, Gemini'ye gitmez | `testReportInTheMiddleOfAQuestionKeepsTheQuestionText` |
| Soru başlığı "Bellek nedir / Ses nedir" | Komut sayılmaz, soru olarak gider | `testQuestionTitlesAndNegatedOrVagueWordsAreNotReportsOrSettings` |
| "Sesi kısma" / "kamera sorusunu kapatma" | Komut sayılmaz | aynı test |
| Kamera sorusunda "kamera sorusunu kapat" | Kapatılır, evet/hayır beklenmez, soru sesle okunur | `testTurningTheCameraQuestionOffAtTheCameraQuestionLeavesIt` |
| Kamera çekerken "kalite yüksek yap" | "Kamera çalışırken ayar değiştirilemez" | `testCameraSettingsAreRefusedWhileTheCameraWorks` |
| Yatay kadrajda "yönü dik çevir" | Nedeniyle reddedilir | `testFrameAndOrientationFollowEachOther` |
| Aynı numaralı soru ikinci kez cevaplanır | "Önceki cevap yenisiyle değiştirildi" | `testAnsweringTheSameNumberAgainSaysTheOldAnswerWasReplaced` |
| Test biter, cevapsız numaralar var | "Test tamamlandı. N cevap kaydedildi. Cevabı olmayan sorular: …" | `testTestCompletionTellsWhichQuestionsHaveNoAnswer` |
| Numara beklerken "5. sorunun cevabını tekrarla" | Cevap okunur, sonra numara yeniden sorulur; tutulan soru korunur | `testRepeatNumberWhileTheQuestionNumberIsAskedReadsItAndAsksTheNumberAgain` |
