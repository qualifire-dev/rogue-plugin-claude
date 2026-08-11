# Rogue Security hook dispatcher for Cursor — PowerShell implementation.
#
# Cross-platform sibling of hook.sh. hooks.json loads this WITHOUT -File so the
# PowerShell ExecutionPolicy never applies (running a scriptblock built from a
# string is not subject to policy, unlike invoking a .ps1 on disk — this also
# survives a GPO-enforced policy, which -ExecutionPolicy Bypass does not):
#
#   powershell -NoProfile -NonInteractive -Command \
#     "& ([scriptblock]::Create((Get-Content -Raw -LiteralPath (Join-Path $env:CURSOR_PLUGIN_ROOT 'scripts/hook.ps1')))) <event>"
#
# CURSOR_PLUGIN_ROOT (the plugin root) is exposed as a process ENVIRONMENT
# VARIABLE, so PowerShell resolves $env:CURSOR_PLUGIN_ROOT at runtime via
# Join-Path — it must NOT be single-quoted (single quotes are literal in
# PowerShell and would never expand). Cursor runs this entry from a cwd that is
# NOT the plugin root, so a relative path would not resolve here. Join-Path also
# keeps the absolute path intact when it contains spaces.
#
# This script OWNS native Windows. It stands down on non-Windows (pwsh on
# macOS/Linux) because hook.sh runs there.
#
# Fail-open everywhere: missing API key, network error, non-200, empty body, or
# non-JSON response all yield `{}` on stdout, exit 0.
#
# Set ROGUE_DEBUG=1 (process/user env var) to emit diagnostics to stderr;
# Cursor shows stderr in its hook log without treating it as the response.
#
# Logs every invocation to $env:ROGUE_LOG_FILE (default
# %USERPROFILE%\.rogue\logs\cursor.log), mirroring hook.sh.
#
# Credential resolution (later file wins; process env wins over all), the
# Windows analogue of hook.sh's search:
#   1. ${CURSOR_PLUGIN_ROOT}\env        (baked into a compiled customer plugin)
#   2. C:\ProgramData\rogue\env         (MDM-provisioned; mirrors /etc/rogue/env)
#   3. %USERPROFILE%\.rogue-env         (user / installer-written)

param([string]$EventName = '')

$ErrorActionPreference = 'SilentlyContinue'
# Invoke-WebRequest renders a progress bar that, when stdout/stderr is
# redirected (always true under a Cursor hook), can slow the call 10-50x or
# effectively hang it. Silencing progress is the standard fix.
$ProgressPreference = 'SilentlyContinue'

