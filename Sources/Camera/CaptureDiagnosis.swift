import Foundation

/// Çekimin teşhisi (kullanıcı kararı 2026-11-17): kamera sayfaya çok yakınsa, görüntü bulanıksa ya da kadraj bazı soruları kaçırıyorsa çekim bittiğinde
/// kullanıcıya TEK cümleyle söylenir ve bir sonraki çekim buna göre düzeltilir. Gönderimi engellemez (çekim her durumda Gemini'ye gider).
///
/// Ölçüler çekim sırasında zaten hesaplanır: pencere kazananlarının netliği, telefonun yazı tanımasının okuyabildiği pencere sayısı ve karelerde görülen
/// soru numaraları. Eşikler cihazda sınanmadı: "Deneme çekimi" raporunda ham sayılar yazılır, eşikler oradan ayarlanır.
struct CaptureDiagnosis: Equatable {
    enum Hint: Equatable {
        /// Yeterince yazı okundu (ya da yazı tanıma çalışmadığı için karar verilemedi)
        case good
        /// Hiçbir karede yazı okunamadı ve görüntü bulanık: kamera çok yakın ya da odak dışı
        case blurry
        /// Hiçbir karede yazı okunamadı ama görüntü net: sayfa kadrajda değil ya da yazı çok küçük
        case noText
        /// Karelerin çoğunda yazı okunamadı
        case mostlyUnreadable
    }

    /// Yazı tanımadan geçen pencere sayısı (yazı tanıma hiç çalışmadıysa 0: teşhis konmaz)
    var windows = 0
    /// Yazısı okunabilen pencere sayısı
    var readableWindows = 0
    /// Pencere kazananlarının netlik puanının ortancası
    var medianSharpness = 0.0
    /// Karelerde görülen soru numaraları (artan, tekrarsız)
    var questionNumbers: [Int] = []
    /// En iyi karesi bile bozuk (bloklaşmış) çıkan pencere sayısı; bu pencereler PDF'te yer almaz (rapor için)
    var damagedWindows = 0

    /// Ortanca netlik bunun altındaysa görüntü bulanık sayılır
    static let blurrySharpness = 60.0
    /// Okunan pencere oranı bunun altındaysa "çoğunda okunamadı" denir
    static let lowReadableRatio = 0.25
    /// En çok bu kadar eksik numara tek tek söylenir; fazlası "birçok" denir
    static let maxListed = 6
    /// Cevapların ilk ve son numarası arası bundan açıksa (yanlış okunmuş bir sayı) eksik aranmaz
    static let maxSpan = 150

    var readableRatio: Double {
        return windows == 0 ? 0 : Double(readableWindows) / Double(windows)
    }

    var hint: Hint {
        guard windows > 0 else { return .good }
        if readableWindows == 0 { return medianSharpness < CaptureDiagnosis.blurrySharpness ? .blurry : .noText }
        if readableRatio < CaptureDiagnosis.lowReadableRatio { return .mostlyUnreadable }
        return .good
    }

    /// Görülen numaraların arasında atlananlar ("11, 12, 14" görüldüyse 13)
    var missingNumbers: [Int] {
        return CaptureDiagnosis.gaps(in: questionNumbers)
    }

    /// Ardışık iki görülen numara arasında en çok `maxGapRun` numara eksikse o eksikler. Daha büyük boşluklar sayılmaz: sayfa sınırı, alt madde numarası
    /// ("1. 2. 3." öncüller) ya da yanlış okunmuş bir sayı olabilir; yalnız "kadraj iki görünen sorunun arasındakini atladı" durumu söylenir.
    static let maxGapRun = 2

