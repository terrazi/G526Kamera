import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @State private var showSettings = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 14) {
                    NoticeRow(messages: [model.crashNotice, model.diskNotice, model.thermalNotice, model.networkNotice, model.micNotice, model.routeNotice])
                    preview
                    powerToggles
                    captureButton
                    videoButton
                    if model.queuedVideos > 0 || model.sendingVideos { sendVideosButton }
                    if !model.videoAnswer.isEmpty {
                        Text(model.videoAnswer)
                            .font(.footnote)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(12)
                    }
                    if settings.guidanceEnabled { GuidanceRow() }
                    VoiceRow(status: model.speechStatus, heard: model.heardText,
                             enabled: settings.voiceEnabled || settings.guidanceEnabled)
                    if settings.geminiEnabled { GeminiRow(chat: model.gemini, exam: model.exam) }
                    ExamRow(exam: model.exam)
                    Toggle(isOn: $settings.motionEnabled) {
                        Label("Görüntü değişince otomatik çek", systemImage: "wand.and.rays")
                    }
                    .padding(12)
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(12)
                    FolderStatusRow(queue: model.queue)
                    lastPhoto
                }
                .padding(16)
            }
            .navigationTitle("G526 Kamera")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Ayarlar")
                    .accessibilityIdentifier("ayarlar")
                }
            }
            .sheet(isPresented: $showSettings, onDismiss: { model.applySettings() }) {
                SettingsView()
                    .environmentObject(model)
                    .environmentObject(settings)
            }
        }
        .navigationViewStyle(.stack)
    }

    /// Önizleme kutusu "Kadraj yönü" ayarını izler: Dikey seçiliyse dikey (9:16), Yatay seçiliyse yatay (16:9).
    /// Kamera karesi kırpılmaz: ekranda kameranın gördüğünün tamamı vardır; oran uymazsa kenarlar boş kalır.
    private var previewSize: CGSize {
        return PreviewLayout.box(screen: UIScreen.main.bounds.size, portrait: settings.guidanceFrame == 1)
    }

    private var previewVideo: some View {
        VideoLayerView(renderer: model.renderer, orientation: settings.imageOrientation)
            .frame(width: previewSize.width, height: previewSize.height)
            .background(Color.black)
            .cornerRadius(12)
    }

    private var preview: some View {
        ZStack(alignment: .topLeading) {
            if settings.previewOff {
                previewOffBox
            } else {
                previewVideo
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(model.isLive ? Color.green : Color.orange)
                    .frame(width: 9, height: 9)
                Text(model.statusText)
                    .font(.caption)
                    .lineLimit(2)
                if model.isLive && !model.resolutionText.isEmpty {
                    Text(model.resolutionText).font(.caption2).foregroundColor(.secondary)
                }
                if model.isLive, let battery = model.cameraBattery {
                    Text(battery.shortText)
                        .font(.caption2)
                        .foregroundColor(battery.isLow ? .red : .secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .cornerRadius(10)
            .padding(8)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .overlay(alignment: .bottom) {
            if !model.banner.isEmpty {
                Text(model.banner)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.75))
                    .foregroundColor(.white)
                    .cornerRadius(10)
                    .padding(10)
            }
        }
    }

    /// Isınmayı azaltmak için iki tik: önizlemeyi kapat, ekran parlaklığını azalt
    private var powerToggles: some View {
        VStack(spacing: 0) {
            Toggle(isOn: $settings.previewOff) {
                Label("Önizlemeyi kapat", systemImage: "eye.slash")
            }
            .accessibilityIdentifier("onizlemeyiKapat")
            Divider().padding(.vertical, 8)
            Toggle(isOn: $settings.dimScreen) {
                Label("Ekran parlaklığını azalt", systemImage: "sun.min")
            }
            .accessibilityIdentifier("parlakligiAzalt")
        }
        .padding(12)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }

    /// Önizleme kapalıyken: video çizilmez (pil/ısınma), çekim ve diğer her şey çalışmaya devam eder.
    private var previewOffBox: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 34)
            Image(systemName: "eye.slash").font(.title3)
            Text("Önizleme kapalı (pil tasarrufu)")
                .font(.footnote.weight(.semibold))
            Text("Çekim ve sesli komut çalışıyor. Çekilen fotoğrafı aşağıda görürsünüz.")
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.7))
            Button("Önizlemeyi aç") { settings.previewOff = false }
                .font(.footnote)
                .accessibilityIdentifier("onizlemeyi-ac")
            Spacer(minLength: 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .foregroundColor(.white)
        .background(Color.black)
        .cornerRadius(12)
    }

    private var captureButton: some View {
        Button {
            model.capture(reason: "Elle")
        } label: {
            HStack {
                Image(systemName: "camera.fill")
                Text(model.capturing ? "İşleniyor…" : "Fotoğraf Çek")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(model.isLive ? Color.accentColor : Color.gray)
            .foregroundColor(.white)
            .cornerRadius(12)
        }
        .disabled(model.capturing || !model.isLive)
    }

    /// Video kaydı: açıkken kırmızı; en çok 90 sn sürer, "kapat" denince ya da süre dolunca biter ve belge klasörüne kaydedilir
    private var videoButton: some View {
        Button {
            model.toggleVideo()
        } label: {
            HStack {
                Image(systemName: model.videoRecording ? "stop.circle.fill" : "video.fill")
                Text(model.videoRecording ? "Kaydı kapat" : "Video kaydı (en çok 90 sn)")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(model.videoRecording ? Color.red : (model.isLive ? Color.accentColor : Color.gray))
            .foregroundColor(.white)
            .cornerRadius(12)
        }
        .disabled(!model.isLive && !model.videoRecording)
        .accessibilityIdentifier("videoKaydi")
    }

    /// Sıradaki videoları tek tek Gemini'ye gönderir ("videoları gönder" demekle aynı)
    private var sendVideosButton: some View {
        Button {
            model.sendQueuedVideos()
        } label: {
            HStack {
                Image(systemName: "paperplane.fill")
                Text(model.sendingVideos ? "Gemini'ye gönderiliyor… (\(model.queuedVideos) kaldı)"
                                         : "Videoları gönder (\(model.queuedVideos))")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(model.sendingVideos ? Color.gray : Color.orange)
            .foregroundColor(.white)
            .cornerRadius(12)
        }
        .disabled(model.sendingVideos || model.videoRecording)
        .accessibilityIdentifier("videolariGonder")
    }

    @ViewBuilder
    private var lastPhoto: some View {
        if let image = model.lastPhoto {
            VStack(alignment: .leading, spacing: 6) {
                Text("Son fotoğraf").font(.footnote).foregroundColor(.secondary)
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .cornerRadius(10)
                Text(model.lastPhotoInfo).font(.caption).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct VoiceRow: View {
    let status: String
    let heard: String
    let enabled: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Label(enabled ? (status.isEmpty ? "Sesli komut başlatılıyor…" : status) : "Sesli komut kapalı",
                      systemImage: enabled ? "mic.fill" : "mic.slash")
                    .font(.subheadline)
                if enabled && !heard.isEmpty {
                    Text("Duyulan: “\(heard)”")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Ses çıkışı (kulaklık) seçimi: iOS'un kendi listesi açılır
            RoutePickerButton()
                .frame(width: 36, height: 36)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
}

struct FolderStatusRow: View {
    @ObservedObject var queue: UploadQueue
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        let ready = DocumentFolder.shared.hasChoice
        VStack(alignment: .leading, spacing: 4) {
            if ready {
                Label("Belge klasörü seçildi", systemImage: "folder.fill")
                    .font(.subheadline)
            } else {
                Label("Belge klasörü seçilmedi (Ayarlar > Belge klasörü)", systemImage: "folder.badge.questionmark")
                    .font(.subheadline)
                    .foregroundColor(.orange)
            }
            if !queue.status.isEmpty {
                Text(queue.status).font(.caption).foregroundColor(.secondary)
            }
            if queue.uploaded > 0 {
                Text("Bu oturumda kaydedilen: \(queue.uploaded)").font(.caption).foregroundColor(.secondary)
            }
            if queue.pending > 0 && ready && settings.sendMode == "batch" {
                Button("Şimdi kaydet (\(queue.pending))") { queue.retry() }
                    .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
}


/// Sesli konumlandırma durumu: ne söylendiği, hangi bölümün seçildiği, bölüm sorusu ve (yedek) düğmeler.
struct GuidanceRow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(model.guidanceStatus.isEmpty ? "Sesli konumlandırma hazır" : model.guidanceStatus,
                  systemImage: "viewfinder")
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("konumlandirma-durum")
            if !model.guidanceSaid.isEmpty {
                Label(model.guidanceSaid, systemImage: "speaker.wave.2")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .accessibilityIdentifier("konumlandirma-soylenen")
            }
            if !model.guidanceNotice.isEmpty {
                Label(model.guidanceNotice, systemImage: "questionmark.circle")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .accessibilityIdentifier("konumlandirma-uyari")
            }
            if model.guidanceAwaiting {
                HStack(spacing: 8) {
                    ForEach(model.guidanceOptions, id: \.self) { choice in
                        Button(choice == .all ? "Hepsi" : choice.title) { model.chooseColumn(choice) }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("bolum-\(choice.rawValue)")
                    }
                }
                Text("Sesle de söyleyebilirsiniz: “sol”, “sağ”…")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
}


/// Gemini ile belge sohbeti: durum, son soru ve cevap, "Gemini'ye sor" düğmesi.
struct GeminiRow: View {
    @ObservedObject var chat: GeminiChat
    /// Deneme sınavı açıkken düğme sınavın "dinle" akışını (her an Gemini ile serbest konuşma) başlatır / keser
    @ObservedObject var exam: ExamMode

    private var headline: String {
        switch chat.phase {
        case .idle: return "Gemini hazır"
        case .listening: return "Dinliyorum…"
        case .thinking: return "Gemini düşünüyor…"
        case .speaking: return "Cevap okunuyor"
        }
    }

    private var icon: String {
        switch chat.phase {
        case .idle: return "sparkles"
        case .listening: return "mic.fill"
        case .thinking: return "hourglass"
        case .speaking: return "speaker.wave.2.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(headline, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("gemini-durum")
            if !chat.status.isEmpty {
                Text(chat.status).font(.caption).foregroundColor(.secondary)
            }
            if !chat.docNames.isEmpty {
                Text("Belgeler: " + chat.docNames.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            if !chat.question.isEmpty {
                Text("Soru: \(chat.question)").font(.footnote).foregroundColor(.secondary)
            }
            if !chat.answer.isEmpty {
                Text(chat.answer).font(.callout)
            }
            if !chat.error.isEmpty {
                Label(chat.error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            HStack(spacing: 12) {
                Button(chat.isActive ? "Durdur" : (exam.info.active ? "Dinle (Gemini)" : "Gemini’ye sor")) {
                    if exam.info.active {
                        _ = exam.listenRequest(source: "ui")
                    } else if chat.isActive {
                        chat.cancel()
                    } else {
                        chat.ask()
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("gemini-sor")
                if chat.turns > 0 && !chat.isActive {
                    Button("Yeni sohbet") { chat.newConversation() }
                        .buttonStyle(.bordered)
                }
            }
            if chat.turns > 0 {
                Text("Sohbette \(chat.turns) soru · son cevap \(chat.tokens) jeton")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
}


/// Deneme sınavı kartı: adım, sayaçlar, son söylenen cümle ve başlat / kapat düğmeleri
struct ExamRow: View {
    @ObservedObject var exam: ExamMode

    private var headline: String {
        switch exam.stage {
        case "video": return "Deneme sınavı: video"
        case "scan": return "Deneme sınavı: tarama"
        case "send": return "Deneme sınavı: klasöre kaydetme"
        case "prepare", "verify": return "Deneme sınavı: belgeler okunuyor"
        case "answer": return "Deneme sınavı: cevaplar"
        case "review": return "Deneme sınavı: soru numarası bekleniyor"
        default: return exam.info.saved ? "Deneme sınavı: yarım kalan sınav var" : "Deneme sınavı"
        }
    }

    /// Cevap anahtarı satırının yazısı
    static func keyText(_ r: ExamKeyRow) -> String {
        let head = r.bolum.isEmpty ? "\(r.no). soru" : "\(r.bolum), \(r.no). soru"
        if r.durum == ExamStatus.unread { return "\(head): okunamadı" }
        if r.durum == ExamStatus.missing { return "\(head): alınamadı" }
        func part(_ sik: String, _ word: String, _ deger: String) -> String {
            var out = [sik, word].filter { !$0.isEmpty }.joined(separator: " - ")
            if !deger.isEmpty { out = out.isEmpty ? deger : "\(out), \(deger)" }
            return out
        }
        let main = part(r.sik, r.word, r.deger)
        var text = "\(head): \(main.isEmpty ? "-" : main)"
        if r.durum == ExamStatus.unsure {
            text += " (emin değil"
            if !r.altSik.isEmpty || !r.altDeger.isEmpty { text += "; ikinci çözüm: \(part(r.altSik, r.altWord, r.altDeger))" }
            text += ")"
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(headline, systemImage: "list.number")
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("sinav-durum")
            if !exam.status.isEmpty {
                Text(exam.status).font(.caption).foregroundColor(.secondary)
            }
            if exam.info.active || exam.info.questions > 0 {
                Text("\(exam.info.scanned) sayfa · \(exam.info.files) PDF · \(exam.info.questions) soru · \(exam.info.answered) cevap")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            if let last = exam.said.last {
                Text(last).font(.footnote)
            }
            if !exam.key.isEmpty {
                DisclosureGroup("Cevap anahtarı (\(exam.key.count) soru)") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(exam.key) { row in
                            Text(ExamRow.keyText(row))
                                .font(.footnote)
                                .foregroundColor(row.durum == ExamStatus.ok ? .primary : .orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.footnote)
                .accessibilityIdentifier("sinav-anahtar")
            }
            HStack(spacing: 12) {
                Button(exam.info.active ? "Sınavı kapat" : "Deneme sınavı modu") {
                    if exam.info.active {
                        exam.stop()
                    } else {
                        _ = exam.start()
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("sinav-dugme")
                if exam.info.active && exam.stage == "scan" {
                    Button("Tarama tamamlandı") { _ = exam.command("scan_done", source: "ui") }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("sinav-tarama-tamam")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
}

/// Kendi kendini denetlemenin bulduğu sorunlar (internet yok, mikrofon sessiz, ses yanlış çıkışa gidiyor): kırmızı kutu.
/// Ses çalışmıyor olabileceği için sorun ekranda da görünür.
struct NoticeRow: View {
    let messages: [String]

    var body: some View {
        let active = messages.filter { !$0.isEmpty }
        if !active.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(active, id: \.self) { text in
                    Label(text, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundColor(.white)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.red)
            .cornerRadius(12)
            .accessibilityIdentifier("uyari-kutusu")
        }
    }
}
