import Foundation

extension ListenHints {
    /// Dinleme kipine uygun ipucu listesi
    static func hints(for mode: ListenMode) -> ListenHints {
        switch mode {
        case .question, .passage: return .dictation
        case .confirmEnd, .startChoice, .reviewMenu, .cameraChoice, .passageCameraChoice, .captureKindChoice, .nextSectionChoice: return .choice
        case .missingNumber: return .number
        case .passageTargets: return .targets
        }
    }
}

/// Konuşmayı anlama: sözlerin sınırları, komutun yalnız son sözden aranması ve anlaşılmayan sözde susmak yerine sesli geri bildirim.
///
/// Neden: tanıyıcı eski bir komut denemesini ("testi bit") metinde bırakınca sonraki doğru deneme ("testi bitir") metnin tamamı
/// "testi bit testi bitir" olarak okunur ve hiçbir zaman komut olarak tanınmazdı; kullanıcı art arda tekrar etmek zorunda kalırdı.
extension SessionViewModel {
    func wordCount(_ text: String) -> Int {
        return text.split(whereSeparator: { $0.isWhitespace }).count
    }

    // MARK: Söz sınırları

    /// Metin değişti: önceki sözden sonra `Timing.utteranceGap` kadar sessizlik geçtiyse bu yeni bir sözdür
    func noteUtterance() {
        if gapPassed {
            utteranceStart = settledCount
            if utteranceStart > 0, !utteranceStarts.contains(utteranceStart) { utteranceStarts.append(utteranceStart) }
            gapPassed = false
        }
        gapTask?.cancel()
        gapTask = deps.scheduler.after(Timing.utteranceGap) { [weak self] in
            guard let self = self else { return }
            self.settledCount = self.wordCount(self.accumulator.text)
            self.gapPassed = true
        }
    }

    /// Dinleme yeniden kuruldu ama metin korunuyor: sonraki söz eldeki metnin arkasında yeni bir sözdür
    func beginNewUtterance() {
        gapTask?.cancel()
        gapTask = nil
        settledCount = wordCount(accumulator.text)
        gapPassed = true
    }

    /// Metin sıfırlandı: söz sınırları da sıfırlanır
    func resetUtterances() {
        gapTask?.cancel()
        gapTask = nil
        utteranceStart = 0
        utteranceStarts = []
        settledCount = 0
        gapPassed = false
    }

    /// Son söz (metnin son sessizlikten sonraki kısmı)
    func currentUtterance() -> String {
        let tokens = accumulator.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let start = utteranceStart < tokens.count ? utteranceStart : 0
        return tokens[start...].joined(separator: " ")
    }

    // MARK: Komut

    /// Söylenen komut: önce metnin tamamı (tanıyıcının alternatif okumalarıyla), olmazsa yalnız son söz. Önceki anlaşılmayan söz engel olmaz.
    func spokenCommand() -> VoiceCommand? {
        if let command = interpret(VoiceCommand.parseLenient) { return command }
        return tailCommand(of: accumulator.text)
    }

    /// Tetikleyiciden ("Cevapla") önceki metin komut mu
    func commandIn(_ text: String) -> VoiceCommand? {
        if let command = VoiceCommand.parseLenient(text) { return command }
        return tailCommand(of: text)
    }

    /// Yalnız son söz komutsa onu verir. Tek sözcüklük son söz ("tekrar") ancak öncesi de komut denemesiyse sayılır: soru ortasındaki bir
    /// duraklamadan sonra gelen tek sözcük yanlışlıkla komut olmasın.
    private func tailCommand(of text: String) -> VoiceCommand? {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard utteranceStart > 0, utteranceStart < tokens.count else { return nil }
        let tail = tokens[utteranceStart...]
        let before = tokens[..<utteranceStart].joined(separator: " ")
        guard tail.count >= 2 || CommandAttempt.looksLike(before) else { return nil }
        return VoiceCommand.parseLenient(tail.joined(separator: " "))
    }

    // MARK: "Anlamadım / bir daha söyle": programın son sözünü yeniden söyleme

