@echo off
chcp 65001 >nul
title DeepSeek Responses Fix Proxy - Restart Service
rem Keep Windows PowerShell 5.1 away from a PS7-inherited PSModulePath.
set "PSModulePath="
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\restart-service.ps1" %*
echo.
pause
