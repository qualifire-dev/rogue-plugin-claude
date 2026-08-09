# Rogue presence heartbeat (Windows / PowerShell) — Google Antigravity plugin.
#
# Native-Windows analogue of heartbeat.sh. Fired (detached, via Start-Process)
# from the first PreInvocation. POSTs /api/v1/hooks/status so this install shows
# up in the Coding Agents roster and the org learns which plugin version runs.
# Fire-and-forget: never blocks Antigravity, always exits 0.
#
# Takes the surface positionally so hook.ps1 can pass what it read off the
# event's transcriptPath (see the surface block below).
#
# Main-and-functions, like hook.ps1: everything below is a function and only
# `Invoke-Main` runs. Shared state lives in the script-scoped variables declared
# under it, and every write to one is `$script:`-qualified — an unqualified
# assignment inside a function writes to a local copy that vanishes on return.
param([string]$Agent = '')

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

$pluginRoot = ''
$creds      = @{}
$apiKey     = ''
$baseUrl    = ''
$actorName  = ''
$actorEmail = ''
$ver        = 'unknown'   # plugin version, from the bundled VERSION file
$agent      = ''          # which of the three surfaces this install reports for

function Dbg { param([string]$Msg) if ($env:ROGUE_DEBUG) { [Console]::Error.WriteLine("[rogue-heartbeat] $Msg") } }

