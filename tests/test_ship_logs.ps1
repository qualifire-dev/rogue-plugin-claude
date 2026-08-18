#!/usr/bin/env pwsh
# PowerShell half of the log-shipper contract test. The sh/Node half is
# tests/test_ship_logs.sh; design and rationale: docs/plugin-log-shipper.md.
#
# WHY THIS FILE EXISTS AT ALL: ship-logs.ps1 is the Windows half of the feature and
# cannot run on a dev Mac, so until this file was written it had ZERO coverage — and
# that gap cost a real bug. Its Send-OversizeLine fell through to
# `advanceBytes = maxLineBytes`, advancing the offset by a fixed window when no
# newline was found. That lands the offset MID-LINE, and every read after it is a
# fragment. The sh copy had already been fixed to stall instead; nothing compared
# the two, so Windows alone shipped corrupt chunks. The stall case below pins it.
#
# Runs on macOS/Linux: ship-logs.ps1 puts every pure helper above an
# `if ($env:ROGUE_PS_LIB_ONLY) { return }` seam and falls back from USERPROFILE to
# $HOME, which is what lets .github/workflows/validate.yml cover Windows-only code
# on a Linux runner.
#
# Three layers, because the main body (Invoke-Main) exits on non-Windows:
#   * behavioural  — call the helpers directly through the seam.
#   * cross-language — assert the helpers agree BYTE FOR BYTE with what
#     ship-logs.sh writes. All three implementations share ~/.rogue/ship/, so a
#     disagreement about `head=` or `path=` makes each shipper treat the other's
#     state as a different file and re-ship the whole log (duplicate data).
#   * structural   — assert the five callers actually invoke the shipper, with the
#     right slug/family, in a child process rather than in-process.
#
#   pwsh -NoProfile -File tests/test_ship_logs.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$failures = 0

