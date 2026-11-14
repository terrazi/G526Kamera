import SwiftUI
import UIKit

/// "Programı kapat" düğmesi: yanlışlıkla dokunulmasın diye `seconds` saniye basılı tutmak gerekir (halka dolar), yarıda bırakılırsa sıfırlanır.
/// Basılı tutma tamamlanınca `onClose` çağrılır: oturum biter, program "kullanıcı kapattı" diye işaretlenir ve çıkar. Bunun dışındaki
/// her kapanış (iOS, çökme, elle kaydırarak kapatma) beklenmedik sayılır ve Kestirmeler otomasyonuyla yeniden açılıp kaldığı yerden sürer.
struct HoldToCloseButton: View {
    let seconds: TimeInterval
    let onClose: () -> Void
    @GestureState private var pressing = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Color.red.opacity(0.12))
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.red.opacity(0.45))
                    .frame(width: pressing ? geometry.size.width : 0)
                    .animation(pressing ? .linear(duration: seconds) : .easeOut(duration: 0.15), value: pressing)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            RoundedRectangle(cornerRadius: 12).stroke(Color.red.opacity(0.6), lineWidth: 1)
            Label(pressing ? "Kapanıyor…" : "Programı kapat (\(Int(seconds)) sn basılı tut)", systemImage: "power")
                .font(.callout.weight(.semibold))
                .foregroundColor(.red)
        }
        .frame(height: 44)
        .contentShape(RoundedRectangle(cornerRadius: 12))
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
