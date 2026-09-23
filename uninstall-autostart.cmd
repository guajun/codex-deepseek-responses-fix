@echo off
chcp 65001 >nul
title DeepSeek Responses Fix Proxy - Uninstall Auto Start
rem Keep Windows PowerShell 5.1 away from a PS7-inherited PSModulePath.
set "PSModulePath="
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\uninstall-autostart.ps1" %*
echo.
pause