function Write-Raw {
    # Write raw UTF-8 bytes to stdout, bypassing [Console]::Out whose encoding
    # may be a legacy codepage (e.g. CP437) that mangles non-ASCII output back
    # into mojibake. Cursor reads the hook's stdout as UTF-8.
    param([string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $stdout = [Console]::OpenStandardOutput()
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Flush()
}
function Dbg { param([string]$Msg) if ($env:ROGUE_DEBUG) { [Console]::Error.WriteLine("[rogue] $Msg"); [Console]::Error.Flush() } }

function Emit-Json {
    param([string]$Data)
    if (-not $Data) { Write-Raw '{}'; return }
    Write-Raw $Data
}

function ConvertFrom-ShellQuoted {
    # Decode one shell "word" the way `hook.sh` would when it `source`s the env
    # file, so values round-trip across both dispatchers. The env files are
    # written either POSIX single-quoted with `'\''` escapes (install.ps1) or
    # via bash `printf %q`, which emits backslash escapes and double quotes
    # (install.sh). A naive outer-quote strip mangles values like O'Brien
    # ('O'\''Brien') or "Your Name" (Your\ Name); this walks the string honoring
    # single quotes, double quotes, and backslash escapes instead.
    param([string]$Val)
    if ($null -eq $Val) { return $Val }
    $sb = [System.Text.StringBuilder]::new()
    $i = 0; $n = $Val.Length
    $state = 'normal'   # normal | single | double
    while ($i -lt $n) {
        $c = $Val[$i]
        switch ($state) {
            'single' {
                if ($c -eq "'") { $state = 'normal' } else { [void]$sb.Append($c) }
            }
            'double' {
                if ($c -eq '"') { $state = 'normal' }
                elseif ($c -eq '\' -and ($i + 1) -lt $n -and ('"\$`'.IndexOf($Val[$i+1]) -ge 0)) {
                    [void]$sb.Append($Val[$i+1]); $i++
                } else { [void]$sb.Append($c) }
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

function Repair-DoubleEncodedUtf8 {
    # Cursor on non-UTF-8 Windows locales double-encodes assistant text
    # (UTF-8 -> CP1252 -> UTF-8): e.g. "—" arrives as "â€"" and "'" as "â€™".
    # We can't change the client's system locale, so repair it here: re-encode
    # the string as CP1252 and decode as UTF-8, with BOTH steps STRICT (throw on
    # any unmappable char / invalid byte). Genuine mojibake round-trips to valid
    # UTF-8 and is repaired; already-correct text (café, 😀, plain ASCII) fails
    # the strict round-trip and is returned unchanged — so this is a safe no-op
    # for well-behaved clients.
    param([string]$Text)
    if (-not $Text) { return $Text }
    try {
        $cp1252 = [System.Text.Encoding]::GetEncoding(1252,
            [System.Text.EncoderFallback]::ExceptionFallback,
            [System.Text.DecoderFallback]::ExceptionFallback)
        $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
        $repaired = $strictUtf8.GetString($cp1252.GetBytes($Text))
        if ($repaired -ne $Text) { Dbg "repaired double-encoded UTF-8"; return $repaired }
    } catch { Dbg "no double-encode repair (text already valid UTF-8)" }
    return $Text
}

# ── hook log ───────────────────────────────────────────────────────────────
# `Dbg` above only writes to stderr under ROGUE_DEBUG, which Cursor keeps in its
# own per-session log — useless for after-the-fact diagnosis and unavailable to
# /rogue:status. So every invocation also gets one durable line here, in the same
# format hook.sh writes: "<ts> provider=cursor event=<E> <k=v>".
#
# ONE FILE PER AGENT. Every Rogue plugin shares ~/.rogue, so a single hook.log
# would interleave Cursor with Claude Code / Codex / … and lose attribution.
# Precedence: $env:ROGUE_LOG_FILE → $env:ROGUE_LOG_DIR/cursor.log → default.
# $HOME backs up USERPROFILE so this file can also be dot-sourced on macOS/Linux
# through the ROGUE_PS_LIB_ONLY seam below (tests).
#
# NOTE the sh/ps asymmetry, shared with every other Rogue plugin: hook.sh
# resolves these AFTER sourcing the env files, so `~/.rogue-env` can set them
# there. Here they come from the PROCESS environment only, because logging has to
# work on the unconfigured path (before credentials are parsed).
$logFile = $env:ROGUE_LOG_FILE
if (-not $logFile) {
    $logDir = $env:ROGUE_LOG_DIR
    if (-not $logDir) {
        $userHome = $env:USERPROFILE
        if (-not $userHome) { $userHome = $HOME }
        if ($userHome) { $logDir = Join-Path (Join-Path $userHome '.rogue') 'logs' }
    }
    if ($logDir) { $logFile = Join-Path $logDir 'cursor.log' }
}
# Size cap. Over it the current log is renamed to <file>.1 (exactly one
# generation kept, so worst case on disk is 2x this). 0 or non-numeric disables
# rotation. Enforced on the WRITE PATH and not by a periodic job on purpose: an
# UNCONFIGURED install writes a line per event and never runs anything else, so
# a cap enforced anywhere else would not hold.
$logMaxBytes = 2097152
if ($env:ROGUE_LOG_MAX_BYTES -match '^[0-9]+$') { $logMaxBytes = [int64]$env:ROGUE_LOG_MAX_BYTES }
# Strip control characters: the logged text is SERVER-CONTROLLED (a block reason
# can carry anything), and a raw newline or CR would forge extra log lines.
function Sanitize { param([string]$S) if ($null -eq $S) { return '' } ($S -replace '[\x00-\x1f\x7f]', '') }
function Rotate-Log {
    if (-not $logFile -or $logMaxBytes -le 0) { return }
    try {
        $fi = Get-Item -LiteralPath $logFile -ErrorAction SilentlyContinue
        if ($fi -and $fi.Length -ge $logMaxBytes) {
            Move-Item -LiteralPath $logFile -Destination "$logFile.1" -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}
function Log {
    param([string]$Msg)
    try {
        if (-not $logFile) { return }
        $dir = Split-Path $logFile
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Rotate-Log
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        Add-Content -LiteralPath $logFile -Value "$stamp provider=cursor event=$EventName $Msg" -Encoding UTF8
    } catch {}
}

# Test seam: dot-sourcing with ROGUE_PS_LIB_ONLY=1 loads the functions above
# (e.g. ConvertFrom-ShellQuoted, Rotate-Log) without running the dispatcher.
# Production never sets this, so the hook always runs its main body.
if ($env:ROGUE_PS_LIB_ONLY) { return }

# Windows PowerShell 5.1 may negotiate only TLS 1.0/1.1 by default, which
# modern HTTPS endpoints reject ("Could not create SSL/TLS secure channel").
# Add TLS 1.2 without clobbering any protocols already enabled.
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

# ── stand down on non-Windows (pwsh on macOS/Linux) ────────────────────────
# $IsWindows exists only in PowerShell 6+. In 5.1 (Windows-only) it is $null,
# so guard on the version to avoid a false stand-down there.
if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { Write-Raw '{}'; exit 0 }

if (-not $EventName) { Dbg "no event name -> {}"; Write-Raw '{}'; exit 0 }
Dbg "event=$EventName"

# ── credential resolution (later file wins; process env wins over all) ─────
$creds = @{}
$pluginRoot = $env:CURSOR_PLUGIN_ROOT
if (-not $pluginRoot) { try { $pluginRoot = (Get-Location).Path } catch { $pluginRoot = '.' } }
Dbg "pluginRoot=$pluginRoot"

$credFiles = @(
    (Join-Path $pluginRoot 'env'),
    'C:\ProgramData\rogue\env',
    (Join-Path $env:USERPROFILE '.rogue-env')
)
foreach ($f in $credFiles) {
    if (-not $f) { continue }
    if (-not (Test-Path -LiteralPath $f)) { Dbg "cred file absent: $f"; continue }
    Dbg "cred file found: $f"
    foreach ($line in (Get-Content -LiteralPath $f)) {
        if ($line -match '^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.+)$') {
            $k = $Matches[1]
            # Decode shell quoting/escaping so the value round-trips with the
            # `source`-based parse in hook.sh (mirrors shlex.split).
            $v = ConvertFrom-ShellQuoted ($Matches[2].Trim())
            $creds[$k] = $v
        }
    }
}
foreach ($k in 'ROGUE_API_KEY','ROGUE_ACTOR_EMAIL','ROGUE_ACTOR_NAME','ROGUE_BASE_URL') {
    $val = [Environment]::GetEnvironmentVariable($k)
    if ($val) { $creds[$k] = $val }
}

$apiKey = $creds['ROGUE_API_KEY']
if (-not $apiKey) {
    Dbg "no API key after cred resolution -> fail-open"
    Log "outcome=unconfigured"
    if ($EventName -eq 'sessionStart') {
        Write-Raw '{"additional_context": "Rogue Security plugin is installed but not configured. Run /rogue:setup to connect your API key."}'
    } else {
        Write-Raw '{}'
    }
    exit 0
}
$keyTail = if ($apiKey.Length -ge 4) { $apiKey.Substring($apiKey.Length - 4) } else { '****' }
Dbg "apiKey present (tail $keyTail)"

$baseUrl = $creds['ROGUE_BASE_URL']
if (-not $baseUrl) { $baseUrl = 'https://api.rogue.security' }
$baseUrl = $baseUrl.TrimEnd('/')

# ── actor resolution: explicit creds → git config → username/hostname ──────
$actorName = $creds['ROGUE_ACTOR_NAME']
if (-not $actorName) { try { $actorName = (& git config --global user.name 2>$null | Out-String).Trim() } catch {} }
if (-not $actorName) { $actorName = $env:USERNAME }

$actorEmail = $creds['ROGUE_ACTOR_EMAIL']
if (-not $actorEmail) { try { $actorEmail = (& git config --global user.email 2>$null | Out-String).Trim() } catch {} }
if (-not $actorEmail) {
    if ($env:USERNAME -and $env:COMPUTERNAME) { $actorEmail = "$($env:USERNAME)@$($env:COMPUTERNAME)" }
    elseif ($env:USERNAME) { $actorEmail = $env:USERNAME }
    else { $actorEmail = $env:COMPUTERNAME }
}

# ── payload from stdin ─────────────────────────────────────────────────────
$payload = [Console]::In.ReadToEnd()
if (-not $payload) { $payload = '{}' }
# Cursor sends a UTF-8 payload, but the console often reads stdin under a legacy
# OEM codepage (observed in the field: IBM437), which mojibakes it — e.g. the
# leading UTF-8 BOM (bytes EF BB BF) decodes to "∩╗┐", not a single U+FEFF.
# Chasing per-codepage code points is futile, so instead round-trip the string
# back through the ACTUAL input encoding to recover the original bytes, then
# decode them as real UTF-8. CP437↔Unicode is a bijection, so this also fully
# recovers any non-ASCII prompt text. No-op when the console is already UTF-8.
Dbg "InputEncoding=$([Console]::InputEncoding.WebName) CP=$([Console]::InputEncoding.CodePage)"
try {
    $raw = [Console]::InputEncoding.GetBytes($payload)
    $payload = [System.Text.Encoding]::UTF8.GetString($raw)
} catch { Dbg "utf8 re-decode failed: $($_.Exception.Message)" }

# After re-decoding, a UTF-8 BOM is a single U+FEFF char. Strip it: a
# BOM-prefixed body is invalid JSON and the API rejects it with HTTP 400.
$payload = $payload.TrimStart([char]0xFEFF)

# Repair Cursor's UTF-8 -> CP1252 -> UTF-8 double-encoding of assistant text,
# which happens on clients with a non-UTF-8 Windows locale (out of our control).
$payload = Repair-DoubleEncodedUtf8 $payload

# ── POST (fail-open) ───────────────────────────────────────────────────────
$headers = @{
    'x-rogue-api-key'     = $apiKey
    'x-rogue-event'       = $EventName
    'x-rogue-actor-email' = $actorEmail
    'x-rogue-actor-name'  = $actorName
    'x-rogue-source'      = 'cursor'
}

$url = "$baseUrl/api/v1/hooks/cursor"
Dbg "POST $url actor=$actorEmail"
# Send an explicit UTF-8 byte array: Windows PowerShell 5.1's Invoke-WebRequest
# re-encodes a string body (commonly to Latin-1), which corrupts non-ASCII
# prompt content and can reintroduce a BOM. GetBytes() never emits a BOM.
$bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
$resp = ''
$postError = ''
try {
    $r = Invoke-WebRequest -Uri $url -Method Post `
        -Headers $headers -ContentType 'application/json' -Body $bodyBytes `
        -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
    Dbg "HTTP $($r.StatusCode), body length $($r.Content.Length)"
    if ($r.StatusCode -eq 200) {
        # Decode the body explicitly as UTF-8. Invoke-WebRequest's .Content
        # mis-decodes as ISO-8859-1 when the server omits a charset, turning
        # UTF-8 punctuation (— ') into mojibake (â€" â€™). RawContentStream
        # holds the original bytes.
        try { $resp = [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) }
        catch { $resp = [string]$r.Content }
    }
} catch {
    Dbg "POST failed: $($_.Exception.Message)"
    # On a 4xx/5xx the body usually explains why; surface it under ROGUE_DEBUG.
    # PS7 stashes it in ErrorDetails.Message; PS5.1 needs the response stream.
    $errBody = $null
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
        $errBody = $_.ErrorDetails.Message
    } elseif ($_.Exception.Response) {
        try {
            $stream = $_.Exception.Response.GetResponseStream()
            $sr = New-Object System.IO.StreamReader($stream)
            $errBody = $sr.ReadToEnd(); $sr.Close()
        } catch {}
    }
    if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
        Dbg "error status: $([int]$_.Exception.Response.StatusCode)"
    }
    if ($errBody) { Dbg "error response body: $errBody" }
    $postError = $_.Exception.Message
    $resp = ''
}

# Exactly one line per invocation, always, so a relay/decision bug is
# diagnosable from the hook log alone without re-instrumenting the script
# (mirrors hook.sh's `log "rc=… raw=…"`). An empty `raw=` means fail-open: either
# the request threw (then `error=` says why) or the server answered non-200.
$respHead = if ($resp.Length -gt 400) { $resp.Substring(0, 400) } else { $resp }
if ($postError) { Log "raw=$(Sanitize $respHead) error=`"$(Sanitize $postError)`"" }
else            { Log "raw=$(Sanitize $respHead)" }

Emit-Json $resp

# ── presence heartbeat (sessionStart only) ──────────────────────────────────
# POSTs /api/v1/hooks/status so this install shows in the dashboard's Coding
# Agents roster (Connected / version / host / user). Pure side-effect: response
# ignored, fully wrapped so it can never affect the already-emitted hook
# response. Runs AFTER Emit-Json; PowerShell has no reliable fire-and-forget
# across process exit, so this is a sync POST (10s cap) on sessionStart only.
# Creds/actor were already resolved above.
if ($EventName -eq 'sessionStart') {
    try {
        # Plugin version from the manifest.
        $hbVer = 'unknown'
        $hbPj = Join-Path $pluginRoot '.cursor-plugin/plugin.json'
        if (Test-Path -LiteralPath $hbPj) {
            try {
                $v = (Get-Content -Raw -LiteralPath $hbPj | ConvertFrom-Json).version
                if ($v -match '^[0-9]+\.[0-9]+\.[0-9]+') { $hbVer = $Matches[0] }
            } catch { Dbg "plugin.json parse failed: $($_.Exception.Message)" }
        }
        $hbHost = $env:COMPUTERNAME
        if (-not $hbHost) { $hbHost = 'unknown' }

        # `agent` is "cursor" (not a display label): the server keys its
        # latest-version lookup (PLUGIN_REPOS) on this value, so the roster can
        # flag outdated installs.
        $hbBody = @{
            agent_family = 'cursor'
            agent        = 'cursor'
            version      = $hbVer
            host         = $hbHost
            actor_email  = $actorEmail
            actor_name   = $actorName
        } | ConvertTo-Json -Compress

        $hbHeaders = @{
            'x-rogue-api-key' = $apiKey
            'x-rogue-source'  = 'cursor'
        }
        $hbUrl = "$baseUrl/api/v1/hooks/status"
        Dbg "heartbeat POST $hbUrl ver=$hbVer host=$hbHost"
        $hbBytes = [System.Text.Encoding]::UTF8.GetBytes($hbBody)
        $r = Invoke-WebRequest -Uri $hbUrl -Method Post `
            -Headers $hbHeaders -ContentType 'application/json' -Body $hbBytes `
            -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        Dbg "heartbeat HTTP $($r.StatusCode)"
        Log "heartbeat=$($r.StatusCode) ver=$hbVer"
    } catch {
        Dbg "heartbeat POST failed: $($_.Exception.Message)"
        Log "heartbeat=fail ver=$hbVer error=`"$(Sanitize $_.Exception.Message)`""
    }
}

exit 0
