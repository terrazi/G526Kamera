import Foundation
import CoreGraphics
import CoreVideo
import Vision

// MARK: - Kadrajdaki satırlar

/// Satırın baştan ya da sondan birkaç sözcüğü; iki sütun görünüyorsa hangi yanda olduğu ("solda" / "sağda")
struct LineEnd: Equatable {
    var side: String?
    var words: String

    /// "solda mercimek çorbası" ya da yalnız "mercimek çorbası"
    var phrase: String {
        if let side = side { return side + " " + words }
        return words
    }
}

/// Kadrajda tam görünen bir sorunun kimliği: numarası (okunduysa) ve sözcükleri (dört harften uzun makul sözcükler, küçük harf). Aynı soru sonradan yeniden
/// görününce "zaten alındı" denebilsin diye kullanılır (kullanıcı isteği 2026-11-18); yazı tanıma gürültüsü yüzünden sözcük örtüşmesine bakılır.
struct QuestionMark: Equatable {
    var number: Int?
    var keys: Set<String>

    /// Sözcük kümesi bu kadar sözcükten azsa kimlik için güvenilmez: numaraya bakılır
    static let minKeys = 5
    /// İki sorunun sözcüklerinin (küçük kümeye göre) örtüşmesi bu orana ulaşırsa aynı sorudur
    static let sameOverlap = 0.5

    func isSame(as other: QuestionMark) -> Bool {
        if keys.count >= QuestionMark.minKeys && other.keys.count >= QuestionMark.minKeys {
            return FramingCoach.overlap(keys, other.keys) >= QuestionMark.sameOverlap
        }
        if let a = number, let b = other.number { return a == b }
        return false
    }
}

/// Kadrajın en üstündeki ve en altındaki TAM satırlar ve kenara dayanıp yarım kalan satır var mı (kullanıcı kararı 2026-11-17: "en alttaki satır …
/// ile bitiyor" diye kameranın nereye kadar gördüğü söylensin). Saf mantık: Vision kutularından kurulur, birim testle denenir.
struct ViewLines: Equatable {
    /// Üstteki tam satır(lar): tek sütunda bir, iki sütunda sol ve sağ için birer tane
    var starts: [LineEnd] = []
    /// Alttaki tam satır(lar)
    var ends: [LineEnd] = []
    /// Bir satır kadrajın üst / alt kenarına dayanıyor (yarım görünüyor)
    var topCut = false
    var bottomCut = false
    /// Güveni yeterli satırlardaki harf + rakam sayısı: yazı program tarafından okunabiliyor mu (kullanıcı kararı 2026-11-18: okunuyorsa daha mükemmel
    /// görüntü aranmaz, ilk yeterli görüntü alınır)
    var chars = 0
    /// Okunan satırlardaki sık kullanılan işlev sözcüklerinin sayısı (bkz. `TextSense`): yazı baş aşağı okunmuyor mu diye bakılır
    var sense = 0
    /// Kadrajda baştan sona (numara / gövde, A–E şıkları) TAM görünen soru sayısı (numarası okunmasa da şıklardan sayılır). Kullanıcı kararı 2026-11-18:
    /// en az bir soru tam görünüyorsa kadraj kabul edilir; yandaki ve alttaki kesik sorular "ekrana sığmıyor" sebebi olmaz
    var completeQuestions = 0
    /// Tam görünen soruların kimlikleri (`completeQuestions` kadar)
    var completeMarks: [QuestionMark] = []
    /// Kadrajın en üstündeki soru ya da paragrafın KESİK olduğuna dair kanıt YOK: ilk satır kenara dayanmıyor ve numarasız bir şık satırıyla (önceki sorunun
    /// kuyruğu) başlamıyor
    var topComplete = false
    /// Kadrajın en altındaki soru ya da paragrafın KESİK olduğuna dair kanıt YOK: son satır kenara dayanmıyor; son soru numarasından sonra E şıkkı
    /// görünüyor ya da yazı alt kenara yakın bitmiyor
    var bottomComplete = false

    /// Kadrajdaki yazı bir PARAGRAF: numaralı soru ve A–E şık yapısı yok (kullanıcı kararı 2026-11-18: soru başı numara, sonu E şıkkı; bu yapı görülmüyorsa
    /// metin paragraf sayılır ve ilk / son satırın sözcükleri söylenip kesikse yön istenir)
    var paragraph = false
    /// Gürültü sayılıp atlanan satır sayısı (dikey yazı, çizgi kırıntısı, orta oluktaki kitap adı…): bkz. `isBodyText`
    var ignored = 0
    /// Üst / alt "kesik" sayılmışsa NEDEN (yalnız günlük için: cihazda yanlış "Metin kesik" uyarısı çözümlenebilsin)
    var cutReason: String?

    /// Kadrajda başından sonuna (E şıkkı dahil) görünen soruların numaraları: ardışık ve artan değilse (yazı tanıma bir rakamı yanlış okumuş olabilir) boş
    var questions: [Int] = []
    /// Sıradaki soru: kadrajda yarım kalan (numarası görünen) soru, yoksa son tam sorunun ardından gelen numara; güvenilmezse nil
    var nextQuestion: Int?

    /// Kadrajdaki okunaklı, kenara dayanmayan satırların sözcükleri (küçük harf, en az 4 harf): parçalı çekimde iki kadrajın örtüştüğü bununla ölçülür
    var words: Set<String> = []
    /// Alt uçtaki "açık blok"un sözcükleri (kullanıcı kararı 2026-11-18: kadraja sığmayan 3/4 sayfalık paragraf parça parça çekilir, her parça öncekiyle
    /// örtüşür): alttan kesilen sorunun numara satırı ve kökü; paragrafta ya da biten soruda son üç satır. Sonraki kadraj bunları da içermelidir
    var anchor: Set<String> = []
    /// Açık bloğun en üstteki satırının baş sözcükleri: kullanıcıya "… satırı ekranda kalsın" diye söylenir
    var anchorHead: String?

    /// Yazı okunabiliyor (bkz. `SeriesSelection.minChars`)
    var isReadable: Bool { return chars >= SeriesSelection.minChars }

    /// Satır kutusu kenara bu orandan yakınsa kenara dayalı (kesik) sayılır
    static let edgeEpsilon = 0.012
    /// Bir satırdan en çok kaç sözcük söylenir
    static let maxWords = 4
    /// "Satır" sayılması için en az sözcük (sayfa numarası, tek sözcüklük kırıntı satır sayılmaz)
    static let minWords = 3

    /// Yazıyı sözcüklere ayırır: uçlardaki noktalama atılır, harf ya da rakam taşımayan parçalar düşer
    static func words(_ text: String) -> [String] {
        let junk = CharacterSet.punctuationCharacters.union(.symbols)
        return text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map { String($0).trimmingCharacters(in: junk) }
            .filter { $0.rangeOfCharacter(from: .alphanumerics) != nil }
    }

    private struct Item {
        /// Satırın başındaki / sonundaki makul sözcükler (söylenecek); yazı tanıma bozuk okuduysa nil
        var head: String?
        var tail: String?
        var top: Double
        var bottom: Double
        var midX: Double
    }

    /// Orta oluk bandı: bu aralığa tümüyle sığan dar kutular iki sütunu ayıran süs / kitap adıdır, soru metni değildir
    static let gutterMin = 0.42
    static let gutterMax = 0.58
    static let gutterWidth = 0.14

    /// Komşu sayfanın kadraja giren kesik şeridi: kutu kadrajın sol / sağ kenarına dayanıyor ve yalnız dış %28'lik banda sığıyor (kullanıcı bildirimi
    /// 2026-11-18: açık kitapta iki sayfa birden görününce yandaki sayfanın yarım metni soru kesik sanılıyordu; ana gövde sağlamdı)
    static let peripheralBand = 0.28

    static func isPeripheral(_ box: CGRect) -> Bool {
        let minX = Double(box.minX)
        let maxX = Double(box.maxX)
        return (maxX > 1 - edgeEpsilon && minX > 1 - peripheralBand) || (minX < edgeEpsilon && maxX < peripheralBand)
    }

    /// Yazı tanıma bozuk okuduğunda ("rJroon W lo I••w") çıkan sözcükler söylenmez ve karar vermekte kullanılmaz. Makul sözcük: yalnız harf, kesme işareti
    /// ve tire; en az iki harf ve bir ünlü; harf sayısı kadar büyük harf (tamamı büyük) ya da yalnız ilk harf büyük; rakamlar ve A–E şık harfi geçer.
    static func isPlausibleWord(_ word: String) -> Bool {
        let letters = word.filter { $0.isLetter }
        if letters.isEmpty { return !word.isEmpty && word.count <= 4 && word.allSatisfy { $0.isNumber } }
        if letters.count == 1 { return word.count == 1 && "ABCDE".contains(letters) }
        guard word.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" }) else { return false }
        guard letters.contains(where: { "aeıioöuüAEIİOÖUÜ".contains($0) }) else { return false }
        let upper = letters.filter { $0.isUppercase }.count
        if upper == 0 || upper == letters.count { return true }
        return upper == 1 && letters.first?.isUppercase == true
    }

    /// Satırdaki makul sözcüklerin oranı (harfsiz sözcükler sayılmaz): bundan azsa satır bozuk okunmuştur
    static func plausibleRatio(_ text: String) -> Double {
        let candidates = words(text).filter { $0.contains(where: { $0.isLetter }) }
        guard !candidates.isEmpty else { return 0 }
        return Double(candidates.filter { isPlausibleWord($0) }.count) / Double(candidates.count)
    }

    static let minPlausible = 0.6

    /// Baştan en çok `maxWords` ardışık makul sözcük; `minWords`'ten azsa nil
    static func plausibleHead(_ words: [String]) -> String? {
        var run: [String] = []
        for w in words {
            guard isPlausibleWord(w), run.count < maxWords else { break }
            run.append(w)
        }
        return run.count >= minWords ? run.joined(separator: " ") : nil
    }

    /// Sondan en çok `maxWords` ardışık makul sözcük; `minWords`'ten azsa nil
    static func plausibleTail(_ words: [String]) -> String? {
        var run: [String] = []
        for w in words.reversed() {
            guard isPlausibleWord(w), run.count < maxWords else { break }
            run.insert(w, at: 0)
        }
        return run.count >= minWords ? run.joined(separator: " ") : nil
    }

