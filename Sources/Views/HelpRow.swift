import SwiftUI

/// Uzun açıklama satırı: başta yalnız "Açıklama" bağlantısı görünür; dokununca metin altına doğru açılır, yeniden dokununca kapanır.
struct HelpRow: View {
    let text: String
    @State private var open = false

    init(_ text: String) { self.text = text }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.up.circle" : "info.circle")
                    Text(open ? "Açıklamayı gizle" : "Açıklama")
                    Spacer()
                }
                .font(.footnote)
                .foregroundColor(.accentColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(open ? "açık" : "kapalı")
            if open {
                Text(text)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
