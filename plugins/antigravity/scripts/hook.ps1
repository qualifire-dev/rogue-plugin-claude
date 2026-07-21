# Rogue Security hook bridge for Google Antigravity — PowerShell implementation.
#
# Cross-platform sibling of hook.sh. hooks.json fires the `sh` command on
# macOS/Linux/WSL and this `powershell` command on native Windows (PS 5.1+,
# so this stays 5.1-compatible). PURE RELAY: reads one Antigravity hook event
# JSON on stdin, POSTs it to /api/v1/hooks/antigravity, relays the native
# Antigravity decision shape verbatim on stdout. No block-detection regex, no
# local modal — Antigravity renders the native deny shape.
#
# FAIL-OPEN IS SAFETY-CRITICAL. PreToolUse must always resolve to an explicit
# decision — never a bare `{}` — so Get-FailOpenDefault emits
# {"decision":"allow"} for PreToolUse and {} for every other event. This
# script MUST always exit 0. A block is carried in the relayed JSON body on
# stdout, never via the exit code.
#
# Exactly-one-runs (Windows): unlike Copilot (which selects one command per
# platform), both the sh entry and the PowerShell entry are registered for
# every event in hooks.json. On non-Windows pwsh this script stands down by
# emitting NOTHING (not even `{}`) and exiting 0, so it never contributes a
# decision when the sh handler also runs on the same invocation (mirrors
# hook.sh's Git Bash stand-down).
#
# Loaded via [scriptblock]::Create((Get-Content ...)) rather than -File, so it
# runs regardless of ExecutionPolicy/GPO. Because it is a scriptblock (not a
# file), $PSCommandPath is empty — hooks.json passes the plugin root
# ((Get-Location).Path) as the 2nd argument instead.
#
# Credential resolution (later file wins; process env wins over all):
#   1. <PluginRoot>\env            (baked into a compiled customer plugin)
#   2. C:\ProgramData\rogue\env    (MDM-provisioned; mirrors /etc/rogue/env)
#   3. %USERPROFILE%\.rogue-env    (user / installer-written)

param([string]$EventName = '', [string]$PluginRoot = '')

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

