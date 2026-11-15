import Foundation

/// Dinleme kipi: mikrofon şu an ne için açık, hangi sözcük işi bitirir.
enum ListenMode: Equatable {
    /// Soru okunuyor; "Cevapla" / "Gönder" ile gönderilir
    case question
    /// "Ortak paragraf" denmiş; paragraf okunuyor, "Tamam" (ya da "Tamamlandı") ile biter
    case passage
    /// Paragraf alındı; hangi sorulara ait olduğu numaralarla söyleniyor ("beş altı yedi, Cevapla")
    case passageTargets
    /// Soru okundu ama numarası söylenmedi; numara bekleniyor ("soru yedi")
    case missingNumber
    /// "Testi bitir" denmiş; onay bekleniyor: "evet" bitirir, "hayır" devam eder
    case confirmEnd
    /// Program açılırken önceki kayıt bulundu; "devam" (önceki kayıttan) ya da "yeni" (yeni sınav) bekleniyor
    case startChoice
    /// Cevaplar okundu; "devam" (teste devam), "tekrar" (cevapları yeniden oku) ya da "bitir" (testi tamamla) bekleniyor
    case reviewMenu
    /// Sürüm 4: "Bu soruyu kamera ile çekip göndermek ister misiniz?" sorusuna "evet" / "hayır" bekleniyor
    case cameraChoice
    /// Sürüm 4: "Ortak paragraf" denmiş; "Ortak paragrafı kamera ile çekmek ister misiniz?" sorusuna "evet" (kamera) / "hayır" (sesle okuma) bekleniyor
    case passageCameraChoice
    /// Sürüm 4: kamera "evet" denmiş; "Soru mu, ortak paragraf mı çekeceksiniz? Birinci seçenek soru, ikinci seçenek paragraf" sorusuna
    /// "bir / soru" ya da "iki / paragraf" bekleniyor
    case captureKindChoice
    /// Sürüm 4: bölüm tamamlandı ve cevaplar teyit edildi; "Yeni bir bölüm ile devam etmek ister misiniz, yoksa testi tamamlayalım mı?" sorusuna
    /// "evet" (yeni bölüm) ya da "hayır" / "testi tamamla" bekleniyor
    case nextSectionChoice
}

/// Kayıtlı ortak paragraf: ait olduğu sorulardan biri her sorulduğunda Gemini'ye soruyla birlikte gider
struct PassageContext: Equatable {
    var text: String
    var english: String
    var audio: Data?
    /// Paragrafın ait olduğu tüm numaralar (söylendiği gibi)
    var all: [Int]
    /// Henüz cevaplanmamış olanlar; hepsi cevaplanınca paragraf bırakılır
    var remaining: [Int]
    /// Paragraf o kadar uzun okundu ki kaydın başı bellek sınırı yüzünden atıldı (metin tam, ses eksik)
    var audioTruncated = false
    /// Sürüm 4: paragraf sesle okunmadı, kamerayla çekildi (fotoğraf + kısa video); bu durumda `text` boştur ve görüntüler her ilgili soruyla gider
    var shot: CapturedQuestion?

    var viaCamera: Bool { return shot != nil }
}

/// "Tamam" denmiş (ya da kamerayla çekilmiş) ama hangi sorulara ait olduğu henüz söylenmemiş paragraf
struct PassageDraft: Equatable {
    var text: String
    var english: String
    var audio: Data?
    var audioTruncated = false
    /// Sürüm 4: kamerayla çekilen paragraf (yalnız görüntü)
    var shot: CapturedQuestion?
}

/// Numarası okunmadığı için numara beklenirken tutulan soru
struct HeldQuestion: Equatable {
    var text: String
    var english: String
    var audio: Data?
}

/// "Ortak paragraf" komutu: okumanın en başında söylenir, paragrafın kendisi sonra okunur
enum PassageCommand {
    /// Paragrafı bitiren sözcük
    static let finishWords = ["Tamam", "Tamamlandı", "Tamamlandi"]
    /// Paragrafın hangi sorulara ait olduğunu söyledikten sonra söylenen sözcük. Burada hiçbir şey Gemini'ye gitmez, yalnız paragraf kaydedilir;
    /// bu yüzden "Tamam" denir. Alışkanlıkla "Cevapla", "Gönder" ya da "Tamamlandı" denirse de aynı işi görür.
    static let targetWords = ["Tamam", "Tamamlandı", "Tamamlandi", "Cevapla", "Gönder"]

    /// Metnin başındaki "ortak paragraf" ifadesinin kapladığı sözcük sayısı (0: ifade yok). Tanıyıcı ifadeyi bozabilir: "ortak paragrafı"
    /// (ek), "ortag baragraf" (b/p, g/k karışması), "ortak para graf" (bölünmüş) ve "ortakparagraf" (bitişik) kabul edilir.
    static func startLength(_ text: String) -> Int {
        let head = tokens(text).prefix(3).map { SpokenWords.fold($0) }
        guard !head.isEmpty else { return 0 }
        if head.count >= 2, SpokenWords.matches(head[0], ["ortak"]), SpokenWords.startsLike(head[1], "paragraf") { return 2 }
        if head.count >= 3, SpokenWords.matches(head[0], ["ortak"]), SpokenWords.startsLike(head[1] + head[2], "paragraf") { return 3 }
        if SpokenWords.startsLike(head[0], "ortakparagraf") { return 1 }
        return 0
    }

    /// Metin "ortak paragraf" ile mi başlıyor
    static func startsWith(_ text: String) -> Bool {
        return startLength(text) > 0
    }

    /// Baştaki komut sözcüklerini atar (komut yoksa metni olduğu gibi döndürür)
    static func stripStart(_ text: String) -> String {
        let length = startLength(text)
        guard length > 0 else { return text.trimmed }
        return tokens(text).dropFirst(length).joined(separator: " ").trimmed
    }

    private static func tokens(_ text: String) -> [String] {
        return text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }
}

/// Sesli komut ve cevaplar için sözcük ayrıştırma: noktalama atılır, büyük/küçük harf ve Türkçe harf farkları (ı/i, ö/o, ş/s…) yok sayılır,
/// baştaki ve sondaki "lütfen" atılır. Tanıyıcı sözcüğü yakın sesle yazabilir ("beş" yerine "peş", "yedi" yerine "yeti"): sözcükler ayrıca
/// ses anahtarıyla karşılaştırılır (`key`) ve beş harften uzun sözcüklerde tek harf farkı (`withinOneEdit`) hoşgörülür.
enum SpokenWords {
    static func of(_ text: String) -> [String] {
        var words = text.split(whereSeparator: { $0.isWhitespace })
            .map { fold(String($0)) }
            .filter { !$0.isEmpty }
        while words.first == "lutfen" { words.removeFirst() }
        while words.last == "lutfen" { words.removeLast() }
        return words
    }

    /// Küçük harf, noktalama atılmış, Türkçe harfler sadeleştirilmiş (ı → i dahil) tek sözcük
    static func fold(_ token: String) -> String {
        return TriggerDetector.fold(token).replacingOccurrences(of: "ı", with: "i")
    }

    /// Ses anahtarı: sesli/sessiz ünsüz çiftleri tek harfe indirilir (p→b, t→d, k→g, s→z). Tanıyıcı "beş"i "peş", "dört"ü "dörd" yazabilir.
    static func key(_ word: String) -> String {
        return String(word.map { ch -> Character in
            switch ch {
            case "p": return "b"
            case "t": return "d"
            case "k": return "g"
            case "s": return "z"
            default: return ch
            }
        })
    }

    /// Tek harf ekleme, silme, değiştirme ya da bitişik iki harfin yer değiştirmesiyle birbirine dönüşüyor mu (eşitse de true)
    static func withinOneEdit(_ a: String, _ b: String) -> Bool {
        let x = Array(a)
        let y = Array(b)
        if x == y { return true }
        if abs(x.count - y.count) > 1 { return false }
        var i = 0
        while i < x.count, i < y.count, x[i] == y[i] { i += 1 }
        if x.count == y.count {
            if Array(x[(i + 1)...]) == Array(y[(i + 1)...]) { return true }
            if i + 1 < x.count, x[i] == y[i + 1], x[i + 1] == y[i], Array(x[(i + 2)...]) == Array(y[(i + 2)...]) { return true }
            return false
        }
        let long = x.count > y.count ? x : y
        let short = x.count > y.count ? y : x
        return Array(long[(i + 1)...]) == Array(short[i...])
    }

