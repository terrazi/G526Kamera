import XCTest
@testable import G526CameraDrive

/// V1'den V4'e kamera taşımasının mantıksal denetimi: V1'deki HER dosya kayıtta tam bir durumla yer alır, hiçbiri unutulmamıştır.
final class PortManifestTests: XCTestCase {
    func testManifestCoversEveryV1SourceFileExactlyOnce() {
        let listed = PortManifest.entries.map { $0.v1 }
        XCTAssertEqual(Set(listed), Set(PortManifest.v1Files), "kayıt V1 dosya listesiyle örtüşmüyor")
        XCTAssertEqual(listed.count, Set(listed).count, "bir dosya iki kez kayıtlı")
        XCTAssertEqual(PortManifest.v1Files.count, 62, "V1 Sources dosya sayısı (taşıma anında)")
        XCTAssertEqual(PortManifest.v1Files, PortManifest.v1Files.sorted(), "liste sıralı tutulur")
    }

    func testEveryEntryExplainsItself() {
        for e in PortManifest.entries {
            switch e.status {
            case .copied:
                XCTAssertFalse(e.types.isEmpty, "\(e.v1): kopya ama türü yok")
            case .adapted, .v3Equivalent, .pending, .excluded:
                XCTAssertGreaterThan(e.note.count, 12, "\(e.v1): açıklama yok")
            }
            if e.status == .adapted { XCTAssertFalse(e.types.isEmpty, "\(e.v1): uyarlanan ama türü yok") }
        }
    }

    /// Taşınan türlere derleme zamanında başvurulur (`PortManifest.entries` içinde); burada adları da yoklanır
    func testPortedTypesExist() {
        let ported = PortManifest.entries.filter { $0.status == .copied || $0.status == .adapted }
        var count = 0
        for e in ported {
            for t in e.types {
                XCTAssertFalse(String(describing: t).isEmpty)
                count += 1
            }
        }
        XCTAssertGreaterThanOrEqual(count, 30, "taşınan tür sayısı beklenenden az")
        // kamera çekirdeğinin ana parçaları
        let names = Set(ported.flatMap { $0.types.map { String(describing: $0) } })
        for must in ["CameraClient", "CameraSession", "CameraUID", "PPPP", "H264Decoder", "FramePipeline", "CaptureEngine", "Enhancer",
                     "GuidanceEngine", "GuidanceVocabulary", "VideoRecorder", "FrameAnalysis", "DocumentGate", "PageEdgeTracker",
                     "ImageOrientation", "PreviewLayout", "CameraSettings", "SpeechMatcher", "SpeechIntent", "CameraBatteryMonitor"] {
            XCTAssertTrue(names.contains(must), "kamera çekirdeğinde eksik tür: \(must)")
        }
    }

    /// Yapılması kalan kamera işleri: bu liste sürüm bitince boşalmalıdır
    static let pendingFiles: Set<String> = ["AppModel.swift", "ContentView.swift", "ConnectionAnnouncer.swift", "GeminiVideo.swift", "Health.swift"]

    func testPendingEntriesAreExactlyTheKnownRemainingWork() {
        let pending = Set(PortManifest.entries.filter { $0.status == .pending }.map { $0.v1 })
        XCTAssertEqual(pending, Self.pendingFiles, "bekleyen iş listesi değişti: docs/SURUM4_TASIMA.md ile birlikte güncelleyin")
    }
}
