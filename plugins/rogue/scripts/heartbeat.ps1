# Rogue presence heartbeat (Windows / PowerShell).
#
# Native-Windows analogue of heartbeat.sh. Fired (detached) from SessionStart and
# from Stop. POSTs /api/v1/hooks/status so this install shows up in the dashboard's
# Coding Agents roster and so the org learns which plugin version is running. Pure
# side-effect: fire-and-forget, never blocks Claude Code, always exits 0.
#
# Credential resolution mirrors hook.ps1 (later file wins; process env over all):
#   1. ${CLAUDE_PLUGIN_ROOT}\env   2. C:\ProgramData\rogue\env   3. %USERPROFILE%\.rogue-env
#
# TWO TRIGGERS, ONE SCRIPT, exactly as in heartbeat.sh. SessionStart fires once per
# session; Stop fires once per TURN, so its beacon is throttled. Keep the two
# halves in lockstep: the throttle interval, the stamp path and the
# SessionStart-is-never-throttled rule all have to agree, or a machine's beacon
# cadence would depend on its operating system.

# Must precede every statement, so it sits above $ErrorActionPreference. The
# default keeps an older hooks.json - which passes no argument - behaving exactly
# as it does today.
param([string]$Trigger = 'SessionStart')

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

function Dbg { param([string]$Msg) if ($env:ROGUE_DEBUG) { [Console]::Error.WriteLine("[rogue-heartbeat] $Msg") } }

# ── beacon throttle ────────────────────────────────────────────────────────
# Mirrors heartbeat.sh stage for stage. SessionStart is never throttled: it fires
# once per session, and a brand-new session is exactly when the roster most wants
# the update. Only the per-turn trigger is rate-limited.
#
# Defined UP HERE, above the credential loading, purely so the ROGUE_PS_LIB_ONLY
# seam below can expose them to the tests without the dot-source running a real
# beacon. The default stands alone so a dot-source that never calls
# Initialize-BeaconThrottle still has a usable interval.
$script:beaconMinInterval = 900

# The interval is resolved from the CREDENTIAL MAP, not from $env: directly, and
# therefore only once the env files have been parsed - exactly like
# Initialize-Logging in hook.ps1, and for the same reason. Read at file scope this
# silently ignored every env file: heartbeat.sh sources them BEFORE it reads the
# knob, so `ROGUE_HEARTBEAT_MIN_INTERVAL` in ~/.rogue-env or in an MDM
# C:\ProgramData\rogue\env took effect on macOS and Linux and did nothing on
# Windows, leaving every Windows machine on the 900s default. There is no
# workaround from a user's shell either: this script is spawned DETACHED by
# hook.ps1, so its process environment comes from Claude Code, not from whoever
# configured the machine. ROGUE_HEARTBEAT_MIN_INTERVAL rides the process-env
# override list below, so process env still wins over the files.
#
# A numeric zero DISABLES the throttle; a non-numeric value falls back to the
# default. Same rule as ROGUE_LOG_MAX_BYTES and ROGUE_SHIP_MIN_INTERVAL, so there
# is one convention to remember. On a Stop trigger zero means a beacon every turn:
# that is the knob doing what it says, and the default is what protects the fleet.
#
# TryParse, not a plain [int64] cast: the cast throws on a value too wide for the
# type, and while $ErrorActionPreference = 'SilentlyContinue' would swallow it and
# leave the default standing, that is the right answer reached by accident.
function Initialize-BeaconThrottle {
    # [hashtable], defaulted, exactly like Initialize-Logging in hook.ps1: the merged
    # credential map, whose precedence is already correct by the time it gets here.
    param([hashtable]$Creds = @{})
    $script:beaconMinInterval = 900
    $raw = [string]$Creds['ROGUE_HEARTBEAT_MIN_INTERVAL']
    if (-not $raw) { return }
    $parsed = [int64]0
    if ([int64]::TryParse($raw, [ref]$parsed) -and $parsed -ge 0) {
        $script:beaconMinInterval = $parsed
    }
}

# $HOME backs up USERPROFILE so this path also resolves when the file is
# dot-sourced on macOS/Linux by the test suite.
$beaconHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
$script:beaconStamp = Join-Path (Join-Path (Join-Path $beaconHome '.rogue') 'beacon') '.last-claude'