function Pass { param([string]$M) Write-Host "  ok: $M" }
function Fail { param([string]$M) Write-Host "FAIL: $M"; $script:failures++ }
function Check {
    param([string]$Label, [string]$Expected, [string]$Actual)
    if ($Expected -eq $Actual) { Pass $Label } else { Fail "$Label (expected [$Expected], got [$Actual])" }
}

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("rogue-shipps-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null

try {

# ── load the helpers through the seam ──────────────────────────────────────
# Dot-sourced, so the functions land in THIS scope and $script:maxLineBytes etc.
# are writable from here — which is how the window-scan cases drive Find-LineEnd
# without running the dispatcher.
$env:ROGUE_PS_LIB_ONLY = '1'
. (Join-Path $repo 'scripts/shared/ship-logs.ps1')
Remove-Item Env:ROGUE_PS_LIB_ONLY -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '== the seam loads the helpers without running the shipper'
foreach ($fn in @('Get-TrailingFragmentLength', 'Get-FirstLineFingerprint', 'Find-LineEnd',
                  'Read-Range', 'Get-NormalizedPath', 'Get-NumberOrDefault',
                  'Test-FlagEnabled', 'Get-StateKeyForPath', 'ConvertFrom-ShellQuoted',
                  'Read-ShipState', 'Write-ShipState')) {
    Check "$fn is defined" 'True' ([string](Test-Path "function:$fn"))
}

# ── trailing fragment ──────────────────────────────────────────────────────
Write-Host ''
Write-Host '== a chunk never ends mid-line'
# The invariant the whole design protects: a chunk that ends mid-line becomes two
# corrupt records server-side. `a\nb\n` must yield 0 — the naive awk one-liner the
# sh side started with returned 1 here, which would have left the offset lagging
# one byte per run forever.
function Bytes { param([string]$S) [System.Text.Encoding]::UTF8.GetBytes($S) }
Check 'ends on a newline -> 0'        '0' ([string](Get-TrailingFragmentLength (Bytes "a`nb`n")))
Check 'no newline at all -> length'   '3' ([string](Get-TrailingFragmentLength (Bytes 'abc')))
Check 'partial last line -> its size' '2' ([string](Get-TrailingFragmentLength (Bytes "a`nbc")))
Check 'empty input -> 0'              '0' ([string](Get-TrailingFragmentLength (New-Object byte[] 0)))

# ── head fingerprint, and it must match sh byte for byte ───────────────────
Write-Host ''
Write-Host '== the head fingerprint is the first line INCLUDING its newline'
$headFile = Join-Path $sandbox 'head.log'
$line1 = "2026-08-12T00:00:01Z provider=claude event=PreToolUse outcome=allow n=1`n"
$line2 = "2026-08-12T00:00:02Z provider=claude event=PreToolUse outcome=allow n=2`n"
[System.IO.File]::WriteAllText($headFile, $line1 + $line2, (New-Object System.Text.UTF8Encoding($false)))
$expectedHead = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($line1))
Check 'base64 of line 1 with its \n' $expectedHead (Get-FirstLineFingerprint $headFile)
# Appending must NOT change it — logs are append-only, so once a newline exists at
# byte k, bytes 0..k are frozen. If the head moved, every append would look like a
# rotation and re-ship the file.
[System.IO.File]::AppendAllText($headFile, "3rd line with no newline", (New-Object System.Text.UTF8Encoding($false)))
Check 'appending does not change it' $expectedHead (Get-FirstLineFingerprint $headFile)
# No newline in the window -> "unknown" (''), and the caller then falls back to
# `size < offset` alone rather than guessing.
$noNl = Join-Path $sandbox 'nonewline.log'
[System.IO.File]::WriteAllText($noNl, 'no newline here', (New-Object System.Text.UTF8Encoding($false)))
Check 'a file with no newline -> unknown' '' (Get-FirstLineFingerprint $noNl)

# ── path normalisation (cross-language) ────────────────────────────────────
Write-Host ''
Write-Host '== path= is NORMALIZED, so all three implementations name a file identically'
# This is the bug the sh copy shipped: a bare $PWD-prefix left `/logs//claude.log`
# unequal to `/logs/claude.log`, so the sh and Node shippers read each other's
# state as a DIFFERENT FILE, reset the offset and re-shipped the whole log.
# GetFullPath collapses the same things path.resolve does; these pin that.
#
# NOT `if ($IsWindows)`: that automatic variable only exists in PowerShell 6+, so
# under Windows PowerShell 5.1 it is $null and this took the POSIX branch -- which
# then resolved `/logs//claude.log` against the current DRIVE and reported
# `D:\logs\claude.log`. Three failures that were purely the harness picking the wrong
# platform. Version first, then the variable.
$onWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
if ($onWindows) {
    Check 'a doubled separator collapses' 'C:\logs\claude.log' (Get-NormalizedPath 'C:\logs\\claude.log')
    Check 'a dot segment collapses'       'C:\logs\claude.log' (Get-NormalizedPath 'C:\logs\.\claude.log')
    Check 'a parent segment resolves'     'C:\claude.log'       (Get-NormalizedPath 'C:\logs\..\claude.log')
} else {
    Check 'a doubled separator collapses' '/logs/claude.log' (Get-NormalizedPath '/logs//claude.log')
    Check 'a dot segment collapses'       '/logs/claude.log' (Get-NormalizedPath '/logs/./claude.log')
    Check 'a parent segment resolves'     '/claude.log'      (Get-NormalizedPath '/logs/../claude.log')
}

# ── knob parsing ───────────────────────────────────────────────────────────
Write-Host ''
Write-Host '== a typo in a knob must never disable shipping or blow a cap'
Check 'non-numeric -> default'          '900' ([string](Get-NumberOrDefault 'abc' 900 1))
Check 'empty -> default'                '900' ([string](Get-NumberOrDefault '' 900 1))
Check 'negative -> default'             '900' ([string](Get-NumberOrDefault '-5' 900 1))
Check 'zero with allowZero -> zero'     '0'   ([string](Get-NumberOrDefault '0' 900 1))
Check 'zero without allowZero -> default' '1024' ([string](Get-NumberOrDefault '0' 1024 0))
Check 'a real value is kept'            '42'  ([string](Get-NumberOrDefault '42' 900 1))
# All digits, but too wide for an Int64. A plain [int64] cast raises here, and
# this file runs under SilentlyContinue, so the value would land $null and
# compare as smaller than every byte count it gates.
Check 'unrepresentable -> default'      '1024' ([string](Get-NumberOrDefault ('9' * 400) 1024 0))
# SHIPPING IS OPT-IN until /api/v1/hooks/logs is deployed, so the flag reads the
# other way round from every knob above: unset is OFF, and only a numeric non-zero
# value turns it on. Zero-padding counts as zero, matching phase 1's rotation cap,
# where '00' read as positive once and rotated the log on every single write.
Check 'ROGUE_SHIP_LOGS=1 opts in'      'True'  ([string](Test-FlagEnabled '1'))
Check 'unset does NOT ship'            'False' ([string](Test-FlagEnabled ''))
Check 'a typo is not an opt-in'        'False' ([string](Test-FlagEnabled 'yes'))
Check 'ROGUE_SHIP_LOGS=0 stays off'    'False' ([string](Test-FlagEnabled '0'))
Check 'a zero-padded 00 stays off'     'False' ([string](Test-FlagEnabled '00'))
# An env file's explicit 0 is a KILL SWITCH that an inline ROGUE_SHIP_LOGS=1 must not
# defeat - the one deliberate exception to "process env beats the files", because the
# documented support one-liner passes =1 inline and would otherwise re-enable uploading
# on a machine whose MDM profile or whose user had turned it off. Absent and
# non-numeric are "said nothing", or a typo in one line would disable it everywhere.
Check 'an explicit 0 is a kill switch'      'True'  ([string](Test-ValueIsZero '0'))
Check 'a zero-padded 00 is too'             'True'  ([string](Test-ValueIsZero '00'))
Check 'unset is not a kill switch'          'False' ([string](Test-ValueIsZero ''))
Check 'a typo is not a kill switch'         'False' ([string](Test-ValueIsZero 'yes'))
Check '1 is not a kill switch'              'False' ([string](Test-ValueIsZero '1'))
# The wiring, since Invoke-Main cannot run here: the flag has to be set per file while
# the files are read (the process-env pass overwrites the value), and checked before
# the opt-in test.
$psShipSource = Get-Content -Raw -LiteralPath (Join-Path $repo 'scripts/shared/ship-logs.ps1')
# Index comparison rather than one big regex: the assertion is about ORDER (the flag
# must be recorded while the files are read, BEFORE the process-env pass overwrites the
# value), and a windowed `[\s\S]{0,600}` match silently depends on comment length.
$zeroTestAt = $psShipSource.IndexOf("Test-ValueIsZero ([string]`$resolved['ROGUE_SHIP_LOGS'])")
$processPassAt = $psShipSource.IndexOf('$processValue = [Environment]::GetEnvironmentVariable($varName)')
Check 'Import-ShipEnv records the kill switch while reading the files' 'True' `
    ([string]($zeroTestAt -gt 0 -and $processPassAt -gt 0 -and $zeroTestAt -lt $processPassAt))
Check 'Invoke-Main checks it before the opt-in flag' 'True' ([string](
    $psShipSource -match '\$script:shipDisabledByFile\)\s*\{[\s\S]{0,400}?Test-FlagEnabled'))

# ── state key ──────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '== state is keyed by the log basename'
Check 'claude.log -> claude' 'claude' (Get-StateKeyForPath (Join-Path $sandbox 'claude.log'))
Check 'a name without .log is kept as-is' 'hook' (Get-StateKeyForPath (Join-Path $sandbox 'hook'))

# ── ranged reads ───────────────────────────────────────────────────────────
Write-Host ''
Write-Host '== ranged reads are exact, and a short read is not an error'
$rangeFile = Join-Path $sandbox 'range.bin'
[System.IO.File]::WriteAllBytes($rangeFile, (Bytes '0123456789'))
Check 'offset 0'            '01234' ([System.Text.Encoding]::UTF8.GetString((Read-Range $rangeFile 0 5)))
Check 'a mid-file offset'   '56789' ([System.Text.Encoding]::UTF8.GetString((Read-Range $rangeFile 5 5)))
Check 'past EOF is short, not an error' '789' ([System.Text.Encoding]::UTF8.GetString((Read-Range $rangeFile 7 99)))
# .Length INSIDE the inner parentheses. Outside them, [string] binds to the
# Read-Range result first, so the byte array is stringified and .Length is read from
# the STRING - which is 0 for an empty array AND 0 for the `, @()` one-element array
# this case exists to reject, so the assertion passed either way.
Check 'a zero count is an EMPTY array, not @(@())' '0' ([string]((Read-Range $rangeFile 0 0).Length))

# ── the line-end scan, and the stall that used to be an advance ────────────
Write-Host ''
Write-Host '== the line-end search spans windows and STALLS rather than land mid-line'
$script:maxLineBytes = 10
$longFile = Join-Path $sandbox 'long.log'
# 45 bytes, then a newline: more than four 10-byte windows, so finding it at all
# requires the scan to span them. A single-window probe returns "not found" here,
# which is what made the sh copy advance by a window and ship a fragment.
[System.IO.File]::WriteAllText($longFile, ('y' * 45) + "`n" + "next`n", (New-Object System.Text.UTF8Encoding($false)))
Find-LineEnd $longFile 0
Check 'the newline is found across windows' '46' ([string]$script:lineLength)
Check 'and it is not reported as EOF'       '0'  ([string]$script:lineSearchHitEof)

# An unterminated tail reports hitEof, NOT a length: on a live file that is a line
# still being written, and shipping half of it would be the fragment bug again.
$tailFile = Join-Path $sandbox 'tail.log'
[System.IO.File]::WriteAllText($tailFile, "done`nunterminated", (New-Object System.Text.UTF8Encoding($false)))
Find-LineEnd $tailFile 5
Check 'an unterminated tail reports EOF' '1' ([string]$script:lineSearchHitEof)
Check 'and reports no line length'       '0' ([string]$script:lineLength)

# The regression itself, asserted on the source: the exhausted-scan branch must NOT
# advance. A functional test would need a 256 MiB file, so this reads the code —
# which is the point, since the whole bug was one assignment nobody compared.
$shipSrc = Get-Content -Raw -LiteralPath (Join-Path $repo 'scripts/shared/ship-logs.ps1')
Check 'the exhausted scan logs outcome=stall' 'True' `
    ([string]($shipSrc -match 'outcome=stall reason=unbounded-line'))
Check 'and never advances by a whole window' 'True' `
    ([string](-not ($shipSrc -match '\$script:advanceBytes\s*=\s*\$script:maxLineBytes')))

# ── state round trip ───────────────────────────────────────────────────────
Write-Host ''
Write-Host '== state survives a round trip, and a moved file resets it'
$script:stateDir = $sandbox
Write-ShipState 'claude' 4096 $expectedHead 8192 '/logs/claude.log'
Read-ShipState 'claude' '/logs/claude.log'
Check 'offset round-trips' '4096' ([string]$script:offset)
Check 'head round-trips'   $expectedHead $script:stateHead
Check 'size round-trips'   '8192' ([string]$script:stateSize)
# The key is a BASENAME, so /a/claude.log and /b/claude.log key alike. Reading the
# state for a DIFFERENT path must reset rather than resume at a foreign offset —
# an MDM edit to ROGUE_LOG_DIR is exactly how that happens in the field.
Read-ShipState 'claude' '/other/claude.log'
Check 'a different path resets the offset' '0'  ([string]$script:offset)
Check 'and drops the stored head'          ''   $script:stateHead

# The state file must be plain LF text with no BOM — the sh shipper parses it with
# `case`/`${x#offset=}`, and a BOM would make the first key `\uFEFFoffset`, read as
# absent, silently re-shipping the file from 0 on every run.
$stateBytes = [System.IO.File]::ReadAllBytes((Join-Path $sandbox 'claude.state'))
$hasBom = ($stateBytes.Length -ge 3 -and $stateBytes[0] -eq 0xEF -and $stateBytes[1] -eq 0xBB -and $stateBytes[2] -eq 0xBF)
Check 'the state file has no UTF-8 BOM' 'False' ([string]$hasBom)
Check 'and uses LF, not CRLF'           'False' `
    ([string]([System.IO.File]::ReadAllText((Join-Path $sandbox 'claude.state')).Contains("`r")))

# ── identity ───────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '== an empty actor email canonicalises to anon, exactly as sh and Node do'
# This diverged silently: Resolve-ShipActor returned $false for an absent, empty or
# whitespace-only email, so a WINDOWS machine whose `git config user.email` is unset
# shipped nothing while the identical POSIX machine shipped under `anon` - and `anon`
# is the roster fingerprint's own fallback, so it is what joins the logs to the row the
# heartbeat created.
foreach ($case in @(
    @{ what = 'an empty email';           creds = @{ ROGUE_ACTOR_EMAIL = '' };    expect = 'anon' },
    @{ what = 'a whitespace-only email';  creds = @{ ROGUE_ACTOR_EMAIL = '   ' }; expect = 'anon' },
    @{ what = 'a real email';             creds = @{ ROGUE_ACTOR_EMAIL = 'a@b.c' }; expect = 'a@b.c' })) {
    $script:creds = $case.creds
    $script:actorEmail = ''
    Check "$($case.what) -> $($case.expect)" 'True' ([string](Resolve-ShipActor))
    Check "…and the value is $($case.expect)" $case.expect $script:actorEmail
}
# An identity that was never PASSED is a different thing from one resolved as empty:
# neither key present means the caller resolved nothing, which must still skip rather
# than invent `anon` for a machine we cannot name.
$script:creds = @{}
Check 'no actor key at all still skips' 'False' ([string](Resolve-ShipActor))

# ── the transport-failure code is three digits ─────────────────────────────
Write-Host ''
Write-Host '== a transport failure logs http=000, matching curl'
# `http=000` is the string both status documents tell an operator to look for. Left
# unformatted this logged `http=0` on Windows only, so the one token support greps for
# existed on one platform.
Check 'zero formats as 000' '000' ((0).ToString('000'))
Check 'a real status is unchanged' '401' ((401).ToString('000'))
Check 'Send-ChunkRequest formats it' 'True' ([string](
    $psShipSource -match 'http=" \+ \$httpCode\.ToString\(''000''\)'))

# ── diagnostics reach the operator with no log file ────────────────────────
Write-Host ''
Write-Host '== every logged outcome also reaches the debug stream'
# The no-argument support invocation has no slug, so $script:selfLogFile stays empty
# and Write-ShipLog returned before writing anything: `http=<code>` and
# `reason=no-actor` vanished on exactly the run support is told to make. Asserted
# structurally (Write-ShipDebug writes to [Console]::Error, which cannot be captured
# from in-process) and in ORDER — the call has to precede the selfLogFile gate.
$psSource = Get-Content -Raw -LiteralPath (Join-Path $repo 'scripts/shared/ship-logs.ps1')
Check 'Write-ShipLog debugs before the log-file gate' 'True' ([string](
    $psSource -match 'function Write-ShipLog[\s\S]{0,600}?Write-ShipDebug \$Message[\s\S]{0,200}?if \(-not \$script:selfLogFile\)'))

# ── the lock ───────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '== a marker-less lock is a LIVE lock, not a stale one'
# Creating the directory and writing `ts` are two operations, so a lock taken
# milliseconds ago legitimately has no marker yet. Reading that absence as stale let
# a second run delete a live lock, take it, and upload the same byte range twice.
# Only the directory's OWN age may reclaim an unmarked lock.
$script:stateDir = Join-Path $sandbox 'lockstate'
New-Item -ItemType Directory -Path $script:stateDir -Force | Out-Null
$lockPath = Join-Path $script:stateDir '.lock-claude'
New-Item -ItemType Directory -Path $lockPath -Force | Out-Null
$script:heldLockDir = ''
Check 'a fresh lock with no ts marker blocks' 'False' ([string](Lock-StateKey 'claude'))
(Get-Item -LiteralPath $lockPath).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(-2)
Check '…but an old one with no ts marker is reclaimed' 'True' ([string](Lock-StateKey 'claude'))
Unlock-StateKey
Check '…and released again' 'False' ([string](Test-Path -LiteralPath $lockPath))
# A readable marker still decides on its own, in both directions.
New-Item -ItemType Directory -Path $lockPath -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $lockPath 'ts'), ((Get-EpochSeconds).ToString() + "`n"))
Check 'a marked, fresh lock blocks'    'False' ([string](Lock-StateKey 'claude'))
[System.IO.File]::WriteAllText((Join-Path $lockPath 'ts'), (((Get-EpochSeconds) - 3600).ToString() + "`n"))
Check 'a marked, expired lock is taken' 'True'  ([string](Lock-StateKey 'claude'))
Unlock-StateKey

