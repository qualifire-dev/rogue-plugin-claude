#!/usr/bin/env pwsh
# END-TO-END test for the WINDOWS shipper: the real ship-logs.ps1 main body, real
# Invoke-WebRequest, real Windows file reads, a real HTTP server
# (tests/e2e_receiver.mjs), and a `cmp` of the file on disk against the file the
# server rebuilt from the wire. The sh equivalent is tests/e2e_ship_logs.sh.
#
#   pwsh -NoProfile -File tests/e2e_ship_logs.ps1
#
# WHY THIS EXISTS, given tests/test_ship_logs.ps1 already covers the .ps1: that suite
# loads the script through the ROGUE_PS_LIB_ONLY seam and calls its helpers on a
# Linux runner. It therefore covers the parser, the state machine and the caller
# wiring, but NEVER the main body - Invoke-Main stands down on non-Windows before it
# reaches Import-ShipEnv, Invoke-WebRequest, the state directory under %USERPROFILE%,
# or the child process the heartbeat spawns. Everything unique to the Windows runtime
# was consequently unexecuted anywhere in CI, on the half of the feature that cannot
# be run on a dev Mac. That gap is what this file closes, so it MUST run on
# windows-latest; on any other platform it is a SKIP, because the script it tests
# deliberately exits 0 there.
#
# %USERPROFILE% is redirected into a sandbox, so the developer's real ~/.rogue,
# ~/.rogue-env and ~/.rogue/ship are never read or written.

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$failures = 0

function Pass { param([string]$M) Write-Host "  ok: $M" }
function Fail { param([string]$M) Write-Host "FAIL: $M"; $script:failures++ }
function Check {
    param([string]$Label, [string]$Expected, [string]$Actual)
    if ($Expected -eq $Actual) { Pass $Label } else { Fail "$Label (expected [$Expected], got [$Actual])" }
}

if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
    Write-Host 'SKIP: ship-logs.ps1 stands down on non-Windows - this suite needs windows-latest.'
    exit 0
}
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Host 'SKIP: node not found (the receiver needs it).'
    exit 0
}

# Scrub every knob the shipper reads from the environment. NOT optional hygiene: a
# developer running this may well have ROGUE_API_KEY set for their own install, and
# PROCESS ENV WINS over the env file by design - so without this the sandbox would
# authenticate to the local receiver with real credentials. The sh suite learned this
# the hard way; same reasoning, same fix.
foreach ($knob in @('ROGUE_API_KEY', 'ROGUE_BASE_URL', 'ROGUE_ACTOR_EMAIL', 'ROGUE_ACTOR_NAME',
                    'ROGUE_LOG_FILE', 'ROGUE_LOG_DIR', 'ROGUE_LOG_MAX_BYTES', 'ROGUE_SHIP_LOGS',
                    'ROGUE_SHIP_MIN_INTERVAL', 'ROGUE_SHIP_MAX_BYTES', 'ROGUE_SHIP_MAX_RUN_BYTES',
                    'ROGUE_SHIP_MAX_LINE_BYTES', 'ROGUE_SHIP_ALL', 'ROGUE_DEBUG')) {
    Remove-Item "Env:$knob" -ErrorAction SilentlyContinue
}

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("rogue-e2eps-" + [System.Guid]::NewGuid().ToString('N'))
$recvDir = Join-Path $sandbox 'recv'
$sandboxHome = Join-Path $sandbox 'home'
New-Item -ItemType Directory -Path $recvDir -Force | Out-Null
New-Item -ItemType Directory -Path $sandboxHome -Force | Out-Null

$realUserProfile = $env:USERPROFILE
$env:USERPROFILE = $sandboxHome
$receiver = $null

