import SwiftUI

/// Kamera ayarları: her bölüm Ayarlar'da akordiyon başlığıdır (bkz. `AccordionSection`).
struct CameraSettingsSections: View {
    @EnvironmentObject private var camera: CameraSettings
    @EnvironmentObject private var tester: CameraTester

    var body: some View {
        Group {
            cameraSection
            videoSection
            photoSection
            guidanceSection
            powerSection
            testSection
            CaptureFolderSection()
        }
    }

    // MARK: Kamera

    private var cameraSection: some View {
        AccordionSection(id: "kamera", title: "Kamera") {
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
        AccordionSection(id: "video", title: "Video kaydı") {
            Stepper(value: $camera.pageVideoSeconds, in: VideoRecorder.pageSecondsRange) {
                Text("Çekim süresi: soru ya da paragraf başına \(camera.pageVideoSeconds) sn")
            }
            Toggle("Çekim sırasında sesli geri sayım", isOn: $camera.countdown)
            Toggle("Videoyu da Gemini'ye gönder", isOn: $camera.videoToGemini)
            Toggle("Videoyu yüksek çözünürlükle oku", isOn: $camera.videoHighRes)
            TextField("Gemini'ye ek talimat (isteğe bağlı)", text: $camera.videoQuestion)
            HelpRow("Çekim süresi (varsayılan 10 sn, 2–15): kamera her soru ya da paragraf için bu kadar çeker. Her saniyenin en net karesi bir fotoğraf olur (10 sn = 10 fotoğraf); fotoğraflar tek PDF'e dizilir ve aynı sürenin küçük bir videosuyla birlikte Gemini'ye gider. Video H.264 / MP4, ses yok, saniyede 2 kare, yaklaşık 1,2 Mbit/sn: 10 sn ≈ 1,5 MB; her cihazda açılır. Çekim başlamadan önce program “10 saniye boyunca çekim yapabilirsiniz. Başlıyorum.” der, sonra çekim sessiz sürer (ekranı ya da kâğıdı bu sürede kameranın önünde gezdirin). “Çekim sırasında sesli geri sayım” açılırsa ayrıca 10, 9, 8 … 1 diye sayar; varsayılan KAPALI, çünkü sürekli konuşma kulaklık (Bluetooth) trafiği yaratır ve kamera bağlantısını bozabilir. Sesle konumlandırma açıksa çekimden önce konum beklenir; kapalıysa başlangıç cümlesi hemen söylenir. PDF ve video birlikte satır içi gider; toplamı 14 MB'ı aşarsa yalnız PDF gönderilir. “Videoyu da gönder” kapalıyken yalnız PDF gider. “Yüksek çözünürlük” küçük yazı için önerilir. Ek talimat, programın kendi talimatının sonuna eklenir (programın talimatı kadrajdaki yarım görünen komşu soruların yok sayılmasını da içerir). Değişiklik bir sonraki çekimden itibaren geçerlidir.")
        }
    }

    // MARK: Fotoğraf

    private var photoSection: some View {
        AccordionSection(id: "foto", title: "Fotoğraf") {
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
            HelpRow("“Yalnız belge çek” açıkken kadrajda kâğıt ve üzerinde yazı yoksa (el, yüz, boş masa, duvar, çizgili desen) fotoğraf çekilmez; program sayfa kadraja alınamadığını söyler ve soruyu sesle okumaya geçer. Belge hiç çekilmiyorsa ya da bu kontrol rahatsız ederse kapatın. Belge taraması için: İyileştirme Hafif, kalite %92 ve üzeri, Yüksek 1920×1080 görüntü önerilir. Büyütme ayrıntı eklemez, yalnızca yazıyı daha rahat okutur. Kamera tarih/saati görüntünün içine işler, silinemez: Bulanıklaştır yalnızca sağ üstteki tarih yazısının kutusunu okunmaz yapar, Kes ise üstteki şeridi atar (fotoğraf biraz kısalır).")
        }
    }

    // MARK: Sesli konumlandırma

    private var guidanceSection: some View {
        AccordionSection(id: "konumlandirma", title: "Sesli konumlandırma") {
            Toggle("Sesle konumlandır", isOn: $camera.guidanceEnabled)
            Toggle("Uyarıları sesli söyle", isOn: $camera.guidanceVoice)
            Toggle("Kamera ve gönderim durumunu da söyle", isOn: $camera.statusNotices)
            Picker("Netlik isteği", selection: $camera.guidanceSharpness) {
                Text("Gevşek").tag(0)
                Text("Normal").tag(1)
                Text("Sıkı").tag(2)
            }
            Toggle("Parlama uyarısı", isOn: $camera.guidanceGlare)
            Toggle("Kadrajı tarif et", isOn: $camera.guidanceDescribe)
            Toggle("Sayfa kenarını da algıla", isOn: $camera.guidancePageEdges)
                .disabled(!camera.guidanceDescribe)
            HelpRow("Çekim her zaman kendiliğinden yapılır; bölüm sorulmaz, kadrajın ortasındaki bölüm hedeflenir. Video sırasında tarif verilmez (video, sayfa durulduktan sonra kısa süre kaydedilir). “Sesle konumlandır” kapalıysa program konumlandırma yapmadan bağlanır bağlanmaz çeker.")
            HelpRow("Program sayfayı ölçer ve “biraz sağa”, “yukarı”, “uzaklaş”, “yaklaş” gibi sesli yönlendirir; konum uygun olunca birkaç kareyi seri çekip en netini alır. Konumlandırma kısa tutulur: sorulan soru kadraja sığıyorsa hemen çekilir; kenarlarda yarım görünen komşu sorular sorun sayılmaz ve “soru bölünüyor” gibi uyarı verilmez (Gemini'ye de bu yarım soruların yok sayılması bildirilir). “Kadrajı tarif et” açıkken program kadrajda ne olduğunu da söyler (varsayılan kapalı). Yönlendirme sağa / sola / yukarı / aşağı için “azıcık, biraz, epey” der, doğru yöne gidip gitmediğinizi söyler ve konum düzelince “Tamam” der. Sayfada parlama (doymuş beyaz leke) görürse en çok iki kez uyarır, sonra yine de çeker. “Kamera ve gönderim durumunu da söyle” açıkken kamera koptu / geri geldi, gönderim başladı / bitti gibi haberler kısaca söylenir. Telefonda denenmemiş özellikler: sayfa kenarı algılama ve parlama kontrolü; rahatsız ederse kapatın.")
        }
    }

    // MARK: Pil ve ısınma

    private var powerSection: some View {
        AccordionSection(id: "pil", title: "Pil ve ısınma") {
            Toggle("Canlı önizlemeyi kapat", isOn: $camera.previewOff)
            Toggle("Son fotoğrafı ana ekranda gösterme", isOn: $camera.lastShotOff)
            HelpRow("Açıkken ana ekranda “Son fotoğraf” kartı çıkmaz ve son çekimin küçük resmi bellekte tutulmaz (başkası ekrana bakıyorsa sınav sorusu görünmesin diye). Çekim ve gönderim aynen çalışır; “Kamerayı dene” küçük resmi bundan etkilenmez.")
            HelpRow("Önizleme kapalıyken ekrana video çizilmez ve kareler seyreltilerek incelenir; fotoğraf çekme ve video kaydı aynen çalışır. Kamera kadrajını önce önizlemeyle ayarlayın. Ekran parlaklığını azaltmak için “Telefon sesi ve ekran” bölümündeki ayarı kullanın. Kamera yayını, Wi-Fi ve mikrofon yine çalıştığı için pil ve ısınma tamamen sıfırlanmaz.")
        }
    }

    // MARK: Kamerayı dene

    private var testSection: some View {
        AccordionSection(id: "deneme", title: "Kamerayı dene (sınavdan önce)") {
            Button(tester.running ? "Durdur" : "Kamerayı dene") {
                if tester.running {
                    tester.stop()
                } else {
                    Task { await tester.run() }
                }
            }
            ForEach(Array(tester.lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.footnote).fixedSize(horizontal: false, vertical: true)
            }
            if let data = tester.lastPhoto, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 180)
                    .accessibilityLabel("Deneme çekiminin fotoğrafı")
            }
            HelpRow("Sınavdaki adımları sırayla yürütür: “Kameraya geç” kestirmesi, kameraya bağlanıp bir çekim (hiçbir yere gönderilmez, silinir), “Hücresele geç” kestirmesi ve internetin gelmesi. Kamera ilk kez açılırken iOS “yerel ağ” izni sorar: sınavda bu kutuyla uğraşmamak için sınavdan önce bir kez deneyip “İzin ver”e basın. Kestirmelerin Wi-Fi ile hücreseli gerçekten değiştirip değiştirmediği ve kameranın ağına kendiliğinden bağlanıp bağlanmadığı da burada görülür. Kamerayı çalıştırın ve bir sayfayı kadraja tutun; sınama en çok bir buçuk dakika sürer. Çekilen deneme fotoğrafı altta küçük resim olarak görünür (kadraj ve netlik gözle denetlenir; fotoğraf hiçbir yere gönderilmez).")
        }
    }
}
