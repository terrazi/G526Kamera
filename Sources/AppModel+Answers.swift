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

    /// Alınan soruların Gemini'ye gidecek belgeleri. Ayara göre: telefonda temiz okunan sorular düz metin olarak (küçük, hızlı), diğerleri
    /// grup boyutuna göre birleştirilmiş PDF olarak (S12.pdf ya da S12-14.pdf) gider.
    func buildAnswerDocs() -> [AnswerDoc] {
        guard let files = files else { return [] }
        var docs: [AnswerDoc] = []
        let accepted = ledger.acceptedNumbers
        var textNumbers: [Int] = []
        if settings.geminiInput != 1 {
            for n in accepted {
                guard let q = ledger.texts[n] else { continue }
                if settings.geminiInput == 2 || q.isReliable(optionCount: ledger.optionCount) { textNumbers.append(n) }
            }
        }
        for n in textNumbers {
            guard let q = ledger.texts[n] else { continue }
            docs.append(AnswerDoc(name: "S\(n)", numbers: [n], data: Data(q.text.utf8), text: q.text))
        }
        let pdfNumbers = accepted.filter { !textNumbers.contains($0) }
        for group in QuestionGroups.split(pdfNumbers, size: settings.groupSize) {
            let jpegs = group.flatMap { ledger.pages[$0] ?? [] }
            guard !jpegs.isEmpty else { continue }
            let name = QuestionGroups.pdfName(group)
            guard let pdf = try? files.buildPDF(name: name, jpegs: jpegs), let data = try? Data(contentsOf: pdf) else {
                addNote("pdf", "\(TurkishNumbers.spokenList(group)). soru PDF'e çevrilemedi.")
                continue
            }
            if group.count > 1 {
                do {
                    try DocumentFolder.shared.store(file: pdf, subfolder: runName, name: name)
                } catch {
                    addNote("klasor", "Belge klasörüne yazılamadı: \(error.localizedDescription)")
                }
            }
            docs.append(AnswerDoc(name: name, numbers: group, data: data))
        }
        tlog("[gemini] \(textNumbers.count) soru metin, \(pdfNumbers.count) soru PDF olarak gönderilecek")
        return docs
    }

    /// Sorular Gemini'ye gider (model zinciriyle), eksik kalanlar bir kez daha sorulur, cevaplar sırayla okunur
    func answerAndRead() async {
        phase = .asking
        setStatus("Cevaplar hazırlanıyor")
        let docs = buildAnswerDocs()
        guard !docs.isEmpty else {
            say("Sorular PDF'e çevrilemedi. Gemini'ye gönderilecek bir şey yok.")
            await voice.waitUntilIdle()
            return
        }
        let requested = docs.flatMap { $0.numbers }.sorted()
        let profiles = settings.geminiProfileInfos()
        let wait = TimeInterval(settings.geminiWaitLimit)
        say("Sorular Gemini'ye gönderiliyor.")
        var records: [Int: AnswerRecord] = [:]
        var lastError: String?
        var pending = docs
        var pass = 0
        while pass < 2 && !pending.isEmpty && !Task.isCancelled {
            pass += 1
            for chunk in AnswerService.chunk(pending) {
                if Task.isCancelled { return }
                setStatus("Gemini'ye soruluyor (\(chunk.count) parça)")
                do {
                    let got = try await AnswerService.ask(docs: chunk, profiles: profiles, active: settings.geminiActive,
                                                          waitLimit: wait) { [weak self] text in
                        Task { @MainActor in self?.say(text) }
                    }
                    for r in got where requested.contains(r.number) {
                        if let old = records[r.number], AppModel.isGood(old), !AppModel.isGood(r) { continue }
                        records[r.number] = r
                    }
                } catch {
                    lastError = (error as? GeminiError)?.message ?? error.localizedDescription
                    tlog("[gemini] istek başarısız: \(lastError ?? "")")
                }
            }
            let missing = ReadingPlan.unanswered(requested: requested, records: Array(records.values))
            pending = docs.filter { d in d.numbers.contains(where: { missing.contains($0) }) }
            if pass < 2 && !pending.isEmpty {
                say("Eksik cevaplar yeniden soruluyor.")
            }
        }
        if Task.isCancelled { return }
        let list = records.values.sorted { $0.number < $1.number }
        answers = list
        let unanswered = ReadingPlan.unanswered(requested: requested, records: list)
        if let error = lastError, !unanswered.isEmpty {
            addNote("gemini", "Gemini: \(error)")
        }
        if !unanswered.isEmpty {
            addNote("cevapsiz", "Cevabı alınamayan sorular: " + unanswered.map { String($0) }.joined(separator: ", "))
        }
        let codes = GeminiSupport.parseOptionCodes(settings.geminiOptionCodes)
        saveAnswerText(list, unanswered: unanswered, codes: codes)
        if list.isEmpty {
            say("Gemini cevap vermedi. Sorular klasörde duruyor.")
            await voice.waitUntilIdle()
            return
        }
        await readAnswers(list, unanswered: unanswered, codes: codes)
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
        let bad = Array(Set(unanswered + ledger.unreadableNumbers)).sorted()
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
