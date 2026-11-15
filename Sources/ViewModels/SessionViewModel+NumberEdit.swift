import Foundation

/// "Kayıt sil" (istenen soruyu sil) ve "soru numarası düzelt" komutlarının adımları. Numara beklenirken dinleme kipi `.missingNumber` kullanılır
/// (bekleyen soru yoksa); bölüm ve numara söylenir, ikisi tekrarlanıp onay alındıktan sonra işlem yapılır.
struct NumberEdit: Equatable {
    enum Kind: Equatable {
        case delete
        case renumber
    }

    enum Step: Equatable {
        case section      // hangi bölümdeki soru (yalnız başka bölümlerde de kayıt varsa sorulur)
        case number       // silinecek / düzeltilecek sorunun numarası
        case newNumber    // yeni numara (yalnız düzeltmede)
    }

    var kind: Kind
    var step: Step
    /// Kaydın bölümü (0: bölümsüz sınav); işlem yalnız bu bölümün klasöründe yapılır
    var section: Int
    /// Düzeltilecek sorunun eski numarası
    var from = 0
}

/// Onay bekleyen numara değişikliği
struct PendingRenumber: Equatable {
    var section: Int
    var from: Int
    var to: Int
}

enum EditReply: Equatable {
    case number(Int)
    case here
    case cancel
}

enum EditWords {
    static let cancel: Set<String> = ["vazgec", "vazgectim", "vazgecelim", "iptal", "birak"]
    /// "Bu bölüm", "şu anki", "mevcut": bölümlü sınavda şu anki bölüm
    static let here: Set<String> = ["bu", "su", "simdiki", "suanki", "mevcut", "burasi", "buradaki", "ayni"]
    /// "Birinci bölüm", "ikinci bölümdeki": bölüm sırasını söyleyen cümlede numaranın yanındaki sözcük
    static let sectionWords: Set<String> = ["bolum", "bolumu", "bolumun", "bolumde", "bolumdeki", "bolume", "bolumden"]
}

/// Güvenlik: işlem YALNIZ şu anki sınav oturumunda (`examFolder`) ve seçilen bölümün klasöründe (bölümsüz sınavda sınav klasöründe) yapılır. Başka bir
/// oturuma (önceki sınavlara) ve aynı numaralı başka bölüm kayıtlarına dokunulmaz. Onaydan önce bölüm ve numara tekrarlanır.
extension SessionViewModel {
    // MARK: Kayıt yeri

    /// Bölümün kayıt klasörü: şu anki bölümse oturum klasörü, değilse AYNI sınavın o bölüm klasörü (yoksa nil)
    func editFolder(section: Int) -> URL? {
        if section == sectionIndex { return sessionFolder }
        guard section > 0, let exam = examFolder else { return nil }
        return deps.library.existingSectionFolder(in: exam, section: section)
    }

    /// Bölümde kayıtlı soru numaraları (bellekteki cevaplar, ses dosyaları ve düz yazı satırları)
    func recordedNumbers(section: Int) -> Set<Int> {
        var numbers = Set<Int>()
        if section == sectionIndex { for record in answers { numbers.insert(record.number) } }
        guard let folder = editFolder(section: section) else { return numbers }
        for file in deps.library.directAnswerFiles(in: folder) {
            if let number = AnswerLibrary.questionNumber(fromFileName: file.lastPathComponent) { numbers.insert(number) }
        }
        for record in deps.library.transcriptRecords(in: folder) { numbers.insert(record.number) }
        return numbers
    }

    /// Şu anki bölümden başka, içinde kayıt olan bölümler (aynı sınavın bölüm klasörlerinden)
    var otherSectionsWithRecords: [Int] {
        guard sectionIndex > 0, let exam = examFolder else { return [] }
        return deps.library.sectionFolders(in: exam).compactMap { url -> Int? in
            guard let number = AnswerLibrary.sectionNumber(fromFolderName: url.lastPathComponent), number != sectionIndex,
                  deps.library.answerCount(in: url) > 0 else { return nil }
            return number
        }
    }

