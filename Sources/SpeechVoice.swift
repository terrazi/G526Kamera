import Foundation
import AVFoundation

/// Telefonda kurulu bir konuşma sesinin özeti (seçim mantığı bu yapı üzerinde çalışır, böylece sınanabilir).
struct VoiceInfo: Equatable {
    let id: String
    let name: String
    let language: String
    /// 0 = standart (kompakt), 1 = gelişmiş (Enhanced), 2 = Premium
    let rank: Int

    var qualityLabel: String {
        switch rank {
        case 2...: return "Premium"
        case 1: return "Gelişmiş"
        default: return "Standart"
        }
    }

    var title: String { return "\(name) · \(qualityLabel)" }
}

/// Okuma sesini seçer: kullanıcı seçtiyse onu, seçmediyse telefonda kurulu en kaliteli Türkçe sesi kullanır.
enum SpeechVoiceChooser {
    /// `AVSpeechSynthesisVoiceQuality` ham değerleri: default 1, enhanced 2, premium 3 (iOS 16 ve sonrası)
    static func rank(forQualityRawValue raw: Int) -> Int {
        return max(0, min(2, raw - 1))
    }

    /// Türkçe sesler, en kaliteli önce; aynı kalitede ada göre sıralı.
    static func sortedTurkish(_ all: [VoiceInfo]) -> [VoiceInfo] {
        return all
            .filter { $0.language.lowercased().hasPrefix("tr") }
            .sorted { a, b in
                if a.rank != b.rank { return a.rank > b.rank }
                return a.name.localizedCompare(b.name) == .orderedAscending
            }
    }

    /// Kullanıcının seçtiği ses kuruluysa o; değilse (ya da "Otomatik" ise) en kaliteli Türkçe ses.
    static func best(from all: [VoiceInfo], preferredID: String) -> VoiceInfo? {
        let turkish = sortedTurkish(all)
        if !preferredID.isEmpty, let chosen = turkish.first(where: { $0.id == preferredID }) { return chosen }
        return turkish.first
    }

    static func installed() -> [VoiceInfo] {
        return AVSpeechSynthesisVoice.speechVoices().map {
            VoiceInfo(id: $0.identifier, name: $0.name, language: $0.language,
                      rank: rank(forQualityRawValue: $0.quality.rawValue))
        }
    }

    /// Okumada kullanılacak ses; Türkçe ses hiç yoksa nil (sistem varsayılanına bırakılır).
    static func voice(preferredID: String) -> AVSpeechSynthesisVoice? {
        if let info = best(from: installed(), preferredID: preferredID),
           let voice = AVSpeechSynthesisVoice(identifier: info.id) {
            return voice
        }
        return AVSpeechSynthesisVoice(language: "tr-TR")
    }

    /// Ayarlar ekranında "şu an kullanılan" satırı için
    static func currentDescription(preferredID: String) -> String {
        guard let info = best(from: installed(), preferredID: preferredID) else { return "Türkçe ses bulunamadı" }
        return info.title
    }
}
