import Foundation

/// Sesle model seçimi için model listesi süzgeci ve söylenişleri (Windows sürümündeki gemini.py'nin choosable_models / spoken_model karşılığı)
enum ModelChoice {
    static let ordinals = ["birinci", "ikinci", "üçüncü", "dördüncü", "beşinci", "altıncı", "yedinci"]
    static let ordinalsCap = ["Birinci", "İkinci", "Üçüncü", "Dördüncü", "Beşinci", "Altıncı", "Yedinci"]
    static let maxChoices = 7
    private static let families = ["pro", "flash", "flash-lite", "gemma"]

    private static let skip = try! NSRegularExpression(
        pattern: "(tts|embed|image|imagen|veo|live|audio|aqa|robotics|computer|learnlm|vision|banana|lyria|guard|translate|speech)",
        options: [.caseInsensitive])
    private static let geminiName = try! NSRegularExpression(pattern: "^gemini-(\\d+(?:\\.\\d+)*)-(pro|flash-lite|flash)(?:-(.+))?$")
    private static let gemmaName = try! NSRegularExpression(pattern: "^gemma-(\\d+)-(.+)-it$")

    private static func match(_ re: NSRegularExpression, _ s: String) -> [String?]? {
        let range = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: range) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            guard r.location != NSNotFound, let rr = Range(r, in: s) else { return nil }
            return String(s[rr])
        }
    }

    private static func matches(_ pattern: String, _ s: String) -> Bool {
        return s.range(of: pattern, options: .regularExpression) != nil
    }

    /// [3, 8] < [3, 10]; eksik basamak daha küçük sayılır (Python demet karşılaştırması gibi)
    private static func less(_ a: [Int], _ b: [Int]) -> Bool {
        for (x, y) in zip(a, b) where x != y { return x < y }
        return a.count < b.count
    }

    /// Sesle seçilecek modeller: yalnız metin üreten Gemini (pro / flash / flash-lite) ve Gemma modelleri; ses, görsel, gömme, canlı vb.
    /// dışarıda. Her aileden en yeni 2 sürüm, kararlı sürüm önizlemeden önce. Sıra: pro, flash, flash-lite, gemma. En çok `limit` ad.
    static func choosable(_ models: [String], limit: Int = maxChoices) -> [String] {
        // aile -> sürüm -> (kararlı mı, ad uzunluğu, ad)
        var fam: [String: [[Int]: (stable: Int, len: Int, name: String)]] = [:]
        for f in families { fam[f] = [:] }
        for raw in models {
            let name = raw.hasPrefix("models/") ? String(raw.dropFirst("models/".count)) : raw
            if name.isEmpty || skip.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil { continue }
            let kind: String
            let ver: [Int]
            var stable = 1
            if let g = match(geminiName, name) {
                ver = (g[1] ?? "").split(separator: ".").compactMap { Int($0) }
                kind = g[2] ?? "flash"
                let rest = g[3] ?? ""
                stable = (rest.isEmpty || rest == "latest" || matches("^\\d{3}$", rest)) ? 1 : 0
            } else if let t = match(gemmaName, name) {
                let rest = t[2] ?? ""
                var size = 0
                if let r = rest.range(of: "\\d+b", options: .regularExpression) { size = Int(rest[r].dropLast()) ?? 0 }
                ver = [Int(t[1] ?? "") ?? 0, size]
                kind = "gemma"
            } else {
                continue
            }
            let cand = (stable: stable, len: -name.count, name: name)
            if let cur = fam[kind]?[ver] {
                if cand.stable > cur.stable || (cand.stable == cur.stable && cand.len > cur.len) { fam[kind]?[ver] = cand }
            } else {
                fam[kind]?[ver] = cand
            }
        }
        var out: [String] = []
        for f in families {
            let sorted = (fam[f] ?? [:]).sorted { less($1.key, $0.key) }
            out += sorted.prefix(2).map { $0.value.name }
        }
        return Array(out.prefix(limit))
    }

    /// Model adını sesli okunacak hale getirir: gemini-3.8-flash → "Gemini 3 nokta 8 Flash", gemma-4-31b-it → "Gemma 4 31 B"
    static func spoken(_ raw: String) -> String {
        var n = raw.hasPrefix("models/") ? String(raw.dropFirst("models/".count)) : raw
        if n.hasSuffix("-it") { n = String(n.dropLast(3)) }
        var out: [String] = []
        for t in n.split(separator: "-", omittingEmptySubsequences: true).map(String.init) {
            if matches("^[aA]\\d+[bB]$", t) { continue }
            if t.lowercased() == "preview" {
                out.append("önizleme")
            } else if matches("^\\d+(\\.\\d+)+$", t) {
                out.append(t.split(separator: ".").joined(separator: " nokta "))
            } else if matches("^\\d+[bB]$", t) {
                out.append(String(t.dropLast()) + " B")
            } else if t.allSatisfy({ $0.isLetter }) {
                out.append(t.prefix(1).uppercased() + t.dropFirst().lowercased())
            } else {
                out.append(t)
            }
        }
        return out.joined(separator: " ")
    }

    /// Seçim cümlesi: "Hangi modeli kullanmak istersiniz? Birinci model: …, şu anki. İkinci model: …"
    static func announcement(slot: Int, choices: [String], current: String) -> String {
        let head = slot <= 1 ? "Hangi modeli kullanmak istersiniz?" : "\(slotName(slot)) için hangi modeli kullanmak istersiniz?"
        let items = choices.enumerated().map { i, n in
            "\(ordinalsCap[min(i, ordinalsCap.count - 1)]) model: \(spoken(n))\(n == current ? ", şu anki" : "")."
        }
        return head + " " + items.joined(separator: " ")
            + " Seçmek için örneğin birinci model deyin. Listeyi yinelemek için tekrarla, vazgeçmek için vazgeç deyin."
    }

    /// "birinci model, birinci modeli, 1 model, 1 numaralı model" (n = 1...7)
    static func pickPhrases(_ n: Int) -> String {
        let word = ordinals[min(max(n, 1), ordinals.count) - 1]
        return "\(word) model, \(word) modeli, \(n) model, \(n) numaralı model"
    }

    static let changePhrases = "model değiştir, modeli değiştir, model seç, modeli seç, ana model seç"
    private static let numberWords = ["bir", "iki", "üç", "dört", "beş"]

    /// k. alternatif model = (k+1). profil; slot 2...4: "birinci alternatif model seç" … "üçüncü alternatif model seç"
    static func alternativePhrases(slot: Int) -> String {
        let k = min(max(slot - 1, 1), numberWords.count)
        let w = ordinals[k - 1], nw = numberWords[k - 1]
        return "\(w) alternatif model seç, \(w) alternatif modeli seç, \(k) alternatif model seç, \(nw) alternatif model seç, \(w) alternatif model, alternatif model \(nw)"
    }
    static var secondPhrases: String { return alternativePhrases(slot: 2) }
    static var thirdPhrases: String { return alternativePhrases(slot: 3) }

    /// Komut kimliği alternatif model komutu mu ("model2" … "model4"); "model", "modelRepeat", "modelCancel" değil
    static func isAlternativeID(_ id: String) -> Bool {
        let rest = id.dropFirst(5)
        return id.hasPrefix("model") && !rest.isEmpty && rest.allSatisfy({ $0.isNumber })
    }
    static let repeatPhrases = "tekrarla, listeyi tekrarla, modelleri tekrarla, modelleri tekrar oku, listeyi tekrar oku"
    static let cancelPhrases = "vazgeç, vazgeçtim, vazgeçiyorum"

    /// Profil yuvasının sesli adı: "Ana model", "Birinci alternatif model", "İkinci alternatif model" …
    static func slotName(_ slot: Int) -> String {
        guard slot >= 2 else { return "Ana model" }
        return "\(ordinalsCap[min(slot - 2, ordinalsCap.count - 1)]) alternatif model"
    }
}

