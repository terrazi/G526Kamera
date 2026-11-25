@echo off
setlocal EnableExtensions
chcp 65001 >nul 2>&1
set "PYTHONUTF8=1"
set "PYTHONIOENCODING=utf-8"

rem Bu dosya kurulum klasorunun icindedir. Klasor silinebilsin diye once TEMP'e kopyalanip oradan calistirilir.
if defined SK_KALDIR_KOPYA goto :kopya
set "SK_KALDIR_KOPYA=1"
set "SK_KURULU_KLASOR=%~dp0"
set "KOPYA=%TEMP%\sk_kaldir_%RANDOM%.bat"
copy /y "%~f0" "%KOPYA%" >nul
start "Sesli Kontrol - Kaldir" "%KOPYA%" %*
exit /b 0

:kopya
cd /d "%TEMP%"
title Sesli Kontrol - Kaldir
echo ============================================================
echo   SESLI KONTROL - KALDIRMA
echo ============================================================
echo.
set "KLASOR=%SK_KURULU_KLASOR%"
if defined KLASOR if "%KLASOR:~-1%"=="\" set "KLASOR=%KLASOR:~0,-1%"
if not defined KLASOR set "KLASOR=%LOCALAPPDATA%\Programs\Sesli Kontrol"

call :bul_python
if not defined PYEXE goto :python_yok
if not exist "%KLASOR%\sesli_kontrol.py" goto :python_yok
"%PYEXE%" "%KLASOR%\sesli_kontrol.py" --kaldir %*
goto :bitti

:python_yok
echo Python bulunamadi; temizlik dogrudan yapiliyor.
taskkill /f /fi "WINDOWTITLE eq Sesli Kontrol*" >nul 2>&1
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\SesliKontrol" /f >nul 2>&1
del /q "%USERPROFILE%\Desktop\Sesli Kontrol.lnk" >nul 2>&1
if defined OneDrive del /q "%OneDrive%\Desktop\Sesli Kontrol.lnk" >nul 2>&1
rmdir /s /q "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Sesli Kontrol" >nul 2>&1
rmdir /s /q "%KLASOR%" >nul 2>&1
echo Program silindi. Ayarlariniz %APPDATA%\SesliKontrol klasorunde duruyor;
echo istemezseniz o klasoru elle silebilirsiniz.

:bitti
echo.
pause
(goto) 2>nul & del "%~f0"

rem ---------------------------------------------------------------
:bul_python
set "PYEXE="
for /f "usebackq delims=" %%P in (`py -3 -c "import sys;print(sys.executable)" 2^>nul`) do set "PYEXE=%%P"
if defined PYEXE exit /b 0
for /f "usebackq delims=" %%P in (`python -c "import sys;print(sys.executable)" 2^>nul`) do set "PYEXE=%%P"
if defined PYEXE exit /b 0
for /d %%D in ("%LOCALAPPDATA%\Programs\Python\Python3*") do if exist "%%~D\python.exe" if not defined PYEXE set "PYEXE=%%~D\python.exe"
exit /b 0