    /// Bölümde kabul edilen en büyük soru numarası (bölümün soru sayısı girilmişse o, değilse 100)
    func editLimit(section: Int) -> Int {
        guard section > 0, section <= sectionPlan.count, sectionPlan[section - 1] > 0 else { return SpokenNumber.maxQuestionNumber }
        return sectionPlan[section - 1]
    }

    // MARK: Başlatma ve adımlar

    func editPrompt(_ edit: NumberEdit) -> String {
        switch edit.step {
        case .section: return Say.askWhichSection(current: sectionIndex)
        case .number: return edit.kind == .delete ? Say.askDeleteNumber(section: edit.section) : Say.askRenumberFrom(section: edit.section)
        case .newNumber: return Say.askRenumberTo(from: edit.from)
        }
    }

    /// Söylenen sözden bu adımın beklediği cevap: numara, "bu bölüm" ya da vazgeçme
    func editReply(for edit: NumberEdit) -> EditReply? {
        let limit = edit.step == .section ? max(sectionPlan.count, sectionIndex) : editLimit(section: edit.section)
        return interpret { text -> EditReply? in
            let words = SpokenWords.of(text)
            if words.contains(where: { SpokenWords.exactly($0, EditWords.cancel) }) { return EditReply.cancel }
            if edit.step == .section, words.contains(where: { SpokenWords.exactly($0, EditWords.here) }) { return EditReply.here }
            // Bölüm sırası "birinci bölüm" diye söylenir: "bölüm" sözcüğü atılıp numara okunur
            let spoken = edit.step == .section ? words.filter { !SpokenWords.exactly($0, EditWords.sectionWords) }.joined(separator: " ") : text
            if let number = SpokenNumber.questionNumber(from: spoken, limit: limit) { return EditReply.number(number) }
            return nil
        }
    }

    /// Numara beklenirken söylenen söz bir numara mı (soru numarasında ya da düzeltme / silme adımında)
    func numberHeard() -> Bool {
        if let edit = numberEdit { return editReply(for: edit) != nil }
        return numberReply() != nil
    }

    /// "Kayıt sil" / "soru numarası düzelt" duyuldu: kayıt yoksa söylenir; varsa (gerekirse önce bölüm) numara sorulur
    func startNumberEdit(_ kind: NumberEdit.Kind) {
        let name = kind == .delete ? "kayıt sil (istenen soru)" : "soru numarası düzelt"
        let others = otherSectionsWithRecords
        guard !recordedNumbers(section: sectionIndex).isEmpty || !others.isEmpty else {
            tlog("[komut] sesli komut: \(name); kayıtlı soru yok")
            work = Task { [weak self] in
                guard let self = self, await self.speakNotice(Say.nothingToEdit) else { return }
                self.beginListening(mode: .question)
            }
            return
        }
        var edit = NumberEdit(kind: kind, step: .number, section: sectionIndex)
        if !others.isEmpty { edit.step = .section }   // başka bölümlerde de kayıt var: hangi bölüm olduğu sorulur (yanlış bölümde işlem yapılmasın)
        numberEdit = edit
        numberReminders = 0
        tlog("[komut] sesli komut: \(name); \(edit.step == .section ? "önce bölüm" : "numara") sorulacak")
        let first = edit   // Task içinde değişebilen bir var yakalanmaz
        work = Task { [weak self] in
            guard let self = self, await self.speakNotice(self.editPrompt(first)) else { return }
            self.beginListening(mode: .missingNumber)
        }
    }

    /// Söylenen numara / bölüm alındı
    func fireEditNumber(_ edit: NumberEdit) {
        guard let reply = editReply(for: edit) else { return }
        closeListening()
        accumulator.clear()
        englishAccumulator.clear()
        liveText = ""
        liveEnglish = ""
        deps.recorder.reset()
        phase = .speaking
        clearWarning("numara")
        clearWarning("duyulan")
        numberReminders = 0
        tlog("[komut] \(edit.kind == .delete ? "silme" : "numara düzeltme"): \(edit.step) adımında \(reply) duyuldu")
        work = Task { [weak self] in await self?.advanceNumberEdit(edit, reply: reply) }
    }

