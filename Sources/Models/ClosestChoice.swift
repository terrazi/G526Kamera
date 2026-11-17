import Foundation

/// En yakın seçenek (bulanık eşleştirme). Tanıyıcı bazen sözcüğü tam yazmaz ("devam" yerine "devan", "evet" yerine "evat"); iki seçenekli
/// sorularda cevap AYNEN tanınmadıysa, duyulan sözcüğün sesce hangi seçeneğe daha çok benzediğine bakılır.
///
/// Yalnız zararsız, geri alınabilir seçimlerde kullanılır: önceki kayda devam / yeni sınav, kamera evet / hayır, yeni bölüm, devam / tekrar.
/// Testi bitirmek, kayıt ya da soru silmek gibi geri alınamayan işlerin yönü HİÇBİR ZAMAN bulanık eşleşmeyle seçilmez; onlar aynen duyulmalıdır.
///
/// Kurallar (hepsi birlikte aranır, biri yoksa cevap anlaşılmamış sayılır ve soru yeniden sorulur):
/// - söz en çok 3 sözcüktür (uzun cümlede tahmin yürütülmez),
/// - olumsuzluk sözü ("etmeyelim", "değil"), komut ("testi bitir", "cevabı sil") ve çelişen söz varsa denenmez,
/// - benzerlik en az %75 (ses anahtarına göre; dört harfli sözcükte tek harf farkı sınırdır) ve en çok iki harf farkı: uzun sözcüklerin ortak
///   ekleri ("-miyorum", "-layalim") iki farklı sözcüğü birbirine benzetmesin,
/// - sözcüğün ilk harfi seçenek sözcüğünün ilk harfiyle aynı, uzunluğu da en çok bir harf farklı olmalıdır (tanıyıcı başı genellikle doğru duyar;
///   "anlamıyorum" ≠ "başlamıyorum", "pazarlama" ≠ "başlama"),
/// - kazanan seçenek diğerinden en az %25 puan önde olmalıdır (iki seçeneğe de benzeyen söz seçilmez).
extension SpokenWords {
    /// Bitişik iki harfin yer değiştirmesi dahil düzenleme uzaklığı (Damerau-Levenshtein, en iyi hizalama)
    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var rows = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { rows[i][0] = i }
        for j in 0...b.count { rows[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var best = min(rows[i - 1][j] + 1, rows[i][j - 1] + 1, rows[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    best = min(best, rows[i - 2][j - 2] + 1)
                }
                rows[i][j] = best
            }
        }
        return rows[a.count][b.count]
    }

    /// İki sözcüğün sesce benzerliği, 0...1: ses anahtarları (`key`) arasındaki düzenleme uzaklığı, uzun olanın uzunluğuna bölünüp 1'den çıkarılır
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(key(a))
        let y = Array(key(b))
        let longest = max(x.count, y.count)
        guard longest > 0 else { return 0 }
        return 1 - Double(editDistance(x, y)) / Double(longest)
    }

    /// Duyulan sözcüklerin en çok benzediği seçeneğin sırası; güvenle seçilemiyorsa nil. Her seçenek bir sözcük kümesidir (örn. "devam" sözleri,
    /// "yeni" sözleri). Dört harften kısa sözcükler ne duyulan ne seçenek tarafında hesaba katılır (kısa sözcükler çok kolay birbirine benzer).
    static func closestOption(_ heard: [String], among options: [Set<String>], maxWords: Int = 3,
                              minScore: Double = 0.75, minGap: Double = 0.25) -> Int? {
        guard options.count >= 2, !heard.isEmpty, heard.count <= maxWords else { return nil }
        let candidates = heard.filter { $0.count >= 4 && !fillerWords.contains($0) }
        guard !candidates.isEmpty else { return nil }
        let scores = options.map { option -> Double in
            var best = 0.0
            for word in candidates {
                let wordKey = Array(key(word))
                for entry in option where entry.count >= 4 {
                    let entryKey = Array(key(entry))
                    guard wordKey.first == entryKey.first,
                          abs(wordKey.count - entryKey.count) <= 1,
                          editDistance(wordKey, entryKey) <= 2 else { continue }
                    best = max(best, similarity(word, entry))
                }
            }
            return best
        }
        guard let top = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[top] >= minScore else { return nil }
        let runnerUp = scores.indices.filter { $0 != top }.map { scores[$0] }.max() ?? 0
        guard scores[top] - runnerUp >= minGap else { return nil }
        return top
    }

    /// Konuşmada sık geçen, ama bir seçeneğe benzediği için yanlış seçtirebilecek dolgu sözcükler ("yani" ≈ "yeni")
    /// ve sayı sözcükleri ("yedi" ≈ "yeni")
    static let fillerWords: Set<String> = ["yani", "hani", "sanki", "dort", "alti", "yedi", "sekiz", "dokuz"]
}

