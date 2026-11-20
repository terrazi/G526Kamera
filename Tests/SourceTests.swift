import XCTest
import UIKit
@testable import G526CameraDrive

/// Oturum sınama düzeneğinin gördüğü kaynak durumu (nil: "Soruları verilen kaynaklara göre cevapla" kapalı)
final class SourceReadinessBox {
    var value: SourceReadiness?
}

/// Boş liste (JSON'da `[]`): türü belli olsun diye adıyla kullanılır
private let noItems = [[String: Any]]()

private func sourceJSON(_ object: [String: Any]) -> Data {
    return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}

private func sourceReply(_ object: [String: Any], status: Int = 200, headers: [String: String] = [:]) -> FakeGeminiProtocol.Reply {
    return FakeGeminiProtocol.Reply(status: status, body: sourceJSON(object), error: nil, headers: headers)
}

private func sourceQueue(_ replies: [FakeGeminiProtocol.Reply]) {
    FakeGeminiProtocol.lock.lock()
    FakeGeminiProtocol.replies = replies
    FakeGeminiProtocol.lock.unlock()
}

private struct SourceTraffic {
    var urls: [String]
    var methods: [String]
    var headers: [[String: String]]
    var bodies: [Data]
}

private func sourceTraffic() -> SourceTraffic {
    FakeGeminiProtocol.lock.lock()
    defer { FakeGeminiProtocol.lock.unlock() }
    return SourceTraffic(urls: FakeGeminiProtocol.urls.map { $0.absoluteString }, methods: FakeGeminiProtocol.methods,
                         headers: FakeGeminiProtocol.headers, bodies: FakeGeminiProtocol.bodies)
}

private func sourceDocument(_ title: String, state: String = "STATE_ACTIVE", bytes: Int? = nil, id: String? = nil) -> [String: Any] {
    var item: [String: Any] = ["name": id ?? "fileSearchStores/depo/documents/\(title)", "displayName": title, "state": state]
    if let bytes = bytes { item["sizeBytes"] = String(bytes) }
    return item
}

// MARK: - Kurallar: klasör ile deponun farkı, klasör taraması, rapor

final class SourceRulesTests: XCTestCase {
    private func file(_ name: String, _ bytes: Int, pages: Int = 0) -> SourceFile {
        return SourceFile(name: name, bytes: bytes, pages: pages)
    }

    private func document(_ title: String, state: String = "STATE_ACTIVE", bytes: Int? = nil, id: String? = nil) -> SourceDocument {
        return SourceDocument(id: id ?? "fileSearchStores/depo/documents/\(title)", title: title, state: state, bytes: bytes)
    }

    func testNewFilesAreUploadedAndFilesGoneFromTheFolderAreRemovedFromTheStore() {
        let plan = SourceRules.plan(local: [file("A.pdf", 100), file("B.pdf", 200)],
                                    remote: [document("A.pdf"), document("Eski.pdf")],
                                    uploaded: ["A.pdf": 100, "Eski.pdf": 50])
        XCTAssertEqual(plan.upload.map { $0.name }, ["B.pdf"], "Depoda karşılığı olmayan dosya yüklenir")
        XCTAssertEqual(plan.remove.map { $0.title }, ["Eski.pdf"], "Klasörden silinen dosya depodan da silinir")
        XCTAssertEqual(plan.keep.map { $0.title }, ["A.pdf"], "Değişmeyen dosya yeniden gönderilmez")
        XCTAssertFalse(plan.isEmpty)
    }

