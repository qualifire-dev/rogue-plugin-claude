# Rogue presence heartbeat (Windows / PowerShell) — Google Antigravity plugin.
#
# Native-Windows analogue of heartbeat.sh. Fired (detached, via Start-Process)
# from the first PreInvocation. POSTs /api/v1/hooks/status so this install shows
# up in the Coding Agents roster and the org learns which plugin version runs.
# Fire-and-forget: never blocks Antigravity, always exits 0.
#
# Takes the surface positionally so hook.ps1 can pass what it read off the
# event's transcriptPath (see the surface block below).
param([string]$Agent = '')

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

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

try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

# Stand down on non-Windows (pwsh on macOS/Linux runs heartbeat.sh instead).
if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { exit 0 }

# Self-locate from $PSCommandPath (<root>\scripts\heartbeat.ps1); fall back to CWD.
$pluginRoot = ''
if ($PSCommandPath) { $pluginRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent }
if (-not $pluginRoot) { try { $pluginRoot = (Get-Location).Path } catch { $pluginRoot = '.' } }

# ── credential resolution ──────────────────────────────────────────────────
$creds = @{}
foreach ($f in @((Join-Path $pluginRoot 'env'), 'C:\ProgramData\rogue\env', (Join-Path $env:USERPROFILE '.rogue-env'))) {
    if (-not $f -or -not (Test-Path -LiteralPath $f)) { continue }
    foreach ($line in (Get-Content -LiteralPath $f)) {
        if ($line -match '^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.+)$') {
            $creds[$Matches[1]] = ConvertFrom-ShellQuoted ($Matches[2].Trim())
        }
    }
}
foreach ($k in 'ROGUE_API_KEY','ROGUE_ACTOR_EMAIL','ROGUE_ACTOR_NAME','ROGUE_BASE_URL') {
    $val = [Environment]::GetEnvironmentVariable($k); if ($val) { $creds[$k] = $val }
}

$apiKey = $creds['ROGUE_API_KEY']
if (-not $apiKey) { Dbg 'not configured -> no-op'; exit 0 }

$baseUrl = $creds['ROGUE_BASE_URL']; if (-not $baseUrl) { $baseUrl = 'https://api.rogue.security' }
$baseUrl = $baseUrl.TrimEnd('/')

# ── actor resolution (mirrors actor.sh) ────────────────────────────────────
$actorName = $creds['ROGUE_ACTOR_NAME']
if (-not $actorName) { try { $actorName = (& git config --global user.name 2>$null | Out-String).Trim() } catch {} }
if (-not $actorName) { $actorName = $env:USERNAME }

$actorEmail = $creds['ROGUE_ACTOR_EMAIL']
if (-not $actorEmail) { try { $actorEmail = (& git config --global user.email 2>$null | Out-String).Trim() } catch {} }
if (-not $actorEmail) {
    if ($env:USERNAME -and $env:COMPUTERNAME) { $actorEmail = "$($env:USERNAME)@$($env:COMPUTERNAME)" }
    elseif ($env:USERNAME) { $actorEmail = $env:USERNAME } else { $actorEmail = $env:COMPUTERNAME }
}

# ── plugin version (from the bundled VERSION file, NOT plugin.json — the
#    Antigravity manifest schema is additionalProperties:false with no
#    version field, so the version lives in its own file at the plugin root) ──
$ver = 'unknown'
$versionFile = Join-Path $pluginRoot 'VERSION'
if (Test-Path -LiteralPath $versionFile) {
    try {
        $first = Get-Content -LiteralPath $versionFile -TotalCount 1
        if ($first) { $ver = $first.Trim() }
    } catch {}
}

# ── surface: -Agent when the caller knows it. hook.ps1 reads it off the event's
#    transcriptPath, the only reliable source — three products (the 2.0 app, the
#    IDE, the `agy` CLI) share one install, so the fallback below cannot
#    tell which is running and picks the CLI whenever it sits alongside another.
#    Validated, not trusted verbatim: the value ends up in a roster row. ──
$agent = $Agent
if (@('antigravity', 'antigravity_ide', 'antigravity_cli') -notcontains $agent) {
    # Default to the 2.0 app — the current flagship; flip to the CLI surface if
    # the `agy` binary is on PATH or the CLI's config dir exists.
    $agent = 'antigravity'
    $agyCmd = Get-Command agy -ErrorAction SilentlyContinue
    $agyCliDir = Join-Path $env:USERPROFILE '.gemini\antigravity-cli'
    if ($agyCmd -or (Test-Path -LiteralPath $agyCliDir)) { $agent = 'antigravity_cli' }
}

$host_ = $env:COMPUTERNAME; if (-not $host_) { try { $host_ = [System.Net.Dns]::GetHostName() } catch { $host_ = 'unknown' } }

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

exit 0
