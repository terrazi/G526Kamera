import SwiftUI

/// Kamera ayarları (V1'deki kamera bölümleri). Her bölüm `CameraSettings.Group` ile birebir eşleşir; hangi ayar hangi bölümde olduğu
/// `CameraSettings.Group.keys` listesindedir ve testle denetlenir.
struct CameraSettingsSections: View {
    @EnvironmentObject private var camera: CameraSettings

    var body: some View {
        Group {
            cameraSection
            videoSection
            photoSection
            motionSection
            voiceSection
            guidanceSection
            powerSection
            shortcutSection
        }
    }

    // MARK: Kamera

    private var cameraSection: some View {
        Section(header: Text(CameraSettings.Group.camera.title)) {
            TextField("Kamera adı (UID)", text: $camera.uid)
                .textInputAutocapitalization(.characters)
                .disableAutocorrection(true)
            TextField("Kamera IP (isteğe bağlı)", text: $camera.cameraIP)
                .keyboardType(.numbersAndPunctuation)
                .disableAutocorrection(true)
            SecureField("Kamera parolası", text: $camera.cameraPassword)
            Picker("Görüntü", selection: $camera.streamQuality) {
                Text("Yüksek 1920×1080").tag(1)
                Text("Düşük 640×360").tag(2)
            }
            Picker("Kadraj yönü", selection: $camera.guidanceFrame) {
                Text("Yatay").tag(0)
                Text("Dikey (tam sayfa)").tag(1)
            }
            Picker("Görüntü yönü", selection: $camera.imageOrientation) {
                ForEach(CameraSettings.orientations(forFrame: camera.guidanceFrame), id: \.self) { o in
                    Text(o.title).tag(o)
                }
            }
            HelpRow("Kadraj yönü: önizleme kutusu ve sesli yönlendirme bu seçime uyar. “Dikey”: kutu dikeydir (9:16) ve kamera görüntüsü 90° çevrilir, böylece kameranın gördüğünün tamamı kırpılmadan kutuya oturur. “Yatay”: kutu yataydır (16:9) ve görüntü olduğu gibi kullanılır (ters takılıysa 180°). Görüntü yönü: Dikey kadrajda “90° sağa” ya da “90° sola” (sayfa yan yatıyorsa öbürünü seçin), Yatay kadrajda “Normal” ya da “180°”. Seçtiğiniz yön önizlemeye, çekilen fotoğrafa, kaydedilen videoya ve sesli yönlendirmedeki sağ / sol / yukarı / aşağıya uygulanır. Fotoğraf kırpılmaz.")
            HelpRow("Kamera adı (UID) hazır yazılı gelir; başka bir kamera için silip yenisini yazabilirsiniz. IP boş bırakılırsa kamera kendiliğinden bulunur. Çekim sırasında telefon kameranın Wi-Fi ağına bağlıdır; çekim bitince program Wi-Fi'yi bırakıp hücresel veriyle Gemini'ye gönderir.")
        }
    }

    // MARK: Video

    private var videoSection: some View {
        Section(header: Text(CameraSettings.Group.video.title)) {
            Stepper(value: $camera.pageVideoSeconds, in: VideoRecorder.pageSecondsRange) {
                Text("Soru videosu: sayfa başına \(camera.pageVideoSeconds) sn")
            }
            Stepper(value: $camera.examVideoMaxSeconds, in: VideoRecorder.examSecondsRange, step: VideoRecorder.secondsStep) {
                Text("Soru videosu: en çok \(camera.examVideoMaxSeconds) sn")
            }
            Toggle("Videoyu da Gemini'ye gönder", isOn: $camera.videoToGemini)
            Toggle("Videoyu yüksek çözünürlükle oku", isOn: $camera.videoHighRes)
            TextField("Gemini'ye ek talimat (isteğe bağlı)", text: $camera.videoQuestion)
            HelpRow("Program soruyu sesle konumlandırır; konum uygun olunca soruyu ayardaki süre kadar (varsayılan 5 sn, 2–15) videoya yazar ve bir fotoğraf çeker. Süre sınırı yalnız kaydedilen saniyeleri sayar (10–300 sn, 10'ar sn adımla). Video saniyede 2 kare yazılır; tahmini boyut: 30 sn ≈ 4,5–8 MB, 90 sn ≈ 14–24 MB. 14 MB'ı aşan video Gemini'ye yüklenerek gönderilir. “Videoyu da gönder” kapalıyken yalnız fotoğraf gider. “Yüksek çözünürlük” küçük yazı için önerilir. Ek talimat, programın kendi talimatının sonuna eklenir (programın talimatı kadrajdaki yarım görünen komşu soruların yok sayılmasını da içerir). Değişiklik bir sonraki çekimden itibaren geçerlidir.")
        }
    }

