<#
.SYNOPSIS
    Diagnose the Codex x DeepSeek Responses fix proxy setup.

.DESCRIPTION
    Checks configuration, credentials, proxy process, ports, the exact
    base_url-vs-listen-port mismatch that breaks the chain, upstream
    reachability, Codex process start times, auto-start entries and recent
    proxy log status codes. Writes the full report to diagnose-report.txt.

    Two free network probes are included: a TCP connect to the upstream and a
    raw HTTP GET through the proxy to an unknown path. Any HTTP status returned
    by that GET proves the proxy can reach DeepSeek; no API tokens are spent.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = "$env:USERPROFILE\.codex\config.toml"
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$proxyScript = Join-Path $root 'deepseek_responses_fix_proxy.py'
$proxyConfigPath = Join-Path $root 'deepseek.config.psd1'
$logPath = Join-Path $root 'proxy.log'
$reportPath = Join-Path $root 'diagnose-report.txt'
$taskName = 'Codex DeepSeek Fix Proxy'
$startupShortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'DeepSeek Responses Fix Proxy.lnk'

$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param(
        [ValidateSet('OK', 'WARN', 'FAIL', 'INFO')][string]$Level,
        [string]$Title,
        [string]$Detail = '',
        [string]$Fix = ''
    )
    $results.Add([pscustomobject]@{ Level = $Level; Title = $Title; Detail = $Detail; Fix = $Fix })
}

