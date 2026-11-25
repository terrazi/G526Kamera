@echo off
setlocal EnableExtensions
cd /d "%~dp0"
title Sesli Kontrol - Kurulum
echo ============================================================
echo   SESLI KONTROL - KURULUM
echo ============================================================
echo Gerekli yazilimlar kontrol edilir (ilk seferde internet gerekir),
echo sonra program bilgisayariniza kurulur. Yonetici izni gerekmez.
echo.
call "%~dp0SESLI_KONTROL_BASLAT.bat" --kur
exit /b %errorlevel%