    func advanceNumberEdit(_ current: NumberEdit, reply: EditReply) async {
        var edit = current
        if reply == .cancel {
            await cancelNumberEdit()
            return
        }
        switch edit.step {
        case .section:
            let chosen: Int
            switch reply {
            case .here: chosen = sectionIndex
            case .number(let number): chosen = number
            case .cancel: return
            }
            guard chosen == sectionIndex || otherSectionsWithRecords.contains(chosen) else {
                await editReprompt(edit, lead: Say.noRecordsInSection(chosen).replacingOccurrences(of: ".", with: ""))
                return
            }
            guard !recordedNumbers(section: chosen).isEmpty else {
                await editReprompt(edit, lead: Say.noRecordsInSection(chosen).replacingOccurrences(of: ".", with: ""))
                return
            }
            edit.section = chosen
            edit.step = .number
            numberEdit = edit
            guard await speakNotice(editPrompt(edit)) else { return }
            beginListening(mode: .missingNumber)
        case .number:
            guard case .number(let number) = reply else {
                await editReprompt(edit, heard: true)
                return
            }
            guard recordedNumbers(section: edit.section).contains(number) else {
                await editReprompt(edit, lead: Say.noSuchRecord(number, section: edit.section).replacingOccurrences(of: ".", with: ""))
                return
            }
            if edit.kind == .delete {
                numberEdit = nil
                pendingDelete = number
                pendingDeleteChosen = true
                pendingEditSection = edit.section
                endReminders = 0
                endReturn = .question
                tlog("[komut] istenen soruyu sil: \(edit.section > 0 ? "\(edit.section). bölüm, " : "")soru \(number); onay isteniyor")
                guard await speakNotice(Say.confirmDeleteLast(number, section: edit.section)) else { return }
                beginListening(mode: .confirmEnd)
            } else {
                edit.from = number
                edit.step = .newNumber
                numberEdit = edit
                guard await speakNotice(editPrompt(edit)) else { return }
                beginListening(mode: .missingNumber)
            }
        case .newNumber:
            guard case .number(let target) = reply else {
                await editReprompt(edit, heard: true)
                return
            }
            guard target != edit.from else {
                await editReprompt(edit, lead: Say.sameNumber(target).replacingOccurrences(of: ".", with: ""))
                return
            }
            numberEdit = nil
            let pending = PendingRenumber(section: edit.section, from: edit.from, to: target)
            pendingRenumber = pending
            endReminders = 0
            endReturn = .question
            let overwrite = recordedNumbers(section: edit.section).contains(target)
            tlog("[komut] numara düzelt: \(edit.section > 0 ? "\(edit.section). bölüm, " : "")soru \(edit.from) → \(target)\(overwrite ? " (hedef numaralı kayıt silinecek)" : ""); onay isteniyor")
            guard await speakNotice(Say.confirmRenumber(from: edit.from, to: target, section: edit.section, overwrite: overwrite)) else { return }
            beginListening(mode: .confirmEnd)
        }
    }

    /// Numara / bölüm söylenmedi, anlaşılmadı ya da kayıt yok: ikinci ve üçüncü soruşta "ikinci / üçüncü defa soruyorum" denir; üçüncüde de olmazsa
    /// işlem bırakılır (hiçbir kayıt değişmez)
    func editReprompt(_ edit: NumberEdit, heard: Bool = false, lead: String? = nil) async {
        closeListening()
        phase = .speaking
        numberReminders += 1
        guard numberReminders <= Timing.numberReminderLimit else {
            tlog("[komut] numara / bölüm \(Timing.numberReminderLimit + 1) kez alınamadı; işlem bırakıldı")
            clearWarning("duyulan")
            numberEdit = nil
            guard await speakNotice(Say.editGivenUp) else { return }
            beginListening(mode: .question)
            return
        }
        let opening = lead ?? (heard ? "Anlayamadım" : "Cevap vermediniz")
        guard await speakNotice(Say.reask(Say.editAgain(editPrompt(edit), lead: opening), attempt: numberReminders + 1)) else { return }
        beginListening(mode: .missingNumber)
    }

