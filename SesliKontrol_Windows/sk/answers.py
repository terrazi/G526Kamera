# -*- coding: utf-8 -*-
"""Soruları Gemini'ye sorar ve cevap satırlarını ayrıştırır. iPhone programındaki AnswerService / AnswerParser'ın karşılığıdır:
aynı talimat, aynı cevap biçimi ("Soru N, şık sözcüğü, cevap metni"), aynı model sırası ve kaynak deposu davranışı."""
import re
import time

from . import gemini as G
from . import prompts as PR
from .applog import log

INLINE_LIMIT = 10_000_000       # bundan büyük PDF isteğin içine konmaz, Gemini'ye dosya olarak yüklenir
ROUNDS = 2                      # bütün modeller geçici hata verirse sıra bir kez daha denenir
ROUND_PAUSE = 3.0

# PDF dosyasıyla gelen sorular için sistem komutu: cevap biçimi kamera taramasıyla aynıdır (iPhone talimatından uyarlanmıştır)
DOC_SYSTEM = (
    "Sen bir sınav okuyucu asistansın. Mesajda bir soru belgesi (PDF) var: içinde çoktan seçmeli sınav soruları, bazen soru grubuna ortak "
    "paragraflar vardır. Belge düzgün bir dosyadır (kamera karesi değildir); sayfalar sırayla okunur, sayfa çoğu zaman iki sütundur: "
    "sorular önce sol sütunda yukarıdan aşağı, sonra sağ sütunda devam eder.\n\n"
    "Belgedeki BÜTÜN soruları (paragraflara bağlı sorular dahil) oku, her birini çöz ve HER SORU İÇİN AYRI BİR SATIR yaz, "
    "soru numarasına göre küçükten büyüğe. Her satırın biçimi: Soru [numara], [şık sözcüğü], [doğru cevabın metni]. Örnek (iki soru):\n"
    "Soru 4, Denizli, Örgütsel Davranış\nSoru 5, Adana, Yönetim\n\n"
    "Şıklar: A=Adana, B=Bursa, C=Ceyhan, D=Denizli, E=Erzurum. Şık için HER ZAMAN bu sözcüğü yaz, harf yazma. "
    "Belgede şıklar A, B, C, D, E harfleriyle basılıdır; hangi harfin hangi sözcüğe denk geldiğini karıştırma.\n\n"
    "Soru numaralarını belgeden oku ve aynen yaz. Bir soru iki sayfaya ya da iki sütuna bölünmüşse parçalarını birleştir. "
    "Birkaç soruya ortak bir paragraf varsa paragrafı oku ve o sorulara paragrafa dayanarak cevap ver; paragrafın kendisi için satır yazma. "
    "Her soruyu YALNIZ BİR KEZ cevapla; soru olmayan yerler (kapak, yönerge, cevap anahtarı, üst ve alt bilgi) için satır yazma. "
    "Cevap metnini şıktan kısaca yaz. Giriş, açıklama, markdown, madde işareti, tırnak ve ek cümle yazma: yalnız soru satırları. "
    "Doğru şıktan emin değilsen en olası şıkkı yaz.\n"
    "Belgede hiç soru yoksa başka hiçbir şey yazmadan yalnız şunu yaz: SORU YOK"
)


