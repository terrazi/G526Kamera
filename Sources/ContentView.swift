import SwiftUI

/// Ana ekran: kamera önizlemesi, tarama durumu, kırmızı uyarı kutusu ve cevaplar. Sınav sırasında dokunulmaz; yalnız elle başlatma / durdurma için düğme vardır.
struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @State private var showSettings = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 14) {
                    ProblemBox(notes: model.notes)
                    preview
                    statusCard
                    startStopButton
                    if !model.answers.isEmpty { answersCard }
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
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(model)
                    .environmentObject(settings)
            }
        }
        .navigationViewStyle(.stack)
    }

    /// Önizleme kutusu "Kadraj yönü" ayarını izler (Dikey: 9:16, Yatay: 16:9); kamera karesi kırpılmaz
    private var previewSize: CGSize {
        return PreviewLayout.box(screen: UIScreen.main.bounds.size, portrait: settings.guidanceFrame == 1)
    }

    private var preview: some View {
        ZStack(alignment: .topLeading) {
            if settings.previewOff {
                VStack(spacing: 6) {
                    Image(systemName: "eye.slash")
                    Text("Önizleme kapalı").font(.footnote)
                }
                .foregroundColor(.secondary)
                .frame(width: previewSize.width, height: previewSize.height)
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(12)
            } else {
                VideoLayerView(renderer: model.renderer, orientation: settings.imageOrientation)
                    .frame(width: previewSize.width, height: previewSize.height)
                    .background(Color.black)
                    .cornerRadius(12)
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(model.decoding ? Color.green : Color.orange)
                    .frame(width: 9, height: 9)
                Text(model.decoding ? "Kamera canlı" : model.cameraState.text)
                    .font(.caption)
                    .lineLimit(2)
                if model.decoding && !model.resolutionText.isEmpty {
                    Text(model.resolutionText).font(.caption2).foregroundColor(.secondary)
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

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.phase.title)
                .font(.headline)
                .accessibilityIdentifier("asama")
            Text(model.statusText)
                .font(.subheadline)
                .foregroundColor(.secondary)
            if settings.questionTotal > 0 || !model.acceptedNumbers.isEmpty {
                Text(progressText)
                    .font(.subheadline)
            }
            if let open = model.openQuestion {
                Text("\(open). sorunun devamı bekleniyor")
                    .font(.footnote)
                    .foregroundColor(.orange)
            }
            if !model.lastSaid.isEmpty {
                Text("Son söylenen: \(model.lastSaid)")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }

    private var progressText: String {
        let count = model.acceptedNumbers.count
        let total = settings.questionTotal
        let head = total > 0 ? "Alınan soru: \(count)/\(total)" : "Alınan soru: \(count)"
        guard !model.acceptedNumbers.isEmpty else { return head }
        return head + " (" + model.acceptedNumbers.map { String($0) }.joined(separator: ", ") + ")"
    }

    private var startStopButton: some View {
        Button {
            if model.phase.isRunning { model.stopScan() } else { model.beginScan(auto: false) }
        } label: {
            Label(model.phase.isRunning ? "Taramayı durdur" : "Taramayı başlat",
                  systemImage: model.phase.isRunning ? "stop.circle" : "play.circle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(model.phase.isRunning ? .red : .accentColor)
        .accessibilityIdentifier("baslat-durdur")
    }

    private var answersCard: some View {
        let codes = GeminiSupport.parseOptionCodes(settings.geminiOptionCodes)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Cevaplar").font(.headline)
            ForEach(model.answers, id: \.number) { record in
                Text(AnswerService.spokenLine(record, codes: codes))
                    .font(.footnote)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
}

/// Kırmızı uyarı kutusu: sorun varsa görünür, yoksa hiç yer kaplamaz
struct ProblemBox: View {
    let notes: [ProblemNote]

    var body: some View {
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(notes, id: \.key) { note in
                    Label(note.text, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .background(Color.red)
            .cornerRadius(12)
            .accessibilityIdentifier("kirmizi-kutu")
        }
    }
}
