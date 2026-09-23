<#
.SYNOPSIS
    Install a plain logon auto-start shortcut for the fix proxy (no watchdog).

.DESCRIPTION
    Creates a per-user Startup-folder shortcut that launches the proxy with
    pythonw.exe when you sign in. It does NOT keep watching or restarting the
    proxy: if the proxy dies during a session, double-click restart-service.cmd
    or start-proxy.cmd. No administrator rights are required.

    Any legacy "Codex DeepSeek Fix Proxy" scheduled task from the earlier
    watchdog version is removed automatically.

.PARAMETER NoStart
    Only create the shortcut; do not start the proxy immediately.
#>
[CmdletBinding()]
param(
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$taskName = 'Codex DeepSeek Fix Proxy'
$configPath = Join-Path $root 'deepseek.config.psd1'
$proxy = Join-Path $root 'deepseek_responses_fix_proxy.py'
if (-not (Test-Path -LiteralPath $proxy)) { throw "Proxy script not found: $proxy" }

$cfg = @{}
if (Test-Path -LiteralPath $configPath) {
    if (Get-Command Import-PowerShellDataFile -ErrorAction SilentlyContinue) {
        $cfg = Import-PowerShellDataFile -LiteralPath $configPath
    }
    else {
        $cfg = . $configPath
    }
}
$upstream = if ($cfg.Upstream) { $cfg.Upstream } else { 'https://api.deepseek.com' }
$listen = if ($cfg.Listen) { $cfg.Listen } else { '127.0.0.1:18787' }
$role = if ($cfg.Role) { $cfg.Role } else { 'user' }
$verbose = if ($null -ne $cfg.Verbose) { [bool]$cfg.Verbose } else { $true }
$logFile = if ($cfg.LogFile) { $cfg.LogFile } else { Join-Path $root 'proxy.log' }

$python = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $python) { throw 'python was not found on PATH. Install Python 3.11+ first.' }
$pythonw = Join-Path (Split-Path -Parent $python) 'pythonw.exe'
if (-not (Test-Path -LiteralPath $pythonw)) { $pythonw = $python }

# Remove the legacy watchdog scheduled task if it is still registered.
$legacyTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($legacyTask) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "Removed legacy watchdog task: $taskName"
}

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
$shortcut.Description = 'DeepSeek Responses fix proxy for Codex (logon only, no watchdog)'
$shortcut.Save()

Write-Host 'Logon auto-start installed (no watchdog).' -ForegroundColor Green
Write-Host "  shortcut : $shortcutPath"
Write-Host "  pythonw  : $pythonw"
Write-Host "  upstream : $upstream"
Write-Host "  listen   : $listen"
Write-Host "  role     : $role"
Write-Host "  log      : $logFile"
Write-Host ''
Write-Host 'This shortcut runs once at sign-in only. If the proxy dies mid-session,'
Write-Host 'double-click restart-service.cmd (or start-proxy.cmd) to bring it back.'

if (-not $NoStart) {
    Start-Process -FilePath $pythonw -ArgumentList $argumentLine -WorkingDirectory $root -WindowStyle Hidden
    Write-Host 'Proxy started in the background now.' -ForegroundColor Green
}

Write-Host ''
Write-Host 'Codex config.toml should contain:'
Write-Host "  base_url = `"http://$listen/`""