    /// Sözcük sözlükte var mı: aynen, aynı sesle ("peş" = "beş") ya da (anahtarı beş harften uzunsa) tek harf farkla
    static func matches(_ word: String, _ vocabulary: Set<String>) -> Bool {
        if vocabulary.contains(word) { return true }
        let k = key(word)
        for entry in vocabulary {
            let ke = key(entry)
            if ke == k { return true }
            if k.count >= 5, ke.count >= 5, withinOneEdit(k, ke) { return true }
        }
        return false
    }

    /// Sözcük sözlükte AYNEN (ya da aynı sesle: "peş" = "beş") var mı; tek harf farkı sayılmaz. Olumsuz ekler yüzünden ("çekiyorum" / "çekmiyorum")
    /// tek harf farkı anlamı tersine çevirebildiği için, kritik "evet" sorularında yalnız bu sınama kullanılır.
    static func exactly(_ word: String, _ vocabulary: Set<String>) -> Bool {
        if vocabulary.contains(word) { return true }
        let k = key(word)
        return vocabulary.contains { key($0) == k }
    }

    /// Sözcük `stem` ile mi başlıyor (ek alabilir: "paragrafı"); yakın sesler ve tek harf farkı hoşgörülür
    static func startsLike(_ word: String, _ stem: String) -> Bool {
        let ks = key(stem)
        let kw = key(word)
        if kw.hasPrefix(ks) { return true }
        guard ks.count >= 5, kw.count >= ks.count - 1 else { return false }
        for length in [ks.count - 1, ks.count, ks.count + 1] where length > 0 && length <= kw.count {
            if withinOneEdit(String(kw.prefix(length)), ks) { return true }
        }
        return false
    }
}

/// Tek başına söylenen sesli komutlar ("testi bitir", "sınavı bitirelim", "son cevabı tekrarla", "cevapları tekrarla"). Yalnız metin TAMAMEN
/// komutsa tanınır: sorunun içinde geçen "testi bitirmek için hangisi…" gibi cümleler komut sayılmaz, soru olarak gider. Söyleyiş esnektir
/// ("lütfen", "artık", "istiyorum" gibi dolgu sözcükler, fiil ekleri, yakın sesli yazımlar kabul edilir). "Cevapla"/"Gönder" ile bitiyorsa da
/// çalışır ("testi bitir cevapla"): o durumda `parse` komut kısmına uygulanır.
///
/// - `endTest`: "testi bitir", "sınavı sonlandır", "bitirelim"
/// - `repeatLast`: "tekrarla", "son cevabı tekrar et", "cevabı oku" (tek cevap: son cevap)
/// - `replayAnswers`: "cevapları tekrarla", "tüm cevapları oku", "hepsini baştan dinleyelim" (çoğul: bütün cevaplar)
enum VoiceCommand: Equatable {
    case endTest
    /// "Bölümü tamamla", "bölümü bitir": sınavın şu anki bölümü biter (cevaplar okunur); test sürer, yeni bölüm sorulur
    case endSection
    case repeatLast
    case replayAnswers
    /// "Soruyu iptal et": okunmakta olan soru (dikte metni ve ses kaydı) silinir, kullanıcı baştan okur
    case cancelQuestion
    /// "Paragrafı iptal et": okunmakta ya da numaraları beklenen paragraf vazgeçilir; yoksa kayıtlı ortak paragraf silinir
    case cancelPassage
    /// "Soruyu atla", "yeni soru": yarım kalan ya da yanlış anlaşılan soru (metin, ses kaydı, numarası beklenen soru) bırakılır; sıradaki soru okunur
    case skipQuestion
    /// "Son soruyu sil", "son cevabı sil": en son kaydedilen sorunun kaydı (cevap satırı ve ses dosyası) silinir; önce "emin misiniz?" diye onay istenir
    case deleteLastQuestion
    /// "Kayıt sil", "belirli bir soruyu sil", "başka bir soruyu sil": kullanıcının söyleyeceği numaralı sorunun kaydı silinir (önce bölüm, sonra numara sorulur; onay istenir)
    case deleteChosenQuestion
    /// "Soru numarası düzelt", "numarayı değiştir": önce düzeltilecek sorunun numarası, sonra yeni numara sorulur; ikisi tekrarlanıp onay istenir
    case renumberQuestion
    /// "5. sorunun cevabını tekrarla": yalnız o sorunun cevabı yeniden okunur
    case repeatNumber(Int)
    /// "Anlamadım", "duyamadım", "bir daha söyle", "yeniden söyle", "tekrar söyle", "ne dedin": programın son sözü (soru, menü, cevap) yeniden söylenir
    case repeatSpeech
    /// "Yardım", "komutlar neler": program kullanılabilecek komutları söyler
    case help
    /// "Ne duydun", "duyduğunu oku": o ana kadar anlaşılan soru metni okunur
    case whatHeard
    /// "Son cümleyi sil": soru metninin son sözü (sessizlikle ayrılan kısım) silinir; soru yeniden okunmaz
    case deleteLast
    /// "Durum", "kaç soru cevaplandı": cevap sayısı, sıradaki numara, kulaklık, internet ve pil
    case status
    /// "Cevapsız soruları söyle": cevabı olmayan (atlanan) soru numaraları
    case missingAnswers
    /// "İnternet raporu", "şarj kaç", "ısındı mı", "ram durumu", "genel rapor": telefonun ve donanımın durumu sesle söylenir
    case report(ReportKind)
    /// "Sesi aç", "sesi kıs", "sesi yüzde elli yap": telefonun ses seviyesi değişir
    case volume(VolumeAction)
    /// "Görüntü kalitesini yüksek yap", "kamera sorusunu kapat", "kadrajı dikey yap": kamera ayarı değişir
    case camera(CameraAction)

    /// Testi ya da bölümü bitirme isteği (ikisi de önce onay ister)
    var isEnding: Bool { return self == .endTest || self == .endSection }

    /// Okunan soruyu bırakan komutlar: "soruyu iptal et" ve "soruyu atla"
    var isCancelQuestion: Bool { return self == .cancelQuestion || self == .skipQuestion }

    /// Bilgi ve düzeltme komutları: her kipte söylenebilir, soru metnini korur ve yaptığını ya da yapamadığını kısaca söyler
    var isInfo: Bool {
        switch self {
        case .help, .whatHeard, .deleteLast, .status, .missingAnswers, .report, .volume, .camera: return true
        default: return false
        }
    }

    static let subjects: Set<String> = ["test", "testi", "testimi", "teste", "sinav", "sinavi", "sinavimi", "sinava", "denemeyi", "deneme"]
    /// "Bölümü tamamla": bölüm konu sözcükleri (tamamen aynı yazılışlar; bulanık eşleşme "bölge" gibi sözcükleri komut yapmasın)
    static let sectionSubjects: Set<String> = ["bolum", "bolumu", "bolumum", "bolumun", "bolumumu", "bolume"]
    static let endVerbs: Set<String> = [
        "bitir", "bitirin", "bitirelim", "bitirsek", "bitirmek", "bitirir", "bitirsene", "bitti", "bitsin", "bitmistir",
        "sonlandir", "sonlandirin", "sonlandiralim", "sonlandirmak", "sonlandirsak",
        "tamamla", "tamamlayin", "tamamlayalim", "tamamlamak", "tamamlandi", "tamamlansin",
        "sona", "erdi", "ersin", "erdirelim", "erdirin"
    ]
    /// Konu sözcüğü olmadan da tek başına komut olan bitirme sözcükleri ("bitir"); "tamamla" gibi başka işlerde de söylenenler değil
    static let bareEndVerbs: Set<String> = ["bitir", "bitirin", "bitirelim", "bitirsek", "sonlandir", "sonlandirin", "sonlandiralim"]
    /// Komutun anlamını değiştirmeyen dolgu sözcükler
    static let fillers: Set<String> = [
        "lutfen", "artik", "simdi", "istiyorum", "isterim", "isteriz", "hadi", "bence", "yani", "evet", "tamam", "su", "bu",
        "et", "eder", "edin", "edelim", "mi", "mu", "misin", "musun", "misiniz", "musunuz", "bir"
    ]
    static let repeatVerbs: Set<String> = [
        "tekrar", "tekrarla", "tekrarlayin", "tekrarlar", "tekrarlasana", "tekrarlayalim", "tekrarlansin", "tekrarlamak",
        "oku", "okuyun", "okur", "okusana", "okuyalim", "okunsun", "okumak",
        "dinle", "dinleyelim", "dinlemek", "dinletin", "dinlet", "dinletir",
        "yeniden", "bastan", "yine", "daha", "sesli", "soyle", "soyler", "soylesene", "oynat", "oynatin", "oynatir"
    ]
    /// Çoğul: bütün cevaplar
    static let allMarkers: Set<String> = [
        "cevaplari", "cevaplar", "cevaplarimi", "cevaplarimizi", "cevaplarin", "tum", "tumu", "tumunu", "butun", "hepsi", "hepsini", "butunu"
    ]
    /// Tekil: son cevap
    static let lastMarkers: Set<String> = ["cevabi", "cevap", "cevabini", "cevabim", "son", "sonuncu", "sonuncuyu"]