try {

# ── the receiver ───────────────────────────────────────────────────────────
# E2E_API_KEY through the inherited environment, not Start-Process -Environment,
# which is PowerShell 7.4+ only and would make this suite fail on an older pwsh
# instead of testing anything.
$env:E2E_API_KEY = 'e2e-key'
$receiver = Start-Process -FilePath 'node' `
    -ArgumentList @((Join-Path $repo 'tests/e2e_receiver.mjs'), $recvDir) `
    -PassThru -NoNewWindow `
    -RedirectStandardOutput (Join-Path $sandbox 'recv.out') `
    -RedirectStandardError (Join-Path $sandbox 'recv.err')

# Poll for the port file rather than sleeping a fixed amount: a fixed sleep is either
# slower than needed or flaky on a loaded runner, and both are avoidable.
$portFile = Join-Path $recvDir 'port'
$port = ''
for ($i = 0; $i -lt 100; $i++) {
    if (Test-Path -LiteralPath $portFile) {
        $port = (Get-Content -Raw -LiteralPath $portFile).Trim()
        if ($port) { break }
    }
    Start-Sleep -Milliseconds 100
}
if (-not $port) { throw "the receiver never wrote a port file (see $sandbox\recv.err)" }
$baseUrl = "http://127.0.0.1:$port"
Pass "the receiver is listening on $port"

# ── helpers ────────────────────────────────────────────────────────────────
$envelopeFile = Join-Path $recvDir 'envelopes.jsonl'
function Envelopes {
    if (-not (Test-Path -LiteralPath $envelopeFile)) { return 0 }
    return @(Get-Content -LiteralPath $envelopeFile | Where-Object { $_ -match '"kind":"logs"' }).Count
}
function LastEnvelopeField {
    param([string]$Field)
    if (-not (Test-Path -LiteralPath $envelopeFile)) { return '' }
    $line = @(Get-Content -LiteralPath $envelopeFile | Where-Object { $_ -match '"kind":"logs"' })[-1]
    if ($line -match ('"' + [regex]::Escape($Field) + '":"([^"]*)"')) { return $Matches[1] }
    if ($line -match ('"' + [regex]::Escape($Field) + '":([0-9]+)')) { return $Matches[1] }
    return ''
}
# Runs one of the product's .ps1 files in a CHILD powershell and waits for it.
# Nothing here may be run in-process: ship-logs.ps1 and heartbeat.ps1 both end in
# `exit 0`, which in-process terminates the CALLER - see the note on Invoke-Shipper.
# Every value travels as an environment variable and the command itself is a
# constant, so there is no interpolation to escape; -EncodedCommand because
# Start-Process's -ArgumentList quoting is unreliable on Windows PowerShell 5.1.
function Invoke-ProductScript {
    param([string]$RelativePath, [string]$ArgumentTail = '')
    $env:ROGUE_E2E_SCRIPT = Join-Path $repo $RelativePath
    $inner = '& ([scriptblock]::Create((Get-Content -Raw -LiteralPath $env:ROGUE_E2E_SCRIPT)))'
    if ($ArgumentTail) { $inner += ' ' + $ArgumentTail }
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($inner))
    return Start-Process -FilePath 'powershell' `
        -ArgumentList '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded `
        -NoNewWindow -PassThru -Wait
}

# ROGUE_SHIP_LOGS=1 on every run: shipping is OPT-IN until /api/v1/hooks/logs is
# deployed, so without it every case here would pass vacuously against a shipper that
# did nothing. The default itself is asserted once, on its own, below.
#
# A CHILD PROCESS, never in-process, for the same reason the heartbeats spawn one:
# ship-logs.ps1's Invoke-Main ends in `exit 0`, which in-process terminates the
# CALLER. The first version of this file ran it in-process and silently exited 0
# half way through, after two passing checks and with no error and no failure count -
# the run just stopped. That is precisely the hazard the callers document, so
# reproducing it here would have made the suite lie about its own coverage.
# Still loaded through [scriptblock]::Create, exactly as hooks.json and the
# heartbeats load it, so ExecutionPolicy/GPO cannot be what makes this pass or fail.
function Invoke-Shipper {
    param([hashtable]$Extra = @{})
    $env:ROGUE_BASE_URL = $baseUrl
    $env:ROGUE_SHIP_MIN_INTERVAL = '0'
    $env:ROGUE_SHIP_LOGS = '1'
    foreach ($k in $Extra.Keys) { Set-Item "Env:$k" $Extra[$k] }
    # Waited on, unlike the heartbeat's detached spawn: every assertion below is about
    # what the run produced, so the run has to be over.
    $env:ROGUE_E2E_ROOT = Join-Path $repo 'plugins/rogue'
    $child = Invoke-ProductScript 'plugins/rogue/scripts/ship-logs.ps1' '$env:ROGUE_E2E_ROOT claude 9.9.9 claude'
    if ($child.ExitCode -ne 0) { Fail "the shipper exited $($child.ExitCode) (it must always exit 0)" }
    foreach ($k in $Extra.Keys) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
}
$logDir = Join-Path (Join-Path $sandboxHome '.rogue') 'logs'
$logFile = Join-Path $logDir 'claude.log'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$lineNumber = 0
function Add-LogLines {
    param([int]$Count = 1)
    for ($i = 0; $i -lt $Count; $i++) {
        $script:lineNumber++
        [System.IO.File]::AppendAllText($logFile,
            ("2026-08-12T00:00:00Z provider=claude event=PreToolUse outcome=allow n=$($script:lineNumber)`n"),
            (New-Object System.Text.UTF8Encoding($false)))
    }
}

