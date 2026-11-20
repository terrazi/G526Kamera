import Foundation

// Gemini "dosya arama" (File Search) deposu: kaynak belgeler buraya bir kez yüklenir, Google parçalara ayırıp dizinler; cevap isteğine yalnız
// deponun adı girer ve model ilgili bölümleri kendisi arar. Depo kalıcıdır (silinene kadar durur); yalnız yüklemenin geçici ham kopyası
// 48 saatte silinir. Adresler ve alan adları Google'ın belgelerindendir (ai.google.dev/gemini-api/docs/file-search, 2026-11-20'de bakıldı).
// Gerçek anahtarla cihazda doğrulanmadı.

extension GeminiSupport {
    /// Depoya yükleme adresi: "https://…/v1beta" + "fileSearchStores/abc" → "https://…/upload/v1beta/fileSearchStores/abc:uploadToFileSearchStore"
    static func storeUploadURL(base: String, store: String) -> String {
        let files = uploadURL(base: base)
        let root = files.hasSuffix("/files") ? String(files.dropLast("/files".count)) : files
        return root + "/" + store + ":uploadToFileSearchStore"
    }

    /// JSON'da sayı da metin de olabilen tam sayı (Google int64 alanlarını metin olarak yollar)
    static func integer(_ value: Any?) -> Int? {
        if let text = value as? String { return Int(text.trimmed) }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    /// Depo listesi cevabı: (ad, görünen ad) çiftleri ve varsa sonraki sayfanın işareti
    static func parseStores(_ json: [String: Any]) -> (stores: [(name: String, title: String)], next: String) {
        let list = (json["fileSearchStores"] as? [[String: Any]]) ?? []
        var stores: [(name: String, title: String)] = []
        for item in list {
            guard let name = (item["name"] as? String)?.trimmed, !name.isEmpty else { continue }
            stores.append((name: name, title: (item["displayName"] as? String) ?? ""))
        }
        return (stores, ((json["nextPageToken"] as? String) ?? "").trimmed)
    }

    /// Belge listesi cevabı: depodaki belgeler ve varsa sonraki sayfanın işareti
    static func parseDocuments(_ json: [String: Any]) -> (documents: [SourceDocument], next: String) {
        let list = (json["documents"] as? [[String: Any]]) ?? []
        var documents: [SourceDocument] = []
        for item in list {
            guard let id = (item["name"] as? String)?.trimmed, !id.isEmpty else { continue }
            documents.append(SourceDocument(id: id,
                                            title: (item["displayName"] as? String) ?? "",
                                            state: ((item["state"] as? String) ?? "STATE_UNSPECIFIED").uppercased(),
                                            bytes: integer(item["sizeBytes"])))
        }
        return (documents, ((json["nextPageToken"] as? String) ?? "").trimmed)
    }

    /// Yükleme işlemi (uzun süren işlem) cevabı: adı, bitti mi, bittiyse hata iletisi (hata yoksa boş)
    static func parseOperation(_ json: [String: Any]) -> (name: String, done: Bool, error: String) {
        let object = (json["operation"] as? [String: Any]) ?? json
        let name = ((object["name"] as? String) ?? "").trimmed
        let done = (object["done"] as? Bool) ?? false
        var error = ""
        if let failure = object["error"] as? [String: Any] {
            let message = ((failure["message"] as? String) ?? "").trimmed
            error = message.isEmpty ? "Google dosyayı işleyemedi" : String(message.prefix(200))
        }
        return (name.contains("operations/") ? name : "", done || !error.isEmpty, error)
    }

    /// Kaynak deposu isteklerinde hata metni: 404 burada "model yok" değil "depo ya da belge yok" demektir
    static func sourceError(status: Int, json: [String: Any]) -> String {
        let message = (((json["error"] as? [String: Any])?["message"] as? String) ?? "").trimmed
        if status == 404 {
            return "Depo ya da belge bulunamadı (404)" + (message.isEmpty ? "." : ": " + String(message.prefix(160)))
        }
        return describeError(status: status, json: json, model: "").1
    }

    /// Cevabın dayandığı kaynak parçaları: belge adı ve o belgeden gelen parça sayısı, çoktan aza (Gemini bunları `groundingMetadata` içinde verir)
    static func sourceUse(from object: Any) -> [(title: String, count: Int)] {
        guard let root = object as? [String: Any],
              let candidate = (root["candidates"] as? [[String: Any]])?.first else { return [] }
        let metadata = (candidate["groundingMetadata"] as? [String: Any]) ?? (candidate["grounding_metadata"] as? [String: Any]) ?? [:]
        let chunks = (metadata["groundingChunks"] as? [[String: Any]]) ?? (metadata["grounding_chunks"] as? [[String: Any]]) ?? []
        var counts: [String: Int] = [:]
        for chunk in chunks {
            let context = (chunk["retrievedContext"] as? [String: Any]) ?? (chunk["retrieved_context"] as? [String: Any]) ?? [:]
            let title = ((context["title"] as? String) ?? "").trimmed
            counts[title.isEmpty ? "adsız belge" : title, default: 0] += 1
        }
        return counts.map { (title: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.title < $1.title }
    }

    /// Günlük satırı: cevap hangi kaynaklara dayandı
    static func sourceUseText(_ use: [(title: String, count: Int)]) -> String {
        if use.isEmpty { return "bu cevapta kaynaklardan parça gelmedi (Gemini kendi bilgisiyle cevapladı)" }
        let total = use.reduce(0) { $0 + $1.count }
        return "cevap \(total) kaynak parçasına dayandı: " + use.map { "\($0.title) ×\($0.count)" }.joined(separator: ", ")
    }
}

/// Yarışan iki işten (istek / süre sınırı) dönen değer
private struct SourceReply: @unchecked Sendable {
    let value: [String: Any]?
}

extension GeminiClient {
    /// Kaynak deposuna tek istek: JSON cevap ya da `GeminiError` (durum koduyla)
    private func sourceCall(_ method: String, _ address: String, key: String, body: Data? = nil) async throws -> [String: Any] {
        let apiKey = key.trimmed
        guard !apiKey.isEmpty else { throw GeminiError("Gemini API anahtarı girilmemiş. Ayarlardan yapıştırın.", .key) }
        guard let url = URL(string: address) else { throw GeminiError("Kaynak deposu adresi geçersiz.", .error) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let result: (data: Data, status: Int)
        do {
            result = try await transport(request, body: body)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw GeminiError("İnternete ulaşılamadı: \(error.localizedDescription)", .network)
        }
        guard (200..<300).contains(result.status) else {
            let message = GeminiSupport.sourceError(status: result.status, json: GeminiSupport.errorObject(from: result.data))
            throw GeminiError(message, result.status == 429 ? .quota : .http, status: result.status)
        }
        return ((try? JSONSerialization.jsonObject(with: result.data)) as? [String: Any]) ?? [:]
    }

    private func pageQuery(_ token: String) -> String {
        if token.isEmpty { return "" }
        return "&pageToken=" + (token.addingPercentEncoding(withAllowedCharacters: GeminiClient.pathAllowed) ?? token)
    }

    /// Kullanılacak depo: kayıtlı depo duruyorsa o; yoksa aynı görünen adlı depo aranır (uygulama yeniden kurulduysa eski depo bulunur);
    /// o da yoksa yenisi açılır
    func sourceStore(saved: String, title: String, key: String) async throws -> String {
        let known = saved.trimmed
        if !known.isEmpty {
            do {
                let json = try await sourceCall("GET", baseURL + "/" + known, key: key)
                let name = ((json["name"] as? String) ?? "").trimmed
                return name.isEmpty ? known : name
            } catch let error as GeminiError where [400, 403, 404].contains(error.status) {
                tlog("[kaynak] kayıtlı depo bulunamadı (\(error.message)); aynı adlı depo aranıyor")
            }
        }
        var token = ""
        var pages = 0
        repeat {
            let parsed = GeminiSupport.parseStores(try await sourceCall("GET", baseURL + "/fileSearchStores?pageSize=20" + pageQuery(token), key: key))
            if let match = parsed.stores.first(where: { $0.title == title }) { return match.name }
            token = parsed.next
            pages += 1
        } while !token.isEmpty && pages < 10
        let body = try JSONSerialization.data(withJSONObject: ["displayName": title])
        let created = try await sourceCall("POST", baseURL + "/fileSearchStores", key: key, body: body)
        guard let name = (created["name"] as? String)?.trimmed, !name.isEmpty else {
            throw GeminiError("Kaynak deposu açıldı ama adı okunamadı.", .error)
        }
        tlog("[kaynak] yeni depo açıldı: \(name)")
        return name
    }

    /// Depodaki bütün belgeler (sayfa sayfa okunur; Google bir sayfada en çok 20 belge verir)
    func sourceDocuments(store: String, key: String) async throws -> [SourceDocument] {
        var all: [SourceDocument] = []
        var token = ""
        var pages = 0
        repeat {
            let address = baseURL + "/" + store + "/documents?pageSize=20" + pageQuery(token)
            let parsed = GeminiSupport.parseDocuments(try await sourceCall("GET", address, key: key))
            all.append(contentsOf: parsed.documents)
            token = parsed.next
            pages += 1
        } while !token.isEmpty && pages < 50
        return all
    }

    /// Belgeyi (parçalarıyla birlikte) depodan siler; zaten yoksa (404) silinmiş sayılır
    func deleteSourceDocument(_ id: String, key: String) async throws {
        do {
            _ = try await sourceCall("DELETE", baseURL + "/" + id + "?force=true", key: key)
        } catch let error as GeminiError where error.status == 404 {
            return
        }
    }

    /// Dosyayı depoya yükler (Files API'deki gibi iki adımlı "resumable" yükleme: önce yükleme adresi istenir, sonra baytlar gönderilir).
    /// Google dosyayı arka planda parçalara ayırıp dizinler; dönen değer bu işlemin adı (cevapta yoksa boş) ve hemen bitip bitmediğidir.
    /// `limit` sn içinde bitmezse `timedOut` işaretli hata verir.
    func uploadSource(_ data: Data, mimeType: String, title: String, store: String, key: String,
                      timeout limit: TimeInterval) async throws -> (name: String, done: Bool, error: String) {
        let reply: SourceReply = try await withThrowingTaskGroup(of: SourceReply.self) { group in
            group.addTask {
                return SourceReply(value: try await self.uploadSourceSteps(data, mimeType: mimeType, title: title, store: store, key: key))
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                return SourceReply(value: nil)
            }
            let first = try await group.next() ?? SourceReply(value: nil)
            group.cancelAll()
            return first
        }
        guard let json = reply.value else {
            var e = GeminiError("Dosya \(Int(limit)) sn içinde yüklenemedi.", .network)
            e.timedOut = true
            throw e
        }
        return GeminiSupport.parseOperation(json)
    }

    private func uploadSourceSteps(_ data: Data, mimeType: String, title: String, store: String, key: String) async throws -> [String: Any] {
        let apiKey = key.trimmed
        guard !apiKey.isEmpty else { throw GeminiError("Gemini API anahtarı girilmemiş. Ayarlardan yapıştırın.", .key) }
        guard let startURL = URL(string: GeminiSupport.storeUploadURL(base: baseURL, store: store)) else {
            throw GeminiError("Yükleme adresi geçersiz.", .error)
        }
        var start = URLRequest(url: startURL)
        start.httpMethod = "POST"
        start.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        start.setValue(String(data.count), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        start.setValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let meta = try JSONSerialization.data(withJSONObject: ["displayName": title, "mimeType": mimeType])
        let first: (data: Data, status: Int, headers: [String: String])
        do {
            first = try await transportFull(start, body: meta)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw GeminiError("Yükleme başlatılamadı: \(error.localizedDescription)", .network)
        }
        guard (200..<300).contains(first.status) else {
            let message = GeminiSupport.sourceError(status: first.status, json: GeminiSupport.errorObject(from: first.data))
            throw GeminiError("Yükleme başlatılamadı: \(message)", first.status == 429 ? .quota : .http, status: first.status)
        }
        guard let target = first.headers["x-goog-upload-url"]?.trimmed, !target.isEmpty, let uploadURL = URL(string: target) else {
            throw GeminiError("Yükleme adresi gelmedi.", .error, status: first.status)
        }
        var send = URLRequest(url: uploadURL)
        send.httpMethod = "POST"
        send.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        send.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        send.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        send.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        let second: (data: Data, status: Int, headers: [String: String])
        do {
            second = try await transportFull(send, body: data)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw GeminiError("Dosya yüklenemedi: \(error.localizedDescription)", .network)
        }
        guard (200..<300).contains(second.status) else {
            let message = GeminiSupport.sourceError(status: second.status, json: GeminiSupport.errorObject(from: second.data))
            throw GeminiError("Dosya yüklenemedi: \(message)", second.status == 429 ? .quota : .http, status: second.status)
        }
        return ((try? JSONSerialization.jsonObject(with: second.data)) as? [String: Any]) ?? [:]
    }

    /// Yükleme işlemi bitene kadar (en çok `limit` sn) `pause` sn arayla sorar. nil: bitti ya da durumu öğrenilemedi (son durum depo
    /// listesinden okunur); metin: Google'ın hata iletisi
    func waitForSourceOperation(_ name: String, key: String, limit: TimeInterval, every pause: TimeInterval = 3) async -> String? {
        guard !name.isEmpty else { return nil }
        var waited: TimeInterval = 0
        while waited < limit {
            await sleep(pause)
            waited += pause
            if Task.isCancelled { return nil }
            guard let json = try? await sourceCall("GET", baseURL + "/" + name, key: key) else { return nil }
            let parsed = GeminiSupport.parseOperation(json)
            if parsed.done { return parsed.error.isEmpty ? nil : parsed.error }
        }
        return nil
    }
}
