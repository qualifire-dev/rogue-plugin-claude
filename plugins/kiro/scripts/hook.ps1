# Rogue Security hook bridge for Kiro (IDE, CLI, Crew) - PowerShell implementation.
#
# Windows sibling of hook.sh. The installer writes the hook command as
#   powershell -NoProfile -ExecutionPolicy Bypass -File <root>\scripts\hook.ps1 <hookEvent> <surface>
# so this runs as a FILE ($PSScriptRoot is set) and must stay Windows PowerShell
# 5.1-compatible: Kiro does not ship pwsh 7.
#
# Reads one Kiro hook event JSON on stdin, POSTs it to /api/v1/hooks/kiro, and
# translates Rogue's decision into Kiro's NATIVE form, which is the exit code:
#
#   PreToolUse block         exit 2, reason on stderr, EMPTY stdout
#   UserPromptSubmit block   exit 0, {"decision":"block","reason":...} on stdout
#   Stop                     exit 0, empty stdout - ALWAYS (a block on Stop tells
#                            Kiro to keep working)
#   everything else          exit 0, empty stdout
#
# FAIL-OPEN IS SAFETY-CRITICAL: exit 2 is a hard deny, and stdout can be injected
# into the model's context, so on ANY error (missing key, network failure,
# timeout, non-200, empty body, an exception anywhere) this exits 0 with an
# empty stdout. $ErrorActionPreference is SilentlyContinue for that reason.
#
# Credential resolution (later file wins; process env wins over all):
#   1. <root>\env                (baked into a compiled customer plugin)
#   2. C:\ProgramData\rogue\env  (MDM-provisioned; mirrors /etc/rogue/env)
#   3. %USERPROFILE%\.rogue-env  (user / installer-written)

param([string]$EventName = '', [string]$Surface = '', [string]$PluginRoot = '')

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

function Write-Raw {
    param([string]$Text)
    if (-not $Text) { return }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $stdout = [Console]::OpenStandardOutput()
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Flush()
}
function Dbg { param([string]$Msg) if ($env:ROGUE_DEBUG) { [Console]::Error.WriteLine("[rogue] $Msg") } }

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

# -- logging -----------------------------------------------------------------
# ONE FILE PER AGENT (mirrors hook.sh): %USERPROFILE%\.rogue\logs\kiro.log.
# Precedence: ROGUE_LOG_FILE -> ROGUE_LOG_DIR\kiro.log -> default, each read from
# the merged credential map so an env file can relocate the log. $HOME backs up
# USERPROFILE so this can be dot-sourced on macOS/Linux through the
# ROGUE_PS_LIB_ONLY seam (tests).
# The surface is an install-time argument resolved in the main body; the
# file-scope default is empty so a probe through the seam emits no token.
$script:surface = ''
$script:logFile = $null
$script:logMaxBytes = 10485760

function Initialize-Logging {
    param([hashtable]$Creds = @{})
    $f = $Creds['ROGUE_LOG_FILE']
    if (-not $f) {
        $d = $Creds['ROGUE_LOG_DIR']
        if (-not $d) {
            $userHome = $env:USERPROFILE
            if (-not $userHome) { $userHome = $HOME }
            if ($userHome) { $d = Join-Path (Join-Path $userHome '.rogue') 'logs' }
        }
        if ($d) { $f = Join-Path $d 'kiro.log' }
    }
    $script:logFile = $f
    # Size cap: numeric zero disables rotation, a non-numeric or oversized value
    # falls back to the default (TryParse, not a cast, so an int64 overflow is a
    # stated fallback rather than a swallowed error).
    $cap = $Creds['ROGUE_LOG_MAX_BYTES']
    $capValue = [int64]0
    if ($cap -match '^[0-9]+$' -and [int64]::TryParse($cap, [ref]$capValue)) { $script:logMaxBytes = $capValue }
    else { $script:logMaxBytes = 10485760 }
}

function Sanitize { param([string]$S) if ($null -eq $S) { return '' } ($S -replace '[\x00-\x1f\x7f]', '') }