    /// İptal fiilleri. "baştan" / "yeniden" tek başına iptal değildir: bir konu sözcüğü ve okuma fiiliyle ("soruyu baştan okuyacağım") sayılır
    static let cancelVerbs: Set<String> = [
        "iptal", "sil", "silin", "silelim", "silsene", "temizle", "temizleyin", "temizleyelim", "unut", "unutun",
        "vazgec", "vazgectim", "vazgecelim"
    ]
    /// Atlama fiilleri: "soruyu atla", "bu soruyu geç", "soruyu bırak". Anlamı iptalle aynıdır (yarım kalan soru bırakılır); söylenen cümle "atlandı" olur
    static let skipVerbs: Set<String> = ["atla", "atlayin", "atlayalim", "atlasana", "gec", "gecin", "gecelim", "birak", "birakin", "birakalim"]
    /// "Yeni soru": tek başına "soruyu atla" demekle aynıdır; "yeni" yalnız soru konusuyla ve okuma fiili olmadan sayılır ("yeni soruyu okuyacağım" komut değildir)
    static let freshWords: Set<String> = ["yeni"]
    static let restartWords: Set<String> = ["bastan", "yeniden"]
    static let restartVerbs: Set<String> = [
        "oku", "okuyacagim", "okuyayim", "okuyorum", "okuyalim", "basla", "baslayacagim", "baslayayim", "baslayalim", "alalim"
    ]
    static let questionSubjects: Set<String> = ["soru", "soruyu", "sorumu", "sorusunu"]
    static let passageSubjects: Set<String> = ["paragraf", "paragrafi", "paragrafimi", "paragrafin"]
    /// "Ortak paragrafı iptal et" gibi söyleyişlerdeki dolgu
    static let cancelFillers: Set<String> = ["ortak"]
    /// "5. sorunun cevabı" söyleyişindeki konu sözcükleri (numara dışında kalan sözcükler)
    static let numberedStops: Set<String> = ["soru", "sorunun", "sorusunun", "sorudaki", "numarali", "numarasi", "numara", "nolu", "no", "olan", "ait", "ki"]
    static let notNumbered: Set<String> = ["son", "sonuncu", "sonuncuyu"]

    /// "soruyu iptal et", "paragrafı sil", "ortak paragrafı iptal et", "soruyu baştan okuyacağım". Metin TAMAMEN komut olmalı ve tam olarak bir konu
    /// sözcüğü (soru ya da paragraf) içermeli: soru metnindeki "iptal et" gibi sözler komut sayılmaz.
    static func parseCancel(_ text: String) -> VoiceCommand? {
        let all = SpokenWords.of(text)
        guard all.count >= 2, all.count <= 6 else { return nil }
        var strong = false, skip = false, fresh = false, restart = false, restartVerb = false, question = false, passage = false
        for word in all {
            if SpokenWords.matches(word, fillers) || SpokenWords.matches(word, cancelFillers) { continue }
            if SpokenWords.matches(word, cancelVerbs) {
                strong = true
            } else if SpokenWords.matches(word, skipVerbs) {
                skip = true
            } else if SpokenWords.exactly(word, freshWords) {
                fresh = true
            } else if SpokenWords.matches(word, restartWords) {
                restart = true
            } else if SpokenWords.matches(word, restartVerbs) {
                restartVerb = true
            } else if SpokenWords.matches(word, passageSubjects) || SpokenWords.startsLike(word, "paragraf") {
                passage = true
            } else if SpokenWords.matches(word, questionSubjects) {
                question = true
            } else {
                return nil   // tanınmayan sözcük: komut değil, soru ya da paragraf metni olabilir
            }
        }
        guard passage != question else { return nil }
        let cancelling = strong || (restart && restartVerb)
        if passage {
            // "paragrafı atla" iptal gibidir; "yeni paragraf" komut değildir
            if cancelling || skip { return VoiceCommand.cancelPassage }
            return nil
        }
        if cancelling { return VoiceCommand.cancelQuestion }
        if fresh && restartVerb { return nil }   // "yeni soruyu okuyacağım": komut değil
        if skip || fresh { return VoiceCommand.skipQuestion }
        return nil
    }

    /// "Son soruyu sil", "son cevabı sil", "son sorunun kaydını sil", "en son soruyu iptal et": en son kaydedilen soru silinsin isteniyor.
    /// "Son" sözcüğü ve silme fiili ile soru/cevap/kayıt sözcüğü birlikte gerekir; metin TAMAMEN komut olmalı. "Soruyu sil" (son yok) okunan soruyu iptal eder.
    static let deleteVerbs: Set<String> = ["sil", "silin", "silelim", "silsene", "iptal", "kaldir", "kaldirin", "kaldiralim", "temizle", "temizleyin"]
    static let recordNouns: Set<String> = [
        "soru", "soruyu", "sorunun", "sorusunu", "sorumu", "cevap", "cevabi", "cevabini", "cevabimi", "kayit", "kaydi", "kaydini", "kaydimi"
    ]
    static let deleteFillers: Set<String> = ["en", "kaydedilen", "kaydettigim", "cevapladigim"]

    static func parseDeleteLastQuestion(_ all: [String]) -> VoiceCommand? {
        guard all.count >= 3, all.count <= 7 else { return nil }
        var verb = false, last = false, noun = false
        for word in all {
            if SpokenWords.matches(word, fillers) || SpokenWords.matches(word, deleteFillers) { continue }
            if SpokenWords.matches(word, deleteVerbs) || SpokenWords.startsLike(word, "iptal") {
                verb = true
            } else if SpokenWords.matches(word, lastPart) {
                last = true
            } else if SpokenWords.matches(word, recordNouns) {
                noun = true
            } else {
                return nil   // tanınmayan sözcük: komut değil, soru metni olabilir
            }
        }
        if verb && last && noun { return VoiceCommand.deleteLastQuestion }
        return nil
    }

    /// "Kayıt sil", "soru kaydını sil", "belirli bir soruyu sil", "başka bir soruyu sil", "numaralı soruyu sil": son soru değil, kullanıcının seçeceği soru silinecek.
    /// Metin TAMAMEN komut olmalı; "son" sözcüğü varsa `parseDeleteLastQuestion` işi görür; yalnız "soruyu sil" okunan soruyu iptal eder (`parseCancel`).
    static let chosenMarkers: Set<String> = ["belirli", "belirtilen", "belli", "istedigim", "istedigimiz", "baska", "diger", "herhangi", "secilen", "numarali", "numara", "numarasi", "numarasini", "bir", "hangi"]
    static let recordWords: Set<String> = ["kayit", "kaydi", "kaydini", "kayitli", "kayitlari", "kaydimi"]

    static func parseDeleteChosen(_ all: [String]) -> VoiceCommand? {
        guard all.count >= 2, all.count <= 8 else { return nil }
        var verb = false, marker = false, record = false, noun = false
        for word in all {
            if SpokenWords.matches(word, fillers) || SpokenWords.matches(word, deleteFillers) { continue }
            if SpokenWords.matches(word, deleteVerbs) || SpokenWords.startsLike(word, "iptal") {
                verb = true
            } else if SpokenWords.matches(word, recordWords) {
                record = true
            } else if SpokenWords.matches(word, chosenMarkers) {
                marker = true
            } else if SpokenWords.matches(word, recordNouns) {
                noun = true
            } else {
                return nil   // tanınmayan sözcük (örneğin "son"): komut değil, soru metni olabilir ya da başka komuttur
            }
        }
        guard verb else { return nil }
        if record || (marker && noun) { return VoiceCommand.deleteChosenQuestion }
        return nil
    }

    /// "Soru numarası düzelt", "numara düzeltme", "numarayı değiştir", "soru numarasını güncelle": kayıtlı bir sorunun numarası değiştirilecek
    static let renumberVerbs: Set<String> = [
        "duzelt", "duzeltin", "duzeltelim", "duzeltme", "duzeltmek", "duzeltmeyi", "duzeltsene", "duzeltecegim",
        "degistir", "degistirin", "degistirelim", "degistirme", "degistirmek", "degistirmeyi", "degistirsene", "degistirecegim",
        "guncelle", "guncelleme", "guncelleyin"
    ]
    static let numberNouns: Set<String> = ["numara", "numarasi", "numarasini", "numarayi", "numarani", "numaralari", "no", "nosu", "nosunu"]

