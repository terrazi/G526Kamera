import Foundation

/// Google Drive v3: uygulamanın kendi klasörünü bulur/oluşturur ve JPEG yükler (drive.file kapsamı).
final class DriveClient {
    private let auth: GoogleAuth
    private let settings = AppSettings.shared
    private let filesURL = "https://www.googleapis.com/drive/v3/files"
    private let uploadURL = "https://www.googleapis.com/upload/drive/v3/files"
    private let resolvedNameKey = "driveFolderResolvedName"

    init(auth: GoogleAuth) {
        self.auth = auth
    }

    private func authorized(_ make: (String) -> URLRequest, body: Data? = nil) async throws -> (Int, Data) {
        var token = try await auth.accessToken()
        var attempt = 0
        while true {
            let request = make(token)
            let (status, data) = try await Http.send(request, body: body)
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

    /// JPEG'i klasöre yükler, dosya kimliğini döndürür.
    @discardableResult
    func upload(jpeg: Data, name: String) async throws -> String {
        var folder = try await ensureFolder()
        var attempt = 0
        while true {
            let boundary = "g526-" + UUID().uuidString
            let metaObject: [String: Any] = ["name": name, "parents": [folder], "mimeType": "image/jpeg"]
            let meta = try JSONSerialization.data(withJSONObject: metaObject)
            var body = Data()
            body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
            body.append(meta)
            body.append(Data("\r\n--\(boundary)\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
            body.append(jpeg)
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))

            let url = URL(string: uploadURL + "?uploadType=multipart&fields=id")!
            let (status, data) = try await authorized({ token in
                var r = URLRequest(url: url)
                r.httpMethod = "POST"
                r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                r.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                return r
            }, body: body)

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
