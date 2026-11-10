import XCTest
@testable import G526CameraDrive

// MARK: - Sahte uzak (Files API + önbellek)

private final class FakeRemote: GeminiRemote, @unchecked Sendable {
    private let lock = NSLock()
    var fingerprint = "anahtar-a"
    var identity = "model|anahtar-a|yonerge"
    private var _uploads: [String] = []
    private var _getFiles: [String] = []
    private var _caches: [String] = []
    private var _touches: [String] = []
    private var _deleted: [String] = []
    /// Gemini'de duran (var olan) dosya adları
    var alive: Set<String> = []
    var uploadFailure: GeminiError?
    var cacheFailure: GeminiError?
    var touchFailure: GeminiError?
    private var counter = 0

    var keyFingerprint: String { return fingerprint }
    var cacheIdentity: String { return identity }

    var uploads: [String] { lock.lock(); defer { lock.unlock() }; return _uploads }
    var getFiles: [String] { lock.lock(); defer { lock.unlock() }; return _getFiles }
    var caches: [String] { lock.lock(); defer { lock.unlock() }; return _caches }
    var touches: [String] { lock.lock(); defer { lock.unlock() }; return _touches }
    var deleted: [String] { lock.lock(); defer { lock.unlock() }; return _deleted }

    func uploadFile(name: String, data: Data) async throws -> RemoteFile {
        if let failure = uploadFailure { throw failure }
        lock.lock()
        counter += 1
        let id = "files/f\(counter)"
        _uploads.append(name)
        alive.insert(id)
        lock.unlock()
        return RemoteFile(name: id, uri: "https://files/\(id)", state: "PROCESSING")
    }

    func getFile(name: String) async throws -> RemoteFile? {
        lock.lock()
        _getFiles.append(name)
        let exists = alive.contains(name)
        lock.unlock()
        return exists ? RemoteFile(name: name, uri: "https://files/\(name)", state: "ACTIVE") : nil
    }

    func waitActive(_ file: RemoteFile) async throws -> RemoteFile {
        return RemoteFile(name: file.name, uri: file.uri, state: "ACTIVE")
    }

    func createCache(docs: [GeminiDoc]) async throws -> String {
        if let failure = cacheFailure { throw failure }
        lock.lock()
        let name = "cachedContents/c\(_caches.count + 1)"
        _caches.append(name)
        lock.unlock()
        return name
    }

    func touchCache(_ name: String) async throws {
        if let failure = touchFailure { throw failure }
        lock.lock(); _touches.append(name); lock.unlock()
    }

    func deleteCache(_ name: String) async {
        lock.lock(); _deleted.append(name); lock.unlock()
    }
}

private final class Clock {
    var value: Double = 1_000_000
}

@MainActor
final class GeminiMemoryTests: XCTestCase {
    private var directory = FileManager.default.temporaryDirectory
    private var remote = FakeRemote()
    private var clock = Clock()
    private var enabled = true
    private var memory: GeminiMemory!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-hafiza-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        remote = FakeRemote()
        clock = Clock()
        enabled = true
        memory = makeMemory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeMemory() -> GeminiMemory {
        let box = self
        let clock = self.clock
        return GeminiMemory(remote: remote, indexURL: directory.appendingPathComponent("dosyalar.json"),
                            enabled: { box.enabled }, now: { clock.value })
    }

    /// pages sayfalık, Drive'dan gelmiş gibi anahtarlı belge
    private func doc(_ id: String, pages: Int = 2) -> GeminiDoc {
        let bytes = Data("%PDF \(id)".utf8)
        return GeminiDoc(name: "\(id).pdf", fileURL: directory.appendingPathComponent("yok-\(id).pdf"), size: bytes.count,
                         pages: pages, key: "d:\(id):\(bytes.count)", loader: { bytes })
    }

    private func noProgress(_ done: Int, _ total: Int) {}

    func testWantedOnlyForBigSets() {
        XCTAssertFalse(memory.wanted([]))
        XCTAssertFalse(memory.wanted([doc("a", pages: 3), doc("b", pages: 4)]), "7 sayfa hafızaya değmez")
        XCTAssertTrue(memory.wanted([doc("a", pages: 4), doc("b", pages: 4)]))
        enabled = false
        XCTAssertFalse(memory.wanted([doc("a", pages: 400)]), "ayar kapalıysa kullanılmaz")
    }

