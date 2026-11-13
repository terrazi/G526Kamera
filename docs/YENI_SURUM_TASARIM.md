# Yeni sürüm (dal: yeni-surum) — tasarım ve kararlar

Eski programın (dal `pdf-toplu-gonderim`, 98c354b, 825 test) budanmış, tam otomatik hâli. Eski program bozulmadan o dalda durur.
Hiçbir şey telefonda denenmedi: yalnız GitHub Actions'ta derlendi ve birim testlerden geçti.

## Temel ilke
- Mikrofon, sesli komut, konuşma tanıma ve sınav sırasında ekrana dokunma YOK. Ekrana yalnız sınavdan önce ayar için dokunulur.
- Ses yalnız kulaklığa verilir; çıkış telefon hoparlörüyse program konuşmaz (bekler).
- Program belli saatte kendiliğinden açılır: iOS Kestirmeler > Otomasyon > "Günün Saati" > "Uygulamayı Aç"/URL aç `seslikontrol://basla`
  (Hemen Çalıştır). Açılışta tarama kendiliğinden başlar.
- Telefon açık, ekran açık ve şarjda olmalı (kilitliyken kamera akışı ve ses sürmez). Telefon yeniden başlarsa ya da uygulama kapanırsa
  program kendini toparlamaz (kullanıcı kararı).

## Akış (sayfa sayfa)
Sınav kâğıdı SORU SORU değil SAYFA SAYFA taranır: telefon soru numarası ya da şık yeri okumaz. (Eski soru-soru tasarımda telefonun yanlış
okuduğu numara — 41. soruyu 11 saymak gibi — Gemini'ye yanlış etiketle gidiyor ve cevap yanlış numarayla okunuyordu; bu yüzden kaldırıldı.)
1. Açılış: "N soru, M sayfa taranacak" denir (ayardan; girilmemişse kırmızı kutuda uyarı yazar ve program yedek bitiş kurallarıyla çalışır).
2. Kamera Wi-Fi kestirmesi çalışır (ayarda adı yazılıysa); kare gelene dek ayardaki sayıda/aralıkla yeniden denenir
   (varsayılan 30 deneme × 60 sn).
3. Kamera canlıyken kulaklığa "Kamera hazır. Taranacak evrakı hazırlayıp kameraya tutun." denir; evrak gelene dek 30 sn'de bir
   (ayar) tekrarlanır; en çok 10 dk (ayar) beklenir, sonra kırmızı kutu + sesli bildirim.
4. Belge görününce 2 sn bekler, sonra sayfa çekimi başlar (varsayılan 8 sn, ayar 3–30): kamera sayfanın üstünde YAKINDAN, yavaşça gezdirilir.
   Sayfa tek kareye sığmak zorunda değildir. Çekim boyunca video yazılır (saniyede 2 kare; her yarım saniyeden en net kare) ve aynı
   kareler ayrıca toplanır. **Sesli konum tarifi, kadraj bekleme, canlı OCR ve kalite reddi YOKTUR.**
5. Çekim bitince tek bir denetim yapılır: videonun bütününde sayfanın kenarları görüldü mü? Apple Vision belge algılaması her karede
   kâğıt kenarlarını bulur; üst kenar bir karede, alt kenar başka karede görülmesi yeterlidir (ayar: kapalı / üst-alt / dört kenar,
   varsayılan üst-alt). Eksik kenar varsa "Sayfanın alt kenarı görünmedi. Sayfayı yeniden gezdirin." denir ve sayfa yeniden istenir; bir
   sayfa için en çok çekim sayısı (varsayılan 2) dolunca sayfa olduğu gibi alınır ("… görünmemiş olabilir" denir). Kenar güvenilir
   bulunan kare sayısı 3'ten azsa (Vision bulamadıysa) denetim sessizce atlanır. **Bu denetimin gerçek sayfalarda ne kadar doğru çalıştığı
   telefonda denenmedi**: yakın çekimde kâğıt kenarı hiç görünmeyebilir; yanlış alarm olursa Ayarlar'dan "Kapalı" seçin.
6. Alınan sayfa için: videodan zaman çizgisi boyunca 8 dilimin en net karesi seçilir (parlamalı kare cezalı) ve çok sayfalı PDF yapılır
   (`Sayfa01.pdf`); video `Sayfa01.mp4` olarak klasöre yazılır. Sesle "Birinci sayfa alındı." denir.
7. Bitiş: ayarda sayfa sayısı varsa o kadar sayfa alınınca. Sayfa sayısı girilmediyse en az bir sayfa alındıktan sonra kadraj 20 sn boş
   kalırsa ya da 90 sn yeni sayfa gelmezse. Toplam süre sınırı 15 dk (ayar). "Tarama bitti. N sayfa alındı." denir.
   Aynı sayfa iki kez taranırsa cevaplar soru numarasına göre birleşir (zararsız ama gereksiz iş).
8. İnternet tarama sırasında kapalıdır (kamera Wi-Fi'sinde hücresel kesilir). Tarama bitince kamera akışı durdurulur, internet yoklanır,
   yoksa ayardaki TEK internet kestirmesi (Wi-Fi kapat → 2 sn bekle → hücreseli aç) ayardaki sayıda/aralıkla çalıştırılır; internet gelince durur.
9. Gemini: her sayfa için gezdirme videosu ve/veya net karelerin PDF'i, standart bir istemle 4 profillik zincire gider (Gemini 3.6 Flash →
   3.5 Flash-Lite → 3.1 Flash-Lite ücretsiz → 3.1 Flash-Lite ücretli). Kota dolarsa / hata olursa / cevap gecikirse sıradaki modele geçilir
   ve nedeni sesle söylenir. Bir istekte en çok 4 sayfa ve ≈14 MB (inline sınırı 20 MB) gider; gönderilemeyen sayfalar bir kez yeniden denenir.
   **Gemini'ye ne gider (Ayarlar > Gemini):** *Video + net kareler* (varsayılan), *Yalnız net kareler*, *Yalnız video*.
   İstem Gemini'ye şunu söyler: sayfa yakından gezdirilerek çekildi, kareler birbirini kısmen örter, bir soru bir karede yarım olabilir,
   kareleri birleştir; soru numarasını sayfadaki yazıdan oku; yarım ya da okunamayan soru için `okunamadi` yaz. Soru sayısı biliniyorsa
   numaraların 1–N arasında olduğu da söylenir. Görüntü çözünürlüğü `MEDIA_RESOLUTION_HIGH` istenir.
   **Bilinen sınır (belgeli):** Gemini videoyu saniyede 1 kare örnekler (kayıt 2 kare/sn olduğundan her ikinci kare atlanır) ve Gemini 3
   modellerinde videonun kare başına belirteç bütçesi görüntününkinden küçüktür (yüksek çözünürlükte bile video karesi ≈280, görüntü ≈1120);
   küçük yazı videoda zor okunabilir. Bu yüzden varsayılan olarak videonun yanında net kareler de gider. Hangi ayarın daha iyi okuduğu
   **denenmedi**; cihazda ve gerçek sınav kâğıdıyla karşılaştırılmalı.
10. Cevaplar Gemini'nin okuduğu soru numarasına göre sıralanır, kulaklıkla okunur ("Birinci soru, ADANA, kırk iki."; şık kodu ayardaki
    "Şık kodları"ndan), her cevaptan sonra ilk okuma için 3 sn, tekrar için 5 sn beklenir; sonra "Cevaplar bir kez daha okunuyor", hepsi
    tekrar okunur. Soru sayısı girildiyse cevabı gelmeyen / okunamayan numaralar sayılır ("Okunamayan ya da cevaplanamayan sorular: …"),
    "Deneme sınavı tamamlandı" denir. `Cevaplar.txt` sınav alt klasörüne yazılır. Eksik soru için kamera yeniden açılmaz.

