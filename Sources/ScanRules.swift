import Foundation

/// Taramanın zamanlama ve bitiş kuralları. Saf mantıktır (zaman dışarıdan verilir): CI'da sınanır.
enum ScanRules {
    /// Belge görününce çekime başlamadan önce beklenen süre (sn)
    static let settleSeconds = 2.0
    /// Bir çekimin süresi (sn): kare toplama ve video
    static let windowSeconds = 5.0
    /// Soru sayısı biliniyorsa: kadrajda belge bu kadar süre yoksa eksik sorular sorulur
    static let emptyForMissing = 10.0
    /// Soru sayısı bilinmiyorsa: kadrajda belge bu kadar süre yoksa tarama biter
    static let emptyForEnd = 20.0
    /// Soru sayısı bilinmiyorsa: hiç yeni soru alınmadan bu kadar süre geçerse tarama biter
    static let noProgressForEnd = 90.0
    /// Belge göründükten sonra yazı kadraja tam sığana ("Tamam" denene) kadar çekim bu kadar (sn) ertelenir; süre dolunca yine de çekilir
    static let framingWaitSeconds = 15.0
    /// Aynı sahne kadrajda duruyorsa (sayfa çevrilmedi) bu kadar süre sonra yeniden çekilir
    static let retrySameSceneSeconds = 12.0
    /// Önceki çekime göre sahne farkı bundan büyükse sayfa çevrildi / kamera oynadı sayılır (GuidanceConfig.changeToRearm ile aynı)
    static let rearmDiff = 4.0
    /// Eksik sorular bu aralıkla yeniden hatırlatılır (sn)
    static let missingRepeatSeconds = 20.0
    /// Aynı uyarı bu süreden önce yeniden söylenmez (sn)
    static let sameWarningGap = 10.0
    /// Kamera görüntüsü bu süre gelmezse kamera kopmuş sayılır (sn)
    static let cameraLostSeconds = 12.0
    /// Kestirme geri dönüşü en çok bu kadar beklenir (sn)
    static let shortcutReturnSeconds = 40.0
    /// Kulaklık yokken cevapların okunması en çok bu kadar beklenir (sn)
    static let headphonesWaitSeconds = 600.0

    enum EndReason: Equatable {
        /// Bütün sorular alındı (ya da deneme sınırı dolduğu için okunamadı sayıldı)
        case complete
        /// Toplam tarama süresi doldu
        case timeLimit
        /// Soru sayısı girilmemişti: belge görünmüyor / yeni soru gelmiyor
        case noMoreQuestions
        /// Eksik sorular için bekleme süresi doldu
        case missingGaveUp
        /// Hazır uyarısına rağmen hiç evrak gösterilmedi
        case readyTimeout
        /// Kamera görüntüsü kesildi ve yeniden bağlanamadı
        case cameraLost
    }

    enum Verdict: Equatable {
        case keepGoing
        /// Eksik soruları söyle ve bekle
        case askMissing
        case finish(EndReason)
    }

    /// Her döngüde sorulur: tarama sürsün mü, eksik sorular mı sorulsun, bitsin mi
    static func verdict(total: Int, accepted: Int, complete: Bool, elapsed: TimeInterval, maxSeconds: TimeInterval,
                        emptyFor: TimeInterval, sinceProgress: TimeInterval, asked: Bool, deadlinePassed: Bool) -> Verdict {
        if complete { return .finish(.complete) }
        if maxSeconds > 0 && elapsed >= maxSeconds { return .finish(.timeLimit) }
        if total <= 0 {
            if accepted > 0 && (emptyFor >= emptyForEnd || sinceProgress >= noProgressForEnd) { return .finish(.noMoreQuestions) }
            return .keepGoing
        }
        if asked && deadlinePassed { return .finish(.missingGaveUp) }
        if !asked && accepted > 0 && emptyFor >= emptyForMissing { return .askMissing }
        return .keepGoing
    }

    /// Yeni bir çekim başlatılabilir mi (belge sabit görünüyor): ilk çekimde hemen; sonrakilerde sayfa çevrilince ya da aynı sahne uzun süre durursa
    static func canRearm(firstCapture: Bool, diffToCapture: Double, stillFor: TimeInterval, sinceLastWindow: TimeInterval,
                         stillNeeded: TimeInterval = 0.4) -> Bool {
        if firstCapture { return true }
        if diffToCapture > rearmDiff && stillFor >= stillNeeded { return true }
        return sinceLastWindow >= retrySameSceneSeconds
    }

