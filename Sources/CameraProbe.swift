import Foundation

/// Kameranın hangi bilgileri verdiğini (özellikle pil / şarj) aramak için gönderilen YALNIZ OKUMA komutları.
/// Ayar değiştiren (Set…, Open…) komut yoktur. Bilinmeyen bir komuta kamera cevap vermezse "cevap yok" yazılır.
enum CameraProbe {
    /// LookCam'in kullandığı okuma komutları (cevaplarında LookCam'in çözmediği ek alanlar olabilir)
    static let known = ["GetDevInfo", "GetDevExInfo", "GetDevVideoInfo", "GetDevStream", "GetCloseTime",
                        "GetLedInfo", "GetPTZLight", "GetAlarmInfo", "GetDevTfParam"]
    /// Pil / durum için tahmin edilen adlar
    static let guesses = ["GetBattery", "GetBatteryInfo", "GetBatteryLevel", "GetBat", "GetBatInfo", "GetDevBattery",
                          "GetPower", "GetPowerInfo", "GetDevPower", "GetElectric", "GetElectricity",
                          "GetCharge", "GetChargeInfo", "GetDevStatus", "GetDevState", "GetStatus",
                          "GetSysInfo", "GetDevAllInfo", "GetNetInfo", "Get4GInfo"]
    static var all: [String] { return known + guesses }

    /// Anahtar adında bunlardan biri geçen alanlar pil / güç ile ilgili olabilir
    static let hintWords = ["bat", "power", "elec", "charg", "chg", "volt", "level", "percent", "dianliang", "soc"]

    static func hints(in reply: [String: Any]) -> [String] {
        var out: [String] = []
        for (key, value) in reply.sorted(by: { $0.key < $1.key }) where key != "cmd" {
            let k = key.lowercased()
            if hintWords.contains(where: { k.contains($0) }) { out.append("\(key)=\(value)") }
        }
        return out
    }

    static func compact(_ reply: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "\(reply)" }
        return text
    }

    /// Ekranda gösterilecek tek satır
    static func format(name: String, reply: [String: Any]?) -> String {
        guard let reply = reply else { return "\(name): cevap yok" }
        let found = hints(in: reply)
        let mark = found.isEmpty ? "" : "  ◀ OLASI PİL/GÜÇ: " + found.joined(separator: ", ")
        return "\(name): " + compact(reply) + mark
    }

    /// Sonuç özeti: pil / şarj ile ilgili olabilecek bir alan bulundu mu
    static func summary(lines: [String]) -> String {
        let hit = lines.contains { $0.contains("OLASI PİL/GÜÇ") }
        return hit ? "Pil ya da güçle ilgili olabilecek alan bulundu (◀ ile işaretli)."
                   : "Kameranın cevaplarında pil / şarj alanı bulunamadı."
    }
}
