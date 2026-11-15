import SwiftUI

/// Ayarlar > Çekim klasörü: çekimlerin telefondaki kalıcı klasörünün durumu ve (yalnız kullanıcı isteğiyle) silme düğmeleri
struct CaptureFolderSection: View {
    @EnvironmentObject private var session: SessionViewModel
    @State private var summary = CaptureFolderSummary()
    @State private var message = ""
    @State private var confirmSent = false
    @State private var confirmAll = false

    var body: some View {
        AccordionSection(id: "cekimler", title: "Çekim klasörü") {
            HStack {
                Text("Durum")
                Spacer()
                Text(summary.text)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            Text("Çekilen sorular telefonda saklanır; kendiliğinden silinmez. Dosyalar uygulamasında Bu iPhone'da > Sesli Kontrol > Cekimler klasöründe görünür.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Gönderilenleri sil") { confirmSent = true }
                .disabled(!session.phase.isAtRest || summary.deletableSent == 0)
                .alert("Gönderilen çekimler silinsin mi?", isPresented: $confirmSent) {
                    Button("Sil", role: .destructive) {
                        let count = session.deleteSentCaptures()
                        message = "\(count) çekim silindi."
                        refresh()
                    }
                    Button("Vazgeç", role: .cancel) {}
                } message: {
                    Text("Gemini'ye gönderilmiş çekimler ve paragraf çekimleri telefondan silinir. Bekleyenlere dokunulmaz.")
                }
            Button("Tümünü sil (bekleyenler dahil)", role: .destructive) { confirmAll = true }
                .disabled(!session.phase.isAtRest || summary.total == 0)
                .alert("Bütün çekimler silinsin mi?", isPresented: $confirmAll) {
                    Button("Hepsini sil", role: .destructive) {
                        let count = session.deleteAllCaptures()
                        message = "\(count) çekim silindi."
                        refresh()
                    }
                    Button("Vazgeç", role: .cancel) {}
                } message: {
                    Text("Gönderilmeyi bekleyen çekimler de silinir; onların cevabı artık alınamaz. Bu geri alınamaz.")
                }
            if !message.isEmpty {
                Text(message).font(.footnote)
            }
            HelpRow("İnternet olmadığında çekilen her soru (fotoğraf + video) önce buraya yazılır: Bekleyen klasörü. İnternet gelince en eskisinden başlayarak sırayla Gemini'ye gönderilir; cevabı gelince Gönderilen klasörüne taşınır (cevap.txt ile). Gemini'nin kabul etmediği çekimler Gonderilemeyen klasörüne alınır (neden.txt ile). Ortak paragraf çekimleri Paragraf klasöründedir. Uygulama kapansa ya da test bitse de bekleyen çekimler kaybolmaz; bir sonraki testte sırayla gönderilir. “Gönderilenleri sil” gönderilmiş çekimlerle paragraf çekimlerini siler; “Tümünü sil” bekleyenleri de siler (cevapları artık alınamaz). Test sürerken silinemez.")
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        summary = session.captureFolderSummary()
    }
}
