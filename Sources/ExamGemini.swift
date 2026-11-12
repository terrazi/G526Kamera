import Foundation

/// Deneme sınavı için Gemini görevi: belgeler üzerinde JSON şemalı tek seferlik istek (geçmiş kullanılmaz)
struct ExamTask {
    let prompt: String
    let schema: [String: Any]
    let system: String
    let maxTokens: Int
    /// Sesli istek (16 kHz WAV); varsa istemin önüne eklenir ("dinle … tamam" serbest konuşması)
    let audio: Data?

    init(prompt: String, schema: [String: Any], system: String = ExamPrompts.system, maxTokens: Int = 16384, audio: Data? = nil) {
        self.prompt = prompt
        self.schema = schema
        self.system = system
        self.maxTokens = maxTokens
        self.audio = audio
    }
}

/// Deneme sınavı yönergeleri ve şemaları (Windows sürümündeki g526/gemini.py'deki EXAM_* sabitlerinin karşılığı)
enum ExamPrompts {
    static let system: String = ([
        "Sen bir deneme sınavı yardımcısısın. Kullanıcı, sınav sorularının taranmış sayfalarını PDF olarak verdi. Belgeler tarama "
            + "sırasıyla 'Belge 1', 'Belge 2' diye numaralıdır (Belge 1 ilk taranandır). Cevapların sesli okunacak. Kurallar:",
        "1. Belgeleri titizlikle oku: her PDF'in her sayfasını görüntü olarak incele; soru numaralarını, soru metinlerini, tabloları, "
            + "şekilleri, küçük yazıları ve şık harflerini (A, B, C…) atlama. Eğik ya da ters taranmış sayfaları düzelterek oku.",
        "2. Aynı sayfa birden çok kez taranmış (mükerrer) olabilir: en okunaklı olanı esas al, soruyu iki kez sayma ya da cevaplama.",
        "3. Her sorunun kimliği 'no' (kâğıtta yazan numara, tamsayı) ve 'bolum'dur. Belgelerde birden çok test, kitapçık ya da deneme "
            + "varsa ve numaralar yeniden başlıyorsa 'bolum' alanına bölümün kısa adını yaz ('Test 2', 'Deneme 3'); adı yoksa 'Belge N' "
            + "kullan. Tek bir numara dizisi varsa 'bolum' boş olsun.",
        "4. Soruyu doğru çöz. Hesap gerektiren sorularda hesabı dikkatle yap ve sonucu şıklarla karşılaştır; bilgi sorularında "
            + "bilmediğin şeyi uydurma. Emin olmadığın soruda en olası şıkkı yaz ama 'durum' alanına 'belirsiz' koy.",
        "5. 'durum' alanı: 'tamam' (cevaptan eminsin), 'belirsiz' (emin değilsin), 'okunamadi' (soru ya da şıklar okunamıyor, "
            + "eksik ya da yarım; bu durumda 'sik' ve 'deger' boş olsun, tahmin etme).",
        "6. 'sik' doğru şıkkın harfidir (A, B, C…), 'deger' şıkkın metni ya da değeridir: belgede yazdığı gibi, eksiksiz; sayıları "
            + "okunuşuyla yazıyla yaz, kısaltma ve sembol kullanma (% yerine yüzde, TL yerine Türk lirası, kg yerine kilogram). Şıkta metin "
            + "yoksa (yalnız harf ya da şekil) 'deger' boş olsun.",
        "7. 'gerekce' tek kısa cümledir (en çok yirmi beş sözcük): cevabı nasıl bulduğunu ya da hangi bilgiye dayandığını söyler. "
            + "Sesli okunacağı için madde işareti, sembol, kalın yazı kullanma.",
        "8. Yalnızca belgelerdeki soruları dikkate al; istenmeyen soruyu cevaplama.",
        "Çıktı her zaman istenen JSON biçiminde olmalı."
    ] as [String]).joined(separator: "\n")

    static let verifySchema: [String: Any] = [
        "type": "OBJECT",
        "properties": [
            "belgeler": ["type": "ARRAY", "items": [
                "type": "OBJECT",
                "properties": ["belge": ["type": "STRING"], "sayfa": ["type": "INTEGER"], "soru_sayisi": ["type": "INTEGER"]],
                "required": ["belge", "sayfa", "soru_sayisi"]]],
            "sorular": ["type": "ARRAY", "items": [
                "type": "OBJECT",
                "properties": ["bolum": ["type": "STRING"], "no": ["type": "INTEGER"]],
                "required": ["bolum", "no"]]],
            "okunamayan_sayfa": ["type": "INTEGER"],
            "not": ["type": "STRING"]
        ],
        "required": ["belgeler", "sorular", "okunamayan_sayfa", "not"]
    ]