    static func parseRenumber(_ all: [String]) -> VoiceCommand? {
        guard all.count >= 2, all.count <= 7 else { return nil }
        var verb = false, number = false
        for word in all {
            if SpokenWords.matches(word, fillers) { continue }
            if SpokenWords.matches(word, renumberVerbs) {
                verb = true
            } else if SpokenWords.matches(word, numberNouns) {
                number = true
            } else if SpokenWords.matches(word, recordNouns) {
                continue
            } else {
                return nil   // tanınmayan sözcük: komut değil, soru metni olabilir
            }
        }
        return verb && number ? VoiceCommand.renumberQuestion : nil
    }

    /// "5. sorunun cevabını tekrarla", "beşinci sorunun cevabını oku", "soru yedinin cevabını söyle": tek bir sorunun cevabı. Numara bulunamazsa nil
    /// ("son cevabı tekrarla" ve "cevapları tekrarla" bu komut değildir).
    static func parseNumbered(_ text: String) -> VoiceCommand? {
        let originals = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard originals.count >= 2, originals.count <= 8 else { return nil }
        var rest: [String] = []
        var hasAnswer = false, hasRepeat = false, sawBir = false
        for original in originals {
            let word = SpokenWords.fold(original)
            if word.isEmpty || word == "lutfen" { continue }
            if word == "bir" { sawBir = true; continue }
            if SpokenWords.matches(word, fillers) { continue }
            if SpokenWords.matches(word, allMarkers) || SpokenWords.matches(word, notNumbered) { return nil }
            if SpokenWords.matches(word, lastMarkers) { hasAnswer = true; continue }
            if SpokenWords.matches(word, repeatVerbs) || SpokenWords.startsLike(word, "tekrar") { hasRepeat = true; continue }
            if SpokenWords.matches(word, numberedStops) { continue }
            rest.append(original)
        }
        if rest.isEmpty && sawBir { rest = ["bir"] }   // "bir numaralı sorunun cevabını oku": "bir" burada sayıdır
        guard hasAnswer, hasRepeat, !rest.isEmpty, let number = SpokenNumber.standalone(from: rest.joined(separator: " ")) else { return nil }
        return .repeatNumber(number)
    }

    // MARK: "Anlamadım / bir daha söyle": programın son sözünü yeniden söylemesi

    /// Duyulmadı / anlaşılmadı sözleri: tek başına yeter ("anlamadım", "duyamadım", "duymadım", "anlaşılmadı", "efendim", "pardon")
    static let misunderstood: Set<String> = [
        "anlamadim", "anlayamadim", "anlamadik", "anlayamadik", "anlasilmadi", "anlasilmiyor", "anlamiyorum", "anlayamiyorum", "anlamiyoruz", "anlayamiyoruz",
        "duyamadim", "duymadim", "duyamadik", "duymadik", "duyulmadi", "duyulmuyor", "duyamiyorum", "duymuyorum", "duyamiyoruz", "duymuyoruz",
        "isitemedim", "isitmedim", "isitemiyorum", "isitmiyorum", "neydi", "efendim", "pardon"
    ]
    /// "Ne dedin?": "ne" ile birlikte
    static let whatDidYouSay: Set<String> = ["dedin", "dediniz", "diyorsun", "diyorsunuz", "demistin", "demistiniz", "demissin", "demissiniz", "dedi"]
    /// "Tekrar / yeniden / bir daha / yine" + söyleme fiili: "tekrar söyle", "bir daha söyler misin", "yeniden anlatır mısınız"
    static let againWords: Set<String> = ["tekrar", "yeniden", "daha", "yine", "tekrardan"]
    static let sayWords: Set<String> = [
        "soyle", "soyler", "soyleyin", "soyleyebilir", "soyleyebilirsin", "soyleyebilirsiniz", "soylermisin", "soylermisiniz", "soylesene", "soylesenize", "soyleyiver",
        "anlat", "anlatir", "anlatin", "anlatsana", "anlatabilir", "anlatabilirsin", "anlatabilirsiniz", "edebilir", "edebilirsin", "edebilirsiniz"
    ]
    /// "Bir daha oku", "yeniden oku": "tekrar oku" bu kümeye girmez (V3'te son cevabı okutur)
    static let readAgainWords: Set<String> = [
        "oku", "okur", "okuyun", "okusana", "okusanize", "okuyabilir", "okuyabilirsin", "okuyabilirsiniz", "okurmusun", "okurmusunuz"
    ]
    /// Nezaket ve dolgu sözcükleri
    static let politeWords: Set<String> = [
        "lutfen", "misin", "misiniz", "mi", "mu", "musun", "musunuz", "bir", "kez", "kere", "defa", "biraz", "hadi", "ya", "rica", "ederim", "bana", "sunu", "bunu", "onu"
    ]

    /// Metnin TAMAMI programdan son sözünü yeniden söylemesini istiyor mu. Bütün sözcükler bu sözlüklerden olmalıdır: soru metni komut sayılmaz.
    /// "Tekrar", "tekrarla", "tekrar et" gibi tek başına söylenenler burada değildir (V3: son cevabı tekrarlar; menüde ve onayda programın sözünü tekrarlar).
    static func isRepeatSpeech(_ words: [String]) -> Bool {
        guard !words.isEmpty, words.count <= 7 else { return false }
        var understood = false, ne = false, what = false, again = false, againWithoutTekrar = false, say = false, read = false
        for word in words {
            if SpokenWords.matches(word, misunderstood) {
                understood = true
            } else if word == "ne" {
                ne = true
            } else if SpokenWords.matches(word, whatDidYouSay) {
                what = true
            } else if SpokenWords.matches(word, sayWords) {
                say = true
            } else if SpokenWords.matches(word, readAgainWords) {
                read = true
            } else if SpokenWords.matches(word, againWords) {
                again = true
                if !SpokenWords.exactly(word, ["tekrar"]) { againWithoutTekrar = true }
            } else if !SpokenWords.matches(word, politeWords) {
                return false   // tanınmayan sözcük: komut değil, soru ya da paragraf metni olabilir
            }
        }
        if understood || (ne && what) { return true }
        if again && say { return true }
        // Tek başına "bir daha" burada değildir: soru ya da paragraf cümlesinin başı olabilir ("Bir kez daha…")
        return againWithoutTekrar && read
    }

    // MARK: Bilgi ve düzeltme komutları ("yardım", "ne duydun", "son cümleyi sil", "durum", "cevapsız soruları söyle")

    /// Bu komutların hepsinde serbestçe geçebilen nezaket ve dolgu sözcükleri
    static let infoPolite: Set<String> = [
        "lutfen", "bana", "bir", "misin", "misiniz", "mi", "mu", "ya", "hadi", "simdi", "su", "bu", "et", "edin", "eder", "ver", "verin"
    ]
    static let helpWords: Set<String> = ["yardim", "yardima"]
    static let commandNouns: Set<String> = ["komut", "komutlar", "komutlari", "komutlarin"]
    static let infoAsk: Set<String> = ["ne", "neler", "nedir", "nelerdir", "hangi", "hangileri", "var"]
    static let infoSay: Set<String> = [
        "say", "sayin", "sayar", "sayabilir", "soyle", "soyler", "soyleyin", "soyleyebilir", "oku", "okur", "okuyun", "okuyabilir",
        "anlat", "anlatir", "anlatin", "anlatabilir"
    ]
    static let canSayWords: Set<String> = ["diyebilirim", "soyleyebilirim", "diyebiliriz", "soyleyebiliriz"]
    /// "Şu ana kadar", "şimdiye kadar"
    static let sofarWords: Set<String> = ["ana", "kadar", "simdiye", "simdilik", "toplam"]
    static let heardVerbs: Set<String> = ["duydun", "duydunuz", "anladin", "anladiniz"]
    static let heardNouns: Set<String> = ["duydugunu", "duydugunuzu", "anladigini", "anladiginizi"]
    static let lastPart: Set<String> = ["son", "sonuncu", "sonuncuyu"]
    static let partNouns: Set<String> = [
        "cumleyi", "cumle", "cumlemi", "sozu", "soz", "sozumu", "kismi", "kismini", "satiri", "soyledigimi", "soyledigim", "dedigimi"
    ]
    static let justNow: Set<String> = ["az", "once"]
    static let statusWords: Set<String> = ["durum", "durumu", "neredeyiz", "neredeyim"]
    static let statusExtras: Set<String> = [
        "ne", "nedir", "nasil", "bilgi", "bilgisi", "rapor", "raporu", "raporunu", "genel", "sistem", "sistemin",
        "soyle", "soyler", "soyleyin", "oku", "okur", "okuyun", "anlat", "anlatin", "bildir", "bildirin"
    ]
    static let countAsk: Set<String> = ["kac", "kacinci"]
    static let countNouns: Set<String> = [
        "soru", "sorusu", "cevap", "cevaplandi", "cevaplanan", "cevaplanmis", "kaydedildi", "kaydedilen", "cozuldu", "cozduk", "cozdum",
        "gonderildi", "gonderdik", "yaptik", "yaptim", "var", "oldu"
    ]
    static let missingQualifiers: Set<String> = [
        "cevapsiz", "eksik", "atlanan", "atladigim", "atladim", "atlanmis", "cevaplanmayan", "cevaplanmamis", "cevaplanmadi", "olmayan", "verilmeyen"
    ]
    static let missingNouns: Set<String> = [
        "soru", "soruyu", "sorular", "sorulari", "cevap", "cevabi", "cevaplar", "cevaplari", "numara", "numaralar", "numaralari"
    ]
    static let missingExtras: Set<String> = [
        "hangi", "hangileri", "hangisi", "var", "kac", "ne", "neler", "nelerdir", "nedir", "oldu",
        "soyle", "soyler", "soyleyin", "oku", "okur", "okuyun", "say", "sayin", "anlat", "anlatin"
    ]

