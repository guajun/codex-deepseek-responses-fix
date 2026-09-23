@echo off
chcp 65001 >nul
title Codex DeepSeek Fix Proxy - Diagnose
rem Keep Windows PowerShell 5.1 away from a PS7-inherited PSModulePath.
set "PSModulePath="
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\diagnose.ps1" %*
echo.
pause
