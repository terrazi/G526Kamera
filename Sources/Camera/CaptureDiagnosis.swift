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

    /// Cevaplanamayan sorular: yalnız Gemini'nin cevapladığı iki numaranın ARASINDA kalan, en çok `maxGapRun` uzunluğundaki boşluklar ("11, 12, 14"
    /// cevaplandıysa 13). Kanıt cevapların kendisidir: iki komşusu da cevaplanmış bir soru gerçekten atlanmıştır. Daha büyük boşluklar (taranmamış sayfa),
    /// cevapların önündeki ve arkasındaki numaralar ve yazı tanımanın karelerde gördüğü numaralar SÖYLENMEZ (kullanıcı 2026-11-19: "hep yanlış soruların
    /// gönderilmediğini söylüyor, söylediği soruların taranan sorularla ilgisi yok"; eski kural aralığın tamamını ve komşu sayfadan görünen numaraları sayıyordu).
    static func missingAnswers(answered: [Int]) -> [Int] {
        return gaps(in: answered)
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
        // Görülen numaraların arasındaki boşluk SÖYLENMEZ (yalnız deneme raporuna yazılır): yazı tanımanın okuduğu numaralar serbest taramada güvenilir
        // değildir, "Soru N görünmedi" çoğu kez yanlış çıkıyordu
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
    /// Toplu çekimde sesli konumlandırma açıkken kadrajın tarifi (kaç sayfa, kesik kenar, üstte ve altta hangi satır); yoksa nil
    var framing: String?
    /// Tarif bir düzeltme istiyor (kesik kenar, çok yakın, üst boş…): o zaman "Başlayabilirsiniz" denmez
    var framingIsCorrection = false

    /// Sesle söylenen karar: tarif varsa ve yazı okunuyorsa tarif önce söylenir
    var spoken: String {
        let verdict = baseVerdict
        guard let framing = framing, let text = text, text.isReadable else { return verdict }
        return framingIsCorrection ? framing : framing + " " + verdict
    }

    private var baseVerdict: String {
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

    /// Cevaplar okunduktan sonra: görünen ama cevaplanamayan sorular
    static func missingAnswers(_ numbers: [Int]) -> String {
        return "Soru \(CaptureDiagnosis.numberList(numbers)) cevaplanamadı. İsterseniz yeniden tarayın."
    }
    static let manyMissingAnswers = "Aradaki birkaç soru cevaplanamadı. İsterseniz o sayfayı yeniden tarayın."

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