    private static func allKnown(_ words: [String], _ vocabularies: [Set<String>]) -> Bool {
        return words.allSatisfy { word in vocabularies.contains { SpokenWords.matches(word, $0) } }
    }

    private static func has(_ words: [String], _ vocabulary: Set<String>) -> Bool {
        return words.contains { SpokenWords.matches($0, vocabulary) }
    }

    /// "Yardım", "komutlar neler", "ne duydun", "duyduğunu oku", "son cümleyi sil", "durum", "kaç soru cevaplandı", "cevapsız soruları söyle".
    /// Metnin TAMAMI bu sözcüklerden oluşmalıdır (soru metni komut sayılmaz). Olumsuz biçimler `parse` başında elenir.
    static func parseInfo(_ all: [String]) -> VoiceCommand? {
        guard !all.isEmpty, all.count <= 7 else { return nil }
        let words = all.filter { !SpokenWords.matches($0, infoPolite) }
        guard !words.isEmpty else { return nil }
        let ne = words.contains("ne")
        if allKnown(words, [helpWords, commandNouns, infoAsk, infoSay, canSayWords]) {
            if has(words, helpWords) { return .help }
            if has(words, commandNouns), has(words, infoAsk) || has(words, infoSay) { return .help }
            if has(words, canSayWords), has(words, infoAsk) { return .help }
        }
        if allKnown(words, [heardVerbs, heardNouns, infoSay, sofarWords, ["ne"]]) {
            if ne, has(words, heardVerbs) { return .whatHeard }
            if has(words, heardNouns), has(words, infoSay) { return .whatHeard }
        }
        if allKnown(words, [lastPart, partNouns, justNow, cancelVerbs]) {
            let recent = words.contains("az") && words.contains("once")
            if has(words, cancelVerbs), has(words, partNouns), has(words, lastPart) || recent { return .deleteLast }
        }
        if allKnown(words, [statusWords, statusExtras]), has(words, statusWords) { return .status }
        if allKnown(words, [countAsk, countNouns, sofarWords]), has(words, countAsk), has(words, countNouns) { return .status }
        if allKnown(words, [missingQualifiers, missingNouns, missingExtras]), has(words, missingQualifiers), has(words, missingNouns) {
            return .missingAnswers
        }
        return nil
    }

    /// Komutu OLUMSUZLAYAN söz var mı ("testi bitirme", "cevapları tekrarlama", "sınavı bitirmem"): yakın sesli eşleşme ("bitirme" ≈ "bitirmek")
    /// bunları komut sayardı. Olumsuz söz komut değildir; metin olduğu gibi soru/paragraf metni olarak kalır.
    private static func isNegated(_ words: [String]) -> Bool {
        return words.contains { SpokenWords.exactly($0, SpokenReply.finishNegations) || SpokenWords.exactly($0, SpokenReply.choiceNegations) }
    }

    static func parse(_ text: String) -> VoiceCommand? {
        let all = SpokenWords.of(text)
        if let askOff = parseCameraAskOff(all) { return askOff }   // "kamera sorusu olmasın" (olumsuzlamadan önce: "olmasın" olumsuz söz sayılır)
        if isNegated(all) { return nil }
        if let cancel = parseCancel(text) { return cancel }
        if let delete = parseDeleteLastQuestion(all) { return delete }
        if let chosen = parseDeleteChosen(all) { return chosen }
        if let renumber = parseRenumber(all) { return renumber }
        if let numbered = parseNumbered(text) { return numbered }
        if isRepeatSpeech(all) { return .repeatSpeech }
        if let info = parseInfo(all) { return info }
        if let setting = parseSetting(all) { return setting }
        guard !all.isEmpty, all.count <= 7 else { return nil }
        let words = all.filter { !SpokenWords.matches($0, fillers) }
        guard !words.isEmpty else { return nil }
        var hasSubject = false, hasEnd = false, hasBareEnd = false, hasRepeat = false, hasTekrar = false, hasAll = false, hasLast = false
        var hasSection = false
        for word in words {
            if SpokenWords.exactly(word, sectionSubjects) {
                hasSection = true
            } else if SpokenWords.matches(word, subjects) {
                hasSubject = true
            } else if SpokenWords.matches(word, endVerbs) {
                hasEnd = true
                if SpokenWords.matches(word, bareEndVerbs) { hasBareEnd = true }
            } else if SpokenWords.matches(word, allMarkers) {
                hasAll = true
            } else if SpokenWords.matches(word, lastMarkers) {
                hasLast = true
            } else if SpokenWords.matches(word, repeatVerbs) || SpokenWords.startsLike(word, "tekrar") {
                hasRepeat = true
                if SpokenWords.startsLike(word, "tekrar") { hasTekrar = true }
            } else {
                return nil   // tanınmayan sözcük: komut değil, soru metni olabilir
            }
        }
        if hasSection {
            // "Bölümü tamamla": konu yalnız bölüm olmalı ("testi bölümü bitir" ya da tekrar fiili içeren söz komut değildir)
            guard hasEnd, !hasSubject, !hasRepeat, !hasAll, !hasLast else { return nil }
            return .endSection
        }
        if hasRepeat || hasAll || hasLast {
            if hasEnd || hasSubject || (hasAll && hasLast) { return nil }
            if hasAll { return hasRepeat ? .replayAnswers : nil }
            if hasLast { return hasRepeat ? .repeatLast : nil }
            return hasTekrar ? .repeatLast : nil   // yalnız "tekrarla"
        }
        guard hasEnd, hasSubject || hasBareEnd else { return nil }
        return .endTest
    }

    /// Tanıyıcı komutu bölmüş olabilir ("tekrar la", "testi bit ir"): önce olduğu gibi, olmazsa üç harfe kadar kısa parçalar öncekine
    /// eklenerek denenir
    static func parseLenient(_ text: String) -> VoiceCommand? {
        if let command = parse(text) { return command }
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard tokens.count >= 2 else { return nil }
        for index in 1..<tokens.count where SpokenWords.fold(tokens[index]).count <= 3 {
            var merged = tokens
            merged[index - 1] += merged[index]
            merged.remove(at: index)
            if let command = parse(merged.joined(separator: " ")) { return command }
        }
        return nil
    }
}

/// Komut denemesi: tanıyıcı komut sözcüklerini yazmış ama söz komut kuralına uymamış ("testi bit", "cevapları tekrar çok"). Böyle bir söz soru
/// metni sayılıp sessizce biriktirilmez; program "anlayamadım" der ve tekrar ister. Yanlış alarm olmasın diye KATI davranılır: bütün sözcükler
/// komut sözcüğü olmalı ve en az biri fiil/işaret sözcüğü olmalı (yalnız "test", "sınav" gibi konu sözcükleri soru başlangıcı olabilir).
enum CommandAttempt {
    /// Fiil ve işaret sözcüklerinin gövdeleri; sözcük gövdenin kısa ön eki de olabilir (en az `minPrefix` harf: "bit" → "bitir")
    private static let cores: [(stem: String, minPrefix: Int)] = [
        ("tekrar", 4), ("bitir", 3), ("sonlandir", 4), ("tamamla", 6), ("cevap", 4), ("cevaplari", 4), ("cevabi", 4)
    ]
    static let maxWords = 6

    static func isCore(_ word: String) -> Bool {
        let heard = SpokenWords.key(word)
        for core in cores {
            let stem = SpokenWords.key(core.stem)
            if heard.count >= core.minPrefix, stem.hasPrefix(heard) { return true }
            if SpokenWords.startsLike(word, core.stem) { return true }
        }
        return SpokenWords.matches(word, VoiceCommand.endVerbs) || SpokenWords.matches(word, VoiceCommand.allMarkers)
            || SpokenWords.matches(word, VoiceCommand.lastMarkers)
    }

