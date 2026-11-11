import Foundation

/// Deneme sınavı metin yardımcıları (Windows sürümündeki g526/exam_text.py'nin karşılığı): Türkçe sayıların okunuşu ve
/// ayrıştırılması, serbest söylenen komutların ANLAM olarak eşleştirilmesi.
/// Komutlar tam cümle değil, anlam olarak aranır: sözcük sırası ve ekler önemli değildir, o an geçerli komutlara bakılır,
/// olumsuz söylenişler ("tarama bitmedi") komut sayılmaz.
enum ExamText {
    // MARK: Normalleştirme

    private static let foldMap: [Character: Character] = ["ç": "c", "ğ": "g", "ı": "i", "ö": "o", "ş": "s", "ü": "u",
                                                         "â": "a", "î": "i", "û": "u"]

    /// Küçük harfe ve aksansız Latin harflerine çevirir (Türkçe özel harfler dahil)
    static func fold(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "İ", with: "i").replacingOccurrences(of: "I", with: "ı")
        s = s.lowercased()
        return String(s.map { foldMap[$0] ?? $0 })
    }

    static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for u in fold(text).unicodeScalars {
            let v = u.value
            if (v >= 97 && v <= 122) || (v >= 48 && v <= 57) {
                cur.unicodeScalars.append(u)
            } else if !cur.isEmpty {
                out.append(cur)
                cur = ""
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    // MARK: Sayılar (okunuşu)

    private static let units = ["", "bir", "iki", "üç", "dört", "beş", "altı", "yedi", "sekiz", "dokuz"]
    private static let tensWords = ["", "on", "yirmi", "otuz", "kırk", "elli", "altmış", "yetmiş", "seksen", "doksan"]
    private static let ordLast: [String: String] = [
        "bir": "birinci", "iki": "ikinci", "üç": "üçüncü", "dört": "dördüncü", "beş": "beşinci", "altı": "altıncı",
        "yedi": "yedinci", "sekiz": "sekizinci", "dokuz": "dokuzuncu", "on": "onuncu", "yirmi": "yirminci",
        "otuz": "otuzuncu", "kırk": "kırkıncı", "elli": "ellinci", "altmış": "altmışıncı", "yetmiş": "yetmişinci",
        "seksen": "sekseninci", "doksan": "doksanıncı", "yüz": "yüzüncü", "bin": "bininci", "sıfır": "sıfırıncı"]

    /// 0...9999 için yazı ile sayı: 37 → "otuz yedi". Dışındakiler rakamla döner.
    static func cardinal(_ n: Int) -> String {
        if n < 0 || n > 9999 { return String(n) }
        if n == 0 { return "sıfır" }
        var parts: [String] = []
        let th = n / 1000
        var rest = n % 1000
        if th > 0 { parts.append(th == 1 ? "bin" : units[th] + " bin") }
        let h = rest / 100
        rest = rest % 100
        if h > 0 { parts.append(h == 1 ? "yüz" : units[h] + " yüz") }
        let t = rest / 10
        let u = rest % 10
        if t > 0 { parts.append(tensWords[t]) }
        if u > 0 { parts.append(units[u]) }
        return parts.joined(separator: " ")
    }

    /// Sıra sayısı: 1 → "birinci", 37 → "otuz yedinci"
    static func ordinal(_ n: Int) -> String {
        if n < 0 || n > 9999 { return "\(n)." }
        var words = cardinal(n).components(separatedBy: " ")
        if let last = words.last { words[words.count - 1] = ordLast[last] ?? last }
        return words.joined(separator: " ")
    }

    // MARK: Sayılar (ayrıştırma)

    private static let unitWords: [String: Int] = ["bir": 1, "iki": 2, "uc": 3, "dort": 4, "bes": 5, "alti": 6, "yedi": 7,
                                                   "sekiz": 8, "dokuz": 9]
    private static let tensParse: [String: Int] = ["on": 10, "yirmi": 20, "otuz": 30, "kirk": 40, "elli": 50, "altmis": 60,
                                                   "yetmis": 70, "seksen": 80, "doksan": 90]
    private static let ordWords: [String: Int] = [
        "birinci": 1, "ikinci": 2, "ucuncu": 3, "dorduncu": 4, "besinci": 5, "altinci": 6, "yedinci": 7, "sekizinci": 8,
        "dokuzuncu": 9, "onuncu": 10, "yirminci": 20, "otuzuncu": 30, "kirkinci": 40, "ellinci": 50, "altmisinci": 60,
        "yetmisinci": 70, "sekseninci": 80, "doksaninci": 90, "yuzuncu": 100, "bininci": 1000]

    private enum Kind { case digit, unit, tens, hundred, thousand }

    private struct NumTok {
        let kind: Kind
        let value: Int
        let ordinal: Bool
        let pos: Int
    }

    private static func kindOf(_ tok: String) -> (kind: Kind, value: Int, ordinal: Bool)? {
        if let v = unitWords[tok] { return (.unit, v, false) }
        if let v = tensParse[tok] { return (.tens, v, false) }
        if tok == "yuz" { return (.hundred, 100, false) }
        if tok == "bin" { return (.thousand, 1000, false) }
        if let v = ordWords[tok] {
            let kind: Kind = v < 10 ? .unit : (v < 100 ? .tens : (v == 100 ? .hundred : .thousand))
            return (kind, v, true)
        }
        return nil
    }

    private static func isDigits(_ s: String) -> Bool {
        return !s.isEmpty && s.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
    }

    /// Metindeki sayıları sırayla verir (rakam ya da Türkçe söz): "otuz yedinci soru ve 5" → [37, 5]. Tek başına "bir"
    /// ("bir daha" gibi) soru/numara sözcüğü yanındaysa sayılır. Aynı sayı bir kez.
    static func parseNumbers(_ text: String) -> [Int] {
        let toks = tokens(text)
        var out: [Int] = []
        func add(_ v: Int) {
            if v > 0 && v < 100000 && !out.contains(v) { out.append(v) }
        }
        var run: [NumTok] = []
        var runs: [[NumTok]] = []
        for (i, t) in toks.enumerated() {
            if isDigits(t) {
                if !run.isEmpty {
                    runs.append(run)
                    run = []
                }
                if let d = Int(t) { runs.append([NumTok(kind: .digit, value: d, ordinal: false, pos: i)]) }
                continue
            }
            if let k = kindOf(t) {
                run.append(NumTok(kind: k.kind, value: k.value, ordinal: k.ordinal, pos: i))
            } else if !run.isEmpty {
                runs.append(run)
                run = []
            }
        }
        if !run.isEmpty { runs.append(run) }

        for r in runs {
            guard let firstTok = r.first else { continue }
            if firstTok.kind == .digit {
                add(firstTok.value)
                continue
            }
            var th = 0
            var cur = 0
            var last: Kind?
            var emitted: [Int] = []
            func emit() {
                let v = th + cur
                if v > 0 { emitted.append(v) }
                th = 0
                cur = 0
                last = nil
            }
            for tok in r {
                switch tok.kind {
                case .unit:
                    if last == .unit { emit() }
                    cur += tok.value
                    last = .unit
                case .tens:
                    if last == .tens || last == .unit { emit() }
                    cur += tok.value
                    last = .tens
                case .hundred:
                    if tok.value == 100 && last == .unit && cur < 10 {
                        cur *= 100
                    } else if last == nil || last == .thousand {
                        cur += 100
                    } else {
                        emit()
                        cur = 100
                    }
                    last = .hundred
                default:
                    if last == .unit || last == .hundred || last == .tens {
                        th += (cur == 0 ? 1 : cur) * 1000
                        cur = 0
                    } else {
                        th += 1000
                    }
                    last = .thousand
                }
                if tok.ordinal { emit() }
            }
            emit()
            if r.count == 1 && firstTok.kind == .unit && firstTok.value == 1 && !firstTok.ordinal {
                let nxt = firstTok.pos + 1 < toks.count ? toks[firstTok.pos + 1] : ""
                let prev = firstTok.pos > 0 ? toks[firstTok.pos - 1] : ""
                if !(nxt.hasPrefix("soru") || nxt.hasPrefix("numara") || prev.hasPrefix("soru") || prev.hasPrefix("numara")) {
                    continue          // "bir daha oku" gibi: sayı değil
                }
            }
            for v in emitted { add(v) }
        }
        if toks.contains("ilk") && !out.contains(1) && toks.contains(where: { $0.hasPrefix("soru") }) {
            out.insert(1, at: 0)
        }
        return out
    }

    // MARK: Anlam olarak komut eşleştirme

    private static func has(_ toks: [String], _ stems: [String]) -> Bool {
        for t in toks {
            for s in stems where t.hasPrefix(s) { return true }
        }
        return false
    }

    private static func exact(_ toks: [String], _ words: Set<String>) -> Bool {
        return toks.contains(where: { words.contains($0) })
    }

    /// "tüm cevapları oku", "hepsini baştan tekrarla", "cevapların hepsi" gibi: kayıtlı cevapların tamamı isteniyor mu?
    /// needSubject: "cevap" ya da "soru" sözcüğü de aranır (sınav dışında, serbest konuşmada yanlış tetiklenmesin).
    static func wantsAll(_ text: String, needSubject: Bool = false) -> Bool {
        let toks = tokens(text)
        if !parseNumbers(text).isEmpty && !has(toks, ["hepsi", "tum", "butun"]) { return false }
        let every = has(toks, ["hepsi", "tum", "butun", "bastan", "tamamini"])
        let verb = has(toks, ["oku", "tekrar", "soyle", "ver", "dinle", "sirala", "say"])
        let subject = has(toks, ["cevap", "soru", "yanit"])
        if !every || !(verb || subject) { return false }
        return needSubject ? subject : true
    }

    /// "5'ten 12'ye kadar", "5 ile 12 arası" → [5...12]; aralık değilse boş
    static func numberRange(_ text: String, limit: Int = 300) -> [Int] {
        let toks = tokens(text)
        let nums = parseNumbers(text)
        if nums.count == 2 && (toks.contains("kadar") || has(toks, ["arasi", "arasindaki", "ila"])) {
            let a = min(nums[0], nums[1])
            let b = max(nums[0], nums[1])
            if b - a < limit { return Array(a...b) }
        }
        return []
    }

    private static let negWords: Set<String> = ["degil", "hayir", "henuz", "yok", "olmadi", "olmamis"]
    private static let negPrefix = ["bitme", "bitirme", "tamamlanma", "tamamlama", "tamamlanamad", "bitiremed"]

    static func negated(_ toks: [String]) -> Bool {
        return exact(toks, negWords) || has(toks, negPrefix)
    }

    private static let scanSubj = ["tara", "sayfa", "belge", "hepsi", "bunlar", "soru", "foto", "cekim", "cektim", "cekil",
                                   "kagit", "yaprak", "evrak", "is"]
    private static let doneStrong = ["bitt", "bitir", "bitmis", "tamamlan", "tamamlad", "tamamla", "tamamlay", "sonlan",
                                     "sonuclan", "kalmad", "kalmadi"]
    private static let doneWords: Set<String> = ["tamam", "tamamdir", "tamamiz", "tamamdi", "hazir", "hazirim", "hazirlar",
                                                 "yeter", "yeterli", "son", "sonuncusu", "bu", "kadar", "hepsi", "bukadar",
                                                 "oldu", "olmustur", "bitis", "erdi", "erdik", "sona"]
    private static let sendStems = ["gonder", "yolla", "yukle", "aktar", "ilet", "drive"]
    private static let endWords = ["kapat", "kapa", "cik", "sonlan", "sonland", "bitir", "bitt", "tamamla", "tamamlan",
                                   "tamamlad", "bitis", "sonuc", "bitm"]
    private static let contWords: Set<String> = [
        "devam", "surdur", "surdurun", "evet", "peki", "haydi", "hadi", "baslayalim", "basla", "baslat", "oldu", "olur",
        "tamam", "tamamdir", "tabi", "tabii", "tabiki", "elbette", "buyur", "hazirim", "hazir", "gec", "gecelim", "sonraki",
        "siradaki", "ileri", "ilerle", "ok", "okay", "kabul", "dogru", "aynen", "onay", "onayliyorum"]
    private static let vdelWords: Set<String> = ["sil", "silin", "silelim", "sile", "silsene", "iptal", "vazgec", "vazgectim", "kaldir", "yanlis"]
    private static let vskipWords: Set<String> = ["atla", "atlayalim", "atlayin", "atlasana", "gec", "gecelim", "istemiyorum", "yok"]
    private static let vstopWords: Set<String> = ["durdur", "durdurun", "dur", "kapat", "kapa", "bitir", "bitti", "yeter", "tamam", "tamamdir", "stop"]
    private static let noWords: Set<String> = ["hayir", "yok", "olmaz", "istemiyorum", "yeter", "gerek", "gerekmez"]
    private static let pauseStems = ["duraklat", "beklet", "durdur", "dakika", "saniye", "susun", "sessiz"]
    private static let pauseWords: Set<String> = ["dur", "bekle", "bekleyin", "bekler", "yeter", "sus", "kes", "kesin", "sakin",
                                                  "pause"]
    private static let cancelWords: Set<String> = [
        "iptal", "vazgec", "vazgectim", "vazgeciyorum", "hayir", "yanlis", "degil", "henuz", "olmaz", "istemiyorum",
        "gonderme", "gondermeyin", "dur", "bekle", "durdur", "bekleyin", "hata", "yanlislik", "sakin"]
    private static let weakCancel: Set<String> = ["dur", "bekle", "durdur", "bekleyin", "sakin", "hata"]
    private static let newStems = ["yeni", "bastan", "sifirdan", "temiz", "bosalt", "yenisini"]
    private static let undoDel = ["sil", "iptal", "kaldir", "cikar", "at", "atin", "yok"]
    private static let undoObj = ["sayfa", "taram", "foto", "cekim", "son", "bunu", "bu", "onu", "sunu", "su", "kagit", "yaprak",
                                  "evrak", "resim", "goruntu"]
    private static let undoBad = ["yanlis", "bozuk", "bulanik", "olmadi", "kotu", "hatali", "silik", "karanlik", "okunmuyor"]
    private static let startVerbs = ["mod", "basla", "baslat", "gec", "ac", "yapal", "calisal", "hazirla", "cozel", "cozum",
                                     "cozdur", "yapalim", "girel", "gir", "gireyim", "baslayal", "calistir", "etkinles",
                                     "devreye"]

    /// `text` içinde, `valid` kümesindeki hangi komutun anlamı var? Döndürür: komut adı ya da nil.
    /// Sıralama önceliktir (özel olan genel olandan önce). Söyleniş serbesttir: sıra, ek ve eşanlamlı sözcük farkı önemsizdir.
    /// Komut adları: start, scan_done, more, undo, end, cancel, pause, continue, new; video aşaması: vstop, vdel, vskip, yes, no.
    static func match(_ text: String, _ valid: Set<String>) -> String? {
        let toks = tokens(text)
        if toks.isEmpty { return nil }
        let neg = negated(toks)
        let sinav = has(toks, ["sinav", "test", "deneme"])
        let examWord = has(toks, ["sinav", "test"])
        let scanSubject = has(toks, scanSubj)
        let scanVerb = has(toks, ["tara", "cek", "cekim", "ekle", "tarat"])

        // Video aşaması (yalnız o aşamada geçerli): sil → göndermeden sil; atla → fotoğrafa geç; durdur/kapat → kaydı bitir; evet / hayır
        // ("sınav" sözcüğü geçiyorsa bunlar değil, sınavı kapatma / bitirme komutu sayılır)
        if valid.contains("vdel") && !examWord && exact(toks, vdelWords) { return "vdel" }
        if valid.contains("vskip") && !examWord && (exact(toks, vskipWords) || has(toks, ["fotograf", "taramaya"])) { return "vskip" }
        if valid.contains("vstop") && !examWord && exact(toks, vstopWords) { return "vstop" }
        if valid.contains("no") && (neg || exact(toks, noWords) || has(toks, ["fotograf", "tarama"])) { return "no" }
        if valid.contains("yes") && (exact(toks, contWords) || has(toks, ["devam", "evet"])) { return "yes" }

        if valid.contains("cancel") {
            let strong = toks.contains(where: { cancelWords.contains($0) && !weakCancel.contains($0) })
            let shortStop = toks.contains(where: { weakCancel.contains($0) }) && toks.count <= 3
            if strong || neg || shortStop { return "cancel" }
        }
        if valid.contains("undo") {
            let deleting = has(toks, undoDel) && !has(toks, ["atla"])
            let badPage = has(toks, undoBad) && (scanVerb || has(toks, ["sayfa", "foto", "resim", "goruntu", "cikti", "cekti", "olmus"]))
            if (deleting && (has(toks, undoObj) || has(toks, undoBad))) || badPage
                || (toks.contains("geri") && toks.contains("al") && !toks.contains("tarama")) || toks == ["olmadi"] {
                return "undo"
            }
        }
        if valid.contains("more") && !neg {
            let again = has(toks, ["yeniden", "tekrar", "ilave", "daha", "ekle", "eksik", "devam"])
            if (scanVerb && again)
                || (has(toks, ["sayfa"]) && has(toks, ["ekle", "daha", "eksik", "ilave", "yeni"]))
                || (has(toks, ["okunamayan", "eksik", "kayip", "alinamayan"]) && (scanVerb || has(toks, ["sayfa", "soru", "belge"])))
                || (has(toks, ["taramay"]) && has(toks, ["devam", "don", "geri", "yeniden", "tekrar"]))
                || has(toks, ["tarayacag", "taratacag", "cekecegim", "ekleyecegim"]) {
                return "more"
            }
        }
        if valid.contains("end") {
            if sinav && (has(toks, endWords) || has(toks, ["sona", "erd"]) || exact(toks, ["tamam", "tamamdir", "yeter", "bu", "kadar"])) && !neg {
                return "end"
            }
            if !valid.contains("scan_done") && !neg
                && (has(toks, endWords) || (toks.contains("bu") && toks.contains("kadar"))
                    || exact(toks, ["gorusuruz", "hoscakal", "cikis", "bye", "gule", "saol", "sagol", "tesekkurler", "tesekkur"])) {
                return "end"
            }
        }
        if valid.contains("scan_done") && !neg {
            if has(toks, sendStems) && (scanSubject || toks.count <= 3 || has(toks, ["hepsi", "artik", "simdi", "drive"])) {
                return "scan_done"
            }
            if has(toks, doneStrong) && (scanSubject || toks.count <= 3) { return "scan_done" }
            if scanSubject && exact(toks, doneWords) && has(toks, ["tara", "hepsi", "bunlar", "sayfa", "soru", "belge"]) {
                return "scan_done"
            }
            if exact(toks, ["taradim", "tarattim", "taramistim"]) || (toks.contains("hepsini") && has(toks, ["tara", "cek"])) {
                return "scan_done"
            }
        }
        if valid.contains("new") && (has(toks, newStems) || (has(toks, ["eski"]) && has(toks, ["sil", "birak", "at", "kaldir"]))) {
            return "new"
        }
        if valid.contains("pause") && !neg
            && (has(toks, pauseStems) || has(toks, ["dinlen"]) || (toks.contains("ara") && has(toks, ["ver"]))
                || (exact(toks, pauseWords) && toks.count <= 4)) {
            return "pause"
        }
        if valid.contains("continue") && !neg {
            if exact(toks, contWords) || has(toks, ["devam", "surdur", "basla", "tamamdir", "sonraki", "kaldig"]) {
                return "continue"
            }
        }
        if valid.contains("start") {
            let deneme = has(toks, ["deneme"])
            if (deneme && (examWord || has(toks, startVerbs)))
                || (examWord && has(toks, startVerbs) && !has(toks, ["bitt", "tamamlan", "bitir"])) {
                return "start"
            }
            if has(toks, ["soru"]) && has(toks, ["cozel", "cozdur", "cevaplat", "cevaplayal"]) { return "start" }
        }
        return nil
    }

    /// Konuşma tanımaya ipucu olarak verilen kalıplar (tanıma bu söyleyişleri daha iyi yakalar)
    static let hints: [String] = [
        "deneme sınavı modu", "deneme sınavı", "sınav modu", "tarama tamamlandı", "taramalar tamamlandı", "taramaya devam",
        "sınav tamamlandı", "son sayfayı sil", "tüm cevapları oku", "devam", "iptal", "duraklat", "yeni sınav",
        "durdur", "sil", "atla", "evet", "hayır", "videoya devam"]
}
