<#
.SYNOPSIS
    Start the DeepSeek Responses fix proxy only when it is not listening.

.DESCRIPTION
    Idempotent watchdog helper used by the scheduled task that
    install-autostart.cmd registers. It reads deepseek.config.psd1, checks the
    listen port, and launches a hidden pythonw instance only when nothing is
    listening. Safe to run every few minutes.

    Only start/failure events are written to watchdog.log, so the file stays
    small even when the task runs all day.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $root 'deepseek.config.psd1'
$stateLog = Join-Path $root 'watchdog.log'

function Write-State {
    param([string]$Message)
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $stateLog -Value $line -Encoding UTF8
}

function Test-ListenPort {
    param([string]$TargetHost, [int]$TargetPort)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $client.Connect($TargetHost, $TargetPort)
        return $true
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

try {
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
    $proxy = Join-Path $root 'deepseek_responses_fix_proxy.py'

    if (-not (Test-Path -LiteralPath $proxy)) { throw "proxy script not found: $proxy" }

    $parts = $listen.Split(':', 2)
    if ($parts.Count -ne 2 -or -not $parts[1]) { throw "invalid Listen value: $listen" }
    $listenHost = $parts[0]
    $listenPort = [int]$parts[1]

    if (Test-ListenPort -TargetHost $listenHost -TargetPort $listenPort) {
        exit 0
    }

    $python = (Get-Command python -ErrorAction SilentlyContinue).Source
    if (-not $python) { throw 'python not found on PATH' }
    $pythonw = Join-Path (Split-Path -Parent $python) 'pythonw.exe'
    if (-not (Test-Path -LiteralPath $pythonw)) { $pythonw = $python }

    $arguments = @($proxy, '--listen', $listen, '--upstream', $upstream, '--role', $role, '--log-file', $logFile)
    if ($verbose) { $arguments += '--verbose' }
    $argumentLine = ($arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '

    Start-Process -FilePath $pythonw -ArgumentList $argumentLine -WorkingDirectory $root -WindowStyle Hidden

    $started = $false
    for ($i = 0; $i -lt 15; $i++) {
        if (Test-ListenPort -TargetHost $listenHost -TargetPort $listenPort) {
            $started = $true
            break
        }
        Start-Sleep -Milliseconds 300
    }

    if ($started) {
        Write-State "started proxy on $listen"
    }
    else {
        Write-State "ERROR: proxy did not come up on $listen"
        exit 1
    }
}
catch {
    Write-State "ERROR: $($_.Exception.Message)"
    exit 1
}
