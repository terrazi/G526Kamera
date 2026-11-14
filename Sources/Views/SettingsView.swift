import SwiftUI

/// Ayarlar: Modül 1 (başlama saati, 4 Gemini profili ve anahtarı, kayıt klasörü, 4 kestirme adı) ve Modül 6 (tekrar boşluğu kaydırıcısı)
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: SettingsViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                startSection
                geminiSection
                geminiProfilesSection
                folderSection
                voiceScreenSection
                readingSection
                shortcutsSection
                replaySection
                Section {
                    NavigationLink(destination: DiagnosticsView()) { Text("Tanı ve günlük") }
                    Text(BuildInfo.version).font(.footnote).foregroundColor(.secondary)
                }
            }
            .navigationTitle("Ayarlar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Bitti") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: Başlama saati

    private var startSection: some View {
        Section(header: Text("Başlama saati")) {
            Toggle("Zamanlı başlatma", isOn: $settings.startEnabled)
            DatePicker("Saat", selection: $settings.startTime, displayedComponents: .hourAndMinute)
                .disabled(!settings.startEnabled)
            HelpRow("iOS bir uygulamanın kendi kendine uyanmasına izin vermez. Asıl yol: Kestirmeler > Otomasyon > Günün Saati > “URL’yi aç”: seslikontrol://basla (Hemen çalıştır). Uygulama açıksa bu saat de başlatır; ayrıca saat gelince sessiz bir bildirim çıkar, dokununca başlar. Telefon açık ve kilitsiz olmalı.")
            HelpRow("Kapanırsa yeniden açılma: Kestirmeler > Otomasyon > Uygulama > Sesli Kontrol > Kapatıldı > Panoyu Al, Eğer pano “SESLIKONTROL-” içeriyorsa kestirmeyi durdur, değilse URL’yi aç: seslikontrol://yeniden (Hemen çalıştır). Uygulama oturum sürerken kapanırsa açılınca kaldığı yerden sürer. Not: yukarı kaydırarak kapatınca yeniden açılma evde denendi ve çalıştı; iOS bunu belgelemediği için her sürümde garanti değildir. Açılmazsa elle açtığınızda oturum kaldığı yerden sürer; günlükteki “pano işareti” satırı otomasyonu neyin engellediğini gösterir. Kapanma yalnız “Programı kapat” düğmesiyle serbesttir: uygulama panoya “SESLIKONTROL-” işaretini yalnız o düğmede ve onarım için Kestirmeler’e bilerek geçerken yazar, otomasyon o zaman açmaz. Oturum yokken ve “Testi Bitir”den sonra da dahil başka her kapanma ya da uygulamadan çıkış otomasyonla geri açılır (yeni oturum başlamaz). Başka uygulama kullanmak için önce ana ekrandaki “Programı kapat” düğmesine 3 saniye basılı tutun.")
        }
    }

    // MARK: Gemini

    private var geminiSection: some View {
        Section(header: Text("Gemini")) {
            Toggle("Soruyu ses olarak da gönder", isOn: $settings.sendAudio)
            Toggle("İngilizce dikteyi de çalıştır", isOn: $settings.englishDictation)
            Toggle("Cevabı Gemini sesiyle oku", isOn: $settings.geminiVoice)
            HelpRow("Ses kaydı açıkken soru, dikte metniyle birlikte ses olarak da gider; İngilizce kelimeleri Gemini sesten daha iyi çözer. İngilizce dikte: Türkçe tanıyıcı İngilizce cümleleri anlamsız Türkçe sözcüklerle yazar; açıkken telefon aynı sesi bir de İngilizce tanıyıcıdan geçirir (ana ekranda “İngilizce:” satırı olarak görünür) ve Gemini'ye ikinci metin olarak yollar. “Cevapla” yine yalnız Türkçe metinde aranır. İki tanıyıcı birlikte çalıştığı için telefon biraz daha ısınır ve pil biraz daha çok gider; yalnız Türkçe sorular okunacaksa kapatabilirsiniz. Telefonda çevrimdışı İngilizce dikte yüklü olmalı. Gemini sesi açıkken cevap internet varken üretilip kaydedilir, tekrar internetsiz çalışır; olmazsa telefonun sesi kullanılır.")
        }
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

    private var geminiProfilesSection: some View {
        Section(header: Text("Gemini modelleri ve API anahtarları (4 yedekli profil)")) {
            ForEach(0..<GeminiProfiles.slotCount, id: \.self) { i in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(i + 1). profil").font(.footnote).foregroundColor(.secondary)
                    TextField("Ad (ör. \(GeminiProfiles.defaultNames[i]))", text: profileName(i))
                        .disableAutocorrection(true)
                    TextField("Model (ör. \(GeminiProfiles.defaultModels[i]))", text: profileModel(i))
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    // anahtar açık görünür: doğru yapıştırıldığı gözle kontrol edilebilsin
                    TextField("API anahtarı", text: profileKey(i))
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    if let problem = GeminiKey.keyShapeProblem(settings.geminiKeys[i]) {
                        Text(problem).font(.caption).foregroundColor(.red)
                    } else if !settings.geminiKeys[i].trimmed.isEmpty {
                        Text("\(settings.geminiKeys[i].trimmed.count) karakter").font(.caption).foregroundColor(.secondary)
                    }
                    HStack(spacing: 24) {
                        Button("Yapıştır") { model.pasteKey(slot: i + 1) }
                        if !settings.geminiKeys[i].trimmed.isEmpty {
                            Button(model.testingKeySlot == i + 1 ? "Deneniyor…" : "Anahtarı dene") {
                                Task { await model.testKey(slot: i + 1) }
                            }
                            .disabled(model.testingKeySlot != 0)
                        }
                    }
                    .buttonStyle(.borderless)
                    if !settings.geminiKeys[i].trimmed.isEmpty {
                        HStack(spacing: 24) {
                            Button(model.listingModelsSlot == i + 1 ? "Listeleniyor…" : "Modelleri listele") {
                                Task { await model.listModels(slot: i + 1) }
                            }
                            .disabled(model.listingModelsSlot != 0)
                            if let list = model.modelLists[i + 1], !list.isEmpty {
                                Menu("Model seç (\(list.count))") {
                                    ForEach(list, id: \.self) { name in
                                        Button(name) { model.chooseModel(name, slot: i + 1) }
                                    }
                                }
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                    if let result = model.keyResults[i + 1] {
                        Text(result.text).font(.caption).foregroundColor(result.ok ? .green : .red)
                    }
                    Toggle(GeminiProfiles.keyKindLabel(free: settings.geminiProfiles[i].free), isOn: profileFree(i))
                }
                .padding(.vertical, 4)
            }
            HelpRow("Soru önce 1. profilin anahtarı ve modeliyle sorulur. Kotası dolarsa, sunucu hata verirse, 40 sn cevap vermezse ya da anahtar/model sorunluysa aynı soru kendiliğinden 2., sonra 3., sonra 4. profile gider. Yalnız anahtarı ve modeli dolu profiller kullanılır; boş bırakılan atlanır. Anahtarı aistudio.google.com'dan alın; ücretli ya da ücretsiz olmak modelin değil anahtarın özelliğidir (faturalandırma bağlı projenin anahtarı ücretlidir), kutuyu buna göre işaretleyin. Anahtarlar yalnız bu telefonun Keychain'inde saklanır. Dikkat: ücretsiz katmanda Google gönderdiğiniz içeriği ürünlerini geliştirmek için kullanabilir.")
        }
    }

    // MARK: Ses ve ekran

    private var voiceScreenSection: some View {
        Section(header: Text("Telefon sesi ve ekran")) {
            Picker("Telefon sesi", selection: $settings.phoneVoiceID) {
                Text("Otomatik").tag("")
                ForEach(SpeechVoiceChooser.sortedTurkish(SpeechVoiceChooser.installed()), id: \.id) { voice in
                    Text(voice.title).tag(voice.id)
                }
            }
            Text("Şu an: " + SpeechVoiceChooser.currentDescription(preferredID: settings.phoneVoiceID))
                .font(.footnote)
                .foregroundColor(.secondary)
            Toggle("Uyarıları sesli söyle", isOn: $settings.spokenWarnings)
            Toggle("Anında tespit (mikrofon ve internet nabzı)", isOn: $settings.instantDetection)
            HelpRow("Anında tespit: dinlerken mikrofonun ses verip vermediğine yarım saniyede bir, internete 5 saniyede bir (ağ yolu değişince hemen) bakılır. Mikrofon bir saniyeden uzun ses vermezse, ses servisi çökerse ya da internet iki nabızdır yoksa, bildirim beklenmeden onarım başlar; yazdığınız yarım soru korunur. Ana ekranda “Canlı” satırı kulaklık, mikrofon ve interneti gösterir. Sorun çıkarsa kapatabilirsiniz; eski davranışa (yalnız iOS bildirimleri) döner. Kapatırsanız takılma gözcüsü, sistem (bellek, ısı, disk) denetimi ve “yaşıyorum” nabzı da durur.")
            Toggle("Test sürerken ekranı kıs", isOn: $settings.dimScreen)
            if settings.dimScreen, !model.dimStatus.isEmpty {
                Text(model.dimStatus)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            HelpRow("Uyarıları sesli söyle: ekrana yazılan her uyarı (internet koptu, mikrofon yok, Kestirmeler sorunu gideremedi, şarj azaldı, ücretli modelden cevaplandı…) kulaklıktan da kısaca söylenir. Yalnız Bluetooth kulaklıktan çalar; kulaklık yoksa hiçbir şey çalınmaz. Soru okunurken ya da cevap verilirken araya girmez, sıradaki sessiz ana kalır. “Otomatik”, telefonda kurulu en kaliteli Türkçe sesi seçer. Daha doğal bir ses için iPhone Ayarlar > Erişilebilirlik > Konuşulan İçerik > Sesler > Türkçe bölümünden “Gelişmiş” ya da “Premium” bir ses indirin, sonra bu ekrana dönün. Bu ses kısa anonslarda (“Ben hazırım…”), Gemini sesi kapalıyken ve Gemini sesi çalışmazken cevaplarda kullanılır; seçtiğiniz sesi ana ekrandaki “Sesi dene” ile kulaklıktan dinleyebilirsiniz (ses telefon hoparlöründen çıkmaz). Ekranı kıs: test sürerken ekran parlaklığı en aza iner ve pil daha yavaş biter; ekran açık kalır (Kestirmeler için gerekir). iOS parlaklık atamasını bazen yok saydığı ya da otomatik parlaklık geri yükselttiği için ekranın üstüne dokunuşları geçiren koyu bir örtü de konur ve parlaklık birkaç saniyede bir denetlenir. Kırmızı bir uyarı çıkınca, ekrana bakıp görebilmeniz için parlaklık kullanıcı ayarına geri verilir (kırmızı uyarı sürdükçe ekran kısılmaz; neden kısılmadığı bu ayarın altında yazar); uygulamadan çıkınca ya da test bitince de geri verilir.")
        }
    }

    // MARK: Okuma komutları ve kesinti

    private var readingSection: some View {
        Section(header: Text("Okuma komutları ve kesinti")) {
            Toggle("Cevaptan sonra sonraki soruyu iste", isOn: $settings.askNextQuestion)
            Toggle("Testi bitirince cevapları oku", isOn: $settings.readAnswersAtEnd)
            Toggle("Soru numarası okunmadıysa sor", isOn: $settings.askMissingNumber)
            Toggle("Gemini beklerken bilgi ver", isOn: $settings.spokenProgress)
            Toggle("Kesintiden sonra akıllı devam", isOn: $settings.smartResume)
            HelpRow("Testi bitirince cevapları oku: “Testi bitir” deyip “evet” dediğinizde program kaydedilen cevapları numara sırasıyla, aralarında Tekrar boşluğu kadar bekleyerek kulaklıktan okur; sonunda kaç sorunun cevabının okunduğunu söyler ve “Devam, Tekrar ya da Bitir” diye sorar. Test sürerken “Cevapları tekrarla” demek de aynı işi yapar. Kapalıysa onaydan sonra test doğrudan biter, cevapları ana ekrandaki tekrar düğmesiyle dinlersiniz.")
            HelpRow("Cevaptan sonra sonraki soruyu iste: cevap kulaklıktan okunup bitince program “Lütfen sonraki soruyu okuyun” der ve ondan sonra dinlemeye geçer; ne zaman okuyacağınızı bilirsiniz. Kapalıyken cevaptan sonra sessizce dinlemeye geçer.")
            HelpRow("Soru numarası okunmadıysa sor: soruyu okuyup “Cevapla” dediniz ama “soru yedi” gibi bir numara söylemediyseniz program “Lütfen okuduğunuz sorunun numarasını söyleyin” der. “Yedi” ya da “soru yedi” demeniz yeter; numara sorunun başına yazılıp Gemini'ye öyle gider. Numarayı bilmiyorsanız “sıradaki” deyin, sıradaki numara verilir. Hiç söylemezseniz iki kez hatırlatılır, sonra sıradaki numarayla gönderilir; soru kaybolmaz. Kapalıyken numara sorulmaz, sıradaki numara verilir.")
            HelpRow("Gemini beklerken bilgi ver: “Cevapla” deyince kulaklıktan “Soru başarıyla alınıp Gemini'ye gönderildi, cevap bekleniyor” denir; cevap uzarsa 30 saniyede bir “Cevap bekleniyor” denir. Gemini 3 dakikada cevap vermezse bekleme bırakılır, durum söylenir ve soruyu yeniden okumanız istenir. Kapalıyken bu anonslar ve 3 dakikalık sınır yoktur.")
            HelpRow("Kesintiden sonra akıllı devam: soru Gemini'ye gittikten sonra bağlantı kopup onarılırsa “Bağlantı yeniden onarıldı. Sorunuz yarım kaldıysa son soruyu tekrar okuyunuz” denir. Okurken kesilirse program soru numarasını ve en son okuduğunuz cümleyi söyler (“En son üçüncü soruda şu cümleyi okudunuz: … Buradan devam edebilirsiniz”); devam ettiğiniz metin öncekiyle birleştirilir. Uygulama tümüyle kapanıp yeniden açılırsa yarım metin korunamaz, soru baştan okunur.")
            HelpRow("Ortak paragraf: birkaç soru aynı paragrafa dayanıyorsa önce “Ortak paragraf” deyip paragrafı okuyun, bitirince “Tamam” deyin. Program “Paragraf metnini aldım, hangi sorular için?” diye sorar; “beş altı yedi” ya da “beşten yediye kadar” deyip “Tamam” deyin. Sonra soruları sırayla okuyun: paragraf, ait olduğu her soruyla birlikte Gemini'ye gider; hepsi cevaplanınca paragraf bırakılır. Paragraf okurken kesinti olursa program son cümleyi söyler, oradan devam edersiniz.")
        }
    }

    // MARK: Kayıt klasörü

    private var folderSection: some View {
        Section(header: Text("Kayıt klasörü")) {
            HStack {
                Text("Durum")
                Spacer()
                Text(model.folderStatus)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            Button("Klasör seç") { model.chooseFolder() }
            Button("Deneme dosyası yaz") { model.writeFolderTest() }
            if !model.folderMessage.isEmpty {
                Text(model.folderMessage).font(.footnote)
            }
            HelpRow("Dosyalar uygulamasında “Bu iPhone” altında “\(FolderStore.suggestedName)” adlı yeni bir klasör açıp seçin. Cevap sesleri (soru_1, soru_2…) ve cevaplar.txt, gün klasörleri içinde buraya kaydedilir; uygulama silinse de kalır. Klasör seçmezseniz cevaplar uygulamanın kendi klasörüne gider ve uygulama silinirse onlar da gider; bu durumda ana ekranda kırmızı uyarı çıkar. Test sürerken klasör değiştirilemez.")
        }
        .onAppear { model.refreshFolderStatus() }
    }

    // MARK: Kestirmeler

    private var shortcutsSection: some View {
        Section(header: Text("Kestirmeler (kendi kendini onarma)")) {
            shortcutRow("Wi-Fi aç", placeholder: "WiFi_Ac", step: .wifi, text: $settings.wifiShortcut)
            shortcutRow("Hücresel aç", placeholder: "Hücresel_Ac", step: .cellular, text: $settings.cellularShortcut)
            shortcutRow("Bluetooth yenile", placeholder: "Bluetooth_Yenile", step: .bluetooth, text: $settings.bluetoothShortcut)
            shortcutRow("Sistemi sıfırla", placeholder: "Sistemi_Sifirla", step: .reset, text: $settings.resetShortcut)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Çıkışı kulaklığa al")
                    TextField("Kulakliga_Al (isteğe bağlı)", text: $settings.outputShortcut)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .multilineTextAlignment(.trailing)
                    Button(model.testingOutputShortcut ? "…" : "Dene") { Task { await model.testOutputShortcut() } }
                        .buttonStyle(.borderless)
                        .disabled(model.testingOutputShortcut)
                }
                if !model.outputShortcutResult.isEmpty {
                    Text(model.outputShortcutResult).font(.footnote).foregroundColor(.secondary)
                }
            }
            HelpRow("“Çıkışı kulaklığa al” isteğe bağlıdır: Kestirmeler'de tek eylemli bir kestirme yapın, “Oynatma Hedefini Ayarla” eylemini ekleyip hedef olarak Bluetooth kulaklığınızı (listede “Bluetooth music” gibi görünür) seçin. Açılışta kulaklık yolda değilse ya da test sürerken kulaklık yoldan çıkarsa uygulama birkaç saniye içinde önce bunu çalıştırır; Bluetooth'u kapatıp açmaz, kulaklığı koparmaz. Çözmezse eskisi gibi “Bluetooth yenile” ve “Sistemi sıfırla” devreye girer. iOS bir uygulamanın Bluetooth ayarlarına girip bağlantıyı kesmesine ya da yeniden bağlamasına izin vermez; bunu yalnız Kestirmeler yapabilir.")
            HelpRow("Kestirmeler uygulamasında yaptığınız kestirmelerin adları. İnternet koparsa sırayla Wi-Fi, hücresel, sıfırlama; Bluetooth kulaklık yoldan çıkarsa önce Bluetooth yenileme, olmazsa sıfırlama çalışır. Yalnız mikrofon sorunluysa (yaka mikrofonu çıktı, alıcı yola girmedi, mikrofon sustu) hiçbir Kestirme çalışmaz: program bekler, nedenini yazar ve mikrofon dönünce devam eder. Ad boşsa o adım atlanır.")
        }
    }

    private func shortcutRow(_ title: String, placeholder: String, step: RecoveryStep, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                TextField(placeholder, text: text)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .multilineTextAlignment(.trailing)
                Button(model.runningShortcut == step ? "…" : "Dene") { Task { await model.testShortcut(step) } }
                    .buttonStyle(.borderless)
                    .disabled(model.runningShortcut != nil)
            }
            if let result = model.shortcutResults[step] {
                Text(result).font(.footnote).foregroundColor(.secondary)
            }
        }
    }

    // MARK: Tekrar

    private var replaySection: some View {
        Section(header: Text("Cevapları tekrarla")) {
            HStack {
                Text("Cevaplar arası boşluk")
                Spacer()
                Text("\(Int(settings.replayGap)) sn").foregroundColor(.secondary)
            }
            Slider(value: $settings.replayGap, in: AppSettings.replayGapRange, step: 1)
            HelpRow("Test bitince “Cevapları Tekrarla” her cevabı çalar, bittikten sonra bu süre kadar bekleyip sıradakini çalar.")
        }
    }
}
