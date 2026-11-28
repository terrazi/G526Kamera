# -*- coding: utf-8 -*-
"""Sesli okuma (Windows sesi / Gemini sesi), konuşmaya uygun metin temizleme ve soru kaydı (sessizlikte durur)."""
import os
import queue
import re
import subprocess
import tempfile
import threading
import time
import unicodedata

import numpy as np

from .applog import log
from .gemini import wav_bytes

# ----------------------------------------------------------------- metni konuşmaya hazırlama
_URL = re.compile(r"https?://\S+|www\.\S+", re.I)
_MD_LINK = re.compile(r"\[([^\]]+)\]\([^)]+\)")
_BULLET = re.compile(r"^\s*(?:[-*•▪◦–—]+|\d{1,2}[.)])\s+", re.M)
_HEADING = re.compile(r"^\s{0,3}#{1,6}\s*", re.M)
_PERCENT_AFTER = re.compile(r"(\d+(?:[.,]\d+)?)\s*%")
_PERCENT_BEFORE = re.compile(r"%\s*(\d+(?:[.,]\d+)?)")
# Sayının hemen önündeki eksi işareti ("-39", "−1/3"): satır başında ya da boşluk / noktalama / karşılaştırma işaretinden sonra.
# "3-5" gibi aralıklara ve "2020 - 2021" gibi ayraç tirelerine dokunulmaz.
_MINUS = re.compile(r"(?<![^\s,;:(=<>])[-−–](?=\d|√)")
_ABBREV = {"sn", "dr", "prof", "doç", "doc", "no", "md", "vb", "vs", "bkz", "say", "tel", "sk", "mah", "cad", "ltd",
           "şti", "sti", "yrd", "öğr", "ogr", "uzm", "av", "mad", "böl", "bol", "fak", "üni", "uni", "tc", "t.c"}


def _strip_symbols(text):
    out = []
    for ch in text:
        cat = unicodedata.category(ch)
        if cat in ("So", "Sk", "Cs", "Co", "Cf") or ord(ch) > 0xFFFF:
            out.append(" ")          # emoji, çizim simgeleri
        else:
            out.append(ch)
    return "".join(out)


def clean_for_speech(text):
    """Markdown ve görsel işaretleri atar; yüzdeleri sesli okunacak biçime getirir."""
    s = str(text or "").replace("\r", "")
    s = _MD_LINK.sub(r"\1", s)
    s = _URL.sub(" bağlantı ", s)
    s = _HEADING.sub("", s)
    s = _BULLET.sub("", s)
    s = s.replace("**", "").replace("__", "").replace("`", "").replace("~~", "")
    s = re.sub(r"(?<![\w*])\*(?!\s)|(?<!\s)\*(?![\w*])", "", s)          # tek yıldız (italik)
    s = s.replace("|", ", ")
    s = _MINUS.sub("eksi ", s)
    s = _PERCENT_AFTER.sub(r"yüzde \1", s)
    s = _PERCENT_BEFORE.sub(r"yüzde \1", s)
    s = _strip_symbols(s)
    s = re.sub(r"[ \t]+", " ", s)
    s = re.sub(r"\n{2,}", "\n", s)
    return s.strip()


def _ends_sentence(chunk):
    """Nokta gerçekten cümle sonu mu (sayı sırası '1.', kısaltma 'Sn.' değil)?"""
    m = re.search(r"([^\s.!?…]+)([.!?…]+)$", chunk.rstrip())
    if not m:
        return True
    word, marks = m.group(1), m.group(2)
    if marks != "." :
        return True
    low = word.lower().strip("()\"'“”")
    if low.isdigit() and len(low) <= 2:
        return False
    if low in _ABBREV:
        return False
    if len(low) == 1 and low.isalpha():
        return False
    return True


