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
                    VoiceRow(status: model.speechStatus, heard: model.heardText, enabled: settings.voiceEnabled)
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
            VideoLayerView(renderer: model.renderer)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .background(Color.black)
                .cornerRadius(12)
            HStack(spacing: 6) {
                Circle()
                    .fill(model.cameraState.isLive ? Color.green : Color.orange)
                    .frame(width: 9, height: 9)
                Text(model.cameraState.text)
                    .font(.caption)
                    .lineLimit(2)
                if model.cameraState.isLive && !model.resolutionText.isEmpty {
                    Text(model.resolutionText).font(.caption2).foregroundColor(.secondary)
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
            .background(model.cameraState.isLive ? Color.accentColor : Color.gray)
            .foregroundColor(.white)
            .cornerRadius(12)
        }
        .disabled(model.capturing || !model.cameraState.isLive)
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
}
