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

    private var diagnostics: [String] = []
    private var nonBlank = 0

    /// Görüntü tek renk mi (çizim boş kaldıysa)? 24×48'e küçültülüp en açık ve en koyu nokta karşılaştırılır
    private func isBlank(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return true }
        let w = 24, h = 48
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return true }
        var low = Int.max, high = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let v = Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])
            low = min(low, v); high = max(high, v)
        }
        return high - low < 12
    }

    /// Görünümü ekran dışı bir pencerede kurar ve PNG olarak yazar (`height` uzun listeler için büyütülür).
    /// Üç yöntem sırayla denenir (ilk boş olmayan seçilir): pencerenin drawHierarchy'si, katmanın render'ı, ImageRenderer (iOS 16+).
    private func render<V: View>(_ view: V, _ name: String, height: CGFloat = 812) async {
        let size = CGSize(width: 375, height: height)
        let bounds = CGRect(origin: .zero, size: size)
        let host = UIHostingController(rootView: view)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: bounds)
        window.frame = bounds
        window.windowLevel = .alert + 1
        window.backgroundColor = .systemBackground
        window.rootViewController = host
        window.isHidden = false
        window.makeKeyAndVisible()
        host.view.frame = bounds
        for _ in 0..<4 {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = height > 1500 ? 2 : 3
        format.opaque = true
        var ok: Bool?
        let viaWindow = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            ok = window.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        var chosen = viaWindow
        var method = "pencere"
        var blankWindow = isBlank(viaWindow)
        var blankLayer: Bool?
        var blankKit: Bool?
        if blankWindow {
            let viaLayer = UIGraphicsImageRenderer(bounds: bounds, format: format).image { ctx in
                UIColor.systemBackground.setFill()
                ctx.fill(bounds)
                host.view.layer.render(in: ctx.cgContext)
            }
            blankLayer = isBlank(viaLayer)
            if blankLayer == false { chosen = viaLayer; method = "katman"; blankWindow = false }
        }
        if blankWindow, #available(iOS 16.0, *) {
            let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height).background(Color(UIColor.systemBackground)))
            renderer.scale = format.scale
            if let image = renderer.uiImage {
                blankKit = isBlank(image)
                if blankKit == false { chosen = image; method = "ImageRenderer"; blankWindow = false }
            }
        }
        let stillBlank = blankWindow
        if !stillBlank { nonBlank += 1 }
        let method2: String = stillBlank ? "HİÇBİRİ (boş)" : method
        let pixelSize = "\(Int(chosen.size.width * chosen.scale))x\(Int(chosen.size.height * chosen.scale))"
        var parts: [String] = []
        parts.append("\(name): yöntem=\(method2)")
        parts.append("drawHierarchy=\(String(describing: ok))")
        parts.append("sahne=\(scene != nil)")
        parts.append("anahtar=\(window.isKeyWindow)")
        parts.append("gizli=\(window.isHidden)")
        parts.append("altGörünüm=\(host.view.subviews.count)")
        parts.append("katmanBoş=\(String(describing: blankLayer))")
        parts.append("imageRendererBoş=\(String(describing: blankKit))")
        parts.append("boyut=\(pixelSize)")
        let line = parts.joined(separator: " ")
        diagnostics.append(line)
        print("[ekran] " + line)
        if let data = chosen.pngData() {
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
        try? diagnostics.joined(separator: "\n").write(to: dir.appendingPathComponent("tani.txt"), atomically: true, encoding: .utf8)
        XCTAssertGreaterThanOrEqual(written.filter { $0.hasSuffix(".png") }.count, 6, "Ekran görüntüleri yazılmadı: \(written)")
        XCTAssertGreaterThanOrEqual(nonBlank, 6, "Ekran görüntüleri boş çıktı: \(diagnostics)")
    }
}