def split_sentences(text, max_len=220):
    """Temizlenmiş metni okunacak parçalara böler (cümle sonlarında; çok uzunsa virgülden)."""
    pieces = []
    for line in str(text or "").split("\n"):
        line = line.strip()
        if not line:
            continue
        tokens = re.split(r"(?<=[.!?…])\s+", line)
        cur = ""
        for tok in tokens:
            cur = (cur + " " + tok).strip() if cur else tok
            if _ends_sentence(cur):
                pieces.append(cur)
                cur = ""
        if cur:
            pieces.append(cur)
    out = []
    for p in pieces:
        while len(p) > max_len:
            cut = max(p.rfind("; ", 0, max_len), p.rfind(", ", 0, max_len), p.rfind(" ", 0, max_len))
            if cut < max_len // 3:
                cut = max_len
            out.append(p[:cut + 1].strip())
            p = p[cut + 1:].strip()
        if p:
            out.append(p)
    return out


def group_sentences(sentences, limit=260):
    """Gemini sesi için art arda cümleleri tek istekte birleştirir (daha az istek, daha doğal akış). Liste listesi döner."""
    out, cur, size = [], [], 0
    for s in sentences:
        if cur and size + 1 + len(s) > limit:
            out.append(cur)
            cur, size = [s], len(s)
        else:
            cur.append(s)
            size += len(s) + 1
    if cur:
        out.append(cur)
    return out


def group_chunks(sentences, limit=260):
    return [" ".join(g) for g in group_sentences(sentences, limit)]


_TRIGGER_FOLD = str.maketrans({"ı": "i", "İ": "i", "ö": "o", "ü": "u", "ş": "s", "ç": "c", "ğ": "g"})


def _fold(text):
    """Kucultur ve Turkce harfleri sadelestirir (Python'un lower()'i 'I' ve 'İ' icin Turkce kuralini bilmez)."""
    return str(text or "").replace("İ", "i").replace("I", "ı").lower().translate(_TRIGGER_FOLD)


NEXT_QUESTION_LINE = "Sonraki sorunuzu bekliyorum."


def ready_line(count, new=None, warnings=None, pages=None):
    """Oturum basinda soylenen cumle. new: onceki hazirliktan beri gelen yeni belge sayisi (ilkinde None).
    warnings: atlanan belge gibi uyarilar (sorulari etkiler, o yuzden sesle de soylenir)."""
    line = "%d belge hazır" % count
    if pages and pages != count:
        line = "%d belge, %d sayfa hazır" % (count, pages)
    if new:
        line += ", hepsi yeni" if new >= count else ", %d tanesi yeni" % new
    line += "."
    warn = " ".join(w.strip() for w in (warnings or []) if w and w.strip())
    if warn:
        line += " Dikkat: " + warn
    return line + " Sorunuzu bekliyorum."


GEMINI_VARIANTS = ["cemini", "jemini"]
MIN_CALL_WORD = 3


def call_words(setting):
    """Ayardaki cagri sozcuklerini ('dostum, gemini', virgul ya da noktalivirgul) temiz listeye cevirir:
    3 harften kisa ve yinelenen girdiler atilir, bos kalirsa 'dinle' ve 'gemini' kullanilir, 'gemini' varsa tanima
    varyantlari da eklenir."""
    out, seen = [], set()
    for part in str(setting or "").replace(";", ",").split(","):
        w = part.strip()
        key = _fold(w)
        if len(key) >= MIN_CALL_WORD and key not in seen:
            seen.add(key)
            out.append(w)
    if not out:
        out = ["dinle", "gemini"]
    if "gemini" in {_fold(w) for w in out}:
        out += [v for v in GEMINI_VARIANTS if v not in {_fold(w) for w in out}]
    return out


def strip_trigger(text, words):
    """Sorunun basindaki cagri sozcuklerini ('gemini, ...') atar. Sozcugun ortasindan kesmez
    ('dostumun faturasi' dostum diye baslamis sayilmaz)."""
    t = str(text or "").strip()
    folded = _fold(t)
    for w in sorted(words, key=len, reverse=True):
        w = _fold(w).strip()
        if w and folded.startswith(w):
            if len(folded) > len(w) and folded[len(w)].isalnum():
                continue
            return t[len(w):].lstrip(" ,.:;-")
    return t


# ----------------------------------------------------------------- soru kaydı: konuşma bitince durma
ONSET_GAP = 0.4        # saniye: konusma baslamadan bu kadar sessizlik, biriken kisa seslerin sayimini sifirlar
PREROLL_SECONDS = 1.2  # konusma baslayana kadar yalniz son bu kadar ses tutulur (sonsuz beklemede bellek sismesin)