    func testAnUnchangedFolderNeedsNoUploadAndNoRemoval() {
        let plan = SourceRules.plan(local: [file("A.pdf", 100)], remote: [document("A.pdf")], uploaded: ["A.pdf": 100])
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.keep.count, 1)
    }

    func testAFileReplacedUnderTheSameNameIsSentAgain() {
        let plan = SourceRules.plan(local: [file("A.pdf", 150)], remote: [document("A.pdf")], uploaded: ["A.pdf": 100])
        XCTAssertEqual(plan.remove.map { $0.title }, ["A.pdf"], "Eski içerik depodan silinir")
        XCTAssertEqual(plan.upload.map { $0.name }, ["A.pdf"], "Yeni içerik yüklenir")
    }

    func testWithoutAnUploadRecordTheSizeGoogleReportsDecides() {
        let same = SourceRules.plan(local: [file("A.pdf", 100)], remote: [document("A.pdf", bytes: 100)], uploaded: [:])
        XCTAssertTrue(same.isEmpty)
        let changed = SourceRules.plan(local: [file("A.pdf", 100)], remote: [document("A.pdf", bytes: 90)], uploaded: [:])
        XCTAssertEqual(changed.upload.count, 1)
        let unknown = SourceRules.plan(local: [file("A.pdf", 100)], remote: [document("A.pdf")], uploaded: [:])
        XCTAssertTrue(unknown.isEmpty, "Boyut bilinmiyorsa ad yeter: dosya boşuna yeniden yüklenmez")
    }

    func testAFailedDocumentAndASecondCopyAreRemoved() {
        let failed = SourceRules.plan(local: [file("A.pdf", 100)], remote: [document("A.pdf", state: "STATE_FAILED")], uploaded: ["A.pdf": 100])
        XCTAssertEqual(failed.remove.count, 1)
        XCTAssertEqual(failed.upload.map { $0.name }, ["A.pdf"], "İşlenemeyen belge silinip dosya yeniden yüklenir")
        let twice = SourceRules.plan(local: [file("A.pdf", 100)],
                                     remote: [document("A.pdf", id: "d1"), document("A.pdf", id: "d2")], uploaded: ["A.pdf": 100])
        XCTAssertEqual(twice.keep.map { $0.id }, ["d1"])
        XCTAssertEqual(twice.remove.map { $0.id }, ["d2"], "Aynı dosyanın ikinci kopyası depoda tutulmaz")
        XCTAssertTrue(twice.upload.isEmpty)
    }

    func testAnEmptyFolderEmptiesTheStore() {
        let plan = SourceRules.plan(local: [], remote: [document("A.pdf"), document("B.pdf")], uploaded: [:])
        XCTAssertEqual(plan.remove.count, 2)
        XCTAssertTrue(plan.upload.isEmpty)
    }

    func testTheFolderScanCountsPagesAndExplainsWhatItSkips() throws {
        let dir = makeTempFolder("kaynak-tarama")
        defer { try? FileManager.default.removeItem(at: dir) }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 200))
        let pdf = renderer.pdfData { context in
            for _ in 0..<3 { context.beginPage() }
        }
        try pdf.write(to: dir.appendingPathComponent("Kitap.pdf"))
        try Data(repeating: 65, count: 4_000).write(to: dir.appendingPathComponent("Notlar.txt"))
        try Data(repeating: 1, count: 10).write(to: dir.appendingPathComponent("resim.jpg"))
        try Data().write(to: dir.appendingPathComponent("bos.pdf"))
        try Data(repeating: 1, count: 10).write(to: dir.appendingPathComponent(".gizli.pdf"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("AltKlasor"), withIntermediateDirectories: true)

        let scan = SourceRules.scan(dir)
        XCTAssertEqual(scan.files.map { $0.name }, ["Kitap.pdf", "Notlar.txt"])
        XCTAssertEqual(scan.files[0].pages, 3, "PDF'in sayfa sayısı yüklemeden önce sayılır")
        XCTAssertEqual(scan.files[0].bytes, pdf.count)
        XCTAssertEqual(scan.files[1].pages, 0)
        XCTAssertEqual(scan.skipped.count, 2, "Desteklenmeyen tür ve boş dosya nedeniyle yazılır; gizli dosya ve alt klasör sayılmaz")
        XCTAssertTrue(scan.skipped.contains { $0.hasPrefix("resim.jpg") && $0.contains("desteklenmeyen") })
        XCTAssertTrue(scan.skipped.contains { $0.hasPrefix("bos.pdf") && $0.contains("boş") })
        XCTAssertTrue(SourceRules.scan(dir.appendingPathComponent("yok")).files.isEmpty, "Klasör yoksa kaynak yok sayılır")
    }

    func testTheSummaryGivesCountPagesAndSize() {
        let files = [file("A.pdf", 40_000_000, pages: 1_000), file("B.pdf", 23_000_000, pages: 602)]
        XCTAssertEqual(SourceRules.summary(files), "2 kaynak, 1.602 sayfa, 63 MB")
        XCTAssertEqual(SourceRules.summary([file("N.txt", 4_000)]), "1 kaynak, 4 KB", "Sayfa sayısı bilinmiyorsa yazılmaz")
        XCTAssertEqual(SourceRules.sizeText(5_200_000), "5,2 MB")
        XCTAssertEqual(SourceRules.mimeType(for: "Kitap.PDF"), "application/pdf")
        XCTAssertNil(SourceRules.mimeType(for: "resim.jpg"))
    }

    func testTheReportSaysHowManyFilesOfWhatSizeWereSynchronised() {
        var report = SourceReport()
        report.uploaded = [file("A.pdf", 40_000_000), file("B.pdf", 23_000_000)]
        report.ready = report.uploaded
        XCTAssertEqual(SourceRules.reportText(report),
                       "Senkron tamamlandı: 63 MB boyutunda 2 dosya senkronize edildi (yüklenen 2 (63 MB), depodan silinen 0, değişmeyen 0).")
        var second = SourceReport()
        second.ready = [file("A.pdf", 40_000_000), file("C.pdf", 12_000_000)]
        second.uploaded = [file("C.pdf", 12_000_000)]
        second.removed = 1
        second.unchanged = 1
        XCTAssertEqual(SourceRules.reportText(second),
                       "Senkron tamamlandı: 52 MB boyutunda 2 dosya senkronize edildi (yüklenen 1 (12 MB), depodan silinen 1, değişmeyen 1).")
    }

    func testAnIncompleteSynchroniseIsReportedWithItsReasons() {
        var report = SourceReport()
        report.ready = [file("A.pdf", 40_000_000)]
        report.unchanged = 1
        report.failed = ["B.pdf": "İnternete ulaşılamadı"]
        report.pending = 1
        let text = SourceRules.reportText(report)
        XCTAssertTrue(text.hasPrefix("Senkron eksik kaldı: 40 MB boyutunda 1 dosya senkronize edildi"), text)
        XCTAssertTrue(text.contains("Yüklenemeyen 1 dosya: B.pdf (İnternete ulaşılamadı)."), text)
        XCTAssertTrue(text.contains("1 dosyayı Google hâlâ işliyor"), text)

        var failed = SourceReport()
        failed.problem = "API anahtarı geçersiz"
        XCTAssertEqual(SourceRules.reportText(failed), "Senkron yapılamadı: API anahtarı geçersiz")

        var emptied = SourceReport()
        emptied.removed = 4
        XCTAssertEqual(SourceRules.reportText(emptied), "Senkron tamamlandı: klasör boş; depodaki 4 kaynak silindi.")
        XCTAssertEqual(SourceRules.reportText(SourceReport()), "Senkron tamamlandı: klasör boş, depoda kaynak yok.")
    }

    func testTheStateLineTellsWhenTheFolderChangedSinceTheLastSynchronise() {
        let files = [file("A.pdf", 100)]
        XCTAssertEqual(SourceRules.stateText(nil, files: files), "henüz yüklenmedi, senkronize edin")
        XCTAssertTrue(SourceRules.outOfDate(state: nil, files: files))
        XCTAssertFalse(SourceRules.outOfDate(state: nil, files: []), "Klasör boşken ve hiç senkron yapılmamışken yapılacak iş yoktur")

        var state = SourceState()
        state.store = "fileSearchStores/depo"
        state.active = ["A.pdf"]
        state.synced = files
        state.date = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(SourceRules.outOfDate(state: state, files: files))
        XCTAssertTrue(SourceRules.stateText(state, files: files).hasPrefix("1 kaynak hazır (son senkron "))

        let changed = files + [file("B.pdf", 200)]
        XCTAssertTrue(SourceRules.outOfDate(state: state, files: changed))
        XCTAssertTrue(SourceRules.stateText(state, files: changed).contains("klasör değişmiş, senkronize edin"))

        state.failed = ["A.pdf": "depoda görünmüyor"]
        XCTAssertTrue(SourceRules.outOfDate(state: state, files: files), "Yüklenemeyen dosya varken depo klasörle eşit sayılmaz")
        XCTAssertTrue(SourceRules.stateText(state, files: files).contains("1 dosya yüklenemedi (A.pdf: depoda görünmüyor)"))
    }
}

