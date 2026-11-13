import Foundation
import UIKit

extension AppModel {
    // MARK: - İnternet

    /// Tarama bitince: önce internet yoklanır; yoksa internet kestirmesi (Wi-Fi'ı kapat, hücreseli aç) çalıştırılır, internet gelene kadar
    /// ayardaki sayıda ve aralıkta yinelenir. İnternet geldiyse true.
    func restoreInternet() async -> Bool {
        phase = .restoringInternet
        setStatus("İnternet kontrol ediliyor")
        if await InternetProbe.isOnline() { return true }
        let name = settings.connectionShortcutName.trimmed
        var tries = max(settings.shortcutTries, 1)
        let wait = Double(settings.shortcutWaitSeconds)
        if name.isEmpty {
            // Kestirme yoksa kullanıcı internetin kendiliğinden / elle gelmesini bekler (en çok 5 yoklama aralığı)
            tries = min(tries, 5)
            addNote("internet", "İnternet kestirmesi girilmemiş (Ayarlar > Kestirmeler). İnternetin gelmesi bekleniyor.")
        }
        say("İnternet bağlanıyor.")
        for attempt in 1...tries {
            if Task.isCancelled { return false }
            if name.isEmpty {
                setStatus("İnternet bekleniyor (\(attempt)/\(tries))")
            } else {
                setStatus("İnternet kestirmesi çalışıyor (\(attempt)/\(tries))")
                _ = await runShortcutAndWait(name)
                if Task.isCancelled { return false }
            }
            let deadline = now() + wait
            while !Task.isCancelled {
                if await InternetProbe.isOnline() {
                    removeNote("internet")
                    say("İnternet bağlandı.")
                    return true
                }
                if now() >= deadline { break }
                await pause(3)
            }
        }
        addNote("internet", "İnternete ulaşılamadı (\(tries) deneme). Sorular belge klasöründe duruyor.")
        return false
    }

    // MARK: - Gemini

    /// Alınan sayfaların Gemini'ye gidecek belgeleri. Ayara göre her sayfa için gezdirme videosu ve/veya videodan seçilen net karelerin PDF'i.
    /// İstenen parça yoksa (video yazılamadıysa gibi) elde olan gönderilir.
    func buildAnswerDocs() -> [AnswerDoc] {
        let mode = settings.pageInput
        var docs: [AnswerDoc] = []
        var videoBytes = 0
        var pdfBytes = 0
        for p in pages {
            var doc = AnswerDoc(page: p.number)
            if mode != 2, let url = p.pdf, let data = try? Data(contentsOf: url) { doc.pdf = data }
            if mode != 1, let url = p.video, let data = try? Data(contentsOf: url) { doc.video = data }
            if doc.pdf == nil && doc.video == nil {
                // istenen parça yok: öbürü varsa o gönderilir
                if let url = p.pdf, let data = try? Data(contentsOf: url) { doc.pdf = data }
                if let url = p.video, let data = try? Data(contentsOf: url) { doc.video = data }
            }
            guard doc.pdf != nil || doc.video != nil else {
                addNote("sayfa\(p.number)", "\(p.number). sayfanın dosyaları okunamadı; bu sayfa gönderilmiyor.")
                continue
            }
            videoBytes += doc.video?.count ?? 0
            pdfBytes += doc.pdf?.count ?? 0
            docs.append(doc)
        }
        tlog("[gemini] \(docs.count) sayfa gönderilecek: video \(videoBytes / 1024) KB, kareler \(pdfBytes / 1024) KB")
        return docs
    }