    /// Söylenen anonsu "son söz" grubuna ekler (en çok iki anons). Aynı cümleyi içeren yeni anons ("Anlayamadım. Bu soruyu kamera ile…") eskisinin yerini alır.
    func rememberSpeech(_ text: String) {
        let spoken = text.trimmed
        guard !spoken.isEmpty else { return }
        if speechSealed {
            recentSpeech.removeAll()
            speechSealed = false
        }
        recentSpeech.removeAll { spoken.contains($0) }
        recentSpeech.append(spoken)
        if recentSpeech.count > 2 { recentSpeech.removeFirst(recentSpeech.count - 2) }
    }

    /// Kullanıcı programın son sözünü yeniden söylemesini istiyor mu. Her kipte geçerlidir; paragraf okunurken yalnız söz tek başına komutsa
    /// (paragraf metnine karışmasın). Tek başına "tekrarla" / "tekrar et" (V3: son cevabı tekrarlar) soru ve kamera sorusunda öyle kalır;
    /// onay, numara, paragraf numarası ve başlangıç sorusunda programın sözünü tekrarlatır. Menüde "Tekrar" bir seçenektir, burada sayılmaz.
    func repeatSpeechRequested() -> Bool {
        let command = listenMode == .passage ? interpret(VoiceCommand.parseLenient) : spokenCommand()
        switch command {
        case .repeatSpeech?:
            return true
        case .repeatLast?:
            return [ListenMode.confirmEnd, .missingNumber, .passageTargets, .startChoice].contains(listenMode)
        default:
            return false
        }
    }

    /// "Anlamadım", "duyamadım", "bir daha söyle"… söylendi: kısa süre sabit kalırsa program son sözünü yeniden söyler
    func fireRepeatSpeech() {
        confirmTask = nil
        guard phase == .listening, repeatSpeechRequested() else { return }
        var keep = false
        if listenMode == .question {
            // Soru okunurken araya girildiyse yalnız komut sözü atılır, okunan soru metni korunur
            let whole = interpret(VoiceCommand.parseLenient) == .repeatSpeech
            if !whole, utteranceStart > 0, utteranceStart < wordCount(accumulator.text) {
                accumulator.dropWords(from: utteranceStart)
                liveText = accumulator.text
                keep = true
            }
        }
        repeatSpeech(keepPartial: keep)
    }

    /// Programın son sözü (en çok son iki anons) aynen yeniden söylenir; sonra aynı kipte dinlemeye dönülur. Cevap sayılmaz, hatırlatma sayaçlarını
    /// ve bekleyen işleri (tutulan soru, paragraf taslağı) değiştirmez. Söylenecek anons yoksa son cevap, o da yoksa bunu söyler.
    func repeatSpeech(keepPartial: Bool) {
        let mode = listenMode
        closeListening()
        attemptFails = 0
        clearWarning("duyulan")
        if !keepPartial {
            accumulator.clear()
            englishAccumulator.clear()
            liveText = ""
            liveEnglish = ""
            deps.recorder.reset()
        }
        phase = .speaking
        let spoken = recentSpeech.joined(separator: " ")
        tlog("[komut] sesli komut: programın son sözü yeniden söyleniyor (\(mode))")
        work = Task { [weak self] in
            guard let self = self else { return }
            let text = spoken.isEmpty ? (self.answers.last?.spoken ?? Say.nothingToRepeat) : spoken
            guard await self.speakNotice(text, remember: false) else { return }
            self.beginListening(mode: mode, keepPartial: keepPartial)
        }
    }

    // MARK: Bilgi ve düzeltme komutları

    /// "Yardım", "ne duydun", "son cümleyi sil", "durum", "cevapsız soruları söyle" söylendi mi. Her kipte geçerlidir; paragraf okunurken yalnız
    /// söz tek başına komutsa (paragraf metnine karışmasın)
    func infoRequested() -> VoiceCommand? {
        let command = listenMode == .passage ? interpret(VoiceCommand.parseLenient) : spokenCommand()
        guard let found = command, found.isInfo else { return nil }
        return found
    }

    /// Komut söylendi, kısa süre sabit kaldı: soru okunurken araya girildiyse yalnız komut sözü atılır, okunan soru metni korunur
    func fireInfoCommand() {
        confirmTask = nil
        guard phase == .listening, let command = infoRequested() else { return }
        var question = ""
        if listenMode == .question {
            let whole = interpret(VoiceCommand.parseLenient) == command
            if !whole, utteranceStart > 0, utteranceStart < wordCount(accumulator.text) {
                accumulator.dropWords(from: utteranceStart)
                liveText = accumulator.text
                question = accumulator.text
            }
        }
        performInfo(command, question: question, keepText: !question.isEmpty)
    }

