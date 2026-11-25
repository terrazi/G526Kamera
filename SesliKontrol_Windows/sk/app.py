# -*- coding: utf-8 -*-
"""Her şeyi birbirine bağlayan ana nesne: kaynak (Wi-Fi kamera / bilgisayar kamerası / PDF), tarama akışı, Gemini, kaynaklar,
sesli okuma ve sesli komutlar. Düğmeler (ekran) ve sesli komutlar aynı işlevleri çağırır."""
import io
import os
import threading
import time

from PIL import Image

from . import answers as A
from . import gemini as G
from . import protocol as P
from .applog import init_file, log
from .camera import CameraClient
from .decoder import H264Decoder
from .flow import Flow
from .settings import Settings, data_dir
from .sources import SourceSync
from .talk import Speaker
from .voice import VoiceTrigger, input_devices
from .webcam import WebcamClient, list_cameras, parse_id
from . import VERSION

CAMERA_KEYS = {"source", "uid", "camera_ip", "camera_password", "stream_quality", "webcam_device"}
VOICE_KEYS = {"voice_enabled", "voice_engine", "mic_device", "voice_threshold"}

TRIGGER = "seslikontroltetikyok"      # tetik sözcüğü yok; ses tanıyıcıya söylenmeyecek bir sözcük verilir

# Sesli komutlar: ad -> söylenişler (aynı işler ekrandaki düğmelerle de yapılır)
COMMANDS = {
    "scan": "taramayı başlat, tarama başlat, taramaya başla, başlat",
    "stop": "durdur, dur, iptal",
    "pdf": "pdf gönder, dosyayı gönder, pdf'i gönder",
    "repeat": "tekrar oku, cevapları oku, yeniden oku",
    "new": "yeni test, testi sıfırla",
    "status": "durum nedir, durum",
}