# Çözüm kuralları (2026-11-25): okuma talimatına eklenir. Neden: 30 soruluk ALES sayısal denemesinde model 13 soruyu aceleyle, işlem
# yapmadan ve sorunun kendi koşullarıyla çelişen şıklarla cevaplamıştı. Cevap biçimi değişmez; kurallar yalnız nasıl çözüleceğini anlatır.
SOLVE_SECTION = (
    "ÇÖZÜM KURALLARI (her soruya uygula; cevap biçimi yukarıda anlatıldığı gibidir, burada yalnız NASIL çözeceğin anlatılır).\n\n"
    "GENEL: Soru kökünü ve beş şıkkı sonuna kadar oku. Kökteki olumsuz ve sınırlayıcı sözlere özellikle dikkat et: değildir, olamaz, "
    "yanlıştır, söylenemez, ulaşılamaz, hangisi dışında, en az, en fazla, kesinlikle, her zaman, yalnız. Önce kendi sonucunu bul, sonra "
    "şıklarla karşılaştır; diğer şıkların neden yanlış olduğunu da denetle. Yazmadan önce seçtiğin şıkkın sorudaki BÜTÜN koşulları "
    "sağladığını bir kez daha kontrol et. İlk akla gelen şıkkı yazma. Sorular çok diye sonrakileri yüzeysel geçme: her soruya ayrı ve tam "
    "düşünme payı ayır. Ortak bir bilgiye ya da paragrafa bağlı soru gruplarında (örneğin \"25. - 26. soruları aşağıdaki bilgilere göre "
    "cevaplayınız\") ortak bilgiyi o grubun her sorusunda yeniden kullan.\n\n"
    "SAYISAL (matematik, geometri, sayısal mantık, tablo ve grafik): İşlemi adım adım yap; işlem önceliğine, artı-eksi işaretine, üs, kök, "
    "mutlak değer ve kesir yazımına dikkat et. Sözel problemde bilinmeyenleri tanımla, denklemi kur ve çöz. Bulduğun değer şıklarda yoksa "
    "çözümü baştan kontrol et; şıklarda olmayan bir değeri cevap diye yazma ve yazdığın değer seçtiğin şıktaki değerle aynı olsun. Sonucu "
    "soruya geri koyup sağlamasını yap. Şekil, tablo ve grafikteki değerleri (açı, yüzde, etiket, hangi harfin hangi sayıyla eşleştiği) "
    "dikkatle oku. \"En az, en çok, kesinlikle, olamaz\" sorularında bütün durumları tek tek dene.\n\n"
    "TÜRKÇE VE SÖZEL (sözcükte ve cümlede anlam, paragraf, dil bilgisi, yazım ve noktalama, sözel mantık): Paragraf sorularında yalnız "
    "metinde söylenene dayan; metinde olmayan bilgiyi ya da kendi yorumunu katma. \"Değinilmemiştir, çıkarılamaz\" sorularında her şıkkın "
    "metindeki karşılığını ara. Numaralanmış cümlelerde ve altı çizili sözlerde numara ile cümleyi karıştırma. Boşluk doldurmada anlamı ve "
    "dil bilgisi uyumunu birlikte denetle. Sözel mantıkta verilen koşulları tek tek sırala ve hepsini birden sağlayan durumu bul.\n\n"
    "İNGİLİZCE (YDS, YÖKDİL, açıköğretim İngilizce ve benzeri): Soru İngilizce ise İngilizce olarak çöz. Boşluk doldurmada zaman, kip, "
    "edilgenlik, bağlaç, edat ve sözcük öbeği uyumunu; paragrafta anlam bütünlüğünü; çeviride özne, zaman, bağlaç ve bütün bilgi "
    "öğelerinin korunmasını (eksik ya da fazla bilgi olmamalı); \"anlamca en yakın cümle\"de anlamın tam karşılanmasını; diyalog ve "
    "paragraf tamamlamada önceki ve sonraki cümleyle bağlantıyı denetle. Cevap metnini şıktaki İngilizce ifadeyle kısaca yaz.\n\n"
    "ALAN BİLGİSİ (açıköğretim dersleri; özellikle Türk Dili ve Edebiyatı: eski Türk edebiyatı, halk edebiyatı, yeni Türk edebiyatı, "
    "Türk dilinin tarihî dönemleri, çağdaş Türk yazı dilleri ve edebiyatları, dil bilgisi): Sorular ders kitabındaki bilgiye göre "
    "hazırlanır. Eser-yazar, dönem-yüzyıl, akım-temsilci, tür-özellik ve terim-tanım eşleşmelerinde benzer adları karıştırma (aynı adlı "
    "eserler, aynı mahlaslı şairler, birbirine yakın yüzyıllar); her şıktaki bilgiyi ayrı ayrı doğrula. \"Hangisi değildir, yanlıştır\" "
    "sorularında doğru olan dördünü bulup yanlış olanı seç. Emin olamadığında en güçlü kanıtı olan şıkkı yaz."
)


