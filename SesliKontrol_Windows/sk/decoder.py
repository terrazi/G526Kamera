# -*- coding: utf-8 -*-
"""H.264 cozucu. Once PyAV (pip install av), yoksa PATH'teki ffmpeg."""
import collections
import os
import queue
import shutil
import subprocess
import threading
import time

import numpy as np

from .applog import log


def _nal_types(data):
    """Annex-B akistaki NAL turleri."""
    types = []
    i = 0
    n = len(data)
    while True:
        i = data.find(b"\x00\x00\x01", i)
        if i < 0 or i + 3 >= n:
            break
        types.append(data[i + 3] & 0x1F)
        i += 3
    return types


def _unescape(rbsp):
    out = bytearray()
    zeros = 0
    for b in rbsp:
        if zeros >= 2 and b == 3:
            zeros = 0
            continue
        out.append(b)
        zeros = zeros + 1 if b == 0 else 0
    return bytes(out)


class _Bits:
    def __init__(self, data):
        self.d = data
        self.p = 0

    def u(self, n):
        v = 0
        for _ in range(n):
            byte = self.d[self.p >> 3] if (self.p >> 3) < len(self.d) else 0
            v = (v << 1) | ((byte >> (7 - (self.p & 7))) & 1)
            self.p += 1
        return v

    def ue(self):
        zeros = 0
        while self.u(1) == 0 and zeros < 32:
            zeros += 1
        return (1 << zeros) - 1 + self.u(zeros) if zeros else 0

    def se(self):
        k = self.ue()
        return (k + 1) // 2 if k & 1 else -(k // 2)


def sps_size(data):
    """Akistaki ilk SPS'ten (genislik, yukseklik) dondurur; bulunamazsa None."""
    i = 0
    while True:
        i = data.find(b"\x00\x00\x01", i)
        if i < 0 or i + 4 >= len(data):
            return None
        if data[i + 3] & 0x1F == 7:
            break
        i += 3
    end = data.find(b"\x00\x00\x01", i + 3)
    if end < 0:
        end = len(data)
    try:
        b = _Bits(_unescape(data[i + 4:end]))
        profile = b.u(8)
        b.u(8)
        b.u(8)
        b.ue()
        chroma = 1
        if profile in (100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135):
            chroma = b.ue()
            if chroma == 3:
                b.u(1)
            b.ue()
            b.ue()
            b.u(1)
            if b.u(1):
                for k in range(8 if chroma != 3 else 12):
                    if b.u(1):
                        size = 16 if k < 6 else 64
                        last = nxt = 8
                        for _ in range(size):
                            if nxt:
                                nxt = (last + b.se() + 256) % 256
                            last = nxt or last
        b.ue()
        poc = b.ue()
        if poc == 0:
            b.ue()
        elif poc == 1:
            b.u(1)
            b.se()
            b.se()
            for _ in range(b.ue()):
                b.se()
        b.ue()
        b.u(1)
        w = (b.ue() + 1) * 16
        h = (b.ue() + 1) * 16
        frame_mbs_only = b.u(1)
        if not frame_mbs_only:
            b.u(1)
        h *= 2 - frame_mbs_only
        b.u(1)
        if b.u(1):
            cl, cr, ct, cb = b.ue(), b.ue(), b.ue(), b.ue()
            cx = 2 if chroma in (1, 2) else 1
            cy = (2 if chroma == 1 else 1) * (2 - frame_mbs_only)
            w -= cx * (cl + cr)
            h -= cy * (ct + cb)
        return w, h
    except Exception:
        return None


class DecodedFrame:
    __slots__ = ("rgb", "gray", "time", "width", "height", "clean")

    def __init__(self, rgb, gray, t, clean=True):
        self.rgb = rgb
        self.gray = gray
        self.time = t
        self.clean = clean      # False: paket kaybindan sonra, bir sonraki anahtar kareye kadar bozuk olabilir
        self.height, self.width = gray.shape


def _gray_of(rgb):
    r = rgb[..., 0].astype(np.uint16)
    g = rgb[..., 1].astype(np.uint16)
    b = rgb[..., 2].astype(np.uint16)
    return ((r * 77 + g * 150 + b * 29) >> 8).astype(np.uint8)


