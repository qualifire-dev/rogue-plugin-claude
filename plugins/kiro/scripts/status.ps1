# Rogue Security status for the Kiro plugin (Windows / PowerShell).
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.rogue\plugins\kiro\scripts\status.ps1"
#
# Native-Windows analogue of status.sh: credential sources, the API key check,
# the installed surfaces and their Kiro builds, the hook wiring install.ps1
# -Kiro wrote, the 2.x engine's default agent, and the hook log.
#
# The credential, actor, version and Kiro-host helpers are heartbeat.ps1's own,
# loaded through its ROGUE_PS_LIB_ONLY seam (the one the test suites use) as a
# scriptblock built from the file's text - never a path dot-source, which is
# subject to ExecutionPolicy. The /hooks/status body is therefore the
# heartbeat's, and the row it upserts is the heartbeat's row: the backend
# fingerprints on host|actor|family|agent, so a second cascade here would
# register a second row for the install being checked.
#
# Exit 0 when configured and the API answered 200; 1 otherwise.
param()

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

$scriptsDir = Split-Path $PSCommandPath -Parent
$saveLibOnly = $env:ROGUE_PS_LIB_ONLY
$env:ROGUE_PS_LIB_ONLY = '1'
. ([scriptblock]::Create((Get-Content -Raw -LiteralPath (Join-Path $scriptsDir 'heartbeat.ps1'))))
$env:ROGUE_PS_LIB_ONLY = $saveLibOnly

$hooksDir = Join-Path (Join-Path $env:USERPROFILE '.kiro') 'hooks'
$configured = $false
$haveCli = $false
$httpCode = '000'

function Write-Row { param([string]$Label, [string]$Value) Write-Output ('  {0,-38} {1}' -f $Label, $Value) }
function Write-SurfaceRow { param([string]$Label, [string]$Value) Write-Output ('  {0,-12}{1}' -f $Label, $Value) }

# -- credentials ---------------------------------------------------------------
function Write-Credentials {
    Write-Output 'Credentials:'
    $bundled = Join-Path $script:pluginRoot 'env'
    if (Test-Path -LiteralPath $bundled) { Write-Output "  $bundled  (plugin bundle)" }
    if (Test-Path -LiteralPath 'C:\ProgramData\rogue\env') { Write-Output '  C:\ProgramData\rogue\env  (MDM)' }
    $perUser = Join-Path $env:USERPROFILE '.rogue-env'
    if (Test-Path -LiteralPath $perUser) { Write-Output "  $perUser  (per-user)" }
    if ($script:apiKey) {
        $script:configured = $true
        $tail = $script:apiKey.Substring([Math]::Max(0, $script:apiKey.Length - 4))
        Write-Output "  API key resolved: ...$tail"
    } else {
        Write-Output '  API key: not resolved - run install.ps1 -Kiro (managed users: contact your security admin)'
    }
}

# -- surfaces ------------------------------------------------------------------
function Get-KiroIdeRoot {
    if ($env:ROGUE_KIRO_APP) { return $env:ROGUE_KIRO_APP }
    if ($env:LOCALAPPDATA) { return (Join-Path $env:LOCALAPPDATA 'Programs\Kiro') }
    return ''
}

function Write-Surfaces {
    Write-Output 'Surfaces:'
    if (Get-Command kiro-cli -ErrorAction SilentlyContinue) {
        $script:haveCli = $true
        $v = Get-KiroCliVersion; if (-not $v) { $v = 'unknown' }
        Write-SurfaceRow 'kiro_cli' "kiro-cli $v"
    } else {
        Write-SurfaceRow 'kiro_cli' 'kiro-cli not found'
    }
    $ideRoot = Get-KiroIdeRoot
    if ($ideRoot -and (Test-Path -LiteralPath $ideRoot)) {
        $v = Get-KiroIdeVersion; if (-not $v) { $v = 'unknown' }
        Write-SurfaceRow 'kiro_ide' "Kiro $v"
    } else {
        Write-SurfaceRow 'kiro_ide' 'Kiro IDE not found'
    }
    Write-SurfaceRow 'kiro_crew' 'macOS / Linux only (Crew imports *.sh wrappers)'
}

# -- hook wiring ---------------------------------------------------------------
function Get-HookFileStatus {
    $f = Join-Path $hooksDir 'rogue.json'
    if (-not (Test-Path -LiteralPath $f)) { return 'MISSING - run install.ps1 -Kiro' }
    $text = Get-Content -Raw -LiteralPath $f
    $n = ([regex]::Matches($text, '"name":\s*"rogue-')).Count
    $m = [regex]::Match($text, 'hook\.ps1[^ ]* [A-Za-z]+ (kiro_[a-z]+)')
    $surface = 'unknown'; if ($m.Success) { $surface = $m.Groups[1].Value }
    return "present ($n Rogue hooks, surface $surface)"
}

function Test-AgentCarriesHooks {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    return [bool]((Get-Content -Raw -LiteralPath $Path) -match '"rogue-preToolUse"')
}

function Get-HookedAgentCount {
    $n = 0
    foreach ($dir in @((Join-Path (Join-Path $env:USERPROFILE '.kiro') 'agents'), (Join-Path (Get-Location).Path '.kiro\agents'))) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $dir -Filter *.json -File)) {
            if (Test-AgentCarriesHooks $f.FullName) { $n++ }
        }
    }
    return $n
}

