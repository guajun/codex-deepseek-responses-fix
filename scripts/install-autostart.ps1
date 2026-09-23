<#
.SYNOPSIS
    Install a self-healing auto-start task for the DeepSeek fix proxy.

.DESCRIPTION
    Registers a per-user scheduled task that runs scripts\ensure-proxy.ps1:

      * at logon (with a 30 second delay), and
      * every 5 minutes, indefinitely.

    ensure-proxy.ps1 only starts the proxy when the listen port is down, so the
    task doubles as a watchdog: if the proxy crashes or is killed, it comes back
    within five minutes.

    The legacy per-user Startup-folder shortcut is removed automatically to
    avoid two competing launchers. No administrator rights are required.

.PARAMETER NoStart
    Only register the task; do not start the proxy immediately.
#>
[CmdletBinding()]
param(
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$taskName = 'Codex DeepSeek Fix Proxy'
$ensure = Join-Path $PSScriptRoot 'ensure-proxy.ps1'
$configPath = Join-Path $root 'deepseek.config.psd1'

if (-not (Test-Path -LiteralPath $ensure)) { throw "Missing helper: $ensure" }

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

# Remove the legacy Startup-folder shortcut: it only ran at logon and never
# recovered a crashed proxy.
$legacyShortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'DeepSeek Responses Fix Proxy.lnk'
if (Test-Path -LiteralPath $legacyShortcut) {
    Remove-Item -LiteralPath $legacyShortcut -Force
    Write-Host "Removed legacy Startup shortcut: $legacyShortcut"
}

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $ensure)

$logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
try { $logonTrigger.Delay = 'PT30S' } catch { }

$repeatTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 5)

$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($logonTrigger, $repeatTrigger) `
    -Settings $settings -Principal $principal -Force `
    -Description 'Watchdog for the DeepSeek Responses fix proxy (Codex missing call_id workaround).' | Out-Null

Write-Host 'Auto-start watchdog installed.' -ForegroundColor Green
Write-Host "  task     : $taskName"
Write-Host '  runs     : at logon (+30s) and every 5 minutes, self-healing'
Write-Host "  action   : $ensure"
Write-Host "  upstream : $upstream"
Write-Host "  listen   : $listen"
Write-Host "  role     : $role"

if (-not $NoStart) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ensure
    Write-Host 'Proxy ensured: it was started if the port was down.' -ForegroundColor Green
}

Write-Host ''
Write-Host 'Check watchdog.log for start/failure events, proxy.log for request traffic.'