    // MARK: Fotoğraf

    private var photoSection: some View {
        Section(header: Text(CameraSettings.Group.photo.title)) {
            Picker("İyileştirme", selection: $camera.enhancement) {
                Text("Kapalı").tag(0)
                Text("Hafif").tag(1)
                Text("Güçlü").tag(2)
            }
            .pickerStyle(.segmented)
            Toggle("Birkaç net kareyi birleştir", isOn: $camera.multiFrame)
            Toggle("Yalnız belge çek (belge değilse çekme)", isOn: $camera.documentOnly)
            Toggle("Belgeyi otomatik düzelt ve kırp (deneysel)", isOn: $camera.deskew)
            Picker("Tarih/saat yazısı", selection: $camera.timestampMode) {
                Text("Bulanıklaştır (okunmaz)").tag(TimestampMode.blur)
                Text("Kes (üst şeridi at)").tag(TimestampMode.crop)
                Text("Olduğu gibi bırak").tag(TimestampMode.keep)
            }
            Picker("Büyütme", selection: $camera.upscale) {
                Text("1×").tag(1.0)
                Text("1,5×").tag(1.5)
                Text("2×").tag(2.0)
            }
            .pickerStyle(.segmented)
            VStack(alignment: .leading) {
                Text("JPEG kalitesi: %\(Int((camera.jpegQuality * 100).rounded()))")
                Slider(value: $camera.jpegQuality, in: 0.7...1.0, step: 0.01)
            }
            Stepper(value: $camera.burstBefore, in: 0...1.5, step: 0.1) {
                Text(String(format: "Seri çekim: öncesi %.1f sn", camera.burstBefore))
            }
            Stepper(value: $camera.burstAfter, in: 0.2...2.0, step: 0.1) {
                Text(String(format: "Seri çekim: sonrası %.1f sn", camera.burstAfter))
            }
            HelpRow("“Yalnız belge çek” açıkken kadrajda kâğıt ve üzerinde yazı yoksa (el, yüz, boş masa, duvar, çizgili desen) fotoğraf çekilmez; program “Belge görünmüyor” der. Belge hiç çekilmiyorsa ya da bu kontrol rahatsız ederse kapatın. Belge taraması için: İyileştirme Hafif, kalite %92 ve üzeri, Yüksek 1920×1080 görüntü önerilir. Büyütme ayrıntı eklemez, yalnızca yazıyı daha rahat okutur. Kamera tarih/saati görüntünün içine işler, silinemez: Bulanıklaştır yalnızca sağ üstteki tarih yazısının kutusunu okunmaz yapar, Kes ise üstteki şeridi atar (fotoğraf biraz kısalır).")
        }
    }

    // MARK: Otomatik çekim

    private var motionSection: some View {
        Section(header: Text(CameraSettings.Group.motion.title)) {
            // Sesli konumlandırma açıkken otomatik çekim çalışmaz: anahtar kapalı ve basılamaz görünür
            Toggle("Görüntü değişince çek", isOn: camera.guidanceEnabled ? Binding<Bool>.constant(false) : $camera.motionEnabled)
                .disabled(camera.guidanceEnabled)
            if camera.guidanceEnabled {
                Text("Sesli konumlandırma açıkken kullanılamaz.").font(.caption).foregroundColor(.secondary)
            }
            Picker("Duyarlılık", selection: $camera.motionSensitivity) {
                Text("Düşük").tag(0)
                Text("Orta").tag(1)
                Text("Yüksek").tag(2)
            }
            .pickerStyle(.segmented)
            HelpRow("Sesli konumlandırma kapalıyken geçerlidir: kamera önüne yeni bir soru sayfası konup görüntü durulunca bir kez çeker. Sayfa değişmedikçe tekrar çekmez.")
        }
    }

    // MARK: Sesle çekim