    /// Canlı okumanın sonucu bu kadar saniyeden eskiyse kullanılmaz
    static let liveMaxAge = 8.0

    /// Canlı okuma sonucu hâlâ geçerli mi: yeterince yeni ve okunan kareden beri sahne değişmemiş (kamera / sayfa oynamamış)
    static func liveVerdictValid(takenAt: TimeInterval, now: TimeInterval, sampleArrived: TimeInterval, stillFor: TimeInterval) -> Bool {
        let age = now - takenAt
        guard age >= 0, age <= liveMaxAge else { return false }
        return takenAt >= sampleArrived - stillFor - 0.3
    }

    /// Çekimden önce kadraj denetimi (yarım soru kalmasın). `live`: geçerli canlı okuma varsa "görünen sorular tam sığıyor mu" kararı;
    /// o yoksa konum tarifinin (kamera durgunken ölçülen) son önerisi "tamam" ise hazırdır. Sığmıyorsa yönlendirme sürer;
    /// `framingWaitSeconds` dolunca yine de çekilir.
    static func framingReady(docFor: TimeInterval, advice: GuidanceAdvice?, adviceAge: TimeInterval, live: Bool? = nil) -> Bool {
        if docFor >= settleSeconds + framingWaitSeconds { return true }
        if let l = live { return l }
        guard let a = advice, adviceAge < 2 else { return false }
        return a == .ok
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

    /// Eksik soru cümlesi: "15 ve 22 eksik. İlgili sayfayı kameraya tutun."
    static func missingText(_ numbers: [Int]) -> String {
        guard !numbers.isEmpty else { return "" }
        return numbers.count == 1
            ? "\(numbers[0]). soru eksik. İlgili sayfayı kameraya tutun."
            : "\(TurkishNumbers.spokenList(numbers)) eksik. İlgili sayfaları kameraya tutun."
    }

    /// Alınan sorular cümlesi: "12 alındı." / "12, 13 ve 14 alındı."
    static func acceptedText(_ numbers: [Int]) -> String {
        guard !numbers.isEmpty else { return "" }
        return "\(TurkishNumbers.spokenList(numbers)) alındı."
    }

    /// "On ikinci sorunun devamını kameraya tutun."
    static func continueText(_ number: Int) -> String {
        return "\(TurkishNumbers.capitalised(TurkishNumbers.ordinal(number))) sorunun devamını kameraya tutun."
    }

    /// Sorunun alt kısmı başından önce çekildi (karışık sıra): başı istenir
    static func headText(_ number: Int) -> String {
        return "\(TurkishNumbers.capitalised(TurkishNumbers.ordinal(number))) sorunun alt kısmı alındı. Üst kısmını da kameraya tutun."
    }
}

/// Aynı cümlenin kısa sürede yeniden söylenmesini engeller ("aynı uyarı en az 10 sn arayla")
struct RepeatGate {
    private var last: [String: TimeInterval] = [:]

    /// Söylenebilirse true döner ve söylenmiş sayar
    mutating func allow(_ text: String, now: TimeInterval, gap: TimeInterval = ScanRules.sameWarningGap) -> Bool {
        if let t = last[text], now - t < gap { return false }
        last[text] = now
        return true
    }

    mutating func reset() { last = [:] }
}

/// Soru PDF'lerinin gruplanması ve adları
enum QuestionGroups {
    /// Numaralar küçükten büyüğe `size`'lık gruplara bölünür: [1,2,3,4,5] ve 2 → [[1,2],[3,4],[5]]
    static func split(_ numbers: [Int], size: Int) -> [[Int]] {
        let sorted = Array(Set(numbers)).sorted()
        let n = max(size, 1)
        var out: [[Int]] = []
        var i = 0
        while i < sorted.count {
            out.append(Array(sorted[i..<min(i + n, sorted.count)]))
            i += n
        }
        return out
    }

    /// S12.pdf ; grup için S12-14.pdf
    static func pdfName(_ numbers: [Int]) -> String {
        guard let first = numbers.min(), let last = numbers.max() else { return "S0.pdf" }
        return first == last ? "S\(first).pdf" : "S\(first)-\(last).pdf"
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