function Get-DefaultAgentStatus {
    if (-not $script:haveCli) { return '(kiro-cli not found)' }
    $name = Get-KiroDefaultAgent
    if (-not $name) { return "(none set) - plain 'kiro-cli chat' runs the built-in agent, which carries no hooks; run install.ps1 -Kiro" }
    $home_ = Join-Path (Join-Path (Join-Path $env:USERPROFILE '.kiro') 'agents') "$name.json"
    $ws = Join-Path (Get-Location).Path ".kiro\agents\$name.json"
    if ((Test-AgentCarriesHooks $home_) -or (Test-AgentCarriesHooks $ws)) { return "$name - covered" }
    return "$name - NOT covered: switch with 'kiro-cli agent set-default rogue' or re-run install.ps1 -Kiro"
}

function Write-Wiring {
    Write-Output 'Hook wiring:'
    Write-Row '~\.kiro\hooks\rogue.json' (Get-HookFileStatus)
    Write-Row 'agent configs with Rogue hooks' "$(Get-HookedAgentCount) (~\.kiro\agents, .\.kiro\agents)"
    Write-Row 'default agent (2.x engine)' (Get-DefaultAgentStatus)
}

# -- connection: the heartbeat's body, so it lands on the heartbeat's row --------
function Get-StatusBody {
    # The CLI's row when kiro-cli is present, the IDE's otherwise: the surface the
    # SessionStart heartbeat on this machine would report first.
    $script:agent = 'kiro_ide'; if ($script:haveCli) { $script:agent = 'kiro_cli' }
    Resolve-KiroHost
    $host_ = $env:COMPUTERNAME
    if (-not $host_) { try { $host_ = [System.Net.Dns]::GetHostName() } catch { $host_ = 'unknown' } }
    $fields = @{
        agent_family  = 'kiro'
        agent         = $script:agent
        version       = $script:ver
        agent_version = $script:kiroVer
        host          = $host_
        actor_email   = [string]$script:actorEmail
        actor_name    = [string]$script:actorName
    }
    if ($script:kiroDefault) { $fields['default_agent'] = $script:kiroDefault }
    return ($fields | ConvertTo-Json -Compress)
}

function Write-HttpExplanation {
    param([string]$Code, [string]$Body)
    switch ($Code) {
        '200' {
            $org = [regex]::Match($Body, '"id"\s*:\s*"([^"]*)"')
            if ($org.Success) { Write-Output "  organization: $($org.Groups[1].Value)" }
            $running = [regex]::Match($Body, '"version"\s*:\s*"([^"]*)"')
            $latest  = [regex]::Match($Body, '"latest_version"\s*:\s*"([^"]*)"')
            $rv = 'unknown'; if ($running.Success) { $rv = $running.Groups[1].Value }
            $lv = 'unknown'; if ($latest.Success)  { $lv = $latest.Groups[1].Value }
            $upd = 'up to date'; $hint = ''
            if ($Body -match '"update_available":true') { $upd = 'update available'; $hint = ' - re-run install.ps1 -Kiro to upgrade' }
            Write-Output "  plugin $rv (latest $lv, $upd)$hint"
        }
        '401' { Write-Output '  the API key is invalid - re-run install.ps1 -Kiro with a key from the dashboard' }
        '000' { Write-Output "  network: $($script:baseUrl) did not answer (proxy or firewall?)" }
        default { Write-Output "  unexpected response: $Body" }
    }
}

function Write-Connection {
    Write-Output 'Connection:'
    if (-not $script:configured) { Write-Output '  skipped - no API key'; return }
    $body = ''
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes((Get-StatusBody))
        $resp = Invoke-WebRequest -Uri "$($script:baseUrl)/api/v1/hooks/status" -Method Post `
            -Headers @{ 'x-rogue-api-key' = $script:apiKey } -ContentType 'application/json' `
            -Body $bytes -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        $script:httpCode = [string]$resp.StatusCode
        $body = [string]$resp.Content
    } catch {
        $script:httpCode = '000'
        $r = $_.Exception.Response
        if ($r) { try { $script:httpCode = ([int]$r.StatusCode).ToString('000') } catch {} }
    }
    Write-Output "  POST /api/v1/hooks/status -> HTTP $($script:httpCode)"
    Write-HttpExplanation $script:httpCode $body
}

# -- the hook log, honouring the dispatcher's relocation knobs ------------------
function Get-LogPath {
    $file = $script:creds['ROGUE_LOG_FILE']; $dir = $script:creds['ROGUE_LOG_DIR']
    if ($env:ROGUE_LOG_FILE) { $file = $env:ROGUE_LOG_FILE }
    if ($env:ROGUE_LOG_DIR)  { $dir  = $env:ROGUE_LOG_DIR }
    if ($file) { return $file }
    if (-not $dir) { $dir = Join-Path (Join-Path $env:USERPROFILE '.rogue') 'logs' }
    return (Join-Path $dir 'kiro.log')
}

function Write-Log {
    $log = Get-LogPath
    Write-Output "Log: $log"
    if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 0) {
        Get-Content -Tail 20 -LiteralPath $log | ForEach-Object { Write-Output "  $_" }
    } else {
        Write-Output '  (no hook log yet)'
    }
}

function Invoke-Status {
    Write-Output 'Rogue Security status (Kiro)'
    Initialize-Tls
    Resolve-PluginRoot
    Import-Credentials
    Resolve-BaseUrl
    Resolve-Actor
    Resolve-Version
    Write-Credentials
    Write-Surfaces
    Write-Wiring
    Write-Connection
    Write-Log
    if ($script:configured -and $script:httpCode -eq '200') { exit 0 }
    exit 1
}

Invoke-Status