    private var voiceSection: some View {
        Section(header: Text(CameraSettings.Group.voice.title),
                footer: Text("Birden fazla sözcüğü virgülle ayırabilirsiniz.")) {
            Toggle("Sesli komutla çek", isOn: $camera.voiceEnabled)
            TextField("Tetikleme sözcüğü", text: $camera.triggerWord)
                .disableAutocorrection(true)
            Stepper(value: $camera.cooldown, in: 2...20, step: 1) {
                Text("İki çekim arası bekleme: \(Int(camera.cooldown)) sn")
            }
            HelpRow("Konum uygun olunca program kendiliğinden çeker (“Konum uygunsa kendiliğinden çek” açıksa); kapalıyken tetikleme sözcüğünü söylemenizi bekler. Sözcük, çekim sırasında kulaklıktan gelen sesinizden aranır.")
        }
    }

    // MARK: Sesli konumlandırma

    private var guidanceSection: some View {
        Section(header: Text(CameraSettings.Group.guidance.title)) {
            Toggle("Sesle konumlandır", isOn: $camera.guidanceEnabled)
            Toggle("Uyarıları sesli söyle", isOn: $camera.guidanceVoice)
            Toggle("Video çekerken de konum tarifi ver", isOn: $camera.videoGuidance)
            Toggle("Kamera ve gönderim durumunu da söyle", isOn: $camera.statusNotices)
            Toggle("Konum uygunsa kendiliğinden çek", isOn: $camera.guidanceAutoCapture)
            Picker("Netlik isteği", selection: $camera.guidanceSharpness) {
                Text("Gevşek").tag(0)
                Text("Normal").tag(1)
                Text("Sıkı").tag(2)
            }
            Toggle("Parlama uyarısı", isOn: $camera.guidanceGlare)
            Toggle("Kadrajı tarif et", isOn: $camera.guidanceDescribe)
            Toggle("Sayfa kenarını da algıla", isOn: $camera.guidancePageEdges)
                .disabled(!camera.guidanceDescribe)
            Toggle("Tam sığan bölümü kendiliğinden seç", isOn: $camera.guidanceAutoPick)
            HelpRow("Program sayfayı ölçer ve “biraz sağa”, “yukarı”, “uzaklaş”, “yaklaş” gibi sesli yönlendirir; konum uygun olunca birkaç kareyi seri çekip en netini alır. Konumlandırma kısa tutulur: sorulan soru kadraja sığıyorsa hemen çekilir; kenarlarda yarım görünen komşu sorular sorun sayılmaz ve “soru bölünüyor” gibi uyarı verilmez (Gemini'ye de bu yarım soruların yok sayılması bildirilir). “Kadrajı tarif et” açıkken program kadrajda ne olduğunu da söyler (varsayılan kapalı). Yönlendirme sağa / sola / yukarı / aşağı için “azıcık, biraz, epey” der, doğru yöne gidip gitmediğinizi söyler ve konum düzelince “Tamam” der. Sayfada parlama (doymuş beyaz leke) görürse en çok iki kez uyarır, sonra yine de çeker. “Kamera ve gönderim durumunu da söyle” açıkken kamera koptu / geri geldi, gönderim başladı / bitti gibi haberler kısaca söylenir. Telefonda denenmemiş özellikler: sayfa kenarı algılama ve parlama kontrolü; rahatsız ederse kapatın.")
        }
    }

    // MARK: Pil ve ısınma

    private var powerSection: some View {
        Section(header: Text(CameraSettings.Group.power.title)) {
            Toggle("Canlı önizlemeyi kapat", isOn: $camera.previewOff)
            HelpRow("Önizleme kapalıyken ekrana video çizilmez ve kareler seyreltilerek incelenir; fotoğraf çekme ve video kaydı aynen çalışır. Kamera kadrajını önce önizlemeyle ayarlayın. Ekran parlaklığını azaltmak için “Telefon sesi ve ekran” bölümündeki ayarı kullanın. Kamera yayını, Wi-Fi ve mikrofon yine çalıştığı için pil ve ısınma tamamen sıfırlanmaz.")
        }
    }

    // MARK: Kestirme

    private var shortcutSection: some View {
        Section(header: Text(CameraSettings.Group.shortcuts.title)) {
            TextField("Kamera Wi-Fi kestirmesi", text: $camera.cameraShortcutName)
                .disableAutocorrection(true)
            HelpRow("Kestirmeler uygulamasındaki kestirmenin adı: telefonu kameranın Wi-Fi ağına bağlar ve hücresel veriyi keser. Program çekimden önce çalıştırır; çekim bitince Wi-Fi'yi bırakıp hücresele geçiren kestirme “Kestirmeler (kendi kendini onarma)” bölümündedir. Boşsa bu adım atlanır.")
        }
    }
}
