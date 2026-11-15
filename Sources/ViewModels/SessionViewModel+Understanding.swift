import Foundation

extension ListenHints {
    /// Dinleme kipine uygun ipucu listesi
    static func hints(for mode: ListenMode) -> ListenHints {
        switch mode {
        case .question, .passage: return .dictation
        case .confirmEnd, .startChoice, .reviewMenu, .cameraChoice, .passageCameraChoice: return .choice
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
        let numbers = bestNumbers(primary: SpokenNumber.list(from: heard))
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
