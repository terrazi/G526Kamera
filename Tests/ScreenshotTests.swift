import XCTest
import SwiftUI
import UIKit
@testable import G526CameraDrive

/// CI'da (iOS simülatörü) uygulamanın ekranlarını gerçekten çizip PNG olarak yazar; kullanıcı ekranları görsün diye sürüme eklenir.
/// `SCREENSHOT_DIR` ortam değişkeni yoksa (normal test koşusu) atlanır. Görüntüler iPhone 12 mini boyutundadır (375×812 pt).
@MainActor
final class ScreenshotTests: XCTestCase {
    private var dir = URL(fileURLWithPath: NSTemporaryDirectory())

    private struct Rig {
        let h: SessionHarness
        let model: SettingsViewModel
        let controller: CameraCaptureController
        let tester: CameraTester
    }

    private func rig(cameraFlow: Bool = false) -> Rig {
        let h = SessionHarness(cameraFlow: cameraFlow)
        let model = SettingsViewModel(settings: h.settings, shortcuts: h.shortcuts)
        let controller = CameraCaptureController(settings: h.cameraSettings)
        let tester = CameraTester(camera: FakeCamera(), shortcuts: FakeShortcuts(), health: FakeHealth(), settings: h.settings,
                                  cameraSettings: h.cameraSettings, sessionActive: { false }, sleep: { _ in })
        return Rig(h: h, model: model, controller: controller, tester: tester)
    }

    private func withEnvironment<V: View>(_ view: V, _ r: Rig) -> some View {
        return view
            .environmentObject(r.h.vm)
            .environmentObject(r.h.settings)
            .environmentObject(r.h.cameraSettings)
            .environmentObject(r.controller)
            .environmentObject(r.tester)
            .environmentObject(r.model)
    }

    /// Görünümü ekran dışı bir pencerede kurar ve PNG olarak yazar (`height` uzun listeler için büyütülür)
    private func render<V: View>(_ view: V, _ name: String, height: CGFloat = 812) async {
        let size = CGSize(width: 375, height: height)
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.backgroundColor = .systemBackground
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        for _ in 0..<4 {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = height > 1500 ? 2 : 3
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        if let data = image.pngData() {
            try? data.write(to: dir.appendingPathComponent("\(name).png"))
        }
        window.isHidden = true
    }

    func testRenderScreens() async throws {
        guard let path = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("SCREENSHOT_DIR yok: ekran görüntüleri yalnız CI'da alınır")
        }
        dir = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 1) Açılış: test başlamadan önceki ana ekran
        let idle = rig()
        await render(withEnvironment(ContentView(), idle), "01-ana-ekran-hazir")

        // 2) Sürüm 3 gibi: dinliyor (kamera sorusu kapalı)
        let listening = rig()
        _ = await listening.h.startListening()
        await render(withEnvironment(ContentView(), listening), "02-ana-ekran-dinliyor")

        // 3) Sürüm 4: "Bu soruyu kamera ile çekip göndermek ister misiniz?" beklenirken
        let camera = rig(cameraFlow: true)
        _ = await camera.h.startListening()
        await render(withEnvironment(ContentView(), camera), "03-ana-ekran-kamera-sorusu")

        // 4) Bir soru sorulmuş ve cevaplanmış
        let asked = rig()
        asked.h.answering.results = [.success(FakeAnswering.reply(1))]
        _ = await asked.h.startListening()
        asked.h.ask("Soru 1. Türkiye'nin başkenti neresidir? A seçeneği Ankara, B seçeneği İstanbul")
        _ = await waitUntil(45) { asked.h.vm.answers.count == 1 }
        await render(withEnvironment(ContentView(), asked), "04-ana-ekran-soru-cevaplandi")

        // 5) Kırmızı uyarılar: ses çok kısık ve pil düşük
        let warned = rig()
        warned.h.system.current.outputVolume = 0.05
        _ = await warned.h.startListening()
        warned.h.vm.warn("gorsel", "Pil yüzde 18: şarja takın.")
        await render(withEnvironment(ContentView(), warned), "05-ana-ekran-uyarilar")

        // 6) Ayarlar (gerçek varsayılanlarla; uzun liste tek görüntüde)
        let defaults = UserDefaults(suiteName: "g526.ekran.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        let cameraSettings = CameraSettings(defaults: defaults)
        let settingsRig = Rig(h: idle.h,
                              model: SettingsViewModel(settings: settings, shortcuts: FakeShortcuts()),
                              controller: CameraCaptureController(settings: cameraSettings),
                              tester: CameraTester(camera: FakeCamera(), shortcuts: FakeShortcuts(), health: FakeHealth(), settings: settings,
                                                   cameraSettings: cameraSettings, sessionActive: { false }, sleep: { _ in }))
        let settingsView = SettingsView()
            .environmentObject(idle.h.vm)
            .environmentObject(settings)
            .environmentObject(cameraSettings)
            .environmentObject(settingsRig.controller)
            .environmentObject(settingsRig.tester)
            .environmentObject(settingsRig.model)
        await render(settingsView, "06-ayarlar-ust", height: 812)
        await render(settingsView, "07-ayarlar-tamami", height: 6000)

        let written = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertGreaterThanOrEqual(written.filter { $0.hasSuffix(".png") }.count, 6, "Ekran görüntüleri yazılmadı: \(written)")
    }
}