    /// Soru / paragraf metni olabilecek bir satır mı. Elenenler: üç harf / rakamdan azı olan kırıntılar (çizgi "l", "I" diye okunur); dikey kutular (piksel olarak
    /// eninden uzun: sayfa kenarındaki dikey kitap adı, sütun çizgisi); sütunlar arasındaki orta oluğa sığan dar kutular. `aspect`: kare genişlik / yükseklik
    /// (1920×1080'de 16/9): kutular 0–1 oranındadır, dikeylik piksel olarak ölçülür.
    static func isBodyText(_ line: (text: String, box: CGRect), aspect: Double) -> Bool {
        let letters = line.text.filter { ch in ch.isLetter || ch.isNumber }.count
        guard letters >= 3 else { return false }
        let w = Double(line.box.width)
        let h = Double(line.box.height)
        guard w > 0, h > 0 else { return false }
        if h > w * aspect { return false }
        if isPeripheral(line.box) { return false }
        if Double(line.box.minX) >= gutterMin && Double(line.box.maxX) <= gutterMax && w < gutterWidth { return false }
        return true
    }

    /// `lines`: Vision satırları, kutu başlangıcı SOL ALT, oranlar 0–1. `skipTop`: üstten bu orandaki bant (kameranın saat yazısı) yok sayılır.
    static func make(_ input: [(text: String, box: CGRect)], skipTop: Double = 0, aspect: Double = 16.0 / 9.0) -> ViewLines {
        var result = ViewLines()
        // Sütunları ayıran dikey kitap adı / çizgi gibi soruyla ilgisi olmayan "satırlar" baştan elenir (kullanıcı bildirimi 2026-11-18: kadraj soruyu tam
        // alıyordu ama koç "Metin kesik" diyordu)
        let lines = input.filter { isBodyText($0, aspect: aspect) }
        result.ignored = input.count - lines.count
        for line in lines where (2 - Double(line.box.maxY) - Double(line.box.minY)) / 2 >= skipTop {   // saat bandındaki yazı sayılmaz
            result.chars += line.text.filter { ch in ch.isLetter || ch.isNumber }.count
            result.sense += TextSense.count(line.text)
        }
        let blocks = completeness(lines, skipTop: skipTop)
        result.topComplete = blocks.top
        result.completeQuestions = blocks.complete
        result.completeMarks = blocks.marks
        result.bottomComplete = blocks.bottom
        result.questions = blocks.questions
        result.nextQuestion = blocks.next
        result.cutReason = blocks.reason
        result.paragraph = blocks.paragraph
        let cover = coverage(lines, skipTop: skipTop)
        result.words = cover.words
        result.anchor = cover.anchor
        result.anchorHead = cover.head
        var items: [Item] = []
        for line in lines {
            let top = 1 - Double(line.box.maxY)
            let bottom = 1 - Double(line.box.minY)
            guard (top + bottom) / 2 >= skipTop else { continue }   // saat bandındaki yazı
            let words = ViewLines.words(line.text)
            guard !words.isEmpty else { continue }
            let cutTop = top < skipTop + edgeEpsilon
            let cutBottom = bottom > 1 - edgeEpsilon
            if cutTop { result.topCut = true }
            if cutBottom { result.bottomCut = true }
            // Kenara dayanan yarım satırın sözcükleri güvenilmez: başlangıç / bitiş olarak kullanılmaz
            if cutTop || cutBottom || words.count < minWords { continue }
            items.append(Item(head: plausibleHead(words), tail: plausibleTail(words), top: top, bottom: bottom, midX: Double(line.box.midX)))
        }
        guard !items.isEmpty else { return result }

        // Bozuk okunan satırlar (makul sözcüğü olmayan) başlangıç / bitiş sayılmaz: bir sonraki okunabilen satır söylenir
        func firstHead(_ list: [Item]) -> String? { return list.filter { $0.head != nil }.min(by: { $0.top < $1.top })?.head }
        func lastTail(_ list: [Item]) -> String? { return list.filter { $0.tail != nil }.max(by: { $0.bottom < $1.bottom })?.tail }

        let left = items.filter { $0.midX < 0.5 }
        let right = items.filter { $0.midX >= 0.5 }
        if left.count >= 2 && right.count >= 2 {
            if let a = firstHead(left), let b = firstHead(right) {
                result.starts = [LineEnd(side: "solda", words: a), LineEnd(side: "sağda", words: b)]
            }
            if let a = lastTail(left), let b = lastTail(right) {
                result.ends = [LineEnd(side: "solda", words: a), LineEnd(side: "sağda", words: b)]
            }
        } else {
            if let a = firstHead(items) { result.starts = [LineEnd(side: nil, words: a)] }
            if let b = lastTail(items) { result.ends = [LineEnd(side: nil, words: b)] }
        }
        return result
    }

    // MARK: Parçalı çekimde örtüşme

    /// Kadrajın sözcükleri ve alt uçtaki açık bloğun sözcükleri / baş sözcükleri (bkz. `words`, `anchor`, `anchorHead`). Yalnız kenara dayanmayan ve makul
    /// okunmuş satırlar sayılır: yarım satırın sözcüğü güvenilmez. İki sütunda her sütunun açık bloğu birleştirilir; söylenecek satır en üsttekidir
    /// (kaydırınca ilk o kadraj dışına çıkar)
    static func coverage(_ lines: [(text: String, box: CGRect)], skipTop: Double = 0) -> (words: Set<String>, anchor: Set<String>, head: String?) {
        struct R {
            var text: String
            var top: Double
            var midX: Double
        }
        var rows: [R] = []
        for line in lines {
            let top = 1 - Double(line.box.maxY)
            let bottom = 1 - Double(line.box.minY)
            guard (top + bottom) / 2 >= skipTop, top >= skipTop + edgeEpsilon, bottom <= 1 - edgeEpsilon else { continue }
            guard plausibleRatio(line.text) >= minPlausible else { continue }
            rows.append(R(text: line.text, top: top, midX: Double(line.box.midX)))
        }
        guard !rows.isEmpty else { return ([], [], nil) }
        func keyWords(_ text: String) -> [String] {
            return words(text).filter { $0.count >= 4 && isPlausibleWord($0) }.map { $0.lowercased() }
        }
        let all = Set(rows.flatMap { keyWords($0.text) })
        let left = rows.filter { $0.midX < 0.45 }
        let right = rows.filter { $0.midX > 0.55 }
        let columns = (left.count >= 3 && right.count >= 3) ? [left, right] : [rows]
        var anchor = Set<String>()
        var highest: R?
        for column in columns {
            let ordered = column.sorted { $0.top < $1.top }
            let block: ArraySlice<R>
            if let n = ordered.lastIndex(where: { matches(numberStart, $0.text) }), !ordered[(n + 1)...].contains(where: { matches(optionE, $0.text) }) {
                block = ordered[n...].prefix(3)
            } else {
                block = ordered.suffix(3)
            }
            for row in block { anchor.formUnion(keyWords(row.text)) }
            if let first = block.first, highest == nil || first.top < highest!.top { highest = first }
        }
        let head = highest.flatMap { plausibleHead(words($0.text)) }
        return (all, anchor, head)
    }

    // MARK: Soru / paragraf bütünlüğü

    private static let numberStart = try? NSRegularExpression(pattern: "^\\s*(\\d{1,3})\\s?[\\.\\)]\\s*\\S", options: [])
    /// E şıkkı: "E)" ya da yazı tanımanın ")" işaretini düşürdüğü "E in which stage" (gerçek günlük 2026-11-18: "A The only way", "E in which stage")
    private static let optionE = try? NSRegularExpression(pattern: "^\\s*\\(?E(\\s?[\\)\\.\\]]|\\s+(?=[A-Za-z]))", options: [])
    /// Şık satırı, ")" işareti düşmüş olabilir: B–E harfi ve sözcük; A yalnız büyük harfli sözcükle ("A study" gibi makale satırları şık sayılmasın)
    private static let optionLoose = try? NSRegularExpression(pattern: "^\\s*\\(?([B-E](\\s?[\\)\\.\\]]|\\s+(?=[A-Za-z]))|A(\\s?[\\)\\.\\]]|\\s+(?=[A-Z])))", options: [])
    private static let optionAny = try? NSRegularExpression(pattern: "^\\s*\\(?[A-E]\\s?[\\)\\.\\]]\\s*\\S", options: [])
    /// Satırın içinde (başında ya da bir sözcük sonra) E şıkkı: iki sütunun satırı tek kutuda birleşmişse sağ sütunun E'si ortada kalır
    private static let optionEInside = try? NSRegularExpression(pattern: "(^|\\s)\\(?E\\s?[\\)\\.\\]]\\s*\\S", options: [])
    /// Alt kenara bu kadar yakın biten (kadraj yüksekliğinin %12'si) yazının devamı kadrajın dışında olabilir
    private static let nearEdge = 0.12

    /// Satır küçük harfle başlıyor: önceki satırın devamıdır (paragrafın başı kadrajın üstünde kalmış)
    private static func startsLowercase(_ text: String) -> Bool {
        guard let c = text.trimmingCharacters(in: .whitespacesAndNewlines).first else { return false }
        return c.isLetter && c.isLowercase
    }