// MARK: - Gemini dosya arama deposu: telde giden istekler

final class GeminiSourceWireTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FakeGeminiProtocol.reset()
    }

    private func client() -> GeminiClient {
        return fakeGeminiClient("gemini-test")
    }

    func testAStoreWithOurTitleIsReusedOtherwiseANewOneIsOpened() async throws {
        sourceQueue([sourceReply(["fileSearchStores": [["name": "fileSearchStores/baska", "displayName": "Başka depo"]]]),
                     sourceReply(["name": "fileSearchStores/sesli-kontrol-1", "displayName": SourceRules.storeTitle])])
        let created = try await client().sourceStore(saved: "", title: SourceRules.storeTitle, key: "AIza-TEST")
        XCTAssertEqual(created, "fileSearchStores/sesli-kontrol-1")
        var traffic = sourceTraffic()
        XCTAssertEqual(traffic.methods, ["GET", "POST"])
        XCTAssertEqual(traffic.urls[0], "https://example.test/v1beta/fileSearchStores?pageSize=20")
        XCTAssertEqual(traffic.urls[1], "https://example.test/v1beta/fileSearchStores")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: traffic.bodies[1]) as? [String: Any])
        XCTAssertEqual(body["displayName"] as? String, SourceRules.storeTitle)
        XCTAssertEqual(traffic.headers[0].first(where: { $0.key.lowercased() == "x-goog-api-key" })?.value, "AIza-TEST")
        XCTAssertFalse(traffic.urls[0].contains("key="), "Anahtar adreste değil başlıkta gider")

        FakeGeminiProtocol.reset()
        sourceQueue([sourceReply(["fileSearchStores": [["name": "fileSearchStores/eski", "displayName": SourceRules.storeTitle]]])])
        let found = try await client().sourceStore(saved: "", title: SourceRules.storeTitle, key: "AIza-TEST")
        XCTAssertEqual(found, "fileSearchStores/eski", "Uygulama yeniden kurulduysa eski depo adından bulunur")
        traffic = sourceTraffic()
        XCTAssertEqual(traffic.methods, ["GET"], "Depo varken yenisi açılmaz")
    }

    func testASavedStoreIsCheckedAndAMissingOneIsLookedUpAgain() async throws {
        sourceQueue([sourceReply(["name": "fileSearchStores/kayitli"])])
        let kept = try await client().sourceStore(saved: "fileSearchStores/kayitli", title: SourceRules.storeTitle, key: "AIza-TEST")
        XCTAssertEqual(kept, "fileSearchStores/kayitli")
        XCTAssertEqual(sourceTraffic().urls, ["https://example.test/v1beta/fileSearchStores/kayitli"])

        FakeGeminiProtocol.reset()
        sourceQueue([sourceReply(["error": ["message": "not found"]], status: 404),
                     sourceReply(["fileSearchStores": noItems]),
                     sourceReply(["name": "fileSearchStores/yeni"])])
        let fresh = try await client().sourceStore(saved: "fileSearchStores/silinmis", title: SourceRules.storeTitle, key: "AIza-TEST")
        XCTAssertEqual(fresh, "fileSearchStores/yeni", "Google'da artık olmayan depo yerine yenisi açılır")
        XCTAssertEqual(sourceTraffic().methods, ["GET", "GET", "POST"])
    }

    func testDocumentsAreReadPageByPage() async throws {
        sourceQueue([sourceReply(["documents": [sourceDocument("A.pdf", bytes: 100)], "nextPageToken": "s2+/="]),
                     sourceReply(["documents": [sourceDocument("B.pdf", state: "STATE_PENDING")]])])
        let documents = try await client().sourceDocuments(store: "fileSearchStores/depo", key: "AIza-TEST")
        XCTAssertEqual(documents.map { $0.title }, ["A.pdf", "B.pdf"])
        XCTAssertEqual(documents[0].bytes, 100, "Google boyutu metin olarak yollar")
        XCTAssertTrue(documents[0].isActive)
        XCTAssertFalse(documents[1].isActive)
        XCTAssertNil(documents[1].bytes)
        let traffic = sourceTraffic()
        XCTAssertEqual(traffic.urls[0], "https://example.test/v1beta/fileSearchStores/depo/documents?pageSize=20")
        XCTAssertEqual(traffic.urls[1], "https://example.test/v1beta/fileSearchStores/depo/documents?pageSize=20&pageToken=s2%2B%2F%3D")
    }

    func testAFileIsUploadedToTheStoreInTwoSteps() async throws {
        sourceQueue([sourceReply([:], headers: ["X-Goog-Upload-URL": "https://example.test/upload/oturum/7"]),
                     sourceReply(["name": "fileSearchStores/depo/upload/operations/is-1", "done": false])])
        let bytes = Data(repeating: 7, count: 2_048)
        let operation = try await client().uploadSource(bytes, mimeType: "application/pdf", title: "XVI. Yüzyıl Türk Edebiyatı.pdf",
                                                        store: "fileSearchStores/depo", key: "AIza-TEST", timeout: 30)
        XCTAssertEqual(operation.name, "fileSearchStores/depo/upload/operations/is-1")
        XCTAssertFalse(operation.done)
        XCTAssertEqual(operation.error, "")
        let traffic = sourceTraffic()
        XCTAssertEqual(traffic.methods, ["POST", "POST"])
        XCTAssertEqual(traffic.urls[0], "https://example.test/upload/v1beta/fileSearchStores/depo:uploadToFileSearchStore")
        func header(_ index: Int, _ name: String) -> String? {
            return traffic.headers[index].first(where: { $0.key.lowercased() == name.lowercased() })?.value
        }
        XCTAssertEqual(header(0, "X-Goog-Upload-Protocol"), "resumable")
        XCTAssertEqual(header(0, "X-Goog-Upload-Command"), "start")
        XCTAssertEqual(header(0, "X-Goog-Upload-Header-Content-Length"), "2048")
        XCTAssertEqual(header(0, "X-Goog-Upload-Header-Content-Type"), "application/pdf")
        XCTAssertEqual(header(0, "x-goog-api-key"), "AIza-TEST")
        let meta = try XCTUnwrap(try JSONSerialization.jsonObject(with: traffic.bodies[0]) as? [String: Any])
        XCTAssertEqual(meta["displayName"] as? String, "XVI. Yüzyıl Türk Edebiyatı.pdf", "Dosyanın adı depoda da aynıdır (klasörle eşlemek için)")
        XCTAssertEqual(traffic.urls[1], "https://example.test/upload/oturum/7")
        XCTAssertEqual(header(1, "X-Goog-Upload-Command"), "upload, finalize")
        XCTAssertEqual(header(1, "X-Goog-Upload-Offset"), "0")
        XCTAssertEqual(traffic.bodies[1], bytes, "Dosyanın baytları olduğu gibi gider")
    }

    func testAnUploadThatGoogleRefusesCarriesItsReason() async {
        sourceQueue([sourceReply(["error": ["message": "File too large"]], status: 400)])
        do {
            _ = try await client().uploadSource(Data([1, 2, 3]), mimeType: "application/pdf", title: "A.pdf",
                                                store: "fileSearchStores/depo", key: "AIza-TEST", timeout: 30)
            XCTFail("Hata bekleniyordu")
        } catch let error as GeminiError {
            XCTAssertEqual(error.status, 400)
            XCTAssertTrue(error.message.contains("Yükleme başlatılamadı"), error.message)
            XCTAssertTrue(error.message.contains("File too large"), error.message)
        } catch {
            XCTFail("Beklenmeyen hata: \(error)")
        }
    }

    func testDeletingADocumentTakesItsChunksAlongAndAMissingOneCountsAsDeleted() async throws {
        sourceQueue([sourceReply([:]), sourceReply(["error": ["message": "not found"]], status: 404)])
        try await client().deleteSourceDocument("fileSearchStores/depo/documents/a-1", key: "AIza-TEST")
        try await client().deleteSourceDocument("fileSearchStores/depo/documents/a-2", key: "AIza-TEST")
        let traffic = sourceTraffic()
        XCTAssertEqual(traffic.methods, ["DELETE", "DELETE"])
        XCTAssertEqual(traffic.urls[0], "https://example.test/v1beta/fileSearchStores/depo/documents/a-1?force=true")
    }

    func testTheUploadOperationIsAskedUntilItIsDone() async {
        sourceQueue([sourceReply(["name": "fileSearchStores/depo/upload/operations/is-1", "done": false]),
                     sourceReply(["name": "fileSearchStores/depo/upload/operations/is-1", "done": true, "response": ["documentName": "x"]])])
        let problem = await client().waitForSourceOperation("fileSearchStores/depo/upload/operations/is-1", key: "AIza-TEST", limit: 60)
        XCTAssertNil(problem)
        XCTAssertEqual(sourceTraffic().urls, Array(repeating: "https://example.test/v1beta/fileSearchStores/depo/upload/operations/is-1", count: 2))

        FakeGeminiProtocol.reset()
        sourceQueue([sourceReply(["done": true, "error": ["code": 3, "message": "Unsupported file"]])])
        let failed = await client().waitForSourceOperation("fileSearchStores/depo/upload/operations/is-2", key: "AIza-TEST", limit: 60)
        XCTAssertEqual(failed, "Unsupported file", "Google dosyayı işleyemezse nedeni kullanıcıya gösterilir")
    }

    func testTheSourcesAnAnswerLeanedOnAreReadFromTheReply() {
        let reply: [String: Any] = ["candidates": [[
            "content": ["parts": [["text": "Soru 1, Adana, X"]]],
            "groundingMetadata": ["groundingChunks": [
                ["retrievedContext": ["title": "XVI. Yüzyıl.pdf", "text": "…"]],
                ["retrievedContext": ["title": "Çağdaş.pdf", "text": "…"]],
                ["retrievedContext": ["title": "XVI. Yüzyıl.pdf", "text": "…"]]
            ]]
        ]]]
        let use = GeminiSupport.sourceUse(from: reply)
        XCTAssertEqual(use.map { $0.title }, ["XVI. Yüzyıl.pdf", "Çağdaş.pdf"])
        XCTAssertEqual(use.map { $0.count }, [2, 1])
        XCTAssertEqual(GeminiSupport.sourceUseText(use), "cevap 3 kaynak parçasına dayandı: XVI. Yüzyıl.pdf ×2, Çağdaş.pdf ×1")
        let none = GeminiSupport.sourceUse(from: ["candidates": [["content": ["parts": [["text": "x"]]]]]])
        XCTAssertTrue(none.isEmpty)
        XCTAssertTrue(GeminiSupport.sourceUseText(none).contains("kaynaklardan parça gelmedi"))
    }
}

