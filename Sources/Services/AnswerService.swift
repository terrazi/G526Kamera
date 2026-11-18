import Foundation

struct GeminiReply: Equatable {
    /// Gemini'nin okuduğu soru numarası (bulunamadıysa nil)
    let number: Int?
    let option: String
    let text: String
    /// Kulaklıktan okunacak cümle
    let spoken: String
    /// Cevabı veren model
    let model: String
    /// Cevap ilk sıradaki profilden gelmediyse nedenini anlatan kısa not ("1. profil kotası doldu; cevap … modelinden geldi"); aksi hâlde boş
    var note: String = ""
    /// Kulaklıktan söylenen tek kısa cümle: yalnız cevap diğer modeller yanıt vermeyince ÜCRETLİ modelden geldiyse "Ücretli modelden cevaplandı."
    /// (para harcandığı bilinsin). Hangi ücretsiz modelin cevapladığı ve sunucunun hata metinleri söylenmez; ayrıntı yalnız ekrandaki `note` içindedir.
    var spokenNote: String = ""
}

@MainActor
protocol Answering: AnyObject {
    /// Dikte edilen soruyu Gemini'ye sorar. `expectedNumber`: soru numarası okunmamışsa kullanılacak sıradaki numara.
    /// `audio`: soruyu okuyanın ses kaydı (WAV); verilirse asıl kaynak odur, `question` dikte metni ipucu olur.
    /// `english`: aynı sesin İngilizce tanıyıcıdan geçmiş hâli (boş olabilir); İngilizce cümlelerde Türkçe metinden daha doğrudur.
    /// `passage`: kamerayla çekilmiş ortak paragraf varsa görüntüleri (soru metni paragrafa göndermeyi söyler); yoksa nil
    func answer(question: String, english: String, expectedNumber: Int, audio: Data?, passage: PassageMedia?) async throws -> GeminiReply
    /// Sürüm 4: kamera ile çekilmiş soru (sayfa fotoğrafı + kısa video). Cevap biçimi ve profil zinciri sesle gelen soruyla aynıdır.
    func answer(capture: CapturedQuestion, expectedNumber: Int) async throws -> GeminiReply
    /// Toplu sayfa çekimi: bir çekim bir sayfadır; sayfadaki BÜTÜN sorular cevaplanır (her soru için bir cevap, Gemini'nin verdiği sırayla)
    func answerPage(capture: CapturedQuestion, expectedNumber: Int) async throws -> [GeminiReply]
}

extension Answering {
    func answerPage(capture: CapturedQuestion, expectedNumber: Int) async throws -> [GeminiReply] {
        return [try await answer(capture: capture, expectedNumber: expectedNumber)]
    }

    func answer(question: String, english: String, expectedNumber: Int, audio: Data?) async throws -> GeminiReply {
        return try await answer(question: question, english: english, expectedNumber: expectedNumber, audio: audio, passage: nil)
    }

    func answer(question: String, expectedNumber: Int, audio: Data?) async throws -> GeminiReply {
        return try await answer(question: question, english: "", expectedNumber: expectedNumber, audio: audio)
    }
}

/// Modül 5: soruyu Gemini'ye gönderir, kısa cevabı çözer. 4 profil (her birinin kendi anahtarı ve modeli) sırayla denenir:
/// kota dolarsa, sunucu hata verirse, cevap gecikirse ya da anahtar/model sorunluysa sıradaki profile geçilir.
@MainActor
final class GeminiAnswerService: Answering {
    /// Her profilde cevap için beklenecek süre (sn); dolunca sıradaki profil denenir (kullanıcı kararı 2026-11-18: modeller çok beklenmesin; 40 idi)
    static let perModelLimit: TimeInterval = 25
    /// Kamera ile çekilen soruda (fotoğraf + video yüklenir, hücresel veriyle) her profilde beklenecek süre: yükleme de buna girer (100 idi)
    static let capturePerModelLimit: TimeInterval = 60
    /// Bütün profiller sırayla denenip hiçbiri cevap vermezse sıra BAŞTAN, aynı sırayla yeniden denenir (kullanıcı kararı 2026-11-18: cevap alınana kadar);
    /// her turda bekleme süresi bu çarpanla uzar (yavaş ağda ya da büyük yüklemede hiçbir model yetişemezse sonsuz boşa dönülmesin); son çarpan sonraki turlarda sürer
    static let roundFactors: [Double] = [1, 1.5, 2]
    /// En çok kaç tur denenir (tur = bütün profillerin sırayla denenmesi)
    static let maxRounds = 5
    /// Turlar arasında beklenecek süre (sn)
    static let roundPause: TimeInterval = 3

    /// Biraz sonra yeniden denenirse düzelebilecek hatalar: cevap gecikmesi, sunucu yoğunluğu, boş cevap, dakikalık kota. Anahtar sorunu, model adı sorunu
    /// ve günlük kota beklemekle düzelmez: o profil sonraki turlara katılmaz.
    static func retryable(_ error: GeminiError) -> Bool {
        if error.timedOut || error.kind == .empty { return true }
        if error.kind == .quota { return !error.message.contains("günlük") }
        return [500, 502, 503, 504].contains(error.status)
    }