    /// Satır bir cümleyi bitiriyor (nokta, soru / ünlem işareti, iki nokta, üç nokta, kapanış tırnağı): paragrafın son satırı böyle biter
    private static func endsSentence(_ text: String) -> Bool {
        guard let c = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return true }
        return ".?!…:;\"”’»)".contains(c)
    }

    private static func matches(_ pattern: NSRegularExpression?, _ text: String) -> Bool {
        guard let pattern = pattern else { return false }
        return pattern.firstMatch(in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil
    }

    /// "34. Aşağıdakilerden …" satırından 34
    private static func questionNumber(_ text: String) -> Int? {
        guard let pattern = numberStart,
              let match = pattern.firstMatch(in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text)),
              match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[r])
    }

    /// `completeness` sonucu: üst / alt tam mı, kadrajda tam görünen sorular ve sıradaki soru
    struct Blocks {
        var top = false
        var bottom = false
        var questions: [Int] = []
        var next: Int?
        /// Üst / alt kesik sayıldıysa nedeni (günlük için)
        var reason: String?
        /// Numaralı soru ve şık yapısı yok: paragraf
        var paragraph = false
        /// Baştan sona tam görünen soru sayısı (numarası okunmayanlar şıklarından sayılır)
        var complete = 0
        /// Tam görünen soruların kimlikleri
        var marks: [QuestionMark] = []
    }

    private struct Row {
        var text: String
        var top: Double
        var bottom: Double
        var midX: Double
        var minX: Double
        var maxX: Double
        var cutTop: Bool
        var cutBottom: Bool
        /// Satır makul sözcüklerden oluşuyor (yazı tanıma bozuk okumadı): küçük harf / dolu satır kuralları yalnız böyle satırlarda işler
        var plausible: Bool
        var width: Double { return maxX - minX }
    }

    /// Kadrajın en üstündeki ve en altındaki soru / paragrafın KESİK olduğuna dair kanıt var mı (kullanıcı kararı 2026-11-18: bir sorunun ya da paragrafın metni
    /// tam görünmeden kabul edilmez; gerekirse "Uzaklaşın" denip tüm sayfa istenir). Gerçek günlük: yazı tanıma soru numarasını çoğu karede okumuyor; bu yüzden
    /// "numarayla başlamıyor = kesik" denemez, yalnız KANIT aranır. Satırlar üstten alta, sütun sütun okunur (iki sütunda her biri ayrı).
    /// ÜST kesik: ilk satır kadrajın kenarına dayanıyor ya da numarasız bir şık satırıyla başlıyor (önceki sorunun kuyruğu).
    /// ALT kesik: son satır kenara dayanıyor; ya da son soru numarasından sonra E şıkkı yokken yazı alt kenara yakın bitiyor (soru dibe uzanıyor); ya da
    /// E'den sonra alt kenara yakın bitecek kadar (en az üç) satır var (başka bir paragraf başlamış). Numara hiç görünmüyorsa (paragraf, başlık) kanıt yoktur.
    /// Kâğıdın üst / alt kenarı görünüyorsa (tam sayfa) çağıran bu denetimi aşar. Yazı bulunmazsa ikisi de false.
    static func completeness(_ lines: [(text: String, box: CGRect)], skipTop: Double = 0) -> Blocks {
        var rows: [Row] = []
        for line in lines {
            let top = 1 - Double(line.box.maxY)
            let bottom = 1 - Double(line.box.minY)
            guard (top + bottom) / 2 >= skipTop, !words(line.text).isEmpty else { continue }
            rows.append(Row(text: line.text, top: top, bottom: bottom, midX: Double(line.box.midX),
                            minX: Double(line.box.minX), maxX: Double(line.box.maxX),
                            cutTop: top < skipTop + edgeEpsilon, cutBottom: bottom > 1 - edgeEpsilon,
                            plausible: plausibleRatio(line.text) >= minPlausible))
        }
        guard !rows.isEmpty else { return Blocks() }
        // İki sütun: satırların orta noktaları açıkça sol ve sağ yarıya dağılmışsa; tek sütunda uzun satırların ortası kadrajın ortasındadır
        let left = rows.filter { $0.midX < 0.45 }
        let right = rows.filter { $0.midX > 0.55 }
        let columns: [[Row]]
        // İki sütunda oluğu aşan geniş satırlar (yazı tanıma iki sütunun satırını tek kutuda birleştirebilir): sütunlara girmez, ama kenara dayanıyorsa kesiktir
        // ve E şıkkını içerebilir. Dar orta satırlar (başlık, kitap adı) soru metni değildir: yok sayılır
        var merged: [Row] = []
        if left.count >= 3 && right.count >= 3 {
            columns = [left, right]
            merged = rows.filter { $0.midX >= 0.45 && $0.midX <= 0.55 && $0.width >= 0.5 }
        } else {
            columns = [rows]
        }
        var topOK = true
        var bottomOK = true
        var reasons: [String] = []
        var done: [Int] = []
        var notDone: [Int] = []
        var numberedRows = 0
        var unnumbered = 0
        var marks: [QuestionMark] = []
        func keys(_ rows: [Row]) -> Set<String> {
            return Set(rows.flatMap { words($0.text) }.filter { $0.count >= 4 && isPlausibleWord($0) }.map { $0.lowercased() })
        }
        for row in merged {
            if row.cutTop {
                topOK = false
                reasons.append("üst: oluğu aşan satır kenara dayalı")
            }
            if row.cutBottom {
                bottomOK = false
                reasons.append("alt: oluğu aşan satır kenara dayalı")
            }
        }
        for (columnIndex, column) in columns.enumerated() {
            let side = columns.count == 2 ? (columnIndex == 0 ? "sol " : "sağ ") : ""
            let ordered = column.sorted { $0.top < $1.top }
            guard let first = ordered.first else { continue }
            // Sütundaki numaralı sorular: E şıkkına kadar görünen ve numara satırı kenara dayanmayan soru "tam"dır, öteki yarım kalmıştır
            let starts = ordered.indices.compactMap { i in questionNumber(ordered[i].text).map { (index: i, number: $0) } }
            numberedRows += starts.count
            for (k, start) in starts.enumerated() {
                let end = k + 1 < starts.count ? starts[k + 1].index : ordered.count
                let slice = ordered[start.index..<end]
                let fromTop = ordered[start.index].top
                let toTop = k + 1 < starts.count ? ordered[starts[k + 1].index].top : Double.infinity
                let mergedE = merged.contains { $0.top >= fromTop && $0.top < toTop && matches(optionEInside, $0.text) }
                var complete = !ordered[start.index].cutTop && (slice.contains { matches(optionE, $0.text) } || mergedE)
                if complete, k == starts.count - 1, let e = slice.firstIndex(where: { matches(optionE, $0.text) }) {
                    let after = ordered[(e + 1)...]
                    if after.count > 2 || ordered[e].cutBottom || after.contains(where: { $0.cutBottom }) { complete = false }
                }
                if complete {
                    done.append(start.number)
                    marks.append(QuestionMark(number: start.number, keys: keys(Array(slice))))
                } else {
                    notDone.append(start.number)
                }
            }
            // Numarası okunmayan tam sorular (gerçek günlük: numara çoğu karede okunmuyor): E şıkkına kadar şık satırları ve üstlerinde gövde satırı görünüyorsa,
            // gövdenin ilk satırı kenara dayanmıyorsa soru tamdır
            var boundary = 0
            for (i, row) in ordered.enumerated() where matches(optionE, row.text) {
                let blockStart = boundary
                boundary = i + 1
                guard !row.cutTop, !row.cutBottom else { continue }
                let block = Array(ordered[blockStart...i])
                guard !block.contains(where: { questionNumber($0.text) != nil }) else { continue }   // numaralı sorular yukarıda sayıldı
                guard let firstOption = block.firstIndex(where: { matches(optionLoose, $0.text) }), firstOption > 0 else { continue }
                guard block.filter({ matches(optionLoose, $0.text) }).count >= 4 else { continue }
                if let head = block.first, head.cutTop || (blockStart == 0 && head.plausible && startsLowercase(head.text)) { continue }
                unnumbered += 1
                marks.append(QuestionMark(number: nil, keys: keys(block)))
            }
            // KESİK KANITI (gerçek günlük 2026-11-18: yazı tanıma soru numarasını çoğu karede okumadığı için "numarayla başlamıyor = kesik" saymak her
            // görüntüyü reddetti): ÜST kesik yalnız ilk satır kenara dayanıyorsa ya da numarasız bir ŞIK satırıyla başlıyorsa (önceki sorunun kuyruğu)
            if first.cutTop {
                topOK = false
                reasons.append("üst: \(side)ilk satır kenara dayalı")
            } else if matches(optionAny, first.text) && !matches(numberStart, first.text) {
                topOK = false
                reasons.append("üst: \(side)şık satırıyla başlıyor")
            } else if first.plausible && startsLowercase(first.text) {
                // Paragraf başı: büyük harf ya da numarayla başlar; küçük harfle başlayan satır paragrafın ortasındandır
                topOK = false
                reasons.append("üst: \(side)önceki satırın devamı (küçük harfle başlıyor)")
            }
            // ALT kesik: son satır kenara dayanıyorsa; ya da son soru numarasından sonra E şıkkı yokken yazı alt kenara yakın bitiyorsa (soru dibe uzanıyor);
            // ya da E'den sonra alt kenara yakın bitecek kadar çok satır varsa (başka bir paragraf başlamış). Numara hiç görünmüyorsa (paragraf, başlık)
            // kanıt yoktur: kesik sayılmaz
            guard let last = ordered.last else { continue }
            if last.cutBottom {
                bottomOK = false
                reasons.append("alt: \(side)son satır kenara dayalı")
            } else if last.bottom >= 1 - nearEdge, let n = ordered.lastIndex(where: { matches(numberStart, $0.text) }) {
                if let e = ordered[(n + 1)...].firstIndex(where: { matches(optionE, $0.text) }) {
                    if ordered[(e + 1)...].count > 2 {
                        bottomOK = false
                        reasons.append("alt: \(side)E'den sonra çok satır var")
                    }
                } else if !merged.contains(where: { $0.top >= ordered[n].top && matches(optionEInside, $0.text) }) {
                    bottomOK = false
                    reasons.append("alt: \(side)son soruda E şıkkı yok, yazı dibe uzanıyor")
                }
            }
            // PARAGRAF SONU: numaralı soru yoksa ya da son sorunun E'sinden sonra paragraf başlamışsa, son satır DOLU uzunlukta (sütunun en uzun satırının %85'i) ve
            // cümle bitirmiyorsa paragraf aşağıda sürüyordur; paragrafın son satırı genelde kısadır ve nokta ile biter
            let paragraphTail: Bool
            if let n = ordered.lastIndex(where: { matches(numberStart, $0.text) }) {
                if let e = ordered[(n + 1)...].firstIndex(where: { matches(optionE, $0.text) }) {
                    paragraphTail = ordered[(e + 1)...].count > 2
                } else {
                    paragraphTail = false
                }
            } else {
                paragraphTail = true
            }
            if !last.cutBottom, last.plausible, paragraphTail, ordered.count >= 3, !matches(optionAny, last.text) {
                let fullWidth = ordered.map { $0.width }.max() ?? 0
                if last.width >= 0.85 * fullWidth && !endsSentence(last.text) {
                    bottomOK = false
                    reasons.append("alt: \(side)paragraf sürüyor (dolu satır, cümle bitmemiş)")
                }
            }
        }
        var result = Blocks(top: topOK, bottom: bottomOK)
        result.complete = done.count + unnumbered
        result.marks = marks
        result.reason = reasons.isEmpty ? nil : reasons.joined(separator: "; ")
        // Paragraf: numaralı soru satırı yok ve A–E şık satırı en çok bir (yazı tanıma numarayı okumasa da şıklar sıralı görünür)
        result.paragraph = numberedRows == 0 && rows.filter { matches(optionAny, $0.text) }.count < 2
        // Numaralar yalnız ardışık ve artansa güvenilir (yazı tanıma bir rakamı yanlış okuyabilir; iki sütunda sol sütun önce gelir): yoksa söylenmez
        done.sort()
        let consecutive = zip(done, done.dropFirst()).allSatisfy { $1 == $0 + 1 }
        if let last = done.last, consecutive {
            // Yarım kalan soru yalnız son tam sorudan SONRA geliyorsa sıradakidir (üst kenarda kesilen numara önceki sorudur)
            let next = notDone.filter { $0 > last }.min() ?? last + 1
            if next == last + 1 {
                result.questions = done
                result.next = next
            }
        }
        return result
    }

    /// Üst taraf: "Üstte A ile başlıyor." ya da üst satır kesikse "Üst satır yarım kalıyor; ilk tam satır A ile başlıyor."
    var startsText: String? {
        let phrase = starts.map { $0.phrase }.joined(separator: ", ")
        if topCut { return starts.isEmpty ? "Üst satır yarım kalıyor." : "Üst satır yarım kalıyor; ilk tam satır " + phrase + " ile başlıyor." }
        return starts.isEmpty ? nil : "Üstte " + phrase + " ile başlıyor."
    }

    /// Alt taraf: "Altta B ile bitiyor." ya da alt satır kesikse "Alt satır yarım kalıyor; son tam satır B ile bitiyor."
    var endsText: String? {
        let phrase = ends.map { $0.phrase }.joined(separator: ", ")
        if bottomCut { return ends.isEmpty ? "Alt satır yarım kalıyor." : "Alt satır yarım kalıyor; son tam satır " + phrase + " ile bitiyor." }
        return ends.isEmpty ? nil : "Altta " + phrase + " ile bitiyor."
    }

    /// "Üstte A ile başlıyor. Altta B ile bitiyor." Satır bilgisi yoksa nil.
    var coverage: String? {
        let parts = [startsText, endsText].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Canlı koçun kısa söylenişi (kullanıcı kararı 2026-11-17: cümle değil kelime): "Üstte: A." ya da üst satır kesikse "Üst satır kesik; ilk tam: A."
    var startsShort: String? {
        let phrase = starts.map { $0.phrase }.joined(separator: ", ")
        if topCut { return starts.isEmpty ? "Üst satır kesik." : "Üst satır kesik; ilk tam: " + phrase + "." }
        return starts.isEmpty ? nil : "Üstte: " + phrase + "."
    }

    /// "Altta: B." ya da alt satır kesikse "Alt satır kesik; son tam: B."
    var endsShort: String? {
        let phrase = ends.map { $0.phrase }.joined(separator: ", ")
        if bottomCut { return ends.isEmpty ? "Alt satır kesik." : "Alt satır kesik; son tam: " + phrase + "." }
        return ends.isEmpty ? nil : "Altta: " + phrase + "."
    }

    var shortCoverage: String? {
        let parts = [startsShort, endsShort].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// Kareyi okuyup satırları çıkarır (Vision, hızlı kip). Yalnız kamera durgunken ve seyrek çağrılır.
enum ViewLinesReader {
    static func read(_ pixelBuffer: CVPixelBuffer, orientation: ImageOrientation) -> ViewLines? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.012
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation.cgOrientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        var lines: [(text: String, box: CGRect)] = []
        for case let observation as VNRecognizedTextObservation in (request.results ?? []) {
            if let best = observation.topCandidates(1).first, best.confidence >= TextScore.minConfidence {
                lines.append((text: best.string, box: observation.boundingBox))
            }
        }
        let skip = orientation == .normal ? GuidanceAnalyzer.skipTop : 0
        // Resim 90° çevriliyorsa Vision'a giden görüntünün genişlik / yüksekliği yer değiştirir (dikey kutuların ölçüsü buna bağlıdır)
        var width = Double(CVPixelBufferGetWidth(pixelBuffer))
        var height = Double(CVPixelBufferGetHeight(pixelBuffer))
        if orientation == .right90 || orientation == .left90 { swap(&width, &height) }
        return ViewLines.make(lines, skipTop: skip, aspect: height > 0 ? width / height : 16.0 / 9.0)
    }
}

// MARK: - Yön sözcükleri

/// Görüntüdeki yön. Koç dik (yazının okunduğu) görüntüde ölçer; sesli yön ise KAMERANIN KENDİ duruşuna göre söylenir (kullanıcı isteği 2026-11-18: yandan
/// çekimde kamera yazıdan farklı yönde tutulur, yön cümleleri yazıyı çevirip değil kameranın gördüğü kadraja göre verilir). `turn`: dik görüntüden kameranın
/// görüntüsüne saat yönünde çeyrek dönüş sayısı (bkz. `ImageOrientation.turn`).
enum ViewDirection: Int {
    case up = 0, right = 1, down = 2, left = 3

    func turned(_ quarterTurns: Int) -> ViewDirection {
        return ViewDirection(rawValue: ((rawValue + quarterTurns) % 4 + 4) % 4) ?? self
    }

    /// Kaydırma sözcüğü: "yukarı" / "sağa" / "aşağı" / "sola"
    var move: String {
        switch self {
        case .up: return "yukarı"
        case .right: return "sağa"
        case .down: return "aşağı"
        case .left: return "sola"
        }
    }

    /// Kenar sözcüğü: "üst" / "sağ" / "alt" / "sol"
    var side: String {
        switch self {
        case .up: return "üst"
        case .right: return "sağ"
        case .down: return "alt"
        case .left: return "sol"
        }
    }

    init(_ side: PageEdges.Side) {
        switch side {
        case .top: self = .up
        case .right: self = .right
        case .bottom: self = .down
        case .left: self = .left
        }
    }

    init?(_ advice: GuidanceAdvice) {
        switch advice {
        case .moveUp: self = .up
        case .moveRight: self = .right
        case .moveDown: self = .down
        case .moveLeft: self = .left
        default: return nil
        }
    }
}

// MARK: - Kadraj koçu

/// Sayfa için çekim planı (kullanıcı kararı 2026-11-18: sistem kamerayı kendisi tutsaydı sayfayı nasıl çekerdi?): önce TÜM SAYFA tek seferde (kenarlar kadrajda
/// ve yazı okunuyor); birkaç konumlandırma denemesinde tam sayfa olmuyorsa ya da tam sayfa okunmayacak kadar küçük kalıyorsa ÜST YARI / ALT YARI.
/// `any`: plan yok (kadraj ne ise o kabul edilir; "Kadraj kontrolü" ve eski davranış).
enum ShotPlan: Equatable {
    case any, wholePage, halves
}

/// Koçun bir değerlendirmesi: ne durumda ve ne söylenecek
struct FramingNote: Equatable {
    enum Kind: String, Equatable {
        case noText, blurry, glare, cutLeft, cutRight, shiftLeft, shiftRight, tooWide, tooSmall, emptyTop, middle
        /// Kare bozuk (bloklaşmış): hiçbir zaman kabul edilmez; `incomplete`: soru ya da paragraf tam görünmüyor (kullanıcı kararı 2026-11-18)
        case damaged, incomplete
        /// Çekim planı (bkz. `ShotPlan`): `wholePage` tüm sayfa için uzaklaşılması, `halves` tam sayfanın olmadığı / okunmadığı için yarım yarım çekime geçilmesi
        case wholePage, halves
        /// Düzeltme gerekmiyor: `good` kâğıt kenarı bilinmiyorken; `goodFull` tam sayfa, `goodUpper` üst yarı, `goodLower` alt yarı
        case good, goodFull, goodUpper, goodLower
        /// Parçalı çekim: sayfanın bu parçası alındı ama sayfa bitmedi (alt uç açık); kullanıcı aşağı kaydırır, sıradaki parça bununla örtüşmelidir
        case goodPart
        /// Kadrajda en az bir soru TAM görünüyor ve okunuyor: hemen alınır (kullanıcı kararı 2026-11-18); kesik komşu sorular sorun sayılmaz
        case taken
        /// Daha önce alınan soruya yeniden durulmuş ve kadrajda başka soru yok: "Bu soru zaten alındı, başka soruya geçin" (düzeltme sayılır)
        case alreadyTaken

        var isGood: Bool { return self == .good || self == .goodFull || self == .goodUpper || self == .goodLower || self == .goodPart || self == .taken }

        /// Yazı okunabiliyorsa değişebilecek (iptal olabilecek) değerlendirme: yazı tanıma sonucu gelene kadar beklenir (bkz. `FramingCoachTimer`).
        /// Kenar kesikleri, "uzaklaşın", "yazı yok", bozuk kare ve eksik metin yazı tanımaya bakmadan söylenir.
        var awaitsText: Bool {
            switch self {
            case .blurry, .glare, .shiftLeft, .shiftRight, .tooSmall, .emptyTop, .middle, .good, .goodFull, .goodUpper, .goodLower, .goodPart: return true
            case .noText, .cutLeft, .cutRight, .tooWide, .damaged, .incomplete, .wholePage, .halves, .taken, .alreadyTaken: return false
            }
        }
    }
    var kind: Kind
    var text: String

    /// Kullanıcıdan bir şey isteyen (düzeltme) değerlendirme mi
    var isCorrection: Bool { return !kind.isGood }
}

/// Sayfanın kadrajdaki konumu (kâğıt kenarları, Apple Vision): üç durum vardır (kullanıcı kararı 2026-11-17).
/// `full`: dört kenar da kadrajın içinde, boşluklu. `upperHalf`: üst, sol ve sağ kenar boş, alt kenardan sayfa devam ediyor (alttaki sorunun bir bölümü
/// girmiş olabilir). `lowerHalf`: alt, sol ve sağ kenar boş, üst kenardan sayfa devam ediyor. `middle`: üst ve alt kenar ikisi de kadraj dışında
/// (sayfanın ortasından bir dilim); bu bir düzeltme sebebidir.
enum PageLayout: Equatable {
    case full, upperHalf, lowerHalf, middle
}

struct PageLayoutReading: Equatable {
    var layout: PageLayout
    /// Kâğıdın kadraj dışına taşan sol / sağ kenarları (yazı tam görünse bile kâğıt yandan taşabilir)
    var cutSides: [PageEdges.Side]
    /// Dört kenar da belirgin boşlukla kadrajın içinde
    var allClear: Bool
}

/// Toplu çekimde sesli konumlandırma DESTEĞİ (kullanıcı kararı 2026-11-17, Ayarlar > "Toplu çekimde sesli konumlandırma"): çekimi başlatmaz ya da
/// bitirmez, yalnız kadrajın durumunu kısa cümlelerle söyler: hangi kenar kesik, sağa / sola kayma, yakın ve bulanıksa uzaklaşma, yazı küçükse
/// yaklaşma, üstte boşluk varsa aşağı kaydırma; düzeltme gerekmiyorsa sayfanın hangi durumda göründüğü (tam sayfa, üst yarı, alt yarı) ve yarım
/// görünümde kesik kenardan hangi satırın başlayıp bittiği.
/// Ölçüler tek soru çekimindeki yönlendirmeyle aynıdır (`GuidanceAdvisor`); farkı: dikey kesik bir sorun sayılmaz (sayfa kadrajdan büyüktür,
/// toplu çekimde yukarıdan aşağı kaydırılır), bunun yerine sayfanın konumu ve satır tarifi verilir.
enum FramingCoach {
    /// Yazının üst kenarı kadrajın bu oranından aşağıdaysa üst taraf boştur (kamera sayfanın üstünde kalmış)
    static let emptyTopLimit = 0.42
    /// Yazının alt kenarı kadrajın bu oranından yukarıdaysa alt taraf boştur (yalnız bilgi verilir: sayfa sonu olabilir)
    static let emptyBottomLimit = 0.55

    /// Kâğıt kenarlarından sayfanın durumu; kenarlar bilinmiyorsa (ölçülmedi, güvenilmez, yazıya yapışık) ya da üst / alt kenar belirsizse nil
    static func layout(_ m: PageMetrics) -> PageLayoutReading? {
        guard let e = GuidanceScene.usableEdges(m) else { return nil }
        let layout: PageLayout
        switch (e.state(.top), e.state(.bottom)) {
        case (.clear, .clear): layout = .full
        case (.clear, .cut): layout = .upperHalf
        case (.cut, .clear): layout = .lowerHalf
        case (.cut, .cut): layout = .middle
        default: return nil
        }
        let sides = [PageEdges.Side.left, PageEdges.Side.right].filter { e.state($0) == .cut }
        return PageLayoutReading(layout: layout, cutSides: sides, allClear: e.allClear)
    }

    /// Canlı koçta kelime ("Tam sayfa.", "Üst yarı.", "Alt yarı.", "Sağ kenar dışarıda."); ayrıntılıysa ("Kadraj kontrolü") tam cümle:
    /// "Tam sayfa görünüyor, dört kenar boş." / "Sayfanın üst yarısı görünüyor, üst, sol ve sağ kenar boş." (+ kesik kenar açıklaması)
    static func layoutText(_ r: PageLayoutReading, verbose: Bool, turn: Int = 0) -> String {
        if !verbose {
            let outside = r.cutSides.isEmpty ? "" : r.cutSides.map { ViewDirection($0).turned(turn).side }.joined(separator: " ve ") + " kenar dışarıda."
            let name: String
            switch r.layout {
            case .full: name = r.cutSides.isEmpty ? "Tam sayfa." : "\(capitalised(ViewDirection.up.turned(turn).side)) ve \(ViewDirection.down.turned(turn).side) boş;"
            case .upperHalf: name = r.cutSides.isEmpty ? "Üst yarı." : "Üst yarı;"
            case .lowerHalf: name = r.cutSides.isEmpty ? "Alt yarı." : "Alt yarı;"
            case .middle: name = "Sayfa ortası."
            }
            return outside.isEmpty ? name : name + " " + outside
        }
        // Kâğıt yandan taşıyorsa "dört kenar boş" denmez: "sağ kenarı kadrajın dışında kalıyor" / "sol ve sağ kenarları kadrajın dışında kalıyor"
        let sideClause = r.cutSides.isEmpty ? "" : r.cutSides.map { ViewDirection($0).turned(turn).side }.joined(separator: " ve ") + (r.cutSides.count == 1 ? " kenarı" : " kenarları") + " kadrajın dışında kalıyor"
        switch r.layout {
        case .full:
            if !r.cutSides.isEmpty { return "Sayfanın üstü ve altı görünüyor; " + sideClause + "." }
            return r.allClear ? "Tam sayfa görünüyor, dört kenar boş." : "Tam sayfa görünüyor."
        case .upperHalf:
            if !r.cutSides.isEmpty { return "Sayfanın üst yarısı görünüyor; " + sideClause + "." }
            return "Sayfanın üst yarısı görünüyor, üst, sol ve sağ kenar boş." + (verbose ? " Alt kenardan alttaki sorunun bir bölümü giriyor olabilir." : "")
        case .lowerHalf:
            if !r.cutSides.isEmpty { return "Sayfanın alt yarısı görünüyor; " + sideClause + "." }
            return "Sayfanın alt yarısı görünüyor, alt, sol ve sağ kenar boş." + (verbose ? " Üst kenardan üstteki sorunun bir bölümü giriyor olabilir." : "")
        case .middle:
            return "Sayfanın ortası görünüyor, üst ve alt kenar kadraj dışında."
        }
    }

    /// Düzgün kadraj ("düzeltme gerekmiyor") için kısa söyleniş; düzeltmeden sonra tek başına "Tamam." olur
    static let okText = "Uygun."

    /// Düzgün kadrajda (kullanıcı kararı 2026-11-18: "Uygun, çekildi" değil, yalnız "Alındı / Sonraki") sayfanın alındığı ve sıradakine geçilebileceği söylenir:
    /// görünüm durgun ve okunaklıyken kareler zaten kaydedilmektedir. "Uygun." ve düzeltmeden sonraki "Tamam." → "Alındı. Sonraki."; "Tamam. Üstte: …" →
    /// "Üstte: … Alındı. Sonraki."; sayfa durumu ("Tam sayfa.", "Alt yarı. …") ve "Alt boş." gibi cümlelerin sonuna " Alındı. Sonraki." eklenir.
    /// Düzeltme isteyen cümlelere eklenmez (çağıran yalnız düzgün kadrajda çağırır).
    static let capturedText = "Alındı. Sonraki."

    /// Aynı soruya yeniden durulduğunda (kadrajda başka soru yokken) söylenir; numarası okunduysa başına eklenir
    static func alreadyTakenText(number: Int?) -> String {
        return (number.map { "\($0). soru zaten alındı." } ?? "Bu soru zaten alındı.") + " Başka soruya geçin."
    }

    /// Tam sayfa tek karede olmuyor ya da okunmuyor: yarım yarım çekilir (her yarıda soru tam görünür). "Uzaklaşın" ile "Yaklaşın" arasında gidip gelinmez
    static let halvesText = "Tam sayfa olmuyor; yarım yarım çekin."

    static func withCapture(_ text: String, capture: String? = nil) -> String {
        let tail = capture ?? capturedText
        if text == okText || text == "Tamam." { return tail }
        if text.hasPrefix("Tamam. ") { return String(text.dropFirst("Tamam. ".count)) + " " + tail }
        return text + " " + tail
    }

    /// Alınan soruların ve sıradakinin söylenişi (kullanıcı kararı 2026-11-18): "34. ve 35. sorular tamam, sıradaki 36. soru." Kullanıcı bunu gözüyle
    /// gördüğü sayfadaki numaralarla karşılaştırıp neyin alındığını, hangisine geçeceğini ve ne kadar kaydıracağını anlar; atlanan soru kendiliğinden
    /// fark edilir. Numaralar güvenilir okunmadıysa nil (çağıran "Alındı. Sonraki." der; bkz. `ViewLines.questions`).
    static func questionsText(_ lines: ViewLines?) -> String? {
        guard let lines = lines, let first = lines.questions.first, let last = lines.questions.last, let next = lines.nextQuestion else { return nil }
        let said: String
        switch lines.questions.count {
        case 1: said = "\(first). soru"
        case 2: said = "\(first). ve \(last). sorular"
        default: said = "\(first). ile \(last). arası sorular"
        }
        return "\(said) tamam, sıradaki \(next). soru."
    }

    /// "azıcık" → "Azıcık" (Türkçe büyük harfle)
    static func capitalised(_ s: String) -> String {
        return String(s.prefix(1)).uppercased(with: Locale(identifier: "tr_TR")) + String(s.dropFirst())
    }

    /// `verbose` false (canlı koç): kelime ("Biraz sağa.", "Uzaklaşın.", "Bulanık, sabit tutun."); true ("Kadraj kontrolü"): tam cümle
    ///
    /// `firstReadable` (canlı koç; kullanıcı kararı 2026-11-18): görüntü kadraja sığıyor ve program okuyabiliyorsa daha mükemmel görüntü için düzeltme
    /// istenmez, ilk yeterli görüntü kabul edilir. Bozuk (bloklu) kare hiçbir zaman kabul edilmez; soru ya da paragraf tam görünmüyorsa (üstte numarasız
    /// başlıyor ya da altta E şıkkına varmadan bitiyor) kabul edilmez, tüm sayfa için "Uzaklaşın" denir (kâğıdın üst / alt kenarı görünüyorsa tam
    /// sayfa görünüyordur: sayılır). Okunduğu kanıtlanınca "yaklaşın, bulanık, parlama, üst boş, sayfa ortası" gibi iyileştirmeler söylenmez;
    /// yalnız yan kenar kesiği ve taşma (kadraja sığmama) düzeltilir.
    /// `plan` (yalnız `firstReadable` ile): `wholePage`: önce tüm sayfa; kâğıdın dört kenarı görünüp yazı okunuyorsa kabul, sayfa yarım / ortadan bir dilim
    /// görünüyorsa "Tüm sayfa için uzaklaşın", tam sayfa görünüp okunmuyorsa ya da küçük yazı yüzünden yaklaşmak gerekecekse `halves` (yarım yarım çekim).
    /// `halves`: tam görünen yarım ya da dilim kabul edilir; soru kesikse hangi yöne kaydırılacağı söylenir.
    static func note(_ m: PageMetrics, lines: ViewLines?, config c: GuidanceConfig = GuidanceConfig(), sharpFloor: Double = 0.45,
                     verbose: Bool = false, firstReadable: Bool = false, plan: ShotPlan = .any, continuing: Bool? = nil, turn: Int = 0) -> FramingNote {
        if firstReadable && m.damaged {
            return FramingNote(kind: .damaged, text: verbose ? "Görüntü bozuk. Kamerayı sabit tutun." : "Bozuk, sabit tutun.")
        }
        // KABUL KURALI (kullanıcı kararı 2026-11-18, konumlandırma değerlendirmesi): kadrajda en az bir soru baştan sona (gövde ve A–E şıkları) görünüyor ve
        // okunuyorsa hemen alınır; hangi soru olduğu söylenir ("47. soru tamam"). En iyisini aramak süre yitirir; yandaki / alttaki ya da üstteki kesik
        // sorular "ekrana sığmıyor, uzaklaşın" sebebi OLMAZ: zaten alınan bir soru vardır. Bozuk kare yukarıda elendi
        if firstReadable, !verbose, let lines = lines, lines.isReadable, lines.completeQuestions > 0 {
            return FramingNote(kind: .taken, text: okText)
        }
        var d = GuidanceAdvisor.decide(m, config: c, sharpFloor: sharpFloor)
        let proven = firstReadable && lines?.isReadable == true
        if firstReadable, plan == .wholePage, let lines = lines, !lines.isReadable {
            // Yazı tanıma bu görünümü okuyamadı: yaklaşmak gerekecekse ya da tam sayfa zaten kadrajdaysa (daha uzaklaşılamaz) tam sayfa olmaz
            let small = d.advice == .closer || (d.advice.isMove && d.scale > 1)
            if small || (d.advice == .ok && layout(m)?.layout == .full) {
                return FramingNote(kind: .halves, text: halvesText)
            }
        }
        if proven { d = relaxed(d) }
        switch d.advice {
        case .noText:
            return FramingNote(kind: .noText, text: verbose ? "Yazı görünmüyor. Kamerayı sayfaya çevirin." : "Yazı yok.")
        case .blurry:
            let close = d.fill >= 0.7
            if verbose {
                return FramingNote(kind: .blurry, text: close ? "Görüntü net değil, çok yakınsınız. Biraz uzaklaşın." : "Görüntü net değil. Kamerayı sabit tutun.")
            }
            return FramingNote(kind: .blurry, text: close ? "Bulanık, uzaklaşın." : "Bulanık, sabit tutun.")
        case .glare:
            return FramingNote(kind: .glare, text: verbose ? "Sayfada parlama var. Kamerayı biraz eğin." : "Parlama. Kamerayı eğin.")
        case .moveLeft, .moveRight, .moveUp, .moveDown:
            let word = GuidanceAdvisor.amountWord(shift: d.shift, config: c)
            let dir = ViewDirection(d.advice).map { $0.turned(turn).move } ?? d.advice.directionWord
            if d.scale > 1 {
                // Yazı kesik değil, küçük: yakınlaşınca taşacağı için önce ortalanır
                let kind: FramingNote.Kind = d.advice == .moveRight ? .shiftRight : .shiftLeft
                let text = verbose ? "Yazı küçük. Önce kamerayı \(word) \(dir) kaydırıp sonra yaklaşın." : "\(capitalised(word)) \(dir), sonra yaklaşın."
                return FramingNote(kind: kind, text: text)
            }
            let side = capitalised(ViewDirection(d.advice == .moveRight ? PageEdges.Side.right : PageEdges.Side.left).turned(turn).side)
            let kind: FramingNote.Kind = d.advice == .moveRight ? .cutRight : .cutLeft
            return FramingNote(kind: kind, text: verbose ? "\(side) taraf kesik. Kamerayı \(word) \(dir) kaydırın." : "\(capitalised(word)) \(dir).")
        case .farther:
            return FramingNote(kind: .tooWide, text: verbose ? "Sayfa kadraja sığmıyor. Biraz uzaklaşın." : "Uzaklaşın.")
        case .closer:
            return FramingNote(kind: .tooSmall, text: verbose ? "Yazı küçük kalıyor. Biraz yaklaşın." : "Yaklaşın.")
        case .ok:
            break
        }
        // Düzeltme gerekmiyor: sayfanın üç durumdan hangisinde göründüğü kâğıt kenarlarından bilinir
        let reading = layout(m)
        if proven, let lines = lines {
            // Okunuyor: soru / paragraf tam görünüyor mu? Kâğıdın üst (alt) kenarı görünüyorsa üst (alt) taraf tamdır
            let topSeen = reading?.layout == .full || reading?.layout == .upperHalf
            let bottomSeen = reading?.layout == .full || reading?.layout == .lowerHalf
            if plan == .wholePage, let r = reading {
                // Tam sayfa öncelikli: dört kenar kadrajdaysa kabul; değilse tüm sayfa için uzaklaşılır
                if r.layout == .full {
                    // Paragrafta tam sayfada da ilk ve son satırdan sözcükler söylenir (kamera hangi alanı görüyor)
                    let spoken = [layoutText(r, verbose: verbose, turn: turn), lines.paragraph ? lines.shortCoverage : nil].compactMap { $0 }
                    return FramingNote(kind: .goodFull, text: spoken.joined(separator: " "))
                }
                return FramingNote(kind: .wholePage, text: "Tüm sayfa için uzaklaşın.")
            }
            if plan == .halves {
                return halvesNote(lines, reading: reading, continuing: continuing, verbose: verbose, turn: turn)
            }
            let topOK = lines.topComplete || topSeen
            let bottomOK = lines.bottomComplete || bottomSeen
            if !(topOK && bottomOK) {
                if (plan == .halves || lines.paragraph) && (topOK || bottomOK) {
                    // Yarımda (ve paragrafta) yalnız bir uç kesik: metin kadrajın yukarısında / aşağısında devam ediyor, kamera o yöne kaydırılır;
                    // görünen ilk / son satırın sözcükleri kullanıcıya fiziksel sayfayla karşılaştırması için söylenir
                    let direction = "Metin kesik, biraz \((topOK ? ViewDirection.down : ViewDirection.up).turned(turn).move)."
                    return FramingNote(kind: .incomplete, text: [direction, lines.shortCoverage].compactMap { $0 }.joined(separator: " "))
                }
                return FramingNote(kind: .incomplete, text: verbose ? "Soru ya da paragraf tam görünmüyor. Tüm sayfa için uzaklaşın." : "Metin kesik, uzaklaşın.")
            }
            // Yeterli görüntü: sayfanın durumu ve kabul. Yarımlarda ilk ve son satırdan birkaç sözcük de okunur (kullanıcı kararı 2026-11-18: kullanıcı
            // okunanı gözüyle gördüğü sayfadaki satırlarla karşılaştırıp kaydırmayı buna göre doğru yapar); tam sayfada satır tarifi gerekmez
            // Soru numaraları okunduysa ("34. ve 35. sorular tamam, sıradaki 36. soru") satır sözcükleri okunmaz: numaralar hem daha kısa hem daha güvenilir
            let tails = ((plan == .halves || lines.paragraph) && questionsText(lines) == nil) ? lines.shortCoverage : nil
            if let r = reading, r.layout != .middle {
                let kind: FramingNote.Kind = r.layout == .upperHalf ? .goodUpper : (r.layout == .lowerHalf ? .goodLower : .goodFull)
                let spoken = [layoutText(r, verbose: verbose, turn: turn), (r.layout == .full && !lines.paragraph) ? nil : tails].compactMap { $0 }
                return FramingNote(kind: kind, text: spoken.joined(separator: " "))
            }
            return FramingNote(kind: .good, text: tails ?? (verbose ? "Kadraj uygun." : okText))
        }
        if let reading = reading, reading.layout == .middle {
            let tail = verbose ? " Tam sayfa için uzaklaşın; yarım sayfa için kamerayı yukarı ya da aşağı kaydırın." : " Uzaklaşın ya da kaydırın."
            return FramingNote(kind: .middle, text: layoutText(reading, verbose: verbose, turn: turn) + tail)
        }
        if m.y0 - c.topBand > emptyTopLimit {
            return FramingNote(kind: .emptyTop, text: verbose ? "Yazı kadrajın alt yarısında, üst taraf boş. Kamerayı biraz aşağı kaydırın."
                               : "\(capitalised(ViewDirection.up.turned(turn).side)) boş, biraz \(ViewDirection.down.turned(turn).move).")
        }
        if let reading = reading {
            // Yarım görünümde kesik kenardan hangi satırın başlayıp bittiği söylenir; tam sayfada satır tarifine gerek yoktur
            var parts = [layoutText(reading, verbose: verbose, turn: turn)]
            let kind: FramingNote.Kind
            switch reading.layout {
            case .upperHalf:
                kind = .goodUpper
                if let text = (verbose ? lines?.endsText : lines?.endsShort) { parts.append(text) }
            case .lowerHalf:
                kind = .goodLower
                if let text = (verbose ? lines?.startsText : lines?.startsShort) { parts.append(text) }
            default:
                kind = .goodFull
            }
            return FramingNote(kind: kind, text: parts.joined(separator: " "))
        }
        var parts: [String] = []
        if m.y1 < emptyBottomLimit { parts.append(verbose ? "Yazı kadrajın üst yarısında, alt taraf boş." : "Alt boş.") }
        if let coverage = (verbose ? lines?.coverage : lines?.shortCoverage) { parts.append(coverage) }
        if parts.isEmpty { parts.append(verbose ? "Kadraj uygun." : okText) }
        return FramingNote(kind: .good, text: parts.joined(separator: " "))
    }

    /// PARÇALI ÇEKİM (kullanıcı kararı 2026-11-18: sayfanın 3/4'ünü kaplayan paragraf yarım kadraja da, tam sayfaya da sığmıyordu; her iki kadrajda "metin
    /// kesik" deniyordu): yarımlarda dikey kesik hata sayılmaz, sayfa yukarıdan aşağı örtüşen parçalarla alınır. Üst parça: sayfanın üstü görünüyor (kâğıt
    /// kenarı ya da kesik kanıtı yok). Alt uç açıksa ("açık blok": alttan kesilen soru ya da paragraf) kullanıcı aşağı kaydırır ve açık bloğun ilk satırının
    /// ekranda kalması istenir: sıradaki parça bunun sözcüklerini içeriyorsa (`continuing`) boşluk kalmamıştır, soru tam görünmüştür. Alt parça: sayfanın
    /// altı görünüyor. Yarımda "uzaklaşın" denmez. `continuing`: nil = açık parça yok; true / false = önceki parçanın sözcükleri bu kadrajda var / yok.
    static func halvesNote(_ lines: ViewLines, reading: PageLayoutReading?, continuing: Bool?, verbose: Bool, turn: Int = 0) -> FramingNote {
        let up = ViewDirection.up.turned(turn).move
        let down = ViewDirection.down.turned(turn).move
        let topSeen = reading?.layout == .full || reading?.layout == .upperHalf
        let bottomSeen = reading?.layout == .full || reading?.layout == .lowerHalf
        let topAnchored: Bool
        switch continuing {
        case .some(true): topAnchored = true
        case .some(false): topAnchored = topSeen
        case .none: topAnchored = topSeen || lines.topComplete
        }
        // Kâğıt kenarları biliniyorsa sayfa bitti mi onlardan; bilinmiyorsa yazıdan
        let bottomReached = reading != nil ? bottomSeen : lines.bottomComplete
        let tails = questionsText(lines) == nil ? lines.shortCoverage : nil
        if !topAnchored {
            if continuing == false {
                return FramingNote(kind: .incomplete, text: verbose ? "Önceki parçayla örtüşmüyor. Kamerayı biraz \(up) kaydırın." : "Örtüşme yok, biraz \(up).")
            }
            // Sayfanın üstü alınmadı (ya da hiç parça yok): önce üst parça
            return FramingNote(kind: .incomplete, text: ["Metin kesik, biraz \(up).", lines.shortCoverage].compactMap { $0 }.joined(separator: " "))
        }
        if bottomReached {
            if continuing == true, reading?.layout != .full {
                return FramingNote(kind: .goodLower, text: "Alt parça, örtüşüyor.")
            }
            if let r = reading, r.layout != .middle {
                let kind: FramingNote.Kind = r.layout == .upperHalf ? .goodUpper : (r.layout == .lowerHalf ? .goodLower : .goodFull)
                let spoken = [layoutText(r, verbose: verbose, turn: turn), (r.layout == .full && !lines.paragraph) ? nil : tails].compactMap { $0 }
                return FramingNote(kind: kind, text: spoken.joined(separator: " "))
            }
            return FramingNote(kind: .good, text: tails ?? (verbose ? "Kadraj uygun." : okText))
        }
        let label = continuing == true ? "Orta parça, örtüşüyor." : (topSeen ? "Üst parça." : "Parça.")
        let move = lines.anchorHead.map { "\(capitalised(down)) kaydırın; \($0) satırı kalsın." } ?? "Biraz \(down) kaydırın."
        return FramingNote(kind: .goodPart, text: label + " " + move)
    }

    /// Yazı okunabildiği kanıtlanmış görünümde yazının küçüklüğü, bulanıklığı, parlaması ve "yazı yok" kararı iptal edilir (okunuyor: daha mükemmel
    /// görüntüye gerek yok). Gerçek kenar kesiği ve kadraja sığmama (uzaklaşın) olduğu gibi kalır; "önce kaydır sonra yaklaş" (küçük yazı) iptal olur.
    static func relaxed(_ d: GuidanceDecision) -> GuidanceDecision {
        switch d.advice {
        case .noText, .blurry, .glare, .closer:
            return GuidanceDecision(advice: .ok, fill: d.fill)
        case .moveLeft, .moveRight, .moveUp, .moveDown:
            return d.scale > 1 ? GuidanceDecision(advice: .ok, fill: d.fill) : d
        case .farther, .ok:
            return d
        }
    }

    /// "Kadraj kontrolü" için tam tarif: kaç sayfa görünüyor ve hangisi kesik, varsa düzeltme, sayfanın durumu, satır tarifi. Yazı yoksa yalnız nedeni.
    static func describe(_ m: PageMetrics, lines: ViewLines?, config c: GuidanceConfig = GuidanceConfig(), sharpFloor: Double = 0.45) -> String {
        let n = note(m, lines: lines, config: c, sharpFloor: sharpFloor, verbose: true)
        guard m.hasText, n.kind != .noText else { return n.text }
        var parts: [String] = []
        let scenes = GuidanceScene.parts(m, config: c)
        // Sayfanın durumu zaten söyleniyorsa ("Tam sayfa görünüyor…") tek sayfa cümlesi tekrarlanmaz
        let layoutSaid = [FramingNote.Kind.goodFull, .goodUpper, .goodLower, .middle].contains(n.kind)
        if !(layoutSaid && scenes.count == 1), let scene = GuidanceScene.describe(scenes, edges: GuidanceScene.usableEdges(m)) { parts.append(scene) }
        parts.append(n.text)
        if n.isCorrection, n.kind != .middle, let coverage = lines?.coverage { parts.append(coverage) }
        return parts.joined(separator: " ")
    }

    /// İki sözcük kümesinin örtüşmesi (kesişim / küçük kümenin boyu); biri boşsa 0
    static func overlap(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(min(a.count, b.count))
    }
}

/// Koçun konuşma zamanlaması (saf mantık): kamera durgunlaşınca ve aynı değerlendirme ardışık iki ölçümde çıkınca söyler; aynı cümleyi sık tekrarlamaz,
/// aynı düzeltmeyi en çok üç kez söyler (ısrar edilmez), "tamam"ı düzeltmeden sonra bir kez söyler, düzgün kadrajda yalnız görünüm değişince yeniden anlatır.
/// YENİ SAYFA (kullanıcı kararı 2026-11-17: gösterilen her sayfa için yardım yeniden başlar): kamera hareket edip yeniden durunca görünümün satır
/// sözcükleri öncekiyle büyük ölçüde örtüşmüyorsa (ya da okunamadıysa) sayaçlar, tekrar aralıkları ve "tamam" durumu sıfırlanır; ilk değerlendirme hemen söylenir.
/// Aynı sayfada küçük bir kaydırma (düzeltme denemesi) örtüşmeyi bozmaz: o zaman sayaçlar sürer.
struct FramingCoachTimer {
    struct Config {
        /// Kamera bu süredir durgunsa değerlendirilir. Bekleme süreleri (`stillNeeded`, `lineWait`, `edgeWait`) kullanıcı isteğiyle kısaltıldı 2026-11-18:
        /// ilk konumlandırma cümlesi geç geliyordu (0,35 / 1,5 / 0,9 idi)
        var stillNeeded: TimeInterval = 0.25
        /// Durgunluk bundan kısaysa kamera oynuyor sayılır (sayfa değişmiş olabilir)
        var movingBelow: TimeInterval = 0.15
        /// İki konuşma arası en az süre
        var speakGap: TimeInterval = 1.5
        /// Aynı değerlendirmenin yeniden söylenme aralığı
        var repeatGap: TimeInterval = 6
        /// Kaç ardışık ölçüm aynı çıkınca söylenir
        var stable = 2
        /// Aynı düzeltme art arda en çok kaç kez söylenir
        var maxSameCorrection = 3
        /// Hareketten sonra satırlar okunana kadar en çok bu kadar beklenir (sayfa değişti mi diye bakılır); sonra yeni sayfa sayılır
        var lineWait: TimeInterval = 1.0
        /// Kâğıt kenarları bekleniyorsa (ayar açık) düzgün kadraj cümlesi için durgunluk en az bu kadar sürmeli: üç durum (tam / üst / alt) kenarlardan bilinir
        var edgeWait: TimeInterval = 0.6
        /// Bir sayfada (görünümde) en çok bu kadar cümle söylenir: ölçüm gürültüsü kulaklıkta sürekli konuşmaya dönüşmesin (yeni sayfada sıfırlanır)
        var maxPerView = 8
        /// Sözcük örtüşmesi bundan azsa görünüm yeni sayfadır
        var sameView = 0.4
        /// Sayfa karşılaştırmasında bundan kısa sözcükler ("ve", "bir", "için") sayılmaz
        var minWordLength = 4
        /// Tam sayfa için bu kadar uzaklaşma söylendikten sonra tam sayfa olmuyorsa yarım yarım çekime geçilir (`firstReadable` + `wholeFirst`). Gerçek günlük
        /// 2026-11-18: iki denemede 75 sn'nin 52 sn'si tam sayfa aramakla geçti, bu yüzden tek deneme
        var wholeTries = 1
        /// Son uzaklaşma cümlesinden bu kadar sn sonra (kullanıcıya uyması için süre) yarım yarım çekime geçilir
        var wholeWait: TimeInterval = 4
        /// Bu kadar sayfada tam sayfa olmayıp yarımlara geçildiyse sonraki sayfalar doğrudan yarımlarla başlar (tam sayfa yine kabul edilir)
        var halvesLearned = 1
        /// Parçalı çekimde açık parçanın sözcükleri bu kadar süre (sn) geçerlidir: sayfa çevrilmişse eski parçayla örtüşme aranmaz
        var chainLife: TimeInterval = 25
        /// Açık parçanın sözcüklerinin bu oranı yeni kadrajda görünüyorsa kadraj öncekiyle örtüşüyor sayılır
        var chainOverlap = 0.5
    }

    var config = Config()
    private var candidate: FramingNote.Kind?
    private var consecutive = 0
    private var lastKind: FramingNote.Kind?
    private var lastTime: TimeInterval = -1000
    private var sameCount = 0
    private var lastWords: Set<String> = []
    private var correctionPending = false
    private var moved = false
    private var viewWords: Set<String> = []
    private var waitingSince: TimeInterval?
    private var spokenInView = 0
    /// Son söylenen cümle düzgün kadraj cümlesi miydi (çağıran bunun sonuna "çekildi" ekler; bkz. `FramingCoach.withCapture`)
    private(set) var lastWasGood = false
    /// Son söylenen cümle düzgün kadrajsa ve soru numaraları okunduysa "Alındı. Sonraki." yerine söylenecek cümle (bkz. `FramingCoach.questionsText`)
    private(set) var lastCapture: String?
    /// Yazı tanıma sonucu beklenirken (`firstReadable`) bekleme başlangıcı
    private var textWaitSince: TimeInterval?
    /// Bu görünümde tam sayfa için söylenen uzaklaşma sayısı; `Config.wholeTries`'a ulaşıp tam sayfa olmazsa yarım yarım çekime geçilir (bkz. `ShotPlan`)
    private var wholeTries = 0
    /// Bu sayfa için yarım yarım çekime geçildi
    private var halvesMode = false
    /// Yarım yarım çekimde üst yarı alındı: sıradaki görünüm aynı sayfanın alt yarısıdır (tam sayfa yeniden denenmez)
    private var expectSecondHalf = false
    /// Oturum boyunca öğrenme: üst üste kaç sayfada tam sayfa olmayıp yarımlara geçildi (`Config.halvesLearned`'a ulaşınca sonraki sayfalar doğrudan yarımlarla
    /// başlar: kitapçığın sayfaları aynı boydadır, her sayfada tam sayfa denemesiyle süre yitirilmez). Tam sayfa kabul edilince sıfırlanır
    private var halvesStreak = 0
    /// Bu sayfa için yarımlara geçiş seriye sayıldı
    private var countedHalves = false
    /// Parçalı çekim: son alınan parçanın açık (alttan kesik) bloğunun sözcükleri ve alındığı an; boşsa açık parça yok
    private var chainAnchor: Set<String> = []
    private var chainTime: TimeInterval = -1000
    /// Alınan (söylenen) tam sorular, hangi durgun dönemde alındığıyla; aynı durgunlukta ("aldım" dedikten sonra beklerken) "zaten alındı" denmez, kamera
    /// oynayıp yeniden durunca denir. `epoch`: kamera her oynamaya başladığında artar
    private var taken: [(mark: QuestionMark, epoch: Int)] = []
    private var epoch = 0
    /// Son söylenen cümle sayfanın bitmediği bir parçaydı (çağıran sonuna "Alındı. Sonraki." eklemez: sıradaki parça aynı sayfanın devamıdır)
    private(set) var lastWasOpen = false

    mutating func reset() {
        taken = []
        epoch = 0
        chainAnchor = []
        chainTime = -1000
        lastWasOpen = false
        textWaitSince = nil
        wholeTries = 0
        halvesMode = false
        expectSecondHalf = false
        halvesStreak = 0
        countedHalves = false
        lastCapture = nil
        candidate = nil
        consecutive = 0
        lastKind = nil
        lastTime = -1000
        sameCount = 0
        lastWords = []
        correctionPending = false
        moved = false
        viewWords = []
        waitingSince = nil
        spokenInView = 0
        lastWasGood = false
    }

    /// Görünümün kimliği: ilk ve son tam satırın sözcükleri (küçük harf, kısa sözcükler atılır)
    static func viewSignature(_ lines: ViewLines?, minLength: Int = 4) -> Set<String> {
        guard let lines = lines else { return [] }
        let all = (lines.starts + lines.ends).flatMap { ViewLines.words($0.words) }
        return Set(all.map { $0.lowercased() }.filter { $0.count >= minLength })
    }

    /// Yeni sayfa: önceki sayfanın konuşma durumu unutulur (konuşma arası `speakGap` korunur: cümleler üst üste binmez)
    private mutating func startNewView() {
        textWaitSince = nil
        // Düzeltme sürerken görünüm değişti (kullanıcı aynı sayfada uzaklaşıp yaklaşıyor): plan ve deneme sayısı korunur, yoksa tam sayfa denemesi hiç bitmez.
        // Sayfa kabul edildiyse ya da hiçbir şey söylenmediyse yeni sayfadır: plan baştan, önce tam sayfa. Yarım yarım çekimde üst yarıdan sonraki görünüm
        // aynı sayfanın alt yarısıdır: yeniden tam sayfa denenmez
        if lastKind == nil || lastKind?.isGood == true {
            halvesMode = (halvesMode && expectSecondHalf) || halvesStreak >= config.halvesLearned
            expectSecondHalf = false
            wholeTries = 0
            countedHalves = false
        }
        // Açık parçadan sonraki görünüm aynı sayfanın devamıdır (örtüşme aranır); başka durumda parça zinciri biter
        if lastKind != .goodPart { chainAnchor = [] }
        candidate = nil
        consecutive = 0
        lastKind = nil
        sameCount = 0
        lastWords = []
        correctionPending = false
        spokenInView = 0
    }

    /// Söylenecek cümle ya da nil. `expectEdges`: kâğıt kenarı algılaması açık; düzgün kadraj cümlesi kenarlar gelene kadar bekler.
    /// `firstReadable` (canlı koç): okunabilen, tam görünen ve bozuk olmayan ilk görüntü kabul edilir (bkz. `FramingCoach.note`); yazı tanıma sonucu
    /// gelene kadar (en çok `lineWait`) iptal olabilecek değerlendirmeler ("yaklaşın", "bulanık", "uygun"…) söylenmez.
    /// `wholeFirst` (kullanıcı kararı 2026-11-18): her yeni sayfada önce TÜM SAYFA tek seferde istenir (`ShotPlan.wholePage`); `Config.wholeTries` denemede
    /// olmazsa ya da tam sayfa okunmuyorsa yarım yarım çekime geçilir (`ShotPlan.halves`), o sayfa için sürer
    mutating func step(metrics m: PageMetrics, lines: ViewLines?, time: TimeInterval, stillFor: TimeInterval,
                       guidance c: GuidanceConfig = GuidanceConfig(), sharpFloor: Double = 0.45, expectEdges: Bool = false,
                       firstReadable: Bool = false, wholeFirst: Bool = false, turn: Int = 0) -> String? {
        if stillFor < config.movingBelow {
            if !moved { epoch += 1 }
            moved = true
            waitingSince = nil
            candidate = nil
            consecutive = 0
            return nil
        }
        guard stillFor >= config.stillNeeded else {
            candidate = nil
            consecutive = 0
            return nil
        }
        if moved {
            // Önceki görünüm yoksa (oturumdaki ilk görünüm) karşılaştırılacak sayfa da yoktur: satırlar beklenmez
            if lines == nil && !viewWords.isEmpty {
                let since = waitingSince ?? time
                waitingSince = since
                if time - since < config.lineWait { return nil }   // satırlar okunana kadar: sayfa değişti mi bilinmiyor
            }
            let words = FramingCoachTimer.viewSignature(lines, minLength: config.minWordLength)
            let same = !words.isEmpty && !viewWords.isEmpty && FramingCoach.overlap(words, viewWords) >= config.sameView
            if !same { startNewView() }
            viewWords = words
            moved = false
            waitingSince = nil
        } else {
            // Durgun görünümün kimliği güncel tutulur: hareket başlayınca "önceki görünüm" budur
            let words = FramingCoachTimer.viewSignature(lines, minLength: config.minWordLength)
            if !words.isEmpty { viewWords = words }
        }
        let plan: ShotPlan = !firstReadable ? .any : (halvesMode ? .halves : (wholeFirst ? .wholePage : .any))
        var continuing: Bool?
        if plan == .halves, !chainAnchor.isEmpty, time - chainTime <= config.chainLife {
            continuing = chainAnchor.count < 3 || FramingCoach.overlap(chainAnchor, lines?.words ?? []) >= config.chainOverlap
        }
        var note = FramingCoach.note(m, lines: lines, config: c, sharpFloor: sharpFloor, firstReadable: firstReadable, plan: plan, continuing: continuing, turn: turn)
        if note.kind == .taken, let lines = lines, lines.completeQuestions == 1, lines.topComplete, lines.bottomComplete, let mark = lines.completeMarks.first,
           taken.contains(where: { $0.epoch < epoch && $0.mark.isSame(as: mark) }) {
            // Daha önce alınan sorunun üzerinde yeniden durulmuş ve kadrajda başka soru yok. Kadrajda birkaç soru varsa (ya da komşu soru kesik görünüyorsa)
            // mükerrer alım sorun sayılmaz: bu kural yalnız tek başına kalan, alınmış soru için
            note = FramingNote(kind: .alreadyTaken, text: FramingCoach.alreadyTakenText(number: mark.number))
        }
        let seeksWhole = plan == .wholePage && (note.kind == .wholePage || note.kind == .tooWide || note.kind == .incomplete)
        if seeksWhole, wholeTries >= config.wholeTries, time - lastTime >= config.wholeWait {
            // Tam sayfa için yeterince denendi ve olmadı: yarım yarım çekime geçilir
            note = FramingNote(kind: .halves, text: FramingCoach.halvesText)
        }
        if firstReadable {
            if lines != nil {
                textWaitSince = nil
            } else if note.kind.awaitsText {
                let since = textWaitSince ?? time
                textWaitSince = since
                if time - since < config.lineWait {
                    candidate = nil
                    consecutive = 0
                    return nil
                }
            }
        }
        if expectEdges, note.kind == .good, stillFor < config.edgeWait {
            candidate = nil
            consecutive = 0
            return nil
        }
        // Sayfa durumu bilinmişken kenarlar bir an belirsizleşirse ("Kadraj uygun.") geri düşülmez: ölçüm gürültüsüyle iki cümle arasında gidip gelinmesin
        if note.kind == .good, let last = lastKind, last.isGood, last != .good {
            candidate = nil
            consecutive = 0
            return nil
        }
        if note.kind == candidate {
            consecutive += 1
        } else {
            candidate = note.kind
            consecutive = 1
        }
        // Tam görünen soru hemen söylenir (tek ölçüm yeter): ilk konumlandırma cümlesi geç geliyordu
        let needed = note.kind == .taken ? 1 : config.stable
        guard consecutive >= needed, time - lastTime >= config.speakGap, spokenInView < config.maxPerView else { return nil }
        let changed = note.kind != lastKind
        var words: Set<String> = []
        if note.kind.isGood {
            words = Set((lines?.ends ?? []).flatMap { ViewLines.words($0.words).map { $0.lowercased() } })
            if !changed {
                // Aynı düzgün kadraj: yalnız görünüm değiştiyse (alttaki satır başka) ve aralık dolduysa yeniden anlatılır
                guard time - lastTime >= config.repeatGap, !words.isEmpty, FramingCoach.overlap(words, lastWords) < 0.5 else { return nil }
            }
            sameCount = 0
        } else if changed {
            sameCount = 1
        } else {
            guard time - lastTime >= config.repeatGap, sameCount < config.maxSameCorrection else { return nil }
            sameCount += 1
        }
        var text = note.text
        if note.kind.isGood && correctionPending { text = note.text == FramingCoach.okText ? "Tamam." : "Tamam. " + text }
        correctionPending = note.isCorrection
        lastKind = note.kind
        lastTime = time
        lastWords = words
        spokenInView += 1
        lastWasGood = note.kind.isGood
        lastWasOpen = note.kind == .goodPart
        if plan == .halves {
            if note.kind == .goodPart {
                chainAnchor = lines?.anchor ?? []
                chainTime = time
            } else if note.kind.isGood {
                chainAnchor = []
            }
        }
        if note.kind == .taken, let marks = lines?.completeMarks {
            let now = epoch
            for mark in marks { taken.append((mark: mark, epoch: now)) }
        }
        lastCapture = note.kind.isGood ? FramingCoach.questionsText(lines) : nil
        if note.kind == .halves {
            halvesMode = true
            if !countedHalves {
                halvesStreak += 1
                countedHalves = true
            }
        }
        if plan == .wholePage && (note.kind == .goodFull || note.kind == .taken) { halvesStreak = 0 }
        if seeksWhole && note.kind != .halves { wholeTries += 1 }
        if plan == .halves && (note.kind == .goodUpper || note.kind == .goodPart) { expectSecondHalf = true }
        return text
    }
}