function Test-TcpPort {
    param([string]$TargetHost, [int]$TargetPort, [int]$TimeoutMs = 3000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($TargetHost, $TargetPort, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($async)
        return $true
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Invoke-RawHttpGet {
    param(
        [string]$TargetHost,
        [int]$TargetPort,
        [string]$Path = '/',
        [string]$AuthorizationHeader = '',
        [int]$TimeoutMs = 4000
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($TargetHost, $TargetPort, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $null }
        $client.EndConnect($async)
        $stream = $client.GetStream()
        $stream.ReadTimeout = $TimeoutMs
        $stream.WriteTimeout = $TimeoutMs
        $request = "GET $Path HTTP/1.1`r`nHost: $TargetHost`r`nConnection: close`r`n"
        if ($AuthorizationHeader) { $request += "Authorization: $AuthorizationHeader`r`n" }
        $request += "`r`n"
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($request)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        $reader = New-Object System.IO.StreamReader($stream)
        $statusLine = $reader.ReadLine()
        # Drain the rest of the response so we do not abort the proxy mid-stream.
        while ($null -ne $reader.ReadLine()) { }
        return $statusLine
    }
    catch {
        return $null
    }
    finally {
        $client.Dispose()
    }
}

function Read-ProxyConfig {
    $cfg = @{}
    if (Test-Path -LiteralPath $proxyConfigPath) {
        if (Get-Command Import-PowerShellDataFile -ErrorAction SilentlyContinue) {
            $cfg = Import-PowerShellDataFile -LiteralPath $proxyConfigPath
        }
        else {
            $cfg = . $proxyConfigPath
        }
    }
    return $cfg
}

Write-Host ''
Write-Host '=== Codex x DeepSeek Responses fix proxy - diagnose ===' -ForegroundColor Cyan
Write-Host "time   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "repo   : $root"
Write-Host "config : $ConfigPath"
Write-Host ''

$proxyCfg = Read-ProxyConfig
$proxyListen = if ($proxyCfg.Listen) { $proxyCfg.Listen } else { '127.0.0.1:18787' }
$proxyUpstream = if ($proxyCfg.Upstream) { $proxyCfg.Upstream } else { 'https://api.deepseek.com' }
$proxyParts = $proxyListen.Split(':', 2)
$proxyHost = $proxyParts[0]
$proxyPort = if ($proxyParts.Count -eq 2) { [int]$proxyParts[1] } else { 0 }

# --- 1. Codex config -------------------------------------------------------
$baseUrl = ''
$wireApi = ''
$hasToken = $false
$envKeyName = ''
$envKeyPresent = $false
$credential = ''
if (Test-Path -LiteralPath $ConfigPath) {
    $cfgText = Get-Content -LiteralPath $ConfigPath -Raw
    $blockMatch = [regex]::Match($cfgText, '(?s)\[model_providers\.deepseek\](.*?)(?=\r?\n\[|\z)')
    if ($blockMatch.Success) {
        $block = $blockMatch.Groups[1].Value
        $baseUrl = [regex]::Match($block, '(?m)^\s*base_url\s*=\s*"([^"]+)"').Groups[1].Value
        $wireApi = [regex]::Match($block, '(?m)^\s*wire_api\s*=\s*"([^"]+)"').Groups[1].Value
        $hasToken = [regex]::IsMatch($block, '(?m)^\s*experimental_bearer_token\s*=\s*"')
        $envKeyName = [regex]::Match($block, '(?m)^\s*env_key\s*=\s*"([^"]+)"').Groups[1].Value
        if ($envKeyName) {
            $envKeyPresent = [bool][Environment]::GetEnvironmentVariable($envKeyName)
        }
        if ($hasToken) {
            $credential = [regex]::Match($block, '(?m)^\s*experimental_bearer_token\s*=\s*"([^"]+)"').Groups[1].Value
        }
        elseif ($envKeyName -and $envKeyPresent) {
            $credential = [Environment]::GetEnvironmentVariable($envKeyName)
        }
        Add-Result OK 'deepseek provider block found' "wire_api=$wireApi base_url=$baseUrl"
    }
    else {
        Add-Result FAIL 'no [model_providers.deepseek] block in config.toml' $ConfigPath 'Add the provider block or check CODEX_HOME.'
    }
}
else {
    Add-Result FAIL 'config.toml not found' $ConfigPath 'Check the path or CODEX_HOME.'
}

if ($hasToken) {
    Add-Result OK 'bearer token present in config.toml' 'experimental_bearer_token is set (value not shown)'
}
elseif ($envKeyName -and $envKeyPresent) {
    Add-Result OK "env_key credential present" "env_key=$envKeyName and the variable is set"
}
elseif ($envKeyName) {
    Add-Result FAIL "env_key=$envKeyName is configured but the variable is empty" '' "setx $envKeyName `"sk-...`" then restart Codex"
}
else {
    Add-Result FAIL 'no DeepSeek credential configured' 'neither experimental_bearer_token nor env_key' 'Add experimental_bearer_token or env_key to the deepseek provider block.'
}

# --- 2. base_url vs proxy listen port -------------------------------------
$configHost = ''
$configPort = 0
if ($baseUrl) {
    try {
        $uri = [System.Uri]$baseUrl
        $configHost = $uri.Host
        $configPort = if ($uri.Port -gt 0) { $uri.Port } else { 443 }
    }
    catch { }
}
$usingProxy = $configHost -in @('127.0.0.1', 'localhost', '::1')

if ($usingProxy) {
    if ($configPort -eq $proxyPort) {
        Add-Result OK 'config points at the proxy port' "$baseUrl matches Listen=$proxyListen"
    }
    else {
        Add-Result FAIL 'base_url port does not match the proxy listen port' "config=$configPort proxy=$proxyPort" "Change base_url to http://${proxyHost}:${proxyPort}/ and restart Codex."
    }
}
else {
    Add-Result INFO 'proxy is not in the request path (direct upstream)' "base_url=$baseUrl" 'Normal chats work, but side-thread/cross-thread call_id injections can still wedge a thread.'
}

# --- 3. proxy process and port --------------------------------------------
$proxyProcesses = @(Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like "*$proxyScript*" })
if ($proxyProcesses.Count -gt 0) {
    $descriptions = foreach ($process in $proxyProcesses) {
        $start = ''
        try { $start = (Get-Process -Id $process.ProcessId -ErrorAction Stop).StartTime.ToString('yyyy-MM-dd HH:mm:ss') } catch { }
        "PID $($process.ProcessId) $($process.Name) started=$start"
    }
    Add-Result OK "proxy process running ($($proxyProcesses.Count))" ($descriptions -join '; ')
}
else {
    if ($usingProxy) {
        Add-Result FAIL 'no proxy process running' "expected script: $proxyScript" 'Double-click start-proxy.cmd or restart-service.cmd.'
    }
    else {
        Add-Result INFO 'no proxy process running (not needed in direct mode)' "expected script: $proxyScript" 'Only start the proxy after pointing base_url at it.'
    }
}

$portListening = Test-TcpPort -TargetHost $proxyHost -TargetPort $proxyPort
if ($portListening) {
    $owner = ''
    if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        $listener = Get-NetTCPConnection -LocalPort $proxyPort -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($listener) { $owner = " owner PID $($listener.OwningProcess)" }
    }
    Add-Result OK "proxy port $proxyPort is listening" $owner.Trim()
}
else {
    if ($usingProxy) {
        Add-Result FAIL "proxy port $proxyPort is not listening" '' 'Double-click start-proxy.cmd or restart-service.cmd.'
    }
    else {
        Add-Result INFO "proxy port $proxyPort is not listening (not needed in direct mode)" '' 'Only start the proxy after pointing base_url at it.'
    }
}

# --- 4. network probes -----------------------------------------------------
$upstreamHost = 'api.deepseek.com'
$upstreamPort = 443
try {
    $u = [System.Uri]$proxyUpstream
    $upstreamHost = $u.Host
    $upstreamPort = if ($u.Port -gt 0) { $u.Port } else { 443 }
}
catch { }
if (Test-TcpPort -TargetHost $upstreamHost -TargetPort $upstreamPort) {
    Add-Result OK "upstream reachable" "$upstreamHost`:$upstreamPort"
}
else {
    Add-Result WARN "upstream not reachable" "$upstreamHost`:$upstreamPort" 'Check network, DNS, VPN or proxy settings.'
}

if ($portListening) {
    $authHeader = if ($credential) { "Bearer $credential" } else { '' }
    $statusLine = Invoke-RawHttpGet -TargetHost $proxyHost -TargetPort $proxyPort -Path '/__diagnose__' -AuthorizationHeader $authHeader
    if ($statusLine) {
        if ($credential -and $statusLine -match '\s401\s') {
            Add-Result FAIL 'upstream rejected the configured credential' $statusLine 'The proxy and network are fine; fix experimental_bearer_token / env_key and restart Codex.'
        }
        elseif ($credential) {
            Add-Result OK 'proxy -> upstream chain responded with credentials' $statusLine 'Auth accepted; the full Codex request path is ready.'
        }
        else {
            Add-Result OK 'proxy -> upstream chain responded (unauthenticated probe)' $statusLine 'No credential found, so a 401 here is expected.'
        }
    }
    else {
        Add-Result FAIL 'proxy did not answer the HTTP probe' '' 'The port is open but no HTTP response came back; check proxy.log.'
    }
}

# --- 5. Codex processes vs config timestamp --------------------------------
$configWrite = if (Test-Path -LiteralPath $ConfigPath) { (Get-Item -LiteralPath $ConfigPath).LastWriteTime } else { $null }
$codexProcesses = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(ChatGPT|codex)$' } |
    Sort-Object StartTime)
if ($codexProcesses.Count -gt 0) {
    $newest = $codexProcesses | Sort-Object StartTime -Descending | Select-Object -First 1
    $summary = "newest: $($newest.ProcessName) PID $($newest.Id) started $($newest.StartTime.ToString('yyyy-MM-dd HH:mm:ss'))"
    Add-Result OK "Codex processes running ($($codexProcesses.Count))" $summary
    if ($configWrite -and $newest.StartTime -lt $configWrite) {
        Add-Result WARN 'Codex started before the last config.toml change' "codex=$($newest.StartTime.ToString('HH:mm:ss')) config=$($configWrite.ToString('HH:mm:ss'))" 'Fully quit Codex (tray included) and start it again so the new base_url is read.'
    }
}
else {
    Add-Result WARN 'no Codex process found' '' 'Start Codex after the proxy is up.'
}

# --- 6. auto-start state ---------------------------------------------------
$legacyTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($legacyTask) {
    Add-Result WARN 'self-healing watchdog task is installed' $taskName 'You said you do not want it: double-click uninstall-autostart.cmd.'
}
else {
    Add-Result OK 'no self-healing watchdog task' 'none installed'
}
if (Test-Path -LiteralPath $startupShortcut) {
    Add-Result INFO 'logon auto-start shortcut installed' $startupShortcut 'Starts once at sign-in; no watchdog.'
}
else {
    Add-Result INFO 'no logon auto-start shortcut' 'start the proxy manually with start-proxy.cmd'
}

# --- 7. recent log status codes -------------------------------------------
if (Test-Path -LiteralPath $logPath) {
    $logLines = Get-Content -LiteralPath $logPath -Tail 500 -Encoding UTF8 -ErrorAction SilentlyContinue
    $statuses = @{}
    $cutoff = (Get-Date).AddMinutes(-30)
    foreach ($line in $logLines) {
        $stamp = [regex]::Match($line, '\[(\d{2}/[A-Za-z]{3}/\d{4} \d{2}:\d{2}:\d{2})\]')
        if (-not $stamp.Success) { continue }
        try {
            $when = [datetime]::ParseExact(
                $stamp.Groups[1].Value,
                'dd/MMM/yyyy HH:mm:ss',
                [System.Globalization.CultureInfo]::InvariantCulture
            )
        }
        catch { continue }
        if ($when -lt $cutoff) { continue }
        if ($line -match '->\s+(\d{3})\s') {
            $code = $Matches[1]
            $statuses[$code] = 1 + ($statuses[$code] -as [int])
        }
    }
    if ($statuses.Count -gt 0) {
        $summary = ($statuses.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Key) x$($_.Value)" }) -join ', '
        Add-Result INFO 'proxy response codes in the last 30 minutes' $summary
        if ($usingProxy) {
            if ($statuses.ContainsKey('401')) { Add-Result WARN 'requests were rejected with 401' 'upstream says the credential is missing or invalid' 'Check experimental_bearer_token / env_key and restart Codex.' }
            if ($statuses.ContainsKey('422')) { Add-Result WARN 'requests were rejected with 422' 'upstream schema rejection' 'Check that the proxy is actually in the path and up to date.' }
        }
    }
    else {
        Add-Result INFO 'no proxy traffic in the last 30 minutes' '' 'Codex has not sent a request through the proxy recently.'
    }
    $tail = $logLines | Select-Object -Last 6
    Add-Result INFO 'proxy.log tail' (($tail -join ' | '))
}
else {
    Add-Result INFO 'proxy.log not found' $logPath
}

# --- report ----------------------------------------------------------------
$failCount = @($results | Where-Object Level -eq 'FAIL').Count
$warnCount = @($results | Where-Object Level -eq 'WARN').Count
$okCount = @($results | Where-Object Level -eq 'OK').Count

foreach ($result in $results) {
    $color = switch ($result.Level) {
        'OK' { 'Green' }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red' }
        default { 'Gray' }
    }
    Write-Host ("[{0,-4}] {1}" -f $result.Level, $result.Title) -ForegroundColor $color
    if ($result.Detail) { Write-Host "       $($result.Detail)" -ForegroundColor DarkGray }
    if ($result.Fix) { Write-Host "       fix: $($result.Fix)" -ForegroundColor DarkYellow }
}

Write-Host ''
Write-Host ("=== summary: OK {0}  WARN {1}  FAIL {2} ===" -f $okCount, $warnCount, $failCount) -ForegroundColor $(if ($failCount) { 'Red' } elseif ($warnCount) { 'Yellow' } else { 'Green' })

$report = New-Object System.Collections.Generic.List[string]
$report.Add("Codex x DeepSeek Responses fix proxy - diagnose report")
$report.Add("time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$report.Add("repo: $root")
$report.Add("config: $ConfigPath")
$report.Add("base_url: $baseUrl  wire_api: $wireApi  proxy_listen: $proxyListen  upstream: $proxyUpstream")
$report.Add('')
foreach ($result in $results) {
    $report.Add(("[{0}] {1}" -f $result.Level, $result.Title))
    if ($result.Detail) { $report.Add("    $($result.Detail)") }
    if ($result.Fix) { $report.Add("    fix: $($result.Fix)") }
}
$report.Add('')
$report.Add("summary: OK $okCount  WARN $warnCount  FAIL $failCount")
Set-Content -LiteralPath $reportPath -Value $report -Encoding UTF8

Write-Host "report written to: $reportPath" -ForegroundColor Cyan
if ($failCount -gt 0) { exit 1 }
exit 0
