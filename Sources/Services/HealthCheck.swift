import Foundation

/// Gemini sunucusuna anahtarlı hafif bir istek sonucu
enum GeminiHealth: Equatable {
    case ok
    /// Sunucuya ulaşıldı ama anahtar kabul edilmedi (mesaj Google'dan)
    case keyRejected(String)
    /// Sunucuya ulaşılamadı ya da sunucu hata verdi
    case unreachable(String)
}

/// Modül 1 (donanım kontrolü) ve Modül 4 (onarım doğrulaması): internet ve Gemini sağlığı
@MainActor
protocol HealthChecking: AnyObject {
    /// Genel internet var mı (küçük "204" adreslerine istek)
    func internetReachable() async -> Bool
    /// Gemini'ye anahtarla ping (model listesinin ilk sayfası; belirteç harcamaz)
    func gemini(key: String) async -> GeminiHealth
    /// Nabız: tek hafif yoklama (en çok ~3 sn); yol şu an canlı mı. Gemini anahtarına dokunmaz.
    func quickProbe() async -> Bool
    /// Telefonda hücresel hizmet (SIM/eSIM) var mı. Yoksa hücresel/sıfırlama Kestirmeleri internet getiremez (Wi-Fi'yi kapatırlar).
    func hasCellularService() -> Bool
}

extension HealthChecking {
    /// Varsayılan: var sayılır (yanlışlıkla "yok" demektense eski davranış korunur)
    func hasCellularService() -> Bool { return true }

    /// Onarım doğrulaması: internet var ve Gemini'ye ulaşılıyor (anahtar sorunu bağlantı sorunu değildir)
    func connectionHealthy(key: String) async -> Bool {
        guard await internetReachable() else { return false }
        if case .unreachable = await gemini(key: key) { return false }
        return true
    }
}

@MainActor
final class NetworkHealth: HealthChecking {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session = session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.waitsForConnectivity = false
            config.timeoutIntervalForRequest = 12
            self.session = URLSession(configuration: config)
        }
    }

    func internetReachable() async -> Bool {
        return await InternetProbe.isOnline()
    }

    func quickProbe() async -> Bool {
        return await InternetProbe.quick()
    }

    private var lastCellular: Bool?

    func hasCellularService() -> Bool {
        let status = CellularService.status()
        // Sık sorulur (nabız, her soru sınırı): günlüğe yalnız değişince yazılır
        if lastCellular != status.available {
            lastCellular = status.available
            tlog("[sistem] hücresel hizmet: \(status.available ? "var" : "yok (SIM kart yok)") (\(status.detail))")
        }
        return status.available
    }

    func gemini(key: String) async -> GeminiHealth {
        let secret = key.trimmed
        guard !secret.isEmpty else { return .keyRejected(Say.noKeyShort) }
        guard let url = URL(string: GeminiConfig.baseURL + "/models?pageSize=1") else { return .unreachable("adres geçersiz") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(secret, forHTTPHeaderField: "x-goog-api-key")
        do {
            // Telefon kameranın Wi-Fi'sindeyse önce hücresel yoldan (kısa süreli: sağlık yoklaması)
            let quick = CellularHTTP.Options(connectTimeout: 8, idleTimeout: 12, totalTimeout: 12)
            let result = try await GeminiTransport.send(request, body: nil, session: session, viaCellular: CellularRoute.shouldUse(),
                                                        cellular: { req, body in try await CellularHTTP.perform(req, body: body, options: quick) })
            return NetworkHealth.classify(status: result.status, data: result.data)
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    /// HTTP durumunu sağlığa çevirir. 429 (kota) sunucuya ulaşıldığını gösterir; 5xx ve anlaşılmaz yanıt ulaşılamadı sayılır.
    static func classify(status: Int, data: Data) -> GeminiHealth {
        switch status {
        case 200..<300, 429:
            return .ok
        case 400, 401, 403:
            let (_, message) = GeminiSupport.describeError(status: status, json: GeminiSupport.errorObject(from: data), model: "")
            return .keyRejected(message)
        default:
            return .unreachable("HTTP \(status)")
        }
    }
}
