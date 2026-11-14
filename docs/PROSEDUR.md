# Sesli Kontrol: öngörülen prosedür ve uyum tablosu

Bu belge, programın sesle nasıl işlemesi gerektiğini adım adım yazar; her adımın karşılığı kodda ve testte aranır. Davranışı değiştirirken
önce burası güncellenir. **Cihazda denenmemiştir**; testler sahte mikrofon, kulaklık ve ağ ile çalışır.

## Akış

1. **Açılış.** İzinler, çevrimdışı dikte, kulaklık + mikrofon, internet, Gemini denetlenir. Önceki klasörde cevap varsa: "Önceki kayıtta N cevap var,
   sıradaki soru M. Devam mı, yeni sınav mı?" (devam / yeni; cevapsızsa bir hatırlatma, sonra 12 saatten yeniyse devam). Sonra "Hazır".
2. **Tek soru.** Soru numarasıyla okunur → "Cevapla" ya da "Gönder" → numara okunmadıysa "Lütfen okuduğunuz sorunun numarasını söyleyin" →
   "Soru gönderildi, cevap bekleniyor" → cevap kulaklıktan okunur ve `soru_N` + `cevaplar.txt` olarak kaydedilir → "Lütfen sonraki soruyu okuyun".
3. **Ortak paragraf.** "Ortak paragraf" (duraklayın) → "Lütfen ortak paragrafı okuyun, bitince Tamam deyin" → paragraf + "Tamam" → "Paragraf metnini
   aldım, hangi sorular için? Numaraları söyleyip Tamam deyin" → "5, 6, 7" → "Ortak paragraf 5, 6 ve 7 için kaydedildi. Şimdi soruları okuyabilirsiniz" →
   her soru (numarası listede ise) paragrafla birlikte gider; hepsi cevaplanınca paragraf bırakılır.
4. **Komutlar** (tek başına): "Testi bitir / Sınavı bitir / Bitir" → onay sorulur; "Son cevabı tekrarla" → son cevap yeniden okunur;
   **"Cevapları tekrarla"** → bütün cevaplar baştan okunur (soru dinlenirken, bitirme onayı beklenirken, eksik numara beklenirken ve paragraf numaraları
   beklenirken söylenebilir; test sürer, oturum kapanmaz).
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
| ortak paragraf | "Lütfen ortak paragrafı okuyun, bitince Tamam deyin" | paragraf + Tamam / Tamamlandı | — ("tamam" cümle içinde geçerse 1,5 sn sabit kalmadan bitmez) | yok |
| paragraf numaraları | "Paragraf metnini aldım, hangi sorular için?" | numaralar + Tamam / Cevapla / Gönder | kısa yeniden sorma; ekranda ne duyulduğu yazar | 2 yeniden, sonra paragraf sıradaki soruya bağlanır ve söylenir |
| eksik soru numarası | "Lütfen okuduğunuz sorunun numarasını söyleyin" | numara, "sıradaki" | numara olmayan kısa söz 4 sn sonra, sessizlik 30 sn sonra yeniden sorulur; ekranda ne duyulduğu yazar | 2 hatırlatma, sonra sıradaki numara |
| testi bitirme onayı | "Testi bitirmek istiyor musunuz?" | evet / hayır (komutu yeniden söylemek de evet); "cevapları tekrarla" | anlaşılmazsa bir kez daha sorulur; cevapsızlıkta test sürer | 1 hatırlatma |
| cevap okuma sonrası menü | "N sorunun cevabı okundu… Devam, Tekrar ya da Bitir deyin" | devam / tekrar / bitir ve doğal söyleyişler ("teste devam edelim", "cevapları yeniden oku", "testi tamamla") | anlaşılmazsa 4 sn sonra, sessizlikte 30 sn sonra bir kez hatırlatılır; sonra varsayılan (bitirme isteğiyse tamamla, değilse devam) | 1 hatırlatma |
| devam mı, yeni mi | "Önceki kayıtta N cevap var… Devam mı, yeni sınav mı?" | devam / yeni | 1 hatırlatma, sonra 12 saat kuralı | 1 |

**Tek seferde anlama.** Söz önce tanıyıcının en iyi okumasıyla çözülür; çözülemezse tanıyıcının son sözcükler için verdiği alternatif okumalar denenir
(cihaz bunları veriyorsa). Sözcükler ses anahtarıyla karşılaştırılır (b/p, d/t, g/k, s/z karışması: "peş" = beş, "yeti" = yedi, "dörd" = dört, "pitir" = bitir);
beş harften uzun sözcüklerde tek harf farkı kabul edilir. Komut sözlükleri birbirine yaklaşmaz (testle denetlenir). Paragraf numaralarında alternatif okuma yalnız
numara EKLER, duyulan numarayı değiştirmez ya da silmez. Tanıyıcıya ipucu olarak komut, menü ve sayı sözcükleri verilir.

Kabul edilen numara söyleyişleri: "yedi", "7", "yedinci", "7. soru", "soru yedi", "5, 6, 7", "beş altı yedi", "5. soru, 6. soru", "beşten yediye kadar", "5-7",
bitişik "567" (üç haneli ve 150'nin üstündeyse tek tek rakam sayılır).

## Bilinen eksikler

- Komutlar paragraf okurken çalışmaz (paragrafa karışır).
- "Testi Bitir" **düğmesi** cevapları kendiliğinden okutmaz; yalnız sesle bitirme okutur (düğme sonrası ana ekrandaki tekrar düğmesi kullanılır).
- "Cevapları tekrarla" paragraf okunurken ve "Devam mı, yeni sınav mı?" sorusu beklenirken çalışmaz.
- Tanıyıcının alternatif okumaları cihaz ve modele bağlıdır; vermiyorsa yalnız en iyi okuma ve yakın ses toleransı kullanılır (cihazda görülmedi).
- Gerçek dikte çıktısının biçimi (rakam mı, sözcük mü, bitişik mi) cihazda görülmedi; anlaşılmayan söz ekranda "Duyulan: …" olarak yazar, günlükte `[soru]` / `[paragraf]` satırlarında durur.
