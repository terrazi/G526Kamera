# -*- coding: utf-8 -*-
"""Gemini API istemcisi (yalnız standart kitaplık): cevap isteği, dosya yükleme (Files API) ve kaynak deposu (File Search).
iPhone programındaki Gemini.swift ve GeminiSources.swift ile aynı adresleri, alan adlarını ve hata iletilerini kullanır."""
import base64
import io
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
import wave

from . import netfast
from .applog import log

API = os.environ.get("SK_GEMINI_BASE") or "https://generativelanguage.googleapis.com/v1beta"


class GeminiError(Exception):
    """kind: key | quota | model | network | http | empty | error"""

    def __init__(self, message, kind="error", status=0, timed_out=False):
        super().__init__(message)
        self.message = message
        self.kind = kind
        self.status = status
        self.timed_out = timed_out


def wav_bytes(pcm, rate=16000, channels=1):
    """talk.py'nin kullandığı yardımcı: ham 16 bit sesi WAV dosyası baytlarına çevirir."""
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm)
    return buf.getvalue()


def base_url():
    return (os.environ.get("SK_GEMINI_BASE") or API).rstrip("/")


def upload_base():
    """".../v1beta" -> ".../upload/v1beta" (Files API ve kaynak deposu yüklemeleri)"""
    base = base_url()
    head, _, version = base.rpartition("/")
    return head + "/upload/" + version


def describe_error(status, obj, model=""):
    """Google'ın hata cevabından kullanıcıya gösterilecek ileti ve hata türü."""
    err = obj.get("error") if isinstance(obj, dict) else None
    message = str((err or {}).get("message") or "").strip()
    low = message.lower()
    short = message[:200]
    if status == 400 and ("api key" in low or "api_key" in low):
        return "key", "Gemini API anahtarı geçersiz. Ayarlardan anahtarı denetleyin."
    if status in (401, 403):
        return "key", "Gemini bu anahtarı kabul etmedi (%d)%s" % (status, ": " + short if short else ".")
    if status == 404:
        return "model", "Model bulunamadı%s%s" % (" (" + model + ")" if model else "", ": " + short if short else ".")
    if status == 429:
        return "quota", "Gemini kotası doldu ya da çok sık istek gönderildi%s" % (": " + short if short else ".")
    if status in (500, 502, 503, 504):
        return "http", "Gemini şu anda yoğun ya da ulaşılamıyor (%d)." % status
    return "http", "Gemini isteği kabul etmedi (%d)%s" % (status, ": " + short if short else ".")


def call(method, url, key, body=None, headers=None, timeout=60.0):
    """Tek HTTP isteği. Dönüş: (durum, başlıklar-küçük-harf, gövde). Ağ hatası GeminiError('network') olur."""
    api_key = (key or "").strip()
    if not api_key:
        raise GeminiError("Gemini API anahtarı girilmemiş. Ayarlardan yapıştırın.", "key")
    req = urllib.request.Request(url, data=body, method=method)
    req.add_header("x-goog-api-key", api_key)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    if body is not None and not any(k.lower() == "content-type" for k in (headers or {})):
        req.add_header("Content-Type", "application/json")
    try:
        with netfast.urlopen(req, timeout=timeout) as r:
            return r.status, {k.lower(): v for k, v in r.headers.items()}, r.read()
    except urllib.error.HTTPError as e:
        data = b""
        try:
            data = e.read()
        except Exception:
            pass
        return e.code, {k.lower(): v for k, v in (e.headers or {}).items()}, data
    except (urllib.error.URLError, OSError, ValueError) as e:
        reason = getattr(e, "reason", e)
        timed = "timed out" in str(reason).lower() or isinstance(reason, TimeoutError)
        if timed:
            raise GeminiError("Gemini %d sn içinde cevap vermedi." % int(timeout), "network", timed_out=True)
        raise GeminiError("İnternete ulaşılamadı: %s" % reason, "network")


def _json(data):
    try:
        obj = json.loads(data.decode("utf-8")) if data else {}
    except (ValueError, UnicodeDecodeError):
        obj = {}
    return obj if isinstance(obj, dict) else {}


def _checked(status, data, model="", prefix=""):
    obj = _json(data)
    if 200 <= status < 300:
        return obj
    kind, message = describe_error(status, obj, model)
    raise GeminiError(prefix + message, kind, status)


# ----------------------------------------------------------------- cevap isteği
def thinking_level(model, setting="auto"):
    """İsteğe konacak thinkingLevel ya da None (iPhone'daki kuralın aynısı). "high": Gemini 3 ve sonrası ile Gemma'da "high" istenir;
    Gemini 2.x bu ayarı tanımaz, ona gönderilmez. "auto": yalnız Gemma'da "high" (Gemma düşünmeyi bu ayarla açar), Gemini'de modelin
    kendi varsayılanı (Gemini 4 Argon'da orta, Flash-Lite'ta en düşük)."""
    name = (model or "").lower().replace("models/", "")
    if setting != "high":
        return "high" if name.startswith("gemma") else None
    return None if name.startswith("gemini-2") else "high"