# $true = skip this beacon. Every unreadable or unparseable case answers $false:
# a stamp we cannot trust must never be able to silence presence reporting.
function Test-BeaconThrottled {
    param([string]$TriggerName = $script:trigger)
    if ($TriggerName -eq 'SessionStart') { return $false }
    if ($script:beaconMinInterval -le 0) { return $false }
    if (-not (Test-Path -LiteralPath $script:beaconStamp)) { return $false }
    $raw = (Get-Content -LiteralPath $script:beaconStamp -TotalCount 1) -replace '\s', ''
    $last = [int64]0
    if (-not [int64]::TryParse($raw, [ref]$last)) { return $false }
    $now = Get-UnixSeconds
    # A stamp in the FUTURE (clock stepped back, bad write) is stale, not a reason
    # to stay quiet until the clock catches up.
    if ($last -gt $now) { return $false }
    return (($now - $last) -lt $script:beaconMinInterval)
}

function Get-UnixSeconds {
    # The epoch is CONSTRUCTED with DateTimeKind::Utc, never parsed from a string.
    # `[datetime]'1970-01-01T00:00:00Z'` looks equivalent and is not: .NET reads the Z
    # as UTC and then CONVERTS TO LOCAL, yielding Kind=Local (1970-01-01T02:00+02:00
    # on a UTC+2 box). Subtracting a Local from a Utc does naive tick arithmetic, so
    # this returned epoch MINUS the machine's UTC offset. The throttle still worked -
    # the same function writes and reads the stamp, so the delta was right - but the
    # number on disk was wrong by hours, disagreeing with the true epoch that
    # heartbeat.sh writes to the same path with `date -u +%s` and with
    # ship-logs.ps1's Get-EpochSeconds, which already does it this way.
    $epoch = New-Object DateTime(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
    return [int64][Math]::Floor(((Get-Date).ToUniversalTime() - $epoch).TotalSeconds)
}

# The param() lands in the caller's scope when this file is dot-sourced, so the
# trigger is copied to a $script: variable that Test-BeaconThrottled can default
# to. PowerShell variable names are case-insensitive, which is exactly how the
# tests' own -Trigger parameter would otherwise be clobbered.
$script:trigger = $Trigger

# Test seam: everything above is pure and safe to dot-source on any platform;
# everything below reads credentials and POSTs. Same seam hook.ps1 uses.
if ($env:ROGUE_PS_LIB_ONLY) { return }

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
# ROGUE_HEARTBEAT_MIN_INTERVAL rides this list so a process-env value still beats
# the files, which is what makes the resolved precedence identical to hook.ps1's.
foreach ($k in 'ROGUE_API_KEY','ROGUE_ACTOR_EMAIL','ROGUE_ACTOR_NAME','ROGUE_BASE_URL',
               'ROGUE_HEARTBEAT_MIN_INTERVAL') {
    $val = [Environment]::GetEnvironmentVariable($k); if ($val) { $creds[$k] = $val }
}

# Resolved HERE - after the env files are parsed so they can set it, and before the
# API-key check below so the ordering cannot regress into reading it too early again.
Initialize-BeaconThrottle $creds

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
# One table, in scripts/surface.ps1, shared with hook.ps1 - which stamps the
# matching SLUG on each log line. Two copies of this mapping would eventually
# drift, and a log line naming a different surface than the roster row for the same
# session is worse than a line that names none. The literal below is a last-resort
# guard for a damaged install, not a second copy of the mapping.
$agent = ''
try {
    $surfaceLib = Join-Path $pluginRoot 'scripts\surface.ps1'
    if (Test-Path -LiteralPath $surfaceLib) {
        . $surfaceLib
        $agent = [string](Get-RogueSurfaceLabel)
    }
} catch { $agent = '' }
if (-not $agent) { $agent = 'Claude Code - CLI' }

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
if ($env:CLAUDE_CODE_ENTRYPOINT -and -not (Test-BeaconThrottled)) {
    # Stamped BEFORE the request, like the shipper's: this is a crash-loop guard as
    # much as a rate limit, so a beacon that hangs or dies still costs the next turn
    # its attempt rather than retrying on every one. No umask counterpart is needed
    # here - another standard user cannot read %USERPROFILE% to begin with.
    try {
        $stampDir = Split-Path -Parent $script:beaconStamp
        if (-not (Test-Path -LiteralPath $stampDir)) {
            New-Item -ItemType Directory -Path $stampDir -Force | Out-Null
        }
        # BOM-less UTF-8 and an LF, matching the log writers: Add-Content -Encoding
        # UTF8 emits a BOM on Windows PowerShell 5.1 when it creates the file, and
        # the leading EF BB BF would then fail every TryParse that reads it back -
        # turning the throttle off permanently instead of noisily.
        [System.IO.File]::WriteAllText($script:beaconStamp, "$(Get-UnixSeconds)`n",
            (New-Object System.Text.UTF8Encoding $false))
    } catch { Dbg "beacon stamp failed: $($_.Exception.Message)" }
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
