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
                shortcutsSection
                replaySection
                Section {
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
        }
    }

    // MARK: Gemini

    private var geminiSection: some View {
        Section(header: Text("Gemini")) {
            Toggle("Soruyu ses olarak da gönder", isOn: $settings.sendAudio)
            Toggle("Cevabı Gemini sesiyle oku", isOn: $settings.geminiVoice)
            HelpRow("Ses kaydı açıkken soru, dikte metniyle birlikte ses olarak da gider; İngilizce kelimeleri Gemini sesten daha iyi çözer. Gemini sesi açıkken cevap internet varken üretilip kaydedilir, tekrar internetsiz çalışır; olmazsa telefonun sesi kullanılır.")
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
            HelpRow("Kestirmeler uygulamasında yaptığınız kestirmelerin adları. İnternet koparsa sırayla Wi-Fi, hücresel, sıfırlama; kulaklık ya da mikrofon koparsa önce Bluetooth yenileme, olmazsa sıfırlama çalışır. Ad boşsa o adım atlanır.")
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