function Write-Raw {
    param([string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $stdout = [Console]::OpenStandardOutput()
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Flush()
}
function Dbg { param([string]$Msg) if ($env:ROGUE_DEBUG) { [Console]::Error.WriteLine("[rogue] $Msg") } }

# Per-event fail-open default. PreToolUse must resolve to an explicit
# decision (never a bare {}), or Antigravity would treat it as ambiguous;
# every other event is audit/monitor-only and fails open to a clean {}.
# Mirrors hook.sh's fail_open_default.
function Get-FailOpenDefault {
    if ($EventName -eq 'PreToolUse') { return '{"decision":"allow"}' }
    return '{}'
}

function ConvertFrom-ShellQuoted {
    # Decode one shell "word" the way hook.sh would when it sources the env file,
    # so values round-trip across both bridges (POSIX single-quoted or bash %q).
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

# Windows PowerShell 5.1 may negotiate only TLS 1.0/1.1 by default; add TLS 1.2.
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

# Stand down on non-Windows (Antigravity runs hook.sh there for real work; this
# guards a stray pwsh). Emit NOTHING (not `{}`) so this entry never
# contributes a decision alongside the sh entry — see the exactly-one-runs
# note above.
if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { exit 0 }

if (-not $EventName) { Write-Raw (Get-FailOpenDefault); exit 0 }
Dbg "event=$EventName"

# Self-locate the plugin root from the 2nd argument (hooks.json passes
# (Get-Location).Path). $PSCommandPath is empty under
# [scriptblock]::Create, so there is no file-path fallback here — fall
# straight back to the current working directory.
if (-not $PluginRoot) { try { $PluginRoot = (Get-Location).Path } catch { $PluginRoot = '.' } }

$logFile = $env:ROGUE_LOG_FILE
if (-not $logFile) { $logFile = Join-Path (Join-Path $env:USERPROFILE '.rogue') 'hook.log' }
function Sanitize { param([string]$S) if ($null -eq $S) { return '' } ($S -replace '[\x00-\x1f\x7f]', '') }
function Log {
    param([string]$Msg)
    try {
        $dir = Split-Path $logFile
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        Add-Content -LiteralPath $logFile -Value "$stamp provider=antigravity event=$EventName $Msg" -Encoding UTF8
    } catch {}
}

# ── credential resolution (later file wins; process env wins over all) ─────
$creds = @{}
foreach ($f in @((Join-Path $PluginRoot 'env'), 'C:\ProgramData\rogue\env', (Join-Path $env:USERPROFILE '.rogue-env'))) {
    if (-not $f -or -not (Test-Path -LiteralPath $f)) { continue }
    foreach ($line in (Get-Content -LiteralPath $f)) {
        if ($line -match '^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.+)$') {
            $creds[$Matches[1]] = ConvertFrom-ShellQuoted ($Matches[2].Trim())
        }
    }
}
foreach ($k in 'ROGUE_API_KEY','ROGUE_ACTOR_EMAIL','ROGUE_ACTOR_NAME','ROGUE_BASE_URL','ROGUE_API_URL') {
    $val = [Environment]::GetEnvironmentVariable($k); if ($val) { $creds[$k] = $val }
}

$apiKey = $creds['ROGUE_API_KEY']

# Not configured: never POST without a key. Emit the per-event fail-open
# default so PreToolUse still resolves to an explicit allow decision.
if (-not $apiKey) {
    Log 'outcome=unconfigured'
    Write-Raw (Get-FailOpenDefault)
    exit 0
}

# URL: explicit ROGUE_API_URL wins, else base + path.
$url = $creds['ROGUE_API_URL']
if (-not $url) {
    $baseUrl = $creds['ROGUE_BASE_URL']; if (-not $baseUrl) { $baseUrl = 'https://api.rogue.security' }
    $url = "$($baseUrl.TrimEnd('/'))/api/v1/hooks/antigravity"
}

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

# ── payload from stdin (recover UTF-8, strip BOM) ──────────────────────────
$payload = [Console]::In.ReadToEnd()
if (-not $payload) { $payload = '{}' }
try {
    $raw = [Console]::InputEncoding.GetBytes($payload)
    $payload = [System.Text.Encoding]::UTF8.GetString($raw)
} catch {}
$payload = $payload.TrimStart([char]0xFEFF)

# Heartbeat on the first invocation of a session (invocationNum == 0). Fire
# detached (Start-Process -WindowStyle Hidden) so the hook itself returns
# immediately regardless of heartbeat.ps1's own latency — mirrors hook.sh's
# `( nohup sh heartbeat.sh & )`.
if ($EventName -eq 'PreInvocation' -and ($payload -like '*"invocationNum":0*' -or $payload -like '*"invocationNum": 0*')) {
    try {
        $hbPath = Join-Path $PluginRoot 'scripts/heartbeat.ps1'
        Start-Process -FilePath 'powershell' `
            -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$hbPath `
            -WindowStyle Hidden -ErrorAction Stop
    } catch { Dbg "heartbeat launch failed: $($_.Exception.Message)" }
}

# PreInvocation/PostInvocation/Stop carry no message content inline — only a
# transcriptPath pointing at the session's transcript.jsonl. Append the last
# ~256KB of that file, base64-encoded, as "transcriptTailB64" so the backend
# can extract recent turn content. base64 has no JSON-special chars, so
# re-closing the object is safe. Fail-open: any problem returns the payload
# unchanged.
#
# Antigravity's transcript.jsonl line schema is undocumented — there is no
# known "turn end" marker line to poll for (unlike Copilot's events.jsonl), so
# this wait is schema-agnostic: it polls file SIZE stability instead of a
# marker line, and is hard time-bounded (~2s). On timeout it fails open and
# tails whatever is on disk rather than hanging or guessing at an undocumented
# marker format. Mirrors hook.sh's wait_for_transcript_flush.
function Wait-TranscriptFlush {
    param([string]$Path)
    # ~2s cap (20 * 100ms), well inside the 30s hook budget.
    # ROGUE_FLUSH_WAIT_ITERS overrides the iteration count (tests set it low
    # to exercise the fail-open path).
    $max = 20
    if ($env:ROGUE_FLUSH_WAIT_ITERS) { try { $max = [int]$env:ROGUE_FLUSH_WAIT_ITERS } catch {} }
    $prevSize = -1
    for ($i = 0; $i -lt $max; $i++) {
        try { $size = (Get-Item -LiteralPath $Path).Length } catch { return }
        if ($i -gt 0 -and $size -eq $prevSize) { return }
        $prevSize = $size
        Start-Sleep -Milliseconds 100
    }
}

if ($EventName -eq 'PreInvocation' -or $EventName -eq 'PostInvocation' -or $EventName -eq 'Stop') {
    try {
        $m = [regex]::Match($payload, '"transcriptPath"\s*:\s*"([^"]*)"')
        if ($m.Success) {
            $tp = $m.Groups[1].Value
            if ($tp -and (Test-Path -LiteralPath $tp)) {
                Wait-TranscriptFlush $tp
                $fs = [System.IO.File]::Open($tp, 'Open', 'Read', 'ReadWrite')
                try {
                    $len = $fs.Length
                    $take = [Math]::Min(262144, $len)
                    if ($take -gt 0) {
                        [void]$fs.Seek($len - $take, 'Begin')
                        $buf = New-Object byte[] $take
                        # Stream.Read may return fewer bytes than requested — loop
                        # until $take bytes are read (or EOF) so no trailing NULs
                        # leak into the base64.
                        $read = 0
                        while ($read -lt $take) {
                            $n = $fs.Read($buf, $read, $take - $read)
                            if ($n -le 0) { break }
                            $read += $n
                        }
                        if ($read -gt 0) {
                            $b64 = [Convert]::ToBase64String($buf, 0, $read)
                            # Strip exactly ONE trailing '}' (mirrors hook.sh's
                            # "${_body%\}}"). String.TrimEnd('}') would strip ALL
                            # trailing braces and corrupt a body ending in "}}".
                            $p = $payload.TrimEnd()
                            if ($p.EndsWith('}')) { $p = $p.Substring(0, $p.Length - 1) }
                            if ($b64) { $payload = $p + ',"transcriptTailB64":"' + $b64 + '"}' }
                        }
                    }
                } finally { $fs.Close() }
            }
        }
    } catch { Dbg "transcript augment failed: $($_.Exception.Message)" }
}

# ── POST (fail-open) → relay verbatim ──────────────────────────────────────
$headers = @{
    'x-rogue-api-key'     = $apiKey
    'x-rogue-event'       = $EventName
    'x-rogue-actor-email' = $actorEmail
    'x-rogue-actor-name'  = $actorName
}
$bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
$resp = ''
try {
    $r = Invoke-WebRequest -Uri $url -Method Post `
        -Headers $headers -ContentType 'application/json' -Body $bodyBytes `
        -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
    if ($r.StatusCode -eq 200) {
        try { $resp = [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) }
        catch { $resp = [string]$r.Content }
    }
} catch { Dbg "POST failed: $($_.Exception.Message)"; $resp = '' }

$respHead = if ($resp.Length -gt 400) { $resp.Substring(0, 400) } else { $resp }
Log "raw=$(Sanitize $respHead)"

# Fail-open on transport error, any non-200, or an empty body: emit the
# per-event default rather than relaying garbage as a decision.
if (-not $resp) {
    Log 'outcome=allow'
    Write-Raw (Get-FailOpenDefault)
    exit 0
}

# rogue-api already returns the correct native Antigravity shape; relay it
# verbatim.
Write-Raw $resp
exit 0
