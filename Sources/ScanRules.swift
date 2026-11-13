import Foundation

/// Taramanın zamanlama ve bitiş kuralları. Saf mantıktır (zaman dışarıdan verilir): CI'da sınanır.
enum ScanRules {
    /// Belge görününce çekime başlamadan önce beklenen süre (sn)
    static let settleSeconds = 2.0
    /// Kadrajda belge bu kadar süre yoksa (sayfa sayısı bilinmiyorsa ya da sayfa alınmışsa) tarama biter
    static let emptyForEnd = 20.0
    /// Hiç yeni sayfa alınmadan bu kadar süre geçerse tarama biter
    static let noProgressForEnd = 90.0
    /// Aynı sahne kadrajda duruyorsa (sayfa çevrilmedi) bu kadar süre sonra yeniden çekilir
    static let retrySameSceneSeconds = 12.0
    /// Önceki çekime göre sahne farkı bundan büyükse sayfa çevrildi / kamera oynadı sayılır
    static let rearmDiff = 4.0
    /// Kamera görüntüsü bu süre gelmezse kamera kopmuş sayılır (sn)
    static let cameraLostSeconds = 12.0
    /// Kestirme geri dönüşü en çok bu kadar beklenir (sn)
    static let shortcutReturnSeconds = 40.0
    /// Kulaklık yokken cevapların okunması en çok bu kadar beklenir (sn)
    static let headphonesWaitSeconds = 600.0
    /// Bir sayfa için Gemini'ye gidecek en çok net kare sayısı
    static let maxStills = 8

    enum EndReason: Equatable {
        /// İstenen sayfa sayısı alındı
        case complete
        /// Toplam tarama süresi doldu
        case timeLimit
        /// Kadraj boşaldı ya da yeni sayfa gelmiyor
        case noMorePages
        /// Hazır uyarısına rağmen hiç evrak gösterilmedi
        case readyTimeout
        /// Kamera görüntüsü kesildi ve yeniden bağlanamadı
        case cameraLost
    }

    enum Verdict: Equatable {
        case keepGoing
        case finish(EndReason)
    }

    /// Her döngüde sorulur: tarama sürsün mü, bitsin mi. `pageTotal` 0 ise sayfa sayısı bilinmiyordur.
    static func verdict(pageTotal: Int, pages: Int, elapsed: TimeInterval, maxSeconds: TimeInterval,
                        emptyFor: TimeInterval, sinceProgress: TimeInterval) -> Verdict {
        if pageTotal > 0 && pages >= pageTotal { return .finish(.complete) }
        if maxSeconds > 0 && elapsed >= maxSeconds { return .finish(.timeLimit) }
        if pages > 0 && (emptyFor >= emptyForEnd || sinceProgress >= noProgressForEnd) { return .finish(.noMorePages) }
        return .keepGoing
    }

    /// Yeni bir çekim başlatılabilir mi (belge görünüyor): ilk çekimde hemen; sonrakilerde sayfa çevrilip kamera biraz durunca ya da
    /// aynı sahne uzun süre durursa
    static func canRearm(firstCapture: Bool, diffToCapture: Double, stillFor: TimeInterval, sinceLastWindow: TimeInterval,
                         stillNeeded: TimeInterval = 0.4) -> Bool {
        if firstCapture { return true }
        if diffToCapture > rearmDiff && stillFor >= stillNeeded { return true }
        return sinceLastWindow >= retrySameSceneSeconds
    }

    /// Hazır uyarısı: son söylenişten bu yana yeterli süre geçti mi (hiç söylenmediyse hemen)
    static func readyPromptDue(lastSpoken: TimeInterval?, now: TimeInterval, repeatSeconds: Int) -> Bool {
        guard let last = lastSpoken else { return true }
        return now - last >= Double(max(repeatSeconds, 5))
    }

    /// Hazır uyarısına rağmen hiç evrak gösterilmedi: vazgeçme süresi doldu mu
    static func readyGaveUp(waited: TimeInterval, maxMinutes: Int) -> Bool {
        return maxMinutes > 0 && waited >= Double(maxMinutes) * 60
    }

