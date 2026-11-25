# -*- coding: utf-8 -*-
"""Test akışı: kamera taraması ya da PDF dosyası -> Gemini -> cevaplar -> sesli okuma.
iPhone programının düzeni: kareler seçilir, zaman sırasıyla tek PDF yapılır, programın talimat metniyle birlikte Gemini'ye gider;
her soru "Soru N, şık sözcüğü, cevap metni" olarak gelir, kaydedilir ve aralıklı okunur."""
import os
import threading
import time

from . import answers as A
from . import frames as F
from . import gemini as G
from .applog import log

SCAN_GRACE = 6.0        # tarama süresi dolduktan sonra son kare için beklenen süre (kamera durduysa tarama yine biter)
STALL_SECONDS = 8.0     # tarama sırasında bu kadar süre kare gelmezse kamera kopmuş sayılır
CUES = (30, 10)         # kalan süre bu saniyelere inince söylenir


class Flow:
    def __init__(self, settings, service, speaker, camera_live=lambda: False, source_warning=lambda: "", clock=time.monotonic,
                 sleep=time.sleep):
        self.s = settings
        self.service = service              # answers.AnswerService
        self.speaker = speaker              # say(text, wait=True) ve stop() olan nesne
        self.camera_live = camera_live
        self.source_warning = source_warning
        self.clock = clock
        self.sleep = sleep
        self.on_speaking = None             # on_speaking(True/False): okuma sürerken sesli komutlar yalnız "dur"u dinler
        self.phase = "idle"                 # idle | scanning | preparing | sending | reading
        self.status = "Hazır."
        self.error = ""
        self.notes = []
        self.answers = {}                   # numara -> kayıt
        self.expected = 1                   # sıradaki soru
        self.last_origin = ""
        self.last_pdf = ""                  # son gönderilen PDF'in yolu
        self.scan_left = 0
        self.scan_report = ""
        self.session_dir = ""
        self._collector = None
        self._last_frame = 0.0
        self._cancel = threading.Event()
        self._thread = None
        self._lock = threading.RLock()

    # ---------------------------------------------------------------- durum
    @property
    def busy(self):
        return self.phase != "idle"

    def state(self):
        with self._lock:
            rows = [self.answers[n] for n in sorted(self.answers)]
            return {"phase": self.phase, "status": self.status, "error": self.error, "notes": list(self.notes),
                    "answers": rows, "expected": self.expected, "scan_left": self.scan_left, "scan_report": self.scan_report,
                    "session_dir": self.session_dir, "last_pdf": os.path.basename(self.last_pdf)}

    def _set(self, phase, status):
        with self._lock:
            self.phase, self.status = phase, status
        log("[akis] %s: %s" % (phase, status))

    def _fail(self, text):
        with self._lock:
            self.error, self.phase, self.status = text, "idle", "Hazır."
        log("[akis] HATA: %s" % text)
        self._say(text)

    def _say(self, text):
        if not text or not self.s["read_answers"] or self._cancel.is_set():
            return
        if self.on_speaking:
            self.on_speaking(True)
        try:
            self.speaker.say(text, wait=True)
        except Exception as e:      # ses hatası akışı durdurmasın
            log("[akis] sesli okuma hatasi: %r" % (e,))
        finally:
            if self.on_speaking:
                self.on_speaking(False)

    def _folder(self):
        if not self.session_dir:
            self.session_dir = os.path.join(self.s.local_dir(), time.strftime("%Y%m%d%H%M%S"))
        os.makedirs(self.session_dir, exist_ok=True)
        return self.session_dir

    def _begin(self, target, *args):
        with self._lock:
            if self.busy:
                return False, "Önce süren işlem bitmeli ya da durdurulmalı."
            self._cancel = threading.Event()
            self.error, self.notes, self.scan_report = "", [], ""
            warning = self.source_warning()
            if warning:
                self.notes.append(warning)
            self.phase = "preparing"
            self._thread = threading.Thread(target=self._guard, args=(target,) + args, daemon=True, name="sk-akis")
            self._thread.start()
            return True, ""

    def _guard(self, target, *args):
        try:
            target(*args)
        except G.GeminiError as e:
            self._fail(e.message)
        except Exception as e:
            log("[akis] beklenmeyen hata: %r" % (e,))
            self._fail("Beklenmeyen hata: %s" % e)
        finally:
            with self._lock:
                self._collector = None
                if self.phase != "idle":
                    self.phase, self.status = "idle", "Hazır."

    def wait(self, timeout=None):
        t = self._thread
        if t is not None:
            t.join(timeout)

    # ---------------------------------------------------------------- komutlar
    def start_scan(self):
        """Kamera taramasını başlatır. Dönüş: (başladı mı, neden)."""
        if not self.camera_live():
            return False, "Kamera görüntüsü yok. Kaynak seçimini ve kamera bağlantısını denetleyin."
        return self._begin(self._scan)

    def send_pdf(self, path, name=""):
        """PDF dosyasındaki soruları gönderir. Dönüş: (başladı mı, neden)."""
        if not path or not os.path.isfile(path):
            return False, "PDF dosyası bulunamadı."
        return self._begin(self._document, path, name or os.path.basename(path))

    def stop(self):
        """Süren işi (tarama, gönderme, okuma) durdurur."""
        self._cancel.set()
        try:
            self.speaker.stop()
        except Exception:
            pass
        with self._lock:
            if self.busy:
                self.status = "Durduruluyor…"
        return True

    def repeat(self):
        """Bütün cevapları baştan okur."""
        with self._lock:
            rows = [self.answers[n] for n in sorted(self.answers)]
        if not rows:
            return False, "Okunacak cevap yok."
        return self._begin(self._read, rows, False)

    def clear(self):
        """Yeni test: cevaplar silinir, soru sayacı 1'e döner (dosyalar yerinde kalır)."""
        with self._lock:
            if self.busy:
                return False, "Önce süren işlem bitmeli ya da durdurulmalı."
            self.answers, self.expected, self.session_dir, self.error, self.notes = {}, 1, "", "", []
            self.status = "Hazır. Yeni test."
        return True, ""

    # ---------------------------------------------------------------- kamera taraması
    def feed(self, frame):
        """Çözülen her kare buraya gelir; tarama sürüyorsa toplayıcıya verilir."""
        collector = self._collector
        if collector is None:
            return
        self._last_frame = self.clock()
        if not collector.add(frame.rgb, frame.gray, frame.time, frame.clean):
            self._collector = None      # süre doldu

    def _scan(self):
        seconds, rate = int(self.s["scan_seconds"]), int(self.s["scan_rate"])
        collector = F.ScanCollector(seconds, rate, float(self.s["jpeg_quality"]))
        self._set("scanning", "Tarama sürüyor: kamerayı sayfaların üzerinde yavaşça gezdirin.")
        self._say("Tarama başladı. %d saniye." % seconds)
        began = self._last_frame = self.clock()
        self._collector = collector
        cues = [c for c in CUES if c < seconds]
        while self._collector is not None and not self._cancel.is_set():
            now = self.clock()
            left = max(0, int(round(seconds - collector.elapsed(now) if collector.start is not None else seconds)))
            self.scan_left = left
            if cues and left <= cues[0]:
                cues.pop(0)
                threading.Thread(target=self._say, args=("%d saniye." % left,), daemon=True).start()
            if now - self._last_frame > STALL_SECONDS or now - began > seconds + SCAN_GRACE + STALL_SECONDS:
                log("[akis] tarama sirasinda kare gelmiyor; eldeki karelerle bitiriliyor")
                break
            self.sleep(0.1)
        self._collector = None
        self.scan_left = 0
        if self._cancel.is_set():
            self._set("idle", "Tarama durduruldu.")
            return
        shots = collector.finish()
        if not shots:
            raise G.GeminiError("Taramada hiç kare alınamadı. Kamera görüntüsünü denetleyin.", "error")
        self._set("preparing", "Kareler seçiliyor ve PDF hazırlanıyor…")
        pdf, labels, report = F.build(shots, rate, bool(self.s["thin_frames"]), "Tarama")
        self.scan_report = "%d kare ölçüldü (%d bozuk); %d kare seçildi (%d bozuk, %d bulanık, %d tekrar çıkarıldı); PDF %.1f MB" % (
            collector.seen, collector.damaged, report["pages"], report["damaged"], report["blurry"], report["repeats"], len(pdf) / 1e6)
        log("[akis] " + self.scan_report)
        path = os.path.join(self._folder(), "tarama_%s.pdf" % time.strftime("%H%M%S"))
        with open(path, "wb") as f:
            f.write(pdf)
        self.last_pdf, self.last_origin = path, "kamera"
        self._say("Tarama bitti. Gönderiliyor.")
        text = A.page_text(self.expected, len(labels), labels, self.s["extra_instruction"])
        self._ask(pdf, A.PR.PAGE_SYSTEM, text, os.path.basename(path), "kamera")

    # ---------------------------------------------------------------- PDF dosyası
    def _document(self, path, name):
        self._set("preparing", "PDF okunuyor: %s" % name)
        with open(path, "rb") as f:
            pdf = f.read()
        if not pdf.startswith(b"%PDF"):
            raise G.GeminiError("Seçilen dosya PDF değil: %s" % name, "error")
        self.last_pdf, self.last_origin = path, "pdf"
        self._say("PDF gönderiliyor.")
        self._ask(pdf, A.DOC_SYSTEM, A.doc_text(self.expected, name, self.s["extra_instruction"]), name, "pdf")

    # ---------------------------------------------------------------- Gemini ve cevaplar
    def _ask(self, pdf, system, text, name, origin):
        self._set("sending", "Gemini'ye gönderildi (%.1f MB), cevap bekleniyor…" % (len(pdf) / 1e6))
        reply = self.service.ask(pdf, system, text, name, cancelled=self._cancel.is_set)
        if self._cancel.is_set():
            self._set("idle", "Durduruldu.")
            return
        with self._lock:
            self.notes += reply.notes
            if reply.sources:
                self.notes.append("Kaynaklar: " + reply.sources)
        if not reply.answers:
            self._set("idle", "Gönderilen görüntülerde soru bulunamadı.")
            self._say("Soru bulunamadı.")
            return
        rows = self._record(reply, origin)
        self._save_answers()
        self._read(rows, True)

    def _record(self, reply, origin):
        rows = []
        with self._lock:
            number = self.expected
            for item in reply.answers:
                n = item["number"] if item["number"] is not None else number
                row = {"number": n, "option": item["option"], "text": item["text"], "origin": origin, "model": reply.model,
                       "time": time.strftime("%H:%M:%S"), "spoken": ("Soru %d, %s" % (n, item["option"]) + (", " + item["text"] if item["text"] else ""))
                       if item["option"] else "Soru %d, %s" % (n, item["spoken"])}
                self.answers[n] = row
                rows.append(row)
                number = n + 1
            self.expected = max(self.answers) + 1
        return rows

    def _save_answers(self):
        try:
            with self._lock:
                lines = ["%s\t(%s, %s, %s)" % (r["spoken"], r["origin"], r["model"], r["time"]) for _, r in sorted(self.answers.items())]
            with open(os.path.join(self._folder(), "cevaplar.txt"), "w", encoding="utf-8") as f:
                f.write("\n".join(lines) + "\n")
        except OSError as e:
            log("[akis] cevaplar dosyaya yazilamadi: %s" % e)

    def _read(self, rows, announce_next):
        self._set("reading", "%d cevap okunuyor." % len(rows))
        gap = float(self.s["answer_gap"])
        for i, row in enumerate(rows):
            if self._cancel.is_set():
                break
            self._say(row["spoken"])
            if i + 1 < len(rows) and gap > 0 and not self._cancel.is_set() and self.s["read_answers"]:
                self._cancel.wait(gap)
        if announce_next and not self._cancel.is_set():
            self._say("Sıradaki soru %d." % self.expected)
        self._set("idle", "Hazır. %d cevap alındı; sıradaki soru %d." % (len(self.answers), self.expected))
