import Foundation

/// Cevap okumasını kimin istediği: sessizlikte hangi seçeneğin varsayılan olacağını belirler
enum ReviewOrigin: Equatable {
    /// "Testi bitir" onaylandı: cevaplar okundu, sessizlikte test tamamlanır
    case endRequest
    /// "Cevapları tekrarla" denmiş: sessizlikte teste devam edilir
    case repeatRequest
}

/// Eksik soru numarası beklenirken verilen cevap
enum NumberReply: Equatable {
    case number(Int)
    /// "sıradaki": sıradaki numara verilir
    case sequence
}

/// Anlama (en iyi okuma + tanıyıcının alternatif okumaları) ve test içinde cevapları okuma: "cevapları tekrarla" her aşamada söylenebilir;
/// okuma bitince kaç sorunun cevabının okunduğu söylenir ve "Devam, Tekrar ya da Bitir" sorulur.
extension SessionViewModel {
    // MARK: Anlama

    /// Duyulan metni çözer. Önce tanıyıcının en iyi okumasına bakılır; anlaşılmazsa son sözcükler için verdiği alternatif okumalar denenir
    /// (tek sözcüğü alternatifiyle değiştirilmiş metinler).
    func interpret<T>(_ parse: (String) -> T?) -> T? {
        if let value = parse(accumulator.text) { return value }
        for variant in alternativeTexts() {
            if let value = parse(variant) {
                tlog("[duyulan] alternatif okuma kullanıldı: \"\(variant)\" (en iyi okuma: \"\(accumulator.text)\")")
                return value
            }
        }
        return nil
    }

    /// Önce aynen (katı) anlama: en iyi okuma ve tanıyıcının alternatif okumaları. Anlaşılmazsa, zararsız iki seçenekli sorularda duyulan söze
    /// en çok benzeyen seçenek alınır (`SpokenWords.closestOption`). Önce bütün okumalar aynen denendiği için bulanık eşleşme aynen tanınan
    /// bir okumanın önüne geçmez. `log` yalnız cevabı gerçekten uygulayan çağrıda açılır (ara denetimler günlüğü doldurmasın).
    func interpretClosely<T>(_ strict: (String) -> T?, closest: (String) -> T?, what: String, log: Bool) -> T? {
        if let value = interpret(strict) { return value }
        for text in [accumulator.text] + alternativeTexts() {
            if let value = closest(text) {
                if log { tlog("[duyulan] en yakın seçenek alındı (\(what)): \"\(text)\"") }
                return value
            }
        }
        return nil
    }

    /// "Önceki kayıttan devam mı, yeni sınav mı" cevabı
    func heardStart(log: Bool = false) -> SpokenReply.Start? {
        return interpretClosely(SpokenReply.start, closest: SpokenReply.closestStart, what: "önceki kayıt / yeni sınav", log: log)
    }

    /// Kamera sorusunun (tek soru ya da paragraf) evet / hayır cevabı
    func heardCameraChoice(log: Bool = false) -> SpokenReply.YesNo? {
        return interpretClosely(SpokenReply.cameraChoice, closest: SpokenReply.closestCameraChoice, what: "kamera evet / hayır", log: log)
    }

    /// "Yeni bölüm mü, testi tamamlayalım mı" cevabı (testi bitirme yönü yalnız aynen duyulursa)
    func heardNextSection(log: Bool = false) -> SpokenReply.NextSection? {
        return interpretClosely(SpokenReply.nextSection, closest: SpokenReply.closestNextSection, what: "yeni bölüm", log: log)
    }

    /// "Devam, Tekrar ya da Bitir" cevabı (bitirme yalnız aynen duyulursa)
    func heardReview(log: Bool = false) -> SpokenReply.Review? {
        return interpretClosely(SpokenReply.review, closest: SpokenReply.closestReview, what: "devam / tekrar", log: log)
    }

    /// En iyi okumadaki tek bir sözcüğü alternatifiyle değiştirerek kurulan metinler. Alternatif sözcükler, eldeki metnin tamamını
    /// kapsamıyorsa (uzun metin, birleştirilmiş bölümler) hizalanamaz ve boş döner.
    func alternativeTexts() -> [String] {
        guard !heardOptions.isEmpty else { return [] }
        let best = heardOptions.map { $0.first ?? "" }
        guard SpokenWords.of(best.joined(separator: " ")) == SpokenWords.of(accumulator.text) else { return [] }
        var variants: [String] = []
        for (index, options) in heardOptions.enumerated() {
            for option in options.dropFirst() where !option.trimmed.isEmpty {
                var words = best
                words[index] = option
                variants.append(words.joined(separator: " "))
            }
        }
        return variants
    }