    static func isCommandish(_ word: String) -> Bool {
        return isCore(word) || SpokenWords.matches(word, VoiceCommand.subjects) || SpokenWords.exactly(word, VoiceCommand.sectionSubjects)
            || SpokenWords.matches(word, VoiceCommand.fillers)
            || SpokenWords.matches(word, VoiceCommand.repeatVerbs) || SpokenWords.startsLike(word, "tekrar")
            || SpokenWords.startsLike(word, "test") || SpokenWords.startsLike(word, "sinav")
    }

    static func looksLike(_ text: String) -> Bool {
        let words = SpokenWords.of(text)
        guard !words.isEmpty, words.count <= maxWords else { return false }
        if looksLikeCancel(words) { return true }
        guard words.allSatisfy(isCommandish) else { return false }
        return words.contains(where: isCore)
    }

    /// Bozuk iptal denemesi ("soruyu iptalet", birleşik yazılan ya da sonuna ek eklenen komut): yalnız iptal fiili (ya da yakın sesi) + soru/paragraf konu sözcüğü + dolgu.
    /// Fiil ya da konu sözcüğü tek başına yetmez ("iptal et", "soruyu"): soru metni olabilir.
    private static func looksLikeCancel(_ words: [String]) -> Bool {
        var verb = false, subject = false
        for word in words {
            if SpokenWords.matches(word, VoiceCommand.fillers) || SpokenWords.matches(word, VoiceCommand.cancelFillers) { continue }
            if SpokenWords.matches(word, VoiceCommand.cancelVerbs) || SpokenWords.matches(word, VoiceCommand.skipVerbs) || SpokenWords.startsLike(word, "iptal") {
                verb = true
            } else if SpokenWords.matches(word, VoiceCommand.questionSubjects) || SpokenWords.matches(word, VoiceCommand.passageSubjects)
                        || SpokenWords.startsLike(word, "paragraf") {
                subject = true
            } else {
                return false
            }
        }
        return verb && subject
    }
}

/// Programın sorduğu kısa sorulara verilen sözlü cevaplar. Yalnız kısa cevaplar tanınır (en çok 8 sözcük); anahtar sözcüğe bakılır, böylece
/// "önceki kayıttan sorulara devam edelim" gibi doğal söyleyişler de anlaşılır. Hem evet hem hayır gibi çelişen söz nil verir.
enum SpokenReply {
    enum YesNo: Equatable { case yes, no }
    enum Start: Equatable { case continuePrevious, startNew }
    /// Cevaplar okunduktan sonra: teste devam, cevapları yeniden oku, testi tamamla
    enum Review: Equatable { case continueTest, repeatAnswers, finishTest }
    /// Kamerayla çekilecek şey: tek bir soru mu, birkaç soruya ortak paragraf mı
    enum CaptureKind: Equatable { case question, passage }
    /// Bölüm bitince: yeni bölümle devam, ya da testi tamamla
    enum NextSection: Equatable { case newSection, finishTest }

    static let yes: Set<String> = ["evet", "tamam", "bitir", "bitirin", "bitirelim", "onayliyorum", "onay", "olur", "aynen", "kesinlikle", "tabii", "tabi", "tabiki", "dogru"]
    static let no: Set<String> = ["hayir", "vazgec", "vazgectim", "vazgecelim", "devam", "iptal", "bitirme", "bitirmeyin", "olmaz", "istemiyorum", "yok", "dur", "degil",
                                  "bitirmem", "bitirmiyorum", "bitirmiyoruz", "bitirmeyelim", "bitirmesek", "bitirmeyiz", "bitmesin",
                                  "sonlandirma", "sonlandirmayin", "sonlandirmiyorum"]
    /// Bitirme sorusunda ("Testi bitirmek istiyor musunuz?") tek başına evet sayılan mastar biçimleri: "bitirmek istiyorum"
    static let confirmWeakYes: Set<String> = ["bitirmek", "bitirmeyi", "sonlandirmak", "sonlandirmayi", "tamamlamak", "tamamlamayi"]
    /// "Bitir" sözcüğünün olumsuz biçimleri: menüde ve onayda bitirme isteği değil, vazgeçmektir ("bitirme, devam")
    static let finishNegations: Set<String> = ["bitirme", "bitirmeyin", "bitirmeyelim", "bitirmem", "bitirmiyorum", "bitirmiyoruz", "bitirmesek", "bitirmeyiz",
                                              "bitmesin", "sonlandirma", "sonlandirmayin", "sonlandirmiyorum", "tamamlama", "tamamlamayin", "kapatma", "kapatmayin"]
    /// Kamera sorusu ("kamera ile çekip göndermek ister misiniz?"): "bitir" ve "devam" burada evet / hayır değildir; "testi bitir" bir
    /// komuttur ve kamerayı başlatmamalı
    static let cameraYes: Set<String> = ["evet", "tamam", "olur", "aynen", "kesinlikle", "tabii", "tabi", "tabiki", "dogru", "istiyorum", "isterim", "istiyoruz", "isteriz",
                                         "cek", "cekelim", "cekin", "cekeyim", "cekecegim", "cekiyorum", "cekerim", "cekeriz", "cekiyoruz"]
    /// Zayıf evet: "kamerayla", "fotoğraf" (soruyu yineleyen kısa cevap). Tek başına evet sayılır; herhangi bir hayır sözüyle birlikte
    /// ("kamera istemiyorum", "kamera değil sesle", "kamera olmasın") hayırdır.
    static let cameraWeakYes: Set<String> = ["kamera", "kamerayla", "kameradan", "kameraya", "kamerayi", "kamerada", "fotograf", "fotografla", "fotografi", "foto",
                                             "kullan", "kullanalim", "kullanin", "kullanayim", "kullaniyorum"]
    static let cameraNo: Set<String> = ["hayir", "olmaz", "olmasin", "istemiyorum", "istemiyoruz", "istemem", "istemeyiz", "yok", "degil", "vazgec", "vazgectim",
                                        "iptal", "sesle", "sesli", "okurum", "ses", "okuyayim", "okuyorum", "okuyacagim", "okuyalim", "gerekmez", "gerekmiyor",
                                        "cekme", "cekmem", "cekmeyin", "cekmeyelim", "cekmeyeyim", "cekmiyorum", "cekmiyoruz", "cekmeyecegim", "cekmesin", "cekmesek",
                                        "cekmeyiz", "kullanma", "kullanmayin", "kullanmayalim", "kullanmam", "kullanmiyorum", "kamerasiz"]
    /// "Çekmek", "çekmeyi" gibi mastar biçimleri hayır sözü ("çekme") gibi duyulabilir ama anlamı belirsizdir ("çekmek istiyorum" evettir): bulanık eşleşmeden çıkarılır
    static let cameraNeutral: Set<String> = ["cekmek", "cekmeyi", "cekmeye", "cekmesi", "cekip", "gondermek", "gondermeyi", "gonderip", "gonderelim"]
    /// "Devam / Tekrar / Bitir" menüsünde ve "önceki kayıt mı, yeni mi" sorusunda seçeneği OLUMSUZLAYAN sözler: "devam etmeyelim", "bitirmek
    /// istemiyorum", "yeni başlamayalım", "yeni değil". Seçenek sözcüğü ("devam", "bitirmek", "yeni") tek başına olumlu sayıldığı için
    /// bunlar yanlışlıkla seçilirdi (testi bitirmek istemeyen kişinin testi bitmesi gibi); olumsuzluk varsa cevap anlaşılmamış sayılır, yeniden sorulur.
    /// "Bitirme" biçimleri ayrıca `finishNegations` ile ele alınır ("bitirme, devam" → devam).
    static let choiceNegations: Set<String> = [
        "etme", "etmeyelim", "etmeyin", "etmem", "etmiyorum", "etmiyoruz", "etmesin", "etmeyiz", "etmesek",
        "istemiyorum", "istemiyoruz", "istemem", "istemeyiz", "degil", "olmasin", "olmaz", "gerekmez", "gerekmiyor",
        "baslama", "baslamayalim", "baslamayin", "baslamam", "baslamiyorum", "baslamiyoruz", "baslamasin",
        "okuma", "okumayin", "okumayalim", "okumam", "okumuyorum", "dinleme", "dinlemeyelim", "dinlemeyin", "dinlemem", "dinlemiyorum",
        "tekrarlama", "tekrarlamayin", "tekrarlamayalim", "tekrarlamam", "tekrarlamiyorum",
        "soyleme", "soylemeyin", "soylemeyelim", "soylemem", "soylemiyorum", "anlatma", "anlatmayin",
        "silme", "silmeyin", "silmeyelim", "silmem", "silmiyorum", "unutma", "temizleme"
    ]
    static let continueWords: Set<String> = ["devam", "onceki", "eski", "kaldigi", "kaldigim", "kaldigimiz", "aynen", "surdur", "surdurelim", "surdurun"]
    static let newWords: Set<String> = ["yeni", "sifirdan", "bastan", "temiz"]
    static let reviewFinish: Set<String> = [
        "bitir", "bitirin", "bitirelim", "bitirsek", "bitirmek", "bitsin", "sonlandir", "sonlandirin", "sonlandiralim", "sonlandirmak",
        "tamamla", "tamamlayin", "tamamlayalim", "tamamlamak", "tamamlansin", "kapat", "kapatalim", "cikis", "yeter"
    ]
    static let reviewContinue: Set<String> = [
        "devam", "surdur", "surdurelim", "surdurun", "kaldigim", "kaldigimiz", "kaldigi", "yerden", "ilerle", "ilerleyelim", "gecelim",
        "sonraki", "siradaki", "sorulara", "soruya"
    ]