class App:
    def __init__(self, directory=None, speaker=None, voice=None):
        self.dir = directory or data_dir()
        init_file(os.path.join(self.dir, "gunluk.txt"))
        log("Sesli Kontrol Windows %s basliyor (iPhone surumu 885ddbc temel alindi)" % VERSION)
        self.settings = Settings(self.dir)
        self.decoder = H264Decoder(self._decoded)
        self.camera = CameraClient()
        self.camera.on_state = lambda key, text: self._source_state("wifi", key, text)
        self.camera.on_frame = lambda frame: self.decoder.feed(frame.payload, frame.loss_before)
        self.camera.on_device_info = self._device_info
        self.webcam = WebcamClient()
        self.webcam.on_state = lambda key, text: self._source_state("webcam", key, text)
        self.webcam.on_frame = self._decoded
        self._webcam_list = None
        self.speaker = speaker or Speaker(self.settings, None, os.path.join(self.dir, "ses"))
        self.voice = voice or VoiceTrigger(self.dir)
        self.voice.on_status = self._voice_status
        self.voice.on_heard = self._voice_heard
        self.voice.on_command = self._voice_command
        self.sources = SourceSync(self.settings, self.dir, lambda: A.profiles(self.settings), busy_elsewhere=lambda: self.flow.busy)
        self.service = A.AnswerService(self.settings, source_store=self.sources.store_for, on_source_rejected=self.sources.note_rejection)
        self.sources.on_change = self.service.sources_changed
        self.flow = Flow(self.settings, self.service, self.speaker, camera_live=self.live, source_warning=self.sources.warning)
        self.flow.on_speaking = self._speaking

        self._source = "wifi"
        self.cam_state, self.cam_text = "stopped", "Kamera kapalı"
        self.device_info = ""
        self.resolution = (0, 0)
        self.fps = 0.0
        self._fps_count, self._fps_since = 0, 0.0
        self.last_decoded = 0.0
        self.voice_status = ""
        self.voice_heard = ""
        self.flash_text, self.flash_until, self.flash_error = "", 0.0, False
        self.key_tests = {}
        self._inbox_name = "sorular.pdf"
        self.preview_id = 0
        self._preview_frame = None
        self._preview_cache = (0, 0, b"")
        self._preview_lock = threading.Lock()
        self._lock = threading.RLock()
        self._timers = {}

    # ---------------------------------------------------------------- yaşam döngüsü
    def start(self):
        if self.settings["use_sources"]:
            self.sources.prepare_folder()
        self._restart_camera()
        self._restart_voice()

    def stop(self):
        self.flow.stop()
        self.camera.stop()
        self.webcam.stop()
        self.voice.stop()
        self.decoder.stop()
        try:
            self.speaker.stop()
        except Exception:
            pass

    # ---------------------------------------------------------------- kaynak ve kamera
    def _restart_camera(self):
        self.camera.stop()
        self.webcam.stop()
        self.device_info, self.fps, self.resolution = "", 0.0, (0, 0)
        with self._preview_lock:
            self._preview_frame = None
        source = self.settings["source"]
        self._source = source
        if source == "pdf":
            self.cam_state, self.cam_text = "stopped", "Kaynak: PDF dosyası (kamera kullanılmıyor)."
            return
        if source == "webcam":
            wanted = self.settings["webcam_device"].strip()
            index = parse_id(wanted) if wanted else None
            if index is None:
                found, err, _ = list_cameras()
                with self._lock:
                    self._webcam_list = (time.time(), found, err, [])
                if not found:
                    self.cam_state, self.cam_text = "stopped", err or "Bilgisayara bağlı kamera bulunamadı."
                    return
                index = found[0]["index"]
            self.cam_state, self.cam_text = "connecting", "Bilgisayar kamerası açılıyor…"
            self.decoder.reset()
            self.webcam.start(index)
            return
        uid = P.CameraUID.parse(self.settings["uid"])
        if uid is None:
            self.cam_state = "stopped"
            self.cam_text = ("Kamera kimliği (UID) girilmemiş. Ayarlar > Kamera bölümünden girin." if not self.settings["uid"].strip()
                             else "Kamera kimliği (UID) anlaşılamadı. Örnek: GHBB-526029-XJPDT")
            return
        state, stream = (1, 1) if self.settings["stream_quality"] == 1 else (2, 2)
        tz = int(round((time.localtime().tm_gmtoff or 0) / 3600.0))
        self.cam_state, self.cam_text = "connecting", "Kameraya bağlanılıyor… (bilgisayar kameranın Wi-Fi ağında olmalı)"
        self.decoder.reset()
        self.camera.start(uid, self.settings["camera_password"], self.settings["camera_ip"], state, stream, tz)

    def _source_state(self, source, key, text):
        if source != self._source:
            return
        self.cam_state, self.cam_text = key, text
        if key in ("connecting", "reconnecting"):
            self.decoder.reset()
            self.fps, self.last_decoded, self._fps_since = 0.0, 0.0, 0.0

    def _device_info(self, info):
        try:
            self.device_info = ", ".join(str(info[k]) for k in ("id", "ver") if info.get(k))
        except Exception:
            pass

    def live(self):
        """Kamera akıyor VE kareler çözülüyor mu?"""
        return self._source != "pdf" and self.cam_state == "streaming" and time.monotonic() - self.last_decoded < 3.0

    def effective_state(self):
        if self.cam_state == "streaming" and not self.live():
            return "connected", getattr(self.decoder, "error", "") or "Görüntü çözülüyor…"
        return self.cam_state, self.cam_text

    def _decoded(self, frame):
        now = frame.time
        self.last_decoded = now
        self.resolution = (frame.width, frame.height)
        with self._preview_lock:
            self._preview_frame = frame
            self.preview_id += 1
        if self._fps_since == 0.0 or now - self._fps_since > 5.0:
            self._fps_since, self._fps_count = now, 0
        self._fps_count += 1
        if now - self._fps_since >= 1.0:
            self.fps = self._fps_count / (now - self._fps_since)
            self._fps_count, self._fps_since = 0, now
        self.flow.feed(frame)

    def preview_jpeg(self, max_width=960, quality=72):
        """Önizleme için küçültülmüş JPEG. (kare_no, bayt)"""
        with self._preview_lock:
            frame, pid, cached = self._preview_frame, self.preview_id, self._preview_cache
        if frame is None:
            return 0, b""
        if cached[0] == pid and cached[1] == max_width:
            return pid, cached[2]
        image = Image.fromarray(frame.rgb)
        if image.width > max_width:
            image = image.resize((max_width, int(image.height * max_width / image.width)), Image.BILINEAR)
        buf = io.BytesIO()
        image.save(buf, "JPEG", quality=quality)
        data = buf.getvalue()
        with self._preview_lock:
            self._preview_cache = (pid, max_width, data)
        return pid, data

    def webcam_cameras(self, refresh=False):
        """Bilgisayara bağlı kameralar (USB ve dizüstü kamerası). Tarama kamerayı kısa süre açar; 60 sn önbellekte tutulur."""
        with self._lock:
            cached = self._webcam_list
        if cached and not refresh and time.time() - cached[0] < 60:
            found, err = cached[1], cached[2]
        else:
            keep = {}
            active = getattr(self.webcam, "active", None) if self._source == "webcam" else None
            if active:
                keep[active["index"]] = active
            found, err, names = list_cameras(keep=keep)
            with self._lock:
                self._webcam_list = (time.time(), found, err, names)
        return {"cameras": [{"id": c["id"], "label": c["label"]} for c in found], "error": err,
                "selected": self.settings["webcam_device"].strip()}

    # ---------------------------------------------------------------- ses
    def _restart_voice(self):
        self.voice.stop()
        self.voice.mic_name = self.settings["mic_device"]
        self.voice.set_commands(COMMANDS)
        if self.settings["voice_enabled"]:
            # Tetik sözcüğü yok: yalnız adlandırılmış komutlar dinlenir (söylenmeyecek bir sözcük verilir)
            self.voice.start(TRIGGER, self.settings["voice_threshold"], self.settings["voice_engine"])
        else:
            self.voice_status = "Sesli komut kapalı"

    def mic_list(self):
        devices, err = input_devices()
        return {"devices": devices, "selected": self.settings["mic_device"], "error": err,
                "active": getattr(self.voice, "mic_used", ""), "mode": getattr(self.voice, "mode", "")}

    def _voice_status(self, text):
        # Tetik sözcüğü kullanılmıyor: durum yazısında yer tutucu görünmesin
        if TRIGGER in text:
            text = "Sesli komutlar dinleniyor" + (" (çevrimdışı Türkçe)" if "cevrimdisi" in text else "")
        self.voice_status = text

    def _voice_heard(self, text):
        self.voice_heard = text

    def _speaking(self, on):
        """Program konuşurken yalnız "dur" komutu dinlenir (kendi sesini komut sanmasın)."""
        self.voice.only_commands = {"stop"} if on else None

    def _voice_command(self, name, text):
        log("[ses] komut: %s (%r)" % (name, text))
        self.command(name, source="ses")

    def command(self, name, source="ekran"):
        """Düğme ya da sesli komut. Dönüş: {"ok": bool, "message": str}"""
        if name == "scan":
            ok, why = self.flow.start_scan()
        elif name == "stop":
            ok, why = self.flow.stop(), ""
        elif name == "pdf":
            ok, why = (self.flow.send_pdf(self._inbox(), self._inbox_name) if os.path.isfile(self._inbox())
                       else (False, "Önce ekrandan bir PDF dosyası seçin."))
        elif name == "repeat":
            ok, why = self.flow.repeat()
        elif name == "new":
            ok, why = self.flow.clear()
        elif name == "status":
            ok, why = True, ""
            threading.Thread(target=self.speaker.say, args=(self.flow.status,), daemon=True).start()
        else:
            ok, why = False, "Bilinmeyen komut."
        if not ok and why:
            self.flash(why, error=True)
            if source == "ses" and self.settings["read_answers"]:
                threading.Thread(target=self.speaker.say, args=(why,), daemon=True).start()
        return {"ok": bool(ok), "message": why}

    # ---------------------------------------------------------------- PDF
    def _inbox(self):
        return os.path.join(self.dir, "gelen.pdf")

    def receive_pdf(self, data, name):
        """Ekrandan seçilen PDF: kaydedilir ve gönderilir."""
        if not data.startswith(b"%PDF"):
            return {"ok": False, "message": "Seçilen dosya PDF değil."}
        if self.flow.busy:
            return {"ok": False, "message": "Önce süren işlem bitmeli ya da durdurulmalı."}
        with open(self._inbox(), "wb") as f:
            f.write(data)
        self._inbox_name = name or "sorular.pdf"
        ok, why = self.flow.send_pdf(self._inbox(), self._inbox_name)
        return {"ok": ok, "message": why}

    # ---------------------------------------------------------------- ayarlar ve durum
    def flash(self, text, seconds=6.0, error=False):
        self.flash_text, self.flash_until, self.flash_error = text, time.time() + seconds, error

    def _debounce(self, name, fn):
        with self._lock:
            timer = self._timers.get(name)
            if timer:
                timer.cancel()
            t = threading.Timer(1.2, fn)
            t.daemon = True
            self._timers[name] = t
            t.start()

    def update_settings(self, changes):
        changed = set(self.settings.update(changes))
        if changed & CAMERA_KEYS:
            if self.flow.phase == "scanning":
                self.flow.stop()
            self._debounce("camera", self._restart_camera)
        if changed & VOICE_KEYS:
            self._debounce("voice", self._restart_voice)
        if "use_sources" in changed:
            log("[kaynak] kaynaklara gore cevaplama %s" % ("ACILDI" if self.settings["use_sources"] else "kapatildi"))
            if self.settings["use_sources"]:
                self.sources.prepare_folder()
        if any(k.startswith("p") and k[1:2].isdigit() for k in changed):
            self.service.sources_changed()
        return sorted(changed)

    def test_key(self, slot):
        slot = int(slot)
        key, model = self.settings["p%d_key" % slot], self.settings["p%d_model" % slot]
        if not key.strip():
            result = (False, "Anahtar girilmemiş.")
        else:
            result = G.test_key(model, key)
        self.key_tests[slot] = {"ok": result[0], "message": result[1]}
        return self.key_tests[slot]

    def open_folder(self, which):
        path = self.sources.folder if which == "sources" else (self.flow.session_dir or self.settings.local_dir())
        try:
            os.makedirs(path, exist_ok=True)
            if hasattr(os, "startfile"):
                os.startfile(path)      # noqa: S606 (yalnız Windows)
            return {"ok": True, "path": path}
        except OSError as e:
            return {"ok": False, "message": str(e), "path": path}

    def state(self):
        cam_state, cam_text = self.effective_state()
        now = time.time()
        return {
            "version": VERSION,
            "source": self._source,
            "camera": {"state": cam_state, "text": cam_text, "live": self.live(), "info": self.device_info,
                       "width": self.resolution[0], "height": self.resolution[1], "fps": round(self.fps, 1)},
            "flow": self.flow.state(),
            "sources": {"lines": self.sources.lines(), "busy": self.sources.busy, "progress": self.sources.progress,
                        "report": list(self.sources.report)},
            "voice": {"status": self.voice_status, "heard": self.voice_heard, "enabled": self.settings["voice_enabled"]},
            "flash": {"text": self.flash_text if now < self.flash_until else "", "error": self.flash_error},
            "profiles": len(A.profiles(self.settings)),
            "key_tests": self.key_tests,
            "settings": self.settings.view(),
        }
