# Sesli Kontrol: öngörülen prosedür ve uyum tablosu

Bu belge, programın sesle nasıl işlemesi gerektiğini adım adım yazar; her adımın karşılığı kodda ve testte aranır. Davranışı değiştirirken
önce burası güncellenir. **Cihazda denenmemiştir**; testler sahte mikrofon, kulaklık ve ağ ile çalışır.

## Akış

1. **Açılış.** İzinler, çevrimdışı dikte, kulaklık + mikrofon, internet, Gemini denetlenir. Önceki klasörde cevap varsa: "Önceki kayıtta N cevap var,
   sıradaki soru M. Devam mı, yeni sınav mı?" (devam / yeni; cevapsızsa bir hatırlatma, sonra 12 saatten yeniyse devam). Sonra "Hazır".
   Kamera sorusu açıksa kontrol listesine "Kamera ayarları" maddesi eklenir; kamera adı ya da kestirme adları eksikse "Hazırım" anonsu bunu söyler
   ("Kamera ayarları eksik olduğu için sorular sesle okunacak") ve oturum V3 gibi çalışır.
2. **Tek soru.** Soru numarasıyla okunur → "Cevapla" ya da "Gönder" → numara okunmadıysa "Lütfen okuduğunuz sorunun numarasını söyleyin" →
   "Soru gönderildi, cevap bekleniyor" → cevap kulaklıktan okunur ve `soru_N` + `cevaplar.txt` olarak kaydedilir → "Lütfen sonraki soruyu okuyun".
2a. **Sürüm 4: kamera ile tek soru.** "Lütfen sonraki soruyu okuyun" yerine her soru sınırında: "Bu soruyu kamera ile çekip göndermek ister misiniz?"
   (evet / hayır; anlaşılmazsa "Anlayamadım…", yine olmazsa güvenli varsayılan: sesle okuma). **Hayır** → 2. adımdaki gibi sesle. **Evet** →
   "Kameraya geçiliyor" → `Kameraya Geç` kestirmesi (hücresel kapanır, kameranın Wi-Fi'si) → kameraya bağlanma (olmazsa `Kamera Bağlantısını Onar`,
   en çok 2 kez) → sesle konumlandırma (ortadaki soru; 30 sn'de yine de çeker) → fotoğraf + kısa video → kamera kapanır → `Hücresele Geç` kestirmesi
   (Wi-Fi kapanır) → internet gelince fotoğraf + video Gemini'ye gider → cevap 2. adımdaki gibi okunur ve kaydedilir → sıradaki soru için yine sorulur.
   Çekim olmazsa nedeni söylenir ve soru sesle okunur; internet gelmezse V3'ün internet onarımı çalışır ve çekim telefonda bekler (gelince bir kez
   yeniden gönderilir; test bitince atılır ve cevapsız kalan soru sayısı yazılır). Arama / kulaklık kesintisi kamerayı kapatır, onarımdan sonra kamera
   sorusu yeniden sorulur. İlk kullanımdan önce Ayarlar > Kamera > "Kamerayı dene" ile iOS yerel ağ izni alınır.
   Kamera sorusu açıkken V3 komutları da çalışır ("Testi bitir" onay ister ve kamera başlamaz; vazgeçilirse soru yeniden sorulur; "Son cevabı tekrarla" okur
   ve yeniden sorar). Kamera sorusunda "bitir" ya da "devam" evet sayılmaz (yalnız evet / tamam / çek gibi sözler). "Devam" ya da "Yeni sınav" seçiminden
   ve kesinti sonrası sürdürmeden sonra da ilk soru için kamera sorulur. Çekilen soruya Gemini 3 dk yanıt vermezse çekim bir kez daha gönderilir; yine
   yanıt yoksa atılır, söylenir ve kamera sorusu yeniden sorulur. Kamera sorusunu beklemeden soru okunursa (9+ sözcük) sesle okuma seçilmiş sayılır.
   Sesle kaydedilmiş ortak paragraf çekilen soruyla birlikte Gemini'ye gider. Kamera akışı kesilirse telefon kameranın Wi-Fi'sinde kalmış olabilir:
   onarımdan sonra internet yoksa `Hücresele Geç` kestirmesi çalışır, sonra bekleyen çekim gönderilir ya da kamera sorulur.
   **Her aşamada kısa bilgi verilir:** "Kameraya geçiliyor" → "Kamera hazır, soruyu kadraja alın" → "Soru için video ve fotoğraf çekimi başarıyla
   yapıldı. Kamera kapatıldı, internete geçiliyor" → "İnternet geldi. Soru Gemini'ye gönderiliyor, cevabı bekleyin" → cevap okunur.