def _sw(text, **values):
    """Swift dizgisini Python'a çevirir: \\n, \\" kaçışları ve \\(ad) yer tutucuları."""
    out = text.replace("\\n", "\n").replace('\\"', '"')
    for name, value in values.items():
        out = out.replace("\\(%s)" % name, str(value))
    return out


def page_text(expected, pages, labels, extra=""):
    """Kamera taraması için kullanıcı mesajı (görüntüden sonra gelir); iPhone'daki pageText ile aynı cümleler."""
    s = PR.PAGE_TEXT_STRINGS
    text = _sw(s[0], expectedNumber=expected)
    text += _sw(s[4], pages=pages) + _sw(s[1]) + _sw(s[5])
    if pages > 0 and len(labels) == pages and "" not in labels:
        listing = "; ".join("%d) %s" % (i + 1, label) for i, label in enumerate(labels))
        text += _sw(s[11]) + _sw(s[12]) + _sw(s[13]) + listing + _sw(s[14]) + _sw(s[15]) + _sw(s[16]) + _sw(s[17])
    note = (extra or "").strip()
    if note:
        text += _sw(s[18], note=note)
    return text


def doc_text(expected, name="", extra="", pages=None):
    """PDF dosyası için kullanıcı mesajı: programın çözüm isteği ve açıklaması ayrıca metin olarak gider. `pages`: (ilk, son, toplam)
    verilirse bu PDF'in belgenin bir parçası olduğu söylenir."""
    text = ("Ekteki PDF bir soru belgesidir%s. Belgedeki bütün soruları çöz ve her biri için ayrı satır yaz. "
            % ((" (dosya adı: %s)" % name) if name else ""))
    if expected:
        text += ("İpucu: belgede soru numarası okunamıyorsa ilk soruya Soru %d de ve sırayla devam et; numara okunuyorsa okunan "
                 "numaraya uy." % expected)
    else:
        text += "Soru numaralarını belgeden oku ve aynen yaz."
    if pages and pages[2] > pages[1] - pages[0] + 1:
        text += (" Bu PDF, %d sayfalık belgenin %d-%d. sayfalarıdır; yalnız bu sayfalardaki soruları cevapla. Sayfanın başında ya da "
                 "sonunda yarım kalan bir soru varsa görünen kısmına göre en olası şıkkı yaz." % (pages[2], pages[0], pages[1]))
    note = (extra or "").strip()
    if note:
        text += "\n\nKullanıcının ek talimatı: " + note
    return text


# ----------------------------------------------------------------- cevap satırları
_HEAD = re.compile(r"^\s*(?:soru(?:\s*(?:no|numara|numarası))?\s*[:\.\-–—]?\s*)?(\d+)\s*[\.\)]?(?:\s*soru(?:su)?\b)?", re.I)
_SEPARATORS = ",-–—:;"
_JUNK = str.maketrans("", "", "*`[]#_")


# Model kimi zaman şık sözcüğü yerine aynı harfle başlayan başka bir şehir yazıyor (E için "Edirne"); sözcük beklenene çevrilir.
# Yalnız satırda cevap metni de varsa uygulanır: şıksız bir sorunun cevabı şehir adı olabilir ("Soru 3, Ankara"), ona dokunulmaz.
OPTION_WORDS = {"a": "Adana", "b": "Bursa", "c": "Ceyhan", "d": "Denizli", "e": "Erzurum"}
_STRAY_CITIES = {"ankara": "a", "antalya": "a", "aydın": "a", "amasya": "a", "balıkesir": "b", "bolu": "b", "bilecik": "b", "burdur": "b",
                 "diyarbakır": "d", "düzce": "d", "edirne": "e", "eskişehir": "e", "elazığ": "e", "erzincan": "e"}


def _lower(text):
    return text.replace("I", "ı").replace("İ", "i").lower()


def fix_option(option, text):
    """Şık sözcüğünü beklenen beş sözcükten birine getirir: tek harf ("E", "E şıkkı") ya da aynı harfli başka şehir -> Erzurum."""
    word = _lower(option.strip().rstrip(".)"))
    if word.endswith(" şıkkı"):
        word = word[:-6].strip()
    if not text:
        return option
    if word in OPTION_WORDS:
        return OPTION_WORDS[word]
    if word in _STRAY_CITIES:
        return OPTION_WORDS[_STRAY_CITIES[word]]
    return option


