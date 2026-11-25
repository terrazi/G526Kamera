@echo off
setlocal EnableExtensions
chcp 65001 >nul 2>&1
set "PYTHONUTF8=1"
set "PYTHONIOENCODING=utf-8"
cd /d "%~dp0"
title Sesli Kontrol - Tanilama
set "PYEXE="
for %%V in (3.12 3.11 3.13 3.10) do if not defined PYEXE for /f "usebackq delims=" %%P in (`py -%%V -c "import sys;print(sys.executable)" 2^>nul`) do set "PYEXE=%%P"
if not defined PYEXE for /f "usebackq delims=" %%P in (`python -c "import sys;print(sys.executable)" 2^>nul`) do set "PYEXE=%%P"
if not defined PYEXE (
  echo Python bulunamadi. Once SESLI_KONTROL_BASLAT.bat dosyasini calistirin.
  pause
  exit /b 1
)
"%PYEXE%" sesli_kontrol.py --tani
echo.
echo Bu pencerenin tamamini secip kopyalayarak bana gonderebilirsiniz.
pause
