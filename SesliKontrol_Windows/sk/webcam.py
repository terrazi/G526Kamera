"""Bilgisayara bagli USB / dizustu kamerasi: G526 kameranin alternatifi.
OpenCV ile okunur (Windows'ta once DirectShow, olmazsa Media Foundation). Kareler H.264 cozucuyu atlayip dogrudan
uygulamaya verilir; sonrasi (kare saklama, hareket, konumlandirma, cekim) G526 kamerasiyla aynidir."""
import os
import subprocess
import threading
import time

import numpy as np

from .applog import log
from .decoder import DecodedFrame

MAX_PROBE = 8           # kamera sirasi 0..7 denenir
FPS_LIMIT = 12.0        # saniyede en fazla bu kadar kare islenir (fazlasi atilir, islemci yorulmasin)
WANT_SIZE = (1920, 1080)
NO_FRAME_SECONDS = 4.0  # bu kadar sure kare gelmezse kamera koptu sayilir
ID_PREFIX = "Kamera "


def _cv2():
    try:
        import cv2
        return cv2
    except Exception:
        return None


def backends(cv2):
    """Denenecek OpenCV arka uclari. Windows: DirectShow (hizli ve guvenilir), olmazsa Media Foundation."""
    if os.name == "nt":
        return [cv2.CAP_DSHOW, cv2.CAP_MSMF]
    return [cv2.CAP_ANY]


def camera_id(index):
    return "%s%d" % (ID_PREFIX, index + 1)


def parse_id(value):
    """'Kamera 2' -> 1 (OpenCV sirasi). Anlasilamazsa None."""
    text = str(value or "").strip()
    if not text.startswith(ID_PREFIX):
        return None
    try:
        n = int(text[len(ID_PREFIX):].split()[0])
    except (ValueError, IndexError):
        return None
    return n - 1 if 1 <= n <= 64 else None


def _read_size(cap, tries=6):
    """Acilmis kameradan bir kare okuyup (genislik, yukseklik) verir; okunamazsa None. Ilk kareler bos gelebilir."""
    for _ in range(tries):
        try:
            ok, frame = cap.read()
        except Exception:
            return None
        if ok and frame is not None and getattr(frame, "ndim", 0) >= 2:
            return int(frame.shape[1]), int(frame.shape[0])
        time.sleep(0.05)
    return None


def pnp_names():
    """Windows'un bildirdigi kamera adlari (yalniz bilgi icin). Windows disinda ya da hata varsa []."""
    if os.name != "nt":
        return []
    cmd = ["powershell", "-NoProfile", "-NonInteractive", "-Command",
           "[Console]::OutputEncoding=[Text.Encoding]::UTF8; "
           "Get-PnpDevice -Class Camera,Image -PresentOnly -ErrorAction SilentlyContinue | "
           "Where-Object { $_.FriendlyName } | ForEach-Object { $_.FriendlyName }"]
    try:
        flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        out = subprocess.run(cmd, capture_output=True, timeout=15, creationflags=flags)
        names = []
        for line in out.stdout.decode("utf-8", "replace").splitlines():
            line = line.strip()
            if line and line not in names:
                names.append(line)
        return names
    except Exception as e:
        log("[webcam] kamera adlari okunamadi: %r" % (e,))
        return []


def list_cameras(cv2=None, keep=None, names=None):
    """Bilgisayardaki kameralari bulur. Donus: (liste, hata, adlar). Liste ogeleri: {"id","index","label","width","height"}.
    keep: {index: oge} - su an kullanilan kamera bir daha acilamaz, bilinen bilgisi aynen alinir.
    Isimler: Windows'un bildirdigi adlar yalniz tek kamera varsa etikete yazilir (sira eslesmesi guvenilir olmadigindan)."""
    cv2 = cv2 or _cv2()
    if cv2 is None:
        return [], "OpenCV kurulu degil (SESLI_KONTROL_BASLAT.bat kurar).", []
    keep = keep or {}
    found = []
    for backend in backends(cv2):
        found = []
        for i in range(MAX_PROBE):
            if i in keep:
                found.append(dict(keep[i]))
                continue
            cap = None
            try:
                cap = cv2.VideoCapture(i, backend)
                if not cap.isOpened():
                    continue
                size = _read_size(cap)
                if size is None:
                    continue
                found.append({"id": camera_id(i), "index": i, "width": size[0], "height": size[1]})
            except Exception as e:
                log("[webcam] kamera %d denenirken hata: %r" % (i, e))
            finally:
                if cap is not None:
                    try:
                        cap.release()
                    except Exception:
                        pass
        if found:
            break
    if names is None:
        names = pnp_names()
    for c in found:
        label = "%s (%dx%d)" % (c["id"], c["width"], c["height"])
        if len(found) == 1 and len(names) == 1:
            label = "%s - %s (%dx%d)" % (c["id"], names[0], c["width"], c["height"])
        c["label"] = label
    err = "" if found else ("Bilgisayara bagli kamera bulunamadi. Kamera takili mi, baska bir program (Teams, Zoom, Kamera uygulamasi) "
                            "kullaniyor mu? Windows Ayarlar > Gizlilik ve guvenlik > Kamera'da masaustu uygulamalarina izin verilmeli.")
    return found, err, list(names)