    /// Komutu uygular, yaptığını ya da yapamadığını söyler ve aynı kipte dinlemeye döner. `question`: komuttan önceki soru metni (yalnız soru
    /// dinlenirken); `keepText`: bu metin korunarak dinlenir. Cevap sayılmaz, sayaçlar ve bekleyen işler (tutulan soru, paragraf taslağı) değişmez.
    func performInfo(_ command: VoiceCommand, question: String, keepText: Bool) {
        let mode = listenMode
        if command == .camera(.trial) {
            performTrial(mode: mode)   // uzun iş (bir oturum süresi): bilgi komutu gibi kısa söylenip dinlemeye dönülmez (bkz. `SessionViewModel+Trial`)
            return
        }
        closeListening()
        attemptFails = 0
        clearWarning("duyulan")
        let live = command.isLive
        let reply = live ? "" : infoReply(command, mode: mode, question: question)
        let keep = keepText && !accumulator.isEmpty
        if !keep {
            accumulator.clear()
            englishAccumulator.clear()
            liveText = ""
            liveEnglish = ""
            deps.recorder.reset()
        }
        phase = .speaking
        if !live { tlog("[komut] sesli komut: \(command): \(reply)") }
        work = Task { [weak self] in
            guard let self = self else { return }
            var answer = LiveReply(text: reply)
            if live {
                answer = await self.liveReply(command, mode: mode)
                tlog("[komut] sesli komut: \(command): \(answer.text)")
            }
            guard await self.speakNotice(answer.text) else { return }
            self.beginListening(mode: mode, keepPartial: keep)
        }
    }

    /// Söylenecek cümle: komutun yapıldığı ya da yapılamadığı. "Son cümleyi sil" soru metnini de değiştirir.
    private func infoReply(_ command: VoiceCommand, mode: ListenMode, question: String) -> String {
        switch command {
        case .help:
            switch mode {
            case .question, .passage:
                return Say.helpCommands
            case .cameraChoice, .passageCameraChoice:
                return [Say.helpCommands, recentSpeech.last ?? ""].filter { !$0.isEmpty }.joined(separator: " ")   // kamera sorusu da yeniden sorulur
            default:
                return recentSpeech.last ?? Say.helpCommands   // evet/hayır, numara, menü: sorunun kendisi ne söylenmesi gerektiğini anlatır
            }
        case .whatHeard:
            guard mode == .question else { return Say.noQuestionText }
            return question.isEmpty ? Say.nothingHeard : Say.heard(question)
        case .deleteLast:
            return deleteLastSentence(mode: mode, question: question)
        case .status:
            let status = Say.status(answers: answers.count, next: nextNumber, headphones: routeVerdict?.headphonesOK, internet: netPulse,
                                    battery: deps.battery.percent, charging: deps.battery.charging)
            return sectionIndex > 0 ? Say.sectionHere(sectionIndex, questions: sectionQuestionCount) + " " + status : status
        case .missingAnswers:
            let found = unansweredNumbers()
            if sectionQuestionCount > 0 { return Say.sectionMissing(found.missing, questions: sectionQuestionCount) }
            return Say.missingAnswers(found.missing, highest: found.highest)
        default:
            return Say.nothingToRepeat
        }
    }

    /// 1'den en yüksek cevaplanan numaraya kadar cevabı olmayan sorular ("cevapsız soruları söyle" ve test kapanışı). Bölümün soru sayısı
    /// ayarlarda girilmişse sınır o sayıdır: hiç okunmayan son sorular da cevapsız sayılır.
    func unansweredNumbers() -> (missing: [Int], highest: Int) {
        let done = Set(answers.map { $0.number })
        let highest = max(done.max() ?? 0, sectionQuestionCount)
        let missing: [Int] = highest == 0 ? [] : (1...highest).filter { !done.contains($0) }
        return (missing, highest)
    }

    /// Soru metninin son sözü (son sessizlikten sonraki kısım) silinir. Silinecek bir şey yoksa bunu söyler.
    private func deleteLastSentence(mode: ListenMode, question: String) -> String {
        let tokens = question.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard mode == .question, !tokens.isEmpty else { return Say.nothingToDelete }
        let start = utteranceStarts.last(where: { $0 < tokens.count }) ?? 0
        let removed = Array(tokens[start...])
        accumulator.dropWords(from: start)
        utteranceStarts.removeAll { $0 >= start }
        liveText = accumulator.text
        return Say.lastSentenceDeleted(removed, remaining: start > 0)
    }

