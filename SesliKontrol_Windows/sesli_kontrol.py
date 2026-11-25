# -*- coding: utf-8 -*-
"""Sesli Kontrol - Windows sürümü. iPhone programının son sürümünün (885ddbc) Windows karşılığıdır; kendi penceresinde açılır."""
import argparse
import json
import os
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

PORT = 8536


def diagnose():
    import platform
    import shutil
    print("=== SESLI KONTROL TANILAMA ===")
    print("Python:", sys.version.split()[0], platform.platform())
    for mod in ("av", "numpy", "PIL", "cv2", "webview", "vosk", "sounddevice"):
        try:
            m = __import__(mod)
            print("  %-11s kurulu (%s)" % (mod, getattr(m, "__version__", "?")))
        except Exception as e:
            print("  %-11s YOK (%s)" % (mod, e))
    print("  ffmpeg:", shutil.which("ffmpeg") or "yok (PyAV varsa gerekmez)")
    from sk.settings import Settings, data_dir
    from sk.voice import model_ready
    print("  Turkce ses modeli:", "kurulu" if model_ready(data_dir()) else "YOK")
    from sk.ui import find_browser
    print("  Edge/Chrome:", find_browser() or "bulunamadi")
    from sk.webcam import list_cameras
    cams, err, names = list_cameras()
    print("Bilgisayar kameralari:", ", ".join(c["label"] for c in cams) if cams else "bulunamadi")
    if names:
        print("  Windows'un bildirdigi kamera adlari:", ", ".join(names))
    if err and not cams:
        print("  ", err)
    from sk.camera import discover_network
    targets, nets, locs, gws = discover_network(None)
    print("Ag: bu bilgisayar", locs, "| gecit", gws, "| aranacak", targets)
    print("Gemini modelleri:")
    from sk import answers, gemini
    settings = Settings(data_dir())
    chain = answers.profiles(settings)
    if not chain:
        print("  API anahtari girilmemis (Ayarlar > Gemini).")
    for p in chain:
        ok, message = gemini.test_key(p["model"], p["key"])
        print("  %d. %s: %s" % (p["slot"], p["name"], ("TAMAM" if ok else "HATA: " + message)))
    return 0


def install_voice_cli():
    from sk.settings import data_dir
    from sk.voice import install_offline_voice, model_ready, vosk_importable
    d = data_dir()
    if vosk_importable() and model_ready(d):
        print("Cevrimdisi Turkce ses zaten kurulu.")
        return 0
    print("Cevrimdisi Turkce ses kuruluyor (vosk + ~35 MB model)...")
    err = install_offline_voice(d, lambda t: print("  " + t, end="\r", flush=True))
    print()
    if err:
        print("Kurulamadi: " + err)
        print("(Program yine de calisir; sesli komut icin Windows motoru denenir, dugmeler her zaman calisir.)")
        return 1
    print("Tamam: cevrimdisi Turkce ses kuruldu.")
    return 0


def setup_cli(args):
    from sk import installer
    try:
        if args.kur:
            return installer.install(HERE)
        policy = "sil" if args.veriyi_sil else ("koru" if args.veriyi_koru else None)

        def ask(text):
            if not sys.stdin or not sys.stdin.isatty():
                return False
            try:
                return input(text + " [e/H] ").strip().lower() in ("e", "evet", "y", "yes")
            except EOFError:
                return False

        return installer.uninstall(ask=ask, data_policy=policy)
    except RuntimeError as e:
        print(str(e))
        return 1


def main(argv=None):
    for stream in (sys.stdout, sys.stderr):     # siyah pencere her harfi gösteremese de yazdırma hatası programı durdurmasın
        try:
            stream.reconfigure(errors="replace")
        except Exception:
            pass
    ap = argparse.ArgumentParser(description="Sesli Kontrol (Windows)")
    ap.add_argument("--port", type=int, default=PORT)
    ap.add_argument("--no-browser", action="store_true", help="arayuzu otomatik acma")
    ap.add_argument("--ui", choices=["auto", "window", "browser"], default="auto")
    ap.add_argument("--home", help="ayar klasoru (varsayilan %%APPDATA%%\\SesliKontrol)")
    ap.add_argument("--tani", action="store_true", help="kurulum, kamera, ag ve Gemini tanilama raporu")
    ap.add_argument("--ses-kur", action="store_true", help="cevrimdisi Turkce ses tanimayi kur (internet gerekir)")
    ap.add_argument("--kur", action="store_true", help="programi bilgisayara kur (kisayol + Uygulamalar listesi)")
    ap.add_argument("--kaldir", action="store_true", help="kurulu programi kaldir")
    ap.add_argument("--veriyi-sil", action="store_true")
    ap.add_argument("--veriyi-koru", action="store_true")
    ap.add_argument("--sure", type=float, default=0.0, help="(sinama) bu kadar saniye calisip kapan")
    args = ap.parse_args(argv)
    if args.home:
        os.environ["SK_HOME"] = args.home
    if args.kur or args.kaldir:
        return setup_cli(args)
    if args.tani:
        return diagnose()
    if args.ses_kur:
        return install_voice_cli()
    if sys.version_info < (3, 9):
        print("Bu program Python 3.9 veya daha yenisini ister.")
        return 1

    from sk import VERSION
    from sk.settings import data_dir
    from sk.webui import load_key, start_server
    from sk.app import App

    directory = data_dir()
    key = load_key(directory)
    url = "http://127.0.0.1:%d/?k=%s" % (args.port, key)
    try:        # program zaten açıksa yeni kopya açma, yalnız pencereyi göster
        with urllib.request.urlopen("http://127.0.0.1:%d/api/ping" % args.port, timeout=1.5) as r:
            if json.loads(r.read().decode()).get("app") == "seslikontrol":
                print("Sesli Kontrol zaten calisiyor, pencere aciliyor...")
                if not args.no_browser:
                    from sk import ui
                    ui.show(url, directory, args.ui)
                return 0
    except Exception:
        pass

    print("=" * 60)
    print("  SESLI KONTROL  (Windows surumu %s)" % VERSION)
    print("=" * 60)
    app = App(directory)
    server = start_server(app, key, args.port)
    url = "http://127.0.0.1:%d/?k=%s" % (server.port, key)
    app.start()
    print()
    print("  Program acildi; kendi penceresinde gorunecek.")
    print("  (Gorunmezse su adresi tarayiciya yapistirabilirsiniz:)")
    print("  " + url)
    print()
    print("  * Bu siyah pencereyi KAPATMAYIN; program burada calisir.")
    print("  * Programi kapatmak icin program penceresini kapatmaniz yeterli.")
    print("=" * 60)
    try:
        if args.sure > 0:
            time.sleep(args.sure)
            return 0
        if not args.no_browser:
            from sk import ui
            if ui.show(url, directory, args.ui):
                print("\nPencere kapatildi, program kapaniyor...")
                return 0
        while True:
            time.sleep(1.0)
    except KeyboardInterrupt:
        print("\nKapatiliyor...")
    finally:
        app.stop()
        server.shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())