/// Sesli model seçiminin durumu. Liste, seçilecek yuvanın (ya da seçili profilin) anahtarıyla hesaptan alınır; "birinci model"
/// gibi söylenen seçim yuvanın modeline yazılır. Anahtarı girilmiş profil seçilince hemen kullanılan profil olur.
@MainActor
final class ModelChooser {
    private(set) var choosing = false
    private(set) var slot = 1
    private(set) var choices: [String] = []

    private let profiles: () -> [GeminiProfileInfo]
    private let activeKey: () -> String
    private let lister: (String) async throws -> [String]
    private let apply: (_ slot: Int, _ model: String, _ activate: Bool) -> Void
    private let say: (String) -> Void
    private let timeout: TimeInterval
    private var generation = 0
    private var timeoutWork: DispatchWorkItem?

    init(profiles: @escaping () -> [GeminiProfileInfo], activeKey: @escaping () -> String,
         lister: @escaping (String) async throws -> [String],
         apply: @escaping (_ slot: Int, _ model: String, _ activate: Bool) -> Void,
         say: @escaping (String) -> Void, timeout: TimeInterval = 60) {
        self.profiles = profiles
        self.activeKey = activeKey
        self.lister = lister
        self.apply = apply
        self.say = say
        self.timeout = timeout
    }