    /// Sistem komutu: kullanıcının verdiği çerçeve + (1) şık sözcükleri (2) dikte hatalarına ve zayıf İngilizce telaffuzuna karşı empati
    static let systemPrompt = """
    Sen bir sınav okuyucu asistansın. Gelen test sorularını çöz ve SADECE şu formatta tek satır yanıt ver: \
    Soru [numara], [şık sözcüğü], [doğru cevabın metni]. Örnek: Soru 1, Denizli, Örgütsel Davranış.

    Şıklar: A=Adana, B=Bursa, C=Ceyhan, D=Denizli, E=Erzurum. Şık için HER ZAMAN bu sözcüğü yaz, harf yazma. \
    Soru okunurken şıklar A, B, C, D, E harfleriyle ya da bu sözcüklerle okunmuş olabilir.

    Soru, kullanıcının sesli okuduğu metnin Türkçe dikte (konuşma tanıma) çıktısıdır; yazı hatalarla dolu olabilir. \
    Bazen dikte metninin yanında kullanıcının SES KAYDI da gelir: o zaman asıl kaynak ses kaydıdır, önce onu dinle; dikte \
    metni yalnız ipucudur. Kaydın sonundaki "Cevapla" ya da "Gönder" sözcüğü tetikleyicidir, soruya katma. \
    Kullanıcı İngilizce sorularda çoğu zaman kelimeleri yanlış telaffuz eder ve Türkçe tanıyıcı İngilizce kelimeleri \
    Türkçe okunuşa benzeyen anlamsız sözcükler olarak yazar (ör. "kompleks ayşın" gibi). Bu yüzden metni harfi harfine \
    değil, kullanıcıya empati kurarak oku: kimin, hangi sınavda, ne söylemeye çalıştığını düşün. Bozuk görünen her \
    sözcük için olası İngilizce (ya da Türkçe) karşılıkları ses benzerliğiyle çıkar, soru kalıbını, şıkları, konunun \
    terimlerini ve gramer yapısını birlikte değerlendir. Çok boyutlu düşün: birden çok açıdan (anlam, ses, bağlam, \
    şıkların birbirine benzerliği) bakıp en tutarlı yorumu seç. Şıkların hangi harfe ya da sözcüğe denk geldiğini de aynı şekilde karıştırma.

    Bazen ikinci bir dikte metni de gelir: aynı sesin İngilizce tanıyıcıdan geçmiş hâli. Soru İngilizceyse bu metin, Türkçe \
    dikte metninden çok daha doğrudur (ses kaydıyla birlikte değerlendir); Türkçe cümlelerde ise İngilizce metin anlamsızdır, onu yok say. \
    İki metin birbirini tamamlayabilir: Türkçe şıkları ve soru kalıbını Türkçe metinden, İngilizce cümleyi İngilizce metinden al.

    Kullanıcı soruları sırayla okumak zorunda değildir (önce Soru 7, sonra Soru 3 okunabilir): numarayı sıradan ya da ipucundan \
    çıkarma, okunan numarayı aynen yaz. Soru numarası hiç okunmadıysa ya da anlaşılmadıysa kullanıcı mesajındaki ipucunu kullan. \
    Bazen mesaj "Ortak paragraf (… numaralı sorular için ortaktır …)" diye başlar; ardından paragraf metni (ya da paragraf yazı olarak \
    değil, mesaja eklenen fotoğraf ve videoda görüntü olarak verildiği notu) ve "Şimdi sorulan soru:" bölümü gelir. Paragraf birden çok sorunun ortak metnidir: yalnız "Şimdi sorulan soru" bölümündeki soruyu, paragrafa dayanarak \
    yanıtla ve cevabı o sorunun numarasıyla ver; paragraftaki diğer numaraları cevaplama. Soru metni "Soru 7." diye başlıyorsa bu \
    numarayı kullanıcı söylemiştir (numara okumadan sonra sorulup öğrenildi): aynen kullan. \
    Cevap metnini şıktan kısaca yaz. \
    Giriş, açıklama, markdown, tırnak ve ek cümle yazma. Emin değilsen en olası şıkkı yaz.
    """