    /// Numara beklenirken söylenen kısa cevap ("yedi", "soru yedi", "sıradaki")
    func numberReply() -> NumberReply? {
        return interpret { text -> NumberReply? in
            // Makul olmayan numara ("570") reddedilir: en iyi okuma buysa interpret alternatif okumalara bakar, yoksa numara yeniden sorulur
            if let heard = SpokenNumber.questionNumber(from: text, limit: numberLimit) { return .number(heard) }
            return SpokenNumber.wantsSequence(text) ? .sequence : nil
        }
    }

    /// Paragrafın soru numaraları: en iyi okumadan çıkan liste esas alınır; alternatif okuma yalnız o listeye numara EKLİYORSA (bir sayıyı
    /// kaçırmışsa) kullanılır, listeden numara düşüren ya da değiştiren okuma kabul edilmez.
    func bestNumbers(primary: [Int]) -> [Int] {
        var best = primary
        for variant in alternativeTexts() {
            guard let match = TriggerDetector.match(in: variant, words: PassageCommand.targetWords) else { continue }
            let candidate = SpokenNumber.list(from: match.question, limit: numberLimit)
            if candidate.count > best.count, Set(best).isSubset(of: Set(candidate)) {
                tlog("[duyulan] numara listesi alternatif okumayla tamamlandı: \(best) → \(candidate)")
                best = candidate
            }
        }
        return best
    }

    // MARK: Cevapları okuma

    /// Oturumun cevap dosyalarını baştan sona okur. Oturum açık kalır (aşama "konuşuyor", test sürüyor); okuma bitince rapor verilir ve
    /// "Devam, Tekrar ya da Bitir" sorulur. `mode`: "Devam" denirse hangi dinleme kipine dönüleceği.
    func beginReview(origin: ReviewOrigin, returnTo mode: ListenMode) async {
        reviewOrigin = origin
        reviewReturn = mode
        listenMode = .reviewMenu
        let files = sessionFolder.map { deps.library.answerFiles(in: $0) } ?? []
        guard !files.isEmpty else {
            tlog("[tekrar] okunacak cevap dosyası yok")
            auto.finishing = false
            if origin == .endRequest {
                await finishEnding()
            } else {
                await resumeAfterReview(prefix: Say.nothingToReplay + " ")
            }
            return
        }
        reviewCount = files.count
        let sectionEnding = origin == .endRequest && endScope == .section
        guard await speakNotice(sectionEnding ? Say.reviewStartSection(files.count) : Say.reviewStart(files.count, ending: origin == .endRequest)) else { return }
        guard phase == .speaking, !Task.isCancelled else { return }
        clearWarning("tekrar")
        reviewing = true
        watchedTicks = 0
        statusNote = "Cevap 1/\(files.count) okunuyor"
        tlog("[tekrar] \(files.count) cevap okunuyor (test sürüyor)")
        // Soru sayısına ulaşılıp sınav kendiliğinden kapanırken iki cevap arasında 2 sn boşluk verilir (kullanıcı kararı 2026-11-19)
        replay.start(files: files, gap: auto.finishing ? AutoStart.finalGap : settings.replayGap)
    }

    /// Okuma yarıda bırakılır (kesinti, iptal, oturum sonu): çalan dosya susar, bitiş bildirimleri yok sayılır
    func abortReview() {
        guard reviewing else { return }
        reviewing = false
        replay.stop(reason: "Okuma durduruldu.")
    }

    /// Bütün cevaplar çalındı: kaç sorunun cevabı okunduğu söylenir ve ne yapılacağı sorulur
    func reviewPlaybackEnded(failed: Int) {
        reviewing = false
        statusNote = ""
        let report = Say.reviewReport(count: reviewCount, failed: failed)
        tlog("[tekrar] \(report)")
        if auto.finishing {
            // Soru sayısına ulaşılmıştı: menü sorulmaz, sınav kapanır
            auto.finishing = false
            work = Task { [weak self] in await self?.finishEnding(prefix: report + " ") }
            return
        }
        work = Task { [weak self] in await self?.promptReviewMenu(report) }
    }

    /// Okuma çalınamadığı için durdu (kulaklık yok, art arda dosya hatası): söylenir ve yine de ne yapılacağı sorulur
    func reviewPlaybackStopped(_ reason: String) {
        reviewing = false
        statusNote = ""
        tlog("[tekrar] okuma durdu: \(reason)")
        warn("tekrar", reason)
        auto.finishing = false   // okuma çalınamadı: sınav kendiliğinden kapanmaz, ne yapılacağı sorulur
        auto.advancing = false   // sonraki bölüme de kendiliğinden geçilmez: "Bitir" denirse yeni bölüm sorulur
        work = Task { [weak self] in await self?.promptReviewMenu(Say.reviewStopped) }
    }

