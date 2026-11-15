# Sesli Kontrol: öngörülen prosedür ve uyum tablosu

Bu belge, programın sesle nasıl işlemesi gerektiğini adım adım yazar; her adımın karşılığı kodda ve testte aranır. Davranışı değiştirirken
önce burası güncellenir. **Cihazda denenmemiştir**; testler sahte mikrofon, kulaklık ve ağ ile çalışır.

## Akış

1. **Açılış.** İzinler, çevrimdışı dikte, kulaklık + mikrofon, internet, Gemini denetlenir. Önceki klasörde cevap varsa: "Önceki kayıtta N cevap var,
   sıradaki soru M. Devam mı, yeni sınav mı?" (devam / yeni; cevapsızsa "ikinci defa soruyorum", sonra "üçüncü defa soruyorum", sonra 12 saatten yeniyse devam). Sonra "Hazır".
   Kamera sorusu açıksa kontrol listesine "Kamera ayarları" maddesi eklenir; kamera adı ya da kestirme adları eksikse "Hazırım" anonsu bunu söyler
   ("Kamera ayarları eksik olduğu için sorular sesle okunacak") ve oturum V3 gibi çalışır.
2. **Tek soru.** Soru numarasıyla okunur → "Cevapla" ya da "Gönder" → numara okunmadıysa "Lütfen okuduğunuz sorunun numarasını söyleyin" →
   "Soru gönderildi, cevap bekleniyor" → cevap kulaklıktan okunur ve `soru_N` + `cevaplar.txt` olarak kaydedilir → "Lütfen sonraki soruyu okuyun".
