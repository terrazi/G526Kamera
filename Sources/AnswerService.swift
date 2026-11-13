import Foundation

/// Bir sorunun Gemini'den gelen cevabı
struct AnswerRecord: Equatable {
    var number: Int
    /// "tamam" | "belirsiz" | "okunamadi"
    var status: String
    /// Doğru şıkkın harfi (A–E); boşsa cevap yok
    var letter: String
    /// Şıkkın metni ya da değeri (belgede yazdığı gibi; sayılar okunuşuyla yazıyla)
    var value: String

    static let unread = "okunamadi"
    static let unsure = "belirsiz"
}

/// Gemini'ye gidecek bir PDF: bir soru ya da bir soru grubu
struct AnswerDoc: Equatable {
    let name: String
    let numbers: [Int]
    let data: Data
}

/// Soru PDF'lerini Gemini'ye standart bir metinle gönderir ve cevapları sıralı, eksiksiz toplar.
/// Model zinciri: seçili profil → (kota dolunca / hata olunca / cevap gecikince) sıradaki profil → … (4 profil, döngüyle).
enum AnswerService {
    /// Bir istekteki en çok PDF sayısı (daha fazlası ayrı isteklere bölünür)
    static let maxDocsPerRequest = 20

    static let system: String = [
        "Sen bir deneme sınavı yardımcısısın. Kullanıcı, sınav sorularını kameradan çekilmiş görüntülerden hazırlanan PDF dosyaları olarak verdi. "
            + "Her PDF bir soruyu (ya da dosya adında yazan sorular grubunu) içerir; dosya adı soru numarasını gösterir (S12.pdf = 12. soru). "
            + "Cevapların sesli okunacak. Kurallar:",
        "1. Bir sorunun birden çok sayfası olabilir: bunlar AYNI sorunun farklı kare görüntüleridir ya da sorunun devamıdır. En okunaklı "
            + "görüntüyü esas al, birleştirerek oku; soruyu iki kez sayma. Soru numarasını sayfadaki yazıdan ve dosya adından doğrula.",
        "2. Soruyu ve bütün şıkları (A, B, C, D, E) titizlikle oku: tabloları, şekilleri, küçük yazıları atlama. Eğik ya da gölgeli görüntüleri "
            + "dikkatle oku.",
        "3. Soruyu doğru çöz. Hesap gerektiren sorularda hesabı dikkatle yap ve sonucu şıklarla karşılaştır; bilgi sorularında bilmediğin "
            + "şeyi uydurma. Emin olmadığın soruda en olası şıkkı yaz ama 'durum' alanına 'belirsiz' koy.",
        "4. 'durum' alanı: 'tamam' (cevaptan eminsin), 'belirsiz' (emin değilsin), 'okunamadi' (soru ya da şıklar okunamıyor, eksik ya da yarım; "
            + "bu durumda 'sik' ve 'deger' boş olsun, tahmin etme).",
        "5. 'sik' doğru şıkkın harfidir (A, B, C…), 'deger' şıkkın metni ya da değeridir: belgede yazdığı gibi, eksiksiz; sayıları okunuşuyla "
            + "yazıyla yaz, kısaltma ve sembol kullanma (% yerine yüzde, TL yerine Türk lirası, kg yerine kilogram). Şıkta metin yoksa "
            + "(yalnız harf ya da şekil) 'deger' boş olsun.",
        "6. Gerekçe, açıklama ya da yorum yazma; yalnız istenen alanları doldur.",
        "Çıktı her zaman istenen JSON biçiminde olmalı."
    ].joined(separator: "\n")

    static let schema: [String: Any] = [
        "type": "OBJECT",
        "properties": ["cevaplar": ["type": "ARRAY", "items": [
            "type": "OBJECT",
            "properties": ["no": ["type": "INTEGER"], "durum": ["type": "STRING"], "sik": ["type": "STRING"], "deger": ["type": "STRING"]],
            "required": ["no", "durum", "sik", "deger"]]]],
        "required": ["cevaplar"]
    ]

    static func prompt(numbers: [Int]) -> String {
        let list = numbers.map { String($0) }.joined(separator: ", ")
        return "Şu soruları cevapla: \(list). Her biri için 'cevaplar' listesine tam bir kayıt yaz (no, durum, sik, deger), "
            + "soru numarasına göre küçükten büyüğe sırala, hiçbirini atlama."
    }

    // MARK: İstek