class H264Decoder:
    """feed(annexb_bytes, kayip_var) -> on_frame(DecodedFrame). Ilk IDR gelene kadar bekler.
    Paket kaybindan sonra gelen kareler, bir sonraki IDR'ye kadar 'clean=False' isaretlenir."""

    _RESET = object()

    def __init__(self, on_frame):
        self.on_frame = on_frame
        self.backend = None
        self.error = ""
        self.q = queue.Queue(maxsize=80)
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True, name="sk-cozucu")
        self.frames = 0
        self.need_idr = True
        self.dropped = 0
        self._tainted = False
        self._flags = collections.deque()      # ffmpeg yolu icin: giren kare -> 'temiz mi'
        self._thread.start()

    @staticmethod
    def available_backend():
        try:
            import av  # noqa: F401
            return "av"
        except Exception:
            pass
        if shutil.which("ffmpeg"):
            return "ffmpeg"
        return None

    def feed(self, payload, loss_before=False):
        try:
            self.q.put_nowait((payload, loss_before))
        except queue.Full:
            # Cozucu yetisemiyor: kuyrugu bosalt, bir sonraki anahtar kareden devam et
            self._drain_queue()
            self.dropped += 1
            try:
                self.q.put_nowait(self._RESET)
            except queue.Full:
                pass

    def reset(self):
        """Yeni baglanti: eski veriyi at, bir sonraki anahtar kareden basla."""
        self._drain_queue()
        try:
            self.q.put_nowait(self._RESET)
        except queue.Full:
            pass

    def _drain_queue(self):
        try:
            while True:
                self.q.get_nowait()
        except queue.Empty:
            pass

    def stop(self):
        self._stop.set()
        try:
            self.q.put_nowait(None)
        except queue.Full:
            pass

    def _run(self):
        backend = self.available_backend()
        self.backend = backend
        if backend is None:
            self.error = ("Goruntu cozucu bulunamadi. 'pip install av' komutu veya ffmpeg gerekli "
                          "(SESLI_KONTROL_BASLAT.bat bunu kendisi kurar).")
            log("[cozucu] " + self.error)
            return
        log("[cozucu] kullanilan cozucu: " + backend)
        try:
            if backend == "av":
                self._run_av()
            else:
                self._run_ffmpeg()
        except Exception as e:  # beklenmeyen
            self.error = "Cozucu hatasi: %s" % e
            log("[cozucu] " + self.error)

    def _next(self):
        """Kuyruktan siradaki (payload, loss) | _RESET | None(durdur) | False(zaman asimi)"""
        try:
            return self.q.get(timeout=0.5)
        except queue.Empty:
            return False

    def _taint_state(self, data, loss):
        """Bu kare temiz mi? (kayiptan sonra bir sonraki IDR'ye kadar degil)"""
        if loss:
            self._tainted = True
        if 5 in _nal_types(data):
            self._tainted = False
        return not self._tainted

    # ---- PyAV
    def _run_av(self):
        import av
        codec = None
        use_parser = False
        failures = 0
        self.need_idr = True
        while not self._stop.is_set():
            item = self._next()
            if item is None:
                break
            if item is False:
                continue
            if item is self._RESET:
                codec = None
                self.need_idr = True
                self._tainted = False
                continue
            data, loss = item
            types = _nal_types(data)
            if self.need_idr:
                if 5 not in types:
                    continue
                if 7 not in types or 8 not in types:
                    log("[cozucu] anahtar karede SPS/PPS yok, bekleniyor")
                    continue
                self.need_idr = False
                codec = av.CodecContext.create("h264", "r")
                self._tainted = False
                loss = False
            if codec is None:
                continue
            clean = self._taint_state(data, loss)
            try:
                if use_parser:
                    packets = codec.parse(data)
                else:
                    try:
                        packets = [av.Packet(data)]
                    except (TypeError, ValueError):
                        use_parser = True
                        packets = codec.parse(data)
                for pkt in packets:
                    for fr in codec.decode(pkt):
                        rgb = fr.to_ndarray(format="rgb24")
                        gray = fr.to_ndarray(format="gray")
                        self._deliver(rgb, gray, clean)
                failures = 0
            except Exception as e:
                failures += 1
                self._tainted = True
                log("[cozucu] cozme hatasi (%d): %s" % (failures, e))
                if failures >= 5:
                    codec = None
                    self.need_idr = True
                    failures = 0

    # ---- ffmpeg
    def _run_ffmpeg(self):
        exe = shutil.which("ffmpeg")
        size = None
        buf = bytearray()
        # Boyutu ilk SPS'ten ogren
        while size is None and not self._stop.is_set():
            item = self._next()
            if item is None:
                return
            if item is False:
                continue
            if item is self._RESET:
                buf.clear()
                continue
            buf += item[0]
            size = sps_size(bytes(buf))
            if len(buf) > 4_000_000:
                buf.clear()
        if size is None:
            return
        w, h = size
        log("[cozucu] ffmpeg, goruntu boyutu %dx%d" % (w, h))
        # Not: "-fflags nobuffer" bu akista kareleri yariya dusuruyor, kullanilmaz.
        cmd = [exe, "-loglevel", "error", "-flags", "low_delay", "-threads", "1",
               "-probesize", "32768", "-analyzeduration", "0", "-f", "h264", "-i", "pipe:0",
               "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1"]
        kwargs = {}
        if os.name == "nt":
            kwargs["creationflags"] = 0x08000000
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, bufsize=0, **kwargs)
        frame_bytes = w * h * 3
        self._flags.clear()

        def reader():
            while not self._stop.is_set():
                raw = bytearray()
                while len(raw) < frame_bytes:
                    chunk = proc.stdout.read(frame_bytes - len(raw))
                    if not chunk:
                        return
                    raw += chunk
                rgb = np.frombuffer(bytes(raw), np.uint8).reshape(h, w, 3)
                try:
                    clean = self._flags.popleft()
                except IndexError:
                    clean = True
                self._deliver(rgb, _gray_of(rgb), clean)

        t = threading.Thread(target=reader, daemon=True, name="sk-ffmpeg-oku")
        t.start()
        try:
            first = bytes(buf)
            self._flags.append(self._taint_state(first, False))
            proc.stdin.write(first)
            while not self._stop.is_set():
                item = self._next()
                if item is False:
                    if proc.poll() is not None:
                        break
                    continue
                if item is None:
                    break
                if item is self._RESET:
                    continue
                data, loss = item
                self._flags.append(self._taint_state(data, loss))
                proc.stdin.write(data)
        except (BrokenPipeError, OSError):
            pass
        finally:
            try:
                proc.stdin.close()
            except OSError:
                pass
            try:
                proc.kill()
            except OSError:
                pass

    def _deliver(self, rgb, gray, clean=True):
        self.frames += 1
        self.on_frame(DecodedFrame(rgb, gray, time.monotonic(), clean))
