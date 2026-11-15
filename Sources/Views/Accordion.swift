import SwiftUI

/// Ayarlar'daki bölümlerin hangisinin açık olduğu. Akordiyon gibi çalışır: bir bölüm açılınca öncekiler kapanır, açılışta hepsi kapalıdır.
final class AccordionState: ObservableObject {
    @Published var open: String?

    init(open: String? = nil) {
        self.open = open
    }

    func toggle(_ id: String) {
        open = (open == id) ? nil : id
    }
}

/// Başlığa dokununca içeriği açılan ayar bölümü. Başlık VoiceOver'a "açık / kapalı" diye okunur.
struct AccordionSection<Content: View>: View {
    @EnvironmentObject private var accordion: AccordionState
    let id: String
    let title: String
    private let content: Content

    init(id: String, title: String, @ViewBuilder content: () -> Content) {
        self.id = id
        self.title = title
        self.content = content()
    }

    private var isOpen: Bool { return accordion.open == id }

    var body: some View {
        Section {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { accordion.toggle(id) }
            } label: {
                HStack {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(isOpen ? "açık" : "kapalı")
            .accessibilityHint(isOpen ? "Kapatmak için dokunun" : "Açmak için dokunun")
            if isOpen { content }
        }
    }
}