class WebcamClient:
    """Secili bilgisayar kamerasini okur, kareleri on_frame(DecodedFrame) ile verir. Kamera koparsa yeniden dener.
    Durumlar CameraClient ile ayni anahtarlari kullanir: connecting | streaming | reconnecting | stopped."""

    def __init__(self):
        self.on_state = None
        self.on_frame = None
        self.cv2 = None               # testlerde sahte cv2 verilebilir
        self._lock = threading.Lock()
        self._gen = 0
        self._running = False
        self._thread = None
        self._stats = ""
        self.active = None            # su an acik kamera: {"id","index","label","width","height"}

    @property
    def statistics(self):
        return self._stats

    def start(self, index):
        self.stop()
        with self._lock:
            self._running = True
            self._gen += 1
            gen = self._gen
        self._thread = threading.Thread(target=self._loop, args=(gen, index), daemon=True, name="sk-webcam")
        self._thread.start()

    def stop(self):
        with self._lock:
            self._running = False
        self._stats = ""
        self.active = None

    def _current(self, gen):
        with self._lock:
            return self._running and self._gen == gen

    def _emit(self, key, text):
        if self.on_state:
            self.on_state(key, text)

    def _open(self, cv2, index):
        """Kamerayi acar; (cap, boyut) ya da (None, neden)."""
        last = "Kamera acilamadi"
        for backend in backends(cv2):
            cap = None
            try:
                cap = cv2.VideoCapture(index, backend)
                if not cap.isOpened():
                    last = "Kamera acilamadi (baska bir program kullaniyor olabilir)"
                    cap.release()
                    continue
                try:
                    cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))   # yuksek cozunurluk icin gerekli
                    cap.set(cv2.CAP_PROP_FRAME_WIDTH, WANT_SIZE[0])
                    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, WANT_SIZE[1])
                    cap.set(cv2.CAP_PROP_AUTOFOCUS, 1)                            # belge icin otomatik odak (desteklenmezse yok sayilir)
                except Exception:
                    pass
                size = _read_size(cap)
                if size is None:
                    last = "Kameradan goruntu gelmiyor"
                    cap.release()
                    continue
                return cap, size
            except Exception as e:
                last = "Kamera acilamadi: %s" % str(e)[:120]
                if cap is not None:
                    try:
                        cap.release()
                    except Exception:
                        pass
        return None, last

    def _loop(self, gen, index):
        cv2 = self.cv2 or _cv2()
        if cv2 is None:
            self._emit("reconnecting", "OpenCV kurulu degil: bilgisayar kamerasi kullanilamaz (SESLI_KONTROL_BASLAT.bat kurar)")
            return
        attempt = 0
        while self._current(gen):
            self._emit("connecting", "Bilgisayar kamerasi aciliyor (%s)..." % camera_id(index))
            cap, info = self._open(cv2, index)
            reason = ""
            if cap is None:
                reason = info
            else:
                w, h = info
                self.active = {"id": camera_id(index), "index": index, "width": w, "height": h,
                               "label": "%s (%dx%d)" % (camera_id(index), w, h)}
                log("[webcam] %s acildi: %dx%d" % (camera_id(index), w, h))
                got = False
                try:
                    reason = self._read_loop(gen, cv2, cap, w, h)
                    got = self._frames > 0
                finally:
                    try:
                        cap.release()
                    except Exception:
                        pass
                self.active = None
                attempt = 1 if got else attempt + 1
            if not self._current(gen):
                break
            attempt = max(attempt, 1)
            wait = min(2.0 * attempt, 8.0)
            self._emit("reconnecting", "%s - %d sn sonra yeniden denenecek" % (reason, int(wait)))
            waited = 0.0
            while waited < wait and self._current(gen):
                time.sleep(0.2)
                waited += 0.2
        with self._lock:
            latest = self._gen == gen
        if latest:
            self._emit("stopped", "Kamera kapali")

    def _read_loop(self, gen, cv2, cap, w, h):
        """Kare okur ve verir; kamera kopunca ya da durdurulunca doner. Donus: bitis nedeni."""
        self._frames = 0
        last_ok = time.monotonic()
        last_sent = 0.0
        started = time.monotonic()
        interval = 1.0 / FPS_LIMIT
        while self._current(gen):
            try:
                ok = cap.grab()
            except Exception as e:
                return "Kamera hatasi: %s" % str(e)[:100]
            now = time.monotonic()
            if not ok:
                if now - last_ok > NO_FRAME_SECONDS:
                    return "Kameradan goruntu gelmiyor (kamera cikarilmis olabilir)"
                time.sleep(0.05)
                continue
            last_ok = now
            if now - last_sent < interval:
                continue                    # kare atlanir: grab() tampon bosaltir, islemci yorulmaz
            try:
                ok, bgr = cap.retrieve()
                if not ok or bgr is None:
                    continue
                rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
                gray = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)
            except Exception as e:
                return "Kare okunamadi: %s" % str(e)[:100]
            last_sent = now
            self._frames += 1
            if self._frames == 1:
                self._emit("streaming", "Canli")
            if now - started >= 1.0:
                self._stats = "%dx%d, %.0f kare/sn" % (bgr.shape[1], bgr.shape[0], self._frames / (now - started))
            try:
                if self.on_frame and self._current(gen):
                    self.on_frame(DecodedFrame(np.ascontiguousarray(rgb), np.ascontiguousarray(gray), now, True))
            except Exception as e:          # bir karenin islenmesindeki sorun akisi durdurmasin
                log("[webcam] kare islenemedi: %r" % (e,))
        return ""
