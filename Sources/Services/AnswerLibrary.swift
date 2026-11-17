import Foundation

/// Modül 5 ve 6: cevap sesleri cihazın içinde, o güne ait bir klasöre kaydedilir (soru_1, soru_2, …).
/// Kök klasör, kullanıcının Dosyalar uygulamasında seçtiği kayıt klasörüdür (uygulama silinse de kalır, `FolderStore`).
/// Seçilmemişse ya da erişilemiyorsa uygulamanın kendi Belgeler dizini kullanılır ve ekranda uyarı çıkar.
struct AnswerLibrary {
    static let transcriptName = "cevaplar.txt"
    static let audioExtensions: Set<String> = ["m4a", "caf", "mp3", "wav", "aac"]

    /// Şu an kullanılacak kök ve (varsa) kayıt klasörüyle ilgili uyarı
    typealias Resolution = (url: URL, warning: String?)

    private let resolver: () -> Resolution
    private let refresher: () -> Void
    /// Temizlik uzantısı (`Cleanup.swift`) de kullanır
    let fileManager: FileManager

    /// Köklerin kullanılacağı klasör
    var root: URL { return resolver().url }
    /// Kayıt klasörü seçilmemiş / erişilemiyorsa Türkçe uyarı, sorun yoksa nil
    var warning: String? { return resolver().warning }

    init(root: URL = AnswerLibrary.documentsDirectory, fileManager: FileManager = .default) {
        self.resolver = { (url: root, warning: nil) }
        self.refresher = {}
        self.fileManager = fileManager
    }

    init(resolver: @escaping () -> Resolution, refresh: @escaping () -> Void, fileManager: FileManager = .default) {
        self.resolver = resolver
        self.refresher = refresh
        self.fileManager = fileManager
    }

    /// Oturum başında seçilen klasörün hâlâ yazılabilir olduğunu yeniden denetler
    func prepare() { refresher() }

    static var documentsDirectory: URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    // MARK: Klasör adları

