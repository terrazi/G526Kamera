import SwiftUI

/// Ayarlar: Modül 1 (başlama saati, API anahtarı, 3 kestirme adı) ve Modül 6 (tekrar boşluğu kaydırıcısı)
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: SettingsViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                startSection
                geminiSection
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
        Section(header: Text("Başlama saati"),
                footer: Text("iOS bir uygulamanın kendi kendine uyanmasına izin vermez. Asıl yol: Kestirmeler > Otomasyon > Günün Saati > “URL’yi aç”: g526kamera://basla (Hemen çalıştır). Uygulama açıksa bu saat de başlatır; ayrıca saat gelince sessiz bir bildirim çıkar, dokununca başlar. Telefon açık ve kilitsiz olmalı.")) {
            Toggle("Zamanlı başlatma", isOn: $settings.startEnabled)
            DatePicker("Saat", selection: $settings.startTime, displayedComponents: .hourAndMinute)
                .disabled(!settings.startEnabled)
        }
    }

    // MARK: Gemini

    private var geminiSection: some View {
        Section(header: Text("Gemini"),
                footer: Text("Ses kaydı açıkken soru, dikte metniyle birlikte ses olarak da gider; İngilizce kelimeleri Gemini sesten daha iyi çözer. Gemini sesi açıkken cevap internet varken üretilip kaydedilir, tekrar internetsiz çalışır; olmazsa telefonun sesi kullanılır.")) {
            TextField("API anahtarı", text: $settings.apiKey)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
            HStack {
                Button("Yapıştır") { model.pasteKey() }
                    .buttonStyle(.borderless)
                Spacer()
                Button(model.testingKey ? "Deneniyor…" : "Anahtarı dene") { Task { await model.testKey() } }
                    .buttonStyle(.borderless)
                    .disabled(model.testingKey)
            }
            if !model.keyResult.isEmpty {
                Text(model.keyResult)
                    .font(.footnote)
                    .foregroundColor(model.keyResultOK ? .green : .red)
            }
            Toggle("Soruyu ses olarak da gönder", isOn: $settings.sendAudio)
            Toggle("Cevabı Gemini sesiyle oku", isOn: $settings.geminiVoice)
        }
    }

    // MARK: Kestirmeler

    private var shortcutsSection: some View {
        Section(header: Text("Kestirmeler (kendi kendini onarma)"),
                footer: Text("Kestirmeler uygulamasında yaptığınız kestirmelerin adları. Bağlantı koparsa sırayla Wi-Fi, hücresel, sıfırlama çalışır. Ad boşsa o adım atlanır.")) {
            shortcutRow("Wi-Fi aç", placeholder: "WiFi_Ac", step: .wifi, text: $settings.wifiShortcut)
            shortcutRow("Hücresel aç", placeholder: "Hücresel_Ac", step: .cellular, text: $settings.cellularShortcut)
            shortcutRow("Sistemi sıfırla", placeholder: "Sistemi_Sifirla", step: .reset, text: $settings.resetShortcut)
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
        Section(header: Text("Cevapları tekrarla"),
                footer: Text("Test bitince “Cevapları Tekrarla” her cevabı çalar, bittikten sonra bu süre kadar bekleyip sıradakini çalar.")) {
            HStack {
                Text("Cevaplar arası boşluk")
                Spacer()
                Text("\(Int(settings.replayGap)) sn").foregroundColor(.secondary)
            }
            Slider(value: $settings.replayGap, in: AppSettings.replayGapRange, step: 1)
        }
    }
}
