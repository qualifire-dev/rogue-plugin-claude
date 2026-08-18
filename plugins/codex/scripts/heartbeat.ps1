# Rogue presence heartbeat (Windows / PowerShell) — Codex plugin.
#
# Native-Windows analogue of heartbeat.sh. Fired (detached) from SessionStart.
# POSTs /api/v1/hooks/status so this install shows up in the Coding Agents roster
# and the org learns which plugin version runs (drives the "outdated" badge).
# Fire-and-forget: never blocks Codex, always exits 0.

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

$pluginRoot = $env:PLUGIN_ROOT
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
foreach ($k in 'ROGUE_API_KEY','ROGUE_ACTOR_EMAIL','ROGUE_ACTOR_NAME','ROGUE_BASE_URL','ROGUE_CODEX_SURFACE') {
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

# ── plugin version (regex from manifest, no python) ────────────────────────
$ver = 'unknown'
$pj = Join-Path $pluginRoot '.codex-plugin\plugin.json'
if (Test-Path -LiteralPath $pj) {
    $m = [regex]::Match((Get-Content -Raw -LiteralPath $pj), '"version"\s*:\s*"([0-9]+\.[0-9]+\.[0-9]+)')
    if ($m.Success) { $ver = $m.Groups[1].Value }
}

# Family is the fixed enum "openai"; surface rides the agent field.
$agent = $creds['ROGUE_CODEX_SURFACE']; if (-not $agent) { $agent = 'codex_cli' }

$host_ = $env:COMPUTERNAME; if (-not $host_) { try { $host_ = [System.Net.Dns]::GetHostName() } catch { $host_ = 'unknown' } }

$body = @{
    agent_family = 'openai'
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

# ── ship the hook log ──────────────────────────────────────────────────────
# See plugins/rogue/scripts/heartbeat.ps1 for why this is a separate process
# (in-process, the shipper's `$script:` writes would clobber this file's variables
# and its `exit 0` would kill the heartbeat), why the values travel as environment
# variables (no interpolation to escape) and why the actor is passed in rather than
# re-resolved (a second cascade would key the log's source row differently from the
# roster row just posted).
#
# SLUG `codex`, FAMILY `openai` - they differ here and that is not a mistake: the
# log file is codex.log and the dispatcher writes `provider=codex`, while the
# roster family is `openai`, exactly as this script's own body reports.
$shipScript = Join-Path $pluginRoot 'scripts\ship-logs.ps1'
if (Test-Path -LiteralPath $shipScript) {
    try {
        $env:ROGUE_ACTOR_EMAIL     = [string]$actorEmail
        $env:ROGUE_ACTOR_NAME      = [string]$actorName
        $env:ROGUE_SHIPPER_SCRIPT  = $shipScript
        $env:ROGUE_SHIPPER_ROOT    = $pluginRoot
        $env:ROGUE_SHIPPER_SLUG    = 'codex'
        $env:ROGUE_SHIPPER_VERSION = [string]$ver
        $env:ROGUE_SHIPPER_FAMILY  = 'openai'
        $inner = '& ([scriptblock]::Create((Get-Content -Raw -LiteralPath $env:ROGUE_SHIPPER_SCRIPT)))' +
                 ' $env:ROGUE_SHIPPER_ROOT $env:ROGUE_SHIPPER_SLUG' +
                 ' $env:ROGUE_SHIPPER_VERSION $env:ROGUE_SHIPPER_FAMILY'
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($inner))
        $psExe = 'powershell'
        try { if ((Get-Process -Id $PID).Path) { $psExe = (Get-Process -Id $PID).Path } } catch {}
        Start-Process -FilePath $psExe `
            -ArgumentList '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded `
            -WindowStyle Hidden -ErrorAction Stop | Out-Null
        Dbg 'log shipper started'
    } catch { Dbg "log shipper not started: $($_.Exception.Message)" }
}

exit 0
