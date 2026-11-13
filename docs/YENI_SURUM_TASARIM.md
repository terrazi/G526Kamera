# Yeni sürüm (dal: yeni-surum) — tasarım ve kararlar

Eski programın (dal `pdf-toplu-gonderim`, 98c354b, 825 test) budanmış, tam otomatik hâli. Eski program bozulmadan o dalda durur.
Hiçbir şey telefonda denenmedi: yalnız GitHub Actions'ta derlendi ve birim testlerden geçti.

## Temel ilke
- Mikrofon, sesli komut, konuşma tanıma ve sınav sırasında ekrana dokunma YOK. Ekrana yalnız sınavdan önce ayar için dokunulur.
- Ses yalnız kulaklığa verilir; çıkış telefon hoparlörüyse program konuşmaz (bekler).
- Program belli saatte kendiliğinden açılır: iOS Kestirmeler > Otomasyon > "Günün Saati" > "Uygulamayı Aç"/URL aç `g526kamera://basla`
  (Hemen Çalıştır). Açılışta tarama kendiliğinden başlar.
- Telefon açık, ekran açık ve şarjda olmalı (kilitliyken kamera akışı ve ses sürmez). Telefon yeniden başlarsa ya da uygulama kapanırsa
  program kendini toparlamaz (kullanıcı kararı).

## Akış
1. Açılış: "N soru taranacak" denir (soru sayısı ayardan; girilmemişse kırmızı kutuda "Soru sayısı girilmemiş" yazar ve program yedek
   bitiş kurallarıyla çalışır).
2. Kamera Wi-Fi kestirmesi çalışır (ayarda adı yazılıysa); kare gelene dek ayardaki sayıda/aralıkla yeniden denenir
   (varsayılan 30 deneme × 60 sn).
3. Kamera canlıyken kulaklığa "Kamera hazır. Taranacak evrakı hazırlayıp kameraya tutun." denir; evrak gelene dek 30 sn'de bir
   (ayar) tekrarlanır; en çok 10 dk (ayar) beklenir, sonra kırmızı kutu + sesli bildirim.
4. Belge görününce 2 sn bekler, sonra 5 sn'lik pencere: ≈10 kare (her yarım saniyeden en net kare) ve 5 sn'lik video (klasöre kaydedilir).
   Pencere boyunca sesli konum yönlendirmesi sürer (sola/sağa/yukarı/aşağı, yaklaş/uzaklaş).
5. Her karede cihaz üstü OCR (Vision) soru numaralarını ve şıkları bulur. Kırpma: numara satırından 2 satır yukarı, son şıktan (E) 4 satır
   aşağı; bir sonraki sorunun numarasında biter. İki sütunlu sayfa desteklenir.
6. Kalite kapısı: kesik / eksik şık / bulanık / parlama / okunmuyor / çok küçük. Sorun varsa nedeni sesle söylenir; aynı uyarı en az 10 sn
   arayla; bir soru için en çok 5 deneme (ayar, 0 = sınırsız), sonra "okunamadı" sayılıp tarama sürer. Toplam süre sınırı 15 dk (ayar).