// MARK: - Cevap isteği: seçenek kapalıyken eskisi gibi, açıkken dosya aramalı

@MainActor
final class SourceAnswerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FakeGeminiProtocol.reset()
    }

    private func ok(_ text: String) -> FakeGeminiProtocol.Reply {
        return sourceReply(["candidates": [["finishReason": "STOP", "content": ["parts": [["text": text]]]]]])
    }

    private func refusal(_ status: Int, _ message: String) -> FakeGeminiProtocol.Reply {
        return sourceReply(["error": ["code": status, "message": message]], status: status)
    }

    private func service() -> GeminiAnswerService {
        return GeminiAnswerService(profiles: testProfiles(count: 1), makeClient: fakeProfileClient)
    }

    private func sent(_ index: Int) throws -> [String: Any] {
        let bodies = sourceTraffic().bodies
        XCTAssertGreaterThan(bodies.count, index, "Giden istek yok")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: bodies[index]) as? [String: Any])
    }

    private func systemTexts(_ body: [String: Any]) -> [String] {
        let parts = ((body["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        return parts.compactMap { $0["text"] as? String }
    }

    func testWithTheOptionOffTheRequestIsExactlyTheOldOne() async throws {
        let plain = try GeminiAnswerService.requestBody(question: "bir soru", expectedNumber: 1)
        XCTAssertEqual(GeminiAnswerService.body(plain, forModel: "gemini-3.6-flash"), plain, "Kaynak yokken gövdeye dokunulmaz (bayt bayt aynı)")
        XCTAssertEqual(GeminiAnswerService.body(plain, forModel: "gemini-3.6-flash", store: "  "), plain)

        sourceQueue([ok("Soru 1, Adana, Cevap")])
        let reply = try await service().answer(question: "bir soru", english: "", expectedNumber: 1, audio: nil, passage: nil)
        XCTAssertEqual(reply.option, "Adana")
        let body = try sent(0)
        XCTAssertNil(body["tools"], "Seçenek kapalıyken isteğe dosya arama girmez")
        XCTAssertEqual(systemTexts(body), [GeminiAnswerService.systemPrompt], "Sistem komutu eskisiyle aynıdır")
        XCTAssertEqual(sourceTraffic().urls.count, 1, "Kaynak deposuna hiçbir istek gitmez")
    }

    func testWithAReadyStoreTheRequestCarriesTheFileSearchToolAndTheSourceInstruction() async throws {
        let answering = service()
        answering.sourceStore = { _ in "fileSearchStores/depo" }
        var rejected = 0
        answering.onSourceRejected = { _, _ in rejected += 1 }
        sourceQueue([ok("Soru 2, Bursa, Cevap")])
        let reply = try await answering.answer(question: "ikinci soru", english: "", expectedNumber: 2, audio: nil, passage: nil)
        XCTAssertEqual(reply.number, 2)
        let body = try sent(0)
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        let search = try XCTUnwrap(tools[0]["file_search"] as? [String: Any])
        XCTAssertEqual(search["file_search_store_names"] as? [String], ["fileSearchStores/depo"])
        let texts = systemTexts(body)
        XCTAssertEqual(texts.count, 2)
        XCTAssertEqual(texts[0], GeminiAnswerService.systemPrompt, "Asıl komut değişmez; kaynak talimatı sonuna eklenir")
        XCTAssertTrue(texts[1].contains("KAYNAKLAR"))
        XCTAssertTrue(texts[1].contains("KAYNAĞA uy"))
        XCTAssertTrue(texts[1].contains("kendi bilginle çöz"), "Kaynakta bilgi yoksa soru cevapsız bırakılmaz")
        XCTAssertEqual(rejected, 0)
    }

    func testAStoreGeminiRefusesIsDroppedAndTheAnswerStillComes() async throws {
        let answering = service()
        answering.sourceStore = { _ in "fileSearchStores/depo" }
        var rejections: [Int] = []
        answering.onSourceRejected = { _, error in rejections.append(error.status) }
        sourceQueue([refusal(400, "File search is not supported for this model"), ok("Soru 3, Ceyhan, Cevap")])
        let reply = try await answering.answer(question: "üçüncü soru", english: "", expectedNumber: 3, audio: nil, passage: nil)
        XCTAssertEqual(reply.option, "Ceyhan", "Kaynak deposu reddedilse de cevap alınır")
        XCTAssertNotNil(try sent(0)["tools"])
        XCTAssertNil(try sent(1)["tools"], "Aynı istek kaynaksız yeniden gönderilir")
        XCTAssertEqual(systemTexts(try sent(1)), [GeminiAnswerService.systemPrompt])
        XCTAssertEqual(rejections, [400], "Kullanıcı bir kez haberdar edilir")

        sourceQueue([ok("Soru 4, Denizli, Cevap")])
        _ = try await answering.answer(question: "dördüncü soru", english: "", expectedNumber: 4, audio: nil, passage: nil)
        XCTAssertNil(try sent(2)["tools"], "Reddedilen depo aynı çalıştırmada her soruda yeniden denenmez")
        XCTAssertEqual(sourceTraffic().urls.count, 3)

        answering.sourcesChanged()
        sourceQueue([ok("Soru 5, Erzurum, Cevap")])
        _ = try await answering.answer(question: "beşinci soru", english: "", expectedNumber: 5, audio: nil, passage: nil)
        XCTAssertNotNil(try sent(3)["tools"], "Yeni senkrondan sonra depo yeniden denenir")
    }

    func testARefusalThatIsNotAboutTheStoreIsNotBlamedOnIt() async throws {
        let answering = service()
        answering.sourceStore = { _ in "fileSearchStores/depo" }
        var rejected = 0
        answering.onSourceRejected = { _, _ in rejected += 1 }
        sourceQueue([refusal(404, "model not found"), refusal(404, "model not found")])
        do {
            _ = try await answering.answer(question: "soru", english: "", expectedNumber: 1, audio: nil, passage: nil)
            XCTFail("Hata bekleniyordu")
        } catch let error as GeminiError {
            XCTAssertEqual(error.status, 404)
        }
        XCTAssertEqual(rejected, 0, "Kaynaksız istek de reddedildiyse neden depo değildir")

        sourceQueue([ok("Soru 1, Adana, Cevap")])
        _ = try await answering.answer(question: "soru", english: "", expectedNumber: 1, audio: nil, passage: nil)
        XCTAssertNotNil(try sent(2)["tools"], "Depo işaretlenmediği için sonraki soruda yine kullanılır")
    }

    func testAnInvalidKeyIsNotTreatedAsAStoreRefusal() {
        var key = GeminiError("API anahtarı geçersiz", .key, status: 400)
        XCTAssertFalse(GeminiAnswerService.sourceRejection(key))
        key = GeminiError("Gemini isteği kabul etmedi (400)", .http, status: 400)
        XCTAssertTrue(GeminiAnswerService.sourceRejection(key))
        XCTAssertTrue(GeminiAnswerService.sourceRejection(GeminiError("yok", .model, status: 404)))
        XCTAssertFalse(GeminiAnswerService.sourceRejection(GeminiError("kota", .quota, status: 429)))
        XCTAssertFalse(GeminiAnswerService.sourceRejection(GeminiError("sunucu", .http, status: 503)))
    }
}

// MARK: - Senkron: yalnız düğmeyle, klasörün aynası, bitince rapor

@MainActor
final class SourceSyncTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var settings: AppSettings!

    override func setUp() {
        super.setUp()
        FakeGeminiProtocol.reset()
        Keychain.testStore = [:]
        root = makeTempFolder("kaynak-senkron")
        defaults = UserDefaults(suiteName: "g526.testler.kaynak.\(UUID().uuidString)")!
        settings = AppSettings(defaults: defaults)
        settings.geminiKeys[0] = "AIza-TEST"
    }

    override func tearDown() {
        Keychain.testStore = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private var folder: URL {
        return root.appendingPathComponent(SourceRules.folderName, isDirectory: true)
    }

    private func put(_ name: String, bytes: Int) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 66, count: bytes).write(to: folder.appendingPathComponent(name))
    }

    private func makeSync() -> SourceSync {
        let base: URL = root
        return SourceSync(settings: settings, defaults: defaults, root: { base },
                          now: { Date(timeIntervalSince1970: 1_800_000_000) }, pause: { _ in }, makeClient: fakeProfileClient)
    }

    /// İlk senkronun cevapları: depo yok → açılır, depo boş, iki dosya yüklenir, sonunda ikisi de hazır
    private func queueFirstSync() {
        sourceQueue([sourceReply(["fileSearchStores": noItems]),
                     sourceReply(["name": "fileSearchStores/depo"]),
                     sourceReply(["documents": noItems]),
                     sourceReply([:], headers: ["X-Goog-Upload-URL": "https://example.test/upload/oturum/1"]),
                     sourceReply(["name": "fileSearchStores/depo/upload/operations/is-1", "done": true]),
                     sourceReply([:], headers: ["X-Goog-Upload-URL": "https://example.test/upload/oturum/2"]),
                     sourceReply(["name": "fileSearchStores/depo/upload/operations/is-2", "done": true]),
                     sourceReply(["documents": [sourceDocument("A.pdf"), sourceDocument("B.txt")]])])
    }

    func testWithTheOptionOffNothingIsTouched() async throws {
        try put("A.pdf", bytes: 2_000)
        try FileManager.default.removeItem(at: folder)
        let sync = makeSync()
        sync.refresh()
        sync.syncNow()
        await sync.waitUntilIdle()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "Seçenek kapalıyken Kaynaklar klasörü açılmaz")
        XCTAssertTrue(sync.lines.isEmpty)
        XCTAssertTrue(sync.report.isEmpty)
        XCTAssertNil(sync.readiness(), "Açılış denetiminde kaynak satırı olmaz")
        XCTAssertNil(sync.store(forKey: "AIza-TEST"))
        XCTAssertTrue(sourceTraffic().urls.isEmpty, "Google'a hiçbir istek gitmez")
    }

    func testTurningTheOptionOnPreparesTheFolderButUploadsNothing() throws {
        let sync = makeSync()
        settings.useSources = true
        sync.optionChanged()
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "Kaynaklar klasörü kullanıcı dosya koyabilsin diye açılır")
        try put("A.pdf", bytes: 2_000)
        sync.refresh()
        XCTAssertTrue(sourceTraffic().urls.isEmpty, "Kendiliğinden yükleme yoktur: kullanıcı düğmeye basar")
        XCTAssertTrue(sync.lines.contains { $0.contains("Klasörde 1 kaynak") }, "\(sync.lines)")
        XCTAssertTrue(sync.lines.contains { $0.contains("henüz yüklenmedi, senkronize edin") }, "\(sync.lines)")
        XCTAssertNil(sync.store(forKey: "AIza-TEST"), "Yüklenmemiş kaynakla istek kaynaksız gider")
        XCTAssertEqual(sync.readiness()?.ok, false)
        XCTAssertTrue(sync.readiness()?.warning?.contains("yüklenmemiş") ?? false)
    }

    func testSynchronisingUploadsTheFolderAndReportsCountAndSize() async throws {
        try put("A.pdf", bytes: 2_000)
        try put("B.txt", bytes: 3_000)
        settings.useSources = true
        let sync = makeSync()
        var changes = 0
        sync.onChange = { changes += 1 }
        queueFirstSync()
        sync.syncNow()
        XCTAssertTrue(sync.busy)
        await sync.waitUntilIdle()
        XCTAssertFalse(sync.busy)
        XCTAssertEqual(sync.report, ["Senkron tamamlandı: 5 KB boyutunda 2 dosya senkronize edildi (yüklenen 2 (5 KB), depodan silinen 0, değişmeyen 0)."])
        XCTAssertEqual(sync.progress, "")
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(sync.store(forKey: "AIza-TEST"), "fileSearchStores/depo", "Hazır depo cevap isteklerine verilir")
        XCTAssertEqual(sync.readiness(), SourceReadiness(ok: true, detail: "2 kaynak hazır", warning: nil))
        XCTAssertTrue(sync.lines.contains { $0.hasPrefix("Gemini deposu: 2 kaynak hazır") }, "\(sync.lines)")
        let traffic = sourceTraffic()
        XCTAssertEqual(traffic.methods, ["GET", "POST", "GET", "POST", "POST", "POST", "POST", "GET"])
        XCTAssertEqual(traffic.bodies[4].count, 2_000)
        XCTAssertEqual(traffic.bodies[6].count, 3_000)

        // Durum kalıcıdır: uygulama yeniden açılınca depo bilinir, yeniden yükleme gerekmez
        let again = makeSync()
        XCTAssertEqual(again.store(forKey: "AIza-TEST"), "fileSearchStores/depo")
        settings.useSources = false
        XCTAssertNil(again.store(forKey: "AIza-TEST"), "Seçenek kapatılınca depo isteklere verilmez")
    }

    func testASecondSynchroniseSendsNothingWhenNothingChanged() async throws {
        try put("A.pdf", bytes: 2_000)
        try put("B.txt", bytes: 3_000)
        settings.useSources = true
        let sync = makeSync()
        queueFirstSync()
        sync.syncNow()
        await sync.waitUntilIdle()

        FakeGeminiProtocol.reset()
        let documents = ["documents": [sourceDocument("A.pdf"), sourceDocument("B.txt")]]
        sourceQueue([sourceReply(["name": "fileSearchStores/depo"]), sourceReply(documents), sourceReply(documents)])
        sync.syncNow()
        await sync.waitUntilIdle()
        XCTAssertEqual(sourceTraffic().methods, ["GET", "GET", "GET"], "Değişmeyen dosya yeniden gönderilmez")
        XCTAssertEqual(sync.report, ["Senkron tamamlandı: 5 KB boyutunda 2 dosya senkronize edildi (yüklenen 0, depodan silinen 0, değişmeyen 2)."])
    }

    func testAFileTakenOutOfTheFolderIsDeletedFromTheStoreAndAStoreLossIsRepaired() async throws {
        try put("A.pdf", bytes: 2_000)
        try put("B.txt", bytes: 3_000)
        settings.useSources = true
        let sync = makeSync()
        queueFirstSync()
        sync.syncNow()
        await sync.waitUntilIdle()

        // Klasör değişti ama düğmeye basılmadı: yükleme yok, yalnız durum ve açılış uyarısı değişir
        try FileManager.default.removeItem(at: folder.appendingPathComponent("B.txt"))
        FakeGeminiProtocol.reset()
        sync.refresh()
        XCTAssertTrue(sourceTraffic().urls.isEmpty)
        XCTAssertTrue(sync.lines.contains { $0.contains("klasör değişmiş, senkronize edin") }, "\(sync.lines)")
        XCTAssertEqual(sync.readiness()?.ok, false)
        XCTAssertTrue(sync.readiness()?.warning?.contains("senkronize değil") ?? false)

        sourceQueue([sourceReply(["name": "fileSearchStores/depo"]),
                     sourceReply(["documents": [sourceDocument("A.pdf"), sourceDocument("B.txt", id: "fileSearchStores/depo/documents/b-9")]]),
                     sourceReply([:]),
                     sourceReply(["documents": [sourceDocument("A.pdf")]])])
        sync.syncNow()
        await sync.waitUntilIdle()
        let traffic = sourceTraffic()
        XCTAssertEqual(traffic.methods, ["GET", "GET", "DELETE", "GET"])
        XCTAssertEqual(traffic.urls[2], "https://example.test/v1beta/fileSearchStores/depo/documents/b-9?force=true")
        XCTAssertEqual(sync.report, ["Senkron tamamlandı: 2 KB boyutunda 1 dosya senkronize edildi (yüklenen 0, depodan silinen 1, değişmeyen 1)."])
        XCTAssertEqual(sync.readiness()?.ok, true)

        // Google depodaki belgeyi silmişse (liste boş döner) bir sonraki senkronda klasördeki dosya yeniden yüklenir
        FakeGeminiProtocol.reset()
        sourceQueue([sourceReply(["name": "fileSearchStores/depo"]),
                     sourceReply(["documents": noItems]),
                     sourceReply([:], headers: ["X-Goog-Upload-URL": "https://example.test/upload/oturum/3"]),
                     sourceReply(["name": "fileSearchStores/depo/upload/operations/is-3", "done": true]),
                     sourceReply(["documents": [sourceDocument("A.pdf")]])])
        sync.syncNow()
        await sync.waitUntilIdle()
        XCTAssertEqual(sourceTraffic().methods, ["GET", "GET", "POST", "POST", "GET"])
        XCTAssertEqual(sync.report, ["Senkron tamamlandı: 2 KB boyutunda 1 dosya senkronize edildi (yüklenen 1 (2 KB), depodan silinen 0, değişmeyen 0)."])
    }

    func testAFailedUploadIsNamedInTheReportAndTheRestStillGoes() async throws {
        try put("A.pdf", bytes: 2_000)
        try put("B.txt", bytes: 3_000)
        settings.useSources = true
        let sync = makeSync()
        sourceQueue([sourceReply(["fileSearchStores": noItems]),
                     sourceReply(["name": "fileSearchStores/depo"]),
                     sourceReply(["documents": noItems]),
                     sourceReply(["error": ["message": "Unsupported file"]], status: 400),
                     sourceReply([:], headers: ["X-Goog-Upload-URL": "https://example.test/upload/oturum/2"]),
                     sourceReply(["name": "fileSearchStores/depo/upload/operations/is-2", "done": true]),
                     sourceReply(["documents": [sourceDocument("B.txt")]])])
        sync.syncNow()
        await sync.waitUntilIdle()
        let text = sync.report.joined(separator: " ")
        XCTAssertTrue(text.hasPrefix("Senkron eksik kaldı: 3 KB boyutunda 1 dosya senkronize edildi (yüklenen 1 (3 KB)"), text)
        XCTAssertTrue(text.contains("Yüklenemeyen 1 dosya: A.pdf ("), text)
        XCTAssertTrue(text.contains("Unsupported file"), text)
        XCTAssertEqual(sync.store(forKey: "AIza-TEST"), "fileSearchStores/depo", "Yüklenen kaynakla cevap yine kaynaklı istenir")
        XCTAssertEqual(sync.readiness()?.ok, false, "Eksik kalan dosya açılışta uyarılır")
    }

    func testWithoutInternetTheReportSaysTheSynchroniseCouldNotBeDone() async throws {
        try put("A.pdf", bytes: 2_000)
        settings.useSources = true
        let sync = makeSync()
        sourceQueue([FakeGeminiProtocol.Reply(status: 0, body: Data(), error: URLError(.notConnectedToInternet))])
        sync.syncNow()
        await sync.waitUntilIdle()
        XCTAssertEqual(sync.report.count, 1)
        XCTAssertTrue(sync.report[0].hasPrefix("Senkron yapılamadı: İnternete ulaşılamadı"), sync.report[0])
        XCTAssertNil(sync.store(forKey: "AIza-TEST"))
        XCTAssertTrue(sync.lines.contains { $0.contains("senkronize edilemedi") }, "\(sync.lines)")
    }

    func testWhileATestRunsTheSynchroniseIsRefused() async throws {
        try put("A.pdf", bytes: 2_000)
        settings.useSources = true
        let sync = makeSync()
        sync.sessionActive = { true }
        sync.syncNow()
        await sync.waitUntilIdle()
        XCTAssertFalse(sync.busy)
        XCTAssertTrue(sync.progress.contains("Test sürerken senkron yapılmaz"))
        XCTAssertTrue(sourceTraffic().urls.isEmpty, "Test sürerken yükleme cevapların yüklemesiyle yarışmaz")
    }

    func testAStoreGeminiNoLongerHasIsForgottenUntilTheNextSynchronise() async throws {
        try put("A.pdf", bytes: 2_000)
        try put("B.txt", bytes: 3_000)
        settings.useSources = true
        let sync = makeSync()
        queueFirstSync()
        sync.syncNow()
        await sync.waitUntilIdle()
        sync.noteRejection(key: "AIza-TEST", status: 400, message: "File search is not supported for this model")
        XCTAssertEqual(sync.store(forKey: "AIza-TEST"), "fileSearchStores/depo", "Modele özgü ret depoyu geçersiz kılmaz")
        XCTAssertTrue(sync.lines.contains { $0.contains("Gemini depoyu kabul etmedi: File search is not supported") }, "\(sync.lines)")
        sync.noteRejection(key: "AIza-TEST", status: 404, message: "store not found")
        XCTAssertNil(sync.store(forKey: "AIza-TEST"), "Google'da olmayan depo isteklere bir daha verilmez")
        XCTAssertEqual(sync.readiness()?.ok, false)
    }

    func testEveryDistinctKeyGetsItsOwnStore() {
        func profile(_ slot: Int, _ key: String) -> GeminiProfileInfo {
            return GeminiProfileInfo(slot: slot, name: "P\(slot)", model: "m\(slot)", key: key, free: false)
        }
        let groups = SourceSync.keyGroups([profile(1, "K1"), profile(2, " K1 "), profile(3, ""), profile(4, "K2")])
        XCTAssertEqual(groups.map { $0.key }, ["K1", "K2"], "Depo anahtarın projesine aittir: aynı anahtar bir kez, boş anahtar hiç sayılmaz")
        XCTAssertEqual(groups[0].profiles.map { $0.slot }, [1, 2])
        XCTAssertEqual(SourceSync.groupLabel(groups[0].profiles), "1. ve 2. profilin anahtarı")
        XCTAssertEqual(SourceSync.groupLabel(groups[1].profiles), "4. profilin anahtarı")
        XCTAssertNotEqual(SourceSync.keyID("K1"), SourceSync.keyID("K2"))
        XCTAssertEqual(SourceSync.keyID("K1"), SourceSync.keyID(" K1 "))
        XCTAssertFalse(SourceSync.keyID("AIza-GIZLI").contains("GIZLI"), "Anahtarın kendisi ayarlara yazılmaz")
    }
}