2a. **Sürüm 4: kamera ile tek soru.** "Lütfen sonraki soruyu okuyun" yerine her soru sınırında: "Bu soruyu kamera ile çekip göndermek ister misiniz?"
   (evet / hayır; cevap gelmezse "Cevap vermediniz, ikinci defa soruyorum", sonra "üçüncü defa"; üçüncüde de gelmezse kameraya kendiliğinden geçilir; anlaşılmazsa "Anlayamadım…"). **Hayır** → 2. adımdaki gibi sesle. **Evet** →
   "Soru mu, ortak paragraf mı çekeceksiniz? Birinci seçenek soru, ikinci seçenek paragraf." (bir / birinci / 1 / soru → soru; iki / ikinci / 2 / paragraf → ortak paragraf;
   cevap gelmezse "ikinci", "üçüncü defa soruyorum", üçüncüde de gelmezse soru olarak çekilir; Ayarlar'dan kapatılabilir). Ortak paragraf seçilirse çekim aynı
   bağlantı düzeniyle yapılır, ardından "hangi sorular için?" sorulur (3. maddedeki ortak paragraf akışı) ve görüntüler Gemini'ye soru gibi gitmez. Soru seçilirse →
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
   **"Soruyu iptal et"** → o ana kadar okunan soru metni ve ses kaydı silinir, "Okunan soru silindi" denir ve soru baştan okunur (okunmuş soru yoksa
   "Silinecek soru yok" denir; kamera sorusu açıkken
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
   **Olumsuzlama kuralı:** "Devam / Tekrar / Bitir" menüsünde ve "önceki kayıt mı, yeni mi" sorusunda seçeneği olumsuzlayan söz ("devam etmeyelim",
   "bitirmek istemiyorum", "yeni başlamayalım", "yeni değil") hiçbir seçeneği seçmez; cevap anlaşılmamış sayılır ve yeniden sorulur (böylece
   "bitirmek istemiyorum" testi bitirmez). Aynı olumsuz sözler komut da değildir: "testi bitirme", "cevapları tekrarlamayın", "son cevabı okuma" komut
   sayılmaz, metin olduğu gibi kalır.
   **Karşılıklı tekrar:** İki taraf da anlamadığını söyleyip tekrar isteyebilir. Program anlamadığında ("Anlayamadım…") sorusunu yeniden sorar. Kullanıcı
   programın söylediğini duymadıysa ya da anlamadıysa her an "anlamadım", "anlayamadım", "duyamadım", "duymadım", "bir daha söyle", "yeniden söyle",
   "tekrar söyle", "yine söyle", "ne dedin", "efendim", "pardon", "tekrar söyler misin", "yeniden anlatır mısınız", "bir daha oku" gibi sözlerden birini
   söyler: program son sözünü (en çok son iki anons: örneğin cevap + kamera sorusu) aynen yeniden söyler ve aynı kipte dinlemeye döner. Bu bir cevap
   sayılmaz: hatırlatma sayaçları, tutulan soru, paragraf taslağı, kamera durumu değişmez. Soru okunurken araya girilirse yalnız komut atılır, okunan metin
   korunur. Paragraf okunurken yalnız söz tek başınaysa komut sayılır (paragraf metnine karışmaz). Tek başına "tekrarla" / "tekrar et": soru ve kamera
   sorusunda son cevabı okur (V3 gibi); onay, numara, paragraf numarası ve başlangıç sorusunda programın sözünü tekrarlar. Menüde "Tekrar" bir seçenektir
   (cevapları yeniden oynatır); menüde programın sözünü tekrarlatmak için "bir daha söyle" / "anlamadım" denir.
   **Bilgi ve düzeltme komutları** (her kipte söylenebilir; soru metni ve kip bozulmaz, Gemini'ye gitmez, cevap sayılmaz). **Her biri yaptığını ya da
   yapamadığını kısaca söyler:**

   | Komut (örnek söyleyişler) | Yaptığında söyler | Yapamadığında söyler |
   |---|---|---|
   | **Yardım** ("yardım et", "komutlar neler", "hangi komutlar var", "ne diyebilirim") | Komutları sayar; kamera sorusundayken sonra soruyu yeniden sorar; evet/hayır, numara ve menü sorularında sorunun kendisini yeniden söyler | — |
   | **Ne duydun** ("ne anladın", "duyduğunu oku", "şu ana kadar ne duydun") | "Duyduğum: …" (30 sözcükten uzunsa son 30 sözcük); okuma kaldığı yerden sürer | "Henüz bir şey duymadım." / soru dinlenmiyorsa "Şu anda dinlenen bir soru metni yok." |
   | **Son cümleyi sil** ("son sözü sil", "az önce söylediğimi sil") | "Son cümle silindi: …" (silinenin ilk 8 sözcüğü) ve "Soruyu okumaya devam edebilirsiniz" (hiç metin kalmadıysa "baştan okuyabilirsiniz") | "Silinecek cümle yok." |
   | **Durum** ("durum nedir", "neredeyiz", "kaç soru cevaplandı", "kaçıncı soru") | "N soru cevaplandı. Sıradaki soru numarası M." + yalnız bilinenler: kulaklık, internet, pil | — (bilinmeyen bilgi söylenmez) |
   | **Cevapsız soruları söyle** ("eksik soruları söyle", "hangi soruları atladım", "cevabı olmayan sorular") | "Cevabı olmayan sorular: 2, 4 ve 5." (1'den en yüksek cevaplanan numaraya kadar; 12'den fazlaysa "ve devamı") | "Cevapsız soru yok…" / "Henüz cevaplanan soru yok." |
   | **Rapor** ("internet raporu", "mikrofon raporu", "kulaklık raporu", "ses raporu", "kamera raporu", "şarj durumu", "ısınma durumu", "bellek durumu", "genel rapor") | Durumu tek cümleyle söyler (genel rapor hepsini sayar); internet raporu gerçekten yoklar | Bilinmeyen bilgi söylenmez ("şarj durumu okunamadı" gibi) |
   | **Ses seviyesi** ("sesi aç", "sesi kıs", "sesi yüzde 60 yap") | "Ses açıldı. Ses seviyesi yüzde N." (iOS'tan okunarak doğrulanır) | "Ses seviyesi değiştirilemedi" / "okunamadığı için ayarlanamadı"; en az yüzde 15 |
   | **Kamera ayarı** ("kamera sorusunu kapat", "görüntü kalitesini yüksek yap", "video süresi 8 saniye", "kadrajı dikey yap"…) | Yapılan ayarı söyler ("zaten" ise onu) | Kamera çalışırken "ayar değiştirilemez"; uyumsuz yön/kadraj nedeniyle reddedilir |

   "Son cümle" = son sessizlikten (1 sn) sonra söylenen kısım; soru okunurken araya girilirse komuttan önceki metin korunur. Soru metninin ortasında tek
   sözcüklük komut ("yardım", "durum") tanınmaz (soru metninin parçası olabilir): iki sözcüklü söyleyin ("yardım et", "durum nedir") ya da komutu tek
   başına söyleyin. "Durum, Cevapla" gibi komut + Cevapla da çalışır. **Sınırlar:** "Son cümleyi sil" yalnız metni siler; ses kaydı ve yardımcı İngilizce
   metin silinmez (ses kaydı Gemini'ye gidiyorsa silinen cümle kayıtta kalır). Olumsuz biçimler ("yardım etme", "son cümleyi silme") komut değildir.
   Her komut tek başına: Tekrarla → son cevap ("Tekrarlanacak cevap yok."), "5. sorunun cevabını tekrarla" → o cevap ("5 numaralı soru için kayıtlı cevap
   yok."), "Paragrafı iptal et" → "Ortak paragraf iptal edildi." / "Kayıtlı ortak paragraf silindi." / "Silinecek ortak paragraf yok.", anlaşılmayan komut →
   "Komutu anlayamadım. Lütfen komutu bir kez daha söyleyin."
   **Rapor ve ayar komutlarının güvenlik kuralı:** yalnız TÜM söz komut sözcüklerinden oluşuyorsa tanınır; sınav soru başlıkları ("Ses nedir", "Bellek nedir") ve olumsuz biçimler
   ("sesi kısma") komut değildir. Soru metninin ortasında tek sözcük ("ses", "şarj") hiçbir zaman komut olmaz. Kamera ayarı çekim sürerken değiştirilmez.
   **Numara beklerken cevap tekrarı:** "N. sorunun cevabını tekrarla" eksik numara ya da paragraf numaraları beklenirken de çalışır; cevap okunur, sonra aynı soru yeniden sorulur, tutulan soru ve paragraf taslağı bozulmaz.
   **Aynı numaralı cevap:** bir numara yeniden cevaplanırsa eski cevabın yenisiyle değiştirildiği söylenir. **Test sonu:** "Test tamamlandı. N cevap kaydedildi." cümlesi cevabı olmayan numaraları da sayar.
   **Ses seviyesi uyarısı:** açılışta ve dakikada bir çıkış sesi yüzde 10'un altındaysa söylenir (oturum engellenmez); yükselince uyarı kalkar.
5. **Cevapları okuma ve menü.** Cevaplar numara sırasıyla, aralarında Tekrar boşluğu (varsayılan 3 sn) okunur. Bitince: "N sorunun cevabı okundu. Başka cevap yok. Ne yapmak
   istersiniz? Teste kaldığınız yerden devam etmek için **Devam**, cevapları yeniden dinlemek için **Tekrar**, testi tamamlamak için **Bitir** deyin."
   Devam → kalınan yere dönülür (soru / eksik numara / paragraf numaraları); Tekrar → yeniden okunur ve yine sorulur; Bitir → "Test tamamlandı. N cevap
   kaydedildi." ve test biter. Anlaşılmazsa ya da sessizlikte "ikinci", sonra "üçüncü defa soruyorum" denir; yine olmazsa varsayılan: bitirme isteğiyle gelindiyse test tamamlanır,
   yalnız tekrar istendiyse teste devam edilir. (Ayar: "Testi bitirince cevapları oku", açık; kapalıysa onaydan sonra test doğrudan tamamlanır.)
5a. **Sınav bölümleri (Ayarlar > Sınav bölümleri).** En çok 4 bölüm açılır, her birinin soru sayısı (en çok 100) yazılır; böylece program sınavdan önce her bölümün kaç soru olduğunu bilir.
   Sınav başlarken "1. bölüme başlıyorum. Bu bölümde N soru var." denir. Her sınav oturumu üst klasörünü yıl-ay-gün-saat-dakika-saniye adıyla alır (ör. `20261115223912`);
   bölümlü sınavda cevaplar bu klasörün içindeki `bolum_1`, `bolum_2`… klasörlerine yazılır (her bölümde numara 1'den başlar, bölümler birbirini ezmez). **"Bölümü tamamla"**
   (ya da "bölümü bitir") denince onay istenir; evet → o bölümün cevapları okunur, menüde **Bitir** denince "N cevap, cevapsız: …" söylenir ve
   "Yeni bir bölüm ile devam etmek ister misiniz, yoksa testi tamamlayalım mı?" diye sorulur. **Evet** → "2. bölüme başlıyorum" (numara 1'den), **hayır / testi tamamla** → test biter.
   Yanıt gelmezse "ikinci", sonra "üçüncü defa soruyorum" denir, sonra yeni bölüme geçilir (test kendiliğinden bitirilmez). Son bölüm tamamlanınca soru sorulmaz, test tamamlanır. Bölümün soru sayısından büyük
   numara kabul edilmez (numara yeniden sorulur); hiçbir sınavda 100'ün üstünde numara yoktur. Bölüm açık değilse sınav tek parçadır ve eskisi gibi çalışır; "bölümü tamamla" denirse
   "Bölüm ayarlı değil" denir. Kapanıp açılınca kalınan bölümden devam edilir.
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
| yeni bölüm mü, test bitti mi (yalnız bölümlü sınavda) | "Yeni bir bölüm ile devam etmek ister misiniz, yoksa testi tamamlayalım mı?" | evet / yeni bölüm / devam; hayır / testi tamamla / bitir | anlaşılmazsa ya da sessizlikte bir kez hatırlatılır; yine olmazsa yeni bölüme geçilir | 1 hatırlatma |
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

- Cevaplar okunurken sesle araya girilemez (okuma sürerken dinleme açık değildir). Durdurmak için ekrandaki Duraklat düğmesi kullanılır; cihazda denenmedi.
- Numara / paragraf numarası beklerken "testi bitir" denebilir; bu durumda program bekleyen soru ya da paragrafın bitirmeyle gönderilmeyeceğini/kaydedilmeyeceğini söyleyip onay ister. Vazgeçilirse (hayır, anlaşılmayan söz, cevapsızlık) aynı bekleme sürer. Yalnız tam "testi bitir" sözü bunu yapar; numara cevabıyla karışmaz. Cihazda denenmedi.
- Paragraf okunurken yapılan yeniden dinleme (cevapları tekrarla) cevapsız bırakılan paragrafı korumaz: paragraf serbest metin olduğundan bu komut orada çalışmaz; bilerek eklenmedi.
- Ses seviyesini sesle değiştirme iOS'un izin vermediği bir işlemi gizli ses çubuğuyla dener; **cihazda doğrulanmadı**. Değişmezse program bunu söyler.
- Kamera pili yalnız kamera açıkken, görüntü karesinden okunur; "kamera raporu" ve "Kamerayı dene" son okunan pili söyler (hiç okunmadıysa söylemez). "Şarj durumu" telefonun pilidir. "Genel rapor" kamera ayarlarını saymaz ("kamera raporu" ayrı).
- Kamera sorusu kapatılırken bekleyen bir çekim varsa o çekim yine gönderilir.
- Çekimler telefondaki kalıcı klasörde saklanır (`Documents/Cekimler`: Bekleyen, Gonderilen, Gonderilemeyen, Paragraf) ve KENDİLİĞİNDEN SİLİNMEZ: ne gönderilince, ne ikinci başarısızlıkta, ne test bitince, ne sayı yüzünden. Yalnız kullanıcı Ayarlar > Çekim klasörü'ndeki onaylı "Gönderilenleri sil" / "Tümünü sil" düğmeleriyle siler (test sürerken silinemez).
- Bekleyen çekimler her yeni soru sınırında, en eskisinden başlayarak sırayla gönderilir; internet yoksa oturum takılmaz. Uygulama kapanıp açılsa da klasörden geri yüklenir.

- Paragraf okunurken yalnız "paragrafı iptal et" çalışır; diğer komutlar (testi bitir, cevapları tekrarla…) paragrafa karışır, çünkü paragraf serbest metindir.
- "Soruyu iptal et" yalnız soru dinlenirken (okunan metni siler) anlamlıdır; kamerayla çekilmiş soru Gemini'ye gittikten sonra geri alınamaz.
- Bilgi komutları paragraf okunurken yalnız söz tek başınaysa çalışır (paragraf serbest metindir). "Cevapsız sorular" numaraları 1'den sayar; sınav 1'den başlamıyorsa baştaki numaralar da eksik görünür.
- Komut denemesi yalnız çok katı bir kuralla ("bütün sözcükler komut sözcüğü, en az biri fiil/işaret") algılanır; ondan uzak bir yanlış okuma (komutla ilgisiz sözcükler) hâlâ soru metni sayılır ve sessiz birikir.
- "Testi Bitir" **düğmesi** cevapları kendiliğinden okutmaz; yalnız sesle bitirme okutur (düğme sonrası ana ekrandaki tekrar düğmesi kullanılır).
- "Cevapları tekrarla" paragraf okunurken ve "Devam mı, yeni sınav mı?" sorusu beklenirken çalışmaz.
- Tanıyıcının alternatif okumaları cihaz ve modele bağlıdır; vermiyorsa yalnız en iyi okuma ve yakın ses toleransı kullanılır (cihazda görülmedi).
- Gerçek dikte çıktısının biçimi (rakam mı, sözcük mü, bitişik mi) cihazda görülmedi; anlaşılmayan söz ekranda "Duyulan: …" olarak yazar, günlükte `[soru]` / `[paragraf]` satırlarında durur.


## Sessizlikte kalmama kuralı (tüm sorular için)

- Program bir şey sorduktan sonra cevap gelmez ya da anlaşılmazsa aynı soruyu "ikinci defa soruyorum", sonra "üçüncü defa soruyorum" diye yeniden sorar; üçüncüde de cevap gelmezse güvenli varsayılana geçer (test hiçbir zaman sessizlikten dolayı bitmez). Bu kural kamera sorusu, soru/paragraf sorusu, paragraf kamerası, bitirme onayı, cevap menüsü, devam/yeni, yeni bölüm, eksik numara ve paragraf numaraları için aynıdır.
- Komut gibi duyulup tanınmayan söz için program "Komutu anlayamadım" der ve ne yapılacağını söyler.
- Mikrofon eksikken (duraklatılmış) program yönlendirmeyi bir kez söyleyip susmaz; yaklaşık dakikada bir yeniden söyler, mikrofon takılınca kendiliğinden devam eder.
- Kameraya geçildikten sonra görüntü gelmezse onarım kestirmesi telefonda olmasa bile kamera yeniden denenir (en çok iki yeniden deneme).