    private static func sayfa(_ number: Int) -> String {
        return TurkishNumbers.capitalised(TurkishNumbers.ordinal(number)) + " sayfa"
    }

    /// "Birinci sayfa alındı."
    static func pageTakenText(_ number: Int) -> String {
        return "\(sayfa(number)) alındı."
    }

    /// Kenar adları cümlede: "alt", "üst ve alt", "üst, alt ve sağ"
    static func sideList(_ sides: [PageEdges.Side]) -> String {
        let words = sides.map { $0.word }
        switch words.count {
        case 0: return ""
        case 1: return words[0]
        default: return words.dropLast().joined(separator: ", ") + " ve " + words[words.count - 1]
        }
    }

    /// Videoda sayfanın bazı kenarları görülmedi, sayfa yeniden isteniyor
    static func coverageRetryText(_ missing: [PageEdges.Side]) -> String {
        let one = missing.count == 1
        return "Sayfanın \(sideList(missing)) \(one ? "kenarı" : "kenarları") görünmedi. Sayfayı yeniden gezdirin."
    }

    /// Deneme sınırı doldu, sayfa eksik görünüyor ama olduğu gibi alındı
    static func pageTakenIncompleteText(_ number: Int, missing: [PageEdges.Side]) -> String {
        let one = missing.count == 1
        return "\(sayfa(number)) alındı; sayfanın \(sideList(missing)) \(one ? "kenarı" : "kenarları") görünmemiş olabilir."
    }
}

/// Okunacak cevap cümleleri ve kayıt metni
enum ReadingPlan {
    /// Sırayla okunacak cümleler (soru numarasına göre)
    static func lines(_ records: [AnswerRecord], codes: [(letter: String, word: String)]) -> [String] {
        return records.sorted { $0.number < $1.number }.map { AnswerService.spokenLine($0, codes: codes) }
    }

    /// Okunamayan ya da hiç cevabı gelmeyen soru numaraları
    static func unanswered(requested: [Int], records: [AnswerRecord]) -> [Int] {
        let good = Set(records.filter { $0.status != AnswerRecord.unread && !$0.letter.isEmpty }.map { $0.number })
        return Array(Set(requested)).sorted().filter { !good.contains($0) }
    }

    /// Okuma sonunda söylenecek: "Okunamayan sorular: 3 ve 7."
    static func unansweredText(_ numbers: [Int]) -> String {
        guard !numbers.isEmpty else { return "" }
        return numbers.count == 1
            ? "\(numbers[0]). soru okunamadı ya da cevaplanamadı."
            : "Okunamayan ya da cevaplanamayan sorular: \(TurkishNumbers.spokenList(numbers))."
    }

    /// Cevaplar.txt içeriği: her satır bir soru
    static func fileText(_ records: [AnswerRecord], unanswered: [Int], codes: [(letter: String, word: String)]) -> String {
        var out: [String] = []
        for r in records.sorted(by: { $0.number < $1.number }) {
            if r.status == AnswerRecord.unread || r.letter.isEmpty {
                out.append("\(r.number). soru: okunamadı")
                continue
            }
            let code = codes.first(where: { $0.letter == r.letter })?.word ?? ""
            var line = "\(r.number). soru: \(r.letter)"
            if !code.isEmpty { line += " (\(code))" }
            if !r.value.isEmpty { line += " — \(r.value)" }
            if r.status == AnswerRecord.unsure { line += " [emin değil]" }
            out.append(line)
        }
        let missing = unanswered.filter { n in !records.contains(where: { $0.number == n }) }
        for n in missing { out.append("\(n). soru: cevap yok") }
        return out.joined(separator: "\n") + "\n"
    }
}

/// Bir taramanın klasör adı: Sinav-20261113-0930
enum RunName {
    static func make(_ date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMdd-HHmm"
        return "Sinav-" + f.string(from: date)
    }
}
