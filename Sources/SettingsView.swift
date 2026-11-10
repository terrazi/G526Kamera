import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @Environment(\.presentationMode) private var presentation
    @State private var voiceTestResult = ""
    @State private var voices: [VoiceInfo] = SpeechVoiceChooser.sortedTurkish(SpeechVoiceChooser.installed())

    var body: some View {
        NavigationView {
            Form {
                cameraSection
                voiceSection
                readingVoiceSection
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