    /// Sürüm 4: kamera ile çekilen soru için sistem komutu. Cevap biçimi ve şık sözcükleri sesli sorudakiyle aynıdır; fark: soru görüntüden okunur
    /// ve kadrajın kenarlarından yarım görünen komşu sorular yok sayılır (sayfa ortada tek bir soruya konumlandırılmıştır, ama kenar taşabilir).
    static let captureSystemPrompt = """
    Sen bir sınav okuyucu asistansın. Mesajda basılı ya da ekranda gösterilen bir test sorusunun görüntüsü var: tek bir FOTOĞRAF ya da \
    kamera soru üzerinde dururken saniyede bir çekilmiş ardışık fotoğrafların PDF'i (her sayfa bir fotoğraftır) ve (varsa) aynı sürenin kısa VİDEOSU. \
    Soruyu görüntüden oku, çöz ve SADECE şu formatta tek satır yanıt ver: Soru [numara], [şık sözcüğü], [doğru cevabın metni]. \
    Örnek: Soru 1, Denizli, Örgütsel Davranış.

    Şıklar: A=Adana, B=Bursa, C=Ceyhan, D=Denizli, E=Erzurum. Şık için HER ZAMAN bu sözcüğü yaz, harf yazma. \
    Sayfada şıklar A, B, C, D, E harfleriyle basılıdır; hangi harfin hangi sözcüğe denk geldiğini karıştırma.

    ODAK: üzerinde çalışılan soru, görüntünün ortasındaki ve şıklarıyla birlikte tam görünen sorudur. Görüntünün kenarlarında yarım \
    görünen başka sorular, şıklar, sütun ya da sayfa parçaları, sayfa numarası, üst ve alt bilgi başka sorulara aittir: bunları YOK SAY, \
    cevaplama, numaralarını kullanma, "soru bölünmüş" gibi bir şey söyleme. Soru tam kadrajda ise sorun yok demektir; hemen cevapla.

    PDF'in sayfaları ve video aynı soruyu gösterir. Kullanıcı kamerayı ya da kâğıdı bu sürede gezdirdiği için aynı soru farklı konum ve \
    açılarla tekrar tekrar görünür; bazı sayfalarda yazının bir bölümü, bir şık ya da soru kökü yarım, kayık, bulanık ya da parlamalı olabilir. \
    Bütün sayfaları ve videoyu BİRLİKTE değerlendir, soruyu ve şıklarını bütün olarak çıkar; en net sayfaya öncelik ver, bir yer okunmuyorsa \
    öbür sayfadan ya da videodan tamamla; çelişirse net olana güven. Soru numarasını soru metninin başından oku ve aynen yaz; numara okunamıyorsa kullanıcı \
    mesajındaki ipucunu kullan. Sayfada birkaç soruya ortak bir paragraf varsa onu oku ve ortada görünen soruyu o paragrafa dayanarak yanıtla. \
    Mesajda ayrıca kullanıcının daha önce çektiği ORTAK PARAGRAFIN görüntüleri (PDF ya da fotoğraf) ve videosu da olabilir (mesajdaki not hangi görüntünün paragrafa, hangisinin \
    soruya ait olduğunu söyler): çekilen soru o paragrafın sorularından biriyse paragrafı oradan oku ve soruyu ona dayanarak yanıtla. \
    Cevap metnini şıktan kısaca yaz. Giriş, açıklama, markdown, tırnak ve ek cümle yazma. Emin değilsen en olası şıkkı yaz.
    """

    /// Toplu çekim için sistem komutu: cevap biçimi aynıdır, ama görüntülerde görünen BÜTÜN sayfalardaki BÜTÜN sorular, her biri ayrı satırda, numara sırasıyla cevaplanır
    static let pageSystemPrompt = """
    Sen bir sınav okuyucu asistansın. Mesajda bir sınav kitapçığının görüntüleri var: kullanıcı kamerayı kitapçığın sayfaları üzerinde gezdirirken çekilen kareler. \
    Program bozuk (bloklaşmış), bulanık, boş ya da birebir tekrar eden kareleri, yerlerine iyisi varsa, elemiş; kalan kareleri ZAMAN SIRASIYLA bir PDF'e koymuştur (PDF'in her sayfası bir karedir; sayısı değişir). \
    Kamera dar bir alan gördüğü için ardışık kareler birbirini KISMEN ÖRTER: kamera kâğıt üzerinde kayar, aynı satırlar iki karede de görünebilir. \
    Kitapçığın kaç sayfası görüneceği belli değildir ve sayfalar eşit sürede gösterilmez; sayfa çevrilirken bulanık ya da yarım kareler olabilir. \
    Kareler zaman sırasındadır ama kullanıcı sayfaları ya da bir sayfanın parçalarını sırasız göstermiş olabilir: bir görüntünün yerini sırasından değil içeriğinden (sayfa ve soru numarası, satır akışı, ortak satırlar) çıkar. \
    Her sayfada BİRDEN ÇOK soru ve soru grubuna ortak paragraflar olabilir.

    Bütün karelerde görünen BÜTÜN soruları (paragraflara bağlı sorular dahil) oku, her birini çöz ve HER SORU İÇİN AYRI BİR SATIR yaz, \
    soru numarasına göre küçükten büyüğe. Her satırın biçimi: Soru [numara], [şık sözcüğü], [doğru cevabın metni]. Örnek (iki soru):
    Soru 4, Denizli, Örgütsel Davranış
    Soru 5, Adana, Yönetim

    Şıklar: A=Adana, B=Bursa, C=Ceyhan, D=Denizli, E=Erzurum. Şık için HER ZAMAN bu sözcüğü yaz, harf yazma. \
    Sayfalarda şıklar A, B, C, D, E harfleriyle basılıdır; hangi harfin hangi sözcüğe denk geldiğini karıştırma.

    BÖLÜNMÜŞ SORULAR (çok önemli): Bir soru tek karenin içine sığmamış olabilir: sorunun numarası ve kökü bir karede, şıkları sonraki karede görünebilir; \
    bir şık iki karede yarım yarım, bir paragraf ya da soru kökü üç karede parça parça olabilir. Parçaları SEN birleştir. Ardışık karelerde ortak görünen satır, \
    sözcük, numara ya da şık harfi "çıpadır": aynı yazıyı iki karede görüyorsan o iki kare aynı yeri gösteriyordur; parçaları okuma sırasıyla (yukarıdan aşağıya, \
    iki sütunlu sayfada önce sol sütun sonra sağ sütun) uç uca ekleyerek soruyu BÜTÜN olarak oluştur. Aynı satırın farklı karelerdeki görünümlerinden en netini al, \
    bir karede kayık ya da bulanık olan yeri başka karenin netinden tamamla. Birleştirirken YALNIZ aynı soruya ait parçaları kullan: komşu sorular, \
    paragraf, sayfa numarası, üst ve alt bilgi birbirine karışmasın; bir parçanın hangi soruya ait olduğundan emin değilsen o parçayı kullanma. \
    Soru numaralarını soru metninin başından oku ve aynen yaz (numara bir karede, şıklar başka karede olabilir); numara okunamıyorsa kullanıcı mesajındaki ipucunu kullan. \
    Her soruyu YALNIZ BİR KEZ cevapla.

    Birkaç soruya ortak bir paragraf varsa paragrafı bütün karelerden birleştirerek tamamla, oku ve o sorulara paragrafa dayanarak cevap ver; paragrafın kendisi için satır yazma, yalnız ona bağlı soruların satırlarını yaz. \
    Parçaları birleştirdikten sonra soru kökü ve A–E şıklarının hepsi elindeyse soruyu cevapla. Birleştirmeye rağmen soru kökü ya da şıklardan biri HİÇBİR karede yoksa ya da \
    numarası çıkarılamıyorsa tahmin yürütme ve o soru için satır yazma; sayfa numarası, üst ve alt bilgi soru değildir. \
    Cevap metnini şıktan kısaca yaz. Giriş, açıklama, markdown, madde işareti, tırnak ve ek cümle yazma: yalnız soru satırları. Birleştirilmiş soruda doğru şıktan emin değilsen en olası şıkkı yaz.
    Hiçbir karede (birleştirerek bile) tam soru çıkarılamıyorsa (boş görüntü, kapak, yönerge, yalnız kesik sorular) başka hiçbir şey yazmadan yalnız şunu yaz: SORU YOK
    """

