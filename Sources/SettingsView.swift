import SwiftUI
import AVFoundation

/// Ayarlar yalnız sınavdan ÖNCE kullanılır; sınav sırasında ekrana dokunulmaz. Varsayılanlar çoğu kullanım için yeterlidir.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @Environment(\.presentationMode) private var presentation
    /// Klasör seçilince durum satırı kendiliğinden yenilensin
    @ObservedObject private var folderChanges = DocumentFolderChanges.shared
    @State private var modelListText = ""
    @State private var listingModels = false
    /// "Anahtarı dene" sonucu (profil numarası → sonuç) ve denenmekte olan profil
    @State private var keyTestResults: [Int: (ok: Bool, text: String)] = [:]
    @State private var testingKeySlot = 0
    @State private var voices: [VoiceInfo] = SpeechVoiceChooser.sortedTurkish(SpeechVoiceChooser.installed())

    var body: some View {
        NavigationView {
            Form {
                scanSection
                cameraSection
                shortcutSection
                geminiSection
                voiceSection
                DocumentFolderSection()
                powerSection
                Section {
                    HStack {
                        Text("Sürüm")
                        Spacer()
                        Text(BuildInfo.version).font(.footnote).foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Ayarlar")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { voices = SpeechVoiceChooser.sortedTurkish(SpeechVoiceChooser.installed()) }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Bitti") { presentation.wrappedValue.dismiss() }
                }
            }
        }
    }

    // MARK: Tarama

    private var scanSection: some View {
        Section(header: Text("Tarama")) {
            NumberRow(title: "Soru sayısı", value: $settings.questionTotal, range: AppSettings.questionTotalRange, unit: "soru")
            NumberRow(title: "Sayfa sayısı", value: $settings.pageTotal, range: AppSettings.pageTotalRange, unit: "sayfa")
            Picker("Şık sayısı", selection: $settings.optionCount) {
                Text("4 (A–D)").tag(4)
                Text("5 (A–E)").tag(5)
            }
            Stepper(value: $settings.sweepSeconds, in: AppSettings.sweepRange) {
                Text("Sayfa çekimi: \(settings.sweepSeconds) sn")
            }
            Picker("Sayfa kenarı denetimi", selection: $settings.coverageMode) {
                Text("Kapalı").tag(0)
                Text("Üst ve alt kenar").tag(1)
                Text("Dört kenar").tag(2)
            }
            Stepper(value: $settings.pageAttempts, in: 1...5) {
                Text("Sayfa başına en çok çekim: \(settings.pageAttempts)")
            }
            Stepper(value: $settings.readyRepeatSeconds, in: 10...300, step: 5) {
                Text("“Kamera hazır” uyarısı: \(settings.readyRepeatSeconds) sn arayla")
            }
            Stepper(value: $settings.readyMaxMinutes, in: 1...120) {
                Text("Evrak gösterilmezse en çok bekleme: \(settings.readyMaxMinutes) dk")
            }
            Stepper(value: $settings.scanMaxMinutes, in: 2...240) {
                Text("Toplam tarama süresi: \(settings.scanMaxMinutes) dk")
            }
            HelpRow("Sayfa sayısı girilirse o kadar sayfa alınınca tarama biter; 0 bırakılırsa kadraj 20 sn boş kalınca (ya da 90 sn yeni sayfa gelmezse) biter. Evrak kameraya tutulunca 2 sn sonra sayfa çekimi başlar: kamerayı sayfanın üstünde yakından, yavaşça gezdirin (üstten alta; iki sütunluysa sütun sütun). Sayfa tek kareye sığmak zorunda değildir; videonun bütünü Gemini’ye gider. Soru numaralarını telefon okumaz, Gemini sayfadan kendisi okur. Sayfa kenarı denetimi: videoda sayfanın üst ve alt kenarı (ya da dört kenarı) bir kez olsun görünmediyse sayfa yeniden istenir; en çok çekim sayısı dolunca sayfa olduğu gibi alınır. Telefon kenarı bulamazsa denetim sessizce atlanır. Sesle yalnız “Kamera hazır”, “N. sayfa alındı”, bu yeniden istek ve cevaplar söylenir; konum tarifi yoktur.")
        }
    }

    // MARK: Kamera

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
            Picker("Kadraj yönü", selection: $settings.guidanceFrame) {
                Text("Yatay").tag(0)
                Text("Dikey (tam sayfa)").tag(1)
            }
            Picker("Görüntü yönü", selection: $settings.imageOrientation) {
                ForEach(AppSettings.orientations(forFrame: settings.guidanceFrame), id: \.self) { o in
                    Text(o.title).tag(o)
                }
            }
            Picker("Tarih / saat yazısı", selection: $settings.timestampMode) {
                Text("Bulanıklaştır").tag(TimestampMode.blur)
                Text("Olduğu gibi bırak").tag(TimestampMode.keep)
            }
            Toggle("Fotoğrafı keskinleştir", isOn: $settings.sharpenImages)
            HelpRow("Kadraj yönü önizleme kutusunu ve görüntünün yönünü belirler; “Dikey”de kamera görüntüsü 90° çevrilir. Kamera adı hazır yazılı gelir; IP boşsa kamera kendiliğinden bulunur. Telefon kameranın Wi-Fi ağına bağlı olmalıdır (bunu kamera kestirmesi yapar). Tarih/saat yazısı kameranın üst köşesindedir; bulanıklaştırmak soru metnine zarar vermez.")
        }
    }

    // MARK: Kestirmeler

    private var shortcutSection: some View {
        Section(header: Text("Kestirmeler (Otomatik başlatma)")) {
            shortcutRow(kind: .camera, title: "Kamera Wi-Fi kestirmesi", name: $settings.cameraShortcutName, identifier: "kamera-kestirmesi")
            shortcutRow(kind: .connection, title: "İnternet kestirmesi", name: $settings.connectionShortcutName, identifier: "baglanti-kestirmesi")
            NumberRow(title: "Deneme sayısı", value: $settings.shortcutTries, range: AppSettings.shortcutTriesRange, unit: "kez")
            NumberRow(title: "Denemeler arası", value: $settings.shortcutWaitSeconds, range: AppSettings.shortcutWaitRange, unit: "sn")
            HelpRow("1) Kamera Wi-Fi kestirmesi: Kestirmeler uygulamasında telefonu kameranın Wi-Fi ağına bağlayan bir kestirme yapın. 2) İnternet kestirmesi: tek kestirmede Wi-Fi’ı kapatın, 2 saniye bekleyin, hücresel veriyi açın. Kameranın Wi-Fi ağındayken telefon hücresel veriyi keser; bu yüzden internet taramadan sonra, kamera kapanınca bu kestirmeyle geri getirilir. 3) Otomatik başlatma: Kestirmeler > Otomasyon > Kişisel otomasyon > Günün Saati; eylem olarak “URL’yi Aç” ve adres olarak g526kamera://basla yazın, “Hemen Çalıştır” seçin. Saat gelince program açılır, kamera kestirmesini çalıştırır ve kamerayı bekler. Deneme sayısı ve aralığı iki kestirme için de geçerlidir (kamera görüntüsü ya da internet gelene kadar tekrar). Telefonun sınav boyunca kilitsiz, ekranı açık ve şarjda olması gerekir. Arama ve mesajların sınav boyunca gelmemesi için iPhone’un Odak (Rahatsız Etme) özelliğini kullanın: bunu uygulama yapamaz, iOS yalnız Odak’a izin verir; Odak’ı da bir otomasyonla sınav saatinde açtırabilirsiniz.")
        }
    }

    /// Bir kestirmenin satırı: ad kutusu + Listeden seç / Yapıştır / Dene
    private func shortcutRow(kind: ShortcutKind, title: String, name: Binding<String>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(title, text: name)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .accessibilityIdentifier(identifier)
            HStack(spacing: 20) {
                Button("Listeden seç") {
                    if let url = ShortcutLink.pickerURL(kind: kind) { UIApplication.shared.open(url) }
                }
                Button("Yapıştır") {
                    if let text = UIPasteboard.general.string?.trimmed, !text.isEmpty { name.wrappedValue = text }
                }
                Button("Dene") { model.testShortcut(named: name.wrappedValue) }
                    .disabled(name.wrappedValue.trimmed.isEmpty)
            }
            .buttonStyle(BorderlessButtonStyle())
        }
    }

    // MARK: Gemini

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

    private var geminiSection: some View {
        Section(header: Text("Gemini (4 model profili)")) {
            Picker("Gemini'ye gönderilen", selection: $settings.pageInput) {
                Text("Video + net kareler").tag(0)
                Text("Yalnız net kareler").tag(1)
                Text("Yalnız video").tag(2)
            }
            HelpRow("Her sayfa için gezdirme videosu gider. Gemini videoyu saniyede yaklaşık 1 kare, düşük çözünürlükle işler; küçük yazı videoda zor okunabilir. Bu yüzden varsayılan olarak videodan seçilen 8 kadar net kare de (PDF) yanında gider. Yalnız net kareler: video gönderilmez (en küçük istek). Yalnız video: kareler gönderilmez. Hangisinin daha iyi okuduğunu deneyerek görün.")
            Picker("İlk denenen model", selection: $settings.geminiActive) {
                ForEach(0..<GeminiProfiles.slotCount, id: \.self) { i in
                    Text(settings.geminiProfiles[i].name.trimmed.isEmpty ? "Model \(i + 1)" : settings.geminiProfiles[i].name).tag(i + 1)
                }
            }
            ForEach(0..<GeminiProfiles.slotCount, id: \.self) { i in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(i + 1). model").font(.footnote).foregroundColor(.secondary)
                    TextField("Ad (ör. \(GeminiProfiles.defaultNames[i]))", text: profileName(i))
                        .disableAutocorrection(true)
                    TextField("Model (ör. \(GeminiConfig.defaultModel))", text: profileModel(i))
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    // anahtar açık görünür: doğru yapıştırıldığı gözle kontrol edilebilsin
                    TextField("API anahtarı", text: profileKey(i))
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    if let problem = GeminiProfiles.keyShapeProblem(settings.geminiKeys[i]) {
                        Text(problem).font(.caption).foregroundColor(.red)
                    } else if !settings.geminiKeys[i].trimmed.isEmpty {
                        Text("\(settings.geminiKeys[i].trimmed.count) karakter").font(.caption).foregroundColor(.secondary)
                    }
                    HStack(spacing: 24) {
                        Button("Yapıştır") { pasteGeminiKey(slot: i + 1) }
                        if !settings.geminiKeys[i].trimmed.isEmpty {
                            Button(testingKeySlot == i + 1 ? "Deneniyor…" : "Anahtarı dene") { testGeminiKey(slot: i + 1) }
                                .disabled(testingKeySlot != 0)
                        }
                    }
                    .buttonStyle(BorderlessButtonStyle())
                    if let result = keyTestResults[i + 1] {
                        Text(result.text).font(.caption).foregroundColor(result.ok ? .green : .red).textSelection(.enabled)
                    }
                    Toggle(GeminiProfiles.keyKindLabel(free: settings.geminiProfiles[i].free), isOn: profileFree(i))
                }
            }
            Stepper(value: $settings.geminiWaitLimit, in: 0...600, step: 5) {
                Text(settings.geminiWaitLimit == 0 ? "Cevap bekleme sınırı: yok" : "Cevap bekleme sınırı: \(settings.geminiWaitLimit) sn")
            }
            TextField("Şık kodları (A=ADANA, B=BURSA, …)", text: $settings.geminiOptionCodes)
                .textInputAutocapitalization(.characters)
                .disableAutocorrection(true)
            Button(listingModels ? "Modeller isteniyor…" : "Modelleri listele (ilk modelin anahtarıyla)") { listGeminiModels() }
                .disabled(listingModels)
            if !modelListText.isEmpty {
                Text(modelListText).font(.footnote).foregroundColor(.secondary).textSelection(.enabled)
            }
            HelpRow("Sayfalar (video ve net kareler), standart bir talimatla Gemini’ye gönderilir; soru numaralarını Gemini sayfadan okur, cevaplar numaraya göre sıralanır; gönderilemeyen sayfalar bir kez daha denenir. Model zinciri: ilk model kotası dolarsa, sunucu hata verirse ya da cevap bekleme sınırında yanıt gelmezse sıradaki profile (kendi anahtarıyla) geçilir; son modele sınır konmaz. Her profilin kendi API anahtarı vardır (aistudio.google.com); anahtarlar yalnız bu telefonun Keychain’inde saklanır. Ücretsiz katmanda içeriğiniz Google tarafından ürün geliştirmede kullanılabilir. Şık kodları: cevap sesli okunurken şık harfi yerine bu kelime söylenir (A=ADANA ise “ADANA”).")
        }
    }

    /// Panodaki anahtarı ilgili alana yazar (eskisinin yerine geçer); eski deneme sonucu silinir
    private func pasteGeminiKey(slot: Int) {
        guard let key = GeminiProfiles.cleanedKey(fromClipboard: UIPasteboard.general.string) else {
            keyTestResults[slot] = (false, "Panoda metin yok. Önce anahtarı kopyalayın.")
            return
        }
        settings.geminiKeys[slot - 1] = key
        keyTestResults[slot] = nil
        tlog("[gemini] \(slot). profile anahtar yapıştırıldı (\(GeminiProfiles.keyHint(key)))")
    }

    /// Profilin anahtarını Google'a denetir: profildeki modele çok kısa bir soru gider; başlık reddedilirse anahtar adreste de denenir
    private func testGeminiKey(slot: Int) {
        guard let profile = settings.geminiProfileInfos().first(where: { $0.slot == slot }) else { return }
        testingKeySlot = slot
        keyTestResults[slot] = (true, "Google'a soruluyor…")
        let client = GeminiClient(key: { profile.key }, model: { profile.model })
        Task { @MainActor in
            let header = await client.probeKey(model: profile.model, key: profile.key, viaQuery: false)
            var query: KeyProbe?
            if GeminiProfiles.isKeyRejection(header) {
                query = await client.probeKey(model: profile.model, key: profile.key, viaQuery: true)
            }
            let text = GeminiProfiles.keyProbeText(model: profile.model, key: profile.key, header: header, query: query)
            tlog("[gemini] anahtar denemesi (\(profile.name), \(GeminiProfiles.keyHint(profile.key))): \(text.text)")
            keyTestResults[slot] = text
            testingKeySlot = 0
        }
    }

    /// İlk modelin anahtarının görebildiği modelleri yazar (doğru model adını bulmak için)
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

    // MARK: Ses

    private var voiceSection: some View {
        Section(header: Text("Ses (yalnız kulaklık)")) {
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
            Stepper(value: $settings.answerPauseSeconds, in: 0...60) {
                Text("İlk okumada cevaplar arası: \(settings.answerPauseSeconds) sn")
            }
            Stepper(value: $settings.repeatPauseSeconds, in: 0...60) {
                Text("Tekrar okumada cevaplar arası: \(settings.repeatPauseSeconds) sn")
            }
            Button("Bu sesi dene") { model.previewVoice() }
            HelpRow("Program hiçbir şey dinlemez (mikrofon yok); yalnız kulaklığa konuşur. Ses kulaklığa ya da Bluetooth çıkışa gitmiyorsa, yani çıkış telefon hoparlörüyse, hiçbir şey okunmaz ve ana ekranda uyarı çıkar. Cevaplar önce sırayla, sonra “Cevaplar bir kez daha okunuyor” denip bir kez daha okunur. “Otomatik”, telefonda kurulu en kaliteli Türkçe sesi seçer; daha doğal ses için iPhone Ayarlar > Erişilebilirlik > Konuşulan İçerik > Sesler > Türkçe bölümünden Gelişmiş ya da Premium sesi indirin.")
        }
    }

    // MARK: Pil

    private var powerSection: some View {
        Section(header: Text("Pil ve ısınma")) {
            Toggle("Önizlemeyi kapat", isOn: $settings.previewOff)
            Toggle("Ekran parlaklığını çok azalt", isOn: $settings.dimScreen)
            HelpRow("Önizlemeyi kapatmak ve parlaklığı azaltmak ısınmayı ve pil tüketimini düşürür; tarama aynen sürer. Kamera görüntüsü çözme ve okuma (OCR) işlemleri telefonda yapılır; uzun sınavda şarjda olun.")
        }
    }
}

/// Tam sayı giriş satırı: sayı tuş takımıyla yazılır, izin verilen aralığa çekilir
struct NumberRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var unit = ""
    @State private var text = ""

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0", text: $text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                .onChange(of: text) { newText in
                    let digits = newText.filter { $0.isNumber }
                    if digits != newText {
                        text = digits
                        return
                    }
                    if let n = Int(digits) {
                        let clamped = min(max(n, range.lowerBound), range.upperBound)
                        if clamped != value { value = clamped }
                    }
                }
            if !unit.isEmpty { Text(unit).foregroundColor(.secondary) }
        }
        .onAppear { text = String(value) }
    }
}