    func testBigDocumentsByBytesWantMemoryEvenWithFewPages() {
        let big = GeminiDoc(name: "kitap.pdf", fileURL: directory.appendingPathComponent("kitap.pdf"), size: 15 * 1024 * 1024,
                            pages: 3, key: "d:kitap:15", loader: nil)
        XCTAssertTrue(memory.wanted([big]), "14 MB'ı aşan set inline gönderilemez")
    }

    func testEachDocumentIsUploadedOnceAndRemembered() async throws {
        let docs = [doc("a"), doc("b"), doc("c")]
        let first = try await memory.upload(docs, progress: noProgress)
        XCTAssertEqual(remote.uploads.sorted(), ["a.pdf", "b.pdf", "c.pdf"])
        XCTAssertTrue(first.allSatisfy { $0.isRemote })
        let second = try await memory.upload(docs, progress: noProgress)
        XCTAssertEqual(remote.uploads.count, 3, "ikinci soruda yeniden yükleme olmamalı")
        XCTAssertEqual(second.map { $0.uri }, first.map { $0.uri })

        let reopened = makeMemory()          // uygulama yeniden açıldı
        let third = try await reopened.upload(docs, progress: noProgress)
        XCTAssertEqual(remote.uploads.count, 3, "uygulama kapanıp açılınca da yüklenmemeli")
        XCTAssertEqual(third.map { $0.remote }, first.map { $0.remote })
    }

    func testProgressIsReported() async throws {
        var seen: [Int] = []
        _ = try await memory.upload([doc("a"), doc("b")], progress: { done, total in
            XCTAssertEqual(total, 2)
            seen.append(done)
        })
        XCTAssertEqual(seen, [1, 2])
    }

    func testAnotherApiKeyUploadsAgain() async throws {
        let docs = [doc("a")]
        _ = try await memory.upload(docs, progress: noProgress)
        remote.fingerprint = "anahtar-b"
        _ = try await memory.upload(docs, progress: noProgress)
        XCTAssertEqual(remote.uploads.count, 2, "dosyalar anahtarın projesine aittir")
    }

    func testMappingOlderThanTheLimitIsUploadedAgain() async throws {
        let docs = [doc("a")]
        _ = try await memory.upload(docs, progress: noProgress)
        clock.value += 41 * 3600
        _ = try await memory.upload(docs, progress: noProgress)
        XCTAssertEqual(remote.uploads.count, 2, "40 saatten eski dosya yeniden yüklenir")
    }

    func testOldMappingIsVerifiedBeforeUse() async throws {
        let docs = [doc("a")]
        let first = try await memory.upload(docs, progress: noProgress)
        clock.value += 13 * 3600
        let kept = try await memory.upload(docs, progress: noProgress)
        XCTAssertEqual(remote.getFiles, [first[0].remote], "12 saatten eski eşleme Gemini'ye sorulur")
        XCTAssertEqual(remote.uploads.count, 1)
        XCTAssertEqual(kept[0].uri, first[0].uri)

        clock.value += 13 * 3600
        remote.alive.removeAll()              // Gemini dosyayı silmiş
        let fresh = try await memory.upload(docs, progress: noProgress)
        XCTAssertEqual(remote.uploads.count, 2)
        XCTAssertNotEqual(fresh[0].uri, first[0].uri)
    }

    func testRevalidateDropsOnlyFilesGeminiLost() async throws {
        let docs = [doc("a"), doc("b")]
        let up = try await memory.upload(docs, progress: noProgress)
        remote.alive.remove(up[0].remote)
        let checked = await memory.revalidate(up)
        XCTAssertEqual(checked.lost, 1)
        XCTAssertFalse(checked.docs[0].isRemote)
        XCTAssertTrue(checked.docs[1].isRemote)
        let again = try await memory.upload(checked.docs, progress: noProgress)
        XCTAssertEqual(remote.uploads.filter { $0 == "a.pdf" }.count, 2, "kaybolan dosya yeniden yüklenmeli")
        XCTAssertTrue(again.allSatisfy { $0.isRemote })
        XCTAssertEqual(remote.uploads.filter { $0 == "b.pdf" }.count, 1)
    }