    /// Toplu çekim kullanıcı mesajı (görüntü parçalarından sonra gelir)
    static func pageText(expectedNumber: Int, hasVideo: Bool, extra: String, pages: Int = 0, labels: [String] = []) -> String {
        var text = "İpucu: görüntülerdeki ilk sorunun numarası okunamazsa ona Soru \(expectedNumber) de ve sırayla devam et. Numara okunuyorsa sıraya değil okunan numaraya uy."
        if pages > 0 {
            let split = " Kareler zaman sırasındadır ve birbirini kısmen örter; bir soru birkaç kareye bölünmüş olabilir: parçaları ortak satırlardan ve şık harflerinden eşleyip birleştir, soruyu bütün olarak çöz."
            text += hasVideo
                ? "\n\nBu mesajda \(pages) fotoğraflık PDF (zaman sırasıyla seçilmiş net kareler) ve aynı sürenin kısa videosu var." + split + " Görüntülerde görünen bütün sayfalardaki bütün soruları, her biri ayrı satırda cevapla."
                : "\n\nBu mesajda \(pages) fotoğraflık PDF (zaman sırasıyla seçilmiş net kareler) var." + split + " Görüntülerde görünen bütün sayfalardaki bütün soruları, her biri ayrı satırda cevapla."
        } else {
            text += hasVideo
                ? "\n\nBu mesajda sayfanın fotoğrafı ve aynı sayfanın kısa videosu var. Görüntülerdeki bütün soruları, her biri ayrı satırda cevapla."
                : "\n\nBu mesajda sayfanın fotoğrafı var. Görüntülerdeki bütün soruları, her biri ayrı satırda cevapla."
        }
        if pages > 0, labels.count == pages, !labels.contains("") {
            // Serbest tarama: kullanıcı kamerayı sayfaların üzerinde gezdirdi, saniyede 2 kare alındı; etiket karenin çekildiği zaman aralığıdır
            let list = labels.enumerated().map { "\($0.offset + 1)) \($0.element)" }.joined(separator: "; ")
            text += "\n\nÇekim serbest taramaydı: kullanıcı kamerayı kitapçık sayfalarının üzerinde yakından ve yavaşça gezdirdi, saniyede İKİ kare alındı; sayfanın tamamını gösteren kare yoktur. "
                + "Ardışık kareler birbirini büyük ölçüde örter: aynı satır birçok karede görünür. Her yeri en net ve bozuksuz göründüğü kareden oku; aynı soruyu ya da satırı birden çok kez sayma. Etiketinde \"(bozuk kare)\" ya da \"(bulanık kare)\" yazan kare zayıftır: yalnız başka karede olmayan yeri ondan oku. Sayfa çoğu zaman iki sütundur: sorular önce sol sütunda yukarıdan aşağı, sonra sağ sütunda akar. Bir soru birkaç kareye bölünmüşse parçaları ortak satırlardan birleştir ve soruyu bütün olarak çöz. "
                + "PDF sayfalarının sırası ve programın verdiği etiketler: " + list + ". "
                + "ETİKETLER YALNIZ İPUCUDUR, kesin değildir: kullanıcı parçaları sırasız ya da karışık göstermiş, bir parçayı atlamış ya da aynı yeri iki kez göstermiş olabilir; "
                + "etiket ile içerik çelişirse İÇERİĞE güven. Her görüntünün hangi sayfaya ve sayfanın neresine ait olduğunu etiketten değil içerikten bul: sayfa numarası, soru numaraları, "
                + "satırların akışı, komşu görüntülerle ortak satırlar. Aynı sayfanın karelerini önce içeriğe göre sütun sütun, yukarıdan aşağı sırala, sonra birleştir; farklı sayfaların parçalarını karıştırma."
        }
        let note = extra.trimmed
        if !note.isEmpty { text += "\n\nKullanıcının ek talimatı: \(note)" }
        return text
    }

