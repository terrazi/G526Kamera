import SwiftUI

/// Ana ekran: durum, kırmızı uyarı kutusu, donanım kontrolü, okunan soru, cevaplar ve düğmeler
struct ContentView: View {
    @EnvironmentObject private var session: SessionViewModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var settingsModel: SettingsViewModel
    @State private var showSettings = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    statusCard
                    if !session.warnings.isEmpty { warningBox }
                    if !session.checkup.isEmpty { checkupList }
                    if !session.liveText.isEmpty { questionCard }
                    if !session.answers.isEmpty { answerList }
                    controls
                    outputPicker
                    Text(BuildInfo.version)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding()
            }
            .navigationTitle("Sesli Kontrol")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Ayarlar") { showSettings = true }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(settings)
                    .environmentObject(settingsModel)
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: Parçalar

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.phase.title)
                .font(.title3.bold())
            if !session.statusNote.isEmpty {
                Text(session.statusNote)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private var warningBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(session.warnings) { warning in
                Text("⚠︎ " + warning.text)
                    .font(.subheadline)
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.red)
        .cornerRadius(12)
    }

    private var checkupList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Donanım kontrolü").font(.headline)
            ForEach(session.checkup) { item in
                HStack(alignment: .top, spacing: 6) {
                    Text(item.ok ? "✓" : "✗").foregroundColor(item.ok ? .green : .red)
                    Text(item.detail.isEmpty ? item.title : "\(item.title): \(item.detail)")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var questionCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Okunan soru").font(.headline)
            Text(session.liveText)
                .font(.subheadline)
                .lineLimit(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(10)
        }
    }

    private var answerList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Cevaplar (\(session.answers.count))").font(.headline)
            ForEach(session.answers) { answer in
                Text(answer.spoken).font(.subheadline)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if session.phase.isAtRest {
                Button("Başlat") { session.start() }
                    .buttonStyle(.borderedProminent)
                Button("Cevapları Tekrarla") { session.startReplay() }
                    .buttonStyle(.bordered)
                    .disabled(!session.canReplay)
            } else if session.phase == .replaying {
                Button("Tekrarı durdur") { session.stopReplay() }
                    .buttonStyle(.bordered)
            } else {
                Button("Testi Bitir") { session.endTest() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var outputPicker: some View {
        HStack {
            Text("Ses çıkışı: Bluetooth kulaklığı seçin")
                .font(.footnote)
                .foregroundColor(.secondary)
            Spacer()
            RoutePickerView().frame(width: 44, height: 44)
        }
    }
}