def parse(raw):
    """Tek cevap satırı -> {"number","option","text","spoken"}"""
    line = raw.translate(_JUNK).strip().split("\n")[0].strip()
    number, rest = None, line
    m = _HEAD.match(line)
    if m:
        number = int(m.group(1))
        rest = line[m.end():]
    rest = rest.lstrip(" \t" + _SEPARATORS)
    option, text = rest.strip(), ""
    for i, ch in enumerate(rest):
        if ch in _SEPARATORS:
            option, text = rest[:i].strip(), rest[i + 1:].strip(" \t\r\n" + _SEPARATORS)
            break
    option = fix_option(option, text)
    spoken = line
    if number is not None and option:
        spoken = "Soru %d, %s" % (number, option) + (", " + text if text else "")
    elif number is None and option and text:
        spoken = "%s, %s" % (option, text)
    return {"number": number, "option": option, "text": text, "spoken": spoken}


def is_no_question_line(line):
    return line.strip(" \t.,;:!?\"'()-–—").lower() == "soru yok"


def is_no_question(raw):
    return any(is_no_question_line(part) for part in raw.translate(_JUNK).split("\n"))


def parse_lines(raw):
    """Çok satırlı cevap: her dolu satır ayrı çözülür; aynı numara ikinci kez gelirse ilki kalır."""
    out, seen = [], set()
    for part in raw.translate(_JUNK).split("\n"):
        line = part.strip()
        if not line or is_no_question_line(line):
            continue
        item = parse(line)
        if not item["spoken"]:
            continue
        if item["number"] is not None:
            if item["number"] in seen:
                continue
            seen.add(item["number"])
        out.append(item)
    return out


# ----------------------------------------------------------------- model sırası
def profiles(settings):
    """Kullanılabilir (anahtarı ve modeli dolu) profiller, yuva sırasıyla."""
    out = []
    for n in (1, 2, 3, 4):
        key, model = settings["p%d_key" % n].strip(), settings["p%d_model" % n].strip()
        if key and model:
            out.append({"slot": n, "name": settings["p%d_name" % n].strip() or model, "model": model, "key": key})
    return out


def source_rejection(error):
    """Kaynak depolu istek bu hatayla reddedildiyse kaynaksız yeniden denemeye değer mi (geçersiz anahtar hariç 400/403/404)."""
    if error.status == 400 and error.kind == "key":
        return False
    return error.status in (400, 403, 404)


def with_sources(body, store):
    """İsteğe dosya arama aracını ve kaynak talimatını ekler."""
    out = dict(body)
    out["tools"] = list(out.get("tools") or []) + [{"file_search": {"file_search_store_names": [store]}}]
    system = dict(out.get("systemInstruction") or {})
    system["parts"] = list(system.get("parts") or []) + [{"text": PR.SOURCE_INSTRUCTION}]
    out["systemInstruction"] = system
    return out


class Reply:
    def __init__(self, answers, model, raw, no_question=False, sources="", notes=None):
        self.answers = answers          # parse_lines çıktısı
        self.model = model              # cevabı veren profilin adı
        self.raw = raw
        self.no_question = no_question  # Gemini "SORU YOK" dedi
        self.sources = sources          # kaynak kullanım satırı (kaynak yoksa "")
        self.notes = notes or []        # kullanıcıya gösterilecek uyarılar


