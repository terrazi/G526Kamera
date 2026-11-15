import Foundation

/// Soru gönderildikten sonraki sessiz bekleyişin yönetimi, kesinti sonrası doğru yerden devam etme ve ortak paragrafın ömrü.
extension SessionViewModel {
    /// Onarım sonrası söylenecek cümle ve dinlemenin hangi kipte, eldeki yarım metin korunarak mı açılacağı
    struct Continuation: Equatable {
        let text: String
        let mode: ListenMode
        let keep: Bool
    }

    // MARK: Cevap beklenirken

    /// Gemini beklenirken kullanıcıya bilgi: kısa aralıkla "cevap bekleniyor", `answerCap` saniyede cevap gelmezse vazgeçilir.
    /// Yalnız ilerleme anonsu açıkken çalışır (kapalıyken eski davranış: Gemini'nin kendi zaman aşımı ve gözcü).
    func startAnswerWait() {
        answerWait?.cancel()
        answerWait = nil
        answerWaitElapsed = 0
        idleCuesInRow = 0   // yeni bir soru gitti: sonraki dinlemede "Dinliyorum" yeniden söylenebilir
        guard settings.spokenProgress else { return }
        scheduleAnswerTick()
    }

    private func scheduleAnswerTick() {
        answerWait = deps.scheduler.after(Timing.answerCueEvery) { [weak self] in self?.answerTick() }
    }

    private func answerTick() {
        answerWait = nil
        guard phase == .answering else { return }
        answerWaitElapsed += Timing.answerCueEvery
        if answerWaitElapsed >= Timing.answerCap {
            giveUpWaiting()
            return
        }
        speakProgress(Say.stillWaiting)
        scheduleAnswerTick()
    }

    /// Cevap sınırda gelmediyse bekleme bırakılır, kullanıcıya söylenir, soru "gitmedi" olur ve dinlemeye dönülür.
    /// Aşama hemen değişir: iptal edilen istek hata dönerse "ağ koptu" onarımını tetiklemesin.
    private func giveUpWaiting() {
        tlog("[soru] Gemini \(Int(Timing.answerCap)) sn içinde cevap vermedi; bekleme bırakılıyor")
        work?.cancel()
        finishEntry(.failed("Gemini cevap vermedi; soruyu yeniden okuyun."))
        var notice = Say.geminiSlow
        if let id = sendingShotID {
            // Sürüm 4: çekilen soru. İlk kez zaman aşımına uğradıysa telefonda kalır ve bir kez yeniden gönderilir (beginListening yapar);
            // bekleyen çekimin yeniden gönderimi de zaman aşımına uğradıysa ATILMAZ: telefondaki klasörde durur, bir sonraki başarılı
            // cevaptan sonra sırayla yeniden gönderilir; kamera bu soru için yeniden sorulur
            if noteSendFailure(id) {
                armCameraOffer()
                notice = Say.cameraSlowParked   // defalarca cevap vermedi: bu test için beklemeye alınır, silinmez
            } else if retriedShots.contains(id), pendingShots.contains(where: { $0.id == id }) {
                armCameraOffer()
                notice = Say.cameraSlowKept
            } else {
                notice = Say.geminiSlowCamera
            }
        }
        let spokenNotice = notice   // Task kapanışı `var` yakalayamaz
        warn("cevap", spokenNotice)
        phase = .speaking
        work = Task { [weak self] in
            guard let self = self, await self.speakNotice(spokenNotice) else { return }
            self.beginListening()
        }
    }

    /// Cevap beklenirken kısa bilgi cümlesi. Başka bir anons çalıyorsa atlanır; cevap hazır olunca onun bitmesi beklenir.
    /// Yalnız kulaklıktan çalar (KURAL 1).
    func speakProgress(_ text: String) {
        guard voiceTask == nil, !interruptionActive, AudioRouting.verdict(deps.route.snapshot()).headphonesOK else { return }
        announced.append(text)   // uyarı anonsu gibi sayılır: cevap akışına karışmaz
        tlog("[ilerleme] \(text)")
        voiceTask = Task { [weak self] in
            guard let self = self else { return }
            _ = try? await self.deps.speaker.speak(text, saveAs: nil)
            self.quietTicks = 0
            self.voiceTask = nil
            self.drainAnnouncementsIfQuiet()
        }
    }

    // MARK: Kesinti sonrası devam

    /// Kesinti (onarım, donanım beklemesi) başlarken hangi aşamadan geldiği not edilir; dinlemeye dönünce (ya da oturum bitince) unutulur
    func trackInterruption(from old: SessionPhase) {
        switch phase {
        case .recovering, .paused:
            guard interruptedFrom == nil else { return }
            if old == .listening || old == .answering { interruptedFrom = old }
        case .listening, .idle, .finished, .checking:
            interruptedFrom = nil
        default:
            break
        }
    }

