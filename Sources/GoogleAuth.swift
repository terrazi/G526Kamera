import Foundation

enum DriveError: LocalizedError {
    case missingClient
    case notSignedIn
    case auth(String)
    case http(Int, String)
    case network(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingClient: return "Google istemci kimliği / sırrı girilmemiş."
        case .notSignedIn: return "Google Drive'a giriş yapılmamış."
        case .auth(let m): return m
        case .http(let code, let m): return "Drive hatası (\(code)): \(m)"
        case .network(let m): return "Ağ hatası: \(m)"
        case .badResponse: return "Google'dan beklenmeyen yanıt geldi."
        }
    }
}

extension String {
    var trimmed: String { return trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Küçük HTTP yardımcıları.
enum Http {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.waitsForConnectivity = false
        c.timeoutIntervalForRequest = 45
        c.timeoutIntervalForResource = 240
        return URLSession(configuration: c)
    }()

    private static let allowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func formEncode(_ params: [String: String]) -> Data {
        let text = params.keys.sorted().map { key -> String in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = (params[key] ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(k)=\(v)"
        }.joined(separator: "&")
        return Data(text.utf8)
    }

    static func jsonObject(_ data: Data) -> [String: Any] {
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    static func send(_ request: URLRequest, body: Data? = nil) async throws -> (Int, Data) {
        do {
            let result: (Data, URLResponse)
            if let body = body {
                result = try await session.upload(for: request, from: body)
            } else {
                result = try await session.data(for: request)
            }
            let (data, response) = result
            guard let http = response as? HTTPURLResponse else { throw DriveError.badResponse }
            return (http.statusCode, data)
        } catch let error as DriveError {
            throw error
        } catch {
            throw DriveError.network(error.localizedDescription)
        }
    }

    static func postForm(_ url: String, _ params: [String: String]) async throws -> (Int, [String: Any]) {
        guard let u = URL(string: url) else { throw DriveError.badResponse }
        var request = URLRequest(url: u)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (status, data) = try await send(request, body: formEncode(params))
        return (status, jsonObject(data))
    }
}

/// Google OAuth "cihaz akışı": uygulamaya parola yazılmaz. Telefonda (veya başka bir cihazda)
/// google.com/device sayfasına kod girilir; uygulama yalnızca yenileme jetonunu Keychain'de saklar.
@MainActor
final class GoogleAuth: ObservableObject {
    static let shared = GoogleAuth()

    enum Phase: Equatable {
        case signedOut
        case waiting(code: String, url: String)
        case signedIn
    }

    @Published private(set) var phase: Phase
    @Published private(set) var email: String
    @Published private(set) var message = ""

    private let settings = AppSettings.shared
    private let refreshKey = "googleRefreshToken"
    private let tokenURL = "https://oauth2.googleapis.com/token"
    private var cachedToken: String?
    private var expiry = Date.distantPast
    private var signInTask: Task<Void, Never>?
    private var refreshTask: Task<String, Error>?

    var isSignedIn: Bool { return phase == .signedIn }

    init() {
        if Keychain.get("googleRefreshToken") != nil {
            phase = .signedIn
        } else {
            phase = .signedOut
        }
        email = UserDefaults.standard.string(forKey: "googleEmail") ?? ""
    }

    // MARK: - Giriş

    func startSignIn() {
        cancelSignIn()
        let id = settings.googleClientID.trimmed
        let secret = settings.googleClientSecret.trimmed
        guard !id.isEmpty, !secret.isEmpty else {
            message = "Önce İstemci Kimliği ve İstemci Sırrı girin."
            return
        }
        message = "Google'dan kod isteniyor…"
        signInTask = Task { [weak self] in
            guard let self = self else { return }
            await self.runSignIn(id: id, secret: secret)
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        if case .waiting = phase {
            phase = Keychain.get(refreshKey) != nil ? .signedIn : .signedOut
            message = ""
        }
    }

    private func runSignIn(id: String, secret: String) async {
        do {
            let (status, json) = try await Http.postForm("https://oauth2.googleapis.com/device/code",
                                                         ["client_id": id,
                                                          "scope": "https://www.googleapis.com/auth/drive.file email"])
            guard status == 200,
                  let device = json["device_code"] as? String,
                  let user = json["user_code"] as? String else {
                message = GoogleAuth.describe(json, status: status)
                return
            }
            let url = (json["verification_url"] as? String) ?? "https://www.google.com/device"
            let interval = (json["interval"] as? Int) ?? 5
            let expires = (json["expires_in"] as? Int) ?? 1800
            if Task.isCancelled { return }
            phase = .waiting(code: user, url: url)
            message = "Kodu Google sayfasına girip izin verin."
            await poll(id: id, secret: secret, device: device, interval: interval, expires: expires)
        } catch {
            if Task.isCancelled { return }
            message = error.localizedDescription
        }
    }

    private func poll(id: String, secret: String, device: String, interval: Int, expires: Int) async {
        var wait = max(interval, 5)
        let deadline = Date().addingTimeInterval(TimeInterval(expires))
        while !Task.isCancelled && Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
            if Task.isCancelled { return }
            do {
                let (status, json) = try await Http.postForm(tokenURL, [
                    "client_id": id,
                    "client_secret": secret,
                    "device_code": device,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
                ])
                if status == 200, let access = json["access_token"] as? String {
                    accept(json: json, access: access)
                    phase = .signedIn
                    message = "Giriş yapıldı."
                    await fetchEmail()
                    return
                }
                let code = json["error"] as? String ?? ""
                switch code {
                case "authorization_pending":
                    continue
                case "slow_down":
                    wait += 5
                default:
                    message = GoogleAuth.describe(json, status: status)
                    phase = Keychain.get(refreshKey) != nil ? .signedIn : .signedOut
                    return
                }
            } catch {
                message = "Ağ hatası, tekrar deneniyor… (\(error.localizedDescription))"
            }
        }
        if !Task.isCancelled {
            message = "Kodun süresi doldu. Yeniden giriş başlatın."
            phase = Keychain.get(refreshKey) != nil ? .signedIn : .signedOut
        }
    }

    private func accept(json: [String: Any], access: String) {
        cachedToken = access
        let seconds = (json["expires_in"] as? Double) ?? 3600
        expiry = Date().addingTimeInterval(max(60, seconds - 90))
        if let refresh = json["refresh_token"] as? String, !refresh.isEmpty {
            Keychain.set(refresh, for: refreshKey)
        }
    }

    private func fetchEmail() async {
        guard let token = cachedToken, let url = URL(string: "https://www.googleapis.com/oauth2/v3/userinfo") else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let (status, data) = try? await Http.send(request), status == 200,
           let mail = Http.jsonObject(data)["email"] as? String {
            email = mail
            UserDefaults.standard.set(mail, forKey: "googleEmail")
        }
    }

    func signOut() {
        signInTask?.cancel()
        signInTask = nil
        let refresh = Keychain.get(refreshKey)
        Keychain.remove(refreshKey)
        cachedToken = nil
        expiry = .distantPast
        email = ""
        UserDefaults.standard.removeObject(forKey: "googleEmail")
        phase = .signedOut
        message = "Çıkış yapıldı."
        if let refresh = refresh {
            Task { _ = try? await Http.postForm("https://oauth2.googleapis.com/revoke", ["token": refresh]) }
        }
    }

    // MARK: - Erişim jetonu

    func accessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let token = cachedToken, Date() < expiry { return token }
        guard let refresh = Keychain.get(refreshKey) else { throw DriveError.notSignedIn }
        if let running = refreshTask { return try await running.value }

        let id = settings.googleClientID.trimmed
        let secret = settings.googleClientSecret.trimmed
        guard !id.isEmpty, !secret.isEmpty else { throw DriveError.missingClient }

        let task = Task<String, Error> { [weak self] in
            guard let self = self else { throw DriveError.notSignedIn }
            return try await self.refresh(id: id, secret: secret, refresh: refresh)
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func refresh(id: String, secret: String, refresh: String) async throws -> String {
        let (status, json) = try await Http.postForm(tokenURL, [
            "client_id": id,
            "client_secret": secret,
            "refresh_token": refresh,
            "grant_type": "refresh_token"
        ])
        if status == 200, let access = json["access_token"] as? String {
            accept(json: json, access: access)
            return access
        }
        if (json["error"] as? String) == "invalid_grant" {
            Keychain.remove(refreshKey)
            cachedToken = nil
            phase = .signedOut
            message = "Google oturumu sona erdi. Yeniden giriş yapın."
            throw DriveError.notSignedIn
        }
        throw DriveError.auth(GoogleAuth.describe(json, status: status))
    }

    // MARK: - Hata metinleri

    nonisolated static func describe(_ json: [String: Any], status: Int) -> String {
        let code = json["error"] as? String ?? ""
        let detail = json["error_description"] as? String ?? ""
        switch code {
        case "invalid_client":
            return "İstemci kimliği veya sırrı hatalı. İstemci türü “TV ve Sınırlı Girişli Cihazlar” olmalı."
        case "invalid_scope", "invalid_request":
            return "Google isteği reddetti (\(code)). Drive API'nin açık olduğunu ve istemci türünü kontrol edin. \(detail)"
        case "access_denied":
            return "Erişim reddedildi. İzin ekranında “İzin ver”e dokunduğunuzdan emin olun."
        case "expired_token":
            return "Kodun süresi doldu. Yeniden giriş başlatın."
        case "":
            return "Google'dan beklenmeyen yanıt (\(status))."
        default:
            return "Google hatası: \(code) \(detail)"
        }
    }
}