# ── the callers ────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '== every PowerShell caller actually starts the shipper'
# The feature was dead code until these calls existed: the shipper worked and
# nothing invoked it. One case per caller, asserting the slug and family it passes
# — those are ARGUMENTS precisely because slug and family diverge (codex ships
# codex.log under family openai), so a copy/paste of the wrong pair is silent.
$callers = @(
    @{ file = 'plugins/rogue/scripts/heartbeat.ps1';       slug = 'claude';      family = 'claude' }
    @{ file = 'plugins/codex/scripts/heartbeat.ps1';       slug = 'codex';       family = 'openai' }
    @{ file = 'plugins/copilot/scripts/heartbeat.ps1';     slug = 'copilot';     family = 'copilot' }
    @{ file = 'plugins/antigravity/scripts/heartbeat.ps1'; slug = 'antigravity'; family = 'antigravity' }
    @{ file = 'plugins/cursor/scripts/hook.ps1';           slug = 'cursor';      family = 'cursor' }
)
foreach ($caller in $callers) {
    $name = Split-Path $caller.file -Leaf
    $plugin = ($caller.file -split '/')[1]
    $src = Get-Content -Raw -LiteralPath (Join-Path $repo $caller.file)
    Check "$plugin/$name references ship-logs.ps1" 'True' ([string]($src -match 'ship-logs\.ps1'))
    Check "$plugin/$name passes slug $($caller.slug)" 'True' `
        ([string]($src -match ("ROGUE_SHIPPER_SLUG\s*=\s*'" + $caller.slug + "'")))
    Check "$plugin/$name passes family $($caller.family)" 'True' `
        ([string]($src -match ("ROGUE_SHIPPER_FAMILY\s*=\s*'" + $caller.family + "'")))
    # A CHILD PROCESS, not an in-process scriptblock. In-process, ship-logs.ps1's
    # own `$script:` writes resolve against the CALLER's scope (clobbering its
    # state) and its `exit 0` would end the caller instead of the shipper — which
    # in cursor/hook.ps1 means exiting before the relayed response is printed.
    Check "$plugin/$name starts it as a child process" 'True' `
        ([string]($src -match 'Start-Process'))
    # -EncodedCommand, and every value passed through the environment: Start-Process
    # -ArgumentList quoting is unreliable on Windows PowerShell 5.1, and a constant
    # command has no interpolation for a quote in a path or version to break out of.
    Check "$plugin/$name passes the command base64-encoded" 'True' `
        ([string]($src -match '-EncodedCommand'))
    # The actor is passed down, never re-resolved: the callers' cascades differ
    # (cursor ends at USERNAME@COMPUTERNAME, actor.sh at the hostname), so a second
    # cascade would key the log's source row differently from the roster row the
    # heartbeat just posted, and the logs would attach to nothing.
    Check "$plugin/$name passes the resolved actor down" 'True' `
        ([string]($src -match 'ROGUE_ACTOR_EMAIL\s*=\s*\[string\]'))
}

# ── the five copies are the same file ──────────────────────────────────────
Write-Host ''
Write-Host '== the five plugin copies match scripts/shared/ship-logs.ps1'
# Every per-plugin difference is an ARGUMENT, which is what lets this be a byte
# comparison instead of a review. scripts/shared/ is the only editable copy.
$canonical = [System.IO.File]::ReadAllBytes((Join-Path $repo 'scripts/shared/ship-logs.ps1'))
foreach ($plugin in @('rogue', 'codex', 'cursor', 'copilot', 'antigravity')) {
    $copyPath = Join-Path $repo "plugins/$plugin/scripts/ship-logs.ps1"
    if (-not (Test-Path -LiteralPath $copyPath)) { Fail "missing $copyPath"; continue }
    $copy = [System.IO.File]::ReadAllBytes($copyPath)
    if ([System.Linq.Enumerable]::SequenceEqual($canonical, $copy)) {
        Pass "$plugin/ship-logs.ps1 is in sync"
    } else {
        Fail "$plugin/scripts/ship-logs.ps1 is a stale copy - run scripts/sync-shared-scripts.sh"
    }
}

} finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failures -eq 0) {
    Write-Host 'All log-shipper PowerShell tests passed.'
    exit 0
}
Write-Host "$failures failure(s)."
exit 1
