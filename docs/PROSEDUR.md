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
4. **Komutlar** (yalnız soru kipinde, tek başına): "Testi bitir / Sınavı bitir" → onay sorulur; "Son cevabı tekrarla" → son cevap yeniden okunur.
5. **Test sonu.** Onaydan sonra: "Test bitiriliyor. N cevap kaydedildi. Cevaplar sırayla okunuyor." → kaydedilen cevaplar numara sırasıyla, aralarında
   Tekrar boşluğu (varsayılan 3 sn) → "Cevapların hepsi okundu." (Ayar: "Testi bitirince cevapları oku", açık.)
6. **Kendini onarma.** Kulaklık/mikrofon/internet kopunca susulur, onarılır, söylenir, kaldığı yerden devam edilir (ayrıntı: SURUM3.md, SENARYOLAR.md).

## Bekleme durumları (her biri: sesli istem, kabul edilen sözler, anlaşılmazsa ne olur, sınır)

| Durum | Sesli istem | Kabul edilen | Anlaşılmazsa / sessizlikte | Sınır |
|---|---|---|---|---|
| soru | "Hazır" / "Lütfen sonraki soruyu okuyun" | soru + Cevapla/Gönder; komutlar | 30 sn sessizlikte dinleme sessizce yenilenir | yok |
| ortak paragraf | "Lütfen ortak paragrafı okuyun, bitince Tamam deyin" | paragraf + Tamam / Tamamlandı | — ("tamam" cümle içinde geçerse 1,5 sn sabit kalmadan bitmez) | yok |
| paragraf numaraları | "Paragraf metnini aldım, hangi sorular için?" | numaralar + Tamam / Cevapla / Gönder | kısa yeniden sorma; ekranda ne duyulduğu yazar | 2 yeniden, sonra paragraf sıradaki soruya bağlanır ve söylenir |
| eksik soru numarası | "Lütfen okuduğunuz sorunun numarasını söyleyin" | numara, "sıradaki" | numara olmayan kısa söz 4 sn sonra, sessizlik 30 sn sonra yeniden sorulur; ekranda ne duyulduğu yazar | 2 hatırlatma, sonra sıradaki numara |
| testi bitirme onayı | "Testi bitirmek istiyor musunuz?" | evet / hayır (komutu yeniden söylemek de evet) | cevapsızlıkta test sürer | — |
| devam mı, yeni mi | "Önceki kayıtta N cevap var… Devam mı, yeni sınav mı?" | devam / yeni | 1 hatırlatma, sonra 12 saat kuralı | 1 |

Kabul edilen numara söyleyişleri: "yedi", "7", "yedinci", "7. soru", "soru yedi", "5, 6, 7", "beş altı yedi", "5. soru, 6. soru", "beşten yediye kadar", "5-7",
bitişik "567" (üç haneli ve 150'nin üstündeyse tek tek rakam sayılır).

## Bilinen eksikler

- Komutlar paragraf okurken çalışmaz (paragrafa karışır).
- "Testi Bitir" **düğmesi** cevapları kendiliğinden okutmaz; yalnız sesle bitirme okutur (düğme sonrası ana ekrandaki tekrar düğmesi kullanılır).
- Gerçek dikte çıktısının biçimi (rakam mı, sözcük mü, bitişik mi) cihazda görülmedi; anlaşılmayan söz ekranda "Duyulan: …" olarak yazar, günlükte `[soru]` / `[paragraf]` satırlarında durur.