    func testUploadFailureIsThrown() async {
        remote.uploadFailure = GeminiError("Kota doldu.", .quota, status: 429)
        do {
            _ = try await memory.upload([doc("a")], progress: noProgress)
            XCTFail("hata beklenirdi")
        } catch let e as GeminiError {
            XCTAssertEqual(e.kind, .quota)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testSessionBuildsOneCacheAndExtendsItAfterwards() async throws {
        let docs = [doc("a", pages: 10), doc("b", pages: 10)]
        let first = try await memory.prepare(docs, session: true, progress: noProgress)
        XCTAssertEqual(first.cache, "cachedContents/c1")
        let second = try await memory.prepare(docs, session: true, progress: noProgress)
        XCTAssertEqual(second.cache, "cachedContents/c1")
        XCTAssertEqual(remote.caches.count, 1, "aynı belge setinde yeni önbellek kurulmaz")
        XCTAssertEqual(remote.touches, ["cachedContents/c1"], "her soruda ömrü uzatılır")
    }

    func testChangedDocumentSetRebuildsTheCache() async throws {
        _ = try await memory.prepare([doc("a", pages: 10)], session: true, progress: noProgress)
        let other = try await memory.prepare([doc("a", pages: 10), doc("b", pages: 10)], session: true, progress: noProgress)
        XCTAssertEqual(other.cache, "cachedContents/c2")
        XCTAssertEqual(remote.deleted, ["cachedContents/c1"], "eski önbellek silinir (saklama ücreti işlemesin)")
    }

    func testChangedPromptOrModelRebuildsTheCache() async throws {
        let docs = [doc("a", pages: 10)]
        _ = try await memory.prepare(docs, session: true, progress: noProgress)
        remote.identity = "baska-model|anahtar-a|yonerge"
        let again = try await memory.prepare(docs, session: true, progress: noProgress)
        XCTAssertEqual(again.cache, "cachedContents/c2")
    }

    func testSingleQuestionNeverCreatesACache() async throws {
        let result = try await memory.prepare([doc("a", pages: 50)], session: false, progress: noProgress)
        XCTAssertEqual(result.cache, "")
        XCTAssertTrue(result.docs[0].isRemote)
        XCTAssertTrue(remote.caches.isEmpty)
    }

    func testTooSmallSetsGetNoCacheBecauseOfTheProviderMinimum() async throws {
        let result = try await memory.prepare([doc("a", pages: 3), doc("b", pages: 3)], session: true, progress: noProgress)
        XCTAssertEqual(result.cache, "", "4096 jetondan küçük set önbelleğe alınamaz")
        XCTAssertTrue(remote.caches.isEmpty)
    }

    func testCacheFailureFallsBackToFileReferences() async throws {
        remote.cacheFailure = GeminiError("Önbellek kurulamadı.", .http, status: 400)
        let result = try await memory.prepare([doc("a", pages: 10)], session: true, progress: noProgress)
        XCTAssertEqual(result.cache, "")
        XCTAssertTrue(result.docs[0].isRemote, "önbellek olmasa da dosya adresleriyle sorulabilir")
    }

    func testFailedCacheExtensionBuildsANewOne() async throws {
        let docs = [doc("a", pages: 10)]
        _ = try await memory.prepare(docs, session: true, progress: noProgress)
        remote.touchFailure = GeminiError("Önbellek bulunamadı.", .http, status: 404)
        let again = try await memory.prepare(docs, session: true, progress: noProgress)
        XCTAssertEqual(again.cache, "cachedContents/c2")
    }

    func testReleaseDeletesTheCache() async throws {
        _ = try await memory.prepare([doc("a", pages: 10)], session: true, progress: noProgress)
        await memory.release()
        XCTAssertEqual(remote.deleted, ["cachedContents/c1"])
        await memory.release()
        XCTAssertEqual(remote.deleted.count, 1, "silinmiş önbellek yeniden silinmez")
    }

    func testFingerprintIsStableAndShort() {
        XCTAssertEqual(GeminiMemory.fingerprint("abc"), GeminiMemory.fingerprint("abc"))
        XCTAssertNotEqual(GeminiMemory.fingerprint("abc"), GeminiMemory.fingerprint("abd"))
        XCTAssertEqual(GeminiMemory.fingerprint("abc").count, 12)
    }
}