    private static func words(_ text: String, max: Int) -> [String] {
        let all = SpokenWords.of(text)
        return all.count <= max ? all : []
    }

    /// Evet/hayır sorularında bir sözcüğün anlamı. Önce AYNEN eşleşme aranır; bulanık (tek harf farklı) eşleşme yalnız HAYIR yönünde sayılır:
    /// yanlış hayır zararsızdır (soru yeniden sorulur ya da sesle okuma sürer), yanlış evet ise işi başlatır (kamerayı açar, testi bitirir).
    private enum Word { case yes, weakYes, no, none }

    private static func classify(_ word: String, yes: Set<String>, weakYes: Set<String>, no: Set<String>, neutral: Set<String> = []) -> Word {
        if SpokenWords.exactly(word, no) { return .no }
        if SpokenWords.exactly(word, yes) { return .yes }
        if SpokenWords.exactly(word, weakYes) { return .weakYes }
        if SpokenWords.exactly(word, neutral) { return .none }
        return SpokenWords.matches(word, no) ? .no : .none
    }

    static func yesNo(_ text: String) -> YesNo? {
        let w = words(text, max: 8)
        guard !w.isEmpty else { return nil }
        let kinds = w.map { classify($0, yes: yes, weakYes: confirmWeakYes, no: no) }
        let hasNo = kinds.contains(.no)
        let hasYes = kinds.contains(.yes)
        let hasWeakYes = kinds.contains(.weakYes)
        if hasNo { return hasYes ? nil : .no }   // çelişen söz ("evet hayır"): anlaşılmamış sayılır; "bitirmek istemiyorum": hayır
        if hasYes || hasWeakYes { return .yes }
        // Onay sorusuna komutu yeniden söylemek ("testi bitir") de evet demektir
        if let command = VoiceCommand.parse(text), command.isEnding { return .yes }
        return nil
    }

    /// Kamera sorusuna cevap. Onay sorusundan ayrıdır: "testi bitir" evet sayılmaz (komuttur), çelişen söz nil verir.
    static func cameraChoice(_ text: String) -> YesNo? {
        let w = words(text, max: 8)
        guard !w.isEmpty else { return nil }
        // "Soruyu iptal et" / "paragrafı sil" bir komuttur; içindeki "iptal" kamera sorusuna hayır demek sayılmaz
        if VoiceCommand.parseCancel(text) != nil { return nil }
        let kinds = w.map { classify($0, yes: cameraYes, weakYes: cameraWeakYes, no: cameraNo, neutral: cameraNeutral) }
        let hasNo = kinds.contains(.no)
        let hasYes = kinds.contains(.yes)
        let hasWeakYes = kinds.contains(.weakYes)
        if hasNo { return hasYes ? nil : .no }   // "evet hayır": çelişki; "kamera istemiyorum": hayır
        if hasYes || hasWeakYes { return .yes }
        return nil
    }

    /// Birinci / ikinci seçenek sözleri ("bir", "birinci", "1" soru; "iki", "ikinci", "2" paragraf). Sayılar için yalnız AYNEN eşleşme kullanılır.
    static let kindFirst: Set<String> = ["bir", "1", "birinci", "birincisi", "birincisini", "ilk", "ilki", "ilkini"]
    static let kindSecond: Set<String> = ["iki", "2", "ikinci", "ikincisi", "ikincisini", "ikisi"]
    /// "Soru mu paragraf mı" diye soruyu yineleyen söz: seçim değildir
    static let kindEchoes: Set<String> = ["mu", "mi", "yoksa"]

    /// "Soru mu, ortak paragraf mı çekeceksiniz?" sorusuna cevap. "paragraf" (ya da "soru paragrafı", "ortak paragraf") ve "iki / ikinci / 2" paragraf;
    /// "soru" ve "bir / birinci / 1" soru. Çelişen ya da seçimi yineleyen söz ("soru mu paragraf mı", "bir iki") nil verir: yeniden sorulur.
    static func captureKind(_ text: String) -> CaptureKind? {
        let w = words(text, max: 8)
        guard !w.isEmpty else { return nil }
        // "Soruyu iptal et" / "paragrafı sil" bir komuttur; seçim değildir
        if VoiceCommand.parseCancel(text) != nil { return nil }
        let passageWord = w.contains { SpokenWords.startsLike($0, "paragraf") }
        let questionWord = w.contains { SpokenWords.startsLike($0, "soru") }
        let echo = w.contains { SpokenWords.exactly($0, kindEchoes) }
        if passageWord && questionWord { return echo ? nil : .passage }   // "soru paragrafı" = paragraf; "soru mu paragraf mı" = seçim değil
        if passageWord { return .passage }
        if questionWord { return .question }
        let first = w.contains { SpokenWords.exactly($0, kindFirst) }
        let second = w.contains { SpokenWords.exactly($0, kindSecond) }
        if first && second { return nil }
        if first { return .question }
        if second { return .passage }
        return nil
    }

    /// "Yeni bölüm" seçeneği: evet, yeni, devam, sonraki, geçelim, başlayalım… ("evet" tek başına yeter)
    static let sectionProceed: Set<String> = [
        "evet", "tamam", "olur", "tabii", "tabi", "tabiki", "aynen", "yeni", "devam", "sonraki", "siradaki", "gec", "gecelim", "basla", "baslayalim", "baslat"
    ]
    /// "Testi tamamla" seçeneği: hayır, tamamla, bitir… Yalnız AYNEN eşleşme sayılır: yanlış anlaşılan "testi tamamla" sınavı bitirirdi
    static let sectionFinish: Set<String> = [
        "hayir", "bitir", "bitirin", "bitirelim", "bitirsek", "bitirmek", "sonlandir", "sonlandirin", "sonlandiralim", "sonlandirmak",
        "tamamla", "tamamlayin", "tamamlayalim", "tamamlamak", "yeter", "kapat", "kapatalim"
    ]

    /// "Yeni bir bölüm ile devam etmek ister misiniz, yoksa testi tamamlayalım mı?" sorusuna cevap. "Evet" / "yeni bölüm" / "devam": yeni bölüm;
    /// "hayır" / "testi tamamla" / "bitir": test biter. İki seçenek de duyulursa ya da hiçbiri duyulmazsa nil (yeniden sorulur). Testi bitiren
    /// yönün yanlış anlaşılması sınavı erken kapatacağı için bulanık eşleşme kullanılmaz; "bitirme", "yeni bölüm istemiyorum" gibi olumsuz sözler ters çevirir.
    static func nextSection(_ text: String) -> NextSection? {
        let w = words(text, max: 8)
        guard !w.isEmpty else { return nil }
        // "Testi bitir" komutunu söylemek de testi tamamlamaktır
        let command = VoiceCommand.parse(text)
        if command == .endTest { return .finishTest }
        if command == .endSection { return nil }   // bölüm zaten tamamlandı: "bölümü tamamla" testi bitirmek sayılmaz, yeniden sorulur
        if w.contains(where: { SpokenWords.exactly($0, finishNegations) }) { return .newSection }   // "bitirme", "tamamlama": test bitmesin
        let finish = w.contains { SpokenWords.exactly($0, sectionFinish) }
        let proceed = w.contains { SpokenWords.exactly($0, sectionProceed) }
        let negated = w.contains { SpokenWords.exactly($0, choiceNegations) }
        if negated {
            // "yeni bölüm istemiyorum" → test biter; "testi tamamlamak istemiyorum" → yeni bölüm; ikisi birden → anlaşılmadı
            if proceed && !finish { return .finishTest }
            if finish && !proceed { return .newSection }
            return nil
        }
        guard finish != proceed else { return nil }
        return finish ? .finishTest : .newSection
    }

