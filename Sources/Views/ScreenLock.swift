import SwiftUI
import UIKit

/// Dokunmatik ekran kilidi (ekran kilidi gibi: program kilidi DEĞİL). Kilitliyken uygulamanın bütün ekranına dokunmak yok sayılır; tek
/// çıkış, kilit penceresindeki düğmeye `holdSeconds` saniye basılı tutmaktır. Program çalışmayı sürdürür: dinleme, cevaplar ve
/// kayıt aynen devam eder; yanlışlıkla ekrana dokunmak ("Testi Bitir" gibi) bir şey yaptırmaz. (İlk sürümden alındı.)
/// Sınır: iPhone'un yan tuşu, ses tuşları ve ekran kenarından kaydırma sistemin işidir, uygulama engelleyemez (kilit penceresi yalnız
/// ilk kenar kaydırmasını yutar: ana ekrana dönmek için iki kez kaydırmak gerekir). Tam kilit için iPhone'un "Kılavuzlu Erişim" özelliği.
@MainActor
final class ScreenLock {
    /// Ana ekrandaki düğme ve test bitince kilidi kaldıran kod aynı kilidi kullanır
    static let shared = ScreenLock()

    /// Kilit düğmesine kaç saniye basılı tutulunca kilit açılır
    static let holdSeconds: TimeInterval = 3

    /// Sesli bildirim ve günlük için: kilit değişince çağrılır (true = kilitlendi)
    var onChange: ((Bool) -> Void)?
    private(set) var isLocked = false
    private let presenter: LockPresenting

    init(presenter: LockPresenting? = nil) {
        self.presenter = presenter ?? LockWindow()
    }

    /// Ekranı kilitler. Kilit penceresi açılamazsa (sahne yok) false döner ve kilitli sayılmaz.
    @discardableResult
    func lock() -> Bool {
        guard !isLocked else { return true }
        guard presenter.present(onUnlock: { [weak self] in self?.unlock() }) else { return false }
        isLocked = true
        tlog("[kilit] ekran kilitlendi")
        onChange?(true)
        return true
    }

    /// Kilidi açar (kilit penceresindeki düğmeye 3 saniye basılınca çağrılır)
    func unlock() {
        guard isLocked else { return }
        isLocked = false
        presenter.dismiss()
        tlog("[kilit] ekran kilidi açıldı")
        onChange?(false)
    }
}

/// Kilit penceresini gösteren ve kaldıran katman (testlerde sahte bir sunucu verilir)
@MainActor
protocol LockPresenting: AnyObject {
    /// Kilit penceresini açar; açılamazsa false. `onUnlock`: kullanıcı düğmeye yeterince basılı tuttu.
    func present(onUnlock: @escaping () -> Void) -> Bool
    func dismiss()
}

/// Her şeyin (sayfalar, menüler, ayar ekranı dahil) üstünde duran, bütün dokunmaları yutan ayrı bir pencere
@MainActor
final class LockWindow: LockPresenting {
    private var window: UIWindow?
    private weak var previousKey: UIWindow?

    func present(onUnlock: @escaping () -> Void) -> Bool {
        guard window == nil else { return true }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return false }
        previousKey = scene.windows.first(where: { $0.isKeyWindow })
        let w = UIWindow(windowScene: scene)
        w.windowLevel = UIWindow.Level.alert + 1
        w.backgroundColor = .clear
        let host = LockHostingController(rootView: ScreenLockView(onUnlock: onUnlock))
        host.view.backgroundColor = .clear
        w.rootViewController = host
        w.makeKeyAndVisible()
        window = w
        return true
    }

    func dismiss() {
        guard let w = window else { return }
        window = nil
        let key = previousKey
        previousKey = nil
        // Kilit açma, pencerenin kendi dokunuş işleyicisinden çağrılır: pencere o işleyici bitince kaldırılır
        DispatchQueue.main.async {
            w.isHidden = true
            w.rootViewController = nil
            key?.makeKey()
        }
    }
}

/// Ana ekrana kaydırma ilk seferde yutulur, ana ekran çubuğu gizlenir
final class LockHostingController: UIHostingController<ScreenLockView> {
    override var prefersHomeIndicatorAutoHidden: Bool { return true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { return .all }
}

/// Kilit ekranı: yarı saydam bir örtü (altındaki ekran görünür ama dokunulamaz) ve tek bir kilit açma düğmesi.
/// Düğmeye `ScreenLock.holdSeconds` saniye basılı tutulunca halka dolar ve kilit açılır; bırakılırsa halka sıfırlanır.
struct ScreenLockView: View {
    let onUnlock: () -> Void
    @GestureState private var pressing = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { }
            VStack(spacing: 14) {
                Spacer()
                Image(systemName: "lock.fill").font(.system(size: 40))
                Text("Ekran kilitli").font(.title2.weight(.bold))
                Text("Test sürüyor, soruları okumaya devam edin. Ekrana dokunmak bir şey yaptırmaz.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                Spacer()
                unlockButton
                Text("Kilidi açmak için düğmeye \(Int(ScreenLock.holdSeconds)) saniye basılı tutun")
                    .font(.footnote.weight(.semibold))
                    .multilineTextAlignment(.center)
                Spacer().frame(height: 30)
            }
            .foregroundColor(.white)
            .padding(24)
        }
    }

    private var unlockButton: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.55))
            Circle().stroke(Color.white.opacity(0.35), lineWidth: 8)
            Circle()
                .trim(from: 0, to: pressing ? 1 : 0)
                .stroke(Color.green, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(pressing ? .linear(duration: ScreenLock.holdSeconds) : .easeOut(duration: 0.15), value: pressing)
            Image(systemName: pressing ? "lock.open.fill" : "lock.fill").font(.system(size: 30))
        }
        .frame(width: 104, height: 104)
        .contentShape(Circle())
        .gesture(
            LongPressGesture(minimumDuration: ScreenLock.holdSeconds, maximumDistance: 90)
                .updating($pressing) { value, state, _ in state = value }
                .onEnded { _ in
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onUnlock()
                }
        )
        .accessibilityLabel("Kilidi aç")
        .accessibilityHint("\(Int(ScreenLock.holdSeconds)) saniye basılı tutun")
        .accessibilityIdentifier("kilidiAc")
    }
}
