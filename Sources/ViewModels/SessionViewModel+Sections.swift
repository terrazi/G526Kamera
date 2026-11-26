import Foundation

/// Bitirme isteği: tüm test mi, yalnız şu anki bölüm mü
enum EndScope: Equatable {
    case test
    case section
}

/// Sınav bölümleri. Ayarlarda etkin bölümler ve soru sayıları girilir; sınav başlarken "Birinci bölüme başlıyorum" denir. "Bölümü tamamla"
/// bölümün cevaplarını okutur (testi bitirmeyle aynı onay ve menü), ardından "Yeni bir bölüm ile devam etmek ister misiniz, yoksa testi
/// tamamlayalım mı?" diye sorar. Her bölümün cevapları sınav klasörünün içindeki ayrı bir klasöre (bolum_1, bolum_2…) yazılır: iki bölümün
/// 5. sorusu birbirini ezmez. Bölüm ayarı kapalıysa hiçbir şey değişmez (tek parça sınav, cevaplar doğrudan sınav klasöründe).
extension SessionViewModel {
    /// Şu anki bölümün ayarlarda girilen soru sayısı; bölümsüz sınavda ya da sayı girilmemişse 0
    var sectionQuestionCount: Int {
        guard sectionIndex > 0, sectionIndex <= sectionPlan.count else { return 0 }
        return sectionPlan[sectionIndex - 1]
    }

    /// Kabul edilen en büyük soru numarası: bölümün soru sayısı girilmişse o, değilse 100. Bölümde olmayan bir numara ("570", 40 soruluk bölümde "45")
    /// soru numarası sayılmaz: alternatif okuma denenir, yoksa numara yeniden sorulur; yanlış numarayla kayıt yapılmaz.
    var numberLimit: Int {
        return sectionQuestionCount > 0 ? sectionQuestionCount : SpokenNumber.maxQuestionNumber
    }

    /// Günlükte ve "önceki kayıt" bilgisinde saklanan kayıt yeri: sınav klasörünün adı ve (bölümlüyse) bölüm sırası
    var locationName: String? {
        return examFolder.map { AnswerLibrary.locationName(exam: $0.lastPathComponent, section: sectionIndex) }
    }

    func saveLocation() {
        if let name = locationName { deps.journal.saveFolder(name) }
    }

    /// Cevapların yazılacağı yeri kurar. Bölüm klasörü açılamazsa hiçbir şey değişmez (hata fırlatılır).
    func place(exam: URL, section: Int) throws {
        let folder: URL
        if section > 0 {
            folder = try deps.library.sectionFolder(in: exam, section: section)
        } else {
            folder = exam
        }
        examFolder = exam
        sectionIndex = section
        sessionFolder = folder
    }

    // MARK: Bölümü / testi bitirme

    /// Bitirme isteği sonuçlandı (cevaplar okundu ya da okunacak cevap yok): isteğe göre bölüm ya da test tamamlanır
    func finishEnding(prefix: String = "") async {
        if endScope == .section, sectionIndex > 0 {
            await completeSectionByVoice(prefix: prefix)
        } else {
            await completeTestByVoice(prefix: prefix)
        }
    }

    /// Bölüm bitti: kaç cevap kaydedildiği ve cevapsız sorular söylenir; sonra yeni bölüm mü, testi tamamlama mı sorulur. Son bölümse test tamamlanır.
    func completeSectionByVoice(prefix: String = "") async {
        let section = sectionIndex
        let found = unansweredNumbers()
        tlog("[komut] \(section). bölüm tamamlandı (\(answers.count) cevap" + (found.missing.isEmpty ? "" : "; cevapsız: " + Say.compactList(found.missing)) + ")")
        endScope = .test
        let advance = auto.advancing
        auto.advancing = false
        guard section < sectionPlan.count else {
            // Son bölüm: soru sormadan test tamamlanır
            await completeTestByVoice(prefix: prefix + (sectionPlan.count > 1 ? Say.allSectionsDone + " " : ""))
            return
        }
        if advance {
            // Otomatik zamanlı başlatma (kullanıcı kararı 2026-11-26): bölümün sonuna gelindi; "yeni bölüm mü?" sorulmaz (mikrofondan talimat beklenmez),
            // bölümün durumu söylenir ve sonraki bölüme geçilir. Yeni bölümün ilk taraması başlangıç sorusu kamerada görülünce başlar
            tlog("[otomatik] \(section). bölüm tamamlandı; \(section + 1). bölüme kendiliğinden geçiliyor")
            autoResetForSection()
            await beginNextSection(prefix: prefix + Say.sectionCompleted(section, answers: answers.count, missing: found.missing) + " ")
            return
        }
        sectionReminders = 0
        listenMode = .nextSectionChoice
        guard await speakNotice(prefix + Say.sectionCompleted(section, answers: answers.count, missing: found.missing) + " " + Say.askNextSection(section + 1)) else { return }
        beginListening(mode: .nextSectionChoice)
    }

