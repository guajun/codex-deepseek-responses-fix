<#
.SYNOPSIS
    Restart the DeepSeek Responses fix proxy (stop + start in background).

.DESCRIPTION
    Reads deepseek.config.psd1 from the repository root, stops every
    python/pythonw process whose command line points at this repository's proxy
    script, then launches a fresh hidden instance with pythonw.exe and verifies
    that the listen port is accepting connections.

    Useful after editing deepseek.config.psd1, changing DEEPSEEK_API_KEY, or
    when you just want a clean process.

.PARAMETER NoStart
    Only stop the running instance; do not start a new one.
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
$listen = if ($cfg.Listen) { $cfg.Listen } else { '127.0.0.1:18787' }
$role = if ($cfg.Role) { $cfg.Role } else { 'user' }
$verbose = if ($null -ne $cfg.Verbose) { [bool]$cfg.Verbose } else { $true }
$logFile = if ($cfg.LogFile) { $cfg.LogFile } else { Join-Path $root 'proxy.log' }
$proxy = Join-Path $root 'deepseek_responses_fix_proxy.py'
if (-not (Test-Path -LiteralPath $proxy)) { throw "Proxy script not found: $proxy" }

$parts = $listen.Split(':', 2)
if ($parts.Count -ne 2 -or -not $parts[1]) { throw "Invalid Listen value: $listen" }
$listenHost = $parts[0]
$listenPort = [int]$parts[1]

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

function Get-ProxyProcesses {
    $filter = "Name='python.exe' OR Name='pythonw.exe'"
    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
        $all = Get-CimInstance Win32_Process -Filter $filter -ErrorAction SilentlyContinue
    }
    elseif (Get-Command Get-WmiObject -ErrorAction SilentlyContinue) {
        $all = Get-WmiObject Win32_Process -Filter $filter -ErrorAction SilentlyContinue
    }
    else {
        $all = @()
    }
    $all | Where-Object { $_.CommandLine -and $_.CommandLine -like "*$proxy*" }
}

Write-Host 'DeepSeek Responses fix proxy - restart' -ForegroundColor Cyan
Write-Host "  upstream : $upstream"
Write-Host "  listen   : $listen"
Write-Host "  role     : $role"
Write-Host "  log      : $logFile"
Write-Host ''

$running = @(Get-ProxyProcesses)
if ($running.Count -gt 0) {
    Write-Host "Stopping $($running.Count) running proxy process(es)..."
    foreach ($process in $running) {
        try {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
            Write-Host "  stopped PID $($process.ProcessId)"
        }
        catch {
            Write-Warning "  could not stop PID $($process.ProcessId): $($_.Exception.Message)"
        }
    }
}
else {
    Write-Host 'No running proxy process found.'
}

for ($i = 0; $i -lt 25; $i++) {
    if (-not (Test-ListenPort -TargetHost $listenHost -TargetPort $listenPort)) { break }
    Start-Sleep -Milliseconds 200
}

if (Test-ListenPort -TargetHost $listenHost -TargetPort $listenPort) {
    $ownerText = ''
    if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        $listener = Get-NetTCPConnection -LocalPort $listenPort -State Listen -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($listener) { $ownerText = " (held by PID $($listener.OwningProcess))" }
    }
    Write-Warning "Port $listenPort is still in use$ownerText. Stop that process or change Listen."
}

if ($NoStart) {
    Write-Host ''
    Write-Host 'NoStart set: stopped only, no new instance was launched.' -ForegroundColor Yellow
    exit 0
}

$python = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $python) { throw 'python was not found on PATH. Install Python 3.11+ first.' }
$pythonw = Join-Path (Split-Path -Parent $python) 'pythonw.exe'
if (-not (Test-Path -LiteralPath $pythonw)) { $pythonw = $python }

$arguments = @($proxy, '--listen', $listen, '--upstream', $upstream, '--role', $role, '--log-file', $logFile)
if ($verbose) { $arguments += '--verbose' }
$argumentLine = ($arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '

Start-Process -FilePath $pythonw -ArgumentList $argumentLine -WorkingDirectory $root -WindowStyle Hidden

$started = $false
for ($i = 0; $i -lt 15; $i++) {
    if (Test-ListenPort -TargetHost $listenHost -TargetPort $listenPort) { $started = $true; break }
    Start-Sleep -Milliseconds 300
}

Write-Host ''
if ($started) {
    Write-Host "Restarted: proxy is listening on $listen" -ForegroundColor Green
}
else {
    Write-Warning "Proxy was launched but $listen is not accepting connections yet. Check $logFile"
}

Write-Host ''
Write-Host 'Last log lines:'
if (Test-Path -LiteralPath $logFile) {
    Get-Content -LiteralPath $logFile -Tail 4 | ForEach-Object { "  $_" }
}
else {
    Write-Host '  (no log yet)'
}