class EndpointDetector:
    """16 kHz, 16 bit, tek kanal ses akışında konuşmanın başını ve sonunu (sessizlik) bulur."""

    def __init__(self, rate=16000, silence_end=1.3, no_speech=7.0, max_len=30.0, min_speech=0.25):
        self.rate = rate
        self.win = int(rate * 0.02)
        self.silence_end, self.no_speech, self.max_len, self.min_speech = silence_end, no_speech, max_len, min_speech
        self._rest = b""
        self._levels = []
        self.elapsed = 0.0
        self.speech_time = 0.0
        self.silence_run = 0.0
        self.started = False
        self.start_at = 0.0           # konusmanin basladigi an (en uzun sure buradan sayilir)
        self.reason = ""

    def _threshold(self):
        recent = self._levels[-150:]
        floor = float(np.percentile(recent, 20)) if recent else 0.0
        return max(350.0, floor * 2.5 + 120.0)

    def feed(self, pcm):
        """Durum: 'wait' (bekle), 'speech' (konuşma sürüyor), 'done' (bitti), 'nospeech', 'max'."""
        if self.reason:
            return self.reason
        data = self._rest + pcm
        step = self.win * 2
        n = len(data) // step
        self._rest = data[n * step:]
        for i in range(n):
            chunk = np.frombuffer(data[i * step:(i + 1) * step], dtype="<i2").astype(np.float32)
            rms = float(np.sqrt(np.mean(chunk * chunk))) if chunk.size else 0.0
            loud = rms > self._threshold()
            self._levels.append(rms)
            if len(self._levels) > 400:
                del self._levels[:100]
            dt = self.win / float(self.rate)
            self.elapsed += dt
            if loud:
                self.speech_time += dt
                self.silence_run = 0.0
                if self.speech_time >= self.min_speech and not self.started:
                    self.started = True
                    self.start_at = self.elapsed - self.speech_time
            else:
                self.silence_run += dt
                # Konusma baslamadan once uzayan sessizlikte biriken "konusma suresi" sifirlanir: uzun beklemede
                # dagilmis tikirtilar (kapi, tuş sesi) toplanip konusma sayilmasin
                if not self.started and self.silence_run >= ONSET_GAP:
                    self.speech_time = 0.0
            if self.started and self.silence_run >= self.silence_end:
                self.reason = "done"
            elif not self.started and self.elapsed >= self.no_speech:
                self.reason = "nospeech"
            elif self.started and self.elapsed - self.start_at >= self.max_len:
                self.reason = "max"
            if self.reason:
                return self.reason
        return "speech" if self.started else "wait"


def beep(freq, ms):
    if os.name != "nt" or os.environ.get("SK_NO_BEEP"):
        return
    try:
        import winsound
        winsound.Beep(int(freq), int(ms))
    except Exception:
        pass


END_WORD_MAX = 120.0     # "tamam" modunda tek bir kaydin en uzun suresi (sn)


