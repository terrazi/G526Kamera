# -*- coding: utf-8 -*-
"""Kurulum ve kaldirma. Yonetici izni gerekmez; her sey kullanici hesabina kurulur.

Kurulum:   %LOCALAPPDATA%\\Programs\\Sesli Kontrol   (program dosyalari)
           Masaustu ve Baslat menusu kisayollari
           Windows "Uygulamalar ve ozellikler" listesine kayit (HKCU\\...\\Uninstall\\SesliKontrol)
Kaldirma:  kisayollar, kayit ve program klasoru silinir. Ayarlar/API anahtarlari/ses modeli (%APPDATA%\\SesliKontrol)
           icin sorulur; kayit klasoru (Belgelerim\\Sesli Kontrol) hicbir zaman silinmez.

Windows'a ozgu islemler `Backend` siniflarinda toplanmistir; testlerde sahte arka uc kullanilir
(SK_FAKE_BACKEND=<klasor>).
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time

APP_NAME = "Sesli Kontrol"
UNINSTALL_KEY = r"Software\Microsoft\Windows\CurrentVersion\Uninstall\SesliKontrol"
MARKER = "kurulum.json"
PROGRAM_FILES = ["sesli_kontrol.py", "SESLI_KONTROL_BASLAT.bat", "SESLI_KONTROL_TANI.bat", "SESLI_KONTROL_KALDIR.bat",
                 "KULLANIM.txt", "requirements.txt"]
REQUIRED = ["sesli_kontrol.py", "SESLI_KONTROL_BASLAT.bat", "SESLI_KONTROL_KALDIR.bat"]
CREATE_NO_WINDOW = 0x08000000


def default_install_dir():
    env = os.environ.get("SK_INSTALL_DIR")
    if env:
        return os.path.abspath(env)
    base = os.environ.get("LOCALAPPDATA") or os.path.join(os.path.expanduser("~"), ".local", "share")
    return os.path.join(base, "Programs", APP_NAME)


# ----------------------------------------------------------------- Arka uclar
class WindowsBackend:
    """Gercek Windows: kayit defteri (winreg), kisayol (WScript.Shell), bilinen klasorler (SHGetKnownFolderPath)."""

    FOLDERS = {"Desktop": "B4BFCC3A-DB2C-424C-B029-7FE99A87C641",
               "Programs": "A77F5D77-2E2B-44C3-A6A2-ABA601054A51"}

    def special_folder(self, name):
        try:
            import ctypes
            import uuid
            from ctypes import wintypes

            class GUID(ctypes.Structure):
                _fields_ = [("Data1", wintypes.DWORD), ("Data2", wintypes.WORD),
                            ("Data3", wintypes.WORD), ("Data4", ctypes.c_ubyte * 8)]

            u = uuid.UUID(self.FOLDERS[name])
            guid = GUID(u.time_low, u.time_mid, u.time_hi_version, (ctypes.c_ubyte * 8)(*u.bytes[8:]))
            ptr = ctypes.c_wchar_p()
            hr = ctypes.windll.shell32.SHGetKnownFolderPath(ctypes.byref(guid), 0, None, ctypes.byref(ptr))
            if hr == 0 and ptr.value:
                path = ptr.value
                ctypes.windll.ole32.CoTaskMemFree(ptr)
                return path
        except Exception:
            pass
        if name == "Desktop":
            return os.path.join(os.path.expanduser("~"), "Desktop")
        return os.path.join(os.environ.get("APPDATA", os.path.expanduser("~")),
                            "Microsoft", "Windows", "Start Menu", "Programs")

    def create_shortcut(self, lnk, target, workdir, icon, description, minimized=False):
        os.makedirs(os.path.dirname(lnk), exist_ok=True)
        script = ("$s=(New-Object -ComObject WScript.Shell).CreateShortcut($env:SK_LNK);"
                  "$s.TargetPath=$env:SK_TARGET;$s.WorkingDirectory=$env:SK_WORKDIR;"
                  "if($env:SK_ICON){$s.IconLocation=$env:SK_ICON};$s.Description=$env:SK_DESC;"
                  "$s.WindowStyle=[int]$env:SK_STYLE;$s.Save()")
        env = dict(os.environ, SK_LNK=lnk, SK_TARGET=target, SK_WORKDIR=workdir,
                   SK_ICON=icon or "", SK_DESC=description, SK_STYLE="7" if minimized else "1")
        out = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script],
                             env=env, capture_output=True, creationflags=CREATE_NO_WINDOW, timeout=60)
        if out.returncode != 0 or not os.path.exists(lnk):
            raise OSError("Kisayol olusturulamadi: " + out.stderr.decode("utf-8", "replace").strip()[:200])

    def write_uninstall(self, strings, dwords):
        import winreg
        with winreg.CreateKeyEx(winreg.HKEY_CURRENT_USER, UNINSTALL_KEY, 0, winreg.KEY_WRITE) as key:
            for k, v in strings.items():
                winreg.SetValueEx(key, k, 0, winreg.REG_SZ, v)
            for k, v in dwords.items():
                winreg.SetValueEx(key, k, 0, winreg.REG_DWORD, int(v))

    def read_uninstall(self):
        import winreg
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, UNINSTALL_KEY) as key:
                out, i = {}, 0
                while True:
                    try:
                        name, value, _t = winreg.EnumValue(key, i)
                    except OSError:
                        break
                    out[name] = value
                    i += 1
                return out
        except OSError:
            return None

    def delete_uninstall(self):
        import winreg
        try:
            winreg.DeleteKey(winreg.HKEY_CURRENT_USER, UNINSTALL_KEY)
        except OSError:
            pass

    def stop_running(self, patterns, exclude_pid):
        """Komut satirinda `patterns` gecen (program ve penceresi) surecleri kapatir; kendimizi kapatmaz."""
        script = ("$me=[int]$env:SK_PID;$pats=@($env:SK_PATS -split '\\|' | Where-Object { $_ });"
                  "foreach($p in (Get-CimInstance Win32_Process)){"
                  "if($p.ProcessId -eq $me -or -not $p.CommandLine){continue};"
                  "if($p.CommandLine -like '*--kaldir*' -or $p.CommandLine -like '*--kur*'){continue};"
                  "foreach($pat in $pats){if($p.CommandLine.Contains($pat)){"
                  "Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue;break}}}")
        env = dict(os.environ, SK_PID=str(exclude_pid), SK_PATS="|".join(patterns))
        try:
            subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script],
                           env=env, capture_output=True, creationflags=CREATE_NO_WINDOW, timeout=60)
        except Exception:
            pass

    def launch(self, path):
        os.startfile(path)   # noqa: S606 (yalnizca Windows)

    def deferred_delete(self, directory):
        """Surec kapandiktan sonra klasoru silecek ayri bir komut baslatir."""
        cmd = 'ping -n 4 127.0.0.1 >nul & rmdir /s /q "%s"' % directory
        subprocess.Popen(["cmd", "/c", cmd], creationflags=CREATE_NO_WINDOW, close_fds=True)


class FakeBackend:
    """Test icin: kayit defteri bir JSON dosyasi, kisayollar kucuk dosyalar, klasorler alt klasorler."""

    def __init__(self, root):
        self.root = root
        os.makedirs(root, exist_ok=True)
        self.registry_path = os.path.join(root, "registry.json")
        self.log_path = os.path.join(root, "olaylar.txt")

    def _log(self, text):
        with open(self.log_path, "a", encoding="utf-8") as f:
            f.write(text + "\n")

    def special_folder(self, name):
        d = os.path.join(self.root, name)
        os.makedirs(d, exist_ok=True)
        return d

    def create_shortcut(self, lnk, target, workdir, icon, description, minimized=False):
        os.makedirs(os.path.dirname(lnk), exist_ok=True)
        with open(lnk, "w", encoding="utf-8") as f:
            json.dump({"target": target, "workdir": workdir, "icon": icon, "description": description,
                       "minimized": minimized}, f)

    def _reg(self):
        try:
            with open(self.registry_path, encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError):
            return None

    def write_uninstall(self, strings, dwords):
        data = dict(strings)
        data.update(dwords)
        with open(self.registry_path, "w", encoding="utf-8") as f:
            json.dump(data, f)

    def read_uninstall(self):
        return self._reg()

    def delete_uninstall(self):
        try:
            os.remove(self.registry_path)
        except OSError:
            pass

    def stop_running(self, patterns, exclude_pid):
        self._log("stop " + "|".join(patterns))

    def launch(self, path):
        self._log("launch " + path)

    def deferred_delete(self, directory):
        self._log("deferred_delete " + directory)


def get_backend():
    fake = os.environ.get("SK_FAKE_BACKEND")
    if fake:
        return FakeBackend(fake)
    if os.name == "nt":
        return WindowsBackend()
    raise RuntimeError("Kurulum yalnizca Windows'ta calisir.")


# ----------------------------------------------------------------- Yardimcilar
def _dir_size_kb(path):
    total = 0
    for base, _dirs, files in os.walk(path):
        for f in files:
            try:
                total += os.path.getsize(os.path.join(base, f))
            except OSError:
                pass
    return max(1, total // 1024)


def make_icon(path):
    """Basit bir belge+kamera simgesi cizer (Pillow varsa). Basarisizsa False."""
    try:
        from PIL import Image, ImageDraw
    except Exception:
        return False
    try:
        size = 256
        img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        d.rounded_rectangle((8, 8, size - 8, size - 8), radius=48, fill=(31, 78, 140, 255))
        d.rounded_rectangle((64, 36, 192, 176), radius=10, fill=(255, 255, 255, 255))
        for i, y in enumerate((62, 86, 110, 134)):
            d.rounded_rectangle((82, y, 174 - (24 if i == 3 else 0), y + 8), radius=4, fill=(150, 170, 200, 255))
        d.ellipse((112, 160, 200, 248), fill=(240, 244, 250, 255), outline=(31, 78, 140, 255), width=6)
        d.ellipse((134, 182, 178, 226), fill=(31, 78, 140, 255))
        d.ellipse((148, 192, 158, 202), fill=(255, 255, 255, 255))
        img.save(path, format="ICO", sizes=[(256, 256), (128, 128), (64, 64), (48, 48), (32, 32), (16, 16)])
        return os.path.exists(path)
    except Exception:
        return False


def _copy_program(src, dst, say):
    os.makedirs(dst, exist_ok=True)
    for name in PROGRAM_FILES:
        s = os.path.join(src, name)
        if not os.path.exists(s):
            if name in REQUIRED:
                raise OSError("Kurulum dosyasi eksik: %s" % name)
            continue
        shutil.copy2(s, os.path.join(dst, name))
    pkg_src, pkg_dst = os.path.join(src, "sk"), os.path.join(dst, "sk")
    if not os.path.isdir(pkg_src):
        raise OSError("Kurulum klasoru eksik: sk")
    if os.path.isdir(pkg_dst):
        shutil.rmtree(pkg_dst, ignore_errors=True)    # eski surumden kalan dosyalar kalmasin
    shutil.copytree(pkg_src, pkg_dst, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"), dirs_exist_ok=True)


def _shortcut_paths(backend):
    desktop = os.path.join(backend.special_folder("Desktop"), APP_NAME + ".lnk")
    menu_dir = os.path.join(backend.special_folder("Programs"), APP_NAME)
    return desktop, menu_dir, os.path.join(menu_dir, APP_NAME + ".lnk"), os.path.join(menu_dir, APP_NAME + " Kaldir.lnk")


def _patterns():
    from sk.settings import data_dir
    return ["sesli_kontrol.py", os.path.join(data_dir(), "pencere")]


# ----------------------------------------------------------------- Kurulum
def install(src, dst=None, backend=None, say=print, launch=True):
    """Programi `src` klasorunden `dst` klasorune kurar. Donus: 0 basarili."""
    backend = backend or get_backend()
    dst = os.path.abspath(dst or default_install_dir())
    src = os.path.abspath(src)
    same = os.path.exists(dst) and os.path.exists(src) and os.path.samefile(src, dst)
    from sk import VERSION

    say("%s %s kuruluyor..." % (APP_NAME, VERSION))
    say("  Klasor: " + dst)
    backend.stop_running(_patterns(), os.getpid())
    if not same:
        try:
            _copy_program(src, dst, say)
        except OSError as e:
            say("[!] Dosyalar kopyalanamadi: %s" % e)
            return 1
    icon = os.path.join(dst, "seslikontrol.ico")
    if not make_icon(icon):
        icon = ""

    with open(os.path.join(dst, MARKER), "w", encoding="utf-8") as f:
        json.dump({"app": "seslikontrol", "version": VERSION, "installed": time.strftime("%Y-%m-%d %H:%M:%S"),
                   "source": src}, f)

    launcher = os.path.join(dst, "SESLI_KONTROL_BASLAT.bat")
    remover = os.path.join(dst, "SESLI_KONTROL_KALDIR.bat")
    desktop, menu_dir, menu_lnk, menu_rm = _shortcut_paths(backend)
    try:
        backend.create_shortcut(desktop, launcher, dst, icon, APP_NAME, minimized=True)
        backend.create_shortcut(menu_lnk, launcher, dst, icon, APP_NAME, minimized=True)
        backend.create_shortcut(menu_rm, remover, dst, icon, APP_NAME + " programini kaldir")
        say("  Kisayollar: Masaustu ve Baslat menusu")
    except OSError as e:
        say("[!] %s" % e)
        say("    (Program yine de kuruldu; %s dosyasini elle calistirabilirsiniz)" % launcher)

    strings = {"DisplayName": APP_NAME, "DisplayVersion": VERSION, "Publisher": "Sesli Kontrol",
               "InstallLocation": dst, "UninstallString": '"%s"' % remover,
               "InstallDate": time.strftime("%Y%m%d")}
    if icon:
        strings["DisplayIcon"] = icon
    try:
        backend.write_uninstall(strings, {"NoModify": 1, "NoRepair": 1, "EstimatedSize": _dir_size_kb(dst)})
        say("  Kayit: Ayarlar > Uygulamalar listesinde \"%s\"" % APP_NAME)
    except OSError as e:
        say("[!] Uygulamalar listesine eklenemedi: %s" % e)

    say("")
    say("Kurulum tamam. Kaldirmak icin: Windows Ayarlar > Uygulamalar > \"%s\" > Kaldir" % APP_NAME)
    say("(ya da Baslat menusunden \"%s Kaldir\")" % APP_NAME)
    if launch:
        try:
            backend.launch(desktop if os.path.exists(desktop) else launcher)
            say("Program aciliyor...")
        except OSError as e:
            say("[!] Program baslatilamadi: %s" % e)
    return 0


# ----------------------------------------------------------------- Kaldirma
def find_install_dir(backend):
    hint = os.environ.get("SK_KURULU_KLASOR", "").rstrip("\\/")
    if hint and os.path.exists(os.path.join(hint, MARKER)):
        return os.path.abspath(hint)
    info = backend.read_uninstall()
    if info and info.get("InstallLocation"):
        return os.path.abspath(info["InstallLocation"])
    return default_install_dir()


def _safe_to_delete(path):
    """Yanlis bir klasoru silmemek icin: kurulum izi olmali, kok/ev/belgeler gibi klasorler olmamali."""
    path = os.path.abspath(path)
    if not os.path.isfile(os.path.join(path, MARKER)):
        return False
    home = os.path.abspath(os.path.expanduser("~"))
    if path == home or os.path.dirname(path) == path:
        return False
    return len(path.replace("\\", "/").strip("/").split("/")) >= 3


def uninstall(backend=None, say=print, ask=None, data_policy=None):
    """Kaldirir. data_policy: 'sil' | 'koru' | None (None: ask(metin)->bool ile sorulur, ask yoksa korunur)."""
    backend = backend or get_backend()
    # Klasor silinirken iceri aktarma yapmamak icin gerekenleri bastan yukle
    from sk.settings import data_dir, default_local_dir

    dst = find_install_dir(backend)
    registered = backend.read_uninstall() is not None
    if not os.path.isdir(dst) and not registered:
        say("%s kurulu gorunmuyor." % APP_NAME)
        return 0

    say("%s kaldiriliyor..." % APP_NAME)
    data = data_dir()
    backend.stop_running(["sesli_kontrol.py", os.path.join(data, "pencere")], os.getpid())

    # 1) kisayollar
    desktop, menu_dir, _a, _b = _shortcut_paths(backend)
    try:
        if os.path.exists(desktop):
            os.remove(desktop)
    except OSError:
        pass
    shutil.rmtree(menu_dir, ignore_errors=True)
    say("  Kisayollar silindi")

    # 2) ayarlar ve veriler: sor
    if os.path.isdir(data):
        if data_policy is None:
            text = "Ayarlar, API anahtarlari ve ses modeli (%s) de silinsin mi?" % data
            data_policy = "sil" if (ask and ask(text)) else "koru"
        if data_policy == "sil":
            shutil.rmtree(data, ignore_errors=True)
            say("  Ayarlar ve veriler silindi")
        else:
            say("  Ayarlar korundu: %s" % data)

    # 3) Uygulamalar listesi kaydi
    backend.delete_uninstall()
    say("  Uygulamalar listesinden kaldirildi")

    # 4) program klasoru
    if os.path.isdir(dst):
        if _safe_to_delete(dst):
            try:
                os.chdir(tempfile.gettempdir())      # calisma klasoru kilitlemesin
            except OSError:
                pass
            for _ in range(4):
                shutil.rmtree(dst, ignore_errors=True)
                if not os.path.exists(dst):
                    break
                time.sleep(0.6)
            if os.path.exists(dst):
                backend.deferred_delete(dst)
                say("  Program klasoru kapanista silinecek")
            else:
                say("  Program klasoru silindi")
        else:
            say("  [!] Program klasorunde kurulum izi yok, guvenlik icin silinmedi: %s" % dst)
    say("")
    say("Kaldirma tamam.")
    local = default_local_dir()
    if os.path.isdir(local):
        say("Kayit klasoru (taramalar, cevaplar, kaynaklar) silinmedi: %s" % local)
    return 0
