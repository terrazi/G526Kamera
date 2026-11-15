import SwiftUI
import UIKit

/// Yuvarlak kapatma düğmesi: ana ekrandaki normal "Programı kapat" düğmesine dokununca çıkan örtüde durur ve kilit penceresindeki
/// "Kilidi aç" düğmesi gibi büyük ve yuvarlaktır. Yanlışlıkla kapanmasın diye `seconds` saniye basılı tutmak gerekir (halka dolar),
/// yarıda bırakılırsa sıfırlanır.
/// Basılı tutma tamamlanınca `onClose` çağrılır: oturum biter, program "kullanıcı kapattı" diye işaretlenir ve çıkar. Bunun dışındaki
/// her kapanış (iOS, çökme, elle kaydırarak kapatma) beklenmedik sayılır ve Kestirmeler otomasyonuyla yeniden açılıp kaldığı yerden sürer.
struct HoldToCloseButton: View {
    /// Düğmenin çapı (kilit penceresindeki "Kilidi aç" düğmesiyle aynı)
    static let diameter: CGFloat = 104

    let seconds: TimeInterval
    let onClose: () -> Void
    @GestureState private var pressing = false

    var body: some View {
        VStack(spacing: 6) {
            button
            Text(pressing ? "Kapanıyor…" : "Programı kapat")
                .font(.callout.weight(.semibold))
                .foregroundColor(.red)
                .accessibilityHidden(true)
            Text("\(Int(seconds)) saniye basılı tutun")
                .font(.footnote)
                .foregroundColor(.secondary)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
    }

    private var button: some View {
        ZStack {
            Circle().fill(Color.red.opacity(0.12))
            Circle().stroke(Color.red.opacity(0.35), lineWidth: 8)
            Circle()
                .trim(from: 0, to: pressing ? 1 : 0)
                .stroke(Color.red, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(pressing ? .linear(duration: seconds) : .easeOut(duration: 0.15), value: pressing)
            Image(systemName: "power")
                .font(.system(size: 34, weight: .semibold))
                .foregroundColor(.red)
        }
        .frame(width: HoldToCloseButton.diameter, height: HoldToCloseButton.diameter)
        .contentShape(Circle())
        .gesture(
            LongPressGesture(minimumDuration: seconds, maximumDistance: 90)
                .updating($pressing) { value, state, _ in state = value }
                .onEnded { _ in
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    onClose()
                }
        )
        .accessibilityLabel("Programı kapat")
        .accessibilityHint("\(Int(seconds)) saniye basılı tutun")
        .accessibilityIdentifier("programiKapatBasili")
    }
}

/// "Programı kapat" düğmesine dokununca çıkan örtü: yarı saydam arka plan ve ortada bir kart (açıklama, yuvarlak basılı tutma düğmesi, Vazgeç).
/// Dışına dokunmak ya da Vazgeç `onCancel`'ı çağırır; program yalnız yuvarlak düğmeye `seconds` saniye basılı tutulunca (`onClose`) kapanır.
struct CloseHoldOverlay: View {
    let seconds: TimeInterval
    let onClose: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onCancel() }
            VStack(spacing: 18) {
                Text("Kapatmak için yuvarlak düğmeye basılı tutun.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                HoldToCloseButton(seconds: seconds, onClose: onClose)
                Button("Vazgeç") { onCancel() }
                    .buttonStyle(.bordered)
            }
            .padding(24)
            .frame(maxWidth: 360)
            .background(Color(.systemBackground))
            .cornerRadius(20)
            .padding(24)
        }
    }
}
