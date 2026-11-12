import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @Environment(\.presentationMode) private var presentation
    @State private var voiceTestResult = ""
    @State private var modelListText = ""
    @State private var listingModels = false
    @State private var voices: [VoiceInfo] = SpeechVoiceChooser.sortedTurkish(SpeechVoiceChooser.installed())

    var body: some View {
        NavigationView {
            Form {
                cameraSection
                Section(header: Text("Bağlantılar")) {
                    NavigationLink(destination: geminiPage) {
                        HStack {
                            Text("Gemini ve API anahtarları")
                            if !settings.geminiPrivacyOK {
                                Spacer()
                                Text("gizlilik onayı gerekli").font(.footnote).foregroundColor(.orange)
                            }
                        }
                    }
                    HelpRow("Gemini API anahtarınızı ve gizlilik onayını buradan girersiniz. Diğer bütün ayarlar “Gelişmiş ayarlar” içindedir; varsayılan değerlerle çalışır, değiştirmeniz gerekmez.")
                }
                soundSection
                DocumentFolderSection()
                Section {
                    NavigationLink(destination: advancedPage) {
                        Text("Gelişmiş ayarlar")
                    }
                }
                Section {
                    NavigationLink(destination: DiagnosticsView()) {
                        Text("Tanı ve günlük")
                    }
                    HStack {
                        Text("Sürüm")
                        Spacer()
                        Text(BuildInfo.version)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Ayarlar")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { voices = SpeechVoiceChooser.sortedTurkish(SpeechVoiceChooser.installed()) }
            .onChange(of: settings.sendMode) { _ in model.queue.kick() }
            .onChange(of: settings.batchSize) { _ in model.queue.kick() }
            .onChange(of: settings.batchIdle) { _ in model.queue.kick() }
            .onChange(of: settings.uploadFormat) { _ in model.queue.kick() }
            .onChange(of: settings.geminiSessionTimeout) { value in
                if value < 0 { settings.geminiSessionTimeout = 0 }
                if value > 86400 { settings.geminiSessionTimeout = 86400 }
            }
            .onChange(of: settings.guidanceEnabled) { on in
                // Sesli konumlandırma açılınca fotoğraflar birikip "hepsi tamamlandı" ile tek PDF gitsin
                if on {
                    settings.sendMode = "batch"
                    settings.batchSize = 0
                    settings.batchIdle = 0
                    settings.uploadFormat = "pdf"
                    settings.motionEnabled = false
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Bitti") { presentation.wrappedValue.dismiss() }
                }
            }
        }
    }

    /// Gemini bölümleri (sesle soru, model profilleri ve API anahtarları)
    private var geminiPage: some View {
        Form {
            geminiPrivacySection
            geminiSection
            geminiModelsSection
        }
        .navigationTitle("Gemini")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Eski ayarların hepsi (değerleri aynen korunur); ilk ekranda görünmesin diye burada toplanır
    private var advancedPage: some View {
        Form {
            voiceSection
            readingVoiceSection
            examSection
            guidanceSection
            photoSection
            powerSection
            motionSection
            saveSection
            selfHealSection
        }
        .navigationTitle("Gelişmiş ayarlar")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Kestirmeler uygulamasındaki iki kestirmenin adı (ad boşsa o kestirme çalıştırılmaz)
    private var selfHealSection: some View {
        Section(header: Text("Kendi kendini onarma (kestirmeler)")) {
            TextField("Bağlantı kestirmesinin adı", text: $settings.connectionShortcutName)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .accessibilityIdentifier("baglanti-kestirmesi")
            TextField("Ses kestirmesinin adı", text: $settings.audioShortcutName)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .accessibilityIdentifier("ses-kestirmesi")
            HelpRow("Kestirmeler uygulamasında yaptığınız kestirmelerin adını aynen yazın; boş bırakılan kapalıdır. Bağlantı kestirmesi: internet 1-2 dakikadır yoksa çalışır (Hücresel Veriyi Ayarla Kapalı → Bekle 3 sn → Hücresel Veriyi Ayarla Açık). Ses kestirmesi: mikrofon 90 saniyedir hiç ses vermiyorsa ya da ses kulaklığa değil mikrofon alıcısına gidiyorsa çalışır (Bluetooth Kapalı → Bekle → Açık). Her kestirme en çok 3 kez, aralarında bekleyerek denenir. Çalışırken Kestirmeler birkaç saniye öne gelir, kamera bağlantısı bu sırada kopabilir; iPhone ilk çalıştırmada izin isteyebilir.")
        }
    }

    /// Ses çıkışı (kulaklık) seçimi ve ses denemesi
    private var soundSection: some View {
        Section(header: Text("Ses")) {
            HStack {
                Text("Ses çıkışını seç (kulaklık)")
                Spacer()
                RoutePickerButton()
                    .frame(width: 36, height: 36)
            }
            Button("Sesi dene") { voiceTestResult = model.testVoice() }
                .accessibilityIdentifier("sesi-dene")
            if !voiceTestResult.isEmpty {
                Text(voiceTestResult).font(.footnote).foregroundColor(.secondary)
            }
            HelpRow("Kulaklıktan dinlemek için ses çıkışı düğmesine basıp kulaklığınızı seçin. “Sesi dene” sesin hangi çıkışa ve hangi mikrofona gittiğini yazar.")
        }
    }

    private var cameraSection: some View {
        Section(header: Text("Kamera")) {
            TextField("Kamera adı (UID)", text: $settings.uid)
                .textInputAutocapitalization(.characters)
                .disableAutocorrection(true)
            TextField("Kamera IP (isteğe bağlı)", text: $settings.cameraIP)
                .keyboardType(.numbersAndPunctuation)
                .disableAutocorrection(true)
            SecureField("Kamera parolası", text: $settings.cameraPassword)
            Picker("Görüntü", selection: $settings.streamQuality) {
                Text("Yüksek 1920×1080").tag(1)
                Text("Düşük 640×360").tag(2)
            }
            Picker("Görüntü yönü", selection: $settings.imageOrientation) {
                ForEach(ImageOrientation.allCases, id: \.self) { o in
                    Text(o.title).tag(o)
                }
            }
            HelpRow("Görüntü yönü: kamera yan ya da ters takılıysa resmi çevirir. Önizleme, çekilen fotoğraflar ve PDF, kaydedilen video ve sesli yönlendirmedeki sağ/sol/yukarı/aşağı hep bu yöne uyar. 90° çevirince kadrajdaki bölümler “sol/sağ” yerine “üst/alt” diye sorulur. Önceki “Kamera ters takılı” ayarı açıktıysa 180° olarak devralınır.")
            HelpRow("Kamera adı (UID) hazır yazılı gelir; başka bir kamera için silip yenisini yazabilirsiniz. IP boş bırakılırsa kamera kendiliğinden bulunur. Telefon kameranın Wi-Fi ağına bağlı olmalıdır.")
        }
    }

    private var voiceSection: some View {
        Section(header: Text("Sesli komut"),
                footer: Text("Birden fazla sözcüğü virgülle ayırabilirsiniz. Uygulama açıkken ve ekran açıkken dinler.")) {
            Toggle("Sesli komutla çek", isOn: $settings.voiceEnabled)
            TextField("Tetikleme sözcüğü", text: $settings.triggerWord)
                .disableAutocorrection(true)
            Stepper(value: $settings.cooldown, in: 2...20, step: 1) {
                Text("İki çekim arası bekleme: \(Int(settings.cooldown)) sn")
            }
        }
    }

    private var readingVoiceSection: some View {
        Section(header: Text("Okuma sesi")) {
            HStack {
                Text("Şu an")
                Spacer()
                Text(SpeechVoiceChooser.currentDescription(preferredID: settings.speechVoiceID))
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            Picker("Ses", selection: $settings.speechVoiceID) {
                Text("Otomatik (en kaliteli)").tag("")
                ForEach(voices, id: \.id) { voice in
                    Text(voice.title).tag(voice.id)
                }
            }
            Stepper(value: $settings.speechRate, in: 0.7...1.3, step: 0.05) {
                Text(verbatim: "Okuma hızı: %\(Int((settings.speechRate * 100).rounded()))")
            }
            Button("Bu sesi dene") { model.previewVoice() }
                .accessibilityIdentifier("okuma-sesi-dene")
            HelpRow("“Otomatik”, telefonda kurulu en kaliteli Türkçe sesi seçer. Daha doğal bir ses için iPhone Ayarlar > Erişilebilirlik > Konuşulan İçerik > Sesler > Türkçe bölümünden “Gelişmiş” ya da “Premium” bir ses indirin, sonra bu ekrana dönün. Siri’nin kendi sesi uygulamalara açık değildir; yalnız bu listedeki sesler kullanılabilir.")
        }
    }

    /// Gemini çağrı sözcüğü fotoğraf çekme / gönderme sözcükleriyle çakışıyorsa uyarı için
    private var callWordClashes: [String] {
        let others = [settings.triggerWord, settings.finishWord, GuidanceVocabulary.finish]
        return GeminiText.clashes(settings.geminiCallWord, with: others)
    }

    private func profileName(_ i: Int) -> Binding<String> {
        return Binding(get: { settings.geminiProfiles[i].name }, set: { settings.geminiProfiles[i].name = $0 })
    }

    private func profileModel(_ i: Int) -> Binding<String> {
        return Binding(get: { settings.geminiProfiles[i].model }, set: { settings.geminiProfiles[i].model = $0 })
    }

    private func profileFree(_ i: Int) -> Binding<Bool> {
        return Binding(get: { settings.geminiProfiles[i].free }, set: { settings.geminiProfiles[i].free = $0 })
    }

    private func profileKey(_ i: Int) -> Binding<String> {
        return Binding(get: { settings.geminiKeys[i] }, set: { settings.geminiKeys[i] = $0 })
    }

    /// Seçili profilin anahtarının görebildiği modelleri yazar (doğru model adını bulmak için)
    private func listGeminiModels() {
        let profile = settings.activeGeminiProfile
        listingModels = true
        modelListText = "Modeller isteniyor…"
        let client = GeminiClient(key: { profile.key }, model: { profile.model })
        Task { @MainActor in
            let text: String
            do {
                let names = try await client.listModels()
                text = names.isEmpty ? "Bu anahtarla kullanılabilir model görünmüyor." : names.joined(separator: "\n")
            } catch let e as GeminiError {
                text = e.message
            } catch {
                text = error.localizedDescription
            }
            modelListText = text
            listingModels = false
        }
    }

    /// Gizlilik onayı: sayfanın en üstünde; onay yoksa Gemini'ye hiçbir şey gönderilmez
    private var geminiPrivacySection: some View {
        Section(header: Text("Gizlilik onayı")) {
            Toggle("Ses kaydımın ve PDF’lerimin Google’a gönderilmesini onaylıyorum", isOn: $settings.geminiPrivacyOK)
                .accessibilityIdentifier("gemini-gizlilik")
            HelpRow("Onay vermezseniz Gemini’ye hiçbir şey gönderilmez ve sesle soru sorulamaz. Onayladığınızda soru sesiniz ve belge klasörünüzdeki PDF’ler Google’ın Gemini hizmetine gönderilir.")
        }
    }

    private var geminiSection: some View {
        Section(header: Text("Gemini ile belge sohbeti")) {
            Toggle("Gemini’ye sesle soru sor", isOn: $settings.geminiEnabled)
                .accessibilityIdentifier("gemini-ac")
            Toggle("Oturum: “hazırım” de, cevaptan sonra yeni soruyu dinle", isOn: $settings.geminiSession)
                .accessibilityIdentifier("gemini-oturum")
            HStack {
                Text("Oturum sessizlik süresi (sn)")
                Spacer()
                TextField("0", value: $settings.geminiSessionTimeout, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 90)
                    .accessibilityIdentifier("gemini-oturum-suresi")
            }
            Text(settings.geminiSessionTimeout <= 0
                 ? "0: oturum hiç kapanmaz, siz kapatana kadar soru beklenir."
                 : "\(settings.geminiSessionTimeout) sn soru gelmezse oturum kapanır.")
                .font(.footnote).foregroundColor(.secondary)
            TextField("Çağrı sözcüğü (boşsa dinle ve gemini)", text: $settings.geminiCallWord)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .accessibilityIdentifier("gemini-cagri-sozcugu")
            HelpRow("“Dinle” deyince program “Dinliyorum” der ve kaydeder; “tamam” deyince kayıt Gemini’ye gider (baştaki “dinle” gönderilmez). Deneme sınavında da her an çalışır. Program konuşurken “dinle” duyulmaz: konuşmayı kesmek için “Gemini’ye sor” düğmesine basın.")
            Picker("Dinle: kaydı ne bitirsin", selection: $settings.listenEnd) {
                Text("“Tamam” deyince").tag("word")
                Text("Sustuğumda").tag("silence")
            }
            .accessibilityIdentifier("dinle-bitirme")
            if settings.listenEnd == "word" {
                Stepper(value: $settings.listenSilence, in: 5...60) {
                    Text("“Tamam” denmezse sessizlikte bitme: \(settings.listenSilence) sn")
                }
                .accessibilityIdentifier("dinle-sessizlik")
            }
            Picker("Düşünme modu (thinking)", selection: $settings.geminiThinking) {
                Text("Otomatik (Gemma’da açık)").tag("auto")
                Text("Hep yüksek (daha doğru, yavaş)").tag("high")
                Text("En az (hızlı)").tag("minimal")
            }
            .accessibilityIdentifier("gemini-dusunme")
            HelpRow("Gemma modellerinde (ör. gemma-4-31b-it) düşünme ancak “yüksek” ile açılır; otomatikte kendiliğinden açılır. ALES/YDS gibi soru çözümünde doğruluğu artırır, cevap birkaç sn gecikir. Gemini 2.x modelleri bu ayarı almaz.")
            if !callWordClashes.isEmpty {
                Text("Bu sözcük başka bir komutla aynı: \(callWordClashes.joined(separator: ", ")). Farklı bir sözcük seçin.")
                    .font(.footnote).foregroundColor(.orange)
            }
            Stepper(value: $settings.geminiDocCount, in: 1...GeminiConfig.maxPages) {
                Text(verbatim: "Gönderilecek son belge sayısı: \(settings.geminiDocCount)")
            }
            HelpRow("Tek tek göndermede her sayfa ayrı belgedir: taradığınız sayfa sayısı kadar yapın. Gemini’ye en çok \(GeminiConfig.maxPages) sayfa verilir; en yeni belgelerden başlanır, sığmayanlar atlanır ve bu sesli söylenir.")
            Toggle("Büyük belge setlerini Gemini’nin hafızasına al", isOn: $settings.geminiMemory)
                .accessibilityIdentifier("gemini-hafiza")
            HelpRow("Açıkken (8 sayfadan büyük setlerde) PDF’ler Gemini’ye bir kez yüklenir (48 saat saklanır), oturumda belgeler Gemini’nin önbelleğinde durur: her soruda 500 sayfa yeniden gönderilmez, daha hızlı ve ucuzdur. Önbellek oturum süresince saat başı küçük bir saklama ücreti işler ve oturum bitince silinir. Bir sorun olursa belgeler eski yöntemle (en çok yaklaşık 14 MB) doğrudan gönderilir.")
            TextField("Şık kodları (A=ADANA, B=BURSA…)", text: $settings.geminiOptionCodes)
                .textInputAutocapitalization(.characters)
                .disableAutocorrection(true)
                .accessibilityIdentifier("gemini-sik-kodlari")
            HelpRow("Cevapta şık harfi yerine bu kod sözcüğü okunur (ör. “Birinci sorunun cevabı DENİZLİ, altmış sekiz.”). Boş bırakırsanız harfin kendisi okunur. “İlk on soruyu cevapla” deyince 10’arlı gruplar hâlinde okunur; “sıradaki on soruyu cevapla” dediğinizde, ulaşan son cevaptan sonrasından devam edilir (cevap kesilirse ya da internet koparsa aynı grup yeniden verilir). Belirli soruları da isteyebilirsiniz: “üçüncü, sekizinci ve on beşinci soruların cevabını ver”; “son yanıtı tekrarla” derseniz son cevap Gemini’ye gitmeden uygulamanın hafızasından okunur.")
            if settings.geminiBatchLast > 0 {
                HStack {
                    Text(verbatim: "Toplu cevapta kalınan yer: \(settings.geminiBatchLast). soru")
                    Spacer()
                    Button("Sıfırla") { settings.geminiBatchLast = 0 }
                        .accessibilityIdentifier("gemini-sira-sifirla")
                }
            }
            HelpRow("Belge klasörüne kaydettiğiniz son PDF’leri Gemini’ye verir; çağrı sözcüğünü söyleyip (kısa bir “tık” sesinden sonra) ya da ana ekrandaki düğmeyle belgeler hakkında sesli soru sorarsınız, cevap Türkçe sesle okunur. Çağrı sözcüğünü değiştirebilirsiniz (ör. “hey dostum”; virgülle birden çok yazabilirsiniz, en az 3 harf); gündelik konuşmada sık geçen bir sözcük seçerseniz Gemini yanlışlıkla açılabilir, fotoğraf çekme ve gönder sözcüklerinden de farklı olsun. Çağrı sözcüğü için Sesli komut açık olmalıdır; düğme her zaman çalışır. Oturum açıkken uygulama “N belge hazır, sorunuzu bekliyorum” der, her cevaptan sonra “Sonraki sorunuzu bekliyorum” diyerek yeni soruyu kendiliğinden dinler. Oturum siz “oturumu kapat” diyene, Durdur’a basana ya da aşağıda yazdığınız sessizlik süresi dolana kadar açık kalır; süreyi 0 bırakırsanız hiç kapanmaz. Oturum açıkken mikrofon sürekli açıktır: duyulan her konuşma Gemini’ye gider ve ücretlendirilir, “okey” gibi diğer sesli komutlar çalışmaz. Her soruda ses kaydınız ve seçilen PDF’ler Google’a gönderilir; IBAN, vergi numarası gibi bilgiler içeren belgeler için ücretli anahtarı tercih edin. Belgelerin PDF olarak Drive’a gitmesi gerekir (Google Drive bölümünde dosya türü “PDF”).")
        }
    }

    private var geminiModelsSection: some View {
        Section(header: Text("Gemini modelleri (6 profil)")) {
            Picker("Kullanılan model", selection: $settings.geminiActive) {
                ForEach(0..<GeminiProfiles.slotCount, id: \.self) { i in
                    Text(settings.geminiProfiles[i].name.trimmed.isEmpty ? "Model \(i + 1)" : settings.geminiProfiles[i].name).tag(i + 1)
                }
            }
            .accessibilityIdentifier("gemini-kullanilan-model")
            ForEach(0..<GeminiProfiles.slotCount, id: \.self) { i in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(i + 1). model").font(.footnote).foregroundColor(.secondary)
                    TextField("Ad (ör. \(GeminiProfiles.defaultNames[i]))", text: profileName(i))
                        .disableAutocorrection(true)
                    TextField("Model (ör. \(GeminiConfig.defaultModel))", text: profileModel(i))
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    SecureField("API anahtarı", text: profileKey(i))
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .accessibilityIdentifier("gemini-anahtar-\(i + 1)")
                    Toggle("Ücretsiz anahtar", isOn: profileFree(i))
                }
            }
            Toggle("Model zinciri: kota dolunca / hata olunca / geç cevap gelince sıradaki modele geç", isOn: $settings.geminiChainFallback)
            if settings.geminiChainFallback {
                HelpRow("Seçili modelin kotası dolarsa, sunucu hata verirse ya da cevap gecikirse aynı soru kendiliğinden 1→2→…→6 sırasındaki bir sonraki modele (kendi anahtarıyla) gönderilir; nedeni ve yeni modeli kısaca sesle söylenir. Kotası dolan model bir süre atlanır. Yalnız anahtarı girilmiş profiller kullanılır. Bağlantı hiç yoksa ya da içerik engellenirse model değişmez.")
                Stepper(value: $settings.geminiWaitLimit, in: 0...600, step: 5) {
                    Text(settings.geminiWaitLimit == 0 ? "Cevap bekleme sınırı: yok" : "Cevap bekleme sınırı: \(settings.geminiWaitLimit) sn")
                }
                HelpRow("Model bu süre içinde cevap vermezse sıradaki modele geçilir (en az 10 sn sayılır; son modele sınır konmaz). Kesilen istek Google tarafında yine de sayılabilir; düşünme modu açık modeller (ör. Gemma) uzun sürebilir, gerekirse süreyi artırın.")
            }
            Toggle("Video bitince Gemini'ye de sor", isOn: $settings.videoToGemini)
            if settings.videoToGemini {
                TextField("Video sorusu (boşsa: “Bu videoda ne oluyor?”)", text: $settings.videoQuestion)
                Toggle("Videoyu yüksek çözünürlükle oku", isOn: $settings.videoHighRes)
                HelpRow("Video kaydı bitince dosya telefondan doğrudan Gemini'ye gönderilir (klasöre ayrıca kaydedilir) ve cevap sesle okunur. Her video bir Gemini isteğidir: ücretsiz kotadan düşer. Gemini videoyu saniyede 1 kare okur; 30 sn ≈ 2.100 token (yüksek çözünürlükte ≈ 8.400). Küçük yazı okuması için yüksek çözünürlük varsayılan açıktır; token tasarrufu için kapatabilirsiniz. Gemini ve gizlilik onayı açık olmalıdır.")
            }
            Toggle("Model yoğunsa ya da kotası dolunca yedek modele geç", isOn: $settings.geminiOverloadFallback)
            if settings.geminiOverloadFallback {
                HelpRow("“Bu model yoğun talep görüyor” (503) ya da kota dolu (429) derse, aynı anahtarla hesabınızdaki başka bir hızlı model (ör. bir önceki flash sürümü) denenir; cevabın hangi modelden geldiği yazılır. Ücretsiz anahtarda günlük istek sayısı düşük olabilir: aynı modele art arda yeniden deneme yapılmaz.")
            }
            Toggle("Harcama sınırı dolunca ücretsiz modele geç", isOn: $settings.geminiAutoFallback)
            if settings.geminiAutoFallback {
                Text("Ücretsiz katmanda içeriğiniz Google tarafından ürün geliştirmede kullanılabilir.")
                    .font(.footnote).foregroundColor(.orange)
            }
            Button(listingModels ? "Modeller isteniyor…" : "Modelleri listele (seçili modelin anahtarıyla)") { listGeminiModels() }
                .disabled(listingModels)
            if !modelListText.isEmpty {
                Text(modelListText).font(.footnote).foregroundColor(.secondary).textSelection(.enabled)
            }
            HelpRow("Her profilin kendi API anahtarı vardır (aistudio.google.com); anahtarlar yalnız bu telefonun Keychain’inde saklanır, kimseyle paylaşmayın. Ücretli ya da ücretsiz olmak modelin değil anahtarın özelliğidir: faturalandırma bağlı projenin anahtarı ücretli, bağlı olmayan ücretsizdir; “Ücretsiz anahtar” kutusunu buna göre işaretleyin. Varsayılanlar ücretsiz katmanda kullanılabilen modellerdir: performans sırasıyla 1. Gemini 3.8 Flash, 2. Gemini 3.6 Flash, 3. Gemini 2.5 Pro, 4. Gemini 3.5 Flash-Lite, 5. Gemini 3.1 Flash-Lite, 6. ücretli Gemini 3.1 Flash-Lite (kendi ücretli anahtarıyla; ucuzdur, yaklaşık 0,25 $ giriş / 1,50 $ çıkış milyon belirteç başına; en sonda). Model adları hesabınızda yoksa ya da ücretsiz hakkı yoksa (ör. 2.5 Pro) değiştirin ya da boş bırakın: kota hatasında program sıradakine geçer. Günlük ücretsiz haklar Google’da değişebilir; en güçlü modellerde azdır (≈20). “Model değiştir” deyince uygulama hesabınızdaki modellerden en çok 7’sini sıralar; “birinci model”, “ikinci model” diye seçersiniz, “tekrarla” listeyi yineler, “vazgeç” bırakır. “Birinci alternatif model seç” 2. profil, “ikinci…” 3., “üçüncü…” 4., “dördüncü…” 5., “beşinci alternatif model seç” 6. profil için aynısını yapar. Anahtarı girilmiş profil seçilince hemen kullanılır. AI Studio’da Spend sayfasından aylık harcama sınırı (ör. 20 dolar) koyabilirsiniz; sınır dolunca ücretli profilden “ücretsiz” işaretli profile kendiliğinden geçilir, yeni ayda eski profile dönülür. Google harcamayı yaklaşık 10 dakika gecikmeyle saydığı için sınır biraz aşılabilir. Dikkat: ücretsiz katmanda Google gönderdiğiniz içeriği ürünlerini geliştirmek için kullanabilir; gizli belgeleriniz varsa bu geçişi kapatın.")
        }
    }

    private var guidanceSection: some View {
        Section(header: Text("Sesli konumlandırma")) {
            Toggle("Sesle konumlandır", isOn: $settings.guidanceEnabled)
                .accessibilityIdentifier("konumlandirma-ac")
            Toggle("Uyarıları sesli söyle", isOn: $settings.guidanceVoice)
            Toggle("Kamera ve gönderim durumunu da söyle", isOn: $settings.statusNotices)
            Toggle("Konum uygunsa kendiliğinden çek", isOn: $settings.guidanceAutoCapture)
            Picker("Kadraj", selection: $settings.guidanceFrame) {
                Text("Dikey tam sayfa").tag(1)
                Text("Bütün kare").tag(0)
            }
            Picker("Netlik isteği", selection: $settings.guidanceSharpness) {
                Text("Gevşek").tag(0)
                Text("Normal").tag(1)
                Text("Sıkı").tag(2)
            }
            Toggle("Parlama uyarısı", isOn: $settings.guidanceGlare)
            TextField("Bitirme sözcüğü", text: $settings.finishWord)
                .disableAutocorrection(true)
            HelpRow("Kadraj: “Dikey tam sayfa” seçiliyken yönlendirme, hedefi dikey bir tam sayfa sayar (A4 gibi; kamera karesi yataydır, bu yüzden sayfa karenin ortasındaki dikey bölümü kaplar). Sayfanın yazısı bu kadrajın içinde, yeterince büyük ve ortada olunca “tamam” der; kadrajın dışına taşarsa kaydırma, kadraja sığmazsa uzaklaşma önerir. Fotoğraf bu kadraja kırpılmaz, kamera karesinin tamamı çekilir. “Bütün kare” eski davranıştır: yazı bütün kareye göre ölçülür. Görüntü yönünü 90° çevirdiyseniz kadraj buna göre kendiliğinden uyar.")
            HelpRow("Program sayfayı ölçer ve “biraz sağa”, “yukarı”, “uzaklaş”, “yaklaş” gibi sesli yönlendirir; konum uygun olunca birkaç kareyi seri çekip en netini alır. Kadrajda birden çok sütun ya da yan yana sayfa varsa ve biri yarım kalıyorsa “Sol mu, sağ mı?” diye sorar: “sol”, “sağ”, “orta”, “ikisi birden” (ya da “soldaki”, “sağ sütun”, “birinci”, “son”…) deyin; “yeniden seç” seçimi siler. “Hepsi tamamlandı”, “hepsini gönder”, “tümünü gönder”, “pdf yap”, “bitirdim” gibi söylenişlerin hepsi bekleyen fotoğrafları tek PDF olarak gönderir (en çok 30 sayfa / 15 MB; fazlası ikinci PDF olur). “Rapor ver” bugün kaç sayfa çekildiğini ve kaçının PDF olarak gittiğini söyler. “Son fotoğrafı sil”, “sonuncuyu sil”, “geri al” henüz gönderilmemiş son fotoğrafı siler; “yeniden çek” onu silip aynı bölümü yeniden kadraja aldırır. Çekimden sonra program “Çekim tamamlandı, N sayfa gönderilmeyi bekliyor” der; PDF sayfa sınırına yaklaşınca bunu da söyler. Sayfada parlama (doymuş beyaz leke) görürse en çok iki kez uyarır, sonra yine de çeker; bu kontrol gerçek kamerada denenmemiştir, rahatsız ederse kapatın. Anlaşılmayan komutta program “anlayamadım” der. Bu özellik açılınca gönderim “toplu, yalnız komutla” olur ve “görüntü değişince çek” kapanır. “Kamera ve gönderim durumunu da söyle” açıkken kamera koptu / geri geldi, mikrofon izni yok, dosya gönderildi / gönderilemedi gibi haberler konuşma arasında kısaca söylenir; aynı haber tekrarlanmaz. Sesli yanıt için mikrofon izni gerekir.")
        }
    }

    private var examSection: some View {
        Section(header: Text("Deneme sınavı")) {
            Stepper(value: $settings.examGroup, in: 3...20) {
                Text("Cevap grubu: \(settings.examGroup) soru")
            }
            Stepper(value: $settings.examFetch, in: 5...40) {
                Text("Gemini’den bir seferde: \(settings.examFetch) soru")
            }
            Stepper(value: $settings.examCancelWindow, in: 0...15) {
                Text("Gönderimden önce vazgeçme süresi: \(settings.examCancelWindow) sn")
            }
            Stepper(value: $settings.examGap, in: 0...10) {
                Text("Gruplar arası duraklama: \(settings.examGap) sn")
            }
            Toggle("Sınav önce video çeksin", isOn: $settings.examVideoFirst)
            Toggle("Sınav başlarken ses, internet ve Gemini'yi sına", isOn: $settings.examSelfCheck)
            HelpRow("“Deneme sınavı modu” deyince soru sayfaları sesli yönlendirmeyle taranır (fotoğraflar gönderilmeden birikir); “tarama tamamlandı” deyince PDF’ler belge klasörüne kaydedilir, Gemini yalnız bu sınavın PDF’lerini okur ve “N belge, M sayfa, K soru görüyorum” der. Cevaplar gruplar hâlinde okunur, her grup bir kez tekrarlanır; sonra soru numarasını söyleyerek ya da “tüm cevapları oku” diyerek istediğiniz cevabı yeniden dinlersiniz (tekrarlar Gemini’ye gitmez, kayıttan okunur). “Sınav tamamlandı” sınavı kapatır. Program konuşurken mikrofon kapalıdır; komutlar cümle bitince söylenmelidir. Okunamayan sorular uydurulmaz, “okunamadı” denir. “Sınav önce video çeksin” açıksa sınav önce video aşamasıyla başlar: evrak kadraja girince kayıt kendiliğinden başlar (en çok 30 sn), “durdur” kaydı bitirip belge klasörüne kaydeder, “sil” kaydetmeden siler, “atla” video aşamasını geçer; her videodan sonra “videoya devam edeyim mi?” diye sorar: “evet” yeni video, “hayır” fotoğraf taraması. Sınav videosu yalnız belge klasörüne kaydedilir (Gemini’ye sorulmaz).")
        }
    }

    private var powerSection: some View {
        Section(header: Text("Pil ve ısınma")) {
            Toggle("Canlı önizlemeyi kapat", isOn: $settings.previewOff)
            Toggle("Ekran parlaklığını azalt", isOn: $settings.dimScreen)
            HelpRow("Önizleme kapalıyken ekrana video çizilmez ve kareler seyreltilerek incelenir; fotoğraf çekme (düğme, sesli komut, görüntü değişince), kaydetme aynen çalışır. Kamera kadrajını önce önizlemeyle ayarlayın. Ekran parlaklığını azaltmak pilin en büyük tüketicisini azaltır; uygulama açıkken ekran hep açık kalır. Kamera yayını, Wi-Fi ve mikrofon yine çalıştığı için pil ve ısınma tamamen sıfırlanmaz.")
        }
    }

    private var photoSection: some View {
        Section(header: Text("Fotoğraf")) {
            Picker("İyileştirme", selection: $settings.enhancement) {
                Text("Kapalı").tag(0)
                Text("Hafif").tag(1)
                Text("Güçlü").tag(2)
            }
            .pickerStyle(.segmented)
            Toggle("Birkaç net kareyi birleştir", isOn: $settings.multiFrame)
            Toggle("Yalnız belge çek (belge değilse çekme)", isOn: $settings.documentOnly)
            Toggle("Belgeyi otomatik düzelt ve kırp (deneysel)", isOn: $settings.deskew)
            Picker("Tarih/saat yazısı", selection: $settings.timestampMode) {
                Text("Bulanıklaştır (okunmaz)").tag(TimestampMode.blur)
                Text("Kes (üst şeridi at)").tag(TimestampMode.crop)
                Text("Olduğu gibi bırak").tag(TimestampMode.keep)
            }
            Picker("Büyütme", selection: $settings.upscale) {
                Text("1×").tag(1.0)
                Text("1,5×").tag(1.5)
                Text("2×").tag(2.0)
            }
            .pickerStyle(.segmented)
            VStack(alignment: .leading) {
                Text("JPEG kalitesi: %\(Int((settings.jpegQuality * 100).rounded()))")
                Slider(value: $settings.jpegQuality, in: 0.7...1.0, step: 0.01)
            }
            Stepper(value: $settings.burstBefore, in: 0...1.5, step: 0.1) {
                Text(String(format: "Seri çekim: öncesi %.1f sn", settings.burstBefore))
            }
            Stepper(value: $settings.burstAfter, in: 0.2...2.0, step: 0.1) {
                Text(String(format: "Seri çekim: sonrası %.1f sn", settings.burstAfter))
            }
            HelpRow("“Yalnız belge çek” açıkken kadrajda kâğıt ve üzerinde yazı yoksa (el, yüz, boş masa, duvar, çizgili desen) fotoğraf çekilmez; program “Belge görünmüyor” der. Belge hiç çekilmiyorsa ya da bu kontrol rahatsız ederse kapatın. Belge taraması için: İyileştirme Hafif, kalite %92 ve üzeri, Yüksek 1920×1080 görüntü önerilir. Büyütme ayrıntı eklemez, yalnızca yazıyı daha rahat okutur. Kamera tarih/saati görüntünün içine işler, silinemez: Bulanıklaştır yalnızca sağ üstteki tarih yazısının kutusunu okunmaz yapar, Kes ise üstteki şeridi atar (fotoğraf biraz kısalır).")
        }
    }

    private var motionSection: some View {
        Section(header: Text("Otomatik çekim")) {
            Toggle("Görüntü değişince çek", isOn: $settings.motionEnabled)
            Picker("Duyarlılık", selection: $settings.motionSensitivity) {
                Text("Düşük").tag(0)
                Text("Orta").tag(1)
                Text("Yüksek").tag(2)
            }
            .pickerStyle(.segmented)
            HelpRow("Kamera önüne yeni bir belge konup görüntü durulunca bir kez çeker. Belge değişmedikçe tekrar çekmez.")
        }
    }

    private var saveSection: some View {
        Section(header: Text("Kaydetme")) {
            Picker("Klasöre kaydetme", selection: $settings.sendMode) {
                Text("Tek tek (hemen)").tag("single")
                Text("Toplu (biriksin)").tag("batch")
            }
            .pickerStyle(.segmented)
            if settings.sendMode == "batch" {
                Stepper(value: $settings.batchSize, in: 0...50) {
                    Text(settings.batchSize > 0 ? "\(settings.batchSize) fotoğrafta gönder" : "Otomatik gönderme kapalı (düğmeyle)")
                }
                Stepper(value: $settings.batchIdle, in: 0...600, step: 10) {
                    Text(settings.batchIdle > 0 ? "Son çekimden \(settings.batchIdle) sn sonra gönder" : "Bekleme süresi kapalı")
                }
            }
            Picker("Dosya türü", selection: $settings.uploadFormat) {
                Text("PDF").tag("pdf")
                Text("JPEG").tag("jpeg")
            }
            .pickerStyle(.segmented)
            HelpRow("Dosyalar belge klasörüne (“G526 Belgeler”) kaydedilir; klasörü ilk ekrandaki “Belge klasörü” bölümünden seçersiniz. PDF: her fotoğraf (toplu modda birikenler tek çok sayfalı PDF olarak) kaydedilir; resim kalitesi bozulmaz.")
        }
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var log = AppLog.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.periodic(from: Date(), by: 1.0)) { _ in
                Text(model.currentStats())
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            DisclosureGroup("Sağlık raporu (ısı, bellek, takılma)") {
                TimelineView(.periodic(from: Date(), by: 5.0)) { _ in
                    Text(HealthMonitor.shared.report())
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("Sağlık raporunu kopyala") {
                    UIPasteboard.general.string = HealthMonitor.shared.report()
                }
            }
            Button("Kameradan pil / şarj bilgisi ara") { model.probeCamera() }
                .accessibilityIdentifier("kamera-sorgula")
            if !model.probeText.isEmpty {
                Text(model.probeText)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !model.deviceInfo.isEmpty {
                Text(model.deviceInfo)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Kameraya bağlanamıyorsanız: telefon kameranın Wi-Fi ağında olmalı ve Ayarlar > G526 Kamera > Yerel Ağ izni açık olmalı.")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack {
                Button("Günlüğü kopyala") {
                    UIPasteboard.general.string = log.lines.joined(separator: "\n")
                }
                Spacer()
                Button("Temizle", role: .destructive) { log.clear() }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(log.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(8)
        }
        .padding(12)
        .navigationTitle("Tanı")
        .navigationBarTitleDisplayMode(.inline)
    }
}