extension SpokenReply {
    /// Bulanık eşleştirmenin ortak ön koşulları: kısa söz; olumsuzluk, komut ve iptal yok. Uygunsa sözcükleri verir.
    private static func closeWords(_ text: String) -> [String]? {
        let heard = SpokenWords.of(text)
        guard !heard.isEmpty, heard.count <= 3 else { return nil }
        if heard.contains(where: { SpokenWords.exactly($0, choiceNegations) || SpokenWords.exactly($0, finishNegations) }) { return nil }
        if VoiceCommand.parse(text) != nil || VoiceCommand.parseCancel(text) != nil { return nil }
        return heard
    }

    /// "Önceki kayıttan devam mı, yeni sınav mı" sorusunda sözcüğe en çok benzeyen seçenek. Önce `start` (aynen) denenmiş olmalıdır.
    static func closestStart(_ text: String) -> Start? {
        guard let heard = closeWords(text),
              let index = SpokenWords.closestOption(heard, among: [continueWords, newWords]) else { return nil }
        return index == 0 ? .continuePrevious : .startNew
    }

    /// Kamera sorusunda ("kamera ile çekip göndermek ister misiniz?") evet / hayır. Zayıf evetler ("kamera", "fotoğraf") bulanık eşleşmede yoktur.
    static func closestCameraChoice(_ text: String) -> YesNo? {
        guard let heard = closeWords(text) else { return nil }
        // "kamerayla", "çekmek" gibi zayıf ya da belirsiz sözler zaten anlamıyla ele alınmıştır ("çekmek istiyorum" evet); bulanık hayır yapılmaz
        if heard.contains(where: { SpokenWords.exactly($0, cameraWeakYes) || SpokenWords.exactly($0, cameraNeutral) }) { return nil }
        guard let index = SpokenWords.closestOption(heard, among: [cameraYesClose, cameraNo]) else { return nil }
        return index == 0 ? .yes : .no
    }

    /// "Yeni bölümle devam mı, testi tamamlayalım mı" sorusunda YALNIZ yeni bölüm yönü bulanık seçilir. Söz testi bitirmeye daha çok
    /// benziyorsa (ya da iki yöne de) nil döner: testi bitirmek aynen duyulmalıdır.
    static func closestNextSection(_ text: String) -> NextSection? {
        guard let heard = closeWords(text),
              SpokenWords.closestOption(heard, among: [sectionProceedClose, sectionFinish.union(reviewFinish)]) == 0 else { return nil }
        return .newSection
    }

    /// Cevaplar okunduktan sonra "Devam, Tekrar ya da Bitir": YALNIZ devam ve tekrar bulanık seçilir. Söz bitirmeye daha çok benziyorsa nil.
    static func closestReview(_ text: String) -> Review? {
        guard let heard = closeWords(text),
              let index = SpokenWords.closestOption(heard, among: [reviewContinueClose, reviewRepeatClose, reviewFinish]) else { return nil }
        switch index {
        case 0: return .continueTest
        case 1: return .repeatAnswers
        default: return nil
        }
    }

    /// Kamera "evet" yönünün bulanık eşleşmede kullanılan sözleri: yalnız açık evetler. "başla / başlat" gibi çok kullanılan sözcükler ("başka" ≈ "başla")
    /// kamerayı yanlışlıkla açtırmasın diye dışarıdadır.
    static let cameraYesClose: Set<String> = ["evet", "tamam", "olur", "aynen", "tabii", "tabiki", "kesinlikle", "dogru", "istiyorum", "isterim", "isteriz"]

    /// Yeni bölüm yönünün bulanık eşleşmede kullanılan sözleri (aynı nedenle "başla" yok)
    static let sectionProceedClose: Set<String> = ["evet", "tamam", "olur", "aynen", "tabii", "tabiki", "yeni", "devam", "sonraki", "siradaki", "gecelim"]

    /// "Devam" yönünün bulanık eşleşmede kullanılan sözleri ("soruya", "sorulara" gibi konu sözcükleri dışarıda: "soruyu atla" devam sayılmasın)
    static let reviewContinueClose: Set<String> = ["devam", "surdur", "surdurelim", "surdurun", "ilerle", "ilerleyelim", "gecelim", "sonraki", "siradaki"]

    /// "Tekrar" yönünün bulanık eşleşmede kullanılan sözleri (kısa ve yaygın sözcükler "oku", "daha", "yine" dışarıda)
    static let reviewRepeatClose: Set<String> = ["tekrar", "tekrarla", "tekrarlayin", "tekrarlayalim", "dinle", "dinleyelim", "yeniden", "oynat", "oynatin"]
}
