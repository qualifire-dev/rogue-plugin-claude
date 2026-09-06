# Contract test for THE BEACON THROTTLE on the PowerShell side.
#
# The throttle itself lives in scripts/beacon.ps1 - a byte-identical copy of
# scripts/shared/beacon.ps1 carried by all five sh/PowerShell plugins - and is loaded
# by plugins/rogue/scripts/heartbeat.ps1. This suite exercises the REAL library
# through the real dispatcher, then pins the wiring of the other four plugins, which
# have no behavioural coverage off Windows.
#
# The PowerShell twin of tests/test_heartbeat_sh.sh. Both halves must agree case for
# case: a machine's beacon cadence must not depend on its operating system, and all
# six plugins write their stamps into ONE ~/.rogue/beacon directory, so a disagreement
# about the interval or the path is a disagreement about one file.
#
# Runs anywhere pwsh runs, including Linux CI, by dot-sourcing through the
# ROGUE_PS_LIB_ONLY seam - so the credential loading and the real POST below it
# never execute. Windows PowerShell 5.1 must also pass; keep the syntax 5.1-clean.
#
#   pwsh -File tests/test_heartbeat_ps1.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$script:fails = 0

function Check {
    param([string]$Label, $Expected, $Actual)
    if ($Expected -eq $Actual) { Write-Host "  ok: $Label" }
    else { Write-Host "FAIL: $Label (expected [$Expected], got [$Actual])"; $script:fails++ }
}

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("rogue-hbps-" + [guid]::NewGuid().ToString('N'))
$stamp = Join-Path (Join-Path (Join-Path $sandbox '.rogue') 'beacon') '.last-claude'
New-Item -ItemType Directory -Path (Split-Path -Parent $stamp) -Force | Out-Null

$pluginRoot = Join-Path $repo 'plugins/rogue'
$hbPath = Join-Path $pluginRoot 'scripts/heartbeat.ps1'

$saveProfile = $env:USERPROFILE
$saveInterval = $env:ROGUE_HEARTBEAT_MIN_INTERVAL
$saveLibOnly = $env:ROGUE_PS_LIB_ONLY
$saveRoot = $env:CLAUDE_PLUGIN_ROOT
$env:USERPROFILE = $sandbox
$env:ROGUE_PS_LIB_ONLY = '1'
# heartbeat.ps1 loads scripts/beacon.ps1 from this root, ABOVE the seam, so the suite
# exercises the library that actually ships rather than a stand-in.
$env:CLAUDE_PLUGIN_ROOT = $pluginRoot
# A TRAP, not configuration. The interval must come from the credential map; if the
# resolution ever regresses to reading $env: at file scope again, this zero reads as
# "throttle disabled" and every throttled case below fails loudly instead of the bug
# shipping silently to Windows a second time.
$env:ROGUE_HEARTBEAT_MIN_INTERVAL = '0'

