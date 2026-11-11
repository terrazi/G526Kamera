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
                voiceSection
                readingVoiceSection
                geminiSection
                geminiModelsSection
                examSection
                guidanceSection
                photoSection
                powerSection
                motionSection
                driveSection
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
            .onChange(of: settings.ocrEnabled) { _ in OcrCenter.shared.reset() }
            .onChange(of: settings.ocrUseGemini) { _ in OcrCenter.shared.reset() }
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

    private var cameraSection: some View {
        Section(header: Text("Kamera"),
                footer: Text("UID yalnızca bu telefonda saklanır. IP boş bırakılırsa kamera kendiliğinden bulunur. Telefon kameranın Wi-Fi ağına bağlı olmalıdır.")) {
            TextField("Kamera UID (örn. G123456ABCDE)", text: $settings.uid)
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
        Section(header: Text("Okuma sesi"),
                footer: Text("“Otomatik”, telefonda kurulu en kaliteli Türkçe sesi seçer. Daha doğal bir ses için iPhone Ayarlar > Erişilebilirlik > Konuşulan İçerik > Sesler > Türkçe bölümünden “Gelişmiş” ya da “Premium” bir ses indirin, sonra bu ekrana dönün. Siri’nin kendi sesi uygulamalara açık değildir; yalnız bu listedeki sesler kullanılabilir.")) {
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

    private var geminiSection: some View {
        Section(header: Text("Gemini ile belge sohbeti"),
                footer: Text("Drive’a gönderdiğiniz son PDF’leri Gemini’ye verir; çağrı sözcüğünü söyleyip (kısa bir “tık” sesinden sonra) ya da ana ekrandaki düğmeyle belgeler hakkında sesli soru sorarsınız, cevap Türkçe sesle okunur. Çağrı sözcüğünü değiştirebilirsiniz (ör. “hey dostum”; virgülle birden çok yazabilirsiniz, en az 3 harf); gündelik konuşmada sık geçen bir sözcük seçerseniz Gemini yanlışlıkla açılabilir, fotoğraf çekme ve gönder sözcüklerinden de farklı olsun. Çağrı sözcüğü için Sesli komut açık olmalıdır; düğme her zaman çalışır. Oturum açıkken uygulama “N belge hazır, sorunuzu bekliyorum” der, her cevaptan sonra “Sonraki sorunuzu bekliyorum” diyerek yeni soruyu kendiliğinden dinler. Oturum siz “oturumu kapat” diyene, Durdur’a basana ya da aşağıda yazdığınız sessizlik süresi dolana kadar açık kalır; süreyi 0 bırakırsanız hiç kapanmaz. Oturum açıkken mikrofon sürekli açıktır: duyulan her konuşma Gemini’ye gider ve ücretlendirilir, “okey” gibi diğer sesli komutlar çalışmaz. Her soruda ses kaydınız ve seçilen PDF’ler Google’a gönderilir; IBAN, vergi numarası gibi bilgiler içeren belgeler için ücretli anahtarı tercih edin. Belgelerin PDF olarak Drive’a gitmesi gerekir (Google Drive bölümünde dosya türü “PDF”).")) {
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
            Text("“Dinle” deyince program “Dinliyorum” der ve kaydeder; “tamam” deyince kayıt Gemini’ye gider (baştaki “dinle” gönderilmez). Deneme sınavında da her an çalışır. Program konuşurken “dinle” duyulmaz: konuşmayı kesmek için “Gemini’ye sor” düğmesine basın.")
                .font(.footnote).foregroundColor(.secondary)
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
            Text("Gemma modellerinde (ör. gemma-4-31b-it) düşünme ancak “yüksek” ile açılır; otomatikte kendiliğinden açılır. ALES/YDS gibi soru çözümünde doğruluğu artırır, cevap birkaç sn gecikir. Gemini 2.x modelleri bu ayarı almaz.")
                .font(.footnote).foregroundColor(.secondary)
            if !callWordClashes.isEmpty {
                Text("Bu sözcük başka bir komutla aynı: \(callWordClashes.joined(separator: ", ")). Farklı bir sözcük seçin.")
                    .font(.footnote).foregroundColor(.orange)
            }
            Stepper(value: $settings.geminiDocCount, in: 1...GeminiConfig.maxPages) {
                Text(verbatim: "Gönderilecek son belge sayısı: \(settings.geminiDocCount)")
            }
            Text("Tek tek göndermede her sayfa ayrı belgedir: taradığınız sayfa sayısı kadar yapın. Gemini’ye en çok \(GeminiConfig.maxPages) sayfa verilir; en yeni belgelerden başlanır, sığmayanlar atlanır ve bu sesli söylenir.")
                .font(.footnote).foregroundColor(.secondary)
            Toggle("Büyük belge setlerini Gemini’nin hafızasına al", isOn: $settings.geminiMemory)
                .accessibilityIdentifier("gemini-hafiza")
            Text("Açıkken (8 sayfadan büyük setlerde) PDF’ler Gemini’ye bir kez yüklenir (48 saat saklanır), oturumda belgeler Gemini’nin önbelleğinde durur: her soruda 500 sayfa yeniden gönderilmez, daha hızlı ve ucuzdur. Önbellek oturum süresince saat başı küçük bir saklama ücreti işler ve oturum bitince silinir. Bir sorun olursa belgeler eski yöntemle (en çok yaklaşık 14 MB) doğrudan gönderilir.")
                .font(.footnote).foregroundColor(.secondary)
            TextField("Şık kodları (A=ADANA, B=BURSA…)", text: $settings.geminiOptionCodes)
                .textInputAutocapitalization(.characters)
                .disableAutocorrection(true)
                .accessibilityIdentifier("gemini-sik-kodlari")
            Text("Cevapta şık harfi yerine bu kod sözcüğü okunur (ör. “Birinci sorunun cevabı DENİZLİ, altmış sekiz.”). Boş bırakırsanız harfin kendisi okunur. “İlk on soruyu cevapla” deyince 10’arlı gruplar hâlinde okunur; “sıradaki on soruyu cevapla” dediğinizde, ulaşan son cevaptan sonrasından devam edilir (cevap kesilirse ya da internet koparsa aynı grup yeniden verilir). Belirli soruları da isteyebilirsiniz: “üçüncü, sekizinci ve on beşinci soruların cevabını ver”; “son yanıtı tekrarla” derseniz son cevap Gemini’ye gitmeden uygulamanın hafızasından okunur.")
                .font(.footnote).foregroundColor(.secondary)
            if settings.geminiBatchLast > 0 {
                HStack {
                    Text(verbatim: "Toplu cevapta kalınan yer: \(settings.geminiBatchLast). soru")
                    Spacer()
                    Button("Sıfırla") { settings.geminiBatchLast = 0 }
                        .accessibilityIdentifier("gemini-sira-sifirla")
                }
            }
            Toggle("Ses kaydımın ve PDF’lerimin Google’a gönderilmesini onaylıyorum", isOn: $settings.geminiPrivacyOK)
                .accessibilityIdentifier("gemini-gizlilik")
        }
    }

    private var geminiModelsSection: some View {
        Section(header: Text("Gemini modelleri (6 profil)"),
                footer: Text("Her profilin kendi API anahtarı vardır (aistudio.google.com); anahtarlar yalnız bu telefonun Keychain’inde saklanır, kimseyle paylaşmayın. Ücretli ya da ücretsiz olmak modelin değil anahtarın özelliğidir: faturalandırma bağlı projenin anahtarı ücretli, bağlı olmayan ücretsizdir; “Ücretsiz anahtar” kutusunu buna göre işaretleyin. Varsayılanlar ücretsiz katmanda kullanılabilen modellerdir: performans sırasıyla 1. Gemini 3.8 Flash, 2. Gemini 3.6 Flash, 3. Gemini 2.5 Pro, 4. Gemini 3.5 Flash-Lite, 5. Gemini 3.1 Flash-Lite, 6. ücretli Gemini 3.1 Flash-Lite (kendi ücretli anahtarıyla; ucuzdur, yaklaşık 0,25 $ giriş / 1,50 $ çıkış milyon belirteç başına; en sonda). Model adları hesabınızda yoksa ya da ücretsiz hakkı yoksa (ör. 2.5 Pro) değiştirin ya da boş bırakın: kota hatasında program sıradakine geçer. Günlük ücretsiz haklar Google’da değişebilir; en güçlü modellerde azdır (≈20). “Model değiştir” deyince uygulama hesabınızdaki modellerden en çok 7’sini sıralar; “birinci model”, “ikinci model” diye seçersiniz, “tekrarla” listeyi yineler, “vazgeç” bırakır. “Birinci alternatif model seç” 2. profil, “ikinci…” 3., “üçüncü…” 4., “dördüncü…” 5., “beşinci alternatif model seç” 6. profil için aynısını yapar. Anahtarı girilmiş profil seçilince hemen kullanılır. AI Studio’da Spend sayfasından aylık harcama sınırı (ör. 20 dolar) koyabilirsiniz; sınır dolunca ücretli profilden “ücretsiz” işaretli profile kendiliğinden geçilir, yeni ayda eski profile dönülür. Google harcamayı yaklaşık 10 dakika gecikmeyle saydığı için sınır biraz aşılabilir. Dikkat: ücretsiz katmanda Google gönderdiğiniz içeriği ürünlerini geliştirmek için kullanabilir; gizli belgeleriniz varsa bu geçişi kapatın.")) {
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
                Text("Seçili modelin kotası dolarsa, sunucu hata verirse ya da cevap gecikirse aynı soru kendiliğinden 1→2→…→6 sırasındaki bir sonraki modele (kendi anahtarıyla) gönderilir; nedeni ve yeni modeli kısaca sesle söylenir. Kotası dolan model bir süre atlanır. Yalnız anahtarı girilmiş profiller kullanılır. Bağlantı hiç yoksa ya da içerik engellenirse model değişmez.")
                    .font(.footnote).foregroundColor(.secondary)
                Stepper(value: $settings.geminiWaitLimit, in: 0...600, step: 5) {
                    Text(settings.geminiWaitLimit == 0 ? "Cevap bekleme sınırı: yok" : "Cevap bekleme sınırı: \(settings.geminiWaitLimit) sn")
                }
                Text("Model bu süre içinde cevap vermezse sıradaki modele geçilir (en az 10 sn sayılır; son modele sınır konmaz). Kesilen istek Google tarafında yine de sayılabilir; düşünme modu açık modeller (ör. Gemma) uzun sürebilir, gerekirse süreyi artırın.")
                    .font(.footnote).foregroundColor(.secondary)
            }
            Toggle("Video bitince Gemini'ye de sor", isOn: $settings.videoToGemini)
            if settings.videoToGemini {
                TextField("Video sorusu (boşsa: “Bu videoda ne oluyor?”)", text: $settings.videoQuestion)
                Toggle("Videoyu yüksek çözünürlükle oku", isOn: $settings.videoHighRes)
                Text("Video kaydı bitince dosya telefondan doğrudan Gemini'ye gönderilir (Drive'a ayrıca yedeklenir) ve cevap sesle okunur. Her video bir Gemini isteğidir: ücretsiz kotadan düşer. Gemini videoyu saniyede 1 kare okur; 30 sn ≈ 2.100 token (yüksek çözünürlükte ≈ 8.400). Küçük yazı okutmak için yüksek çözünürlüğü açın. Gemini ve gizlilik onayı açık olmalıdır.")
                    .font(.footnote).foregroundColor(.secondary)
            }
            Toggle("Model yoğunsa ya da kotası dolunca yedek modele geç", isOn: $settings.geminiOverloadFallback)
            if settings.geminiOverloadFallback {
                Text("“Bu model yoğun talep görüyor” (503) ya da kota dolu (429) derse, aynı anahtarla hesabınızdaki başka bir hızlı model (ör. bir önceki flash sürümü) denenir; cevabın hangi modelden geldiği yazılır. Ücretsiz anahtarda günlük istek sayısı düşük olabilir: aynı modele art arda yeniden deneme yapılmaz.")
                    .font(.footnote).foregroundColor(.secondary)
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
        }
    }

    private var guidanceSection: some View {
        Section(header: Text("Sesli konumlandırma"),
                footer: Text("Program sayfayı ölçer ve “biraz sağa”, “yukarı”, “uzaklaş”, “yaklaş” gibi sesli yönlendirir; konum uygun olunca birkaç kareyi seri çekip en netini alır. Kadrajda birden çok sütun ya da yan yana sayfa varsa ve biri yarım kalıyorsa “Sol mu, sağ mı?” diye sorar: “sol”, “sağ”, “orta”, “ikisi birden” (ya da “soldaki”, “sağ sütun”, “birinci”, “son”…) deyin; “yeniden seç” seçimi siler. “Hepsi tamamlandı”, “hepsini gönder”, “tümünü gönder”, “pdf yap”, “bitirdim” gibi söylenişlerin hepsi bekleyen fotoğrafları tek PDF olarak gönderir (en çok 30 sayfa / 15 MB; fazlası ikinci PDF olur). “Rapor ver” bugün kaç sayfa çekildiğini ve kaçının PDF olarak gittiğini söyler. “Son fotoğrafı sil”, “sonuncuyu sil”, “geri al” henüz gönderilmemiş son fotoğrafı siler; “yeniden çek” onu silip aynı bölümü yeniden kadraja aldırır. Çekimden sonra program “Çekim tamamlandı, N sayfa gönderilmeyi bekliyor” der; PDF sayfa sınırına yaklaşınca bunu da söyler. Sayfada parlama (doymuş beyaz leke) görürse en çok iki kez uyarır, sonra yine de çeker; bu kontrol gerçek kamerada denenmemiştir, rahatsız ederse kapatın. Anlaşılmayan komutta program “anlayamadım” der. Bu özellik açılınca gönderim “toplu, yalnız komutla” olur ve “görüntü değişince çek” kapanır. “Kamera ve gönderim durumunu da söyle” açıkken kamera koptu / geri geldi, mikrofon izni yok, dosya gönderildi / gönderilemedi gibi haberler konuşma arasında kısaca söylenir; aynı haber tekrarlanmaz. Sesli yanıt için mikrofon izni gerekir.")) {
            Toggle("Sesle konumlandır", isOn: $settings.guidanceEnabled)
                .accessibilityIdentifier("konumlandirma-ac")
            Toggle("Uyarıları sesli söyle", isOn: $settings.guidanceVoice)
            Toggle("Kamera ve gönderim durumunu da söyle", isOn: $settings.statusNotices)
            Button("Sesi dene") { voiceTestResult = model.testVoice() }
                .accessibilityIdentifier("sesi-dene")
            if !voiceTestResult.isEmpty {
                Text(voiceTestResult).font(.footnote).foregroundColor(.secondary)
            }
            Toggle("Konum uygunsa kendiliğinden çek", isOn: $settings.guidanceAutoCapture)
            Toggle("Kamera ters takılı (yönleri çevir)", isOn: $settings.guidanceFlip)
            Picker("Netlik isteği", selection: $settings.guidanceSharpness) {
                Text("Gevşek").tag(0)
                Text("Normal").tag(1)
                Text("Sıkı").tag(2)
            }
            Toggle("Parlama uyarısı", isOn: $settings.guidanceGlare)
            TextField("Bitirme sözcüğü", text: $settings.finishWord)
                .disableAutocorrection(true)
        }
    }

    private var examSection: some View {
        Section(header: Text("Deneme sınavı"),
                footer: Text("“Deneme sınavı modu” deyince soru sayfaları sesli yönlendirmeyle taranır (fotoğraflar gönderilmeden birikir); “tarama tamamlandı” deyince PDF’ler Drive’a gider, Gemini yalnız bu sınavın PDF’lerini okur ve “N belge, M sayfa, K soru görüyorum” der. Cevaplar gruplar hâlinde okunur, her grup bir kez tekrarlanır; sonra soru numarasını söyleyerek ya da “tüm cevapları oku” diyerek istediğiniz cevabı yeniden dinlersiniz (tekrarlar Gemini’ye gitmez, kayıttan okunur). “Sınav tamamlandı” sınavı kapatır. Program konuşurken mikrofon kapalıdır; komutlar cümle bitince söylenmelidir. Okunamayan sorular uydurulmaz, “okunamadı” denir.")) {
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
        }
    }

    private var powerSection: some View {
        Section(header: Text("Pil ve ısınma"),
                footer: Text("Önizleme kapalıyken ekrana video çizilmez ve kareler seyreltilerek incelenir; fotoğraf çekme (düğme, sesli komut, görüntü değişince), OCR ve Drive aynen çalışır. Kamera kadrajını önce önizlemeyle ayarlayın. Kısılan ekran pilin en büyük tüketicisini azaltır; uygulama açıkken ekran hep açık kalır. Kamera yayını, Wi-Fi ve mikrofon yine çalıştığı için pil ve ısınma tamamen sıfırlanmaz.")) {
            Toggle("Canlı önizlemeyi kapat", isOn: $settings.previewOff)
            Toggle("Önizleme kapalıyken ekranı kıs", isOn: $settings.dimWhenPreviewOff)
                .disabled(!settings.previewOff)
        }
    }

    private var photoSection: some View {
        Section(header: Text("Fotoğraf"),
                footer: Text("“Yalnız belge çek” açıkken kadrajda kâğıt ve üzerinde yazı yoksa (el, yüz, boş masa, duvar, çizgili desen) fotoğraf çekilmez; program “Belge görünmüyor” der. Belge hiç çekilmiyorsa ya da bu kontrol rahatsız ederse kapatın. Belge taraması için: İyileştirme Hafif, kalite %92 ve üzeri, Yüksek 1920×1080 görüntü önerilir. Büyütme ayrıntı eklemez, yalnızca yazıyı daha rahat okutur. Kamera tarih/saati görüntünün içine işler, silinemez: Bulanıklaştır yalnızca sağ üstteki tarih yazısının kutusunu okunmaz yapar, Kes ise üstteki şeridi atar (fotoğraf biraz kısalır).")) {
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
        }
    }

    private var motionSection: some View {
        Section(header: Text("Otomatik çekim"),
                footer: Text("Kamera önüne yeni bir belge konup görüntü durulunca bir kez çeker. Belge değişmedikçe tekrar çekmez.")) {
            Toggle("Görüntü değişince çek", isOn: $settings.motionEnabled)
            Picker("Duyarlılık", selection: $settings.motionSensitivity) {
                Text("Düşük").tag(0)
                Text("Orta").tag(1)
                Text("Yüksek").tag(2)
            }
            .pickerStyle(.segmented)
        }
    }

    private var driveSection: some View {
        Section(header: Text("Google Drive"),
                footer: Text("PDF: her fotoğraf (toplu modda birikenler tek çok sayfalı PDF olarak) gider; resim kalitesi bozulmaz. Gemini gibi yapay zekâlara PDF eklemek kolaydır. Telefondaki kopya her zaman JPEG'dir. OCR açıkken her fotoğrafın yazısı arka planda okunur ve PDF'in sonuna ayrı sayfalar olarak eklenir; telefon ısınırsa ya da yavaşlarsa OCR kendini kapatır. Apple'ın yazı okuyucusu Türkçeyi destekler; büyük “İ” bazen “I” ya da “i” okunabilir. Okunan metin görüntünün üstüne yazılmaz.")) {
            NavigationLink(destination: DriveSetupView(auth: model.auth, queue: model.queue)) {
                Text("Google hesabı ve bağlantı")
            }
            TextField("Drive klasör adı", text: $settings.driveFolderName)
            Picker("Drive'a gönderme", selection: $settings.sendMode) {
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
            Toggle("Metni oku (OCR), PDF sonuna ekle", isOn: $settings.ocrEnabled)
            Toggle("OCR’ı Gemini ile yap (daha akıllı; sayfalar Google’a gider)", isOn: $settings.ocrUseGemini)
                .accessibilityIdentifier("ocr-gemini")
            if settings.ocrEnabled && settings.ocrUseGemini {
                Text("Soru numaralarını, şıkları, tabloları ve küçük yazıyı telefondaki OCR’dan çok daha doğru okur; her sayfa için küçük bir Gemini ücreti çıkar. Gemini bölümünde gizlilik onayı ve anahtar gerekir, yoksa telefondaki OCR kullanılır.")
                    .font(.footnote).foregroundColor(.secondary)
            }
            Toggle("Telefonda da kopya sakla (Dosyalar uygulaması)", isOn: $settings.keepLocalCopies)
        }
    }
}

struct DriveSetupView: View {
    @ObservedObject var auth: GoogleAuth
    @ObservedObject var queue: UploadQueue
    @EnvironmentObject var settings: AppSettings
    @State private var testResult = ""
    @State private var testing = false

    var body: some View {
        Form {
            Section(header: Text("Google Cloud istemcisi"),
                    footer: Text("Türü “TV ve Sınırlı Girişli Cihazlar” olan bir OAuth istemcisi oluşturun (KURULUM.md). Bu bilgiler yalnızca bu telefonun Keychain'inde saklanır. Google parolanızı uygulamaya yazmazsınız.")) {
                TextField("İstemci Kimliği (Client ID)", text: $settings.googleClientID)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                SecureField("İstemci Sırrı (Client secret)", text: $settings.googleClientSecret)
            }

            Section(header: Text("Hesap")) {
                switch auth.phase {
                case .signedIn:
                    Label(auth.email.isEmpty ? "Giriş yapıldı" : auth.email, systemImage: "checkmark.seal.fill")
                        .foregroundColor(.green)
                    Button("Çıkış yap", role: .destructive) { auth.signOut() }
                case .waiting(let code, let url):
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Google sayfasında bu kodu girin:").font(.footnote)
                        Text(code)
                            .font(.system(size: 30, weight: .bold, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Button("Kodu kopyala ve Google sayfasını aç") {
                        UIPasteboard.general.string = code
                        if let link = URL(string: url) { UIApplication.shared.open(link) }
                    }
                    Button("İptal", role: .cancel) { auth.cancelSignIn() }
                case .signedOut:
                    Button("Google ile giriş yap") { auth.startSignIn() }
                }
                if !auth.message.isEmpty {
                    Text(auth.message).font(.footnote).foregroundColor(.secondary)
                }
            }

            if auth.isSignedIn {
                Section(header: Text("Bağlantı")) {
                    Button(testing ? "Sınanıyor…" : "Bağlantıyı sına / klasörü oluştur") {
                        testing = true
                        Task { @MainActor in
                            let text = await queue.testConnection()
                            testResult = text
                            testing = false
                        }
                    }
                    .disabled(testing)
                    if !testResult.isEmpty {
                        Text(testResult).font(.footnote).foregroundColor(.secondary)
                    }
                }
            }

            Section(header: Text("Yükleme kuyruğu")) {
                Text(queue.pending > 0 ? "\(queue.pending) fotoğraf bekliyor" : "Bekleyen fotoğraf yok")
                if !queue.status.isEmpty {
                    Text(queue.status).font(.footnote).foregroundColor(.secondary)
                }
                if queue.pending > 0 {
                    Button(settings.sendMode == "batch" ? "Şimdi gönder" : "Şimdi yeniden dene") { queue.retry() }
                }
            }
        }
        .navigationTitle("Google Drive")
        .navigationBarTitleDisplayMode(.inline)
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