    static func captureText(expectedNumber: Int, hasVideo: Bool, extra: String, passage: String = "", pages: Int = 0) -> String {
        var text = "İpucu: soru numarası görüntüden okunamazsa bu soruyu Soru \(expectedNumber) say. Numara okunuyorsa sıraya değil okunan numaraya uy."
        if pages > 0 {
            text += hasVideo
                ? "\n\nBu mesajda sorunun \(pages) sayfalık PDF'i (saniyede bir çekilmiş ardışık fotoğraflar) ve aynı sürenin kısa videosu var. Görüntülerin ortasındaki soruyu cevapla; kenarlardan yarım görünen diğer soruları dikkate alma."
                : "\n\nBu mesajda sorunun \(pages) sayfalık PDF'i (saniyede bir çekilmiş ardışık fotoğraflar) var. Görüntülerin ortasındaki soruyu cevapla; kenarlardan yarım görünen diğer soruları dikkate alma."
        } else {
            text += hasVideo
                ? "\n\nBu mesajda soru sayfasının fotoğrafı ve aynı sayfanın kısa videosu var. Görüntünün ortasındaki soruyu cevapla; kenarlardan yarım görünen diğer soruları dikkate alma."
                : "\n\nBu mesajda soru sayfasının fotoğrafı var. Görüntünün ortasındaki soruyu cevapla; kenarlardan yarım görünen diğer soruları dikkate alma."
        }
        let note = extra.trimmed
        if !note.isEmpty { text += "\n\nKullanıcının ek talimatı: \(note)" }
        let shared = passage.trimmed
        if !shared.isEmpty { text += "\n\n" + shared }
        return text
    }

    /// Çekimin görüntü parçası: saniyede bir çekilmiş fotoğrafların PDF'i varsa o (application/pdf), yoksa tek fotoğraf (image/jpeg)
    static func visualPart(photo: Data, pdf: Data?) -> [String: Any] {
        if let pdf = pdf { return ["inlineData": ["mimeType": "application/pdf", "data": pdf.base64EncodedString()]] }
        return ["inlineData": ["mimeType": "image/jpeg", "data": photo.base64EncodedString()]]
    }

    /// Kamerayla çekilmiş ortak paragrafın istek parçaları: fotoğraf, sığarsa video. Video okunamazsa (dosya yok) yalnız fotoğraf gider.
    static func passageParts(_ media: PassageMedia, withVideo: Bool, fps: Double?) -> [[String: Any]] {
        var parts: [[String: Any]] = [visualPart(photo: media.photo, pdf: media.pdf)]
        if withVideo, let url = media.video, let data = try? Data(contentsOf: url) {
            var part: [String: Any] = ["inlineData": ["mimeType": "video/mp4", "data": data.base64EncodedString()]]
            if let fps = fps { part["videoMetadata"] = ["fps": fps] }
            parts.append(part)
        }
        return parts
    }