    /// "Yeni bir bölüm ile devam etmek ister misiniz, yoksa testi tamamlayalım mı?" sorusuna cevap
    func fireNextSection() {
        guard let reply = heardNextSection(log: true) else { return }
        clearWarning("duyulan")
        closeListening()
        accumulator.clear()
        englishAccumulator.clear()
        liveText = ""
        liveEnglish = ""
        deps.recorder.reset()
        phase = .speaking
        switch reply {
        case .newSection:
            tlog("[komut] yeni bölüme geçiliyor")
            work = Task { [weak self] in await self?.beginNextSection(prefix: "") }
        case .finishTest:
            tlog("[komut] bölümler bitmeden test tamamlanıyor")
            work = Task { [weak self] in await self?.completeTestByVoice() }
        }
    }

    /// Cevap gelmedi ya da anlaşılmadı: bir kez yeniden sorulur; yine olmazsa yeni bölüme geçilir (testi bitirmek geri alınamaz, bölüme geçmek alınabilir)
    func nextSectionSilence() async {
        closeListening()
        phase = .speaking
        sectionReminders += 1
        if sectionReminders <= Timing.choiceReminderLimit {
            guard await speakNotice(Say.reask(Say.askNextSectionAgain(sectionIndex + 1), attempt: sectionReminders + 1)) else { return }
            beginListening(mode: .nextSectionChoice)
        } else {
            tlog("[komut] yeni bölüm sorusu cevapsız kaldı; yeni bölüme geçiliyor")
            clearWarning("duyulan")
            await beginNextSection(prefix: Say.nextSectionDefault + " ")
        }
    }

    /// Bir sonraki bölümü başlatır: yeni bölüm klasörü, numara 1, boş cevap listesi
    func beginNextSection(prefix: String) async {
        guard let exam = examFolder else {
            await completeTestByVoice(prefix: prefix)
            return
        }
        let next = sectionIndex + 1
        do {
            try place(exam: exam, section: next)
        } catch {
            warn("klasor", "Bölüm klasörü açılamadı: \(error.localizedDescription)")
            await completeTestByVoice(prefix: prefix + Say.sectionFolderFailed + " ")
            return
        }
        sectionReminders = 0
        endScope = .test
        nextNumber = 1
        answers = []
        answerOrder = []
        passage = nil
        passageDraft = nil
        heldQuestion = nil
        unheard = nil
        deps.journal.saveNextNumber(1)
        deps.journal.savePending(nil)
        saveLocation()
        listenMode = .question
        tlog("[bölüm] \(next). bölüme başlandı (\(sectionQuestionCount) soru)")
        armCameraOffer()   // yeni bölümün ilk sorusu için de kamera sorulur
        let text = prefix + Say.sectionStart(next, questions: sectionQuestionCount) + (cameraQuestionWillBeAsked ? "" : " İlk soruyu okuyabilirsiniz.")
        guard await speakNotice(text) else { return }
        beginListening(mode: .question)
    }

    /// Bölüm başına kayıtlı cevap sayısı (şu anki bölüm için bellekteki liste, öncekiler için klasör)
    func sectionAnswerCounts() -> [Int] {
        guard sectionIndex > 0, let exam = examFolder else { return [] }
        return (1...sectionIndex).map { number in
            if number == sectionIndex { return answers.count }
            guard let folder = deps.library.existingSectionFolder(in: exam, section: number) else { return 0 }
            return deps.library.answerCount(in: folder)
        }
    }
}