    /// "Vazgeç" / "soruyu iptal et": hiçbir şey değişmeden işlem bırakılır
    func cancelNumberEdit() async {
        closeListening()
        phase = .speaking
        numberEdit = nil
        pendingRenumber = nil
        pendingDelete = nil
        pendingDeleteChosen = false
        tlog("[komut] numara düzeltme / silme bırakıldı; hiçbir kayıt değişmedi")
        guard await speakNotice(Say.editCancelled) else { return }
        beginListening(mode: .question)
    }

    // MARK: İstenen soruyu silme

    /// "Soru N kaydı silinsin mi?" onayı (kullanıcının seçtiği soru): evet siler, hayır silmez
    func confirmChosenDelete(_ number: Int, section: Int, reply: SpokenReply.YesNo) {
        switch reply {
        case .yes:
            tlog("[komut] istenen soruyu silme onaylandı (\(section > 0 ? "\(section). bölüm, " : "")soru \(number))")
            let reread = deleteChosenRecord(number, section: section)
            if reread { armCameraOffer() }   // silinen soru yeniden okunacak: kamera açıksa o soru için yeniden sorulur
            let notice = Say.chosenQuestionDeleted(number, section: section, reread: reread, cameraNext: cameraQuestionWillBeAsked)
            work = Task { [weak self] in
                guard let self = self, await self.speakNotice(notice) else { return }
                self.beginListening(mode: .question)
            }
        case .no:
            tlog("[komut] istenen soruyu silmekten vazgeçildi (\(section > 0 ? "\(section). bölüm, " : "")soru \(number)); hiçbir şey silinmedi")
            let notice = cameraQuestionWillBeAsked ? Say.deleteCancelledCamera : Say.deleteCancelled
            work = Task { [weak self] in
                guard let self = self, await self.speakNotice(notice) else { return }
                self.beginListening(mode: .question)
            }
        }
    }

    /// Kaydı seçilen bölümde siler. Şu anki bölümse bellek, ana ekran ve dosyalar; başka bölümse yalnız o bölüm klasöründeki ses dosyası ve düz yazı
    /// satırı. Dönen değer: sıradaki numara silinen soruya döndü (soru yeniden okunur).
    @discardableResult
    func deleteChosenRecord(_ number: Int, section: Int) -> Bool {
        if section == sectionIndex {
            deleteRecordedQuestion(number, clearPending: false)
            return nextNumber == number
        }
        guard let folder = editFolder(section: section) else { return false }
        deps.library.removeExisting(question: number, in: folder)
        if !deps.library.removeTranscript(number: number, in: folder) { warn("yazi", Say.transcriptFailed) }
        refreshReplayAvailability()
        tlog("[kayıt] \(section). bölüm, soru \(number) silindi (başka bölüm: ses dosyası ve düz yazı satırı)")
        return false
    }

    // MARK: Soru numarası düzeltme

    /// "Soru 7, soru 8 olarak değiştirilsin mi?" onayı: evet değiştirir, hayır değiştirmez
    func confirmRenumber(_ renumber: PendingRenumber, reply: SpokenReply.YesNo) {
        pendingRenumber = nil
        switch reply {
        case .yes:
            tlog("[komut] numara değiştirme onaylandı (\(renumber.section > 0 ? "\(renumber.section). bölüm, " : "")soru \(renumber.from) → \(renumber.to))")
            let done = renumberRecord(renumber)
            let notice = done ? Say.questionRenumbered(from: renumber.from, to: renumber.to, section: renumber.section, cameraNext: cameraQuestionWillBeAsked)
                : Say.renumberFailed
            work = Task { [weak self] in
                guard let self = self, await self.speakNotice(notice) else { return }
                self.beginListening(mode: .question)
            }
        case .no:
            tlog("[komut] numara değiştirmekten vazgeçildi (soru \(renumber.from) → \(renumber.to)); hiçbir şey değişmedi")
            let notice = Say.renumberCancelled(cameraNext: cameraQuestionWillBeAsked)
            work = Task { [weak self] in
                guard let self = self, await self.speakNotice(notice) else { return }
                self.beginListening(mode: .question)
            }
        }
    }