function ConvertFrom-ShellQuoted {
    param([string]$Val)
    if ($null -eq $Val) { return $Val }
    $sb = [System.Text.StringBuilder]::new()
    $i = 0; $n = $Val.Length; $state = 'normal'
    while ($i -lt $n) {
        $c = $Val[$i]
        switch ($state) {
            'single' { if ($c -eq "'") { $state = 'normal' } else { [void]$sb.Append($c) } }
            'double' {
                if ($c -eq '"') { $state = 'normal' }
                elseif ($c -eq '\' -and ($i + 1) -lt $n -and ('"\$`'.IndexOf($Val[$i+1]) -ge 0)) { [void]$sb.Append($Val[$i+1]); $i++ }
                else { [void]$sb.Append($c) }
            }
            default {
                if ($c -eq "'") { $state = 'single' }
                elseif ($c -eq '"') { $state = 'double' }
                elseif ($c -eq '\' -and ($i + 1) -lt $n) { [void]$sb.Append($Val[$i+1]); $i++ }
                else { [void]$sb.Append($c) }
            }
        }
        $i++
    }
    return $sb.ToString()
}

function Initialize-Tls {
    try {
        [Net.ServicePointManager]::SecurityProtocol = `
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {}
}

# Stand down on non-Windows (pwsh on macOS/Linux runs heartbeat.sh instead).
function Stop-OnNonWindows {
    if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { exit 0 }
}

# Self-locate from $PSCommandPath (<root>\scripts\heartbeat.ps1); fall back to CWD.
function Resolve-PluginRoot {
    if ($PSCommandPath) { $script:pluginRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent }
    if (-not $script:pluginRoot) {
        try { $script:pluginRoot = (Get-Location).Path } catch { $script:pluginRoot = '.' }
    }
}

# ── credential resolution ──────────────────────────────────────────────────
function Import-Credentials {
    $script:creds = @{}
    foreach ($f in @((Join-Path $pluginRoot 'env'), 'C:\ProgramData\rogue\env', (Join-Path $env:USERPROFILE '.rogue-env'))) {
        if (-not $f -or -not (Test-Path -LiteralPath $f)) { continue }
        foreach ($line in (Get-Content -LiteralPath $f)) {
            if ($line -match '^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.+)$') {
                $script:creds[$Matches[1]] = ConvertFrom-ShellQuoted ($Matches[2].Trim())
            }
        }
    }
    foreach ($k in 'ROGUE_API_KEY','ROGUE_ACTOR_EMAIL','ROGUE_ACTOR_NAME','ROGUE_BASE_URL') {
        $val = [Environment]::GetEnvironmentVariable($k); if ($val) { $script:creds[$k] = $val }
    }
    $script:apiKey = $script:creds['ROGUE_API_KEY']
}

# Not configured → no-op (mirrors heartbeat.sh).
function Assert-ApiKey {
    if ($apiKey) { return }
    Dbg 'not configured -> no-op'
    exit 0
}

function Resolve-BaseUrl {
    $script:baseUrl = $creds['ROGUE_BASE_URL']
    if (-not $script:baseUrl) { $script:baseUrl = 'https://api.rogue.security' }
    $script:baseUrl = $script:baseUrl.TrimEnd('/')
}

# ── actor resolution (mirrors actor.sh) ────────────────────────────────────
function Resolve-Actor {
    $script:actorName = $creds['ROGUE_ACTOR_NAME']
    if (-not $script:actorName) { try { $script:actorName = (& git config --global user.name 2>$null | Out-String).Trim() } catch {} }
    if (-not $script:actorName) { $script:actorName = $env:USERNAME }

    $script:actorEmail = $creds['ROGUE_ACTOR_EMAIL']
    if (-not $script:actorEmail) { try { $script:actorEmail = (& git config --global user.email 2>$null | Out-String).Trim() } catch {} }
    if (-not $script:actorEmail) {
        if ($env:USERNAME -and $env:COMPUTERNAME) { $script:actorEmail = "$($env:USERNAME)@$($env:COMPUTERNAME)" }
        elseif ($env:USERNAME) { $script:actorEmail = $env:USERNAME } else { $script:actorEmail = $env:COMPUTERNAME }
    }
}

# ── plugin version (from the bundled VERSION file, NOT plugin.json — the
#    Antigravity manifest schema is additionalProperties:false with no
#    version field, so the version lives in its own file at the plugin root) ──
function Resolve-Version {
    $versionFile = Join-Path $pluginRoot 'VERSION'
    if (Test-Path -LiteralPath $versionFile) {
        try {
            $first = Get-Content -LiteralPath $versionFile -TotalCount 1
            if ($first) { $script:ver = $first.Trim() }
        } catch {}
    }
}

# ── surface: -Agent when the caller knows it. hook.ps1 reads it off the event's
#    transcriptPath, the only reliable source — three products (the 2.0 app, the
#    IDE, the `agy` CLI) share one install, so the fallback below cannot
#    tell which is running and picks the CLI whenever it sits alongside another.
#    Validated, not trusted verbatim: the value ends up in a roster row. ──
function Resolve-Surface {
    $script:agent = $Agent
    if (@('antigravity', 'antigravity_ide', 'antigravity_cli') -contains $script:agent) { return }
    # Default to the 2.0 app — the current flagship; flip to the CLI surface if
    # the `agy` binary is on PATH or the CLI's config dir exists.
    $script:agent = 'antigravity'
    $agyCmd = Get-Command agy -ErrorAction SilentlyContinue
    $agyCliDir = Join-Path $env:USERPROFILE '.gemini\antigravity-cli'
    if ($agyCmd -or (Test-Path -LiteralPath $agyCliDir)) { $script:agent = 'antigravity_cli' }
}

function Send-Heartbeat {
    $host_ = $env:COMPUTERNAME
    if (-not $host_) { try { $host_ = [System.Net.Dns]::GetHostName() } catch { $host_ = 'unknown' } }

    $body = @{
        agent_family = 'antigravity'
        agent        = $agent
        version      = $ver
        host         = $host_
        actor_email  = [string]$actorEmail
        actor_name   = [string]$actorName
    } | ConvertTo-Json -Compress

    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        Invoke-WebRequest -Uri "$baseUrl/api/v1/hooks/status" -Method Post `
            -Headers @{ 'x-rogue-api-key' = $apiKey } -ContentType 'application/json' `
            -Body $bytes -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop | Out-Null
        Dbg 'heartbeat sent'
    } catch { Dbg "heartbeat failed: $($_.Exception.Message)" }
}

# ── main ───────────────────────────────────────────────────────────────────
# Same order as heartbeat.sh: stand down, configure, then fire and forget.
function Invoke-Main {
    Initialize-Tls
    Stop-OnNonWindows
    Resolve-PluginRoot
    Import-Credentials
    Assert-ApiKey      # exits 0 when this install is not configured
    Resolve-BaseUrl
    Resolve-Actor
    Resolve-Version
    Resolve-Surface
    Send-Heartbeat
    exit 0
}

# Test seam, as in hook.ps1: `if (-not …)` and never a bare `return`, which would
# unwind a test that dot-sources this file.
if (-not $env:ROGUE_PS_LIB_ONLY) { Invoke-Main }
