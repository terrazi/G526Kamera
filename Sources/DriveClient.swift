import Foundation

/// Yüklenecek içerik: tek bir JPEG dosyası ya da bir veya birkaç JPEG'den yapılan PDF.
enum UploadPayload {
    case jpeg(URL)
    case pdf([URL], title: String, texts: [String])

    var mime: String {
        switch self {
        case .jpeg: return "image/jpeg"
        case .pdf: return "application/pdf"
        }
    }
}

/// Google Drive v3: uygulamanın kendi klasörünü bulur/oluşturur ve JPEG/PDF yükler (drive.file kapsamı).
final class DriveClient {
    private let auth: GoogleAuth
    private let settings = AppSettings.shared
    private let filesURL = "https://www.googleapis.com/drive/v3/files"
    private let uploadURL = "https://www.googleapis.com/upload/drive/v3/files"
    private let resolvedNameKey = "driveFolderResolvedName"

    init(auth: GoogleAuth) {
        self.auth = auth
    }

    private func authorized(_ make: (String) -> URLRequest, body: Data? = nil, bodyFile: URL? = nil) async throws -> (Int, Data) {
        var token = try await auth.accessToken()
        var attempt = 0
        while true {
            let request = make(token)
            let (status, data) = try await Http.send(request, body: body, bodyFile: bodyFile)
            if status == 401 && attempt == 0 {
                attempt += 1
                token = try await auth.accessToken(forceRefresh: true)
                continue
            }
            return (status, data)
        }
    }

    private static func errorMessage(_ data: Data) -> String {
        let json = Http.jsonObject(data)
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return String(data: data.prefix(200), encoding: .utf8) ?? ""
    }

    private var folderName: String {
        let name = settings.driveFolderName.trimmed
        return name.isEmpty ? "G526 Belgeler" : name
    }

    private func rememberFolder(id: String, name: String) async {
        await MainActor.run {
            self.settings.driveFolderID = id
        }
        UserDefaults.standard.set(name, forKey: resolvedNameKey)
    }

    private func forgetFolder() async {
        await MainActor.run {
            self.settings.driveFolderID = ""
        }
        UserDefaults.standard.removeObject(forKey: resolvedNameKey)
    }

    /// Klasörün kimliğini döndürür; yoksa oluşturur.
    @discardableResult
    func ensureFolder() async throws -> String {
        let name = folderName
        let known = settings.driveFolderID
        if !known.isEmpty && UserDefaults.standard.string(forKey: resolvedNameKey) == name {
            return known
        }

        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        var components = URLComponents(string: filesURL)!
        components.queryItems = [
            URLQueryItem(name: "q", value: "name = '\(escaped)' and mimeType = 'application/vnd.google-apps.folder' and trashed = false"),
            URLQueryItem(name: "fields", value: "files(id,name)"),
            URLQueryItem(name: "spaces", value: "drive"),
            URLQueryItem(name: "pageSize", value: "10")
        ]
        let searchURL = components.url!
        let (status, data) = try await authorized({ token in
            var r = URLRequest(url: searchURL)
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return r
        })
        guard (200..<300).contains(status) else {
            throw DriveError.http(status, DriveClient.errorMessage(data))
        }
        if let files = Http.jsonObject(data)["files"] as? [[String: Any]],
           let id = files.first?["id"] as? String {
            await rememberFolder(id: id, name: name)
            return id
        }

        let createBody: [String: Any] = ["name": name, "mimeType": "application/vnd.google-apps.folder"]
        let payload = try JSONSerialization.data(withJSONObject: createBody)
        let createURL = URL(string: filesURL + "?fields=id")!
        let (cStatus, cData) = try await authorized({ token in
            var r = URLRequest(url: createURL)
            r.httpMethod = "POST"
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            r.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            return r
        }, body: payload)
        guard (200..<300).contains(cStatus), let id = Http.jsonObject(cData)["id"] as? String else {
            throw DriveError.http(cStatus, DriveClient.errorMessage(cData))
        }
        await rememberFolder(id: id, name: name)
        return id
    }

    /// multipart/related gövdesini bir dosyaya yazar. PDF ve JPEG içerik doğrudan dosyaya akıtılır:
    /// bellekte tüm gövde tutulmaz ve ana iş parçacığı kullanılmaz.
    private static func buildBody(payload: UploadPayload, name: String, folder: String, boundary: String, to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let metaObject: [String: Any] = ["name": name, "parents": [folder], "mimeType": payload.mime]
        let meta = try JSONSerialization.data(withJSONObject: metaObject)
        try handle.write(contentsOf: Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        try handle.write(contentsOf: meta)
        try handle.write(contentsOf: Data("\r\n--\(boundary)\r\nContent-Type: \(payload.mime)\r\n\r\n".utf8))
        switch payload {
        case .jpeg(let file):
            let source = try FileHandle(forReadingFrom: file)
            defer { try? source.close() }
            while true {
                guard let chunk = try source.read(upToCount: 256 * 1024), !chunk.isEmpty else { break }
                try handle.write(contentsOf: chunk)
            }
        case .pdf(let files, let title, let texts):
            try PDFWrap.write(jpegs: files, title: title, texts: texts, to: handle)
        }
        try handle.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
    }

    /// Klasöre yükler, dosya kimliğini döndürür.
    @discardableResult
    func upload(_ payload: UploadPayload, name: String) async throws -> String {
        var folder = try await ensureFolder()
        var attempt = 0
        while true {
            let boundary = "g526-" + UUID().uuidString
            let bodyURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("g526-yukleme-\(UUID().uuidString).govde")
            defer { try? FileManager.default.removeItem(at: bodyURL) }

            let folderID = folder
            try await Task.detached(priority: .utility) {
                try DriveClient.buildBody(payload: payload, name: name, folder: folderID, boundary: boundary, to: bodyURL)
            }.value

            let url = URL(string: uploadURL + "?uploadType=multipart&fields=id")!
            let (status, data) = try await authorized({ token in
                var r = URLRequest(url: url)
                r.httpMethod = "POST"
                r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                r.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                return r
            }, bodyFile: bodyURL)

            if (200..<300).contains(status) {
                return Http.jsonObject(data)["id"] as? String ?? ""
            }
            if status == 404 && attempt == 0 {
                // Klasör silinmiş olabilir: yeniden oluştur ve bir kez daha dene
                attempt += 1
                await forgetFolder()
                folder = try await ensureFolder()
                continue
            }
            throw DriveError.http(status, DriveClient.errorMessage(data))
        }
    }
}