# Independent of the implementation under test on purpose: this is the reference the
# assertions below compare the library's own arithmetic against, so it must not share
# its bugs. ToUnixTimeSeconds is unambiguous - no epoch literal to mis-Kind.
function Get-NowSeconds {
    return [int64][System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

# WriteAllText, not Set-Content, and Remove-Item -Force: the stamp's name begins
# with a dot, which PowerShell's provider treats as HIDDEN on Linux and macOS -
# Remove-Item without -Force silently refuses, which made a "no stamp" case read a
# leftover file and pass for the wrong reason while this suite was written.
function Set-Stamp { param($Value)
    if ($null -eq $Value) { Remove-Item -LiteralPath $stamp -Force -ErrorAction SilentlyContinue }
    else { [System.IO.File]::WriteAllText($stamp, "$Value`n") }
}

# Each case re-dot-sources, then resolves the interval the way the dispatcher does.
#
# $Interval arrives through the CREDENTIAL MAP, not $env:, because that is where the
# dispatcher reads it from - the map being the merged bundled env / MDM / per-user
# file chain. Feeding it through $env: here would test a path the fix deliberately
# removed, and would have passed against the bug it fixes.
#
# The parameter is deliberately NOT called $Trigger. heartbeat.ps1 declares
# `param([string]$Trigger = 'SessionStart')`, and dot-sourcing runs that param
# block in THIS function's scope - so a parameter of the same name is overwritten
# with 'SessionStart' before the call below ever reads it, and every throttled case
# silently tests the never-throttled trigger instead. PowerShell variable names are
# case-insensitive, so no spelling of it would have been safe. Same trap
# tests/log_probe.ps1 documents; it cost this suite four false passes.
#
# NOTE the inverted return: the library answers "may I send" where the old private
# helper answered "am I throttled". Kept as Throttled here so every case below still
# reads as the sh half's does.
function Throttled { param([string]$Which, [string]$Interval)
    $wanted = $Which   # snapshot BEFORE the dot-source, for the reason above
    $map = @{}
    if ($Interval -ne '') { $map['ROGUE_HEARTBEAT_MIN_INTERVAL'] = $Interval }
    . $hbPath
    Initialize-RogueBeacon $map
    return -not (Request-RogueBeaconSlot -Slug 'claude' -Unthrottled ($wanted -eq 'SessionStart'))
}

try {
    Write-Host "-- SessionStart is NEVER throttled ----------------------------------"
    Set-Stamp (Get-NowSeconds)
    Check "fires even with a fresh stamp" $false (Throttled 'SessionStart' '')

    Write-Host "-- Stop IS throttled ------------------------------------------------"
    Set-Stamp (Get-NowSeconds)
    Check "skipped inside the window" $true (Throttled 'Stop' '')
    Set-Stamp 0
    Check "fires once the window has elapsed" $false (Throttled 'Stop' '')
    Set-Stamp $null
    Check "fires when no stamp exists yet" $false (Throttled 'Stop' '')

    Write-Host "-- the interval knob ------------------------------------------------"
    Set-Stamp (Get-NowSeconds)
    Check "zero disables the throttle" $false (Throttled 'Stop' '0')
    Set-Stamp (Get-NowSeconds)
    Check "a padded zero counts as zero too" $false (Throttled 'Stop' '00')
    Set-Stamp (Get-NowSeconds)
    Check "a non-numeric value falls back to the default" $true (Throttled 'Stop' 'abc')
    Set-Stamp (Get-NowSeconds)
    # TryParse rather than a plain [int64] cast: the cast throws here, and although
    # SilentlyContinue would swallow it and leave the default standing, that is the
    # right answer reached by accident rather than by design.
    Check "a value too wide for int64 falls back to the default" $true `
        (Throttled 'Stop' '99999999999999999999999')
    Set-Stamp (Get-NowSeconds)
    Check "a small interval still throttles inside its window" $true (Throttled 'Stop' '3600')

    Write-Host "-- a stamp we cannot trust never silences the beacon ------------------"
    Set-Stamp 'not-a-number'
    Check "a corrupt stamp does not throttle" $false (Throttled 'Stop' '')
    Set-Stamp 99999999999
    Check "a stamp in the FUTURE does not throttle" $false (Throttled 'Stop' '')
    Set-Stamp ''
    Check "an empty stamp does not throttle" $false (Throttled 'Stop' '')

    Write-Host "-- the stamp is written, and only when the slot is claimed -----------"
    # Crash-loop guard as much as a rate limit: a beacon that hangs or dies must still
    # cost the next turn its attempt rather than retrying on every single one. And a
    # SKIPPED beacon must NOT stamp - that would push the window forward on every turn
    # and the beacon would never fire again.
    Set-Stamp $null
    [void](Throttled 'Stop' '')
    Check "a claimed slot leaves a stamp behind" $true (Test-Path -LiteralPath $stamp)
    $before = [System.IO.File]::ReadAllText($stamp)
    Set-Stamp (Get-NowSeconds)
    $held = [System.IO.File]::ReadAllText($stamp)
    [void](Throttled 'Stop' '3600')
    Check "a skipped beacon does not move the window" $held `
        ([System.IO.File]::ReadAllText($stamp))
    Check "the stamp holds an epoch-seconds integer" $true ($before.Trim() -match '^[0-9]+$')

    Write-Host "-- the two halves agree on where the stamp lives ---------------------"
    # A path mismatch would not fail any assertion above - each half would throttle
    # correctly against its own file - but a machine that ran both dispatchers would
    # beacon twice per window. The sh half builds ~/.rogue/beacon/.last-<slug>.
    . $hbPath
    $expected = Join-Path (Join-Path (Join-Path $sandbox '.rogue') 'beacon') '.last-claude'
    Check "the stamp path matches beacon.sh's" $expected (Get-RogueBeaconStampPath 'claude')
    $shSource = Get-Content -Raw (Join-Path $pluginRoot 'scripts/beacon.sh')
    Check "beacon.sh builds the same path" $true `
        ($shSource -match '\.rogue/beacon/\.last-\$1')
    Check "and defaults to the same interval" $true ($shSource -match 'ROGUE_HEARTBEAT_MIN_INTERVAL:-900')
    Check "the ps default is 900 too" 900 $script:rogueBeaconMinInterval

    Write-Host "-- the seam and the trigger default ---------------------------------"
    # The param default is what keeps an OLDER hooks.json - one that passes no
    # argument - behaving exactly as it does today rather than throttling silently.
    $psSource = Get-Content -Raw $hbPath
    $libSource = Get-Content -Raw (Join-Path $pluginRoot 'scripts/beacon.ps1')
    Check "the trigger defaults to SessionStart" $true `
        ($psSource -match "param\(\[string\]\`$Trigger = 'SessionStart'\)")
    Check "the lib-only seam exists" $true ($psSource -match 'ROGUE_PS_LIB_ONLY')
    # The library must load ABOVE the seam, or this whole suite would be asserting
    # against the fallback stand-ins instead of the shipped throttle.
    $libAt  = $psSource.IndexOf('scripts\beacon.ps1')
    $seamAt = $psSource.IndexOf('if ($env:ROGUE_PS_LIB_ONLY) { return }')
    Check "the beacon library loads above the test seam" $true `
        ($libAt -gt 0 -and $seamAt -gt 0 -and $libAt -lt $seamAt)
    # Never -File and never a path dot-source: both are subject to ExecutionPolicy and
    # to a GPO-enforced policy that -ExecutionPolicy Bypass cannot override.
    Check "the library is loaded as a scriptblock, not by path" $true `
        ($psSource -match '\[scriptblock\]::Create\(\(Get-Content -Raw -LiteralPath \$beaconLib\)\)')
    # A missing or unparseable library must degrade to an UNTHROTTLED beacon: too many
    # beacons is noise, none is a roster row that looks like an uninstalled plugin.
    Check "a missing library falls back to stand-ins" $true `
        ($psSource -match 'if \(-not \(Get-Command Request-RogueBeaconSlot')
    # The stamp is written with a BOM-less UTF-8 writer. Add-Content -Encoding UTF8
    # emits a BOM on Windows PowerShell 5.1 when it creates a file, and those three
    # leading bytes would fail every TryParse that reads the stamp back - turning
    # the throttle off permanently and silently.
    Check "the stamp is written without a BOM" $true `
        ($libSource -match 'UTF8Encoding \$false')

    Write-Host "-- the stamp holds a TRUE epoch ------------------------------------"
    # `[datetime]'1970-01-01T00:00:00Z'` reads the Z as UTC and then converts to LOCAL,
    # so its Kind is Local and subtracting it from a Utc value does naive tick
    # arithmetic: the result was epoch MINUS the machine's UTC offset. Every assertion
    # above still passed, because one function both writes and reads the stamp and the
    # DELTA was correct - which is exactly why this needs its own reference clock.
    # What broke was the absolute value: hours off from the `date -u +%s` beacon.sh
    # writes to the very same path, and from ship-logs.ps1's Get-EpochSeconds.
    $drift = [Math]::Abs((Get-RogueBeaconUnixSeconds) - (Get-NowSeconds))
    Check "the epoch is within a few seconds of the real one (drift ${drift}s)" $true ($drift -le 5)
    # The construction, not just the result: a Utc-kind epoch is the only form that
    # cannot regress into the local-time trap.
    Check "the epoch is constructed with DateTimeKind::Utc" $true `
        ($libSource -match 'New-Object DateTime\(1970, 1, 1, 0, 0, 0, \[DateTimeKind\]::Utc\)')
    # Comment-stripped, the same crude line-wise way validate.yml strips them for its
    # dash-lookalike step: the comment explaining this trap necessarily quotes the bad
    # form, and matching the raw source would flag the explanation as the defect.
    $libCode = (($libSource -split "`n") | ForEach-Object { $_ -replace '#.*$', '' }) -join "`n"
    Check "and never parsed from a Z-suffixed string" $true `
        (-not ($libCode -match "\[datetime\]'1970-01-01T00:00:00Z'"))

    Write-Host "-- the interval is resolved from the env FILES, not just process env --"
    # The bug this pins: the interval used to be read from $env: at FILE SCOPE, which
    # runs before the credential files are parsed - so heartbeat.sh honored
    # ROGUE_HEARTBEAT_MIN_INTERVAL in ~/.rogue-env or an MDM C:\ProgramData\rogue\env
    # and heartbeat.ps1 ignored all of them, pinning every Windows machine to 900s.
    # Nor could a user work around it: the script is spawned DETACHED by hook.ps1, so
    # its process environment comes from Claude Code. Same failure, same shape and
    # same fix as the ROGUE_LOG_DIR bug CLAUDE.md records for the log knobs.
    # 3600 and not 0, so the case DISCRIMINATES. The process env carries the 0 trap,
    # so a regression that reads $env: sees "disabled" and answers $false here, while
    # the correct map read sees 3600 and throttles. Asserting on 0 would have agreed
    # with both and passed against the very bug it exists to catch.
    Set-Stamp (Get-NowSeconds)
    Check "an env-file value reaches the throttle" $true (Throttled 'Stop' '3600')
    # Order matters as much as the read: resolving before the map is built is the bug.
    $mapAt  = $psSource.IndexOf("foreach (`$k in 'ROGUE_API_KEY'")
    $initAt = $psSource.IndexOf('Initialize-RogueBeacon $creds')
    Check "the resolver is called with the creds map" $true ($initAt -gt 0)
    Check "and called AFTER the map is built" $true ($mapAt -gt 0 -and $initAt -gt $mapAt)
    # In the override list, so process env still beats the files - the precedence
    # every other knob in this dispatcher follows.
    Check "the knob is in the process-env override list" $true `
        ($psSource -match "'ROGUE_HEARTBEAT_MIN_INTERVAL'\)\s*\{")
    # Belt and braces: no file-scope $env: read may come back, in the dispatcher or in
    # the library. The only permitted mention of the variable is the override list.
    $envReads = ([regex]::Matches($psSource + $libSource, '\$env:ROGUE_HEARTBEAT_MIN_INTERVAL')).Count
    # Single-quoted: PowerShell escapes with a backtick, not a backslash, so "\$env:"
    # would still interpolate and fail to parse.
    Check 'the knob is never read via $env: directly' 0 $envReads

    Write-Host "-- the shared library is byte-identical across the ps plugins ---------"
    # The five copies are generated by scripts/sync-shared-scripts.sh. An edit made to
    # a plugin's copy is silently reverted by the next sync, and a machine whose
    # plugins disagree about the interval or the stamp path throttles inconsistently.
    $shared = Join-Path $repo 'scripts/shared/beacon.ps1'
    $sharedBytes = [System.IO.File]::ReadAllBytes($shared)
    foreach ($p in 'rogue','codex','cursor','copilot','antigravity') {
        $copy = Join-Path $repo "plugins/$p/scripts/beacon.ps1"
        $same = $false
        if (Test-Path -LiteralPath $copy) {
            $b = [System.IO.File]::ReadAllBytes($copy)
            $same = ($b.Length -eq $sharedBytes.Length)
            if ($same) {
                for ($i = 0; $i -lt $b.Length; $i++) {
                    if ($b[$i] -ne $sharedBytes[$i]) { $same = $false; break }
                }
            }
        }
        Check "plugins/$p/scripts/beacon.ps1 matches scripts/shared" $true $same
    }

    Write-Host "-- every ps plugin wires the throttle the same way -------------------"
    # One assertion each, per plugin, for the four things that make the throttle apply.
    # Each was a real way to get this wrong while the code still looked finished: a
    # heartbeat with no -Trigger parameter throttles nothing; one that never loads the
    # library throttles nothing; one that never calls Initialize-RogueBeacon with the
    # CREDS MAP silently ignores every env file (the original Windows bug); and a slug
    # typo gives that plugin its own stamp file, so it and its own log shipper disagree
    # about which agent they are.
    #
    # Slugs match the LOG FILE names, not the roster families - codex ships codex.log
    # under family openai, and copilot's roster label is github_copilot.
    foreach ($row in @(
        @{ Plugin = 'codex';       File = 'scripts/heartbeat.ps1'; Slug = 'codex';       Session = 'SessionStart' },
        @{ Plugin = 'copilot';     File = 'scripts/heartbeat.ps1'; Slug = 'copilot';     Session = 'sessionStart' },
        @{ Plugin = 'antigravity'; File = 'scripts/heartbeat.ps1'; Slug = 'antigravity'; Session = 'SessionStart' },
        # Cursor has no heartbeat.ps1 - its beacon is inline in the dispatcher, which is
        # also the only plugin where a throttled beacon is worth a log line (the
        # decision happens where the log is being written).
        @{ Plugin = 'cursor';      File = 'scripts/hook.ps1';      Slug = 'cursor';      Session = 'sessionStart' }
    )) {
        $src = Get-Content -Raw (Join-Path $repo "plugins/$($row.Plugin)/$($row.File)")
        $tag = $row.Plugin
        Check "$tag loads the beacon library" $true ($src -match 'scripts\\beacon\.ps1')
        Check "$tag claims the slot as '$($row.Slug)'" $true `
            ($src -match "Request-RogueBeaconSlot -Slug '$($row.Slug)'")
        Check "$tag initialises the throttle from the creds map" $true `
            ($src -match 'Initialize-RogueBeacon \$(script:)?creds')
        Check "$tag lists the knob in its override pass" $true `
            ($src -match "'ROGUE_HEARTBEAT_MIN_INTERVAL'")
        if ($row.File -eq 'scripts/heartbeat.ps1') {
            Check "$tag defaults its trigger to $($row.Session)" $true `
                ($src -match "\`$Trigger = '$($row.Session)'")
        }
    }
    # Cursor's per-turn trigger is a dispatcher branch rather than a script argument.
    $curSrc = Get-Content -Raw (Join-Path $repo 'plugins/cursor/scripts/hook.ps1')
    Check "cursor treats stop as the per-turn trigger" $true `
        ($curSrc -match "elseif \(\`$EventName -eq 'stop'\)\s+\{ \`$hbUnthrottled = \`$false \}")
    Check "cursor logs a throttled beacon" $true ($curSrc -match 'heartbeat=throttled')

    Write-Host "-- every ps dispatcher fires a per-turn trigger at all ---------------"
    # The whole point of this change: on a session-start-only trigger a session left
    # open for days produced exactly one beacon and one log upload for its lifetime.
    $codexHook = Get-Content -Raw (Join-Path $repo 'plugins/codex/scripts/hook.ps1')
    Check "codex hook.ps1 spawns the Stop heartbeat" $true `
        ($codexHook -match "ROGUE_HEARTBEAT_SCRIPT\)\)\) Stop")
    $copHook = Get-Content -Raw (Join-Path $repo 'plugins/copilot/scripts/hook.ps1')
    Check "copilot hook.ps1 spawns the agentStop heartbeat" $true `
        ($copHook -match "ROGUE_HEARTBEAT_SCRIPT\)\)\) agentStop")
    # ...and only for the MAIN agent: Copilot fires agentStop for subagents too, and a
    # turn using three of them would otherwise queue four beacons.
    Check "copilot skips a subagent's agentStop" $true `
        ($copHook -match "\`$EventName -eq 'agentStop' -and -not \`$subagentId")
    $agHook = Get-Content -Raw (Join-Path $repo 'plugins/antigravity/scripts/hook.ps1')
    Check "antigravity hook.ps1 maps Stop to the per-turn trigger" $true `
        ($agHook -match "\`$hbTrigger = 'Stop'")
    # The step count is EXTRACTED, never -like matched: '*"initialNumSteps":1*' also
    # matches 18, so every continuation of a long conversation looked like a fresh one
    # and got an unthrottled beacon. This is a real bug this suite caught on the sh
    # side; the same shape must not come back here.
    Check "antigravity extracts initialNumSteps numerically" $true `
        ($agHook -match '\[regex\]::Match\(\$payload, .\"initialNumSteps\"')
    Check "antigravity never globs initialNumSteps" $true `
        (-not ($agHook -match '-like .\*"initialNumSteps"'))
}
finally {
    $env:USERPROFILE = $saveProfile
    $env:ROGUE_HEARTBEAT_MIN_INTERVAL = $saveInterval
    $env:ROGUE_PS_LIB_ONLY = $saveLibOnly
    $env:CLAUDE_PLUGIN_ROOT = $saveRoot
    Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fails -eq 0) { Write-Host "ALL HEARTBEAT PS1 TESTS PASSED" }
else { Write-Host "$script:fails failure(s)" }
exit $script:fails