def record_question(voice, stop, on_status=None, rate=16000, end_word=False, end_silence=15.0, **kw):
    """Mikrofondan soruyu kaydeder. Vosk dinleyicisi çalışıyorsa onun sesini kullanır (mikrofonu ikinci kez açmaz).
    end_word=True: kayıt, kullanıcı "tamam" deyince biter (ses motoru çalışıyorsa); konuşmadan sonra end_silence saniye sessizlik olursa da biter.
    Donus: (pcm, neden)  neden: done | word | nospeech | max | stopped | error:<metin>"""
    done_ev = None
    if end_word and voice is not None and getattr(voice, "ready", False):
        done_ev = threading.Event()
        voice.done_event = done_ev
        voice.only_commands = {"done"}
        kw.setdefault("silence_end", float(end_silence))
        kw.setdefault("max_len", END_WORD_MAX)
    det = EndpointDetector(rate, **kw)
    audio = queue.Queue(maxsize=400)
    chunks = []
    tapped = voice is not None and voice.mode == "vosk" and voice.ready
    stream = None
    if tapped:
        voice.tap = lambda b: audio.put_nowait(bytes(b)) if not audio.full() else None
    else:
        try:
            import sounddevice as sd

            def cb(indata, frames, t, status):
                try:
                    audio.put_nowait(bytes(indata))
                except queue.Full:
                    pass
            from .voice import open_input
            stream = open_input(sd, getattr(voice, "mic_name", ""), cb, rate, 1600)
        except Exception as e:
            return b"", "error:Mikrofon açılamadı (%s)" % str(e).strip().replace("\n", " ")[:420]
    try:
        beep(880, 110)
        if on_status:
            on_status("Dinliyorum...")
        reason = ""
        while not stop.is_set():
            if done_ev is not None and done_ev.is_set():
                return b"".join(chunks), "word"
            try:
                b = audio.get(timeout=0.3)
            except queue.Empty:
                continue
            chunks.append(b)
            reason = det.feed(b)
            if reason in ("done", "nospeech", "max"):
                break
            if reason == "wait":      # konusma henuz baslamadi: yalniz son birkac saniyeyi tut
                keep = int(rate * 2 * PREROLL_SECONDS)
                while len(chunks) > 1 and sum(len(c) for c in chunks[1:]) >= keep:
                    chunks.pop(0)
        else:
            reason = "stopped"
        return b"".join(chunks), reason
    finally:
        if done_ev is not None:
            voice.only_commands = None
            voice.done_event = None
        if tapped:
            voice.tap = None
        if stream is not None:
            try:
                stream.stop()
                stream.close()
            except Exception:
                pass
        beep(520, 90)


# ----------------------------------------------------------------- sesli okuma
TTS_PS = r'''
param([string]$TextFile, [string]$Voice = '', [int]$Rate = 0, [string]$Culture = 'tr-TR', [int]$List = 0)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
function Say([string]$s) { [Console]::Out.WriteLine($s); [Console]::Out.Flush() }
try {
    Add-Type -AssemblyName System.Speech
    $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
    $all = $synth.GetInstalledVoices() | Where-Object { $_.Enabled }
    if ($List -eq 1) {
        foreach ($v in $all) { $i = $v.VoiceInfo; Say ('VOICE|' + $i.Name + '|' + $i.Culture.Name + '|' + $i.Gender) }
        exit 0
    }
    $picked = $null
    if ($Voice) { $picked = $all | Where-Object { $_.VoiceInfo.Name -eq $Voice } | Select-Object -First 1 }
    if (-not $picked) { $picked = $all | Where-Object { $_.VoiceInfo.Culture.Name -eq $Culture } | Select-Object -First 1 }
    if (-not $picked) { $picked = $all | Where-Object { $_.VoiceInfo.Culture.TwoLetterISOLanguageName -eq 'tr' } | Select-Object -First 1 }
    $isTr = $true
    if ($picked) { $synth.SelectVoice($picked.VoiceInfo.Name) } else { $isTr = $false }
    Say ('INFO|' + $synth.Voice.Name + '|' + $synth.Voice.Culture.Name + '|' + $isTr)
    $synth.Rate = [Math]::Max(-10, [Math]::Min(10, $Rate))
    $synth.Volume = 100
    $lines = [System.IO.File]::ReadAllLines($TextFile, [System.Text.Encoding]::UTF8)
    $pb = New-Object System.Speech.Synthesis.PromptBuilder
    if ($picked) { $pb.Culture = $picked.VoiceInfo.Culture }
    foreach ($l in $lines) {
        if ($l.Trim().Length -eq 0) { continue }
        $pb.AppendText($l)
        $pb.AppendBreak([TimeSpan]::FromMilliseconds(220))
    }
    $synth.Speak($pb)
    Say 'DONE'
} catch {
    Say ('ERROR|' + ($_.Exception.Message -replace "[\r\n]+", ' '))
    exit 1
}
'''

_NO_WINDOW = 0x08000000


def _play_wav_blocking(wav):
    """Windows'ta WAV'ı çalar (bitene kadar bekler). Test için Speaker.play_wav ile değiştirilebilir."""
    import winsound
    winsound.PlaySound(wav, winsound.SND_MEMORY)


def _stop_wav_playback():
    try:
        import winsound
        winsound.PlaySound(None, winsound.SND_PURGE)
    except Exception:
        pass