// MARK: - Açılış denetimi ve ayar

@MainActor
final class SourceSessionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Keychain.testStore = [:]
    }

    override func tearDown() {
        Keychain.testStore = nil
        super.tearDown()
    }

    func testTheOptionIsOffByDefaultAndIsRemembered() {
        let defaults = UserDefaults(suiteName: "g526.testler.kaynak.ayar.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.useSources, "Varsayılan kapalıdır: program eskisi gibi çalışır")
        settings.useSources = true
        XCTAssertTrue(AppSettings(defaults: defaults).useSources)
    }

    func testWithTheOptionOffTheStartCheckHasNoSourceLine() async {
        let h = SessionHarness()
        let started = await h.startListening()
        XCTAssertTrue(started)
        XCTAssertNil(h.vm.checkup.first(where: { $0.id == "kaynak" }))
        XCTAssertNil(h.vm.warnings.first(where: { $0.id == "kaynak" }))
    }

    func testUnsynchronisedSourcesWarnAtTheStartButTheTestStillStarts() async {
        let h = SessionHarness()
        h.sourceBox.value = SourceReadiness(ok: false, detail: "1 kaynak hazır, klasörle eşit değil", warning: "Kaynaklar senkronize değil.")
        let started = await h.startListening()
        XCTAssertTrue(started, "Kaynakların hazır olmaması testi engellemez")
        XCTAssertEqual(h.vm.warnings.first(where: { $0.id == "kaynak" })?.text, "Kaynaklar senkronize değil.")
        XCTAssertEqual(h.vm.checkup.first(where: { $0.id == "kaynak" })?.ok, false)
    }

    func testReadySourcesShowInTheStartCheckWithoutAWarning() async {
        let h = SessionHarness()
        h.sourceBox.value = SourceReadiness(ok: true, detail: "8 kaynak hazır", warning: nil)
        let started = await h.startListening()
        XCTAssertTrue(started)
        XCTAssertNil(h.vm.warnings.first(where: { $0.id == "kaynak" }))
        XCTAssertEqual(h.vm.checkup.first(where: { $0.id == "kaynak" })?.detail, "8 kaynak hazır")
        XCTAssertEqual(h.vm.checkup.first(where: { $0.id == "kaynak" })?.ok, true)
    }
}