    /// "Model değiştir" (slot 1), "birinci alternatif model seç" (2) … "üçüncü alternatif model seç" (4)
    func begin(slot newSlot: Int = 1) {
        let slot = min(max(newSlot, 1), GeminiProfiles.slotCount)
        let own = profiles().first(where: { $0.slot == slot })?.key.trimmed ?? ""
        let key = own.isEmpty ? activeKey().trimmed : own
        guard !key.isEmpty else {
            say("Model listesi için önce Ayarlardan bir Gemini anahtarı girin.")
            return
        }
        generation += 1
        let gen = generation
        timeoutWork?.cancel()
        choosing = true
        self.slot = slot
        choices = []
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let names = ModelChoice.choosable(try await self.lister(key))
                guard gen == self.generation, self.choosing else { return }
                guard !names.isEmpty else {
                    self.choosing = false
                    self.say("Listelenecek uygun model bulunamadı.")
                    return
                }
                self.choices = names
                self.announce()
            } catch {
                guard gen == self.generation else { return }
                self.choosing = false
                let detail = ((error as? GeminiError)?.message ?? "").trimmed
                self.say("Model listesi alınamadı. \(detail)".trimmed)
            }
        }
    }

    private func announce() {
        let current = profiles().first(where: { $0.slot == slot })?.model ?? ""
        say(ModelChoice.announcement(slot: slot, choices: choices, current: current))
        armTimeout()
    }

    private func armTimeout() {
        timeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.choosing else { return }
            self.end()
            self.say("Model değişmedi.")
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    /// Seçimi sessizce bırakır (başka bir komut geldi)
    func end() {
        choosing = false
        generation += 1
        timeoutWork?.cancel()
        timeoutWork = nil
    }

    /// "Vazgeç"
    @discardableResult
    func cancel() -> Bool {
        guard choosing else { return false }
        end()
        say("Model değişmedi.")
        return true
    }

    /// "Tekrarla": liste yeniden okunur
    @discardableResult
    func repeatList() -> Bool {
        guard choosing, !choices.isEmpty else { return false }
        announce()
        return true
    }

    /// "Birinci model" … "yedinci model". Seçim sürmüyorsa false (komut yok sayılır)
    @discardableResult
    func pick(_ n: Int) -> Bool {
        guard choosing, !choices.isEmpty else { return false }
        guard n >= 1, n <= choices.count else {
            let word = (n >= 1 && n <= ModelChoice.ordinals.count) ? ModelChoice.ordinals[n - 1] : "\(n)."
            say("Listede \(word) model yok.")
            armTimeout()
            return true
        }
        let model = choices[n - 1]
        let usable = !(profiles().first(where: { $0.slot == slot })?.key.trimmed ?? "").isEmpty
        let chosenSlot = slot
        end()
        apply(chosenSlot, model, usable)
        let tail = usable ? " Şimdi bu model kullanılıyor."
            : " Bu profilin anahtarı girilmediği için henüz kullanılmayacak; anahtarı Ayarlardan ekleyin."
        say("\(ModelChoice.slotName(chosenSlot)), \(ModelChoice.spoken(model)) olarak seçildi.\(tail)")
        return true
    }
}
