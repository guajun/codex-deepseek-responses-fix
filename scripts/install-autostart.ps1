<#
.SYNOPSIS
    Install a per-user auto-start entry for the DeepSeek fix proxy.

.DESCRIPTION
    Creates a shortcut in the current user's Startup folder that launches the
    proxy with pythonw.exe (no console window) at logon. No administrator
    rights are required. The shortcut is rebuilt from deepseek.config.psd1.

.PARAMETER NoStart
    Only create the shortcut; do not start the proxy immediately.
#>
[CmdletBinding()]
param(
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $root 'deepseek.config.psd1'
$cfg = @{}
if (Test-Path -LiteralPath $configPath) {
    $cfg = Import-PowerShellDataFile -LiteralPath $configPath
}

$upstream = if ($cfg.Upstream) { $cfg.Upstream } else { 'https://api.deepseek.com' }
$listen = if ($cfg.Listen) { $cfg.Listen } else { '127.0.0.1:8787' }
$role = if ($cfg.Role) { $cfg.Role } else { 'user' }
$verbose = if ($null -ne $cfg.Verbose) { [bool]$cfg.Verbose } else { $true }
$logFile = if ($cfg.LogFile) { $cfg.LogFile } else { Join-Path $root 'proxy.log' }
$proxy = Join-Path $root 'deepseek_responses_fix_proxy.py'
if (-not (Test-Path -LiteralPath $proxy)) { throw "Proxy script not found: $proxy" }

$python = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $python) { throw 'python was not found on PATH. Install Python 3.11+ first.' }
$pythonw = Join-Path (Split-Path -Parent $python) 'pythonw.exe'
if (-not (Test-Path -LiteralPath $pythonw)) { $pythonw = $python }

$arguments = @($proxy, '--listen', $listen, '--upstream', $upstream, '--role', $role, '--log-file', $logFile)
if ($verbose) { $arguments += '--verbose' }
$argumentLine = ($arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '

$startupFolder = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startupFolder 'DeepSeek Responses Fix Proxy.lnk'

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $pythonw
$shortcut.Arguments = $argumentLine
$shortcut.WorkingDirectory = $root
$shortcut.WindowStyle = 7
$shortcut.Description = 'DeepSeek Responses fix proxy for Codex (missing call_id workaround)'
$shortcut.Save()

Write-Host 'Auto-start installed.' -ForegroundColor Green
Write-Host "  shortcut : $shortcutPath"
Write-Host "  pythonw  : $pythonw"
Write-Host "  upstream : $upstream"
Write-Host "  listen   : $listen"
Write-Host "  role     : $role"
Write-Host "  log      : $logFile"

if (-not $NoStart) {
    Start-Process -FilePath $pythonw -ArgumentList $argumentLine -WorkingDirectory $root -WindowStyle Hidden
    Write-Host 'Proxy started in the background now.' -ForegroundColor Green
}

Write-Host ''
Write-Host 'Codex config.toml should contain:'
Write-Host "  base_url = `"http://$listen/`""
