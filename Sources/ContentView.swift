import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @State private var showSettings = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 14) {
                    preview
                    captureButton
                    if settings.guidanceEnabled { GuidanceRow() }
                    VoiceRow(status: model.speechStatus, heard: model.heardText,
                             enabled: settings.voiceEnabled || settings.guidanceEnabled)
                    if settings.geminiEnabled { GeminiRow(chat: model.gemini) }
                    ExamRow(exam: model.exam)
                    Toggle(isOn: $settings.motionEnabled) {
                        Label("Görüntü değişince otomatik çek", systemImage: "wand.and.rays")
                    }
                    .padding(12)
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(12)
                    DriveStatusRow(auth: model.auth, queue: model.queue)
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

    private var preview: some View {
        ZStack(alignment: .topLeading) {
            if settings.previewOff {
                previewOffBox
            } else {
                VideoLayerView(renderer: model.renderer)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .background(Color.black)
                    .cornerRadius(12)
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

    /// Önizleme kapalıyken: video çizilmez (pil/ısınma), çekim ve diğer her şey çalışmaya devam eder.
    private var previewOffBox: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 34)
            Image(systemName: "eye.slash").font(.title3)
            Text("Önizleme kapalı (pil tasarrufu)")
                .font(.footnote.weight(.semibold))
            Text("Çekim, sesli komut ve Drive çalışıyor. Çekilen fotoğrafı aşağıda görürsünüz.")
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
        .padding(12)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
}

struct DriveStatusRow: View {
    @ObservedObject var auth: GoogleAuth
    @ObservedObject var queue: UploadQueue
    @ObservedObject private var ocr = OcrCenter.shared
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if auth.isSignedIn {
                Label(auth.email.isEmpty ? "Google Drive bağlı" : "Drive: \(auth.email)",
                      systemImage: "icloud.and.arrow.up")
                    .font(.subheadline)
            } else {
                Label("Google Drive bağlı değil (Ayarlar > Google Drive)", systemImage: "icloud.slash")
                    .font(.subheadline)
                    .foregroundColor(.orange)
            }
            if !queue.status.isEmpty {
                Text(queue.status).font(.caption).foregroundColor(.secondary)
            }
            if queue.uploaded > 0 {
                Text("Bu oturumda yüklenen: \(queue.uploaded)").font(.caption).foregroundColor(.secondary)
            }
            if settings.ocrEnabled && !ocr.status.isEmpty {
                Text(ocr.status).font(.caption).foregroundColor(.secondary)
            }
            if queue.pending > 0 && auth.isSignedIn && settings.sendMode == "batch" {
                Button("Şimdi gönder (\(queue.pending))") { queue.retry() }
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
                Button(chat.isActive ? "Durdur" : "Gemini’ye sor") {
                    if chat.isActive { chat.cancel() } else { chat.ask() }
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
        case "scan": return "Deneme sınavı: tarama"
        case "send": return "Deneme sınavı: Drive’a gönderim"
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