2b. **Sürüm 4: kamera ile ortak paragraf.** Kamera sorusunda (ya da sesle okuma seçildikten sonra) "Ortak paragraf" denirse program "Paragrafı kamera ile
   çekmek ister misiniz?" diye sorar. **Hayır** → 3. adımdaki gibi paragraf sesle okunur. **Evet** → paragraf OKUNMAZ: kameraya geçilir, kadraja alınır
   ("Ortak paragrafı kadraja alın"), 5 sn video + fotoğraf çekilir, "Paragraf için video ve fotoğraf çekimi başarıyla yapıldı" denir, internete dönülür
   ve "Bu paragraf hangi sorular için? Numaraları söyleyip Tamam deyin" diye sorulur → "5, 6, 7" + Tamam → "Ortak paragraf 5, 6 ve 7 için kaydedildi" →
   bu soru için kamera yeniden sorulur. Paragraf tek başına Gemini'ye gitmez; paragrafın fotoğrafı ve videosu o numaralı her soruyla (sesle okunan ya da
   kamerayla çekilen) birlikte gider, hepsi cevaplanınca bırakılır. Paragraf ve soru görüntüleri birlikte 14 MB'ı aşarsa paragrafın videosu atılır
   (fotoğrafı gider). Video süresi Ayarlar > Kamera > "Soru videosu" ayarındandır. Uygulama kapanıp açılırsa paragrafın yalnız fotoğrafı korunur.
3. **Ortak paragraf.** "Ortak paragraf" (duraklayın) → "Lütfen ortak paragrafı okuyun, bitince Tamam deyin" → paragraf + "Tamam" → "Paragraf metnini
   aldım, hangi sorular için? Numaraları söyleyip Tamam deyin" → "5, 6, 7" → "Ortak paragraf 5, 6 ve 7 için kaydedildi. Şimdi soruları okuyabilirsiniz" →
   her soru (numarası listede ise) paragrafla birlikte gider; hepsi cevaplanınca paragraf bırakılır.
