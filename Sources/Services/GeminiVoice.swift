import Foundation

/// Gemini sesi (Gemini TTS): cevabı Gemini'nin doğal sesiyle dosyaya çevirir. Cevap geldiği anda (internet varken) üretilir ve
/// soru dosyasına kaydedilir; test sonundaki çevrimdışı tekrar bu dosyaları çalar, bu yüzden tekrarda internet gerekmez.
/// Başarısız olursa (kota, internet, model) sıradaki motor olan telefonun sesi devreye girer.
@MainActor
final class GeminiVoice: SpeechSynthesizing {
    /// Denenecek TTS modelleri (aynı anahtarla)
    static let models = ["gemini-3.8-flash-tts", "gemini-3.8-flash-lite-tts"]
    static let voiceName = "Kore"
    /// Sınavda beklemeyi uzatmamak için her model için en çok bekleme (sn)
    static let perModelLimit: TimeInterval = 12
    static let sampleRate = 24_000

    private let keyProvider: () -> String
    private let modelNames: [String]
    private let limit: TimeInterval
    private let makeClient: (String) -> GeminiClient
    private var cancelled = false

    init(key: @escaping () -> String,
         models: [String] = GeminiVoice.models,
         limit: TimeInterval = GeminiVoice.perModelLimit,
         makeClient: ((String) -> GeminiClient)? = nil) {
        self.keyProvider = key
        self.modelNames = models
        self.limit = limit
        self.makeClient = makeClient ?? { model in GeminiClient(key: key, model: { model }) }
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
        let key = keyProvider().trimmed
        guard !key.isEmpty, !modelNames.isEmpty else { throw GeminiError(Say.noKeyShort, .key) }
        cancelled = false
        let body = try GeminiVoice.requestBody(text: text)
        var lastError = GeminiError("Gemini sesi üretilemedi.", .error)
        for model in modelNames {
            do {
                // Sunucu hatasında yeniden deneme yok: sınavda beklemek yerine hemen sıradaki motora geçilir
                let object = try await makeClient(model).generate(model: model, key: key, body: body, serverRetries: 0, timeout: limit)
                if cancelled { throw CancellationError() }
                let wav = GeminiVoice.wavFile(from: try GeminiVoice.audioBytes(from: object))
                let url = base.appendingPathExtension("wav")
                try wav.write(to: url, options: .atomic)
                return url
            } catch let error as GeminiError {
                lastError = error
                if cancelled { throw CancellationError() }
            }
        }
        throw lastError
    }

    func cancel() {
        cancelled = true
    }
}
