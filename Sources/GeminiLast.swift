import Foundation

/// Gemini'nin verdiği son cevap. "Son yanıtı tekrarla" denince Gemini'ye istek gitmeden buradan okunur (ücret yazılmaz).
struct LastAnswer: Codable, Equatable {
    var answer: String
    /// Bu cevap toplu cevapsa verdiği en büyük soru numarası (0 = toplu değil)
    var batch: Int
    var question: String
}

/// Son cevabı diskte tutar: uygulama kapanıp açılsa da tekrar edilebilir.
final class LastAnswerStore {
    private let url: URL

    init(url: URL? = nil) {
        if let url = url {
            self.url = url
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            self.url = base.appendingPathComponent("gemini-son-cevap.json")
        }
    }

    func load() -> LastAnswer? {
        guard let data = try? Data(contentsOf: url),
              let item = try? JSONDecoder().decode(LastAnswer.self, from: data),
              !item.answer.trimmed.isEmpty else { return nil }
        return item
    }

    func save(_ item: LastAnswer) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(item) { try? data.write(to: url, options: .atomic) }
    }
}
