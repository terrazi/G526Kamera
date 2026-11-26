import SwiftUI

/// Ana ekran: durum, kırmızı uyarı kutusu, donanım kontrolü, yüklenen sorular (gidiş işaretiyle), düğmeler ve ses girişi / çıkışı
struct ContentView: View {
    @EnvironmentObject private var session: SessionViewModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var settingsModel: SettingsViewModel
    @EnvironmentObject private var camera: CameraSettings
    @EnvironmentObject private var cameraController: CameraCaptureController
    @EnvironmentObject private var tester: CameraTester
    @State private var showSettings = false
    @State private var confirmEnd = false
    /// "Programı kapat" düğmesine dokununca açılan yuvarlak, basılı tutmalı kapatma düğmesi görünüyor mu
    @State private var showCloseHold = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    statusCard
                    cameraCard
                    lastShotCard
                    if !session.warnings.isEmpty { warningBox }
                    if !session.checkup.isEmpty { checkupList }
                    if !session.questions.isEmpty || liveBoxVisible || passageNote != nil { questionList }
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
            .confirmationDialog("Test bitirilsin mi?", isPresented: $confirmEnd, titleVisibility: .visible) {
                Button("Testi Bitir", role: .destructive) { session.endTest() }
                Button("Vazgeç", role: .cancel) {}
            } message: {
                Text("Dinleme durur. Kaydedilen cevaplar kalır, “Cevapları Tekrarla” ile dinlenir.")
            }
            .onChange(of: camera.lastShotOff) { off in
                if off { session.clearLastShot() }
            }
            .onChange(of: session.phase.isAtRest) { rest in
                // Test bitince ya da hiç başlamadıysa ekran kilidi kalmasın
                if rest { ScreenLock.shared.unlock() }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(session)
                    .environmentObject(settings)
                    .environmentObject(camera)
                    .environmentObject(settingsModel)
            }
        }
        .navigationViewStyle(.stack)
        .overlay { closeOverlay }
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

    /// Kamera kutusu ana ekranda hep durur (görüntü yokken siyahtır). Üstünde kamera durumu, altında bildirim bandı;
    /// önizleme ve ekran kısma buradan açılıp kapatılır; "Şimdi çek" yalnız çekim sürerken çalışır.
    private var cameraCard: some View {
        // Kutu, kartın içindeki genişliğe oranla (yatay 16:9, dikey 9:16) oturur; sabit ekran genişliğinden hesaplanırsa kart + kenar boşluğu taşırdı
        let portrait = camera.guidanceFrame == 1
        let ratio: CGFloat = portrait ? 9.0 / 16.0 : 16.0 / 9.0
        let maxWidth: CGFloat = portrait ? UIScreen.main.bounds.height * 0.6 * ratio : .infinity
        let previewOn = Binding<Bool>(get: { !camera.previewOff }, set: { camera.previewOff = !$0 })
        return VStack(alignment: .leading, spacing: 8) {
            if camera.previewOff {
                cameraStateLine
                Text("Önizleme kapalı (pil tasarrufu)").font(.caption).foregroundColor(.secondary)
            } else {
                // Yazılar görüntünün ÜSTÜNE değil, üstüne ve altına konur: kamera önizlemesi hiçbir yerinden kapanmasın
                cameraStateLine
                VideoLayerView(renderer: cameraController.renderer, orientation: camera.imageOrientation)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .cornerRadius(12)
                    .aspectRatio(ratio, contentMode: .fit)
                    .frame(maxWidth: maxWidth, alignment: .leading)
                cameraStatusLine
            }
            Toggle("Canlı önizleme", isOn: previewOn).font(.subheadline)
            Toggle("Ekranı kıs", isOn: $settings.dimScreen).font(.subheadline)
            Button("Şimdi çek") { cameraController.captureNow() }
                .buttonStyle(.bordered)
                .disabled(!cameraController.active)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    /// Çekim sürerken kameranın söylediği/yazdığı kısa durum ("Soruyu kadraja alın"…): görüntünün altında durur. Yazı çıkıp kaybolurken
    /// kart oynamasın diye yeri hep ayrılıdır.
    private var cameraStatusLine: some View {
        let text = cameraController.active ? cameraController.statusText : ""
        return Text(text.isEmpty ? " " : text)
            .font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .foregroundColor(text.isEmpty ? .clear : .white)
            .frame(maxWidth: .infinity, minHeight: 36)
            .padding(.horizontal, 10)
            .background(text.isEmpty ? Color.clear : Color.black.opacity(0.75))
            .cornerRadius(10)
    }

    /// Kamera durum noktası (canlıysa yeşil) ve yazısı; kamera pili okunduysa yanında
    private var cameraStateLine: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(cameraController.cameraState.isLive ? Color.green : Color.orange)
                .frame(width: 9, height: 9)
            Text("Kamera: " + cameraController.cameraState.text)
                .font(.caption)
                .lineLimit(2)
            if let battery = cameraController.cameraBattery {
                Text(battery.shortText).font(.caption2)
            }
        }
    }

    /// "Son fotoğraf": kameranın en son çektiği sayfa (küçük resim) ve bilgisi
    @ViewBuilder
    private var lastShotCard: some View {
        if !camera.lastShotOff, let image = session.lastShot {
            VStack(alignment: .leading, spacing: 6) {
                Text("Son fotoğraf").font(.footnote).foregroundColor(.secondary)
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 220)
                    .cornerRadius(10)
                Text(session.lastShotInfo).font(.caption).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
        }
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

    /// Okunmakta olan soru ya da paragraf kutusu görünsün mü (dinleme sürerken; soru kipinde yalnız bir şey okunmaya başlandıysa)
    private var liveBoxVisible: Bool {
        guard session.phase == .listening else { return false }
        return !session.liveText.isEmpty || session.listenMode != .question
    }

    /// Mikrofon şu an ne bekliyor
    private var modeNote: String {
        switch session.listenMode {
        case .question: return "Tarama bekleniyor: sesli komut verebilirsiniz (“durum”, “cevapları tekrarla”, “testi bitir”)"
        case .passage: return "Ortak paragraf okunuyor: bitirince “Tamam” deyin"
        case .passageTargets: return "Paragraf alındı: hangi sorulara ait olduğunu söyleyip “Tamam” deyin"
        case .missingNumber:
            if session.numberEdit != nil { return "Numarayı söyleyin (ör. “yedi”); vazgeçmek için “soruyu iptal et” deyin" }
            return "Soru numarası bekleniyor: numarayı söyleyin (ör. “yedi”)"
        case .confirmEnd:
            if session.pendingRenumber != nil { return "Numarayı değiştirmek için “evet”, vazgeçmek için “hayır” deyin" }
            return session.pendingDelete != nil ? "Kaydı silmek için “evet”, vazgeçmek için “hayır” deyin" : "Testi bitirmek için “evet”, devam etmek için “hayır” deyin"
        case .cameraChoice:
            if session.cameraSettings.pageSeries {
                return session.cameraSettings.autoStart ? "Otomatik tarama: saat ya da soru bekleniyor (hemen başlatmak için “başla” deyin)"
                    : "Kamera hazır: süreyi başlatmak için “başla” deyin"
            }
            return "Kamera ile çekmek için “evet”, sesle okumak için “hayır” deyin (ortak paragraf için “ortak paragraf” deyin)"
        case .passageCameraChoice: return "Ortak paragrafı kamera ile çekmek için “evet”, sesle okumak için “hayır” deyin"
        case .captureKindChoice: return "Soru çekmek için “bir” ya da “soru”, ortak paragraf için “iki” ya da “paragraf” deyin"
        case .nextSectionChoice: return "Yeni bölüm için “evet”, testi tamamlamak için “hayır” deyin"
        case .startChoice: return "Önceki kayıttan devam için “devam”, yeni sınav için “yeni” deyin"
        case .reviewMenu: return "Cevaplar okundu: teste “Devam”, yeniden dinlemek için “Tekrar”, testi tamamlamak için “Bitir” deyin"
        }
    }

    private var passageNote: String? {
        guard let context = session.passage else { return nil }
        return "Ortak paragraf kayıtlı\(context.viaCamera ? " (kamera görüntüsü)" : ""): \(QuestionComposer.listText(context.remaining)) numaralı sorular için"
    }

    /// Tek liste: yüklenen sorular, her birinin yanında Gemini'ye gidiş işareti. Yeni soru en üstte; durum canlı güncellenir.
    private var questionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Yüklenen sorular (\(session.questions.count))").font(.headline)
            if let note = passageNote {
                questionBox {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        markSlot { Image(systemName: "doc.text.fill").foregroundColor(.blue) }
                        Text(note)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if liveBoxVisible {
                questionBox {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            markSlot { Image(systemName: "clock.fill").foregroundColor(.orange) }
                            Text(session.liveText.isEmpty ? "…" : session.liveText)
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
                        Text(modeNote)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
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

    /// Dokunmatik ekran kilidi: test başlamadan da, test sürerken de aynı düğme. Hazır durumdayken kilitlenen ekran test başlayınca da kilitli
    /// kalır; test bitince (hazır durumuna dönülünce) kilit kendiliğinden kalkar. Elle açmak için kilit penceresindeki yuvarlak düğmeye 3 sn basılır.
    private var lockButton: some View {
        Button {
            ScreenLock.shared.lock()
        } label: {
            Label("Ekranı kilitle", systemImage: "lock.fill")
        }
        .buttonStyle(.borderedProminent)
        .tint(.blue)
    }

    /// "Programı kapat": normal (kırmızı) düğme. Dokununca ekranda büyük yuvarlak düğme çıkar; program ancak o düğmeye
    /// `SessionViewModel.Timing.closeHold` saniye basılı tutulunca kapanır (kilit penceresindeki "Kilidi aç" düğmesi gibi).
    private var closeButton: some View {
        Button {
            showCloseHold = true
        } label: {
            Label("Programı kapat", systemImage: "power")
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .padding(.top, 6)
        .accessibilityIdentifier("programiKapat")
    }

    /// Yuvarlak kapatma düğmesinin çıktığı örtü; dışına dokunmak ya da Vazgeç örtüyü kaldırır, program kapanmaz
    @ViewBuilder
    private var closeOverlay: some View {
        if showCloseHold {
            CloseHoldOverlay(seconds: SessionViewModel.Timing.closeHold,
                             onClose: {
                                 showCloseHold = false
                                 session.closeByUser()
                             },
                             onCancel: { showCloseHold = false })
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if session.phase.isAtRest {
                Button("Başlat") { session.start() }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(tester.running)   // deneme çekimi sürerken telefon kameranın ağındadır
                // "Başlat" kapanan sınava kaldığı yerden devam eder; önceki kaydı kapatıp baştan başlamak için bu düğme kullanılır
                Button("Yeni sınav başlat") { session.startNewExam() }
                    .buttonStyle(.bordered)
                    .disabled(tester.running)
                trialButton
                Button("Cevapları Tekrarla") { session.startReplay() }
                    .buttonStyle(.bordered)
                    .disabled(!session.canReplay)
                Button(session.testingSound ? "Ses deneniyor…" : "Sesi dene") { session.testSound() }
                    .buttonStyle(.bordered)
                    .disabled(session.testingSound)
                lockButton
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
                        .buttonStyle(.borderedProminent)
                        .tint(Color(UIColor.brown))
                }
                lockButton
                Button("Testi Bitir") { confirmEnd = true }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            }
            closeButton
        }
        .frame(maxWidth: .infinity)
    }

    /// Deneme çekimi (kullanıcı kararı 2026-11-17): kamera gerçek çekimdeki gibi bir oturum süresi çeker, video + PDF + rapor telefondaki Deneme klasörüne yazılır,
    /// Gemini'ye hiçbir şey gitmez. Kullanıcı videoya ve rapora bakıp kamerayı tutuş biçimini düzeltir.
    @ViewBuilder private var trialButton: some View {
        Button(tester.running && tester.showsTrial ? "Deneme çekiliyor…" : "Deneme çekimi (\(cameraSettingsSeconds) sn)") {
            Task { await tester.runTrial() }
        }
        .buttonStyle(.bordered)
        .disabled(tester.running)
        if tester.running && tester.showsTrial {
            Button(tester.stopping ? "Durduruluyor…" : "Denemeyi durdur") { tester.stop() }
                .buttonStyle(.bordered)
                .disabled(tester.stopping)
            if !tester.progress.isEmpty {
                Text(tester.progress).font(.footnote).foregroundColor(.secondary)
            }
        }
        if tester.showsTrial, !tester.lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(tester.lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.footnote)
                        .foregroundColor(line.hasPrefix("✗") ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var cameraSettingsSeconds: Int { return camera.seriesSeconds }

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
            if !session.liveStatus.isEmpty {
                Text(session.liveStatus)
                    .font(.footnote)
                    .foregroundColor(session.liveStatus.contains("✗") ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if session.routeVerdict?.headphonesOK == false {
                // Elle bağlanılamaz (sınavdaki kişi telefona dokunamaz): kulaklığı yalnız Kestirmeler kendiliğinden geri alabilir
                Text(settings.outputShortcut.trimmed.isEmpty
                     ? "Kulaklık düşünce kendiliğinden bağlanması için Ayarlar > Kestirmeler > “Çıkışı kulaklığa al” alanına kestirmenin adını yazın."
                     : "Kulaklık yolda değil; uygulama “\(settings.outputShortcut.trimmed)” kestirmesini kendisi çalıştırır.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