function Rotate-Log {
    if (-not $logFile -or $logMaxBytes -le 0) { return }
    try {
        $fi = Get-Item -LiteralPath $logFile -ErrorAction SilentlyContinue
        if ($fi -and $fi.Length -ge $logMaxBytes) {
            # Delete the previous generation first: Move-Item -Force onto an
            # EXISTING destination is not reliable on Windows PowerShell 5.1.
            Remove-Item -LiteralPath "$logFile.1" -Force -ErrorAction SilentlyContinue
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
        # BOM-less UTF-8 via AppendAllText: Add-Content -Encoding UTF8 writes a BOM
        # on create under 5.1, which breaks any parser anchored on the timestamp.
        $surfaceToken = if ($script:surface) { " surface=$($script:surface)" } else { '' }
        [System.IO.File]::AppendAllText(
            $logFile,
            "$stamp provider=kiro$surfaceToken event=$EventName $Msg`n",
            (New-Object System.Text.UTF8Encoding $false))
    } catch {}
}

# -- Kiro translation helpers (pure; unit-tested through the seam) -----------

# The canonical hook event, as the route's monitored/blocking tables spell it.
# The 2.x engine names the same events in camelCase (SessionStart is agentSpawn
# there). Unrecognised names pass through verbatim.
function ConvertTo-KiroEvent {
    param([string]$Name)
    switch -CaseSensitive ($Name) {
        'agentSpawn'       { return 'SessionStart' }
        'userPromptSubmit' { return 'UserPromptSubmit' }
        'preToolUse'       { return 'PreToolUse' }
        'postToolUse'      { return 'PostToolUse' }
        'stop'             { return 'Stop' }
    }
    return $Name
}

# A closed vocabulary; anything else is '' (no log token, kiro_cli on the wire).
function Get-KiroSurface {
    param([string]$Arg)
    if ($Arg -cin @('kiro_ide', 'kiro_cli', 'kiro_crew')) { return $Arg }
    return ''
}

# The 2.x engine sends no session_id in the body and exposes KIRO_SESSION_ID in
# the environment instead. Splice it in under the field the 3.0 engine uses,
# preserving the vendor's bytes (no re-serialisation). A body that already has
# the field, a value outside the bare token charset, or a body that is not an
# object comes back unchanged - fail-open to today's 2.x behaviour.
# "Already has the field" is a SUBSTRING check (no JSON parser here, in lockstep
# with hook.sh): a NESTED key of the same name skips the injection, which is the
# fail-open direction - the event is still recorded, without a session id.
# Prompt text cannot trip it: a quote inside a JSON string is escaped.
function Add-KiroSessionId {
    param([string]$Payload, [string]$SessionId)
    if (-not $Payload) { return $Payload }
    if ($Payload -match '"session_id"') { return $Payload }
    if (-not $SessionId -or $SessionId -notmatch '^[A-Za-z0-9_.:-]+$') { return $Payload }
    $body = $Payload.TrimEnd()
    if (-not $body.EndsWith('}')) { return $Payload }
    $pre = $body.Substring(0, $body.Length - 1).TrimEnd()
    $sep = if ($pre -eq '{') { '' } else { ',' }
    return $pre + $sep + '"session_id":"' + $SessionId + '"}'
}

# STRICT shape match: the pair, not the substrings, so an allow that carries
# "block" as some other field's value never trips it.
function Test-KiroBlock {
    param([string]$Resp)
    return [bool]($Resp -match '"decision"\s*:\s*"block"')
}

function Get-KiroBlockReason {
    param([string]$Resp)
    $reason = ''
    try {
        $obj = ConvertFrom-Json $Resp -ErrorAction Stop
        if ($obj -and $obj.reason) { $reason = [string]$obj.reason }
    } catch {
        if ($Resp -match '"reason"\s*:\s*"((?:[^"\\]|\\.)*)"') {
            $reason = $Matches[1] -replace '\\n', "`n" -replace '\\"', '"' -replace '\\\\', '\'
        }
    }
    if (-not $reason) { $reason = 'Blocked by Rogue Security' }
    return $reason
}

# The decision table, as one value: what to exit with, what to write where, and
# what to log. Allow and every failure are the zero row. The route already
# answers {} where a block cannot apply (Stop, UserPromptSubmit off the IDE);
# this is the second fence.
function Resolve-KiroOutcome {
    param([string]$Event, [string]$Resp)
    $o = @{ ExitCode = 0; Stdout = ''; Stderr = ''; Outcome = 'allow'; Note = '' }
    if (-not $Resp -or -not (Test-KiroBlock $Resp)) { return $o }
    switch -CaseSensitive ($Event) {
        'PreToolUse' {
            $o.ExitCode = 2
            $o.Stderr = Get-KiroBlockReason $Resp
            $o.Outcome = 'block'
        }
        'UserPromptSubmit' {
            $o.Stdout = $Resp
            $o.Outcome = 'block'
        }
        default {
            # Stop and every audit-only event: recorded, never enforced.
            $o.Note = 'decision=block'
        }
    }
    return $o
}

# Test seam: dot-sourcing with ROGUE_PS_LIB_ONLY=1 loads the functions above
# without running the bridge. Production never sets this.
if ($env:ROGUE_PS_LIB_ONLY) { return }

# Windows PowerShell 5.1 may negotiate only TLS 1.0/1.1 by default; add TLS 1.2.
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

# Stand down on non-Windows (Kiro runs hook.sh there; this guards a stray pwsh).
if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { exit 0 }

$EventName = ConvertTo-KiroEvent $EventName
$script:surface = Get-KiroSurface $Surface
$agent = if ($script:surface) { $script:surface } else { 'kiro_cli' }
Dbg "event=$EventName surface=$agent"

if (-not $PluginRoot -and $PSScriptRoot) { $PluginRoot = Split-Path -Parent $PSScriptRoot }
if (-not $PluginRoot) { $PluginRoot = $env:KIRO_PLUGIN_ROOT }
if (-not $PluginRoot) { try { $PluginRoot = (Get-Location).Path } catch { $PluginRoot = '.' } }

# -- credential resolution (later file wins; process env wins over all) -----
$creds = @{}
foreach ($f in @((Join-Path $PluginRoot 'env'), 'C:\ProgramData\rogue\env', (Join-Path $env:USERPROFILE '.rogue-env'))) {
    if (-not $f -or -not (Test-Path -LiteralPath $f)) { continue }
    foreach ($line in (Get-Content -LiteralPath $f)) {
        if ($line -match '^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.+)$') {
            $creds[$Matches[1]] = ConvertFrom-ShellQuoted ($Matches[2].Trim())
        }
    }
}
# ROGUE_LOG_* ride the same list so a process-env value still beats the files,
# which is what makes the resolved precedence identical to hook.sh's.
foreach ($k in 'ROGUE_API_KEY','ROGUE_ACTOR_EMAIL','ROGUE_ACTOR_NAME','ROGUE_BASE_URL','ROGUE_API_URL',
               'ROGUE_LOG_FILE','ROGUE_LOG_DIR','ROGUE_LOG_MAX_BYTES','ROGUE_HOOK_TIMEOUT') {
    $val = [Environment]::GetEnvironmentVariable($k); if ($val) { $creds[$k] = $val }
}

# After the credential files (so they can relocate the log), before the API-key
# check (so an unconfigured install still records outcome=unconfigured).
Initialize-Logging $creds
Dbg "logFile=$logFile cap=$logMaxBytes"

$apiKey = $creds['ROGUE_API_KEY']
if (-not $apiKey) {
    Log 'outcome=unconfigured'
    exit 0
}

$url = $creds['ROGUE_API_URL']
if (-not $url) {
    $baseUrl = $creds['ROGUE_BASE_URL']; if (-not $baseUrl) { $baseUrl = 'https://api.rogue.security' }
    $url = "$($baseUrl.TrimEnd('/'))/api/v1/hooks/kiro"
}

# curl budget in hook.sh; here the request timeout. The hook file gives the
# command 10s, so 8s leaves room without letting Kiro's own timeout be what
# fails us open. Zero falls back to the default: -TimeoutSec 0 means NO timeout.
$timeoutSec = 8
$t = $creds['ROGUE_HOOK_TIMEOUT']
if ($t -match '^[0-9]{1,9}$' -and [int]$t -gt 0) { $timeoutSec = [int]$t }

# -- actor resolution (mirrors actor.sh) -------------------------------------
$actorName = $creds['ROGUE_ACTOR_NAME']
if (-not $actorName) { try { $actorName = (& git config --global user.name 2>$null | Out-String).Trim() } catch {} }
if (-not $actorName) { $actorName = $env:USERNAME }

$actorEmail = $creds['ROGUE_ACTOR_EMAIL']
if (-not $actorEmail) { try { $actorEmail = (& git config --global user.email 2>$null | Out-String).Trim() } catch {} }
if (-not $actorEmail) {
    if ($env:USERNAME -and $env:COMPUTERNAME) { $actorEmail = "$($env:USERNAME)@$($env:COMPUTERNAME)" }
    elseif ($env:USERNAME) { $actorEmail = $env:USERNAME } else { $actorEmail = $env:COMPUTERNAME }
}

# -- payload from stdin (recover UTF-8, strip BOM), then the 2.x session id ---
$payload = [Console]::In.ReadToEnd()
if (-not $payload) { $payload = '{}' }
try {
    $raw = [Console]::InputEncoding.GetBytes($payload)
    $payload = [System.Text.Encoding]::UTF8.GetString($raw)
} catch {}
$payload = $payload.TrimStart([char]0xFEFF)
$payload = Add-KiroSessionId $payload $env:KIRO_SESSION_ID

# -- install identity: host + version (mirrors install-id.sh) ----------------
$installError = @()
$hostName = $env:COMPUTERNAME
if (-not $hostName) { try { $hostName = [System.Net.Dns]::GetHostName() } catch { $hostName = '' } }
if (-not $hostName) { $hostName = 'unknown'; $installError += 'host-unresolved' }

$pluginVersion = 'unknown'
$pluginJson = Join-Path $PluginRoot 'plugin.json'
if (Test-Path -LiteralPath $pluginJson) {
    $m = [regex]::Match((Get-Content -Raw -LiteralPath $pluginJson), '"version"\s*:\s*"([0-9]+\.[0-9]+\.[0-9]+)')
    if ($m.Success) { $pluginVersion = $m.Groups[1].Value }
    else { $installError += "version-unparsed:$pluginJson" }
} else {
    $installError += "manifest-missing:$pluginJson"
}
if ($installError.Count) { Log "error=install-id $($installError -join ',')" }

# -- presence heartbeat (SessionStart unthrottled, Stop throttled) ------------
# Detached; heartbeat.ps1 takes the surface and the trigger, as heartbeat.sh does.
if ($EventName -eq 'SessionStart' -or $EventName -eq 'Stop') {
    $hb = Join-Path $PluginRoot 'scripts\heartbeat.ps1'
    if (Test-Path -LiteralPath $hb) {
        try {
            Start-Process -FilePath 'powershell' -WindowStyle Hidden `
                -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$hb,$agent,$EventName | Out-Null
        } catch { Dbg "heartbeat spawn failed: $($_.Exception.Message)" }
    }
}

# -- POST (fail-open) --------------------------------------------------------
$headers = @{
    'x-rogue-api-key'     = $apiKey
    'x-rogue-event'       = $EventName
    'x-rogue-agent'       = $agent
    'x-rogue-host'        = $hostName
    'x-rogue-version'     = $pluginVersion
    'x-rogue-actor-email' = $actorEmail
    'x-rogue-actor-name'  = $actorName
}
$bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
$resp = ''
$code = '000'
try {
    $r = Invoke-WebRequest -Uri $url -Method Post `
        -Headers $headers -ContentType 'application/json' -Body $bodyBytes `
        -UseBasicParsing -TimeoutSec $timeoutSec -ErrorAction Stop
    $code = [string]$r.StatusCode
    if ($r.StatusCode -eq 200) {
        try { $resp = [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) }
        catch { $resp = [string]$r.Content }
    }
} catch { Dbg "POST failed: $($_.Exception.Message)"; $resp = '' }

# -- translate, log ONE line, answer Kiro -------------------------------------
$o = Resolve-KiroOutcome $EventName $resp
$respHead = if ($resp.Length -gt 400) { $resp.Substring(0, 400) } else { $resp }
$note = if ($o.Note) { " $($o.Note)" } else { '' }
Log "outcome=$($o.Outcome)$note http=$code raw=$(Sanitize $respHead)"

if ($o.Stdout) { Write-Raw $o.Stdout }
if ($o.Stderr) { [Console]::Error.WriteLine($o.Stderr) }
exit $o.ExitCode
