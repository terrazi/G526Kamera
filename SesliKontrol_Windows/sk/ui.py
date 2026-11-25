# -*- coding: utf-8 -*-
"""Arayuzu kendi penceresinde gosterir (tarayici sekmesi/adres cubugu olmadan).
Sira: pywebview (gomulu pencere) -> Edge/Chrome 'uygulama penceresi' -> varsayilan tarayici."""
import os
import subprocess
import threading
import time
import urllib.parse
import webbrowser

from .applog import log

EXTERNAL_HOSTS = {"google.com", "www.google.com", "drive.google.com", "accounts.google.com"}


def open_external(url):
    """Google giris / Drive baglantilarini varsayilan tarayicida acar (yalnizca izinli adresler)."""
    try:
        u = urllib.parse.urlparse(url)
    except ValueError:
        return False
    if u.scheme != "https" or (u.hostname or "") not in EXTERNAL_HOSTS:
        return False
    if os.environ.get("SK_NO_BROWSER"):
        log("[ui] acilacakti: " + url)
        return True
    try:
        webbrowser.open(url)
        return True
    except Exception:
        return False


def find_browser():
    override = os.environ.get("SK_BROWSER_EXE")
    if override:
        return override
    names = []
    for var in ("ProgramFiles(x86)", "ProgramFiles"):
        base = os.environ.get(var)
        if base:
            names.append(os.path.join(base, "Microsoft", "Edge", "Application", "msedge.exe"))
    for var in ("ProgramFiles", "ProgramFiles(x86)", "LOCALAPPDATA"):
        base = os.environ.get(var)
        if base:
            names.append(os.path.join(base, "Google", "Chrome", "Application", "chrome.exe"))
    for path in names:
        if os.path.isfile(path):
            return path
    return None


def show_pywebview(url, directory, title="Sesli Kontrol"):
    """Gomulu pencere. Pencere kapaninca doner. Donus: True = pencere acildi ve kapandi."""
    try:
        import webview
    except Exception as e:
        log("[ui] pywebview kurulu degil (%s)" % e)
        return False
    try:
        webview.create_window(title, url, width=1400, height=920, min_size=(960, 640))
        started = time.time()
        webview.start(gui="edgechromium", private_mode=True)
        if time.time() - started < 2.0:
            log("[ui] pencere hemen kapandi")
            return False
        return True
    except Exception as e:
        log("[ui] gomulu pencere acilamadi: %s" % e)
        return False


def show_app_window(url, directory, title="Sesli Kontrol"):
    """Edge/Chrome'u 'uygulama modu'nda acar (adres cubugu yok). Pencere kapaninca doner.
    Donus: "closed" | "detached" (pencere acildi ama kapanisi izlenemiyor) | None (acilamadi)"""
    exe = find_browser()
    if not exe:
        log("[ui] Edge/Chrome bulunamadi")
        return None
    profile = os.path.join(directory, "pencere")
    os.makedirs(profile, exist_ok=True)
    cmd = [exe, "--app=" + url, "--user-data-dir=" + profile, "--window-size=1400,920",
           "--no-first-run", "--no-default-browser-check", "--disable-features=Translate"]
    extra = os.environ.get("SK_BROWSER_ARGS")
    if extra:
        cmd += extra.split("|")
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError as e:
        log("[ui] uygulama penceresi acilamadi: %s" % e)
        return None
    started = time.time()
    proc.wait()
    # Cok kisa surede bittiyse baska bir tarayici surecine devredilmistir: kapanisi bilemeyiz
    return "closed" if time.time() - started > 8 else "detached"


def show(url, directory, mode="auto"):
    """Arayuzu gosterir. Pencere kapatilinca True doner (program kapanmali); False: konsolda beklenmeli."""
    if mode in ("auto", "window"):
        if show_pywebview(url, directory):
            return True
        result = show_app_window(url, directory)
        if result == "closed":
            return True
        if result == "detached":
            return False
        log("[ui] ozel pencere acilamadi, varsayilan tarayici kullaniliyor")
    try:
        webbrowser.open(url)
    except Exception:
        pass
    return False