    static let answerSchema: [String: Any] = [
        "type": "OBJECT",
        "properties": ["cevaplar": ["type": "ARRAY", "items": [
            "type": "OBJECT",
            "properties": ["bolum": ["type": "STRING"], "no": ["type": "INTEGER"], "durum": ["type": "STRING"],
                           "sik": ["type": "STRING"], "deger": ["type": "STRING"], "gerekce": ["type": "STRING"]],
            "required": ["bolum", "no", "durum", "sik", "deger", "gerekce"]]]],
        "required": ["cevaplar"]
    ]

    static let verifyPrompt: String = "Belgelerdeki bütün sayfaları incele ve bildir: her belge için sayfa sayısı (taranmış sayfa "
        + "görüntüleri) ve içindeki soru sayısı. Sonra belgelerdeki TÜM soruları, "
        + "belgelerde göründükleri sırayla 'sorular' listesine yaz (her soru için kâğıttaki numarası 'no' ve gerekirse 'bolum'). "
        + "Okunamayan ya da kesik sayfa sayısını 'okunamayan_sayfa' alanına, varsa dikkat edilmesi gereken bir durumu (eksik sayfa, "
        + "ters tarama gibi) kısa bir cümleyle 'not' alanına yaz. Soruları çözme, yalnız say ve listele."

    /// keys: (bölüm, numara) — bu soruları cevapla
    static func answerPrompt(_ keys: [(bolum: String, no: Int)]) -> String {
        var lines: [String] = []
        for k in keys {
            lines.append(k.bolum.isEmpty ? "no: \(k.no)" : "bolum: '\(k.bolum)', no: \(k.no)")
        }
        return "Şu soruları cevapla (her biri için 'cevaplar' listesine tam bir kayıt yaz, sırayı koru, hiçbirini atlama):\n"
            + lines.joined(separator: "\n")
    }
}

extension ExamPrompts {
    /// "Dinle" ile gelen serbest sesli istek: Gemini ne istendiğini ve yapılacak işlemi bildirir
    static let freeSchema: [String: Any] = [
        "type": "OBJECT",
        "properties": [
            "anlasilan": ["type": "STRING"],
            "islem": ["type": "STRING", "enum": ["cevap", "tekrar", "hepsi", "devam", "bitir", "anlasilmadi"]],
            "numaralar": ["type": "ARRAY", "items": ["type": "INTEGER"]],
            "cevap": ["type": "STRING"]
        ],
        "required": ["anlasilan", "islem"]
    ]

    /// Deneme sınavı sırasında "dinle" ile gelen serbest sesli soru/istek. record: o ana kadar verilen cevapların dökümü
    static func freePrompt(record: String) -> String {
        let lines: [String] = [
            "Ekteki ses kaydı, deneme sınavı sırasında kullanıcıdan geldi (Türkçe). Kaydın sonundaki 'tamam' sözcüğü kaydı bitirme "
                + "işaretidir; yok say. Önce söyleneni 'anlasilan' alanına yaz. Sonra 'islem' alanını seç:",
            "- tekrar: kullanıcı belirli soruların kayıtlı cevaplarının yeniden okunmasını istiyor; 'numaralar'a soru numaralarını yaz.",
            "- hepsi: bütün cevapların baştan okunmasını istiyor.",
            "- devam: sıradaki sorulara geçilmesini istiyor.",
            "- bitir: sınavı bitirmek istiyor.",
            "- cevap: bunlardan başka bir şey söylüyor ya da soruyor (bir soruyu açıkla, neden bu şık, yeniden çöz, kontrol et, başka bir "
                + "soru…). 'cevap' alanına sesle okunacak kısa, düz Türkçe bir cevap yaz (en çok yaklaşık altı cümle; madde işareti, sembol, "
                + "kalın yazı yok). Belgelerdeki soruları ve aşağıdaki kayıtlı cevapları esas al; emin değilsen bunu söyle, uydurma.",
            "- anlasilmadi: kayıt boş, anlaşılmaz ya da sınavla ilgisiz.",
            "Şu ana kadar verilen cevaplar:"
        ]
        return lines.joined(separator: "\n") + "\n" + (record.isEmpty ? "(henüz yok)" : record)
    }

    /// Emin olunmayan soruları bağımsız olarak, özenle yeniden çözdürür (keys: (bölüm, numara))
    static func recheckPrompt(_ keys: [(bolum: String, no: Int)]) -> String {
        var lines: [String] = []
        for k in keys {
            lines.append(k.bolum.isEmpty ? "no: \(k.no)" : "bolum: '\(k.bolum)', no: \(k.no)")
        }
        let head: String = "Şu soruları SIFIRDAN, adım adım ve çok dikkatli yeniden çöz: daha önce bir cevap vermedin, "
            + "kendini tekrar etme. Hesap varsa hesabı baştan yap ve her şıkkı tek tek eleyerek ilerle; sayfa görüntüsündeki "
            + "soru ve şıkları yeniden oku. Her biri için 'cevaplar' listesine tam bir kayıt yaz, sırayı koru, hiçbirini atlama:\n"
        return head + lines.joined(separator: "\n")
    }
}

