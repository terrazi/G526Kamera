import Foundation

/// Gemini sesi (Gemini TTS): cevabı Gemini'nin doğal sesiyle dosyaya çevirir. Cevap geldiği anda (internet varken) üretilir ve
/// soru dosyasına kaydedilir; test sonundaki çevrimdışı tekrar bu dosyaları çalar, bu yüzden tekrarda internet gerekmez.
/// Başarısız olursa (kota, internet, model) sıradaki motor olan telefonun sesi devreye girer.
@MainActor
final class GeminiVoice: SpeechSynthesizing {
    /// Denenecek TTS modelleri (her anahtarla sırayla)
    static let models = ["gemini-3.8-flash-tts", "gemini-3.8-flash-lite-tts"]
    static let voiceName = "Kore"
    /// Sınavda beklemeyi uzatmamak için her model için en çok bekleme (sn)
    static let perModelLimit: TimeInterval = 8
    /// Tüm modeller başarısız olunca Gemini sesi bu kadar süre denenmez: her cevapta boşuna bekleme olmasın, telefonun sesi hemen devreye girer
    static let cooldown: TimeInterval = 300
    /// Birkaç anahtar denenirken toplam bekleme bütçesi (sn): yavaş başarısızlıktan sonra sıradaki anahtara geçilmez,
    /// cevap telefonun sesiyle gecikmeden okunur. Hızlı hatalarda (kota, anahtar, model yok) sıradaki anahtar denenir.
    static let budget: TimeInterval = 12
    static let sampleRate = 24_000

    private let keysProvider: () -> [String]
    private let budget: TimeInterval
    private let modelNames: [String]
    private let limit: TimeInterval
    private let makeClient: (String) -> GeminiClient
    private let cooldown: TimeInterval
    private let now: () -> Date
    private var cancelled = false
    private var disabledUntil: Date?

    /// `keys`: dolu API anahtarları, öncelik sırasıyla (aynı anahtar bir kez denenir)
    init(keys: @escaping () -> [String],
         models: [String] = GeminiVoice.models,
         limit: TimeInterval = GeminiVoice.perModelLimit,
         budget: TimeInterval = GeminiVoice.budget,
         cooldown: TimeInterval = GeminiVoice.cooldown,
         now: @escaping () -> Date = { Date() },
         makeClient: ((String) -> GeminiClient)? = nil) {
        self.keysProvider = keys
        self.modelNames = models
        self.limit = limit
        self.budget = budget
        self.cooldown = cooldown
        self.now = now
        self.makeClient = makeClient ?? { model in GeminiClient(key: { keys().first ?? "" }, model: { model }) }
    }

    /// Tek anahtarlı kısa yol
    convenience init(key: @escaping () -> String,
                     models: [String] = GeminiVoice.models,
                     limit: TimeInterval = GeminiVoice.perModelLimit,
                     budget: TimeInterval = GeminiVoice.budget,
                     cooldown: TimeInterval = GeminiVoice.cooldown,
                     now: @escaping () -> Date = { Date() },
                     makeClient: ((String) -> GeminiClient)? = nil) {
        self.init(keys: { [key()] }, models: models, limit: limit, budget: budget, cooldown: cooldown, now: now,
                  makeClient: makeClient)
    }

    // MARK: İstek ve cevap (saf yardımcılar)

    /// Gemini 3.8 TTS isteği: metin parts[].text içinde, ses speechConfig.voiceConfig.voice altında
    static func requestBody(text: String, voice: String = voiceName) throws -> Data {
        let object: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": text]]]],
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": ["voiceConfig": ["voice": voice]]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// Cevaptaki ses verisi (candidates[0].content.parts[].inlineData.data, base64)
    static func audioBytes(from object: Any) throws -> Data {
        guard let obj = object as? [String: Any] else { throw GeminiError("Gemini sesi anlaşılmaz yanıt verdi.", .error) }
        let candidates = (obj["candidates"] as? [[String: Any]]) ?? []
        let parts = ((candidates.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        for part in parts {
            let inline = (part["inlineData"] as? [String: Any]) ?? (part["inline_data"] as? [String: Any])
            if let text = inline?["data"] as? String, let data = Data(base64Encoded: text), !data.isEmpty { return data }
        }
        throw GeminiError("Gemini ses döndürmedi.", .empty)
    }

    /// Dosyaya yazılacak WAV: yanıt zaten başlıklı WAV ("RIFF") ise olduğu gibi, ham 16 bit PCM ise 24 kHz tek kanal başlıkla sarılır
    static func wavFile(from audio: Data) -> Data {
        if audio.count > 12, audio.prefix(4) == Data("RIFF".utf8) { return audio }
        let samples: [Int16] = stride(from: 0, to: audio.count - 1, by: 2).map { i in
            Int16(bitPattern: UInt16(audio[audio.startIndex + i]) | (UInt16(audio[audio.startIndex + i + 1]) << 8))
        }
        return PCMRecorder.wav(samples: samples, sampleRate: sampleRate)
    }

    // MARK: SpeechSynthesizing

    func synthesize(_ text: String, to base: URL) async throws -> URL {
        var keys: [String] = []
        for raw in keysProvider() {
            let key = raw.trimmed
            if !key.isEmpty, !keys.contains(key) { keys.append(key) }
        }
        guard !keys.isEmpty, !modelNames.isEmpty else { throw GeminiError(Say.noKeyShort, .key) }
        if let until = disabledUntil, now() < until {
            throw GeminiError("Gemini sesi az önce çalışmadı; bir süre telefonun sesi kullanılıyor.", .error)
        }
        cancelled = false
        let body = try GeminiVoice.requestBody(text: text)
        var lastError = GeminiError("Gemini sesi üretilemedi.", .error)
        let started = now()
        var attempts = 0
        keyLoop: for key in keys {
            for model in modelNames {
                if attempts > 0, now().timeIntervalSince(started) >= budget { break keyLoop }
                attempts += 1
                do {
                    // Sunucu hatasında yeniden deneme yok: sınavda beklemek yerine hemen sıradaki motora / anahtara geçilir
                    let object = try await makeClient(model).generate(model: model, key: key, body: body, serverRetries: 0, timeout: limit)
                    if cancelled { throw CancellationError() }
                    let wav = GeminiVoice.wavFile(from: try GeminiVoice.audioBytes(from: object))
                    let url = base.appendingPathExtension("wav")
                    try wav.write(to: url, options: .atomic)
                    disabledUntil = nil
                    return url
                } catch let error as GeminiError {
                    lastError = error
                    if cancelled { throw CancellationError() }
                    // Anahtar geçersizse bu anahtarla başka model denemenin anlamı yok
                    if error.kind == .key { continue keyLoop }
                    // İnternet hiç yoksa başka anahtar da çalışmaz
                    if error.kind == .network, !error.timedOut { break keyLoop }
                }
            }
        }
        // İnternet sorunuysa (onarım zaten ilgilenir) süre tutulmaz; modelin/kotanın çalışmaması ise bir süre atlanır
        if cooldown > 0, lastError.kind != .network { disabledUntil = now().addingTimeInterval(cooldown) }
        throw lastError
    }

    func cancel() {
        cancelled = true
    }
}
