# -*- coding: utf-8 -*-
"""'Okey' sesli komutu: Windows'un kendi konuşma tanıması (System.Speech, PowerShell uzerinden)."""
import base64
import json
import os
import queue
import shutil
import subprocess
import sys
import threading
import time
import unicodedata
import urllib.request
import zipfile

from .applog import log

_FOLD = str.maketrans({"ı": "i", "İ": "i", "ö": "o", "Ö": "o", "ü": "u", "Ü": "u",
                       "ş": "s", "Ş": "s", "ç": "c", "Ç": "c", "ğ": "g", "Ğ": "g"})


# ----------------------------------------------------------------- Eslestirme
def words(text):
    s = (text or "").replace("İ", "i").replace("I", "ı").lower().translate(_FOLD)
    s = unicodedata.normalize("NFKD", s)
    s = "".join(ch for ch in s if not unicodedata.combining(ch))
    out, cur = [], ""
    for ch in s:
        if ch.isalnum():
            cur += ch
        elif cur:
            out.append(cur)
            cur = ""
    if cur:
        out.append(cur)
    return out


def patterns(trigger):
    result = []
    for part in (trigger or "").replace(";", ",").split(","):
        w = words(part)
        if not w:
            continue
        result.append(w)
        if w == ["okey"]:
            result += [["okay"], ["oke"], ["ok"], ["o", "key"], ["o", "kay"]]
        if w == ["gemini"]:       # Turkce tanima motoru yabanci adi boyle bolup yazabilir
            result += [["cemini"], ["jemini"], ["gemin"], ["ge", "mini"], ["ce", "mini"], ["cem", "ini"], ["jem", "ini"],
                       ["gem", "ini"], ["gemi", "ni"], ["jeminay"]]
    return result


def _distance(a, b):
    if not a:
        return len(b)
    if not b:
        return len(a)
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def word_matches(heard, target):
    if heard == target:
        return True
    if min(len(heard), len(target)) < 4:
        return False
    return _distance(heard, target) <= 1


def occurrences(transcript, trigger):
    heard = words(transcript)
    pats = patterns(trigger)
    if not heard or not pats:
        return 0
    count, i = 0, 0
    while i < len(heard):
        matched = 0
        for p in pats:
            if i + len(p) <= len(heard) and all(word_matches(heard[i + k], p[k]) for k in range(len(p))):
                matched = max(matched, len(p))
        if matched:
            count += 1
            i += matched
        else:
            i += 1
    return count


def ends_with(transcript, trigger):
    """Metnin SON sözcük(ler)i tetik sözcüklerinden biri mi? ('... çöz tamam' evet; 'tamam mı' ya da 'tamamlandı' hayır)"""
    heard = words(transcript)
    for p in patterns(trigger):
        n = len(p)
        if n and len(heard) >= n and all(word_matches(heard[len(heard) - n + k], p[k]) for k in range(n)):
            return True
    return False


