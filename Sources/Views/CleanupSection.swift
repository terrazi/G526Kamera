import SwiftUI

/// Ayarlar > Eski kayıtları sil: seçeneği işaretleyince hangi kayıtların silineceği sorulur (son 1 saat, 6 saat, 24 saat ya da tümü);
/// seçilen süredeki sınav kayıtları (cevap sesleri ve cevaplar.txt) ile telefondaki çekimler silinir. Test sürerken kapalıdır.
struct CleanupSection: View {
    @EnvironmentObject private var session: SessionViewModel
    @State private var armed = false
    @State private var choosing = false
    @State private var message = ""
    @State private var counts: [CleanupWindow: CleanupCounts] = [:]

    var body: some View {
        AccordionSection(id: "temizlik", title: "Eski kayıtları sil") {
            Toggle("Eski kayıtları ve dosyaları sil", isOn: $armed)
                .disabled(!session.phase.isAtRest)
                .onChange(of: armed) { isOn in
                    guard isOn else { return }
                    message = ""
                    counts = Dictionary(uniqueKeysWithValues: CleanupWindow.allCases.map { ($0, session.cleanupCounts($0)) })
                    choosing = true
                }
                .onChange(of: choosing) { isOpen in
                    if !isOpen { armed = false }   // seçim yapılsa da vazgeçilse de seçenek kendiliğinden kapanır
                }
                .confirmationDialog("Hangi kayıtlar silinsin?", isPresented: $choosing, titleVisibility: .visible) {
                    ForEach(CleanupWindow.allCases, id: \.self) { window in
                        Button("\(window.title): \(counts[window]?.text ?? "")", role: .destructive) { run(window) }
                    }
                    Button("Vazgeç", role: .cancel) {}
                } message: {
                    Text("Seçilen süre içinde başlayan sınav kayıtları ve çekilen sorular telefondan silinir. Gönderilmeyi bekleyen çekimler de silinir. Bu geri alınamaz.")
                }
            if !session.phase.isAtRest {
                Text("Test sürerken silinemez.").font(.footnote).foregroundColor(.secondary)
            }
            if !message.isEmpty {
                Text(message).font(.footnote)
            }
            HelpRow("Seçeneği işaretleyince dört seçenek sorulur: son 1 saat, son 6 saat, son 24 saat ya da tüm kayıtlar. Silinenler: o süre içinde başlamış sınav kayıtları (kayıt klasöründeki cevap sesleri ve cevaplar.txt) ile Cekimler klasöründeki çekimler (bekleyen, gönderilen, gönderilemeyen, paragraf). Kayıt klasöründeki başka dosyalara dokunulmaz. Süre, kaydın BAŞLADIĞI andan sayılır. Gönderilmeyi bekleyen çekimlerin cevabı silinince artık alınamaz. Test sürerken silinemez.")
        }
    }

    private func run(_ window: CleanupWindow) {
        if let result = session.deleteRecords(window) {
            message = "\(window.title): \(result.doneText)"
        } else {
            message = "Test sürerken silinemez."
        }
    }
}
