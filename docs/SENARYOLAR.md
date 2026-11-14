# Olumsuz durum senaryoları ve önlemleri (Sürüm 3)

Her satır: ne olabilir → uygulama ne yapar → hangi testle sınandı. **Cihazda doğrulanamayanlar** ve **açık kalan** maddeler ayrıca işaretlidir;
test yeşil olması, sahada aynen böyle çalıştığının kanıtı değildir (testler sahte kulaklık/mikrofon/ağ ile çalışır, gerçek Bluetooth ve iOS ses servisi yoktur).

Durum: ✅ önlem var ve testli · 🛠 bu incelemede bulundu ve düzeltildi · ⚠️ açık (karar/cihaz denemesi gerekiyor) · 📱 yalnız cihazda doğrulanabilir

## 1. Kulaklık ve mikrofon

| Ne olabilir | Önlem | Durum |
|---|---|---|
| Kulaklık koptu (okurken, dinlerken, Gemini beklerken) | Ses anında susar, mikrofon kapanır, iş durur; hiçbir şey telefon hoparlöründen çalınmaz (KURAL 1). Yol dönünce 1 sn sabit kalırsa devam; 20 sn dönmezse "çıkışı kulaklığa al" → Bluetooth → sıfırlama kestirmesi. Duyulamayan cevap devamda yeniden okunur | ✅ 📱 (iOS bildirimi gelmeden önceki kısa pencere ölçülemez) |
| Yaka mikrofonu çıktı / ses telefonun kendi mikrofonuna düştü | Aynı duraklama; "mikrofon alıcısı takılı ama yola girmiyor" durumunda Kestirme çalışmaz (kulaklığı koparırdı), mikrofon yeniden seçilir | ✅ |
| Çıkış kulaklıktan telefona düştü ama kulaklık bağlı | "Çıkışı kulaklığa al" kestirmesi 1 sn içinde, bir oturumda en çok 6 kez | ✅ |
| Mikrofon donuyor (tampon gelmiyor) | Nöbetçi 0,5 sn'de yakalar, dinlemeyi yeniden kurar, yarım metin korunur; art arda olursa Kestirmeler | ✅ |
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
| Soru giderken bağlantı düştü | Soru "gitmedi" işaretlenir, bağlantı onarılır, "soruyu yeniden oku" denir | ✅ (kullanıcı isteği: otomatik yeniden gönderim bekliyor, bkz. §6) |
| Kota / anahtar reddi / sunucu hatası / boş yanıt | 4 profil sırayla; arızalı profil dinlenir, cevap yedekten gelirse sebebi kırmızı kutuda | ✅ |
| İçerik engeli, harcama sınırı, çok büyük istek | Başka modele geçilmez; ne olduğu söylenir, dinlemeye dönülür | ✅ |
| **Gemini takıldı** (bağlantı var, cevap gelmiyor) | Son profil dışında 40 sn; **son profilde 120 sn + 3 sunucu yeniden denemesi → en kötü durumda yaklaşık 8–10 dk sessiz bekleme** | ⚠️ açık |
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
| Gemini "Soru: 3, …" / "Soru No 3 - …" / ```` ``` ```` çitli / başlıklı yazar | Numara ve şık çözülür; çözülemezse ham satır numarayla okunur | 🛠 |
| Soru numarası okunmadı / çakıştı | Önce okunan, sonra Gemini'nin duyduğu, sonra sıradaki; aynı numaralı eski dosya silinir | ✅ |
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
| Telefon ısınır | Yalnız özette gösterilir; canlı uyarı yok | ⚠️ |
| iOS uygulamayı kapatır (bellek/çökme) | Algılanmıyor; sesli bir bildirim imkânı yok | ⚠️ |
| Düşük Güç Modu | Ele alınmıyor | ⚠️ düşük öncelik |

## 6. Durum makinesi taraması (kaos testi)

`Tests/ChaosTests.swift`: tohumlu rastgele 8–16 olaylık diziler (kulaklık/mikrofon kopma ve dönüşü, arama, internet, tanıma hatası, ses motoru,
mikrofon tamponu, Kestirme sonuçları, Gemini hata/takılma, okuma hatası/takılma, elle duraklatma, şarj, ağ yolu, uygulamanın öne gelmesi).
Her adımda "dinliyor aşamasında dinleyici çalışıyor" değişmezi; dizi sonunda her şey düzeltilip **oturumun kendiliğinden dinlemeye dönmesi**,
Kestirme ve anons sayılarının sınırlı kalması aranır. İki zaman kipi vardır: gerçek zamana yakın (yarım saniyelik adım) ve hamle (zaman tek seferde geçer).

**Bulunan ve düzeltilen takılma:** kuyruğa alınmış ama başlamadan iptal edilen bir onarım görevi, çalışınca aşamayı "onarılıyor" yapıp iptal
olduğunu görünce çıkıyor, oturum kalıcı olarak "onarılıyor"da kalıyordu (kulaklık ve mikrofon düzelse de dinlemeye dönülmezdi). Mikrofon donması,
yol bildirimi ve onarım sınırı aynı anda üst üste gelince tetikleniyordu. Gerçek hayatta pencere dardır ama sonucu sessiz ve kalıcıdır.

## 7. Bekleyen kararlar ve öneriler

1. **Gemini'nin takılması:** toplam bekleme sınırı (öneri ≈ 150 sn), 20 sn'de bir kısa "cevap bekleniyor" ve süre dolunca "Gemini cevap vermedi, soruyu yeniden oku". İstediğiniz 1. madde ("soru gönderildi, cevap bekleniyor") ile aynı koda dokunur; birlikte yapılması önerilir.
2. **Zaman aşımında ses kaydı:** ilk profil zaman aşımına uğrarsa sıradaki profile yalnız metinle (kayıtsız) gitmek; doğruluğu biraz düşürür, ama yavaş hatta cevabı kurtarır. Karar sizin.
3. **Isınma uyarısı:** `thermalState` "ciddi" olunca bir kez sesli uyarı ("Telefon ısındı, serin tutun").
4. **Beklenmedik kapanma:** oturum açıkken bayrak tutulur; uygulama yeniden açıldığında bayrak duruyorsa "önceki oturum beklenmedik kapanmış" yazılır/söylenir (sebebi öğrenmek için). Kapanmanın kendisi engellenemez.
5. **Ses seviyesi:** açılışta çıkış sesi çok düşükse (<%10) kullanıcıya söylemek.
