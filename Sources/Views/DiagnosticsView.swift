import SwiftUI
import UIKit

/// Ayarlar > Tanı ve günlük: cihaz özeti ve uygulama günlüğü. Telefonda bir sorun olursa nedeni Mac olmadan buradan okunur,
/// "Günlüğü kopyala" ile bana yapıştırılabilir. (İlk sürümdeki Tanı ekranından alındı.)
struct DiagnosticsView: View {
    @ObservedObject private var log = AppLog.shared
    @State private var info = "Cihaz bilgisi okunuyor…"
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(info)
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button(copied ? "Kopyalandı" : "Günlüğü kopyala") {
                    UIPasteboard.general.string = info + "\n\n" + log.lines.joined(separator: "\n")
                    copied = true
                }
                Spacer()
                Button("Temizle", role: .destructive) {
                    log.clear()
                    copied = false
                }
            }
            if log.lines.isEmpty {
                Text("Günlük boş. Test başlayınca olaylar (ses yolu, uyarılar, sorular, onarım adımları) burada birikir.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
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
        .navigationTitle("Tanı ve günlük")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { info = DeviceInfo.current() }
    }
}
