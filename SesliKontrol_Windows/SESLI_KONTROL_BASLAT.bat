@echo off
setlocal EnableExtensions
chcp 65001 >nul 2>&1
set "PYTHONUTF8=1"
set "PYTHONIOENCODING=utf-8"
cd /d "%~dp0"
title Sesli Kontrol

echo ============================================================
echo   SESLI KONTROL - Windows surumu
echo ============================================================
echo.

if not exist "sesli_kontrol.py" goto :dosya_yok

call :bul_python
if defined PYEXE goto :paketler

echo Bu bilgisayarda uygun bir Python yok. Otomatik kurulacak.
echo Bunun icin bilgisayarin INTERNETE bagli olmasi gerekir.
echo.
call :internet_var https://www.python.org
if errorlevel 1 goto :internet_yok
call :kur_python
call :bul_python
if not defined PYEXE goto :kurulamadi
echo.
echo Python kuruldu.

:paketler
"%PYEXE%" -c "import av, numpy, PIL" >nul 2>&1
if not errorlevel 1 goto :opencv
echo.
echo Gerekli paketler kuruluyor (goruntu cozucu, resim kutuphanesi)...
call :internet_var https://pypi.org
if errorlevel 1 goto :internet_yok
"%PYEXE%" -m ensurepip --upgrade >nul 2>&1
"%PYEXE%" -m pip install --user --disable-pip-version-check --no-input av numpy pillow
"%PYEXE%" -c "import av, numpy, PIL" >nul 2>&1
if errorlevel 1 goto :paket_hata

:opencv
"%PYEXE%" -c "import cv2" >nul 2>&1
if not errorlevel 1 goto :pywebview
call :internet_var https://pypi.org
if errorlevel 1 goto :pywebview
echo.
echo USB ve dizustu kamerasi icin OpenCV kuruluyor (yaklasik 50 MB)...
"%PYEXE%" -m pip install --user --disable-pip-version-check --no-input opencv-python-headless

:pywebview
"%PYEXE%" -c "import webview" >nul 2>&1
if not errorlevel 1 goto :ses
if exist "%APPDATA%\SesliKontrol\pywebview.denendi" goto :ses
call :internet_var https://pypi.org
if errorlevel 1 goto :ses
echo.
echo Program penceresi icin pywebview kuruluyor (istege bagli)...
"%PYEXE%" -m pip install --user --disable-pip-version-check --no-input pywebview
"%PYEXE%" -c "import webview" >nul 2>&1
if not errorlevel 1 goto :ses
if not exist "%APPDATA%\SesliKontrol" mkdir "%APPDATA%\SesliKontrol" >nul 2>&1
echo denendi> "%APPDATA%\SesliKontrol\pywebview.denendi"
echo (pywebview kurulamadi; program Edge/Chrome uygulama penceresinde acilacak)

:ses
"%PYEXE%" -c "import sys; from sk.voice import vosk_importable, model_ready; from sk.settings import data_dir; sys.exit(0 if (vosk_importable() and model_ready(data_dir())) else 1)" >nul 2>&1
if not errorlevel 1 goto :kurulum_sec
call :internet_var https://pypi.org
if errorlevel 1 goto :kurulum_sec
echo.
echo Cevrimdisi Turkce ses tanima kuruluyor (istege bagli, yaklasik 50 MB)...
"%PYEXE%" sesli_kontrol.py --ses-kur

:kurulum_sec
if /i not "%~1"=="--kur" goto :calistir
echo.
"%PYEXE%" sesli_kontrol.py --kur
echo.
pause
exit /b 0

:calistir
echo.
echo ------------------------------------------------------------
echo  Wi-Fi kamerayi kullanmak icin bilgisayar KAMERANIN Wi-Fi
echo  agina bagli olmalidir. USB / dizustu kamerasi ve PDF ile
echo  soru gonderme icin buna gerek yoktur.
echo  Guvenlik Duvari penceresi cikarsa "Erisime izin ver" deyin
echo  (Ozel ve Genel kutularini isaretleyin).
echo ------------------------------------------------------------
echo.
"%PYEXE%" sesli_kontrol.py %*
echo.
echo Program kapandi.
pause
exit /b 0