4. **Komutlar** (tek başına): "Testi bitir / Sınavı bitir / Bitir" → onay sorulur; "Son cevabı tekrarla" → son cevap yeniden okunur;
   **"Cevapları tekrarla"** → bütün cevaplar baştan okunur (soru dinlenirken, bitirme onayı beklenirken, eksik numara beklenirken ve paragraf numaraları
   beklenirken söylenebilir; test sürer, oturum kapanmaz).
   **"N. sorunun cevabını tekrarla"** (ör. "beşinci sorunun cevabını tekrarla", "soru 12 cevabı tekrar") → yalnız o sorunun cevabı okunur; kayıt yoksa
   "N numaralı soru için kayıtlı cevap yok" denir; ardından dinlemeye dönülür (soru dinlenirken ve kamera sorusu açıkken söylenebilir).
   **"Soruyu iptal et"** → o ana kadar okunan soru metni ve ses kaydı silinir, "Okunan soru silindi" denir ve soru baştan okunur (kamera sorusu açıkken
   silinecek soru olmadığı söylenir ve kamera sorusu yeniden sorulur).
   **"Paragrafı iptal et" / "Ortak paragrafı iptal et"** → okunmakta ya da numaraları beklenen paragraf (ve kamerayla çekilmişse görüntüleri) bırakılır;
   paragraf okunmaya hiç başlanmamışsa kayıtlı ortak paragraf silinir; ikisi de yoksa "Silinecek ortak paragraf yok" denir. Paragraf okunurken,
   numaraları beklenirken ve "Paragrafı kamera ile çekmek ister misiniz?" sorusu açıkken söylenebilir. Sonra bu soru için kamera yeniden sorulur.
   Numarası söylenmediği için numara beklenen soru da "soruyu iptal et" ile bırakılır (boşuna sıradaki numarayla Gemini'ye gitmez).
   Kamera sorusuna ("Bu soruyu kamera ile çekmek ister misiniz?") verilen yanıtlar geniş tutuldu: evet / olur / tabii / çekelim / çekmek istiyorum /
   kamerayla / kamerayı kullan, hayır / istemiyorum / çekmiyorum / çekme / sesle / okuyayım / kamera olmasın / gerekmez gibi.
   **Güvenli evet kuralı:** evet/hayır sorularında "evet" yalnız TAM eşleşmeyle (ya da aynı sesle: p/b, t/d, k/g, s/z) anlaşılır; tek harf farklı
   bulanık eşleşme yalnız HAYIR yönünde sayılır. Çünkü Türkçede olumsuzluk eki tek harf farkıdır ("çekiyorum" / "çekmiyorum", "bitirme" / "bitirmek") ve
   yanlış evet kamerayı açar (hücreseli keser) ya da testi bitirir; yanlış hayır zararsızdır. Olumsuz biçimler listede açıkça yazılıdır ve testle
   denetlenir (her olumlu/olumsuz ikiz için). "Bitirmek istiyorum" onay sorusunda evet, menüde "bitirme, devam" devam sayılır.
5. **Cevapları okuma ve menü.** Cevaplar numara sırasıyla, aralarında Tekrar boşluğu (varsayılan 3 sn) okunur. Bitince: "N sorunun cevabı okundu. Ne yapmak
   istersiniz? Teste kaldığınız yerden devam etmek için **Devam**, cevapları yeniden dinlemek için **Tekrar**, testi tamamlamak için **Bitir** deyin."
   Devam → kalınan yere dönülür (soru / eksik numara / paragraf numaraları); Tekrar → yeniden okunur ve yine sorulur; Bitir → "Test tamamlandı. N cevap
   kaydedildi." ve test biter. Anlaşılmazsa ya da sessizlikte bir kez hatırlatılır; yine olmazsa varsayılan: bitirme isteğiyle gelindiyse test tamamlanır,
   yalnız tekrar istendiyse teste devam edilir. (Ayar: "Testi bitirince cevapları oku", açık; kapalıysa onaydan sonra test doğrudan tamamlanır.)
6. **Kendini onarma.** Kulaklık/mikrofon/internet kopunca susulur, onarılır, söylenir, kaldığı yerden devam edilir (ayrıntı: SURUM3.md, SENARYOLAR.md).

## Bekleme durumları (her biri: sesli istem, kabul edilen sözler, anlaşılmazsa ne olur, sınır)

| Durum | Sesli istem | Kabul edilen | Anlaşılmazsa / sessizlikte | Sınır |
|---|---|---|---|---|
| soru | "Hazır" / "Lütfen sonraki soruyu okuyun" | soru + Cevapla/Gönder; komutlar | 30 sn sessizlikte dinleme sessizce yenilenir | yok |
| ortak paragraf | "Lütfen ortak paragrafı okuyun, bitince Tamam deyin" | paragraf + Tamam / Tamamlandı; "paragrafı iptal et" (son sözde) | — ("tamam" cümle içinde geçerse 1,5 sn sabit kalmadan bitmez) | yok |
| ortak paragraf: kamera mı, ses mi (yalnız kamera açıkken) | "Ortak paragraf. Paragrafı kamera ile çekmek ister misiniz?" | evet / hayır; "paragrafı iptal et", "soruyu iptal et", "N. sorunun cevabını tekrarla", "cevapları tekrarla" | anlaşılmazsa ya da sessizlikte bir kez daha sorulur; olmazsa sesle okuma | 1 hatırlatma |
| paragraf numaraları | "Paragraf metnini aldım, hangi sorular için?" | numaralar + Tamam / Cevapla / Gönder; "cevapları tekrarla"; "paragrafı iptal et" | kısa yeniden sorma; ekranda ne duyulduğu yazar | 2 yeniden, sonra paragraf sıradaki soruya bağlanır ve söylenir |
| eksik soru numarası | "Lütfen okuduğunuz sorunun numarasını söyleyin" | numara, "sıradaki"; "cevapları tekrarla"; "soruyu iptal et" | numara olmayan kısa söz 4 sn sonra, sessizlik 30 sn sonra yeniden sorulur; ekranda ne duyulduğu yazar | 2 hatırlatma, sonra sıradaki numara |
| testi bitirme onayı | "Testi bitirmek istiyor musunuz?" | evet / hayır (komutu yeniden söylemek de evet); "cevapları tekrarla" | anlaşılmazsa bir kez daha sorulur; cevapsızlıkta test sürer | 1 hatırlatma |
| cevap okuma sonrası menü | "N sorunun cevabı okundu… Devam, Tekrar ya da Bitir deyin" | devam / tekrar / bitir ve doğal söyleyişler ("teste devam edelim", "cevapları yeniden oku", "testi tamamla") | anlaşılmazsa 4 sn sonra, sessizlikte 30 sn sonra bir kez hatırlatılır; sonra varsayılan (bitirme isteğiyse tamamla, değilse devam) | 1 hatırlatma |
| devam mı, yeni mi | "Önceki kayıtta N cevap var… Devam mı, yeni sınav mı?" | devam / yeni | 1 hatırlatma, sonra 12 saat kuralı | 1 |

**Tek seferde anlama.** Söz önce tanıyıcının en iyi okumasıyla çözülür; çözülemezse tanıyıcının son sözcükler için verdiği alternatif okumalar denenir
(cihaz bunları veriyorsa). Sözcükler ses anahtarıyla karşılaştırılır (b/p, d/t, g/k, s/z karışması: "peş" = beş, "yeti" = yedi, "dörd" = dört, "pitir" = bitir);
beş harften uzun sözcüklerde tek harf farkı kabul edilir. Komut sözlükleri birbirine yaklaşmaz (testle denetlenir). Paragraf numaralarında alternatif okuma yalnız
numara EKLER, duyulan numarayı değiştirmez ya da silmez. Tanıyıcıya ipucu olarak komut, menü ve sayı sözcükleri verilir.

**Anlayamayınca susmaz.** Program yalnız şu durumlarda sessiz bekler: soru okunurken ve cevap beklenirken. Diğer her durumda ne duyduğunu ve ne yapmasını
beklediğini söyler:

| Durum | Program ne yapar |
|---|---|
| Komut gibi duyuldu ama tanınmadı ("testi bit", "soruyu iptalet", "paragrafı iptalet") | 2,5 sn sonra "Komutu anlayamadım. Lütfen komutu bir kez daha söyleyin." der; söz metinden **atılır** (soruya karışmaz); ikinci kez olursa komutları sayar; ekranda "Duyulan: …" |
| Soru metni geldi, 20 sn hiçbir şey söylenmedi, "Cevapla" yok | "Cevapla komutunu duyamadım. Soru bittiyse lütfen Cevapla deyin." (bir soruda en çok 2 kez; okunan metin korunur) |
| Paragraf numaraları söylendi, "Tamam" yok | 4 sn sonra "5, 6 ve 7 numaralı sorular için duydum. Doğruysa Tamam deyin…"; yine denmezse numaralar kabul edilir |
| Paragraf numaraları anlaşılmadı ya da 30 sn sessizlik | "Numaraları anlayamadım…" (en çok 2 kez, sonra sıradaki soruya bağlanır) |

**Komut yalnız son sözden aranır.** Konuşmada 1 sn sessizlik yeni bir söz başlatır. Önceki anlaşılmayan söz ("testi bit") metinde kalsa bile sonraki doğru söz
("testi bitir") tanınır; önceden metnin tamamı "testi bit testi bitir" okunduğu için art arda tekrar gerekiyordu. Tek sözcüklük son söz ancak öncesi de komut
denemesiyse komut sayılır (soru ortasındaki duraklamadan sonra gelen "tekrar" komut olmasın). Tanıyıcının böldüğü komut ("tekrar la", "testi bit ir") birleştirilir.

**Kipe göre ipucu.** Evet/hayır ve devam/tekrar/bitir sorularında yalnız o sözcükler, numara beklerken yalnız sayılar, paragraf numaralarında sayılar ve Tamam/Cevapla
tanıyıcıya ipucu verilir (dar liste tanıyıcıyı o sözcüklere yöneltir). Soru dinlerken geniş liste kullanılır. Cihazda ölçülmedi.

Kabul edilen numara söyleyişleri: "yedi", "7", "yedinci", "7. soru", "soru yedi", "5, 6, 7", "beş altı yedi", "5. soru, 6. soru", "beşten yediye kadar", "5-7",
bitişik "567" (üç haneli ve 150'nin üstündeyse tek tek rakam sayılır).

## Bilinen eksikler

- Paragraf okunurken yalnız "paragrafı iptal et" çalışır; diğer komutlar (testi bitir, cevapları tekrarla…) paragrafa karışır, çünkü paragraf serbest metindir.
- "Soruyu iptal et" yalnız soru dinlenirken (okunan metni siler) anlamlıdır; kamerayla çekilmiş soru Gemini'ye gittikten sonra geri alınamaz.
- Komut denemesi yalnız çok katı bir kuralla ("bütün sözcükler komut sözcüğü, en az biri fiil/işaret") algılanır; ondan uzak bir yanlış okuma (komutla ilgisiz sözcükler) hâlâ soru metni sayılır ve sessiz birikir.
- "Testi Bitir" **düğmesi** cevapları kendiliğinden okutmaz; yalnız sesle bitirme okutur (düğme sonrası ana ekrandaki tekrar düğmesi kullanılır).
- "Cevapları tekrarla" paragraf okunurken ve "Devam mı, yeni sınav mı?" sorusu beklenirken çalışmaz.
- Tanıyıcının alternatif okumaları cihaz ve modele bağlıdır; vermiyorsa yalnız en iyi okuma ve yakın ses toleransı kullanılır (cihazda görülmedi).
- Gerçek dikte çıktısının biçimi (rakam mı, sözcük mü, bitişik mi) cihazda görülmedi; anlaşılmayan söz ekranda "Duyulan: …" olarak yazar, günlükte `[soru]` / `[paragraf]` satırlarında durur.