    /// Onay cevapsız kaldı: ikinci ve üçüncü soruşta yeniden sorulur; yine olmazsa hiçbir şey değiştirilmez
    func renumberSilence(_ renumber: PendingRenumber) async {
        if endReminders <= Timing.choiceReminderLimit {
            let again = Say.confirmRenumberAgain(from: renumber.from, to: renumber.to, section: renumber.section)
            guard await speakNotice(Say.reask(again, attempt: endReminders + 1)) else { return }
            beginListening(mode: .confirmEnd)
        } else {
            tlog("[komut] numara değiştirme sorusu cevapsız kaldı; hiçbir şey değişmedi")
            clearWarning("duyulan")
            pendingRenumber = nil
            guard await speakNotice(Say.renumberCancelled(cameraNext: cameraQuestionWillBeAsked)) else { return }
            beginListening(mode: .question)
        }
    }

    /// "Soru 7, ..." cümlesinin numarası değişir; cümle bu biçimde değilse başına yeni numara eklenir
    func renumberedLine(_ spoken: String, from: Int, to: Int) -> String {
        let prefix = "Soru \(from),"
        if spoken.hasPrefix(prefix) { return "Soru \(to)," + String(spoken.dropFirst(prefix.count)) }
        return "Soru \(to), " + spoken
    }

    /// Kaydın numarasını seçilen bölümün klasöründe değiştirir (ses dosyaları, düz yazı satırı ve şu anki bölümse bellek ve ana ekran).
    /// Yeni numaralı eski kayıt (varsa) silinir. Dosyalar taşınamazsa hiçbir şey değişmez ve false döner.
    func renumberRecord(_ change: PendingRenumber) -> Bool {
        guard let folder = editFolder(section: change.section) else { return false }
        let current = change.section == sectionIndex
        let existingLine: String? = (current ? answers.first(where: { $0.number == change.from })?.spoken : nil)
            ?? deps.library.transcriptRecords(in: folder).first(where: { $0.number == change.from })?.spoken
        guard deps.library.renumberFiles(from: change.from, to: change.to, in: folder) else {
            warn("yazi", Say.renumberFailed)
            return false
        }
        if let line = existingLine {
            if !deps.library.renumberTranscript(from: change.from, to: change.to, line: renumberedLine(line, from: change.from, to: change.to), in: folder) {
                warn("yazi", Say.transcriptFailed)
            }
        } else if !deps.library.removeTranscript(number: change.to, in: folder) {
            warn("yazi", Say.transcriptFailed)   // eski kayıt silinirken yeni numaranın bayat satırı da gider
        }
        if current {
            if let record = answers.first(where: { $0.number == change.from }) {
                let moved = AnswerRecord(number: change.to, option: record.option, text: record.text,
                                         spoken: renumberedLine(record.spoken, from: change.from, to: change.to))
                answers.removeAll { $0.number == change.from || $0.number == change.to }
                answers.append(moved)
                answers.sort { $0.number < $1.number }
            } else {
                answers.removeAll { $0.number == change.to }
            }
            answerOrder = answerOrder.filter { $0 != change.to }.map { $0 == change.from ? change.to : $0 }
            questions.removeAll { entry in
                guard entry.number == change.to else { return false }
                if case .answered = entry.state { return true }
                return false
            }
            for index in questions.indices where questions[index].number == change.from {
                if case .answered(let spoken) = questions[index].state {
                    questions[index].number = change.to
                    questions[index].state = .answered(renumberedLine(spoken, from: change.from, to: change.to))
                }
            }
            if let heard = unheard {
                if heard.number == change.to {
                    unheard = nil
                } else if heard.number == change.from {
                    unheard = AnswerRecord(number: change.to, option: heard.option, text: heard.text,
                                           spoken: renumberedLine(heard.spoken, from: change.from, to: change.to))
                }
            }
            if nextNumber == change.from + 1 {
                // En son kaydedilen sorunun numarası düzeltildi: sıradaki numara yeni numaradan sonraki olur
                nextNumber = change.to + 1
                deps.journal.saveNextNumber(nextNumber)
                carry?.nextNumber = nextNumber
            }
        }
        refreshReplayAvailability()
        tlog("[kayıt] \(change.section > 0 ? "\(change.section). bölüm, " : "")soru \(change.from) numarası \(change.to) olarak değiştirildi (ses dosyaları, düz yazı satırı\(current ? ", bellek ve ana ekran" : ""))")
        return true
    }
}