:dosya_yok
echo [!] sesli_kontrol.py dosyasi bu klasorde yok.
echo     ZIP dosyasina sag tiklayip "Tumunu ayikla" deyin,
echo     sonra acilan klasorun icinden bu dosyayi calistirin.
echo.
pause
exit /b 1

:internet_yok
echo.
echo [!] Internet baglantisi yok. Ilk kurulum icin internet gerekir.
echo     1. Bilgisayari internetli bir aga baglayin.
echo     2. Bu dosyaya tekrar cift tiklayin. Kurulum bir kez yapilir.
echo     3. Sonra bilgisayari kameranin Wi-Fi agina baglayabilirsiniz;
echo        Gemini'ye gonderim icin ayrica internet gerekir (kablo ya da telefondan USB ile).
echo.
pause
exit /b 1

:kurulamadi
echo.
echo [!] Python otomatik kurulamadi.
echo     Elle kurun: https://www.python.org/downloads/windows/
echo     Kurulumda "Add python.exe to PATH" kutusunu isaretleyin,
echo     sonra bu dosyaya tekrar cift tiklayin.
echo.
pause
exit /b 1

:paket_hata
echo.
echo [!] Gerekli paketler kurulamadi (av, numpy, pillow).
echo     Yukaridaki hata satirlarini bana gonderin.
echo.
pause
exit /b 1

rem ---------------------------------------------------------------
:internet_var
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ProgressPreference = 'SilentlyContinue'; try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -Uri '%~1' -Method Head -TimeoutSec 10 | Out-Null; exit 0 } catch { exit 1 }"
exit /b %errorlevel%

rem ---------------------------------------------------------------
:kur_python
set "INST=%TEMP%\python-3.12.8-amd64.exe"
if exist "%INST%" del "%INST%" >nul 2>&1
echo Python indiriliyor, yaklasik 27 MB. Lutfen bekleyin...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ProgressPreference = 'SilentlyContinue'; try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -Uri 'https://www.python.org/ftp/python/3.12.8/python-3.12.8-amd64.exe' -OutFile '%INST%'; exit 0 } catch { exit 1 }"
if not exist "%INST%" exit /b 1
echo Python kuruluyor. Yonetici izni gerekmez, 1-2 dakika surebilir...
"%INST%" /quiet InstallAllUsers=0 PrependPath=1 Include_launcher=1 Include_test=0 Include_doc=0 Include_tcltk=0 Include_pip=1 Shortcuts=0
del "%INST%" >nul 2>&1
exit /b 0

rem ---------------------------------------------------------------
:bul_python
set "PYEXE="
where py >nul 2>&1
if errorlevel 1 goto :bp_python
for %%V in (3.12 3.11 3.13 3.10) do call :bp_try_py %%V
if defined PYEXE exit /b 0
:bp_python
where python >nul 2>&1
if errorlevel 1 goto :bp_dirs
python -c "import sys;sys.exit(0 if sys.version_info>=(3,9) else 1)" >nul 2>&1
if errorlevel 1 goto :bp_dirs
for /f "usebackq delims=" %%P in (`python -c "import sys;print(sys.executable)" 2^>nul`) do set "PYEXE=%%P"
if defined PYEXE if exist "%PYEXE%" exit /b 0
set "PYEXE="
:bp_dirs
for /d %%D in ("%LOCALAPPDATA%\Programs\Python\Python3*" "%ProgramFiles%\Python3*") do call :bp_try_dir "%%~D"
exit /b 0

:bp_try_py
if defined PYEXE exit /b 0
for /f "usebackq delims=" %%P in (`py -%1 -c "import sys;print(sys.executable)" 2^>nul`) do set "PYEXE=%%P"
if defined PYEXE if not exist "%PYEXE%" set "PYEXE="
exit /b 0

:bp_try_dir
if defined PYEXE exit /b 0
if exist "%~1\python.exe" (
  "%~1\python.exe" -c "import sys;sys.exit(0 if sys.version_info>=(3,9) else 1)" >nul 2>&1
  if not errorlevel 1 set "PYEXE=%~1\python.exe"
)
exit /b 0