_no_thinking = set()        # düşünme ayarını geri çeviren modeller: bu çalıştırmada ayar onlara gönderilmez


def generate(model, key, body, timeout=150.0, thinking="auto"):
    """generateContent. `body` sözlüktür; dönüş Google'ın cevabı (sözlük). Model düşünme ayarını reddederse ayarsız yeniden denenir."""
    name = (model or "").strip().replace("models/", "")
    if not name:
        raise GeminiError("Model adı girilmemiş.", "model")
    url = "%s/models/%s:generateContent" % (base_url(), urllib.parse.quote(name, safe="-._"))
    level = None if name in _no_thinking else thinking_level(name, thinking)
    obj = dict(body)
    if level:
        config = dict(obj.get("generationConfig") or {})
        config["thinkingConfig"] = {"thinkingLevel": level}
        obj["generationConfig"] = config
    status, _, data = call("POST", url, key, json.dumps(obj).encode("utf-8"), timeout=timeout)
    if level and status == 400 and "thinking" in data.decode("utf-8", "replace").lower():
        log("[gemini] %s dusunme ayarini kabul etmedi; ayarsiz yeniden deneniyor" % name)
        _no_thinking.add(name)
        status, _, data = call("POST", url, key, json.dumps(body).encode("utf-8"), timeout=timeout)
    return _checked(status, data, name)


def reply_text(obj):
    """Cevabın metni. Boşsa nedeniyle birlikte GeminiError('empty')."""
    candidates = obj.get("candidates") or []
    if not candidates:
        reason = str(((obj.get("promptFeedback") or {}).get("blockReason")) or "")
        raise GeminiError("Gemini cevap vermedi%s." % (" (" + reason + ")" if reason else ""), "empty")
    cand = candidates[0]
    parts = ((cand.get("content") or {}).get("parts")) or []
    text = "".join(str(p.get("text") or "") for p in parts if isinstance(p, dict) and not p.get("thought")).strip()
    if not text:
        raise GeminiError("Gemini boş cevap verdi (%s)." % (cand.get("finishReason") or "neden bildirilmedi"), "empty")
    return text


def source_use(obj):
    """Cevabın dayandığı kaynak parçaları: [(belge adı, parça sayısı)] çoktan aza."""
    candidates = obj.get("candidates") or []
    if not candidates:
        return []
    meta = candidates[0].get("groundingMetadata") or candidates[0].get("grounding_metadata") or {}
    counts = {}
    for chunk in meta.get("groundingChunks") or meta.get("grounding_chunks") or []:
        ctx = chunk.get("retrievedContext") or chunk.get("retrieved_context") or {}
        title = str(ctx.get("title") or "").strip() or "adsız belge"
        counts[title] = counts.get(title, 0) + 1
    return sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))


def source_use_text(use):
    if not use:
        return "bu cevapta kaynaklardan parça gelmedi (Gemini kendi bilgisiyle cevapladı)"
    return "cevap %d kaynak parçasına dayandı: %s" % (sum(n for _, n in use), ", ".join("%s ×%d" % kv for kv in use))


def test_key(model, key, timeout=30.0):
    """Anahtar ve model çalışıyor mu: kısa bir istek gönderir. Dönüş: (tamam mı, ileti)."""
    try:
        obj = generate(model, key, {"contents": [{"role": "user", "parts": [{"text": "Yalnız şunu yaz: tamam"}]}]}, timeout)
        reply_text(obj)
        return True, "Anahtar çalışıyor (%s)." % model
    except GeminiError as e:
        return False, e.message


# ----------------------------------------------------------------- iki adımlı yükleme (Files API ve kaynak deposu aynı yolu kullanır)
def _resumable(start_url, meta, data, mime, key, timeout):
    headers = {"X-Goog-Upload-Protocol": "resumable", "X-Goog-Upload-Command": "start",
               "X-Goog-Upload-Header-Content-Length": str(len(data)), "X-Goog-Upload-Header-Content-Type": mime,
               "Content-Type": "application/json"}
    status, head, body = call("POST", start_url, key, json.dumps(meta).encode("utf-8"), headers, timeout=60.0)
    _checked(status, body, prefix="Yükleme başlatılamadı: ")
    target = (head.get("x-goog-upload-url") or "").strip()
    if not target:
        raise GeminiError("Yükleme adresi gelmedi.", "error", status)
    headers = {"Content-Type": mime, "X-Goog-Upload-Offset": "0", "X-Goog-Upload-Command": "upload, finalize"}
    status, _, body = call("POST", target, key, data, headers, timeout=timeout)
    return _checked(status, body, prefix="Dosya yüklenemedi: ")


def upload_limit(size):
    """Yükleme için süre sınırı: 120 sn + MB başına 10 sn."""
    return 120.0 + size / 1_000_000.0 * 10.0


