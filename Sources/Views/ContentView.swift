import SwiftUI

/// Ana ekran: durum, kırmızı uyarı kutusu, donanım kontrolü, yüklenen sorular (gidiş işaretiyle), düğmeler ve ses girişi / çıkışı
struct ContentView: View {
    @EnvironmentObject private var session: SessionViewModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var settingsModel: SettingsViewModel
    @State private var showSettings = false
    @State private var confirmEnd = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    statusCard
                    if !session.warnings.isEmpty { warningBox }
                    if !session.checkup.isEmpty { checkupList }
                    if !session.questions.isEmpty || liveQuestion != nil { questionList }
                    controls
                    outputPicker
                    inputPicker
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
            .confirmationDialog("Test bitirilsin mi?", isPresented: $confirmEnd, titleVisibility: .visible) {
                Button("Testi Bitir", role: .destructive) { session.endTest() }
                Button("Vazgeç", role: .cancel) {}
            } message: {
                Text("Dinleme durur. Kaydedilen cevaplar kalır, “Cevapları Tekrarla” ile dinlenir.")
            }
            .onChange(of: session.phase.isAtRest) { rest in
                // Test bitince ya da hiç başlamadıysa ekran kilidi kalmasın
                if rest { ScreenLock.shared.unlock() }
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

    /// Okunmakta olan soru (dinleme sürerken, henüz "Cevapla" denmemiş)
    private var liveQuestion: String? {
        guard session.phase == .listening, !session.liveText.isEmpty else { return nil }
        return session.liveText
    }

    /// Tek liste: yüklenen sorular, her birinin yanında Gemini'ye gidiş işareti. Yeni soru en üstte; durum canlı güncellenir.
    private var questionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Yüklenen sorular (\(session.questions.count))").font(.headline)
            if let live = liveQuestion {
                questionBox {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            markSlot { Image(systemName: "clock.fill").foregroundColor(.orange) }
                            Text(live)
                                .font(.subheadline)
                                .lineLimit(6)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !session.liveEnglish.isEmpty {
                            Text("İngilizce: " + session.liveEnglish)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .lineLimit(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("Bekliyor: “Cevapla” demenizi bekliyor")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
            }
            ForEach(Array(session.questions.reversed())) { entry in
                questionBox { entryRow(entry) }
            }
        }
    }

    private func questionBox<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(10)
    }

    private func entryRow(_ entry: QuestionEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                mark(for: entry.state)
                Text("\(entry.number). " + entry.text)
                    .font(.subheadline)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch entry.state {
            case .sending:
                Text(entry.withAudio ? "Gitti (ses kaydıyla), cevap bekleniyor…" : "Gitti, cevap bekleniyor…")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            case .answered(let spoken):
                Text(spoken).font(.footnote.bold())
                if entry.numberSource == .sequence {
                    Text("Numara okunmadı; sıradaki numara verildi. Numarayı \"soru yedi\" gibi okuyun.")
                        .font(.caption2)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !entry.model.isEmpty {
                    Text(entry.model).font(.caption2).foregroundColor(.secondary)
                }
            case .failed(let reason):
                Text("Gitmedi: " + reason)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Sorunun yanındaki işaret. Saat: okunuyor, "Cevapla" bekleniyor (yukarıdaki canlı satır). Mektup: gitti, cevap bekleniyor.
    /// Gülen yüz: cevaplandı. Kırmızı çarpı: gitmedi.
    @ViewBuilder
    private func mark(for state: QuestionEntry.State) -> some View {
        switch state {
        case .sending:
            markSlot { Image(systemName: "envelope.fill").foregroundColor(.blue) }
        case .answered:
            markSlot { Text("😊") }
        case .failed:
            markSlot { Image(systemName: "xmark.circle.fill").foregroundColor(.red) }
        }
    }

    /// İşaretler aynı genişlikte durur, soru metinleri hizalı kalır
    private func markSlot<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.subheadline)
            .frame(width: 24)
            .accessibilityHidden(true)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if session.phase.isAtRest {
                Button("Başlat") { session.start() }
                    .buttonStyle(.borderedProminent)
                Button("Cevapları Tekrarla") { session.startReplay() }
                    .buttonStyle(.bordered)
                    .disabled(!session.canReplay)
                Button(session.testingSound ? "Ses deneniyor…" : "Sesi dene") { session.testSound() }
                    .buttonStyle(.bordered)
                    .disabled(session.testingSound)
                if !session.soundTest.isEmpty {
                    Text(session.soundTest)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if session.phase == .replaying {
                Button("Tekrarı durdur") { session.stopReplay() }
                    .buttonStyle(.bordered)
            } else {
                if session.phase == .paused(.manual) {
                    Button("Devam et") { session.resumeByUser() }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                } else if session.canPauseByUser {
                    Button("Duraklat") { session.pauseByUser() }
                        .buttonStyle(.bordered)
                }
                Button {
                    ScreenLock.shared.lock()
                } label: {
                    Label("Ekranı kilitle", systemImage: "lock.fill")
                }
                .buttonStyle(.bordered)
                Button("Testi Bitir") { confirmEnd = true }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var inputPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Mikrofon: yaka mikrofonunu (Lightning) seçin")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Yenile") { session.refreshInputs() }
                    .font(.footnote)
                    .buttonStyle(.borderless)
            }
            if session.inputs.isEmpty {
                Text("Harici mikrofon görünmüyor. Alıcı takılı mı, mikrofon açık mı?")
                    .font(.footnote)
                    .foregroundColor(.orange)
            }
            ForEach(session.inputs) { input in
                Button {
                    session.chooseInput(input.uid)
                } label: {
                    HStack {
                        Image(systemName: input.isCurrent ? "checkmark.circle.fill" : "circle")
                        Text(input.name)
                        Spacer()
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var outputPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Ses çıkışı: Bluetooth kulaklığı seçin")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Spacer()
                RoutePickerView().frame(width: 44, height: 44)
            }
            if !session.routeText.isEmpty {
                Text("Şu an: " + session.routeText)
                    .font(.footnote)
                    .foregroundColor(session.routeVerdict?.isSafe == false ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if session.routeVerdict?.headphonesOK == false {
                // Kulaklık düştüyse elle bağlamanın en kısa yolu: Ayarlar > Bluetooth > Aygıtlarım'da kulaklığa bir kez dokunmak
                Button("Bluetooth ayarlarını aç (kulaklığa bir kez dokunun)") { SystemSettings.openBluetooth() }
                    .font(.footnote)
                    .buttonStyle(.bordered)
            }
        }
    }
}