# ── credentials, written by the product's own setup script ──────────────────
Write-Host ''
Write-Host '== setup.ps1 writes credentials the shipper can read'
# The product's own script, not a hand-rolled file: its quoting is exactly what
# Import-ShipEnv has to parse back, and that round trip is part of what is under test.
Invoke-ProductScript 'plugins/rogue/scripts/setup.ps1' 'e2e-key amos@rogue.security amos' | Out-Null
Check 'setup.ps1 wrote %USERPROFILE%\.rogue-env' 'True' `
    ([string](Test-Path -LiteralPath (Join-Path $sandboxHome '.rogue-env')))

# ── a first run ships the whole file, byte-exactly ─────────────────────────
Write-Host ''
Write-Host '== the real main body uploads the log over real HTTP'
Add-LogLines 5
$fileBytes = (Get-Item -LiteralPath $logFile).Length
Invoke-Shipper
Check 'one envelope arrived' '1' ([string](Envelopes))
Check 'it reports the basename only' 'claude.log' (LastEnvelopeField 'log_file')
Check 'it starts at offset 0'        '0'          (LastEnvelopeField 'offset')
Check 'it carries the whole file'    ([string]$fileBytes) (LastEnvelopeField 'bytes')
Check 'the actor came from the env file' 'amos@rogue.security' (LastEnvelopeField 'actor_email')
# The property a stubbed transport cannot check: the bytes the server rebuilt from
# content_b64 are the bytes on disk. A CRLF slip, a BOM, or an Invoke-WebRequest that
# re-encodes the body would all show up here and nowhere else.
$reassembled = Join-Path $recvDir 'reassembled-claude.log'
Check 'the server rebuilt the file byte-exactly' `
    ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($logFile))) `
    ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($reassembled)))

# ── nothing new means no request at all ────────────────────────────────────
Write-Host ''
Write-Host '== an idle machine makes no request'
$before = Envelopes
Invoke-Shipper
Check 'a run with nothing new uploads nothing' ([string]$before) ([string](Envelopes))

# ── an append ships only the new bytes ─────────────────────────────────────
Write-Host ''
Write-Host '== an append ships only the new bytes'
$offsetBefore = $fileBytes
Add-LogLines 2
Invoke-Shipper
Check 'one more envelope' ([string]($before + 1)) ([string](Envelopes))
Check 'starting at the previous offset' ([string]$offsetBefore) (LastEnvelopeField 'offset')
Check 'and the rebuilt file still matches disk' `
    ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($logFile))) `
    ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($reassembled)))

# ── the offset advances ONLY on 2xx, against a real non-2xx ────────────────
Write-Host ''
Write-Host '== a real HTTP 500 does not advance the offset'
# The receiver re-reads status_code per request, so this is a genuine failed
# round-trip rather than a stubbed return value - which is the only way to cover
# Invoke-WebRequest's own throw-on-non-2xx behaviour on Windows.
[System.IO.File]::WriteAllText((Join-Path $recvDir 'status_code'), '500')
$stateFile = Join-Path (Join-Path (Join-Path $sandboxHome '.rogue') 'ship') 'claude.state'
$offsetLine = (Get-Content -LiteralPath $stateFile | Where-Object { $_ -match '^offset=' })
Add-LogLines 2
Invoke-Shipper
Check 'the offset did not move on a 500' $offsetLine `
    ((Get-Content -LiteralPath $stateFile | Where-Object { $_ -match '^offset=' }) -join '')
Remove-Item -LiteralPath (Join-Path $recvDir 'status_code') -Force
Invoke-Shipper
Check 'the same range ships once the server recovers' `
    ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($logFile))) `
    ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($reassembled)))

# ── rotation ───────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '== a rotated generation is drained before the live file'
Add-LogLines 2                                    # written, not yet shipped…
Move-Item -LiteralPath $logFile -Destination "$logFile.1" -Force
Add-LogLines 2                                    # …and the new generation begins
$rotatedBefore = Envelopes
Invoke-Shipper
$after = Envelopes
if ($after -lt $rotatedBefore + 2) {
    Fail "expected a .1 chunk and a live chunk (got $($after - $rotatedBefore))"
} else {
    Pass 'both the .1 tail and the live file shipped'
    Check 'the live chunk starts at 0' '0' (LastEnvelopeField 'offset')
}

