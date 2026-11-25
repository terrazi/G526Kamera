# -*- coding: utf-8 -*-
"""Ayarlar (JSON) ve gizli bilgiler (Windows DPAPI ile sifreli)."""
import base64
import ctypes
import json
import os
import threading

from .applog import log


def data_dir():
    base = os.environ.get("SK_HOME")
    if not base:
        root = os.environ.get("APPDATA") or os.path.join(os.path.expanduser("~"), ".config")
        base = os.path.join(root, "SesliKontrol")
    os.makedirs(base, exist_ok=True)
    return base


def default_local_dir():
    docs = os.path.join(os.path.expanduser("~"), "Documents")
    if not os.path.isdir(docs):
        docs = os.path.expanduser("~")
    return os.path.join(docs, "Sesli Kontrol")


# ----------------------------------------------------------------- DPAPI
class _Blob(ctypes.Structure):
    _fields_ = [("cbData", ctypes.c_ulong), ("pbData", ctypes.POINTER(ctypes.c_char))]


def _dpapi(data, protecting):
    buf = ctypes.create_string_buffer(data, len(data))
    blob_in = _Blob(len(data), ctypes.cast(buf, ctypes.POINTER(ctypes.c_char)))
    blob_out = _Blob()
    crypt32 = ctypes.windll.crypt32
    fn = crypt32.CryptProtectData if protecting else crypt32.CryptUnprotectData
    ok = fn(ctypes.byref(blob_in), None, None, None, None, 0, ctypes.byref(blob_out))
    if not ok:
        raise OSError("DPAPI hatasi")
    try:
        return ctypes.string_at(blob_out.pbData, blob_out.cbData)
    finally:
        ctypes.windll.kernel32.LocalFree(blob_out.pbData)


def protect(data):
    if os.name == "nt":
        try:
            return b"D1" + _dpapi(data, True)
        except Exception as e:  # DPAPI calismazsa bilgiler kaybolmasin
            log("[ayar] DPAPI sifreleme basarisiz (%s), kullanici klasorunde sifresiz saklanacak" % e)
    return b"P0" + base64.b64encode(data)


def unprotect(blob):
    if blob[:2] == b"D1" and os.name == "nt":
        return _dpapi(blob[2:], False)
    if blob[:2] == b"P0":
        return base64.b64decode(blob[2:])
    raise OSError("Bilinmeyen gizli veri bicimi")


SECRET_KEYS = ("camera_password", "p1_key", "p2_key", "p3_key", "p4_key")

# Varsayılanlar iPhone programının son sürümüyle (885ddbc) aynıdır: model sırası, kamera kimliği ve parolası, tarama süresi, kare hızı
DEFAULTS = {
    # ---- kaynak: sorular nereden gelir
    "source": "wifi",             # wifi: Wi-Fi kamera | webcam: USB / dizüstü kamerası | pdf: PDF dosyası
    "uid": "GHBB-526029-XJPDT",   # Wi-Fi kameranın kimliği
    "camera_ip": "",              # boş: program kendisi bulur
    "camera_password": "123456",
    "stream_quality": 1,          # 1 = Yüksek (1920x1080), 2 = Düşük (640x360)
    "webcam_device": "",          # "Kamera 1" gibi; boşsa bulunan ilk kamera
    # ---- tarama (serbest tarama: kamera sayfaların üzerinde gezdirilir)
    "scan_seconds": 60,           # bir taramanın süresi
    "scan_rate": 2,               # saniyede seçilen kare
    "thin_frames": True,          # benzer ve bulanık kareleri azalt
    "jpeg_quality": 0.85,
    "high_resolution": True,      # Gemini görüntüyü yüksek çözünürlükte okusun
    "extra_instruction": "",      # kullanıcının Gemini'ye ek talimatı (boş olabilir)
    # ---- Gemini: sırayla denenen dört model, her birinin kendi anahtarı
    "p1_name": "Ücretli Gemini 4 Argon", "p1_model": "gemini-4-argon", "p1_key": "",
    "p2_name": "Ücretli Gemini 3.8 Flash", "p2_model": "gemini-3.8-flash", "p2_key": "",
    "p3_name": "Ücretli Gemini 3.7 Flash", "p3_model": "gemini-3.7-flash", "p3_key": "",
    "p4_name": "Gemini 3.5 Flash-Lite", "p4_model": "gemini-3.5-flash-lite", "p4_key": "",
    "wait_limit": 240,            # bir modelin cevabı için beklenen süre (sn); dolunca sıradaki model denenir
    "thinking": "high",           # high: Gemini'den en yüksek düşünme düzeyi istenir | auto: modelin kendi varsayılanı
    "pdf_pages": 2,               # PDF dosyası bir istekte en çok bu kadar sayfa olarak gönderilir (az soru = daha dikkatli çözüm)
    "use_sources": False,         # soruları verilen kaynaklara göre cevapla (Kaynaklar klasörü)
    # ---- ses
    "read_answers": True,         # cevapları sesli oku
    "answer_gap": 2,              # cevaplar arasında beklenen süre (sn)
    "voice_enabled": True,        # sesli komutlar
    "voice_engine": "auto",       # auto | vosk | windows
    "mic_device": "",
    "voice_threshold": 0.55,
    "tts_engine": "windows",
    "tts_voice": "",              # boş = en uygun Türkçe Windows sesi
    "tts_rate": 0,
    # ---- dosyalar
    "local_dir": "",              # kayıt klasörü (boş = Belgelerim\Sesli Kontrol)
}