class AnswerService:
    """Sıradaki modele sorar; hata ya da gecikmede bir sonrakine geçer (iPhone'daki model zinciri)."""

    def __init__(self, settings, source_store=None, on_source_rejected=None, sleep=time.sleep):
        self.s = settings
        self.source_store = source_store or (lambda key: None)        # anahtar -> hazır depo adı ya da None
        self.on_source_rejected = on_source_rejected or (lambda key, error: None)
        self.sleep = sleep
        self._refused = set()           # bu çalıştırmada kaynak depolu isteği reddeden profiller (anahtar|model)

    def sources_changed(self):
        self._refused.clear()

    def _visual(self, pdf, name, profile, cache):
        """PDF parçası: küçükse isteğin içinde, büyükse Gemini'ye dosya olarak yüklenip adresiyle (anahtar başına bir kez)."""
        if len(pdf) <= INLINE_LIMIT:
            return {"inlineData": {"mimeType": "application/pdf", "data": G.b64(pdf)}}
        if profile["key"] not in cache:
            began = time.monotonic()
            cache[profile["key"]] = G.upload_file(pdf, "application/pdf", name, profile["key"])
            log("[gemini] PDF dosya olarak yuklendi (%.1f MB, %d sn)" % (len(pdf) / 1e6, int(time.monotonic() - began)))
        return {"fileData": {"mimeType": "application/pdf", "fileUri": cache[profile["key"]]}}

    def ask(self, pdf, system, user_text, name="sorular.pdf", cancelled=lambda: False):
        """PDF'i ve talimatı modellere sırayla sorar. Dönüş: Reply. Hiçbiri cevap vermezse GeminiError."""
        chain = profiles(self.s)
        if not chain:
            raise G.GeminiError("Gemini API anahtarı girilmemiş. Ayarlar > Gemini bölümünden yapıştırın.", "key")
        limit = float(self.s["wait_limit"])
        files, last, notes = {}, None, []
        for round_no in range(ROUNDS):
            retry = False
            for profile in chain:
                if cancelled():
                    raise G.GeminiError("Durduruldu.", "error")
                ident = profile["key"] + "|" + profile["model"]
                store = None if ident in self._refused else self.source_store(profile["key"])
                try:
                    body = {"systemInstruction": {"parts": [{"text": system}, {"text": SOLVE_SECTION}]},
                            "contents": [{"role": "user", "parts": [self._visual(pdf, name, profile, files), {"text": user_text}]}]}
                    if self.s["high_resolution"]:
                        body["generationConfig"] = {"mediaResolution": "MEDIA_RESOLUTION_HIGH"}
                    began = time.monotonic()
                    try:
                        obj = G.generate(profile["model"], profile["key"], with_sources(body, store) if store else body, limit, self.s["thinking"])
                    except G.GeminiError as e:
                        if not store or not source_rejection(e):
                            raise
                        # Aynı istek kaynaksız kabul edilirse reddin nedeni depodur: profil bu çalıştırmada kaynaksız sorulur
                        log("[kaynak] kaynak depolu istek reddedildi (HTTP %d: %s); %s kaynaksiz yeniden deneniyor"
                            % (e.status, e.message, profile["name"]))
                        obj = G.generate(profile["model"], profile["key"], body, limit, self.s["thinking"])
                        self._refused.add(ident)
                        self.on_source_rejected(profile["key"], e)
                        notes.append("Gemini kaynak deposunu kabul etmedi; cevap kaynaksız verildi.")
                        store = None
                    raw = G.reply_text(obj)
                    answers = parse_lines(raw)
                    none = is_no_question(raw)
                    if not answers and not none:
                        raise G.GeminiError("Gemini cevap satırı vermedi.", "empty")
                    sources = ""
                    if store:
                        sources = G.source_use_text(G.source_use(obj))
                        log("[kaynak] " + sources)
                    log("[gemini] %s cevapladi: %d soru, %d sn" % (profile["name"], len(answers), int(time.monotonic() - began)))
                    if profile is not chain[0]:
                        notes.append("Cevap %s modelinden geldi." % profile["name"])
                    return Reply(answers, profile["name"], raw, none, sources, notes)
                except G.GeminiError as e:
                    last = e
                    log("[gemini] %s cevap veremedi: %s" % (profile["name"], e.message))
                    if e.kind == "key" and len(chain) == 1:
                        raise
                    retry = retry or e.kind in ("network", "quota", "empty") or e.status in (500, 502, 503, 504)
            if not retry or round_no + 1 >= ROUNDS:
                break
            self.sleep(ROUND_PAUSE)
        raise last or G.GeminiError("Gemini cevap vermedi.", "error")
