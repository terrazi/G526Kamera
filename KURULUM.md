# G526 Kamera — Kurulum (iPhone 12 mini, Mac gerekmez)

Bu uygulama G526 (LookCam / MYKJ) Wi-Fi kameranızdan canlı görüntü alır, kâğıdı sayfa sayfa (kamerayı sayfada gezdirerek) video olarak
çeker, videoyu ve net kareleri Gemini'ye gönderir, soru numaralarını Gemini okur ve cevapları kulaklıktan okur. Ayrıntılı işleyiş: `docs/YENI_SURUM_TASARIM.md`.

> Hiçbir özellik telefonda denenmedi; yalnız GitHub Actions'ta derlendi ve birim testlerden geçti.

## 1) Derleme (GitHub Actions)

1. Depoya `yeni-surum` dalına gönderilen her değişiklik kendiliğinden derlenir.
2. **Releases** sayfasında `yeni-surum` sürümünün altından `G526CameraDrive-unsigned.ipa` dosyasını indirin.
3. Derleme hata verirse aynı çalışmadaki `G526CameraDrive-Build-Log` dosyasına bakın.

## 2) iPhone'a yükleme (Sideloadly, Windows)

1. Sideloadly'de `.ipa` dosyasını sürükleyin, Apple ID'nizi yazın, **Start**.
2. iPhone: **Ayarlar > Genel > VPN ve Cihaz Yönetimi** → geliştirici profiline **Güven**.
3. iOS 16 ve üstünde: **Ayarlar > Gizlilik ve Güvenlik > Geliştirici Modu** açık olmalı.
4. Ücretsiz Apple ID ile uygulama **7 gün** sonra süresi dolar; Sideloadly ile aynı ayarlarla yeniden yükleyin.
5. İlk açılışta **Yerel Ağ** iznini verin (kameraya bağlanmak için).

## 3) Uygulamada ayar (sınavdan önce, bir kez)

**Ayarlar** (ana ekranda sağ üst):
- **Tarama:** soru sayısı ve sayfa sayısı (her sınavdan önce), şık sayısı (4/5), sayfa çekimi süresi, sayfa kenarı denetimi, sayfa başına en çok çekim, uyarı tekrarı, bekleme süreleri.
- **Kamera:** kamera adı (UID) hazır gelir; parola; görüntü yönü.
- **Kestirmeler:** kamera Wi-Fi kestirmesinin adı, internet kestirmesinin adı, deneme sayısı ve aralığı.
- **Gemini:** en az bir profile API anahtarı yapıştırın; **Anahtarı dene** ile sınayın. Eski sürümün anahtarları silinir, yeniden girin.
- **Gemini'ye gönderilen:** *Video + net kareler* (varsayılan), *Yalnız net kareler* ya da *Yalnız video*. Küçük yazıyı hangisinin daha iyi okuduğu denenmedi; sınav öncesi bir deneme sayfasıyla karşılaştırın.
- **Ses:** konuşma sesi ve hızı, okuma arası beklemeler. Ses yalnız kulaklığa verilir.
- **Belge klasörü:** "G526 Belgeler" klasörünü bir kez seçin.

## 4) iOS Kestirmeler / Otomasyon (sınavdan önce, bir kez)

1. **Kamera Wi-Fi kestirmesi:** telefonun Wi-Fi'sini açıp kamera ağına bağlayan kestirme.
2. **İnternet kestirmesi:** Wi-Fi'yi kapat → 2 saniye bekle → hücresel veriyi aç.
3. **Otomasyon > Günün Saati:** sınav saati, eylem "URL'yi Aç": `g526kamera://basla`, **Hemen Çalıştır**.
4. İsteğe bağlı: sınav süresince **Odak** (Rahatsız Etme) açan otomasyon. Uygulama aramaları/mesajları engelleyemez.

## 5) Sınav günü
Telefon açık, ekran açık, şarjda ve kulaklık takılı olsun. Evrakı kameranın önüne tutun; belge görününce 2 sn sonra çekim başlar: kamerayı sayfanın üstünde yakından, yavaşça üstten alta gezdirin (iki sütunluysa sütun sütun). Konum tarifi yoktur; yalnız “N. sayfa alındı” ve sayfa kenarı görünmediyse “yeniden gezdirin” denir. Gerisini program yapar.

## Sorun giderme
- **Kamera bulunamadı:** Ayarlar > G526 Kamera > **Yerel Ağ** açık mı? UID doğru mu? Kamera Wi-Fi kestirmesi çalıştı mı?
- **İnternete ulaşılamadı:** internet kestirmesinin adı ayarda yazılı mı, kestirme tek başına çalıştırınca internet geliyor mu?
- **Gemini cevap vermiyor:** kırmızı kutu nedeni söyler (anahtar geçersiz, kota doldu…). Model zinciri sıradaki profile kendiliğinden geçer.
- **Ses gelmiyor:** kulaklık takılı mı? Çıkış telefon hoparlörüyse program konuşmaz.