    /// Sayfalar Gemini'ye gider (model zinciriyle), gönderilemeyenler bir kez daha denenir, cevaplar sırayla okunur
    func answerAndRead() async {
        phase = .asking
        setStatus("Cevaplar hazırlanıyor")
        let docs = buildAnswerDocs()
        guard !docs.isEmpty else {
            say("Sayfalar gönderilemedi. Gemini'ye gönderilecek bir şey yok.")
            await voice.waitUntilIdle()
            return
        }
        let total = settings.questionTotal
        let optionCount = settings.optionCount
        let profiles = settings.geminiProfileInfos()
        let wait = TimeInterval(settings.geminiWaitLimit)
        say("Sayfalar Gemini'ye gönderiliyor.")
        var records: [Int: AnswerRecord] = [:]
        var lastError: String?
        var pending = docs
        var pass = 0
        while pass < 2 && !pending.isEmpty && !Task.isCancelled {
            pass += 1
            var failed: [AnswerDoc] = []
            for chunk in AnswerService.chunk(pending) {
                if Task.isCancelled { return }
                setStatus("Gemini'ye soruluyor (\(chunk.count) sayfa)")
                do {
                    let got = try await AnswerService.ask(docs: chunk, total: total, optionCount: optionCount, profiles: profiles,
                                                          active: settings.geminiActive, waitLimit: wait) { [weak self] text in
                        Task { @MainActor in self?.say(text) }
                    }
                    for r in got where r.number >= 1 && (total <= 0 || r.number <= total) {
                        if let old = records[r.number], AppModel.isGood(old), !AppModel.isGood(r) { continue }
                        records[r.number] = r
                    }
                } catch {
                    lastError = (error as? GeminiError)?.message ?? error.localizedDescription
                    tlog("[gemini] istek başarısız: \(lastError ?? "")")
                    failed += chunk
                }
            }
            pending = failed
            if pass < 2 && !pending.isEmpty {
                say("Gönderilemeyen sayfalar yeniden deneniyor.")
            }
        }
        if Task.isCancelled { return }
        let list = records.values.sorted { $0.number < $1.number }
        answers = list
        if !pending.isEmpty {
            addNote("gemini", "Gemini: \(lastError ?? "cevap alınamadı") (gönderilemeyen sayfalar: " + pending.map { String($0.page) }.joined(separator: ", ") + ")")
        }
        let unanswered = ReadingPlan.unanswered(requested: AppModel.expectedNumbers(total: total, records: list), records: list)
        if !unanswered.isEmpty {
            addNote("cevapsiz", "Cevabı alınamayan sorular: " + unanswered.map { String($0) }.joined(separator: ", "))
        }
        let codes = GeminiSupport.parseOptionCodes(settings.geminiOptionCodes)
        saveAnswerText(list, unanswered: unanswered, codes: codes)
        if list.isEmpty {
            say("Gemini cevap vermedi. Sayfalar klasörde duruyor.")
            await voice.waitUntilIdle()
            return
        }
        await readAnswers(list, unanswered: unanswered, codes: codes)
    }

    /// Cevabı beklenen soru numaraları: soru sayısı girilmişse 1…sayı, girilmemişse Gemini'nin verdiği numaralar
    static func expectedNumbers(total: Int, records: [AnswerRecord]) -> [Int] {
        if total > 0 { return Array(1...total) }
        return records.map { $0.number }
    }

    /// Cevap kullanılabilir mi (şık var ve okunamadı değil)
    static func isGood(_ r: AnswerRecord) -> Bool {
        return r.status != AnswerRecord.unread && !r.letter.isEmpty
    }

    private func saveAnswerText(_ list: [AnswerRecord], unanswered: [Int], codes: [(letter: String, word: String)]) {
        let text = ReadingPlan.fileText(list, unanswered: unanswered, codes: codes)
        do {
            try DocumentFolder.shared.store(data: Data(text.utf8), subfolder: runName, name: "Cevaplar.txt")
        } catch {
            addNote("klasor", "Cevaplar belge klasörüne yazılamadı: \(error.localizedDescription)")
        }
    }

    // MARK: - Okuma

    /// Cevapları kulaklığa sırayla okur; sonra bir kez daha okur; okunamayanları söyler
    func readAnswers(_ list: [AnswerRecord], unanswered: [Int], codes: [(letter: String, word: String)]) async {
        phase = .reading
        // Kulaklık yoksa cevaplar boşa okunmasın: bağlanana kadar beklenir (cevaplar ekranda görünür)
        if !voice.headphonesReady {
            setStatus("Kulaklık bekleniyor")
            addNote("kulaklik", "Kulaklık bağlı değil: cevaplar kulaklık bağlanınca okunacak (cevaplar ekranda ve klasördeki Cevaplar.txt dosyasında).")
            let deadline = now() + ScanRules.headphonesWaitSeconds
            while !voice.headphonesReady && now() < deadline && !Task.isCancelled {
                await pause(2)
            }
            if Task.isCancelled { return }
            if !voice.headphonesReady {
                setStatus("Cevaplar okunamadı: kulaklık yok")
                return
            }
            removeNote("kulaklik")
        }
        let lines = ReadingPlan.lines(list, codes: codes)
        setStatus("Cevaplar okunuyor")
        await speakAll(lines, pauseSeconds: Double(settings.answerPauseSeconds))
        if Task.isCancelled { return }
        await pause(Double(settings.answerPauseSeconds))
        setStatus("Cevaplar bir kez daha okunuyor")
        await sayAndWait("Cevaplar bir kez daha okunuyor.")
        await pause(Double(settings.repeatPauseSeconds))
        await speakAll(lines, pauseSeconds: Double(settings.repeatPauseSeconds))
        if Task.isCancelled { return }
        let bad = unanswered
        if !bad.isEmpty {
            await pause(Double(settings.repeatPauseSeconds))
            await sayAndWait(ReadingPlan.unansweredText(bad))
        }
        await sayAndWait("Deneme sınavı tamamlandı.")
    }

    /// Cümleleri sırayla okur; her cümleden sonra (sonuncudan sonra değil) bekler
    private func speakAll(_ lines: [String], pauseSeconds: Double) async {
        for (i, line) in lines.enumerated() {
            if Task.isCancelled { return }
            await sayAndWait(line)
            if i < lines.count - 1 { await pause(pauseSeconds) }
        }
    }
}