    /// Çekilen soru için istek gövdesi. Video satır içi gider (≤ 14 MB; büyükse yalnız fotoğraf gider); `fps`: kaydın kare hızı (nil: ayarsız)
    static func captureBody(_ shot: CapturedQuestion, expectedNumber: Int, fps: Double? = VideoRecorder.fps, page: Bool = false) throws -> Data {
        var video: Data?
        if shot.canSendVideo, let url = shot.video { video = try? Data(contentsOf: url) }
        // Google'ın önerisi (video ve görüntü belgeleri): metin istemi görüntü / video parçalarından SONRA gelir
        var parts: [[String: Any]] = []
        // Kamerayla çekilmiş ortak paragraf varsa görüntüleri soruninkinden ÖNCE gelir (mesajdaki not sırayı söyler)
        if let media = shot.passageMedia {
            parts.append(contentsOf: passageParts(media, withVideo: shot.canSendPassageVideo, fps: fps))
        }
        parts.append(visualPart(photo: shot.photo, pdf: shot.pdf))
        if let video = video {
            var part: [String: Any] = ["inlineData": ["mimeType": "video/mp4", "data": video.base64EncodedString()]]
            if let fps = fps { part["videoMetadata"] = ["fps": fps] }
            parts.append(part)
        }
        let pages = shot.pdf == nil ? 0 : max(shot.pageCount, 1)
        parts.append(["text": page
            ? pageText(expectedNumber: expectedNumber, hasVideo: video != nil, extra: shot.extraInstruction, pages: pages, labels: shot.rhythmLabels)
            : captureText(expectedNumber: expectedNumber, hasVideo: video != nil, extra: shot.extraInstruction, passage: shot.passageNote, pages: pages)])
        var object: [String: Any] = [
            "systemInstruction": ["parts": [["text": page ? pageSystemPrompt : captureSystemPrompt]]],
            "contents": [["role": "user", "parts": parts]]
        ]
        if shot.highResolution { object["generationConfig"] = ["mediaResolution": "MEDIA_RESOLUTION_HIGH"] }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private let profilesProvider: () -> [GeminiProfileInfo]
    private let makeClient: (GeminiProfileInfo) -> GeminiClient
    private let limit: TimeInterval
    private let captureLimit: TimeInterval
    private let maxRounds: Int
    private let roundPause: TimeInterval
    private let now: () -> Date
    /// Bu profiller bu zamana kadar sona bırakılır (kotası doldu / cevap vermedi): her soruda boşuna beklenmesin. Anahtar profilin kimliğidir (yuva değil):
    /// kullanıcı sırayı değiştirse de dinlenme kendi profilinde kalır
    private var restingUntil: [String: Date] = [:]

    init(profiles: @escaping () -> [GeminiProfileInfo],
         limit: TimeInterval = GeminiAnswerService.perModelLimit,
         captureLimit: TimeInterval = GeminiAnswerService.capturePerModelLimit,
         maxRounds: Int = GeminiAnswerService.maxRounds,
         roundPause: TimeInterval = GeminiAnswerService.roundPause,
         now: @escaping () -> Date = { Date() },
         makeClient: ((GeminiProfileInfo) -> GeminiClient)? = nil) {
        self.profilesProvider = profiles
        self.limit = limit
        self.captureLimit = captureLimit
        self.maxRounds = max(1, maxRounds)
        self.roundPause = roundPause
        self.now = now
        self.makeClient = makeClient ?? { profile in GeminiClient(key: { profile.key }, model: { profile.model }) }
    }

    // MARK: İstek ve cevap (saf yardımcılar)

    static func userText(question: String, english: String = "", expectedNumber: Int, hasAudio: Bool = false) -> String {
        let hint = "İpucu: soru numarası okunmadıysa bu soruyu Soru \(expectedNumber) say. Numara okunduysa sıraya değil okunan numaraya uy."
        var text: String
        if hasAudio {
            text = "\(hint)\n\nBu mesajda soruyu okuyanın ses kaydı var (asıl kaynak). Dikte metni yalnız ipucudur, hatalı olabilir:\n\(question)"
        } else {
            text = "\(hint)\n\nOkunan soru (dikte çıktısı):\n\(question)"
        }
        let second = english.trimmed
        if !second.isEmpty {
            text += "\n\nAynı sesin İngilizce tanıyıcıdan geçmiş hâli (İngilizce cümleleri Türkçe metinden daha doğru yazmış olabilir; Türkçe cümleleri bozuk yazar):\n\(second)"
        }
        return text
    }

    static func requestBody(question: String, english: String = "", expectedNumber: Int, audio: Data? = nil, passage: PassageMedia? = nil) throws -> Data {
        var parts: [[String: Any]] = [["text": userText(question: question, english: english, expectedNumber: expectedNumber, hasAudio: audio != nil)]]
        if let audio = audio {
            parts.append(["inlineData": ["mimeType": "audio/wav", "data": audio.base64EncodedString()]])
        }
        if let media = passage {
            // Ses kaydı + paragraf fotoğrafı + paragraf videosu 14 MB'ı (base64 ile ~18,7 MB) aşmasın: sığmazsa yalnız fotoğraf gider
            let used = (audio?.count ?? 0) + media.visualBytes
            let fits = media.canHaveVideo && used + media.videoBytes <= CapturedQuestion.maxInlineVideoBytes
            parts.append(contentsOf: passageParts(media, withVideo: fits, fps: VideoRecorder.fps))
        }
        let object: [String: Any] = [
            "systemInstruction": ["parts": [["text": systemPrompt]]],
            "contents": [["role": "user", "parts": parts]]
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// generateContent cevabından model metni (düşünce parçaları atlanır). Engellenmiş ya da boş cevapta GeminiError.
    static func replyText(from object: Any) throws -> String {
        guard let obj = object as? [String: Any] else {
            throw GeminiError("Gemini'den anlaşılmaz yanıt geldi.", .error)
        }
        if let feedback = obj["promptFeedback"] as? [String: Any], let reason = feedback["blockReason"] as? String, !reason.isEmpty {
            throw GeminiError("Gemini isteği güvenlik nedeniyle engelledi (\(reason)).", .blocked)
        }
        guard let candidates = obj["candidates"] as? [[String: Any]], let candidate = candidates.first else {
            throw GeminiError("Gemini boş yanıt döndürdü.", .empty)
        }
        let parts = ((candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        var text = ""
        for part in parts {
            if let thought = part["thought"] as? Bool, thought { continue }
            if let piece = part["text"] as? String { text += piece }
        }
        let trimmed = text.trimmed
        if trimmed.isEmpty {
            let finish = (candidate["finishReason"] as? String) ?? ""
            throw GeminiError("Gemini boş yanıt döndürdü (\(finish.isEmpty ? "neden yok" : finish)).", .empty)
        }
        return trimmed
    }

    /// Sıradaki modelin işe yarayacağı hatalar: kota, sunucu hatası/yoğunluk, cevap gecikmesi, boş cevap, anahtar ya da model adı sorunu.
    /// Harcama sınırı, içerik engeli, çok büyük istek ve internetin hiç olmaması başka modelle düzelmez.
    static func fallbackWorthy(_ error: GeminiError) -> Bool {
        switch error.kind {
        case .cap, .blocked, .tooBig: return false
        case .network: return error.timedOut
        case .empty: return true
        default: return [500, 502, 503, 504].contains(error.status) || error.kind == .quota || error.kind == .key || error.kind == .model
        }
    }

    /// Profilin modeline göre istek gövdesi: Gemma modelleri düşünmeyi yalnız "thinkingLevel" ile açar (soru çözümünde doğruluk için gerekir),
    /// Gemini modellerine dokunulmaz.
    static func body(_ body: Data, forModel model: String) -> Data {
        guard let level = GeminiSupport.thinkingLevel(model: model, setting: "auto"),
              let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: GeminiSupport.applyThinking(object, level: level)) else { return body }
        return data
    }

    // MARK: Answering

    /// Sıra: dinlenmiş profiller yuva sırasıyla, ardından sona bırakılanlar (hepsi sondaysa yine hepsi denenir)
    func order(_ usable: [GeminiProfileInfo]) -> [GeminiProfileInfo] {
        let t = now()
        let ready = usable.filter { (restingUntil[$0.identity] ?? .distantPast) <= t }
        let resting = usable.filter { (restingUntil[$0.identity] ?? .distantPast) > t }
        return ready + resting
    }

    private func rest(_ profile: GeminiProfileInfo, after error: GeminiError) {
        let seconds: TimeInterval
        switch error.kind {
        case .quota: seconds = error.message.contains("günlük") ? 3600 : 300
        case .key, .model, .cap: seconds = 900
        default: seconds = 120
        }
        restingUntil[profile.identity] = now().addingTimeInterval(seconds)
    }

    func answer(question: String, english: String, expectedNumber: Int, audio: Data?, passage: PassageMedia?) async throws -> GeminiReply {
        guard !GeminiProfiles.usable(profilesProvider()).isEmpty else { throw GeminiError(Say.noKeyShort, .key) }
        let body = try GeminiAnswerService.requestBody(question: question, english: english, expectedNumber: expectedNumber, audio: audio, passage: passage)
        // Paragraf görüntüsü de gidiyorsa istek, yüklemesi daha uzun süren çekilmiş soru gibi bekler
        return try await run(body: body, limit: passage == nil ? limit : captureLimit)
    }

    /// Kamera ile çekilen soru: kare hızı ayarı bu modelde reddedilirse (400) ayarsız bir kez daha denenir. Anahtar hataları (Google onları da
    /// 400 ile döndürür) ve kare hızıyla ilgisi olmayan istekler yeniden denenmez: aynı büyük yükleme boşuna ikinci kez yapılmasın.
    func answer(capture: CapturedQuestion, expectedNumber: Int) async throws -> GeminiReply {
        guard !GeminiProfiles.usable(profilesProvider()).isEmpty else { throw GeminiError(Say.noKeyShort, .key) }
        let body = try GeminiAnswerService.captureBody(capture, expectedNumber: expectedNumber)
        do {
            return try await run(body: body, limit: captureLimit)
        } catch let error as GeminiError where error.status == 400 && error.kind == .http && capture.sendsFrameRate {
            tlog("[kamera] kare hızı ayarıyla istek reddedildi (\(error.message)); ayarsız yeniden deneniyor")
            return try await run(body: try GeminiAnswerService.captureBody(capture, expectedNumber: expectedNumber, fps: nil), limit: captureLimit)
        }
    }

    /// Sayfa cevabı: satır satır cevaplar; model "SORU YOK" derse tek, boş cümleli bir cevap (sayfada soru yok) döner
    static func parsePage(_ raw: String) -> [AnswerParser.Parsed] {
        let lines = AnswerParser.parseLines(raw)
        if !lines.isEmpty { return lines }
        return AnswerParser.isNoQuestion(raw) ? [AnswerParser.Parsed(number: nil, option: "", text: "", spoken: "")] : []
    }

    /// Toplu sayfa çekimi: sayfadaki bütün soruların cevabı (kare hızı ayarı reddedilirse ayarsız bir kez daha denenir, `answer(capture:)` gibi)
    func answerPage(capture: CapturedQuestion, expectedNumber: Int) async throws -> [GeminiReply] {
        guard !GeminiProfiles.usable(profilesProvider()).isEmpty else { throw GeminiError(Say.noKeyShort, .key) }
        let body = try GeminiAnswerService.captureBody(capture, expectedNumber: expectedNumber, page: true)
        // 75 fotoğraflık PDF (≈16 MB) hücresel veriyle yüklenir ve çok görüntü okunur: model başına bekleme iki katıdır (üç katıydı)
        let limit = capture.pageCount > 20 ? captureLimit * 2 : captureLimit
        do {
            return try await runChain(body: body, limit: limit, parse: GeminiAnswerService.parsePage)
        } catch let error as GeminiError where error.status == 400 && error.kind == .http && capture.sendsFrameRate {
            tlog("[kamera] kare hızı ayarıyla sayfa isteği reddedildi (\(error.message)); ayarsız yeniden deneniyor")
            return try await runChain(body: try GeminiAnswerService.captureBody(capture, expectedNumber: expectedNumber, fps: nil, page: true),
                                      limit: limit, parse: GeminiAnswerService.parsePage)
        }
    }

    private func run(body: Data, limit: TimeInterval) async throws -> GeminiReply {
        let replies = try await runChain(body: body, limit: limit, parse: { raw in
            let parsed = AnswerParser.parse(raw)
            return parsed.spoken.isEmpty ? [] : [parsed]
        })
        return replies[0]
    }

    /// Profil zinciri: istek sırayla her profile gönderilir (kota, sunucu hatası, gecikme, anahtar ya da model sorununda sıradakine geçilir). Hiçbiri cevap
    /// vermezse ve hatalar geçici ise (gecikme, yoğunluk, dakikalık kota) sıra BAŞTAN aynı sırayla yeniden denenir, en çok `maxRounds` tur.
    /// `parse`: model metninden cevap satırları (tek soruda bir, sayfada birkaç); boş dönerse cevap satırı verilmemiş sayılır.
    private func runChain(body: Data, limit: TimeInterval, parse: (String) -> [AnswerParser.Parsed]) async throws -> [GeminiReply] {
        let usable = GeminiProfiles.usable(profilesProvider())
        guard !usable.isEmpty else { throw GeminiError(Say.noKeyShort, .key) }
        var active = order(usable)
        var lastError = GeminiError("Gemini cevap vermedi.", .error)
        var trail: [String] = []
        var failedNames: [String] = []
        var round = 0
        roundLoop: while round < maxRounds && !active.isEmpty {
            try Task.checkCancellation()
            let factors = GeminiAnswerService.roundFactors
            let wait = limit * factors[min(round, factors.count - 1)]
            var again: [GeminiProfileInfo] = []
            for profile in active {
                do {
                    let client = makeClient(profile)
                    // Sunucu hatasında yeniden deneme ve uzun bekleme yok: hemen sıradakine geçilir; yeniden deneme turlarla yapılır
                    let object = try await client.generate(model: profile.model, key: profile.key,
                                                           body: GeminiAnswerService.body(body, forModel: profile.model),
                                                           serverRetries: 0, timeout: wait)
                    let parsedList = parse(try GeminiAnswerService.replyText(from: object))
                    if parsedList.isEmpty { throw GeminiError("Gemini cevap satırı vermedi.", .empty) }
                    restingUntil[profile.identity] = nil
                    let note = trail.isEmpty ? "" : "Cevap \(profile.name) modelinden geldi: " + trail.joined(separator: " ")
                    let spokenNote = (!profile.free && !failedNames.isEmpty) ? Say.paidModelUsed : ""
                    return parsedList.map { parsed in
                        GeminiReply(number: parsed.number, option: parsed.option, text: parsed.text,
                                    spoken: parsed.spoken, model: profile.model, note: note, spokenNote: spokenNote)
                    }
                } catch let error as GeminiError {
                    let turn = round == 0 ? "" : "[\(round + 1). tur] "
                    trail.append("\(turn)\(profile.name) (\(profile.model)): \(error.message)")
                    failedNames.append(profile.name)
                    lastError = error
                    guard GeminiAnswerService.fallbackWorthy(error) else { break roundLoop }
                    rest(profile, after: error)
                    if GeminiAnswerService.retryable(error) { again.append(profile) }
                }
            }
            active = again
            round += 1
            if active.isEmpty || round >= maxRounds { break }
            tlog("[gemini] hiçbir model cevap vermedi; \(round + 1). tur başlıyor (\(active.map { $0.name }.joined(separator: ", ")))")
            if roundPause > 0 { try await Task.sleep(nanoseconds: UInt64(roundPause * 1_000_000_000)) }
        }
        var merged = GeminiError(trail.joined(separator: " "), lastError.kind, status: lastError.status)
        merged.timedOut = lastError.timedOut
        throw merged
    }
}
