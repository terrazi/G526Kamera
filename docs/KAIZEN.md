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

İncelenip değişiklik gerekmeyenler (kanıtla): tetikleyici "Cevapla/Gönder" yalnız son sözcük ve aynı sesle eşleşir ("cevaplayınız" tetiklemez);
paragraf numarası çözümleme ve kesinti/kurtarma akışı (tur 1 ve 2 incelemesi).

## Kurallar (bundan sonrası için)

1. Evet/hayır sorularında "evet" bulanık eşleşmeyle kabul edilmez; yeni bir "evet" sözü eklenirse olumsuz ikizi de listeye yazılır (test yakalar).
2. Yeni komut sözcüğü eklenirse: gerçekçi soru parçalarıyla "komut sayılmaz" testi genişletilir.
3. Her yeni komut: tanıyıcı ipucu + yardım cümlesi + uygulama içi yardım + `docs/PROSEDUR.md` satırı.
4. Olumsuz söz hiçbir seçeneği seçmez ve komut sayılmaz; yeni bir komut/seçenek sözü eklenirse olumsuz biçimi `choiceNegations`/`finishNegations`'a da yazılır.
5. Cihazda doğrulanmamış hiçbir davranış "çalışıyor" diye yazılmaz (gerçek dikte çıktısı, kestirmelerin Wi-Fi/hücreseli gerçekten değiştirmesi).