# ----------------------------------------------------------------- PowerShell tarafi
PS_SCRIPT = r'''
param([string]$WordsB64, [double]$Threshold = 0.55, [string]$Culture = 'tr-TR', [int]$Dictation = 1)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
function Say([string]$s) { [Console]::Out.WriteLine($s); [Console]::Out.Flush() }
try {
    Add-Type -AssemblyName System.Speech
    $words = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($WordsB64)).Split('|')
    $infos = [System.Speech.Recognition.SpeechRecognitionEngine]::InstalledRecognizers()
    if ($infos.Count -eq 0) { Say 'ERROR|Windows konusma tanima motoru kurulu degil'; exit 2 }
    $info = $infos | Where-Object { $_.Culture.Name -eq $Culture } | Select-Object -First 1
    $fallback = $false
    if (-not $info) {
        $info = $infos | Where-Object { $_.Culture.TwoLetterISOLanguageName -eq 'tr' } | Select-Object -First 1
    }
    if (-not $info) { $info = $infos | Select-Object -First 1; $fallback = $true }
    $engine = New-Object -TypeName System.Speech.Recognition.SpeechRecognitionEngine -ArgumentList (, $info)
    $isTr = ($info.Culture.TwoLetterISOLanguageName -eq 'tr')
    $choices = New-Object System.Speech.Recognition.Choices
    foreach ($w in $words) {
        $w = $w.Trim()
        if ($w.Length -eq 0) { continue }
        $choices.Add($w)
        # Turkce tanima motoru yoksa (genelde yalnizca Ingilizce kurulu): 'okey' sesi Ingilizce 'okay' ile taninir
        if ((-not $isTr) -and ($w -eq 'okey')) { $choices.Add('okay'); $choices.Add('ok') }
    }
    $gb = New-Object System.Speech.Recognition.GrammarBuilder
    $gb.Culture = $info.Culture
    $gb.Append($choices)
    $grammar = New-Object -TypeName System.Speech.Recognition.Grammar -ArgumentList (, $gb)
    $engine.LoadGrammar($grammar)
    $dict = 'yok'
    if ($Dictation -eq 1) {
        try {
            $engine.LoadGrammar((New-Object System.Speech.Recognition.DictationGrammar))
            $dict = 'var'
        } catch { $dict = 'yok' }
    }
    $engine.SetInputToDefaultAudioDevice()
    Say ('INFO|' + $info.Culture.Name + '|' + $info.Description + '|' + $dict + '|' + $fallback)
    Say 'READY'
    while ($true) {
        $r = $engine.Recognize([TimeSpan]::FromSeconds(4))
        if ($r -ne $null) {
            $t = ($r.Text -replace '\|', ' ')
            Say ('HEARD|' + $t + '|' + [Math]::Round($r.Confidence, 2))
        } else {
            Say 'TICK'
        }
    }
} catch {
    Say ('ERROR|' + ($_.Exception.Message -replace "[\r\n]+", ' '))
    exit 1
}
'''


MODEL_URLS = [
    "https://alphacephei.com/vosk/models/vosk-model-small-tr-0.3.zip",
    "https://huggingface.co/rhasspy/vosk-models/resolve/main/tr/vosk-model-small-tr-0.3.zip",
]

ENGINE_ORDER = {
    "auto": ("vosk", "windows", "browser"),
    "vosk": ("vosk",),
    "windows": ("windows",),
    "browser": ("browser",),
}
ENGINE_LABEL = {"vosk": "Cevrimdisi Turkce ses", "windows": "Windows konusma tanima"}


# ----------------------------------------------------------------- Cevrimdisi model (Vosk)
def model_path(work_dir):
    return os.environ.get("SK_VOSK_MODEL") or os.path.join(work_dir, "model-tr")


def _looks_like_model(path, dirnames, filenames):
    """Vosk'un iki duzeni: yeni (am/ + conf/) ve eski (dogrudan final.mdl)."""
    if "am" in dirnames and "conf" in dirnames:
        return True
    return "final.mdl" in filenames and ("mfcc.conf" in filenames or "conf" in dirnames)


def model_ready(work_dir):
    p = model_path(work_dir)
    if not os.path.isdir(p):
        return False
    try:
        names = os.listdir(p)
    except OSError:
        return False
    dirs = [n for n in names if os.path.isdir(os.path.join(p, n))]
    files = [n for n in names if os.path.isfile(os.path.join(p, n))]
    return _looks_like_model(p, dirs, files)


def vosk_importable():
    try:
        import vosk  # noqa: F401
        import sounddevice  # noqa: F401
        return True
    except Exception:
        return False


MODEL_PAGE = "https://alphacephei.com/vosk/models/vosk-model-small-tr-0.3.zip"
LOCAL_ZIP_NAMES = ("model-tr.zip", "vosk-model-small-tr-0.3.zip", "ses-modeli.zip")


def local_model_zip(work_dir):
    """Kullanicinin tarayiciyla indirip biraktigi model zip'i (varsa). Silinmez."""
    folders = [work_dir]
    home = os.path.expanduser("~")
    folders.append(os.path.join(home, "Downloads"))
    folders.append(os.path.join(home, "Indirilenler"))
    for folder in folders:
        for name in LOCAL_ZIP_NAMES:
            path = os.path.join(folder, name)
            if os.path.isfile(path) and os.path.getsize(path) > 64 * 1024:
                return path
    return ""


def _zip_listing(z, limit=8):
    tops = []
    for n in z.namelist():
        head = n.replace("\\", "/").lstrip("/").split("/")[0]
        if head and head not in tops:
            tops.append(head)
    shown = ", ".join(tops[:limit]) + (" ..." if len(tops) > limit else "")
    return "%d dosya; ust duzey: %s" % (len(z.namelist()), shown or "(bos)")