    /// Söz, seçeneklerden birini olumsuzluyor mu ("devam etmeyelim")
    private static func negatesChoice(_ words: [String]) -> Bool {
        return words.contains { SpokenWords.exactly($0, choiceNegations) }
    }

    static func start(_ text: String) -> Start? {
        let w = words(text, max: 8)
        guard !w.isEmpty, !negatesChoice(w) else { return nil }
        let cont = w.contains(where: { SpokenWords.matches($0, continueWords) })
        let new = w.contains(where: { SpokenWords.matches($0, newWords) })
        if cont && !new { return .continuePrevious }
        if new && !cont { return .startNew }
        return nil
    }

    /// "Devam, Tekrar ya da Bitir" sorusuna cevap. Üç seçenekten tam biri anlaşılmalı; hiçbiri ya da çelişen ikisi nil verir ("tamam" gibi
    /// hangisi olduğu belli olmayan söz de nil: yeniden sorulur).
    static func review(_ text: String) -> Review? {
        let w = words(text, max: 8)
        guard !w.isEmpty, !negatesChoice(w) else { return nil }
        let finish = w.contains(where: { !SpokenWords.exactly($0, finishNegations) && SpokenWords.matches($0, reviewFinish) })
        let again = w.contains(where: { SpokenWords.matches($0, VoiceCommand.repeatVerbs) || SpokenWords.startsLike($0, "tekrar") })
        let proceed = w.contains(where: { SpokenWords.matches($0, reviewContinue) })
        guard [finish, again, proceed].filter({ $0 }).count == 1 else { return nil }
        if finish { return .finishTest }
        return again ? .repeatAnswers : .continueTest
    }
}

/// Sıra sayıları: "üçüncü soruda" (anons için; rakam okunuşuna bırakılmaz)
enum TurkishOrdinal {
    private static let tens = ["", "on", "yirmi", "otuz", "kırk", "elli", "altmış", "yetmiş", "seksen", "doksan"]
    private static let tenOrdinals = ["", "onuncu", "yirminci", "otuzuncu", "kırkıncı", "ellinci", "altmışıncı", "yetmişinci", "sekseninci", "doksanıncı"]
    private static let unitOrdinals = ["", "birinci", "ikinci", "üçüncü", "dördüncü", "beşinci", "altıncı", "yedinci", "sekizinci", "dokuzuncu"]

    /// 1...199 için sıra sayısı sözcüğü; dışındakiler için nil
    static func word(_ n: Int) -> String? {
        switch n {
        case 1...9: return unitOrdinals[n]
        case 10...99: return n % 10 == 0 ? tenOrdinals[n / 10] : tens[n / 10] + " " + unitOrdinals[n % 10]
        case 100: return "yüzüncü"
        case 101...199: return "yüz " + (word(n - 100) ?? "")
        default: return nil
        }
    }

    /// "üçüncü soruda" ("250 numaralı soruda": sıra sayısı sözcüğü olmayanlar için)
    static func inQuestion(_ n: Int) -> String {
        if let w = word(n) { return "\(w) soruda" }
        return "\(n) numaralı soruda"
    }
}

/// Okunan metnin son cümlesi: kesinti sonrası "en son şu cümleyi okudunuz" anonsu için
enum LastSentence {
    static let maxWords = 14
    private static let terminators: Set<Character> = [".", "?", "!", "…"]

    static func of(_ text: String) -> String {
        let trimmed = text.trimmed
        let body = String(trimmed.reversed().drop(while: { terminators.contains($0) || $0.isWhitespace }).reversed())
        guard !body.isEmpty else { return "" }
        let chars = Array(body)
        var start = 0
        var index = chars.count - 2
        while index >= 0 {
            // Cümle sonu: noktalama ve ardından boşluk ("3.5" gibi sayılar bölünmez)
            if terminators.contains(chars[index]), chars[index + 1].isWhitespace {
                start = index + 1
                break
            }
            index -= 1
        }
        var words = String(chars[start...]).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if words.count < 3, start > 0 {
            // Çok kısa bir son cümle ("Evet."): öncesinden de al
            words = body.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        }
        if words.count > maxWords { words = Array(words.suffix(maxWords)) }
        return words.joined(separator: " ")
    }
}

/// Gemini'ye gidecek soru metnini kurar: numara başa yazılır, ortak paragraf varsa soruyla birlikte gider
enum QuestionComposer {
    /// [5, 6, 7] → "5, 6 ve 7"
    static func listText(_ numbers: [Int]) -> String {
        let items = numbers.map { String($0) }
        guard let last = items.last else { return "" }
        if items.count == 1 { return last }
        return items.dropLast().joined(separator: ", ") + " ve " + last
    }

    /// Numara okunmamışsa (sonradan sorulup öğrenildiyse) soru metninin başına yazılır
    static func numbered(_ question: String, number: Int) -> String {
        return "Soru \(number). " + question
    }

    static func withPassage(question: String, passage: PassageContext, audioCombined: Bool) -> String {
        var text = "Ortak paragraf (\(listText(passage.all)) numaralı sorular için ortaktır; soruyu bu paragrafa göre çöz):\n\(passage.text)"
        if audioCombined { text += "\n\n(Ses kaydında önce ortak paragraf, ardından soru okunuyor.)" }
        if audioCombined && passage.audioTruncated {
            text += "\n(Paragraf çok uzun okunduğu için ses kaydında paragrafın ilk bölümü yok; paragrafın tamamı yukarıdaki dikte metnindedir, eksik bölüm için onu esas al.)"
        }
        return text + "\n\nŞimdi sorulan soru:\n\(question)"
    }

    /// Sesle okunan soru + KAMERAYLA çekilmiş paragraf: paragrafın görüntüleri mesaja eklenir, metin yerine bu cümle yazılır
    static func withCameraPassage(question: String, passage: PassageContext) -> String {
        return "Ortak paragraf (\(listText(passage.all)) numaralı sorular için ortaktır; soruyu bu paragrafa göre çöz):\n"
            + "(Paragraf yazı olarak değil, bu mesaja eklenen fotoğraf ve varsa videoda görüntü olarak veriliyor; paragrafı oradan oku.)"
            + "\n\nŞimdi sorulan soru:\n\(question)"
    }

    /// Kamera ile çekilen soru için: numara görüntüden okunacağından paragraf, hangi numaralara ait olduğuyla birlikte eklenir
    static func cameraNote(passage: PassageContext) -> String {
        if passage.viaCamera {
            guard !passage.remaining.isEmpty else { return "" }
            return "Bu mesajdaki görüntülerin İLK fotoğrafı (ve varsa ilk videosu) ORTAK PARAGRAFA, sonraki fotoğraf ve video ÇEKİLEN SORUYA aittir. "
                + "Ortak paragraf \(listText(passage.all)) numaralı sorular için ortaktır. Çekilen soru bu numaralardan biriyse paragrafı görüntüden oku "
                + "ve soruyu ona göre çöz, değilse paragrafı yok say."
        }
        let text = passage.text.trimmed
        guard !text.isEmpty, !passage.remaining.isEmpty else { return "" }
        return "Kullanıcı bu paragrafı sesle okuttu; \(listText(passage.all)) numaralı sorular için ortaktır. Çekilen soru bu numaralardan biriyse "
            + "paragrafa göre çöz, değilse paragrafı yok say.\nOrtak paragraf (dikte metni, hatalı olabilir; fotoğraftaki yazı varsa onu esas al):\n\(text)"
    }

    static func english(passage: PassageContext, question: String) -> String {
        let p = passage.english.trimmed
        let q = question.trimmed
        if p.isEmpty { return q }
        return "Ortak paragraf: \(p)" + (q.isEmpty ? "" : "\nSoru: \(q)")
    }
}

/// Ortak paragrafın ses kaydı ile sorunun ses kaydını tek WAV'da birleştirir (Gemini tek ses kaydı alır)
enum AudioJoin {
    /// Birleşik kaydın en çok bayt sayısı (300 sn, 16 kHz, 16 bit): istek boyutu sınırı için
    static let maxBytes = 300 * 32_000 + 44

    /// `combined`: paragraf sesi gerçekten eklendi mi (ekleme olmadıysa yalnız soru sesi döner)
    static func join(passage: Data?, question: Data?) -> (data: Data?, combined: Bool) {
        guard let question = question else { return (nil, false) }
        guard let passage = passage, passage.count + question.count <= maxBytes,
              let joined = PCMRecorder.concatenated([passage, question]) else {
            return (question, false)
        }
        return (joined, true)
    }
}