7. Kabul edilen her soru için en iyi 2 kare `S12.pdf` olur; grup boyutu 2–3 ise ayrıca `S12-14.pdf` yapılır (Gemini'ye bu gider).
   Alta uzanan sorular için "N. sorunun devamını kameraya tutun" denir; devam sayfası birleştirilir.
   **Karışık sıra:** Sorular sırayla çekilmek zorunda değildir. Kayıt defteri her şeyi soru numarasına göre tutar: alınan sorular, eksikler,
   deneme sayıları ve yarım kalan sorular numarasıyla saklanır; hangi sırayla çekildikleri sonucu etkilemez. Sayfanın başındaki numarasız
   parça, sayfadaki ilk numaralı sorudan bir önceki sorunun devamıdır (sayfada numara yoksa ve tek yarım soru varsa onunki). Birden çok soru
   aynı anda yarım kalabilir. Bir sorunun alt kısmı başından önce çekilirse alt kısım numarasıyla saklanır ("N. sorunun alt kısmı alındı. Üst
   kısmını da kameraya tutun" denir); üst kısım gelince birleşir. PDF'ler (S12.pdf, S12-14.pdf) ve cevap okuma her zaman numara sırasındadır.
8. Bitiş: bütün sorular alınınca. Eksik varken belge 10 sn görünmezse "15 ve 22 eksik. İlgili sayfaları kameraya tutun." denir, 60 sn
   (ayar) beklenir (20 sn'de bir tekrar; ilerleme olursa süre yenilenir); olmazsa kalanlar kırmızı kutuda listelenir ve tarama biter.
9. İnternet sırasında kapalıdır (kamera Wi-Fi'sinde hücresel kesilir). Tarama bitince kamera akışı durdurulur, internet yoklanır, yoksa
   ayardaki TEK internet kestirmesi (Wi-Fi kapat → 2 sn bekle → hücreseli aç) ayardaki sayıda/aralıkla çalıştırılır; internet gelince durur.
10. Gemini: PDF'ler standart istemle 4 profillik zincire gider (Gemini 3.6 Flash → 3.5 Flash-Lite → 3.1 Flash-Lite ücretsiz → 3.1 Flash-Lite
    ücretli). Kota dolarsa / hata olursa / cevap gecikirse sıradaki modele geçilir ve nedeni sesle söylenir. Eksik ya da okunamayan sorular
    bir kez yeniden sorulur.
11. Cevaplar sıralanır, kulaklıkla okunur ("Birinci soru, ADANA, kırk iki."; şık kodu ayardaki "Şık kodları"ndan), her cevaptan sonra ilk
    okuma için 3 sn, tekrar için 5 sn (ayarlar) beklenir; sonra "Cevaplar bir kez daha okunuyor", hepsi tekrar okunur, okunamayanlar
    sayılır, "Deneme sınavı tamamlandı" denir. `Cevaplar.txt` sınav alt klasörüne yazılır.

## Dosyalar
`G526 Belgeler/Sinav-yyyyMMdd-HHmm/` altında: `S12.pdf`, `S12-14.pdf`, `V01.mp4` …, `Cevaplar.txt`. Klasör telefonda kalır, program silmez.

## Arama / mesaj engelleme
Uygulama aramaları ya da mesajları engelleyemez. Sınav süresince Odak (Rahatsız Etme) kullanın ve Kestirmeler otomasyonuyla aynı saatte
Odak'ı açın; arama/mesaj tamamen susmayabilir, bunu garanti etmiyoruz.

## Kullanıcının kuracağı kestirmeler
- Kamera Wi-Fi'sini açan kestirme (örn. "Kamera Wi-Fi") — adı Ayarlar > Kestirmeler'e yazılır.
- İnternet kestirmesi: Wi-Fi'yi kapat → 2 sn bekle → hücresel veriyi aç — adı aynı yere yazılır.
- Günün Saati otomasyonu: `g526kamera://basla` adresini aç (Hemen Çalıştır).
- İsteğe bağlı "G526 Kestirme Seç": ayarlarda adı yazmak yerine listeden seçmek için (Ayarlar'daki yardım metni anlatır).

## Kod haritası
- Saf mantık (CI'da sınanır): `QuestionLayout`, `QualityGate`, `ScanLedger`/`ScanPlanner`, `CaptureAnalyzer`, `ScanRules`, `TurkishNumbers`, `AnswerService`.
- Akış: `AppModel` (+Scan, +Answers). Kamera hattı: `CameraClient` → `H264Decoder` → `FramePipeline` → `FrameCollector`/`GuidanceEngine`.
- Gemini: `Gemini`, `GeminiProfiles`, `AnswerService`. Kestirmeler ve internet yoklaması: `Kestirme`.