## Dosyalar
`G526 Belgeler/Sinav-yyyyMMdd-HHmm/` altında: `Sayfa01.pdf`, `Sayfa01.mp4`, `Sayfa02.pdf` …, `Cevaplar.txt`. Klasör telefonda kalır, program silmez.

## Arama / mesaj engelleme
Uygulama aramaları ya da mesajları engelleyemez. Sınav süresince Odak (Rahatsız Etme) kullanın ve Kestirmeler otomasyonuyla aynı saatte
Odak'ı açın; arama/mesaj tamamen susmayabilir, bunu garanti etmiyoruz.

## Kullanıcının kuracağı kestirmeler
- Kamera Wi-Fi'sini açan kestirme (örn. "Kamera Wi-Fi") — adı Ayarlar > Kestirmeler'e yazılır.
- İnternet kestirmesi: Wi-Fi'yi kapat → 2 sn bekle → hücresel veriyi aç — adı aynı yere yazılır.
- Günün Saati otomasyonu: `seslikontrol://basla` adresini aç (Hemen Çalıştır).
- İsteğe bağlı "G526 Kestirme Seç": ayarlarda adı yazmak yerine listeden seçmek için (Ayarlar'daki yardım metni anlatır).

## Kod haritası
- Saf mantık (CI'da sınanır): `PageSweep` (kenar kapsaması, net kare seçimi), `ScanRules`, `ReadingPlan`, `TurkishNumbers`, `AnswerService`, `PageEdges`, `DocumentGate`.
- Akış: `AppModel` (+Scan, +Answers). Kamera hattı: `CameraClient` → `H264Decoder` → `FramePipeline` → `FrameCollector` / `VideoRecorder`.
- Gemini: `Gemini`, `GeminiProfiles`, `AnswerService`. Kestirmeler ve internet yoklaması: `Kestirme`.
- Kullanılmayan ama silinmemiş: `Guidance.swift` içindeki konum tarifi motoru (`GuidanceEngine`, `GuidanceAdvisor` …) ve testleri. Yalnız belge
  ölçümü (`GuidanceAnalyzer`, `PageMetrics`, `DocumentGate`) kullanılır. Silinecek adaydır.
