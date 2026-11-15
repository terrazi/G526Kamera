# Kaizen günlüğü (sürekli iyileştirme)

Yöntem (PUKÖ): **Planla** (bölümü seç, ne bozulabilir) → **Uygula** (kanıt üret: test ya da hesap, sonra düzelt) → **Kontrol et** (CI'da tüm testler)
→ **Önlem al** (aynı hata bir daha girmesin diye genel bir test ya da kural). Bölümler önce ayrı ayrı, sonra kaos testleriyle birlikte sınanır.

## Tur 1: sesli cevap sözlükleri ve komutlar

| Bulgu (kanıtlı) | Neden | Düzeltme | Önlem (test / kural) |
|---|---|---|---|
| Kamera sorusuna **"çekmiyorum" EVET** sayılıyordu (kamerayı açar, hücreseli keser) | Tek harf farklı bulanık eşleşme: "çekmiyorum" ↔ "çekiyorum". Türkçede olumsuzluk eki tek harf farkıdır | Evet yalnız TAM eşleşmeyle; bulanık eşleşme yalnız HAYIR yönünde; olumsuz biçimler listeye yazıldı | `VoiceReplyHazardTests`: her olumlu/olumsuz ikiz için "olumsuz asla evet olmaz" taraması |
| "**çekmek istiyorum**" anlaşılmıyordu | "çekmek" bulanık olarak "çekme" (hayır) sözüne benziyordu, "istiyorum" (evet) ile çelişti | "çekmek/çekmeyi" nötr mastar listesine alındı | Aynı test dosyası (doğal söyleyişler) |
| Bitirme onayında "**bitirmek istiyorum**" HAYIR sayılıyordu | "bitirmek" ↔ "bitirme" bulanık eşleşmesi | "bitirmek/sonlandırmak/tamamlamak" zayıf evet; hayır sözü ("istemiyorum") yine kazanır | Aynı |
| "kamerayı kullanmayalım", "kamera olmasın" EVET sayılıyordu | Zayıf evet sözü ("kamera") hayır sözü tanınmadığı için tek başına evet oldu | Hayır sözleri eklendi (kullanma, olmasın, gerekmez…) | Aynı |
| Menüde "bitirme, devam" çelişki sayılıp anlaşılmıyordu | "bitirme" ↔ "bitirmek" | Bitirme olumsuzlukları (`finishNegations`) bitirme isteği sayılmaz | `testReviewMenuNegationsCannotBeMistakenForFinishing` |
| Numara beklerken (söylenmeden) yanlış okunan soruyu **iptal edecek komut yoktu**; boşuna sıradaki numarayla Gemini'ye giderdi | Numara beklenirken yalnız "cevapları tekrarla" çalışıyordu | "Soruyu iptal et" burada da çalışır, bekleyen soru bırakılır | `testCancelQuestionWhileTheNumberIsAskedDropsTheHeldQuestion` |
| Bozuk okunan iptal komutu ("soruyu iptalet") sessizce soru metnine biriktirilirdi | Komut denemesi algılayıcısı iptal sözcüklerini bilmiyordu | Yalnız iptal fiili + soru/paragraf sözcüğü birlikteyse "komutu anlayamadım" denir | `testMisheardCancelCommandIsReportedNotSwallowedSilently` |
| Yeni komutlar tanıyıcı ipuçlarında, "anlayamadım" yardımında ve uygulama içi yardımda yoktu | Komutlar yalnız kodda tanımlıydı | Üçüne de eklendi | `SpokenGrammarTests` (ipucu ≤ 100) |
| Kameralı akışın kaos testi yoktu | V3 kaos testi kamera olaylarını içermiyordu | `CameraChaosTests` (150 gerçek zamanlı + 250 hamle tohum, video sızıntı denetimi) | Her CI koşusunda |

## Tur 2: menüler, başlangıç sorusu ve komut olumsuzlaması

| Bulgu (kanıtlı: Python taşımasıyla hesaplandı) | Neden | Düzeltme | Önlem |
|---|---|---|---|
| Cevap okuma menüsünde "**bitirmek istemiyorum**" testi BİTİRİYORDU (son zararlı eşleşme) | "bitirmek" seçenek sözüydü, "istemiyorum" menüde bilinmiyordu | Seçeneği olumsuzlayan sözler (`choiceNegations`) varsa cevap anlaşılmamış sayılır, yeniden sorulur | `testReviewMenuNegatedChoicesAreNeverSelected` + akış testi |
| "Devam etmeyelim", "tekrar etme", "tekrar dinlemek istemiyorum" menüde devam/tekrar sayılıyordu | Aynı | Aynı | Aynı |
| Başlangıç sorusunda "devam etmeyelim" devam, "yeni başlamayalım" yeni sayılıyordu | Aynı | Aynı ("hayır yeni" yine yeni: "hayır" tek başına olumsuzlama sayılmaz) | `testStartChoiceNegatedChoicesAreNeverSelected` |
| "**Testi bitirme**", "sınavı bitirmem", "testi tamamlama", "cevapları tekrarlamayın", "son cevabı okuma" KOMUT sayılıyordu | Yakın sesli eşleşme: "bitirme" ≈ "bitirmek", "tekrarlama" `tekrar` ile başlıyor | Olumsuz söz içeren metin komut değildir | `testNegatedCommandsAreNeverCommands` (her olumsuz söz × her önek taraması) |

## Tur 3: karşılıklı tekrar (kullanıcı isteği)

| İstek / bulgu | Düzeltme | Önlem |
|---|---|---|
| Kullanıcı programın söylediğini duymadı/anlamadı: tekrar isteyebilmeli ("anlamadım", "duyamadım", "bir daha söyle", "yeniden söyle"…). Eskiden yalnız "tekrarla" ve yalnız soru/kamera sorusunda çalışıyordu; onay, menü, numara, paragraf, başlangıçta hiçbir şey olmuyordu | Yeni komut `repeatSpeech`: programın son sözü (en çok son iki anons) aynen yeniden söylenir, aynı kipte dinlenir; cevap sayılmaz, sayaçlar ve bekleyen işler değişmez | `RepeatSpeechTests` (26 söyleyiş, her kipte akış, soru metni/olumsuz söz komut değil) |
| Cevap + kamera sorusu arka arkaya söylenince yalnız kamera sorusu tekrarlanırsa cevap kaçırılır | "Son söz" grubu: mikrofon açılınca yeni grup başlar; cevap ve ardından gelen soru birlikte tekrarlanır | `testRepeatAfterAnAnswerAndTheCameraQuestionSpeaksBoth…` |
| Menüde "Tekrar" bir seçenek (cevapları oynatır): "tekrar söyle" ile karışmamalı | "Tekrar söyle" programın sözünü tekrarlatır; tek başına "Tekrar" yine cevapları oynatır | `testRepeatAtTheReviewMenu…`, `testMenuTekrarOptionStillReplaysTheAnswers` |
| Paragraf metninde "bir kez daha söyledi… duyamadım" gibi sözler tekrar isteği sayılmamalı | Paragraf okunurken yalnız söz tek başınaysa komut sayılır; tek başına "bir daha" hiç komut değil | `testParagraphTextContainingTheWordsIsNotMistaken…` |

İncelenip değişiklik gerekmeyenler (kanıtla): tetikleyici "Cevapla/Gönder" yalnız son sözcük ve aynı sesle eşleşir ("cevaplayınız" tetiklemez);
paragraf numarası çözümleme ve kesinti/kurtarma akışı (tur 1 ve 2 incelemesi).

## Tur 4: CI'nin yakaladığı eksik, kaos testleri ve belgeler

| Bulgu | Düzeltme | Önlem |
|---|---|---|
| CI (788a2b7): 1021 testten 3'ü düştü. "Anlamadım" denince son CEVAP değil, açılış anonsu ("Ben hazırım…") ya da "Kameraya geçiliyor…" tekrarlanıyordu | Cevap `speakNotice` ile değil doğrudan okunduğu için "son söz" grubuna girmiyordu. Cevap okunurken yeni grup başlatılıp cevap hatırlanır (ara anonslar "gönderildi, bekleniyor" tekrarlanmaz) | Aynı üç test (`testEveryPhrase…`, `testPartlyReadQuestion…`, `testRepeatAfterAnAnswerAndTheCameraQuestion…`) |
| Kaos testleri tekrar isteğini hiç denemiyordu | `ChaosTests` (olay 42, 43) ve `CameraChaosTests` (olay 37, 38) havuza değiştirilerek eklendi (havuz boyutu ve eski tohumların sırası korunur): rastgele kesintiler, kamera ve Gemini gecikmeleri arasında "anlamadım" / "bir daha söyle" | Mevcut değişmezler (takılma, sızıntı, anons yağmuru) |
| `KURULUM.md` hâlâ "Sürüm 3, kamera yok" diyordu; yeni komutlar eksikti | V4 girişi, `surum-4` dalı, iptal / N. cevap / "anlamadım" komutları ve evet-hayır güvenli kuralı yazıldı | — |

## Kurallar (bundan sonrası için)

1. Evet/hayır sorularında "evet" bulanık eşleşmeyle kabul edilmez; yeni bir "evet" sözü eklenirse olumsuz ikizi de listeye yazılır (test yakalar).
2. Yeni komut sözcüğü eklenirse: gerçekçi soru parçalarıyla "komut sayılmaz" testi genişletilir.
3. Her yeni komut: tanıyıcı ipucu + yardım cümlesi + uygulama içi yardım + `docs/PROSEDUR.md` satırı.
4. Olumsuz söz hiçbir seçeneği seçmez ve komut sayılmaz; yeni bir komut/seçenek sözü eklenirse olumsuz biçimi `choiceNegations`/`finishNegations`'a da yazılır.
5. Programın söylediği her şey "bir daha söyle" ile tekrarlatılabilmeli; yeni bir anons türü eklenirse `speakNotice` kullanılır (otomatik hatırlanır). `speakNotice` kullanmayan okuma (örn. cevap) `rememberSpeech` çağırmalıdır.
6. Cihazda doğrulanmamış hiçbir davranış "çalışıyor" diye yazılmaz (gerçek dikte çıktısı, kestirmelerin Wi-Fi/hücreseli gerçekten değiştirmesi).
