# Rogue presence heartbeat (Windows / PowerShell).
#
# Native-Windows analogue of heartbeat.sh. Fired (detached) from SessionStart.
# POSTs /api/v1/hooks/status so this install shows up in the dashboard's Coding
# Agents roster and so the org learns which plugin version is running. Pure
# side-effect: fire-and-forget, never blocks Claude Code, always exits 0.
#
# Credential resolution mirrors hook.ps1 (later file wins; process env over all):
#   1. ${CLAUDE_PLUGIN_ROOT}\env   2. C:\ProgramData\rogue\env   3. %USERPROFILE%\.rogue-env

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
# CLAUDE_CODE_ENTRYPOINT used to `exit 0` right here. It now guards only the beacon
# POST below, in lockstep with heartbeat.sh: this script also ships the hook log, and
# the entrypoint decides whether there is a SESSION to report presence for, which is
# a different question from whether the log on disk is worth uploading. Behaviour of
# the beacon itself is unchanged - it still fires exactly when it did.

$pluginRoot = $env:CLAUDE_PLUGIN_ROOT
if (-not $pluginRoot) { try { $pluginRoot = (Get-Location).Path } catch { $pluginRoot = '.' } }

# -- credential resolution --------------------------------------------------
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

# -- actor resolution (mirrors actor.sh) ------------------------------------
$actorName = $creds['ROGUE_ACTOR_NAME']
if (-not $actorName) { try { $actorName = (& git config --global user.name 2>$null | Out-String).Trim() } catch {} }
if (-not $actorName -and $env:CLAUDE_CODE_USER_EMAIL) { $actorName = ($env:CLAUDE_CODE_USER_EMAIL -split '@')[0] }
if (-not $actorName) { $actorName = $env:USERNAME }

$actorEmail = $creds['ROGUE_ACTOR_EMAIL']
if (-not $actorEmail) { try { $actorEmail = (& git config --global user.email 2>$null | Out-String).Trim() } catch {} }
if (-not $actorEmail -and $env:CLAUDE_CODE_USER_EMAIL) { $actorEmail = $env:CLAUDE_CODE_USER_EMAIL }
if (-not $actorEmail) {
    if ($env:USERNAME -and $env:COMPUTERNAME) { $actorEmail = "$($env:USERNAME)@$($env:COMPUTERNAME)" }
    elseif ($env:USERNAME) { $actorEmail = $env:USERNAME } else { $actorEmail = $env:COMPUTERNAME }
}

# -- plugin version (regex from manifest, no python) ------------------------
$ver = 'unknown'
$pj = Join-Path $pluginRoot '.claude-plugin\plugin.json'
if (Test-Path -LiteralPath $pj) {
    $m = [regex]::Match((Get-Content -Raw -LiteralPath $pj), '"version"\s*:\s*"([0-9]+\.[0-9]+\.[0-9]+)')
    if ($m.Success) { $ver = $m.Groups[1].Value }
}

# -- agent display label from entrypoint (family is the fixed enum "claude") -
$ep = ([string]$env:CLAUDE_CODE_ENTRYPOINT).ToLower()
if ($ep -like '*cowork*')      { $agent = 'Claude Cowork' }
elseif ($ep -like '*desktop*') { $agent = 'Claude Code - Desktop' }
else                           { $agent = 'Claude Code - CLI' }

$host_ = $env:COMPUTERNAME; if (-not $host_) { try { $host_ = [System.Net.Dns]::GetHostName() } catch { $host_ = 'unknown' } }

$body = @{
    agent_family = 'claude'
    agent        = $agent
    version      = $ver
    host         = $host_
    actor_email  = [string]$actorEmail
    actor_name   = [string]$actorName
} | ConvertTo-Json -Compress

# The beacon, and ONLY the beacon, is gated on there being a session (see the note
# where that check used to live).
if ($env:CLAUDE_CODE_ENTRYPOINT) {
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        Invoke-WebRequest -Uri "$baseUrl/api/v1/hooks/status" -Method Post `
            -Headers @{ 'x-rogue-api-key' = $apiKey } -ContentType 'application/json' `
            -Body $bytes -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop | Out-Null
        Dbg 'heartbeat sent'
    } catch { Dbg "heartbeat failed: $($_.Exception.Message)" }
}

# ── ship the hook log ──────────────────────────────────────────────────────
# AFTER the status POST when both run, for the same reason as heartbeat.sh: the
# beacon creates or refreshes this install's roster row, so this order means it
# exists before the logs land. An ordering preference, NOT a prerequisite - the
# backend resolves-or-creates the log source from the identity fields the shipper
# sends - which is why shipping sits OUTSIDE the gate above.
#
# A SEPARATE PROCESS, not an in-process scriptblock, for two concrete reasons:
#   * a scriptblock created here resolves `$script:` against THIS file's scope, so
#     ship-logs.ps1's own $script:creds / $script:offset / $script:stateKey writes
#     would land on this script's variables;
#   * ship-logs.ps1 ends in `exit 0`, which in-process would terminate the
#     heartbeat instead of the shipper.
# The child loads it via [scriptblock]::Create so ExecutionPolicy/GPO never
# applies - the same trick hooks.json uses for the dispatchers, and the reason
# -File is not used anywhere in this repo.
#
# EVERY VALUE TRAVELS AS AN ENVIRONMENT VARIABLE and the command itself is a
# constant, so there is no string interpolation to escape: a plugin path or a
# version containing a quote cannot alter the command. -EncodedCommand for the
# same reason - Start-Process's -ArgumentList quoting is unreliable on Windows
# PowerShell 5.1 for anything containing spaces.
#
# The actor is PASSED IN, never re-resolved: this script resolved it into ordinary
# locals through a cascade of its own, and a second cascade inside the shipper
# would key the log's source row differently from the roster row just posted, so
# the logs would attach to nothing. Writing $env: here is safe - this process
# exits immediately below.
$shipScript = Join-Path $pluginRoot 'scripts\ship-logs.ps1'
if (Test-Path -LiteralPath $shipScript) {
    try {
        $env:ROGUE_ACTOR_EMAIL     = [string]$actorEmail
        $env:ROGUE_ACTOR_NAME      = [string]$actorName
        $env:ROGUE_SHIPPER_SCRIPT  = $shipScript
        $env:ROGUE_SHIPPER_ROOT    = $pluginRoot
        $env:ROGUE_SHIPPER_SLUG    = 'claude'
        $env:ROGUE_SHIPPER_VERSION = [string]$ver
        $env:ROGUE_SHIPPER_FAMILY  = 'claude'
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
