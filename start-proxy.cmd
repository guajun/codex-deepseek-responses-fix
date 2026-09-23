@echo off
chcp 65001 >nul
title DeepSeek Responses Fix Proxy
rem Keep Windows PowerShell 5.1 away from a PS7-inherited PSModulePath.
set "PSModulePath="
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deepseek.ps1"
echo.
pause
