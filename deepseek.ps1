<#
.SYNOPSIS
    Start the DeepSeek Responses fix proxy with one command.

.DESCRIPTION
    Reads deepseek.config.psd1 from this folder (Upstream / Listen / Role /
    Verbose / LogFile), then runs deepseek_responses_fix_proxy.py with the
    system Python. Command line switches override the config file.

.EXAMPLES
    .\deepseek.ps1
    .\deepseek.ps1 -Background
    .\deepseek.ps1 -Upstream https://api.deepseek.com -Listen 127.0.0.1:18787
    .\deepseek.ps1 -Role developer
#>
[CmdletBinding()]
param(
    [string]$Upstream,
    [string]$Listen,
    [ValidateSet('user', 'developer')][string]$Role,
    [string]$ConfigFile,
    [switch]$Background,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $ConfigFile) { $ConfigFile = Join-Path $root 'deepseek.config.psd1' }

$cfg = @{}
if (Test-Path -LiteralPath $ConfigFile) {
    $cfg = Import-PowerShellDataFile -LiteralPath $ConfigFile
}

$upstream = if ($Upstream) { $Upstream } elseif ($cfg.Upstream) { $cfg.Upstream } else { 'https://api.deepseek.com' }
$listen = if ($Listen) { $Listen } elseif ($cfg.Listen) { $cfg.Listen } else { '127.0.0.1:18787' }
$role = if ($Role) { $Role } elseif ($cfg.Role) { $cfg.Role } else { 'user' }
$verbose = if ($Quiet) { $false } elseif ($null -ne $cfg.Verbose) { [bool]$cfg.Verbose } else { $true }
$logFile = if ($cfg.LogFile) { $cfg.LogFile } else { Join-Path $root 'proxy.log' }

$proxy = Join-Path $root 'deepseek_responses_fix_proxy.py'
if (-not (Test-Path -LiteralPath $proxy)) { throw "Proxy script not found: $proxy" }

$python = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $python) { throw 'python was not found on PATH. Install Python 3.11+ first.' }

$version = ((& $python -c "import sys; print('.'.join(map(str, sys.version_info[:3])))") | Select-Object -First 1).Trim()
$major, $minor = $version.Split('.')[0..1]
if ([int]$major -lt 3 -or ([int]$major -eq 3 -and [int]$minor -lt 11)) {
    throw "Python 3.11+ is required (found $version)."
}

$rawArguments = @($proxy, '--listen', $listen, '--upstream', $upstream, '--role', $role, '--log-file', $logFile)
if ($verbose) { $rawArguments += '--verbose' }
$argumentLine = ($rawArguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '

Write-Host 'DeepSeek Responses fix proxy' -ForegroundColor Cyan
Write-Host "  upstream : $upstream"
Write-Host "  listen   : http://$listen"
Write-Host "  role     : $role"
Write-Host "  log      : $logFile"
Write-Host "  config   : $ConfigFile"
Write-Host "  python   : $python ($version)"
Write-Host ''

if ($Background) {
    $pythonw = Join-Path (Split-Path -Parent $python) 'pythonw.exe'
    if (-not (Test-Path -LiteralPath $pythonw)) { $pythonw = $python }
    Start-Process -FilePath $pythonw -ArgumentList $argumentLine -WorkingDirectory $root -WindowStyle Hidden

    Start-Sleep -Milliseconds 900
    $parts = $listen.Split(':', 2)
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $client.Connect($parts[0], [int]$parts[1])
        $client.Close()
        Write-Host "Proxy started in the background and is listening on $listen" -ForegroundColor Green
    }
    catch {
        Write-Warning "Proxy was started but $listen is not accepting connections yet. Check $logFile"
    }
    Write-Host ''
    Write-Host 'Point Codex at it:'
    Write-Host "  base_url = `"http://$listen/`""
}
else {
    Write-Host 'Running in the foreground. Press Ctrl+C to stop.' -ForegroundColor DarkGray
    Write-Host ''
    & $python @rawArguments
}
