<#
.SYNOPSIS
    Remove the logon auto-start entry and stop running proxy instances.

.DESCRIPTION
    Removes the per-user Startup-folder shortcut, unregisters any legacy
    "Codex DeepSeek Fix Proxy" scheduled task, and stops python/pythonw
    processes whose command line points at this repository's proxy script.
    Other Python processes are never touched.
#>

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$taskName = 'Codex DeepSeek Fix Proxy'

$legacyTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($legacyTask) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "Removed legacy watchdog task: $taskName" -ForegroundColor Green
}

$shortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'DeepSeek Responses Fix Proxy.lnk'
if (Test-Path -LiteralPath $shortcutPath) {
    Remove-Item -LiteralPath $shortcutPath -Force
    Write-Host "Removed logon shortcut: $shortcutPath" -ForegroundColor Green
}
else {
    Write-Host 'No logon shortcut was installed.'
}

$proxy = Join-Path $root 'deepseek_responses_fix_proxy.py'
$stopped = 0
Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like "*$proxy*" } |
    ForEach-Object {
        try {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop
            $stopped++
        }
        catch {
            Write-Warning "Could not stop PID $($_.ProcessId): $($_.Exception.Message)"
        }
    }

if ($stopped -gt 0) {
    Write-Host "Stopped $stopped running proxy process(es)." -ForegroundColor Green
}
else {
    Write-Host 'No running proxy process was found.'
}

Write-Host ''
Write-Host 'Remember to point Codex base_url back to the direct upstream if you uninstall for good.'