# ── shipping is OPT-IN ─────────────────────────────────────────────────────
Write-Host ''
Write-Host '== shipping is OPT-IN: no ROGUE_SHIP_LOGS uploads nothing'
Add-LogLines 2
$optInBefore = Envelopes
$env:ROGUE_BASE_URL = $baseUrl
$env:ROGUE_SHIP_MIN_INTERVAL = '0'
Remove-Item Env:ROGUE_SHIP_LOGS -ErrorAction SilentlyContinue
$env:ROGUE_E2E_ROOT = Join-Path $repo 'plugins/rogue'
Invoke-ProductScript 'plugins/rogue/scripts/ship-logs.ps1' '$env:ROGUE_E2E_ROOT claude 9.9.9 claude' | Out-Null
Check 'an opt-out install uploads nothing' ([string]$optInBefore) ([string](Envelopes))
Invoke-Shipper
Check 'and the same lines upload once opted in' ([string]($optInBefore + 1)) ([string](Envelopes))

# ── the REAL caller: heartbeat.ps1 spawns the shipper as a child process ───
Write-Host ''
Write-Host '== heartbeat.ps1 actually starts the shipper (a child process, not in-process)'
# The case tests/test_ship_logs.ps1 can only assert with a regex. Here the child is
# really spawned, really loads the script through [scriptblock]::Create, and really
# uploads - which is the only way to catch a -EncodedCommand quoting failure, a
# missing $env: hand-off, or a child that dies before its first request.
$callerHome = Join-Path $sandbox 'home2'
New-Item -ItemType Directory -Path (Join-Path (Join-Path $callerHome '.rogue') 'logs') -Force | Out-Null
$env:USERPROFILE = $callerHome
Invoke-ProductScript 'plugins/rogue/scripts/setup.ps1' "e2e-key caller@rogue.security 'Caller Person'" | Out-Null
[System.IO.File]::WriteAllText((Join-Path (Join-Path (Join-Path $callerHome '.rogue') 'logs') 'claude.log'),
    "2026-08-12T00:00:01Z provider=claude event=PreToolUse outcome=allow n=1`n",
    (New-Object System.Text.UTF8Encoding($false)))
$callerBefore = Envelopes
$env:CLAUDE_PLUGIN_ROOT = (Join-Path $repo 'plugins/rogue')
$env:CLAUDE_CODE_ENTRYPOINT = 'cli'
$env:ROGUE_BASE_URL = $baseUrl
$env:ROGUE_SHIP_MIN_INTERVAL = '0'
$env:ROGUE_SHIP_LOGS = '1'
Invoke-ProductScript 'plugins/rogue/scripts/heartbeat.ps1' | Out-Null
# The shipper is DETACHED by design, so poll for its upload instead of assuming it
# has finished by the time the heartbeat returns.
for ($i = 0; $i -lt 100; $i++) {
    if ((Envelopes) -gt $callerBefore) { break }
    Start-Sleep -Milliseconds 100
}
Check 'the heartbeat''s child uploaded the log' ([string]($callerBefore + 1)) ([string](Envelopes))
Check 'under the identity the heartbeat resolved, not a second cascade' `
    'caller@rogue.security' (LastEnvelopeField 'actor_email')
Check 'with the caller''s slug' 'claude' (LastEnvelopeField 'shipper')
Check 'reporting the plugin version, not "unknown"' 'False' `
    ([string]((LastEnvelopeField 'shipper_version') -eq 'unknown'))

# ── an unconfigured install ships nothing ──────────────────────────────────
Write-Host ''
Write-Host '== an unconfigured install ships nothing'
$noKeyHome = Join-Path $sandbox 'home3'
New-Item -ItemType Directory -Path (Join-Path (Join-Path $noKeyHome '.rogue') 'logs') -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path (Join-Path (Join-Path $noKeyHome '.rogue') 'logs') 'claude.log'),
    "2026-08-12T00:00:01Z provider=claude event=PreToolUse outcome=unconfigured`n",
    (New-Object System.Text.UTF8Encoding($false)))
$env:USERPROFILE = $noKeyHome
$unconfiguredBefore = Envelopes
Invoke-Shipper
Check 'no API key -> no upload' ([string]$unconfiguredBefore) ([string](Envelopes))

} finally {
    $env:USERPROFILE = $realUserProfile
    if ($receiver -and -not $receiver.HasExited) {
        try { $receiver.Kill() } catch {}
    }
    try { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

Write-Host ''
if ($failures -eq 0) {
    Write-Host 'All end-to-end Windows log-shipper tests passed.'
    exit 0
}
Write-Host "$failures failure(s)."
exit 1