def _manual_hint():
    return (" Elle kurmak icin: %s adresini tarayicida acip zip'i Indirilenler klasorune kaydedin, "
            "sonra bu dugmeye yeniden basin." % MODEL_PAGE)


def _unpack_model(source, work_dir, target, progress=None):
    """Zip'i acar ve model klasorunu `target`a tasir. Donus: hata metni ('' = tamam)."""
    tmp = os.path.join(work_dir, "model-tmp")
    try:
        if progress:
            progress("Ses modeli aciliyor...")
        shutil.rmtree(tmp, ignore_errors=True)
        size_mb = os.path.getsize(source) / 1048576.0
        with zipfile.ZipFile(source) as z:
            listing = _zip_listing(z)
            log("[ses] model zip'i: %.1f MB, %s" % (size_mb, listing))
            for n in z.namelist()[:60]:
                log("[ses]   " + n)
            z.extractall(tmp)
        root = None
        for dirpath, dirnames, files in os.walk(tmp):
            if _looks_like_model(dirpath, dirnames, files):
                root = dirpath
                break
        if root is None:
            return "Indirilen dosya bir ses modeli gibi gorunmuyor (%.1f MB; %s)." % (size_mb, listing)
        shutil.rmtree(target, ignore_errors=True)
        shutil.move(root, target)
        return ""
    except zipfile.BadZipFile:
        return "Indirilen dosya zip degil (yarim kalmis ya da bir hata sayfasi olabilir)."
    except Exception as e:
        return "Model acilamadi: %s" % e
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def download_model(work_dir, progress=None):
    """Turkce Vosk modelini indirir (ya da kullanicinin biraktigi hazir zip'i kullanir) ve acar.
    Donus: hata metni ('' = tamam)."""
    target = model_path(work_dir)
    os.makedirs(work_dir, exist_ok=True)
    part = os.path.join(work_dir, "model-tr.zip.part")
    local_error = ""
    local = local_model_zip(work_dir)
    if local:
        log("[ses] hazir model zip'i kullaniliyor: " + local)
        if progress:
            progress("Hazir ses modeli bulundu, aciliyor...")
        local_error = _unpack_model(local, work_dir, target, progress)
        if not local_error:
            return ""
        log("[ses] hazir zip kullanilamadi (%s): %s" % (local, local_error))
        local_error = "Hazir zip (%s): %s " % (os.path.basename(local), local_error)
    last_error = ""
    for url in MODEL_URLS:
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "Sesli-Kontrol"})
            with urllib.request.urlopen(req, timeout=30) as resp, open(part, "wb") as out:
                total = int(resp.headers.get("Content-Length") or 0)
                done = 0
                while True:
                    chunk = resp.read(256 * 1024)
                    if not chunk:
                        break
                    out.write(chunk)
                    done += len(chunk)
                    if progress:
                        progress("Ses modeli indiriliyor: %d MB%s" % (
                            done // 1048576, (" / %d MB" % (total // 1048576)) if total else ""))
            break
        except Exception as e:
            last_error = "%s (%s)" % (e, url.split("/")[2])
            log("[ses] model indirilemedi: " + last_error)
            try:
                os.remove(part)
            except OSError:
                pass
    else:
        return local_error + "Model indirilemedi: " + last_error + "." + _manual_hint()
    try:
        err = _unpack_model(part, work_dir, target, progress)
    finally:
        try:
            os.remove(part)
        except OSError:
            pass
    return (local_error + err + _manual_hint()) if err else ""


def check_model(work_dir):
    """Model gercekten yuklenebiliyor mu? ('' = evet ya da denenemedi). Yuklenemiyorsa model silinir."""
    try:
        import vosk
    except Exception:
        return ""
    try:
        try:
            vosk.SetLogLevel(-1)
        except Exception:
            pass
        vosk.Model(model_path(work_dir))
        return ""
    except Exception as e:
        shutil.rmtree(model_path(work_dir), ignore_errors=True)
        return "Model indirildi ama yuklenemedi: %s." % e + _manual_hint()


# ----------------------------------------------------------------- Mikrofon secimi
# Gercek mikrofon olmayan (Windows'un kendi yonlendirme/geri-dinleme) girisler listede gosterilmez; varsayilan ise yine kullanilir.
VIRTUAL_INPUTS = ("sound mapper", "primary sound", "ses eşleyici", "ses esleyici", "birincil ses", "stereo mix",
                  "karışım", "karisim", "loopback", "what u hear", "wave out")
PRIVACY_HINT = " Windows Ayarlar > Gizlilik ve güvenlik > Mikrofon bölümünde masaüstü uygulamalarına izin verildiğinden emin olun."


def _sounddevice(sd):
    if sd is not None:
        return sd, ""
    try:
        import sounddevice
        return sounddevice, ""
    except Exception:
        return None, "Ses paketi (sounddevice) kurulu degil."


def input_devices(sd=None):
    """Bilgisayardaki mikrofonlar: ([{"index", "name", "default", "virtual"}], hata_metni).
    Windows ayni aygiti birkac ses sistemi (MME, DirectSound, WASAPI...) altinda tekrar tekrar listeler;
    yalnizca varsayilan girisin ses sistemindekiler alinir (ayni ad bir kez)."""
    sd, err = _sounddevice(sd)
    if sd is None:
        return [], err
    try:
        devices = list(sd.query_devices())
    except Exception as e:
        return [], "Ses aygitlari okunamadi: %s" % e
    try:
        default_index = int(sd.default.device[0])
    except Exception:
        default_index = -1
    api = devices[default_index].get("hostapi") if 0 <= default_index < len(devices) else None
    inputs = [(i, d) for i, d in enumerate(devices) if (d.get("max_input_channels") or 0) > 0]
    same = [(i, d) for i, d in inputs if api is None or d.get("hostapi") == api]
    out, seen = [], set()
    for i, d in same or inputs:
        name = str(d.get("name") or "").strip()
        low = name.lower()
        if not name or low in seen:
            continue
        seen.add(low)
        out.append({"index": i, "name": name, "default": i == default_index,
                    "virtual": any(v in low for v in VIRTUAL_INPUTS)})
    return out, ""


NO_MIC = "Bilgisayarda mikrofon bulunamadi. Mikrofon takili mi?" + PRIVACY_HINT


def _order(devices, preferred):
    """Aygit listesini deneme sirasina koyar: secilen (ayardaki ad), Windows varsayilani, diger gercek mikrofonlar.
    Secilen bulunamazsa not dusulur ve otomatige donulur. Donus: ([(index, ad)], not)."""
    order, note = [], ""
    want = (preferred or "").strip().lower()
    if want:
        hit = next((d for d in devices if d["name"].lower() == want), None) or \
            next((d for d in devices if want in d["name"].lower() or d["name"].lower() in want), None)
        if hit:
            order.append(hit)
        else:
            note = "Secili mikrofon (%s) bulunamadi, otomatik secildi." % preferred.strip()
    order += [d for d in devices if d["default"] and d not in order]
    order += [d for d in devices if not d["virtual"] and d not in order]
    return [(d["index"], d["name"]) for d in order], note


def mic_candidates(preferred="", sd=None):
    """Denenecek mikrofonlar, sirasiyla: [(index, ad)] ve not metni (liste bos ise not nedenidir)."""
    devices, err = input_devices(sd)
    if err:
        return [], err
    if not devices:
        return [], NO_MIC
    return _order(devices, preferred)


class OpenedMic:
    """Acilmis mikrofon akisi (with ile kullanilir)."""

    def __init__(self, stream, name, note=""):
        self.stream, self.name, self.note = stream, name, note

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False

    def stop(self):
        self.stream.stop()

    def close(self):
        for fn in (self.stream.stop, self.stream.close):
            try:
                fn()
            except Exception:
                pass


def open_input(sd, preferred, callback, samplerate=16000, blocksize=4000):
    """Mikrofonu acar ve baslatir: secilen, olmazsa Windows varsayilani, olmazsa digerleri. Donus: OpenedMic.
    Hicbiri acilamazsa son hata, denenenlerin listesi ve izin ipucuyla birlikte OSError olarak cikar."""
    sd, err = _sounddevice(sd)
    if sd is None:
        raise OSError(err)
    devices, err = input_devices(sd)
    if err:
        # Liste okunamadi: yine de Windows varsayilanini dene (eski davranis)
        cands, note = [(None, "varsayilan mikrofon")], ""
    elif not devices:
        raise OSError(NO_MIC)
    else:
        cands, note = _order(devices, preferred)
    last, tried = None, []
    for index, name in cands:
        stream = None
        try:
            stream = sd.RawInputStream(samplerate=samplerate, blocksize=blocksize, dtype="int16", channels=1,
                                       callback=callback, device=index)
            stream.start()
            if tried:
                log("[ses] mikrofon: %s (onceki denenenler acilamadi: %s)" % (name, ", ".join(tried)))
            return OpenedMic(stream, name, note)
        except Exception as e:
            if stream is not None:
                try:
                    stream.close()
                except Exception:
                    pass
            last = e
            tried.append(name)
            log("[ses] mikrofon acilamadi (%s): %s" % (name, str(e).strip().replace("\n", " ")[:120]))
    text = str(last).strip().replace("\n", " ")[:120]
    raise OSError("%s (denenen: %s).%s" % (text, ", ".join(tried), PRIVACY_HINT))


def measure_level(pcm):
    """16 bit PCM'in (tepe, rms) duzeyi, 0-1 araliginda."""
    import numpy as np
    data = np.frombuffer(pcm[: len(pcm) // 2 * 2], dtype=np.int16)
    if data.size == 0:
        return 0.0, 0.0
    f = data.astype(np.float32) / 32768.0
    return float(np.abs(f).max()), float(np.sqrt((f * f).mean()))


def describe_level(peak):
    if peak < 0.004:
        return False, "Ses hiç gelmiyor. Mikrofon sessize alınmış, çıkarılmış ya da Windows'ta izni kapalı olabilir." + PRIVACY_HINT
    if peak < 0.04:
        return False, "Ses çok zayıf. Mikrofona yaklaşın ya da Windows'ta giriş düzeyini artırın."
    return True, "Mikrofon çalışıyor."


def test_microphone(preferred="", voice=None, sd=None, seconds=2.0, sleep=time.sleep):
    """Mikrofonu `seconds` sn dinleyip duzeyini olcer. Donus: {"ok", "device", "peak", "message"}.
    Cevrimdisi Turkce (Vosk) dinleyicisi mikrofonu zaten aciksa onun sesinden olcer (ikinci kez acmaz)."""
    got = []
    device = ""
    try:
        if voice is not None and voice.mode == "vosk" and voice.ready:
            if voice.tap is not None:
                return {"ok": False, "device": "", "peak": 0.0, "message": "Şu an soru kaydı sürüyor; birazdan yeniden deneyin."}
            voice.tap = lambda b: got.append(bytes(b))
            try:
                sleep(seconds)
            finally:
                voice.tap = None
            device = getattr(voice, "mic_used", "") or ""
        else:
            with open_input(sd, preferred, lambda indata, frames, t, status: got.append(bytes(indata)), 16000, 1600) as mic:
                device = mic.name
                sleep(seconds)
    except OSError as e:
        return {"ok": False, "device": "", "peak": 0.0, "message": "Mikrofon açılamadı: %s" % e}
    peak, _rms = measure_level(b"".join(got))
    ok, message = describe_level(peak)
    return {"ok": ok, "device": device, "peak": round(peak, 3), "message": message}


def install_offline_voice(work_dir, progress=None):
    """Vosk + sounddevice paketlerini ve Turkce modeli kurar. Donus: hata metni ('' = tamam)."""
    if not vosk_importable():
        if progress:
            progress("Ses paketleri kuruluyor (vosk, sounddevice)...")
        cmd = [sys.executable, "-m", "pip", "install", "--user", "--disable-pip-version-check",
               "--no-input", "vosk", "sounddevice"]
        kwargs = {"creationflags": 0x08000000} if os.name == "nt" else {}
        try:
            out = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=900, **kwargs)
        except Exception as e:
            return "Paketler kurulamadi: %s" % e
        if out.returncode != 0:
            tail = out.stdout.decode("utf-8", "replace").strip().splitlines()[-3:]
            return "Paketler kurulamadi: " + " | ".join(tail)
        try:
            import importlib
            import site
            site.addsitedir(site.getusersitepackages())
            importlib.invalidate_caches()
        except Exception:
            pass
        if not vosk_importable():
            return "Paketler kuruldu ama yuklenemedi. Programi kapatip yeniden acin."
    if not model_ready(work_dir):
        err = download_model(work_dir, progress)
        if err:
            return err
        err = check_model(work_dir)
        if err:
            return err
    return ""


# ----------------------------------------------------------------- Ses dinleyici
class VoiceTrigger:
    """Surekli dinler. Duyulan metinde tetikleme sozcugu varsa on_trigger(metin) cagrilir.
    Motorlar sirayla denenir: cevrimdisi Turkce (Vosk) -> Windows -> tarayici."""

    def __init__(self, work_dir):
        self.on_trigger = None
        self.on_status = None
        self.on_heard = None
        self.on_command = None      # on_command(ad, metin): ek komutlar (ör. "gemini", "pil durumu")
        self.intent_hook = None     # intent_hook(metin) -> True: serbest söylenen metni ANLAM olarak yorumlar (deneme sınavı komutları)
        self.commands = {}          # ad -> virgülle ayrılmış söyleniş listesi
        self.tap = None             # tap(bytes): Vosk'un 16 kHz ses blokları (soru kaydı için)
        self.muted = False          # True iken duyulanlar komut sayılmaz (kendi sesimizi duymayalım)
        self.only_commands = None   # küme: kayıt sırasında YALNIZ bu komutlar dinlenir (ör. {"done"}: "tamam"); muted'ı da aşar
        self.done_event = None      # "done" komutu (cümlenin SON sözcüğü olarak söylenen "tamam") duyulunca set edilir
        self._model = None
        self.work_dir = work_dir
        self._stop = threading.Event()
        self._thread = None
        self._proc = None
        self._lock = threading.Lock()
        self.trigger = "okey"
        self.threshold = 0.55
        self.ready = False
        self.info = ""
        self.mode = ""          # "vosk" | "windows" | "browser" | ""
        self.mic_name = ""      # secilen mikrofon adi ("" = otomatik)
        self.mic_used = ""      # su an acik olan mikrofon

    def _status(self, text):
        if self.on_status:
            self.on_status(text)

    def start(self, trigger, threshold=0.55, engine="auto"):
        self.stop()
        self.trigger = trigger
        self.threshold = threshold
        self.mode = ""
        self.info = ""
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._loop, args=(self._stop, trigger, threshold, engine),
                                        daemon=True, name="sk-ses")
        self._thread.start()

    def stop(self):
        self._stop.set()
        with self._lock:
            proc = self._proc
        if proc is not None:
            try:
                proc.kill()
            except OSError:
                pass
        self.ready = False
        self.mode = ""

    # ---- ortak
    def set_commands(self, commands):
        """{ad: 'soz1, soz2'} — tetik sözcüğünden ayrı, adlandırılmış sesli komutlar."""
        self.commands = {k: v for k, v in (commands or {}).items() if words(v)}

    def command_for(self, text):
        for name, trig in self.commands.items():
            if occurrences(text, trig) > 0:
                return name
        return None

    def transcribe_pcm(self, pcm):
        """Kaydedilmiş 16 kHz/16 bit sesi çevrimdışı metne çevirir (Vosk modeli yüklüyse), yoksa ''."""
        model = self._model
        if model is None:
            return ""
        try:
            import vosk
            rec = vosk.KaldiRecognizer(model, 16000)
            for i in range(0, len(pcm), 8000):
                rec.AcceptWaveform(pcm[i:i + 8000])
            return str(json.loads(rec.FinalResult()).get("text", "")).strip()
        except Exception as e:
            log("[ses] kayit metne cevrilemedi: %r" % (e,))
            return ""

    def _heard(self, text, conf=1.0, check_threshold=False, allow=True, final=True):
        if self.on_heard:
            self.on_heard(("%s (%.2f)" % (text, conf)) if conf < 1.0 else text)
        only = self.only_commands
        if only is not None:
            # Kayıt sürüyor: yalnız bitirme sözcüğü ("tamam") dinlenir; kısmi sonuçta ve cümle ortasında ("tamam mı") bitirmez
            if not final or not allow or (check_threshold and conf < self.threshold):
                return False
            for name in only:
                trig = self.commands.get(name)
                if trig and ends_with(text, trig):
                    log("[ses] kayit bitirme sozcugu (%s): %r" % (name, text))
                    ev = self.done_event
                    if name == "done" and ev is not None:
                        ev.set()
                    elif self.on_command:
                        self.on_command(name, text)
                    return True
            return False
        if self.muted:
            return False
        name = self.command_for(text) if allow else None
        if name and (not check_threshold or conf >= self.threshold):
            log("[ses] komut %s: %r guven %.2f (%s)" % (name, text, conf, self.mode))
            if self.on_command:
                self.on_command(name, text)
            return True
        if allow and occurrences(text, self.trigger) > 0 and (not check_threshold or conf >= self.threshold):
            log("[ses] tetik: %r guven %.2f (%s)" % (text, conf, self.mode))
            if self.on_trigger:
                self.on_trigger(text)
            return True
        if allow and self.intent_hook is not None and (not check_threshold or conf >= self.threshold):
            try:
                if self.intent_hook(text):
                    log("[ses] anlam eslesti: %r (%s)" % (text, self.mode))
                    return True
            except Exception as e:      # yorumlayici hatasi dinlemeyi durdurmasin
                log("[ses] anlam eslestirme hatasi: %r" % (e,))
        return False

    def feed_text(self, text, confidence=1.0):
        """Tarayici motorundan gelen metin. Yalnizca tarayici modundayken kabul edilir."""
        if self.mode != "browser" or self._stop.is_set():
            return False
        return self._heard(str(text)[:300], 1.0 if not confidence else float(confidence))

    def set_browser_status(self, text):
        if self.mode == "browser":
            self._status(str(text)[:200])

    def _loop(self, stop, trigger, threshold, pref):
        reasons = []
        for name in ENGINE_ORDER.get(pref, ENGINE_ORDER["auto"]):
            if stop.is_set():
                return
            if name == "browser":
                self.mode = "browser"
                self.info = "tarayici (internet gerekir)"
                note = ""
                if reasons:
                    note = " [" + "; ".join(reasons) + "]"
                self._status("Tarayici sesi bekleniyor (bu sayfa acik kalmali, internet gerekir)" + note)
                log("[ses] tarayici motoru kullanilacak. " + "; ".join(reasons))
                stop.wait()
                return
            self.mode = name
            result = self._run_vosk(stop, trigger) if name == "vosk" else self._run_windows(stop, trigger, threshold)
            if result is None:
                return
            reasons.append("%s: %s" % (ENGINE_LABEL[name], result))
            log("[ses] %s kullanilamiyor: %s" % (name, result))
        self.mode = ""
        self._status("Sesli komut kullanilamiyor. " + "; ".join(reasons))

    # ---- Vosk (cevrimdisi, Turkce)
    def _run_vosk(self, stop, trigger):
        """None = durduruldu, metin = kullanilamaz nedeni"""
        try:
            import vosk
            import sounddevice as sd
        except Exception:
            return "ses paketleri (vosk, sounddevice) kurulu degil"
        if not model_ready(self.work_dir):
            return "Turkce ses modeli indirilmemis"
        try:
            try:
                vosk.SetLogLevel(-1)
            except Exception:
                pass
            self._status("Ses modeli yukleniyor...")
            model = vosk.Model(model_path(self.work_dir))
        except Exception as e:
            return "model yuklenemedi: %s" % e
        self.info = "cevrimdisi Turkce (Vosk)"
        self._model = model
        failures = 0
        while not stop.is_set():
            audio = queue.Queue(maxsize=100)

            def callback(indata, frames, time_info, status, audio=audio):
                try:
                    audio.put_nowait(bytes(indata))
                except queue.Full:
                    pass

            self._status("Mikrofon aciliyor...")
            started = time.time()
            try:
                rec = vosk.KaldiRecognizer(model, 16000)
                with open_input(sd, self.mic_name, callback, 16000, 4000) as mic:
                    self.mic_used = mic.name
                    if mic.note:
                        log("[ses] " + mic.note)
                    self.ready = True
                    failures = 0
                    self._status("Dinleniyor: \u201c%s\u201d (cevrimdisi)" % trigger)
                    fired = False
                    while not stop.is_set():
                        try:
                            data = audio.get(timeout=0.5)
                        except queue.Empty:
                            continue
                        tap = self.tap
                        if tap is not None:
                            try:
                                tap(data)
                            except Exception:
                                pass
                        if rec.AcceptWaveform(data):
                            text = json.loads(rec.Result()).get("text", "")
                            if text:
                                self._heard(text, allow=not fired)
                            fired = False
                        else:
                            part = json.loads(rec.PartialResult()).get("partial", "")
                            if part and not fired and (occurrences(part, trigger) > 0 or self.command_for(part)):
                                fired = self._heard(part, final=False)
            except Exception as e:
                failures += 1
                self.ready = False
                msg = str(e).strip().replace("\n", " ")[:360]
                log("[ses] mikrofon/tanima hatasi: %s" % msg)
                self._status("Mikrofon acilamadi: %s - yeniden denenecek" % msg)
                if stop.wait(min(5 * failures, 30)):
                    return None
                continue
            finally:
                self.ready = False
                self.mic_used = ""
            if stop.is_set():
                return None
            if time.time() - started < 5:
                failures += 1
            if stop.wait(2):
                return None
        return None

    # ---- Windows (System.Speech)
    def _command(self, trigger, threshold):
        override = os.environ.get("SK_VOICE_CMD")
        if override:  # sinama icin: ayni satir protokolunu veren baska bir komut
            return override.split("|")
        if os.name != "nt":
            return None
        os.makedirs(self.work_dir, exist_ok=True)
        path = os.path.join(self.work_dir, "ses.ps1")
        with open(path, "w", encoding="utf-8-sig") as f:
            f.write(PS_SCRIPT)
        spoken = []
        for p in patterns(trigger):
            spoken.append(" ".join(p))
        for trig in self.commands.values():
            for p in patterns(trig):
                spoken.append(" ".join(p))
        b64 = base64.b64encode("|".join(dict.fromkeys(spoken)).encode("utf-8")).decode("ascii")
        return ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                "-File", path, "-WordsB64", b64, "-Threshold", str(threshold)]

    def _run_windows(self, stop, trigger, threshold):
        """None = durduruldu, metin = kullanilamaz nedeni"""
        failures = 0
        while not stop.is_set():
            cmd = self._command(trigger, threshold)
            if cmd is None:
                return "yalnizca Windows'ta calisir"
            self._status("Mikrofon aciliyor...")
            started = time.time()
            kwargs = {}
            if os.name == "nt":
                kwargs["creationflags"] = 0x08000000
            try:
                proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                        stdin=subprocess.DEVNULL, **kwargs)
            except OSError as e:
                return "baslatilamadi: %s" % e
            with self._lock:
                self._proc = proc
            error = ""
            saw_ready = False
            try:
                for raw in iter(proc.stdout.readline, b""):
                    if stop.is_set():
                        break
                    line = raw.decode("utf-8", "replace").strip("\r\n\ufeff ")
                    if not line:
                        continue
                    if line == "READY":
                        saw_ready = True
                        self.ready = True
                        failures = 0
                        self._status("Dinleniyor: \u201c%s\u201d" % trigger)
                    elif line == "TICK":
                        continue
                    elif line.startswith("INFO|"):
                        parts = line.split("|")
                        self.info = "Windows %s, dikte %s" % (parts[1], parts[3] if len(parts) > 3 else "?")
                        log("[ses] tanima motoru: " + " | ".join(parts[1:]))
                        if len(parts) > 4 and parts[4].strip().lower() == "true":
                            log("[ses] UYARI: Turkce tanima motoru kurulu degil, baska dil kullaniliyor")
                    elif line.startswith("ERROR|"):
                        error = line[6:]
                        log("[ses] hata: " + error)
                    elif line.startswith("HEARD|"):
                        parts = line.split("|")
                        text = parts[1] if len(parts) > 1 else ""
                        try:
                            conf = float(parts[2].replace(",", ".")) if len(parts) > 2 else 1.0
                        except ValueError:
                            conf = 1.0
                        self._heard(text, conf, check_threshold=True)
            finally:
                self.ready = False
                try:
                    proc.kill()
                except OSError:
                    pass
                with self._lock:
                    self._proc = None
            if stop.is_set():
                return None
            code = proc.poll()
            if not saw_ready and (code == 2 or "kurulu degil" in error):
                return error or "motor kurulu degil"
            failures += 1
            self._status(("Ses hatasi: " + error) if error else "Ses motoru kapandi, yeniden baslatiliyor...")
            lived = time.time() - started
            if stop.wait(3 if lived > 20 else min(5 * failures, 30)):
                return None
        return None
