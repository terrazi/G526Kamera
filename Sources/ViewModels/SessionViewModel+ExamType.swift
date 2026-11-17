import Foundation

/// Sınav türü (kullanıcı kararı 2026-11-17): görüntülü (kamera), sesli (mikrofon + kulaklık), hibrit (her soruda kamera mı sesle mi sorulur).
/// Tür Ayarlar'dan seçilir; sınav sırasında "sesli sınav başlat", "hibrit sınav başlat", "görüntülü sınav başlat" denirse sınavın kalanı o türle
/// sürer, denmezse tür aynı kalır (görüntülü sınav kaldığı yerden görüntülü sürer). Komut, sorular arasında dinlenen her kipte anlaşılır
/// ("cevaplar okunduktan sonra" menüde, kamera sorusunda, soru beklenirken); tür kaydedilir ve sonraki soru sınırında uygulanır.
extension SessionViewModel {
    /// Komut söylendi. Tür hemen kaydedilir. Sesliye geçilirse kamera bırakılır; görüntülü / hibrite geçilirse okunmakta olan soru sesle biter ve
    /// kamera sonraki sorudan başlar, soru metni henüz yoksa kamera hemen sorulur.
    func changeExamType(_ type: ExamType, mode: ListenMode) async -> LiveReply {
        let before = settings.examType
        if before == type { return LiveReply(text: Say.examTypeAlready(type)) }
        settings.examType = type
        if mode == .startChoice { examTypePinned = true }   // başlangıç sorusunda seçildi: "yeni sınav" bunu ezmez
        let choice = mode == .cameraChoice || mode == .passageCameraChoice || mode == .captureKindChoice
        let keepsQuestion = mode == .question && !accumulator.isEmpty
        tlog("[ayar] sınav türü: \(before.spoken) → \(type.spoken) (\(mode) kipinde söylendi)")
        var reply = LiveReply(text: "")
        if type == .voice {
            offerCamera = false
            let releasing = deps.camera.holding || networkMayBeOnCamera
            reply.leaveCameraChoice = choice
            reply.releaseCamera = releasing
            reply.text = Say.examTypeChanged(type, configured: cameraConfigured, leavingChoice: choice, releasing: releasing, keepsQuestion: false)
            return reply
        }
        let configured = cameraConfigured
        if mode == .question, configured {
            if keepsQuestion {
                offerCamera = true   // okunan soru sesle biter; sonraki soru sınırında kamera sorulur
            } else {
                reply.askCameraNow = true
            }
        }
        reply.text = Say.examTypeChanged(type, configured: configured, leavingChoice: false, releasing: false, keepsQuestion: keepsQuestion && configured)
        return reply
    }

    /// Sesli sınava geçildi: toplu çekimde hazır bekleyen kamera bağlantısı kapanır, telefon kameranın Wi-Fi'sindeyse internete dönülür
    /// (yoksa soru Gemini'ye gidemezdi). İnternet yerindeyse hiçbir şey çalışmaz.
    func releaseCameraForVoice() async {
        tlog("[kamera] sesli sınava geçildi: kamera bağlantısı kapatılıyor, internete dönülüyor")
        deps.camera.closeHeld()
        statusNote = internetNote
        await restoreInternetIfStrandedOnCamera()
        statusNote = ""
    }

    /// Yeni bir sınav başlıyor: tür ayardaki başlangıç türüne döner. Sınav türü başlangıç sorusunda sesle seçildiyse korunur.
    func startNewExamType() async {
        defer { examTypePinned = false }
        guard !examTypePinned, settings.examType != settings.examTypeDefault else { return }
        let before = settings.examType
        settings.examType = settings.examTypeDefault
        tlog("[ayar] yeni sınav: sınav türü \(before.spoken) → \(settings.examType.spoken) (ayardaki başlangıç türü)")
        if settings.examType == .voice, deps.camera.holding || networkMayBeOnCamera { await releaseCameraForVoice() }
    }
}