class Speaker:
    """Cevabı yüksek sesle okur. Motor: 'windows' (System.Speech) ya da 'gemini' (Gemini sesi, hata olursa Windows'a döner)."""

    def __init__(self, settings, gemini=None, work_dir=None):
        self.s = settings
        self.gemini = gemini
        self.work_dir = work_dir or tempfile.gettempdir()
        self.on_state = None            # on_state(True/False): okuma başladı / bitti
        self.play_wav = _play_wav_blocking
        self.stop_wav = _stop_wav_playback
        self.force_engine = ""          # dolu ise ayardaki motor yerine bu kullanılır (ör. konumlandırma uyarıları her zaman "windows")
        self.last_error = ""
        self.last_voice = ""            # kullanılan Windows sesi (bilgi için)
        self.last_engine = ""           # gerçekten kullanılan motor
        self.said = []                  # son okunanlar (tanı/test)
        self._gen = 0
        self._lock = threading.Lock()
        self._proc = None
        self._thread = None
        self._speaking = False

    @property
    def speaking(self):
        return self._speaking

    def _set_speaking(self, gen, value):
        with self._lock:
            if gen != self._gen and value is False:
                return
            changed = self._speaking != value
            self._speaking = value
        if changed and self.on_state:
            try:
                self.on_state(value)
            except Exception as e:
                log("[ses] on_state hatasi: %r" % (e,))

    def say(self, text, wait=False, on_done=None, engine=""):
        """Metni okutmaya başlar (öncekini keser). wait=True ise bitene kadar bekler.
        engine: dolu ise (ör. "windows") ayardaki motor yerine bu kullanılır (kısa uyarılar internet/kota istemesin).
        on_done: metin SONUNA KADAR okunduysa (kesilmedi, ses hatası olmadı) okuma iş parçacığında bir kez çağrılır."""
        spoken = clean_for_speech(text)
        sentences = split_sentences(spoken)
        if not sentences:
            return None
        self.stop()
        with self._lock:
            self._gen += 1
            gen = self._gen
        self.said.append(spoken)
        del self.said[:-20]
        t = threading.Thread(target=self._run, args=(gen, sentences, on_done, engine), daemon=True, name="sk-oku")
        self._thread = t
        self._set_speaking(gen, True)
        t.start()
        if wait:
            t.join()
        return t

    def stop(self):
        with self._lock:
            self._gen += 1
            proc = self._proc
        if proc is not None:
            try:
                proc.kill()
            except OSError:
                pass
        self.stop_wav()
        self._set_speaking(self._gen, False)

    def _run(self, gen, sentences, on_done=None, engine=""):
        run = {"error": False}
        try:
            engine = engine or self.force_engine or self.s["tts_engine"]
            if engine == "gemini" and self.gemini is not None and self.gemini.has_key():
                if self._run_gemini(gen, sentences, run):
                    pass
                else:
                    self._run_windows(gen, sentences, run)
            else:
                self._run_windows(gen, sentences, run)
        except Exception as e:
            run["error"] = True
            self.last_error = "Okuma hatası: %s" % e
            log("[oku] hata: %r" % (e,))
        finally:
            self._set_speaking(gen, False)
        if on_done is not None and not run["error"] and gen == self._gen:
            try:
                on_done()
            except Exception as e:
                log("[oku] on_done hatasi: %r" % (e,))

    # ---- Windows sesi
    def _command(self, textfile):
        override = os.environ.get("SK_TTS_CMD")
        if override:
            return override.split("|") + [textfile]
        if os.name != "nt":
            return None
        path = self._script_path()
        return ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", path,
                "-TextFile", textfile, "-Voice", self.s["tts_voice"], "-Rate", str(int(self.s["tts_rate"]))]

    def _script_path(self):
        """PowerShell betiğini (içerik değişmediyse yeniden yazmadan) hazırlar: çalışan bir okumanın dosyası kilitlenmesin."""
        os.makedirs(self.work_dir, exist_ok=True)
        path = os.path.join(self.work_dir, "oku.ps1")
        try:
            with open(path, "r", encoding="utf-8-sig") as f:
                if f.read() == TTS_PS:
                    return path
        except OSError:
            pass
        with open(path, "w", encoding="utf-8-sig") as f:
            f.write(TTS_PS)
        return path

    def _run_windows(self, gen, sentences, run=None):
        run = run if run is not None else {}
        self.last_engine = "windows"
        fd, textfile = tempfile.mkstemp(suffix=".txt", prefix="skoku")
        try:
            with os.fdopen(fd, "w", encoding="utf-8-sig") as f:
                f.write("\n".join(sentences))
            cmd = self._command(textfile)
            if cmd is None:
                self.last_error = "Windows sesi yalnızca Windows'ta çalışır."
                run["error"] = True
                return
            kwargs = {"creationflags": _NO_WINDOW} if os.name == "nt" else {}
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, **kwargs)
            with self._lock:
                if gen != self._gen:
                    proc.kill()
                    return
                self._proc = proc
            err = ""
            done_seen = False
            for raw in iter(proc.stdout.readline, b""):
                line = raw.decode("utf-8", "replace").strip("\r\n﻿ ")
                if line.startswith("INFO|"):
                    parts = line.split("|")
                    self.last_voice = "%s (%s)" % (parts[1], parts[2]) if len(parts) > 2 else parts[1]
                    if len(parts) > 3 and parts[3].strip().lower() == "false":
                        log("[oku] UYARI: Türkçe Windows sesi kurulu değil, başka ses kullanılıyor")
                        self.last_error = "Türkçe Windows sesi kurulu değil; okuma bozuk olabilir. Ayarlar > Zaman ve dil > Konuşma bölümünden Türkçe sesi ekleyin."
                elif line.startswith("ERROR|"):
                    err = line[6:]
                elif line == "DONE":
                    done_seen = True
            proc.wait()
            if err:
                run["error"] = True
                self.last_error = "Okuma hatası: " + err
                log("[oku] " + err)
            elif not done_seen and gen == self._gen:
                # Betik 'DONE' demeden kapandı (çöktü, dışarıdan sonlandırıldı): okuma sonuna kadar duyulmuş sayılmaz
                run["error"] = True
                self.last_error = "Okuma tamamlanamadı: Windows sesi beklenmedik biçimde kapandı."
                log("[oku] " + self.last_error)
        finally:
            with self._lock:
                self._proc = None
            try:
                os.remove(textfile)
            except OSError:
                pass

    # ---- Gemini sesi
    def _run_gemini(self, gen, sentences, run=None):
        """True = tamam, False = Windows sesine dönülmeli (hiç ses çalınmadıysa)."""
        run = run if run is not None else {}
        groups = group_sentences(sentences)
        q = queue.Queue(maxsize=2)
        failed = []

        def producer():
            for g in groups:
                if gen != self._gen:
                    break
                try:
                    pcm, rate = self.gemini.speak_pcm(" ".join(g))
                    q.put(wav_bytes(pcm, rate))
                except Exception as e:
                    failed.append(str(e))
                    break
            q.put(None)

        threading.Thread(target=producer, daemon=True, name="sk-gtts").start()
        self.last_engine = "gemini"
        played = 0
        while True:
            item = q.get()
            if item is None:
                break
            if gen != self._gen:
                return True
            try:
                self.play_wav(item)
                played += 1
            except Exception as e:
                self.last_error = "Ses çalınamadı: %s" % e
                if played > 0:
                    run["error"] = True
                return played > 0
        if failed:
            self.last_error = "Gemini sesi alınamadı, Windows sesine geçildi: " + failed[0]
            log("[oku] " + self.last_error)
            rest = [s for g in groups[played:] for s in g]
            if rest and gen == self._gen:
                self._run_windows(gen, rest, run)
        return True

    # ---- yüklü Windows sesleri
    def installed_voices(self):
        """[(ad, kültür)] — Windows'ta System.Speech'in bildirdiği sesler."""
        override = os.environ.get("SK_TTS_LIST")
        out = []
        if override:
            lines = override.split(";")
        elif os.name == "nt":
            path = self._script_path()
            try:
                res = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                                      "-File", path, "-TextFile", "x", "-List", "1"], stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, timeout=30, creationflags=_NO_WINDOW)
                lines = res.stdout.decode("utf-8", "replace").splitlines()
            except Exception:
                lines = []
        else:
            lines = []
        for line in lines:
            parts = line.strip("\r\n﻿ ").split("|")
            if parts[0] == "VOICE" and len(parts) >= 3:
                out.append((parts[1], parts[2]))
        return out