    static func gaps(in numbers: [Int]) -> [Int] {
        let sorted = Array(Set(numbers)).sorted()
        var result: [Int] = []
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            let run = b - a - 1
            if run >= 1 && run <= maxGapRun { result += Array((a + 1)..<b) }
        }
        return result
    }

    /// Cevapların numaraları (Gemini'nin okuduğu) arasında atlananlar; ayrıca telefonun karelerde gördüğü ama cevaplanmayan, cevaplanan en büyük numaranın hemen
    /// ardındaki (en çok `edgeReach` numara) sorular. Daha uzaktaki görülen numaralar (alt maddeler, puan, yıl gibi yanlış okumalar) sayılmaz.
    /// Numaralı cevap yoksa ya da aralık `maxSpan`'dan açıksa boş.
    static let edgeReach = 3

    static func missingAnswers(answered: [Int], seen: [Int]) -> [Int] {
        let done = Set(answered)
        guard let low = done.min(), let high = done.max() else { return [] }
        let edge = seen.filter { $0 > high && $0 <= high + edgeReach }
        let top = max(high, edge.max() ?? high)
        guard top - low <= maxSpan else { return [] }
        return (low...top).filter { !done.contains($0) }
    }

    /// "4", "4 ve 7", "4, 7 ve 9"
    static func numberList(_ numbers: [Int]) -> String {
        let texts = numbers.map { String($0) }
        switch texts.count {
        case 0: return ""
        case 1: return texts[0]
        default: return texts.dropLast().joined(separator: ", ") + " ve " + (texts.last ?? "")
        }
    }

    /// Kullanıcıya söylenecek tek bakışlık uyarı; sorun yoksa boş
    var spoken: String {
        var parts: [String] = []
        switch hint {
        case .good: break
        case .blurry: parts.append(CaptureSay.blurry)
        case .noText: parts.append(CaptureSay.noText)
        case .mostlyUnreadable: parts.append(CaptureSay.mostlyUnreadable)
        }
        let missing = missingNumbers
        if !missing.isEmpty {
            parts.append(missing.count <= CaptureDiagnosis.maxListed ? CaptureSay.missingSeen(missing) : CaptureSay.manyMissingSeen)
        }
        return parts.joined(separator: " ")
    }

    /// Deneme çekiminin raporu (rapor.txt): ham sayılar eşiklerin ayarlanabilmesi için yazılır
    func report(seconds: Int, measured: Int, selected: Int, readable: Int) -> String {
        let perSecond = measured / max(seconds, 1)
        var lines = ["Deneme çekimi raporu", ""]
        lines.append("Süre: \(seconds) sn; ölçülen kare: \(measured) (yaklaşık saniyede \(perSecond))")
        lines.append("Yazı tanımadan geçen pencere: \(windows); yazısı okunan: \(readableWindows) (%\(Int((readableRatio * 100).rounded())))")
        lines.append("Netlik (ortanca): \(Int(medianSharpness.rounded())); bulanık eşiği: \(Int(CaptureDiagnosis.blurrySharpness))")
        lines.append("Bozuk (bloklaşmış) pencere: \(damagedWindows); bu pencereler PDF'e yalnız sağlam kare yetmezse girer")
        lines.append("PDF'e giren kare: \(selected) (yazısı okunan: \(readable))")
        lines.append("Görülen soru numaraları: " + (questionNumbers.isEmpty ? "yok" : questionNumbers.map { String($0) }.joined(separator: ", ")))
        let missing = missingNumbers
        lines.append("Arada görünmeyen numaralar: " + (missing.isEmpty ? "yok" : missing.map { String($0) }.joined(separator: ", ")))
        lines.append("")
        lines.append("Sonuç: " + (spoken.isEmpty ? "Yazı yeterince okundu; bu kadrajla çekim yapılabilir." : spoken))
        return lines.joined(separator: "\n")
    }

    /// Medyan (boşsa 0)
    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}

/// Başla denmeden önce canlı görüntüye kısa bir bakış ("kadraj kontrolü"): kameranın o anki en net karesi ve o karedeki yazı
struct ViewCheck: Equatable {
    /// İncelenen taze kare sayısı (0: görüntü gelmiyor)
    var frames = 0
    /// En net karenin netlik puanı
    var sharpness = 0.0
    /// En net karedeki yazı (yazı tanıma çalışmadıysa nil)
    var text: TextScore?