    /// Onarım bitti: kesintiye uygun cümle söylenir, dinleme doğru kipte açılır
    func finishRecovery(brief: Bool) async {
        let next = continuation(brief: brief)
        guard await speakNotice(next.text) else { return }
        beginListening(mode: next.mode, keepPartial: next.keep)
    }

    func continuation(brief: Bool) -> Continuation {
        // Numara ya da paragrafın soru numaraları bekleniyordu: aynı soru yeniden sorulur, bekleyen soru/paragraf kaybolmaz
        if choiceOffer != nil { return Continuation(text: Say.askChoiceAgain, mode: .startChoice, keep: false) }
        // Cevaplar okunurken ya da okuma sonrası menü beklenirken kesinti oldu: menü yeniden sorulur
        if listenMode == .reviewMenu { return Continuation(text: Say.reviewResume, mode: .reviewMenu, keep: false) }
        // Telefonda gönderilmemiş bir çekim varsa önce o gönderilir; kamera akışı kesildiyse (offerCamera) evet / hayır yeniden sorulur.
        // İkisini de beginListening yapar; burada yalnız kısa bir cümle söylenir
        if resendablePending != nil || offerCamera { return Continuation(text: Say.recoveredPendingShot, mode: .question, keep: false) }
        if listenMode == .cameraChoice { return Continuation(text: Say.askCameraAfterRecovery, mode: .cameraChoice, keep: false) }
        if listenMode == .passageCameraChoice { return Continuation(text: Say.askPassageCameraAfterRecovery, mode: .passageCameraChoice, keep: false) }
        if listenMode == .captureKindChoice { return Continuation(text: Say.askCaptureKindAfterRecovery, mode: .captureKindChoice, keep: false) }
        if listenMode == .nextSectionChoice { return Continuation(text: Say.askNextSectionAfterRecovery(sectionIndex + 1), mode: .nextSectionChoice, keep: false) }
        if let edit = numberEdit { return Continuation(text: "Bağlantı yeniden onarıldı. " + editPrompt(edit), mode: .missingNumber, keep: false) }
        if heldQuestion != nil { return Continuation(text: Say.recoveredAskNumber, mode: .missingNumber, keep: false) }
        if let draft = passageDraft { return Continuation(text: draft.shot == nil ? Say.recoveredAskTargets : Say.recoveredAskTargetsCamera, mode: .passageTargets, keep: false) }
        if settings.smartResume {
            if interruptedFrom == .answering {
                return Continuation(text: Say.recoveredAfterSend, mode: .question, keep: false)
            }
            if interruptedFrom == .listening, let partial = partialContinuation() { return partial }
        }
        return Continuation(text: brief ? Say.recoveredShort : Say.recovered, mode: .question, keep: false)
    }

    /// Okuma yarıda kesildiyse: numara ve en son cümle söylenir; kullanıcı oradan devam eder, metinler birleştirilir
    private func partialContinuation() -> Continuation? {
        let text = accumulator.text
        switch listenMode {
        case .passage:
            let body = PassageCommand.stripStart(text)
            let sentence = LastSentence.of(body)
            return Continuation(text: Say.continuePartial(passage: true, number: nil, sentence: sentence), mode: .passage, keep: !body.isEmpty)
        case .passageTargets:
            return Continuation(text: passageDraft?.shot == nil ? Say.recoveredAskTargets : Say.recoveredAskTargetsCamera, mode: .passageTargets, keep: false)
        case .missingNumber, .confirmEnd, .startChoice, .reviewMenu, .cameraChoice, .passageCameraChoice, .captureKindChoice, .nextSectionChoice:
            return nil
        case .question:
            let words = text.split(whereSeparator: { $0.isWhitespace })
            guard words.count >= Timing.partialMinWords else { return nil }
            let sentence = LastSentence.of(text)
            guard !sentence.isEmpty else { return nil }
            return Continuation(text: Say.continuePartial(passage: false, number: SpokenNumber.extract(from: text, limit: numberLimit), sentence: sentence), mode: .question, keep: true)
        }
    }

    // MARK: Ortak paragraf

    /// Cevaplanan soru paragrafın soru listesinden düşer; hepsi cevaplanınca paragraf bırakılır
    func completePassage(for number: Int) {
        guard var context = passage, context.remaining.contains(number) else { return }
        context.remaining.removeAll { $0 == number }
        if context.remaining.isEmpty {
            passage = nil
            tlog("[paragraf] ortak paragrafın tüm soruları cevaplandı; paragraf bırakıldı")
        } else {
            passage = context
        }
    }
}
