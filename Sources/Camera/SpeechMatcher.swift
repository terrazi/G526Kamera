import Foundation
import Speech
import AVFoundation

/// Türkçe sesli komut eşleştirme (konuşma tanıma çıktısı ile tetikleme sözcüğü).
enum SpeechMatcher {
    static let turkish = Locale(identifier: "tr_TR")

    /// Küçük harfe çevirir, Türkçe harfleri sadeleştirir ve sözcüklere böler.
    static func words(_ text: String) -> [String] {
        var s = text.lowercased(with: turkish)
        s = s.folding(options: [.diacriticInsensitive], locale: turkish)
        s = s.replacingOccurrences(of: "ı", with: "i")
        var result: [String] = []
        var current = ""
        for scalar in s.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Virgülle ayrılmış tetikleme sözcükleri; "okey" için yaygın yazılışlar da eklenir.
    static func patterns(for trigger: String) -> [[String]] {
        var result: [[String]] = []
        for part in trigger.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let w = words(String(part))
            if w.isEmpty { continue }
            result.append(w)
            if w == ["okey"] {
                result.append(["okay"])
                result.append(["oke"])
                result.append(["ok"])
            }
        }
        return result
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a)
        let y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[y.count]
    }

    /// `loose`: 3 harfli kısa sözcükler (sol, sağ) için, aynı harfle başlayan ve 1 harf farklı 2–4 harfli
    /// duyumlar da kabul edilir ("so", "sor", "sa", "sak"). Yalnızca soru bekleniyorken açılır.
    static func wordMatches(_ heard: String, _ target: String, loose: Bool = false) -> Bool {
        if heard == target { return true }
        if loose, target.count == 3, heard.count >= 2, heard.count <= 4, heard.first == target.first {
            return distance(heard, target) <= 1
        }
        if min(heard.count, target.count) < 4 { return false }
        return distance(heard, target) <= 1
    }

    /// Seçim sözcükleri (sol, soldaki, sağa…): metinde kümedeki sözcüklerden kaç tane geçtiği.
    /// 5+ harfli sözcüklerde 1 harf fark, `loose` iken `looseTokens` için kısa/bozuk duyumlar kabul edilir.
    static func tokenOccurrences(in transcript: String, tokens: [String], looseTokens: [String], loose: Bool) -> Int {
        var count = 0
        for w in words(transcript) {
            var hit = false
            for t in tokens {
                if w == t || (t.count >= 5 && w.count >= 5 && distance(w, t) <= 1) {
                    hit = true
                    break
                }
            }
            if !hit && loose {
                for t in looseTokens where wordMatches(w, t, loose: true) {
                    hit = true
                    break
                }
            }
            if hit { count += 1 }
        }
        return count
    }

    /// Metnin SON sözcüğü verilen sözcüklerden biri mi ("… tamam"): "dinle … tamam" kaydını bitirir.
    /// Sözcükler `words` biçimindedir (küçük harf, aksansız, ı→i); "tamamdır" için "tamamdir" verilir.
    static func endsWith(_ transcript: String, words targets: [String]) -> Bool {
        guard let last = words(transcript).last else { return false }
        // Tam eşleşme: "tamamı", "tamamen" gibi sözcükler kaydı bitirmesin
        return targets.contains(last)
    }

    /// Metinde tetikleme sözcüğünün kaç kez geçtiği.
    static func occurrences(in transcript: String, trigger: String, loose: Bool = false) -> Int {
        let heard = words(transcript)
        let pats = patterns(for: trigger)
        if heard.isEmpty || pats.isEmpty { return 0 }
        var count = 0
        var i = 0
        while i < heard.count {
            var matched = 0
            for p in pats where i + p.count <= heard.count {
                var ok = true
                for k in 0..<p.count where !wordMatches(heard[i + k], p[k], loose: loose && p.count == 1) {
                    ok = false
                    break
                }
                if ok { matched = max(matched, p.count) }
            }
            if matched > 0 {
                count += 1
                i += matched
            } else {
                i += 1
            }
        }
        return count
    }
}

/// Esnek komut anlama: aynı niyeti anlatan çok sayıda söyleniş ("hepsini gönder", "tümünü gönder",
/// "pdf yap", "çekimler tamam", "bitirdim"…) tek tek sayılmak yerine sözcük gruplarıyla yakalanır.
/// Tüm sözcükler `SpeechMatcher.words` biçimindedir (küçük harf, aksansız, ı→i).
struct SpeechIntent {
    /// Tek başına yeterli sözcükler ("gönder", "bitirdim", "tamamlandı")
    var strong: Set<String>
    /// Bağlam sözcükleri ("hepsi", "tümü", "sayfalar", "pdf"…)
    var scope: Set<String>
    /// Yalnızca yakınında bir bağlam sözcüğü varsa yeten sözcükler ("tamam", "yap", "çevir"…)
    var weak: Set<String>
    /// Bağlam sözcüğü en çok kaç sözcük uzakta olabilir
    var window = 5

    private func hit(_ word: String, _ set: Set<String>) -> Bool {
        if set.contains(word) { return true }
        if word.count >= 6 {
            for t in set where t.count >= 6 && SpeechMatcher.distance(word, t) <= 1 { return true }
        }
        return false
    }

    func count(in transcript: String) -> Int {
        let w = SpeechMatcher.words(transcript)
        var n = 0
        for i in w.indices {
            if hit(w[i], strong) {
                n += 1
                continue
            }
            if hit(w[i], weak) {
                let lo = max(0, i - window)
                let hi = min(w.count - 1, i + window)
                var found = false
                for j in lo...hi where j != i && hit(w[j], scope) {
                    found = true
                    break
                }
                if found { n += 1 }
            }
        }
        return n
    }
}
