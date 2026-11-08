import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @Environment(\.presentationMode) private var presentation

    var body: some View {
        NavigationView {
            Form {
                cameraSection
                voiceSection
                photoSection
                motionSection
                driveSection
                Section {
                    NavigationLink(destination: DiagnosticsView()) {
                        Text("Tanı ve günlük")
                    }
                }
            }
            .navigationTitle("Ayarlar")
            .navigationBarTitleDisplayMode(.inline)
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

    private var photoSection: some View {
        Section(header: Text("Fotoğraf"),
                footer: Text("Belge taraması için: İyileştirme Hafif, kalite %92 ve üzeri, Yüksek 1920×1080 görüntü önerilir. Büyütme ayrıntı eklemez, yalnızca yazıyı daha rahat okutur.")) {
            Picker("İyileştirme", selection: $settings.enhancement) {
                Text("Kapalı").tag(0)
                Text("Hafif").tag(1)
                Text("Güçlü").tag(2)
            }
            .pickerStyle(.segmented)
            Toggle("Birkaç net kareyi birleştir", isOn: $settings.multiFrame)
            Toggle("Belgeyi otomatik düzelt ve kırp (deneysel)", isOn: $settings.deskew)
            Toggle("Üstteki saat yazısını kes", isOn: $settings.cropTimestamp)
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
        Section(header: Text("Google Drive")) {
            NavigationLink(destination: DriveSetupView(auth: model.auth, queue: model.queue)) {
                Text("Google hesabı ve bağlantı")
            }
            TextField("Drive klasör adı", text: $settings.driveFolderName)
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
                    Button("Şimdi yeniden dene") { queue.retry() }
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
