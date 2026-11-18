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
            Picker("Çekim akışı (deneme)", selection: $camera.streamOverride) {
                Text("Otomatik (şimdiki gibi)").tag(0)
                Text("Akış 1 – ana (1920×1080)").tag(1)
                Text("Akış 2 – alt (640×360)").tag(2)
                Text("Akış 3 – bilinmiyor, denenecek").tag(3)
            }
            HelpRow("Çekim akışı: “Otomatik” bırakırsanız hiçbir şey değişmez (toplu çekimde akış 1; eski tek soru çekiminde yukarıdaki Görüntü ayarı). 1, 2 ya da 3 seçerseniz HER çekim o akışla yapılır; “Görüntü” ayarı o zaman yok sayılır. Kameranın üç akışı var; akış 3'ün ne verdiği bilinmiyor. Hangi akışın gerçekte ne verdiği (boyut, saniyedeki kare, bitrate) her çekimin sonunda günlüğe “akış ölçümü” satırı olarak yazılır; Deneme çekimi ve Kamerayı dene satırlarında da görünür. Düşük çözünürlüklü akışlarda soru yazısı okunmayabilir: yalnız deneme içindir, deneme bitince “Otomatik”e dönün.")
            Picker("Kadraj yönü", selection: $camera.guidanceFrame) {
                Text("Yatay").tag(0)
                Text("Dikey (tam sayfa)").tag(1)
            }
            Picker("Görüntü yönü", selection: $camera.imageOrientation) {
                ForEach(CameraSettings.orientations(forFrame: camera.guidanceFrame), id: \.self) { o in
                    Text(o.title).tag(o)
                }
            }
            Toggle("Yazının yönünü kendiliğinden bul", isOn: $camera.autoOrientation)
            HelpRow("Kamera sayfaya alttan ya da yandan bakınca yazı yan ya da ters görünür. Açıkken yazı tanıma gerekirse yan ve ters yönleri de dener; yazı okunan yönde ölçülür, fotoğraflar PDF'e dik girer. Sesli yön cümleleri (sağa, sola, yukarı, aşağı) kameranın kendi duruşuna göre söylenir. Kapalıyken yalnız yukarıdaki Görüntü yönü geçerlidir. Cihazda doğrulanmadı.")
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
            Toggle("Toplu çekim (bir oturumda birçok sayfa, süre sınırlı)", isOn: $camera.pageSeries)
            Stepper(value: $camera.seriesSeconds, in: CameraSettings.seriesSecondsRange, step: CameraSettings.seriesSecondsStep) {
                Text("Oturum süresi \(camera.seriesSeconds) sn (en çok \(camera.seriesSeconds * 2) kare)")
            }
            Toggle("Kamera çalışırken telefonun mikrofonunu kullan", isOn: $camera.phoneMic)
            Toggle("Çekimde yaka mikrofonunu elle kapat (uyarı ver)", isOn: $camera.muteLapel)
            if camera.muteLapel {
                Stepper(value: $camera.lapelOffSeconds, in: CameraSettings.lapelOffSecondsRange) {
                    Text("“Başla”dan çekime bekleme: \(camera.lapelOffSeconds) sn")
                }
            }
            HelpRow("Kamera çalışırken telefonun mikrofonunu kullan (varsayılan AÇIK): yaka mikrofonları (BOYA gibi) 2,4 GHz ile çalışır ve kameranın Wi-Fi'sini bozabilir (günlükte yaka mikrofonu takılıyken kamera oturumlarının %42'si koptu, alıcı çıkıkken %14). “Başla” deyince program ses girişini kendisi telefonun mikrofonuna alır (“Başla”yı yaka mikrofonu duyar); kamera açılıp çekim bitene ve internete dönülene kadar öyle kalır, sonra yaka mikrofonuna döner. iOS yaka mikrofonunun alıcısını ve vericisini kapatmaya izin vermez: alıcı takılı, verici açık kalır, yalnız ses girişi değişir. Bu paraziti ortadan kaldırmayabilir; etkisi çekim başlarken günlüğe yazılan ses yolu satırları ve oturum sonundaki paket tekrarı oranından anlaşılır. Parazit sürerse vericiyi ve alıcıyı çekim süresince kendiniz kapatın ya da çıkarın.")
            HelpRow("Çekimde yaka mikrofonunu elle kapat (varsayılan KAPALI): açılırsa “Başla” deyince program “Yaka mikrofonunu kapatın, N saniye sonra başlıyorum” der, ayardaki süre kadar bekler, sonra kamera açılır; çekim bitip internet ve kulaklık gelince “Yaka mikrofonunu açın” der ve alıcı ses yoluna girene (en çok 15 sn) kadar bekler. Vericiyi sizin kapatmanız gerekir (yazılım kapatamaz). Telefonun mikrofonu ayarıyla birlikte de kullanılabilir.")
            HelpRow("Toplu çekim (varsayılan AÇIK): Kamera “Başla”dan SONRA açılır: açılışta kameraya bağlanılmaz, talimat beklenirken kamera kapalıdır ve internet açıktır; program “Kamera oturumu için talimatınızı bekliyorum. Başla deyince geri sayımla başlayacak; süreniz N saniye” der. “Başla” deyince “Kamera açılıyor” der, kameraya geçer (hücresel kapanır; uçak modu kulaklığı düşürür, aşağıdaki Bluetooth kestirmesi geri getirir), görüntü gelince “Hazır olun” der, beşten bire sayar, sonra “Başladı” der ve süre başlar; kameraya geçiş 20–35 sn sürebilir. Toplu çekimde sesli konumlandırma AÇIKSA çekim SERBEST TARAMADIR (varsayılan 60 sn, hedef 2 sayfa; 30–180 sn ayarlanır): program komut vermez, yalnız her 10 saniyede geçen süreyi söyler (“10 saniye”, “20 saniye”…). Kamerayı sayfaya yakın tutup yavaşça gezdirin; sayfanın tamamını sığdırmaya çalışmayın (uzaklaşınca yazı okunmaz). Tarama boyunca saniyede 2 kare alınır (her yarım saniyenin en net karesi; 60 sn'de en çok 120). Bozuk (bloklaşmış) ve bulanık kareler, aynı 10 saniyede sağlam kare varsa gönderilmez; yazısı okunan kare, kamera oynasa da bulanık sayılmaz. Kameradan 3 sn görüntü gelmezse program “Kameradan görüntü gelmiyor, bekleyin” der ve süreyi bekletir. Kareler çekildikleri zaman aralığının etiketiyle Gemini'ye gider; Gemini örtüşen kareleri birleştirir. Konumlandırma KAPALIYSA çekim sessizdir: sayfa sayısı ya da sayfa başına süre yoktur, sayfaları istediğiniz hızda gösterirsiniz, kamera her saniyenin en net karesini saklar. Bütün oturumun fotoğrafları TEK PDF olur ve tek seferde Gemini'ye gider (16 MB'ı aşarsa fotoğraflar biraz daha düşük kaliteyle yeniden sıkıştırılır; yükleme ve okuma birkaç dakika sürebilir). Süre dolunca kamera kapanır, kestirme hücreseli açar; Gemini görüntülerdeki BÜTÜN soru ve paragraf sorularını cevaplar, cevaplar soru numarası, şık sözcüğü ve doğru şıkkın metniyle sırayla okunur, her cevap arasında 2 sn boşluk olur. Sonra program yeniden talimat bekler; kamera bir sonraki “Başla”ya kadar kapalı kalır. “Başla” denmezse süre kendiliğinden başlamaz. “Kameraya geç” kestirmesi (uçak modu) kulaklığı düşürür; program hemen ardından “Bluetooth yenile” kestirmesini çalıştırıp kulaklığı geri getirir (Ayarlar > Kestirmeler'de dolu olmalıdır). Toplu çekimde video gönderilmez. Kapatırsanız her çekim tek bir sorudur (eski düzen).")
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
            Toggle("Toplu çekimde süre anonsu ve sayfa denetimi (serbest tarama)", isOn: $camera.seriesGuidance)
            HelpRow("Açıkken (varsayılan) toplu çekim ve deneme çekimi SERBEST TARAMADIR: program yön ya da bölüm komutu vermez, kadraj aramaz; yalnız her 10 saniyede geçen süreyi söyler. Her 30 saniyenin (bir sayfalık tarama) sonunda o sayfanın görüntülerine bakar: iyiyse “Birinci sayfa tamam. Sonraki sayfaya geçin.” der; kötüyse nedenini söyler (“Birinci sayfa okunamadı: blok bozulmaları ve bulanıklık var. Bu sayfayı yeniden, yavaşça tarayın.”) ve o sayfa için 30 saniye daha verir (sayfa başına bir kez). Kötü görüntüler saklanmaz; yalnız iyi görüntüler PDF olur ve internet gelince Gemini'ye gider. Kapalıyken çekim tümüyle sessizdir ve program her yarım saniyenin en net karesini kendi seçer (eski düzen). Sesli komut: “toplu çekimde konumlandırmayı aç / kapat”.")
            Group {
                Toggle("Büyük PDF'i dosya olarak yükle (kareler sıkıştırılmaz)", isOn: $camera.largeUpload)
                HelpRow("Açıkken (varsayılan) toplu çekimin kareleri sıkıştırılmadan PDF olur (45 MB'a kadar; Gemini'nin PDF sınırı 50 MB'tır). 16 MB'ı aşan PDF önce Gemini'ye DOSYA olarak bir kez yüklenir, isteğe yalnız adresi girer: model yoğun olup sıradaki modele geçilse de dosya yeniden gönderilmez. Yükleme hücresel veriyle birkaç dakika sürebilir ve veri harcar (40 MB'a kadar). Yükleme başarısız olursa PDF eski yoldan, isteğin içinde gider. Kapalıyken eski düzen geçerlidir: PDF 16 MB'ı aşarsa kareler daha düşük kaliteyle yeniden sıkıştırılır. Cihazda denenmedi; sorun çıkarsa kapatın.")
                Toggle("Güçlü yazı okuma (serbest taramada)", isOn: $camera.accurateReading)
                HelpRow("Açıkken (varsayılan) serbest taramada telefon kareleri Apple'ın güçlü (yavaş) yazı okuma kipiyle okur: soru numaraları daha doğru çıkar. Sayfa denetiminde görülen sorular söylenir (“Görülen sorular: 10 ile 14 arası”); iki komşusu görülüp kendisi görülmeyen bir numara varsa (“12. soru görülmedi”) sayfa bir kez yeniden taratılır. Telefon saniyede iki kareye yetişemezse o oturumda kendiliğinden hızlı okumaya dönülür (günlüğe yazılır). Kapalıyken hızlı okuma kullanılır ve eksik numara yüzünden yeniden tarama istenmez. Şıkların (A–E) tam görünüp görünmediğine bakılmaz. Cihazda denenmedi; ısınma ya da yavaşlama olursa kapatın.")
                Toggle("Hareket takibi (serbest taramada)", isOn: $camera.motionTracking)
                HelpRow("Açıkken (varsayılan) telefon ardışık kareleri birbirine hizalayıp kameranın ne hızla ve ne kadar kaydığını ölçer. Bu sürümde yalnız danışmandır: sayfa okunamadıysa ve kamera hızlı kaydırıldıysa bunu söyler (“kamera hızlı kaydırıldı, daha yavaş tarayın”); kamera 30 saniye boyunca aynı yerde kaldıysa “Kamera az kaydırıldı; sayfanın tamamı görünmemiş olabilir” der. Hiçbir kareyi elemez, hiçbir sayfayı kendi başına kötü saymaz; ölçümler günlüğe yazılır ve eşikler ilk çekimlere göre ayarlanacaktır. Cihazda denenmedi; yavaşlama olursa kapatın.")
            }
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
            Button("Akış denemesi (1, 2, 3 ölç)") {
                Task { await tester.runStreamSurvey() }
            }
            .disabled(tester.running)
            // Ana ekrandaki "Deneme çekimi"nin satırları orada gösterilir; burada yalnız bu sınamanın satırları
            ForEach(Array((tester.showsTrial ? [] : tester.lines).enumerated()), id: \.offset) { _, line in
                Text(line).font(.footnote).fixedSize(horizontal: false, vertical: true)
            }
            if !tester.showsTrial, let data = tester.lastPhoto, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 180)
                    .accessibilityLabel("Deneme çekiminin fotoğrafı")
            }
            HelpRow("Sınavdaki adımları sırayla yürütür: “Kameraya geç” kestirmesi, kameraya bağlanıp bir çekim (hiçbir yere gönderilmez, silinir), “Hücresele geç” kestirmesi ve internetin gelmesi. Kamera ilk kez açılırken iOS “yerel ağ” izni sorar: sınavda bu kutuyla uğraşmamak için sınavdan önce bir kez deneyip “İzin ver”e basın. Kestirmelerin Wi-Fi ile hücreseli gerçekten değiştirip değiştirmediği ve kameranın ağına kendiliğinden bağlanıp bağlanmadığı da burada görülür. Kamerayı çalıştırın ve bir sayfayı kadraja tutun; sınama en çok bir buçuk dakika sürer. Çekilen deneme fotoğrafı altta küçük resim olarak görünür (kadraj ve netlik gözle denetlenir; fotoğraf hiçbir yere gönderilmez).")
            HelpRow("Akış denemesi: “Kameraya geç” kestirmesinden sonra kameranın 1, 2 ve 3 numaralı akışlarını sırayla açar ve her birini yaklaşık 8 sn ölçer: gerçek görüntü boyutu, saniyedeki kare sayısı ve bitrate. İlk bağlantıda kameranın yalnız okuma bilgi komutlarını da sorgular (pozlama bilgisi dahil) ve cevapları ekrana ile günlüğe yazar. Kameranın hiçbir ayarını değiştirmez, hiçbir şey kaydetmez ya da göndermez. Bir akış açılmazsa “görüntü gelmedi” yazar. Sonra “Hücresele geç” kestirmesiyle internete döner; yaklaşık 1–2 dakika sürer.")
        }
    }
}