    /// Sesle söylenen karar
    var spoken: String {
        if frames == 0 { return CaptureSay.viewNoFrames }
        guard let text = text else { return CaptureSay.viewNoOCR }
        if text.isReadable {
            if !text.options.isEmpty || !text.questionNumbers.isEmpty { return CaptureSay.viewGood }
            return CaptureSay.viewTextOnly
        }
        return sharpness < CaptureDiagnosis.blurrySharpness ? CaptureSay.viewBlurry : CaptureSay.viewNoText
    }
}

/// Çekim teşhisinin ve kadraj kontrolünün söylenen cümleleri
enum CaptureSay {
    static let blurry = "Görüntüler bulanık; kamera sayfaya çok yakın ya da odak dışı olabilir. Bir sonraki çekimde biraz uzaklaşıp sabit tutun."
    static let noText = "Hiçbir karede yazı okunamadı; sayfa kadrajda olmayabilir ya da yazı çok küçük. Kamerayı sayfaya doğrultup sabit tutun."
    static let mostlyUnreadable = "Karelerin çoğunda yazı okunamadı; kamerayı daha sabit tutun ve sayfaya çok yaklaşmayın."
    static func missingSeen(_ numbers: [Int]) -> String {
        return "Soru \(CaptureDiagnosis.numberList(numbers)) görünmedi."
    }
    static let manyMissingSeen = "Birçok soru numarası görünmedi."

    /// Cevaplar okunduktan sonra: görünen ama cevaplanamayan sorular
    static func missingAnswers(_ numbers: [Int]) -> String {
        return "Soru \(CaptureDiagnosis.numberList(numbers)) cevaplanamadı; okunamamış ya da kadraja tam girmemiş olabilir. İsterseniz o kısımları daha sabit gösterip yeniden çekin."
    }
    static let manyMissingAnswers = "Birçok soru cevaplanamadı; okunamamış ya da kadraja tam girmemiş olabilir. İsterseniz o kısımları daha sabit gösterip yeniden çekin."

    // Kadraj kontrolü
    static let viewGood = "Kadraj iyi: yazı net okunuyor. Başlayabilirsiniz."
    static let viewTextOnly = "Yazı okunuyor ama soru numarası ve şıklar görünmüyor; kamerayı soruların üzerine getirin."
    static let viewBlurry = "Görüntü bulanık; kamera sayfaya çok yakın olabilir. Biraz uzaklaşın."
    static let viewNoText = "Yazı okunamıyor; sayfa kadrajda değil ya da yazı çok küçük. Sayfayı kadraja alın."
    static let viewNoOCR = "Yazı tanıma çalışmadı, kadraj değerlendirilemedi."
    static let viewNoFrames = "Kameradan görüntü gelmiyor."
    static let viewNotReady = "Kadraj kontrolü için kamera hazır olmalı. Başlat'tan sonra kamera bağlanınca söyleyin."

    // Deneme çekimi
    static func trialIntro(seconds: Int) -> String {
        return "Deneme çekimi başlıyor: \(seconds) saniye. Hiçbir şey Gemini'ye gönderilmeyecek. Sayfaları gerçek çekimdeki gibi gösterin."
    }
    static let trialNotReady = "Deneme çekimi için kamera hazır olmalı. Başlat'tan sonra kamera bağlanınca söyleyin."
    static let trialBusy = "Deneme çekimi zaten sürüyor."
    static func trialDone(_ diagnosis: String) -> String {
        let tail = diagnosis.isEmpty ? "Yazı yeterince okundu; bu kadrajla çekim yapılabilir." : diagnosis
        return "Deneme bitti. " + tail + " Video, PDF ve rapor telefonda Cekimler klasöründeki Deneme klasörüne yazıldı."
    }
    static let trialFailed = "Deneme çekimi yapılamadı."
}