RANGES = {"stream_quality": (1, 2), "scan_seconds": (10, 300), "scan_rate": (1, 4), "jpeg_quality": (0.5, 0.95),
          "wait_limit": (20, 600), "pdf_pages": (1, 20), "answer_gap": (0, 10), "voice_threshold": (0.2, 0.95), "tts_rate": (-10, 10)}
CHOICES = {"source": ("wifi", "webcam", "pdf"), "thinking": ("high", "auto"), "voice_engine": ("auto", "vosk", "windows"), "tts_engine": ("windows",)}
NO_SPACE = ("p1_model", "p2_model", "p3_model", "p4_model", "p1_key", "p2_key", "p3_key", "p4_key")


def _clamp(v, lo, hi):
    return max(lo, min(hi, v))


def _coerce(key, value):
    """Gelen değeri anahtarın türüne ve geçerli aralığına getirir."""
    default = DEFAULTS[key]
    if isinstance(default, bool):
        if isinstance(value, str):
            return value.strip().lower() in ("1", "true", "evet", "on")
        return bool(value)
    if isinstance(default, int):
        value = int(float(value))
    elif isinstance(default, float):
        value = float(value)
    else:
        value = str(value if value is not None else "")
    if key in RANGES:
        value = _clamp(value, *RANGES[key])
    if key in CHOICES and value not in CHOICES[key]:
        value = default
    if isinstance(value, str):
        value = "".join(value.split()) if key in NO_SPACE else value.strip()
    return value


class Settings:
    def __init__(self, directory=None):
        self.dir = directory or data_dir()
        self._lock = threading.RLock()
        self._values = dict(DEFAULTS)
        self._path = os.path.join(self.dir, "ayarlar.json")
        self._secret_path = os.path.join(self.dir, "gizli.bin")
        self._load()

    def _load(self):
        try:
            with open(self._path, "r", encoding="utf-8") as f:
                data = json.load(f)
            for k, v in data.items():
                if k in DEFAULTS and k not in SECRET_KEYS:
                    try:
                        self._values[k] = _coerce(k, v)
                    except (ValueError, TypeError):
                        pass
            # 4.0'dan kalan ayar dosyası ("thinking" yok): eski varsayılan bekleme süresi (150 sn) yüksek düşünme düzeyine kısa gelir
            if "thinking" not in data and data.get("wait_limit") == 150:
                self._values["wait_limit"] = DEFAULTS["wait_limit"]
        except (OSError, ValueError):
            pass
        try:
            with open(self._secret_path, "rb") as f:
                secrets = json.loads(unprotect(f.read()).decode("utf-8"))
            for k in SECRET_KEYS:
                if k in secrets:
                    self._values[k] = str(secrets[k])
        except FileNotFoundError:
            pass
        except Exception as e:
            log("[ayar] gizli bilgiler okunamadi: %s" % e)

    def _save(self):
        plain = {k: v for k, v in self._values.items() if k not in SECRET_KEYS}
        secrets = {k: self._values[k] for k in SECRET_KEYS}
        try:
            tmp = self._path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(plain, f, ensure_ascii=False, indent=2)
            os.replace(tmp, self._path)
            tmp = self._secret_path + ".tmp"
            with open(tmp, "wb") as f:
                f.write(protect(json.dumps(secrets).encode("utf-8")))
            os.replace(tmp, self._secret_path)
        except OSError as e:
            log("[ayar] kaydedilemedi: %s" % e)

    def get(self, key):
        with self._lock:
            return self._values[key]

    def __getitem__(self, key):
        return self.get(key)

    def update(self, changes):
        """Geçerli anahtarları günceller; değişen anahtarların listesini döndürür."""
        changed = []
        with self._lock:
            for k, v in changes.items():
                if k not in DEFAULTS:
                    continue
                try:
                    nv = _coerce(k, v)
                except (ValueError, TypeError):
                    continue
                if self._values[k] != nv:
                    self._values[k] = nv
                    changed.append(k)
            if changed:
                self._save()
        return changed

    def local_dir(self):
        return self.get("local_dir") or default_local_dir()

    def view(self):
        """Arayüze giden ayarlar. Anahtarlar açık yazıyla gider (kullanıcı kararı: gizlenmesin); arayüz yalnız bu bilgisayardan açılır."""
        with self._lock:
            out = dict(self._values)
            out["local_dir_effective"] = self.local_dir()
            return out