    static func requestBody(docs: [AnswerDoc], thinking: String?) throws -> Data {
        var parts: [[String: Any]] = []
        var all: [Int] = []
        for d in docs {
            let label = d.numbers.count == 1 ? "\(d.numbers[0]). soru" : "sorular: " + d.numbers.map { String($0) }.joined(separator: ", ")
            parts.append(["text": "Dosya: \(d.name) (\(label))"])
            parts.append(["inlineData": ["mimeType": "application/pdf", "data": d.data.base64EncodedString()]])
            all += d.numbers
        }
        parts.append(["text": prompt(numbers: all.sorted())])
        let object: [String: Any] = [
            "contents": [["role": "user", "parts": parts]],
            "systemInstruction": ["parts": [["text": system]]],
            "generationConfig": [
                "temperature": 0.2,
                "responseMimeType": "application/json",
                "responseSchema": schema,
                "maxOutputTokens": 8192
            ] as [String: Any]
        ]
        let body = GeminiSupport.applyThinking(object, level: thinking)
        return try JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])
    }

    /// PDF'leri istek sınırlarına göre gruplara böler: bir istekteki toplam bayt (inline sınırı) ve PDF sayısı sınırlıdır
    static func chunk(_ docs: [AnswerDoc], budget: Int = GeminiConfig.inlineBudget, maxDocs: Int = maxDocsPerRequest) -> [[AnswerDoc]] {
        var out: [[AnswerDoc]] = []
        var cur: [AnswerDoc] = []
        var bytes = 0
        for d in docs.sorted(by: { ($0.numbers.first ?? 0) < ($1.numbers.first ?? 0) }) {
            if !cur.isEmpty && (bytes + d.data.count > budget || cur.count >= max(maxDocs, 1)) {
                out.append(cur)
                cur = []
                bytes = 0
            }
            cur.append(d)
            bytes += d.data.count
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    // MARK: Cevabı çözme

    /// generateContent cevabından model metnini çıkarır (düşünce parçaları atlanır). Engellenmiş / boş cevapta GeminiError.
    static func responseText(_ object: Any) throws -> String {
        guard let obj = object as? [String: Any] else {
            throw GeminiError("Gemini'den anlaşılmaz yanıt geldi.", .error)
        }
        if let feedback = obj["promptFeedback"] as? [String: Any], let reason = feedback["blockReason"] as? String, !reason.isEmpty {
            throw GeminiError("Gemini isteği güvenlik nedeniyle engelledi (\(reason)).", .blocked)
        }
        guard let candidates = obj["candidates"] as? [[String: Any]], let cand = candidates.first else {
            throw GeminiError("Gemini boş yanıt döndürdü.", .empty)
        }
        let parts = ((cand["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        var text = ""
        for p in parts {
            if let thought = p["thought"] as? Bool, thought { continue }
            if let t = p["text"] as? String { text += t }
        }
        let trimmed = text.trimmed
        if trimmed.isEmpty {
            let finish = (cand["finishReason"] as? String) ?? ""
            throw GeminiError("Gemini boş yanıt döndürdü (\(finish.isEmpty ? "neden yok" : finish)).", .empty)
        }
        return trimmed
    }

    /// {"cevaplar":[{"no":12,"durum":"tamam","sik":"B","deger":"…"}]} → kayıtlar (numaraya göre sıralı, aynı numara tek kez)
    static func parse(_ text: String) -> [AnswerRecord] {
        guard let data = GeminiSupport.stripFence(text).data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = json["cevaplar"] as? [[String: Any]] else { return [] }
        var byNumber: [Int: AnswerRecord] = [:]
        for item in items {
            guard let n = number(item["no"]), n > 0, byNumber[n] == nil else { continue }
            var status = ((item["durum"] as? String) ?? "tamam").trimmed.lowercased()
            let letter = letterOf((item["sik"] as? String) ?? "")
            let value = ((item["deger"] as? String) ?? "").trimmed
            if status != AnswerRecord.unread && status != AnswerRecord.unsure { status = "tamam" }
            if letter.isEmpty && value.isEmpty { status = AnswerRecord.unread }
            byNumber[n] = AnswerRecord(number: n, status: status, letter: letter, value: value)
        }
        return byNumber.keys.sorted().compactMap { byNumber[$0] }
    }

    private static func number(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String { return Int(s.trimmed) }
        return nil
    }

    /// "B", "b)", "B şıkkı" → "B"; A–E dışı → ""
    static func letterOf(_ raw: String) -> String {
        for c in raw.uppercased() where "ABCDE".contains(c) { return String(c) }
        return ""
    }

    // MARK: Sesli cümle

    /// Okunacak cümle: "Birinci soru, ADANA, kırk iki." (şık harfi ayardaki şehir koduna çevrilir)
    static func spokenLine(_ r: AnswerRecord, codes: [(letter: String, word: String)]) -> String {
        let label = TurkishNumbers.capitalised(TurkishNumbers.ordinal(r.number)) + " soru"
        if r.status == AnswerRecord.unread || r.letter.isEmpty { return "\(label) okunamadı." }
        let word = codes.first(where: { $0.letter == r.letter })?.word ?? r.letter
        var text = "\(label), \(word)"
        if !r.value.isEmpty { text += ", \(r.value)" }
        text += "."
        if r.status == AnswerRecord.unsure { text += " Emin değilim." }
        return text
    }

    // MARK: Model zinciri

    /// Denenecek profiller: seçili profil, ardından 1→…→4 döngüsüyle anahtarı ve modeli dolu olanlar
    static func chainOrder(profiles: [GeminiProfileInfo], active: Int) -> [GeminiProfileInfo] {
        let usable = GeminiProfiles.usable(profiles)
        let act = GeminiProfiles.active(profiles, active: active)
        guard usable.contains(where: { $0.slot == act.slot }) else { return [] }
        var list = [act]
        let n = GeminiProfiles.slotCount
        for k in 1..<n {
            let slot = (act.slot - 1 + k) % n + 1
            if let p = usable.first(where: { $0.slot == slot }) { list.append(p) }
        }
        return list
    }

    /// Sıradaki modelin işe yarayacağı hatalar: kota, sunucu hatası / yoğunluk, cevap gecikmesi, boş cevap, anahtar ya da model adı sorunu.
    /// Harcama sınırı, içerik engeli, çok büyük istek ve internetin hiç olmaması başka modelle düzelmez.
    static func chainWorthy(_ e: GeminiError) -> Bool {
        switch e.kind {
        case .cap, .blocked, .tooBig: return false
        case .network: return e.timedOut
        case .empty: return true
        default: return [500, 502, 503, 504].contains(e.status) || e.kind == .quota || e.kind == .key || e.kind == .model
        }
    }

    /// Kullanıcıya sesle söylenen kısa bilgi: neden başka modele geçildi
    static func switchText(from prev: GeminiProfileInfo, error e: GeminiError, to next: GeminiProfileInfo) -> String {
        let why: String
        if e.kind == .quota {
            why = "\(prev.name) kotası doldu."
        } else if e.timedOut {
            why = "\(prev.name) uzun süre cevap vermedi."
        } else if e.kind == .key {
            why = "\(prev.name) için API anahtarı geçersiz."
        } else if e.kind == .model {
            why = "\(prev.name) modeli bulunamadı."
        } else if GeminiSupport.isOverload(e) {
            why = "\(prev.name) şu an çok yoğun."
        } else {
            why = "\(prev.name) cevap veremedi."
        }
        return "\(why) Sorular \(next.name) modeline gönderiliyor."
    }

    /// Hangi modelin (ve anahtar hatasında hangi anahtarın) neden başarısız olduğu
    static func failureLine(profile: GeminiProfileInfo, error e: GeminiError) -> String {
        var line = "\(profile.name): \(e.message)"
        if e.kind == .key {
            line += " (anahtar: \(GeminiProfiles.keyHint(profile.key)))"
            if let note = GeminiProfiles.keyFormatNote(key: profile.key) { line += " " + note }
        }
        return line
    }

    /// Denenen her modelin sonucu tek iletide toplanır; tür ve durum kodu son hatanın kalır
    static func combined(_ last: GeminiError, trail: [String]) -> GeminiError {
        guard !trail.isEmpty else { return last }
        var merged = GeminiError(trail.joined(separator: " "), last.kind, status: last.status)
        merged.timedOut = last.timedOut
        return merged
    }

    /// Bir istek için bekleme sınırı: ayardaki süre (en az 10 sn) + PDF başına birkaç saniye
    static func waitLimit(setting: TimeInterval, docCount: Int) -> TimeInterval? {
        guard setting > 0 else { return nil }
        return max(setting, 10) + Double(docCount) * 3
    }

    // MARK: Gönderim

    /// Bir PDF grubunu sorar. Hata olursa (zincir açık) sıradaki profile geçer ve `notify` ile kısa bilgi verir. Son profile bekleme sınırı konmaz.
    static func ask(docs: [AnswerDoc], profiles: [GeminiProfileInfo], active: Int, waitLimit setting: TimeInterval,
                    makeClient: ((GeminiProfileInfo) -> GeminiClient)? = nil,
                    notify: @escaping (String) -> Void) async throws -> [AnswerRecord] {
        let order = chainOrder(profiles: profiles, active: active)
        guard !order.isEmpty else {
            throw GeminiError("Gemini API anahtarı girilmemiş. Ayarlardan yapıştırın.", .key)
        }
        var lastError = GeminiError("Gemini cevap vermedi.", .error)
        var trail: [String] = []
        for (i, profile) in order.enumerated() {
            let isLast = i == order.count - 1
            let limit = isLast ? nil : waitLimit(setting: setting, docCount: docs.count)
            let client = makeClient?(profile) ?? GeminiClient(key: { profile.key }, model: { profile.model })
            do {
                let body = try requestBody(docs: docs, thinking: GeminiSupport.thinkingLevel(model: profile.model, setting: "auto"))
                let object = try await client.generate(model: profile.model, key: profile.key, body: body,
                                                       serverRetries: GeminiClient.askServerRetries, timeout: limit)
                let records = parse(try responseText(object))
                if records.isEmpty { throw GeminiError("Gemini cevap listesi vermedi.", .empty) }
                return records
            } catch let e as GeminiError {
                trail.append(failureLine(profile: profile, error: e))
                lastError = e
                guard !isLast, chainWorthy(e) else { throw combined(e, trail: trail) }
                notify(switchText(from: profile, error: e, to: order[i + 1]))
            }
        }
        throw combined(lastError, trail: trail)
    }
}