    // MARK: Anlaşılmayan söz

    /// Soru dinlenirken metin değişmeden kaldı ve "Cevapla" yok: komut gibi duyulduysa kısa sürede, değilse uzun sessizlikten sonra konuşulur
    func scheduleQuestionChecks() {
        if CommandAttempt.looksLike(currentUtterance()) {
            confirmTask = deps.scheduler.after(Timing.attemptConfirm) { [weak self] in self?.commandNotUnderstood() }
        } else if wordCount(accumulator.text) >= Timing.partialMinWords, idleReminders < Timing.idleReminderLimit {
            confirmTask = deps.scheduler.after(Timing.questionIdle) { [weak self] in self?.questionIdle() }
        }
    }

    /// Komut gibi duyuldu ama anlaşılamadı: program açıkça söyler, söz metinden atılır (soruya karışmaz) ve tekrar ister
    func commandNotUnderstood() {
        confirmTask = nil
        guard phase == .listening, listenMode == .question, spokenCommand() == nil,
              TriggerDetector.match(in: accumulator.text) == nil else { return }
        let utterance = currentUtterance()
        guard CommandAttempt.looksLike(utterance) else { return }
        attemptFails += 1
        tlog("[komut] komut anlaşılamadı (deneme \(attemptFails)); duyulan: \"\(utterance)\"")
        warn("duyulan", "Duyulan: “\(utterance)”. Komut anlaşılamadı.")
        let tokens = wordCount(accumulator.text)
        let start = utteranceStart < tokens ? utteranceStart : 0
        accumulator.dropWords(from: start)
        if start == 0 {
            englishAccumulator.clear()
            liveEnglish = ""
            deps.recorder.reset()
        }
        liveText = accumulator.text
        closeListening()
        phase = .speaking
        let text = attemptFails >= 2 ? Say.commandHelp : Say.commandNotUnderstood
        work = Task { [weak self] in
            guard let self = self, await self.speakNotice(text) else { return }
            self.beginListening(mode: .question, keepPartial: true)
        }
    }

    /// Soru metni geldi, uzun süre konuşulmadı: "Cevapla" duyulmamıştır. Bir soruda en çok iki kez söylenir; metin korunur.
    func questionIdle() {
        confirmTask = nil
        guard phase == .listening, listenMode == .question, idleReminders < Timing.idleReminderLimit,
              wordCount(accumulator.text) >= Timing.partialMinWords, TriggerDetector.match(in: accumulator.text) == nil else { return }
        idleReminders += 1
        tlog("[soru] metin geldi ama Cevapla duyulmadı (hatırlatma \(idleReminders))")
        closeListening()
        phase = .speaking
        work = Task { [weak self] in
            guard let self = self, await self.speakNotice(Say.noTriggerHeard) else { return }
            self.beginListening(mode: .question, keepPartial: true)
        }
    }

    /// Paragraf numaraları beklenirken: numaralar söylendi ama "Tamam" denmedi (bir kez sorulur, yine denmezse numaralar kabul edilir) ya da
    /// numara anlaşılamadı / hiçbir şey söylenmedi (sınırlı sayıda yeniden sorulur)
    func targetsIdle() {
        confirmTask = nil
        guard phase == .listening, listenMode == .passageTargets, passageDraft != nil else { return }
        let heard = accumulator.text
        let numbers = bestNumbers(primary: SpokenNumber.list(from: heard, limit: numberLimit))
        guard !numbers.isEmpty else {
            finishTargets(numbers: [], heard: heard)
            return
        }
        targetDoneReminders += 1
        guard targetDoneReminders <= 1 else {
            tlog("[paragraf] Tamam denmedi; numaralar kabul edildi: \(QuestionComposer.listText(numbers))")
            finishTargets(numbers: numbers, heard: heard)
            return
        }
        tlog("[paragraf] numaralar duyuldu ama Tamam denmedi; onay isteniyor")
        closeListening()
        phase = .speaking
        work = Task { [weak self] in
            guard let self = self, await self.speakNotice(Say.passageTargetsConfirm(numbers)) else { return }
            self.beginListening(mode: .passageTargets, keepPartial: true)
        }
    }
}