def upload_file(data, mime, name, key, sleep=time.sleep):
    """Dosyayı Gemini'ye yükler (Files API; Google 48 saat saklar). Dönüş: isteğe yazılacak dosya adresi (uri)."""
    obj = _resumable(upload_base() + "/files", {"file": {"displayName": name}}, data, mime, key, upload_limit(len(data)))
    info = obj.get("file") or {}
    uri, state, ident = info.get("uri") or "", str(info.get("state") or "ACTIVE").upper(), info.get("name") or ""
    tries = 0
    while state == "PROCESSING" and ident and tries < 30:      # büyük PDF'i Google bir süre işler
        sleep(2.0)
        tries += 1
        status, _, body = call("GET", "%s/%s" % (base_url(), ident), key, timeout=30.0)
        info = _checked(status, body)
        uri, state = info.get("uri") or uri, str(info.get("state") or "ACTIVE").upper()
    if not uri or state == "FAILED":
        raise GeminiError("Gemini yüklenen dosyayı işleyemedi.", "error")
    return uri


# ----------------------------------------------------------------- kaynak deposu (File Search)
def _source(method, path, key, body=None, timeout=60.0):
    status, _, data = call(method, base_url() + "/" + path, key, None if body is None else json.dumps(body).encode("utf-8"),
                           timeout=timeout)
    if 200 <= status < 300:
        return _json(data)
    obj = _json(data)
    if status == 404:
        message = str(((obj.get("error") or {}).get("message")) or "").strip()
        raise GeminiError("Depo ya da belge bulunamadı (404)" + (": " + message[:160] if message else "."), "http", 404)
    kind, message = describe_error(status, obj)
    raise GeminiError(message, kind, status)


def _page_query(token):
    return "&pageToken=" + urllib.parse.quote(token, safe="-._") if token else ""


def source_store(saved, title, key):
    """Kullanılacak depo: kayıtlı depo duruyorsa o; yoksa aynı adlı depo; o da yoksa yenisi açılır."""
    known = (saved or "").strip()
    if known:
        try:
            name = str(_source("GET", known, key).get("name") or "").strip()
            return name or known
        except GeminiError as e:
            if e.status not in (400, 403, 404):
                raise
            log("[kaynak] kayitli depo bulunamadi (%s); ayni adli depo araniyor" % e.message)
    token, pages = "", 0
    while True:
        obj = _source("GET", "fileSearchStores?pageSize=20" + _page_query(token), key)
        for item in obj.get("fileSearchStores") or []:
            if str(item.get("displayName") or "") == title and item.get("name"):
                return str(item["name"])
        token, pages = str(obj.get("nextPageToken") or "").strip(), pages + 1
        if not token or pages >= 10:
            break
    name = str(_source("POST", "fileSearchStores", key, {"displayName": title}).get("name") or "").strip()
    if not name:
        raise GeminiError("Kaynak deposu açıldı ama adı okunamadı.", "error")
    log("[kaynak] yeni depo acildi: %s" % name)
    return name


def _int(value):
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return None


def source_documents(store, key):
    """Depodaki belgeler: [{"id","title","state","bytes"}] (sayfa sayfa okunur)."""
    out, token, pages = [], "", 0
    while True:
        obj = _source("GET", "%s/documents?pageSize=20%s" % (store, _page_query(token)), key)
        for item in obj.get("documents") or []:
            ident = str(item.get("name") or "").strip()
            if ident:
                out.append({"id": ident, "title": str(item.get("displayName") or ""),
                            "state": str(item.get("state") or "STATE_UNSPECIFIED").upper(), "bytes": _int(item.get("sizeBytes"))})
        token, pages = str(obj.get("nextPageToken") or "").strip(), pages + 1
        if not token or pages >= 50:
            return out


def delete_source_document(ident, key):
    """Belgeyi (parçalarıyla) depodan siler; zaten yoksa silinmiş sayılır."""
    try:
        _source("DELETE", ident + "?force=true", key)
    except GeminiError as e:
        if e.status != 404:
            raise


def parse_operation(obj):
    """Yükleme işlemi cevabı: (adı, bitti mi, hata iletisi)."""
    obj = obj.get("operation") if isinstance(obj.get("operation"), dict) else obj
    name = str(obj.get("name") or "").strip()
    error = ""
    if isinstance(obj.get("error"), dict):
        error = str(obj["error"].get("message") or "").strip()[:200] or "Google dosyayı işleyemedi"
    return (name if "operations/" in name else ""), bool(obj.get("done")) or bool(error), error


def upload_source(data, mime, title, store, key):
    """Dosyayı kaynak deposuna yükler; Google arka planda parçalayıp dizinler. Dönüş: parse_operation gibi."""
    url = "%s/%s:uploadToFileSearchStore" % (upload_base(), store)
    return parse_operation(_resumable(url, {"displayName": title, "mimeType": mime}, data, mime, key, upload_limit(len(data))))


def wait_source_operation(name, key, limit, pause=3.0, sleep=time.sleep):
    """İşlem bitene kadar sorar. None: bitti ya da öğrenilemedi (son durum depo listesinden okunur); metin: Google'ın hatası."""
    if not name:
        return None
    waited = 0.0
    while waited < limit:
        sleep(pause)
        waited += pause
        try:
            _, done, error = parse_operation(_source("GET", name, key, timeout=30.0))
        except GeminiError:
            return None
        if done:
            return error or None
    return None


def b64(data):
    return base64.b64encode(data).decode("ascii")