    /// Her sınav oturumunun kendi üst klasörünün adı: yerel saatle yıl, ay, gün, saat, dakika, saniye ("20261115223912")
    static func folderName(for date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: date)
    }

    /// "20261115223912" → (ad, 1); aynı saniyede ikinci açılış "20261115223912_2" → (ad, 2). Eski sürümlerin gün adları ("2026-11-13",
    /// "2026-11-13_2") de tanınır (önceki kayıtlar kaybolmasın); başka ad nil
    static func parseFolderName(_ name: String) -> (day: String, part: Int)? {
        guard name.range(of: "^(\\d{14}|\\d{4}-\\d{2}-\\d{2})(_\\d+)?$", options: .regularExpression) != nil else { return nil }
        let pieces = name.split(separator: "_", maxSplits: 1).map(String.init)
        let part = pieces.count > 1 ? (Int(pieces[1]) ?? 1) : 1
        return (pieces[0], part)
    }

    /// Klasörleri zamana göre sıralamak için anahtar: eski gün adı o günün gece yarısı sayılır ("2026-11-13" → "20261113000000")
    static func sortKey(_ day: String) -> String {
        let digits = day.filter { $0.isNumber }
        return digits.count == 8 ? digits + "000000" : digits
    }

    // MARK: Bölümler

    /// Bölümlü sınavda her bölümün cevapları sınav klasörünün içinde ayrı bir klasöre gider ("bolum_2"): iki bölümün 5. sorusu birbirini ezmez
    static let sectionPrefix = "bolum_"

    static func sectionFolderName(_ section: Int) -> String {
        return "\(sectionPrefix)\(section)"
    }

    /// "bolum_2" → 2
    static func sectionNumber(fromFolderName name: String) -> Int? {
        guard name.hasPrefix(sectionPrefix) else { return nil }
        guard let number = Int(name.dropFirst(sectionPrefix.count)), number > 0 else { return nil }
        return number
    }

    /// Günlükte ve "önceki kayıt" bilgisinde saklanan kayıt yeri adı: bölümsüz sınavda yalnız klasör adı ("2026-11-15"), bölümlüde klasör adı
    /// ve bölüm sırası ("2026-11-15@2")
    static func locationName(exam: String, section: Int) -> String {
        return section > 0 ? "\(exam)@\(section)" : exam
    }

    static func splitLocation(_ name: String) -> (exam: String, section: Int) {
        let pieces = name.split(separator: "@", maxSplits: 1).map(String.init)
        guard pieces.count == 2, let section = Int(pieces[1]), section > 0 else { return (pieces.first ?? name, 0) }
        return (pieces[0], section)
    }

    /// Kayıt yeri adından sınav klasörü (varsa) ve bölüm sırası; klasör yoksa nil
    func existingLocation(named name: String) -> (exam: URL, section: Int)? {
        let parts = AnswerLibrary.splitLocation(name)
        guard let exam = existingSessionFolder(named: parts.exam) else { return nil }
        return (exam, parts.section)
    }

    /// Bölümün cevap klasörü (yoksa açılır)
    func sectionFolder(in exam: URL, section: Int) throws -> URL {
        let url = exam.appendingPathComponent(AnswerLibrary.sectionFolderName(section), isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Bölümün cevap klasörü varsa adresi (açmaz); yoksa nil
    func existingSectionFolder(in exam: URL, section: Int) -> URL? {
        let url = exam.appendingPathComponent(AnswerLibrary.sectionFolderName(section), isDirectory: true)
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue ? url : nil
    }

    /// Sınavın bütün bölümlerindeki (ve bölümsüz kısmındaki) toplam cevap sayısı
    func examAnswerCount(exam: URL) -> Int {
        return sectionFolders(in: exam).reduce(answerCount(in: exam)) { $0 + answerCount(in: $1) }
    }

    /// Sınav klasöründeki bölüm klasörleri, bölüm sırasına göre
    func sectionFolders(in exam: URL) -> [URL] {
        let names = (try? fileManager.contentsOfDirectory(atPath: exam.path)) ?? []
        return names.compactMap { name -> (Int, URL)? in
            guard let number = AnswerLibrary.sectionNumber(fromFolderName: name) else { return nil }
            return (number, exam.appendingPathComponent(name, isDirectory: true))
        }
        .sorted { $0.0 < $1.0 }
        .map { $0.1 }
    }

    /// Klasörde kayıtlı farklı soru numaralarının sayısı (hem ses dosyalarına hem cevaplar.txt satırlarına bakılır)
    func answerCount(in folder: URL) -> Int {
        var numbers = Set<Int>()
        for file in directAnswerFiles(in: folder) {
            if let number = AnswerLibrary.questionNumber(fromFileName: file.lastPathComponent) { numbers.insert(number) }
        }
        for record in transcriptRecords(in: folder) { numbers.insert(record.number) }
        return numbers.count
    }

    /// "soru_12.m4a" → 12
    static func questionNumber(fromFileName name: String) -> Int? {
        let url = URL(fileURLWithPath: name)
        guard audioExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        let stem = url.deletingPathExtension().lastPathComponent
        guard stem.hasPrefix("soru_") else { return nil }
        return Int(stem.dropFirst("soru_".count))
    }

    // MARK: Klasör işlemleri

    /// Yeni sınav oturumu için kendi üst klasörünü açar (adı o anın tarihi ve saati: "20261115223912"). Hiç dosya içermeyen önceki boş oturum
    /// klasörleri (açılıp cevap alınmadan kapananlar) silinir; aynı saniyede açılmış, içinde cevap olan bir klasör varsa ezilmesin diye "_2", "_3" … açılır.
    func newSessionFolder(for date: Date, calendar: Calendar = .current) throws -> URL {
        removeEmptySessionFolders()
        let base = AnswerLibrary.folderName(for: date, calendar: calendar)
        var part = 1
        while true {
            let name = part == 1 ? base : "\(base)_\(part)"
            let url = root.appendingPathComponent(name, isDirectory: true)
            if !fileManager.fileExists(atPath: url.path) || answerFiles(in: url).isEmpty {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
                return url
            }
            part += 1
        }
    }

    /// İçinde hiçbir şey olmayan oturum klasörlerini siler (yalnız zaman damgalı adlılar; cevap ya da başka dosya içeren hiçbir klasöre dokunulmaz)
    func removeEmptySessionFolders() {
        let names = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names {
            guard name.range(of: "^\\d{14}(_\\d+)?$", options: .regularExpression) != nil else { continue }
            let url = root.appendingPathComponent(name, isDirectory: true)
            if holdsNoFiles(url) { try? fileManager.removeItem(at: url) }
        }
    }

    /// Klasörde (alt klasörler dahil) hiç dosya yok mu; okunamayan klasör "var" sayılır (silinmez)
    private func holdsNoFiles(_ url: URL) -> Bool {
        guard let names = try? fileManager.contentsOfDirectory(atPath: url.path) else { return false }
        for name in names {
            let child = url.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
            if !holdsNoFiles(child) { return false }
        }
        return true
    }

    /// Adı verilen oturum klasörü varsa (beklenmedik kapanmadan sonra aynı klasöre devam etmek için) adresi; yoksa nil
    func existingSessionFolder(named name: String) -> URL? {
        guard AnswerLibrary.parseFolderName(name) != nil else { return nil }
        let url = root.appendingPathComponent(name, isDirectory: true)
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue ? url : nil
    }

    /// İçinde cevap dosyası olan en yeni gün klasörü (tekrar modu için); yoksa nil
    func latestFolder() -> URL? {
        let names = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        let candidates = names.compactMap { name -> (name: String, key: (String, Int))? in
            guard let parsed = AnswerLibrary.parseFolderName(name) else { return nil }
            return (name, (AnswerLibrary.sortKey(parsed.day), parsed.part))
        }
        let sorted = candidates.sorted { a, b in
            a.key.0 != b.key.0 ? a.key.0 < b.key.0 : a.key.1 < b.key.1
        }
        for candidate in sorted.reversed() {
            let url = root.appendingPathComponent(candidate.name, isDirectory: true)
            if !answerFiles(in: url).isEmpty { return url }
        }
        return nil
    }

    // MARK: Cevap dosyaları

    /// Soru için dosya yolu, uzantısız ("…/soru_3"); uzantıyı kaydeden belirler
    func fileBase(question number: Int, in folder: URL) -> URL {
        return folder.appendingPathComponent("soru_\(number)")
    }

    /// Aynı numaralı eski kayıtları siler (soru yeniden okunup cevaplanınca çift dosya kalmasın)
    func removeExisting(question number: Int, in folder: URL) {
        for url in answerFiles(in: folder) where AnswerLibrary.questionNumber(fromFileName: url.lastPathComponent) == number {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Klasördeki cevap sesleri, soru numarasına göre sıralı (soru_2, soru_10'dan önce gelir). Bölümlü bir sınav klasörüyse önce kendi
    /// dosyaları, sonra bölüm klasörlerindekiler bölüm sırasıyla gelir (tekrar modu bütün bölümleri okur); bölüm klasörünün içinde yalnız o bölümünkiler.
    func answerFiles(in folder: URL) -> [URL] {
        var files = directAnswerFiles(in: folder)
        for section in sectionFolders(in: folder) { files += directAnswerFiles(in: section) }
        return files
    }

    /// Yalnız bu klasörün kendi cevap sesleri (alt klasörlere bakılmaz)
    func directAnswerFiles(in folder: URL) -> [URL] {
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        let numbered = names.compactMap { name -> (Int, String)? in
            guard let number = AnswerLibrary.questionNumber(fromFileName: name) else { return nil }
            return (number, name)
        }
        return numbered
            .sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
            .map { folder.appendingPathComponent($0.1) }
    }

    /// Düz yazıdaki ("cevaplar.txt") cevap satırları; her satır "Soru N, …" biçimindedir. Önceki kayıttan devam edilirken cevap listesini ve
    /// "son cevabı tekrarla" komutunu besler. Dosya yoksa ya da okunamazsa boş.
    func transcriptRecords(in folder: URL) -> [AnswerRecord] {
        let url = folder.appendingPathComponent(AnswerLibrary.transcriptName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { raw -> AnswerRecord? in
            let line = String(raw)
            guard line.hasPrefix("Soru ") else { return nil }
            guard let number = Int(line.dropFirst("Soru ".count).prefix(while: { $0.isNumber })) else { return nil }
            return AnswerRecord(number: number, option: "", text: "", spoken: line)
        }
    }

    /// Soru yeniden okunup cevaplandıysa düz yazıdaki eski satırı yenisiyle değiştirir (aynı numaralı iki çelişen satır kalmasın); numaranın
    /// satırı yoksa sona ekler. Dosya okunamazsa üzerine yazılmaz (önceki cevaplar kaybolmasın). Yazılamadıysa false.
    @discardableResult
    func upsertTranscript(_ line: String, number: Int, in folder: URL) -> Bool {
        let url = folder.appendingPathComponent(AnswerLibrary.transcriptName)
        guard fileManager.fileExists(atPath: url.path) else { return appendTranscript(line, in: folder) }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let prefix = "Soru \(number),"
        let matches = lines.indices.filter { lines[$0].hasPrefix(prefix) }
        guard let first = matches.first else { return appendTranscript(line, in: folder) }
        lines[first] = line
        for index in matches.dropFirst().reversed() { lines.remove(at: index) }
        do {
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// "Son soruyu sil": numaranın düz yazıdaki satırı (varsa) silinir. Dosya yoksa ya da satır yoksa bir şey yapılmaz (true). Dosya okunamaz ya da
    /// yazılamazsa false (üzerine yazılmaz; önceki cevaplar kaybolmasın).
    @discardableResult
    func removeTranscript(number: Int, in folder: URL) -> Bool {
        let url = folder.appendingPathComponent(AnswerLibrary.transcriptName)
        guard fileManager.fileExists(atPath: url.path) else { return true }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let prefix = "Soru \(number),"
        let kept = lines.filter { !$0.hasPrefix(prefix) }
        guard kept.count != lines.count else { return true }
        do {
            try (kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// "Soru numarası düzelt": `folder` içindeki "soru_7.m4a" gibi dosyalar "soru_8.m4a" olur (uzantı korunur). Hedef numaranın eski dosyaları önce silinir.
    /// Yalnız verilen klasöre bakılır (bölüm klasörü ya da bölümsüz sınav klasörü; başka bölüme ya da oturuma dokunulmaz). Hiçbir dosya yoksa true.
    /// Bir dosya taşınamazsa o ana kadar taşınanlar geri alınır ve false döner (yarım kalmış, iki numaralı kayıt bırakılmaz).
    @discardableResult
    func renumberFiles(from old: Int, to new: Int, in folder: URL) -> Bool {
        let sources = directAnswerFiles(in: folder).filter { AnswerLibrary.questionNumber(fromFileName: $0.lastPathComponent) == old }
        guard !sources.isEmpty else { return true }
        var staged: [(from: URL, to: URL)] = []
        for url in sources {
            let target = folder.appendingPathComponent("soru_\(new)").appendingPathExtension(url.pathExtension)
            staged.append((url, target))
        }
        // Hedef numaranın eski dosyaları (kaynak dosyalarla çakışmayanlar) silinir: aynı numaralı iki kayıt kalmasın
        for url in directAnswerFiles(in: folder) where AnswerLibrary.questionNumber(fromFileName: url.lastPathComponent) == new {
            try? fileManager.removeItem(at: url)
        }
        var done: [(from: URL, to: URL)] = []
        for move in staged {
            do {
                try fileManager.moveItem(at: move.from, to: move.to)
                done.append(move)
            } catch {
                for undo in done.reversed() { try? fileManager.moveItem(at: undo.to, to: undo.from) }
                return false
            }
        }
        return true
    }

    /// "Soru numarası düzelt": düz yazıdaki "Soru 7, …" satırı `line` ile (yeni numaralı) değiştirilir; yeni numaranın eski satırı (varsa) silinir. Satır
    /// aynı yerde kalır. Eski numaranın satırı yoksa yeni satır sona eklenir. Dosya okunamaz ya da yazılamazsa false (üzerine yazılmaz).
    @discardableResult
    func renumberTranscript(from old: Int, to new: Int, line: String, in folder: URL) -> Bool {
        let url = folder.appendingPathComponent(AnswerLibrary.transcriptName)
        guard fileManager.fileExists(atPath: url.path) else { return appendTranscript(line, in: folder) }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let oldPrefix = "Soru \(old),"
        let newPrefix = "Soru \(new),"
        lines.removeAll { $0.hasPrefix(newPrefix) }
        if let index = lines.firstIndex(where: { $0.hasPrefix(oldPrefix) }) {
            lines[index] = line
            for extra in lines.indices.reversed() where extra != index && lines[extra].hasPrefix(oldPrefix) { lines.remove(at: extra) }
        } else {
            lines.append(line)
        }
        do {
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// Cevapları düz yazı olarak da tutar: sesler silinse de cevaplar okunabilir kalır. Yazılamadıysa (yer doldu, klasör erişimi gitti) false.
    /// Dosya varsa yalnız sonuna eklenir; açılamazsa üzerine yazılmaz (önceki cevapların satırları kaybolmasın).
    @discardableResult
    func appendTranscript(_ line: String, in folder: URL) -> Bool {
        let url = folder.appendingPathComponent(AnswerLibrary.transcriptName)
        let data = Data((line + "\n").utf8)
        if fileManager.fileExists(atPath: url.path) {
            guard let handle = try? FileHandle(forWritingTo: url) else { return false }
            defer { try? handle.close() }
            do {
                _ = try handle.seekToEnd()
                try handle.write(contentsOf: data)
                return true
            } catch {
                return false
            }
        }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