    func promptReviewMenu(_ report: String) async {
        reviewReminders = 0
        listenMode = .reviewMenu
        speechSealed = true   // okuma bitti: "Cevaplar okunuyor" anonsu değil, yalnız bu menü "bir daha söyle" ile tekrarlanır
        let sectionEnding = reviewOrigin == .endRequest && endScope == .section
        guard await speakNotice(report + " " + (sectionEnding ? Say.reviewMenuSection : Say.reviewMenu)) else { return }
        beginListening(mode: .reviewMenu)
    }

    /// "Devam", "Tekrar" ya da "Bitir" denince
    func fireReview() {
        guard let reply = heardReview(log: true) else { return }
        clearWarning("duyulan")
        closeListening()
        accumulator.clear()
        englishAccumulator.clear()
        liveText = ""
        liveEnglish = ""
        deps.recorder.reset()
        phase = .speaking
        switch reply {
        case .repeatAnswers:
            tlog("[komut] cevaplar yeniden okunacak")
            work = Task { [weak self] in
                guard let self = self else { return }
                await self.beginReview(origin: self.reviewOrigin, returnTo: self.reviewReturn)
            }
        case .continueTest:
            tlog("[komut] teste devam")
            work = Task { [weak self] in await self?.resumeAfterReview(prefix: "") }
        case .finishTest:
            // "Bölümü tamamla" ile gelindiyse yalnız bölüm biter; cevapları tekrarla menüsünden gelindiyse "Bitir" testi tamamlar
            let sectionEnding = reviewOrigin == .endRequest && endScope == .section
            tlog(sectionEnding ? "[komut] bölüm tamamlanıyor" : "[komut] test tamamlanıyor")
            work = Task { [weak self] in
                guard let self = self else { return }
                if sectionEnding { await self.finishEnding() } else { await self.completeTestByVoice() }
            }
        }
    }

    /// Menüde söz gelmedi ya da anlaşılmadı: bir kez hatırlatılır; yine olmazsa varsayılan uygulanır (bitirme isteğiyle gelindiyse test
    /// tamamlanır, yalnız tekrar istendiyse teste devam edilir)
    func reviewSilence() async {
        reviewReminders += 1
        if reviewReminders <= Timing.choiceReminderLimit {
            guard await speakNotice(Say.reask(Say.reviewMenuAgain, attempt: reviewReminders + 1)) else { return }
            beginListening(mode: .reviewMenu)
            return
        }
        clearWarning("duyulan")
        if reviewOrigin == .endRequest {
            tlog(endScope == .section ? "[komut] okuma sonrası seçenek söylenmedi; bölüm tamamlanıyor" : "[komut] okuma sonrası seçenek söylenmedi; test tamamlanıyor")
            await finishEnding(prefix: Say.reviewNoAnswer + " ")
        } else {
            tlog("[komut] okuma sonrası seçenek söylenmedi; test devam ediyor")
            await resumeAfterReview(prefix: Say.reviewNoAnswer + " ")
        }
    }

    /// Teste kalınan yerden devam: dönülecek kipe uygun cümleyi söyler ve dinlemeyi açar
    func resumeAfterReview(prefix: String) async {
        let target: ListenMode = (reviewReturn == .missingNumber || reviewReturn == .passageTargets) ? reviewReturn : .question
        listenMode = target
        let text: String
        switch target {
        case .missingNumber: text = Say.reviewBackToNumber
        case .passageTargets: text = Say.reviewBackToTargets
        default: text = cameraQuestionWillBeAsked ? Say.reviewBackToCamera : Say.reviewBackToQuestion
        }
        guard await speakNotice(prefix + text) else { return }
        beginListening(mode: target)
    }

    /// Sesle testi tamamlar: kısa bilgi verilir, test biter (cevaplar klasörde kalır)
    func completeTestByVoice(prefix: String = "") async {
        let count = answers.count
        let missing = unansweredNumbers().missing
        let missingNote = missing.isEmpty ? "" : "; cevapsız: " + QuestionComposer.listText(missing)
        tlog("[komut] test tamamlandı (\(count) cevap\(missingNote))")
        // Bölümlü sınavda her bölümün cevap sayısı söylenir; bölümsüzde eski cümle
        let report = sectionIndex > 0 ? Say.testCompletedSections(sectionAnswerCounts(), current: sectionIndex, missing: missing)
                                      : Say.testCompleted(count, missing: missing)
        await speakNotice(prefix + report)
        guard !Task.isCancelled else { return }
        endTest()
    }
}
