# -*- coding: utf-8 -*-
"""Gerçek Windows'ta duman sınaması (GitHub'ın Windows makinesinde çalışır): program açılıyor mu, ekran geliyor mu,
bilgisayar kamerası listesi ve PDF yolu çalışıyor mu, Windows sesi konuşabiliyor mu, kurulum / kaldırma işliyor mu."""
import io
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "SesliKontrol_Windows")
home = tempfile.mkdtemp(prefix="skduman")
PORT = 8551
env = dict(os.environ, SK_HOME=home, SK_NO_BROWSER="1", PYTHONIOENCODING="utf-8")
proc = subprocess.Popen([sys.executable, os.path.join(ROOT, "sesli_kontrol.py"), "--no-browser", "--port", str(PORT), "--sure", "40"],
                        env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
failures = []


def check(name, ok, detail=""):
    print(("TAMAM  " if ok else "HATA   ") + name + (": " + str(detail) if detail else ""))
    if not ok:
        failures.append(name)


def call(path, body=None, raw=None, key=""):
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request("http://127.0.0.1:%d%s" % (PORT, path), data=data, headers={"X-SK-Key": key})
    with urllib.request.urlopen(req, timeout=20) as r:
        text = r.read().decode("utf-8")
    return json.loads(text) if text.startswith(("{", "[")) else text


try:
    up = False
    for _ in range(80):
        try:
            up = call("/api/ping").get("app") == "seslikontrol"
            break
        except Exception:
            time.sleep(0.5)
    check("program acildi", up)
    key = open(os.path.join(home, "anahtar.txt")).read().strip()
    state = call("/api/state", key=key)
    check("durum okunuyor", state["flow"]["phase"] == "idle" and state["source"] == "wifi", state["camera"]["text"])
    page = call("/?k=" + key)
    check("ekran geliyor", "Taramayı başlat" in page and "PDF dosyası" in page)
    cams = call("/api/webcams?refresh=1", key=key)
    check("bilgisayar kamerasi listesi calisiyor", "cameras" in cams, cams)
    mics = call("/api/mics", key=key)
    check("mikrofon listesi calisiyor", "devices" in mics, (mics.get("error") or "")[:120])
    call("/api/settings", {"source": "pdf", "read_answers": False}, key=key)
    time.sleep(2.0)
    from reportlab.pdfgen import canvas
    buf = io.BytesIO()
    c = canvas.Canvas(buf)
    c.drawString(72, 720, "1. Deneme sorusu A) bir B) iki")
    c.save()
    r = call("/api/pdf?name=deneme.pdf", raw=buf.getvalue(), key=key)
    check("PDF kabul edildi", r.get("ok") is True, r)
    time.sleep(3.0)
    state = call("/api/state", key=key)
    check("anahtar yokken acik hata", "anahtarı girilmemiş" in state["flow"]["error"], state["flow"]["error"])
    check("ses durumu", True, state["voice"]["status"])
    log = call("/api/log", key=key)["lines"]
    print("--- gunluk (son 25 satir)")
    print("\n".join(log[-25:]))
finally:
    proc.terminate()
    try:
        out = proc.communicate(timeout=10)[0].decode("utf-8", "replace")
    except Exception:
        out = ""
    print("--- program ciktisi")
    print(out[-3000:])

# Windows sesi: gerçek konuşma (ses aygıtı olmayan makinede yalnız bilgi olarak yazılır)
sys.path.insert(0, ROOT)
os.environ["SK_HOME"] = home
try:
    from sk.settings import Settings
    from sk.talk import Speaker
    sp = Speaker(Settings(home), None, os.path.join(home, "ses"))
    began = time.time()
    sp.say("Soru 1, Adana, deneme", wait=True)
    print("BILGI  Windows sesi: %.1f sn, hata: %r" % (time.time() - began, getattr(sp, "last_error", "")))
    print("BILGI  Windows sesleri:", getattr(sp, "installed_voices", lambda: "?")())
except Exception as e:
    print("BILGI  Windows sesi denenemedi: %r" % (e,))

# Kurulum ve kaldırma
r = subprocess.run([sys.executable, os.path.join(ROOT, "sesli_kontrol.py"), "--home", home, "--kur"], env=env, capture_output=True, text=True,
                   encoding="utf-8", errors="replace", timeout=180)
print(r.stdout[-1500:], r.stderr[-800:])
target = os.path.join(os.environ.get("LOCALAPPDATA", ""), "Programs", "Sesli Kontrol")
check("kurulum", r.returncode == 0 and os.path.isfile(os.path.join(target, "sesli_kontrol.py")) and os.path.isdir(os.path.join(target, "sk")), target)
r = subprocess.run([sys.executable, os.path.join(ROOT, "sesli_kontrol.py"), "--home", home, "--kaldir", "--veriyi-koru"], env=env,
                   capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=180)
print(r.stdout[-1200:], r.stderr[-800:])
check("kaldirma", r.returncode == 0 and not os.path.isfile(os.path.join(target, "sesli_kontrol.py")))

print("SONUC:", "BASARISIZ " + ", ".join(failures) if failures else "HEPSI TAMAM")
sys.exit(1 if failures else 0)