extension GeminiSupport {
    /// Belgeler üzerinde yapılandırılmış (JSON şemalı) görev isteği. Geçmiş kullanılmaz. Dosya adresli belgeler Files API'den,
    /// diğerleri inline gider.
    static func taskRequestObject(_ task: ExamTask, docs: [GeminiDoc]) -> [String: Any] {
        var contents: [[String: Any]] = []
        if !docs.isEmpty {
            if allRemote(docs) {
                contents.append(contentsOf: docsTurns(docs))
            } else {
                var parts: [[String: Any]] = []
                for (n, doc) in docs.enumerated() {
                    parts.append(["text": "Belge \(n + 1): \(doc.name)"])
                    parts.append(["inlineData": ["mimeType": "application/pdf", "data": doc.data.base64EncodedString()]])
                }
                parts.append(["text": GeminiConfig.docsIntro])
                contents.append(["role": "user", "parts": parts])
                contents.append(["role": "model", "parts": [["text": taskAck()]]])
            }
        }
        var tail: [[String: Any]] = []
        if let wav = task.audio {
            tail.append(["inlineData": ["mimeType": "audio/wav", "data": wav.base64EncodedString()]])
        }
        tail.append(["text": task.prompt])
        contents.append(["role": "user", "parts": tail])
        return [
            "contents": contents,
            "systemInstruction": ["parts": [["text": task.system]]],
            "generationConfig": [
                "temperature": 0.2,
                "responseMimeType": "application/json",
                "responseSchema": task.schema,
                "maxOutputTokens": task.maxTokens
            ] as [String: Any]
        ]
    }

    private static func taskAck() -> String {
        let object: [String: Any] = ["soru": "", "cevap": GeminiConfig.docsAck, "kapat": false, "model_degistir": false, "son_soru": 0]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return GeminiConfig.docsAck
    }

    static func buildTaskRequest(_ task: ExamTask, docs: [GeminiDoc], thinking: String? = nil) throws -> Data {
        let object = applyThinking(taskRequestObject(task, docs: docs), level: thinking)
        return try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
    }

    /// Görev cevabından ham JSON metnini çıkarır. Engellenmiş / boş cevapta GeminiError.
    static func parseTask(_ object: Any) throws -> String {
        guard let obj = object as? [String: Any] else {
            throw GeminiError("Gemini'den anlaşılmaz yanıt geldi.", .error)
        }
        if let feedback = obj["promptFeedback"] as? [String: Any], let reason = feedback["blockReason"] as? String, !reason.isEmpty {
            throw GeminiError("Gemini isteği güvenlik nedeniyle engelledi (\(reason)).", .blocked)
        }
        guard let candidates = obj["candidates"] as? [[String: Any]], let cand = candidates.first else {
            throw GeminiError("Gemini boş yanıt döndürdü.", .empty)
        }
        let finish = (cand["finishReason"] as? String) ?? ""
        let parts = ((cand["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        var text = ""
        for p in parts {
            if let thought = p["thought"] as? Bool, thought { continue }
            if let t = p["text"] as? String { text += t }
        }
        let trimmed = text.trimmed
        if trimmed.isEmpty {
            throw GeminiError("Gemini boş yanıt döndürdü (\(finish.isEmpty ? "neden yok" : finish)).", .empty)
        }
        return trimmed
    }
}

/// Belgeler üzerinde görev çalıştıran istemci arayüzü (sınav mantığı sahte istemciyle sınansın diye)
protocol GeminiTasking: AnyObject {
    var currentModel: String { get }
    func fallbackModels() async -> [String]
    /// Görevi sorar, ham JSON metnini döndürür. model: yedek model (nil = seçili model)
    func runTask(_ task: ExamTask, docs: [GeminiDoc], model: String?, serverRetries: Int?) async throws -> String
}

extension GeminiClient: GeminiTasking {
    func runTask(_ task: ExamTask, docs: [GeminiDoc], model overrideModel: String?, serverRetries: Int?) async throws -> String {
        var useModel = model
        if let m = overrideModel, !m.trimmed.isEmpty { useModel = m.trimmed }
        let body = try GeminiSupport.buildTaskRequest(task, docs: docs,
                                                      thinking: GeminiSupport.thinkingLevel(model: useModel, setting: thinkingProvider()))
        let object = try await postTask(model: useModel, body: body, serverRetries: serverRetries ?? GeminiClient.askServerRetries)
        return try GeminiSupport.parseTask(object)
    }
}
