import SwiftUI
import UIKit

/// "Programı kapat" düğmesi: kilit penceresindeki "Kilidi aç" düğmesi gibi büyük ve yuvarlaktır. Yanlışlıkla dokunulmasın diye `seconds` saniye
/// basılı tutmak gerekir (halka dolar), yarıda bırakılırsa sıfırlanır.
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
        .accessibilityIdentifier("programiKapat")
    }
}
